import XCTest
@testable import ConsoCore

final class TemperatureTests: XCTestCase {
    func testAverageMatchesSensorsByNameCaseInsensitively() {
        let sensors = ["GPU A": 40.0, "gpu B": 50.0, "CPU core": 70.0, "NAND": 30.0]
        XCTAssertEqual(TemperatureProvider.average(sensors, matching: ["gpu"]) ?? 0, 45, accuracy: 0.001)
        XCTAssertEqual(TemperatureProvider.average(sensors, matching: ["cpu"]) ?? 0, 70, accuracy: 0.001)
    }

    func testAverageReturnsNilWhenNoMatch() {
        XCTAssertNil(TemperatureProvider.average(["NAND": 30], matching: ["gpu"]))
    }

    func testSensorsAreReadAndDieIsPlausible() {
        let sensors = TemperatureProvider.sensors()
        XCTAssertFalse(sensors.isEmpty, "no temperature sensors found")
        XCTAssert(sensors.values.allSatisfy { $0 > 0 && $0 < 130 })
        if let die = TemperatureProvider.die() {
            XCTAssert((20...110).contains(die), "die temp implausible: \(die)")
        }
    }
}

final class GPUTests: XCTestCase {
    func testCurrentIsPlausible() {
        let g = GPUProvider.current()
        XCTAssert((0...1).contains(g.utilization), "gpu utilization out of range: \(g.utilization)")
        XCTAssert(g.coreCount >= 0)
    }
}
