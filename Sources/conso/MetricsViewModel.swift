import Foundation
import Observation
import ConsoCore

@MainActor
@Observable
final class MetricsViewModel {
    private let provider: MetricsProvider = LiveMetricsProvider()
    private let processProvider = ProcessProvider()
    private var timer: Timer?
    private var tick = 0

    var snapshot = SystemSnapshot()
    var cpuHistory: [Double] = []
    var gpuHistory: [Double] = []
    var memHistory: [Double] = []
    var netDownHistory: [Double] = []
    var processes: [ProcRow] = []
    var battery: BatteryInfo?
    var lastSampledAt = Date()
    let host = HostInfo.current()

    func start() {
        guard timer == nil else { return }
        sample() // prime
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        let s = provider.snapshot()
        snapshot = s
        lastSampledAt = Date()
        append(&cpuHistory, s.cpuUsage)
        append(&gpuHistory, s.gpuUsage)
        append(&memHistory, s.memoryFraction)
        append(&netDownHistory, s.netDown)

        // Processes are heavier (a `ps` subprocess) — sample off-main every 2s.
        if tick % 2 == 0 { sampleProcesses() }
        // Battery changes slowly — every 5s (and on the first tick).
        if tick % 5 == 0 { battery = BatteryProvider.current() }
        tick &+= 1
    }

    private func sampleProcesses() {
        let provider = processProvider
        Task.detached(priority: .utility) {
            let rows = provider.top(7)
            await MainActor.run { self.processes = rows }
        }
    }

    private func append(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > 60 { history.removeFirst(history.count - 60) }
    }
}
