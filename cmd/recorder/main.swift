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
//   RECORDER_SOURCE=synthetic[:WxH] — test seam: generated frames instead of
//                              ScreenCaptureKit (no TCC, no screen). Frame n
//                              carries n as a 16-block barcode along its top
//                              edge. Default size 1600x1000 for a window
//                              target, 1920x1080 for a display target.
//   RECORDER_SOLID_RED=1     — probe mode: solid red bg, no shadow/padding,
//                              used to verify alpha-through-compose end-to-end
//   RECORDER_DISK_FLOOR_BYTES=<n> — stop and save once the output volume has
//                              less free (default 2 GB)
//   SIGUSR2                  — discard: stop and delete the take instead of
//                              saving it; exits 2.
//
// Open-ended takes have no time cap. They stop on SIGTERM/SIGINT, on the free-
// disk floor, or when the parent process exits; all three save the take.
// Exit: 0 saved, 1 failed, 2 discarded, 3 stopped before the first frame
// (nothing written), 64 usage.
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
import Foundation
import ScreenCaptureKit

// MARK: - Args

// The app or CLI reading our stdout and stderr can die mid-take. Writing to
// the closed pipes must not kill us (SIGPIPE) or raise (FileHandle) before the
// take is saved, so both streams go through write(2) and its error is ignored.
signal(SIGPIPE, SIG_IGN)
func writeDiagnostic(_ data: Data) { data.withUnsafeBytes { _ = write(STDERR_FILENO, $0.baseAddress, $0.count) } }
func writeLifecycle(_ data: Data) { data.withUnsafeBytes { _ = write(STDOUT_FILENO, $0.baseAddress, $0.count) } }

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
    writeDiagnostic(Data("usage: recorder <windowID | display:<id> | display:main> <durationSeconds> <outputPath>\n".utf8))
    exit(64)
}
let outputPath = args[3]
let partialURL = partialPath(for: outputPath, pid: getpid())
let excludedPID = ProcessInfo.processInfo.environment["RECORDER_EXCLUDE_PID"].flatMap { pid_t($0) }
let captureAudio = ProcessInfo.processInfo.environment["RECORDER_NO_AUDIO"] != "1"
let probeSolidRed = ProcessInfo.processInfo.environment["RECORDER_SOLID_RED"] == "1"
let syntheticSize: (width: Int, height: Int)?? = {
    guard let raw = ProcessInfo.processInfo.environment["RECORDER_SOURCE"], !raw.isEmpty else { return nil }
    guard raw.hasPrefix("synthetic") else {
        writeDiagnostic(Data("recorder: unknown RECORDER_SOURCE \(raw)\n".utf8))
        exit(64)
    }
    let size = raw.dropFirst("synthetic".count)
    if size.isEmpty { return .some(nil) }
    let parts = size.dropFirst().split(separator: "x")
    guard size.first == ":", parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w >= 64, h >= 64 else {
        writeDiagnostic(Data("recorder: RECORDER_SOURCE must be synthetic or synthetic:<W>x<H>\n".utf8))
        exit(64)
    }
    return .some((w, h))
}()
/// Controller mode: hold the take until SIGUSR1, and report lifecycle on stdout.
/// Off by default so the direct/headless contract (and its stdout) is unchanged.
let handshake = ProcessInfo.processInfo.environment["RECORDER_HANDSHAKE"] == "1"
// Optional file path to use as the canvas background image. JPEG/PNG/HEIC all
// supported. Center-cropped + scaled to output dims. If unset (or file missing),
// falls back to the procedural mesh gradient.
let backgroundImagePath = ProcessInfo.processInfo.environment["RECORDER_BG_IMAGE"]

/// An open-ended take (`durationS == 0`) runs until a signal, its parent's
/// death or this much free space left on the output volume; each one saves it.
let diskFloorBytes: Int64 = ProcessInfo.processInfo.environment["RECORDER_DISK_FLOOR_BYTES"].flatMap { Int64($0) } ?? 2_000_000_000

func freeBytes(onVolumeOf path: String) -> Int64? {
    var fs = statfs()
    guard statfs(path, &fs) == 0 else { return nil }
    return Int64(fs.f_bavail) * Int64(fs.f_bsize)
}

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
    writeLifecycle(Data("windowclip:\(event)\n".utf8))
}

