import Foundation

// The dev socket commands drive the same entry points as ⌥⌘R and the picker,
// and only the dev identity answers them.
@MainActor func devCommandCases(_ s: SessionController, _ w: CapturableWindow) {
    var replies: [[String: Any]] = []
    func send(_ command: String, _ body: [String: Any] = [:], as identity: AppIdentity) -> Bool {
        var full = body; full["command"] = command
        return DevCommands.handle(ControlRequest(command: command, body: full), session: s, identity: identity,
                                  window: { $0 == w.id ? w : nil }, respond: { replies.append($0) })
    }
    let before = Recorder.prepares.count

    let prodToggle = send("toggle", as: .prod)
    let prodPick = send("pick", ["windowId": Int(w.id)], as: .prod)
    check("prod identity ignores toggle and pick", !prodToggle && !prodPick && s.phase == .idle && replies.isEmpty,
          "handled=\(prodToggle)/\(prodPick) phase=\(s.describe(s.phase)) replies=\(replies.count)")

    let earlyPick = send("pick", ["windowId": Int(w.id)], as: .dev)
    check("dev pick outside the picker is refused", earlyPick && (replies.last?["error"] as? String) == "not_picking"
          && s.phase == .idle, "\(replies.last ?? [:])")

    _ = send("toggle", as: .dev)
    check("dev toggle opens the picker", s.phase == .picking, "phase=\(s.describe(s.phase))")
    _ = send("pick", ["windowId": 9999], as: .dev)
    check("dev pick of a missing window", (replies.last?["error"] as? String) == "window_not_found" && s.phase == .picking,
          "\(replies.last ?? [:])")
    _ = send("pick", ["windowId": Int(w.id)], as: .dev)
    check("dev pick starts the countdown", s.phase == .countdown, "phase=\(s.describe(s.phase))")
    pump(3.4)
    _ = send("toggle", as: .dev)
    pump(4.7)
    let take = Recorder.prepares.dropFirst(before).last
    check("dev-driven take is a plain hotkey take", Recorder.prepares.count == before + 1
          && take?.output == Recorder.defaultPath && take?.background == "/bg/1B.png",
          "output=\(take?.output ?? "-") bg=\(take?.background ?? "-")")
}
