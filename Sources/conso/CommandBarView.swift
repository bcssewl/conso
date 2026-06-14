import SwiftUI
import ConsoCore

/// The "Ask conso" command bar: a centered, Spotlight-like overlay where the user asks a
/// natural-language question about their Mac. As you type it shows the matching SAFE
/// actions (the launcher affordance); on Enter it ANSWERS in plain language — grounded in
/// real telemetry — and offers up to two one-tap actions. ↑/↓ to move, Enter to ask, Esc
/// to dismiss. When the on-device model is unavailable it degrades to the deterministic
/// keyword launcher, so it's never dead.
///
/// This is a maintenance control surface, NOT a general launcher — there is no file
/// search, no app launching, no arbitrary commands. Suggested actions come only from the
/// closed `CommandCatalog`; running one routes through `CommandBarViewModel.run` (the same
/// handlers the in-app controls use) and only ever on a user tap.
struct CommandBarView: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.colorScheme) private var scheme

    @Bindable var model: CommandBarViewModel
    let context: CommandContext
    /// Dismisses the overlay (clears focus + state).
    let dismiss: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        let t = theme.tokens(scheme)
        ZStack(alignment: .top) {
            // Scrim: click-out to dismiss.
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            panel(t)
                .frame(width: 540)
                .padding(.top, 96)
        }
        .onExitCommand { dismiss() }   // Esc
        .onAppear { fieldFocused = true }
    }

    private func panel(_ t: Tokens) -> some View {
        VStack(spacing: 0) {
            field(t)
            if model.isAnswering {
                Divider().overlay(t.hair)
                loadingState(t)
            } else if let answer = model.answer {
                Divider().overlay(t.hair)
                answerView(answer, t)
            } else if !model.results.isEmpty {
                Divider().overlay(t.hair)
                resultsList(t)
            } else if !model.query.isEmpty {
                emptyState(t)
            }
        }
        .background(t.glass ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(t.card),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(t.cardBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 30, y: 14)
    }

    private func field(_ t: Tokens) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(t.accent)
            TextField("Ask about your Mac — “why is it slow?” — or a command", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(t.text)
                .focused($fieldFocused)
                .onSubmit { model.submit(in: context) }   // Enter → grounded answer
                .onKeyPress(.downArrow) { model.moveDown(); return .handled }
                .onKeyPress(.upArrow) { model.moveUp(); return .handled }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private func resultsList(_ t: Tokens) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(model.results.enumerated()), id: \.element.id) { index, cmd in
                    row(cmd, active: index == model.selection, t: t)
                        .contentShape(Rectangle())
                        .onTapGesture { run(cmd) }
                        .onHover { if $0 { model.selection = index } }
                }
            }
            .padding(6)
        }
        .frame(maxHeight: 320)
    }

    // MARK: - Answer

    /// The grounded answer: the model's plain-language reply, a row of one-tap action
    /// buttons (each runs the SAFE catalog target on tap), and — offline — a subtle
    /// "Basic" hint plus, when out of scope, the example commands.
    private func answerView(_ answer: ConsoAnswer, _ t: Tokens) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(answer.answer)
                    .font(.system(size: 13.5))
                    .foregroundStyle(t.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !answer.isAIGenerated {
                    Text("Basic")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(t.text3)
                }
            }

            let commands = answer.suggestedCommands
            if !commands.isEmpty {
                HStack(spacing: 8) {
                    ForEach(commands) { cmd in
                        actionButton(cmd, t)
                    }
                    Spacer(minLength: 0)
                }
            } else if !answer.inScope {
                exampleHint(t)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func actionButton(_ cmd: ConsoCommand, _ t: Tokens) -> some View {
        Button { run(cmd) } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol(for: cmd)).font(.system(size: 12, weight: .medium))
                Text(cmd.title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(t.accentOn)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .background(t.accent, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func exampleHint(_ t: Tokens) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "lightbulb").font(.system(size: 11)).foregroundStyle(t.text3)
            Text("Try “free up space” or “run doctor”.")
                .font(.system(size: 11.5)).foregroundStyle(t.text3)
            Spacer(minLength: 0)
        }
    }

    private func loadingState(_ t: Tokens) -> some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text("Thinking…").font(.system(size: 12.5)).foregroundStyle(t.text3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
    }

    private func row(_ cmd: ConsoCommand, active: Bool, t: Tokens) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(for: cmd))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? t.accentOn : t.text2)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(cmd.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(active ? t.accentOn : t.text)
                Text(cmd.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(active ? t.accentOn.opacity(0.85) : t.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if active {
                Text("↩")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(t.accentOn.opacity(0.85))
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .background(active ? AnyShapeStyle(t.accent) : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func emptyState(_ t: Tokens) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(t.text3)
            Text("No matching action — conso only runs its own maintenance tools.")
                .font(.system(size: 12)).foregroundStyle(t.text3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    // MARK: - Run

    /// Runs a SAFE catalog target (navigate / Doctor sheet / Quick Clean PREVIEW / rescan /
    /// toggle) then dismisses — only ever from a user tap, never inline by the model.
    private func run(_ cmd: ConsoCommand) {
        model.run(cmd, in: context)
        dismiss()
    }

    /// A representative SF Symbol per command, matched to its pillar/effect.
    private func symbol(for cmd: ConsoCommand) -> String {
        switch cmd.target {
        case .navigate(let p):
            switch p {
            case .clean: return "sparkles"
            case .software: return "shippingbox"
            case .optimize: return "bolt"
            case .analyze: return "chart.bar"
            case .status: return "waveform.path.ecg"
            }
        case .runDoctor: return "stethoscope"
        case .quickClean: return "sparkles"
        case .checkUpdates: return "arrow.down.circle"
        case .openAnalyze: return "chart.bar"
        case .toggleKeepAwake: return "cup.and.saucer"
        }
    }
}
