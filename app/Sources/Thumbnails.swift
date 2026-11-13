// Thumbnails — live window snapshots for the picker, via ScreenCaptureKit.
//
// THIS IS THE FIRST SCK CALL IN THE APP, which means it is where macOS asks for
// the Screen Recording grant. Until a human clicks Allow, `SCShareableContent`
// throws and every thumbnail comes back nil — the picker still works, it just
// shows icon placeholders. That degradation is deliberate: a permission the user
// hasn't granted yet should not take the whole surface down.

import AppKit
import CoreGraphics
import ScreenCaptureKit

@MainActor
final class ThumbnailProvider {
    /// Longest edge of a captured thumbnail, in pixels. The picker's cells are
    /// ~175pt wide, so 400px covers 2x with room to spare.
    private static let maxEdge: CGFloat = 400

    private var cache: [CGWindowID: CGImage] = [:]
    private var shareable: SCShareableContent?

    /// Set when SCK refused — the caller surfaces it once rather than per window.
    private(set) var lastError: String?
    var isDenied: Bool { lastError != nil }

    /// Refresh the shared window list. Separated from `thumbnail(for:)` so the
    /// permission failure surfaces once, up front, instead of N times.
    func prepare() async {
        do {
            shareable = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
            lastError = nil
        } catch {
            shareable = nil
            lastError = error.localizedDescription
        }
    }

    func cached(_ id: CGWindowID) -> CGImage? { cache[id] }

    func thumbnail(for display: CapturableDisplay) async -> CGImage? {
        guard let shareable,
              let target = shareable.displays.first(where: { $0.displayID == display.id })
        else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let filter = SCContentFilter(
            display: target,
            excludingApplications: shareable.applications.filter { $0.processID == ownPID },
            exceptingWindows: []
        )
        let config = SCStreamConfiguration()
        let w = max(CGFloat(target.width), 1)
        let h = max(CGFloat(target.height), 1)
        let scale = Self.maxEdge / max(w, h)
        config.width = max(Int((w * scale).rounded()), 1)
        config.height = max(Int((h * scale).rounded()), 1)
        config.showsCursor = false
        config.captureResolution = .best

        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func thumbnail(for window: CapturableWindow) async -> CGImage? {
        if let hit = cache[window.id] { return hit }
        guard let shareable else { return nil }
        guard let target = shareable.windows.first(where: { $0.windowID == window.id }) else {
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        let w = max(target.frame.width, 1)
        let h = max(target.frame.height, 1)
        let scale = Self.maxEdge / max(w, h)
        config.width = max(Int((w * scale).rounded()), 1)
        config.height = max(Int((h * scale).rounded()), 1)
        config.showsCursor = false
        config.captureResolution = .best

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
            cache[window.id] = image
            return image
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
}
