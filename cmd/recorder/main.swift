// windowclip recorder — captures a single macOS window with ScreenCaptureKit,
// composites it onto a styled background via Core Image, and writes a finished
// H.264 MP4 with optional mic audio. Or captures one whole display as-is: no
// background, padding or shadow, at the display's own aspect ratio.
//
// Why this owns the whole pipeline (capture → compose → encode): Remotion's
// alpha pipeline drops source transparency when re-encoding to H264, which
// produced sharp black corners around the rounded window content. Compositing
// natively in Swift via Core Image (Metal-backed CIContext) preserves the
// window's actual rounded-rect alpha as the camera-shaped mask, and outputs
// a normal opaque MP4 ready to share.
//
// Output: MP4 (H.264 video + AAC audio).
//
// Usage: recorder <target> <durationSeconds> <outputPath>
//   <target> is a CGWindowID, or display:<CGDirectDisplayID>, or display:main
//
// Env:
//   RECORDER_BG_IMAGE=<path> — background image, scale-to-fill + centre crop;
//                              unset, empty or undecodable → mesh gradient
//   RECORDER_NO_AUDIO=1      — skip mic capture
//   RECORDER_EXCLUDE_PID=<n> — display capture leaves this process's windows
//                              out of the frames (the app passes its own pid,
//                              so its pill never appears in a screen recording)
//   RECORDER_SOLID_RED=1     — probe mode: solid red bg, no shadow/padding,
//                              used to verify alpha-through-compose end-to-end
//   SIGUSR2                  — discard: stop and delete the take instead of
//                              saving it; exits 2.
//
// The take is written to a hidden `.<name>.partial-<pid>.mp4` beside the
// output and renamed onto `outputPath` only once it is complete, so nothing
// at `outputPath` is touched until there is a finished file to put there.
//
//   RECORDER_HANDSHAKE=1     — controller mode (DIG-807). Capture starts as
//                              usual, but frames are DISCARDED until SIGUSR1
//                              arrives, and lifecycle lines are written to
//                              stdout so the controller can tell warm-up from
//                              recording:
//                                windowclip:armed      capture is live and
//                                                        real frames are arriving
//                                windowclip:capturing  the take has begun
//                              This exists so a caller can pay the (variable,
//                              occasionally multi-second) start-up cost BEFORE
//                              the user's clock starts, instead of subtracting
//                              it from the recording.
//
// Requires Screen Recording AND Microphone permission on the parent terminal app.

import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal
import ScreenCaptureKit
import SwiftUI

// MARK: - Args

enum CaptureTarget {
    case window(CGWindowID)
    case display(CGDirectDisplayID)

    init?(argument: String) {
        if argument == "display:main" {
            self = .display(CGMainDisplayID())
        } else if argument.hasPrefix("display:"), let id = UInt32(argument.dropFirst("display:".count)) {
            self = .display(CGDirectDisplayID(id))
        } else if let id = UInt32(argument) {
            self = .window(CGWindowID(id))
        } else {
            return nil
        }
    }
}

let args = CommandLine.arguments
guard args.count >= 4,
      let captureTarget = CaptureTarget(argument: args[1]),
      let durationS = Double(args[2]) else {
    FileHandle.standardError.write(Data("usage: recorder <windowID | display:<id> | display:main> <durationSeconds> <outputPath>\n".utf8))
    exit(64)
}
let outputPath = args[3]
let partialURL: URL = {
    let output = URL(fileURLWithPath: outputPath)
    let ext = output.pathExtension.isEmpty ? "mp4" : output.pathExtension
    return output.deletingLastPathComponent()
        .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).partial-\(getpid()).\(ext)")
}()

func removePartial() {
    if FileManager.default.fileExists(atPath: partialURL.path) {
        try? FileManager.default.removeItem(at: partialURL)
    }
}
let excludedPID = ProcessInfo.processInfo.environment["RECORDER_EXCLUDE_PID"].flatMap { pid_t($0) }
let captureAudio = ProcessInfo.processInfo.environment["RECORDER_NO_AUDIO"] != "1"
let probeSolidRed = ProcessInfo.processInfo.environment["RECORDER_SOLID_RED"] == "1"
/// Controller mode: hold the take until SIGUSR1, and report lifecycle on stdout.
/// Off by default so the direct/headless contract (and its stdout) is unchanged.
let handshake = ProcessInfo.processInfo.environment["RECORDER_HANDSHAKE"] == "1"
// Optional file path to use as the canvas background image. JPEG/PNG/HEIC all
// supported. Center-cropped + scaled to output dims. If unset (or file missing),
// falls back to the procedural mesh gradient.
let backgroundImagePath = ProcessInfo.processInfo.environment["RECORDER_BG_IMAGE"]

