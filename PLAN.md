# Testability program: plan and status

The goal: **an app agents can debug and test without ever touching Joel's installed instance, and one that tells anyone what it's about to do.** Joel approved the program as a package (2026-11-13). Every part below serves that goal. If a part stops serving it, say so instead of building it.

The plan was approved 2026-11-13 and the rulings are folded in. **Each stage ends by updating this file**, so a fresh engineer can pick up any stage from here and the code. Read `CLAUDE.md` first.

Why it exists: in November 2026 a session-state leak silently sent two days of Joel's takes to the wrong place and background (DIG-2652, fixed in `be84e94`). Nothing on screen showed it, and the only way to test the app was against his real copy.

## Status

| Stage | Part | State | Commit |
|---|---|---|---|
| A | 6 CLAUDE.md v1, `.gitignore`, this plan | done | see `git log -- PLAN.md` |
| B | 4 test suite (DIG-2650) | not started | |
| C | 5 recorder fixes (DIG-2653 and two more) | not started | |
| D | 2 test identity | not started | |
| E | 1 doctor | not started | |
| F | 3 stella | not started | |
| — | memory stage | not started | |

Branch `feat/testability`, made from `origin/main` at `41fbb12`. The lead grants one stage at a time.

## Rulings (the lead's, 2026-11-13; Joel has been told and can overrule)

1. Quitting, logging out or restarting during a take **saves** the take. This is fixed in part 5.
2. `--doctor` may run against Joel's installed app once his build has it. It's a read-only process that never touches the socket and writes nothing. A run that does anything else breaks the rail.
3. **No microphone on stella.** The dev identity skips the mic gate there. Room audio in Joel's house is out.
4. **No whole-display takes on stella.** Its screen shows Stella's iMessage threads, so takes there record the test card window only. Display-path coverage comes from synthetic frames, plus an occasional take on the m3 when the lead schedules one.
5. **No hotkey for the dev identity.** Drive it through the dev socket commands.
6. An env-gated synthetic frame source inside the shipping recorder is allowed.
7. The recorder keeps a 2 GB free-disk floor, and **saves** the take when its parent dies.
8. The lead installs builds with Joel. His CLI link is DIG-2648, outside this program.
9. Left out on purpose: SwiftPM, XCTest, CI, notarizing the dev build, and any Accessibility grant on stella. Tests are plain `swiftc`.
- The test card instrument is approved, to be built as part of F.
- The dev app is **not** launched on the m3 unless the lead schedules it with Joel. It runs on stella only.

## Facts found while planning (verified 2026-11-13)

- **Quit discards a live take today.** The path is `applicationWillTerminate` → `SessionController.shutdown()` → `Recorder.cancel()` → SIGUSR2, and the recorder deletes its partial file. This is fixed in C under ruling 1.
- **A second instance touches more than the socket.**
  - `ControlServer.start` unlinks `control.sock` without checking whether another instance is still listening.
  - The prod bundle's debug modes write to Joel's real state: `--debug-record` records into `recents.json`, every `note()` writes to his log, and a pill grabs Esc.
- **`HOME=/tmp/x` does not move Application Support.** `FileManager.urls(.applicationSupportDirectory)` and `NSHomeDirectory()` both still return `/Users/joel/...`. Instances can only be kept apart by name.
- **Stopping the recorder before it writes a frame aborts it.**
  - A SIGTERM or SIGINT (or the 60 s watchdog) before the first written frame reaches `videoInput.markAsFinished()` while the writer status is 0. AVFoundation raises an exception and the recorder aborts with exit 134. That includes handshake mode, armed but before `go`.
  - Related: if `writer.startWriting()` fails, every later frame retries it on the failed writer (`ensureSession`).
- **The display size box is stricter than the encoder.** Recordings are fitted within 3840×2160 (`DISPLAY_MAX_W/H`). The measured encoder boundary (4096×2304 accepted, 4480×2520 refused) fits H.264 level 5.2's frame-size limit of 36,864 macroblocks; 4096×2304 is exactly 36,864. This is a hypothesis, to be measured in C.
- **The stray `.build/` comes from Joel's global git hook.** `~/.git-hooks/prepare-commit-msg` runs `swift package --build-path .build/lefthook …`.
- **The toolchain.**
  - m3: Xcode, SDK 27.2, Swift 6.4.2.
  - `swiftc -target x86_64-apple-macosx15.0` builds both the recorder and the app on the m3, so stella builds are compiled and signed on the m3 with the Developer ID.
  - stella: x86_64, macOS 26.7.3, user `stella` at the console, a 3072×1920 built-in panel, `~/.bun/bin/bun`, `/usr/local/bin/ffmpeg`, no `rg`. Display sleep is held off by an existing `caffeinate`.
- **The name is spelled twice:** `AppSupport.name` in the app and `APP_NAME` in `src/cli.ts`. The CLI also keeps its own copy of the background-choice logic.

## Order

A (6) → B (4) → C (5) → D (2) → E (1) → F (3) → memory.

