import SwiftUI
import AppKit
import ServiceManagement
import ConsoCore

struct SoftwareView: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @State private var tab: Tab = .updates

    // Held by RootView so the inventory + detection survive navigating between pillars
    // (no re-detect every time you open Software).
    @Bindable var model: SoftwareModel

    enum Tab: String, CaseIterable, Identifiable { case updates = "Updates", installed = "Installed", login = "Login Items"; var id: String { rawValue } }
    enum InstalledSort: String, CaseIterable, Identifiable { case name = "Name", size = "Size", version = "Version"; var id: String { rawValue } }
    @State private var installedSort: InstalledSort = .size

    /// Filter for the updates list: All, or one of the deterministic categories. Apps =
    /// Mac App Store / Sparkle / Electron / Homebrew casks; Libraries = Homebrew formulae;
    /// System = the macOS system update.
    enum UpdateFilter: Hashable, Identifiable {
        case all
        case category(UpdateCategory)
        var id: String { switch self { case .all: return "all"; case .category(let c): return c.rawValue } }
        static let allCases: [UpdateFilter] = [.all, .category(.app), .category(.library), .category(.system)]
    }
    @State private var updateFilter: UpdateFilter = .all

    var body: some View {
        let t = theme.tokens(scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PillarHeader(t: t, title: "Software", subtitle: headerSubtitle)

                VStack(spacing: 18) {
                    statStrip(t)
                    SegmentedPills(t: t, options: Tab.allCases, selection: $tab) { $0.rawValue }
                        .frame(maxWidth: .infinity, alignment: .leading)

                    switch tab {
                    case .updates: updatesTab(t)
                    case .installed: installedTab(t)
                    case .login: loginTab(t)
                    }
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .padding(20)
        }
        .onAppear { model.start() }
        .sheet(item: brewSheetBinding) { progress in
            brewProgressSheet(t, progress)
        }
    }

    private var headerSubtitle: String {
        let appPart = model.appCount > 0 ? "\(model.appCount) apps" : "scanning…"
        return "\(model.updateCount) updates · \(appPart)"
    }

    // MARK: - Stat strip (real data)

    private func statStrip(_ t: Tokens) -> some View {
        HStack(spacing: 14) {
            StatCell(t: t, symbol: "arrow.down.circle", key: "Updates", value: "\(model.updateCount)", detail: "ready to route")
            let dl = byteParts(model.totalDownloadBytes)
            StatCell(t: t, symbol: "square.and.arrow.down", key: "Download", value: dl.value, valueSuffix: dl.unit, detail: "known sizes")
            StatCell(t: t, symbol: "square.grid.2x2", key: "Apps", value: "\(model.appCount)", detail: "installed")
            StatCell(t: t, symbol: "power", key: "Login items", value: "\(model.loginItemCount)", detail: "\(model.slowLoginItemCount) at startup")
        }
    }

    // MARK: - Updates tab

    private func updatesTab(_ t: Tokens) -> some View {
        VStack(spacing: 14) {
            HStack {
                Text(updatesLead)
                    .font(.system(size: 13)).foregroundStyle(t.text2)
                Spacer()
                if model.isScanning {
                    ProgressView().controlSize(.small)
                }
                ConsoButton(t: t, title: "Rescan", kind: .ghost) { model.refresh() }
                ConsoButton(t: t, title: "Review & Update", kind: .primary) { tab = .updates }
            }

            // Category filter: All · Apps · Libraries · System, with live counts.
            SegmentedPills(t: t, options: UpdateFilter.allCases, selection: $updateFilter) { filterLabel($0) }
                .frame(maxWidth: .infinity, alignment: .leading)
            categoryCountLine(t)

            // macOS system update — separate from app updates. Shown when the filter
            // includes System (All or System), and only once a scan has produced one.
            if showsSystemRow, let sys = model.systemUpdate {
                card(t) {
                    updateRow(t, update: sys, system: true)
                    Divider().overlay(t.hair)
                    footnote(t, "Installs via Software Update and requires a restart — never bundled with app updates.")
                }
            }

            // Loading skeleton, the filtered list, or an honest empty state.
            if model.isScanning && model.updates.isEmpty {
                loadingCard(t)
            } else if filteredUpdates.isEmpty {
                card(t) {
                    emptyState(t, title: emptyTitle, detail: emptyDetail)
                    Divider().overlay(t.hair)
                    footnote(t, detectorFootnote)
                }
            } else {
                card(t) {
                    ForEach(Array(filteredUpdates.enumerated()), id: \.element.id) { i, u in
                        if i > 0 { Divider().overlay(t.hair) }
                        updateRow(t, update: u, system: false)
                    }
                    Divider().overlay(t.hair)
                    footnote(t, detectorFootnote)
                }
            }
        }
    }

    // MARK: Filtering & category counts (deterministic, from AppUpdate.category)

    /// The app-update rows (system row is handled separately) matching the active filter.
    private var filteredUpdates: [AppUpdate] {
        switch updateFilter {
        case .all: return model.updates
        case .category(let c): return model.updates.filter { $0.category == c }
        }
    }

    /// Whether the system row participates in the current filter.
    private var showsSystemRow: Bool {
        switch updateFilter {
        case .all, .category(.system): return true
        case .category: return false
        }
    }

    private func categoryCount(_ c: UpdateCategory) -> Int {
        let appUpdates = model.updates.filter { $0.category == c }.count
        // The system update lives outside `updates`; fold it into the System count.
        if c == .system, model.systemUpdate != nil { return appUpdates + 1 }
        return appUpdates
    }

    private func filterLabel(_ filter: UpdateFilter) -> String {
        switch filter {
        case .all: return "All"
        case .category(let c): return c.pluralName
        }
    }

    /// "Apps 4 · Libraries 60 · System 1" — live per-category counts under the pills.
    private func categoryCountLine(_ t: Tokens) -> some View {
        Text("Apps \(categoryCount(.app)) · Libraries \(categoryCount(.library)) · System \(categoryCount(.system))")
            .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(t.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyTitle: String {
        switch updateFilter {
        case .all: return "Everything's up to date"
        case .category(let c): return "No \(c.pluralName.lowercased()) need updating"
        }
    }

    private var emptyDetail: String {
        switch updateFilter {
        case .all:            return "No updates detected across the installers conso can reach."
        case .category(.app): return "Mac App Store, Sparkle, Electron and Homebrew cask apps are all current."
        case .category(.library): return "Every Homebrew formula (CLI tool / library) is up to date."
        case .category(.system):  return "macOS is up to date — no system update is pending."
        }
    }

    private var updatesLead: String {
        if model.isScanning && model.updates.isEmpty { return "Detecting updates across every installer…" }
        return "\(model.updateCount) updates detected · each routed to its real installer"
    }

    // MARK: Loading skeleton (inline — placeholder rows while the scan runs)

    private func loadingCard(_ t: Tokens) -> some View {
        card(t) {
            ForEach(0..<4, id: \.self) { i in
                if i > 0 { Divider().overlay(t.hair) }
                skeletonRow(t)
            }
            Divider().overlay(t.hair)
            footnote(t, "Checking for updates across Mac App Store · Homebrew · Sparkle · Electron…")
        }
    }

    private func skeletonRow(_ t: Tokens) -> some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(t.hair)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(t.hair)
                    .frame(width: 140, height: 11)
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(t.hair)
                    .frame(width: 90, height: 9)
            }
            Spacer(minLength: 8)
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(t.hair)
                .frame(width: 64, height: 22)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .redacted(reason: .placeholder)
    }

    private var detectorFootnote: String {
        let checked = model.lastScan.map { "Checked \(relative($0)) · " } ?? ""
        return "\(checked)detects across Mac App Store · Homebrew · Sparkle · Electron — conso surfaces each update and hands it to the app's own installer (macOS doesn't allow silent third-party installs)."
    }

    private func updateRow(_ t: Tokens, update u: AppUpdate, system: Bool) -> some View {
        HStack(spacing: 13) {
            updateIcon(t, u, system: system)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(u.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(t.text)
                    ExplainButton(target: .updateCategory(u.category), sizeBytes: u.bytes)
                }
                HStack(spacing: 4) {
                    Text(u.fromVersion).foregroundStyle(t.text3)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(t.text3)
                    Text(u.remoteVersionKnown ? u.toVersion : "update available").foregroundStyle(t.text2)
                }
                .font(.system(size: 11.5).monospacedDigit())
            }
            Spacer(minLength: 8)
            Badge(t: t, text: u.source.displayName, style: badgeStyle(u, system: system))
            if system {
                Text("installs & restarts your Mac").font(.system(size: 11, weight: .semibold)).foregroundStyle(t.warn)
            } else if u.daysOutOfDate > 0 {
                Text("out of date \(u.daysOutOfDate)d").font(.system(size: 11.5)).foregroundStyle(t.text3)
            }
            if u.bytes > 0 {
                Text(ByteFormat.string(u.bytes)).font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(t.text2).frame(minWidth: 58, alignment: .trailing)
            } else {
                Text("—").font(.system(size: 13)).foregroundStyle(t.text3).frame(minWidth: 58, alignment: .trailing)
            }
            ConsoButton(t: t, title: u.source.actionLabel, kind: .ghost) { perform(route: model.route(for: u)) }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(system ? t.accentSoft : Color.clear)
    }

    private func badgeStyle(_ u: AppUpdate, system: Bool) -> BadgeStyle {
        if system { return .warm }
        return u.source == .appStore ? .accent : .muted
    }

    // MARK: - Installed tab (real inventory)

    private func installedTab(_ t: Tokens) -> some View {
        VStack(spacing: 14) {
            HStack {
                Text(model.appCount > 0 ? "\(model.appCount) apps installed · \(ByteFormat.string(installedTotalBytes))" : "Scanning /Applications…")
                    .font(.system(size: 13)).foregroundStyle(t.text2)
                Spacer()
                Picker("", selection: $installedSort) {
                    ForEach(InstalledSort.allCases) { Text("Sort: \($0.rawValue)").tag($0) }
                }
                .labelsHidden().fixedSize().controlSize(.small)
            }

            if model.installedApps.isEmpty {
                card(t) {
                    emptyState(t, title: model.isScanning ? "Reading installed apps…" : "No apps found",
                               detail: "conso scans /Applications, /Applications/Utilities and ~/Applications.")
                }
            } else {
                card(t) {
                    ForEach(Array(sortedInstalled.enumerated()), id: \.element.id) { i, app in
                        if i > 0 { Divider().overlay(t.hair) }
                        installedRow(t, app)
                    }
                    Divider().overlay(t.hair)
                    footnote(t, "Uninstall needs the App-Management permission (TCC) — conso lists apps read-only and can reveal each in Finder.")
                }
            }
        }
    }

    private func installedRow(_ t: Tokens, _ app: InstalledApp) -> some View {
        HStack(spacing: 13) {
            appIcon(t, path: app.path, fallback: glyph(app.name))
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(t.text)
                Text(app.bundleID.isEmpty ? app.path : app.bundleID)
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(t.text3)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text("v\(app.displayVersion)").font(.system(size: 12).monospacedDigit()).foregroundStyle(t.text2)
            Text(app.bytes > 0 ? ByteFormat.string(app.bytes) : "—")
                .font(.system(size: 13).monospacedDigit()).foregroundStyle(t.text2)
                .frame(minWidth: 64, alignment: .trailing)
            ConsoButton(t: t, title: "Reveal", kind: .ghost) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private var sortedInstalled: [InstalledApp] {
        switch installedSort {
        case .name: return model.installedApps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size: return model.installedApps.sorted { $0.bytes > $1.bytes }
        case .version: return model.installedApps.sorted { $0.displayVersion.localizedStandardCompare($1.displayVersion) == .orderedDescending }
        }
    }

    private var installedTotalBytes: UInt64 { model.installedApps.reduce(0) { $0 + $1.bytes } }

    // MARK: - Login Items tab (read-only + conso's own via SMAppService)

    private func loginTab(_ t: Tokens) -> some View {
        VStack(spacing: 14) {
            HStack {
                Text("\(model.loginItemCount) launch items · \(model.slowLoginItemCount) run at startup")
                    .font(.system(size: 13)).foregroundStyle(t.text2)
                Spacer()
                ConsoButton(t: t, title: "Open Login Items Settings", kind: .primary) {
                    open(SoftwareRouter.loginItemsSettingsURL)
                }
            }

            // conso's own item — the only one conso can legitimately toggle.
            card(t) {
                consoOwnItemRow(t)
                Divider().overlay(t.hair)
                footnote(t, "conso can enable/disable only its own login item (SMAppService). macOS has no public API to toggle other apps' login items.")
            }

            if model.loginItems.isEmpty {
                card(t) {
                    emptyState(t, title: model.isScanning ? "Reading launch items…" : "No launch agents or daemons found",
                               detail: "conso reads LaunchAgents and LaunchDaemons read-only.")
                }
            } else {
                card(t) {
                    ForEach(Array(model.loginItems.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Divider().overlay(t.hair) }
                        loginItemRow(t, item)
                    }
                    Divider().overlay(t.hair)
                    footnote(t, "Listed read-only across ~/Library/LaunchAgents, /Library/LaunchAgents and /Library/LaunchDaemons — disable these in System Settings.")
                }
            }
        }
    }

    private func consoOwnItemRow(_ t: Tokens) -> some View {
        let status = SMAppService.mainApp.status
        return HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(t.accentSoft)
                .frame(width: 32, height: 32)
                .overlay(Image(systemName: "bolt.badge.clock").font(.system(size: 14, weight: .semibold)).foregroundStyle(t.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text("conso").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(t.text)
                Text("Launch at login").font(.system(size: 11.5)).foregroundStyle(t.text3)
            }
            Spacer(minLength: 8)
            Badge(t: t, text: ownItemLabel(status), style: status == .enabled ? .accent : .muted)
            ConsoButton(t: t, title: status == .enabled ? "Disable" : "Enable", kind: .ghost) {
                toggleOwnLoginItem(currentlyEnabled: status == .enabled)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private func ownItemLabel(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "Enabled"
        case .notRegistered: return "Disabled"
        case .requiresApproval: return "Needs approval"
        case .notFound: return "Not available"
        @unknown default: return "Unknown"
        }
    }

    private func toggleOwnLoginItem(currentlyEnabled: Bool) {
        do {
            if currentlyEnabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            // If registration needs user approval, point them at the right pane.
            open(SoftwareRouter.loginItemsSettingsURL)
        }
    }

    private func loginItemRow(_ t: Tokens, _ item: LoginItem) -> some View {
        HStack(spacing: 13) {
            appIcon(t, path: programAppPath(item.program), fallback: glyph(item.displayName))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(t.text)
                Text(item.label).font(.system(size: 11).monospacedDigit()).foregroundStyle(t.text3)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if item.runAtLoad {
                Text("at startup").font(.system(size: 11, weight: .semibold)).foregroundStyle(t.warn)
            }
            Badge(t: t, text: item.kind.rawValue, style: .muted)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    /// If a launch item's program lives inside an `.app`, return that bundle for its icon.
    private func programAppPath(_ program: String) -> String? {
        guard let range = program.range(of: ".app") else { return nil }
        return String(program[..<range.upperBound])
    }

    // MARK: - Routing (NSWorkspace / openURL live here, in the app layer)

    private func perform(route: UpdateRoute) {
        switch route {
        case .openURL(let url):
            open(url)
        case .openApp(let path):
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config)
        case .brewUpgrade(let name, let isCask):
            model.runBrewUpgrade(name: name, isCask: isCask)
        case .openAppStoreUpdates:
            open(SoftwareRouter.appStoreUpdatesURL)
        }
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Brew progress sheet

    private var brewSheetBinding: Binding<BrewProgress?> {
        Binding(get: { model.brewProgress }, set: { if $0 == nil { model.finishBrewUpgrade() } })
    }

    private func brewProgressSheet(_ t: Tokens, _ progress: BrewProgress) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if progress.isRunning { ProgressView().controlSize(.small) }
                else { Image(systemName: progress.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(progress.succeeded ? t.good : t.warn) }
                Text(progress.isRunning ? "Updating \(progress.name)…" : "Updated \(progress.name)")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(t.text)
            }
            ScrollView {
                Text(progress.log.isEmpty ? "Starting brew upgrade…" : progress.log)
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(t.text2)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(height: 280)
            .padding(10).background(t.hair, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack {
                Spacer()
                ConsoButton(t: t, title: progress.isRunning ? "Run in background" : "Done", kind: .primary) {
                    model.finishBrewUpgrade()
                }
            }
        }
        .padding(20).frame(width: 560)
    }

    // MARK: - Shared bits

    private func card<C: View>(_ t: Tokens, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }.consoCard(t)
    }

    private func footnote(_ t: Tokens, _ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(t.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func emptyState(_ t: Tokens, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(t.text)
            Text(detail).font(.system(size: 12.5)).foregroundStyle(t.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 18)
    }

    @ViewBuilder
    private func updateIcon(_ t: Tokens, _ u: AppUpdate, system: Bool) -> some View {
        if system {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(t.accent)
                .frame(width: 32, height: 32)
                .overlay(Image(systemName: "apple.logo").font(.system(size: 15, weight: .bold)).foregroundStyle(t.accentOn))
        } else {
            appIcon(t, path: u.bundlePath, fallback: u.glyph)
        }
    }

    /// Resolves a real app icon from a bundle path (preferred), then falls back to a
    /// lettered chip. Lives in the view because `NSWorkspace` is an AppKit API.
    @ViewBuilder
    private func appIcon(_ t: Tokens, path: String?, fallback: String) -> some View {
        if let path, FileManager.default.fileExists(atPath: path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable().interpolation(.high).frame(width: 32, height: 32)
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(t.accentSoft)
                .frame(width: 32, height: 32)
                .overlay(Text(fallback).font(.system(size: 15, weight: .bold)).foregroundStyle(t.accent))
        }
    }

    private func glyph(_ name: String) -> String {
        String(name.first.map(Character.init) ?? "•").uppercased()
    }

    private func byteParts(_ bytes: UInt64) -> (value: String, unit: String) {
        let parts = ByteFormat.string(bytes).split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return (ByteFormat.string(bytes), "") }
        return (String(parts[0]), String(parts[1]))
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