// 1920x1080 final output. Hardcoded for now — backgrounds and presets land later.
let OUTPUT_W = 1920
let OUTPUT_H = 1080
let WINDOW_BITRATE = 12_000_000

let DISPLAY_MAX_W = 3840
let DISPLAY_MAX_H = 2160
let DISPLAY_MAX_BITRATE = 40_000_000

func displayOutputSize(pixelWidth: Int, pixelHeight: Int) -> (width: Int, height: Int) {
    let fit = min(1.0, Double(DISPLAY_MAX_W) / Double(pixelWidth), Double(DISPLAY_MAX_H) / Double(pixelHeight))
    func even(_ v: Double) -> Int { max(2, Int(v / 2) * 2) }
    return (even(Double(pixelWidth) * fit), even(Double(pixelHeight) * fit))
}

func displayBitrate(width: Int, height: Int) -> Int {
    let perPixel = Double(WINDOW_BITRATE) / Double(OUTPUT_W * OUTPUT_H)
    return min(DISPLAY_MAX_BITRATE, Int(perPixel * Double(width * height)))
}

/// When `durationS == 0` we run open-ended until SIGTERM/SIGINT. This safety
/// cap stops a forgotten recording from filling the disk if the user walks
/// away. 5 minutes is generous for a single demo clip; bump if it turns out to
/// matter.
let OPEN_ENDED_MAX_DURATION_S: Double = 300

/// If capture never produces a first written frame, stop rather than hang.
/// Generous, because in controller mode this span legitimately covers the
/// caller's countdown as well as start-up.
let STARTUP_WATCHDOG_S: Double = 60

/// One line per lifecycle event, on stdout, for a controlling process to read.
/// Unbuffered (FileHandle.write is a direct syscall), so the reader sees each
/// line the moment it happens — the whole point is that the controller learns
/// "ready" without polling.
func emitLifecycle(_ event: String) {
    guard handshake else { return }
    FileHandle.standardOutput.write(Data("windowclip:\(event)\n".utf8))
}

/// The take gate. Capture may be running (warming SCK, CoreAudio, the encoder)
/// while this is still shut; frames that arrive before it opens are dropped
/// before any compositing work, so warm-up is nearly free.
final class CaptureGate {
    private let lock = NSLock()
    private var open: Bool
    private var openedAt: CMTime?
    init(open: Bool) { self.open = open }

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return open
    }

    /// True only for the call that actually opened it.
    @discardableResult
    func openNow() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if open { return false }
        open = true
        // SCK stamps every frame on the host clock, so reading the same clock
        // here gives an exact boundary: frames already in flight when "go"
        // arrived were captured during warm-up and are not part of the take.
        // Without this the file starts ~0.19s early — the pipeline's delivery
        // latency, silently prepended to the recording.
        openedAt = CMClockGetTime(CMClockGetHostTimeClock())
        return true
    }

    /// Both halves under one lock, so a frame can't be tested against a gate
    /// state that changed between the two reads.
    func snapshot() -> (open: Bool, openedAt: CMTime?) {
        lock.lock(); defer { lock.unlock() }
        return (open, openedAt)
    }

    /// Ends the take at this instant. Tearing a capture down is not free —
    /// stopCapture took ~0.3-0.45s to actually halt delivery — and every frame
    /// that arrives meanwhile would otherwise land in the file, overshooting
    /// the requested duration by the teardown latency. Closing here makes the
    /// artifact's length a property of the deadline rather than of how long
    /// the shutdown happened to take.
    func closeNow() {
        lock.lock(); defer { lock.unlock() }
        open = false
    }
}

// MARK: - Composer

