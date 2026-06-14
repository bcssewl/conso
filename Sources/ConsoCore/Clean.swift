import Foundation

/// One reclaimable item shown in the Clean pillar — a safe category or a large
/// hidden item. Sizes are sample data until the real scanners land.
public struct CleanItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    /// On-disk size. Starts at 0 (the catalog is a definition) and is filled in by the
    /// real scanner — hence `var`, not `let`.
    public var bytes: UInt64
    public var isSelected: Bool

    public init(id: String, name: String, detail: String, bytes: UInt64, isSelected: Bool) {
        self.id = id
        self.name = name
        self.detail = detail
        self.bytes = bytes
        self.isSelected = isSelected
    }
}

public extension Array where Element == CleanItem {
    var selectedCount: Int { lazy.filter(\.isSelected).count }
    var selectedBytes: UInt64 { lazy.filter(\.isSelected).reduce(0) { $0 + $1.bytes } }
    var totalBytes: UInt64 { reduce(0) { $0 + $1.bytes } }
}

/// The *definition* of what the Clean pillar scans: each row's id matches a
/// `CleanCategory`, with the copy to show. Bytes start at 0 — the real sizes come from
/// `CleanScanner`. The default-selected flags encode safety policy (Trash and all hidden
/// items default OFF; the rest default ON for the light sweep).
public enum CleanCatalog {
    /// Known-safe categories — selected by default except Trash. Sizes filled by the scanner.
    public static func categories() -> [CleanItem] {
        [
            CleanItem(id: CleanCategory.systemCaches.rawValue, name: "System Caches",
                      detail: "clears known-safe cache contents with apps quit · selective, not a blanket wipe",
                      bytes: 0, isSelected: true),
            CleanItem(id: CleanCategory.developerJunk.rawValue, name: "Developer Junk",
                      detail: "DerivedData, node_modules, package caches · skips folders with uncommitted changes",
                      bytes: 0, isSelected: true),
            CleanItem(id: CleanCategory.browserData.rawValue, name: "Browser Data",
                      detail: "caches & temporary files (keeps history & logins)",
                      bytes: 0, isSelected: true),
            CleanItem(id: CleanCategory.appLeftovers.rawValue, name: "App Leftovers",
                      detail: "remnants of apps you've removed · matched by bundle id — review",
                      bytes: 0, isSelected: false),
            CleanItem(id: CleanCategory.logs.rawValue, name: "Logs & Diagnostics",
                      detail: "system, crash & install logs",
                      bytes: 0, isSelected: true),
            CleanItem(id: CleanCategory.trash.rawValue, name: "Trash",
                      detail: "items waiting in the Bin",
                      bytes: 0, isSelected: false),
        ]
    }

    /// Large hidden reclaimers (snapshots, backups, mail) — recovery data, so
    /// NEVER selected by default. This default-off invariant is a safety promise.
    public static func hiddenItems() -> [CleanItem] {
        [
            CleanItem(id: CleanCategory.apfsSnapshots.rawValue, name: "APFS local snapshots",
                      detail: "local Time Machine snapshots — freed automatically under pressure · needs a privileged helper to remove",
                      bytes: 0, isSelected: false),
            CleanItem(id: CleanCategory.iosBackups.rawValue, name: "iOS device backups",
                      detail: "old iPhone/iPad backups in MobileSync · recovery data, review carefully",
                      bytes: 0, isSelected: false),
            CleanItem(id: CleanCategory.mailAttachments.rawValue, name: "Mail attachments",
                      detail: "downloaded mail attachments · needs Full Disk Access · recovery data",
                      bytes: 0, isSelected: false),
        ]
    }

    /// The conservative subset Quick Clean is allowed to touch: caches, dev junk, logs,
    /// trash — NEVER App Leftovers, NEVER any hidden item. Encodes the Quick Clean policy
    /// in one place so the model and tests share it.
    public static let quickCleanCategories: Set<CleanCategory> =
        [.systemCaches, .developerJunk, .browserData, .logs, .trash]
}
