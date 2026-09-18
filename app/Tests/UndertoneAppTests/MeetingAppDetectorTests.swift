import XCTest
@testable import UndertoneApp

final class MeetingAppDetectorTests: XCTestCase {
    func testZoomBundleWithNilTitleUsesAppNameCall() {
        let detected = MeetingAppDetector.classify(
            bundleID: "us.zoom.xos", appName: nil, windowTitle: nil
        )
        XCTAssertEqual(detected?.appName, "Zoom")
        XCTAssertEqual(detected?.suggestedTitle, "Zoom call")
        XCTAssertEqual(detected?.bundleID, "us.zoom.xos")
    }

    func testFaceTimeUsesReadableWindowTitle() {
        let detected = MeetingAppDetector.classify(
            bundleID: "com.apple.FaceTime", appName: "FaceTime", windowTitle: "Jordan FaceTime"
        )
        XCTAssertEqual(detected?.appName, "FaceTime")
        XCTAssertEqual(detected?.suggestedTitle, "Jordan FaceTime")
        XCTAssertEqual(detected?.bundleID, "com.apple.FaceTime")
    }

    func testChromeMeetTitleIsDetected() {
        let detected = MeetingAppDetector.classify(
            bundleID: "com.google.Chrome", appName: "Google Chrome",
            windowTitle: "Meet - Weekly sync"
        )
        XCTAssertEqual(detected?.appName, "Google Chrome")
        XCTAssertEqual(detected?.suggestedTitle, "Meet - Weekly sync")
        XCTAssertEqual(detected?.bundleID, "com.google.Chrome")
    }

    func testChromeGitHubTitleIsIgnored() {
        XCTAssertNil(MeetingAppDetector.classify(
            bundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: "GitHub"
        ))
    }

    func testChromeNilTitleIsIgnored() {
        XCTAssertNil(MeetingAppDetector.classify(
            bundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: nil
        ))
    }

    func testUnknownBundleIsIgnored() {
        XCTAssertNil(MeetingAppDetector.classify(
            bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Inbox"
        ))
        XCTAssertNil(MeetingAppDetector.classify(
            bundleID: "com.apple.finder", appName: "Finder", windowTitle: "Meet"
        ))
    }

    func testNilBundleIsIgnored() {
        XCTAssertNil(MeetingAppDetector.classify(bundleID: nil, appName: "Zoom", windowTitle: nil))
    }

    func testMeetingNotesDoesNotCountAsACallTab() {
        XCTAssertFalse(MeetingAppDetector.titleLooksLikeCall("Meeting notes"))
        XCTAssertTrue(MeetingAppDetector.titleLooksLikeCall("Meet - Weekly sync"))
        XCTAssertTrue(MeetingAppDetector.titleLooksLikeCall("Zoom"))
        XCTAssertTrue(MeetingAppDetector.titleLooksLikeCall("Microsoft Teams"))
    }
}

/// The two signal combine rules. Everything here runs on the pure `detect`
/// entry point, so no Core Audio, Accessibility, or frontmost app is touched.
final class MeetingDetectionCombineTests: XCTestCase {
    private let ownPID: pid_t = 99

    private func owner(_ pid: pid_t, _ bundleID: String, input: Bool = true) -> MicOwner {
        MicOwner(pid: pid, bundleID: bundleID, isRunningInput: input, isRunningOutput: true)
    }

    private func snapshot(front: String? = nil,
                          frontName: String? = nil,
                          frontTitle: String? = nil,
                          owners: [MicOwner] = [],
                          names: [pid_t: String] = [:],
                          titles: [pid_t: [String]] = [:]) -> DetectionSnapshot {
        DetectionSnapshot(frontmostBundleID: front, frontmostAppName: frontName,
                          frontmostTitle: frontTitle, frontmostPID: 1,
                          micOwners: owners, ownerAppNames: names,
                          ownerTitles: titles, ownPID: ownPID)
    }

    // MARK: Native apps holding the mic

    func testZoomHoldingMicWinsOverTheFrontmostApp() {
        let detected = MeetingAppDetector.detect(snapshot(
            front: "com.apple.mail", frontName: "Mail",
            owners: [owner(310, "us.zoom.xos")], names: [310: "zoom.us"]
        ))
        XCTAssertEqual(detected?.platform, .zoom)
        XCTAssertEqual(detected?.source, .micOwner)
        XCTAssertEqual(detected?.pid, 310)
        XCTAssertEqual(detected?.suggestedTitle, "zoom.us call")
        XCTAssertNil(detected?.browserName)
    }