/// Loads a JPEG/PNG/HEIC from disk and scales/center-crops it to the output
/// canvas dimensions. Returns nil if the file is missing or undecodable.
func loadBackgroundImage(path: String, width: Int, height: Int) -> CIImage? {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        FileHandle.standardError.write(Data("recorder: failed to load bg image \(path)\n".utf8))
        return nil
    }
    let srcCI = CIImage(cgImage: cg)
    let srcW = CGFloat(cg.width)
    let srcH = CGFloat(cg.height)
    let outW = CGFloat(width)
    let outH = CGFloat(height)

    // Scale-to-fill: scale by the LARGER of the two ratios so the smaller
    // dimension of the source covers the canvas. Then center-crop the excess.
    let scale = max(outW / srcW, outH / srcH)
    let scaled = srcCI.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let scaledW = srcW * scale
    let scaledH = srcH * scale
    // Center the scaled image, then crop to canvas. CIImage origin is bottom-left.
    let tx = (outW - scaledW) / 2
    let ty = (outH - scaledH) / 2
    let positioned = scaled.transformed(by: CGAffineTransform(translationX: tx, y: ty))
    return positioned.cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))
}

/// Builds the styled background CIImage that frames every windowclip recording.
///
/// Uses SwiftUI's `MeshGradient` (Sequoia+) for a tasteful warm-tone field
/// that recedes behind the recorded window. A 3x3 mesh gives enough control
/// to get richness without busy-ness: warm peach top, amber midline,
/// deep mocha bottom, with subtle hue variation midfield.
///
/// Rendered once at recorder init and cached as a CIImage. Per-frame
/// composition just references this image — no recomputation in the hot path.
@MainActor
func makeMeshGradientBackground(width: Int, height: Int) -> CIImage {
    // Warm "Tahoe sunset" palette. Points are normalized [0..1] in the grid.
    // Colors flow from peach top-left → amber midline → deep warm mocha
    // bottom-right, with subtle terracotta and rust nodes interpolating.
    let view = MeshGradient(
        width: 3,
        height: 3,
        points: [
            [0.00, 0.00], [0.50, 0.00], [1.00, 0.00],
            [0.00, 0.50], [0.55, 0.45], [1.00, 0.50],
            [0.00, 1.00], [0.50, 1.00], [1.00, 1.00],
        ],
        colors: [
            Color(red: 0.99, green: 0.80, blue: 0.62),  // top-left:    soft peach
            Color(red: 0.96, green: 0.65, blue: 0.40),  // top-center:  warm amber
            Color(red: 0.85, green: 0.45, blue: 0.32),  // top-right:   terracotta
            Color(red: 0.78, green: 0.42, blue: 0.32),  // mid-left:    warm rust
            Color(red: 0.55, green: 0.28, blue: 0.25),  // center:      deep terracotta
            Color(red: 0.45, green: 0.22, blue: 0.22),  // mid-right:   warm umber
            Color(red: 0.32, green: 0.16, blue: 0.18),  // bot-left:    deep warm
            Color(red: 0.22, green: 0.11, blue: 0.13),  // bot-center:  mocha
            Color(red: 0.12, green: 0.07, blue: 0.09),  // bot-right:   near-black
        ]
    )
    .frame(width: CGFloat(width), height: CGFloat(height))

    let renderer = ImageRenderer(content: view)
    renderer.scale = 1.0  // canvas is already at output resolution
    guard let cgImage = renderer.cgImage else {
        // Fallback: solid warm color if SwiftUI rendering somehow fails.
        FileHandle.standardError.write(Data("recorder: MeshGradient render failed, falling back to flat color\n".utf8))
        return CIImage(color: CIColor(red: 0.55, green: 0.28, blue: 0.25))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return CIImage(cgImage: cgImage)
}

/// Builds a soft drop shadow from the window's alpha mask. Steps:
/// 1. Keep only the alpha channel as a gray image
/// 2. Tint to black with target shadow opacity
/// 3. Blur for softness
/// 4. Offset down/right
func makeShadow(for window: CIImage, blur: Double, offsetX: Double, offsetY: Double, opacity: Double) -> CIImage {
    // CIMaskToAlpha turns a grayscale into an alpha-only image. To get just the
    // window's alpha as a tinted shape, multiply the original by a solid black,
    // then blur, then move.
    let blackTint = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(opacity)))
        .cropped(to: window.extent)
    // sourceIn: shadow = blackTint where window has alpha > 0
    let masked = blackTint.applyingFilter("CISourceInCompositing", parameters: [
        kCIInputBackgroundImageKey: window,
    ])
    let blurred = masked.applyingFilter("CIGaussianBlur", parameters: [
        kCIInputRadiusKey: blur,
    ])
    return blurred.transformed(by: CGAffineTransform(translationX: CGFloat(offsetX), y: CGFloat(-offsetY)))
}

