import Foundation

/// One installed `.app` bundle, read from its Info.plist. Drives the "Apps" count and
/// the Installed tab. Sizes are on-disk allocated bytes, summed off the main actor.
public struct InstalledApp: Identifiable, Equatable, Sendable {
    public let bundleID: String          // CFBundleIdentifier (or "" if missing)
    public let name: String              // display name (CFBundleDisplayName/Name or file stem)
    public let shortVersion: String      // CFBundleShortVersionString (marketing, e.g. "1.90")
    public let buildVersion: String      // CFBundleVersion (build, e.g. "16040")
    public let path: String              // absolute .app bundle path
    public var bytes: UInt64             // on-disk size (filled in by a second pass)

    /// `bundleID` is unique per app; when missing we fall back to the path.
    public var id: String { bundleID.isEmpty ? path : bundleID }

    public init(bundleID: String, name: String, shortVersion: String, buildVersion: String,
                path: String, bytes: UInt64 = 0) {
        self.bundleID = bundleID
        self.name = name
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.path = path
        self.bytes = bytes
    }

    /// Best version string to show: marketing version, else build, else "—".
    public var displayVersion: String {
        if !shortVersion.isEmpty { return shortVersion }
        if !buildVersion.isEmpty { return buildVersion }
        return "—"
    }
}

/// Enumerates installed `.app` bundles across the standard application folders and
/// reads each one's Info.plist. Stateless and `Sendable`, so it runs on a detached
/// task off the main actor (Info.plist reads + size sums are slow).
public struct SoftwareInventory: Sendable {
    public init() {}

    /// The directories conso scans for installed apps.
    public static var searchDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            home.appendingPathComponent("Applications"),
        ]
    }

    /// Lists installed apps (no sizes), sorted by name. Skips folders that don't
    /// exist or aren't readable. Reads Info.plist for id / versions / display name.
    public func apps() -> [InstalledApp] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [InstalledApp] = []

        for dir in Self.searchDirectories {
            guard let contents = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for url in contents where url.pathExtension == "app" {
                // Dedupe by resolved path (a symlinked app could appear twice).
                let path = url.resolvingSymlinksInPath().path
                guard seen.insert(path).inserted else { continue }
                if let app = Self.readApp(at: url) { result.append(app) }
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Lists installed apps and fills in each one's on-disk size. The size pass is
    /// the expensive part, so callers should run this off the main actor. Honours
    /// `isCancelled` between apps so a re-scan can abandon a slow pass.
    public func appsWithSizes(isCancelled: @Sendable () -> Bool = { false }) -> [InstalledApp] {
        var apps = self.apps()
        for i in apps.indices {
            if isCancelled() { break }
            apps[i].bytes = Self.bundleSize(at: URL(fileURLWithPath: apps[i].path))
        }
        return apps
    }

    /// Reads one `.app` bundle's Info.plist into an `InstalledApp`. Returns nil if the
    /// bundle can't be opened at all (we don't fabricate entries for broken bundles).
    static func readApp(at url: URL) -> InstalledApp? {
        guard let bundle = Bundle(url: url) else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let bundleID = bundle.bundleIdentifier ?? (info["CFBundleIdentifier"] as? String) ?? ""
        let short = (info["CFBundleShortVersionString"] as? String) ?? ""
        let build = (info["CFBundleVersion"] as? String) ?? ""
        let display = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledApp(bundleID: bundleID, name: display, shortVersion: short,
                            buildVersion: build, path: url.path)
    }

    /// On-disk allocated size of a bundle's subtree, in bytes. Uses URL resource keys
    /// (no subprocess); unreadable entries are skipped rather than failing the sum.
    static func bundleSize(at url: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [],
            errorHandler: { _, _ in true }) else { return 0 }
        var bytes: UInt64 = 0
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            bytes &+= UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return bytes
    }
}
