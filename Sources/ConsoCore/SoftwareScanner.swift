import Foundation

// MARK: - Subprocess helper

/// Runs a command-line tool to completion and returns its stdout as a string, or nil
/// if the tool is missing / fails to launch / exits non-zero. Stderr is discarded.
/// Stateless and `Sendable` — safe to call from a detached task. This is the only
/// place in the software detectors that touches `Process`.
enum Subprocess {
    /// Returns the first existing path from `candidates`, or nil if none exist. Used
    /// to resolve tools (brew, mas) that may live in different prefixes — each detector
    /// fails soft when its tool is absent.
    static func resolve(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `path` with `args` and `extraEnv` merged over the current environment.
    /// Returns stdout (UTF-8) on a clean run, or nil on launch failure. Note: a
    /// non-zero exit still returns stdout when there was any (some tools, like
    /// `softwareupdate`, print useful output and exit non-zero) — callers that need
    /// exit-status semantics should use `runStatus`.
    static func output(_ path: String, _ args: [String], env extraEnv: [String: String] = [:],
                       timeout: TimeInterval = 60) -> String? {
        runStatus(path, args, env: extraEnv, timeout: timeout)?.stdout
    }

    /// Like `output`, but returns the exit status alongside stdout. nil only when the
    /// process could not be launched at all.
    static func runStatus(_ path: String, _ args: [String], env extraEnv: [String: String] = [:],
                          timeout: TimeInterval = 60) -> (status: Int32, stdout: String)? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        if !extraEnv.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in extraEnv { env[k] = v }
            task.environment = env
        }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
        // Read fully before waiting to avoid deadlock if the pipe buffer fills.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Homebrew

/// Parses `brew outdated --json=v2`. The JSON has `formulae[]` and `casks[]`; each
/// entry has `name`, `installed_versions` (array), and `current_version`. We map both
/// into `AppUpdate(source: .homebrew)`, tagging casks so the upgrade routes correctly.
public enum HomebrewParser {
    public static func parse(_ json: String) -> [AppUpdate] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        func updates(_ list: [[String: Any]], isCask: Bool) -> [AppUpdate] {
            list.compactMap { entry in
                guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
                let installed = (entry["installed_versions"] as? [String])?.last ?? ""
                let current = (entry["current_version"] as? String) ?? ""
                guard !current.isEmpty, installed != current else { return nil }
                return AppUpdate(
                    id: "brew:\(name)", name: name, glyph: glyph(name),
                    fromVersion: installed.isEmpty ? "—" : installed, toVersion: current,
                    bytes: 0, source: .homebrew, brewName: name, isCask: isCask)
            }
        }

        let formulae = (root["formulae"] as? [[String: Any]]) ?? []
        let casks = (root["casks"] as? [[String: Any]]) ?? []
        return updates(formulae, isCask: false) + updates(casks, isCask: true)
    }

    private static func glyph(_ name: String) -> String {
        String(name.first.map(Character.init) ?? "•").uppercased()
    }
}

// MARK: - Mac App Store (mas)

/// Parses `mas outdated` lines of the form:
///   `497799835 Xcode (16.0 -> 16.1)`
/// The leading integer is the App-Store adam-id (kept for `macappstore://…/id<id>`).
public enum MASParser {
    public static func parse(_ output: String) -> [AppUpdate] {
        var result: [AppUpdate] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(of: " ") else { continue }
            let id = String(line[..<space])
            guard id.allSatisfy(\.isNumber), !id.isEmpty else { continue }
            var rest = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)

            // Pull the trailing "(<old> -> <new>)" version diff off the end.
            var from = "", to = ""
            if let open = rest.lastIndex(of: "("), rest.hasSuffix(")") {
                let inner = rest[rest.index(after: open)..<rest.index(before: rest.endIndex)]
                let parts = inner.components(separatedBy: "->")
                if parts.count == 2 {
                    from = parts[0].trimmingCharacters(in: .whitespaces)
                    to = parts[1].trimmingCharacters(in: .whitespaces)
                }
                rest = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
            }
            let name = rest.isEmpty ? id : rest
            result.append(AppUpdate(
                id: "mas:\(id)", name: name, glyph: glyph(name),
                fromVersion: from.isEmpty ? "—" : from, toVersion: to.isEmpty ? "—" : to,
                bytes: 0, source: .appStore, masID: id))
        }
        return result
    }

    private static func glyph(_ name: String) -> String {
        String(name.first.map(Character.init) ?? "•").uppercased()
    }
}

