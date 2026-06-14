import SwiftUI
import ConsoCore

/// The two views of the Analyze pillar: the disk treemap, and the file finder.
enum AnalyzeTab: String, CaseIterable, Identifiable {
    case treemap = "Treemap"
    case files = "Files"
    var id: String { rawValue }
}

struct AnalyzeView: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    // Held by RootView so the scan + drill trail survive navigating between pillars
    // (no re-scan every time you open Analyze).
    @Bindable var model: AnalyzeModel

    /// Which Analyze view is showing (treemap vs file finder).
    @State private var tab: AnalyzeTab = .treemap
    /// The file finder's model — scans on demand (the duplicate/old-file finders are
    /// opt-in), so it can live with the view's lifetime.
    @State private var files = FilesModel()

    /// Deep-link to the Full Disk Access pane of System Settings.
    private let fdaSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    var body: some View {
        let t = theme.tokens(scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    PillarHeader(t: t, title: "Analyze", subtitle: headerSubtitle)
                    SegmentedPills(t: t, options: AnalyzeTab.allCases, selection: $tab) { $0.rawValue }
                }

                switch tab {
                case .treemap: treemapTab(t)
                case .files: filesTab(t)
                }
            }
            .padding(20)
        }
        .onAppear { model.start() }
    }

    // MARK: Treemap tab (existing UI, unchanged)

    @ViewBuilder
    private func treemapTab(_ t: Tokens) -> some View {
        statStrip(t)

        if model.partial { fdaBanner(t) }

        breadcrumbs(t)

        HStack(alignment: .top, spacing: 14) {
            treemap(t).frame(maxWidth: .infinity)
            largestFolders(t).frame(width: 250)
        }

        Label("Click a block to drill in. Needs Full Disk Access for a complete map.",
              systemImage: "info.circle")
            .font(.system(size: 11.5)).foregroundStyle(t.text3).labelStyle(.titleAndIcon)
    }

    // MARK: Header / stat strip

    private var headerSubtitle: String {
        let name = model.volume?.name ?? model.currentURL.lastPathComponent
        if let v = model.volume {
            return "\(name) · \(ByteFormat.string(v.used)) of \(ByteFormat.string(v.total)) used"
        }
        return name
    }

    /// "Files" stat detail: live "scanning N/M…" while a scan runs, else "scanned".
    private var scanDetail: String {
        guard model.isScanning else { return "scanned" }
        return model.totalChildren > 0 ? "scanning \(model.scannedCount)/\(model.totalChildren)…" : "scanning…"
    }

    private func statStrip(_ t: Tokens) -> some View {
        let v = model.volume
        let used = byteParts(v?.used ?? model.usedBytes)
        let free = byteParts(v?.free ?? 0)
        let totalDetail = v.map { "of \(ByteFormat.string($0.total))" } ?? "this folder"
        let fsName = (v?.fsName).flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        return HStack(spacing: 14) {
            StatCell(t: t, symbol: "circle.lefthalf.filled", key: "Used", value: used.value, valueSuffix: used.unit, detail: totalDetail)
            StatCell(t: t, symbol: "checkmark.circle", key: "Free", value: free.value, valueSuffix: free.unit, detail: fsName)
            StatCell(t: t, symbol: "doc.on.doc", key: "Files", value: compactCount(model.fileCount), detail: scanDetail)
            StatCell(t: t, symbol: "chart.pie", key: "Largest", value: model.largest?.name ?? "—", detail: ByteFormat.string(model.largest?.bytes ?? 0))
        }
    }

    // MARK: Full Disk Access banner

    private func fdaBanner(_ t: Tokens) -> some View { fdaBanner(t, granted: model.fdaGranted) }

    private func fdaBanner(_ t: Tokens, granted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(t.warn)
            VStack(alignment: .leading, spacing: 1) {
                Text(granted ? "Partial results" : "Partial results — grant Full Disk Access")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(t.text)
                Text(granted
                     ? "Some folders couldn’t be read and were skipped."
                     : "conso can’t read every folder yet. Grant Full Disk Access for complete results.")
                    .font(.system(size: 11.5)).foregroundStyle(t.text3)
            }
            Spacer(minLength: 8)
            if !granted {
                ConsoButton(t: t, title: "Open Settings", kind: .ghost) { openURL(fdaSettingsURL) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(t.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(t.warn.opacity(0.3), lineWidth: 1))
    }

    // MARK: Breadcrumbs

    private func breadcrumbs(_ t: Tokens) -> some View {
        let crumbs = model.breadcrumbs
        return HStack(spacing: 7) {
            ForEach(Array(crumbs.enumerated()), id: \.element.id) { i, crumb in
                if i > 0 { sep(t) }
                crumbButton(t, crumb.label, current: i == crumbs.count - 1, index: i)
            }
        }
    }

    private func crumbButton(_ t: Tokens, _ s: String, current: Bool, index: Int) -> some View {
        Button { model.popTo(index) } label: {
            Text(s).font(.system(size: 12.5, weight: current ? .semibold : .regular))
                .foregroundStyle(current ? t.text : t.text3)
        }
        .buttonStyle(.plain)
        .disabled(current)
    }

    private func sep(_ t: Tokens) -> some View {
        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(t.text3.opacity(0.6))
    }

    // MARK: Treemap

    private func treemap(_ t: Tokens) -> some View {
        let entries = model.entries
        let inputs = entries.map { TreemapInput(id: $0.id, value: Double($0.bytes)) }
        let rank = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.id, $0) })
        return GeometryReader { geo in
            let tiles = Treemap.squarify(inputs, in: Rect(x: 0, y: 0, width: geo.size.width, height: geo.size.height))
            ZStack(alignment: .topLeading) {
                if tiles.isEmpty {
                    treemapPlaceholder(t)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ForEach(tiles) { tile in
                        tileView(t, tile: tile, opacity: opacity(forRank: rank[tile.id] ?? 0))
                            .frame(width: tile.rect.width, height: tile.rect.height)
                            .position(x: tile.rect.x + tile.rect.width / 2, y: tile.rect.y + tile.rect.height / 2)
                    }
                }
            }
        }
        .frame(height: 360)
    }

    private func treemapPlaceholder(_ t: Tokens) -> some View {
        VStack(spacing: 10) {
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning \(model.currentURL.lastPathComponent)…")
                    .font(.system(size: 12.5)).foregroundStyle(t.text3)
            } else {
                Image(systemName: "tray").font(.system(size: 22)).foregroundStyle(t.text3)
                Text("Nothing to show here.").font(.system(size: 12.5)).foregroundStyle(t.text3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t.hair.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func tileView(_ t: Tokens, tile: TreemapTile, opacity: Double) -> some View {
        // Tiles too small to fit a label show a centered dot (per mockup .tile.tiny).
        let showLabel = tile.rect.width > 52 && tile.rect.height > 34
        let tiny = tile.rect.width < 26 || tile.rect.height < 22
        return Button {
            if let entry = model.entries.first(where: { $0.id == tile.id }) { model.drillInto(entry) }
        } label: {
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(t.accent.opacity(opacity))
                LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.12)],
                               startPoint: .bottom, endPoint: .top)
                if showLabel {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name(for: tile.id)).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.96)).lineLimit(1)
                        Text(ByteFormat.string(UInt64(tile.value)))
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.82))
                    }
                    .padding(11)
                } else if tiny {
                    Circle().fill(.white.opacity(0.55)).frame(width: 5, height: 5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(name(for: tile.id))
        .padding(1.5)
    }

    // MARK: Largest folders

    private func largestFolders(_ t: Tokens) -> some View {
        let entries = model.entries
        let maxBytes = entries.map(\.bytes).max() ?? 1
        return SectionCard(t: t) {
            CardTitle(t: t, text: "Largest folders")
        } content: {
            VStack(spacing: 0) {
                if entries.isEmpty {
                    Text(model.isScanning ? "Scanning…" : "Nothing here")
                        .font(.system(size: 12.5)).foregroundStyle(t.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                } else {
                    ForEach(Array(entries.prefix(6).enumerated()), id: \.element.id) { i, e in
                        if i > 0 { Divider().overlay(t.hair) }
                        Button { model.drillInto(e) } label: {
                            folderRow(t, entry: e, rank: i, maxBytes: maxBytes)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } footer: {
            HStack {
                Text("\(ByteFormat.string(model.usedBytes)) used").font(.system(size: 12)).foregroundStyle(t.text3)
                Spacer()
                ConsoButton(t: t, title: model.isScanning ? "Scanning…" : "Rescan", kind: .ghost) { model.rescan() }
            }
        }
    }

    private func folderRow(_ t: Tokens, entry e: DiskEntry, rank i: Int, maxBytes: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(t.accent.opacity(opacity(forRank: i)))
                    .frame(width: 9, height: 9)
                Text(e.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(t.text).lineLimit(1)
                Spacer(minLength: 6)
                Text(ByteFormat.string(e.bytes)).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(t.text2)
            }
            BarRow(t: t, fraction: Double(e.bytes) / Double(max(maxBytes, 1)), color: t.accent.opacity(opacity(forRank: i)))
            Text("\(e.fileCount.formatted()) files").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(t.text3)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    // MARK: Helpers

    private func name(for id: String) -> String { model.entries.first { $0.id == id }?.name ?? id }
    private func opacity(forRank rank: Int) -> Double { max(0.22, 1.0 - Double(rank) * 0.085) }

    private func byteParts(_ bytes: UInt64) -> (value: String, unit: String) {
        let parts = ByteFormat.string(bytes).split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return (ByteFormat.string(bytes), "") }
        return (String(parts[0]), String(parts[1]))
    }
    private func compactCount(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000)
            : n >= 1_000 ? "\(n / 1_000)K" : "\(n)"
    }

    // MARK: - Files tab (duplicate + old-file finder)

    @ViewBuilder
    private func filesTab(_ t: Tokens) -> some View {
        folderBar(t)

        if files.partial { fdaBanner(t, granted: files.fdaGranted) }

        if files.capped {
            Label("Showing the first batch of files — this folder is very large.",
                  systemImage: "exclamationmark.circle")
                .font(.system(size: 11.5)).foregroundStyle(t.text3).labelStyle(.titleAndIcon)
        }

        duplicatesSection(t)
        oldFilesSection(t)
    }

    /// The chosen-folder bar + Scan / Rescan button + folder picker.
    private func folderBar(_ t: Tokens) -> some View {
        Panel(t: t) {
            HStack(spacing: 10) {
                Image(systemName: "folder").font(.system(size: 13, weight: .semibold)).foregroundStyle(t.text3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(files.root.lastPathComponent).font(.system(size: 13, weight: .semibold)).foregroundStyle(t.text).lineLimit(1)
                    Text(files.root.path).font(.system(size: 11).monospaced()).foregroundStyle(t.text3).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 10)
                ConsoButton(t: t, title: "Choose Folder…", kind: .ghost) { chooseFolder() }
                ConsoButton(t: t, title: files.isScanning ? "Scanning…" : (files.didScan ? "Rescan" : "Scan"),
                            kind: .primary) { if !files.isScanning { files.scan() } }
            }
        }
    }

    // MARK: Duplicates section

    private func duplicatesSection(_ t: Tokens) -> some View {
        SectionCard(t: t) {
            HStack {
                CardTitle(t: t, text: "Exact duplicates")
                Spacer()
                if !files.duplicates.isEmpty {
                    Badge(t: t, text: "\(ByteFormat.string(files.duplicateReclaimable)) reclaimable", style: .accent)
                }
            }
        } content: {
            VStack(spacing: 0) {
                if files.isScanning {
                    finderLoading(t, text: files.phase.isEmpty ? "Scanning…" : files.phase)
                } else if !files.didScan {
                    finderEmpty(t, symbol: "doc.on.doc", text: "Scan a folder to find files with identical content.")
                } else if files.duplicates.isEmpty {
                    finderEmpty(t, symbol: "checkmark.seal", text: "No duplicates found")
                } else {
                    ForEach(Array(files.duplicates.enumerated()), id: \.element.id) { i, group in
                        if i > 0 { Divider().overlay(t.hair) }
                        duplicateGroupRow(t, group: group)
                    }
                }
            }
        } footer: {
            HStack {
                Text(files.duplicates.isEmpty ? "Keep one copy, trash the rest." :
                        "\(files.duplicates.count) groups · keep one each").font(.system(size: 12)).foregroundStyle(t.text3)
                Spacer()
                if !files.duplicates.isEmpty {
                    ConsoButton(t: t, title: "Trash extra copies", kind: .primary) { files.trashDuplicateCandidates() }
                }
            }
        }
    }

    private func duplicateGroupRow(_ t: Tokens, group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(group.files.count) copies").font(.system(size: 12, weight: .semibold)).foregroundStyle(t.text2)
                Text(ByteFormat.string(group.copyBytes)).font(.system(size: 12).monospacedDigit()).foregroundStyle(t.text3)
                ExplainButton(target: .duplicateFile, sizeBytes: group.reclaimableBytes)
                Spacer()
                Text("\(ByteFormat.string(group.reclaimableBytes)) reclaimable")
                    .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(t.accent)
            }
            ForEach(group.files) { file in
                let kept = files.keptPath(in: group) == file.path
                Button { files.keepByGroup[group.id] = file.path } label: {
                    HStack(spacing: 8) {
                        Image(systemName: kept ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 13)).foregroundStyle(kept ? t.accent : t.text3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.name).font(.system(size: 12.5, weight: kept ? .semibold : .regular))
                                .foregroundStyle(t.text).lineLimit(1)
                            Text(file.path).font(.system(size: 10.5).monospaced()).foregroundStyle(t.text3)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if kept { Badge(t: t, text: "Keep", style: .accent) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: Old files section

    private func oldFilesSection(_ t: Tokens) -> some View {
        SectionCard(t: t) {
            HStack {
                CardTitle(t: t, text: "Old & unused")
                Spacer()
                if !files.selectedOld.isEmpty {
                    Badge(t: t, text: "\(ByteFormat.string(files.selectedOldBytes)) selected", style: .accent)
                }
            }
        } content: {
            VStack(spacing: 0) {
                if files.isScanning {
                    finderLoading(t, text: files.phase.isEmpty ? "Scanning…" : files.phase)
                } else if !files.didScan {
                    finderEmpty(t, symbol: "clock.arrow.circlepath", text: "Scan a folder to find files untouched for a long time.")
                } else if files.oldFiles.isEmpty {
                    finderEmpty(t, symbol: "sparkles", text: "Nothing old in here")
                } else {
                    ForEach(Array(files.oldFiles.enumerated()), id: \.element.id) { i, file in
                        if i > 0 { Divider().overlay(t.hair) }
                        oldFileRow(t, file: file)
                    }
                }
            }
        } footer: {
            HStack {
                Text("Not modified or opened in over \(files.thresholdDays / 365 == 1 ? "a year" : "\(files.thresholdDays) days").")
                    .font(.system(size: 12)).foregroundStyle(t.text3)
                Spacer()
                if !files.selectedOld.isEmpty {
                    ConsoButton(t: t, title: "Trash selected", kind: .primary) { files.trashSelectedOld() }
                }
            }
        }
    }

    private func oldFileRow(_ t: Tokens, file: FileRecord) -> some View {
        let selected = files.selectedOld.contains(file.path)
        return HStack(spacing: 10) {
            // The toggle covers everything except the trailing info affordance, so tapping
            // "What's this?" doesn't also flip the selection.
            Button { files.toggleOld(file.path) } label: {
                HStack(spacing: 10) {
                    CheckToggle(t: t, isOn: selected)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(t.text).lineLimit(1)
                        Text(file.path).font(.system(size: 10.5).monospaced()).foregroundStyle(t.text3)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(ByteFormat.string(file.size)).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(t.text2)
                        Text(file.modified.formatted(.dateTime.year().month().day())).font(.system(size: 10.5)).foregroundStyle(t.text3)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ExplainButton(target: .oldFile, sizeBytes: file.size)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    // MARK: Finder shared states

    private func finderLoading(_ t: Tokens, text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12.5)).foregroundStyle(t.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 16)
    }

    private func finderEmpty(_ t: Tokens, symbol: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(t.text3)
            Text(text).font(.system(size: 12.5)).foregroundStyle(t.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 16)
    }

    // MARK: Folder picker

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = files.root
        panel.prompt = "Scan"
        panel.message = "Choose a folder to scan for duplicates and old files."
        if panel.runModal() == .OK, let url = panel.url {
            files.setRoot(url)
        }
    }
}