    func testTeamsHoldingMicUsesItsWindowTitle() {
        let detected = MeetingAppDetector.detect(snapshot(
            front: "com.apple.finder", frontName: "Finder",
            owners: [owner(410, "com.microsoft.teams2")],
            names: [410: "Microsoft Teams"],
            titles: [410: ["Weekly sync | Microsoft Teams"]]
        ))
        XCTAssertEqual(detected?.platform, .teams)
        XCTAssertEqual(detected?.suggestedTitle, "Weekly sync | Microsoft Teams")
        XCTAssertEqual(detected?.source, .micOwner)
    }

    func testClassicTeamsBundleIsTeams() {
        let detected = MeetingAppDetector.detect(snapshot(owners: [owner(411, "com.microsoft.teams")]))
        XCTAssertEqual(detected?.platform, .teams)
    }

    func testFaceTimeHoldingMicIsACall() {
        let detected = MeetingAppDetector.detect(snapshot(
            owners: [owner(200, "com.apple.FaceTime")], names: [200: "FaceTime"],
            titles: [200: ["Jordan"]]
        ))
        XCTAssertEqual(detected?.platform, .facetime)
        XCTAssertEqual(detected?.suggestedTitle, "Jordan")
    }

    func testWebexAndSlackHoldingMicAreCalls() {
        XCTAssertEqual(MeetingAppDetector.detect(snapshot(
            owners: [owner(500, "com.webex.meetingmanager")]))?.platform, .webex)
        XCTAssertEqual(MeetingAppDetector.detect(snapshot(
            owners: [owner(501, "com.tinyspeck.slackmacgap")]))?.platform, .slack)
    }

    // MARK: Browsers holding the mic

    func testChromeHoldingMicWithAMeetTitleIsAMeetCall() {
        let detected = MeetingAppDetector.detect(snapshot(
            front: "com.apple.mail", frontName: "Mail",
            owners: [owner(700, "com.google.Chrome")],
            names: [700: "Google Chrome"],
            titles: [700: ["Inbox", "Meet - abc-defg-hij"]]
        ))
        XCTAssertEqual(detected?.platform, .meet)
        XCTAssertEqual(detected?.source, .micOwner)
        XCTAssertEqual(detected?.browserName, "Google Chrome")
        XCTAssertEqual(detected?.suggestedTitle, "Meet - abc-defg-hij")
    }

    /// A background window counts. A Meet tab can hold the call without
    /// being the focused one; scanning every window title is how we match that.
    func testBackgroundBrowserWindowTitleCounts() {
        let detected = MeetingAppDetector.detect(snapshot(
            owners: [owner(701, "com.brave.Browser")],
            titles: [701: ["GitHub", "Docs", "Zoom Meeting"]]
        ))
        XCTAssertEqual(detected?.platform, .zoom)
        XCTAssertEqual(detected?.appName, "Brave")
    }

    func testBrowserHoldingMicWithoutACallTitleIsNotACall() {
        XCTAssertNil(MeetingAppDetector.detect(snapshot(
            owners: [owner(700, "com.google.Chrome")],
            titles: [700: ["Inbox", "Meeting notes"]]
        )))
    }

    func testBrowserHoldingMicWithNoTitlesIsNotACall() {
        XCTAssertNil(MeetingAppDetector.detect(snapshot(owners: [owner(700, "com.google.Chrome")])))
    }

    // MARK: Ignored mic owners

    func testSiriHoldingTheMicRaisesNothing() {
        XCTAssertNil(MeetingAppDetector.detect(snapshot(
            owners: [owner(120, "com.apple.CoreSpeech"), owner(121, "com.apple.assistantd")]
        )))
    }

    func testOurOwnDictationDoesNotLookLikeACall() {
        let owners = [MicOwner(pid: ownPID, bundleID: "com.undertone.app",
                               isRunningInput: true, isRunningOutput: false)]
        XCTAssertNil(MeetingAppDetector.detect(snapshot(owners: owners)))
    }

    func testCallAppPlayingAudioWithoutTheMicIsNotACall() {
        XCTAssertNil(MeetingAppDetector.detect(snapshot(
            owners: [owner(310, "us.zoom.xos", input: false)]
        )))
    }

    // MARK: Frontmost fallback

    func testFrontmostZoomStillCountsWithNoMicOwner() {
        let detected = MeetingAppDetector.detect(snapshot(front: "us.zoom.xos", frontName: "zoom.us"))
        XCTAssertEqual(detected?.source, .frontmost)
        XCTAssertEqual(detected?.platform, .zoom)
        XCTAssertEqual(detected?.suggestedTitle, "zoom.us call")
        XCTAssertEqual(detected?.pid, 1)
    }

