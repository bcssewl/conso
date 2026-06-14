import Foundation
import Observation

/// One drill-down level in the Analyze breadcrumb trail: the directory and the
/// label to show for it.
public struct AnalyzeCrumb: Identifiable, Equatable, Sendable {
    public let url: URL
    public let label: String
    public var id: String { url.path }

    public init(url: URL, label: String) {
        self.url = url
        self.label = label
    }
}

/// Drives the Analyze page: scans a directory's immediate children off the main
/// actor, publishes the result for the treemap + largest-folders list, and tracks
/// the drill-down path for the breadcrumb trail. Scans are cancellable — drilling
/// in / out / rescanning cancels any in-flight scan before starting the next.
///
/// Lives in ConsoCore (no SwiftUI dependency) and is `@MainActor` so its observable
/// state can be read directly from the view.
@MainActor
@Observable
public final class AnalyzeModel {
    /// The volume root used to derive volume stats and the first breadcrumb label.
    public let rootURL: URL
    /// The drill-down trail (root first). The last element is the directory shown.
    public private(set) var path: [URL]
    /// Immediate children of the current directory, largest-first.
    public private(set) var entries: [DiskEntry] = []
    /// Capacity figures for the volume the root lives on.
    public private(set) var volume: VolumeStats?
    /// Total files counted in the current directory's subtree.
    public private(set) var fileCount: Int = 0
    /// A scan is currently running.
    public private(set) var isScanning = false
    /// How many of the current directory's children have been measured so far.
    public private(set) var scannedCount = 0
    /// How many children the current directory has (the scan's denominator).
    public private(set) var totalChildren = 0
    /// The current map is incomplete (a subtree was skipped, or FDA is missing).
    public private(set) var partial = false
    /// Whether Full Disk Access is currently granted (probed live on each scan).
    public private(set) var fdaGranted = false

    @ObservationIgnored private let scanner = DiskScanner()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var didStart = false

    /// - Parameter root: the directory to show first. Defaults to the user's home.
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.rootURL = root
        self.path = [root]
    }

    /// The directory currently being shown (deepest level of the trail).
    public var currentURL: URL { path.last ?? rootURL }

    /// Total on-disk bytes across the current directory's children.
    public var usedBytes: UInt64 { entries.reduce(0) { $0 + $1.bytes } }

    /// The largest child, if any.
    public var largest: DiskEntry? { entries.first }

    /// Breadcrumb trail: the volume name for the root, then each path component.
    public var breadcrumbs: [AnalyzeCrumb] {
        path.enumerated().map { i, url in
            let label = i == 0 ? (volume?.name ?? url.lastPathComponent) : url.lastPathComponent
            return AnalyzeCrumb(url: url, label: label)
        }
    }

    /// Kicks off the first scan. Safe to call repeatedly (only the first runs).
    public func start() {
        guard !didStart else { return }
        didStart = true
        volume = scanner.volumeStats(for: rootURL)
        scan(currentURL)
    }

    /// Drills into `entry` if it is a readable directory; no-op for plain files.
    public func drillInto(_ entry: DiskEntry) {
        let url = URL(fileURLWithPath: entry.id)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        path.append(url)
        scan(url)
    }

    /// Jumps to breadcrumb `index`, truncating deeper levels, and rescans it.
    public func popTo(_ index: Int) {
        guard path.indices.contains(index) else { return }
        guard index < path.count - 1 else { return } // already here
        path.removeLast(path.count - 1 - index)
        scan(currentURL)
    }

    /// Re-runs the scan of the current directory.
    public func rescan() { scan(currentURL) }

    // MARK: - Scanning

    /// Cancels any in-flight scan and scans `dir` off the main actor. Children are
    /// measured one at a time and published as they complete, so the treemap and the
    /// largest-folders list fill in progressively (biggest-first) with a live count,
    /// rather than appearing all at once. FDA is probed live so the banner is accurate.
    public func scan(_ dir: URL) {
        task?.cancel()
        isScanning = true
        entries = []
        fileCount = 0
        scannedCount = 0
        totalChildren = 0
        partial = false
        let scanner = self.scanner
        let task = Task.detached(priority: .utility) { [scanner] in
            let fda = DiskScanner.hasFullDiskAccess()
            let children = scanner.childURLs(of: dir)
            await MainActor.run { [weak self] in
                guard let self, dir == self.currentURL else { return }
                self.totalChildren = children.count
                self.fdaGranted = fda
                self.partial = !fda
            }
            var acc: [DiskEntry] = []
            var skippedAny = false
            for (i, child) in children.enumerated() {
                if Task.isCancelled { return }
                let measured = scanner.measureChild(child, isCancelled: { Task.isCancelled })
                if Task.isCancelled { return }
                skippedAny = skippedAny || measured.skipped
                if measured.entry.bytes > 0 || measured.entry.fileCount > 0 { acc.append(measured.entry) }
                let snapshot = acc.sorted { $0.bytes > $1.bytes }
                let files = acc.reduce(0) { $0 + $1.fileCount }
                let done = i + 1
                let skipped = skippedAny
                await MainActor.run { [weak self] in
                    guard let self, dir == self.currentURL else { return }
                    self.entries = snapshot
                    self.fileCount = files
                    self.scannedCount = done
                    self.partial = skipped || !fda
                }
            }
            await MainActor.run { [weak self] in
                guard let self, dir == self.currentURL else { return }
                self.isScanning = false
            }
        }
        self.task = task
    }
}
