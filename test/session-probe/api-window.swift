import AppKit

// Trees whose session records windows only (3fe3170, be84e94).
struct CapturableWindow { let id: CGWindowID; let app: String }

@MainActor final class PickerController {
    var onPick: (CapturableWindow) -> Void = { _ in }
    var onCancel: () -> Void = {}
    func show() {}
    func close(cancelled: Bool) {}
}

@MainActor func pick(_ s: SessionController, _ w: CapturableWindow) { picker(of: s).onPick(w) }

@MainActor func startWindowTake(
    _ s: SessionController, _ w: CapturableWindow, source: SessionSource, output: URL?,
    background: Background? = nil, completion: @escaping (SessionResult) -> Void
) {
    s.start(window: w, source: source, output: output, background: background, completion: completion)
}

@MainActor func screenTakeThenHotkeyTake(_ s: SessionController, _ pill: PillController, _ w: CapturableWindow, scratch: String) {
    print("SKIP  screen take, then hotkey take — this tree has no screen target")
}
