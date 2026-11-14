import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

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

// MARK: - Recorder

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    let audioInput: AVAssetWriterInput?
    let composer: Composer
    var sessionStarted = false
    private(set) var writerFailed = false
    let writerLock = NSLock()
    /// Fired once, if the writer cannot start; the take cannot be recorded.
    var onWriterFailed: () -> Void = {}

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
        if sessionStarted || writerFailed { return false }
        if !writer.startWriting() {
            writerFailed = true
            writeDiagnostic(Data("recorder: startWriting failed: \(writer.error?.localizedDescription ?? "?")\n".utf8))
            onWriterFailed()
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
        handleCompleteFrame(sampleBuffer)
    }

    /// Every complete frame, from ScreenCaptureKit or the synthetic source.
    func handleCompleteFrame(_ sampleBuffer: CMSampleBuffer) {
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
        let writing = sessionStarted
        writerLock.unlock()
        if didStartSession { onSessionStarted() }
        guard writing else { return }

        if videoInput.isReadyForMoreMediaData {
            if !videoInput.append(composed) {
                writeDiagnostic(Data("video append failed: \(writer.error?.localizedDescription ?? "?")\n".utf8))
            }
        }

        if let limit = takeLimitSeconds, !takeCompleteFired,
           CMTimeGetSeconds(pts) - sessionStartSeconds >= limit {
            takeCompleteFired = true
            onTakeComplete()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        writeDiagnostic(Data("stream stopped with error: \(error.localizedDescription)\n".utf8))
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
                writeDiagnostic(Data("audio append failed: \(writer.error?.localizedDescription ?? "?")\n".utf8))
            }
        }
    }
}
