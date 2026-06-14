import Foundation

/// The seam between conso and the model for the Clean confirmation summary. Implementations
/// NEVER throw — any failure falls back to a deterministic report — so the sheet always
/// gets a usable paragraph. Mirrors `Explaining` / `DoctorAdvising`.
public protocol CleanSummarizing: Sendable {
    func summarize(_ facts: CleanSummaryFacts) async -> CleanSummaryReport
}

/// The no-AI implementation: always the deterministic fallback. Used on older systems,
/// when AI is off, and as the injectable test double.
public struct FallbackCleanSummarizer: CleanSummarizing {
    public init() {}
    public func summarize(_ facts: CleanSummaryFacts) async -> CleanSummaryReport {
        CleanSummaryFallback.report(from: facts)
    }
}

/// Builds a `CleanSummaryReport` from facts with no model involved. This is BOTH the no-AI
/// fallback AND the canonical facts→words mapping — so the sheet always has a truthful,
/// one-paragraph summary. Mirrors `ExplainFallback` / `DoctorFallback`.
public enum CleanSummaryFallback {
    public static func report(from f: CleanSummaryFacts) -> CleanSummaryReport {
        CleanSummaryReport(summary: summary(from: f), isAIGenerated: false)
    }

    /// A deterministic, templated one-paragraph summary. Calm, accurate to the facts, no
    /// marketing, no emoji.
    public static func summary(from f: CleanSummaryFacts) -> String {
        guard f.totalCount > 0, !f.categories.isEmpty else {
            return "Nothing to clean in the current selection."
        }

        var sentences: [String] = []

        // Lead: how much, across how many items.
        let itemWord = f.totalCount == 1 ? "item" : "items"
        sentences.append("Frees ~\(ByteFormat.string(f.totalBytes)) across \(f.totalCount) \(itemWord).")

        // Composition: the largest category (with its size), then a nod to the rest.
        if let largest = f.largestCategory {
            let largestName = largest.category.displayName
            if f.categories.count == 1 {
                sentences.append("It's all \(largestName) (\(ByteFormat.string(largest.bytes))).")
            } else {
                let rest = f.categories.dropFirst().map { $0.category.displayName }
                sentences.append("Most of it is \(largestName) (\(ByteFormat.string(largest.bytes))); the rest is \(joinList(rest)).")
            }
        }

        // Safety: reversibility + a stronger note when recovery data is involved.
        if f.includesRecoveryData {
            sentences.append("Some of this is recovery data that doesn't move to the Trash — review it before continuing.")
        } else if f.isFullyReversible {
            sentences.append("Everything moves to the Trash, so it's reversible.")
        } else {
            sentences.append("Most of this moves to the Trash; emptying the Trash itself is permanent.")
        }

        return sentences.joined(separator: " ")
    }

    /// Joins a list of names into readable prose: "A", "A and B", "A, B and C".
    private static func joinList(_ names: some Sequence<String>) -> String {
        let items = Array(names)
        switch items.count {
        case 0: return "a few smaller categories"
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            let head = items.dropLast().joined(separator: ", ")
            return "\(head) and \(items.last!)"
        }
    }
}
