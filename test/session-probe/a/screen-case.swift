import AppKit

/// An agent records the screen to its own path; the next hotkey take must get
/// none of it: the default output, the saved background, a window, a human pill
/// with its Esc hint back.
@MainActor func screenTakeThenHotkeyTake(_ s: SessionController, _ pill: PillController, _ w: CapturableWindow, scratch: String) {
    let screenOut = URL(fileURLWithPath: "\(scratch)/agent-screen.mp4")
    FileManager.default.createFile(atPath: screenOut.path, contents: Data("screen".utf8))
    let display = CapturableDisplay(id: 1, name: "Probe Display", isMain: true, sizeInPoints: CGSize(width: 2560, height: 1440))
    s.start(target: .display(display), source: .agent(label: "Claude"), output: screenOut) { _ in }
    pump(3.4); s.requestStop { _ in }; pump(4.7)
    let screen = Recorder.prepares.last!
    check("agent screen take", Recorder.targets.last == "display:1" && screen.output == screenOut.path
            && screen.background == "<none>" && pill.shownEscapeHints.last == false,
          "target=\(Recorder.targets.last ?? "-") output=\(screen.output) bg=\(screen.background) escHint=\(pill.shownEscapeHints.last.map(String.init) ?? "-")")

    hotkeyTake(s, w)
    let take = Recorder.prepares.last!
    check("hotkey take after a screen take", Recorder.targets.last == "\(w.id)" && take.output == Recorder.defaultPath
            && take.background == "/bg/1B.png" && pill.shownSources.last == "human" && pill.shownEscapeHints.last == true,
          "target=\(Recorder.targets.last ?? "-") output=\(take.output) bg=\(take.background) pill=\(pill.shownSources.last ?? "-") escHint=\(pill.shownEscapeHints.last.map(String.init) ?? "-")")
}
