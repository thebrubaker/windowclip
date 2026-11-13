#!/usr/bin/env bun
// windowclip — record screen + clicks + mic, render polished MP4 with auto-zoom on each click.
//
// Phase 2: ugly end-to-end with a small set of CLI flags. Hardcodes a few things still:
//   - output resolution 2560x1440 (matches CGEventTap point space on a 5K display)
//   - capture cursor on
//   - h264_videotoolbox encoder
//   - no display picker; uses whatever `Capture screen 0` is today

import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { connect } from "node:net";
import { homedir } from "node:os";
import { resolve, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "..");
const CLICKS_BIN = resolve(REPO_ROOT, "cmd/clicks/clicks");
const WINDOWS_BIN = resolve(REPO_ROOT, "cmd/windows/windows");
const RECORDER_BIN = resolve(REPO_ROOT, "cmd/recorder/recorder");

const FPS = 30;

// ---------------------------------------------------------------------------
// Control surface — talking to the running Windowclip app (DIG-793)
//
// Recording routes through the app by default so that EVERY recording, however
// it was started, puts the pill on screen. That visibility is the point: an
// agent-initiated capture the user can't see and can't kill is not something
// that should be possible.
//
// The old direct-spawn path still exists behind --headless for contexts with no
// GUI session to talk to.
// ---------------------------------------------------------------------------

const APP_NAME = "Windowclip";
const APP_PATH = `/Applications/${APP_NAME}.app`;
const APP_SUPPORT = resolve(homedir(), "Library/Application Support", APP_NAME);
const LOG_FILE = resolve(homedir(), "Library/Logs", APP_NAME, `${APP_NAME.toLowerCase()}.log`);
const CONTROL_SOCKET = resolve(APP_SUPPORT, "control.sock");

type ControlResponse = {
  ok: boolean;
  state?: string;
  output?: string;
  duration?: number;
  cancelled?: boolean;
  error?: string;
  message?: string;
  [key: string]: unknown;
};

/** One request, one response, connection closes. */
function control(payload: Record<string, unknown>, timeoutMs = 15 * 60_000): Promise<ControlResponse> {
  return new Promise((resolveP, reject) => {
    const sock = connect({ path: CONTROL_SOCKET });
    let buf = "";
    const timer = setTimeout(() => {
      sock.destroy();
      reject(new Error(`control timeout after ${timeoutMs}ms`));
    }, timeoutMs);
    sock.on("connect", () => sock.write(JSON.stringify(payload) + "\n"));
    sock.on("data", (d) => (buf += d.toString()));
    sock.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
    sock.on("close", () => {
      clearTimeout(timer);
      const text = buf.trim();
      if (!text) return reject(new Error("control closed without a response"));
      try {
        resolveP(JSON.parse(text) as ControlResponse);
      } catch {
        reject(new Error(`unparseable control response: ${text}`));
      }
    });
  });
}

async function appIsUp(): Promise<boolean> {
  if (!existsSync(CONTROL_SOCKET)) return false;
  try {
    const res = await control({ command: "ping" }, 2000);
    return res.ok === true;
  } catch {
    // A socket file left behind by a crashed instance looks present but refuses
    // connections — treat that as "not running" rather than a hard failure.
    return false;
  }
}

/** Bring the app up if it isn't already, and wait until it answers. */
async function ensureApp(): Promise<void> {
  if (await appIsUp()) return;
  if (!existsSync(APP_PATH)) {
    throw new Error(
      `Windowclip isn't installed at ${APP_PATH}. Build and install it with ` +
        `\`pnpm run build:app\`, or use --headless to bypass the app entirely.`,
    );
  }
  console.error(`[windowclip] launching ${basename(APP_PATH)}…`);
  spawn("open", ["-a", APP_PATH], { stdio: "ignore", detached: true }).unref();

  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 300));
    if (await appIsUp()) return;
  }
  throw new Error("Windowclip did not come up within 15s");
}

// ---------------------------------------------------------------------------
// Saved backgrounds (DIG-2643). The app owns the menu and the choice; this is
// the same folder and file read from disk, so --headless and `backgrounds`
// work with the app down. Twin of app/Sources/Backgrounds.swift.
// ---------------------------------------------------------------------------

