import AppKit
import ApplicationServices
import Foundation
import os

/// A call the dock can offer to record.
///
/// Two signals produce one of these. `micOwner` means a process is holding
/// the microphone and its bundle id is a known call app, so the call counts
/// even when its window is behind everything else. `frontmost` is the older
/// signal: the app in front looks like a call, but nothing is recording yet.
struct DetectedMeeting: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case micOwner
        case frontmost
    }

    let appName: String
    let suggestedTitle: String
    let bundleID: String
    let platform: MeetingPlatform
    let source: Source
    /// The process holding the mic, when the mic owner signal found it.
    let pid: pid_t?
    /// The browser hosting the call, when the call lives in a tab.
    let browserName: String?

    /// New fields default so existing callers keep their three argument call.
    /// A missing platform is worked out from the bundle id and the title, so
    /// a caller that knows nothing about platforms still gets the right badge.
    init(appName: String,
         suggestedTitle: String,
         bundleID: String,
         platform: MeetingPlatform? = nil,
         source: Source = .frontmost,
         pid: pid_t? = nil,
         browserName: String? = nil) {
        self.appName = appName
        self.suggestedTitle = suggestedTitle
        self.bundleID = bundleID
        self.platform = platform
            ?? MeetingPlatform.classify(bundleID: bundleID, windowTitle: suggestedTitle)
            ?? .unknown
        self.source = source
        self.pid = pid
        self.browserName = browserName
    }
}

/// Everything the combine rules need, with no AppKit or Core Audio in sight
/// so the rules can be tested directly.
struct DetectionSnapshot: Equatable, Sendable {
    var frontmostBundleID: String?
    var frontmostAppName: String?
    var frontmostTitle: String?
    var frontmostPID: pid_t?
    var micOwners: [MicOwner]
    var ownerAppNames: [pid_t: String]
    /// Every window title of a mic owning process, not only the focused one.
    var ownerTitles: [pid_t: [String]]
    var ownPID: pid_t

    init(frontmostBundleID: String? = nil,
         frontmostAppName: String? = nil,
         frontmostTitle: String? = nil,
         frontmostPID: pid_t? = nil,
         micOwners: [MicOwner] = [],
         ownerAppNames: [pid_t: String] = [:],
         ownerTitles: [pid_t: [String]] = [:],
         ownPID: pid_t = 0) {
        self.frontmostBundleID = frontmostBundleID
        self.frontmostAppName = frontmostAppName
        self.frontmostTitle = frontmostTitle
        self.frontmostPID = frontmostPID
        self.micOwners = micOwners
        self.ownerAppNames = ownerAppNames
        self.ownerTitles = ownerTitles
        self.ownPID = ownPID
    }
}

/// Names the call that is on, from the microphone first and the frontmost
/// window second.
///
/// The mic owner path answers "Teams is in a call" even when Teams is buried.
/// The frontmost path stays as it was, for the browser tab that is open on a
/// lobby page and has not taken the mic yet.
@MainActor
final class MeetingAppDetector {
    var onChange: ((DetectedMeeting?) -> Void)?
    /// Fires once when the detected call's process has released the
    /// microphone for longer than `CallSession.releaseGrace`. Never fires for
    /// a frontmost-only detection, which never held the mic to begin with.
    var onCallEnded: ((DetectedMeeting) -> Void)?
    private(set) var detected: DetectedMeeting?

    private let watcher: MicOwnerWatcher
    private let defaults: UserDefaults
    private let ownPID: pid_t
    private var observers: [NSObjectProtocol] = []
    private var titleTimer: Timer?
    private var callEndTimer: Timer?
    private var callSession: CallSession?
    private var started = false

    /// How often the tracked call is checked for a released microphone.
    static let callEndCheckInterval: TimeInterval = 1

    nonisolated private static let log = Logger(subsystem: "com.undertone.app", category: "meeting")

    nonisolated private static let callAppIDs: Set<String> = Set(MeetingPlatform.nativeBundleIDs.keys)

    nonisolated private static let browserIDs: Set<String> = MeetingPlatform.browserBundleIDs

