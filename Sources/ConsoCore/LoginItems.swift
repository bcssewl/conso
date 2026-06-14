import Foundation

/// One launch-time item (LaunchAgent / LaunchDaemon) read from a `.plist`. conso lists
/// these read-only: macOS has no public API to toggle *other* apps' login items, only
/// conso's own (via `SMAppService`, handled in the app layer).
public struct LoginItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case userAgent = "User Agent"       // ~/Library/LaunchAgents
        case globalAgent = "Global Agent"   // /Library/LaunchAgents
        case daemon = "Daemon"              // /Library/LaunchDaemons
    }

    public let label: String                // plist Label (reverse-DNS id)
    public let program: String              // first ProgramArguments entry / Program
    public let runAtLoad: Bool              // starts at login/boot
    public let kind: Kind
    public let path: String                 // the .plist path

    public var id: String { path }

    public init(label: String, program: String, runAtLoad: Bool, kind: Kind, path: String) {
        self.label = label
        self.program = program
        self.runAtLoad = runAtLoad
        self.kind = kind
        self.path = path
    }

    /// A short, human label: the last path component of the program, else the Label.
    public var displayName: String {
        if !program.isEmpty {
            let leaf = (program as NSString).lastPathComponent
            if !leaf.isEmpty { return leaf }
        }
        return label
    }
}

/// Enumerates launch agents/daemons by reading their `.plist` files. Read-only and
/// `Sendable`. Pure Foundation (no ServiceManagement) so it stays in ConsoCore; the
/// app layer adds conso's own item via `SMAppService`.
public struct LoginItemsReader: Sendable {
    public init() {}

    /// The directories scanned, paired with the kind each contains.
    public static var sources: [(URL, LoginItem.Kind)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            (home.appendingPathComponent("Library/LaunchAgents"), .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .globalAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .daemon),
        ]
    }

    /// Reads all readable `.plist` launch items, sorted by display name. Skips missing
    /// or unreadable directories silently (a fresh user may have no LaunchAgents folder).
    public func items() -> [LoginItem] {
        let fm = FileManager.default
        var result: [LoginItem] = []
        for (dir, kind) in Self.sources {
            guard let contents = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for url in contents where url.pathExtension == "plist" {
                if let item = Self.read(url, kind: kind) { result.append(item) }
            }
        }
        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Parses one launchd plist. Returns nil if it can't be read as a dictionary.
    static func read(_ url: URL, kind: LoginItem.Kind) -> LoginItem? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let label = (plist["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let program: String
        if let args = plist["ProgramArguments"] as? [String], let first = args.first {
            program = first
        } else {
            program = (plist["Program"] as? String) ?? ""
        }
        let runAtLoad = (plist["RunAtLoad"] as? Bool) ?? false
        return LoginItem(label: label, program: program, runAtLoad: runAtLoad, kind: kind, path: url.path)
    }
}
