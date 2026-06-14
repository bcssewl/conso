import Foundation
import ServiceManagement

// Thin wrapper around SMAppService.mainApp for the "Launch at login" toggle.
// macOS 13+ (the app targets macOS 26). Registering adds conso to the user's
// Login Items; unregistering removes it. State is read live from `.status`.
//
// Named `LoginItemService` (not `LoginItem`) on purpose: ConsoCore already exports a
// `public struct LoginItem` for the read-only launch-items list, and `import ConsoCore`
// would make the bare name ambiguous inside the app module.

@MainActor
enum LoginItemService {
    private static var service: SMAppService { SMAppService.mainApp }

    /// Whether conso is currently set to launch at login.
    static var isEnabled: Bool { service.status == .enabled }
    static var status: SMAppService.Status { service.status }

    /// Enables or disables launch-at-login. Returns true on success; swallows the
    /// failure (returns false) instead of throwing so the UI never crashes — the
    /// caller re-reads `isEnabled` to reflect the real resulting state.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
            return true
        } catch {
            return false
        }
    }
}
