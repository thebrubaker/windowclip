import AppKit

/// Probe A's recorder: no process, no files. Records what the session asked for.
@MainActor final class Recorder {
    static var prepares: [(output: String, background: String)] = []
    var onExit: (Int32) -> Void = { _ in }
    var onArmed: () -> Void = {}
    private(set) var outputURL: URL?
    private(set) var isArmed = false
    private(set) var isRunning = false
    var elapsed: TimeInterval { 3 }
    static var defaultPath = "/probe/Desktop/recording-DEFAULT.mp4"
    static func defaultOutputURL(now: Date = Date()) -> URL { URL(fileURLWithPath: defaultPath) }
    func prepare(windowID: CGWindowID, output: URL, background: URL?) throws {
        Recorder.prepares.append((output.path, background?.path ?? "<none>"))
        outputURL = output; isRunning = true; isArmed = true
    }
    func go() {}
    func stop() { isRunning = false; let cb = onExit; Task { @MainActor in cb(0) } }
    func cancel() { onExit = { _ in }; isRunning = false; outputURL = nil }
    static func measuredDuration(of url: URL) async -> TimeInterval? { 3 }
}
