import Foundation

/// One row in the Status process table.
public struct ProcRow: Identifiable, Sendable, Equatable {
    public let pid: Int
    public let name: String
    public let cpu: Double      // percent (can exceed 100 on multi-core)
    public let memBytes: UInt64
    public var id: Int { pid }

    public init(pid: Int, name: String, cpu: Double, memBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.cpu = cpu
        self.memBytes = memBytes
    }
}

public enum ProcessTable {
    /// Parses `ps -Aceo pid=,pcpu=,rss=,comm=` output (rss in KB) into rows,
    /// sorted by CPU descending, capped at `limit`. Malformed lines are skipped.
    public static func parse(_ psOutput: String, limit: Int) -> [ProcRow] {
        var rows: [ProcRow] = []
        for raw in psOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = raw.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4,
                  let pid = Int(fields[0]),
                  let cpu = Double(fields[1]),
                  let rssKB = UInt64(fields[2]) else { continue }
            let name = fields[3...].joined(separator: " ")
            rows.append(ProcRow(pid: pid, name: name, cpu: cpu, memBytes: rssKB * 1_024))
        }
        return Array(rows.sorted { $0.cpu > $1.cpu }.prefix(max(0, limit)))
    }
}

/// Reads the current top processes by shelling out to `ps` (non-root, reliable).
/// Stateless, so safe to call from a background task.
public final class ProcessProvider: Sendable {
    public init() {}

    public func top(_ limit: Int) -> [ProcRow] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Aceo", "pid=,pcpu=,rss=,comm=", "-r"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return ProcessTable.parse(String(decoding: data, as: UTF8.self), limit: limit)
        } catch {
            return []
        }
    }
}
