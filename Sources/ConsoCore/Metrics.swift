import Foundation
import Darwin

/// Supplies live system metrics. Protocol-fronted so the UI can be tested with a fake.
public protocol MetricsProvider: AnyObject {
    func snapshot() -> SystemSnapshot
}

/// Reads CPU/memory/disk/uptime from the OS using stable, non-root APIs
/// (host_statistics, sysctl, FileManager). No special permissions required —
/// this is why Status is the first thing conso can ship (Phase 1).
public final class LiveMetricsProvider: MetricsProvider {
    private var previousCPUTicks: host_cpu_load_info?
    private var previousNet: (rx: UInt64, tx: UInt64)?
    private var previousNetTime: TimeInterval?
    private let coreCount = sysctlInt("hw.physicalcpu")

    public init() {}

    public func snapshot() -> SystemSnapshot {
        let mem = sampleMemory()
        let disk = sampleDisk()
        let net = sampleNetworkRate()
        let gpu = GPUProvider.current()
        let swap = sampleSwap()
        let memFraction = mem.total == 0 ? 0 : Double(mem.used) / Double(mem.total)
        return SystemSnapshot(
            cpuUsage: sampleCPU(),
            cpuCoreCount: coreCount,
            loadAverage: sampleLoadAverage(),
            gpuUsage: gpu.utilization,
            gpuCoreCount: gpu.coreCount,
            dieTempC: TemperatureProvider.die(),
            thermal: sampleThermal(),
            memoryUsed: mem.used,
            memoryTotal: mem.total,
            swapUsed: swap,
            diskUsed: disk.used,
            diskTotal: disk.total,
            netDown: net.down,
            netUp: net.up,
            uptime: ProcessInfo.processInfo.systemUptime,
            // Heuristic (not the flaky kernel sysctl): steady + deterministic, so a healthy
            // idle Mac reads "low" instead of a jumpy "medium". One source for all surfaces.
            memoryPressure: MemoryPressure.classify(fraction: memFraction, swapUsed: swap)
        )
    }

    // MARK: - CPU extras

    private func sampleLoadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) > 0 ? loads[0] : 0
    }

    private func sampleThermal() -> ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    // MARK: - Swap

    private func sampleSwap() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    // MARK: - Network

    /// Cumulative non-loopback interface byte counters.
    private func sampleNetworkBytes() -> (rx: UInt64, tx: UInt64) {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return (0, 0) }
        defer { freeifaddrs(addrs) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
               !String(cString: ifa.ifa_name).hasPrefix("lo"),
               let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) {
                rx &+= UInt64(data.pointee.ifi_ibytes)
                tx &+= UInt64(data.pointee.ifi_obytes)
            }
            ptr = ifa.ifa_next
        }
        return (rx, tx)
    }

    /// Download/upload rate (bytes/sec) since the previous sample. 0 on the first sample.
    private func sampleNetworkRate() -> (down: Double, up: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        let current = sampleNetworkBytes()
        defer { previousNet = current; previousNetTime = now }
        guard let prev = previousNet, let prevTime = previousNetTime else { return (0, 0) }
        let elapsed = now - prevTime
        return (NetCounters.rate(previous: prev.rx, current: current.rx, elapsed: elapsed),
                NetCounters.rate(previous: prev.tx, current: current.tx, elapsed: elapsed))
    }

    // MARK: - CPU

    private func currentCPULoad() -> host_cpu_load_info? {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { reboundPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPtr, &size)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    /// Usage since the previous sample. Returns 0 on the very first sample (no baseline yet).
    private func sampleCPU() -> Double {
        guard let current = currentCPULoad() else { return 0 }
        defer { previousCPUTicks = current }
        guard let previous = previousCPUTicks else { return 0 }

        let user = Double(current.cpu_ticks.0 &- previous.cpu_ticks.0)
        let system = Double(current.cpu_ticks.1 &- previous.cpu_ticks.1)
        let idle = Double(current.cpu_ticks.2 &- previous.cpu_ticks.2)
        let nice = Double(current.cpu_ticks.3 &- previous.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return 0 }
        return max(0, min(1, (user + system + nice) / total))
    }

    // MARK: - Memory

    private func sampleMemory() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total) }
        let pageSize = UInt64(sysconf(Int32(_SC_PAGESIZE)))
        let occupied = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        let used = occupied * pageSize
        return (min(used, total), total)
    }

    // MARK: - Disk

    private func sampleDisk() -> (used: UInt64, total: UInt64) {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/") else { return (0, 0) }
        let total = (attrs[.systemSize] as? NSNumber)?.uint64Value ?? 0
        let free = (attrs[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        let used = total >= free ? total - free : 0
        return (used, total)
    }
}

/// Reads the filesystem type ("APFS", "HFS", "exfat"…) for a mounted path via
/// `statfs` (`f_fstypename`). Non-root, stable. Returns nil if the path can't be
/// stat'd. `Filesystem.displayName` normalises the raw token for the UI.
public enum Filesystem {
    /// Raw `f_fstypename` token for a path, e.g. "apfs". nil on failure.
    public static func typeName(forPath path: String = "/") -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let raw = withUnsafeBytes(of: &fs.f_fstypename) { buf -> String in
            let bytes = buf.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
        return raw.isEmpty ? nil : raw
    }

    /// UI-friendly filesystem label. Upper-cases known acronyms (APFS/HFS),
    /// leaves anything else as the raw token. Falls back to "Disk" if unavailable.
    public static func displayName(forPath path: String = "/") -> String {
        guard let raw = typeName(forPath: path) else { return "Disk" }
        return label(forRawType: raw)
    }

    /// Pure mapping from a raw `f_fstypename` token to a display label. Testable.
    public static func label(forRawType raw: String) -> String {
        switch raw.lowercased() {
        case "apfs": return "APFS"
        case "hfs":  return "HFS+"
        case "exfat": return "exFAT"
        case "msdos", "fat32": return "FAT32"
        case "ntfs": return "NTFS"
        case "smbfs": return "SMB"
        case "nfs":  return "NFS"
        case "webdav": return "WebDAV"
        case "": return "Disk"
        default: return raw.uppercased()
        }
    }
}

extension HostInfo {
    /// Reads host facts via sysctl. Safe, no permissions.
    public static func current() -> HostInfo {
        HostInfo(
            model: sysctlString("hw.model"),
            chip: sysctlString("machdep.cpu.brand_string"),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            physicalMemory: ProcessInfo.processInfo.physicalMemory
        )
    }
}

/// Reads an integer sysctl value by name, e.g. "hw.physicalcpu". Returns 0 on failure.
func sysctlInt(_ name: String) -> Int {
    var value: Int = 0
    var size = MemoryLayout<Int>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return 0 }
    return value
}

/// Reads a string sysctl value by name, e.g. "hw.model".
func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
    return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
}
