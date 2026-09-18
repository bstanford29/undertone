import Foundation

/// One call the detector is tracking, and the rule that says it ended.
///
/// A call ends when the owning process has let go of the microphone for
/// longer than `releaseGrace`. Muting yourself is not letting go: Zoom and
/// Teams keep the input stream open while muted, so `isRunningInput` stays
/// true and the session never ends on a mute.
///
/// This is a pure state machine. Feed it observations with their timestamps
/// and it answers once, on the observation that crosses the grace interval.
struct CallSession: Equatable, Sendable {
    /// How long the mic must stay released before the call counts as over.
    static let releaseGrace: TimeInterval = 8

    let meeting: DetectedMeeting
    let pid: pid_t
    let startedAt: Date
    private(set) var lastHeldAt: Date
    private(set) var releasedAt: Date?
    private(set) var hasEnded = false

    init(meeting: DetectedMeeting, pid: pid_t, at: Date) {
        self.meeting = meeting
        self.pid = pid
        self.startedAt = at
        self.lastHeldAt = at
    }

    /// Feeds one observation. Returns true exactly once, on the observation
    /// where the release has lasted longer than the grace interval.
    @discardableResult
    mutating func update(holdsMic: Bool, now: Date, grace: TimeInterval = CallSession.releaseGrace) -> Bool {
        guard !hasEnded else { return false }
        guard !holdsMic else {
            lastHeldAt = now
            releasedAt = nil
            return false
        }
        let since = releasedAt ?? now
        releasedAt = since
        guard now.timeIntervalSince(since) > grace else { return false }
        hasEnded = true
        return true
    }

    /// True while the tracked process still has the microphone open.
    static func holdsMic(pid: pid_t, in owners: [MicOwner]) -> Bool {
        owners.contains { $0.pid == pid && $0.isRunningInput }
    }
}
