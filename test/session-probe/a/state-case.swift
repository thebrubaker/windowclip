import Foundation

// state.json is rewritten at every phase change and says what the next take
// will do, through the same resolver the take uses.
@MainActor func stateFileCases(_ s: SessionController, _ w: CapturableWindow, scratch: String) {
    let url = URL(fileURLWithPath: "\(scratch)/state.json")
    func read() -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    func session(_ body: [String: Any]) -> [String: Any] { body["session"] as? [String: Any] ?? [:] }

    s.stateFile = StateFile(url: url, app: { ["identity": "probe"] })
    let idle = read()
    check("state.json at publish", (session(idle)["phase"] as? String) == "idle"
          && (idle["pid"] as? Int) == Int(ProcessInfo.processInfo.processIdentifier) && (idle["identity"] as? String) == "probe",
          "phase=\(session(idle)["phase"] ?? "-") pid=\(idle["pid"] ?? "-")")
    let next = session(idle)["next"] as? [String: Any] ?? [:]
    check("idle state predicts the next take", (next["output"] as? String) == Recorder.defaultPath
          && (next["outputFrom"] as? String) == "default" && (next["backgroundFrom"] as? String) == "saved"
          && session(idle)["request"] == nil, "\(next)")

    var seen: [(phase: String, file: [String: Any])] = []
    s.onPhaseChange = { phase in seen.append((s.describe(phase), session(read()))) }
    let agentOut = URL(fileURLWithPath: "\(scratch)/agent-state.mp4")
    FileManager.default.createFile(atPath: agentOut.path, contents: Data("agent".utf8))
    let agentBG = Background(id: "Runtime/2D-bonsai-terrace-sun.png", url: URL(fileURLWithPath: "/bg/2D.png"))
    startWindowTake(s, w, source: .agent(label: "Claude"), output: agentOut, background: agentBG) { _ in }
    pump(3.4); s.requestStop { _ in }; pump(4.7)
    s.onPhaseChange = nil

    let phases = seen.map(\.phase)
    check("state.json follows every transition", phases == ["countdown", "recording", "saved", "idle"]
          && seen.allSatisfy { ($0.file["phase"] as? String) == $0.phase }, "\(seen.map { "\($0.phase)=\($0.file["phase"] ?? "-")" })")
    let recording = seen.first { $0.phase == "recording" }?.file["request"] as? [String: Any] ?? [:]
    check("recording state carries the request and its origins", (recording["output"] as? String) == agentOut.path
          && (recording["outputFrom"] as? String) == "request" && (recording["backgroundFrom"] as? String) == "request"
          && (recording["source"] as? String) == "agent" && (recording["windowId"] as? Int) == Int(w.id), "\(recording)")
    let recordingNext = seen.first { $0.phase == "recording" }?.file["next"] as? [String: Any] ?? [:]
    check("next take during an agent take is a plain one", (recordingNext["outputFrom"] as? String) == "default"
          && (recordingNext["backgroundFrom"] as? String) == "saved", "\(recordingNext)")
    let after = session(read())
    check("idle after the take: no request left", (after["phase"] as? String) == "idle" && after["request"] == nil
          && ((after["next"] as? [String: Any])?["outputFrom"] as? String) == "default", "\(after)")
    let take = Recorder.prepares.last!
    check("the take used the plan it published", take.output == agentOut.path && take.background == "/bg/2D.png", "\(take)")
    s.stateFile = nil
}
