import Foundation

// MARK: - Scan result

/// The outcome of one finder walk: every regular file found under the chosen root
/// (excluding protected/system subtrees), whether the file-count cap was hit (so the UI
/// can say "showing the first N"), and whether any subtree was skipped (unreadable / FDA).
public struct FileScanResult: Sendable, Equatable {
    public let files: [FileRecord]
    public let capped: Bool
    public let partial: Bool

    public init(files: [FileRecord], capped: Bool, partial: Bool) {
        self.files = files
        self.capped = capped
        self.partial = partial
    }
}

// MARK: - The walk (I/O)

/// Walks a chosen root and collects regular-file metadata for the duplicate / old-file
/// finders. Mirrors `DiskScanner` / `CleanScanner`: `FileManager.enumerator` with resource
/// keys, a skip-and-continue error handler, and cooperative `isCancelled` checks.
///
/// Safety: the walk PRUNES any directory that `CleanSafety` would refuse to delete-protect
/// — i.e. it never descends into the system roots or the protected user roots (Keychains,
/// Mail store, iCloud, etc.). Listing the user's Documents/Desktop IS allowed (the user may
/// legitimately want to find duplicates there), but nothing is ever removed by the walk —
/// deletion is a separate, per-file-guarded step in `FileTrasher`.
///
/// Bounded: stops collecting once `fileLimit` regular files have been recorded (flagging
/// `capped`), so a huge home stays responsive.
public struct FileScanner: Sendable {
    public let safety: CleanSafety
    /// Max regular files to record before stopping (the walk reports `capped` when hit).
    public let fileLimit: Int

    public init(safety: CleanSafety = CleanSafety(), fileLimit: Int = 200_000) {
        self.safety = safety
        self.fileLimit = fileLimit
    }

    /// Directory names never worth walking for user files — caches, VCS internals, app
    /// bundles, and other package-like containers whose innards are not "user documents".
    /// Pruned for performance and to avoid surfacing thousands of irrelevant inner files.
    static let prunedDirNames: Set<String> = [
        "node_modules", ".git", ".svn", ".hg", "Caches", "Cache",
        ".Trash", "DerivedData", ".build", ".gradle", ".cargo",
    ]

    /// Bundle extensions to treat as opaque single items (don't descend) — an app or
    /// document package shouldn't have its internal parts listed as loose files.
    static let opaqueBundleExts: Set<String> = ["app", "framework", "bundle", "photoslibrary", "xcassets"]

    /// Walks `root`, returning regular-file records (skipping protected subtrees). Off-main;
    /// honours `isCancelled` throughout. Unreadable subtrees are skipped and flag `partial`.
    public func scan(_ root: URL, isCancelled: @Sendable () -> Bool = { false }) -> FileScanResult {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
            .contentModificationDateKey, .contentAccessDateKey,
        ]
        var partial = false
        guard let e = fm.enumerator(
            at: root.resolvingSymlinksInPath().standardizedFileURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in partial = true; return true }
        ) else {
            return FileScanResult(files: [], capped: false, partial: true)
        }

        var files: [FileRecord] = []
        var capped = false

        for case let url as URL in e {
            if isCancelled() { break }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }

            // Prune protected / system / package directories — never descend into them.
            if v.isDirectory == true {
                if shouldPrune(url) { e.skipDescendants(); continue }
                continue
            }

            guard v.isRegularFile == true, v.isSymbolicLink != true else { continue }

            let size = UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
            let now = Date()
            let modified = v.contentModificationDate ?? now
            let accessed = v.contentAccessDate ?? modified
            files.append(FileRecord(path: url.path, size: size, modified: modified, accessed: accessed))

            if files.count >= fileLimit { capped = true; break }
        }

        return FileScanResult(files: files, capped: capped, partial: partial)
    }

    /// System-owned roots the walk must never enter (mirrors `CleanSafety`'s private list;
    /// duplicated here because that list isn't exported, and the walk must prune them).
    static let systemRoots: [URL] = [
        "/System", "/usr", "/bin", "/sbin", "/Library", "/private", "/opt",
    ].map { URL(fileURLWithPath: $0) }

    /// True if the walk must NOT descend into `dir`: a sensitive/system subtree, a
    /// pruned-by-name cache/VCS dir, or an opaque bundle package.
    ///
    /// Note: this deliberately does NOT prune the user's Documents / Desktop / Downloads /
    /// media folders. Those stay LISTABLE so the finder can surface duplicates there; the
    /// `FileTrasher` still guards every deletion, and only user-selected files are ever
    /// trashed. What it DOES prune is the credential / sync / system subtree
    /// (`FileSafety.sensitiveRoots`) — never list keychains, the Mail store, iCloud, etc.
    func shouldPrune(_ dir: URL) -> Bool {
        let name = dir.lastPathComponent
        if Self.prunedDirNames.contains(name) { return true }
        if Self.opaqueBundleExts.contains(dir.pathExtension.lowercased()) { return true }
        let resolved = dir.resolvingSymlinksInPath().standardizedFileURL
        for root in FileSafety.sensitiveRoots(home: safety.home)
        where safety.isAtOrInside(resolved, of: root) { return true }
        return false
    }
}

// MARK: - Finder-specific safety roots

/// The protected roots the FILE FINDER honours. Distinct from `CleanSafety.deniedRoots()`
/// (which also denies Documents/Desktop/media so the *cleaner* never touches them): the
/// finder treats user documents as LISTABLE + user-trashable, but credential / sync /
/// browser-login / system subtrees are off-limits to both listing and trashing.
public enum FileSafety {
    /// Credential, sync, message-store, and system roots the finder never lists or trashes.
    /// Drawn from the sensitive subset of `CleanSafety.deniedRoots()` PLUS the system roots.
    public static func sensitiveRoots(home: URL) -> [URL] {
        func h(_ rel: String) -> URL { home.appendingPathComponent(rel) }
        let underHome = [
            "Library/Keychains",
            "Library/Mobile Documents",                 // iCloud Drive
            "Library/Application Support/MobileSync",    // iOS backups
            "Library/Application Support/AddressBook",
            "Library/Messages",
            "Library/Mail",                              // mail store
            "Library/Safari",
            "Library/Cookies",
            "Library/Photos",
            "Library/Containers/com.apple.Photos",
        ].map(h)
        return underHome + FileScanner.systemRoots
    }
}
