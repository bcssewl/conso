import Foundation

/// The plain-language summary shown at the TOP of the Clean confirmation sheet. The
/// deterministic fallback builds it directly; the live model produces a mirror whose
/// `summary` is the only model-authored field (`isAIGenerated == true`). Mirrors
/// `ExplainReport` / `DoctorReport` in role.
public struct CleanSummaryReport: Sendable, Equatable {
    public var summary: String
    public var isAIGenerated: Bool
    public init(summary: String, isAIGenerated: Bool) {
        self.summary = summary
        self.isAIGenerated = isAIGenerated
    }
}
