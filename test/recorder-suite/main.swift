import AVFoundation
import Foundation

// Drives the real recorder binary on synthetic frames (RECORDER_SOURCE).
//   recorder-suite <recorder binary> <scratch dir>
// Compiled with the tree's cmd/recorder/Sizing.swift for the size math checks.

let recorderPath = CommandLine.arguments[1]
let scratch = CommandLine.arguments[2]
let fm = FileManager.default

var failures = 0
var expectedFailures = 0
var unexpectedPasses = 0

func check(_ name: String, _ ok: Bool, _ detail: String) {
    print("  \(ok ? "PASS" : "FAIL")  \(name): \(detail)")
    if !ok { failures += 1 }
}

/// A case that is known to fail until a later stage fixes it. It still runs, so
/// the fix shows up as XPASS and the mark has to be removed.
func knownFailure(_ name: String, until: String, _ ok: Bool, _ detail: String) {
    if ok {
        print("  XPASS \(name): \(detail) (marked failing until \(until); remove the mark)")
        unexpectedPasses += 1
    } else {
        print("  XFAIL \(name): \(detail) (known, until \(until))")
        expectedFailures += 1
    }
}

final class Take {
    let process = Process()
    let dir: String
    let output: String
    private let lock = NSLock()
    private var out = ""
    private var err = ""

    let viaParent: Bool

    init(_ name: String, target: String = "1", duration: Double, source: String = "synthetic",
         handshake: Bool = false, existing: Data? = nil, output: String? = nil, env extra: [String: String] = [:],
         viaParent: Bool = false) throws {
        dir = "\(scratch)/\(name)"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.output = output ?? "\(dir)/take.mp4"
        self.viaParent = viaParent
        if let existing { fm.createFile(atPath: self.output, contents: existing) }
        if viaParent {
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            // The recorder writes into a FIFO that only `cat` reads, as it writes
            // into pipes that only the app reads; killing both leaves it no reader.
            let fifo = "\(dir)/output.fifo"
            mkfifo(fifo, 0o600)
            process.arguments = ["-c", "cat \"$1\" >/dev/null & r=$!; \"$0\" \"${@:2}\" >\"$1\" 2>&1 & echo child:$! reader:$r; wait",
                                 recorderPath, fifo, target, String(duration), self.output]
        } else {
            process.executableURL = URL(fileURLWithPath: recorderPath)
            process.arguments = [target, String(duration), self.output]
        }
        var env = ProcessInfo.processInfo.environment
        env["RECORDER_NO_AUDIO"] = "1"
        env["RECORDER_SOURCE"] = source
        env["RECORDER_HANDSHAKE"] = handshake ? "1" : nil
        env["RECORDER_BG_IMAGE"] = nil
        env["RECORDER_DISK_FLOOR_BYTES"] = nil
        env.merge(extra) { $1 }
        process.environment = env
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            self?.lock.withLock { self?.out += s }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            self?.lock.withLock { self?.err += s }
        }
        try process.run()
    }

    var stdout: String { lock.withLock { out } }
    var stderr: String { lock.withLock { err } }
    /// The recorder's pid, whichever process started it.
    var pid: pid_t {
        guard viaParent else { return process.processIdentifier }
        let line = stdout.split(whereSeparator: { $0 == "\n" || $0 == " " }).first { $0.hasPrefix("child:") }
        return line.flatMap { pid_t($0.dropFirst("child:".count)) } ?? -1
    }
    var parentPID: pid_t { process.processIdentifier }
    var readerPID: pid_t {
        let field = stdout.split(whereSeparator: { $0 == "\n" || $0 == " " }).first { $0.hasPrefix("reader:") }
        return field.flatMap { pid_t($0.dropFirst("reader:".count)) } ?? -1
    }

    /// For a recorder that is no longer our child: wait for it to be gone.
    func waitGone(timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        kill(pid, SIGKILL)
        return false
    }
    var partial: String { "\(dir)/.take.partial-\(pid).mp4" }

    func waitForLine(_ line: String, timeout: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if stdout.split(separator: "\n").contains(Substring(line)) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    func signal(_ sig: Int32) { kill(pid, sig) }

    /// Exit status, or a signal as 128+n; nil if it had to be killed.
    func finish(timeout: Double) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            kill(pid, SIGKILL)
            process.waitUntilExit()
            return nil
        }
        Thread.sleep(forTimeInterval: 0.05)
        return process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
    }

    func leftovers() -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.contains("partial") }
    }
}

func describe(_ status: Int32?) -> String { status.map { "exit \($0)" } ?? "hung, killed" }

/// Seconds of video in the file, from the track's own time range.
func videoDuration(_ path: String) -> Double? {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let sem = DispatchSemaphore(value: 0)
    var seconds: Double?
    Task {
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let range = try? await track.load(.timeRange) {
            seconds = range.duration.seconds
        }
        sem.signal()
    }
    sem.wait()
    return seconds
}