// MARK: - macOS system update (softwareupdate)

/// Parses `softwareupdate -l` output for an available macOS update. The relevant
/// shape is a `* Label:` line followed by an indented `Title: …, Version: …, Size: …`
/// line. Returns nil when nothing is available ("No new software available.").
public enum SoftwareUpdateParser {
    public static func parse(_ output: String) -> AppUpdate? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var label: String?
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // The label line: "* Label: macOS Sequoia 15.6-24G..."
            if line.hasPrefix("* Label:") {
                label = line.replacingOccurrences(of: "* Label:", with: "").trimmingCharacters(in: .whitespaces)
                // The detail line usually follows immediately.
                if i + 1 < lines.count {
                    let detail = lines[i + 1].trimmingCharacters(in: .whitespaces)
                    if let update = parseDetail(detail, label: label ?? "") { return update }
                }
            }
        }
        // A label with no parseable detail line: still surface the update by name.
        if let label, !label.isEmpty {
            return AppUpdate(id: "macos", name: titleFromLabel(label), glyph: "",
                             fromVersion: "current", toVersion: "available", bytes: 0,
                             source: .system, remoteVersionKnown: false)
        }
        return nil
    }

    /// Parses the indented "Title: …, Version: …, Size: …KiB, Recommended: YES, …" line.
    private static func parseDetail(_ detail: String, label: String) -> AppUpdate? {
        var fields: [String: String] = [:]
        for part in detail.components(separatedBy: ",") {
            let kv = part.components(separatedBy: ":")
            guard kv.count >= 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces)
            let value = kv[1...].joined(separator: ":").trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        guard let title = fields["Title"], !title.isEmpty else { return nil }
        let version = fields["Version"] ?? ""
        let bytes = sizeBytes(fields["Size"])
        let name = version.isEmpty ? title : "\(title)"
        return AppUpdate(id: "macos", name: name, glyph: "",
                         fromVersion: "current", toVersion: version.isEmpty ? "available" : version,
                         bytes: bytes, source: .system)
    }

    /// `softwareupdate` reports size as a KiB count, e.g. "Size: 3014102KiB".
    private static func sizeBytes(_ size: String?) -> UInt64 {
        guard let size else { return 0 }
        let digits = size.prefix { $0.isNumber }
        guard let kib = UInt64(digits) else { return 0 }
        return kib * 1_024
    }

    /// Cleans a label like "macOS Sequoia 15.6-24G..." into a friendly title.
    private static func titleFromLabel(_ label: String) -> String {
        if let dash = label.firstIndex(of: "-") { return String(label[..<dash]).trimmingCharacters(in: .whitespaces) }
        return label
    }
}

// MARK: - Sparkle (appcast)

/// Parses a Sparkle appcast XML and returns the newest item's build number
/// (`sparkle:version`), short version, and enclosure length (bytes). Sparkle compares
/// the *build* number (`CFBundleVersion`), so that's what we use for the comparison.
public enum SparkleAppcastParser {
    public struct Item: Equatable, Sendable {
        public let build: String         // sparkle:version (== CFBundleVersion)
        public let shortVersion: String  // sparkle:shortVersionString (marketing)
        public let bytes: UInt64         // enclosure length
        public init(build: String, shortVersion: String, bytes: UInt64) {
            self.build = build; self.shortVersion = shortVersion; self.bytes = bytes
        }
    }

    /// Returns the item with the highest numeric build, or the first item if builds
    /// aren't numeric. nil for non-appcast / HTML / empty responses.
    public static func newestItem(_ xml: String) -> Item? {
        let trimmed = xml.trimmingCharacters(in: .whitespacesAndNewlines)
        // Guard against HTML error pages masquerading as an appcast.
        guard trimmed.contains("<item") || trimmed.contains("sparkle:") else { return nil }
        let items = parseItems(xml)
        guard !items.isEmpty else { return nil }
        return items.max { lhs, rhs in
            switch (Int(lhs.build), Int(rhs.build)) {
            case let (l?, r?): return l < r
            default: return false   // non-numeric builds: keep document order (first wins)
            }
        }
    }

