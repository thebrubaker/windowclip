import CoreGraphics

/// Socket commands only the dev identity answers: the same entry points as
/// ⌥⌘R and the picker, for a copy that has no hotkey and nobody at its screen.
/// Returns false when the command isn't one of these, or this copy doesn't
/// answer them, so the caller replies `unknown_command` as for any other.
@MainActor
enum DevCommands {
    static func handle(
        _ request: ControlRequest,
        session: SessionController,
        identity: AppIdentity = .current,
        window: (CGWindowID) -> CapturableWindow?,
        respond: @escaping ([String: Any]) -> Void
    ) -> Bool {
        guard identity.answersDevCommands else { return false }
        switch request.command {
        case "toggle":
            session.toggle()
        case "pick":
            guard let id = request.int("windowId") else {
                respond(["ok": false, "error": "bad_request", "message": "pick requires windowId"])
                return true
            }
            guard let found = window(CGWindowID(id)) else {
                respond(["ok": false, "error": "window_not_found",
                         "message": "no on-screen window with id \(id)"])
                return true
            }
            guard session.pick(.window(found)) else {
                respond(["ok": false, "error": "not_picking", "state": session.describe(session.phase)])
                return true
            }
        default:
            return false
        }
        respond(["ok": true, "state": session.describe(session.phase)])
        return true
    }
}