/// The synthetic frame number in the file's first frame. Display takes only:
/// their frames reach the file unscaled, so the barcode sits where it was drawn.
func firstFrameIndex(_ path: String) -> Int? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let sem = DispatchSemaphore(value: 0)
    var image: CGImage?
    generator.generateCGImageAsynchronously(for: .zero) { img, _, _ in image = img; sem.signal() }
    sem.wait()
    guard let image else { return nil }
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let block = 32
    var n = 0
    for bit in 0..<16 {
        let x = block * 2 + bit * block + block / 2
        let y = block + block / 2
        let i = (y * w + x) * 4
        n = n << 1 | (Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) > 3 * 128 ? 1 : 0)
    }
    return n
}

// A/A on the m3, 15 synthetic 2 s takes (window, display, gated): 2.032-2.063 s,
// 61 frames in 14, 62 in one. Never short of the request; at most two frames over.
func durationOK(_ d: Double) -> Bool { d >= 2.0 && d <= 2.0 + 2.0 / 30 + 0.005 }

func sizeMath() {
    print("size math")
    let any: (Int, Int) -> Bool = { _, _ in true }
    // stella's Intel encoder (grid, 2026-11-13): hardware up to 4096x2320, not 2304x4096.
    let stella: (Int, Int) -> Bool = { w, h in w <= 4096 && h <= 2320 }
    let cases: [((Int, Int), String, (Int, Int) -> Bool, (Int, Int))] = [
        ((1920, 1080), "any", any, (1920, 1080)),
        ((3024, 1964), "any", any, (3024, 1964)),
        ((3840, 2160), "any", any, (3840, 2160)),
        ((5120, 2880), "any", any, (4096, 2304)),
        ((6016, 3384), "any", any, (4096, 2304)),
        ((7680, 2160), "any", any, (4096, 1152)),
        ((2160, 3840), "any", any, (2160, 3840)),
        ((1001, 601), "any", any, (1000, 600)),
        ((5120, 2880), "stella", stella, (4096, 2304)),
        ((2160, 3840), "stella", stella, (1214, 2160)),
        ((5120, 2880), "none", { _, _ in false }, (3840, 2160)),
    ]
    for (input, encoder, accepts, want) in cases {
        let got = displayOutputSize(pixelWidth: input.0, pixelHeight: input.1, hardwareAccepts: accepts)
        check("display \(input.0)x\(input.1) on \(encoder) encoder", got == want, "\(got.width)x\(got.height), want \(want.0)x\(want.1)")
    }
    check("display bitrate is capped", displayBitrate(width: 4096, height: 2304) == DISPLAY_MAX_BITRATE,
          "\(displayBitrate(width: 4096, height: 2304))")
    check("1080p display bitrate matches window", displayBitrate(width: 1920, height: 1080) == WINDOW_BITRATE,
          "\(displayBitrate(width: 1920, height: 1080))")
}

func partialRenamed() throws {
    print("window take: partial, then renamed")
    let t = try Take("renamed", duration: 2)
    Thread.sleep(forTimeInterval: 1.2)
    let midPartial = fm.fileExists(atPath: t.partial), midOutput = fm.fileExists(atPath: t.output)
    check("writes to the partial while recording", midPartial && !midOutput,
          "partial \(midPartial ? "present" : "missing"), output \(midOutput ? "present" : "absent")")
    let status = t.finish(timeout: 15)
    check("exits 0", status == 0, describe(status))
    let d = videoDuration(t.output)
    check("partial renamed", d != nil && t.leftovers().isEmpty,
          "output \(d.map { String(format: "%.3f s of video", $0) } ?? "missing or unreadable"), leftovers \(t.leftovers())")
}

func replacesExisting() throws {
    print("window take over an existing file")
    let t = try Take("replace", duration: 1, existing: Data("old take".utf8))
    let status = t.finish(timeout: 15)
    let d = videoDuration(t.output)
    check("a finished take replaces the file", status == 0 && d != nil && t.stderr.contains("replaced the file already there"),
          "\(describe(status)), output \(d.map { String(format: "%.3f s", $0) } ?? "not a video")")
}

func discardLeavesExisting() throws {
    print("discard (SIGUSR2)")
    let sentinel = Data("Joel's earlier take".utf8)
    let t = try Take("discard", duration: 0, existing: sentinel)
    Thread.sleep(forTimeInterval: 1.0)
    let hadPartial = fm.fileExists(atPath: t.partial)
    t.signal(SIGUSR2)
    let status = t.finish(timeout: 15)
    check("discard exits 2", status == 2, describe(status))
    check("discard leaves the existing file alone", fm.contents(atPath: t.output) == sentinel,
          fm.contents(atPath: t.output) == sentinel ? "unchanged" : "CHANGED or deleted")
    check("discard removes its partial", hadPartial && t.leftovers().isEmpty,
          "partial was \(hadPartial ? "there" : "never there"), leftovers \(t.leftovers())")
}

