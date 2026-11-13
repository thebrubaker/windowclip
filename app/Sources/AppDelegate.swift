// AppDelegate — app lifecycle plus the debug-show harness.
//
// Every surface must be summonable deterministically, without a hotkey and
// without a real recording, so it can be screenshotted and judged:
//
//   Windowclip.app/Contents/MacOS/Windowclip --debug-show pill-recording
//
// In debug mode the app prints the CGWindowID of each surface it puts on screen,
// so `screencapture -l <id>` targets the REAL rendered window.

import AVFoundation
import AppKit
import UniformTypeIdentifiers

struct LaunchOptions {
    var debugShow: String?
    var debugMidline = false
    var debugFreeze = false
    /// Screenshot the surface to this path and quit. Debug surfaces appear on the
    /// user's REAL screen — a floating panel parked there while someone goes off
    /// to analyze the shot is in their way, so capture is self-terminating by
    /// construction rather than by remembering to clean up.
    var debugCapture: String?
    /// Time to let the surface settle (thumbnails stream in async) before capture.
    var debugCaptureDelay: Double = 1.8
    /// Backstop for interactive debug runs: a surface can never outlive this.
    var debugTimeout: Double = 25
    /// End-to-end: drive the real session against this window (CGWindowID, or a
    /// case-insensitive substring of app+title) and quit when it's saved.
    var debugRecord: String?
    var debugRecordSeconds: Double = 5
    /// Where the end-to-end run writes. Same `--output` the control surface takes,
    /// so a harness recording can land somewhere disposable — and so the history
    /// it feeds carries the real, arbitrary filenames a caller actually asks for
    /// rather than only the Desktop default.
    var debugRecordOutput: String?
    /// Force the saved pill's filename into its hover treatment, so the click
    /// affordance can be screenshotted without parking a pointer on the pill.
    var debugHover = false
    /// Exercise the Finder-reveal call directly, then quit.
    var debugReveal = false
    /// Fire the status menu's Nth "Recent Recordings" item — the real NSMenuItem,
    /// its real target/action — then quit. A menu item is only as good as what
    /// happens when it is clicked, and clicking one for real needs an
    /// Accessibility grant this app deliberately doesn't have.
    var debugRevealRecent: Int?
    /// Dress a debug surface as an agent-initiated session (violet ring +
    /// attribution). The agent pill has its own text runs — "Claude · Recording
    /// Linear…", "Claude · 0:42" — and a text run that can't be summoned can't be
    /// measured, so the attribution states are first-class debug surfaces too.
    var debugAgent = false
    var debugLabel = "Claude"
    /// Force the setup window's permission rows into a given state.
    ///
    /// The ungranted states must be renderable WITHOUT revoking a real grant:
    /// `tccutil reset` on this machine would break the installed app that is in
    /// daily use, and re-granting is a manual chore. So the states are injected
    /// here, and the only thing the harness can't prove is TCC's own reporting —
    /// which stage 2 verifies against the live granted path instead.
    var debugScreenStatus: PermissionStatus?
    var debugMicStatus: PermissionStatus?
    /// Park a plain light (or dark) window behind the debug surface, owned by THIS
    /// app, so a translucent panel can be judged over a background other than the
    /// user's wallpaper — without changing that wallpaper.
    ///
    /// It lives in-process because borrowing another app's window doesn't work:
    /// parking a white Preview window behind the setup panel was tried twice and
    /// the frontmost app reclaimed the z-order between the launch and the shot both
    /// times, so the "white background" shot came back showing a dark terminal.
    /// Same-app windows order deterministically; other apps' don't.
    var debugBackdrop: String?
    /// Print what macOS actually reports about our grants, then quit. Reads only —
    /// no request, no prompt, nothing written. This is the safe way to confirm the
    /// live state of a machine before running anything that *could* raise a prompt.
    var debugPermissions = false
    /// Drive the setup window from the REAL permission state instead of injected
    /// flags, and keep it in sync while it's up. How the granted path gets verified
    /// against live TCC rather than against a fixture.
    var debugLive = false
    /// Fire a row's real action — the same closure a click runs — then quit. A
    /// button is only as good as what happens when it's pressed, and pressing one
    /// for real needs an Accessibility grant this app deliberately doesn't have.
    /// Same trick as `--debug-reveal-recent`.
    var debugSetupAction: PermissionKind?
    /// Fire the status-menu item whose title contains this text, then quit.
    var debugFireMenu: String?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let options: LaunchOptions
    private var pill: PillController?
    private var picker: PickerController?
    private var session: SessionController?
    private var statusItem: NSStatusItem?
    private var control: ControlServer?
    private var setup: SetupController?
    /// Debug-only: see `showDebugBackdrop`.
    private var backdrop: NSWindow?
    /// Re-reads TCC while the setup window is up: see `startStatusPolling`.
    private var statusPoll: Timer?
    /// The setup window can be dismissed twice on the way out (Done, then
    /// `windowWillClose` as the app tears down). Debug runs quit on dismissal, so
    /// the second one must not re-enter `terminate`.
    private var setupDismissed = false

    nonisolated init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First thing, before any surface exists: whether Screen Recording was
        // granted *at launch* is the only way to tell a usable grant from one that
        // needs a relaunch, and it stops being knowable the moment the user grants.
        Permissions.snapshotLaunchState()
        applyDebugInjections()

