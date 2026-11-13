// PickerController — owns the picker panel: enumerate windows, show the panel,
// stream thumbnails in as ScreenCaptureKit returns them, and handle keyboard nav.
//
// Unlike the pill, this panel DOES take key focus — it's a modal moment the user
// summoned, and arrow keys have to land somewhere. Focus returns to the target
// app as soon as the picker closes.

import AppKit
import SwiftUI

final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PickerController {
    private var panel: PickerPanel?
    private var hosting: NSHostingView<PickerView>?
    private var keyMonitor: Any?
    private var thumbnailTask: Task<Void, Never>?

    private let model = PickerModel()
    private let thumbnails = ThumbnailProvider()

    /// Called with the chosen window or display. The picker closes itself first.
    var onPick: (CaptureTarget) -> Void = { _ in }
    /// Called when the user dismissed without choosing.
    var onCancel: () -> Void = {}

    var isVisible: Bool { panel?.isVisible ?? false }

    var windowID: CGWindowID? {
        guard let panel, panel.windowNumber > 0 else { return nil }
        return CGWindowID(panel.windowNumber)
    }

    /// `x,y,w,h` in top-left screen coordinates, for `screencapture -R`.
    var captureRegion: String? {
        guard let panel, let primary = NSScreen.screens.first else { return nil }
        let f = panel.frame
        return "\(Int(f.minX)),\(Int(primary.frame.maxY - f.maxY)),\(Int(f.width)),\(Int(f.height))"
    }

    // MARK: - Lifecycle

    func show(selectingScreens: Bool = false) {
        model.displays = DisplayEnumerator.list()
        model.windows = WindowEnumerator.list()
        model.selected = selectingScreens || model.windows.isEmpty ? 0 : model.displays.count
        model.notice = model.windows.isEmpty ? "No recordable windows on screen" : nil

        let panel = panel ?? makePanel()
        layout(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        startThumbnails()
    }

    func selectScreens() {
        model.selected = 0
    }

    func close(cancelled: Bool) {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        removeKeyMonitor()
        panel?.orderOut(nil)
        // Hand focus back to whatever the user was actually using.
        NSApp.hide(nil)
        if cancelled { onCancel() }
    }

    // MARK: - Thumbnails

    private func startThumbnails() {
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            guard let self else { return }
            await thumbnails.prepare()
            if let error = thumbnails.lastError {
                // Tripwire surface: this is what a missing Screen Recording grant
                // looks like from inside the app.
                note("ScreenCaptureKit refused: \(error)")
                model.notice = "Screen Recording permission needed for previews"
                return
            }
            for display in model.displays {
                if Task.isCancelled { return }
                if let image = await thumbnails.thumbnail(for: display) {
                    model.displayThumbnails[display.id] = image
                }
            }
            for window in model.windows {
                if Task.isCancelled { return }
                if let image = await thumbnails.thumbnail(for: window) {
                    model.thumbnails[window.id] = image
                }
            }
        }
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) ? nil : event }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the key was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        guard isVisible else { return false }
        let count = model.items.count
        guard count > 0 else {
            if event.keyCode == 53 { close(cancelled: true); return true }
            return false
        }

        switch event.keyCode {
        case 123: move(by: -1)                          // ←
        case 124: move(by: 1)                           // →
        case 126: moveRow(by: -1)                       // ↑
        case 125: moveRow(by: 1)                        // ↓
        case 36, 76:                                    // return / enter
            let picked = model.items[model.selected]
            close(cancelled: false)
            onPick(picked)
        case 53:                                        // esc
            close(cancelled: true)
        default:
            return false
        }
        return true
    }

    /// Clamps rather than wraps. Wrapping in a ragged grid makes ↓ on the last
    /// row jump somewhere the user didn't point at.
    private func move(by delta: Int) {
        let count = model.items.count
        guard count > 0 else { return }
        model.selected = min(max(model.selected + delta, 0), count - 1)
    }

    private func moveRow(by delta: Int) {
        let rows = model.rows
        guard let row = rows.firstIndex(where: { $0.contains(model.selected) }),
              let column = rows[row].firstIndex(of: model.selected)
        else { return }
        let next = row + delta
        if next < 0 { model.selected = 0; return }
        if next >= rows.count { model.selected = model.items.count - 1; return }
        model.selected = rows[next][min(column, rows[next].count - 1)]
    }

    // MARK: - Panel

    private func makePanel() -> PickerPanel {
        let panel = PickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: Theme.pickerWidth, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none

        let hostingView = NSHostingView(rootView: makeRootView())
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        self.hosting = hostingView
        self.panel = panel
        return panel
    }

    private func makeRootView() -> PickerView {
        PickerView(
            model: model,
            onPick: { [weak self] target in
                self?.close(cancelled: false)
                self?.onPick(target)
            },
            onClose: { [weak self] in self?.close(cancelled: true) }
        )
    }

    private func layout(_ panel: PickerPanel) {
        guard let hosting else { return }
        hosting.rootView = makeRootView()
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.midY - size.height / 2).rounded()
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        hosting.frame = NSRect(origin: .zero, size: size)
    }
}
