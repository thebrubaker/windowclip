import Foundation
import os

/// `~/Library/Logs/Windowclip/windowclip.log`, rotated at `maxBytes` with
/// `keep` old files, and mirrored to the unified log under the bundle id.
enum Log {
    nonisolated(unsafe) static var directory = AppSupport.logsDirectory
    static var fileURL: URL { directory.appendingPathComponent("\(AppSupport.name.lowercased()).log") }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "io.digitalpine.windowclip"
    private static let queue = DispatchQueue(label: "windowclip.log")
    private static let maxBytes: UInt64 = 2_000_000
    private static let keep = 3
    nonisolated(unsafe) private static var handle: FileHandle?

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    static func write(_ category: String, _ message: String) {
        Logger(subsystem: subsystem, category: category).notice("\(message, privacy: .public)")
        let line = "\(stamp.string(from: Date())) [\(category)] \(message)\n"
        queue.async { append(line) }
    }

    /// Blocks until every line written so far is on disk.
    static func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    private static func append(_ line: String) {
        if handle == nil { handle = open() }
        guard let handle else { return }
        handle.write(Data(line.utf8))
        if (try? handle.offset()) ?? 0 >= maxBytes { rotate() }
    }

    private static func open() -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
        return handle
    }

    private static func rotated(_ n: Int) -> URL {
        directory.appendingPathComponent("\(AppSupport.name.lowercased()).\(n).log")
    }

    private static func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: rotated(keep))
        for n in stride(from: keep - 1, through: 1, by: -1) where fm.fileExists(atPath: rotated(n).path) {
            try? fm.moveItem(at: rotated(n), to: rotated(n + 1))
        }
        try? fm.moveItem(at: fileURL, to: rotated(1))
    }
}
