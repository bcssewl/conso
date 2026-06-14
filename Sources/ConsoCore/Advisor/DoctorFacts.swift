import Foundation

/// A compact, grounded snapshot of system health handed to the advisor. Built
/// entirely from real telemetry — the model only ever sees these facts, never the
/// live system. Kept small to fit the on-device model's ~4k-token budget.
public struct DoctorFacts: Sendable, Equatable {
    public var score: Int
    public var grade: String
    public var checksPassed: Int
    public var checksTotal: Int
    public var cpuPercent: Int
    public var memoryPercent: Int
    public var diskPercent: Int
    public var swapBytes: UInt64
    public var thermal: ThermalState
    public var pressure: MemoryPressure
    public var dieTempC: Double?
    public var uptime: TimeInterval
    public var topProcesses: [String]

    public init(score: Int, grade: String, checksPassed: Int, checksTotal: Int,
                cpuPercent: Int, memoryPercent: Int, diskPercent: Int, swapBytes: UInt64,
                thermal: ThermalState, pressure: MemoryPressure, dieTempC: Double?,
                uptime: TimeInterval, topProcesses: [String]) {
        self.score = score; self.grade = grade
        self.checksPassed = checksPassed; self.checksTotal = checksTotal
        self.cpuPercent = cpuPercent; self.memoryPercent = memoryPercent
        self.diskPercent = diskPercent; self.swapBytes = swapBytes
        self.thermal = thermal; self.pressure = pressure
        self.dieTempC = dieTempC; self.uptime = uptime
        self.topProcesses = topProcesses
    }

    /// Builds facts from a live snapshot, reusing the existing `Health` scoring so
    /// the AI summary and the Status hero never disagree. `topProcesses` is capped.
    public static func from(snapshot s: SystemSnapshot, topProcesses procs: [String]) -> DoctorFacts {
        let health = Health.evaluate(diskFraction: s.diskFraction, pressure: s.memoryPressure,
                                     thermal: s.thermal, swapUsed: s.swapUsed,
                                     loadAverage: s.loadAverage, coreCount: s.cpuCoreCount)
        func pct(_ f: Double) -> Int { Int((max(0, min(1, f)) * 100).rounded()) }
        return DoctorFacts(
            score: health.score, grade: health.grade,
            checksPassed: health.checksPassed, checksTotal: health.checksTotal,
            cpuPercent: pct(s.cpuUsage), memoryPercent: pct(s.memoryFraction), diskPercent: pct(s.diskFraction),
            swapBytes: s.swapUsed, thermal: s.thermal, pressure: s.memoryPressure,
            dieTempC: s.dieTempC, uptime: s.uptime,
            topProcesses: Array(procs.prefix(3)))
    }
}
