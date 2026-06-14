import Foundation

/// Whether the on-device model is usable, with a user-facing reason when not. The
/// live adapter maps the system framework's availability onto this; the enum is
/// pure so its messaging stays unit-testable without the framework.
public enum AdvisorAvailability: Sendable, Equatable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupported(String)

    public var isAvailable: Bool { self == .available }

    /// A short note to show when AI is off (nil when available).
    public var userMessage: String? {
        switch self {
        case .available: return nil
        case .deviceNotEligible: return "AI explanations aren’t supported on this Mac."
        case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings for AI explanations."
        case .modelNotReady: return "The on-device model is still downloading — try again shortly."
        case .unsupported(let why): return "AI explanations are unavailable. (\(why))"
        }
    }
}

/// The seam between conso and the model. Implementations NEVER throw — any failure
/// falls back to a deterministic report — so the UI always receives one.
public protocol DoctorAdvising: Sendable {
    func generateReport(from facts: DoctorFacts) async -> DoctorReport
}

/// The no-AI implementation: always the deterministic fallback. Used on older
/// systems, when AI is off, and as the injectable test double.
public struct FallbackDoctorAdvisor: DoctorAdvising {
    public init() {}
    public func generateReport(from facts: DoctorFacts) async -> DoctorReport {
        DoctorFallback.report(from: facts)
    }
}
