import Foundation

// Which folders, socket and log each copy of the app resolves to, and the
// control socket's refusal to take over one that answers.
//   main report            print this process's identity and paths (run inside bundles)
//   main suite <scratch>   the checks

func note(_ m: String) {}

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String) {
    print("\(ok ? "PASS" : "FAIL")  \(label) — \(detail)")
    if !ok { failures += 1 }
}

let support = URL(fileURLWithPath: "/Users/x/Library/Application Support")
let library = URL(fileURLWithPath: "/Users/x/Library")

func paths(_ id: AppIdentity) -> [String] {
    [AppSupport.directory(for: id, in: support).path, AppSupport.logsDirectory(for: id, in: library).path]
}

/// True when `path` is `root` or lies inside it, by path components.
func within(_ path: String, _ root: String) -> Bool {
    let p = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    let r = URL(fileURLWithPath: root).standardizedFileURL.pathComponents
    return p.count >= r.count && Array(p.prefix(r.count)) == r
}

func mapping() {
    let prodPaths = paths(.prod)
    check("prod bundle id → prod", AppIdentity.resolve(bundleId: AppIdentity.prod.bundleId) == .prod, AppIdentity.prod.bundleId)
    check("prod paths are the installed app's", prodPaths == [
        "/Users/x/Library/Application Support/\(AppIdentity.prod.name)", "/Users/x/Library/Logs/\(AppIdentity.prod.name)",
    ], prodPaths.joined(separator: ", "))
    let others: [String?] = [
        nil, "", AppIdentity.dev.bundleId, "com.example.other", AppIdentity.prod.bundleId.uppercased(),
        AppIdentity.prod.bundleId + " ", AppIdentity.prod.bundleId + ".probe",
    ]
    for id in others {
        let resolved = AppIdentity.resolve(bundleId: id)
        let reaches = paths(resolved).filter { p in prodPaths.contains { within(p, $0) } }
        check("bundle id \(id.map { "\"\($0)\"" } ?? "none") → dev, clear of prod paths",
              resolved == .dev && reaches.isEmpty, "\(resolved.kind) \(paths(resolved).joined(separator: ", "))")
    }
    check("dev and prod differ in every name", AppIdentity.dev.bundleId != AppIdentity.prod.bundleId
          && AppIdentity.dev.name != AppIdentity.prod.name && AppIdentity.dev.slug != AppIdentity.prod.slug
          && AppIdentity.dev.executable != AppIdentity.prod.executable, "\(AppIdentity.dev)")
    check("only prod grabs keys or the mic; only dev answers dev commands",
          AppIdentity.prod.registersHotkeys && AppIdentity.prod.recordsMicrophone && !AppIdentity.prod.answersDevCommands
          && !AppIdentity.dev.registersHotkeys && !AppIdentity.dev.recordsMicrophone && AppIdentity.dev.answersDevCommands, "")
}

@MainActor func socketRefusal(_ scratch: String) {
    AppSupport.rootOverride = URL(fileURLWithPath: "\(scratch)/support")
    Log.directory = URL(fileURLWithPath: "\(scratch)/logs")
    let path = ControlServer.socketURL.path

    let first = ControlServer()
    do { try first.start() } catch { check("first instance listens", false, "\(error)"); return }
    check("first instance listens", ControlServer.probe(path) == .answers, path)

    let second = ControlServer()
    var refused: Error?
    do { try second.start() } catch { refused = error }
    let reason = (refused as? ControlServer.ControlError).map { "\($0.errorDescription ?? "")" } ?? "started"
    check("second instance refuses a socket that answers", refused.map { "\($0)".contains("inUse") } ?? false, reason)
    check("first instance still answers", ControlServer.probe(path) == .answers, "\(ControlServer.probe(path))")
    first.stop()

    // A dead instance's socket: bound, then closed without unlinking.
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr.sun_path) { raw in
        raw.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strncpy($0, path, 103) }
    }
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    close(fd)
    check("a dead socket reads stale", bound == 0 && ControlServer.probe(path) == .stale, "\(ControlServer.probe(path))")
    let third = ControlServer()
    do {
        try third.start()
        check("a stale socket is taken over", ControlServer.probe(path) == .answers, path)
    } catch { check("a stale socket is taken over", false, "\(error)") }
    third.stop()
}

switch CommandLine.arguments.dropFirst().first {
case "report":
    print("bundle=\(Bundle.main.bundleIdentifier ?? "none")")
    print("kind=\(AppIdentity.current.kind.rawValue)")
    print("support=\(AppSupport.directory.path)")
    print("logs=\(AppSupport.logsDirectory.path)")
    print("log=\(Log.fileURL.path)")
    MainActor.assumeIsolated { print("socket=\(ControlServer.socketURL.path)") }
case "suite":
    mapping()
    MainActor.assumeIsolated { socketRefusal(CommandLine.arguments[2]) }
    exit(failures == 0 ? 0 : 1)
default:
    exit(64)
}
