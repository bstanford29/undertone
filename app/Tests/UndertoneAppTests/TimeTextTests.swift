import XCTest
@testable import UndertoneApp

final class TimeTextTests: XCTestCase {
    func testDurationsNeverShowMilliseconds() {
        XCTAssertEqual(TimeText.duration(milliseconds: 0), "0 s")
        XCTAssertEqual(TimeText.duration(milliseconds: 742.4), "<1 s")
        XCTAssertEqual(TimeText.duration(milliseconds: 999), "<1 s")
        XCTAssertEqual(TimeText.duration(milliseconds: 1000), "1 s")
        XCTAssertEqual(TimeText.duration(milliseconds: 1499), "1 s")
        XCTAssertEqual(TimeText.duration(milliseconds: 1500), "2 s")
        XCTAssertEqual(TimeText.duration(milliseconds: 59_400), "59 s")
        XCTAssertEqual(TimeText.duration(milliseconds: 60_000), "1 min")
        XCTAssertEqual(TimeText.duration(milliseconds: 65_200), "1 min 5 s")
    }

    func testBadValuesReadAsZero() {
        XCTAssertEqual(TimeText.duration(milliseconds: -5), "0 s")
        XCTAssertEqual(TimeText.duration(milliseconds: .nan), "0 s")
        XCTAssertEqual(TimeText.duration(milliseconds: .infinity), "0 s")
    }

    func testSpokenDurations() {
        XCTAssertEqual(TimeText.spokenDuration(milliseconds: 742), "under a second")
        XCTAssertEqual(TimeText.spokenDuration(milliseconds: 1200), "1 second")
        XCTAssertEqual(TimeText.spokenDuration(milliseconds: 12_400), "12 seconds")
    }

    func testNoLabelEverEndsInMilliseconds() {
        for value in stride(from: 0.0, through: 200_000.0, by: 137.0) {
            let label = TimeText.duration(milliseconds: value)
            XCTAssertFalse(label.contains("ms"), label)
            XCTAssertFalse(TimeText.spokenDuration(milliseconds: value).contains("milli"))
        }
    }
}
