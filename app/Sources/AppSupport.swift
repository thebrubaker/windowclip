import Foundation

/// The app's per-user folders. The only place its name is spelled, so a rename
/// moves the socket, the recents, the saved backgrounds and the log together.
enum AppSupport {
    static let name = "Windowclip"

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
    }

    static var logsDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }
}
