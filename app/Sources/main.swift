// windowclip hotkey recorder — LSUIElement agent app.
//
// Global hotkey → window picker → countdown → record → stop pill. The recording
// itself is delegated to the existing `cmd/recorder` binary; this app is the
// front door, not a second implementation.

import AppKit

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

func usage() -> Never {
    let text = """
    windowclip hotkey recorder

    Usage:
      Windowclip [--debug-show <surface>] [--debug-midline] [--debug-freeze]

    Debug flags (summon a surface deterministically, no hotkey / no recording):
      --debug-show <surface>     menu | picker | setup | gate |
                                 pill-countdown | pill-recording | pill-saved
                                 gate = run the launch decision and show whatever
                                 it decides to (nothing, if all grants are in)
      --debug-screen <state>     setup: force the Screen Recording row
                                 needed | granted | denied | relaunch
      --debug-mic <state>        setup: force the Microphone row
                                 needed | granted | denied
      --debug-live               setup: drive the rows from REAL permission state
                                 instead of the flags above, and keep them in sync
      --debug-setup-action <row> setup: press that row's real button, then quit
                                 screen | mic
      --debug-permissions        print what macOS reports about our grants and quit
                                 (reads only — cannot raise a prompt)
      --debug-backdrop <fill>    park a flat window behind the surface, so a
                                 translucent panel can be judged against
                                 something other than the wallpaper
                                 white | light | dark
      --debug-capture <png>      screenshot the surface, then quit (self-cleaning)
      --debug-capture-delay <s>  settle time before the shot (default 1.8)
      --debug-timeout <s>        hard teardown for interactive runs (default 25)
      --debug-midline            draw the row midline over the pill (centering check)
      --debug-freeze             hold animations at their resting phase
      --debug-hover              force the saved filename's hover affordance on
      --debug-reveal             reveal the newest recording in Finder, then quit
      --debug-reveal-recent <n>  fire the status menu's Nth recent item, then quit
      --debug-fire-menu <text>   fire the status menu item whose title contains
                                 <text> — real item, real target/action — then quit
      --debug-agent              dress the surface as an agent session (ring + attribution)
      --debug-label <name>       who the attribution credits (default Claude)

    Read-only (prints JSON, writes nothing, starts nothing):
      --doctor [--doctor-root <dir>]  what this copy is and what its next take
                                      will do; <dir> reads a fixture instead

    End-to-end (drives the real session, then quits):
      --debug-record <target>       window (CGWindowID or app/title text), or display:<id|main>
      --debug-record-seconds <s>    how long to record (default 5)
      --debug-record-output <path>  where to write it (default: Desktop)
    """
    print(text)
    exit(0)
}

var argv = Array(CommandLine.arguments.dropFirst())
// Before anything else: the doctor reads files and exits, and must never reach
// NSApplication, the log or the socket.
if argv.first == "--doctor" {
    var root: URL?
    switch argv.count {
    case 1: break
    case 3 where argv[1] == "--doctor-root": root = URL(fileURLWithPath: argv[2])
    default:
        FileHandle.standardError.write(Data("usage: --doctor [--doctor-root <dir>]\n".utf8))
        exit(64)
    }
    exit(Doctor.run(root: root))
}

var options = LaunchOptions()
var i = 0
while i < argv.count {
    switch argv[i] {
    case "--debug-show":
        i += 1
        guard i < argv.count else {
            FileHandle.standardError.write(Data("--debug-show needs a surface name\n".utf8))
            exit(64)
        }
        options.debugShow = argv[i]
    case "--debug-screen", "--debug-mic":
        let flag = argv[i]
        i += 1
        guard let status = PermissionStatus.parse(argv[safe: i] ?? "") else {
            FileHandle.standardError.write(Data(
                "\(flag) needs one of: needed, granted, denied, relaunch\n".utf8
            ))
            exit(64)
        }
        if flag == "--debug-screen" {
            options.debugScreenStatus = status
        } else {
            // Microphone access applies to the running process the moment it's
            // granted — there is no relaunch state to render, and offering one in
            // the harness would invent a screenshot of something that can't happen.
            guard status != .needsRelaunch else {
                FileHandle.standardError.write(Data(
                    "--debug-mic has no relaunch state (mic grants apply immediately)\n".utf8
                ))
                exit(64)
            }
            options.debugMicStatus = status
        }
    case "--debug-permissions":
        options.debugPermissions = true
    case "--debug-fire-menu":
        i += 1
        guard i < argv.count else {
            FileHandle.standardError.write(Data("--debug-fire-menu needs part of an item title\n".utf8))
            exit(64)
        }
        options.debugFireMenu = argv[i]
    case "--debug-live":
        options.debugLive = true
    case "--debug-setup-action":
        i += 1
        switch argv[safe: i]?.lowercased() {
        case "screen", "screenrecording", "screen-recording":
            options.debugSetupAction = .screenRecording
        case "mic", "microphone":
            options.debugSetupAction = .microphone
        default:
            FileHandle.standardError.write(Data("--debug-setup-action needs screen or mic\n".utf8))
            exit(64)
        }
    case "--debug-backdrop":
        i += 1
        guard i < argv.count else {
            FileHandle.standardError.write(Data("--debug-backdrop needs white, light or dark\n".utf8))
            exit(64)
        }
        options.debugBackdrop = argv[i]
    case "--debug-midline":
        options.debugMidline = true
    case "--debug-freeze":
        options.debugFreeze = true
    case "--debug-hover":
        options.debugHover = true
    case "--debug-reveal":
        options.debugReveal = true
    case "--debug-reveal-recent":
        i += 1
        guard let index = Int(argv[safe: i] ?? "") else {
            FileHandle.standardError.write(Data("--debug-reveal-recent needs an index\n".utf8))
            exit(64)
        }
        options.debugRevealRecent = index
    case "--debug-agent":
        options.debugAgent = true
    case "--debug-label":
        i += 1
        guard i < argv.count else {
            FileHandle.standardError.write(Data("--debug-label needs a name\n".utf8))
            exit(64)
        }
        options.debugLabel = argv[i]
    case "--debug-capture":
        i += 1
        guard i < argv.count else {
            FileHandle.standardError.write(Data("--debug-capture needs an output path\n".utf8))
            exit(64)
        }
        options.debugCapture = argv[i]
    case "--debug-capture-delay":
        i += 1
        options.debugCaptureDelay = Double(argv[safe: i] ?? "") ?? options.debugCaptureDelay
    case "--debug-timeout":
        i += 1
        options.debugTimeout = Double(argv[safe: i] ?? "") ?? options.debugTimeout
    case "--debug-record":
        i += 1
        guard i < argv.count else {
            FileHandle.standardError.write(Data("--debug-record needs a window id or pattern, or display:<id|main>\n".utf8))
            exit(64)
        }
        options.debugRecord = argv[i]
    case "--debug-record-seconds":
        i += 1
        options.debugRecordSeconds = Double(argv[safe: i] ?? "") ?? options.debugRecordSeconds
    case "--debug-record-output":
        i += 1
        guard i < argv.count else {
            FileHandle.standardError.write(Data("--debug-record-output needs a path\n".utf8))
            exit(64)
        }
        options.debugRecordOutput = argv[i]
    case "-h", "--help":
        usage()
    default:
        FileHandle.standardError.write(Data("unknown arg: \(argv[i])\n".utf8))
        exit(64)
    }
    i += 1
}

let app = NSApplication.shared
// Agent app: no Dock icon, no menu bar. Belt-and-braces with LSUIElement in the
// Info.plist so running the raw binary behaves the same as launching the bundle.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.run()
