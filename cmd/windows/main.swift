// windowclip window enumerator — lists on-screen windows or finds one by pattern.
//
// CGWindowList runs without Accessibility permission, but window TITLES require
// Screen Recording permission. Without it, you'll see app names and bounds but
// no titles. The CLI should handle this case (match on app name only).
//
// Output: JSON array on stdout. One window per element:
//   { "title": "Foo", "app": "Bar", "pid": 123, "windowId": 456,
//     "bounds": { "x": 0, "y": 0, "w": 800, "h": 600 } }
// Bounds are in screen POINTS (CGWindowList returns CGRectInDictionaryRepresentation
// values that are point-space). Recorder runs in pixels — caller multiplies by DPR.
//
// Compile:
//   swiftc -O main.swift -o windows
// Usage:
//   windows list             # all on-screen windows
//   windows frontmost        # frontmost non-self window (excludes the calling terminal)
//   windows find <pattern>   # case-insensitive substring match against app+title
//   windows displays         # connected displays: id, name, main, point bounds
//                            # (top-left origin) and pixel size

import Cocoa
import CoreGraphics
import Foundation

struct WindowInfo: Codable {
    let title: String
    let app: String
    let pid: Int
    let windowId: Int
    let bounds: Bounds
    let layer: Int
}
struct Bounds: Codable {
    let x: Double
    let y: Double
    let w: Double
    let h: Double
}

func listWindows() -> [WindowInfo] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }
    var out: [WindowInfo] = []
    for w in raw {
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        // Layer 0 = normal app windows. Higher layers = menubar, dock, overlays.
        if layer != 0 { continue }

        let app = w[kCGWindowOwnerName as String] as? String ?? ""
        let title = w[kCGWindowName as String] as? String ?? ""
        let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
        let windowId = w[kCGWindowNumber as String] as? Int ?? 0

        guard let boundsDict = w[kCGWindowBounds as String] as? [String: Any] else { continue }
        let x = (boundsDict["X"] as? NSNumber)?.doubleValue ?? 0
        let y = (boundsDict["Y"] as? NSNumber)?.doubleValue ?? 0
        let width = (boundsDict["Width"] as? NSNumber)?.doubleValue ?? 0
        let height = (boundsDict["Height"] as? NSNumber)?.doubleValue ?? 0

        // Skip tiny windows (likely chrome elements that snuck past the layer filter).
        if width < 100 || height < 100 { continue }
        // Skip apps that are clearly system UI (no useful title and small).
        if app.isEmpty { continue }

        out.append(WindowInfo(
            title: title, app: app, pid: pid, windowId: windowId,
            bounds: Bounds(x: x, y: y, w: width, h: height), layer: layer
        ))
    }
    return out
}

struct DisplayInfo: Codable {
    let displayId: Int
    let name: String
    let main: Bool
    let bounds: Bounds
    let pixelWidth: Int
    let pixelHeight: Int
}

func listDisplays() -> [DisplayInfo] {
    let mainID = CGMainDisplayID()
    return NSScreen.screens.compactMap { screen in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let id = CGDirectDisplayID(number.uint32Value)
        let bounds = CGDisplayBounds(id)
        let mode = CGDisplayCopyDisplayMode(id)
        return DisplayInfo(
            displayId: Int(id),
            name: screen.localizedName,
            main: id == mainID,
            bounds: Bounds(x: bounds.minX, y: bounds.minY, w: bounds.width, h: bounds.height),
            pixelWidth: mode?.pixelWidth ?? Int(bounds.width * screen.backingScaleFactor),
            pixelHeight: mode?.pixelHeight ?? Int(bounds.height * screen.backingScaleFactor)
        )
    }
    .sorted { $0.main && !$1.main }
}

func emitJSON<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    guard let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) else {
        FileHandle.standardError.write(Data("encode failed\n".utf8))
        exit(1)
    }
    print(s)
}

// Identify "self" — the terminal app that ran this binary. PPID's session leader
// is a reasonable proxy. For frontmost-exclude-self, we walk up to find the
// owning terminal. Simpler: just exclude any window whose app matches a known
// terminal name OR our own owning process tree.
func ownerAppName() -> String? {
    // Get our parent process's owning app via NSWorkspace front-most isn't quite right.
    // Use ProcessInfo + check known terminals.
    let knownTerminals = ["cmux", "Terminal", "iTerm2", "iTerm", "Alacritty", "Ghostty", "kitty", "WezTerm", "Hyper"]
    // Find the frontmost terminal-ish app at startup as "self".
    if let front = NSWorkspace.shared.frontmostApplication?.localizedName {
        if knownTerminals.contains(front) { return front }
    }
    return nil
}

let args = CommandLine.arguments
let mode = args.count >= 2 ? args[1] : "list"

switch mode {
case "list":
    emitJSON(listWindows())

case "displays":
    emitJSON(listDisplays())

case "frontmost":
    // Frontmost = first window with the lowest CG ordering for the frontmost-app's pid.
    // CGWindowList returns front-to-back order, so the first matching window of the
    // frontmost non-self app wins.
    let selfApp = ownerAppName()
    let workspace = NSWorkspace.shared
    let frontApp = workspace.frontmostApplication
    let frontPid = frontApp?.processIdentifier ?? 0
    let frontName = frontApp?.localizedName ?? ""

    let windows = listWindows()
    let candidates = windows.filter { w in
        // If frontmost is our terminal, skip windows from it and pick next-best.
        if let s = selfApp, w.app == s { return false }
        // Prefer windows owned by the OS-reported frontmost app.
        return Int32(w.pid) == frontPid || w.app == frontName
    }
    if let pick = candidates.first ?? windows.first(where: { $0.app != selfApp }) {
        emitJSON(pick)
    } else {
        FileHandle.standardError.write(Data("no frontmost window found\n".utf8))
        exit(2)
    }

case "find":
    guard args.count >= 3 else {
        FileHandle.standardError.write(Data("usage: windows find <pattern>\n".utf8))
        exit(64)
    }
    let needle = args[2].lowercased()
    let windows = listWindows()
    // Rank: title match > app match. Substring match only for v1.
    var best: (WindowInfo, Int)? = nil
    for w in windows {
        var score = 0
        if w.title.lowercased().contains(needle) { score += 10 }
        if w.app.lowercased().contains(needle) { score += 5 }
        if score == 0 { continue }
        if best == nil || score > best!.1 { best = (w, score) }
    }
    if let (pick, _) = best {
        emitJSON(pick)
    } else {
        FileHandle.standardError.write(Data("no window matched: \(args[2])\n".utf8))
        exit(2)
    }

default:
    FileHandle.standardError.write(Data("unknown mode: \(mode). usage: windows [list|frontmost|find <pattern>|displays]\n".utf8))
    exit(64)
}
