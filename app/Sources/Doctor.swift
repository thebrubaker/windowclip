import CryptoKit
import Foundation

/// `--doctor`: what this copy is and what its next take will do, read from its
/// own files. Runs before `NSApplication` and writes nothing: no log line, no
/// socket, no defaults. Prints one JSON object.
enum Doctor {
    struct Paths {
        var support: URL
        var logs: URL
        var bundle: URL

        static func current(root: URL?) -> Paths {
            Paths(support: root ?? AppSupport.directory,
                  logs: root?.appendingPathComponent("Logs", isDirectory: true) ?? AppSupport.logsDirectory,
                  bundle: Bundle.main.bundleURL)
        }
    }

    static func run(root: URL?) -> Int32 {
        let report = Self.report(identity: .current, paths: .current(root: root))
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return 1
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return 0
    }

    static func report(identity: AppIdentity, paths: Paths) -> [String: Any] {
        let logFile = paths.logs.appendingPathComponent("\(identity.slug).log")
        var out: [String: Any] = [
            "doctor": 1,
            "identity": identity.kind.rawValue,
            "bundleId": identity.bundleId,
            "support": paths.support.path,
            "log": logFile.path,
        ]
        let tail = logTail(logFile, lines: 10)
        out["logTail"] = tail.lines
        if let last = tail.lastTake { out["lastTake"] = last }

        let state = readState(paths.support.appendingPathComponent("state.json"), executable: identity.executable)
        out["state"] = state.summary
        if let live = state.live {
            let session = live["session"] as? [String: Any] ?? [:]
            out["mode"] = "live"
            out["predicted"] = false
            out["phase"] = session["phase"] ?? "?"
            out["take"] = session["take"] ?? 0
            if let request = session["request"] { out["request"] = request }
            out["next"] = session["next"] ?? [:]
            for key in ["pid", "version", "build", "executable", "permissions", "hotkey", "socket"] {
                if let v = live[key] { out[key] = v }
            }
        } else {
            out["mode"] = "files"
            out["predicted"] = true
            out["phase"] = tail.lastPhase ?? "not running"
            out["next"] = predictNext(support: paths.support)
        }
        out["recents"] = recents(paths.support.appendingPathComponent("recents.json"))
        out["background"] = json(paths.support.appendingPathComponent("background.json")) ?? NSNull()
        out["recorder"] = recorder(paths.bundle.appendingPathComponent("Contents/MacOS/recorder"))
        out["tcc"] = tcc(identity.bundleId)
        out["summary"] = summary(out)
        return out
    }

    // MARK: - state.json

    struct StateRead {
        var live: [String: Any]?
        var summary: [String: Any]
    }

    static func readState(_ url: URL, executable: String) -> StateRead {
        guard let body = json(url) as? [String: Any] else {
            return StateRead(summary: ["file": url.path, "found": FileManager.default.fileExists(atPath: url.path)])
        }
        var summary: [String: Any] = ["file": url.path, "found": true, "written": body["written"] ?? "?"]
        guard let pid = body["pid"] as? Int else {
            summary["stale"] = true; summary["reason"] = "no pid"
            return StateRead(summary: summary)
        }
        let name = processName(pid_t(pid))
        if name == nil {
            summary["stale"] = true; summary["reason"] = "pid \(pid) is not running"
        } else if name != executable {
            summary["stale"] = true; summary["reason"] = "pid \(pid) is \(name!), not \(executable)"
        } else {
            summary["stale"] = false
            return StateRead(live: body, summary: summary)
        }
        return StateRead(summary: summary)
    }

    static func processName(_ pid: pid_t) -> String? {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return nil }
        var buffer = [CChar](repeating: 0, count: 1024)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Files