const BACKGROUNDS_DIR = resolve(APP_SUPPORT, "Backgrounds");
const BACKGROUND_CHOICE = resolve(APP_SUPPORT, "background.json");
const DEFAULT_BACKGROUND = resolve(REPO_ROOT, "assets/big-sur-graphic.jpg");
const IMAGE_EXTENSIONS = new Set(["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp"]);

type SavedBackground = { id: string; name: string; group?: string; path: string };

const byName = (a: { name: string }, b: { name: string }) =>
  a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" });

function imageEntry(dir: string, file: string, group?: string): SavedBackground | null {
  const dot = file.lastIndexOf(".");
  if (dot <= 0 || !IMAGE_EXTENSIONS.has(file.slice(dot + 1).toLowerCase())) return null;
  return { id: group ? `${group}/${file}` : file, name: file.slice(0, dot), group, path: resolve(dir, file) };
}

function savedBackgrounds(): SavedBackground[] {
  if (!existsSync(BACKGROUNDS_DIR)) return [];
  const loose: SavedBackground[] = [];
  const groups: { name: string; items: SavedBackground[] }[] = [];
  for (const entry of readdirSync(BACKGROUNDS_DIR)) {
    if (entry.startsWith(".")) continue;
    const full = resolve(BACKGROUNDS_DIR, entry);
    if (statSync(full).isDirectory()) {
      const items = readdirSync(full)
        .filter((f) => !f.startsWith("."))
        .map((f) => imageEntry(full, f, entry))
        .filter((b): b is SavedBackground => b !== null && statSync(b.path).isFile());
      groups.push({ name: entry, items: items.sort(byName) });
    } else {
      const item = imageEntry(BACKGROUNDS_DIR, entry);
      if (item) loose.push(item);
    }
  }
  return [...loose.sort(byName), ...groups.sort(byName).flatMap((g) => g.items)];
}

/** The choice made in the app's menu, if it still points at a file. */
function chosenBackground(): SavedBackground | null {
  if (!existsSync(BACKGROUND_CHOICE)) return null;
  try {
    const { selected } = JSON.parse(readFileSync(BACKGROUND_CHOICE, "utf8")) as { selected?: string };
    return savedBackgrounds().find((b) => b.id === selected) ?? null;
  } catch {
    return null;
  }
}

/** Same order as the app: `default`, a saved id, a saved name, then a path to an image. */
function resolveBackground(request: string): string | null {
  if (request === "default") return existsSync(DEFAULT_BACKGROUND) ? DEFAULT_BACKGROUND : "";
  const saved = savedBackgrounds();
  const lower = request.toLowerCase();
  const match =
    saved.find((b) => b.id === request) ??
    saved.find((b) => b.name.toLowerCase() === lower || basename(b.path).toLowerCase() === lower);
  if (match) return match.path;
  const path = resolve(request.replace(/^~(?=\/)/, homedir()));
  const ext = path.slice(path.lastIndexOf(".") + 1).toLowerCase();
  return IMAGE_EXTENSIONS.has(ext) && existsSync(path) && statSync(path).isFile() ? path : null;
}

function printBackgrounds() {
  const current = chosenBackground();
  const items = [
    { id: "default", name: "Big Sur", path: DEFAULT_BACKGROUND },
    ...savedBackgrounds(),
  ].map((b) => ({ ...b, current: b.id === (current?.id ?? "default") }));
  console.log(JSON.stringify({ current: current?.id ?? "default", folder: BACKGROUNDS_DIR, items }, null, 2));
}

function unknownBackground(request: string): never {
  console.error(
    `[windowclip] no saved background or image file matches "${request}". ` +
      `\`windowclip backgrounds\` lists the saved ones.`,
  );
  process.exit(1);
}

// Exponential smoothing time constant for cursor → camera. Camera position lags
// cursor with a ~tau half-life; smaller tau = snappier follow, larger = floatier.
// 0.18s feels close to Screen Studio's default.
const CURSOR_SMOOTH_TAU = 0.18;

// v1.3 dwell-commit: a click only triggers a zoom event if the cursor stays
// within DWELL_RADIUS_PX of the click coord for the first DWELL_WINDOW_S
// seconds after the click. Filters out "transit clicks" — click + immediately
// move far away — which would otherwise yank the camera to a place the user
// has already left.
//
// 250 source pixels at backingScale=2 ≈ 125 logical points. About a button's
// width on macOS. Tune by observation.
const DWELL_WINDOW_S = 0.3;
const DWELL_RADIUS_PX = 250;

