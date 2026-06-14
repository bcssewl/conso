import Foundation
import Darwin

/// macOS thermal pressure — a real, non-root reading (`ProcessInfo.thermalState`).
public enum ThermalState: Int, Sendable, Equatable {
    case nominal, fair, serious, critical
    public var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        }
    }
    public var isWarm: Bool { self != .nominal }
}

/// Coarse memory-pressure bucket, derived from how full RAM is and whether swap is in use.
public enum MemoryPressure: Sendable, Equatable {
    case low, medium, high
    public var label: String {
        switch self {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }

    public static func classify(fraction: Double, swapUsed: UInt64) -> MemoryPressure {
        if fraction >= 0.90 && swapUsed > 1_000_000_000 { return .high }
        if fraction >= 0.80 || swapUsed > 0 { return .medium }
        return .low
    }

    /// The kernel's real, non-root memory-pressure level via
    /// `kern.memorystatus_vm_pressure_level` — the same signal that backs
    /// `DispatchSource.makeMemoryPressureSource`. Values: 1 = normal, 2 = warn,
    /// 4 = critical. Returns nil if unavailable/unexpected so callers fall back.
    public static func system() -> MemoryPressure? {
        var raw: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &raw, &size, nil, 0) == 0 else { return nil }
        return level(fromKernelLevel: raw)
    }

    /// Pure mapping from the kernel pressure level to a bucket. Testable.
    /// 1 = DISPATCH_MEMORYPRESSURE_NORMAL, 2 = WARN, 4 = CRITICAL.
    static func level(fromKernelLevel level: Int32) -> MemoryPressure? {
        switch level {
        case 1: return .low
        case 2: return .medium
        case 4: return .high
        default: return nil   // unknown/unset — let the caller use the heuristic.
        }
    }

    /// Best-effort pressure: prefer the real kernel signal, fall back to the
    /// fraction/swap heuristic when the sysctl is unavailable.
    public static func best(fraction: Double, swapUsed: UInt64) -> MemoryPressure {
        system() ?? classify(fraction: fraction, swapUsed: swapUsed)
    }
}

/// Formats a byte-rate as a compact "8.4 MB/s" style string.
public enum RateFormat {
    public static func perSecond(_ bytesPerSecond: Double) -> String {
        let v = max(0, bytesPerSecond)
        if v < 1_000 { return "\(Int(v.rounded())) B/s" }
        if v < 1_000_000 { return String(format: "%.1f KB/s", v / 1_000) }
        if v < 1_000_000_000 { return String(format: "%.1f MB/s", v / 1_000_000) }
        return String(format: "%.1f GB/s", v / 1_000_000_000)
    }

    /// Same rate as bits/second (Mbps/Kbps) — the convention for network throughput.
    public static func perSecondBits(_ bytesPerSecond: Double) -> String {
        let bits = max(0, bytesPerSecond) * 8
        if bits < 1_000 { return "\(Int(bits.rounded())) bps" }
        if bits < 1_000_000 { return String(format: "%.1f Kbps", bits / 1_000) }
        if bits < 1_000_000_000 { return String(format: "%.1f Mbps", bits / 1_000_000) }
        return String(format: "%.1f Gbps", bits / 1_000_000_000)
    }
}

/// Pure helper for turning interface byte counters into a per-second rate.
public enum NetCounters {
    /// Bytes/second between two cumulative counter samples. Guards against the
    /// counter resetting (interface down/up) and non-positive elapsed time.
    public static func rate(previous: UInt64, current: UInt64, elapsed: TimeInterval) -> Double {
        guard elapsed > 0, current >= previous else { return 0 }
        return Double(current - previous) / elapsed
    }
}
