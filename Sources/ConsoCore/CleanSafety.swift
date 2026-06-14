import Foundation

/// The six safe-categories conso can sweep, plus the recovery-data "hidden" items.
/// The id strings match `CleanCatalog`/`CleanItem.id` exactly — they are the contract
/// between the catalog, the scanner, the executor, and the safety guard.
public enum CleanCategory: String, CaseIterable, Sendable {
    case systemCaches   = "system-caches"
    case developerJunk  = "developer-junk"
    case browserData    = "browser-data"
    case appLeftovers   = "app-leftovers"
    case logs           = "logs"
    case trash          = "trash"

    // Hidden / recovery-data items (default off, never auto-deleted).
    case apfsSnapshots  = "apfs-snapshots"
    case iosBackups     = "ios-backups"
    case mailAttachments = "mail-attachments"

    /// Human-readable name for the preview sheet / summaries.
    public var displayName: String {
        switch self {
        case .systemCaches:   return "System Caches"
        case .developerJunk:  return "Developer Junk"
        case .browserData:    return "Browser Data"
        case .appLeftovers:   return "App Leftovers"
        case .logs:           return "Logs & Diagnostics"
        case .trash:          return "Trash"
        case .apfsSnapshots:  return "APFS local snapshots"
        case .iosBackups:     return "iOS device backups"
        case .mailAttachments: return "Mail attachments"
        }
    }
}

