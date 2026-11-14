// Permissions — the only place in the app that asks macOS about TCC.
//
// The setup window renders states; this decides what state we are actually in and
// performs the one action that state allows. Kept separate because the mapping
// from "what macOS reports" to "what the user should do" is the whole substance of
// the feature, and it is not obvious:
//
//   * Screen Recording has no API that distinguishes "never asked" from "denied".
//     `CGPreflightScreenCaptureAccess()` returns one Bool. So denial is inferred
//     from the fact that we already asked and still don't have it, which is
//     persisted — because after a denial macOS never prompts this app again, and an
//     `Allow…` button that silently does nothing is precisely the failure the
//     denied state exists to prevent.
//
//   * A Screen Recording grant does not apply to the process that was already
//     running when it arrived. So "granted" is only true if it was granted at
//     LAUNCH; a grant that appeared mid-session is `needsRelaunch`.
//
//   * Microphone is the easy one: AVFoundation reports all four states directly
//     and a grant applies immediately.
//
// Nothing here can revoke anything. There is no `tccutil` and no reset path: the
// only writes are macOS's own consent prompts, and requesting a permission that is
// already granted is a no-op.

import AVFoundation
import AppKit
import CoreGraphics

@MainActor
enum Permissions {
    // MARK: - Launch snapshot

    /// Whether Screen Recording was already granted when this process started.
    ///
    /// Read once, deliberately: it is the difference between `granted` and
    /// `needsRelaunch`, and if it were read lazily the answer would change the
    /// moment the user granted the permission — collapsing the relaunch state and
    /// leaving the user with a window that says "Allowed" over an app that still
    /// cannot capture anything.
    private(set) static var screenGrantedAtLaunch = false
    private static var didSnapshot = false

    /// Call once, early in `applicationDidFinishLaunching`. This is a read; it
    /// raises no prompt and changes no grant.
    static func snapshotLaunchState() {
        guard !didSnapshot else { return }
        didSnapshot = true
        screenGrantedAtLaunch = CGPreflightScreenCaptureAccess()
        note("launch snapshot: screen recording granted=\(screenGrantedAtLaunch)")
    }

    // MARK: - Debug injection

    /// Debug-only overrides of what the reads report.
    ///
    /// They live HERE, at the source of truth, rather than being poured into the
    /// window's model — because the launch gate, the status-menu entry and the poll
    /// all ask this type, and a fixture that only fools the view can't exercise any
    /// of them. Overriding here means a forced state drives the whole real path.
    ///
    /// Only the `--debug-screen` / `--debug-mic` flags ever write these; normal
    /// operation leaves them nil and can't reach them. This is the reason no
    /// `tccutil reset` is needed to see an ungranted state.
    private static var injectedScreen: PermissionStatus?
    private static var injectedMicrophone: PermissionStatus?

    static func inject(screen: PermissionStatus?, microphone: PermissionStatus?) {
        injectedScreen = screen
        injectedMicrophone = microphone
        note("injected: screen=\(screen?.rawValue ?? "live"), mic=\(microphone?.rawValue ?? "live")")
    }

    /// Drop back to reality. `--debug-live` calls this once the window is up, so a
    /// forced starting state can be *corrected* by the poll — which is the only way
    /// to prove the poll runs at all on a machine that already holds every grant.
    static func clearInjections() {
        guard injectedScreen != nil || injectedMicrophone != nil else { return }
        injectedScreen = nil
        injectedMicrophone = nil
        note("injections cleared — reads are live from here")
    }

    // MARK: - Status

