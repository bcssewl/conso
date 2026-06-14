import XCTest
@testable import ConsoCore

final class CommandMatcherTests: XCTestCase {

    // MARK: - Catalog integrity

    func testCatalogIsNonEmptyWithUniqueIDs() {
        let all = CommandCatalog.all
        XCTAssertFalse(all.isEmpty)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "command ids must be unique")
    }

    func testEveryCommandHasTitleSubtitleAndKeywords() {
        for c in CommandCatalog.all {
            XCTAssertFalse(c.title.isEmpty, "\(c.id) needs a title")
            XCTAssertFalse(c.subtitle.isEmpty, "\(c.id) needs a subtitle")
            XCTAssertFalse(c.keywords.isEmpty, "\(c.id) needs keywords")
        }
    }

    func testCommandLookupByID() {
        XCTAssertEqual(CommandCatalog.command(id: "run.doctor")?.target, .runDoctor)
        XCTAssertNil(CommandCatalog.command(id: "not.a.command"))
        XCTAssertEqual(Set(CommandCatalog.ids), Set(CommandCatalog.all.map(\.id)))
    }

    /// SAFETY: every command's target must be one of the safe, closed effects. A
    /// destructive command can only ever open a preview (.quickClean), never delete.
    func testEveryTargetIsSafe() {
        for c in CommandCatalog.all {
            switch c.target {
            case .navigate, .runDoctor, .quickClean, .checkUpdates, .openAnalyze, .toggleKeepAwake:
                continue  // all members of the closed, safe set
            }
        }
    }

    // MARK: - Representative queries → expected command

    private func assertTop(_ query: String, isID id: String, line: UInt = #line) {
        let result = CommandMatcher.match(query)
        XCTAssertEqual(result.first?.id, id, "‘\(query)’ should match \(id)", line: line)
    }

    func testFreeUpSpaceQueriesMapToQuickClean() {
        assertTop("free up space", isID: "clean.quick")
        assertTop("I'm running out of space", isID: "clean.quick")
        assertTop("make some room on my disk", isID: "clean.quick")
        assertTop("quick clean", isID: "clean.quick")
    }

    func testDoctorQueries() {
        assertTop("run doctor", isID: "run.doctor")
        assertTop("how is my mac", isID: "run.doctor")
        assertTop("health check", isID: "run.doctor")
    }

    func testUpdateQueries() {
        assertTop("check for updates", isID: "software.update")
        assertTop("are my apps outdated", isID: "software.update")
    }

    func testDuplicateAndDiskQueries() {
        assertTop("find duplicates", isID: "analyze.find")
        assertTop("what's using my disk", isID: "analyze.find")
        assertTop("show me the biggest files", isID: "analyze.find")
    }

    func testKeepAwakeQueries() {
        assertTop("keep my mac awake", isID: "keepawake.toggle")
        assertTop("prevent sleep", isID: "keepawake.toggle")
        assertTop("caffeinate", isID: "keepawake.toggle")
    }

    func testNavigationQueries() {
        assertTop("open clean", isID: "open.clean")
        assertTop("open software", isID: "open.software")
        assertTop("optimize my mac", isID: "open.optimize")
        assertTop("status", isID: "open.status")
    }

    // MARK: - Robustness

    func testCaseInsensitive() {
        XCTAssertEqual(CommandMatcher.match("RUN DOCTOR").first?.id, "run.doctor")
        XCTAssertEqual(CommandMatcher.match("Free Up Space").first?.id, "clean.quick")
    }

    func testGibberishReturnsNoMatches() {
        XCTAssertTrue(CommandMatcher.match("zxqwlkjhgf").isEmpty)
        XCTAssertTrue(CommandMatcher.match("    ").isEmpty)
        XCTAssertTrue(CommandMatcher.match("").isEmpty)
    }

    func testEveryResultIsFromTheClosedCatalog() {
        let ids = Set(CommandCatalog.ids)
        for q in ["free up space", "doctor", "kjsdfh", "open analyze", "keep awake", "updates"] {
            for c in CommandMatcher.match(q) {
                XCTAssertTrue(ids.contains(c.id), "matcher returned out-of-catalog id \(c.id)")
            }
        }
    }

    // MARK: - Resolver

    func testKeywordResolverReturnsBestMatch() async {
        let resolver = KeywordCommandResolver()
        let cmd = await resolver.resolve("free up some space")
        XCTAssertEqual(cmd?.id, "clean.quick")
    }

    func testKeywordResolverReturnsNilForGibberish() async {
        let resolver = KeywordCommandResolver()
        let cmd = await resolver.resolve("qwzxlkj")
        XCTAssertNil(cmd)
    }
}