        if options.debugPermissions {
            runDebugPermissions()
        } else if let needle = options.debugFireMenu {
            runDebugFireMenu(needle)
        } else if options.debugReveal {
            revealInFinder(Self.newestRecording())
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        } else if let index = options.debugRevealRecent {
            runDebugRevealRecent(index)
        } else if let surface = options.debugShow {
            runDebugSurface(surface)
        } else if let target = options.debugRecord {
            runEndToEnd(target: target)
        } else {
            startSession()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.shutdown()
        control?.stop()
    }

    /// Force what the permission reads report, before anything asks them.
    ///
    /// `--debug-show setup` keeps its documented behaviour of defaulting an
    /// unspecified row to `needed`, because that is the state every README example
    /// and every stage-1 screenshot was taken in. Every other surface — the gate
    /// especially — injects only what was asked for, so an unflagged run reads the
    /// machine's real state and the invisible case is observable.
    private func applyDebugInjections() {
        let defaultsToNeeded = options.debugShow == "setup" && !options.debugLive
        let screen = options.debugScreenStatus ?? (defaultsToNeeded ? .needed : nil)
        let mic = options.debugMicStatus ?? (defaultsToNeeded ? .needed : nil)
        guard screen != nil || mic != nil else { return }
        Permissions.inject(screen: screen, microphone: mic)
    }

    // MARK: - Normal operation

    private func startSession() {
        let pill = PillController()
        self.pill = pill
        let session = SessionController(pill: pill)
        self.session = session

        let ok = HotkeyManager.shared.register(.toggle) { [weak session] in session?.toggle() }
        if ok {
            note("registered ⌥⌘R (Esc stays yours until a pill is up)")
        } else {
            // A hotkey we couldn't claim means the app silently does nothing —
            // say so rather than sitting there looking alive.
            FileHandle.standardError.write(Data(
                "windowclip: could not register ⌥⌘R — another app is probably holding it.\n".utf8
            ))
            Log.write("app", "could not register ⌥⌘R — another app is probably holding it")
        }

        installStatusItem()
        Backgrounds.shared.warmThumbnails()
        startControlServer(session: session)
        note("ready — ⌥⌘R to record")

        // Last, and only if something is missing. The hotkey, the status item and the
        // control socket all come up first so a user who dismisses this window
        // without fixing anything still has a working app to come back to — and so
        // the window is never the reason the rest of the app didn't start.
        showSetupIfIncomplete()
    }

    /// The external control surface. Failing to open it must not take the app
    /// down — the hotkey flow is still perfectly usable without it, and a hard
    /// exit here would break the thing that already works.
    private func startControlServer(session: SessionController) {
        let server = ControlServer()
        server.handler = { [weak session] request, respond in
            guard let session else {
                return respond(["ok": false, "error": "unavailable"])
            }
            AppDelegate.handle(request, session: session, respond: respond)
        }
        do {
            try server.start()
            control = server
        } catch {
            FileHandle.standardError.write(Data(
                "windowclip: control socket unavailable: \(error.localizedDescription)\n".utf8
            ))
            Log.write("control", "socket unavailable: \(error.localizedDescription)")
        }
    }

    /// The control vocabulary. Kept static and session-parameterised so it has no
    /// hidden state of its own.
    private static func handle(
        _ request: ControlRequest,
        session: SessionController,
        respond: @escaping ([String: Any]) -> Void
    ) {
        func reply(_ result: SessionResult) {
            var payload: [String: Any] = ["ok": result.ok, "state": result.state]
            if let output = result.output { payload["output"] = output.path }
            if result.duration > 0 { payload["duration"] = result.duration }
            if result.cancelled { payload["cancelled"] = true }
            if let error = result.error { payload["error"] = error }
            respond(payload)
        }

        switch request.command {
        case "ping":
            respond(["ok": true, "state": session.describe(session.phase)])

        case "status":
            respond(session.statusPayload())

        case "start":
            let target: CaptureTarget
            let asksForDisplay = request.body["displayId"] != nil
            if asksForDisplay {
                guard request.body["windowId"] == nil else {
                    return respond(["ok": false, "error": "bad_request",
                                    "message": "start takes windowId or displayId, not both"])
                }
                guard request.body["background"] == nil else {
                    return respond(["ok": false, "error": "bad_request",
                                    "message": "a screen recording has no background"])
                }
                let id: CGDirectDisplayID? = request.string("displayId") == "main"
                    ? CGMainDisplayID()
                    : request.int("displayId").map { CGDirectDisplayID($0) }
                guard let id, let display = DisplayEnumerator.display(id: id) else {
                    return respond(["ok": false, "error": "display_not_found",
                                    "message": "no connected display with id \(request.body["displayId"] ?? "")"])
                }
                target = .display(display)
            } else {
                guard let windowId = request.int("windowId") else {
                    return respond(["ok": false, "error": "bad_request",
                                    "message": "start requires windowId or displayId"])
                }
                guard let window = WindowEnumerator.list()
                    .first(where: { $0.id == CGWindowID(windowId) })
                else {
                    return respond(["ok": false, "error": "window_not_found",
                                    "message": "no on-screen window with id \(windowId)"])
                }
                target = .window(window)
            }
            let source: SessionSource = {
                guard request.string("source") != "human" else { return .human }
                return .agent(label: request.string("label") ?? "Claude")
            }()
            let output = request.string("output").map { URL(fileURLWithPath: $0) }
            var background: Background?
            if let asked = request.string("background") {
                guard let found = Backgrounds.shared.resolve(asked) else {
                    return respond(["ok": false, "error": "background_not_found",
                                    "message": "no saved background or image file matches \"\(asked)\""])
                }
                background = found
            }
            session.start(target: target, source: source, output: output, background: background) { reply($0) }

        case "backgrounds":
            respond(Backgrounds.shared.payload())

        case "stop":
            session.requestStop { reply($0) }

        case "cancel":
            session.requestCancel { reply($0) }

        // The human override, fired deterministically. `escape` is NOT another
        // way to cancel — `cancel` already exists. It calls the very function the
        // physical Esc key calls, with no waiter of its own, so what it proves is
        // that a user overriding an agent's session resolves that agent's pending
        // `start` as cancelled. A synthetic key event can't prove that (the hotkey
        // is a Carbon grab, not a keystroke anyone can inject without an
        // Accessibility grant this app deliberately doesn't have), so the same
        // entry point is exposed directly rather than approximated.
        case "escape":
            session.escape(via: "control escape")
            respond(["ok": true, "state": session.describe(session.phase)])

        default:
            respond(["ok": false, "error": "unknown_command", "message": request.command])
        }
    }

