import XCTest
@testable import ConsoCore

/// Covers the pure update/distribution logic that the app's Sparkle updater and the
/// helper-gating UI depend on. Kept in ConsoCore so it's testable without the app target.
final class UpdatesTests: XCTestCase {

    // MARK: DistributionChannel

    func testChannelDefaultsToDeveloperForMissingOrUnknown() {
        // Local Xcode/dev builds don't set the marker and MUST keep full functionality.
        XCTAssertEqual(DistributionChannel.parse(nil), .developer)
        XCTAssertEqual(DistributionChannel.parse(""), .developer)
        XCTAssertEqual(DistributionChannel.parse("developer"), .developer)
        XCTAssertEqual(DistributionChannel.parse("garbage"), .developer)
        // An unsubstituted build-setting variable must not read as self-signed.
        XCTAssertEqual(DistributionChannel.parse("$(CONSO_DIST_CHANNEL)"), .developer)
    }

    func testChannelRecognizesSelfSignedVariants() {
        XCTAssertEqual(DistributionChannel.parse("self-signed"), .selfSigned)
        XCTAssertEqual(DistributionChannel.parse("  self-signed  "), .selfSigned)
        XCTAssertEqual(DistributionChannel.parse("SELF-SIGNED"), .selfSigned)
        XCTAssertEqual(DistributionChannel.parse("selfsigned"), .selfSigned)
    }

    func testOnlyDeveloperBuildSupportsThePrivilegedHelper() {
        XCTAssertTrue(DistributionChannel.developer.supportsPrivilegedHelper)
        XCTAssertFalse(DistributionChannel.selfSigned.supportsPrivilegedHelper)
    }

    // MARK: UpdateFeed (stable <-> beta URL derivation, Trace-style dual feed)

    private let stable = "https://github.com/bcssewl/conso/releases/latest/download/appcast.xml"

    func testStableChannelReturnsTheConfiguredFeedUnchanged() {
        XCTAssertEqual(UpdateFeed.url(for: .stable, stableFeed: stable), stable)
    }

    func testBetaChannelRewritesLatestToTheRollingBetaFeed() {
        XCTAssertEqual(
            UpdateFeed.url(for: .beta, stableFeed: stable),
            "https://github.com/bcssewl/conso/releases/download/beta-feed/appcast.xml"
        )
    }

    func testBetaChannelReturnsNilWhenFeedIsNotTheExpectedGitHubShape() {
        // Caller stays on stable rather than inventing a bad URL.
        XCTAssertNil(UpdateFeed.url(for: .beta, stableFeed: "https://example.com/appcast.xml"))
    }

    func testChannelRoundTripsThroughRawValue() {
        for c in UpdateChannel.allCases {
            XCTAssertEqual(UpdateChannel(rawValue: c.rawValue), c)
        }
    }
}