B is the safety net for everything after it and builds the instrument C and E are proven with. C goes before D because DIG-2653 cuts Joel's long takes today.

## Parts

### A. Part 6: CLAUDE.md and `.gitignore`
- `CLAUDE.md` covers building, testing and debugging, identity and TCC, the rail against touching Joel's installed app, and traps. `.gitignore` gains `.build/`.
- Proof: every command `CLAUDE.md` lists is run exactly as written. Exceptions are named in the stage report.
- Later stages add their section to `CLAUDE.md`.

### B. Part 4: the test suite (DIG-2650)
- **One command:** `test/run.sh`, wired to `bun run test`. It runs:
  - the session suite: probes A and B folded in, still compiling the shipping `SessionController.swift` and `Recorder.swift` unchanged against stubs;
  - the recorder suite;
  - the existing TS Clickzoom test, which renders video. Decide in B whether that one runs by default or behind a flag on stella.
- **The recorder suite** drives the **real recorder binary** on synthetic frames (`RECORDER_SOURCE=synthetic[:WxH]`, ruling 6). That runs the real Composer, AVAssetWriter, gate, handshake, signals and partial→rename path, with no ScreenCaptureKit and no TCC, in a fresh `/tmp` directory.
- **It covers:**
  - partial→rename;
  - a SIGUSR2 discard that leaves an existing file alone;
  - the handshake lines and the gate;
  - a fixed duration measured from the file;
  - stop before the first frame, recorded as a known failing case until C.
- **Shape:** `cmd/recorder/` is split into `main.swift` (the entry point) and a few files: size math, frame source, finalize. `build:recorder` and `app/build.sh` then compile `cmd/recorder/*.swift`.
- **Positive controls:**
  - the session suite run on `git archive 3fe3170` must fail;
  - a recorder built with the rename removed must fail "partial renamed";
  - durations get an A/A noise floor first (the same synthetic take run 5 times), and the tolerance comes from that.
- Rung: the regression suite.

### C. Part 5: recorder fixes
- **The 5:00 cap goes** (DIG-2653). Two things replace its protection:
  1. **The recorder watches its parent** with kqueue NOTE_EXIT on the parent pid read at start, and refuses to start if that pid is already 1. When the parent dies, it **finalizes and saves** (ruling 7).
  2. **A 2 GB free-disk floor** on the output volume. When it trips, the recorder finalizes. An env knob lets the suite trip it.
  - Both also protect the CLI's `--headless` route, where bun is the parent.
- **Stop before the writer starts:** cancel, remove the partial, and exit 3 ("no frames"), with no abort and no `.ips` crash report. A `startWriting` failure stops the take once, with a clear message.
- **App:**
  - Quit, logout or restart during a take **finalizes and saves** it (ruling 1).
  - Exit 3 maps to a clear log line.
- **Size box:** fit by the 36,864-macroblock area rule, check the size at setup with a VTCompressionSession, and step down to the 3840×2160 box if it's refused. The step-down is there because stella's Intel encoder may have different limits.
- **Files:**
  - `cmd/recorder/*`;
  - in `app/Sources/`: `SessionController.swift` (the terminate path), `AppDelegate.swift`, `Recorder.swift` (header comment);
  - every mention of the cap in docs and help: `README.md:501`, `src/cli.ts:318`, `.claude/skills/windowclip/SKILL.md:165`.
- **Proof:**
  - Each fix goes red, then green, in the suite:
    - the parent killed with SIGKILL → the file is saved;
    - the disk floor trips;
    - stop during warm-up → exit 3 and no partial.
  - An encoder size grid through the real AVAssetWriter, on synthetic frames, on both the m3 and stella.
  - A synthetic take past 300 s, run on stella.
- Rungs: the suite and the grid. Native 5K at 4096×2304 from a real display needs a gated take on the m3; until then that claim stays on the synthetic rung.

### D. Part 2: test identity
- **One source of identity.** `app/identity.json` lists prod (`io.digitalpine.windowclip`, "Windowclip") and dev (`io.digitalpine.windowclip.dev`, "Windowclip Dev"). It's the only place the product name lives (the rename is still open).
  - `app/build.sh --dev [--arch x86_64]` writes the bundle id, name, support-folder name and build sha into Info.plist with `plutil`.
  - `AppSupport` reads the support name from the bundle. **Only the prod bundle id maps to prod paths.** No bundle id, or an unknown one, gets dev paths, so probes and raw binaries can never reach Joel's folders.
  - The CLI reads the same json and takes `--dev` / `WINDOWCLIP_IDENTITY=dev`.
- **The dev identity has:**
  - **no hotkey** (ruling 5) and no mic gate (ruling 3);
  - its own status item title;
  - a Log subsystem equal to its bundle id;
  - separate `UserDefaults` (automatic, by bundle id);
  - separate recents, backgrounds and socket, through AppSupport.