/// Computes the (scale, translation) to aspect-fit a srcW x srcH source into
/// an inner rect of [padX, padY] padding inside an outputW x outputH canvas.
/// Returns the affine transform to apply to the source CIImage.
func fitTransform(srcW: Int, srcH: Int, outputW: Int, outputH: Int, padRatio: CGFloat) -> CGAffineTransform {
    let padX = CGFloat(outputW) * padRatio
    let padY = CGFloat(outputH) * padRatio
    let innerW = CGFloat(outputW) - 2 * padX
    let innerH = CGFloat(outputH) - 2 * padY
    let srcAspect = CGFloat(srcW) / CGFloat(srcH)
    let innerAspect = innerW / innerH

    let dispW: CGFloat, dispH: CGFloat
    if srcAspect > innerAspect {
        dispW = innerW
        dispH = innerW / srcAspect
    } else {
        dispH = innerH
        dispW = innerH * srcAspect
    }
    let scale = dispW / CGFloat(srcW)
    let tx = (CGFloat(outputW) - dispW) / 2
    let ty = (CGFloat(outputH) - dispH) / 2
    return CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
}

/// Composites a window-shaped CIImage (with alpha) onto a styled background.
/// Renders into reusable CVPixelBuffers from a pool — minimizes per-frame allocs.
final class Composer {
    enum Layout {
        case styled
        case solidProbe
        case passthrough
    }

    let ciContext: CIContext
    let outputSize: CGSize
    let pixelBufferPool: CVPixelBufferPool
    let background: CIImage
    let layout: Layout
    let padRatio: CGFloat = 0.08
    // Tasteful "macOS window on desktop" shadow — visible but not heavy.
    let shadowBlur: Double = 55
    let shadowOffsetX: Double = 0
    let shadowOffsetY: Double = 35
    let shadowOpacity: Double = 0.7

    init(outputW: Int, outputH: Int, layout: Layout, background: CIImage) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "composer", code: 1, userInfo: [NSLocalizedDescriptionKey: "no Metal device"])
        }
        self.ciContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
            .outputColorSpace: CGColorSpaceCreateDeviceRGB(),
        ])
        self.outputSize = CGSize(width: outputW, height: outputH)
        self.layout = layout

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputW,
            kCVPixelBufferHeightKey as String: outputH,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 4,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, attrs as CFDictionary, &pool)
        guard let pool = pool else {
            throw NSError(domain: "composer", code: 2, userInfo: [NSLocalizedDescriptionKey: "pool creation failed"])
        }
        self.pixelBufferPool = pool

        self.background = background
    }

    func compose(_ source: CMSampleBuffer) -> CMSampleBuffer? {
        guard let srcBuffer = CMSampleBufferGetImageBuffer(source) else { return nil }
        let srcW = CVPixelBufferGetWidth(srcBuffer)
        let srcH = CVPixelBufferGetHeight(srcBuffer)
        let sourceCI = CIImage(cvPixelBuffer: srcBuffer)

        let composed: CIImage
        switch layout {
        case .solidProbe:
            let probeBg = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
                .cropped(to: CGRect(x: 0, y: 0, width: srcW, height: srcH))
            composed = sourceCI.composited(over: probeBg)
        case .passthrough:
            let transform = fitTransform(srcW: srcW, srcH: srcH, outputW: Int(outputSize.width), outputH: Int(outputSize.height), padRatio: 0)
            composed = sourceCI.transformed(by: transform).composited(over: background)
        case .styled:
            // Scale + position the window inside the canvas with padding.
            let transform = fitTransform(srcW: srcW, srcH: srcH, outputW: Int(outputSize.width), outputH: Int(outputSize.height), padRatio: padRatio)
            let positionedWindow = sourceCI.transformed(by: transform)
            // Build drop shadow from the positioned (and thus scaled) window.
            let shadow = makeShadow(for: positionedWindow, blur: shadowBlur, offsetX: shadowOffsetX, offsetY: shadowOffsetY, opacity: shadowOpacity)
            // Layer order: bg → shadow → window
            let shadowOverBg = shadow.composited(over: background)
            composed = positionedWindow.composited(over: shadowOverBg)
        }

        var outBuf: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &outBuf)
        guard let outBuf = outBuf else { return nil }
        ciContext.render(composed, to: outBuf)

        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: outBuf,
                                                     formatDescriptionOut: &formatDesc)
        guard let formatDesc = formatDesc else { return nil }

        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(source, at: 0, timingInfoOut: &timing)

        var newBuf: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                           imageBuffer: outBuf,
                                           dataReady: true,
                                           makeDataReadyCallback: nil,
                                           refcon: nil,
                                           formatDescription: formatDesc,
                                           sampleTiming: &timing,
                                           sampleBufferOut: &newBuf)
        return newBuf
    }
}

