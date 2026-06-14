import Foundation

/// A computed system-health summary for the Status hero.
public struct HealthReport: Sendable, Equatable {
    public let score: Int          // 0...100
    public let grade: String       // Excellent / Good / Fair / Needs attention
    public let summary: String
    public let checksPassed: Int
    public let checksTotal: Int
    public init(score: Int, grade: String, summary: String, checksPassed: Int, checksTotal: Int) {
        self.score = score
        self.grade = grade
        self.summary = summary
        self.checksPassed = checksPassed
        self.checksTotal = checksTotal
    }
}

public enum Health {
    /// Derives a health score and a pass/fail check list from real signals: disk
    /// fullness, memory pressure, thermal state, swap, and CPU load.
    public static func evaluate(diskFraction: Double, pressure: MemoryPressure, thermal: ThermalState,
                                swapUsed: UInt64 = 0, loadAverage: Double = 0, coreCount: Int = 0) -> HealthReport {
        // Score: each problem deducts points from a clean 100.
        let diskHit = diskFraction > 0.90 ? 20 : diskFraction > 0.80 ? 10 : diskFraction > 0.70 ? 4 : 0
        let memHit: Int = pressure == .high ? 20 : pressure == .medium ? 8 : 0
        let thermalHit: Int = {
            switch thermal {
            case .critical: return 30
            case .serious: return 15
            case .fair: return 5
            case .nominal: return 0
            }
        }()
        let score = max(0, 100 - diskHit - memHit - thermalHit)
        let grade = score >= 95 ? "Excellent" : score >= 75 ? "Good" : score >= 55 ? "Fair" : "Needs attention"

        // Discrete health checks (the "N checks passed" line).
        let diskOk = diskFraction < 0.90
        let memOk = pressure != .high
        let thermalOk = thermal != .serious && thermal != .critical
        let swapOk = swapUsed < 2_000_000_000
        let loadOk = coreCount == 0 || loadAverage < Double(coreCount)
        let checks = [diskOk, memOk, thermalOk, swapOk, loadOk]
        let passed = checks.filter { $0 }.count

        let summary: String
        if passed == checks.count {
            summary = "all \(checks.count) checks passed · nothing needs attention"
        } else if !diskOk {
            summary = "disk is filling up — consider a clean"
        } else if !memOk {
            summary = "memory is under pressure"
        } else if !thermalOk {
            summary = "the system is running warm"
        } else if !swapOk {
            summary = "swap is in heavy use"
        } else {
            summary = "CPU load is high"
        }
        return HealthReport(score: score, grade: grade, summary: summary, checksPassed: passed, checksTotal: checks.count)
    }
}
