import Foundation

/// One executable step of a fix: an absolute tool path, its arguments, and whether it
/// needs root. Root steps are NOT executed by the in-process runner — they're routed to
/// the privileged helper by their `rootCommandKey` (a whitelist id the helper recognises).
/// When no root-runner is wired (or the helper isn't installed), they're skipped honestly.
public struct FixStep: Equatable, Sendable {
    public let executable: String   // absolute path, e.g. "/usr/bin/dscacheutil"
    public let args: [String]
    public let needsRoot: Bool
    /// For a root step, the whitelist command id the privileged helper runs (e.g.
    /// "spotlight", "dns-hup", "fonts-system"). The helper maps this id to a fixed
    /// tool+args allowlist — the app never sends a path/command, only this key. nil for
    /// user-level steps (which run in-process via `executable`/`args`).
    public let rootCommandKey: String?

    public init(executable: String, args: [String], needsRoot: Bool, rootCommandKey: String? = nil) {
        self.executable = executable
        self.args = args
        self.needsRoot = needsRoot
        self.rootCommandKey = rootCommandKey
    }
}

/// A situational repair in the Optimize ("Fix a problem") pillar. These are not
/// routine cleanups: every task is symptom-based and unselected by default.
public struct FixTask: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let detail: String     // "use this when: …"
    public let symbol: String     // SF Symbol name
    public let badge: String      // e.g. "slow", "network"
    public let badgeIsWarm: Bool   // warm = caution (slow/reboot/per-app)
    /// Ordered steps that make up the fix. Some are USER-level (runnable now), some
    /// ROOT-level (routed to the privileged helper). The runner executes USER steps and
    /// routes ROOT steps via their `rootCommandKey` (or skips them if no helper is wired).
    public let steps: [FixStep]
    /// True when the fix targets a specific app and needs a bundle id picked first
    /// (Reset an App's Preferences). The concrete `defaults delete <id>` step is built
    /// at run time once the user chooses the app.
    public let requiresAppPicker: Bool
    /// A pointed warning shown before running (prefs wiped, slow, reboot needed). Empty
    /// when the fix has no special caveat beyond its `detail`.
    public let warning: String
    public var isSelected: Bool

    public init(id: String, name: String, detail: String, symbol: String,
                badge: String, badgeIsWarm: Bool, steps: [FixStep],
                requiresAppPicker: Bool = false, warning: String = "",
                isSelected: Bool = false) {
        self.id = id
        self.name = name
        self.detail = detail
        self.symbol = symbol
        self.badge = badge
        self.badgeIsWarm = badgeIsWarm
        self.steps = steps
        self.requiresAppPicker = requiresAppPicker
        self.warning = warning
        self.isSelected = isSelected
    }

    /// True when ANY step needs root — the fix can't fully complete without the
    /// privileged helper (routed via `rootCommandKey`). Used to flag tasks in the UI.
    public var needsHelper: Bool { steps.contains(where: \.needsRoot) }

    /// The steps the in-process runner can actually execute now (user-level only).
    public var userSteps: [FixStep] { steps.filter { !$0.needsRoot } }

    /// The steps routed to the privileged helper (root-level), by `rootCommandKey`.
    public var rootSteps: [FixStep] { steps.filter(\.needsRoot) }
}

public extension Array where Element == FixTask {
    var selectedCount: Int { lazy.filter(\.isSelected).count }
}

