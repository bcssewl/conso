import Foundation
import CSensors

/// Reads Apple Silicon temperature sensors (°C) via the IOHIDEventSystem C shim.
/// Non-root. Sensor names vary by chip, so CPU/GPU are derived by name matching.
public enum TemperatureProvider {
    /// All temperature sensors: name → °C. Filters out implausible/zero readings.
    public static func sensors() -> [String: Double] {
        guard let raw = CSensorsCopyTemperatures() as? [String: Double] else { return [:] }
        return raw.filter { $0.value > 0 && $0.value < 130 }
    }

    /// The SoC die temperature — the headline chip temp. On Apple Silicon the CPU
    /// and GPU share one die, so the `tdie*` sensors are the meaningful reading.
    /// Falls back to named CPU sensors on chips that expose them.
    public static func die() -> Double? {
        let s = sensors()
        return average(s, matching: ["tdie"]) ?? average(s, matching: ["CPU", "pACC", "eACC"])
    }

    static func average(_ sensors: [String: Double], matching needles: [String]) -> Double? {
        let hits = sensors.filter { key, _ in
            needles.contains { key.localizedCaseInsensitiveContains($0) }
        }.map(\.value)
        guard !hits.isEmpty else { return nil }
        return hits.reduce(0, +) / Double(hits.count)
    }
}