    private static func parseItems(_ xml: String) -> [Item] {
        // Lightweight XML scan: split on <item> blocks, pull sparkle attributes /
        // enclosure length from each. Sparkle puts version info either as attributes
        // on <enclosure …> or as <sparkle:version> child elements; handle both.
        var items: [Item] = []
        let blocks = splitBlocks(xml, tag: "item")
        for block in blocks {
            let build = attribute("sparkle:version", in: block)
                ?? element("sparkle:version", in: block) ?? ""
            let short = attribute("sparkle:shortVersionString", in: block)
                ?? element("sparkle:shortVersionString", in: block) ?? ""
            let length = attribute("length", in: block).flatMap { UInt64($0) } ?? 0
            if !build.isEmpty || !short.isEmpty {
                items.append(Item(build: build, shortVersion: short, bytes: length))
            }
        }
        return items
    }

    /// Returns the inner text of each `<tag>…</tag>` block (case-sensitive on the tag).
    private static func splitBlocks(_ xml: String, tag: String) -> [String] {
        var result: [String] = []
        var search = xml[xml.startIndex...]
        let openMarker = "<\(tag)"
        let closeMarker = "</\(tag)>"
        while let open = search.range(of: openMarker) {
            guard let close = search.range(of: closeMarker, range: open.upperBound..<search.endIndex) else { break }
            result.append(String(search[open.lowerBound..<close.upperBound]))
            search = search[close.upperBound...]
        }
        return result
    }

    /// Finds `name="value"` (single or double quotes) anywhere in `block`.
    private static func attribute(_ name: String, in block: String) -> String? {
        for quote in ["\"", "'"] {
            let marker = "\(name)=\(quote)"
            guard let r = block.range(of: marker) else { continue }
            guard let end = block.range(of: quote, range: r.upperBound..<block.endIndex) else { continue }
            return String(block[r.upperBound..<end.lowerBound])
        }
        return nil
    }