type Args = {
  duration: number; // seconds
  output?: string;
  workDir: string;
  skipRecord: boolean; // dev shortcut: reuse last recording
  /** Window picker target. If unset, use frontmost-non-self. */
  window?: string;
  /** Specific CGWindowID to record. Preferred over --window when Claude pipes
   *  an exact id from `cmd/windows list`. Skips the fuzzy-match path entirely. */
  windowId?: number;
  /** Record a whole display instead: a CGDirectDisplayID from `list-displays`,
   *  or `main`. No background, padding or shadow. */
  display?: string;
  /** `windowclip list-displays`: print connected displays as JSON and exit. */
  listDisplays: boolean;
  /** Subcommand short-circuit: print all on-screen windows as JSON and exit.
   *  Intended for the /stage skill — gives it a window picker without depending
   *  on the bundled cmd/windows binary path. */
  listWindows: boolean;
  /** Bypass the app and spawn the recorder directly (the pre-DIG-793 path).
   *  For contexts with no GUI session to show a pill in. */
  headless: boolean;
  /** Who the pill says started this. */
  label: string;
  /** `agent` (default for CLI-driven recordings) or `human`. */
  source: "agent" | "human";
  /** Control subcommand, if the invocation was one. */
  controlCommand?: "stop" | "cancel" | "status";
  /** `windowclip backgrounds`: list the saved backgrounds and exit. */
  listBackgrounds: boolean;
  /** This recording only: a saved background's name or id, `default`, or an image path. */
  background?: string;
};

function parseArgs(argv: string[]): Args {
  const args: Args = {
    duration: 8,
    workDir: resolve(REPO_ROOT, "out"),
    skipRecord: false,
    listWindows: false,
    headless: false,
    label: "Claude",
    source: "agent",
    listBackgrounds: false,
    listDisplays: false,
  };
  // Control subcommands: `windowclip stop|cancel|status`.
  if (argv[0] === "stop" || argv[0] === "cancel" || argv[0] === "status") {
    args.controlCommand = argv[0];
    return args;
  }
  // Accept `windowclip list-windows` as a bare subcommand (no leading dashes).
  // Strictly positional: it has to be the first arg. Anything else falls through
  // to the regular flag parser, including `--list-windows` for symmetry.
  if (argv[0] === "list-windows" || argv[0] === "--list-windows") {
    args.listWindows = true;
    return args;
  }
  if (argv[0] === "backgrounds") {
    args.listBackgrounds = true;
    return args;
  }
  if (argv[0] === "log") {
    showLog(argv.slice(1));
  }
  if (argv[0] === "list-displays") {
    args.listDisplays = true;
    return args;
  }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--duration" || a === "-t") args.duration = Number(argv[++i]);
    else if (a === "--output" || a === "-o") args.output = argv[++i];
    else if (a === "--work-dir") args.workDir = resolve(argv[++i]);
    else if (a === "--skip-record") args.skipRecord = true;
    else if (a === "--window" || a === "-w") args.window = argv[++i];
    else if (a === "--window-id") args.windowId = Number(argv[++i]);
    else if (a === "--display" || a === "-d") args.display = argv[++i];
    else if (a === "--headless") args.headless = true;
    else if (a === "--label") args.label = argv[++i];
    else if (a === "--source") args.source = argv[++i] === "human" ? "human" : "agent";
    else if (a === "--background" || a === "-b") args.background = argv[++i];
    else if (a === "-h" || a === "--help") {
      console.log(`windowclip — record a window (or a whole screen) as a polished MP4

Recordings route through the Windowclip app by default, so every recording
shows the on-screen pill and can be stopped by hand (Esc / click / ⌥⌘R).

Usage:
  windowclip [options]              start a recording (default)
  windowclip stop                   stop the running recording, print the file
  windowclip cancel                 abort and delete the partial file
  windowclip status                 print what the app is doing, as JSON
  windowclip list-windows           print on-screen windows as JSON and exit
  windowclip list-displays          print connected displays as JSON and exit
  windowclip backgrounds            print the saved backgrounds and which one
                                    recordings use, as JSON
  windowclip log [-n N] [-f]        print the app's log (last N lines, default
                                    50; -f follows it)

Recording options:
  -t, --duration <s>    recording duration in seconds, or 0 for open-ended
                        (stops on SIGTERM; default 8). Open-ended recordings
                        cap at 5 minutes as a safety.
  -o, --output <path>   final MP4 path (default ~/Desktop/recording-<time>.mp4,
                        named the way the app names a hotkey take)
      --work-dir <p>    where to put intermediate artifacts (default ./out)
      --skip-record     reuse existing recording in work-dir (re-render only)
  -w, --window <pat>    target window pattern (case-insensitive substring of
                        app+title; default: frontmost non-terminal window)
      --window-id <N>   target specific CGWindowID (numeric). Use this when
                        you have an exact id from \`windowclip list-windows\`.
  -d, --display <id>    record a whole display instead of a window: a
                        displayId from \`windowclip list-displays\`, or \`main\`
                        for the one with the menu bar. The screen as it is: no
                        background, padding or shadow, at its own aspect ratio
                        (fit within 3840x2160). The pill stays out of it.
      --label <name>    who the pill credits for the recording (default Claude)
      --source <who>    agent (default) or human — picks the pill's treatment
  -b, --background <b>  this recording only: a saved background's name or id
                        (see \`windowclip backgrounds\`), \`default\`, or an
                        image path. Without it, the one chosen in the app's menu.
      --headless        bypass the app: spawn the recorder directly, no pill.
                        Only for contexts with no GUI session.
  -h, --help            this help

  When --duration 0 is used, the recorder PID is printed to stdout as:
    [windowclip] recorder PID: <pid>
  Send SIGTERM to that PID to stop the recording cleanly.
`);
      process.exit(0);
    } else {
      console.error(`unknown arg: ${a}`);
      process.exit(1);
    }
  }
  return args;
}

