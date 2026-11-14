import AppKit

// Trees whose session records a window or a whole display (DIG-804).
struct CapturableWindow: Equatable { let id: CGWindowID; let app: String }

@MainActor final class PickerController {
    var onPick: (CaptureTarget) -> Void = { _ in }
    var onCancel: () -> Void = {}
    func show(selectingScreens: Bool = false) {}
    func selectScreens() {}
    func close(cancelled: Bool) {}
}

@MainActor func pick(_ s: SessionController, _ w: CapturableWindow) { picker(of: s).onPick(.window(w)) }

@MainActor func startWindowTake(
    _ s: SessionController, _ w: CapturableWindow, source: SessionSource, output: URL?,
    background: Background? = nil, completion: @escaping (SessionResult) -> Void
) {
    s.start(target: .window(w), source: source, output: output, background: background, completion: completion)
}
