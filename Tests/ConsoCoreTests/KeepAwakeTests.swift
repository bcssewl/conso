import XCTest
@testable import ConsoCore

final class KeepAwakeTests: XCTestCase {
    @MainActor
    func testStartsInactive() {
        XCTAssertFalse(KeepAwake().isActive)
    }

    @MainActor
    func testSetActiveTogglesState() {
        let k = KeepAwake()
        k.setActive(true)
        XCTAssertTrue(k.isActive)
        k.setActive(false)
        XCTAssertFalse(k.isActive)
    }

    @MainActor
    func testRepeatedSetActiveIsIdempotent() {
        let k = KeepAwake()
        k.setActive(true)
        k.setActive(true)
        XCTAssertTrue(k.isActive)
        k.setActive(false)
        k.setActive(false)
        XCTAssertFalse(k.isActive)
    }

    @MainActor
    func testToggleFlipsState() {
        let k = KeepAwake()
        k.toggle()
        XCTAssertTrue(k.isActive)
        k.toggle()
        XCTAssertFalse(k.isActive)
    }
}
