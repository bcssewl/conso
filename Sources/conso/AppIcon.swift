import AppKit
import Darwin

/// Resolves real macOS app icons for the process table and update rows, with a
/// small cache. Returns nil when there's no matching app (e.g. daemons, CLIs) —
/// callers fall back to a lettered placeholder chip.
@MainActor
enum AppIconResolver {
    private static var byName: [String: NSImage?] = [:]
    private static var byPath: [String: NSImage?] = [:]

    /// conso's own app icon (fallback logo mark), loaded once from the bundle.
    static let consoMark: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }()

    /// Icon for a running process. First tries the registered app (GUI apps);
    /// then falls back to the executable's enclosing `.app` bundle, so Electron
    /// helpers ("Chrome Helper (Renderer)") resolve to their parent app's icon.
    static func forRunningProcess(pid: Int) -> NSImage? {
        if let icon = NSRunningApplication(processIdentifier: pid_t(pid))?.icon { return icon }
        guard let path = executablePath(pid: pid), let bundle = enclosingAppBundle(path) else { return nil }
        if let cached = byPath[bundle] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: bundle)
        byPath[bundle] = icon
        return icon
    }

    /// Absolute path of a process's executable, or nil if not permitted/found.
    private static func executablePath(pid: Int) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(count)), as: UTF8.self)
    }

    /// The outermost `.app` bundle containing `path`, e.g.
    /// `/Applications/Google Chrome.app` from a deeply-nested helper executable.
    private static func enclosingAppBundle(_ path: String) -> String? {
        let parts = path.components(separatedBy: "/")
        guard let idx = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return parts[0...idx].joined(separator: "/")
    }

    /// Best-effort icon for an installed app by its display name.
    static func forAppNamed(_ name: String) -> NSImage? {
        if let cached = byName[name] { return cached }
        let icon = locate(name)
        byName[name] = icon
        return icon
    }

    private static func locate(_ name: String) -> NSImage? {
        let dirs = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            let path = "\(dir)/\(name).app"
            if FileManager.default.fileExists(atPath: path) {
                return NSWorkspace.shared.icon(forFile: path)
            }
        }
        return nil
    }
}

/// The per-theme transparent "c + pulse" logo marks (mark-native/pro/character.png).
@MainActor
enum ThemeAssets {
    private static var cache: [String: NSImage?] = [:]

    static func mark(for kind: ThemeKind) -> NSImage? {
        let name: String
        switch kind {
        case .modernNative: name = "mark-native"
        case .proDark:      name = "mark-pro"
        case .character:    name = "mark-character"
        }
        if let cached = cache[name] { return cached }
        let image = Bundle.main.url(forResource: name, withExtension: "png").flatMap { NSImage(contentsOf: $0) }
        cache[name] = image
        return image
    }
}
