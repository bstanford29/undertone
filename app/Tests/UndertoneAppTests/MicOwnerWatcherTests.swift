import XCTest
@testable import UndertoneApp

final class MicOwnerWatcherTests: XCTestCase {
    private func owner(_ pid: pid_t, _ bundleID: String?, input: Bool = true, output: Bool = false) -> MicOwner {
        MicOwner(pid: pid, bundleID: bundleID, isRunningInput: input, isRunningOutput: output)
    }

    func testNativeCallAppHoldingMicIsTheOwner() {
        let owners = [owner(310, "us.zoom.xos")]
        XCTAssertEqual(MicOwnerWatcher.callOwner(owners: owners, ownPID: 99)?.pid, 310)
    }

    func testSystemDictationDaemonIsIgnored() {
        let owners = [owner(120, "com.apple.CoreSpeech"), owner(121, "com.apple.assistantd")]
        XCTAssertNil(MicOwnerWatcher.callOwner(owners: owners, ownPID: 99))
    }

    func testOurOwnProcessIsIgnored() {
        let owners = [owner(99, "com.undertone.app")]
        XCTAssertNil(MicOwnerWatcher.callOwner(owners: owners, ownPID: 99))
    }

    /// The bundle id list already holds us, but the pid filter has to work on
    /// its own so a renamed or unbundled build still excludes itself.
    func testOurOwnPIDIsIgnoredEvenWithACallBundle() {
        let owners = [owner(99, "us.zoom.xos")]
        XCTAssertNil(MicOwnerWatcher.callOwner(owners: owners, ownPID: 99))
    }

    func testOutputOnlyProcessIsNotAnOwner() {
        let owners = [owner(400, "us.zoom.xos", input: false, output: true)]
        XCTAssertNil(MicOwnerWatcher.callOwner(owners: owners, ownPID: 99))
    }

    func testUnknownAppHoldingMicIsNotACall() {
        let owners = [owner(500, "com.apple.Photo-Booth")]
        XCTAssertNil(MicOwnerWatcher.callOwner(owners: owners, ownPID: 99))
    }

    func testProcessWithoutABundleIsNotACall() {
        let owners = [owner(600, nil), owner(601, "")]
        XCTAssertNil(MicOwnerWatcher.callOwner(owners: owners, ownPID: 99))
    }

    func testBrowserHoldingMicIsACandidate() {
        let owners = [owner(700, "com.google.Chrome")]
        XCTAssertEqual(MicOwnerWatcher.callOwner(owners: owners, ownPID: 99)?.bundleID, "com.google.Chrome")
    }

    func testNativeAppSortsAheadOfBrowser() {
        let owners = [owner(700, "com.google.Chrome"), owner(900, "com.microsoft.teams2")]
        let candidates = MicOwnerWatcher.callCandidates(owners: owners, ownPID: 99)
        XCTAssertEqual(candidates.map(\.pid), [900, 700])
    }

    func testCandidateOrderIsStableByPID() {
        let owners = [owner(900, "us.zoom.xos"), owner(300, "com.apple.FaceTime")]
        XCTAssertEqual(MicOwnerWatcher.callCandidates(owners: owners, ownPID: 99).map(\.pid), [300, 900])
    }

    func testPollGateNeedsAKnownCallApp() {
        XCTAssertFalse(MicOwnerWatcher.knownCallAppIsRunning(bundleIDs: ["com.apple.finder", "com.apple.Notes"]))
        XCTAssertTrue(MicOwnerWatcher.knownCallAppIsRunning(bundleIDs: ["com.apple.finder", "us.zoom.xos"]))
        XCTAssertTrue(MicOwnerWatcher.knownCallAppIsRunning(bundleIDs: ["com.google.Chrome"]))
    }
}
