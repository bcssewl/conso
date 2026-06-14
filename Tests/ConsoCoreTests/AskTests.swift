import XCTest
@testable import ConsoCore

final class AskTests: XCTestCase {

    private func facts() -> DoctorFacts {
        DoctorFacts(score: 82, grade: "B", checksPassed: 5, checksTotal: 6,
                    cpuPercent: 20, memoryPercent: 55, diskPercent: 70, swapBytes: 0,
                    thermal: .nominal, pressure: .low, dieTempC: nil,
                    uptime: 3600, topProcesses: ["Safari", "Xcode"])
    }

    // MARK: - ConsoAnswer validation

    func testInitDropsNonCatalogIDs() {
        let a = ConsoAnswer(answer: "x", suggestedCommandIDs: ["run.doctor", "not.real", "clean.quick"],
                            inScope: true, isAIGenerated: true)
        XCTAssertEqual(a.suggestedCommandIDs, ["run.doctor", "clean.quick"])
    }

    func testInitDropsDuplicateIDs() {
        let a = ConsoAnswer(answer: "x", suggestedCommandIDs: ["run.doctor", "run.doctor", "clean.quick"],
                            inScope: true, isAIGenerated: true)
        XCTAssertEqual(a.suggestedCommandIDs, ["run.doctor", "clean.quick"])
    }

    func testSuggestedIDsAreAlwaysInCatalog() {
        let ids = Set(CommandCatalog.ids)
        let a = ConsoAnswer(answer: "x", suggestedCommandIDs: ["garbage", "open.clean", "", "analyze.find"],
                            inScope: true, isAIGenerated: true)
        for id in a.suggestedCommandIDs { XCTAssertTrue(ids.contains(id)) }
    }

    func testSuggestedCommandsResolveInOrder() {
        let a = ConsoAnswer(answer: "x", suggestedCommandIDs: ["clean.quick", "run.doctor"],
                            inScope: true, isAIGenerated: true)
        XCTAssertEqual(a.suggestedCommands.map(\.id), ["clean.quick", "run.doctor"])
    }

    // MARK: - FallbackAsker (offline launcher behavior)

    func testFallbackMatchedQuestionReturnsTopCommands() async {
        let asker = FallbackAsker()
        let a = await asker.answer("free up some space", facts: facts())
        XCTAssertTrue(a.inScope)
        XCTAssertFalse(a.isAIGenerated)
        XCTAssertEqual(a.suggestedCommandIDs.first, "clean.quick")
        XCTAssertLessThanOrEqual(a.suggestedCommandIDs.count, 2)
    }

    func testFallbackDoctorQuestion() async {
        let asker = FallbackAsker()
        let a = await asker.answer("how is my mac doing", facts: facts())
        XCTAssertTrue(a.inScope)
        XCTAssertEqual(a.suggestedCommandIDs.first, "run.doctor")
    }

    func testFallbackGibberishIsOutOfScope() async {
        let asker = FallbackAsker()
        let a = await asker.answer("zxqwlkjhgf", facts: facts())
        XCTAssertFalse(a.inScope)
        XCTAssertFalse(a.isAIGenerated)
        XCTAssertTrue(a.suggestedCommandIDs.isEmpty)
        XCTAssertEqual(a.answer, FallbackAsker.outOfScopeMessage)
    }

    func testFallbackEmptyQuestionIsOutOfScope() async {
        let asker = FallbackAsker()
        let a = await asker.answer("   ", facts: facts())
        XCTAssertFalse(a.inScope)
        XCTAssertTrue(a.suggestedCommandIDs.isEmpty)
    }

    func testFallbackSuggestionsAreAllInCatalog() async {
        let asker = FallbackAsker()
        let ids = Set(CommandCatalog.ids)
        for q in ["free up space", "doctor", "updates", "keep awake", "what's using my disk"] {
            let a = await asker.answer(q, facts: facts())
            for id in a.suggestedCommandIDs { XCTAssertTrue(ids.contains(id), "\(q) → \(id) not in catalog") }
        }
    }
}
