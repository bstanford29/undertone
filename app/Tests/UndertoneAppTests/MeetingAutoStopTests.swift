import XCTest
@testable import UndertoneApp

/// Auto-stop bookkeeping and the Ignore memory. Capture itself needs a live
/// engine, so these cover the state the dock reads.
@MainActor
final class MeetingAutoStopTests: XCTestCase {
    private func model() -> MeetingModel {
        MeetingModel(engine: EngineClient(path: "/dev/null/undertone-test.sock"), previewMode: true)
    }

    private func meeting(_ bundleID: String, title: String, pid: pid_t) -> DetectedMeeting {
        DetectedMeeting(appName: "Zoom", suggestedTitle: title, bundleID: bundleID,
                        source: .micOwner, pid: pid)
    }

    func testNoCallIsTrackedBeforeCaptureStarts() {
        XCTAssertNil(model().activeCallPID)
    }

    func testAutoStopDoesNothingWhileIdle() {
        let meetings = model()
        meetings.autoStop(reason: "Zoom released the microphone")
        XCTAssertNil(meetings.lastAutoStop)
    }

    func testResumeWithoutAnAutoStopDoesNothing() {
        let meetings = model()
        meetings.resumeLast()
        XCTAssertNil(meetings.lastAutoStop)
        XCTAssertNil(meetings.currentSession)
    }

    func testIgnoreHidesTheSameDetectionOnly() {
        let meetings = model()
        let zoom = meeting("us.zoom.xos", title: "Zoom call", pid: 310)
        XCTAssertFalse(meetings.isIgnored(zoom))
        meetings.ignore(zoom)
        XCTAssertTrue(meetings.isIgnored(zoom))
        XCTAssertTrue(meetings.isIgnored(meeting("us.zoom.xos", title: "Zoom call", pid: 310)))
    }

    func testANewCallIsNotIgnored() {
        let meetings = model()
        meetings.ignore(meeting("us.zoom.xos", title: "Zoom call", pid: 310))
        XCTAssertFalse(meetings.isIgnored(meeting("us.zoom.xos", title: "Zoom call", pid: 480)))
        XCTAssertFalse(meetings.isIgnored(meeting("us.zoom.xos", title: "Standup", pid: 310)))
        XCTAssertFalse(meetings.isIgnored(nil))
    }

    func testClearingTheIgnoreShowsTheCardAgain() {
        let meetings = model()
        let zoom = meeting("us.zoom.xos", title: "Zoom call", pid: 310)
        meetings.ignore(zoom)
        meetings.clearIgnored()
        XCTAssertFalse(meetings.isIgnored(zoom))
        XCTAssertNil(meetings.ignoredDetection)
    }
}
