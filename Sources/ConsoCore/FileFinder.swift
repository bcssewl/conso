import Foundation
import CryptoKit

// MARK: - File record (what the walk produces)

/// One file the finder considered: its absolute path, on-disk logical size (the byte
/// count used both for same-size grouping and for the reclaimable estimate), and the
/// last-modified / last-accessed dates used by the old-file filter. Stateless / `Sendable`
/// so it can flow off the main actor.
public struct FileRecord: Identifiable, Equatable, Sendable {
    public let path: String
    public let size: UInt64
    public let modified: Date
    public let accessed: Date
    public var id: String { path }

    public init(path: String, size: UInt64, modified: Date, accessed: Date) {
        self.path = path
        self.size = size
        self.modified = modified
        self.accessed = accessed
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { (path as NSString).lastPathComponent }
}

// MARK: - Duplicate group

/// A set of ≥2 files with byte-for-byte identical content (same SHA-256). The first
/// element is the suggested keeper (the others are the trash candidates), but the UI is
/// free to let the user choose which one to keep.
public struct DuplicateGroup: Identifiable, Equatable, Sendable {
    /// The shared content hash (lowercase hex) — also the stable group id.
    public let hash: String
    /// The files in the group, largest-first then path-sorted for stable ordering.
    public let files: [FileRecord]
    public var id: String { hash }

    public init(hash: String, files: [FileRecord]) {
        self.hash = hash
        self.files = files
    }

    /// On-disk size of one copy (they're identical, so any file's size will do).
    public var copyBytes: UInt64 { files.first?.size ?? 0 }
    /// How many duplicate copies exist beyond the one kept.
    public var redundantCount: Int { max(files.count - 1, 0) }
    /// Bytes reclaimable from this group if the user keeps exactly one copy.
    public var reclaimableBytes: UInt64 { copyBytes &* UInt64(redundantCount) }
}

// MARK: - Duplicate finder (pure grouping + streamed hashing)

/// Finds exact, BY-CONTENT duplicates. The expensive content hashing is only ever applied
/// to files that already collide on size — a file with a unique size cannot have a
/// byte-for-byte twin, so it is excluded before any bytes are read.
///
/// Two layers, both pure and testable:
///  1. `sizeBuckets` / grouping — given `(path, size, hash)` metadata, produces the
///     duplicate groups (singletons excluded) with no I/O at all.
///  2. `hash(fileAt:)` — a CryptoKit SHA-256 streamed in fixed-size chunks, so even
///     multi-gigabyte files hash with bounded memory.
public struct DuplicateFinder: Sendable {
    /// Read chunk for streamed hashing (1 MiB). Large enough to amortise syscalls, small
    /// enough that a huge file never loads whole into memory.
    public static let chunkSize = 1 << 20

    public init() {}

    // MARK: Pure grouping (no I/O)

    /// Groups records by size, keeping only buckets with ≥2 members — these are the only
    /// candidates worth hashing. Singletons (unique sizes) can never be content twins.
    /// Zero-byte files are excluded (an empty file is not a meaningful "duplicate" to
    /// reclaim and every empty file would otherwise collide).
    public static func sizeBuckets(_ records: [FileRecord]) -> [UInt64: [FileRecord]] {
        var bySize: [UInt64: [FileRecord]] = [:]
        for r in records where r.size > 0 {
            bySize[r.size, default: []].append(r)
        }
        return bySize.filter { $0.value.count >= 2 }
    }

    /// Builds duplicate groups from records already paired with their content hash. Only
    /// hashes that occur on ≥2 distinct paths become a group; each group's files are
    /// ordered largest-first then by path so ordering is deterministic. Groups themselves
    /// are returned most-reclaimable-first.
    ///
    /// This is the seam the tests drive directly: inject `(path, size, hash)` tuples and
    /// assert the resulting groups — no filesystem required.
    public static func groups(from hashed: [(record: FileRecord, hash: String)]) -> [DuplicateGroup] {
        var byHash: [String: [FileRecord]] = [:]
        for item in hashed {
            byHash[item.hash, default: []].append(item.record)
        }
        return byHash
            .filter { dedupePaths($0.value).count >= 2 }
            .map { hash, files in
                let unique = dedupePaths(files).sorted {
                    $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path
                }
                return DuplicateGroup(hash: hash, files: unique)
            }
            .sorted {
                $0.reclaimableBytes != $1.reclaimableBytes
                    ? $0.reclaimableBytes > $1.reclaimableBytes
                    : $0.hash < $1.hash
            }
    }

