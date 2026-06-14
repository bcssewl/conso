import Foundation
import IOKit

/// Apple Silicon GPU stats. Read non-root from the IOAccelerator registry node —
/// the same `PerformanceStatistics` the system uses (Activity Monitor's GPU history).
public struct GPUStats: Sendable, Equatable {
    public var utilization: Double   // 0...1
    public var coreCount: Int
    public init(utilization: Double = 0, coreCount: Int = 0) {
        self.utilization = utilization
        self.coreCount = coreCount
    }
}

public enum GPUProvider {
    public static func current() -> GPUStats {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return GPUStats() }
        defer { IOObjectRelease(iterator) }

        var utilization = 0.0
        var coreCount = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let perf = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let devUtil = perf["Device Utilization %"] as? Int {
                utilization = max(utilization, Double(devUtil) / 100.0)
            }
            if coreCount == 0,
               let cores = IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, "gpu-core-count" as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? Int {
                coreCount = cores
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return GPUStats(utilization: min(1, utilization), coreCount: coreCount)
    }
}
