import Foundation
import ServiceManagement

// App-side counterpart to the privileged helper. Carries its own matching copy of the
// @objc protocol + constants (the daemon has the other copy — XPC matches them across
// processes by selector). Installs/removes the daemon via SMAppService (one admin
// prompt) and runs whitelisted root fixes over a code-signing-validated XPC connection.

@objc protocol ConsoHelperProtocol {
    func runFix(_ id: String, reply: @escaping (Bool, String) -> Void)
    func deleteSnapshot(_ date: String, reply: @escaping (Bool, String) -> Void)
    func version(reply: @escaping (String) -> Void)
}

enum ConsoHelperInfo {
    static let machServiceName = "com.conso.conso.helper"
    static let plistName = "com.conso.conso.helper.plist"
    // NOTE: Apple Developer Team ID — contributors must set their own (see CONTRIBUTING.md).
    static let teamID = "VMJ9FM7QD9"
    static let codeRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
}

@MainActor
final class HelperClient {
    static let shared = HelperClient()
    private var connection: NSXPCConnection?

    private var service: SMAppService { SMAppService.daemon(plistName: ConsoHelperInfo.plistName) }

    /// Whether the helper is currently registered + enabled.
    var isInstalled: Bool { service.status == .enabled }
    var status: SMAppService.Status { service.status }

    /// Installs the daemon. The FIRST call triggers a one-time admin-password prompt.
    /// Throws on failure — surface it, don't swallow.
    func install() throws { try service.register() }
    func uninstall() throws { try service.unregister() }

    /// Runs a whitelisted root fix through the helper.
    func runFix(_ id: String) async -> (ok: Bool, output: String) {
        guard let conn = connection ?? makeConnection() else {
            return (false, "helper unavailable")
        }
        connection = conn
        return await withCheckedContinuation { continuation in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(returning: (false, "helper connection failed: \(error.localizedDescription)"))
            }
            guard let helper = proxy as? ConsoHelperProtocol else {
                continuation.resume(returning: (false, "helper proxy unavailable"))
                return
            }
            helper.runFix(id) { ok, output in continuation.resume(returning: (ok, output)) }
        }
    }

    /// Deletes ONE APFS local snapshot by its `YYYY-MM-DD-HHMMSS` timestamp through the
    /// helper (which re-validates the date server-side and runs `tmutil deletelocalsnapshots`
    /// as root). Mirrors `runFix`'s continuation + proxy-error handling.
    func deleteSnapshot(_ date: String) async -> (ok: Bool, output: String) {
        guard let conn = connection ?? makeConnection() else {
            return (false, "helper unavailable")
        }
        connection = conn
        return await withCheckedContinuation { continuation in
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(returning: (false, "helper connection failed: \(error.localizedDescription)"))
            }
            guard let helper = proxy as? ConsoHelperProtocol else {
                continuation.resume(returning: (false, "helper proxy unavailable"))
                return
            }
            helper.deleteSnapshot(date) { ok, output in continuation.resume(returning: (ok, output)) }
        }
    }

    /// Builds the privileged XPC connection, pinning the helper's code-signing requirement.
    /// If that pin can't be set we MUST NOT talk to the peer (it could be a spoofed helper):
    /// log loudly, tear the connection down, and return nil so callers degrade to "helper
    /// unavailable" — mirroring how the helper side returns false when its requirement fails.
    private func makeConnection() -> NSXPCConnection? {
        let conn = NSXPCConnection(machServiceName: ConsoHelperInfo.machServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: ConsoHelperProtocol.self)
        do {
            try conn.setCodeSigningRequirement(ConsoHelperInfo.codeRequirement)
        } catch {
            NSLog("conso: refusing helper connection — could not pin code-signing requirement: \(error)")
            conn.invalidate()
            return nil
        }
        conn.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
        conn.resume()
        return conn
    }
}
