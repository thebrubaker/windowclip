// HotkeyManager — global hotkeys via Carbon's RegisterEventHotKey.
//
// Why Carbon and not a CGEventTap: an event tap needs Accessibility permission,
// and this app deliberately introduces ZERO new permission types. RegisterEventHotKey
// needs none, and it consumes the keystroke so the frontmost app never sees it.
//
// Two hotkeys, with very different lifetimes:
//   ⌥⌘R — registered for the life of the app. Summons the picker; stops a session.
//   Esc — registered ONLY while a session's pill is up, and unregistered the
//         moment it ends. Esc is far too important to hold globally; hijacking
//         it outside the ~seconds a pill is on screen would be hostile.

import AppKit
import Carbon.HIToolbox

/// Carbon hands us a raw C callback, so the dispatch table has to be reachable
/// from a global function — hence the singleton.
private func hotkeyCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &id
    )
    guard status == noErr else { return status }
    let fired = id.id
    // Carbon dispatches on the main run loop, so we're already on the main thread.
    MainActor.assumeIsolated { HotkeyManager.shared.fire(fired) }
    return noErr
}

@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    enum Binding: UInt32 {
        /// ⌥⌘R — summon the picker, or stop an active session.
        case toggle = 1
        /// Esc — cancel the countdown / stop the recording. Session-scoped.
        case escape = 2

        var keyCode: UInt32 {
            switch self {
            case .toggle: return UInt32(kVK_ANSI_R)
            case .escape: return UInt32(kVK_Escape)
            }
        }

        var modifiers: UInt32 {
            switch self {
            case .toggle: return UInt32(cmdKey | optionKey)
            case .escape: return 0
            }
        }
    }

    private var handlerRef: EventHandlerRef?
    private var registered: [Binding: EventHotKeyRef] = [:]
    private var actions: [Binding: () -> Void] = [:]

    private init() {}

    /// Installs the shared Carbon event handler. Safe to call more than once.
    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), hotkeyCallback, 1, &spec, nil, &handlerRef)
    }

    @discardableResult
    func register(_ binding: Binding, action: @escaping () -> Void) -> Bool {
        // The dev copy runs beside the installed one and grabs no keys, Esc included.
        guard AppIdentity.current.registersHotkeys else { return false }
        installHandlerIfNeeded()
        actions[binding] = action
        guard registered[binding] == nil else { return true }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x7374_6773 /* 'stgs' */), id: binding.rawValue)
        let status = RegisterEventHotKey(
            binding.keyCode, binding.modifiers, id, GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            // Most likely another app already owns this combination.
            note("hotkey \(binding) registration failed (OSStatus \(status)) — is it taken?")
            return false
        }
        registered[binding] = ref
        return true
    }

    func unregister(_ binding: Binding) {
        guard let ref = registered.removeValue(forKey: binding) else { return }
        UnregisterEventHotKey(ref)
    }

    func isRegistered(_ binding: Binding) -> Bool { registered[binding] != nil }

    fileprivate func fire(_ raw: UInt32) {
        guard let binding = Binding(rawValue: raw) else { return }
        actions[binding]?()
    }
}
