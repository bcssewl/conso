import Foundation

// MARK: - Per-target scan result

/// A concrete removable target found by the scanner: an absolute path, its on-disk
/// size, and the category it belongs to. This is exactly what the executor will trash
/// (after a fresh `CleanSafety` check) — there is no separate "delete by glob" path.
public struct CleanTarget: Identifiable, Equatable, Sendable {
    public let path: String
    public let bytes: UInt64
    public let category: CleanCategory
    public var id: String { path }

    public init(path: String, bytes: UInt64, category: CleanCategory) {
        self.path = path
        self.bytes = bytes
        self.category = category
    }

    public var url: URL { URL(fileURLWithPath: path) }
}

/// The scan outcome for one category: its real total size and the concrete targets that
/// make it up. `needsHelper`/`needsFDA` flag categories conso can size but cannot act on
/// without elevated rights or Full Disk Access (surfaced honestly in the UI).
public struct CategoryScan: Equatable, Sendable {
    public let category: CleanCategory
    public let bytes: UInt64
    public let targets: [CleanTarget]
    public let needsHelper: Bool
    public let needsFDA: Bool

    public init(category: CleanCategory, bytes: UInt64, targets: [CleanTarget],
                needsHelper: Bool = false, needsFDA: Bool = false) {
        self.category = category
        self.bytes = bytes
        self.targets = targets
        self.needsHelper = needsHelper
        self.needsFDA = needsFDA
    }
}

// MARK: - Git porcelain helper (pure, TDD'd)

