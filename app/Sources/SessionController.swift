// SessionController — the flow itself.
//
//   idle ──⌥⌘R──▶ picking ──pick──▶ countdown 3·2·1 ──▶ recording ──stop──▶ saved ──▶ idle
//                    │                    │                  │
//                   esc                  esc               esc / ⌥⌘R / Stop
//                    ▼                    ▼                  ▼
//                   idle              idle (nothing        finalize, then saved
//                                      written)
//
// Esc is hijacked only for the span of the arrows above that have a pill on
// screen — registered when the countdown starts, unregistered when the session
// ends, in every exit path including failure.

import AppKit
import Foundation

/// Reveal in Finder rather than open: the point of a recording is usually to drag
/// it somewhere, and Finder-with-the-file-selected is that landing.
///
/// Top-level (not a method) so the debug path exercises the SHIPPING call rather
/// than a copy of it.
@MainActor
func revealInFinder(_ url: URL) {
    guard FileManager.default.fileExists(atPath: url.path) else {
        note("reveal: \(url.path) is gone")
        NSSound.beep()
        return
    }
    NSWorkspace.shared.activateFileViewerSelecting([url])
    note("revealed \(url.lastPathComponent) in Finder")
}

/// Who asked for this recording. Drives the pill's treatment: an agent-initiated
/// session has to be obviously distinguishable from one the user started, because
/// "I can see it happening" is the whole basis for ever letting an agent start one.
enum SessionSource: Equatable {
    case human
    case agent(label: String)

    var isAgent: Bool { self != .human }
    var label: String? {
        if case let .agent(label) = self { return label }
        return nil
    }
}

/// Everything a caller may choose about one take. Assigned whole at every
/// countdown, so nothing one session asked for can reach the next.
struct SessionRequest {
    var source: SessionSource = .human
    var output: URL?
    var background: Background?

    static let human = SessionRequest()
}

/// Where a take's output and background come from. The one resolver: the take
/// itself and every report of what the next take will do go through it.
struct TakePlan {
    enum Origin: String { case request, `default`, saved }

    var output: URL
    var outputFrom: Origin
    /// Nil for a screen take, or when there is no background at all.
    var background: Background?
    var backgroundFrom: Origin?

    @MainActor static func resolve(request: SessionRequest, isDisplay: Bool) -> TakePlan {
        let output = request.output ?? Recorder.defaultOutputURL()
        let outputFrom: Origin = request.output != nil ? .request : .default
        guard !isDisplay else { return TakePlan(output: output, outputFrom: outputFrom) }
        let background = request.background ?? Backgrounds.shared.current
        let from: Origin = request.background != nil ? .request : (background?.isDefault ?? true) ? .default : .saved
        return TakePlan(output: output, outputFrom: outputFrom, background: background, backgroundFrom: from)
    }

    var payload: [String: Any] {
        var p: [String: Any] = ["output": output.path, "outputFrom": outputFrom.rawValue]
        if let backgroundFrom {
            p["background"] = background?.id ?? "<mesh gradient>"
            p["backgroundFrom"] = backgroundFrom.rawValue
        } else {
            p["background"] = "none"
        }
        return p
    }
}

/// What a control-surface caller learns about the session it asked for.
struct SessionResult {
    var ok: Bool
    var state: String
    var output: URL?
    var duration: TimeInterval = 0
    var cancelled: Bool = false
    var error: String?
}

@MainActor
final class SessionController {
    enum Phase {
        case idle
        case picking
        case countdown
        case recording
        case saved
    }

