import Foundation
import Observation
import ConsoCore

@MainActor
@Observable
final class DoctorViewModel {
    enum Phase: Equatable { case idle, loading, loaded(DoctorReport) }
    var phase: Phase = .idle

    private let advisor: DoctorAdvising

    /// `advisor` is injectable for tests/previews; in the app it picks the live
    /// on-device advisor on macOS 26+ and the deterministic one otherwise.
    init(advisor: DoctorAdvising? = nil) {
        if let advisor {
            self.advisor = advisor
        } else if #available(macOS 26, *) {
            self.advisor = FoundationModelsDoctorAdvisor()
        } else {
            self.advisor = FallbackDoctorAdvisor()
        }
    }

    func run(snapshot: SystemSnapshot, topProcesses: [String]) async {
        phase = .loading
        let facts = DoctorFacts.from(snapshot: snapshot, topProcesses: topProcesses)
        let report = await advisor.generateReport(from: facts)
        phase = .loaded(report)
    }
}
