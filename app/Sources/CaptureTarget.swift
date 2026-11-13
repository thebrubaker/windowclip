import AppKit
import CoreGraphics

struct CapturableDisplay: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let isMain: Bool
    let sizeInPoints: CGSize
}

enum DisplayEnumerator {
    static func list() -> [CapturableDisplay] {
        let mainID = CGMainDisplayID()
        let displays = NSScreen.screens.compactMap { screen -> CapturableDisplay? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            return CapturableDisplay(id: id, name: screen.localizedName, isMain: id == mainID, sizeInPoints: screen.frame.size)
        }
        return displays.filter(\.isMain) + displays.filter { !$0.isMain }
    }

    static func display(id: CGDirectDisplayID) -> CapturableDisplay? {
        list().first { $0.id == id }
    }
}

enum CaptureTarget: Equatable {
    case window(CapturableWindow)
    case display(CapturableDisplay)

    var recorderArgument: String {
        switch self {
        case let .window(window): return String(window.id)
        case let .display(display): return "display:\(display.id)"
        }
    }

    var label: String {
        switch self {
        case let .window(window): return window.app
        case let .display(display): return display.name
        }
    }

    var isDisplay: Bool {
        if case .display = self { return true }
        return false
    }
}