    static func status(of kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .screenRecording: return screenRecording
        case .microphone: return microphone
        }
    }

    /// The launch gate's whole question. Reads only — it cannot raise a prompt, so
    /// asking it on every launch costs a correctly-configured user nothing.
    static var allGranted: Bool {
        screenRecording == .granted && microphone == .granted
    }

    static var screenRecording: PermissionStatus {
        if let injectedScreen { return injectedScreen }
        if CGPreflightScreenCaptureAccess() {
            // The grant exists. Whether it applies to US depends on when it arrived.
            return screenGrantedAtLaunch ? .granted : .needsRelaunch
        }
        // No grant. `needed` and `denied` are indistinguishable to CoreGraphics, so
        // the only evidence is whether we've already spent our one prompt.
        return hasAskedForScreenRecording ? .denied : .needed
    }

    static var microphone: PermissionStatus {
        if let injectedMicrophone { return injectedMicrophone }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .needed
        // `.restricted` is a managed device with the microphone turned off by
        // policy. The user can't grant it from here either, so the honest action is
        // the same one denial gets: show them where the setting lives.
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    // MARK: - Requests

    private static let screenAskedKey = "screenRecordingRequested"

    private static var hasAskedForScreenRecording: Bool {
        UserDefaults.standard.bool(forKey: screenAskedKey)
    }

    /// Raise macOS's Screen Recording consent prompt.
    ///
    /// Off the main thread: this is a synchronous CoreGraphics call that can sit
    /// there while the system puts up its own alert, and blocking the main thread
    /// would freeze the very window the user is reading.
    ///
    /// The "we asked" flag is only written when the request did NOT yield access —
    /// so a machine that already has the grant never accumulates the flag, and the
    /// flag only ever means what it says.
    static func requestScreenRecording(then finish: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let granted = CGRequestScreenCaptureAccess()
            DispatchQueue.main.async {
                if !granted { UserDefaults.standard.set(true, forKey: screenAskedKey) }
                note("screen recording request → granted=\(granted)")
                finish()
            }
        }
    }

    static func requestMicrophone(then finish: @escaping () -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                note("microphone request → granted=\(granted)")
                finish()
            }
        }
    }

    // MARK: - System Settings

    /// The exact pane for one permission. Both anchors are verified to land on the
    /// right list rather than the top of Privacy & Security — see the stage-2 notes
    /// in README; a URL that opens the wrong pane is worse than no button, because
    /// the user believes they've been taken where they need to be.
    static func settingsURL(for kind: PermissionKind) -> URL {
        let anchor: String
        switch kind {
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .microphone: anchor = "Privacy_Microphone"
        }
        // Force-unwrapped on purpose: these are two compile-time constants with no
        // interpolated user input. If one of them stops parsing, that is a build
        // mistake to find immediately, not a silently dead button to ship.
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    static func openSettings(for kind: PermissionKind) {
        let url = settingsURL(for: kind)
        note("opening \(url.absoluteString)")
        NSWorkspace.shared.open(url)
    }

    // MARK: - Relaunch

    /// Quit and come back, because a Screen Recording grant that arrived after
    /// launch doesn't apply to this process.
    ///
    /// Launched through `/bin/sh` so the child outlives us, and with `open -n` so it
    /// starts a NEW instance of the bundle at *this* path. Without `-n`, `open`
    /// would just activate an already-running instance — which, since the bundle id
    /// is shared with any installed copy, could be a completely different build.
    ///
    /// The current arguments are forwarded, so a relaunch is a relaunch of the same
    /// invocation. In normal operation there are none; in a debug run it means the
    /// new instance is also self-terminating rather than a resident process left
    /// holding the global hotkey.
    static func relaunch() {
        let bundle = Bundle.main.bundleURL
        let target = bundle.pathExtension == "app" ? bundle.path : Bundle.main.executablePath
        guard let target else {
            note("relaunch: no launchable path — staying put")
            return
        }
        let isBundle = bundle.pathExtension == "app"
        let args = forwardableArguments()
        var command = isBundle ? "/usr/bin/open -n \(quote(target))" : quote(target)
        if !args.isEmpty {
            command += (isBundle ? " --args " : " ") + args.map(quote).joined(separator: " ")
            if !isBundle { command += " &" }
        } else if !isBundle {
            command += " &"
        }
        note("relaunching: \(command)")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The delay lets this process finish exiting first, so the new instance
        // isn't competing with a dying one for the hotkey and the control socket.
        task.arguments = ["-c", "sleep 0.6; \(command)"]
        do {
            try task.run()
        } catch {
            note("relaunch failed to spawn: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    /// Arguments worth carrying into the new instance.
    ///
    /// `--debug-setup-action` is dropped, and that exclusion is load-bearing rather
    /// than tidy: it means "press this button once, then quit". Forwarded, the new
    /// instance would press Relaunch again — and again — spawning app instances
    /// without bound on the user's machine. Any future one-shot flag belongs in this
    /// list for the same reason: a relaunch must not re-fire the thing that caused it.
    private static let oneShotFlags: Set<String> = ["--debug-setup-action"]

    private static func forwardableArguments() -> [String] {
        var kept: [String] = []
        let argv = Array(CommandLine.arguments.dropFirst())
        var i = 0
        while i < argv.count {
            if oneShotFlags.contains(argv[i]) {
                // Skip the flag and the value that belongs to it.
                i += 2
                continue
            }
            kept.append(argv[i])
            i += 1
        }
        return kept
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