type WindowBounds = {
  title: string;
  app: string;
  pid: number;
  windowId: number;
  /** Bounds in screen POINTS — caller converts to source pixels by multiplying by backingScale. */
  bounds: { x: number; y: number; w: number; h: number };
};

async function detectWindow(opts: { pattern?: string; windowId?: number }): Promise<WindowBounds> {
  if (!existsSync(WINDOWS_BIN)) {
    throw new Error(`windows binary missing at ${WINDOWS_BIN} — run \`pnpm run build:windows\``);
  }
  // Priority: --window-id (exact, unambiguous) > --window (pattern) > frontmost.
  let subcmd: string[];
  if (opts.windowId !== undefined) {
    // No `windows by-id` subcommand yet — we list and filter. Cheap; macOS
    // returns the full window list synchronously.
    return new Promise((resolveBounds, reject) => {
      const proc = spawn(WINDOWS_BIN, ["list"], { stdio: ["ignore", "pipe", "pipe"] });
      let stdout = "";
      let stderr = "";
      proc.stdout.on("data", (d) => (stdout += d.toString()));
      proc.stderr.on("data", (d) => (stderr += d.toString()));
      proc.on("close", (code) => {
        if (code !== 0) return reject(new Error(`windows list failed (${code}): ${stderr.trim()}`));
        try {
          const all = JSON.parse(stdout) as WindowBounds[];
          const hit = all.find((w) => w.windowId === opts.windowId);
          if (!hit) return reject(new Error(`window-id ${opts.windowId} not found in ${all.length} listed windows`));
          resolveBounds(hit);
        } catch (e) {
          reject(new Error(`failed to parse windows JSON: ${(e as Error).message}`));
        }
      });
    });
  } else {
    subcmd = opts.pattern ? ["find", opts.pattern] : ["frontmost"];
  }
  return new Promise((resolveBounds, reject) => {
    const proc = spawn(WINDOWS_BIN, subcmd, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (d) => (stdout += d.toString()));
    proc.stderr.on("data", (d) => (stderr += d.toString()));
    proc.on("close", (code) => {
      if (code !== 0) return reject(new Error(`windows ${subcmd.join(" ")} failed (${code}): ${stderr.trim()}`));
      try {
        const w = JSON.parse(stdout) as WindowBounds;
        resolveBounds(w);
      } catch (e) {
        reject(new Error(`failed to parse windows JSON: ${(e as Error).message}\n${stdout}`));
      }
    });
  });
}

type Click = { t: number; x: number; y: number; button: string };
type CursorSample = { t: number; x: number; y: number };

type InputEvent =
  | { kind: "meta"; pointWidth: number; pointHeight: number; backingScale: number }
  | { kind: "click"; epoch: number; x: number; y: number; button: string }
  | { kind: "move"; epoch: number; x: number; y: number };

