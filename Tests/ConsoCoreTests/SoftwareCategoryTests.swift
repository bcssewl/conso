import XCTest
@testable import ConsoCore

/// Exhaustive, pure-mapping tests for `AppUpdate.category`. The categorization is
/// deterministic — derived only from `source` (+ Homebrew formula-vs-cask) — so every
/// source must map to exactly one known category.
final class SoftwareCategoryTests: XCTestCase {

    private func update(source: UpdateSource, isCask: Bool = false) -> AppUpdate {
        AppUpdate(id: "x", name: "X", glyph: "X", fromVersion: "1", toVersion: "2",
                  bytes: 0, source: source, isCask: isCask)
    }

    // MARK: Source → category (every source covered)

    func testHomebrewFormulaIsLibrary() {
        XCTAssertEqual(update(source: .homebrew, isCask: false).category, .library)
    }

    func testHomebrewCaskIsApp() {
        XCTAssertEqual(update(source: .homebrew, isCask: true).category, .app)
    }

    func testAppStoreIsApp() {
        XCTAssertEqual(update(source: .appStore).category, .app)
    }

    func testSparkleIsApp() {
        XCTAssertEqual(update(source: .sparkle).category, .app)
    }

    func testElectronIsApp() {
        XCTAssertEqual(update(source: .electron).category, .app)
    }

    func testSystemIsSystem() {
        XCTAssertEqual(update(source: .system).category, .system)
    }

    /// Guards against an un-handled source slipping through: every source must produce
    /// a category, and only homebrew is sensitive to the cask flag.
    func testEverySourceMapsToACategory() {
        for source in UpdateSource.allCases {
            let formula = update(source: source, isCask: false)
            let cask = update(source: source, isCask: true)
            switch source {
            case .homebrew:
                XCTAssertEqual(formula.category, .library)
                XCTAssertEqual(cask.category, .app)
            case .appStore, .sparkle, .electron:
                XCTAssertEqual(formula.category, .app)
                XCTAssertEqual(cask.category, .app)  // cask flag irrelevant off-homebrew
            case .system:
                XCTAssertEqual(formula.category, .system)
                XCTAssertEqual(cask.category, .system)
            }
        }
    }

    // MARK: isCask only matters for Homebrew

    func testCaskFlagIgnoredForNonHomebrewSources() {
        // A Sparkle/App Store/Electron/System update is never re-classified by isCask.
        for source in UpdateSource.allCases where source != .homebrew {
            XCTAssertEqual(update(source: source, isCask: false).category,
                           update(source: source, isCask: true).category,
                           "\(source) category must not depend on isCask")
        }
    }

    // MARK: End-to-end through the Homebrew parser (formula vs cask split)

    func testHomebrewParserFeedsCorrectCategories() {
        let json = """
        {
          "formulae": [
            { "name": "ffmpeg", "installed_versions": ["6.1"], "current_version": "7.0" },
            { "name": "cmake", "installed_versions": ["3.29"], "current_version": "3.30" }
          ],
          "casks": [
            { "name": "visual-studio-code", "installed_versions": ["1.89"], "current_version": "1.90" }
          ]
        }
        """
        let updates = HomebrewParser.parse(json)
        let ffmpeg = updates.first { $0.name == "ffmpeg" }
        let cmake = updates.first { $0.name == "cmake" }
        let code = updates.first { $0.name == "visual-studio-code" }
        XCTAssertEqual(ffmpeg?.category, .library)
        XCTAssertEqual(cmake?.category, .library)
        XCTAssertEqual(code?.category, .app)
    }

    // MARK: Category metadata

    func testPluralNames() {
        XCTAssertEqual(UpdateCategory.app.pluralName, "Apps")
        XCTAssertEqual(UpdateCategory.library.pluralName, "Libraries")
        XCTAssertEqual(UpdateCategory.system.pluralName, "System")
    }

    func testAllCategoriesAreCovered() {
        XCTAssertEqual(Set(UpdateCategory.allCases), [.app, .library, .system])
    }
}
