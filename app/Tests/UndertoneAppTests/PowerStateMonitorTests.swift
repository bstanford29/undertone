import XCTest
@testable import UndertoneApp

final class PowerStateMonitorTests: XCTestCase {
    func testIsSlowerIsFalseOnACWithoutLowPowerMode() {
        XCTAssertFalse(PowerStateMonitor.isSlower(onBattery: false, lowPowerMode: false))
    }

    func testIsSlowerIsTrueOnBattery() {
        XCTAssertTrue(PowerStateMonitor.isSlower(onBattery: true, lowPowerMode: false))
    }

    func testIsSlowerIsTrueInLowPowerMode() {
        XCTAssertTrue(PowerStateMonitor.isSlower(onBattery: false, lowPowerMode: true))
    }

    func testIsSlowerIsTrueOnBatteryInLowPowerMode() {
        XCTAssertTrue(PowerStateMonitor.isSlower(onBattery: true, lowPowerMode: true))
    }
}
