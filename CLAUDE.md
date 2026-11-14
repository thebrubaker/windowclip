# Windowclip: working in this repo

Windowclip is Joel's macOS menu bar app. It records a window, or a whole display, into a finished MP4. The repo has four parts:
- the Swift app (`app/`): session state machine, picker, pill, control socket;
- the ScreenCaptureKit recorder binary (`cmd/recorder/`);
- the Bun CLI (`src/cli.ts`);
- the Claude skill (`.claude/skills/windowclip/`).

`README.md` covers what the product does and its full debug flag list. **`PLAN.md`** is the testability program in progress: read it before starting a stage of that work.

The product name is not final; Joel will rename it again. Spell new paths and identifiers through `AppSupport` (`app/Sources/AppSupport.swift`), never as a new literal "Windowclip".

## Joel's installed app is not a test bench

Joel records his published work with `/Applications/Windowclip.app` every day. In November 2026 a session-state leak quietly sent two days of his takes to the wrong place.

- **Never** quit, relaunch, replace or install over `/Applications/Windowclip.app`. The lead schedules installs with Joel.
- **Never** send anything to its control socket, `~/Library/Application Support/Windowclip/control.sock`. That rules out `windowclip status`, `stop`, `cancel` or a recording without `--headless`, and `nc -U`. A request there can start a real recording on his screen and leave state behind.
- **Never run a second instance under his bundle id** (`io.digitalpine.windowclip`). That includes `app/build/Windowclip.app` and the `--debug-*` modes of either bundle. It would take over his socket (`ControlServer.start` unlinks it), write into his `recents.json` and log, and grab Esc. A separate test identity is planned (`PLAN.md` part D). Until it lands, there is no safe second instance on the m3.
- Anything that shows a window, takes focus, sends synthetic input or raises a permission, keychain or authorization prompt needs Joel's go, routed through the lead. That includes every `--debug-show` surface.
- Reading his files is fine: the log, `recents.json`, `background.json`, the bundle's plist and its signature.

## Build

Run these from the repo root. Every `swiftc` call names `-target …-apple-macosx15.0`. Without it, swiftc silently bakes the build machine's OS in as the binary's minimum. The plist's `LSMinimumSystemVersion` is only a claim; `LC_BUILD_VERSION` is what dyld enforces.

```sh
pnpm run build:recorder
otool -l cmd/recorder/recorder | grep -A4 LC_BUILD_VERSION
git restore cmd/recorder/recorder
```

`build:recorder` compiles every file in `cmd/recorder/` (`main.swift` is the entry point; `Sizing`, `Composer`, `Writer`, `FrameSource` and `Finalize` hold the rest). `cmd/recorder/recorder` is a tracked binary. Commit it only when its source changed; otherwise restore it, as above. `app/build.sh` copies that binary into the bundle; it does not compile the recorder.

To check that the app bundle builds without Joel's signing identity (ad hoc signature):

```sh
WINDOWCLIP_SIGN_ID=- ./app/build.sh
otool -l app/build/Windowclip.app/Contents/MacOS/recorder | grep -A4 LC_BUILD_VERSION
app/build/Windowclip.app/Contents/MacOS/Windowclip --help
rm -rf app/build
```

- `--help` exits during argument parsing, before the app starts, so it is safe to run.
- **Don't launch that bundle.** It carries Joel's bundle id.
- Remove `app/build` when you're done, so LaunchServices doesn't hold a second copy of his identity.

The install build is plain `./app/build.sh`, which signs with the Developer ID in Joel's keychain. It belongs to the lead's install slot with Joel, because signing can raise a keychain prompt.

## Test

```sh
bun run test            # same as test/run.sh
```

About 80 s on the m3, all of it in fresh `/tmp` directories. There is no app, no screen capture and no prompt. It runs:
- **session** (`test/session-probe/run.sh`, about 65 s): compiles the shipping `SessionController.swift` and `Recorder.swift` against stubs and a stand-in recorder script.
- **recorder** (`test/recorder-suite/run.sh`, about 16 s): builds `cmd/recorder/*.swift` and drives the real binary, muted, on synthetic frames (`RECORDER_SOURCE=synthetic[:WxH]`). It covers size math, partial→rename, replacing a file, SIGUSR2 discard, duration, handshake and gate. Frame n carries n as a barcode; display takes reach the file unscaled, so the suite reads the first frame's number back.
- **clickzoom** only with `test/run.sh --clickzoom` (or `bun run test:clickzoom`). It renders video through Remotion, so run it on stella or legion-tower, not the m3.

Each part takes a tree argument, so a comparison can run the same suite on another commit. Run the suite before and after any `SessionController`, `Recorder` or `cmd/recorder` change.

