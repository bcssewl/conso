import Foundation

public enum DoctorStatus: String, Sendable, Equatable { case healthy, attention, critical, unknown }
public enum Severity: String, Sendable, Equatable { case info, warn, critical }
public enum SuggestionTarget: String, Sendable, Equatable { case clean, optimize, analyze, software, status }

/// One thing worth the user's attention. `id == title` so streamed/rebuilt lists
/// keep stable identity in SwiftUI.
public struct Finding: Sendable, Equatable, Identifiable {
    public var title: String
    public var detail: String
    public var severity: Severity
    public var id: String { title }
    public init(title: String, detail: String, severity: Severity) {
        self.title = title; self.detail = detail; self.severity = severity
    }
}

/// A one-tap next step. The *target* is chosen deterministically by conso — the
/// model never decides where to send the user.
public struct Suggestion: Sendable, Equatable {
    public var label: String
    public var target: SuggestionTarget
    public init(label: String, target: SuggestionTarget) { self.label = label; self.target = target }
}

/// The plain-language health report the Doctor renders. The deterministic fallback
/// produces it directly; the live model produces a mirror that maps onto it.
public struct DoctorReport: Sendable, Equatable {
    public var headline: String
    public var status: DoctorStatus
    public var score: Int
    public var findings: [Finding]
    public var suggestion: Suggestion?
    public var isAIGenerated: Bool
    public init(headline: String, status: DoctorStatus, score: Int,
                findings: [Finding], suggestion: Suggestion?, isAIGenerated: Bool) {
        self.headline = headline; self.status = status; self.score = score
        self.findings = findings; self.suggestion = suggestion; self.isAIGenerated = isAIGenerated
    }
}
