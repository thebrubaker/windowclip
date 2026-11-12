import Foundation

/// The app's per-user folder. The only place its name is spelled, so a rename
/// moves the socket, the recents and the saved backgrounds together.
enum AppSupport {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Windowclip", isDirectory: true)
    }
}
