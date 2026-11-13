// PillController — owns the floating pill panel: a borderless, non-activating
// NSPanel pinned bottom-center that must (a) float above everything, (b) survive
// space switches, and (c) never take key focus away from the app being recorded.

import AppKit
import SwiftUI

/// Borderless panel that never becomes key. Focus staying with the recorded app
/// is a hard requirement — the pill is chrome, not an app you interact with by
/// tabbing to it. Clicks still land (Stop button) because AppKit routes mouse
/// events to non-key windows of a non-activating panel.
final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The pill window is inflated by `Theme.pillShadowMargin` on every side so the
/// SwiftUI drop shadow has room to draw. That margin must not eat clicks meant
/// for whatever is behind the pill, so hits outside the capsule fall through.
final class PillContainerView: NSView {
    var interactiveInset: CGFloat = Theme.pillShadowMargin

    override func hitTest(_ point: NSPoint) -> NSView? {
        let inner = bounds.insetBy(dx: interactiveInset, dy: interactiveInset)
        guard inner.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}

@MainActor
final class PillController {
    private var panel: PillPanel?
    private var hosting: NSHostingView<PillView>?

    private let showMidline: Bool
    private let freezeAnimation: Bool
    private let forceHover: Bool
    var onStop: () -> Void = {}
    var onReveal: (URL) -> Void = { _ in }
    var onHoverChanged: (Bool) -> Void = { _ in }

    /// Set before `show` — decides whether the pill wears its agent treatment.
    var source: SessionSource = .human
    var showsEscapeHint = true

    /// Invalidates in-flight fades. Without it, a fade that gets cancelled
    /// mid-flight still runs its completion handler and hides the pill.
    private var fadeToken = 0

    private(set) var state: PillState = .countdown(remaining: 3, appName: "")

    init(showMidline: Bool = false, freezeAnimation: Bool = false, forceHover: Bool = false) {
        self.showMidline = showMidline
        self.freezeAnimation = freezeAnimation
        self.forceHover = forceHover
    }

    /// CGWindowID of the live pill panel — printed in debug mode so a screenshot
    /// can target the real rendered window (`screencapture -l <id>`).
    var windowID: CGWindowID? {
        guard let panel, panel.windowNumber > 0 else { return nil }
        return CGWindowID(panel.windowNumber)
    }

    /// `x,y,w,h` in top-left screen coordinates — feeds `screencapture -R`, which
    /// (unlike `-l`) captures the pill over the real desktop instead of over
    /// transparency. Needed to judge the pill in the context it actually lives in.
    var captureRegion: String? {
        guard let panel, let primary = NSScreen.screens.first else { return nil }
        let f = panel.frame
        let top = primary.frame.maxY - f.maxY
        return "\(Int(f.minX)),\(Int(top)),\(Int(f.width)),\(Int(f.height))"
    }

    func show(_ newState: PillState) {
        state = newState
        let panel = panel ?? makePanel()
        hosting?.rootView = rootView()
        layout(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func update(_ newState: PillState) {
        guard panel != nil else { return show(newState) }
        state = newState
        hosting?.rootView = rootView()
        if let panel { layout(panel) }
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.alphaValue = 1
    }

    /// The "Saved ✓" flash doesn't blink out — it fades, so the end of a session
    /// reads as a settling rather than a disappearance.
    func fadeOut(duration: TimeInterval = 0.5, completion: @escaping () -> Void = {}) {
        guard let panel, panel.isVisible else { return completion() }
        fadeToken += 1
        let token = fadeToken
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, token == self.fadeToken else { return }
                self.hide()
                completion()
            }
        }
    }

    /// Catch a fade that has already started — the user reached for the pill just
    /// as it began to go. Snaps back to full opacity and voids the pending hide.
    func cancelFade() {
        guard let panel, panel.isVisible else { return }
        fadeToken += 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
    }

    // MARK: - Internals

    private func rootView() -> PillView {
        PillView(
            state: state,
            source: source,
            showsEscapeHint: showsEscapeHint,
            showMidline: showMidline,
            freezeAnimation: freezeAnimation,
            forceHover: forceHover,
            onStop: { [weak self] in self?.onStop() },
            onReveal: { [weak self] url in self?.onReveal(url) },
            onHoverChanged: { [weak self] hovering in self?.onHoverChanged(hovering) }
        )
    }

    private func makePanel() -> PillPanel {
        let panel = PillPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 90),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // We draw our own shadow inside the window so it can be tuned; the system
        // window shadow would trace the full (inflated) window rect.
        panel.hasShadow = false
        // Above full-screen apps and the menu bar — this is session chrome.
        panel.level = .screenSaver
        panel.collectionBehavior = [
            .canJoinAllSpaces,      // survives space switches
            .stationary,            // doesn't slide in Mission Control
            .fullScreenAuxiliary,   // shows over full-screen apps
            .ignoresCycle,          // not in cmd-` rotation
        ]
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none

        let container = PillContainerView()
        let hostingView = NSHostingView(rootView: rootView())
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        panel.contentView = container

        self.hosting = hostingView
        self.panel = panel
        return panel
    }

    /// Size to the SwiftUI content and pin bottom-center, `pillBottomFraction` of
    /// the visible frame above the bottom (mockup's `bottom-[4%]`). The visible
    /// frame excludes the Dock, so the pill never lands under it.
    private func layout(_ panel: PillPanel) {
        guard let hosting else { return }
        // The pill changes width between states (a filename is longer than an
        // elapsed clock). fittingSize is stale until SwiftUI has laid the new
        // content out, so force the pass before trusting it.
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }

        let pillBottom = visible.minY + visible.height * Theme.pillBottomFraction
        let origin = NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            // The window bottom sits a shadow-margin below the capsule bottom.
            y: (pillBottom - Theme.pillShadowMargin).rounded()
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        hosting.frame = panel.contentView?.bounds ?? NSRect(origin: .zero, size: size)
    }
}
