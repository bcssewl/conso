import XCTest
@testable import ConsoCore

// MARK: - Homebrew JSON parsing

final class HomebrewParserTests: XCTestCase {
    /// Real-shape `brew outdated --json=v2` output with both a formula and a cask.
    private let sample = """
    {
      "formulae": [
        { "name": "ffmpeg", "installed_versions": ["6.1"], "current_version": "7.0", "pinned": false },
        { "name": "node", "installed_versions": ["20.0", "20.1"], "current_version": "22.3", "pinned": false }
      ],
      "casks": [
        { "name": "visual-studio-code", "installed_versions": ["1.89"], "current_version": "1.90" }
      ]
    }
    """

    func testParsesFormulaeAndCasks() {
        let updates = HomebrewParser.parse(sample)
        XCTAssertEqual(updates.count, 3)
        XCTAssertTrue(updates.allSatisfy { $0.source == .homebrew })
    }

    func testFormulaFields() {
        let ffmpeg = HomebrewParser.parse(sample).first { $0.name == "ffmpeg" }
        XCTAssertNotNil(ffmpeg)
        XCTAssertEqual(ffmpeg?.fromVersion, "6.1")
        XCTAssertEqual(ffmpeg?.toVersion, "7.0")
        XCTAssertEqual(ffmpeg?.brewName, "ffmpeg")
        XCTAssertEqual(ffmpeg?.isCask, false)
    }

    func testUsesLatestInstalledVersion() {
        // node has multiple installed_versions; the most recent should be the "from".
        let node = HomebrewParser.parse(sample).first { $0.name == "node" }
        XCTAssertEqual(node?.fromVersion, "20.1")
        XCTAssertEqual(node?.toVersion, "22.3")
    }

    func testCaskIsFlagged() {
        let code = HomebrewParser.parse(sample).first { $0.name == "visual-studio-code" }
        XCTAssertEqual(code?.isCask, true)
        XCTAssertEqual(code?.toVersion, "1.90")
    }

    func testEmptyAndGarbageInputYieldNothing() {
        XCTAssertTrue(HomebrewParser.parse("").isEmpty)
        XCTAssertTrue(HomebrewParser.parse("not json").isEmpty)
        XCTAssertTrue(HomebrewParser.parse("{\"formulae\": [], \"casks\": []}").isEmpty)
    }

    func testSkipsEntriesWithSameVersion() {
        let json = """
        {"formulae": [{"name": "git", "installed_versions": ["2.45"], "current_version": "2.45"}], "casks": []}
        """
        XCTAssertTrue(HomebrewParser.parse(json).isEmpty)
    }

    func testRoutesToBrewUpgrade() {
        let cask = HomebrewParser.parse(sample).first { $0.isCask }!
        let formula = HomebrewParser.parse(sample).first { !$0.isCask }!
        XCTAssertEqual(SoftwareRouter.route(for: cask), .brewUpgrade(name: cask.brewName!, isCask: true))
        XCTAssertEqual(SoftwareRouter.route(for: formula), .brewUpgrade(name: formula.brewName!, isCask: false))
    }
}

// MARK: - Mac App Store (mas) line parsing

final class MASParserTests: XCTestCase {
    private let sample = """
    497799835 Xcode (16.0 -> 16.1)
    1295203466 Microsoft Remote Desktop (10.9.5 -> 10.9.6)
    409201541 Pages (13.2 -> 13.3)
    """

    func testParsesAllLines() {
        let updates = MASParser.parse(sample)
        XCTAssertEqual(updates.count, 3)
        XCTAssertTrue(updates.allSatisfy { $0.source == .appStore })
    }

    func testKeepsNumericIDForRouting() {
        let xcode = MASParser.parse(sample).first { $0.name == "Xcode" }
        XCTAssertEqual(xcode?.masID, "497799835")
        XCTAssertEqual(xcode?.fromVersion, "16.0")
        XCTAssertEqual(xcode?.toVersion, "16.1")
    }