    /// Not the interface — the app is the pill and the picker. This exists so an
    /// agent app with no Dock icon has a visible way to quit, and (DIG-795) so the
    /// last five recordings stay findable after their pill has faded.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "record.circle",
            accessibilityDescription: "Windowclip"
        )
        let menu = NSMenu()
        // The recents section decides its own enablement (a file that has moved
        // is shown greyed rather than firing into nothing), so AppKit's automatic
        // validation has to stay out of it.
        menu.autoenablesItems = false
        menu.delegate = self
        rebuildMenu(menu)
        item.menu = menu
        statusItem = item
    }

    /// Rebuilt every time the menu is about to open, not once at launch: the
    /// history changes underneath it as recordings are made, and a file's
    /// existence is only worth checking at the moment someone can click it.
    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let record = NSMenuItem(
            title: "Record a Window…", action: #selector(recordFromMenu), keyEquivalent: "r"
        )
        record.keyEquivalentModifierMask = [.command, .option]
        record.target = self
        menu.addItem(record)

        let screen = NSMenuItem(
            title: "Record Entire Screen…", action: #selector(recordScreenFromMenu), keyEquivalent: ""
        )
        screen.target = self
        screen.isEnabled = true
        menu.addItem(screen)

        menu.addItem(.separator())
        let header = NSMenuItem(title: "Recent Recordings", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let entries = RecentRecordings.shared.entries
        if entries.isEmpty {
            let empty = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            empty.indentationLevel = 1
            menu.addItem(empty)
        } else {
            for entry in entries { menu.addItem(recentItem(for: entry)) }
        }

        menu.addItem(.separator())
        menu.addItem(backgroundMenuItem())

        menu.addItem(.separator())

        // A section of its own, NOT grouped with Quit. macOS gives Quit a
        // system-supplied glyph, and an icon on any item makes AppKit reserve an icon
        // column for that whole section — so sharing Quit's group pushed this item
        // right to align with Quit's *text* while filling nothing, and it read as
        // accidentally indented next to every other row in the menu. (Seen; the menu
        // dump reports `image=yes` on Quit and nothing else.) Its own section puts it
        // back on the same left edge as "Record a Window…".
        //
        // It exists because a grant can be revoked at any time, months later, by
        // someone who has long forgotten this window existed. Without a way back the
        // app just quietly stops working — the exact failure this feature prevents,
        // reintroduced one level up. Ellipsis: it opens a window that wants something.
        let permissions = NSMenuItem(
            title: "Permissions…", action: #selector(showSetupFromMenu), keyEquivalent: ""
        )
        permissions.target = self
        // The menu turns off AppKit's automatic validation for the recents section,
        // so enablement here has to be stated rather than assumed.
        permissions.isEnabled = true
        menu.addItem(permissions)

        let revealLog = NSMenuItem(title: "Reveal Log", action: #selector(revealLog), keyEquivalent: "")
        revealLog.target = self
        revealLog.isEnabled = true
        menu.addItem(revealLog)

        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "Quit Windowclip", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        )
    }

    /// Rebuilt with the rest of the menu on every open, so a file dropped into
    /// the folder in Finder is there the next time the menu opens. Groups are
    /// the folder's subfolders, each under its own header.
    private func backgroundMenuItem() -> NSMenuItem {
        let store = Backgrounds.shared
        let current = store.current
        let parent = NSMenuItem(
            title: "Background: \(current?.name ?? "None")", action: nil, keyEquivalent: ""
        )
        parent.isEnabled = true
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        if let fallback = store.bundledDefault {
            submenu.addItem(backgroundItem(fallback, title: "\(fallback.name) (default)", current: current))
        }
        var group: String?
        for item in store.saved() {
            if item.group != group {
                group = item.group
                submenu.addItem(.separator())
                submenu.addItem(.sectionHeader(title: item.group ?? ""))
            }
            submenu.addItem(backgroundItem(item, title: item.name, current: current))
        }

        submenu.addItem(.separator())
        let add = NSMenuItem(title: "Add Background…", action: #selector(addBackground), keyEquivalent: "")
        add.target = self
        add.isEnabled = true
        submenu.addItem(add)
        let reveal = NSMenuItem(
            title: "Show Backgrounds Folder", action: #selector(showBackgroundsFolder), keyEquivalent: ""
        )
        reveal.target = self
        reveal.isEnabled = true
        submenu.addItem(reveal)

        parent.submenu = submenu
        return parent
    }

    private func backgroundItem(_ background: Background, title: String, current: Background?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(chooseBackground(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        item.representedObject = background.id
        item.state = background.id == current?.id ? .on : .off
        item.image = Backgrounds.shared.thumbnail(for: background)
        item.toolTip = background.url.path
        return item
    }

    @objc private func chooseBackground(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let chosen = Backgrounds.shared.resolve(id)
        else { return }
        Backgrounds.shared.select(chosen)
    }

    @objc private func addBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose images to keep as backgrounds. They are copied into the backgrounds folder."
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let added = Backgrounds.shared.importFiles(panel.urls)
        if added.count == 1 { Backgrounds.shared.select(added[0]) }
        Backgrounds.shared.warmThumbnails()
    }

    @objc private func revealLog() {
        Log.write("app", "log revealed from the menu")
        Log.flush()
        NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
    }

    @objc private func showBackgroundsFolder() {
        let folder = Backgrounds.shared.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// Summoned on demand, so the window is reachable when everything is already
    /// granted — the launch gate deliberately won't show it then.
    @objc private func showSetupFromMenu() {
        showSetup()
    }

    private func recentItem(for entry: RecentRecordings.Entry) -> NSMenuItem {
        let url = entry.url
        let exists = FileManager.default.fileExists(atPath: url.path)
        let name = RecentRecordings.displayName(for: url)
        // A recording that has been moved or thrown away stays listed but greyed
        // and labelled — silently dropping it would leave the user wondering
        // whether the app forgot, and firing a reveal at a dead path would beep
        // for no reason they can see.
        let item = NSMenuItem(
            title: exists ? name : "\(name) — missing",
            action: #selector(revealRecent(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = url
        item.isEnabled = exists
        item.indentationLevel = 1
        item.toolTip = url.path
        return item
    }

    @objc private func recordFromMenu() {
        session?.toggle()
    }

    @objc private func recordScreenFromMenu() {
        session?.pickScreen()
    }

    /// The same reveal the saved pill performs — Finder, with the file selected.
    @objc private func revealRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        revealInFinder(url)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        rebuildMenu(menu)
    }

    // MARK: - End-to-end harness

    /// Drives the REAL SessionController (countdown → recorder spawn → SIGTERM
    /// finalize → saved pill) against a named window, then quits. Deliberately
    /// not a parallel test-only path: if this passes, the thing that ran is the
    /// thing the hotkey runs.
    private func runEndToEnd(target: String) {
        let windows = WindowEnumerator.list()
        let match: CaptureTarget? = {
            if target == "display:main" {
                return DisplayEnumerator.display(id: CGMainDisplayID()).map(CaptureTarget.display)
            }
            if target.hasPrefix("display:"), let id = UInt32(target.dropFirst("display:".count)) {
                return DisplayEnumerator.display(id: id).map(CaptureTarget.display)
            }
            if let id = UInt32(target) {
                return windows.first { $0.id == id }.map(CaptureTarget.window)
            }
            let needle = target.lowercased()
            return windows.first { "\($0.app) \($0.title)".lowercased().contains(needle) }.map(CaptureTarget.window)
        }()

        guard let match else {
            FileHandle.standardError.write(Data(
                "windowclip: nothing matched \"\(target)\" among \(windows.count) windows on screen\n".utf8
            ))
            exit(2)
        }

        let pill = PillController()
        self.pill = pill
        let session = SessionController(pill: pill)
        self.session = session

        switch match {
        case let .window(window): note("end-to-end: \(window.app) — \(window.title) [\(window.id)]")
        case let .display(display): note("end-to-end: display \(display.name) [\(display.id)]")
        }
        session.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            note("phase → \(phase)")
            switch phase {
            case .recording:
                let after = self.options.debugRecordSeconds
                // NOT asyncAfter: GCD coalesces timers with a leeway
                // proportional to the deadline, which fired this ~5% late
                // (+0.5s on a 10s take) and showed up as the recorder
                // overshooting when the recorder was in fact accurate to 13ms.
                // The harness is the measuring instrument for duration bugs, so
                // it has to keep better time than the thing it measures.
                let stopTimer = Timer(timeInterval: after, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        note("stopping after \(after)s")
                        session.requestStop()
                    }
                }
                stopTimer.tolerance = 0
                RunLoop.main.add(stopTimer, forMode: .common)
            case .saved:
                note("output: \(session.outputURL?.path ?? "<none>")")
                self.captureAfterRedraw(options.debugCapture, region: { pill.captureRegion }) {
                    NSApp.terminate(nil)
                }
            default:
                break
            }
        }
        session.start(target: match, output: options.debugRecordOutput.map { URL(fileURLWithPath: $0) })

        // Backstop: never leave a recorder running because a phase never arrived.
        DispatchQueue.main.asyncAfter(deadline: .now() + options.debugRecordSeconds + 30) {
            FileHandle.standardError.write(Data("windowclip: end-to-end timed out\n".utf8))
            NSApp.terminate(nil)
        }
    }

    /// Screenshotting a surface you just mutated in the SAME run-loop turn races
    /// the redraw — `screencapture` runs synchronously and the window never gets
    /// to draw, so the shot shows the PREVIOUS state. (Caught exactly that way:
    /// a "saved" capture that came back showing the recording pill.) Always let
    /// the run loop turn over first.
    private func captureAfterRedraw(
        _ path: String?,
        region: @escaping () -> String?,
        then finish: @escaping () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let path, let region = region() {
                self.captureRegion(region, to: path)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: finish)
        }
    }

    private func captureRegion(_ region: String, to path: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-R\(region)", "-o", "-x", path]
        try? task.run()
        task.waitUntilExit()
        Self.reportCapture(path, describedAs: "region \(region)")
    }

    /// Say what actually happened, not what was attempted.
    ///
    /// This used to print "captured <path>" unconditionally. `screencapture` writing
    /// into a directory that doesn't exist fails silently, `try?` swallows the throw,
    /// and the harness cheerfully reported a screenshot that was never written — a
    /// verification tool minting a false fact about its own work, which is worse than
    /// no tool. Caught exactly that way: a whole run's evidence didn't exist.
    private nonisolated static func reportCapture(_ path: String, describedAs what: String) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard let bytes = attributes?[.size] as? Int, bytes > 0 else {
            let message = "windowclip: capture FAILED — nothing written to \(path)"
                + " (\(what)). Does its directory exist?\n"
            FileHandle.standardError.write(Data(message.utf8))
            return
        }
        note("captured \(path) (\(what), \(bytes) bytes)")
    }

    /// The debug saved-pill points at a REAL file when one exists, so its click
    /// target is actually clickable rather than a dead path.
    private static func newestRecording() -> URL {
        let fm = FileManager.default
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
        let candidates = desktop.flatMap {
            try? fm.contentsOfDirectory(
                at: $0, includingPropertiesForKeys: [.contentModificationDateKey]
            )
        } ?? []
        let newest = candidates
            .filter { $0.lastPathComponent.hasPrefix("recording-") && $0.pathExtension == "mp4" }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return da < db
            }
        return newest ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop/recording-example.mp4")
    }

    /// Summon the status-item menu itself. Opening a menu runs a modal tracking
    /// loop that owns the main thread until it closes, so everything after
    /// `performClick` is scheduled off-main — including the exit, since
    /// `NSApp.terminate` would sit in a queue the tracking loop never drains.
    private func runDebugMenu() {
        installStatusItem()
        if let menu = statusItem?.menu {
            rebuildMenu(menu)
            note("menu items:")
            Self.dump(menu, depth: 1)
        }
        armMenuCapture()
        DispatchQueue.main.async { [self] in
            note("opening the status menu — Ctrl-C or `pkill -f Windowclip` to dismiss")
            statusItem?.button?.performClick(nil)
        }
    }

    private func armMenuCapture() {
        let path = options.debugCapture
        let delay = path == nil ? options.debugTimeout : options.debugCaptureDelay
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            if let path {
                if let id = Self.openMenuWindowID() {
                    Self.captureWindow(id, to: path)
                } else {
                    FileHandle.standardError.write(Data(
                        "windowclip: no open menu window to capture\n".utf8
                    ))
                }
            }
            exit(0)
        }
    }

    /// The menu is drawn by this process, above the normal window levels — so
    /// "our biggest high-level window on screen" identifies it without guessing
    /// at screen coordinates that move with the status item.
    private nonisolated static func openMenuWindowID() -> CGWindowID? {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let mine = info.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == getpid() }
        let candidates = mine.filter {
            ($0[kCGWindowLayer as String] as? Int ?? 0) >= Int(CGWindowLevelForKey(.popUpMenuWindow))
        }
        func area(_ window: [String: Any]) -> Double {
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double
            else { return 0 }
            return w * h
        }
        return (candidates.max { area($0) < area($1) })?[kCGWindowNumber as String] as? CGWindowID
    }

    /// Window-scoped capture, and that scope has a consequence worth stating: it
    /// records the window's own layer, NOT the screen composite, so whatever is
    /// behind the window never appears. A menu shot is therefore **backdrop-blind** —
    /// proven, not assumed: the same menu captured over a white backdrop and a dark
    /// one came out byte-identical. So these shots cannot be used to judge
    /// translucency, vibrancy or contrast-against-background, and a flat-looking panel
    /// in one is the capture talking, not the material. (An adversarial review of a
    /// menu shot reached exactly that wrong conclusion.) Use `-R` region capture, as
    /// the pill/picker/setup surfaces do, if the background matters.
    private nonisolated static func captureWindow(_ id: CGWindowID, to path: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-l\(id)", "-o", "-x", path]
        try? task.run()
        task.waitUntilExit()
        reportCapture(path, describedAs: "window \(id)")
    }

    // indent/image/state are reported because they are what decides an item's
    // left inset, and a row sitting at a different inset from its neighbours
    // reads as a layout accident rather than a group.
    private static func dump(_ menu: NSMenu, depth: Int) {
        let pad = String(repeating: "  ", count: depth)
        for item in menu.items {
            if item.isSeparatorItem { note("\(pad)---"); continue }
            note("\(pad)\(item.isEnabled ? "•" : "×") \(item.title)"
                + " [indent=\(item.indentationLevel)"
                + " image=\(item.image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "none")"
                + " state=\(item.state.rawValue)"
                + " header=\(item.isSectionHeader)"
                + " key=\(item.keyEquivalent.isEmpty ? "-" : item.keyEquivalent)]")
            if let submenu = item.submenu { dump(submenu, depth: depth + 1) }
        }
    }

    /// Submenu items first, so a needle like "1B" reaches a background rather
    /// than the parent whose title names the current one.
    private static func flatten(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in (item.submenu.map(flatten) ?? []) + [item] }
    }

    /// Fire the status-menu item whose title contains `needle` — the real NSMenuItem,
    /// its real target and action. A menu entry is only worth as much as what happens
    /// when it is clicked, and clicking one for real needs an Accessibility grant this
    /// app deliberately doesn't have.
    private func runDebugFireMenu(_ needle: String) {
        installStatusItem()
        guard let menu = statusItem?.menu else { exit(70) }
        rebuildMenu(menu)
        guard let item = Self.flatten(menu).first(where: {
            $0.title.localizedCaseInsensitiveContains(needle)
        }) else {
            let titles = Self.flatten(menu).map(\.title).filter { !$0.isEmpty }
            FileHandle.standardError.write(Data(
                "windowclip: no menu item matching \"\(needle)\" among \(titles)\n".utf8
            ))
            exit(2)
        }
        note("menu item: \"\(item.title)\" enabled=\(item.isEnabled)")
        guard item.isEnabled, let action = item.action, let target = item.target else {
            note("nothing wired to it — a click here does nothing")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            return
        }
        _ = target.perform(action, with: item)
        // The action may well have put a window up; capture whatever it produced.
        DispatchQueue.main.async { [self] in
            note("window id: \(setup?.windowID.map(String.init) ?? "<none>")")
            armCapture { self.setup?.captureRegion }
        }
    }

    /// Click the Nth recent item the way AppKit would: a disabled item is
    /// reported and left alone, exactly as a real click on a greyed row does
    /// nothing. Everything else goes through the item's own target/action.
    private func runDebugRevealRecent(_ index: Int) {
        installStatusItem()
        guard let menu = statusItem?.menu else { exit(70) }
        rebuildMenu(menu)
        let recents = menu.items.filter { $0.representedObject is URL }
        guard let item = recents[safe: index] else {
            FileHandle.standardError.write(Data(
                "windowclip: no recent item at index \(index) (have \(recents.count))\n".utf8
            ))
            exit(2)
        }
        note("recent[\(index)]: \"\(item.title)\" enabled=\(item.isEnabled)")
        note("path: \((item.representedObject as? URL)?.path ?? "<none>")")
        if item.isEnabled, let action = item.action, let target = item.target {
            _ = target.perform(action, with: item)
        } else {
            note("item is disabled — a click on it does nothing, by design")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSApp.terminate(nil) }
    }

    // MARK: - Permissions

    /// Read the real state into the window and re-lay it out. Called after every
    /// action and on a poll, because a grant can arrive from System Settings — a
    /// different app entirely — and nothing notifies us when it does.
    private func refreshSetupStatuses() {
        guard let setup else { return }
        let screen = Permissions.screenRecording
        let mic = Permissions.microphone
        guard screen != setup.model.screenRecording || mic != setup.model.microphone else { return }
        note("status change: screen \(setup.model.screenRecording.rawValue)→\(screen.rawValue), "
            + "mic \(setup.model.microphone.rawValue)→\(mic.rawValue)")
        setup.model.screenRecording = screen
        setup.model.microphone = mic
        setup.refresh()
    }

    /// The user visits System Settings and comes back; the window has to be right
    /// when they do. There is no TCC change notification, so this polls — but only
    /// while the window is actually on screen, so an invisible agent app isn't
    /// waking up to ask macOS questions nobody is reading the answer to.
    private func startStatusPolling() {
        guard statusPoll == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSetupStatuses() }
        }
        // Common-mode: without it the timer stalls for the whole time a menu or a
        // window drag is running its own tracking loop.
        RunLoop.main.add(timer, forMode: .common)
        statusPoll = timer
    }

    private func stopStatusPolling() {
        statusPoll?.invalidate()
        statusPoll = nil
    }

    /// The ONE place a setup window is built and wired.
    ///
    /// Both the real launch path and the debug harness come through here, so the
    /// buttons in a screenshot are wired to the handlers the shipping app uses. A
    /// debug surface that wires its own actions is a surface that can pass while the
    /// product is broken — which is the same reason the debug states are injected
    /// into `Permissions` rather than painted onto the model.
    private func setupController() -> SetupController {
        if let setup { return setup }
        let setup = SetupController()
        setup.onAction = { [weak self] kind, status in
            note("action: \(kind.rawValue) (\(status.rawValue))")
            self?.performSetupAction(kind, status)
        }
        setup.onClose = { [weak self] in self?.setupDidClose() }
        self.setup = setup
        return setup
    }

    /// Put the window up, seeded from whatever `Permissions` currently reports and
    /// tracking it from then on.
    private func showSetup() {
        let setup = setupController()
        // The window can be summoned again from the status menu after being
        // dismissed, so the once-only latch resets on the way in.
        setupDismissed = false
        setup.model.screenRecording = Permissions.screenRecording
        setup.model.microphone = Permissions.microphone
        setup.show()
        startStatusPolling()
        // Checked HERE because this is the only moment it could plausibly break: this
        // window is the one surface in the app that deliberately activates and takes
        // focus, and an app that quietly became .regular grows a Dock icon and a menu
        // bar it is not supposed to have. The invisibility is the product.
        let policy = NSApp.activationPolicy()
        note(policy == .accessory
            ? "activation policy: accessory (no Dock icon) — as it must be"
            : "activation policy: \(policy.rawValue) — NOT accessory, LSUIElement has regressed")
    }

    /// The launch gate: appear only when something is actually missing.
    ///
    /// A correctly configured user must see NOTHING — this app is `LSUIElement` and
    /// that invisibility is the product, not a side effect. Factored so the harness
    /// exercises this exact decision rather than a paraphrase of it.
    @discardableResult
    private func showSetupIfIncomplete() -> Bool {
        let screen = Permissions.screenRecording
        let mic = Permissions.microphone
        guard !(screen == .granted && mic == .granted) else {
            note("gate: screen=\(screen.rawValue), mic=\(mic.rawValue) — complete, staying invisible")
            return false
        }
        note("gate: screen=\(screen.rawValue), mic=\(mic.rawValue) — incomplete, showing setup")
        showSetup()
        return true
    }

    /// Dismissal, from Done, the close box, or Esc — and it can arrive twice on the
    /// way out, hence the latch.
    private func setupDidClose() {
        guard !setupDismissed else { return }
        setupDismissed = true
        stopStatusPolling()
        note("setup dismissed")
        // A debug run exists to show one surface, so dismissing it ends the run. In
        // normal operation the app simply goes back to being invisible.
        if options.debugShow != nil {
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// One state, one action. The window knows nothing about any of this; it just
    /// reports which row was pressed and what state that row was in.
    private func performSetupAction(_ kind: PermissionKind, _ status: PermissionStatus) {
        switch (kind, status) {
        case (_, .granted):
            // Not actionable — there is no button on a granted row.
            break
        case (.screenRecording, .needed):
            Permissions.requestScreenRecording { [weak self] in self?.refreshSetupStatuses() }
        case (.microphone, .needed):
            Permissions.requestMicrophone { [weak self] in self?.refreshSetupStatuses() }
        case (_, .denied):
            // macOS will not prompt this app again, so the only thing left that
            // helps is putting the right switch in front of them.
            Permissions.openSettings(for: kind)
        case (.screenRecording, .needsRelaunch):
            Permissions.relaunch()
        case (.microphone, .needsRelaunch):
            // Unreachable: a microphone grant applies to the running process, so
            // this row can never ask for a relaunch. Named rather than defaulted so
            // it stays unreachable on purpose instead of by omission.
            note("microphone has no relaunch state — ignoring")
        }
    }

    /// Press a row's control the way AppKit would, through the window's own
    /// `onAction`. A granted row has no control, so firing at one is reported and
    /// left alone — exactly as clicking empty space does nothing.
    private func fireSetupAction(_ kind: PermissionKind, on setup: SetupController) {
        let status = setup.model.status(of: kind)
        guard status != .granted else {
            note("\(kind.rawValue) is granted — that row has no button to press, by design")
            return
        }
        note("firing \(kind.rawValue) action in state \(status.rawValue)")
        setup.onAction(kind, status)
    }

    /// Read the live state and quit. Deliberately request-free: it proves what TCC
    /// says about this machine without any chance of raising a prompt, which is the
    /// only responsible first step on a machine whose real grants matter.
    private func runDebugPermissions() {
        note("screen recording: \(Permissions.screenRecording.rawValue) "
            + "(preflight=\(CGPreflightScreenCaptureAccess()))")
        note("microphone: \(Permissions.microphone.rawValue) "
            + "(AVCaptureDevice=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue))")
        for kind in PermissionKind.allCases {
            note("\(kind.rawValue) settings URL: \(Permissions.settingsURL(for: kind).absoluteString)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
    }

    /// The setup window, with real actions wired.
    ///
    /// Row states come from the flags by default — so a screenshot of `denied`
    /// costs nothing and revokes nothing — or from live TCC under `--debug-live`.
    /// Either way the BUTTONS are real: pressing one requests, deep-links or
    /// relaunches for real, and the window then re-reads the live state, which will
    /// replace any injected value. That is the point; a stub button proves nothing.
    private func runDebugSetup() {
        showSetup()
        guard let setup else { return }
        DispatchQueue.main.async { [self] in
            note("screen: \(setup.model.screenRecording.rawValue), mic: \(setup.model.microphone.rawValue)")
            note("window id: \(setup.windowID.map(String.init) ?? "<unavailable>")")
            note("showing setup — Esc or the close button to dismiss")
            // From here the poll reads reality, so a forced starting state can be
            // corrected in front of us. A timer that silently never fires looks
            // exactly like a machine whose permissions didn't change, and this is
            // the only way to tell those apart on a fully-granted machine.
            if options.debugLive { Permissions.clearInjections() }
            if let kind = options.debugSetupAction {
                fireSetupAction(kind, on: setup)
            }
            armCapture { setup.captureRegion }
        }
    }

    /// The launch gate itself, run in isolation and then torn down.
    ///
    /// Deliberately NOT a full `startSession()`: that registers the global hotkey,
    /// binds the control socket and installs a status item, all of which this clone
    /// shares a bundle id with an installed copy over — so a debug run of it would
    /// contend with the app the user actually depends on, and would never exit. This
    /// calls the same `showSetupIfIncomplete()` the real launch calls, and nothing
    /// else.
    private func runDebugGate() {
        let shown = showSetupIfIncomplete()
        guard shown, let setup else {
            note("gate showed nothing — quitting, which is exactly the invisible case")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            return
        }
        DispatchQueue.main.async { [self] in
            note("window id: \(setup.windowID.map(String.init) ?? "<unavailable>")")
            armCapture { setup.captureRegion }
        }
    }

    /// A screen-filling flat window under the surface being judged. Deliberately
    /// dumb: opaque fill, no content, ignores the mouse, torn down with the run.
    /// It measures nothing — it only changes what the panel's material has to
    /// survive being seen against.
    private func showDebugBackdrop(_ name: String) {
        let fill: NSColor
        switch name.lowercased() {
        case "white": fill = .white
        // A typical light-mode document window, which is what Art's screen will
        // actually have behind this panel more often than pure white.
        case "light": fill = NSColor(calibratedWhite: 0.95, alpha: 1)
        case "dark": fill = NSColor(calibratedWhite: 0.10, alpha: 1)
        default:
            FileHandle.standardError.write(Data(
                "windowclip: unknown --debug-backdrop \(name). Try: white, light, dark\n".utf8
            ))
            exit(64)
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let window = NSWindow(
            contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.backgroundColor = fill
        window.isOpaque = true
        // Left at .normal on purpose. Activating the app raises ALL of its normal
        // windows above other apps', so the backdrop covers the desktop while the
        // key window (the surface under test) still orders above the backdrop. A
        // below-normal level would put every other app's window back on top of it.
        window.level = .normal
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.orderFront(nil)
        backdrop = window
    }

    private func runDebugSurface(_ surface: String) {
        if let name = options.debugBackdrop { showDebugBackdrop(name) }

        if surface == "menu" {
            runDebugMenu()
            return
        }

        if surface == "setup" {
            runDebugSetup()
            return
        }

        if surface == "gate" {
            runDebugGate()
            return
        }

        if surface == "picker" {
            let picker = PickerController()
            self.picker = picker
            picker.onPick = { target in
                switch target {
                case let .window(window): note("picked: \(window.app) — \(window.title) [\(window.id)]")
                case let .display(display): note("picked: display \(display.name) [\(display.id)]")
                }
                NSApp.terminate(nil)
            }
            picker.onCancel = {
                note("picker cancelled")
                NSApp.terminate(nil)
            }
            picker.show()
            DispatchQueue.main.async { [self] in
                note("window id: \(picker.windowID.map(String.init) ?? "<unavailable>")")
                note("showing picker — arrows + return to pick, esc to close")
                armCapture { picker.captureRegion }
            }
            return
        }

        let pill = PillController(
            showMidline: options.debugMidline,
            freezeAnimation: options.debugFreeze,
            forceHover: options.debugHover
        )
        self.pill = pill
        pill.source = options.debugAgent ? .agent(label: options.debugLabel) : .human
        pill.onStop = { note("stop tapped") }
        // The real reveal call — not a stand-in — so clicking the filename in a
        // debug surface proves the shipping path.
        pill.onReveal = { url in revealInFinder(url) }
        pill.onHoverChanged = { note("pointer \($0 ? "entered" : "left") the pill") }

        switch surface {
        case "pill-countdown":
            pill.show(.countdown(remaining: 3, appName: "Linear"))
        case "pill-recording":
            pill.show(.recording(elapsed: 42))
        case "pill-saved":
            pill.show(.saved(url: Self.newestRecording(), duration: 42))
        default:
            FileHandle.standardError.write(Data(
                "windowclip: unknown --debug-show \(surface). Try: menu, picker, setup, gate, pill-countdown, pill-recording, pill-saved\n".utf8
            ))
            exit(64)
        }

        // Window numbers only exist once the panel is on screen; let the run loop
        // turn over once so the id we print is the real one.
        DispatchQueue.main.async { [self] in
            note("window id: \(pill.windowID.map(String.init) ?? "<unavailable>")")
            note("showing \(surface) — Ctrl-C or `pkill -f Windowclip` to dismiss")
            armCapture { pill.captureRegion }
        }
    }

    /// Self-terminating verification: screenshot the surface, then quit. Also
    /// arms a hard timeout for interactive runs, so no debug surface can outlive
    /// its welcome on someone's real desktop.
    private func armCapture(_ region: @escaping () -> String?) {
        if let path = options.debugCapture {
            DispatchQueue.main.asyncAfter(deadline: .now() + options.debugCaptureDelay) {
                guard let region = region() else {
                    FileHandle.standardError.write(Data("windowclip: no capture region\n".utf8))
                    NSApp.terminate(nil)
                    return
                }
                self.captureRegion(region, to: path)
                NSApp.terminate(nil)
            }
            return
        }
        note("capture region: \(region() ?? "<unavailable>")")
        DispatchQueue.main.asyncAfter(deadline: .now() + options.debugTimeout) {
            note("debug timeout reached — tearing the surface down")
            NSApp.terminate(nil)
        }
    }
}

func note(_ message: String) {
    print("[windowclip] \(message)")
    fflush(stdout)
    Log.write("app", message)
}
