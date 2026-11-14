// Recorder — a thin supervisor for the EXISTING cmd/recorder binary.
//
// The recorder is not reimplemented here. This app is a second front door onto
// the same proven pipeline the Claude/CLI flow uses, and it speaks the same
// contract src/cli.ts does:
//
//   recorder <windowID | display:<id>> <durationSeconds> <outputPath>
//   env RECORDER_BG_IMAGE=<path to background>
//   env RECORDER_EXCLUDE_PID=<this app's pid>, so the pill stays out of a
//       screen recording
//   duration 0 = open-ended, stop with SIGTERM
//   exit 0 saved, 1 failed, 2 discarded (SIGUSR2), 3 stopped before its first
//       frame; if this app dies mid-take, the recorder saves the take itself

import AppKit
import AVFoundation
import Foundation

@MainActor
final class Recorder {
    enum StartError: LocalizedError {
        case binaryMissing(String)

        var errorDescription: String? {
            switch self {
            case let .binaryMissing(path):
                return "recorder binary missing at \(path) — run `pnpm run build:recorder`"
            }
        }
    }

    private var process: Process?
    private(set) var outputURL: URL?
    private(set) var startedAt: Date?

    /// Called on the main actor when the recorder exits, with its status code.
    var onExit: (Int32) -> Void = { _ in }
    /// Called on the main actor once capture is proven live and frames are
    /// arriving — the moment it becomes honest to start the user's clock.
    var onArmed: () -> Void = {}

    /// True once the recorder has reported a real frame. Until then a `go()`
    /// would start a clock the capture cannot yet honour.
    private(set) var isArmed = false

    var isRunning: Bool { process?.isRunning ?? false }
    /// Time since the take began — NOT since the process was spawned. Start-up
    /// happens before `go()` and must not count against the recording (DIG-807).
    var elapsed: TimeInterval { startedAt.map { -$0.timeIntervalSinceNow } ?? 0 }

    // MARK: - Repo layout

    /// Only meaningful for dev builds run from inside the checkout. An installed
    /// app in /Applications has no repo, which is exactly why the bundled copies
    /// below are consulted first.
    static var repoRoot: URL {
        if let override = ProcessInfo.processInfo.environment["WINDOWCLIP_ROOT"] {
            return URL(fileURLWithPath: override)
        }
        return Bundle.main.bundleURL
            .deletingLastPathComponent()  // build/
            .deletingLastPathComponent()  // app/
            .deletingLastPathComponent()  // <repo>
    }

    /// Bundled copy first, checkout second.
    ///
    /// The app's permanent home is /Applications, so it cannot depend on a
    /// checkout that may be moved or deleted — `build.sh` embeds the recorder in
    /// `Contents/MacOS/`. The repo fallback keeps a dev build working when the
    /// helper hasn't been built into the bundle yet.
    static var binaryURL: URL {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/recorder")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return repoRoot.appendingPathComponent("cmd/recorder/recorder")
    }

    /// Same default background the CLI uses, so both front doors produce clips
    /// that look like they came from the same tool.
    static var defaultBackgroundURL: URL? {
        let fm = FileManager.default
        if let bundled = Bundle.main.url(forResource: "big-sur-graphic", withExtension: "jpg"),
           fm.fileExists(atPath: bundled.path) {
            return bundled
        }
        let url = repoRoot.appendingPathComponent("assets/big-sur-graphic.jpg")
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    static func defaultOutputURL(now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        let stem = "recording-\(formatter.string(from: now))"
        var candidate = desktop.appendingPathComponent("\(stem).mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = desktop.appendingPathComponent("\(stem)-\(n).mp4")
            n += 1
        }
        return candidate
    }

    // MARK: - Lifecycle

    /// Spawn the recorder and let it warm up, WITHOUT beginning the take.
    ///
    /// Start-up is not free and not constant: measured at ~0.6s warm and 3.2s
    /// with a cold CoreAudio stack (the audio device alone blocked 2.25s on the
    /// session behind DIG-807). Spawning here — during the countdown — means
    /// that cost is paid inside a wait the user is already having, and `go()`
    /// can begin capture on a pipeline that is already hot.
    func prepare(target: CaptureTarget, output: URL, background: URL?) throws {
        let binary = Self.binaryURL
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw StartError.binaryMissing(binary.path)
        }

        let task = Process()
        task.executableURL = binary
        // duration 0 = open-ended; we own the stop.
        task.arguments = [target.recorderArgument, "0", output.path]

        var env = ProcessInfo.processInfo.environment
        env["RECORDER_BG_IMAGE"] = background?.path ?? ""
        env["RECORDER_EXCLUDE_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        // Hold the take until SIGUSR1, and report lifecycle on stdout.
        env["RECORDER_HANDSHAKE"] = "1"
        task.environment = env

        let lifecycle = Pipe()
        task.standardOutput = lifecycle
        let diagnostics = Pipe()
        task.standardError = diagnostics

        task.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            lifecycle.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.process = nil
                self.onExit(status)
            }
        }