/// The pure, exhaustively-tested deletion guard. This is conso's last line of defence:
/// **every** path the executor is about to trash or delete is run through
/// `isSafeToDelete` first, and a single failure aborts the whole run. The design is
/// *default-deny*: a path is removable only if it resolves to a location that has a
/// known-safe allowlist prefix for its category AND does not sit under any protected
/// (deny) prefix. Everything else is rejected.
///
/// All allowlist roots live UNDER THE USER'S HOME — conso never deletes outside it. The
/// guard resolves symlinks and standardizes before checking, so a symlink or `..` escape
/// that lands outside the allowed root is rejected.
///
/// Stateless / `Sendable` so it runs on a detached scan/clean task.
public struct CleanSafety: Sendable {
    /// The user's home directory, resolved + standardized. Injectable so the guard can
    /// be tested against a temp "home" without touching the real one.
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home.resolvingSymlinksInPath().standardizedFileURL
    }

    // MARK: - Allowlist (per category, all under ~)

    /// Known-safe root prefixes for a category, as resolved absolute paths under `home`.
    /// A candidate must resolve to a location strictly *inside* one of these roots (or be
    /// the root itself) to be eligible. These are the ONLY places conso will ever remove
    /// from for that category.
    public func allowedRoots(for category: CleanCategory) -> [URL] {
        func h(_ rel: String) -> URL { home.appendingPathComponent(rel) }
        switch category {
        case .systemCaches:
            return [h("Library/Caches")]
        case .developerJunk:
            return [
                h("Library/Developer/Xcode/DerivedData"),
                h("Library/Caches/org.swift.swiftpm"),
                h("Library/Caches/org.carthage.CarthageKit"),
                h("Library/Caches/Yarn"),
                h("Library/Caches/CocoaPods"),
                h("Library/Caches/pip"),
                h(".npm/_cacache"),
                h(".gradle/caches"),
                h(".cargo/registry/cache"),
                // node_modules discovered bounded-depth under these dev roots only.
                h("Developer"),
                h("Projects"),
                h("Code"),
                h("src"),
            ]
        case .browserData:
            // Only the browser-profile parents — the guard additionally requires the
            // *leaf* to be a cache directory (see isBrowserCacheLeaf).
            return [
                h("Library/Caches"),                                   // many browsers cache here
                h("Library/Application Support/Google/Chrome"),
                h("Library/Application Support/Microsoft Edge"),
                h("Library/Application Support/BraveSoftware/Brave-Browser"),
                h("Library/Application Support/Arc"),
                h("Library/Application Support/Firefox/Profiles"),
                h("Library/Application Support/com.apple.Safari"),
            ]
        case .appLeftovers:
            return [
                h("Library/Application Support"),
                h("Library/Caches"),
                h("Library/Preferences"),
                h("Library/Saved Application State"),
            ]
        case .logs:
            return [
                h("Library/Logs"),
                h("Library/Application Support/CrashReporter"),
            ]
        case .trash:
            return [h(".Trash")]
        case .apfsSnapshots, .iosBackups, .mailAttachments:
            // Hidden items: snapshots need root (deletion deferred to a helper); backups
            // are user-owned under MobileSync; mail attachments under ~/Library/Mail.
            return [
                h("Library/Application Support/MobileSync/Backup"),
                h("Library/Mail"),
            ]
        }
    }

    // MARK: - Denylist (protected paths — never deleted, any category)

    /// Protected path prefixes. A candidate whose resolved path equals or sits under ANY
    /// of these is rejected outright, regardless of category. Covers user documents &
    /// media, credentials, iCloud, device-sync, browser history/cookies/logins, and the
    /// whole system. Default-deny means this list is a backstop, not the only defence.
    public func deniedRoots() -> [URL] {
        func h(_ rel: String) -> URL { home.appendingPathComponent(rel) }
        return [
            // User documents & media.
            h("Documents"), h("Desktop"), h("Pictures"), h("Movies"), h("Music"),
            h("Downloads"), h("Public"),
            h("Library/Photos"),
            h("Library/Containers/com.apple.Photos"),
            // Credentials & sync.
            h("Library/Keychains"),
            h("Library/Mobile Documents"),                  // iCloud Drive
            h("Library/Application Support/MobileSync"),     // iOS backups (hidden item handles its own subset)
            h("Library/Application Support/AddressBook"),
            h("Library/Messages"),
            h("Library/Mail"),                               // mail store (hidden item handles attachments subset)
            // Browser history / cookies / logins — NEVER touched.
            h("Library/Application Support/Google/Chrome/Default/History"),
            h("Library/Application Support/Google/Chrome/Default/Cookies"),
            h("Library/Application Support/Google/Chrome/Default/Login Data"),
            h("Library/Safari"),
            h("Library/Cookies"),
        ]
    }

    /// System-owned roots that are never under `home` but are listed explicitly so an
    /// escaped symlink/`..` that resolves to them is caught by the deny check too.
    private static let systemRoots: [URL] = [
        URL(fileURLWithPath: "/System"),
        URL(fileURLWithPath: "/usr"),
        URL(fileURLWithPath: "/bin"),
        URL(fileURLWithPath: "/sbin"),
        URL(fileURLWithPath: "/Library"),
        URL(fileURLWithPath: "/private"),
        URL(fileURLWithPath: "/opt"),
    ]

    // MARK: - The guard

    /// True only if `url` is safe to remove for `category`. Default-deny: resolves
    /// symlinks + standardizes, requires an allowlist prefix for the category, rejects
    /// anything under a deny prefix, the home root itself, `..` escapes, and (for the
    /// browser category) anything that isn't a recognised cache leaf.
    public func isSafeToDelete(_ url: URL, category: CleanCategory) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL

        // Never the home root itself, never a path that resolves to home or above.
        guard resolved.path != home.path, resolved.path != "/" else { return false }

        // Reject if anything in the (standardized) path still escapes upward — paranoia
        // against `..` that standardizing didn't collapse because the prefix is missing.
        if resolved.pathComponents.contains("..") { return false }

        // Must stay strictly inside the user's home (all our allowlists do).
        guard isInside(resolved, of: home) else { return false }

        // Deny check first — a protected prefix beats any allowlist overlap.
        for denied in deniedRoots() where isAtOrInside(resolved, of: denied) {
            return false
        }
        for denied in Self.systemRoots where isAtOrInside(resolved, of: denied) {
            return false
        }

        // Allowlist: must sit at-or-inside a known-safe root for THIS category.
        let allowed = allowedRoots(for: category).contains { isAtOrInside(resolved, of: $0) }
        guard allowed else { return false }

        // Browser category: only Cache / Code Cache / GPUCache leaves may go — never a
        // profile root (which holds history/cookies/logins).
        if category == .browserData {
            return Self.isBrowserCacheLeaf(resolved)
        }
        return true
    }

    // MARK: - Path containment

    /// True when `child` resolves to a location strictly inside `parent` (parent is a
    /// proper ancestor). Compares full path components so `/a/bc` is NOT inside `/a/b`.
    func isInside(_ child: URL, of parent: URL) -> Bool {
        let c = child.standardizedFileURL.pathComponents
        let p = parent.standardizedFileURL.pathComponents
        guard c.count > p.count else { return false }
        return Array(c.prefix(p.count)) == p
    }

    /// True when `child` is `parent` itself or strictly inside it.
    func isAtOrInside(_ child: URL, of parent: URL) -> Bool {
        let c = child.standardizedFileURL.pathComponents
        let p = parent.standardizedFileURL.pathComponents
        guard c.count >= p.count else { return false }
        return Array(c.prefix(p.count)) == p
    }

    /// True if any path component is a recognised browser *cache* directory. Browsers
    /// keep removable caches in `Cache`, `Code Cache`, `GPUCache`, `Service Worker`'s
    /// `CacheStorage`, etc. — but their history/cookies/logins live elsewhere, so we
    /// require an explicit cache-folder name in the path.
    static func isBrowserCacheLeaf(_ url: URL) -> Bool {
        // The path must contain an explicit cache-folder component. History / cookies /
        // logins live in the profile root (no cache component), so they never match.
        let cacheFolders: Set<String> = [
            "Cache", "Caches", "Code Cache", "GPUCache",
            "CacheStorage", "DawnCache", "ShaderCache", "GrShaderCache",
        ]
        return url.pathComponents.contains { cacheFolders.contains($0) }
    }
}