// MARK: - Recorder

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    let audioInput: AVAssetWriterInput?
    let composer: Composer
    var sessionStarted = false
    let writerLock = NSLock()

    /// Shut during pre-roll in controller mode; permanently open otherwise.
    var gate = CaptureGate(open: true)
    /// Fired once, on the first genuinely complete frame — capture is proven live.
    var onArmed: () -> Void = {}
    /// Fired once, when the writer session opens on the first frame of the take.
    var onSessionStarted: () -> Void = {}
    /// How long the take should run, measured on the MEDIA timeline. A wall
    /// clock can't express this: the first frame's presentation timestamp
    /// trails its callback by ~0.19s of pipeline latency, so a wall-clock timer
    /// started at that callback runs the file 0.19s long. Counting in frame
    /// timestamps makes the artifact's length independent of delivery latency.
    var takeLimitSeconds: Double?
    /// Fired once, when the take has run its requested length.
    var onTakeComplete: () -> Void = {}
    /// Touched only from the single serial sample-handler queue.
    private var armedReported = false
    private var takeCompleteFired = false
    private var sessionStartSeconds: Double = 0

    init(outputURL: URL, outputW: Int, outputH: Int, bitrate: Int, withAudio: Bool, composer: Composer) throws {
        self.writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        self.composer = composer

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputW,
            AVVideoHeightKey: outputH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        self.videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        self.videoInput.expectsMediaDataInRealTime = true
        self.writer.add(videoInput)

        if withAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 128_000,
            ]
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            ai.expectsMediaDataInRealTime = true
            self.audioInput = ai
            self.writer.add(ai)
        } else {
            self.audioInput = nil
        }
        super.init()
    }

    private func ensureSession(at pts: CMTime) -> Bool {
        if sessionStarted { return false }
        if !writer.startWriting() {
            FileHandle.standardError.write(Data("startWriting failed: \(writer.error?.localizedDescription ?? "?")\n".utf8))
            return false
        }
        writer.startSession(atSourceTime: pts)
        sessionStartSeconds = CMTimeGetSeconds(pts)
        sessionStarted = true
        return true
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard sampleBuffer.isValid else { return }

        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let first = attachments.first,
              let rawStatus = first[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus),
              status == .complete else {
            return
        }

        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }

        // A real frame in hand is the only honest proof that the whole path —
        // permission, SCK, the audio device, the encoder — is live. Report it
        // even while the gate is shut, because that is precisely what lets a
        // controller start the user's clock at a moment capture can honour.
        if !armedReported {
            armedReported = true
            onArmed()
        }

        // Pre-roll: capture is warm but the take hasn't started. Drop ahead of
        // compositing so holding the gate shut costs almost nothing.
        let gateState = gate.snapshot()
        guard gateState.open else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // In flight when "go" landed — captured during warm-up, not the take.
        if let openedAt = gateState.openedAt, CMTimeCompare(pts, openedAt) < 0 { return }

        // Compose: source (alpha-shaped window) on background → opaque output buffer.
        guard let composed = composer.compose(sampleBuffer) else { return }

        writerLock.lock()
        let didStartSession = ensureSession(at: pts)
        writerLock.unlock()
        if didStartSession { onSessionStarted() }

        if videoInput.isReadyForMoreMediaData {
            if !videoInput.append(composed) {
                FileHandle.standardError.write(Data("video append failed: \(writer.error?.localizedDescription ?? "?")\n".utf8))
            }
        }

        if let limit = takeLimitSeconds, !takeCompleteFired,
           CMTimeGetSeconds(pts) - sessionStartSeconds >= limit {
            takeCompleteFired = true
            onTakeComplete()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("stream stopped with error: \(error.localizedDescription)\n".utf8))
    }

    // MARK: AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let audioInput = audioInput else { return }
        guard sampleBuffer.isValid else { return }

        writerLock.lock()
        let started = sessionStarted
        writerLock.unlock()
        if !started { return }
        // Same gate as video, so both tracks end on the same instant instead of
        // audio trailing on through teardown.
        guard gate.isOpen else { return }

        if audioInput.isReadyForMoreMediaData {
            if !audioInput.append(sampleBuffer) {
                FileHandle.standardError.write(Data("audio append failed: \(writer.error?.localizedDescription ?? "?")\n".utf8))
            }
        }
    }
}

