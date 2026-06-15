import SwiftUI
import ConsoCore

struct OptimizeView: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.colorScheme) private var scheme
    @Bindable var model: OptimizeModel

    var body: some View {
        let t = theme.tokens(scheme)
        let selected = model.tasks.selectedCount
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PillarHeader(t: t, title: "Fix a problem", subtitle: "targeted repairs · nothing runs until you pick it")

                VStack(spacing: 18) {
                    statStrip(t, selected: selected)
                    hero(t, selected: selected)
                    if model.isDetecting {
                        detectingCard(t)
                    } else if model.tasks.isEmpty {
                        EmptyState(t: t, icon: "checkmark.seal",
                                   title: "Nothing to fix right now",
                                   message: "No situational repairs apply to your system at the moment. These tools are here when a symptom shows up.")
                    } else {
                        tasksCard(t, selected: selected)
                    }
                }
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .padding(20)
        }
        .onAppear { model.detect() }
        .confirmationDialog("Run selected fixes?",
                            isPresented: Binding(get: { model.pendingConfirmation != nil },
                                                 set: { if !$0 { model.cancelConfirmation() } }),
                            titleVisibility: .visible,
                            presenting: model.pendingConfirmation) { _ in
            Button("Run now") { model.confirmRun() }
            Button("Cancel", role: .cancel) { model.cancelConfirmation() }
        } message: { plan in
            Text(confirmMessage(plan))
        }
        .sheet(item: Binding(get: { model.appPicker }, set: { if $0 == nil { model.cancelAppPicker() } })) { picker in
            appPickerSheet(t, picker)
        }
        .sheet(isPresented: Binding(get: { model.showingResults }, set: { if !$0 { model.dismissResults() } })) {
            resultsSheet(t)
        }
    }

    private func statStrip(_ t: Tokens, selected: Int) -> some View {
        // Real "Last run" from the persisted timestamp — "Never" until the first run.
        let age = RelativeAgeFormat.valueUnit(model.lastRun, now: Date())
        return HStack(spacing: 14) {
            StatCell(t: t, symbol: "clock", key: "Last run",
                     value: age?.value ?? "Never", valueSuffix: age?.unit ?? "",
                     detail: lastRunDetail(age))
            StatCell(t: t, symbol: "checklist", key: "Fixes", value: "\(model.tasks.count)", detail: "available")
            StatCell(t: t, symbol: "hand.tap", key: "Selected", value: "\(selected)", detail: "tasks")
            StatCell(t: t, symbol: "externaldrive", key: "Scope", value: "app", valueSuffix: "& sys", detail: "caches")
        }
    }

    /// Detail line under "Last run": honest for never-run, just-run, and aged cases.
    private func lastRunDetail(_ age: (value: String, unit: String)?) -> String {
        guard let age else { return "no runs yet" }
        return age.value == "now" ? "just now" : "ago"
    }

    private func hero(_ t: Tokens, selected: Int) -> some View {
        VStack(spacing: 16) {
            Text("Something acting up? Pick the fix that matches the symptom — these aren't routine cleanups, so nothing is selected until you choose it.")
                .font(.system(size: 14)).foregroundStyle(t.text2)
                .multilineTextAlignment(.center).lineSpacing(2)
                .frame(maxWidth: 520)
            HStack(spacing: 10) {
                ConsoButton(t: t, title: selected > 0 ? "Run \(selected) Selected" : "Run Selected Fixes",
                            kind: .primary, large: true) { model.runSelected() }
                    .opacity(selected > 0 ? 1 : 0.5)
                    .disabled(selected == 0)
                ConsoButton(t: t, title: "Clear selection", kind: .ghost, large: true) { model.setAll(false) }
            }
        }
        .padding(.top, 4)
    }

    // MARK: Loading (detect pass on first appear)

    /// Skeleton rows shaped like the situational-fixes list while the detect pass settles,
    /// so the section keeps its layout before the real fixes appear.
    private func detectingCard(_ t: Tokens) -> some View {
        SectionCard(t: t) {
            HStack {
                CardTitle(t: t, text: "Situational fixes")
                Spacer()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking your system…").font(.system(size: 12, weight: .semibold)).foregroundStyle(t.text3)
                }
            }
        } content: {
            VStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { i in
                    if i > 0 { Divider().overlay(t.hair) }
                    HStack(spacing: 12) {
                        SkeletonBlock(t: t, height: 34, width: 34, corner: 9)
                        VStack(alignment: .leading, spacing: 6) {
                            SkeletonBlock(t: t, height: 13, width: 170)
                            SkeletonBlock(t: t, height: 11, width: 240)
                        }
                        Spacer(minLength: 8)
                        SkeletonBlock(t: t, height: 18, width: 52, corner: 9)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 13)
                }
            }
        } footer: {
            SkeletonBlock(t: t, height: 12, width: 200)
        }
    }

    private func tasksCard(_ t: Tokens, selected: Int) -> some View {
        SectionCard(t: t) {
            HStack {
                CardTitle(t: t, text: "Situational fixes")
                Spacer()
                Button {
                    let allOn = model.tasks.allSatisfy(\.isSelected)
                    model.setAll(!allOn)
                } label: {
                    Text(model.tasks.allSatisfy(\.isSelected) ? "Clear all" : "Select all")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(t.accent)
                }
                .buttonStyle(.plain)
            }
        } content: {
            VStack(spacing: 0) {
                ForEach(Array(model.tasks.enumerated()), id: \.element.id) { i, task in
                    if i > 0 { Divider().overlay(t.hair) }
                    taskRow(t, task: task)
                }
            }
        } footer: {
            HStack(spacing: 8) {
                Text(selected == 0 ? "0 selected — pick a fix above" : "\(selected) selected")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(t.text2)
                Spacer()
                Label("Admin password requested only if needed", systemImage: "shield")
                    .font(.system(size: 12)).foregroundStyle(t.text3).labelStyle(.titleAndIcon)
            }
        }
    }

    private func taskRow(_ t: Tokens, task: FixTask) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(t.accentSoft)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: task.symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(t.accent))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(task.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(t.text)
                    // "What's this?" — explains what the fix does, whether it's safe to run,
                    // and whether it needs admin. Grounded in SafetyCatalog's .fixTask facts.
                    ExplainButton(target: .fixTask(id: task.id))
                }
                Text(task.detail).font(.system(size: 11.5)).foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
                if task.needsHelper {
                    let installed = HelperClient.shared.isInstalled
                    // Single expression (nested ternary): if/else statements aren't allowed
                    // here inside the ViewBuilder. Self-signed builds can't run the helper.
                    let copy = !AppDistribution.supportsPrivilegedHelper
                        ? (task.userSteps.isEmpty ? "needs the developer build — unavailable in this download"
                                                  : "partly needs the developer build — unavailable in this download")
                        : (installed
                            ? (task.userSteps.isEmpty ? "runs via the privileged helper"
                                                      : "partly runs via the privileged helper")
                            : (task.userSteps.isEmpty ? "needs the privileged helper — install it in Settings"
                                                      : "partly needs the privileged helper — install it in Settings"))
                    Label(copy, systemImage: installed ? "checkmark.shield" : "lock.shield")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(installed ? t.text3 : t.warn)
                        .labelStyle(.titleAndIcon)
                }
            }
            Spacer(minLength: 8)
            Badge(t: t, text: task.badge, style: task.badgeIsWarm ? .warm : .muted)
            CheckToggle(t: t, isOn: task.isSelected)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(task.id) }
    }

    // MARK: - Confirm dialog message

    /// Plain-text body for the confirm dialog: what runs now, what's deferred to the
    /// (not-yet-built) admin helper, and any pointed warnings.
    private func confirmMessage(_ plan: RunPlan) -> String {
        let installed = HelperClient.shared.isInstalled
        var lines: [String] = []
        let now = plan.runsNow.map(\.name)
        if !now.isEmpty { lines.append("Runs now: " + now.joined(separator: ", ")) }

        let partial = plan.partial.map(\.name)
        if !partial.isEmpty {
            lines.append(installed
                ? "Partly runs via the privileged helper: " + partial.joined(separator: ", ")
                : "Partly skipped (some steps need the privileged helper — install it in Settings): "
                  + partial.joined(separator: ", "))
        }
        let helperOnly = plan.helperOnly.map(\.name)
        if !helperOnly.isEmpty {
            lines.append(installed
                ? "Runs via the privileged helper: " + helperOnly.joined(separator: ", ")
                : "Needs the privileged helper — install it in Settings (won't run): "
                  + helperOnly.joined(separator: ", "))
        }
        for w in plan.warnings { lines.append("⚠︎ \(w.name): \(w.text)") }
        return lines.joined(separator: "\n\n")
    }

    // MARK: - App picker sheet (Reset an App's Preferences)

    private func appPickerSheet(_ t: Tokens, _ picker: AppPickerState) -> some View {
        @Bindable var picker = picker
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "gearshape").font(.system(size: 16, weight: .semibold)).foregroundStyle(t.accent)
                Text("Choose an app to reset").font(.system(size: 16, weight: .semibold)).foregroundStyle(t.text)
                Spacer()
            }
            Text("This wipes the app's preferences (defaults delete) — there is no undo. Quit the app first.")
                .font(.system(size: 12.5)).foregroundStyle(t.warn).fixedSize(horizontal: false, vertical: true)

            if picker.isLoading {
                HStack(spacing: 8) { ProgressView().controlSize(.small)
                    Text("Loading installed apps…").font(.system(size: 12.5)).foregroundStyle(t.text3) }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(picker.apps) { app in
                            Button { model.choosePickedApp(app.bundleID) } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(app.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(t.text)
                                        Text(app.bundleID).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(t.text3)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(t.hair)
                        }
                    }
                }
                .frame(height: 240)
                .background(t.hair.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 8) {
                TextField("…or type a bundle id (com.example.app)", text: $picker.manualBundleID)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                ConsoButton(t: t, title: "Use", kind: .ghost) {
                    let id = picker.manualBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !id.isEmpty { model.choosePickedApp(id) }
                }
                .disabled(picker.manualBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack { Spacer()
                ConsoButton(t: t, title: "Cancel", kind: .ghost) { model.cancelAppPicker() }
            }
        }
        .padding(20).frame(width: 460)
    }

    // MARK: - Results sheet (per-task status, fail loud)

    private func resultsSheet(_ t: Tokens) -> some View {
        let results = model.runner.results
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if model.runner.isRunning { ProgressView().controlSize(.small) }
                else { Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(t.good) }
                Text(model.runner.isRunning ? "Running fixes…" : "Fixes finished")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(t.text)
                Spacer()
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Divider().overlay(t.hair) }
                        resultRow(t, r)
                    }
                }
            }
            .frame(height: 300)
            .background(t.hair.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack { Spacer()
                ConsoButton(t: t, title: model.runner.isRunning ? "Run in background" : "Done", kind: .primary) {
                    model.dismissResults()
                }
            }
        }
        .padding(20).frame(width: 540)
    }

    private func resultRow(_ t: Tokens, _ r: FixResult) -> some View {
        let (icon, tint, label, detail) = statusPresentation(t, r.status)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(tint).frame(width: 16)
                Text(r.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(t.text)
                Spacer()
                Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            }
            if let detail, !detail.isEmpty {
                Text(detail).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(t.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(.leading, 25)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    /// Maps a per-task status to its icon, tint, short label, and detail text.
    private func statusPresentation(_ t: Tokens, _ status: FixStatus) -> (String, Color, String, String?) {
        switch status {
        case .pending:            return ("clock", t.text3, "queued", nil)
        case .running:            return ("arrow.triangle.2.circlepath", t.accent, "running…", nil)
        case .done(let summary):  return ("checkmark.circle.fill", t.good, "done", summary)
        case .partial(let summary): return ("checkmark.circle", t.warn, "partial", summary)
        case .failed(let message): return ("xmark.octagon.fill", t.warn, "failed", message)
        case .skippedNeedsHelper:  return ("lock.shield", t.warn, "needs admin helper", "Install the privileged helper in Settings to run this. Nothing ran.")
        case .skippedNeedsPicker:  return ("questionmark.circle", t.text3, "no app picked", "Skipped — no app/bundle id was chosen.")
        }
    }
}
