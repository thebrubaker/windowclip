import Foundation

/// `state.json` in the app's own support folder: what this copy is and what
/// its next take will do. Written whole and atomically, so a reader never sees
/// half a file. `--doctor` and `windowclip doctor` read it.
@MainActor
final class StateFile {
    let url: URL
    /// What the app knows about itself: identity, binaries, permissions,
    /// hotkey and socket. Read at every publish.
    var app: () -> [String: Any]

    init(url: URL = StateFile.defaultURL, app: @escaping () -> [String: Any] = { [:] }) {
        self.url = url
        self.app = app
    }

    nonisolated static var defaultURL: URL { AppSupport.directory.appendingPathComponent("state.json") }

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func publish(_ session: [String: Any]) {
        var body = app()
        body["pid"] = Int(ProcessInfo.processInfo.processIdentifier)
        body["written"] = Self.stamp.string(from: Date())
        body["session"] = session
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