// MARK: - Capture flow

func setupAudioCapture(recorder: Recorder) throws -> AVCaptureSession {
    let session = AVCaptureSession()
    guard let device = AVCaptureDevice.default(for: .audio) else {
        throw NSError(domain: "recorder", code: 10, userInfo: [
            NSLocalizedDescriptionKey: "no default audio capture device",
        ])
    }
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else {
        throw NSError(domain: "recorder", code: 11, userInfo: [NSLocalizedDescriptionKey: "can't add audio input"])
    }
    session.addInput(input)

    let output = AVCaptureAudioDataOutput()
    let queue = DispatchQueue(label: "windowclip.recorder.audio", qos: .userInteractive)
    output.setSampleBufferDelegate(recorder, queue: queue)
    guard session.canAddOutput(output) else {
        throw NSError(domain: "recorder", code: 12, userInfo: [NSLocalizedDescriptionKey: "can't add audio output"])
    }
    session.addOutput(output)
    return session
}

struct CaptureSetup {
    let filter: SCContentFilter
    let config: SCStreamConfiguration
    let captureW: Int
    let captureH: Int
    let outW: Int
    let outH: Int
    let bitrate: Int
    let composer: Composer
}

func windowCaptureSetup(windowID: CGWindowID, content: SCShareableContent) async throws -> CaptureSetup {
    guard let target = content.windows.first(where: { $0.windowID == windowID }) else {
        let available = content.windows.map { "\($0.windowID)=\($0.owningApplication?.applicationName ?? "?"):\($0.title ?? "")" }.joined(separator: "\n")
        throw NSError(domain: "recorder", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "window \(windowID) not found. Available:\n\(available)",
        ])
    }

    FileHandle.standardError.write(Data("recorder: target \(windowID) — \(target.owningApplication?.applicationName ?? "?") — \(target.title ?? "")\n".utf8))

    let backingScale = NSScreen.main?.backingScaleFactor ?? 2.0
    let pxW = Int(target.frame.width * backingScale)
    let pxH = Int(target.frame.height * backingScale)

    // Output dims:
    //   probe mode → match source so alpha-corner pixels are at a predictable
    //   location for byte-sampling discriminating test
    //   real mode → fixed 1920x1080
    let outW = probeSolidRed ? pxW : OUTPUT_W
    let outH = probeSolidRed ? pxH : OUTPUT_H

    let filter = SCContentFilter(desktopIndependentWindow: target)
    let config = SCStreamConfiguration()
    config.width = pxW
    config.height = pxH
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.queueDepth = 8
    config.showsCursor = true
    config.scalesToFit = true
    // SCStreamConfiguration.backgroundColor defaults to clear — alpha-correct.

    // Build the background CIImage. Priority:
    //   1. RECORDER_BG_IMAGE env var → load JPEG/PNG/HEIC, scale-to-fill
    //   2. Probe mode → solid red
    //   3. Default → SwiftUI mesh gradient (requires MainActor hop)
    let backgroundImage: CIImage
    if probeSolidRed {
        backgroundImage = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))
    } else if let bgPath = backgroundImagePath, let loaded = loadBackgroundImage(path: bgPath, width: outW, height: outH) {
        FileHandle.standardError.write(Data("recorder: bg image \(bgPath)\n".utf8))
        backgroundImage = loaded
    } else {
        if backgroundImagePath != nil {
            FileHandle.standardError.write(Data("recorder: bg image failed to load, using mesh gradient\n".utf8))
        }
        backgroundImage = await MainActor.run {
            makeMeshGradientBackground(width: outW, height: outH)
        }
    }
    let composer = try Composer(outputW: outW, outputH: outH, layout: probeSolidRed ? .solidProbe : .styled, background: backgroundImage)
    return CaptureSetup(filter: filter, config: config, captureW: pxW, captureH: pxH, outW: outW, outH: outH, bitrate: WINDOW_BITRATE, composer: composer)
}

