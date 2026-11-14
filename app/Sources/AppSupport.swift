import Foundation

/// The app's per-user folders, named by its identity: the socket, the recents,
/// the saved backgrounds and the log move together.
enum AppSupport {
    static var identity: AppIdentity { .current }

    /// Tests point this at a scratch folder. Deliberately not read from the
    /// environment, so nothing outside the process can aim it at another copy.
    nonisolated(unsafe) static var rootOverride: URL?

    static var directory: URL {
        rootOverride ?? directory(for: identity, in: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    }

    static var logsDirectory: URL {
        rootOverride?.appendingPathComponent("Logs", isDirectory: true)
            ?? logsDirectory(for: identity, in: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0])
    }

    static var logFileStem: String { identity.slug }

    static func directory(for identity: AppIdentity, in applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(identity.name, isDirectory: true)
    }

    static func logsDirectory(for identity: AppIdentity, in library: URL) -> URL {
        library.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(identity.name, isDirectory: true)
    }
}
