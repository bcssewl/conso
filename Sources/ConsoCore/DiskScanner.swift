import Foundation

/// Volume capacity figures for a mounted filesystem.
public struct VolumeStats: Sendable, Equatable {
    public let name: String
    public let total: UInt64
    public let free: UInt64
    public let fsName: String

    public var used: UInt64 { total > free ? total - free : 0 }

    public init(name: String, total: UInt64, free: UInt64, fsName: String) {
        self.name = name
        self.total = total
        self.free = free
        self.fsName = fsName
    }
}

/// The aggregate of one `scanChildren` pass: the per-child entries plus whether any
/// subtree was skipped (unreadable directory / permission denied) so the caller can
/// flag the map as partial.
public struct ScanResult: Sendable, Equatable {
    public let entries: [DiskEntry]
    public let partial: Bool

    public init(entries: [DiskEntry], partial: Bool) {
        self.entries = entries
        self.partial = partial
    }

    /// Total on-disk bytes across all immediate children.
    public var totalBytes: UInt64 { entries.reduce(0) { $0 + $1.bytes } }
    /// Total file count across all immediate children.
    public var totalFiles: Int { entries.reduce(0) { $0 + $1.fileCount } }
}

/// Real on-disk scanner. Stateless and `Sendable` so it can run on a detached task
/// off the main actor. Sizes are *on-disk allocated* bytes (what the filesystem
/// actually reserves), summed recursively per immediate child of a directory.
public struct DiskScanner: Sendable {
    public init() {}

    /// Lists the immediate children of `root` and, for each, recursively sums the
    /// on-disk allocated size and file count of its subtree. A child that is a single
    /// file contributes its own size and a count of 1.
    ///
    /// Unreadable subtrees are skipped (not fatal): the enumerator's error handler
    /// returns `true` to keep going, and the result is flagged `partial` if anything
    /// was skipped. Honours `isCancelled` between children and during enumeration.
    /// Entries come back sorted largest-first; `DiskEntry.id` is the child's path.
    public func scan(_ root: URL, isCancelled: @Sendable () -> Bool = { false }) -> ScanResult {
        let fm = FileManager.default
        let childKeys: [URLResourceKey] = [.isDirectoryKey]
        let children: [URL]
        do {
            children = try fm.contentsOfDirectory(at: root,
                                                  includingPropertiesForKeys: childKeys,
                                                  options: [])
        } catch {
            // The root itself was unreadable — nothing to list, but flag it partial.
            return ScanResult(entries: [], partial: true)
        }

        var entries: [DiskEntry] = []
        var partial = false

        for child in children {
            if isCancelled() { break }
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                let measured = measureSubtree(child, fm: fm, isCancelled: isCancelled)
                partial = partial || measured.skipped
                entries.append(DiskEntry(id: child.path, name: child.lastPathComponent,
                                         bytes: measured.bytes, fileCount: measured.files))
            } else {
                entries.append(DiskEntry(id: child.path, name: child.lastPathComponent,
                                         bytes: fileSize(child), fileCount: 1))
            }
        }

        entries.sort { $0.bytes > $1.bytes }
        return ScanResult(entries: entries, partial: partial)
    }

    /// Convenience: just the sorted entries.
    public func scanChildren(of root: URL, isCancelled: @Sendable () -> Bool = { false }) -> [DiskEntry] {
        scan(root, isCancelled: isCancelled).entries
    }

    /// Immediate children of `root` (unsorted). Empty if `root` is unreadable.
    /// Used by the streaming scan path so each child can be measured + published
    /// one at a time for live progress.
    public func childURLs(of root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: root,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [])) ?? []
    }

    /// Measures one immediate child — recursively if it's a directory, or its own
    /// size if it's a file. Returns the entry plus whether any subtree was skipped.
    public func measureChild(_ child: URL, isCancelled: @Sendable () -> Bool = { false })
        -> (entry: DiskEntry, skipped: Bool) {
        let fm = FileManager.default
        let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDir {
            let m = measureSubtree(child, fm: fm, isCancelled: isCancelled)
            return (DiskEntry(id: child.path, name: child.lastPathComponent, bytes: m.bytes, fileCount: m.files), m.skipped)
        }
        return (DiskEntry(id: child.path, name: child.lastPathComponent, bytes: fileSize(child), fileCount: 1), false)
    }

    // MARK: - Subtree measurement

    private func measureSubtree(_ dir: URL, fm: FileManager,
                                isCancelled: @Sendable () -> Bool) -> (bytes: UInt64, files: Int, skipped: Bool) {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        var skipped = false
        // The error handler returns true to SKIP the unreadable item and keep enumerating;
        // we record that we degraded so the caller can flag a partial map.
        let enumerator = fm.enumerator(at: dir,
                                       includingPropertiesForKeys: keys,
                                       options: [],
                                       errorHandler: { _, _ in skipped = true; return true })
        guard let enumerator else { return (0, 0, true) }

        var bytes: UInt64 = 0
        var files = 0
        for case let url as URL in enumerator {
            if isCancelled() { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            bytes &+= UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            files += 1
        }
        return (bytes, files, skipped)
    }

    private func fileSize(_ url: URL) -> UInt64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        return UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }

    // MARK: - Volume stats

    /// Reads name / capacity / free-space / filesystem description for the volume
    /// that `url` lives on. `free` uses the "important usage" figure macOS reports
    /// (what the user can actually reclaim), and `used` is derived as total − free.
    public func volumeStats(for url: URL) -> VolumeStats? {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeLocalizedFormatDescriptionKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let name = values.volumeName ?? url.lastPathComponent
        let total = UInt64(values.volumeTotalCapacity ?? 0)
        let free = UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        let fsName = values.volumeLocalizedFormatDescription ?? ""
        return VolumeStats(name: name, total: total, free: free, fsName: fsName)
    }

    // MARK: - Full Disk Access probe

    /// Probes (live, never cached) whether the app currently has Full Disk Access by
    /// attempting to memory-map a TCC-protected file. There is no read-only status
    /// API for FDA, so the only truth is attempting a protected read. Returns `true`
    /// only if a protected path could actually be opened.
    public static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Paths that require Full Disk Access to read. The first one that opens proves
        // the grant; if none open, we treat FDA as missing.
        let probes = [
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"),
            home.appendingPathComponent("Library/Mail"),
            home.appendingPathComponent("Library/Safari/History.db"),
        ]
        for url in probes {
            if (try? Data(contentsOf: url, options: .mappedIfSafe)) != nil { return true }
            // A directory (e.g. ~/Library/Mail) can't be mapped as Data; if it exists
            // and is listable, that also proves access.
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
               (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil {
                return true
            }
        }
        return false
    }
}