type DisplayMeta = { pointWidth: number; pointHeight: number; backingScale: number };

function loadInputTrack(
  path: string,
  t0Epoch: number,
  durationSeconds: number,
  dpr: number,
): { clicks: Click[]; cursor: CursorSample[]; meta: DisplayMeta | null } {
  const raw = readFileSync(path, "utf8");
  const clicks: Click[] = [];
  const cursor: CursorSample[] = [];
  let meta: DisplayMeta | null = null;

  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    let e: InputEvent;
    try {
      e = JSON.parse(line) as InputEvent;
    } catch {
      continue;
    }
    if (e.kind === "meta") {
      meta = { pointWidth: e.pointWidth, pointHeight: e.pointHeight, backingScale: e.backingScale };
      continue;
    }
    const t = e.epoch - t0Epoch;
    if (t < 0) continue; // pre-roll, ignore
    if (t > durationSeconds + 0.5) continue; // tail noise after ffmpeg stopped
    if (e.kind === "click") clicks.push({ t, x: e.x * dpr, y: e.y * dpr, button: e.button });
    else cursor.push({ t, x: e.x * dpr, y: e.y * dpr });
  }
  cursor.sort((a, b) => a.t - b.t);
  return { clicks, cursor, meta };
}

/**
 * Exponential smoothing with continuous-time correction (samples aren't uniform).
 * Per-sample: alpha = 1 - exp(-dt / tau). Output preserves the input timeline.
 */
function smoothCursor(samples: CursorSample[], tau: number): CursorSample[] {
  if (samples.length <= 1) return samples;
  const out: CursorSample[] = [samples[0]];
  for (let i = 1; i < samples.length; i++) {
    const dt = samples[i].t - samples[i - 1].t;
    const alpha = 1 - Math.exp(-dt / tau);
    const prev = out[i - 1];
    out.push({
      t: samples[i].t,
      x: prev.x + (samples[i].x - prev.x) * alpha,
      y: prev.y + (samples[i].y - prev.y) * alpha,
    });
  }
  return out;
}

/**
 * Dwell-commit: keep only clicks where the user's cursor lingered near the
 * click coord for DWELL_WINDOW_S seconds after the click. Drops transit clicks
 * (click + immediately moved far away).
 *
 * Note we deliberately use the SMOOTHED cursor stream as the dwell oracle —
 * this filter runs after smoothCursor. The smoothed signal is also what the
 * eye sees, so dwell-from-smoothed matches the user's perceived "did they
 * stay there?" question.
 */
export function commitClicks(clicks: Click[], cursor: CursorSample[]): Click[] {
  return clicks.filter(c => {
    const tEnd = c.t + DWELL_WINDOW_S;
    let maxDist = 0;
    let sawSample = false;
    for (const s of cursor) {
      if (s.t < c.t) continue;
      if (s.t > tEnd) break;
      sawSample = true;
      const dx = s.x - c.x;
      const dy = s.y - c.y;
      const d = Math.sqrt(dx * dx + dy * dy);
      if (d > maxDist) maxDist = d;
    }
    // No cursor samples in the window (cursor was idle) → user definitely
    // dwelled → commit.
    if (!sawSample) return true;
    return maxDist <= DWELL_RADIUS_PX;
  });
}