func run() async throws {
    let setup: CaptureSetup
    if let synthetic = syntheticSize {
        switch captureTarget {
        case .window:
            setup = try await syntheticWindowSetup(width: synthetic?.width ?? 1600, height: synthetic?.height ?? 1000)
        case .display:
            setup = try syntheticDisplaySetup(width: synthetic?.width ?? 1920, height: synthetic?.height ?? 1080)
        }
    } else {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        switch captureTarget {
        case let .window(windowID):
            setup = try await windowCaptureSetup(windowID: windowID, content: content)
        case let .display(displayID):
            setup = try displayCaptureSetup(displayID: displayID, content: content)
        }
    }
    let pxW = setup.captureW
    let pxH = setup.captureH
    let outW = setup.outW
    let outH = setup.outH

    let recorder = try Recorder(outputURL: partialURL, outputW: outW, outputH: outH, bitrate: setup.bitrate, withAudio: captureAudio, composer: setup.composer)

    let videoQueue = DispatchQueue(label: "windowclip.recorder.video", qos: .userInteractive)
    let source = try setup.makeSource(recorder, videoQueue)

    var audioSession: AVCaptureSession? = nil
    if captureAudio {
        do { audioSession = try setupAudioCapture(recorder: recorder) }
        catch {
            writeDiagnostic(Data("recorder: audio setup failed, recording silently: \(error.localizedDescription)\n".utf8))
        }
    }

    // Stop trigger: either fixed duration elapses, signal fires (SIGTERM/SIGINT),
    // the parent dies, or the disk floor trips. Whichever happens first.
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
        writeDiagnostic(Data("recorder: stop requested (\(reason))\n".utf8))
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
            writeDiagnostic(Data("recorder: go (SIGUSR1)\n".utf8))
        }
    }
    sigusr1Source.resume()

    signal(SIGUSR2, SIG_IGN)
    let sigusr2Source = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .global())
    sigusr2Source.setEventHandler { signalStop("SIGUSR2") }
    sigusr2Source.resume()

    // The app or the CLI can die without stopping us (a crash, a SIGKILL, a
    // forced logout). Saving is the safe answer: the take is the user's.
    let parent = getppid()
    guard parent != 1 else {
        throw NSError(domain: "recorder", code: 6, userInfo: [NSLocalizedDescriptionKey: "started without a parent (ppid 1); refusing to record"])
    }
    let parentWatch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global())
    parentWatch.setEventHandler { signalStop("parent \(parent) exited") }
    parentWatch.resume()
    if getppid() != parent { signalStop("parent \(parent) exited") }

    // Duration is measured from the first frame actually written, NOT from
    // process start (DIG-807). Start-up here costs 0.6s on a warm machine and
    // was measured at 3.2s with a cold CoreAudio stack; charging that to the
    // recording silently shortened it, worst of all on the short clips where
    // the loss is proportionally largest.
    let durationLock = NSLock()
    var durationArmed = false
    let outputDirectory = URL(fileURLWithPath: outputPath).deletingLastPathComponent().path
    var diskWatch: DispatchSourceTimer?
    let armDuration: () -> Void = {
        durationLock.lock()
        if durationArmed { durationLock.unlock(); return }
        durationArmed = true
        let watch = DispatchSource.makeTimerSource(queue: .global())
        watch.schedule(deadline: .now(), repeating: 1.0)
        watch.setEventHandler {
            guard let free = freeBytes(onVolumeOf: outputDirectory), free < diskFloorBytes else { return }
            signalStop("free-disk floor: \(free / 1_000_000) MB left on the output volume, floor \(diskFloorBytes / 1_000_000) MB")
        }
        diskWatch = watch
        durationLock.unlock()
        watch.resume()
        if durationS > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + durationS) { signalStop("duration elapsed") }
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
    recorder.onWriterFailed = { signalStop("the writer could not start") }
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

    writeDiagnostic(Data("recorder: starting capture \(pxW)x\(pxH) → compose \(outW)x\(outH)\(probeSolidRed ? " [SOLID-RED PROBE]" : "")\(captureAudio ? " + mic" : " (no audio)") duration=\(durationS == 0 ? "open-ended" : "\(durationS)s")\n".utf8))
    audioSession?.startRunning()
    try await source.start()

    writeDiagnostic(Data("recorder: ready\n".utf8))

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
    parentWatch.cancel()
    durationLock.withLock { diskWatch }?.cancel()

    writeDiagnostic(Data("recorder: stopping stream...\n".utf8))
    try await source.stop()
    audioSession?.stopRunning()

    if stopLock.withLock({ discard }) {
        discardTake(recorder: recorder, partial: partialURL, output: outputPath)
    }
    try await finishTake(recorder: recorder, partial: partialURL, output: outputPath)
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
        removePartialFile(at: partialURL)
        writeDiagnostic(Data("recorder error: \(error)\n".utf8))
        exit(1)
    }
}
RunLoop.main.run()
