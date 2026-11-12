// ControlServer — the app's external control surface (DIG-793).
//
// A Unix domain socket carrying one JSON request per connection, one JSON
// response back, then close.
//
// Why a socket and not the obvious alternatives:
//   - URL scheme (windowclip://…) is one-way. The caller needs to learn
//     "started" vs "user cancelled" vs "busy", and a URL can't tell it.
//   - Localhost HTTP would work, but binding a TCP port can raise the macOS
//     firewall prompt — and this app's whole permission story is "no new
//     prompts, ever". A socket file adds no permission surface at all.
//   - Apple Events would add an Automation grant. Same objection.
//
// The socket lives under Application Support, so it's per-user and doesn't
// collide with anything in /tmp.

import Foundation

struct ControlRequest {
    let command: String
    let body: [String: Any]

    func string(_ key: String) -> String? { body[key] as? String }
    func int(_ key: String) -> Int? {
        if let i = body[key] as? Int { return i }
        if let d = body[key] as? Double { return Int(d) }
        if let s = body[key] as? String { return Int(s) }
        return nil
    }
}

@MainActor
final class ControlServer {
    /// Called on the main actor for each request. Respond whenever the answer is
    /// actually known — a `start` holds its connection open through the whole
    /// countdown so the caller learns whether the user let it through.
    var handler: ((ControlRequest, @escaping ([String: Any]) -> Void) -> Void)?

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    static var socketURL: URL {
        AppSupport.directory.appendingPathComponent("control.sock")
    }

    func start() throws {
        let url = Self.socketURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let path = url.path
        // sockaddr_un.sun_path is a fixed 104-byte buffer — a long path would be
        // silently truncated into a socket nobody can find.
        guard path.utf8.count < 104 else {
            throw ControlError.pathTooLong(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.posix("socket", errno) }

        // A crashed or SIGKILLed app leaves the socket file behind; bind would
        // fail with EADDRINUSE forever. Clearing it is safe because only one
        // instance is meant to be listening.
        unlink(path)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                _ = strncpy(dest, path, 103)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bindResult == 0 else {
            close(fd)
            throw ControlError.posix("bind", errno)
        }
        guard listen(fd, 8) == 0 else {
            close(fd)
            throw ControlError.posix("listen", errno)
        }
        // Owner-only: this socket can start a screen recording.
        chmod(path, 0o600)

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.acceptOne() }
        }
        source.resume()
        acceptSource = source
        note("control socket listening at \(path)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(Self.socketURL.path)
    }

    // MARK: - Connection handling

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }

        // Read off the main thread; a caller that connects and stalls must not
        // freeze the UI.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let raw = Self.readRequest(client)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        close(client)
                        return
                    }
                    self.dispatch(raw: raw, client: client)
                }
            }
        }
    }

    private static func readRequest(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        // Requests are a single small JSON line. Stop at the newline so a caller
        // that holds the connection open doesn't block us waiting for EOF.
        while data.count < 64 * 1024 {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if data.last == UInt8(ascii: "\n") { break }
        }
        return data
    }

    private func dispatch(raw: Data, client: Int32) {
        var responded = false
        let respond: ([String: Any]) -> Void = { payload in
            // A handler that fires twice (e.g. a phase waiter plus a timeout)
            // would write into a closed fd. Only the first answer counts.
            guard !responded else { return }
            responded = true
            Self.write(payload, to: client)
            close(client)
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: raw),
            let body = object as? [String: Any],
            let command = body["command"] as? String
        else {
            respond(["ok": false, "error": "bad_request",
                     "message": "expected a JSON object with a \"command\" key"])
            return
        }

        guard let handler else {
            respond(["ok": false, "error": "unavailable", "message": "no handler installed"])
            return
        }
        handler(ControlRequest(command: command, body: body), respond)
    }

    private static func write(_ payload: [String: Any], to fd: Int32) {
        var data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data(#"{"ok":false,"error":"encode_failed"}"#.utf8)
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    enum ControlError: LocalizedError {
        case posix(String, Int32)
        case pathTooLong(String)

        var errorDescription: String? {
            switch self {
            case let .posix(call, code):
                return "\(call) failed: \(String(cString: strerror(code))) (\(code))"
            case let .pathTooLong(path):
                return "socket path too long for sockaddr_un: \(path)"
            }
        }
    }
}