/** The recorder's first argument: a window id, or `display:<id|main>`. */
async function record(args: Args, target: string, outputPath: string, workDir: string, background: string) {
  // v3: recorder owns the whole pipeline — captures, composites onto a styled
  // background via Core Image, and outputs the final H.264 MP4 directly. No
  // post-recording stage needed.
  const clicksPath = resolve(workDir, "clicks.jsonl");
  mkdirSync(workDir, { recursive: true });

  // Spawn click recorder first — its first stdout line is the display meta breadcrumb
  // (point dims + backing scale), which we need afterward to translate click coords.
  console.error(`[windowclip] starting input recorder…`);
  const clicksProc = spawn(CLICKS_BIN, [], { stdio: ["ignore", "pipe", "pipe"] });
  writeFileSync(clicksPath, "");
  const clicksOut = Bun.file(clicksPath).writer();
  clicksProc.stdout.on("data", (d) => clicksOut.write(d));
  clicksProc.stderr.on("data", (d) => process.stderr.write(`[clicks] ${d}`));
  // Wait briefly for the meta + ready breadcrumb to land.
  await new Promise((r) => setTimeout(r, 400));

  spawn("afplay", ["/System/Library/Sounds/Tink.aiff"], { stdio: "ignore" });
  console.error(`\n[windowclip] >>> RECORDING ${args.duration}s <<<\n`);
  // Lock t0 right before recorder spawn. SCK first-frame latency is typically
  // smaller than ffmpeg's (~100-200ms vs ~200-500ms) but still nonzero.
  const t0Epoch = Date.now() / 1000;

  // Recorder writes the FINAL styled MP4 directly to outputPath. Capture +
  // compose + encode all happen inside one Swift process using SCK + Core
  // Image + AVAssetWriter. No intermediate file, no Remotion pass.
  //
  const recorderProc = spawn(
    RECORDER_BIN,
    [target, String(args.duration), outputPath],
    {
      stdio: ["ignore", "inherit", "inherit"],
      env: {
        ...process.env,
        RECORDER_BG_IMAGE: background,
      },
    },
  );
  // Surface the recorder's PID so Claude (or any external controller) can
  // SIGTERM it when the user says "stop". Print in a machine-parseable form.
  if (recorderProc.pid !== undefined) {
    console.log(`[windowclip] recorder PID: ${recorderProc.pid}`);
  }
  // Forward our own SIGTERM/SIGINT to the recorder so foreground Ctrl-C and
  // sigterm-to-cli both work as a clean stop.
  const forwardSignal = (sig: NodeJS.Signals) => {
    if (recorderProc.pid !== undefined && !recorderProc.killed) {
      recorderProc.kill(sig);
    }
  };
  process.on("SIGTERM", () => forwardSignal("SIGTERM"));
  process.on("SIGINT", () => forwardSignal("SIGINT"));
  await new Promise<void>((r, j) => {
    recorderProc.on("close", (code) => (code === 0 ? r() : j(new Error(`recorder exited ${code}`))));
  });

  spawn("afplay", ["/System/Library/Sounds/Pop.aiff"], { stdio: "ignore" });

  clicksProc.kill("SIGTERM");
  await new Promise((r) => setTimeout(r, 100));
  await clicksOut.end();

  return { clicksPath, t0Epoch };
}

/**
 * Drive a recording through the running app. Returns when the outcome is real:
 * `start` doesn't resolve until the countdown has elapsed, so a user who hits
 * Esc during it produces a cancelled result rather than a false "recording".
 */
async function recordViaApp(args: Args) {
  await ensureApp();

  const target = args.display !== undefined
    ? { displayId: displayIdArg(args.display) }
    : { windowId: args.windowId ?? (await detectWindow({ pattern: args.window })).windowId };
  // A path is made absolute here, since the app doesn't share our cwd; a name
  // goes as-is and the app resolves it against its saved set.
  const background =
    args.background && existsSync(args.background) ? resolve(args.background) : args.background;
  const started = await control({
    command: "start",
    ...target,
    ...(args.output ? { output: resolve(args.output) } : {}),
    source: args.source,
    label: args.label,
    ...(background ? { background } : {}),
  });

  if (!started.ok) {
    if (started.error === "busy") {
      // Never queue, never preempt — whoever owns the pill owns the machine.
      console.error(
        `[windowclip] busy: a ${started.state} session is already running. ` +
          `Stop it first (\`windowclip stop\`, Esc, or ⌥⌘R).`,
      );
      process.exit(3);
    }
    if (started.error === "background_not_found") unknownBackground(args.background ?? "");
    if (started.error === "display_not_found") {
      console.error(`[windowclip] no connected display with id ${args.display} — see \`windowclip list-displays\`.`);
      process.exit(2);
    }
    if (started.cancelled) {
      console.error(`[windowclip] cancelled during the countdown — nothing recorded.`);
      process.exit(4);
    }
    console.error(`[windowclip] could not start: ${started.error ?? "unknown"}${started.message ? ` — ${started.message}` : ""}`);
    process.exit(1);
  }

  console.log(`[windowclip] recording → ${started.output}`);

  if (args.duration <= 0) {
    // Open-ended: hand control back. Stop with `windowclip stop`, or by hand.
    console.error(`[windowclip] open-ended — stop with \`windowclip stop\` (or Esc / ⌥⌘R).`);
    return;
  }

  await new Promise((r) => setTimeout(r, args.duration * 1000));
  const stopped = await control({ command: "stop" });
  reportStop(stopped, args.duration);
}

