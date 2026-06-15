import SwiftUI
import AppKit
import ConsoCore

// MARK: - Pillars (top-centered glass pill nav)

enum Pillar: String, CaseIterable, Identifiable {
    case clean = "Clean", software = "Software", optimize = "Optimize", analyze = "Analyze", status = "Status"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .clean: return "sparkles"
        case .software: return "shippingbox"
        case .optimize: return "bolt"
        case .analyze: return "chart.bar"
        case .status: return "waveform.path.ecg"
        }
    }
}

// MARK: - Reusable bits

struct Sparkline: View {
    var values: [Double]
    var color: Color
    var body: some View {
        GeometryReader { geo in
            Path { p in
                guard values.count > 1 else { return }
                let w = geo.size.width, h = geo.size.height
                for (i, v) in values.enumerated() {
                    let x = w * CGFloat(i) / CGFloat(values.count - 1)
                    let y = h * (1 - CGFloat(max(0, min(1, v))))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

struct Meter: View {
    var fraction: Double
    var color: Color
    var track: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(color).frame(width: g.size.width * CGFloat(max(0, min(1, fraction))))
            }
        }
        .frame(height: 7)
    }
}

struct Ring: View {
    var fraction: Double
    var color: Color
    var track: Color
    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: 9)
            Circle().trim(from: 0, to: CGFloat(max(0, min(1, fraction))))
                .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct Panel<Content: View>: View {
    let t: Tokens
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
            .consoCard(t)
    }
}

func clabel(_ text: String, _ t: Tokens) -> some View {
    Text(text.uppercased())
        .font(.system(size: 11, weight: .semibold))
        .tracking(0.4)
        .foregroundStyle(t.text2)
}

// MARK: - Top bar

struct TopBar: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(Router.self) private var router
    @Environment(MetricsViewModel.self) private var metrics
    @Environment(\.colorScheme) private var scheme
    @State private var showSettings = false
    @State private var showDoctor = false
    // Real figures from the live models (0 = not scanned yet → no badge shown).
    var cleanBytes: UInt64 = 0
    var softwareCount: Int = 0
    /// Opens the "Ask conso" command bar (⌘K). Optional so other call sites compile.
    var onAskConso: () -> Void = {}

