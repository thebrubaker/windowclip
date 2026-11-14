import AppKit
import Foundation

func note(_ m: String) { Probe.notes.append(m) }

enum Probe {
    nonisolated(unsafe) static var notes: [String] = []
}

struct Background: Equatable {
    let id: String
    let url: URL
    var isDefault: Bool { id == "default" }
}

@MainActor final class Backgrounds {
    static let shared = Backgrounds()
    var current: Background? = Background(id: "Onlook/1B-eclipse-over-dunes.png", url: URL(fileURLWithPath: "/bg/1B.png"))
}

@MainActor final class RecentRecordings {
    static let shared = RecentRecordings()
    var saved: [String] = []
    func record(_ url: URL) { saved.append(url.path) }
}

@MainActor final class HotkeyManager {
    static let shared = HotkeyManager()
    enum Binding { case toggle, escape }
    @discardableResult func register(_ b: Binding, action: @escaping () -> Void) -> Bool { true }
    func unregister(_ b: Binding) {}
}

enum PillState {
    case countdown(remaining: Int, appName: String)
    case recording(elapsed: TimeInterval)
    case saved(url: URL, duration: TimeInterval)
}

@MainActor final class PillController {
    var onStop: () -> Void = {}
    var onReveal: (URL) -> Void = { _ in }
    var onHoverChanged: (Bool) -> Void = { _ in }
    var source: SessionSource = .human
    var showsEscapeHint = true
    var shownSources: [String] = []
    var shownEscapeHints: [Bool] = []
    func show(_ s: PillState) {
        shownSources.append(source.isAgent ? "agent(\(source.label ?? ""))" : "human")
        shownEscapeHints.append(showsEscapeHint)
    }
    func update(_ s: PillState) {}
    func hide() {}
    func fadeOut(duration: TimeInterval = 0.5, completion: @escaping () -> Void = {}) { completion() }
    func cancelFade() {}
}

@MainActor func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

@MainActor func picker(of s: SessionController) -> PickerController {
    Mirror(reflecting: s).children.first { $0.label == "picker" }!.value as! PickerController
}

/// A hotkey take: ⌥⌘R, pick, countdown, record, ⌥⌘R, saved pill fades.
@MainActor func hotkeyTake(_ s: SessionController, _ w: CapturableWindow) {
    s.toggle(); pick(s, w); pump(3.4); s.toggle(); pump(4.7)
}

func check(_ label: String, _ ok: Bool, _ detail: String) {
    print("\(ok ? "PASS" : "FAIL")  \(label) — \(detail)")
    if !ok { Probe.failures += 1 }
}

extension Probe { nonisolated(unsafe) static var failures = 0 }
