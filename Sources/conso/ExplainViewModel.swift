import Foundation
import Observation
import ConsoCore

/// Drives one "What's this?" popover: given a target (+ optional size) it produces an
/// `ExplainReport`, picking the live on-device explainer on macOS 26+ and the
/// deterministic one otherwise. Lightweight and reusable — every info affordance creates
/// its own instance, so popovers don't share state.
@MainActor
@Observable
final class ExplainViewModel {
    enum Phase: Equatable { case idle, loading, loaded(ExplainReport) }
    var phase: Phase = .idle

    private let explainer: Explaining

    /// `explainer` is injectable for tests/previews; in the app it picks the live
    /// on-device explainer on macOS 26+ and the deterministic one otherwise.
    init(explainer: Explaining? = nil) {
        if let explainer {
            self.explainer = explainer
        } else if #available(macOS 26, *) {
            self.explainer = FoundationModelsExplainer()
        } else {
            self.explainer = FallbackExplainer()
        }
    }

    /// Resolves the grounded facts from the deterministic safety table, then phrases them.
    func run(target: ExplainTarget, sizeBytes: UInt64? = nil) async {
        // Re-running on an already-loaded popover is a no-op (cheap, idempotent).
        if case .loaded = phase { return }
        phase = .loading
        let facts = SafetyCatalog.facts(for: target, sizeBytes: sizeBytes)
        let report = await explainer.explain(facts)
        phase = .loaded(report)
    }
}