/// Pure helpers for the "is this dev folder safe to delete" decision. Kept separate from
/// the I/O scanner so the dirty-repo rule can be unit-tested against sample porcelain
/// output without a real git repo.
public enum GitStatus {
    /// True if `git status --porcelain` output indicates uncommitted changes (anything
    /// non-empty after trimming). A clean repo prints nothing; ANY line — modified,
    /// untracked (`??`), staged, conflicted — means dirty, so we keep the folder.
    public static func isDirty(porcelain: String) -> Bool {
        !porcelain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - The scanner (I/O)

/// Walks each category's real roots and sums on-disk allocated bytes, returning the
/// concrete target list the executor would remove. Stateless / `Sendable`, mirrors
/// `DiskScanner`: `FileManager.enumerator` with `.totalFileAllocatedSizeKey`, a
/// skip-and-continue error handler, and cooperative `isCancelled` checks. Every target
/// it emits has already passed `CleanSafety.isSafeToDelete` — the scanner never lists a
/// path the executor would refuse.
public struct CleanScanner: Sendable {
    public let safety: CleanSafety
    private let home: URL

    public init(safety: CleanSafety = CleanSafety()) {
        self.safety = safety
        self.home = safety.home
    }

    // MARK: Public entry

    /// Scans every safe category and the hidden items, returning their real sizes +
    /// targets. Off-main; honours `isCancelled` between categories and during walks.
    public func scanAll(isCancelled: @Sendable () -> Bool = { false }) -> [CategoryScan] {
        var out: [CategoryScan] = []
        for category in CleanCategory.allCases {
            if isCancelled() { break }
            out.append(scan(category, isCancelled: isCancelled))
        }
        return out
    }

    /// Scans a single category.
    public func scan(_ category: CleanCategory, isCancelled: @Sendable () -> Bool = { false }) -> CategoryScan {
        switch category {
        case .systemCaches:   return scanFlatCacheChildren(category, root: home.appendingPathComponent("Library/Caches"), isCancelled: isCancelled)
        case .logs:           return scanRoots(category, roots: safety.allowedRoots(for: category), isCancelled: isCancelled)
        case .trash:          return scanFlatChildren(category, root: home.appendingPathComponent(".Trash"), isCancelled: isCancelled)
        case .developerJunk:  return scanDeveloper(isCancelled: isCancelled)
        case .browserData:    return scanBrowsers(isCancelled: isCancelled)
        case .appLeftovers:   return scanAppLeftovers(isCancelled: isCancelled)
        case .apfsSnapshots:  return scanSnapshots()
        case .iosBackups:     return scanIOSBackups(isCancelled: isCancelled)
        case .mailAttachments: return scanMailAttachments(isCancelled: isCancelled)
        }
    }

    // MARK: Generic walkers

    /// Each immediate child of `root` becomes one guarded target sized by subtree.
    private func scanFlatChildren(_ category: CleanCategory, root: URL,
                                  isCancelled: @Sendable () -> Bool) -> CategoryScan {
        let targets = guardedChildren(of: root, category: category, isCancelled: isCancelled)
        return CategoryScan(category: category, bytes: targets.totalBytes, targets: targets)
    }

    /// Like `scanFlatChildren` but for `~/Library/Caches` — each bundle-id child is a
    /// target, skipping any the guard rejects (denylisted ones like MobileSync overlaps).
    private func scanFlatCacheChildren(_ category: CleanCategory, root: URL,
                                       isCancelled: @Sendable () -> Bool) -> CategoryScan {
        let targets = guardedChildren(of: root, category: category, isCancelled: isCancelled)
        return CategoryScan(category: category, bytes: targets.totalBytes, targets: targets)
    }

    /// Sums every existing root directly (the root itself is the target, e.g. Logs).
    private func scanRoots(_ category: CleanCategory, roots: [URL],
                           isCancelled: @Sendable () -> Bool) -> CategoryScan {
        var targets: [CleanTarget] = []
        for root in roots {
            if isCancelled() { break }
            guard exists(root), safety.isSafeToDelete(root, category: category) else { continue }
            let bytes = subtreeBytes(root, isCancelled: isCancelled)
            if bytes > 0 || isDirectory(root) {
                targets.append(CleanTarget(path: root.path, bytes: bytes, category: category))
            }
        }
        return CategoryScan(category: category, bytes: targets.totalBytes, targets: targets)
    }

    /// The immediate children of `root`, each guarded and sized. Children that fail the
    /// safety guard are silently skipped (they were never deletable).
    private func guardedChildren(of root: URL, category: CleanCategory,
                                 isCancelled: @Sendable () -> Bool) -> [CleanTarget] {
        guard let kids = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return [] }
        var targets: [CleanTarget] = []
        for child in kids {
            if isCancelled() { break }
            guard safety.isSafeToDelete(child, category: category) else { continue }
            let bytes = subtreeBytes(child, isCancelled: isCancelled)
            targets.append(CleanTarget(path: child.path, bytes: bytes, category: category))
        }
        return targets.sorted { $0.bytes > $1.bytes }
    }

    // MARK: Developer junk

    /// DerivedData + package-manager caches + git-clean node_modules found bounded-depth
    /// under the dev roots. Each candidate is guarded; node_modules inside a dirty git
    /// repo is excluded (uncommitted work could be lost otherwise).
    private func scanDeveloper(isCancelled: @Sendable () -> Bool) -> CategoryScan {
        var targets: [CleanTarget] = []
        // Fixed cache roots (everything except the node_modules search dirs).
        let nodeSearchDirs = ["Developer", "Projects", "Code", "src"].map { home.appendingPathComponent($0) }
        for root in safety.allowedRoots(for: .developerJunk) {
            if isCancelled() { break }
            if nodeSearchDirs.contains(root) { continue } // handled by the node_modules walk
            guard exists(root), safety.isSafeToDelete(root, category: .developerJunk) else { continue }
            let bytes = subtreeBytes(root, isCancelled: isCancelled)
            targets.append(CleanTarget(path: root.path, bytes: bytes, category: .developerJunk))
        }
        // node_modules discovery (bounded depth ≤4), skipping dirty repos.
        for dir in nodeSearchDirs {
            if isCancelled() { break }
            targets.append(contentsOf: findNodeModules(under: dir, isCancelled: isCancelled))
        }
        return CategoryScan(category: .developerJunk, bytes: targets.totalBytes,
                            targets: targets.sorted { $0.bytes > $1.bytes })
    }

    /// Finds `node_modules` directories up to depth 4 under `base`, excluding any whose
    /// containing git repo is dirty. Does NOT descend into a found `node_modules`.
    func findNodeModules(under base: URL, maxDepth: Int = 4,
                         isCancelled: @Sendable () -> Bool) -> [CleanTarget] {
        guard exists(base) else { return [] }
        var found: [CleanTarget] = []
        var dirtyCache: [String: Bool] = [:]

        func walk(_ dir: URL, depth: Int) {
            if isCancelled() || depth > maxDepth { return }
            guard let kids = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for child in kids {
                if isCancelled() { return }
                guard isDirectory(child) else { continue }
                if child.lastPathComponent == "node_modules" {
                    guard safety.isSafeToDelete(child, category: .developerJunk) else { continue }
                    // Git-dirty rule: keep node_modules in a repo with uncommitted work.
                    let repo = child.deletingLastPathComponent()
                    if isRepoDirty(repo, cache: &dirtyCache) { continue }
                    let bytes = subtreeBytes(child, isCancelled: isCancelled)
                    found.append(CleanTarget(path: child.path, bytes: bytes, category: .developerJunk))
                    // Don't descend into node_modules.
                } else {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(base, depth: 0)
        return found
    }

    /// True if the git repo containing `dir` has uncommitted changes. Resolves the repo
    /// toplevel and runs `git -C <repo> status --porcelain`; a non-repo (`git` missing
    /// or not a worktree) is treated as NOT dirty (no work to lose). Memoised per repo.
    private func isRepoDirty(_ dir: URL, cache: inout [String: Bool]) -> Bool {
        guard let git = Self.gitPath else { return false }
        // Resolve the repo root so sibling node_modules share one status call.
        guard let top = Subprocess.output(git, ["-C", dir.path, "rev-parse", "--show-toplevel"], timeout: 15)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !top.isEmpty else {
            return false // not a git repo → nothing to lose
        }
        if let cached = cache[top] { return cached }
        let porcelain = Subprocess.output(git, ["-C", top, "status", "--porcelain"], timeout: 30) ?? ""
        let dirty = GitStatus.isDirty(porcelain: porcelain)
        cache[top] = dirty
        return dirty
    }

    static var gitPath: String? {
        Subprocess.resolve(["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"])
    }

    // MARK: Browser data

    /// Cache / Code Cache / GPUCache leaves under each browser profile. Never history /
    /// cookies / logins — both the path construction and `CleanSafety` enforce this.
    private func scanBrowsers(isCancelled: @Sendable () -> Bool) -> CategoryScan {
        var targets: [CleanTarget] = []
        let leafNames = ["Cache", "Code Cache", "GPUCache"]
        for profile in browserProfileDirs() {
            if isCancelled() { break }
            for leaf in leafNames {
                let url = profile.appendingPathComponent(leaf)
                guard exists(url), safety.isSafeToDelete(url, category: .browserData) else { continue }
                let bytes = subtreeBytes(url, isCancelled: isCancelled)
                targets.append(CleanTarget(path: url.path, bytes: bytes, category: .browserData))
            }
        }
        return CategoryScan(category: .browserData, bytes: targets.totalBytes,
                            targets: targets.sorted { $0.bytes > $1.bytes })
    }

    /// Enumerates the per-profile directories for the supported Chromium browsers and
    /// Firefox. Chromium keeps profiles as `Default` + `Profile N` under the app-support
    /// root; Firefox uses `Profiles/<id>`.
    private func browserProfileDirs() -> [URL] {
        let support = home.appendingPathComponent("Library/Application Support")
        var dirs: [URL] = []
        let chromium = [
            "Google/Chrome", "Microsoft Edge",
            "BraveSoftware/Brave-Browser", "Arc",
        ]
        for rel in chromium {
            let root = support.appendingPathComponent(rel)
            guard exists(root) else { continue }
            // Profile dirs: Default, Profile 1, Profile 2, …
            if let kids = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for k in kids where isDirectory(k) &&
                    (k.lastPathComponent == "Default" || k.lastPathComponent.hasPrefix("Profile ")) {
                    dirs.append(k)
                }
            }
        }
        // Firefox: Library/Application Support/Firefox/Profiles/<id>; caches live under
        // Library/Caches/Firefox/Profiles/<id> — include both parents.
        let ffProfiles = support.appendingPathComponent("Firefox/Profiles")
        if let kids = try? FileManager.default.contentsOfDirectory(
            at: ffProfiles, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            dirs.append(contentsOf: kids.filter { isDirectory($0) })
        }
        return dirs
    }

    // MARK: App leftovers

    /// Support / cache / preference folders whose owning bundle id is no longer
    /// installed. Cross-references `installedBundleIDs`; only orphans are returned. Always
    /// review (the caller keeps this default-off-ish / requires explicit confirm).
    private func scanAppLeftovers(isCancelled: @Sendable () -> Bool) -> CategoryScan {
        let installed = installedBundleIDs()
        var targets: [CleanTarget] = []
        let containers: [URL] = [
            home.appendingPathComponent("Library/Application Support"),
            home.appendingPathComponent("Library/Caches"),
        ]
        for container in containers {
            if isCancelled() { break }
            guard let kids = try? FileManager.default.contentsOfDirectory(
                at: container, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for child in kids {
                if isCancelled() { break }
                guard isDirectory(child) else { continue }
                let name = child.lastPathComponent
                // Only consider folders that look like a bundle id (reverse-DNS).
                guard looksLikeBundleID(name), !installed.contains(name.lowercased()) else { continue }
                guard safety.isSafeToDelete(child, category: .appLeftovers) else { continue }
                let bytes = subtreeBytes(child, isCancelled: isCancelled)
                targets.append(CleanTarget(path: child.path, bytes: bytes, category: .appLeftovers))
            }
        }
        return CategoryScan(category: .appLeftovers, bytes: targets.totalBytes,
                            targets: targets.sorted { $0.bytes > $1.bytes })
    }

    /// Lowercased bundle ids of every installed `.app` across the standard app folders.
    private func installedBundleIDs() -> Set<String> {
        var ids = Set<String>()
        for app in SoftwareInventory().apps() where !app.bundleID.isEmpty {
            ids.insert(app.bundleID.lowercased())
        }
        return ids
    }

    /// Heuristic: a reverse-DNS-looking folder name (≥2 dot-separated segments, no spaces)
    /// — e.g. `com.acme.app`. Avoids treating plain folders like `Google` as leftovers.
    func looksLikeBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".")
        return parts.count >= 2 && !name.contains(" ") && parts.allSatisfy { !$0.isEmpty }
    }

    // MARK: Hidden items

    /// APFS local snapshots — LISTING only. Deletion needs root (`tmutil deletelocalsnapshots`
    /// + privileges), so this is flagged `needsHelper` and the executor refuses to act.
    /// Sizes aren't directly enumerable from userland, so size is reported as 0 (count via
    /// the target list); the UI shows them as recovery data, helper-gated.
    private func scanSnapshots() -> CategoryScan {
        guard let out = Subprocess.output("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 30) else {
            return CategoryScan(category: .apfsSnapshots, bytes: 0, targets: [], needsHelper: true)
        }
        // Lines look like: com.apple.TimeMachine.2026-06-14-101500.local
        let snaps = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("com.apple.TimeMachine") }
        let targets = snaps.map { CleanTarget(path: $0, bytes: 0, category: .apfsSnapshots) }
        return CategoryScan(category: .apfsSnapshots, bytes: 0, targets: targets, needsHelper: true)
    }

    /// iOS device backups under MobileSync — user-owned, real sizes. Each backup folder is
    /// a target. (The denylist blocks MobileSync for the *cache* categories; this hidden
    /// category has its own allowlist entry, and is default-off + requires explicit action.)
    private func scanIOSBackups(isCancelled: @Sendable () -> Bool) -> CategoryScan {
        let root = home.appendingPathComponent("Library/Application Support/MobileSync/Backup")
        guard exists(root) else { return CategoryScan(category: .iosBackups, bytes: 0, targets: []) }
        var targets: [CleanTarget] = []
        if let kids = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for child in kids where isDirectory(child) {
                if isCancelled() { break }
                guard safety.isSafeToDelete(child, category: .iosBackups) else { continue }
                let bytes = subtreeBytes(child, isCancelled: isCancelled)
                targets.append(CleanTarget(path: child.path, bytes: bytes, category: .iosBackups))
            }
        }
        return CategoryScan(category: .iosBackups, bytes: targets.totalBytes,
                            targets: targets.sorted { $0.bytes > $1.bytes })
    }

