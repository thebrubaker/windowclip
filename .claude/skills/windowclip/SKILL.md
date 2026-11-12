---
name: windowclip
description: Record a polished MP4 of a single macOS window — gradient background, drop shadow, mic audio — driven from a Claude chat. Use when Joel says things like "let's record a video of this", "make a clip", "demo this in a recording".
---

# windowclip — Claude-driven recording flow

You are the conversational front end for this tool. The CLI exposes the primitives;
you compose them around `AskUserQuestion` and short foreground bash calls.

**Recordings run inside the Windowclip app, not inside your bash task.** You ask
the app to record; the app puts a pill on Joel's screen, counts down, captures, and
finalizes. This matters for three reasons:

1. Joel can always **see** that a recording is happening, and who asked for it.
2. Joel can always **kill** it — `esc`, the pill's Stop button, or `⌥⌘R` — and his
   controls outrank yours.
3. The recording permissions live on the app's signed identity, not on whatever
   terminal you happen to be running in. Nothing to re-grant, no black frames.

The app auto-launches if it isn't running. You don't manage its lifecycle.

## When to use this skill

Joel says something like:
- "let's make a video / clip / recording of this"
- "record what we just built"
- "demo this in a short clip"
- "I want to share this — record it"

Or you proactively suggest it when something demoable just landed.

## The canonical flow

### 1. Identify the target window

```bash
cd ~/Code/stage-studio && bun run src/cli.ts list-windows
```

Returns a JSON array of every on-screen window: `windowId`, `app`, `title`, `bounds`.

**Pick contextually if the target is obvious.** If you've been talking about "the
Onlook calendar in Chrome" and exactly one Chrome window has "Calendar" in the
title, that's the answer — take it without asking.

**Ask if ambiguous.** `AskUserQuestion` with up to 4 candidates ("Other" is added
for you), labelled by app + short title:

```
Question: "Which window should I record?"
Options:
  - Linear — DIG-228
  - Chrome — onbook
  - Slack — #d-dev
  - Cursor — windowclip
```

Hold onto the chosen `windowId`.

### 2. Pick an output path

Default to `~/Code/stage-studio/out/<slug>-<YYYYMMDD-HHMMSS>.mp4`, where `<slug>`
describes what's being recorded. Don't ask — Joel doesn't care about the path, and
a sensible default keeps the exchange conversational. He'll say if he wants it
somewhere specific.

### 3. Start the recording (open-ended)

```bash
cd ~/Code/stage-studio && bun run src/cli.ts \
  --duration 0 \
  --window-id <CGWindowID> \
  --output <output-path>
```

**Run this in the foreground.** It is not a long-lived process — it returns as soon
as the outcome is real, because the app answers honestly rather than optimistically:

- **exit 0**, `[windowclip] recording → <path>` — the countdown survived and
  capture is genuinely underway. Only now may you tell Joel it's recording.
- **exit 4**, `cancelled during the countdown` — Joel hit `esc` in the 3-second
  veto window. Nothing was recorded and no file exists. Don't retry unless he asks;
  he just said no.
- **exit 3**, `busy: a <state> session is already running` — something else owns
  the pill. Never queue and never preempt. Tell Joel and let him decide.