**Known failures** print `XFAIL` and don't fail the suite. When a fix makes one pass it prints `XPASS` and fails the suite until the mark is removed.

Every comparison needs a positive control. The session suite must **fail** on `3fe3170`, the tree with the DIG-2652 leak:

```sh
rm -rf /tmp/wc-3fe3170 && mkdir /tmp/wc-3fe3170
git archive 3fe3170 app cmd | tar -x -C /tmp/wc-3fe3170
test/session-probe/run.sh /tmp/wc-3fe3170 || echo "failed, as it must"
rm -rf /tmp/wc-3fe3170
```

The recorder suite must fail "partial renamed" on a copy of `cmd/recorder` whose `Finalize.swift` skips the `rename` (`guard true else {`); pass the copy's parent as the tree.

Recordings are lossy, so compare output by PSNR against an A/A floor, never at zero. On the m3, 2 s synthetic window takes read 35.8-42.3 dB against each other, and a 0.5% padding change reads 27.4 dB.

## Debug

The app writes one line per take saying where its output and background came from (`from: request|default|saved`), plus every phase change, control request and recorder stderr line:

```sh
bun run src/cli.ts log -n 20
```

That reads `~/Library/Logs/Windowclip/windowclip.log`; the status menu's Reveal Log opens the same file. For anything before a log line existed, the unified log gives per-pid lifetimes:

```sh
/usr/bin/log show --style compact --last 30m --predicate 'process == "Windowclip" OR process == "recorder"' | tail -40
```

What the installed app is, read-only:

```sh
plutil -p /Applications/Windowclip.app/Contents/Info.plist | grep -E 'CFBundleIdentifier|CFBundleShortVersionString|CFBundleVersion'
codesign -dr - /Applications/Windowclip.app
otool -l /Applications/Windowclip.app/Contents/MacOS/recorder | grep -A4 LC_BUILD_VERSION
pgrep -lx Windowclip
sqlite3 -readonly "/Library/Application Support/com.apple.TCC/TCC.db" "select service, client, auth_value from access where client like 'io.digitalpine.%'"
```

The TCC read needs Full Disk Access, which cmux has. `auth_value` 2 means allowed.

## Identity and TCC

- Grants follow the **bundle id plus the signing identity.** A Developer ID build that keeps the same bundle id keeps its grants across rebuilds. Ad hoc signing, or a new bundle id, means asking for every permission again.
- Running `Windowclip.app/Contents/MacOS/Windowclip`, or the recorder, from a shell makes the terminal the responsible process. TCC then checks the **terminal's** grants. So a take that worked from a shell proves nothing about the app's own grant, and a recording started over plain ssh is refused.
- `HOME=/tmp/x` does **not** move `~/Library/Application Support` (measured 2026-11-13). Instances can only be kept apart by name.
- The process name is `Windowclip`. The recorder runs as `recorder`, a child of the app, with handshake lines on its stdout.

## Traps

- **A stray `.build/` after a commit** comes from Joel's global hook `~/.git-hooks/prepare-commit-msg`, which runs `swift package --build-path .build/lefthook …`. It is gitignored.
- **In zsh, `log` is a builtin.** A bare `log show …` fails with "too many arguments", so call `/usr/bin/log`. And `process == "Windowclip"` also matches any copy of the binary run from a shell (an ad hoc build's `--help` shows up there), so tell instances apart by pid.
- **`RECORDER_BG_IMAGE` only works on the `--headless` route.** App takes get their background from `SessionController`, and the app's `Recorder.prepare` overwrites that variable.
- **Run any recording from your own shell muted.** It needs a brief that allows it. Set `RECORDER_NO_AUDIO=1`, and remember the CLI also plays sounds through `afplay`. Write only under a fresh `/tmp` directory and delete it afterwards: the file holds whatever was on Joel's screen.
- **The recorder writes `.<name>.partial-<pid>.mp4`** beside the output and renames it into place only on success. SIGUSR2 discards the take. Keep that contract: no code path deletes a file at the output path.
- **The recorder's exit codes:** 0 saved, 1 failed, 2 discarded (SIGUSR2), 3 stopped before its first frame (nothing written), 64 usage. If its parent dies, it saves the take, so a stray recorder from a killed shell keeps recording until it gets a SIGTERM or the disk falls under 2 GB free. Look before you kill it: by literal pid, SIGTERM saves it.
- **A recorder whose output is piped to a reader that exits** used to die by SIGPIPE before saving. It now ignores SIGPIPE and writes through `write(2)`. Keep `FileHandle.standardError.write` out of `cmd/recorder`: it raises on a closed pipe.