func displayCaptureSetup(displayID: CGDirectDisplayID, content: SCShareableContent) throws -> CaptureSetup {
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
        let available = content.displays.map { "\($0.displayID) \($0.width)x\($0.height)" }.joined(separator: "\n")
        throw NSError(domain: "recorder", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "display \(displayID) not found. Available:\n\(available)",
        ])
    }
    let excluded = content.applications.filter { $0.processID == excludedPID }
    if let excludedPID, excluded.isEmpty {
        FileHandle.standardError.write(Data("recorder: no running application with pid \(excludedPID) to exclude\n".utf8))
    }
    let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])

    let pixelW = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
    let pixelH = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
    let (outW, outH) = displayOutputSize(pixelWidth: pixelW, pixelHeight: pixelH)
    FileHandle.standardError.write(Data("recorder: target display \(displayID) — \(pixelW)x\(pixelH) px\(excluded.isEmpty ? "" : ", excluding pid \(excluded[0].processID) \(excluded[0].applicationName)")\n".utf8))

    let config = SCStreamConfiguration()
    config.width = outW
    config.height = outH
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.queueDepth = 8
    config.showsCursor = true
    config.scalesToFit = true

    let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
        .cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))
    let composer = try Composer(outputW: outW, outputH: outH, layout: .passthrough, background: black)
    return CaptureSetup(filter: filter, config: config, captureW: outW, captureH: outH, outW: outW, outH: outH, bitrate: displayBitrate(width: outW, height: outH), composer: composer)
}

