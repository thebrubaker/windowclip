import AppKit
import Foundation

// Probe B: the real app Recorder.swift supervising a stand-in recorder binary
// (WINDOWCLIP_ROOT/cmd/recorder/recorder). Does any later action delete a saved take?
@MainActor func probeB() {
    let scratch = CommandLine.arguments[1]
    configureLogging(scratch)
    let fm = FileManager.default
    let w = CapturableWindow(id: 5583, app: "Onlook")
    let out = URL(fileURLWithPath: "\(scratch)/take.mp4")
    let s = SessionController(pill: PillController())

    startWindowTake(s, w, source: .agent(label: "Claude"), output: out) { _ in }
    pump(3.6); s.requestStop { _ in }; pump(1.0)
    let saved = (try? String(contentsOf: out, encoding: .utf8)) ?? "<missing>"
    check("a finished take is saved", saved.hasPrefix("take"), "take.mp4 = \(saved.trimmingCharacters(in: .newlines))")
    pump(4.0)

    startWindowTake(s, w, source: .agent(label: "Claude"), output: out) { _ in }
    pump(1.2); s.escape(); pump(0.8)
    check("Esc during the countdown keeps the saved take", fm.fileExists(atPath: out.path),
          fm.fileExists(atPath: out.path) ? "take.mp4 still there" : "take.mp4 DELETED")

    let keeper = URL(fileURLWithPath: "\(scratch)/keeper.mp4")
    startWindowTake(s, w, source: .agent(label: "Claude"), output: keeper) { _ in }
    pump(3.6); s.requestStop { _ in }; pump(5.0)
    let binary = "\(scratch)/root/cmd/recorder/recorder"
    try? fm.moveItem(atPath: binary, toPath: binary + ".hidden")
    startWindowTake(s, w, source: .agent(label: "Claude"), output: URL(fileURLWithPath: "\(scratch)/next.mp4")) { r in
        print("      start with the recorder missing -> \(r.error ?? "ok")")
    }
    pump(0.5)
    try? fm.moveItem(atPath: binary + ".hidden", toPath: binary)
    check("a failed start keeps the last saved take", fm.fileExists(atPath: keeper.path),
          fm.fileExists(atPath: keeper.path) ? "keeper.mp4 still there" : "keeper.mp4 DELETED")

    let leftovers = ((try? fm.contentsOfDirectory(atPath: scratch)) ?? []).filter { $0.contains("partial") }
    check("no partial files left behind", leftovers.isEmpty, leftovers.isEmpty ? "none" : leftovers.joined(separator: ", "))
    dumpLog()
}

MainActor.assumeIsolated { probeB() }
print(Probe.failures == 0 ? "probe B: all pass" : "probe B: \(Probe.failures) failing")
exit(Probe.failures == 0 ? 0 : 1)
