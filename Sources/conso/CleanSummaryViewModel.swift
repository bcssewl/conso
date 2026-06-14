import Foundation
import Observation
import ConsoCore

/// Drives the plain-language summary shown at the TOP of the Clean confirmation sheet: it
/// builds the AGGREGATED `CleanSummaryFacts` from the preview's targets and phrases them,
/// picking the live on-device summarizer on macOS 26+ and the deterministic one otherwise.
/// Mirrors `ExplainViewModel` / `DoctorViewModel`.
@MainActor
@Observable
final class CleanSummaryViewModel {
    /// One source of truth for the summary lifecycle (mirrors `ExplainViewModel.Phase`). The
    /// `loaded` case carries the preview id it was built for so a re-drive of the SAME preview
    /// is a no-op and a superseded load can never strand the spinner — `isLoading == true`
    /// while a report exists is simply unrepresentable.
    enum Phase: Equatable {
        case idle
        case loading(previewID: UUID)
        case loaded(previewID: UUID, report: CleanSummaryReport)
    }
    private(set) var phase: Phase = .idle

    private let summarizer: CleanSummarizing

    /// `summarizer` is injectable for tests/previews; in the app it picks the live on-device
    /// summarizer on macOS 26+ and the deterministic one otherwise.
    init(summarizer: CleanSummarizing? = nil) {
        if let summarizer {
            self.summarizer = summarizer
        } else if #available(macOS 26, *) {
            self.summarizer = FoundationModelsCleanSummarizer()
        } else {
            self.summarizer = FallbackCleanSummarizer()
        }
    }

    /// Builds the aggregated facts from the preview's targets and phrases them. Idempotent
    /// per preview — re-running for the same preview returns immediately.
    func load(for preview: CleanPreview) async {
        // Already loaded for this exact preview → nothing to do.
        if case .loaded(let id, _) = phase, id == preview.id { return }
        phase = .loading(previewID: preview.id)
        let facts = CleanSummaryFacts.from(targets: preview.targets,
                                           isQuickClean: preview.kind == .quick)
        let result = await summarizer.summarize(facts)
        // A newer preview may have superseded this one while we awaited — only publish if
        // we're still the active load for this preview.
        guard case .loading(let id) = phase, id == preview.id else { return }
        phase = .loaded(previewID: preview.id, report: result)
    }
}
