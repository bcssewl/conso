import Foundation

/// How often scheduled auto-clean runs the conservative Quick Clean. Off by default at the
/// settings layer — this enum only describes the cadence once the user opts in. Each case
/// carries a fixed `TimeInterval` (the "due window") so the pure `CleanSchedule.isDue`
/// decision is deterministic and unit-testable, independent of wall-clock calendars.
public enum CleanScheduleInterval: String, CaseIterable, Sendable, Codable {
    case daily
    case weekly
    case monthly

    /// The minimum elapsed time before the next run is due. Calendar-free (fixed seconds)
    /// so the schedule decision is deterministic — "monthly" means every 30 days, not a
    /// calendar month, which keeps `isDue` pure and the tests hermetic.
    public var interval: TimeInterval {
        switch self {
        case .daily:   return 24 * 60 * 60
        case .weekly:  return 7 * 24 * 60 * 60
        case .monthly: return 30 * 24 * 60 * 60
        }
    }

    /// Human-readable name for the Settings picker.
    public var displayName: String {
        switch self {
        case .daily:   return "Daily"
        case .weekly:  return "Weekly"
        case .monthly: return "Monthly"
        }
    }
}

/// Pure scheduling decision for auto-clean. No I/O, no clock of its own — the caller passes
/// `now` and the persisted `lastRun`, so the rule is exhaustively unit-testable.
public enum CleanSchedule {
    /// True when an auto-clean is due: never run before (`lastRun == nil`) ⇒ due immediately;
    /// otherwise due once at least `interval`'s worth of time has elapsed since `lastRun`.
    public static func isDue(now: Date, lastRun: Date?, interval: CleanScheduleInterval) -> Bool {
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= interval.interval
    }

    /// The category set scheduled auto-clean is allowed to touch — exactly the manual Quick
    /// Clean subset (`CleanCatalog.quickCleanCategories`). Defined here so the scheduler's
    /// runner and the manual path provably agree on scope: caches, dev junk, browser data,
    /// logs, trash. NEVER app leftovers, NEVER any hidden / recovery-data item.
    public static var quickCleanCategories: Set<CleanCategory> { CleanCatalog.quickCleanCategories }

    /// The concrete target ids (paths) for a scheduled run, drawn from completed scans keyed
    /// by category raw value — mirrors `CleanModel.targets(in:)`. Pure given the scan map so
    /// the runner and the manual Quick Clean path select the same targets.
    public static func quickCleanTargetIDs(scans: [String: CategoryScan]) -> [String] {
        quickCleanTargets(scans: scans).map(\.path)
    }

    /// The concrete targets for a scheduled run: the Quick Clean categories' targets from the
    /// supplied scan map. Same selection rule as the manual path.
    public static func quickCleanTargets(scans: [String: CategoryScan]) -> [CleanTarget] {
        quickCleanCategories.flatMap { scans[$0.rawValue]?.targets ?? [] }
    }
}
