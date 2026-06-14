import Foundation

/// The seam between conso and the model for the "What's this?" explainer. Implementations
/// NEVER throw — any failure falls back to a deterministic report — so the UI always
/// receives one. Mirrors `DoctorAdvising`. Reuses the shared `AdvisorAvailability`.
public protocol Explaining: Sendable {
    func explain(_ facts: ExplainFacts) async -> ExplainReport
}

/// The no-AI implementation: always the deterministic fallback. Used on older systems,
/// when AI is off, and as the injectable test double.
public struct FallbackExplainer: Explaining {
    public init() {}
    public func explain(_ facts: ExplainFacts) async -> ExplainReport {
        ExplainFallback.report(from: facts)
    }
}
