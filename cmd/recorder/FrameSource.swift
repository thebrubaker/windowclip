import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import VideoToolbox

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

protocol FrameSource {
    func start() async throws
    func stop() async throws
}

final class ScreenCaptureSource: FrameSource {
    let stream: SCStream
    init(filter: SCContentFilter, config: SCStreamConfiguration, recorder: Recorder, queue: DispatchQueue) throws {
        stream = SCStream(filter: filter, configuration: config, delegate: recorder)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: queue)
    }
    func start() async throws { try await stream.startCapture() }
    func stop() async throws { try await stream.stopCapture() }
}

/// 30 fps of generated BGRA frames stamped on the host clock, as SCK stamps its
/// own. Window-shaped (transparent rounded corners) so the styled composite
/// exercises alpha; frame n carries n as a barcode of 16 white/black blocks.
final class SyntheticSource: FrameSource {
    static let blockSize = 32
    let width: Int
    let height: Int
    let recorder: Recorder
    let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var frameIndex = 0
    private let pool: CVPixelBufferPool
    private let base: [UInt8]

    init(width: Int, height: Int, recorder: Recorder, queue: DispatchQueue) throws {
        self.width = width
        self.height = height
        self.recorder = recorder
        self.queue = queue
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        guard let pool else {
            throw NSError(domain: "recorder", code: 20, userInfo: [NSLocalizedDescriptionKey: "synthetic pool creation failed"])
        }
        self.pool = pool
        let radius = min(width, height) / 20
        var base = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let cx = x < radius ? radius - x : (x >= width - radius ? x - (width - radius - 1) : 0)
                let cy = y < radius ? radius - y : (y >= height - radius ? y - (height - radius - 1) : 0)
                if cx * cx + cy * cy > radius * radius { continue }
                base[i] = UInt8(255 * y / height)          // B
                base[i + 1] = UInt8(160)                    // G
                base[i + 2] = UInt8(255 * x / width)        // R
                base[i + 3] = 255
            }
        }
        self.base = base
    }

    func start() async throws {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 30), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.emitFrame() }
        self.timer = timer
        timer.resume()
    }

    func stop() async throws {
        queue.sync { timer?.cancel(); timer = nil }
    }

    private func emitFrame() {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let dst = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        base.withUnsafeBufferPointer { src in
            for y in 0..<height {
                memcpy(dst + y * rowBytes, src.baseAddress! + y * width * 4, width * 4)
            }
        }
        let n = frameIndex
        let b = Self.blockSize
        let top = b
        for bit in 0..<16 {
            let value: UInt8 = (n >> (15 - bit)) & 1 == 1 ? 255 : 0
            let left = b * 2 + bit * b
            guard left + b <= width, top + b <= height else { break }
            for y in top..<(top + b) {
                let row = dst + y * rowBytes + left * 4
                for x in 0..<b {
                    row[x * 4] = value; row[x * 4 + 1] = value; row[x * 4 + 2] = value; row[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        frameIndex += 1

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                 formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        recorder.handleCompleteFrame(sample)
    }
}

struct CaptureSetup {
    let makeSource: (Recorder, DispatchQueue) throws -> FrameSource
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

    writeDiagnostic(Data("recorder: target \(windowID) — \(target.owningApplication?.applicationName ?? "?") — \(target.title ?? "")\n".utf8))

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

    let composer = try await windowComposer(outW: outW, outH: outH)
    return CaptureSetup(makeSource: { try ScreenCaptureSource(filter: filter, config: config, recorder: $0, queue: $1) },
                        captureW: pxW, captureH: pxH, outW: outW, outH: outH, bitrate: WINDOW_BITRATE, composer: composer)
}

func windowComposer(outW: Int, outH: Int) async throws -> Composer {
    // Build the background CIImage. Priority:
    //   1. RECORDER_BG_IMAGE env var → load JPEG/PNG/HEIC, scale-to-fill
    //   2. Probe mode → solid red
    //   3. Default → SwiftUI mesh gradient (requires MainActor hop)
    let backgroundImage: CIImage
    if probeSolidRed {
        backgroundImage = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))
    } else if let bgPath = backgroundImagePath, let loaded = loadBackgroundImage(path: bgPath, width: outW, height: outH) {
        writeDiagnostic(Data("recorder: bg image \(bgPath)\n".utf8))
        backgroundImage = loaded
    } else {
        if backgroundImagePath != nil {
            writeDiagnostic(Data("recorder: bg image failed to load, using mesh gradient\n".utf8))
        }
        backgroundImage = await MainActor.run {
            makeMeshGradientBackground(width: outW, height: outH)
        }
    }
    return try Composer(outputW: outW, outputH: outH, layout: probeSolidRed ? .solidProbe : .styled, background: backgroundImage)
}

func syntheticWindowSetup(width: Int, height: Int) async throws -> CaptureSetup {
    writeDiagnostic(Data("recorder: target synthetic window \(width)x\(height) px\n".utf8))
    let outW = probeSolidRed ? width : OUTPUT_W
    let outH = probeSolidRed ? height : OUTPUT_H
    let composer = try await windowComposer(outW: outW, outH: outH)
    return CaptureSetup(makeSource: { try SyntheticSource(width: width, height: height, recorder: $0, queue: $1) },
                        captureW: width, captureH: height, outW: outW, outH: outH, bitrate: WINDOW_BITRATE, composer: composer)
}

func syntheticDisplaySetup(width: Int, height: Int) throws -> CaptureSetup {
    let (outW, outH) = displayOutputSize(pixelWidth: width, pixelHeight: height, hardwareAccepts: hardwareEncoderAccepts)
    writeDiagnostic(Data("recorder: target synthetic display \(width)x\(height) px\n".utf8))
    let composer = try displayComposer(outW: outW, outH: outH)
    return CaptureSetup(makeSource: { try SyntheticSource(width: outW, height: outH, recorder: $0, queue: $1) },
                        captureW: outW, captureH: outH, outW: outW, outH: outH, bitrate: displayBitrate(width: outW, height: outH), composer: composer)
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
        writeDiagnostic(Data("recorder: no running application with pid \(excludedPID) to exclude\n".utf8))
    }
    let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])

    let pixelW = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
    let pixelH = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
    let (outW, outH) = displayOutputSize(pixelWidth: pixelW, pixelHeight: pixelH, hardwareAccepts: hardwareEncoderAccepts)
    writeDiagnostic(Data("recorder: target display \(displayID) — \(pixelW)x\(pixelH) px\(excluded.isEmpty ? "" : ", excluding pid \(excluded[0].processID) \(excluded[0].applicationName)")\n".utf8))

    let config = SCStreamConfiguration()
    config.width = outW
    config.height = outH
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.queueDepth = 8
    config.showsCursor = true
    config.scalesToFit = true

    let composer = try displayComposer(outW: outW, outH: outH)
    return CaptureSetup(makeSource: { try ScreenCaptureSource(filter: filter, config: config, recorder: $0, queue: $1) },
                        captureW: outW, captureH: outH, outW: outW, outH: outH, bitrate: displayBitrate(width: outW, height: outH), composer: composer)
}

func displayComposer(outW: Int, outH: Int) throws -> Composer {
    let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
        .cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))
    return try Composer(outputW: outW, outputH: outH, layout: .passthrough, background: black)
}

func hardwareEncoderAccepts(width: Int, height: Int) -> Bool {
    var session: VTCompressionSession?
    let created = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                             encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                             outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    guard created == noErr, let session else { return false }
    defer { VTCompressionSessionInvalidate(session) }
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
    guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else { return false }
    var hardware: CFTypeRef?
    VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: &hardware)
    let accepted = (hardware as? Bool) == true
    if !accepted {
        writeDiagnostic(Data("recorder: no hardware H.264 encoder for \(width)x\(height), stepping down to fit \(DISPLAY_FALLBACK_W)x\(DISPLAY_FALLBACK_H)\n".utf8))
    }
    return accepted
}