func run() async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let setup: CaptureSetup
    switch captureTarget {
    case let .window(windowID):
        setup = try await windowCaptureSetup(windowID: windowID, content: content)
    case let .display(displayID):
        setup = try displayCaptureSetup(displayID: displayID, content: content)
    }
    let filter = setup.filter
    let config = setup.config
    let pxW = setup.captureW
    let pxH = setup.captureH
    let outW = setup.outW
    let outH = setup.outH

    let recorder = try Recorder(outputURL: partialURL, outputW: outW, outputH: outH, bitrate: setup.bitrate, withAudio: captureAudio, composer: setup.composer)

    let stream = SCStream(filter: filter, configuration: config, delegate: recorder)
    let videoQueue = DispatchQueue(label: "windowclip.recorder.video", qos: .userInteractive)
    try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: videoQueue)

    var audioSession: AVCaptureSession? = nil
    if captureAudio {
        do { audioSession = try setupAudioCapture(recorder: recorder) }
        catch {
            FileHandle.standardError.write(Data("recorder: audio setup failed, recording silently: \(error.localizedDescription)\n".utf8))
        }
    }

    // Stop trigger: either fixed duration elapses, signal fires (SIGTERM/SIGINT),
    // or the open-ended safety cap kicks in. Whichever happens first.
    //
    // Using a DispatchSemaphore signaled from any of three sources, then
    // bridged to async via a continuation. This blocks the run() task until
    // stop is requested.
    let stopSemaphore = DispatchSemaphore(value: 0)
    let stopLock = NSLock()
    var stopFired = false
    var discard = false
    let signalStop: (String) -> Void = { reason in
        stopLock.lock(); defer { stopLock.unlock() }
        if stopFired { return }
        stopFired = true
        if reason == "SIGUSR2" { discard = true }
        // Close the take FIRST, before the (slow) orderly teardown, so the file
        // ends where the caller asked rather than wherever stopCapture landed.
        recorder.gate.closeNow()
        FileHandle.standardError.write(Data("recorder: stop requested (\(reason))\n".utf8))
        stopSemaphore.signal()
    }

    // SIGTERM: clean stop, what Claude sends via `kill <pid>`. Default action
    // is process termination — we override with SIG_IGN and capture via
    // DispatchSource so we get a chance to finalize the writer.
    signal(SIGTERM, SIG_IGN)
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    sigtermSource.setEventHandler { signalStop("SIGTERM") }
    sigtermSource.resume()

    // SIGINT: same as SIGTERM, lets `kill -INT` or Ctrl-C work cleanly too.
    signal(SIGINT, SIG_IGN)
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sigintSource.setEventHandler { signalStop("SIGINT") }
    sigintSource.resume()

    // SIGUSR1: "go" — open the gate and let the take begin. Only meaningful in
    // controller mode; harmless otherwise, since the gate is already open.
    signal(SIGUSR1, SIG_IGN)
    let sigusr1Source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global())
    sigusr1Source.setEventHandler {
        if recorder.gate.openNow() {
            FileHandle.standardError.write(Data("recorder: go (SIGUSR1)\n".utf8))
        }
    }
    sigusr1Source.resume()

    signal(SIGUSR2, SIG_IGN)
    let sigusr2Source = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .global())
    sigusr2Source.setEventHandler { signalStop("SIGUSR2") }
    sigusr2Source.resume()

    // Duration is measured from the first frame actually written, NOT from
    // process start (DIG-807). Start-up here costs 0.6s on a warm machine and
    // was measured at 3.2s with a cold CoreAudio stack; charging that to the
    // recording silently shortened it, worst of all on the short clips where
    // the loss is proportionally largest.
    let effectiveDuration: Double = durationS == 0 ? OPEN_ENDED_MAX_DURATION_S : durationS
    let durationLock = NSLock()
    var durationArmed = false
    let armDuration: () -> Void = {
        durationLock.lock()
        if durationArmed { durationLock.unlock(); return }
        durationArmed = true
        durationLock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + effectiveDuration) {
            let reason = durationS == 0 ? "open-ended safety cap (\(Int(OPEN_ENDED_MAX_DURATION_S))s)" : "duration elapsed"
            signalStop(reason)
        }
    }

    recorder.onArmed = { emitLifecycle("armed") }
    recorder.onSessionStarted = {
        emitLifecycle("capturing")
        armDuration()
    }
    // A fixed duration is honoured on the media timeline; the wall-clock timer
    // above stays on as the backstop for a stream that stops delivering.
    recorder.takeLimitSeconds = durationS > 0 ? durationS : nil
    recorder.onTakeComplete = { signalStop("duration elapsed") }
    // Controller mode holds the take until "go"; every other caller records
    // from the first frame, exactly as before.
    recorder.gate = CaptureGate(open: !handshake)

    // A take that never gets a first frame — no go signal, a vanished window —
    // must not leave the process alive forever.
    DispatchQueue.global().asyncAfter(deadline: .now() + STARTUP_WATCHDOG_S) {
        durationLock.lock()
        let started = durationArmed
        durationLock.unlock()
        if !started { signalStop("no frames within \(Int(STARTUP_WATCHDOG_S))s") }
    }

    FileHandle.standardError.write(Data("recorder: starting capture \(pxW)x\(pxH) → compose \(outW)x\(outH)\(probeSolidRed ? " [SOLID-RED PROBE]" : "")\(captureAudio ? " + mic" : " (no audio)") duration=\(durationS == 0 ? "open-ended" : "\(durationS)s")\n".utf8))
    audioSession?.startRunning()
    try await stream.startCapture()

    FileHandle.standardError.write(Data("recorder: ready\n".utf8))

    // Block until stop is requested (signal or timer).
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            stopSemaphore.wait()
            cont.resume()
        }
    }

    sigtermSource.cancel()
    sigintSource.cancel()
    sigusr1Source.cancel()
    sigusr2Source.cancel()

    FileHandle.standardError.write(Data("recorder: stopping stream...\n".utf8))
    try await stream.stopCapture()
    audioSession?.stopRunning()

    if stopLock.withLock({ discard }) {
        if recorder.writer.status == .writing { recorder.writer.cancelWriting() }
        removePartial()
        FileHandle.standardError.write(Data("recorder: discarded the take, \(outputPath) untouched\n".utf8))
        exit(2)
    }

    recorder.videoInput.markAsFinished()
    recorder.audioInput?.markAsFinished()
    await recorder.writer.finishWriting()

    if recorder.writer.status != .completed {
        throw NSError(domain: "recorder", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "writer status \(recorder.writer.status.rawValue): \(recorder.writer.error?.localizedDescription ?? "?")",
        ])
    }
    let replacing = FileManager.default.fileExists(atPath: outputPath)
    guard rename(partialURL.path, outputPath) == 0 else {
        throw NSError(domain: "recorder", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "could not move the take into place: \(String(cString: strerror(errno)))",
        ])
    }
    FileHandle.standardError.write(Data("recorder: wrote \(outputPath)\(replacing ? " (replaced the file already there)" : "")\n".utf8))
}

// MARK: - Entry

// Use RunLoop.main.run() instead of DispatchSemaphore so the main thread can
// service @MainActor hops (needed for SwiftUI MeshGradient rendering). The
// Task calls exit() directly when done to break out of the runloop.
Task {
    do {
        try await run()
        exit(0)
    } catch {
        removePartial()
        FileHandle.standardError.write(Data("recorder error: \(error)\n".utf8))
        exit(1)
    }
}
RunLoop.main.run()
