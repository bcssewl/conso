import Foundation

/// One node in the disk map (a top-level folder/category). Sample data until the
/// real disk scanner lands; feeds both the treemap and the "largest folders" list.
public struct DiskEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bytes: UInt64
    public let fileCount: Int

    public init(id: String, name: String, bytes: UInt64, fileCount: Int) {
        self.id = id
        self.name = name
        self.bytes = bytes
        self.fileCount = fileCount
    }
}

public enum AnalyzeCatalog {
    public static let volumeName = "Macintosh HD"
    public static let totalBytes: UInt64 = 1_000_000_000_000   // 1 TB sample volume

    /// Largest-first disk entries.
    public static func entries() -> [DiskEntry] {
        let gb: UInt64 = 1_000_000_000
        return [
            DiskEntry(id: "developer",    name: "Developer",    bytes: 142 * gb, fileCount: 8_214),
            DiskEntry(id: "system",       name: "System",       bytes: 98 * gb,  fileCount: 31_902),
            DiskEntry(id: "photos",       name: "Photos",       bytes: 76 * gb,  fileCount: 22_470),
            DiskEntry(id: "other",        name: "Other",        bytes: 76 * gb,  fileCount: 64_120),
            DiskEntry(id: "movies",       name: "Movies",       bytes: 64 * gb,  fileCount: 312),
            DiskEntry(id: "applications", name: "Applications", bytes: 52 * gb,  fileCount: 1_486),
            DiskEntry(id: "documents",    name: "Documents",    bytes: 38 * gb,  fileCount: 9_640),
            DiskEntry(id: "downloads",    name: "Downloads",    bytes: 22 * gb,  fileCount: 1_204),
            DiskEntry(id: "caches",       name: "Caches",       bytes: 18 * gb,  fileCount: 40_338),
            DiskEntry(id: "music",        name: "Music",        bytes: 14 * gb,  fileCount: 3_102),
            DiskEntry(id: "icloud",       name: "iCloud",       bytes: 12 * gb,  fileCount: 5_880),
        ]
    }

    public static var usedBytes: UInt64 { entries().reduce(0) { $0 + $1.bytes } }
    public static var freeBytes: UInt64 { totalBytes - usedBytes }
    public static var fileCount: Int { entries().reduce(0) { $0 + $1.fileCount } }
}