    private(set) var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            Log.write("session", "take \(takeNumber): \(describe(oldValue)) → \(describe(phase))")
            publishState()
            onPhaseChange?(phase)
        }
    }

    /// Observation hook. Used by the end-to-end debug harness to drive the REAL
    /// state machine rather than a parallel test-only copy of it.
    var onPhaseChange: ((Phase) -> Void)?

    private let picker = PickerController()
    private let pill: PillController
    private let recorder = Recorder()

    private var target: CaptureTarget?
    private var countdownRemaining = 0
    private var timer: Timer?
    private var savedDismissWork: DispatchWorkItem?
    /// Where the warming recorder was told to write. Chosen at countdown time,
    /// because the recorder now spawns then.
    private var preparedOutput: URL?
    /// The countdown finished before the recorder could arm; the take starts the
    /// moment it does.
    private var waitingForArm = false
    private var armTimeoutWork: DispatchWorkItem?

    private var request = SessionRequest.human
    var source: SessionSource { request.source }
    private var activeBackground: Background?
    private var takeNumber = 0

    /// Control-surface callers block on these. A `start` isn't answered until the
    /// countdown has actually elapsed, so the caller learns "recording" or
    /// "cancelled" — never an optimistic "started" the user then vetoed.
    private var startWaiter: ((SessionResult) -> Void)?
    private var stopWaiter: ((SessionResult) -> Void)?

    private let fullScreenClaimsEscape = false

    /// Mockup's 3·2·1.
    private let countdownSeconds = 3
    /// How long to hold after the countdown for capture to come up, before
    /// calling the session failed rather than leaving a pill up forever.
    private let armTimeout: TimeInterval = 15
    /// How long the "Saved ✓" flash stays before fading.
    private let savedLinger: TimeInterval = 4

    init(pill: PillController) {
        self.pill = pill
        self.pill.onStop = { [weak self] in self?.stop(reason: "pill") }
        self.pill.onReveal = { [weak self] url in self?.reveal(url) }
        self.pill.onHoverChanged = { [weak self] hovering in self?.savedHoverChanged(hovering) }
        picker.onPick = { [weak self] target in self?.beginCountdown(for: target, request: .human) }
        picker.onCancel = { [weak self] in self?.phase = .idle }
    }

    // MARK: - Entry points

    /// ⌥⌘R. One key for the whole flow: summon, or stop what's running.
    func toggle() {
        switch phase {
        case .idle:
            showPicker()
        case .picking:
            picker.close(cancelled: true)
            phase = .idle
        case .countdown:
            cancelCountdown(reason: "hotkey")
        case .recording:
            stop(reason: "hotkey")
        case .saved:
            // Don't make the user wait out the confirmation to start the next take.
            dismissSaved()
            showPicker()
        }
    }

    /// What choosing a target in the open picker does.
    func pick(_ target: CaptureTarget) -> Bool {
        guard phase == .picking else { return false }
        picker.close(cancelled: false)
        picker.onPick(target)
        return true
    }

    func pickScreen() {
        switch phase {
        case .idle:
            showPicker(selectingScreens: true)
        case .saved:
            dismissSaved()
            showPicker(selectingScreens: true)
        case .picking:
            picker.selectScreens()
        case .countdown, .recording:
            toggle()
        }
    }

    /// Esc, while a pill is up.
    func escape(via reason: String = "esc") {
        switch phase {
        case .countdown: cancelCountdown(reason: reason)
        case .recording: stop(reason: reason)
        default: break
        }
    }

    /// Enter the flow at the moment a window has been chosen — same path the
    /// picker takes, minus the picking. Used by the hotkey picker, the debug
    /// harness, and the control surface alike, so an agent-started session runs
    /// exactly the machinery a human-started one does.
    ///
    /// `completion` fires once the outcome is real: recording underway, or the
    /// user cancelled during the countdown.
    func start(
        target: CaptureTarget,
        source: SessionSource = .human,
        output: URL? = nil,
        background: Background? = nil,
        completion: ((SessionResult) -> Void)? = nil
    ) {
        guard phase == .idle else {
            // Never queue, never preempt — a live session belongs to whoever has
            // the pill, and silently taking it over would be exactly the sort of
            // thing the user must never have to worry about.
            completion?(SessionResult(
                ok: false, state: describe(phase),
                error: "busy"
            ))
            return
        }
        self.startWaiter = completion
        beginCountdown(for: target, request: SessionRequest(source: source, output: output, background: background))
    }

    /// Stop from outside (control surface / debug harness / status menu).
    func requestStop(completion: ((SessionResult) -> Void)? = nil) {
        guard phase == .countdown || phase == .recording else {
            completion?(SessionResult(ok: false, state: describe(phase), error: "not_recording"))
            return
        }
        if phase == .countdown {
            // Stopping during the countdown is a cancel: nothing has been written.
            stopWaiter = completion
            cancelCountdown(reason: "control stop")
            return
        }
        stopWaiter = completion
        stop(reason: "control stop")
    }

    /// Abort and leave nothing behind.
    func requestCancel(completion: ((SessionResult) -> Void)? = nil) {
        guard phase != .idle else {
            completion?(SessionResult(ok: false, state: "idle", error: "not_recording"))
            return
        }
        stopWaiter = completion
        Log.write("session", "take \(takeNumber): cancel requested (control cancel)")
        if phase == .recording {
            endSession()
        } else {
            cancelCountdown(reason: "control cancel")
        }
    }

    var outputURL: URL? { recorder.outputURL }

    /// Snapshot for the control surface's `status` command.
    func statusPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "ok": true,
            "state": describe(phase),
            "source": source.isAgent ? "agent" : "human",
        ]
        if let label = source.label { payload["label"] = label }
        switch target {
        case let .window(window)?:
            payload["windowId"] = Int(window.id); payload["app"] = window.app
        case let .display(display)?:
            payload["displayId"] = Int(display.id); payload["display"] = display.name
        case nil:
            break
        }
        if let output = recorder.outputURL { payload["output"] = output.path }
        let live = phase == .countdown || phase == .recording
        let recordsBackground = !(live && target?.isDisplay == true)
        if recordsBackground, let background = (live ? activeBackground : nil) ?? Backgrounds.shared.current {
            payload["background"] = background.id
        }
        if phase == .recording { payload["elapsed"] = recorder.elapsed }
        return payload
    }

    func describe(_ phase: Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .picking: return "picking"
        case .countdown: return "countdown"
        case .recording: return "recording"
        case .saved: return "saved"
        }
    }

    // MARK: - Waiters

    private func resolveStart(_ result: SessionResult) {
        let waiter = startWaiter
        startWaiter = nil
        waiter?(result)
    }

    private func resolveStop(_ result: SessionResult) {
        let waiter = stopWaiter
        stopWaiter = nil
        waiter?(result)
    }

    // MARK: - Picking

    private func showPicker(selectingScreens: Bool = false) {
        phase = .picking
        picker.show(selectingScreens: selectingScreens)
    }

    // MARK: - Countdown

    private func beginCountdown(for target: CaptureTarget, request: SessionRequest) {
        self.request = request
        takeNumber += 1
        self.target = target
        phase = .countdown
        countdownRemaining = countdownSeconds

        // Esc becomes ours for exactly as long as the pill is up — for agent
        // sessions just as much as human ones. The countdown IS the user's veto
        // window, so it has to run identically no matter who asked.
        let claimsEscape = !target.isDisplay || fullScreenClaimsEscape
        if claimsEscape {
            HotkeyManager.shared.register(.escape) { [weak self] in self?.escape() }
        }

        pill.source = source
        pill.showsEscapeHint = claimsEscape
        pill.show(.countdown(remaining: countdownRemaining, appName: target.label))
        startTimer(interval: 1) { [weak self] in self?.tickCountdown() }

        // The countdown is dead time we were paying twice: the user waited it
        // out, and then the recording separately lost however long start-up
        // took. Warming here spends it once.
        prepareRecorder(for: target)
    }

    /// Spawn the recorder now and let it warm. It captures but discards frames
    /// until `go()`, so nothing of the countdown lands in the file.
    private func prepareRecorder(for target: CaptureTarget) {
        let plan = TakePlan.resolve(request: request, isDisplay: target.isDisplay)
        activePlan = plan
        let output = plan.output
        preparedOutput = output
        recorder.onArmed = { [weak self] in self?.recorderArmed() }
        recorder.onExit = { [weak self] status in self?.recorderExited(status: status) }
        do {
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let background = plan.background
            activeBackground = background
            let backgroundOrigin = plan.backgroundFrom?.rawValue ?? "none"
            let targetDescription: String
            switch target {
            case let .window(window): targetDescription = "window=\(window.id) app=\(window.app)"
            case let .display(display): targetDescription = "display=\(display.id) name=\(display.name)"
            }
            Log.write("take", "take \(takeNumber): source=\(request.source.isAgent ? "agent(\(request.source.label ?? ""))" : "human")"
                + " \(targetDescription)"
                + " output=\(output.path) (from: \(plan.outputFrom.rawValue))"
                + (target.isDisplay ? " background=none (screen take)" : " background=\(background?.id ?? "<mesh gradient>") (from: \(backgroundOrigin))"))
            publishState()
            try recorder.prepare(target: target, output: output, background: background?.url)
        } catch {
            note("failed to start recorder: \(error.localizedDescription)")
            NSSound.beep()
            resolveStart(SessionResult(ok: false, state: "idle", error: "recorder_failed"))
            endSession()
        }
    }

    private func tickCountdown() {
        countdownRemaining -= 1
        if countdownRemaining > 0 {
            pill.update(.countdown(remaining: countdownRemaining, appName: target?.label ?? ""))
        } else {
            stopTimer()
            beginRecording()
        }
    }

    private func cancelCountdown(reason: String) {
        Log.write("session", "take \(takeNumber): countdown cancelled (\(reason))")
        stopTimer()
        endSession()
    }

    // MARK: - Recording

    private func beginRecording() {
        guard preparedOutput != nil else { return endSession() }
        guard recorder.isRunning else {
            note("recorder died during the countdown")
            NSSound.beep()
            resolveStart(SessionResult(ok: false, state: "idle", error: "recorder_failed"))
            return endSession()
        }

        guard recorder.isArmed else {
            // Warm-up outran the countdown — a cold audio stack has been seen to
            // take 2.25s on its own. Waiting is the honest move: starting a
            // clock the capture can't yet honour is the whole defect.
            waitingForArm = true
            note("countdown done — waiting for capture to arm")
            let work = DispatchWorkItem { [weak self] in self?.armTimedOut() }
            armTimeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + armTimeout, execute: work)
            return
        }
        startTake()
    }

    /// Capture went live after the countdown had already finished.
    private func recorderArmed() {
        guard waitingForArm else { return }
        startTake()
    }

    private func armTimedOut() {
        guard waitingForArm else { return }
        note("capture never armed within \(Int(armTimeout))s — giving up")
        NSSound.beep()
        resolveStart(SessionResult(ok: false, state: "idle", error: "recorder_failed"))
        endSession()
    }

    /// t=0 for the recording. Everything before this is warm-up.
    private func startTake() {
        waitingForArm = false
        armTimeoutWork?.cancel()
        armTimeoutWork = nil
        guard let output = preparedOutput else { return endSession() }

        recorder.go()
        phase = .recording
        pill.update(.recording(elapsed: 0))
        startTimer(interval: 0.5) { [weak self] in self?.tickElapsed() }
        // The caller has been holding since `start` — the countdown survived and
        // capture is live, so the clock it starts now is one we can honour.
        resolveStart(SessionResult(ok: true, state: "recording", output: output))
    }

    private func tickElapsed() {
        guard phase == .recording else { return }
        pill.update(.recording(elapsed: recorder.elapsed))
    }

    private func stop(reason: String) {
        guard phase == .recording else { return }
        Log.write("session", "take \(takeNumber): stop requested (\(reason)) at \(String(format: "%.2f", recorder.elapsed))s")
        stopTimer()
        // Hold the recording pill until the recorder has actually finalized —
        // flashing "Saved" before the file is written would be a lie.
        recorder.stop()
    }

    private func recorderExited(status: Int32) {
        // Dying while it was still warming is a failed session, not a save —
        // there is no take to report.
        guard phase == .recording else {
            note("recorder \(Recorder.describeExit(status)) before the take began")
            NSSound.beep()
            return endSession()
        }
        stopTimer()
        let output = recorder.outputURL
        let elapsed = recorder.elapsed

        guard status == 0, let output, FileManager.default.fileExists(atPath: output.path) else {
            note("recorder \(Recorder.describeExit(status)) without a usable file")
            NSSound.beep()
            return endSession()
        }

        let take = takeNumber
        phase = .saved
        // Save-time is the only place history is written: every session — hotkey,
        // CLI, agent — arrives here with a file that exists on disk, and a session
        // that never got here never made one.
        RecentRecordings.shared.record(output)
        HotkeyManager.shared.unregister(.escape)
        clearRequest()

        // Ask the artifact how long it is. Reporting our own elapsed time is
        // what let a 1.8s recording announce itself as 5.2s.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let measured = await Recorder.measuredDuration(of: output)
            if measured == nil {
                note("could not read a duration from \(output.lastPathComponent) — reporting elapsed")
            }
            let duration = measured ?? elapsed
            let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? Int
            Log.write("take", "take \(take): saved \(output.path) duration=\(String(format: "%.2f", duration))s"
                + "\(measured == nil ? " (elapsed, not measured)" : "") size=\(bytes.map(String.init) ?? "?") bytes")
            self.pill.update(.saved(url: output, duration: duration))
            self.scheduleSavedDismiss()
            self.resolveStop(SessionResult(ok: true, state: "saved", output: output, duration: duration))
        }
    }

    private func scheduleSavedDismiss() {
        savedDismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismissSaved() }
        savedDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + savedLinger, execute: work)
    }

    /// The saved pill carries a click target, so it must not fade out from under
    /// a user who is reaching for it. Pointer on the pill = the clock stops; when
    /// the pointer leaves, the full linger starts over.
    private func savedHoverChanged(_ hovering: Bool) {
        guard phase == .saved else { return }
        if hovering {
            savedDismissWork?.cancel()
            savedDismissWork = nil
            pill.cancelFade()
        } else {
            scheduleSavedDismiss()
        }
    }

    private func reveal(_ url: URL) { revealInFinder(url) }

    private func dismissSaved() {
        savedDismissWork?.cancel()
        savedDismissWork = nil
        pill.fadeOut { [weak self] in
            guard let self, phase == .saved || phase == .idle else { return }
            phase = .idle
        }
        phase = .idle
    }

    // MARK: - Teardown

    /// Every exit path funnels here, so Esc can never stay hijacked past the pill
    /// — and no control-surface caller is left hanging on a session that ended.
    private func endSession() {
        stopTimer()
        waitingForArm = false
        armTimeoutWork?.cancel()
        armTimeoutWork = nil
        recorder.cancel()
        HotkeyManager.shared.unregister(.escape)
        pill.hide()
        clearRequest()
        phase = .idle
        // Whoever asked for this session learns the user ended it. This is how a
        // caller finds out its recording was overridden rather than completed.
        resolveStart(SessionResult(ok: false, state: "idle", cancelled: true, error: "cancelled"))
        resolveStop(SessionResult(ok: true, state: "idle", cancelled: true))
    }

    private func clearRequest() {
        request = .human
        target = nil
        preparedOutput = nil
        activeBackground = nil
        activePlan = nil
        publishState()
    }

    // MARK: - State file

    /// Where `state.json` goes; nil publishes nothing.
    var stateFile: StateFile? {
        didSet { publishState() }
    }

    private var activePlan: TakePlan?

    func stateSnapshot() -> [String: Any] {
        var snapshot: [String: Any] = ["phase": describe(phase), "take": takeNumber]
        if let activePlan {
            var request = activePlan.payload
            request["source"] = source.isAgent ? "agent" : "human"
            if let label = source.label { request["label"] = label }
            switch target {
            case let .window(window)?: request["windowId"] = Int(window.id); request["app"] = window.app
            case let .display(display)?: request["displayId"] = Int(display.id)
            case nil: break
            }
            snapshot["request"] = request
        }
        snapshot["next"] = TakePlan.resolve(request: .human, isDisplay: false).payload
        return snapshot
    }

    private func publishState() {
        stateFile?.publish(stateSnapshot())
    }

    /// Called on app termination (quit, logout, restart): a take in progress is
    /// finalized and saved, never discarded.
    func shutdown() {
        stopTimer()
        HotkeyManager.shared.unregister(.escape)
        guard recorder.isRunning else { return }
        let take = takeNumber
        let output = recorder.outputURL
        note("take \(take): app quitting during \(phase), finalizing")
        let status = recorder.finishBeforeExit(timeout: 10)
        guard let status else {
            return note("take \(take): recorder still finishing after 10 s; it saves on its own once the app is gone")
        }
        if status == 0, let output, FileManager.default.fileExists(atPath: output.path) {
            RecentRecordings.shared.record(output)
            Log.write("take", "take \(take): saved \(output.path) on quit")
        } else {
            note("take \(take): recorder \(Recorder.describeExit(status)) on quit")
        }
    }

    // MARK: - Timer

    private func startTimer(interval: TimeInterval, _ tick: @escaping () -> Void) {
        stopTimer()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        // .common so the countdown keeps ticking while a menu or resize loop is up.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