    /// Mail attachments under ~/Library/Mail/V*/…/Attachments — needs Full Disk Access to
    /// read. We report the size when readable and flag `needsFDA` when the Mail store is
    /// present but unreadable, so the UI can point the user at the FDA grant.
    private func scanMailAttachments(isCancelled: @Sendable () -> Bool) -> CategoryScan {
        let mail = home.appendingPathComponent("Library/Mail")
        guard exists(mail) else { return CategoryScan(category: .mailAttachments, bytes: 0, targets: []) }
        // If Mail exists but we can't list it, FDA is missing.
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: mail, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return CategoryScan(category: .mailAttachments, bytes: 0, targets: [], needsFDA: true)
        }
        var targets: [CleanTarget] = []
        var sawAny = false
        for version in versions where version.lastPathComponent.hasPrefix("V") {
            if isCancelled() { break }
            let attachments = findAttachmentDirs(under: version, isCancelled: isCancelled)
            for url in attachments {
                sawAny = true
                guard safety.isSafeToDelete(url, category: .mailAttachments) else { continue }
                let bytes = subtreeBytes(url, isCancelled: isCancelled)
                targets.append(CleanTarget(path: url.path, bytes: bytes, category: .mailAttachments))
            }
        }
        let needsFDA = !versions.isEmpty && !sawAny && !DiskScannerHasFDA()
        return CategoryScan(category: .mailAttachments, bytes: targets.totalBytes,
                            targets: targets.sorted { $0.bytes > $1.bytes }, needsFDA: needsFDA)
    }

    /// Finds "Attachments" directories under a Mail version folder (bounded depth).
    private func findAttachmentDirs(under base: URL, isCancelled: @Sendable () -> Bool, maxDepth: Int = 6) -> [URL] {
        var out: [URL] = []
        func walk(_ dir: URL, depth: Int) {
            if isCancelled() || depth > maxDepth { return }
            guard let kids = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for child in kids where isDirectory(child) {
                if child.lastPathComponent == "Attachments" { out.append(child) }
                else { walk(child, depth: depth + 1) }
            }
        }
        walk(base, depth: 0)
        return out
    }

    private func DiskScannerHasFDA() -> Bool { DiskScanner.hasFullDiskAccess() }

    // MARK: Filesystem helpers

    /// On-disk allocated bytes of a subtree (regular files only), skip-and-continue on
    /// unreadable entries. Mirrors `DiskScanner.measureSubtree` / `SoftwareInventory.bundleSize`.
    func subtreeBytes(_ dir: URL, isCancelled: @Sendable () -> Bool) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                      .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey]
        // A single regular file: just its own size.
        if !isDirectory(dir) {
            guard let v = try? dir.resourceValues(forKeys: Set(keys)) else { return 0 }
            return UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        // No cycle guard otherwise: `.skipsSubdirectoryDescendants` is wrong (we need depth),
        // so we rely on the default non-following of the link target plus an explicit skip of
        // any symlinked/alias entry so a directory symlink can't be descended into.
        guard let e = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: keys, options: [],
            errorHandler: { _, _ in true }) else { return 0 }
        var bytes: UInt64 = 0
        for case let url as URL in e {
            if isCancelled() { break }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            // Don't descend into / count symlinked or alias entries (avoids cycles and
            // double-counting the link target's bytes).
            if v.isSymbolicLink == true || v.isAliasFile == true {
                e.skipDescendants()
                continue
            }
            guard v.isRegularFile == true else { continue }
            bytes &+= UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return bytes
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// True only for a REAL directory. A symlink/alias pointing at a directory returns false
    /// so a symlinked `node_modules` (etc.) is never treated as a deletable real dir.
    private func isDirectory(_ url: URL) -> Bool {
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey]),
              v.isDirectory == true,
              v.isSymbolicLink != true,
              v.isAliasFile != true else { return false }
        return true
    }
}

