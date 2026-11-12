// RecentRecordings — the app's memory of where recordings landed (DIG-795).
//
// A recording is announced once, by a pill that fades in four seconds. After
// that the file is findable only by whoever remembers the `--output` they
// passed. This is the app remembering for them: the last five saves, newest
// first, hanging off the status item.
//
// Recorded at save-time by SessionController, because every session — hotkey,
// CLI, agent — funnels through the same app. There is no second place a
// recording can come from, so there is no second place this has to be wired.
//
// Persisted as JSON next to the control socket rather than in UserDefaults:
// the file is the verification surface (you can cat it after a relaunch and
// see exactly what the menu will show), and cfprefsd's write coalescing makes
// "is it on disk yet?" an unanswerable question in a test.

import Foundation

@MainActor
final class RecentRecordings {
    static let shared = RecentRecordings()

    struct Entry: Equatable {
        var url: URL
        var savedAt: Date
    }

    /// Five is the feature. This is a five-line menu, not a library — no paging,
    /// no settings, nothing to grow into.
    private let limit = 5
    private let storeURL: URL

    private(set) var entries: [Entry] = []

    init(storeURL: URL = RecentRecordings.defaultStoreURL) {
        self.storeURL = storeURL
        self.entries = Self.load(from: storeURL)
    }

    /// `~/Library/Application Support/Windowclip/recents.json`.
    ///
    /// The 2026-07-30 rename moved this out of `.../Stage Studio/`, and the old
    /// list is deliberately NOT migrated. It is five file paths for one installed
    /// user, and the rename exists precisely so the app can be met fresh — a
    /// first run that opens with someone else's recents is the wrong first run.
    /// The stale directory is harmless; delete it by hand if it bothers you.
    nonisolated static var defaultStoreURL: URL {
        AppSupport.directory.appendingPathComponent("recents.json")
    }

    /// Called when a recording has actually been written. Cancelled sessions
    /// never reach here — nothing was saved, so there is nothing to reveal.
    func record(_ url: URL, at date: Date = Date()) {
        let path = url.standardizedFileURL
        // Re-recording over the same path moves it back to the top rather than
        // filling the menu with five copies of one filename.
        entries.removeAll { $0.url.standardizedFileURL == path }
        entries.insert(Entry(url: path, savedAt: date), at: 0)
        if entries.count > limit { entries.removeSubrange(limit...) }
        save()
    }

    /// Middle truncation, not tail: recordings are named `<slug>-<timestamp>.mp4`
    /// and the timestamp is the part that tells two takes apart. Cutting the tail
    /// would leave five menu items that all read the same.
    static func displayName(for url: URL, limit: Int = 34) -> String {
        let name = url.lastPathComponent
        guard name.count > limit, limit > 12 else { return name }
        let head = 10
        let tail = limit - head - 1
        return name.prefix(head) + "…" + name.suffix(tail)
    }

    // MARK: - Persistence

    private struct Stored: Codable {
        var path: String
        var savedAt: Double
    }

    private func save() {
        let stored = entries.map { Stored(path: $0.url.path, savedAt: $0.savedAt.timeIntervalSince1970) }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(stored)
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // History is a convenience; losing it must never take a recording
            // down with it. Say so and carry on.
            note("could not write recents: \(error.localizedDescription)")
        }
    }

    private static func load(from url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let stored = try? JSONDecoder().decode([Stored].self, from: data) else {
            note("recents store is unreadable — starting empty")
            return []
        }
        return stored.map {
            Entry(url: URL(fileURLWithPath: $0.path), savedAt: Date(timeIntervalSince1970: $0.savedAt))
        }
    }
}