/** `requested` is the duration the caller asked for, when there was one. The
 *  duration in `res` is measured from the finished file, so comparing the two
 *  is a real check rather than the app agreeing with itself — DIG-807 shipped a
 *  1.8s recording that announced itself as 5.2s precisely because nothing ever
 *  compared the artifact to the ask. */
function reportStop(res: ControlResponse, requested?: number) {
  if (res.cancelled) {
    // The user's physical controls outrank the caller's request, and the caller
    // is told plainly rather than being handed a missing file to puzzle over.
    console.error(`[windowclip] the recording was stopped by hand — no file written.`);
    process.exit(4);
  }
  if (!res.ok) {
    console.error(`[windowclip] stop failed: ${res.error ?? "unknown"}`);
    process.exit(1);
  }
  const seconds = res.duration ? ` (${res.duration.toFixed(1)}s)` : "";
  console.log(`[windowclip] saved ${res.output}${seconds}`);
  // Half a second of slack: a take ends on a frame boundary, not exactly on the
  // deadline. Anything beyond that is the recording being materially shorter
  // than asked for, and the user should hear it from us rather than discover it
  // in the file.
  if (requested && requested > 0 && res.duration && res.duration < requested - 0.5) {
    console.error(
      `[windowclip] warning: asked for ${requested}s but the file is ` +
        `${res.duration.toFixed(1)}s — the recording is short.`,
    );
  }
}

async function runControlCommand(command: "stop" | "cancel" | "status") {
  if (!(await appIsUp())) {
    console.error(`[windowclip] Windowclip isn't running — nothing to ${command}.`);
    process.exit(2);
  }
  const res = await control({ command });
  if (command === "status") {
    console.log(JSON.stringify(res, null, 2));
    return;
  }
  if (command === "cancel") {
    console.log(`[windowclip] cancelled${res.ok ? "" : ` (${res.error})`}`);
    return;
  }
  reportStop(res);
}

/** The app's own naming for a take with no requested path, so a headless
 *  recording lands where a hotkey one would. */
