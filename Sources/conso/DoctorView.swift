import SwiftUI
import ConsoCore

struct DoctorView: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(Router.self) private var router
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    let snapshot: SystemSnapshot
    let topProcesses: [String]
    @State private var model = DoctorViewModel()

    var body: some View {
        let t = theme.tokens(scheme)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "stethoscope").foregroundStyle(t.accent)
                Text("Doctor").font(.system(size: 16, weight: .semibold)).foregroundStyle(t.text)
            }
            content(t)
        }
        .padding(20)
        .frame(width: 420)
        .background(t.bg)
        .task { await model.run(snapshot: snapshot, topProcesses: topProcesses) }
    }

    @ViewBuilder private func content(_ t: Tokens) -> some View {
        switch model.phase {
        case .idle, .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking your Mac…").font(.system(size: 13)).foregroundStyle(t.text2)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        case .loaded(let r):
            report(r, t)
        }
    }

    private func report(_ r: DoctorReport, _ t: Tokens) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Ring(fraction: Double(r.score) / 100, color: statusColor(r.status, t), track: t.hair)
                        .frame(width: 54, height: 54)
                    Text("\(r.score)").font(.system(size: 16, weight: .bold).monospacedDigit()).foregroundStyle(t.text)
                }
                Text(r.headline).font(.system(size: 14, weight: .medium)).foregroundStyle(t.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !r.findings.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(r.findings) { f in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(severityColor(f.severity, t)).frame(width: 7, height: 7).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(t.text)
                                Text(f.detail).font(.system(size: 11.5)).foregroundStyle(t.text2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            HStack {
                if let s = r.suggestion {
                    ConsoButton(t: t, title: s.label, kind: .primary) {
                        router.pillar = pillar(for: s.target)
                        dismiss()
                    }
                }
                Spacer()
                ConsoButton(t: t, title: "Done", kind: .ghost) { dismiss() }
            }

            if !r.isAIGenerated {
                Text("Basic summary — turn on Apple Intelligence for richer explanations.")
                    .font(.system(size: 10.5)).foregroundStyle(t.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusColor(_ s: DoctorStatus, _ t: Tokens) -> Color {
        switch s {
        case .healthy: return t.good
        case .attention, .critical, .unknown: return t.warn
        }
    }
    private func severityColor(_ s: Severity, _ t: Tokens) -> Color {
        switch s {
        case .info: return t.text3
        case .warn, .critical: return t.warn
        }
    }
    private func pillar(for target: SuggestionTarget) -> Pillar {
        switch target {
        case .clean: return .clean
        case .optimize: return .optimize
        case .analyze: return .analyze
        case .software: return .software
        case .status: return .status
        }
    }
}
