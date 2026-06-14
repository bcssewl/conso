import Foundation
import IOKit
import IOKit.ps

/// Battery state for the Status card. All values are read non-root; `nil` from the
/// provider means the machine has no internal battery (e.g. a desktop Mac).
public struct BatteryInfo: Sendable, Equatable {
    public let percent: Int
    public let isCharging: Bool
    public let onACPower: Bool
    public let minutesRemaining: Int?   // nil while macOS is still calculating
    public let cycleCount: Int?
    public let healthPercent: Int?

    public init(percent: Int, isCharging: Bool, onACPower: Bool,
                minutesRemaining: Int?, cycleCount: Int?, healthPercent: Int?) {
        self.percent = percent
        self.isCharging = isCharging
        self.onACPower = onACPower
        self.minutesRemaining = minutesRemaining
        self.cycleCount = cycleCount
        self.healthPercent = healthPercent
    }

    /// e.g. "16:04 left" / "2:30 to full" / "Fully charged" / "Plugged in" / "Calculating…".
    public var timeLabel: String {
        guard let m = minutesRemaining, m > 0 else {
            // macOS gives no time estimate on AC power, so don't say "Calculating…".
            if onACPower { return percent >= 95 ? "Fully charged" : "Plugged in" }
            return "Calculating…"
        }
        let label = isCharging ? "to full" : "left"
        return String(format: "%d:%02d %@", m / 60, m % 60, label)
    }
}

public enum BatteryProvider {
    public static func current() -> BatteryInfo? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else { continue }

            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue

            let rawMinutes = (charging ? desc[kIOPSTimeToFullChargeKey] : desc[kIOPSTimeToEmptyKey]) as? Int
            let minutes = (rawMinutes ?? -1) > 0 ? rawMinutes : nil

            let detail = smartBatteryDetail()
            return BatteryInfo(percent: percent, isCharging: charging, onACPower: onAC,
                               minutesRemaining: minutes, cycleCount: detail.cycles, healthPercent: detail.health)
        }
        return nil
    }

    /// Best-effort cycle count and health from the AppleSmartBattery IORegistry node.
    private static func smartBatteryDetail() -> (cycles: Int?, health: Int?) {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard entry != 0 else { return (nil, nil) }
        defer { IOObjectRelease(entry) }

        func intProp(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
        }
        let cycles = intProp("CycleCount")
        let design = intProp("DesignCapacity")
        let maxCap = intProp("AppleRawMaxCapacity") ?? intProp("MaxCapacity")
        var health: Int?
        if let design, design > 0, let maxCap {
            health = min(100, Int((Double(maxCap) / Double(design) * 100).rounded()))
        }
        return (cycles, health)
    }
}