function defaultOutputPath(now = new Date()): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  const stamp =
    `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}-` +
    `${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
  const desktop = resolve(homedir(), "Desktop");
  let candidate = resolve(desktop, `recording-${stamp}.mp4`);
  for (let n = 2; existsSync(candidate); n++) candidate = resolve(desktop, `recording-${stamp}-${n}.mp4`);
  return candidate;
}

function showLog(rest: string[]): never {
  let lines = "50";
  let follow = false;
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === "-n") lines = rest[++i] ?? lines;
    else if (rest[i] === "-f") follow = true;
  }
  if (!existsSync(LOG_FILE)) {
    console.error(`[windowclip] no log yet at ${LOG_FILE}`);
    process.exit(1);
  }
  console.error(`[windowclip] ${LOG_FILE}`);
  const proc = Bun.spawnSync(["tail", "-n", lines, ...(follow ? ["-F"] : []), LOG_FILE], {
    stdio: ["inherit", "inherit", "inherit"],
  });
  process.exit(proc.exitCode ?? 1);
}

/** `main` passes through by name; anything else must be a numeric display id. */
function displayIdArg(display: string): number | "main" {
  if (display === "main") return "main";
  const id = Number(display);
  if (!Number.isInteger(id) || id < 0) {
    console.error(`[windowclip] --display takes a displayId from \`windowclip list-displays\`, or \`main\` — got "${display}".`);
    process.exit(1);
  }
  return id;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));

  if (args.display !== undefined) {
    displayIdArg(args.display);
    if (args.window !== undefined || args.windowId !== undefined) {
      console.error(`[windowclip] --display records a whole screen; drop --window / --window-id.`);
      process.exit(1);
    }
    if (args.background !== undefined) {
      console.error(`[windowclip] a screen recording has no background; drop --background.`);
      process.exit(1);
    }
  }

  if (args.controlCommand) {
    await runControlCommand(args.controlCommand);
    return;
  }

  if (args.listBackgrounds) {
    printBackgrounds();
    return;
  }

  if (args.listWindows) {
    // Thin pass-through to the windows binary. Inherits stdio so callers get
    // the raw JSON array on stdout and any errors on stderr.
    if (!existsSync(WINDOWS_BIN)) {
      console.error(`[windowclip] windows binary missing at ${WINDOWS_BIN} — run \`pnpm run build:windows\``);
      process.exit(1);
    }
    const proc = spawn(WINDOWS_BIN, ["list"], { stdio: "inherit" });
    proc.on("close", (code) => process.exit(code ?? 1));
    return;
  }

  if (args.listDisplays) {
    if (!existsSync(WINDOWS_BIN)) {
      console.error(`[windowclip] windows binary missing at ${WINDOWS_BIN} — run \`pnpm run build:windows\``);
      process.exit(1);
    }
    const proc = spawn(WINDOWS_BIN, ["displays"], { stdio: "inherit" });
    proc.on("close", (code) => process.exit(code ?? 1));
    return;
  }

  // The default path: drive the app, so the recording is visible and killable.
  if (!args.headless) {
    await recordViaApp(args);
    return;
  }

  if (!existsSync(CLICKS_BIN)) {
    console.error(`[windowclip] clicks binary missing at ${CLICKS_BIN} — run \`pnpm run build:clicks\``);
    process.exit(1);
  }
  if (!existsSync(RECORDER_BIN)) {
    console.error(`[windowclip] recorder binary missing at ${RECORDER_BIN} — run \`pnpm run build:recorder\``);
    process.exit(1);
  }
  if (!existsSync(WINDOWS_BIN)) {
    console.error(`[windowclip] windows binary missing at ${WINDOWS_BIN} — run \`pnpm run build:windows\``);
    process.exit(1);
  }

  const workDir = args.workDir;
  const outputPath = args.output ? resolve(args.output) : defaultOutputPath();

  if (args.display !== undefined) {
    const target = `display:${displayIdArg(args.display)}`;
    console.error(`[windowclip] target: ${target}`);
    const { t0Epoch } = await record(args, target, outputPath, workDir, "");
    writeFileSync(resolve(workDir, "meta.json"), JSON.stringify({ t0Epoch, display: args.display }, null, 2));
    console.error(`[windowclip] wrote ${outputPath}`);
    return;
  }

  // v3: detect the target window BEFORE recording. SCK records ONLY that window's
  // content (occlusion-immune); recorder composites onto a styled background
  // and writes the final MP4 directly. No post-recording stage.
  const windowInfo = await detectWindow({ pattern: args.window, windowId: args.windowId });
  console.error(`[windowclip] target window: "${windowInfo.title}" (${windowInfo.app}) ${windowInfo.bounds.w}x${windowInfo.bounds.h} @ (${windowInfo.bounds.x}, ${windowInfo.bounds.y})`);

  if (args.skipRecord) {
    console.error(`[windowclip] --skip-record: no longer supported in v3 (no intermediate stage to reuse). Re-record.`);
    process.exit(1);
  }

  // --background, then RECORDER_BG_IMAGE, then the app's saved choice, then the
  // Big Sur default in assets/. Settled before anything is spawned, so a bad
  // name exits with nothing left running.
  const background = args.background
    ? (resolveBackground(args.background) ?? unknownBackground(args.background))
    : (process.env.RECORDER_BG_IMAGE ??
      chosenBackground()?.path ??
      (existsSync(DEFAULT_BACKGROUND) ? DEFAULT_BACKGROUND : ""));
  console.error(`[windowclip] background: ${background || "(mesh gradient)"}`);

  const { clicksPath, t0Epoch } = await record(args, String(windowInfo.windowId), outputPath, workDir, background);
  writeFileSync(resolve(workDir, "meta.json"), JSON.stringify({ t0Epoch, windowInfo }, null, 2));

  // Load click/cursor data for diagnostics (and future overlay features).
  const probe = loadInputTrack(clicksPath, t0Epoch, args.duration, /*placeholder*/ 1);
  const dpr = probe.meta?.backingScale ?? 2;
  const { clicks, cursor } = loadInputTrack(clicksPath, t0Epoch, args.duration, dpr);
  const smoothed = smoothCursor(cursor, CURSOR_SMOOTH_TAU);
  const committed = commitClicks(clicks, smoothed);

  console.error(`[windowclip] ${committed.length}/${clicks.length} click(s) committed, ${cursor.length} cursor sample(s) (overlay TBD)`);
  console.error(`[windowclip] wrote ${outputPath}`);
}

main().catch((err) => {
  console.error(`[windowclip] error: ${err.message}`);
  process.exit(1);
});