    func testHandlesMultiWordNames() {
        let rdp = MASParser.parse(sample).first { $0.masID == "1295203466" }
        XCTAssertEqual(rdp?.name, "Microsoft Remote Desktop")
        XCTAssertEqual(rdp?.toVersion, "10.9.6")
    }

    func testRoutesToAppStoreDeepLink() {
        let xcode = MASParser.parse(sample).first { $0.name == "Xcode" }!
        XCTAssertEqual(SoftwareRouter.route(for: xcode),
                       .openURL("macappstore://apps.apple.com/app/id497799835"))
    }

    func testIgnoresNonNumericLeadingToken() {
        // A header or stray line without a numeric id must be skipped.
        let updates = MASParser.parse("Checking for updates...\nNo updates available")
        XCTAssertTrue(updates.isEmpty)
    }

    func testEmptyInput() {
        XCTAssertTrue(MASParser.parse("").isEmpty)
    }
}

// MARK: - softwareupdate -l parsing

final class SoftwareUpdateParserTests: XCTestCase {
    func testParsesAvailableUpdate() {
        let output = """
        Software Update Tool

        Finding available software
        Software Update found the following new or updated software:
        * Label: macOS Sequoia 15.6-24G84
        \tTitle: macOS Sequoia, Version: 15.6, Size: 3014102KiB, Recommended: YES, Action: restart,
        """
        let update = SoftwareUpdateParser.parse(output)
        XCTAssertNotNil(update)
        XCTAssertEqual(update?.source, .system)
        XCTAssertEqual(update?.toVersion, "15.6")
        XCTAssertEqual(update?.bytes, 3014102 * 1_024)
        XCTAssertTrue(update?.name.contains("macOS Sequoia") == true)
    }

    func testNoUpdatesReturnsNil() {
        let output = """
        Software Update Tool

        Finding available software
        No new software available.
        """
        XCTAssertNil(SoftwareUpdateParser.parse(output))
    }

    func testEmptyOutputReturnsNil() {
        XCTAssertNil(SoftwareUpdateParser.parse(""))
    }

    func testLabelWithoutDetailStillSurfaces() {
        let output = "* Label: macOS Some Update-ABC123"
        let update = SoftwareUpdateParser.parse(output)
        XCTAssertNotNil(update)
        XCTAssertEqual(update?.remoteVersionKnown, false)
    }

    func testRoutesToSoftwareUpdateSettings() {
        let output = """
        * Label: macOS Sequoia 15.6-24G84
        \tTitle: macOS Sequoia, Version: 15.6, Size: 3014102KiB, Recommended: YES, Action: restart,
        """
        let update = SoftwareUpdateParser.parse(output)!
        XCTAssertEqual(SoftwareRouter.route(for: update),
                       .openURL("x-apple.systempreferences:com.apple.Software-Update-Settings.extension"))
    }
}

// MARK: - Sparkle appcast parsing + version comparison

