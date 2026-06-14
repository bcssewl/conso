import Foundation

// conso privileged helper — a tiny root daemon launched by launchd (via SMAppService).
// Self-contained on purpose: the app has its own matching copy of this @objc protocol;
// XPC matches the two across processes by selector, so they don't share a source file.
//
// It exposes ONE capability: run a whitelisted root "fix" by id. Every connection is
// validated against our team's code-signing requirement, and every command is looked up
// in a fixed allowlist — the app can never make it run anything arbitrary.

@objc protocol ConsoHelperProtocol {
    func runFix(_ id: String, reply: @escaping (Bool, String) -> Void)
    func deleteSnapshot(_ date: String, reply: @escaping (Bool, String) -> Void)
    func version(reply: @escaping (String) -> Void)
}

enum ConsoHelper {
    static let machServiceName = "com.conso.conso.helper"
    static let version = "2"
    // NOTE: Apple Developer Team ID — contributors must set their own (see CONTRIBUTING.md).
    static let teamID = "VMJ9FM7QD9"
    /// Pin BOTH the bundle identifier AND the team, so ONLY the conso app (not just any
    /// same-team binary) can drive this root helper. NOTE: an already-installed daemon caches
    /// the old requirement — after changing this you must Remove + Install the helper from
    /// Settings for the tightened requirement to take effect.
    static let codeRequirement =
        "identifier \"com.conso.conso\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""

    /// The ONLY commands the helper will run. No arbitrary execution.
    static let whitelist: [String: (tool: String, args: [String])] = [
        "spotlight":    ("/usr/bin/mdutil", ["-E", "/"]),
        "dns-hup":      ("/usr/bin/killall", ["-HUP", "mDNSResponder"]),
        "fonts-system": ("/usr/bin/atsutil", ["databases", "-remove"]),
    ]
}

final class HelperService: NSObject, ConsoHelperProtocol, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        do {
            try conn.setCodeSigningRequirement(ConsoHelper.codeRequirement)
        } catch {
            NSLog("conso-helper: rejecting connection: \(error)")
            return false
        }
        conn.exportedInterface = NSXPCInterface(with: ConsoHelperProtocol.self)
        conn.exportedObject = self
        conn.resume()
        return true
    }

    func runFix(_ id: String, reply: @escaping (Bool, String) -> Void) {
        guard let cmd = ConsoHelper.whitelist[id] else { reply(false, "unknown fix: \(id)"); return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cmd.tool)
        process.arguments = cmd.args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            reply(process.terminationStatus == 0, out.isEmpty ? "done" : out)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    /// Deletes ONE APFS local snapshot by its `YYYY-MM-DD-HHMMSS` timestamp. The trust
    /// boundary: we NEVER trust the caller — `date` is re-validated against the exact same
    /// `^\d{4}-\d{2}-\d{2}-\d{6}$` regex the app uses, and on mismatch we run nothing. On a
    /// match it's passed as a single literal `Process` argument (never a shell, never
    /// interpolated into a command), so nothing but a literal timestamp can ever reach
    /// `tmutil`. Mirrors `runFix`'s style.
    func deleteSnapshot(_ date: String, reply: @escaping (Bool, String) -> Void) {
        guard Self.isValidSnapshotDate(date) else { reply(false, "invalid snapshot date"); return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["deletelocalsnapshots", date]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            reply(process.terminationStatus == 0, out.isEmpty ? "done" : out)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    /// Server-side re-validation of the snapshot timestamp — identical to the app-side check
    /// (`SnapshotName.isValidDate`). The helper owns its own copy because it shares no source
    /// with the app or ConsoCore.
    private static let snapshotDateRegex = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2}-\d{6}$"#)

    private static func isValidSnapshotDate(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = snapshotDateRegex.firstMatch(in: s, options: [.anchored], range: range) else { return false }
        return m.range == range
    }

    func version(reply: @escaping (String) -> Void) { reply(ConsoHelper.version) }
}

let delegate = HelperService()
let listener = NSXPCListener(machServiceName: ConsoHelper.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
