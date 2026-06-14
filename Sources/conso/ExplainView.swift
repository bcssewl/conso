import SwiftUI
import ConsoCore

/// A small "What's this?" info affordance — an `info.circle` button that opens a compact
/// popover explaining the given target. Drop it onto any cleanable / updatable / file row.
/// Each instance owns its own `ExplainViewModel`, so popovers don't share state.
struct ExplainButton: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.colorScheme) private var scheme

    let target: ExplainTarget
    var sizeBytes: UInt64? = nil

    @State private var showing = false
    @State private var model = ExplainViewModel()

    var body: some View {
        let t = theme.tokens(scheme)
        Button { showing = true } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(t.text3)
        }
        .buttonStyle(.plain)
        .help("What's this?")
        .popover(isPresented: $showing, arrowEdge: .top) {
            ExplainPopover(t: t, model: model)
                .task { await model.run(target: target, sizeBytes: sizeBytes) }
        }
    }
}

/// The popover body: title, plain-language summary, a verdict chip (dot + text — no
/// colored capsule behind the label, per conso's status-pill convention), and the
/// "Basic summary…" footnote when the explanation isn't AI-generated.
struct ExplainPopover: View {
    let t: Tokens
    @Bindable var model: ExplainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.phase {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking this up…").font(.system(size: 12.5)).foregroundStyle(t.text2)
                }
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            case .loaded(let r):
                report(r)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    @ViewBuilder private func report(_ r: ExplainReport) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").font(.system(size: 13)).foregroundStyle(t.accent)
            Text(r.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(t.text)
            Spacer(minLength: 6)
        }

        Text(r.summary)
            .font(.system(size: 12.5)).foregroundStyle(t.text2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

        // Verdict: dot + text only (no capsule background behind the status text). The
        // label is phrased for the page's action — "Safe to update" / "Safe to run" /
        // "Safe to move to Trash" — so it matches what the button below actually does.
        HStack(spacing: 6) {
            Circle().fill(verdictColor(r.verdict)).frame(width: 7, height: 7)
            Text(r.verdict.label(for: r.actionKind))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(verdictColor(r.verdict))
        }
        .padding(.top, 1)

        if !r.isAIGenerated {
            Text("Basic summary — turn on Apple Intelligence for richer explanations.")
                .font(.system(size: 10.5)).foregroundStyle(t.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 1)
        }
    }

    private func verdictColor(_ v: ExplainVerdict) -> Color {
        switch v {
        case .safe: return t.good
        case .caution, .recoveryData: return t.warn
        }
    }
}