final class SparkleParserTests: XCTestCase {
    /// Sparkle attribute-style appcast (version info on <enclosure>).
    private let attrFeed = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item>
          <title>Version 1.71</title>
          <enclosure url="https://example.com/app-1.71.zip" sparkle:version="1710" sparkle:shortVersionString="1.71" length="29360128" type="application/octet-stream"/>
        </item>
        <item>
          <title>Version 1.70</title>
          <enclosure url="https://example.com/app-1.70.zip" sparkle:version="1700" sparkle:shortVersionString="1.70" length="29000000" type="application/octet-stream"/>
        </item>
      </channel>
    </rss>
    """

    /// Sparkle element-style appcast (version info as child elements).
    private let elemFeed = """
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item>
          <sparkle:version>125</sparkle:version>
          <sparkle:shortVersionString>125</sparkle:shortVersionString>
          <enclosure url="https://example.com/f-125.zip" length="100663296"/>
        </item>
      </channel>
    </rss>
    """

    func testPicksNewestByBuild() {
        let item = SparkleAppcastParser.newestItem(attrFeed)
        XCTAssertEqual(item?.build, "1710")
        XCTAssertEqual(item?.shortVersion, "1.71")
        XCTAssertEqual(item?.bytes, 29360128)
    }

    func testElementStyleFeed() {
        let item = SparkleAppcastParser.newestItem(elemFeed)
        XCTAssertEqual(item?.build, "125")
        XCTAssertEqual(item?.bytes, 100663296)
    }

    func testHTMLErrorPageReturnsNil() {
        XCTAssertNil(SparkleAppcastParser.newestItem("<html><body>404 Not Found</body></html>"))
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(SparkleAppcastParser.newestItem(""))
    }

    func testIsNewerNumericBuild() {
        XCTAssertTrue(SoftwareScanner.isNewer(remoteBuild: "1710", localBuild: "1700"))
        XCTAssertFalse(SoftwareScanner.isNewer(remoteBuild: "1700", localBuild: "1700"))
        XCTAssertFalse(SoftwareScanner.isNewer(remoteBuild: "1690", localBuild: "1700"))
    }

    func testIsNewerDottedFallback() {
        XCTAssertTrue(SoftwareScanner.isNewer(remoteBuild: "1.71", localBuild: "1.70"))
        XCTAssertTrue(SoftwareScanner.isNewer(remoteBuild: "2.0", localBuild: "1.99"))
        XCTAssertFalse(SoftwareScanner.isNewer(remoteBuild: "1.70", localBuild: "1.70"))
    }
}

// MARK: - Merge / routing

final class SoftwareModelMergeTests: XCTestCase {
    func testKnownRemoteSortsFirst() {
        let known = AppUpdate(id: "a", name: "Zeta", glyph: "Z", fromVersion: "1", toVersion: "2",
                              bytes: 0, source: .sparkle, bundlePath: "/A.app", remoteVersionKnown: true)
        let unknown = AppUpdate(id: "b", name: "Alpha", glyph: "A", fromVersion: "1", toVersion: "in-app",
                                bytes: 0, source: .electron, bundlePath: "/B.app", remoteVersionKnown: false)
        let merged = SoftwareModel.merge(brew: [], appStore: [], sparkle: [known], electron: [unknown])
        XCTAssertEqual(merged.first?.id, "a", "known-remote update sorts before unknown despite name")
    }

    func testDeDupesByBundlePathPreferringSparkle() {
        let sparkle = AppUpdate(id: "s", name: "App", glyph: "A", fromVersion: "1", toVersion: "2",
                                bytes: 10, source: .sparkle, bundlePath: "/Same.app")
        let electron = AppUpdate(id: "e", name: "App", glyph: "A", fromVersion: "1", toVersion: "in-app",
                                 bytes: 0, source: .electron, bundlePath: "/Same.app", remoteVersionKnown: false)
        let merged = SoftwareModel.merge(brew: [], appStore: [], sparkle: [sparkle], electron: [electron])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.source, .sparkle)
    }

    func testSparkleRoutesToOpenApp() {
        let u = AppUpdate(id: "s", name: "App", glyph: "A", fromVersion: "1", toVersion: "2",
                          bytes: 0, source: .sparkle, bundlePath: "/Applications/App.app")
        XCTAssertEqual(SoftwareRouter.route(for: u), .openApp(bundlePath: "/Applications/App.app"))
    }

    func testAppStoreFallbackRouteWithoutID() {
        let u = AppUpdate(id: "r", name: "App", glyph: "A", fromVersion: "1", toVersion: "App Store",
                          bytes: 0, source: .appStore, remoteVersionKnown: false)
        XCTAssertEqual(SoftwareRouter.route(for: u), .openAppStoreUpdates)
    }
}