func fixedDuration() throws {
    print("fixed duration, display take")
    let t = try Take("duration", target: "display:main", duration: 2, source: "synthetic:1280x720")
    let status = t.finish(timeout: 15)
    let d = videoDuration(t.output) ?? -1
    check("exits 0", status == 0, describe(status))
    check("2 s take measures 2 s", durationOK(d),
          String(format: "%.3f s (band 2.000-2.072)", d))
    let first = firstFrameIndex(t.output)
    check("ungated take starts at the first frame", first.map { $0 <= 2 } ?? false, "first frame #\(first.map(String.init) ?? "?")")
}

func handshakeAndGate() throws {
    print("handshake and gate")
    let t = try Take("gate", target: "display:main", duration: 2, source: "synthetic:1280x720", handshake: true)
    let armed = t.waitForLine("windowclip:armed", timeout: 10)
    check("reports armed", armed, armed ? "windowclip:armed" : "no armed line: \(t.stdout)")
    Thread.sleep(forTimeInterval: 1.0)
    check("holds the take until go", !t.stdout.contains("windowclip:capturing") && !fm.fileExists(atPath: t.partial),
          t.stdout.contains("windowclip:capturing") ? "capturing before go" : "nothing written yet")
    t.signal(SIGUSR1)
    let capturing = t.waitForLine("windowclip:capturing", timeout: 5)
    check("reports capturing after go", capturing, capturing ? "windowclip:capturing" : "no capturing line")
    let status = t.finish(timeout: 15)
    let d = videoDuration(t.output) ?? -1
    check("gated take exits 0 and measures 2 s", status == 0 && durationOK(d),
          String(format: "%@, %.3f s", describe(status), d))
    let first = firstFrameIndex(t.output)
    check("warm-up frames stay out of the file", first.map { $0 >= 25 } ?? false,
          "first frame #\(first.map(String.init) ?? "?") (1 s of warm-up at 30 fps is #30)")
}

func stopBeforeFirstFrame() throws {
    print("stop before the first frame")
    let t = try Take("early-stop", target: "display:main", duration: 0, source: "synthetic:1280x720", handshake: true)
    _ = t.waitForLine("windowclip:armed", timeout: 10)
    t.signal(SIGTERM)
    let status = t.finish(timeout: 15)
    check("stop before go exits 3 and leaves nothing", status == 3 && t.leftovers().isEmpty && !fm.fileExists(atPath: t.output),
          "\(describe(status)), leftovers \(t.leftovers()), output \(fm.fileExists(atPath: t.output) ? "present" : "absent")")
}

func parentDies() throws {
    print("parent killed")
    let t = try Take("orphan", duration: 0, viaParent: true)
    Thread.sleep(forTimeInterval: 1.5)
    let pid = t.pid
    let reader = t.readerPID
    if reader > 0 { kill(reader, SIGKILL) }
    Thread.sleep(forTimeInterval: 0.2)
    kill(t.parentPID, SIGKILL)
    t.process.waitUntilExit()
    let gone = pid > 0 && reader > 0 && t.waitGone(timeout: 15)
    let d = videoDuration(t.output)
    check("parent SIGKILL: the recorder finalizes and saves", gone && d != nil && t.leftovers().isEmpty,
          "recorder \(pid) \(gone ? "exited" : "still running, killed"), its output reader \(reader > 0 ? "killed" : "MISSING"), output \(d.map { String(format: "%.3f s", $0) } ?? "missing"), leftovers \(t.leftovers())")
}

func diskFloor() throws {
    print("free-disk floor")
    let t = try Take("disk-floor", duration: 0, env: ["RECORDER_DISK_FLOOR_BYTES": "1000000000000000000"])
    let status = t.finish(timeout: 15)
    let d = videoDuration(t.output)
    check("disk floor trips: the take finalizes and saves", status == 0 && d != nil && t.stderr.contains("free-disk floor"),
          "\(describe(status)), output \(d.map { String(format: "%.3f s", $0) } ?? "missing")")
}

func writerFailure() throws {
    print("writer cannot start")
    let dir = "\(scratch)/writer-fails/read-only"
    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    chmod(dir, 0o555)
    defer { chmod(dir, 0o755) }
    let t = try Take("writer-fails", duration: 0, output: "\(dir)/take.mp4")
    let status = t.finish(timeout: 15)
    let lines = t.stderr.components(separatedBy: "startWriting failed").count - 1
    check("a writer that cannot start stops once, with a message", status == 1 && lines == 1,
          "\(describe(status)), \(lines) startWriting line(s), last: \(t.stderr.split(separator: "\n").last ?? "-")")
}

sizeMath()
for test in [partialRenamed, replacesExisting, discardLeavesExisting, fixedDuration, handshakeAndGate, stopBeforeFirstFrame,
             parentDies, diskFloor, writerFailure] {
    do { try test() } catch { check("case ran", false, "\(error)") }
}
print("recorder suite: \(failures) failing, \(expectedFailures) known failing, \(unexpectedPasses) unexpectedly passing")
exit(failures == 0 && unexpectedPasses == 0 ? 0 : 1)