    /// Finds `<name>value</name>` child element text.
    private static func element(_ name: String, in block: String) -> String? {
        guard let open = block.range(of: "<\(name)>"),
              let close = block.range(of: "</\(name)>", range: open.upperBound..<block.endIndex) else { return nil }
        return String(block[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Live scanner (I/O)

/// Runs the real update detectors. Stateless / `Sendable` so it executes on a detached
/// task. Each detector fails soft: a missing tool or network error yields no rows, not
/// an error — conso shows honest empty states rather than fake updates.
public struct SoftwareScanner: Sendable {
    public init() {}

    /// Resolves the `brew` executable across Apple-silicon / Intel prefixes.
    public static var brewPath: String? {
        Subprocess.resolve(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"])
    }

    /// Resolves the `mas` executable, if installed.
    public static var masPath: String? {
        Subprocess.resolve(["/opt/homebrew/bin/mas", "/usr/local/bin/mas"])
    }

    // MARK: Homebrew

    /// `brew outdated --json=v2` (with auto-update disabled). Empty if brew is absent.
    public func homebrewUpdates() -> [AppUpdate] {
        guard let brew = Self.brewPath else { return [] }
        guard let out = Subprocess.output(
            brew, ["outdated", "--json=v2"],
            env: ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1"],
            timeout: 90) else { return [] }
        return HomebrewParser.parse(out)
    }

    // MARK: Mac App Store

    /// `mas outdated` when `mas` is installed; otherwise falls back to flagging apps
    /// that carry an App-Store receipt (`_MASReceipt/receipt`) with an unknown remote
    /// version, so the user still sees they're App-Store-managed.
    public func appStoreUpdates(installed: [InstalledApp]) -> [AppUpdate] {
        if let mas = Self.masPath, let out = Subprocess.output(mas, ["outdated"], timeout: 60) {
            return MASParser.parse(out)
        }
        // Fallback: no `mas`. We can't know remote versions, so we don't invent
        // updates — we only mark apps as App-Store-provenance. The model decides
        // whether to surface these; we return them with remoteVersionKnown == false.
        return installed.compactMap { app in
            let receipt = URL(fileURLWithPath: app.path)
                .appendingPathComponent("Contents/_MASReceipt/receipt")
            guard FileManager.default.fileExists(atPath: receipt.path) else { return nil }
            return AppUpdate(
                id: "mas-receipt:\(app.id)", name: app.name, glyph: glyph(app.name),
                fromVersion: app.displayVersion, toVersion: "App Store", bytes: 0,
                source: .appStore, bundlePath: app.path, remoteVersionKnown: false)
        }
    }

    // MARK: Sparkle

    /// For every installed app whose Info.plist declares an `SUFeedURL`, fetches the
    /// appcast and compares its newest build to the bundle's `CFBundleVersion`. Apps
    /// without a feed, or whose feed errors / isn't newer, contribute nothing.
    public func sparkleUpdates(installed: [InstalledApp], session: URLSession = .shared) async -> [AppUpdate] {
        var result: [AppUpdate] = []
        for app in installed {
            guard let feed = Self.feedURL(forBundleAt: app.path) else { continue }
            guard let item = await fetchAppcast(feed, session: session) else { continue }
            guard Self.isNewer(remoteBuild: item.build, localBuild: app.buildVersion) else { continue }
            result.append(AppUpdate(
                id: "sparkle:\(app.id)", name: app.name, glyph: glyph(app.name),
                fromVersion: app.displayVersion,
                toVersion: item.shortVersion.isEmpty ? item.build : item.shortVersion,
                bytes: item.bytes, source: .sparkle, bundlePath: app.path))
        }
        return result
    }

    /// Reads the `SUFeedURL` from a bundle's Info.plist (the Sparkle appcast endpoint).
    static func feedURL(forBundleAt path: String) -> URL? {
        guard let bundle = Bundle(url: URL(fileURLWithPath: path)),
              let feed = bundle.infoDictionary?["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    /// Fetches + parses one appcast. Returns nil on any network / decode / non-2xx
    /// failure or an HTML error page — the app simply isn't flagged for update.
    private func fetchAppcast(_ url: URL, session: URLSession) async -> SparkleAppcastParser.Item? {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("conso", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
        return SparkleAppcastParser.newestItem(String(decoding: data, as: UTF8.self))
    }

    /// True when `remoteBuild` is strictly greater than `localBuild`. Compares numeric
    /// builds when both parse; otherwise falls back to a dotted-version comparison.
    static func isNewer(remoteBuild: String, localBuild: String) -> Bool {
        if let r = Int(remoteBuild), let l = Int(localBuild) { return r > l }
        return compareDotted(remoteBuild, localBuild) == .orderedDescending
    }

    /// Compares dotted version strings component-by-component, numerically.
    static func compareDotted(_ a: String, _ b: String) -> ComparisonResult {
        let ac = a.split(separator: ".").map { Int($0) ?? 0 }
        let bc = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(ac.count, bc.count) {
            let av = i < ac.count ? ac[i] : 0
            let bv = i < bc.count ? bc[i] : 0
            if av != bv { return av < bv ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: Electron (best-effort)

    /// Detects Electron apps by their bundled framework and surfaces the current
    /// version with an *unknown* remote version (we can't poll Electron release feeds
    /// generically). Honest by construction: `remoteVersionKnown == false`.
    public func electronUpdates(installed: [InstalledApp]) -> [AppUpdate] {
        installed.compactMap { app in
            let framework = URL(fileURLWithPath: app.path)
                .appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
            guard FileManager.default.fileExists(atPath: framework.path) else { return nil }
            // Skip apps already covered by a Sparkle feed (those get a real comparison).
            guard Self.feedURL(forBundleAt: app.path) == nil else { return nil }
            return AppUpdate(
                id: "electron:\(app.id)", name: app.name, glyph: glyph(app.name),
                fromVersion: app.displayVersion, toVersion: "in-app", bytes: 0,
                source: .electron, bundlePath: app.path, remoteVersionKnown: false)
        }
    }

    // MARK: macOS system update

    /// `softwareupdate -l` parsed into the single system row, or nil if none / no tool.
    public func systemUpdate() -> AppUpdate? {
        guard let out = Subprocess.output(
            "/usr/sbin/softwareupdate", ["-l"], timeout: 120) else { return nil }
        return SoftwareUpdateParser.parse(out)
    }

    private func glyph(_ name: String) -> String {
        String(name.first.map(Character.init) ?? "•").uppercased()
    }
}
