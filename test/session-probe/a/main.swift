import AppKit
import Foundation

// Probe A: does anything an agent request asked for reach the next hotkey take?
// Outputs point at files that exist: the session treats a missing file as a failed take.
@MainActor func probeA() {
    let scratch = CommandLine.arguments[1]
    configureLogging(scratch)
    let agentOut = URL(fileURLWithPath: "\(scratch)/agent.mp4")
    FileManager.default.createFile(atPath: agentOut.path, contents: Data("agent".utf8))
    Recorder.defaultPath = "\(scratch)/recording-DEFAULT.mp4"
    FileManager.default.createFile(atPath: Recorder.defaultPath, contents: Data("default".utf8))
    let pill = PillController()
    let s = SessionController(pill: pill)
    let w = CapturableWindow(id: 5583, app: "Onlook")
    let agentBG = Background(id: "Runtime/2D-bonsai-terrace-sun.png", url: URL(fileURLWithPath: "/bg/2D.png"))

    s.start(window: w, source: .agent(label: "Claude"), output: agentOut, background: agentBG) { _ in }
    pump(3.4); s.requestStop { _ in }; pump(4.7)
    let status = s.statusPayload()
    check("status after an agent take", (status["source"] as? String) == "human",
          "source=\(status["source"] ?? "-") background=\(status["background"] ?? "-")")

    hotkeyTake(s, w)
    let take = Recorder.prepares.last!
    check("hotkey take output", take.output == Recorder.defaultPath, take.output)
    check("hotkey take background", take.background == "/bg/1B.png", take.background)
    check("hotkey take pill source", pill.shownSources.last == "human", pill.shownSources.last ?? "-")

    hotkeyTake(s, w)
    check("second hotkey take output", Recorder.prepares.last!.output == Recorder.defaultPath, Recorder.prepares.last!.output)
    for (i, p) in Recorder.prepares.enumerated() { print("      prepare[\(i)] output=\(p.output) bg=\(p.background)") }
    dumpLog()
}

MainActor.assumeIsolated { probeA() }
print(Probe.failures == 0 ? "probe A: all pass" : "probe A: \(Probe.failures) failing")
exit(Probe.failures == 0 ? 0 : 1)