    var body: some View {
        let t = theme.tokens(scheme)
        HStack(spacing: 10) {
            Color.clear.frame(width: 60, height: 1) // room for traffic lights
            Spacer(minLength: 0)
            navPill(t)
            Spacer(minLength: 0)
            iconButton(t, "sparkle.magnifyingglass", help: "Ask conso (⌘K)", action: onAskConso)
            iconButton(t, "stethoscope", help: "Run Doctor") { showDoctor = true }
            iconButton(t, "gearshape", help: "Settings") { showSettings.toggle() }
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { SettingsPopover() }
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .sheet(isPresented: $showDoctor) {
            DoctorView(snapshot: metrics.snapshot, topProcesses: metrics.processes.map(\.name))
        }
    }

    private func navPill(_ t: Tokens) -> some View {
        HStack(spacing: 2) {
            ForEach(Pillar.allCases) { p in
                let active = router.pillar == p
                Button { router.pillar = p } label: {
                    HStack(spacing: 6) {
                        Image(systemName: p.symbol).font(.system(size: 12, weight: .semibold))
                        Text(p.rawValue).font(.system(size: 13, weight: .semibold))
                        if let badge = navBadge(p) {
                            Text(badge).font(.system(size: 10, weight: .bold))
                                .foregroundStyle(active ? t.navActiveText : t.accent)
                                .padding(.vertical, 1).padding(.horizontal, 5)
                                .background(active ? AnyShapeStyle(t.navActiveText.opacity(0.18)) : AnyShapeStyle(t.accentSoft), in: Capsule())
                        }
                    }
                    .padding(.vertical, 7).padding(.horizontal, 13)
                    .foregroundStyle(active ? t.navActiveText : t.text2)
                    .background(active ? AnyShapeStyle(t.navActive) : AnyShapeStyle(Color.clear), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(t.glass ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(t.navBG), in: Capsule())
        .overlay(Capsule().strokeBorder(t.cardBorder, lineWidth: t.glass ? 1 : 0))
    }

    private func iconButton(_ t: Tokens, _ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .foregroundStyle(t.text2)
                .frame(width: 30, height: 30)
                .background(t.glass ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(t.navBG), in: Circle())
                .overlay(Circle().strokeBorder(t.cardBorder, lineWidth: t.glass ? 1 : 0))
        }
        .buttonStyle(.plain).help(help)
    }

    /// Nav badges: Clean shows reclaimable size, Software shows update count.
    private func navBadge(_ p: Pillar) -> String? {
        switch p {
        case .clean: return cleanBytes > 0 ? ByteFormat.string(cleanBytes) : nil
        case .software: return softwareCount > 0 ? "\(softwareCount)" : nil
        default: return nil
        }
    }
}

// MARK: - Settings popover

struct SettingsPopover: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var updater: UpdaterController
    @State private var helperMsg = ""
    @State private var helperBusy = false
    // Launch-at-login mirrors SMAppService.mainApp; seeded from the real status and
    // re-read whenever the toggle attempt finishes so the UI always reflects reality.
    @State private var launchAtLogin = LoginItemService.isEnabled
    @State private var onboardingReset = false
    // Scheduled auto-clean: the app's SINGLE shared scheduler (injected from `ConsoApp`), so
    // toggling never registers a duplicate `NSBackgroundActivityScheduler`. The toggle/picker
    // state is seeded from it in `.onAppear` (which already re-reads the persisted settings).
    @Environment(AutoCleanScheduler.self) private var autoClean
    @State private var autoCleanEnabled = false
    @State private var autoCleanInterval: CleanScheduleInterval = .weekly

    // Placeholder destinations until the real site/repo exist.
    private static let websiteURL = URL(string: "https://conso.app")!
    private static let githubURL = URL(string: "https://github.com/bcssewl/conso")!

    var body: some View {
        @Bindable var theme = theme
        let t = theme.tokens(scheme)
        VStack(alignment: .leading, spacing: 14) {
            Text("Appearance").font(.system(size: 13, weight: .semibold)).foregroundStyle(t.text)
            VStack(alignment: .leading, spacing: 7) {
                Text("THEME").font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(t.text3)
                SegmentedPills(t: t, options: ThemeKind.allCases, selection: $theme.kind) { $0.rawValue }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("MODE").font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(t.text3)
                SegmentedPills(t: t, options: Appearance.allCases, selection: $theme.appearance) { $0.rawValue }
                    .disabled(theme.kind == .proDark)
                    .opacity(theme.kind == .proDark ? 0.5 : 1)
            }
            if theme.kind == .proDark {
                Text("Pro Dark is always dark.").font(.system(size: 11)).foregroundStyle(t.text3)
            }
            Divider()
            generalSection(t)
            Divider()
            autoCleanSection(t)
            Divider()
            updatesSection(t)
            Divider()
            helperSection(t)
            Divider()
            aboutSection(t)
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - General (launch at login + reset onboarding)

    @ViewBuilder
    private func generalSection(_ t: Tokens) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("GENERAL").font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(t.text3)
            Toggle(isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    LoginItemService.setEnabled(newValue)
                    // Re-read the authoritative status so a failed register/unregister
                    // doesn't leave the switch out of sync with the system.
                    launchAtLogin = LoginItemService.isEnabled
                }
            )) {
                Text("Launch conso at login")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(t.text)
            }
            .toggleStyle(.switch)
            .tint(t.accent)
            .onAppear { launchAtLogin = LoginItemService.isEnabled }

            HStack {
                Text("Onboarding")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(t.text)
                Spacer()
                ConsoButton(t: t, title: onboardingReset ? "Will show on relaunch" : "Reset", kind: .ghost) {
                    // Write the default directly — ConsoApp reads "didOnboard" via @AppStorage.
                    UserDefaults.standard.set(false, forKey: "didOnboard")
                    onboardingReset = true
                }
            }
        }
    }

    // MARK: - Scheduled auto-clean (off by default)

    @ViewBuilder
    private func autoCleanSection(_ t: Tokens) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("AUTO-CLEAN").font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(t.text3)
            Toggle(isOn: Binding(
                get: { autoCleanEnabled },
                set: { newValue in
                    autoCleanEnabled = newValue
                    autoClean.isEnabled = newValue
                    autoClean.start()
                }
            )) {
                Text("Automatically clean")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(t.text)
            }
            .toggleStyle(.switch)
            .tint(t.accent)

            Text("Runs the safe Quick Clean — caches, logs, dev junk — to the Trash. Never touches your files or recovery data.")
                .font(.system(size: 11)).foregroundStyle(t.text3)
                .fixedSize(horizontal: false, vertical: true)

            if autoCleanEnabled {
                SegmentedPills(t: t, options: CleanScheduleInterval.allCases,
                               selection: Binding(
                                get: { autoCleanInterval },
                                set: { newValue in
                                    autoCleanInterval = newValue
                                    autoClean.interval = newValue
                                    autoClean.start()
                                })) { $0.displayName }
                Text(lastRunText).font(.system(size: 10.5)).foregroundStyle(t.text3)
            }
        }
        .onAppear {
            autoCleanEnabled = autoClean.isEnabled
            autoCleanInterval = autoClean.interval
        }
    }

    /// "Last run: …" line — humane relative time, or "never" before the first run.
    private var lastRunText: String {
        guard let last = autoClean.lastRun else { return "Last run: never" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Last run: \(f.localizedString(for: last, relativeTo: Date()))"
    }

    // MARK: - About (app name + version + links)

    @ViewBuilder
    private func aboutSection(_ t: Tokens) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ABOUT").font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(t.text3)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("conso").font(.system(size: 13, weight: .semibold)).foregroundStyle(t.text)
                    Text(versionString).font(.system(size: 11).monospacedDigit()).foregroundStyle(t.text3)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                ConsoButton(t: t, title: "Website", kind: .ghost) { openURL(Self.websiteURL) }
                ConsoButton(t: t, title: "GitHub", kind: .ghost) { openURL(Self.githubURL) }
                Spacer()
            }
        }
    }

    /// "Version 1.2 (34)" from Info.plist, gracefully degrading if keys are absent.
    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        if let build, !build.isEmpty { return "Version \(short) (\(build))" }
        return "Version \(short)"
    }

    // MARK: - Updates (Sparkle auto-update + Stable/Beta channel)

    @ViewBuilder
    private func updatesSection(_ t: Tokens) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("UPDATES").font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(t.text3)
            Toggle(isOn: $updater.automaticallyChecksForUpdates) {
                Text("Automatically check for updates")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(t.text)
            }
            .toggleStyle(.switch)
            .tint(t.accent)

            Toggle(isOn: Binding(
                get: { updater.channel == .beta },
                set: { updater.channel = $0 ? .beta : .stable }
            )) {
                Text("Receive beta updates")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(t.text)
            }
            .toggleStyle(.switch)
            .tint(t.accent)

            Text("Beta builds ship early and may be rougher than stable.")
                .font(.system(size: 11)).foregroundStyle(t.text3)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                ConsoButton(t: t, title: "Check Now", kind: .ghost) { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func helperSection(_ t: Tokens) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("PRIVILEGED HELPER").font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(t.text3)
            if AppDistribution.supportsPrivilegedHelper {
                HStack(spacing: 8) {
                    Circle().fill(HelperClient.shared.isInstalled ? t.good : t.text3).frame(width: 6, height: 6)
                    Text(HelperClient.shared.isInstalled ? "Installed" : "Not installed")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HelperClient.shared.isInstalled ? t.good : t.text2)
                    Spacer()
                    if HelperClient.shared.isInstalled {
                        ConsoButton(t: t, title: "Remove", kind: .ghost) {
                            try? HelperClient.shared.uninstall(); helperMsg = ""
                        }
                    } else {
                        ConsoButton(t: t, title: "Install", kind: .primary) {
                            do {
                                try HelperClient.shared.install()
                                helperMsg = "Requested — approve in System Settings ▸ Login Items if prompted."
                            } catch {
                                helperMsg = "Install failed: \(error.localizedDescription)"
                            }
                        }
                    }
                }
                if HelperClient.shared.isInstalled {
                    ConsoButton(t: t, title: helperBusy ? "Running…" : "Test: Rebuild Spotlight (root)", kind: .ghost) {
                        helperBusy = true
                        Task {
                            let r = await HelperClient.shared.runFix("spotlight")
                            helperMsg = r.ok ? "✓ ran as root — \(r.output.prefix(120))" : "✗ \(r.output)"
                            helperBusy = false
                        }
                    }
                    .disabled(helperBusy)
                }
                if !helperMsg.isEmpty {
                    Text(helperMsg).font(.system(size: 10.5)).foregroundStyle(t.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // Self-signed download: the team-validated helper can't run here.
                Text("Root maintenance — rebuild Spotlight, flush DNS, clear system font caches, delete APFS snapshots — needs the signed developer build, so it's unavailable in this download. Everything else works normally.")
                    .font(.system(size: 11)).foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Root

struct RootView: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(Router.self) private var router
    @Environment(QuickActions.self) private var quick
    @Environment(MetricsViewModel.self) private var metrics
    @Environment(\.colorScheme) private var scheme
    // All pillar models live here so their state (selection, scans, drill trail)
    // survives navigating between pillars — no re-scan on every visit.
    @State private var clean = CleanModel()
    @State private var optimize = OptimizeModel()
    @State private var analyze = AnalyzeModel()
    @State private var software = SoftwareModel()

    // "Ask conso" command bar (⌘K) and the Doctor sheet it (and App Intents) can open.
    @State private var commandBar = CommandBarViewModel()
    @State private var showCommandBar = false
    @State private var showDoctor = false
    private let intentBridge = AppIntentBridge.shared

    var body: some View {
        let t = theme.tokens(scheme)
        VStack(spacing: 0) {
            TopBar(cleanBytes: clean.reclaimableBytes, softwareCount: software.updateCount,
                   onAskConso: { showCommandBar = true })
            Group {
                switch router.pillar {
                case .clean: CleanView(model: clean)
                case .software: SoftwareView(model: software)
                case .optimize: OptimizeView(model: optimize)
                case .analyze: AnalyzeView(model: analyze)
                case .status: StatusView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 840, minHeight: 560)
        .background {
            if t.glass {
                // Behind-window blur with a theme tint on top — frosted "Liquid Glass".
                VisualEffectView(material: .underWindowBackground, blending: .behindWindow)
                    .overlay(t.bg.opacity(0.72))
                    .ignoresSafeArea()
            } else {
                t.bg.ignoresSafeArea()
            }
        }
        .background(WindowConfigurator())
        // ⌘K opens the command bar. A hidden button carries the keyboard shortcut so it
        // works app-wide without stealing focus from the pillar views.
        .background {
            Button("") { showCommandBar = true }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
        .overlay {
            if showCommandBar {
                CommandBarView(model: commandBar, context: commandContext) {
                    showCommandBar = false
                    commandBar.reset()
                }
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $showDoctor) {
            DoctorView(snapshot: metrics.snapshot, topProcesses: metrics.processes.map(\.name))
        }
        // App Intents (Spotlight / Shortcuts) post a pending command id; run it once.
        .onChange(of: intentBridge.pendingCommandID) { _, id in
            guard let id, let cmd = CommandCatalog.command(id: id) else { return }
            intentBridge.pendingCommandID = nil
            commandBar.run(cmd, in: commandContext)
        }
        .preferredColorScheme(theme.preferredScheme)
    }

    /// The live dependencies a command needs to run — the same handlers the in-app
    /// controls use, so a command does exactly what its UI control does (preview, never
    /// delete; navigate; rescan; toggle).
    private var commandContext: CommandContext {
        CommandContext(router: router, quick: quick, clean: clean, software: software,
                       analyze: analyze, runDoctor: { showDoctor = true },
                       snapshot: metrics.snapshot, topProcesses: metrics.processes.map(\.name))
    }
}

// MARK: - Menu-bar HUD

struct HUDView: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(MetricsViewModel.self) private var metrics
    @Environment(Router.self) private var router
    @Environment(QuickActions.self) private var quick
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let t = theme.tokens(scheme)
        let s = metrics.snapshot
        let nominal = s.thermal == .nominal
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("conso").font(.system(size: 13, weight: .semibold)).foregroundStyle(t.text)
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(nominal ? t.good : t.warn).frame(width: 6, height: 6)
                    Text(nominal ? "Nominal" : s.thermal.label)
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(nominal ? t.good : t.warn)
                }
            }
            .padding(.bottom, 12)

            VStack(spacing: 2) {
                sparkRow(t, "CPU", metrics.cpuHistory, t.accent, "\(Int((s.cpuUsage * 100).rounded()))%")
                sparkRow(t, "GPU", metrics.gpuHistory, t.good, "\(Int((s.gpuUsage * 100).rounded()))%")
                sparkRow(t, "MEM", metrics.memHistory, t.warn, "\(Int((s.memoryFraction * 100).rounded()))%")
                sparkRow(t, "NET", normalizedNet, t.accent, RateFormat.perSecondBits(s.netDown))
            }

            Divider().padding(.vertical, 11)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                qa(t, "Keep Awake", quick.keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer",
                   on: quick.keepAwake.isActive) { quick.keepAwake.toggle() }
                qa(t, "Clean Keys", "keyboard", on: false) { quick.cleanKeys() }
                qa(t, "Clean Screen", "display", on: false) { quick.cleanScreen() }
                qa(t, "Hidden Files", "eye", on: quick.hiddenFilesShown) { quick.toggleHiddenFiles() }
            }

            HStack(spacing: 8) {
                hudButton(t, "Optimize", solid: false) { open(.optimize) }
                hudButton(t, "Quick Clean", solid: true) { open(.clean) }
            }
            .padding(.top, 10)
        }
        .padding(14)
        .frame(width: 320)
    }

    private var normalizedNet: [Double] {
        let h = metrics.netDownHistory
        let mx = max(h.max() ?? 1, 1)
        return h.map { $0 / mx }
    }

    private func open(_ p: Pillar) {
        router.pillar = p
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func sparkRow(_ t: Tokens, _ k: String, _ values: [Double], _ color: Color, _ v: String) -> some View {
        HStack(spacing: 10) {
            Text(k).font(.system(size: 10, weight: .bold)).tracking(0.3)
                .foregroundStyle(t.text3).frame(width: 28, alignment: .leading)
            Sparkline(values: Array(values.suffix(30)), color: color)
                .frame(height: 16)
                .background(alignment: .bottom) {
                    // Faint baseline so a flat/empty trace still reads as a row.
                    Rectangle().fill(t.hair).frame(height: 1)
                }
            Text(v).font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(t.text).frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }

    private func qa(_ t: Tokens, _ title: String, _ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 15)
                Text(title).font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
            .foregroundStyle(on ? t.accentOn : t.text2)
            .padding(.vertical, 8).padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(on ? AnyShapeStyle(t.accent) : AnyShapeStyle(t.accentSoft), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func hudButton(_ t: Tokens, _ title: String, solid: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(solid ? t.accentOn : t.text)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(solid ? AnyShapeStyle(t.accent) : AnyShapeStyle(t.hair), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
