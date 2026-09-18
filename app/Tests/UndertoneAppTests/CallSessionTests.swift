import XCTest
@testable import UndertoneApp

final class CallSessionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func session() -> CallSession {
        let meeting = DetectedMeeting(appName: "Zoom", suggestedTitle: "Zoom call",
                                      bundleID: "us.zoom.xos", source: .micOwner, pid: 310)
        return CallSession(meeting: meeting, pid: 310, at: start)
    }

    func testHoldingTheMicNeverEnds() {
        var call = session()
        for second in stride(from: 1.0, through: 60, by: 1) {
            XCTAssertFalse(call.update(holdsMic: true, now: start.addingTimeInterval(second)))
        }
        XCTAssertFalse(call.hasEnded)
    }

    func testReleaseShorterThanTheGraceDoesNotEnd() {
        var call = session()
        XCTAssertFalse(call.update(holdsMic: false, now: start.addingTimeInterval(1)))
        XCTAssertFalse(call.update(holdsMic: false, now: start.addingTimeInterval(8)))
        XCTAssertFalse(call.hasEnded)
    }

    func testReleaseLongerThanTheGraceEndsOnce() {
        var call = session()
        XCTAssertFalse(call.update(holdsMic: false, now: start.addingTimeInterval(1)))
        XCTAssertTrue(call.update(holdsMic: false, now: start.addingTimeInterval(9.1)))
        XCTAssertTrue(call.hasEnded)
        XCTAssertFalse(call.update(holdsMic: false, now: start.addingTimeInterval(30)))
    }

    /// A blip in the process list must not add up across two separate gaps.
    func testReacquiringTheMicRestartsTheClock() {
        var call = session()
        XCTAssertFalse(call.update(holdsMic: false, now: start.addingTimeInterval(1)))
        XCTAssertFalse(call.update(holdsMic: false, now: start.addingTimeInterval(7)))
        XCTAssertFalse(call.update(holdsMic: true, now: start.addingTimeInterval(8)))
        XCTAssertNil(call.releasedAt)
        XCTAssertFalse(call.update(holdsMic: false, now: start.addingTimeInterval(9)))
        XCTAssertFalse(call.update(holdsMic: false, now: start.addingTimeInterval(16)))
        XCTAssertTrue(call.update(holdsMic: false, now: start.addingTimeInterval(18)))
    }

    /// Zoom and Teams keep the input stream open while you are muted, so the
    /// owner stays in the list and the session must survive a long mute.
    func testMuteIsNotRelease() {
        var call = session()
        let owners = [MicOwner(pid: 310, bundleID: "us.zoom.xos", isRunningInput: true, isRunningOutput: true)]
        for second in stride(from: 1.0, through: 120, by: 1) {
            let holds = CallSession.holdsMic(pid: 310, in: owners)
            XCTAssertFalse(call.update(holdsMic: holds, now: start.addingTimeInterval(second)))
        }
        XCTAssertFalse(call.hasEnded)
    }

    func testHoldsMicMatchesOnlyTheTrackedProcess() {
        let owners = [
            MicOwner(pid: 310, bundleID: "us.zoom.xos", isRunningInput: true, isRunningOutput: false),
            MicOwner(pid: 400, bundleID: "com.microsoft.teams2", isRunningInput: false, isRunningOutput: true),
        ]
        XCTAssertTrue(CallSession.holdsMic(pid: 310, in: owners))
        XCTAssertFalse(CallSession.holdsMic(pid: 400, in: owners))
        XCTAssertFalse(CallSession.holdsMic(pid: 999, in: owners))
    }

    func testGraceIntervalIsEightSeconds() {
        XCTAssertEqual(CallSession.releaseGrace, 8)
    }
}