    static func json(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// The last lines, and the last `take N: X → Y` anywhere in the file.
    static func logTail(_ url: URL, lines: Int) -> (lines: [String], lastTake: String?, lastPhase: String?) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ([], nil, nil) }
        let all = text.split(separator: "\n").map(String.init)
        let take = all.last { $0.contains("[session] take ") && $0.contains(" → ") }
        let phase = take.flatMap { $0.components(separatedBy: " → ").last }
        return (Array(all.suffix(lines)), take, phase)
    }

    static func recents(_ url: URL) -> [String: Any] {
        let entries = json(url) as? [[String: Any]] ?? []
        var out: [String: Any] = ["count": entries.count]
        if let path = entries.first?["path"] as? String {
            out["newest"] = path
            out["newestExists"] = FileManager.default.fileExists(atPath: path)
        }
        return out
    }

    /// What a plain take would resolve to with no app to ask: the Desktop
    /// default and the saved background, as `TakePlan.resolve` would.
    static func predictNext(support: URL) -> [String: Any] {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? "~/Desktop"
        var next: [String: Any] = ["output": "\(desktop)/recording-<time>.mp4", "outputFrom": "default"]
        let selected = (json(support.appendingPathComponent("background.json")) as? [String: Any])?["selected"] as? String
        if let selected, FileManager.default.fileExists(atPath: support.appendingPathComponent("Backgrounds/\(selected)").path) {
            next["background"] = selected; next["backgroundFrom"] = "saved"
        } else {
            next["background"] = "default"; next["backgroundFrom"] = "default"
            if let selected { next["note"] = "saved choice \(selected) is missing from Backgrounds" }
        }
        return next
    }

    // MARK: - The bundled recorder

    static func recorder(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return ["path": url.path, "found": false] }
        var out: [String: Any] = ["path": url.path, "found": true]
        out["slices"] = MachO.slices(data).map { ["arch": $0.arch, "minos": $0.minos ?? "none"] }
        out["sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let sign = run("/usr/bin/codesign", ["-dv", url.path])
        out["team"] = sign.err.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) } ?? "unsigned or unreadable"
        return out
    }

    static func tcc(_ bundleId: String) -> Any {
        let db = "/Library/Application Support/com.apple.TCC/TCC.db"
        let query = "select service, auth_value from access where client = '\(bundleId)'"
        let result = run("/usr/bin/sqlite3", ["-readonly", "-separator", "=", db, query])
        guard result.status == 0 else { return "unreadable (needs Full Disk Access)" }
        return result.out.split(separator: "\n").map(String.init)
    }

    static func run(_ tool: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        guard (try? p.run()) != nil else { return (-1, "", "") }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    static func summary(_ r: [String: Any]) -> String {
        let next = r["next"] as? [String: Any] ?? [:]
        let mode = (r["predicted"] as? Bool) == true ? "predicted from files" : "from the running app"
        let stale = ((r["state"] as? [String: Any])?["reason"] as? String).map { "; stale state.json: \($0)" } ?? ""
        return "\(r["identity"] ?? "?") is \(r["phase"] ?? "?"); next take → \(next["output"] ?? "?") (from: \(next["outputFrom"] ?? "?")), "
            + "background \(next["background"] ?? "?") (from: \(next["backgroundFrom"] ?? "?")); \(mode)\(stale)"
    }
}

/// Arch and LC_BUILD_VERSION minos of each slice, read from the file itself
/// so the check needs no developer tools on the machine.
enum MachO {
    struct Slice { var arch: String; var minos: String? }

    static func slices(_ d: Data) -> [Slice] {
        func be32(_ o: Int) -> UInt32 { d.count >= o + 4 ? d[d.startIndex + o..<d.startIndex + o + 4].reduce(0) { $0 << 8 | UInt32($1) } : 0 }
        switch be32(0) {
        case 0xcafe_babe, 0xcafe_babf:
            let wide = be32(0) == 0xcafe_babf
            return (0..<Int(be32(4))).compactMap { i in
                let entry = 8 + i * (wide ? 32 : 20)
                let offset = wide ? Int(be32(entry + 12)) : Int(be32(entry + 8))
                return thin(d, at: offset)
            }
        default:
            return thin(d, at: 0).map { [$0] } ?? []
        }
    }

    private static func thin(_ d: Data, at base: Int) -> Slice? {
        func le32(_ o: Int) -> UInt32 {
            let s = d.startIndex + base + o
            guard d.count >= base + o + 4 else { return 0 }
            return d[s..<s + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }
        guard le32(0) == 0xfeed_facf else { return nil }
        let arch: String
        switch le32(4) {
        case 0x0100_000c: arch = "arm64"
        case 0x0100_0007: arch = "x86_64"
        case let other: arch = String(format: "cpu 0x%x", other)
        }
        var offset = 32
        var minos: String?
        for _ in 0..<Int(le32(16)) {
            let cmd = le32(offset), size = Int(le32(offset + 4))
            if cmd == 0x32 {
                let v = le32(offset + 12)
                minos = "\(v >> 16).\((v >> 8) & 0xff)" + ((v & 0xff) > 0 ? ".\(v & 0xff)" : "")
            }
            guard size > 0 else { break }
            offset += size
        }
        return Slice(arch: arch, minos: minos)
    }
}