    func testFrontmostBrowserNeedsACallTitle() {
        XCTAssertNil(MeetingAppDetector.detect(snapshot(
            front: "com.google.Chrome", frontName: "Google Chrome", frontTitle: "GitHub"
        )))
        let detected = MeetingAppDetector.detect(snapshot(
            front: "com.google.Chrome", frontName: "Google Chrome", frontTitle: "Meet - standup"
        ))
        XCTAssertEqual(detected?.platform, .meet)
        XCTAssertEqual(detected?.source, .frontmost)
        XCTAssertEqual(detected?.browserName, "Google Chrome")
    }

    func testNothingInFrontAndNoMicOwnerIsNil() {
        XCTAssertNil(MeetingAppDetector.detect(snapshot(front: "com.apple.finder", frontName: "Finder")))
        XCTAssertNil(MeetingAppDetector.detect(snapshot()))
    }

    // MARK: Ordering

    func testNativeCallBeatsABrowserCallWhenBothHoldTheMic() {
        let detected = MeetingAppDetector.detect(snapshot(
            owners: [owner(700, "com.google.Chrome"), owner(900, "com.microsoft.teams2")],
            titles: [700: ["Meet - standup"]]
        ))
        XCTAssertEqual(detected?.platform, .teams)
        XCTAssertEqual(detected?.pid, 900)
    }

    /// A browser with nothing call-like open must not block a browser that
    /// does have a call window.
    func testASilentBrowserDoesNotHideACallInAnother() {
        let detected = MeetingAppDetector.detect(snapshot(
            owners: [owner(700, "com.google.Chrome"), owner(800, "com.apple.Safari")],
            titles: [700: ["Inbox"], 800: ["Webex Meeting"]]
        ))
        XCTAssertEqual(detected?.platform, .webex)
        XCTAssertEqual(detected?.pid, 800)
    }

    // MARK: Settings

    func testDetectionSettingDefaultsOnAndCanBeTurnedOff() {
        let defaults = UserDefaults(suiteName: "undertone.detection.test.\(UUID().uuidString)")!
        XCTAssertTrue(MeetingDetectionSettings.isEnabled(defaults: defaults))
        defaults.set(false, forKey: MeetingDetectionSettings.detectCallsKey)
        XCTAssertFalse(MeetingDetectionSettings.isEnabled(defaults: defaults))
        defaults.set(true, forKey: MeetingDetectionSettings.detectCallsKey)
        XCTAssertTrue(MeetingDetectionSettings.isEnabled(defaults: defaults))
    }

    @MainActor
    func testDetectorPublishesNilWhileDetectionIsOff() {
        let defaults = UserDefaults(suiteName: "undertone.detection.test.\(UUID().uuidString)")!
        defaults.set(false, forKey: MeetingDetectionSettings.detectCallsKey)
        let detector = MeetingAppDetector(defaults: defaults, ownPID: ownPID)
        var published: [DetectedMeeting?] = []
        detector.onChange = { published.append($0) }
        detector.start()
        detector.refresh()
        XCTAssertNil(detector.detected)
        XCTAssertTrue(published.allSatisfy { $0 == nil })
        detector.stop()
    }

    // MARK: Platform naming

    func testEveryPlatformHasAReadableName() {
        XCTAssertEqual(MeetingPlatform.zoom.displayName, "Zoom")
        XCTAssertEqual(MeetingPlatform.teams.displayName, "Teams")
        XCTAssertEqual(MeetingPlatform.meet.displayName, "Google Meet")
        XCTAssertEqual(MeetingPlatform.facetime.displayName, "FaceTime")
        XCTAssertEqual(MeetingPlatform.webex.displayName, "Webex")
        XCTAssertEqual(MeetingPlatform.slack.displayName, "Slack")
        XCTAssertEqual(MeetingPlatform.unknown.displayName, "Call")
    }

    /// The three argument initializer still compiles and still fills in a
    /// platform, so the dock keeps working while it migrates.
    func testLegacyInitializerDerivesThePlatform() {
        let meeting = DetectedMeeting(appName: "FaceTime", suggestedTitle: "FaceTime call",
                                      bundleID: "com.apple.FaceTime")
        XCTAssertEqual(meeting.platform, .facetime)
        XCTAssertEqual(meeting.source, .frontmost)
        XCTAssertNil(meeting.pid)
    }
}