    /// Total bytes reclaimable across all groups, keeping one copy of each.
    public static func reclaimableBytes(_ groups: [DuplicateGroup]) -> UInt64 {
        groups.reduce(0) { $0 &+ $1.reclaimableBytes }
    }

    /// Collapses records that share a path (the same file enumerated twice can't be its
    /// own duplicate). Keeps first occurrence.
    private static func dedupePaths(_ files: [FileRecord]) -> [FileRecord] {
        var seen = Set<String>()
        var out: [FileRecord] = []
        for f in files where seen.insert(f.path).inserted { out.append(f) }
        return out
    }

    // MARK: Streamed content hash (real I/O)

    /// SHA-256 of a file's bytes, streamed in `chunkSize` chunks so arbitrarily large
    /// files hash with bounded memory. Returns lowercase hex, or nil if the file can't be
    /// opened/read (skip-and-continue — an unreadable file is simply not grouped).
    /// Honours `isCancelled` between chunks.
    public func hash(fileAt url: URL, isCancelled: @Sendable () -> Bool = { false }) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if isCancelled() { return nil }
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: Self.chunkSize) ?? Data()
            } catch {
                return nil // unreadable mid-stream → skip this file
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Convenience end-to-end: hash each size-collision candidate and assemble the groups.
    /// Files that fail to hash (unreadable) are skipped. Off-main; honours `isCancelled`.
    public func findDuplicates(in records: [FileRecord],
                               isCancelled: @Sendable () -> Bool = { false }) -> [DuplicateGroup] {
        var hashed: [(record: FileRecord, hash: String)] = []
        for (_, bucket) in Self.sizeBuckets(records) {
            if isCancelled() { return [] }
            for r in bucket {
                if isCancelled() { return [] }
                guard let h = hash(fileAt: r.url, isCancelled: isCancelled) else { continue }
                hashed.append((r, h))
            }
        }
        return Self.groups(from: hashed)
    }
}

// MARK: - Old-file finder (pure date filter + sorting)

/// Finds files untouched for a long time. The threshold test is a pure function so the
/// "is this old" decision is unit-testable without touching the clock or the disk.
public struct OldFileFinder: Sendable {
    /// Default age threshold: a file not modified AND not accessed within this many days is
    /// considered old/unused.
    public static let defaultThresholdDays = 365

    /// How many old files to surface (sorted largest-first). A bound keeps a huge home
    /// responsive; the UI notes when results were capped.
    public let limit: Int
    /// Age threshold in days.
    public let thresholdDays: Int

    public init(thresholdDays: Int = OldFileFinder.defaultThresholdDays, limit: Int = 200) {
        self.thresholdDays = thresholdDays
        self.limit = limit
    }

    /// True when a file last touched at `modified` / `accessed` is older than `threshold`
    /// (days) relative to `now`. A file counts as old only if BOTH its modified and
    /// accessed dates are beyond the threshold — recently-read files are kept even if not
    /// recently written.
    public static func isOld(modified: Date, accessed: Date, now: Date, thresholdDays: Int) -> Bool {
        let cutoff = now.addingTimeInterval(-Double(thresholdDays) * 86_400)
        return modified < cutoff && accessed < cutoff
    }

    /// Filters `records` to the old ones (per `isOld`) and returns them largest-first,
    /// capped to `limit`. Pure — `now` is injected.
    public func oldFiles(from records: [FileRecord], now: Date) -> [FileRecord] {
        records
            .filter { Self.isOld(modified: $0.modified, accessed: $0.accessed, now: now, thresholdDays: thresholdDays) }
            .sorted { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
            .prefix(limit)
            .map { $0 }
    }
}
