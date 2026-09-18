import XCTest
@testable import UndertoneApp

final class RuntimeIdentityTests: XCTestCase {
    func testProductionMustUseInstalledLocation() {
        XCTAssertTrue(RuntimeIdentity.isInstalled(bundlePath: "/Users/example/Applications/Undertone.app", home: "/Users/example"))
        XCTAssertTrue(RuntimeIdentity.isInstalled(bundlePath: "/Applications/Undertone.app", home: "/Users/example"))
        XCTAssertFalse(RuntimeIdentity.isInstalled(bundlePath: "/Users/example/project/app/.build/Undertone.app", home: "/Users/example"))
        XCTAssertFalse(RuntimeIdentity.isInstalled(bundlePath: "/Users/example/Applications/Undertone-old.app", home: "/Users/example"))
    }
}
