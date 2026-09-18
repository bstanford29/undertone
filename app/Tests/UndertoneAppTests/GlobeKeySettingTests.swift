import XCTest
@testable import UndertoneApp

/// Exercises only the pure decision and bookkeeping logic in
/// `GlobeKeySetting`. Nothing here touches real `CFPreferences`; the
/// in-memory `FakeStore` stands in for `UserDefaults`.
final class GlobeKeySettingTests: XCTestCase {
    // MARK: needsChange

    func testNeedsChangeIsFalseWhenHoldKeyIsNotFn() {
        XCTAssertFalse(GlobeKeySetting.needsChange(holdKeyIsFn: false, currentValue: nil))
        XCTAssertFalse(GlobeKeySetting.needsChange(holdKeyIsFn: false, currentValue: 2))
    }

    func testNeedsChangeIsTrueWhenFnHoldKeyAndValueIsUnset() {
        XCTAssertTrue(GlobeKeySetting.needsChange(holdKeyIsFn: true, currentValue: nil))
    }

    func testNeedsChangeIsTrueWhenFnHoldKeyAndValueIsNotZero() {
        XCTAssertTrue(GlobeKeySetting.needsChange(holdKeyIsFn: true, currentValue: 1))
        XCTAssertTrue(GlobeKeySetting.needsChange(holdKeyIsFn: true, currentValue: 2))
        XCTAssertTrue(GlobeKeySetting.needsChange(holdKeyIsFn: true, currentValue: 3))
    }

    func testNeedsChangeIsFalseWhenFnHoldKeyAndValueIsAlreadyZero() {
        XCTAssertFalse(GlobeKeySetting.needsChange(holdKeyIsFn: true, currentValue: 0))
    }

    // MARK: previous-value bookkeeping

    func testValueToStoreUsesSentinelForUnsetValue() {
        XCTAssertEqual(GlobeKeySetting.valueToStore(currentValue: nil), -1)
    }

    func testValueToStorePassesThroughARealValue() {
        XCTAssertEqual(GlobeKeySetting.valueToStore(currentValue: 2), 2)
        XCTAssertEqual(GlobeKeySetting.valueToStore(currentValue: 0), 0)
    }

    func testValueToRestoreTurnsSentinelBackIntoNil() {
        XCTAssertNil(GlobeKeySetting.valueToRestore(storedPreviousValue: -1))
    }

    func testValueToRestorePassesThroughARealStoredValue() {
        XCTAssertEqual(GlobeKeySetting.valueToRestore(storedPreviousValue: 2), 2)
        XCTAssertEqual(GlobeKeySetting.valueToRestore(storedPreviousValue: 0), 0)
    }

    func testStoreAndRestoreRoundTripForAnUnsetValue() {
        let stored = GlobeKeySetting.valueToStore(currentValue: nil)
        XCTAssertNil(GlobeKeySetting.valueToRestore(storedPreviousValue: stored))
    }

    func testStoreAndRestoreRoundTripForARealValue() {
        let stored = GlobeKeySetting.valueToStore(currentValue: 2)
        XCTAssertEqual(GlobeKeySetting.valueToRestore(storedPreviousValue: stored), 2)
    }

    // MARK: injected-store bookkeeping via the PreferenceStore protocol

    func testFakeStoreRecordsAndClearsTheStoredValue() {
        let store = FakeStore()
        XCTAssertNil(store.integer(forKey: GlobeKeySetting.previousValueDefaultsKey))

        store.set(GlobeKeySetting.valueToStore(currentValue: nil), forKey: GlobeKeySetting.previousValueDefaultsKey)
        XCTAssertEqual(store.integer(forKey: GlobeKeySetting.previousValueDefaultsKey), -1)

        store.removeObject(forKey: GlobeKeySetting.previousValueDefaultsKey)
        XCTAssertNil(store.integer(forKey: GlobeKeySetting.previousValueDefaultsKey))
    }
}

/// In-memory stand-in for `UserDefaults` so bookkeeping can be tested
/// without touching real preferences.
private final class FakeStore: GlobeKeySetting.PreferenceStore {
    private var values: [String: Int] = [:]

    func integer(forKey key: String) -> Int? {
        values[key]
    }

    func set(_ value: Int, forKey key: String) {
        values[key] = value
    }

    func removeObject(forKey key: String) {
        values.removeValue(forKey: key)
    }
}