    nonisolated private static let defaultNames: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.apple.FaceTime": "FaceTime",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "com.webex.meetingmanager": "Webex",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.apple.Safari": "Safari",
        "com.google.Chrome": "Chrome",
        "company.thebrowser.Browser": "Arc",
        "com.brave.Browser": "Brave",
        "org.mozilla.firefox": "Firefox",
        "com.microsoft.edgemac": "Edge",
    ]

    init(watcher: MicOwnerWatcher? = nil,
         defaults: UserDefaults = .standard,
         ownPID: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.watcher = watcher ?? MicOwnerWatcher(ownPID: ownPID)
        self.defaults = defaults
        self.ownPID = ownPID
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        watcher.onChange = { [weak self] _ in self?.refresh() }
        observe(NSWorkspace.didActivateApplicationNotification)
        observe(NSWorkspace.didLaunchApplicationNotification)
        observe(NSWorkspace.didTerminateApplicationNotification)
        observeDefaultsChange()
        applyEnabledState()
    }

    func stop() {
        guard started else { return }
        started = false
        watcher.stop()
        watcher.onChange = nil
        titleTimer?.invalidate(); titleTimer = nil
        callEndTimer?.invalidate(); callEndTimer = nil
        callSession = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers = []
        NotificationCenter.default.removeObserver(self, name: UserDefaults.didChangeNotification, object: nil)
    }

    /// Re-reads both signals and publishes the result.
    func refresh() {
        guard started else { return }
        guard MeetingDetectionSettings.isEnabled(defaults: defaults) else {
            applyEnabledState()
            return
        }
        let snapshot = currentSnapshot()
        syncTitleTimer(isBrowser: Self.browserIDs.contains(snapshot.frontmostBundleID ?? ""))
        publish(Self.detect(snapshot))
        updateCallSession(owners: snapshot.micOwners, now: Date())
    }

    /// Settings off means no detection at all: the watcher stops and the dock
    /// is told there is no call.
    private func applyEnabledState() {
        guard started else { return }
        guard MeetingDetectionSettings.isEnabled(defaults: defaults) else {
            watcher.stop()
            titleTimer?.invalidate(); titleTimer = nil
            callEndTimer?.invalidate(); callEndTimer = nil
            callSession = nil
            publish(nil)
            return
        }
        watcher.start()
        refresh()
    }

    // MARK: Combine rules (pure)

    /// The microphone wins. A native call app holding the mic is a call even
    /// in the background. A browser holding the mic is a call only when one of
    /// its window titles names the service. When neither answers, the
    /// frontmost app is classified the way it always was.
    nonisolated static func detect(_ snapshot: DetectionSnapshot) -> DetectedMeeting? {
        for candidate in MicOwnerWatcher.callCandidates(owners: snapshot.micOwners, ownPID: snapshot.ownPID) {
            guard let bundleID = candidate.bundleID else { continue }
            let name = resolvedName(bundleID: bundleID, appName: snapshot.ownerAppNames[candidate.pid])
            let titles = (snapshot.ownerTitles[candidate.pid] ?? []).compactMap(usableTitle)

            if let platform = MeetingPlatform.nativeBundleIDs[bundleID] {
                return DetectedMeeting(
                    appName: name,
                    suggestedTitle: titles.first ?? "\(name) call",
                    bundleID: bundleID,
                    platform: platform,
                    source: .micOwner,
                    pid: candidate.pid
                )
            }

            for title in titles {
                guard let platform = MeetingPlatform.classify(bundleID: bundleID, windowTitle: title) else { continue }
                return DetectedMeeting(
                    appName: name,
                    suggestedTitle: title,
                    bundleID: bundleID,
                    platform: platform,
                    source: .micOwner,
                    pid: candidate.pid,
                    browserName: name
                )
            }
        }

        return classify(bundleID: snapshot.frontmostBundleID,
                        appName: snapshot.frontmostAppName,
                        windowTitle: snapshot.frontmostTitle,
                        pid: snapshot.frontmostPID)
    }

    /// Native call apps always count. Browsers count only when the focused
    /// window title has a Meet / Zoom / Teams token.
    nonisolated static func classify(bundleID: String?,
                                     appName: String?,
                                     windowTitle: String?,
                                     pid: pid_t? = nil) -> DetectedMeeting? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let name = resolvedName(bundleID: bundleID, appName: appName)
        let usable = usableTitle(windowTitle)

        if callAppIDs.contains(bundleID) {
            return DetectedMeeting(
                appName: name,
                suggestedTitle: usable ?? "\(name) call",
                bundleID: bundleID,
                platform: MeetingPlatform.nativeBundleIDs[bundleID],
                source: .frontmost,
                pid: pid
            )
        }
        if browserIDs.contains(bundleID) {
            guard let usable, let platform = MeetingPlatform.classify(bundleID: bundleID, windowTitle: usable) else {
                return nil
            }
            return DetectedMeeting(
                appName: name,
                suggestedTitle: usable,
                bundleID: bundleID,
                platform: platform,
                source: .frontmost,
                pid: pid,
                browserName: name
            )
        }
        return nil
    }

    /// Tokens must be exactly Meet, Zoom, or Teams so "Meeting notes" in an
    /// unrelated tab does not count as a call.
    nonisolated static func titleLooksLikeCall(_ title: String) -> Bool {
        let markers: Set<String> = ["Meet", "Zoom", "Teams"]
        return title.split { !$0.isLetter }.contains { markers.contains(String($0)) }
    }

    nonisolated static func usableTitle(_ title: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    nonisolated private static func resolvedName(bundleID: String, appName: String?) -> String {
        let trimmed = appName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        return defaultNames[bundleID] ?? "Call"
    }

    // MARK: Machine state

    private func currentSnapshot() -> DetectionSnapshot {
        let front = NSWorkspace.shared.frontmostApplication
        let frontBundleID = front?.bundleIdentifier
        let needsTitle = Self.callAppIDs.contains(frontBundleID ?? "")
            || Self.browserIDs.contains(frontBundleID ?? "")
        let owners = watcher.owners
        let candidates = MicOwnerWatcher.callCandidates(owners: owners, ownPID: ownPID)

        var names: [pid_t: String] = [:]
        var titles: [pid_t: [String]] = [:]
        for candidate in candidates {
            let app = NSRunningApplication(processIdentifier: candidate.pid)
            if let name = app?.localizedName { names[candidate.pid] = name }
            titles[candidate.pid] = Self.windowTitles(pid: candidate.pid)
        }

        return DetectionSnapshot(
            frontmostBundleID: frontBundleID,
            frontmostAppName: front?.localizedName,
            frontmostTitle: needsTitle ? Self.focusedWindowTitle(pid: front?.processIdentifier) : nil,
            frontmostPID: front?.processIdentifier,
            micOwners: owners,
            ownerAppNames: names,
            ownerTitles: titles,
            ownPID: ownPID
        )
    }

    private func publish(_ next: DetectedMeeting?) {
        guard next != detected else { return }
        detected = next
        logDetection(next)
        if let next, next.source == .micOwner, let pid = next.pid, callSession?.pid != pid {
            callSession = CallSession(meeting: next, pid: pid, at: Date())
            startCallEndTimer()
        }
        onChange?(next)
    }

    /// Nothing here carries the window title text. Only its length, so a live
    /// log can show that a title was read without printing what it said.
    private func logDetection(_ meeting: DetectedMeeting?) {
        guard let meeting else {
            Self.log.info("meeting detection cleared")
            return
        }
        Self.log.info("""
        meeting detected source=\(meeting.source.rawValue, privacy: .public) \
        platform=\(meeting.platform.rawValue, privacy: .public) \
        bundle=\(meeting.bundleID, privacy: .public) \
        pid=\(meeting.pid ?? -1, privacy: .public) \
        titleLength=\(meeting.suggestedTitle.count, privacy: .public)
        """)
    }

    private func startCallEndTimer() {
        guard callEndTimer == nil else { return }
        let timer = Timer(timeInterval: Self.callEndCheckInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.checkCallEnd() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        callEndTimer = timer
    }

    /// The watcher's poll is gated on a call app running, so a call app that
    /// quit outright would never publish again. Ask Core Audio directly while
    /// a call is tracked; it is one cheap read per second, and only then.
    private func checkCallEnd() {
        guard callSession != nil else {
            callEndTimer?.invalidate(); callEndTimer = nil
            return
        }
        watcher.refreshNow()
        updateCallSession(owners: watcher.owners, now: Date())
    }

    private func updateCallSession(owners: [MicOwner], now: Date) {
        guard var session = callSession else { return }
        let holds = CallSession.holdsMic(pid: session.pid, in: owners)
        let ended = session.update(holdsMic: holds, now: now)
        callSession = session
        guard ended else { return }
        callSession = nil
        callEndTimer?.invalidate(); callEndTimer = nil
        Self.log.info("""
        meeting call ended platform=\(session.meeting.platform.rawValue, privacy: .public) \
        bundle=\(session.meeting.bundleID, privacy: .public) \
        pid=\(session.pid, privacy: .public)
        """)
        onCallEnded?(session.meeting)
    }

    // MARK: Accessibility

    /// Every window title the app owns, so a Meet tab in a background window
    /// still names the call. Falls back to the focused window when the window
    /// list is unavailable.
    nonisolated static func windowTitles(pid: pid_t) -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let list = value as? [AXUIElement] {
            let titles = list.compactMap { windowTitle($0) }
            if !titles.isEmpty { return titles }
        }
        guard let focused = focusedWindowTitle(pid: pid) else { return [] }
        return [focused]
    }

    nonisolated static func focusedWindowTitle(pid: pid_t?) -> String? {
        guard let pid else { return nil }
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window,
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return windowTitle(window as! AXUIElement)
    }

    nonisolated private static func windowTitle(_ element: AXUIElement) -> String? {
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success,
              let text = title as? String else { return nil }
        return usableTitle(text)
    }

    // MARK: Observers

    private func observe(_ name: Notification.Name) {
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.refresh()
                }
            }
        }
        observers.append(observer)
    }

    /// The settings toggle writes to UserDefaults, so a change there has to
    /// start or stop the watcher without the dock calling anything.
    private func observeDefaultsChange() {
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyEnabledState() }
            }
        }
    }

    private func syncTitleTimer(isBrowser: Bool) {
        if isBrowser {
            guard titleTimer == nil else { return }
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.refresh()
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            titleTimer = timer
        } else {
            titleTimer?.invalidate()
            titleTimer = nil
        }
    }
}