- `ControlServer.start` connects first, and refuses to take over a socket that answers.
- **Dev-only socket commands:** `toggle` and `pick <windowId>` call the same entry points as ⌥⌘R and the picker. They follow the `escape` precedent, so no Accessibility grant is needed. The prod build doesn't answer them.
- The future settings window plugs into the same take resolver as E (save location, backgrounds, mic, shortcut).
- **Files:**
  - in `app/Sources/`: `AppSupport.swift`, `Log.swift`, `HotkeyManager.swift`, `AppDelegate.swift`, `ControlServer.swift`;
  - `app/build.sh`, `app/Resources/Info.plist`, `app/identity.json`, `src/cli.ts`.
- **Proof:**
  - suite tests of the path mapping (prod, dev and no bundle id);
  - both bundles built and compared with `plutil -p` and `codesign -dr -`;
  - on stella (in F), a live dev app holding its own socket and folders.
- The dev app is not launched on the m3.

### E. Part 1: doctor ("What will the next recording do?")
- **The app publishes `state.json`** (written atomically, in its own support folder) at launch and on every phase or request change. It holds:
  - pid, version, build sha, bundle id, binary paths;
  - phase and take number;
  - any request in flight (source, output, background, each with `from: request|default|saved`);
  - **the next take's** resolution, with origins;
  - the app's own permission view: preflight now and at launch, plus AVCaptureDevice status;
  - whether the hotkey registered and whether the socket is listening.
- **One resolver.** `TakePlan.resolve(request:)` is pulled out of `prepareRecorder`, so a take and the report can't drift apart.
- **`Windowclip --doctor`** parses its arguments and exits **before** `NSApplication` starts. It writes nothing, never calls `note()`, and never opens the socket (ruling 2). It reads the target identity's `state.json`, recents, `background.json` and the log tail. It also checks:
  - pid liveness and process name, to flag a stale state file;
  - the bundled recorder: arch, `LC_BUILD_VERSION`, signing team, sha, `recorder --version`;
  - TCC.db rows, read-only, when readable.
- **`windowclip doctor`** in the CLI runs the installed app's `--doctor`.
  - Builds older than E don't have `--doctor`: their arg parser exits 64 before the app starts (`app/Sources/main.swift`), so trying it is harmless.
  - For those builds the CLI falls back to files only, takes the phase from the last `take N: X → Y` log line, and labels the result as predicted.
- **Files:**
  - new `app/Sources/StateFile.swift` and `app/Sources/Doctor.swift`;
  - edits to `app/Sources/SessionController.swift`, `app/Sources/main.swift`, `src/cli.ts`.
- **Proof:**
  - the suite asserts `state.json` after each transition;
  - a stale-state fixture must be flagged;
  - a run against Joel's live app adds no line to his log and changes no file mtimes, before against after. The positive control is that the same check catches a deliberate append in a fixture directory.

### F. Part 3: stella
- **`tools/stella.sh`:**
  1. builds `--dev --arch x86_64` on the m3 and signs it with the Developer ID;
  2. copies it to stella's `~/Applications/Windowclip Dev.app` with rsync, which sets no quarantine;
  3. launches it with `ssh stella open -a …`, so it runs in the GUI session as its own responsible process;
  4. drives takes through the dev socket;
  5. pulls back frames and durations.
- **The test card** (`cmd/testcard`): a window showing a frame counter and timestamp. It's the **only** thing recorded on stella (ruling 4), and it makes frame-exact checks possible.
- Takes run muted (`open --env RECORDER_NO_AUDIO=1`, ruling 3) and write to a fresh `/tmp` directory on stella, deleted when the stage ends.
- **Never touch** Messages, `stella-send` or focuskit.
- **Proof:** real recordings of the test card with frames read back, covering pill, picker (through `toggle` and `pick`), countdown, saved file and duration. The pill and picker surfaces come from the app's own `--debug-capture`, under the dev app's grant.
- Rung: a real recording whose frames were watched.

**Joel's one-time step on stella** (the lead schedules it; about 2 minutes at stella's keyboard or over Screen Sharing):
- **When:** right after F's first build has been copied and launched, so the dev app's setup window is up.
- **What:** click Allow for Screen Recording, turn on the toggle in System Settings, then press the window's Relaunch button. Nothing else: no microphone (ruling 3) and no Accessibility.
- **It lasts** across every rebuild, as long as the bundle id and the Developer ID stay the same.
- **It may recur:** macOS 15+ shows a periodic "continue to allow" alert to screen-capturing apps. Predict it from `~/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist` and warn the lead before it's due.

## Open measurements (not decisions)
- Whether Carbon `RegisterEventHotKey` for the same combination conflicts across processes. It matters less now that dev has no hotkey.
- The encoder ceilings on stella's Intel encoder, measured in C.
- Whether ScreenCaptureKit delivers frames on stella while the display sleeps. Today a `caffeinate` holds it awake.

## Stage log
- **A (2026-11-13):** wrote this plan, `CLAUDE.md` v1, and added `.build/` to `.gitignore`. Baseline: `test/session-probe/run.sh` passes all 11 checks on 41fbb12 (about 65 s).