- **exit 1** — anything else (window vanished, app wouldn't launch). Read the message.

What Joel sees while this runs: a pill at the bottom of the screen, ringed in violet
with **"Claude · Recording <App>…"** and a 3·2·1 countdown, then **"Claude · 0:07"**
with a red dot and a Stop button. The violet ring and the "Claude ·" credit are how
an agent-started recording announces itself — a human-started one has neither. The
dot is red either way: red means "capturing right now", whoever asked.

Then confirm briefly:

> Recording **Linear — DIG-228**. Say "stop" when you're done.

### 4. Stop when Joel says so

"stop", "done", "that's it", "cut" — or any message that means the demo is over:

```bash
cd ~/Code/stage-studio && bun run src/cli.ts stop
```

- **exit 0**, `saved <path> (12.4s)` — the app held on until the recorder actually
  finalized the MP4, so the file exists by the time this returns.
- **exit 4**, `stopped by hand — no file written` — the session ended before capture
  began (Joel cancelled during the countdown). Nothing to show.
- **exit 1**, `stop failed: not_recording` — **do not report this as a failed
  recording.** It usually means Joel already ended the session himself with `esc` /
  Stop / `⌥⌘R` while you were waiting. Run `status` before saying anything:

```bash
cd ~/Code/stage-studio && bun run src/cli.ts status
```

`{"state":"saved","output":"…"}` means his stop finalized the file normally —
surface that path as the result. `{"state":"idle"}` **with** an `output` means the
same thing a few seconds later, after the saved pill faded. `{"state":"idle"}` with
**no** `output` means the session was cancelled and no file was written. A cancel
deletes the partial file and clears the path, so an `output` that's present is a
file that's really there — but if it matters, `ls` it.

### 5. Surface the result

Tell Joel where it landed and offer the obvious next step:

> Done. `out/dig228-20260728-153012.mp4` (12s). Want me to open it?

The pill also shows `Saved ✓ <file> · <duration>` for a few seconds, and the
filename in it is clickable — it reveals the recording in Finder.

## Other commands

```bash
bun run src/cli.ts status     # what the app is doing, as JSON
bun run src/cli.ts cancel     # abort and delete the partial file — nothing kept
bun run src/cli.ts stop       # stop and keep the file
```

`cancel` is the right verb when the take was bad and Joel wants it gone; `stop`
keeps what was captured. Both exit 2 if the app isn't running.

Useful flags: `--duration <s>` records for a fixed number of seconds and stops
itself (default 8); `--window <pattern>` matches on app+title instead of an exact
id; `--label <name>` changes who the pill credits.

## Important constraints

- **Joel's controls always win.** `esc`, the pill's Stop button, and `⌥⌘R` end any
  session, including one you started. That's the whole point of routing through the
  app — never work around it, never treat his stop as an error to retry through.
- **Never two at once.** If a session is live, a second start returns busy (exit 3).
  Don't queue it, don't stop his session to make room for yours.
- **The countdown is a veto, not a delay.** Every recording gets 3 seconds where
  `esc` kills it before a single frame is captured. Don't look for a way to skip it.
- **5-minute hard cap.** The recorder stops itself at 5 minutes so a forgotten
  recording can't fill the disk.
- **No pause.** Stop, set up, record again.
- **Don't kill the bash task to stop a recording.** The recording isn't running in
  your task — it's in the app. `windowclip stop` is the stop.

## `--headless` — the fallback, not the default

`--headless` bypasses the app and spawns the recorder directly, the way this tool
worked before the app existed. No pill, no countdown, no way for Joel to see or stop
it — so use it only where there's no GUI session to show a pill in (CI, a remote
shell). In that mode the CLI prints `[windowclip] recorder PID: <pid>` and you
stop the recording with `kill -TERM <pid>`.

It also means the recording runs under *your terminal's* identity, so it needs
Screen Recording / Microphone granted to that terminal — the permissions the
app-routed path exists to stop worrying about.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `Windowclip isn't installed at /Applications/Windowclip.app` | Build + install it: `pnpm run build:app && ditto "app/build/Windowclip.app" "/Applications/Windowclip.app"` |
| `Windowclip did not come up within 15s` | Launch it by hand and check stderr; if `⌥⌘R` is taken by another app it says so |
| exit 3 busy, but nothing is on screen | `status` shows the real state; `cancel` clears a stuck session |
| Blank/black video, or no audio (headless only) | Screen Recording / Microphone missing on the *terminal*. The app-routed path doesn't have this problem |

## What this skill does NOT cover

- **Editing.** The recording is the deliverable. Don't propose trims or transitions.
- **Multiple windows.** One window at a time.
- **Choosing the background.** Joel picks it in the app's menu (Background ▸), and every
  recording uses it. Don't ask him to pick. When he names a different one for a single
  recording, pass `--background <name>`; `windowclip backgrounds` lists the names.

## File reference

- `src/cli.ts` — Bun CLI. Talks to the app over a Unix socket; `--headless` keeps
  the old direct-spawn path.
- `app/Sources/ControlServer.swift` — the socket (`~/Library/Application Support/
  Windowclip/control.sock`, 0600, one JSON request per connection).
- `app/Sources/SessionController.swift` — countdown → record → save state machine,
  and the honest-answer semantics behind the exit codes above.
- `cmd/windows/windows` — window enumeration (`list`, `frontmost`, `find <pattern>`).
- `cmd/recorder/recorder` — SCK + Core Image + AVAssetWriter capture pipeline.
- `README.md` — architecture; `SHAPE-ui.md` — why Claude is the UI.
