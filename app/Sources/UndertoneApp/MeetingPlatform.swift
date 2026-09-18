import Foundation

/// Which conferencing service a detected call belongs to. Shared by the
/// detector (which classifies) and the dock (which draws the badge and
/// names the meeting). Pure and testable.
enum MeetingPlatform: String, Equatable, Sendable, CaseIterable {
    case zoom, teams, facetime, webex, slack, meet, unknown

    var displayName: String {
        switch self {
        case .zoom: return "Zoom"
        case .teams: return "Teams"
        case .facetime: return "FaceTime"
        case .webex: return "Webex"
        case .slack: return "Slack"
        case .meet: return "Google Meet"
        case .unknown: return "Call"
        }
    }

    /// Native call apps, by bundle identifier.
    static let nativeBundleIDs: [String: MeetingPlatform] = [
        "us.zoom.xos": .zoom,
        "com.microsoft.teams2": .teams,
        "com.microsoft.teams": .teams,
        "com.apple.FaceTime": .facetime,
        "com.webex.meetingmanager": .webex,
        "com.cisco.webexmeetingsapp": .webex,
        "com.tinyspeck.slackmacgap": .slack,
    ]

    /// Browsers that can host a call. A browser only counts when a window
    /// title names the service.
    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
    ]

    /// Processes that hold the microphone for system features, never a call.
    static let ignoredMicOwnerBundleIDs: Set<String> = [
        "com.apple.CoreSpeech",
        "com.apple.siri",
        "com.apple.Siri",
        "com.apple.assistantd",
        "com.apple.DictationIM",
        "com.apple.controlcenter",
        "com.undertone.app",
    ]

    static func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return browserBundleIDs.contains(bundleID)
    }

    /// Classifies a process by bundle id, plus a window title for browsers.
    /// Returns nil when the process is not a call.
    static func classify(bundleID: String?, windowTitle: String?) -> MeetingPlatform? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let native = nativeBundleIDs[bundleID] { return native }
        guard browserBundleIDs.contains(bundleID), let windowTitle else { return nil }
        let tokens = Set(windowTitle.split { !$0.isLetter }.map(String.init))
        if tokens.contains("Meet") { return .meet }
        if tokens.contains("Zoom") { return .zoom }
        if tokens.contains("Teams") { return .teams }
        if tokens.contains("Webex") { return .webex }
        return nil
    }
}

/// Keys shared between the detector and Settings so both sides agree
/// without importing each other.
enum MeetingDetectionSettings {
    /// UserDefaults key. Missing means true.
    static let detectCallsKey = "detectCallsAutomatically"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: detectCallsKey) == nil ? true : defaults.bool(forKey: detectCallsKey)
    }
}