public enum OptimizeCatalog {
    /// Situational fixes — all default-OFF (nothing runs until the user picks it).
    ///
    /// Each fix carries its concrete command steps with an honest user/root split:
    /// USER steps run in-process now; ROOT steps route to the privileged helper by their
    /// `rootCommandKey`, or are surfaced as "needs admin helper" when it isn't installed.
    public static func tasks() -> [FixTask] {
        [
            // ROOT-only: rebuilding the Spotlight index requires privilege. Fully gated.
            FixTask(id: "spotlight", name: "Rebuild Spotlight Index",
                    detail: "use this when: search returns nothing or stale results · can take 30+ min — only if search is broken",
                    symbol: "magnifyingglass", badge: "slow", badgeIsWarm: true,
                    steps: [
                        FixStep(executable: "/usr/bin/mdutil", args: ["-E", "/"], needsRoot: true, rootCommandKey: "spotlight"),
                    ],
                    warning: "Reindexing can take 30+ minutes; search will be incomplete until it finishes."),

            // USER + ROOT: flush runs now; the mDNSResponder HUP needs the helper.
            FixTask(id: "dns", name: "Flush DNS Cache",
                    detail: "use this when: a site won't load but works elsewhere, or after changing DNS",
                    symbol: "globe", badge: "network", badgeIsWarm: false,
                    steps: [
                        FixStep(executable: "/usr/bin/dscacheutil", args: ["-flushcache"], needsRoot: false),
                        FixStep(executable: "/usr/bin/killall", args: ["-HUP", "mDNSResponder"], needsRoot: true, rootCommandKey: "dns-hup"),
                    ]),

            // USER-only: Quick Look rebuild runs entirely without privilege.
            FixTask(id: "quicklook", name: "Rebuild Quick Look",
                    detail: "use this when: spacebar previews are blank or show the wrong file",
                    symbol: "eye", badge: "previews", badgeIsWarm: false,
                    steps: [
                        FixStep(executable: "/usr/bin/qlmanage", args: ["-r"], needsRoot: false),
                        FixStep(executable: "/usr/bin/qlmanage", args: ["-r", "cache"], needsRoot: false),
                    ]),

            // USER + ROOT: the per-user font DB clears now; the system DB needs the helper.
            FixTask(id: "fonts", name: "Clear Font Caches",
                    detail: "use this when: fonts render garbled or boxes appear · needs a reboot to take effect",
                    symbol: "textformat", badge: "reboot", badgeIsWarm: true,
                    steps: [
                        FixStep(executable: "/usr/bin/atsutil", args: ["databases", "-removeUser"], needsRoot: false),
                        FixStep(executable: "/usr/bin/atsutil", args: ["databases", "-remove"], needsRoot: true, rootCommandKey: "fonts-system"),
                    ],
                    warning: "Font caches need a reboot to fully take effect."),

            // USER-only: rebuild the Launch Services database and restart Finder.
            FixTask(id: "launchservices", name: "Reset Launch Services",
                    detail: "use this when: the 'Open With' menu has duplicates or the wrong default app",
                    symbol: "arrow.triangle.2.circlepath", badge: "file menus", badgeIsWarm: false,
                    steps: [
                        FixStep(executable: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister",
                                args: ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"],
                                needsRoot: false),
                        FixStep(executable: "/usr/bin/killall", args: ["Finder"], needsRoot: false),
                    ]),

            // USER-only, but needs a bundle id chosen first. The `defaults delete <id>`
            // step is built at run time once the user picks the app (see FixRunner).
            FixTask(id: "app-prefs", name: "Reset an App's Preferences",
                    detail: "use this when: one app is misbehaving or won't launch · runs defaults delete <bundle-id>",
                    symbol: "gearshape", badge: "per app", badgeIsWarm: true,
                    steps: [],
                    requiresAppPicker: true,
                    warning: "This wipes the app's preferences — there is no undo. Quit the app first."),

            // USER-only: relaunch the Dock and Finder. Both restart themselves instantly,
            // so it's safe and reversible — no privilege needed.
            FixTask(id: "restart-dock-finder", name: "Restart Dock & Finder",
                    detail: "use this when: the Dock is frozen/glitchy or Finder is misbehaving · both relaunch instantly",
                    symbol: "menubar.dock.rectangle", badge: "instant", badgeIsWarm: false,
                    steps: [
                        FixStep(executable: "/usr/bin/killall", args: ["Dock"], needsRoot: false),
                        FixStep(executable: "/usr/bin/killall", args: ["Finder"], needsRoot: false),
                    ]),

            // USER-only: clear the icon-services cache, then relaunch the Dock so icons
            // redraw. macOS regenerates the icons as apps are used.
            FixTask(id: "icon-cache", name: "Rebuild Icon Cache",
                    detail: "use this when: app icons are wrong, blank or blurry · macOS redraws them as you use your apps",
                    symbol: "app.dashed", badge: "icons", badgeIsWarm: false,
                    steps: [
                        FixStep(executable: "/bin/rm", args: ["-rf", iconServicesCachePath], needsRoot: false),
                        FixStep(executable: "/usr/bin/killall", args: ["Dock"], needsRoot: false),
                    ]),
        ]
    }

    /// Absolute path to the per-user Icon Services cache store, whose contents are cleared
    /// by the "Rebuild Icon Cache" fix. Resolved from the user's home so the step carries a
    /// concrete absolute path (matching every other fix step).
    static let iconServicesCachePath: String =
        NSHomeDirectory() + "/Library/Caches/com.apple.iconservices.store"
}
