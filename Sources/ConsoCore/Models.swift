import Foundation

/// A single point-in-time sample of system metrics for the Status pillar + menu-bar HUD.
public struct SystemSnapshot: Sendable, Equatable {
    public var cpuUsage: Double      // 0...1
    public var cpuCoreCount: Int     // physical cores
    public var loadAverage: Double   // 1-minute load average
    public var gpuUsage: Double      // 0...1
    public var gpuCoreCount: Int
    public var dieTempC: Double?     // SoC die temperature, nil if unavailable
    public var thermal: ThermalState
    public var memoryUsed: UInt64    // bytes
    public var memoryTotal: UInt64   // bytes
    public var swapUsed: UInt64      // bytes
    public var diskUsed: UInt64      // bytes
    public var diskTotal: UInt64     // bytes
    public var netDown: Double       // bytes/second
    public var netUp: Double         // bytes/second
    public var uptime: TimeInterval  // seconds
    /// Memory pressure for THIS sample. The live provider sets it from the kernel's real
    /// signal (`MemoryPressure.best`); manually-built snapshots default to `.low`. Stored
    /// (not computed) so every surface — Status hero, Doctor, explainer — reads one value
    /// and they can never disagree.
    public var memoryPressure: MemoryPressure

    public init(cpuUsage: Double = 0, cpuCoreCount: Int = 0, loadAverage: Double = 0,
                gpuUsage: Double = 0, gpuCoreCount: Int = 0, dieTempC: Double? = nil,
                thermal: ThermalState = .nominal, memoryUsed: UInt64 = 0, memoryTotal: UInt64 = 0,
                swapUsed: UInt64 = 0, diskUsed: UInt64 = 0, diskTotal: UInt64 = 0,
                netDown: Double = 0, netUp: Double = 0, uptime: TimeInterval = 0,
                memoryPressure: MemoryPressure = .low) {
        self.cpuUsage = cpuUsage
        self.cpuCoreCount = cpuCoreCount
        self.loadAverage = loadAverage
        self.gpuUsage = gpuUsage
        self.gpuCoreCount = gpuCoreCount
        self.dieTempC = dieTempC
        self.thermal = thermal
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.swapUsed = swapUsed
        self.diskUsed = diskUsed
        self.diskTotal = diskTotal
        self.netDown = netDown
        self.netUp = netUp
        self.uptime = uptime
        self.memoryPressure = memoryPressure
    }

    public var memoryFraction: Double { memoryTotal == 0 ? 0 : Double(memoryUsed) / Double(memoryTotal) }
    public var diskFraction: Double { diskTotal == 0 ? 0 : Double(diskUsed) / Double(diskTotal) }
}

/// Static facts about the machine, shown in the Status header.
public struct HostInfo: Sendable, Equatable {
    public var model: String         // e.g. "Mac16,5"
    public var chip: String          // e.g. "Apple M4 Max"
    public var osVersion: String     // e.g. "Version 26.3.1 (Build …)"
    public var physicalMemory: UInt64

    public init(model: String, chip: String, osVersion: String, physicalMemory: UInt64) {
        self.model = model
        self.chip = chip
        self.osVersion = osVersion
        self.physicalMemory = physicalMemory
    }
}

public enum ByteFormat {
    /// Compact human-readable size, e.g. "38.2 GB".
    public static func string(_ bytes: UInt64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB, .useTB]
        f.countStyle = .file
        // Clamp so a garbage/huge UInt64 (e.g. UInt64.max) can't trap on the Int64 conversion.
        return f.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }
}

public enum UptimeFormat {
    /// e.g. "3d 4h" / "5h 12m" / "8m".
    public static func string(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

/// Compact relative-age formatting for "last run" style timestamps: a short value + unit
/// (e.g. `3` / `d`), or "Never" when nil. Pure (no `Date.now`) so it's deterministic + TDD'd.
public enum RelativeAgeFormat {
    /// Value + unit for how long ago `date` was, relative to `now`. Returns `nil` for a nil
    /// date so callers can render "Never". Future dates clamp to "now".
    public static func valueUnit(_ date: Date?, now: Date) -> (value: String, unit: String)? {
        guard let date else { return nil }
        let seconds = max(0, now.timeIntervalSince(date))
        let s = Int(seconds)
        if s < 60 { return ("now", "") }
        if s < 3_600 { return ("\(s / 60)", "m") }
        if s < 86_400 { return ("\(s / 3_600)", "h") }
        return ("\(s / 86_400)", "d")
    }
}