        try task.run()
        process = task
        outputURL = output
        // Deliberately nil: the clock starts at `go()`, not here.
        startedAt = nil
        isArmed = false
        readLifecycle(from: lifecycle)
        forwardDiagnostics(from: diagnostics, pid: task.processIdentifier)
        note("recorder warming (pid \(task.processIdentifier)) → \(output.path)")
    }

    /// Begin the take. This is t=0 for the recording, for the pill, and for
    /// whoever is counting down to the stop.
    func go() {
        guard let process, process.isRunning else { return }
        startedAt = Date()
        kill(process.processIdentifier, SIGUSR1)
        note("go → recorder \(process.processIdentifier)")
    }

    /// One line per lifecycle event on the recorder's stdout. Read rather than
    /// polled, so the app learns "armed" the instant it is true.
    private func readLifecycle(from pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        handle.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            if chunk.isEmpty {
                fh.readabilityHandler = nil
                return
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard line.hasPrefix("windowclip:") else { continue }
                let event = String(line.dropFirst("windowclip:".count))
                Task { @MainActor [weak self] in self?.handleLifecycle(event) }
            }
        }
    }

    private func forwardDiagnostics(from pipe: Pipe, pid: Int32) {
        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty {
                fh.readabilityHandler = nil
                if !buffer.isEmpty { Log.write("recorder", "[\(pid)] \(String(decoding: buffer, as: UTF8.self))") }
                try? fh.close()
                return
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                Log.write("recorder", "[\(pid)] \(line)")
            }
        }
    }

    private func handleLifecycle(_ event: String) {
        switch event {
        case "armed":
            guard !isArmed else { return }
            isArmed = true
            note("recorder armed — capture live, holding for go")
            onArmed()
        case "capturing":
            note("recorder capturing")
        default:
            break
        }
    }

    /// The recording's length as the FILE reports it.
    ///
    /// The app used to report its own process lifetime, which is exactly why a
    /// session that captured 1.8 seconds of a requested 5 still printed
    /// "(5.2s)": the number was structurally incapable of contradicting the
    /// bug. Measuring the artifact is what makes a regression here visible.
    static func measuredDuration(of url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        do {
            let seconds = CMTimeGetSeconds(try await asset.load(.duration))
            return (seconds.isFinite && seconds > 0) ? seconds : nil
        } catch {
            return nil
        }
    }

    /// Clean finalize — the same SIGTERM path the Claude flow uses.
    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    /// For app termination: finalize the take and wait for it, so quitting saves
    /// rather than discards. Nil if the recorder was still finishing at the
    /// deadline; it then saves on its own once this app is gone.
    func finishBeforeExit(timeout: TimeInterval) -> Int32? {
        onExit = { _ in }
        onArmed = {}
        guard let process, process.isRunning else { return nil }
        process.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        return process.isRunning ? nil : process.terminationStatus
    }

    static func describeExit(_ status: Int32) -> String {
        switch status {
        case 0: return "saved (exit 0)"
        case 1: return "failed (exit 1), see the recorder lines above"
        case 2: return "discarded (exit 2)"
        case 3: return "stopped before its first frame (exit 3), nothing written"
        default: return "exited \(status)"
        }
    }

    /// Abort the take. SIGUSR2 tells the recorder to discard its own partial
    /// file; the app never deletes anything at `outputURL`, which may hold a
    /// finished recording from an earlier session.
    func cancel() {
        onExit = { _ in }
        onArmed = {}
        isArmed = false
        if let process, process.isRunning {
            kill(process.processIdentifier, SIGUSR2)
            process.waitUntilExit()
            note("cancelled recorder \(process.processIdentifier) — take discarded")
        }
        self.process = nil
        outputURL = nil
        startedAt = nil
    }
}
