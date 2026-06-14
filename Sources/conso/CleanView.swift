import SwiftUI
import ConsoCore

struct CleanView: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @Bindable var model: CleanModel

    /// Drives the AI summary paragraph at the top of the confirmation sheet (live on
    /// macOS 26+, deterministic fallback otherwise). One instance, re-driven per preview.
    @State private var summaryModel = CleanSummaryViewModel()
    /// Which preview categories are expanded to show their item list (by category).
    @State private var expandedCategories: Set<CleanCategory> = []

    var body: some View {
        let t = theme.tokens(scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PillarHeader(t: t, title: "Clean", subtitle: headerSubtitle)

                VStack(spacing: 22) {
                    hero(t)
                    if model.isScanning && !model.didScan {
                        scanningCards(t)
                    } else if model.didScan && model.reclaimableBytes == 0 {
                        EmptyState(t: t, icon: "sparkles",
                                   title: "All clean — nothing to reclaim",
                                   message: "We swept your caches, logs, and build junk and found nothing worth removing. Check back later or run a fresh scan.")
                        hiddenCard(t)
                    } else {
                        categoriesCard(t)
                        hiddenCard(t)
                    }
                }
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .padding(20)
        }
        .onAppear { model.start() }
        .sheet(item: Binding(get: { model.preview }, set: { if $0 == nil { model.cancelPreview() } })) { preview in
            previewSheet(t, preview)
        }
        .sheet(item: Binding(get: { model.result.map { ResultBox(result: $0) } },
                             set: { if $0 == nil { model.dismissResult() } })) { box in
            resultSheet(t, box.result)
        }
        .alert("Clean aborted", isPresented: Binding(
            get: { model.abortError != nil }, set: { if !$0 { model.dismissAbort() } })) {
            Button("OK", role: .cancel) { model.dismissAbort() }
        } message: {
            Text(model.abortError ?? "")
        }
    }

    private var headerSubtitle: String {
        if model.isScanning { return "scanning your caches & junk…" }
        if model.didScan { return "\(ByteFormat.string(model.reclaimableBytes)) reclaimable across \(model.categories.count) categories" }
        return "preparing to scan"
    }

    // MARK: Hero

    private func hero(_ t: Tokens) -> some View {
        VStack(spacing: 16) {
            ZStack {
                SegmentRing(values: model.categories.map { Double($0.bytes) },
                            color: t.accent, track: t.hair, lineWidth: 18)
                    .frame(width: 196, height: 196)
                VStack(spacing: 6) {
                    let parts = byteParts(model.reclaimableBytes)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(parts.value).font(.system(size: 40, weight: .semibold).monospacedDigit())
                            .foregroundStyle(t.text)
                        Text(parts.unit).font(.system(size: 17, weight: .semibold)).foregroundStyle(t.text3)
                    }
                    Text("RECLAIMABLE").font(.system(size: 11, weight: .semibold)).tracking(0.7)
                        .foregroundStyle(t.text3)
                }
            }
            Text("A light sweep of caches, logs, and build junk. Everything is previewed before removal — nothing important is touched.")
                .font(.system(size: 13)).foregroundStyle(t.text2)
                .multilineTextAlignment(.center).lineSpacing(2)
                .frame(maxWidth: 400)
            if model.isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(t.text3)
                }
            } else {
                HStack(spacing: 10) {
                    ConsoButton(t: t, title: "Review & Clean", kind: .primary, large: true) { model.review() }
                    ConsoButton(t: t, title: "Quick Clean", kind: .ghost, large: true) { model.quickClean() }
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: Loading (first scan in flight)

    /// Skeleton rows standing in for the categories card while the first scan resolves
    /// sizes, so the section keeps its shape before real rows appear.
    private func scanningCards(_ t: Tokens) -> some View {
        SectionCard(t: t) {
            HStack {
                CardTitle(t: t, text: "What we found")
                Spacer()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").font(.system(size: 12, weight: .semibold)).foregroundStyle(t.text3)
                }
            }
        } content: {
            VStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { i in
                    if i > 0 { Divider().overlay(t.hair) }
                    HStack(spacing: 13) {
                        SkeletonBlock(t: t, height: 36, width: 9, corner: 5)
                        VStack(alignment: .leading, spacing: 6) {
                            SkeletonBlock(t: t, height: 13, width: 150)
                            SkeletonBlock(t: t, height: 11, width: 220)
                        }
                        Spacer(minLength: 8)
                        SkeletonBlock(t: t, height: 13, width: 60)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 13)
                }
            }
        } footer: {
            SkeletonBlock(t: t, height: 12, width: 240)
        }
    }

    // MARK: Safe categories

    private func categoriesCard(_ t: Tokens) -> some View {
        SectionCard(t: t) {
            HStack {
                CardTitle(t: t, text: "What we found")
                Spacer()
                Button {
                    let allOn = model.categories.allSatisfy(\.isSelected)
                    model.setAllCategories(!allOn)
                } label: {
                    Text(model.categories.allSatisfy(\.isSelected) ? "Deselect all" : "Select all")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(t.accent)
                }
                .buttonStyle(.plain)
            }
        } content: {
            VStack(spacing: 0) {
                ForEach(Array(model.categories.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Divider().overlay(t.hair) }
                    cleanRow(t, item: item, accentOpacity: 1.0 - Double(i) * 0.13,
                             target: explainTarget(for: item.id)) {
                        model.toggleCategory(item.id)
                    }
                }
            }
        } footer: {
            HStack(spacing: 8) {
                Text("\(model.categories.selectedCount) of \(model.categories.count) selected · \(ByteFormat.string(model.categories.selectedBytes))")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(t.text2)
                Spacer()
                Label("Protected paths are never removed", systemImage: "shield")
                    .font(.system(size: 12)).foregroundStyle(t.text3).labelStyle(.titleAndIcon)
            }
        }
    }

    // MARK: Large hidden items (recovery data — default off)

    private func hiddenCard(_ t: Tokens) -> some View {
        SectionCard(t: t) {
            HStack {
                CardTitle(t: t, text: "Large hidden items")
                Spacer()
                Text("separate from the \(ByteFormat.string(model.reclaimableBytes)) sweep")
                    .font(.system(size: 12)).foregroundStyle(t.text3)
            }
        } content: {
            VStack(spacing: 0) {
                ForEach(Array(model.hiddenItems.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Divider().overlay(t.hair) }
                    // APFS snapshots need the privileged helper to remove. When it isn't
                    // installed the row is locked (can't be selected) and points the user at
                    // Settings; once installed it behaves like any other selectable row.
                    let helperLocked = model.needsHelper(item.id) && !model.helperInstalled
                    cleanRow(t, item: item, accentOpacity: 0.5, swatchColor: t.warn,
                             note: helperLocked ? "needs the privileged helper — install it in Settings" : nil,
                             locked: helperLocked, target: explainTarget(for: item.id)) {
                        model.toggleHidden(item.id)
                    }
                }
            }
        } footer: {
            HStack(spacing: 8) {
                Text("\(model.hiddenItems.selectedCount) of \(model.hiddenItems.count) selected · \(ByteFormat.string(model.hiddenItems.totalBytes))")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(t.text2)
                Spacer()
                Label("Recovery data — nothing selected by default", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(t.warn).labelStyle(.titleAndIcon)
            }
        }
    }

    // MARK: Row

    private func cleanRow(_ t: Tokens, item: CleanItem, accentOpacity: Double,
                          swatchColor: Color? = nil, note: String? = nil, locked: Bool = false,
                          target: ExplainTarget? = nil,
                          toggle: @escaping () -> Void) -> some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 5)
                .fill((swatchColor ?? t.accent).opacity(accentOpacity))
                .frame(width: 9, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(t.text)
                    if let target { ExplainButton(target: target, sizeBytes: item.bytes) }
                }
                Text(item.detail).font(.system(size: 11.5)).foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note).font(.system(size: 11, weight: .semibold)).foregroundStyle(t.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(ByteFormat.string(item.bytes))
                .font(.system(size: 13, weight: .regular).monospacedDigit()).foregroundStyle(t.text2)
            CheckToggle(t: t, isOn: item.isSelected)
                .opacity(locked ? 0.4 : 1)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .opacity(locked ? 0.7 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !locked { toggle() } }
    }

    /// Maps a row id (a `CleanCategory.rawValue`) to its explainer target. Nil for an
    /// unrecognised id so the info affordance is simply omitted rather than guessing.
    private func explainTarget(for id: String) -> ExplainTarget? {
        CleanCategory(rawValue: id).map { .cleanCategory($0) }
    }

    /// Splits "12.4 GB" → ("12.4", "GB") so the unit can be styled smaller.
    private func byteParts(_ bytes: UInt64) -> (value: String, unit: String) {
        let s = ByteFormat.string(bytes)
        let parts = s.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return (s, "") }
        return (String(parts[0]), String(parts[1]))
    }

    // MARK: - Preview sheet (shown BEFORE any deletion)

    /// The confirmation sheet. Lists the concrete per-category sizes + counts that would
    /// move to Trash, and only on the explicit "Move to Trash" press does the run happen.
    private func previewSheet(_ t: Tokens, _ preview: CleanPreview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "trash").font(.system(size: 16, weight: .semibold)).foregroundStyle(t.accent)
                Text(preview.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(t.text)
                Spacer()
                Text(ByteFormat.string(preview.totalBytes))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(t.text2)
            }

            summarySection(t)

            Text("These items will move to the Trash, where you can restore them. Nothing is deleted permanently except the Trash category itself.")
                .font(.system(size: 12.5)).foregroundStyle(t.text3).fixedSize(horizontal: false, vertical: true)

            if preview.groups.isEmpty {
                Text("Nothing to clean in the current selection.")
                    .font(.system(size: 13)).foregroundStyle(t.text2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(preview.groups.enumerated()), id: \.element.category) { i, g in
                        if i > 0 { Divider().overlay(t.hair) }
                        previewRow(t, group: g)
                    }
                }
                .padding(.vertical, 4)
                .background(t.hair.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 10) {
                Spacer()
                ConsoButton(t: t, title: "Cancel", kind: .ghost) { model.cancelPreview() }
                ConsoButton(t: t, title: "Move to Trash", kind: .primary) { model.confirm(preview) }
                    .disabled(preview.targets.isEmpty)
                    .opacity(preview.targets.isEmpty ? 0.5 : 1)
            }
        }
        .padding(20).frame(width: 520)
        // Rebuild the summary whenever a new preview is shown; reset expansion too.
        .task(id: preview.id) {
            expandedCategories = []
            await summaryModel.load(for: preview)
        }
    }

    /// The plain-language summary at the top of the sheet: a spinner while it generates,
    /// then the paragraph, with a subtle "Basic summary" footnote when it isn't AI-generated
    /// (mirrors DoctorView / ExplainView).
    @ViewBuilder private func summarySection(_ t: Tokens) -> some View {
        switch summaryModel.phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Summarizing…").font(.system(size: 12.5)).foregroundStyle(t.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .loaded(_, let r) where !r.summary.isEmpty:
            VStack(alignment: .leading, spacing: 4) {
                Text(r.summary)
                    .font(.system(size: 13)).foregroundStyle(t.text2).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !r.isAIGenerated {
                    Text("Basic summary — turn on Apple Intelligence for richer explanations.")
                        .font(.system(size: 10.5)).foregroundStyle(t.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .idle, .loaded:
            EmptyView()
        }
    }

    /// Cap on how many individual items each expanded category lists before the "+N more"
    /// line — keeps a category with hundreds of caches from flooding the sheet.
    private static let previewItemCap = 15

    @ViewBuilder private func previewRow(_ t: Tokens, group g: CleanPreview.Group) -> some View {
        // Expandable only when there are concrete items to show.
        let expandable = !g.items.isEmpty
        let isExpanded = expandedCategories.contains(g.category)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if expandable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(t.text3)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.category.displayName).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(t.text)
                    if g.needsHelper && !model.helperInstalled {
                        Text("needs the privileged helper — will be skipped").font(.system(size: 11)).foregroundStyle(t.warn)
                    } else if g.needsHelper {
                        Text("\(g.count) snapshot\(g.count == 1 ? "" : "s") — removed via the privileged helper").font(.system(size: 11)).foregroundStyle(t.text3)
                    } else if g.needsFDA {
                        Text("needs Full Disk Access").font(.system(size: 11)).foregroundStyle(t.warn)
                    } else {
                        Text("\(g.count) item\(g.count == 1 ? "" : "s")").font(.system(size: 11.5)).foregroundStyle(t.text3)
                    }
                }
                Spacer(minLength: 8)
                Text(ByteFormat.string(g.bytes))
                    .font(.system(size: 13, weight: .regular).monospacedDigit()).foregroundStyle(t.text2)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .contentShape(Rectangle())
            .onTapGesture {
                guard expandable else { return }
                if isExpanded { expandedCategories.remove(g.category) }
                else { expandedCategories.insert(g.category) }
            }

            if expandable && isExpanded {
                itemList(t, group: g)
            }
        }
    }

    /// The expanded per-category item list: each item's name, its path (truncated,
    /// monospaced, secondary), and per-item size — top 15, then a "+N more…" line.
    private func itemList(_ t: Tokens, group g: CleanPreview.Group) -> some View {
        let shown = Array(g.items.prefix(Self.previewItemCap))
        let remaining = g.items.count - shown.count
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { item in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(PathName.leaf(item.path))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(t.text)
                            .lineLimit(1).truncationMode(.middle)
                        Text(item.path)
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(t.text3)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Text(ByteFormat.string(item.bytes))
                        .font(.system(size: 11.5, weight: .regular).monospacedDigit()).foregroundStyle(t.text2)
                }
                .padding(.vertical, 5)
            }
            if remaining > 0 {
                Text("+\(remaining) more…")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(t.text3)
                    .padding(.top, 3)
            }
        }
        .padding(.leading, 26).padding(.trailing, 14)
        .padding(.bottom, 10).padding(.top, 1)
    }

    // MARK: - Result summary (fail loud)

    /// The after-run summary: trashed / skipped / failed counts and bytes freed, with the
    /// failed items listed explicitly (never swallowed).
    private func resultSheet(_ t: Tokens, _ result: CleanRunResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: result.failedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 16)).foregroundStyle(result.failedCount == 0 ? t.good : t.warn)
                Text(result.failedCount == 0 ? "Clean complete" : "Clean finished with issues")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(t.text)
                Spacer()
            }
            HStack(spacing: 20) {
                summaryStat(t, value: "\(result.trashedCount)", label: "removed")
                summaryStat(t, value: "\(result.skippedCount)", label: "skipped")
                summaryStat(t, value: "\(result.failedCount)", label: "failed")
                summaryStat(t, value: ByteFormat.string(result.bytesFreed), label: "reclaimed")
            }

            if !result.failedItems.isEmpty {
                Text("Could not remove").font(.system(size: 12, weight: .semibold)).foregroundStyle(t.warn)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(result.failedItems) { item in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(PathName.leaf(item.path))
                                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(t.text)
                                if case .failed(let reason) = item.outcome {
                                    Text(reason).font(.system(size: 11)).foregroundStyle(t.text3)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 160)
                .background(t.hair, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack { Spacer()
                ConsoButton(t: t, title: "Done", kind: .primary) { model.dismissResult() }
            }
        }
        .padding(20).frame(width: 480)
    }

    private func summaryStat(_ t: Tokens, value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .semibold).monospacedDigit()).foregroundStyle(t.text)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(t.text3)
        }
    }
}

/// `Identifiable` wrapper so `CleanRunResult` (a value type without an id) can drive a
/// `.sheet(item:)`.
private struct ResultBox: Identifiable {
    let id = UUID()
    let result: CleanRunResult
}