// MARK: - Aggregation helpers

public extension Array where Element == CleanTarget {
    var totalBytes: UInt64 { reduce(0) { $0 + $1.bytes } }

    /// Largest-first ordering with a stable path tiebreak, so any list of targets renders in
    /// the same deterministic order everywhere (clean preview groups, summary top items, …).
    func sortedBySizeThenPath() -> [CleanTarget] {
        sorted(by: CleanTarget.bySizeThenPath)
    }
}

public extension CleanTarget {
    /// The shared "biggest-first, ties broken by path" comparator. One source of truth so the
    /// preview sheet, the summary facts, and anywhere else order targets identically.
    static func bySizeThenPath(_ lhs: CleanTarget, _ rhs: CleanTarget) -> Bool {
        lhs.bytes != rhs.bytes ? lhs.bytes > rhs.bytes : lhs.path < rhs.path
    }
}

// MARK: - Path display helper

/// Shared leaf-name helper so the last-path-component logic isn't reimplemented per call site.
public enum PathName {
    /// The last path component of `path`, falling back to the whole string if empty — used to
    /// name an item without leaking its full (potentially private) path.
    public static func leaf(_ path: String) -> String {
        let leaf = (path as NSString).lastPathComponent
        return leaf.isEmpty ? path : leaf
    }
}
