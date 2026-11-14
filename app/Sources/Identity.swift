import Foundation

/// Which copy of the app this is. The names come from `app/identity.json`,
/// compiled in by `app/identity.sh swift`.
///
/// Only the prod bundle id resolves to prod. A raw binary, a probe or any
/// other bundle resolves to dev, so nothing but the installed app can reach
/// the prod folders, socket or log.
struct AppIdentity: Equatable, Sendable {
    enum Kind: String, Sendable { case prod, dev }

    let kind: Kind
    let bundleId: String
    let name: String
    let executable: String
    let slug: String
    let statusTitle: String

    var registersHotkeys: Bool { kind == .prod }
    var recordsMicrophone: Bool { kind == .prod }
    var answersDevCommands: Bool { kind == .dev }

    static func resolve(bundleId: String?) -> AppIdentity {
        bundleId == prod.bundleId ? prod : dev
    }

    static let current = resolve(bundleId: Bundle.main.bundleIdentifier)
}
