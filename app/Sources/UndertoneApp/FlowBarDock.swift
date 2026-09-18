import AppKit
import CoreGraphics
import Foundation

/// One of the three controls the dock fans out on hover. The order of
/// `allCases` is the order they sit in along the edge: mic nearest the top on
/// the side docks, nearest the left on the top and bottom docks.
enum DockControl: String, CaseIterable, Identifiable, Sendable {
    case dictate
    case newNote
    case scratchpad

    var id: String { rawValue }
}

/// What the dock draws right now. Hover is view state, not `PillState`, so
/// the model never has to know where the pointer is.
enum FlowBarViewState: Equatable {
    /// The rest state: one small gray nub at the edge.
    case nub
    /// The three controls, with the hovered one lightened and labelled.
    case stack(hovered: DockControl?, labelWidth: CGFloat)
    /// Dictation. `commandWidth` is the width of the Command marker, or nil.
    case level(locked: Bool, commandWidth: CGFloat?)
    /// Cleanup is running with nothing to say yet.
    case spinner
    /// A capsule with a glyph, a message, or a millisecond reading.
    case text(FlowBarTextCapsule, width: CGFloat)
    /// Meeting capture is running. `badgeWidth` is the timer capsule, or the
    /// Stop label while the control is hovered.
    case recording(elapsed: TimeInterval, hovered: Bool, badgeWidth: CGFloat)
    /// The nub plus the meeting nudge card.
    case nudge(DetectedMeeting)
}

/// A one-line capsule: an optional glyph, a message, and an optional
/// monospaced reading such as "742 ms".
struct FlowBarTextCapsule: Equatable {
    enum Glyph: Equatable {
        case none
        case check
        case warning
        case failure
    }

    let glyph: Glyph
    let text: String
    let mono: String?

    init(glyph: Glyph = .none, text: String = "", mono: String? = nil) {
        self.glyph = glyph
        self.text = text
        self.mono = mono
    }
}

/// Every size and duration the dock is built from. Points on a Mac display,
/// straight out of section 05 of `docs/mockups-flowbar-v2.html`.
enum FlowBarMetrics {
    // Nub
    static let nubLength: CGFloat = 48
    static let nubThickness: CGFloat = 8
    static let nubRadius: CGFloat = 4
    static let nubInset: CGFloat = 6
    /// The nub is too thin to aim at, so the panel covers 48 along the edge
    /// by 44 inward, the same trick the Dock uses.
    static let nubHitAlong: CGFloat = 48
    static let nubHitDepth: CGFloat = 44

    // Stack
    static let stackInset: CGFloat = 10
    static let controlGap: CGFloat = 8
    static let controlSize: CGFloat = 40
    static let micAlong: CGFloat = 64
    static let newNoteHoverDepth: CGFloat = 76
    /// 64 + 8 + 40 + 8 + 40.
    static let stackAlong: CGFloat = 160
    static let hitPadding: CGFloat = 4

    // Labels
    static let labelAlong: CGFloat = 46
    static let labelPadding: CGFloat = 22
    static let labelGap: CGFloat = 12
    static let labelFontSize: CGFloat = 17
    static let labelShortcutGap: CGFloat = 8

    // Capsules
    static let capsuleDepth: CGFloat = 40
    static let capsuleAlong: CGFloat = 120
    static let textCapsuleThickness: CGFloat = 40
    static let textCapsulePadding: CGFloat = 16
    static let textCapsuleFontSize: CGFloat = 13
    static let textCapsuleGap: CGFloat = 8
    static let monoFontSize: CGFloat = 12
    static let glyphSize: CGFloat = 16

    // Recording
    static let timerThickness: CGFloat = 28
    static let timerPadding: CGFloat = 10
    static let recordingDot: CGFloat = 14
    static let recordingPulsePeriod: TimeInterval = 1.2

    // Nudge card
    static let nudgeWidth: CGFloat = 300
    /// Tall enough for a two-line reason, which is what a browser call needs.
    static let nudgeHeight: CGFloat = 132
    static let nudgeGap: CGFloat = 12
    static let nudgeRadius: CGFloat = 12
    static let nudgePadding: CGFloat = 14
    static let nudgeButtonHeight: CGFloat = 26
    static let nudgeButtonGap: CGFloat = 8
    static let nudgeAutoDismiss: TimeInterval = 20

    /// Room around the drawn content so the shadow is not clipped by the
    /// panel edge. The nub gets none: it is drawn with a tight shadow so its
    /// panel can stay exactly the hit area.
    static let shadowSlack: CGFloat = 12

    // Timing
    static let hoverOpenDelay: TimeInterval = 0.120
    static let hoverCloseDelay: TimeInterval = 0.400
    static let fanOutDuration: TimeInterval = 0.260
    static let fanOutStagger: TimeInterval = 0.045
    static let collapseDuration: TimeInterval = 0.160
    static let nubFadeDuration: TimeInterval = 0.140
    static let labelFadeDuration: TimeInterval = 0.140
    static let reducedMotionFade: TimeInterval = 0.120

    // Holds
    static let insertedHold: Duration = .milliseconds(900)
    static let transientHold: Duration = .milliseconds(1800)
    static let savedHold: Duration = .milliseconds(1200)
    static let meetingEndedHold: Duration = .seconds(3)
}

/// Panel-local geometry for every dock. `depth` measures inward from the
/// docked edge. `along` measures along the edge, downward on the left and
/// right docks and rightward on the top and bottom docks. One set of numbers
/// then describes all four docks, and this type maps them into the panel's
/// AppKit (bottom-left origin) coordinates.
struct DockAxis: Equatable {
    let edge: PillEdge
    let panelSize: CGSize

    init(edge: PillEdge, panelSize: CGSize) {
        self.edge = edge
        self.panelSize = panelSize
    }

    /// The panel size for a box `depth` points deep and `along` points long.
    static func size(edge: PillEdge, depth: CGFloat, along: CGFloat) -> CGSize {
        edge.isHorizontal ? CGSize(width: along, height: depth) : CGSize(width: depth, height: along)
    }

    /// The panel's own extent along the edge.
    var alongExtent: CGFloat { edge.isHorizontal ? panelSize.width : panelSize.height }

    /// The panel's own extent inward from the edge.
    var depthExtent: CGFloat { edge.isHorizontal ? panelSize.height : panelSize.width }

    func rect(depth: CGFloat, deep: CGFloat, along: CGFloat, long: CGFloat) -> CGRect {
        switch edge {
        case .right:
            return CGRect(x: panelSize.width - depth - deep, y: panelSize.height - along - long,
                          width: deep, height: long)
        case .left:
            return CGRect(x: depth, y: panelSize.height - along - long, width: deep, height: long)
        case .bottom:
            return CGRect(x: along, y: depth, width: long, height: deep)
        case .top:
            return CGRect(x: along, y: panelSize.height - depth - deep, width: long, height: deep)
        }
    }

    /// A box of `deep` by `long` centered along the edge.
    func centered(depth: CGFloat, deep: CGFloat, long: CGFloat) -> CGRect {
        rect(depth: depth, deep: deep, along: (alongExtent - long) / 2, long: long)
    }

    /// The direction a label or card grows toward the interior, as a unit
    /// offset in AppKit panel coordinates.
    var interiorDirection: CGPoint {
        switch edge {
        case .right: return CGPoint(x: -1, y: 0)
        case .left: return CGPoint(x: 1, y: 0)
        case .bottom: return CGPoint(x: 0, y: 1)
        case .top: return CGPoint(x: 0, y: -1)
        }
    }
}

/// Pure layout for the dock: panel sizes, control rects, hit testing, and the
/// words on every label. No AppKit state, so it is all unit testable.
enum FlowBarDock {

    // MARK: - Words

    /// What a click on New note does next.
    enum NewNoteAction: Equatable, Sendable {
        case start
        case stop
        /// Auto-stop ended a call recently enough that the same control
        /// should pick that call back up rather than open a blank meeting.
        case resume
    }

    /// How long after an auto-stop the control keeps offering Resume. Past
    /// this the call is stale and New note means a new meeting again.
    static let resumeWindow: TimeInterval = 10 * 60

    static func newNoteAction(
        isRecording: Bool,
        autoStoppedAt: Date?,
        now: Date,
        window: TimeInterval = resumeWindow
    ) -> NewNoteAction {
        if isRecording { return .stop }
        guard let autoStoppedAt, now.timeIntervalSince(autoStoppedAt) < window else { return .start }
        return .resume
    }

    /// The label capsule's two parts. The shortcut is drawn at weight 700.
    static func labelText(for control: DockControl, newNote action: NewNoteAction) -> (title: String, shortcut: String?) {
        switch control {
        case .dictate:
            return ("Dictate", "fn")
        case .newNote:
            switch action {
            case .start: return ("New note", "Opt+M")
            case .stop: return ("Stop", "Opt+M")
            case .resume: return ("Resume", "Opt+M")
            }
        case .scratchpad:
            return ("Quick note", nil)
        }
    }

    static func labelText(for control: DockControl, isRecording: Bool = false) -> (title: String, shortcut: String?) {
        labelText(for: control, newNote: isRecording ? .stop : .start)
    }

    /// The VoiceOver name for a control, which says what a click does.
    static func accessibilityLabel(for control: DockControl, newNote action: NewNoteAction) -> String {
        let label = labelText(for: control, newNote: action)
        guard let shortcut = label.shortcut else { return label.title }
        return "\(label.title), \(shortcut)"
    }

    static func accessibilityLabel(for control: DockControl, isRecording: Bool = false) -> String {
        accessibilityLabel(for: control, newNote: isRecording ? .stop : .start)
    }

    /// The recording timer, "12:04" under an hour and "1:02:04" past it.
    static func timerText(_ elapsed: TimeInterval) -> String {
        let total = Int(max(0, elapsed.rounded(.down)))
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// The capsule contents for a settled pill state, or nil when that state
    /// does not draw a text capsule.
    static func textCapsule(for state: PillState, workingNote: String?) -> FlowBarTextCapsule? {
        switch state {
        case .working:
            guard let workingNote, !workingNote.isEmpty else { return nil }
            return FlowBarTextCapsule(text: workingNote)
        case .inserted(let totalMS):
            return FlowBarTextCapsule(glyph: .check, mono: "\(Int(totalMS.rounded())) ms")
        case .guarded:
            return FlowBarTextCapsule(glyph: .warning, text: "Kept raw")
        case .error(let message):
            return FlowBarTextCapsule(glyph: .failure, text: message)
        case .notice(let message):
            return FlowBarTextCapsule(glyph: .check, text: message)
        case .idle, .listening, .recording, .meetingDetected:
            return nil
        }
    }

    // MARK: - Nudge words

    static let nudgeTitle = "Meeting detected"
    static let nudgeSubline = "No bot joins. Recording stays on this Mac."

    /// Why the card appeared. A native call app names itself. A browser names
    /// itself and the tab it is holding.
    ///
    /// The detector already worked out the platform and the browser, so this
    /// reads its answer rather than classifying the bundle id a second time.
    /// Two classifiers would eventually disagree, and the card would then
    /// name a different app from the one the detector is tracking.
    static func nudgeReason(for detected: DetectedMeeting) -> String {
        guard let browserName = detected.browserName else {
            return "\(detected.platform.displayName) is using the microphone."
        }
        return "\(browserName) is using the microphone and a \(detected.platform.displayName) tab is open."
    }

    /// The title Start note gives the capture: the platform name plus the
    /// window title, without repeating the platform when the title has it.
    static func startNoteTitle(for detected: DetectedMeeting) -> String {
        let platform = detected.platform
        let title = detected.suggestedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "\(platform.displayName) call" }
        guard platform != .unknown, !title.localizedCaseInsensitiveContains(platform.displayName) else { return title }
        return "\(platform.displayName) · \(title)"
    }

    // MARK: - Sizes

    /// Width of a text capsule holding `textWidth` points of message and
    /// `monoWidth` points of reading.
    static func textCapsuleWidth(glyph: FlowBarTextCapsule.Glyph, textWidth: CGFloat, monoWidth: CGFloat) -> CGFloat {
        var width = 2 * FlowBarMetrics.textCapsulePadding
        var pieces: [CGFloat] = []
        if glyph != .none { pieces.append(FlowBarMetrics.glyphSize) }
        if textWidth > 0 { pieces.append(textWidth) }
        if monoWidth > 0 { pieces.append(monoWidth) }
        width += pieces.reduce(0, +)
        if pieces.count > 1 {
            width += CGFloat(pieces.count - 1) * FlowBarMetrics.textCapsuleGap
        }
        return width
    }

    /// Width of a label capsule holding `textWidth` points of words.
    static func labelWidth(textWidth: CGFloat) -> CGFloat {
        textWidth + 2 * FlowBarMetrics.labelPadding
    }

    /// Width of the recording timer capsule.
    static func timerWidth(textWidth: CGFloat) -> CGFloat {
        textWidth + 2 * FlowBarMetrics.timerPadding
    }

    /// Maps a box that has to stay upright on screen, because it holds words,
    /// into this edge's depth and along extents. Without it a label capsule
    /// would stand on end on the top and bottom docks and the text would spill
    /// out of it.
    static func upright(width: CGFloat, height: CGFloat, edge: PillEdge) -> (deep: CGFloat, long: CGFloat) {
        edge.isHorizontal ? (deep: height, long: width) : (deep: width, long: height)
    }

    /// How far a control's centre sits from the centre of the stack, along
    /// the edge. Labels hang off that centre, so this decides how long the
    /// panel has to be to hold one.
    static func controlCentreOffset(_ control: DockControl) -> CGFloat {
        controlOffset(control) + controlAlong(control) / 2 - FlowBarMetrics.stackAlong / 2
    }

    /// How deep and how long the drawn capsule is for a view state. The
    /// dictation capsule is 40 by 120 along the edge. A text capsule keeps
    /// its words horizontal, so on a side dock it grows inward instead.
    static func capsuleBox(for state: FlowBarViewState, edge: PillEdge) -> (depth: CGFloat, along: CGFloat)? {
        switch state {
        case .level(_, let commandWidth):
            var depth = FlowBarMetrics.capsuleDepth
            var along = FlowBarMetrics.capsuleAlong
            if let commandWidth {
                let extra = commandWidth + 2 * FlowBarMetrics.textCapsuleGap
                if edge.isHorizontal { along += extra } else { depth += extra }
            }
            return (depth, along)
        case .spinner:
            return (FlowBarMetrics.capsuleDepth, FlowBarMetrics.capsuleAlong)
        case .text(_, let width):
            let box = upright(width: width, height: FlowBarMetrics.textCapsuleThickness, edge: edge)
            return (box.deep, box.long)
        case .nub, .stack, .recording, .nudge:
            return nil
        }
    }

    /// How deep the hovered control is drawn. New note grows toward the
    /// interior so the chevron has somewhere to appear.
    static func controlDepth(_ control: DockControl, hovered: DockControl?) -> CGFloat {
        guard control == .newNote, hovered == .newNote else { return FlowBarMetrics.controlSize }
        return FlowBarMetrics.newNoteHoverDepth
    }

    /// How long a control is along the edge.
    static func controlAlong(_ control: DockControl) -> CGFloat {
        control == .dictate ? FlowBarMetrics.micAlong : FlowBarMetrics.controlSize
    }

    /// Where a control starts along the edge, measured from the start of the
    /// stack.
    static func controlOffset(_ control: DockControl) -> CGFloat {
        var offset: CGFloat = 0
        for candidate in DockControl.allCases {
            if candidate == control { return offset }
            offset += controlAlong(candidate) + FlowBarMetrics.controlGap
        }
        return offset
    }

    /// The panel box for a view state: how far it reaches inward and how far
    /// it runs along the edge.
    static func panelBox(for state: FlowBarViewState, edge: PillEdge) -> (depth: CGFloat, along: CGFloat) {
        let slack = FlowBarMetrics.shadowSlack
        switch state {
        case .nub:
            return (FlowBarMetrics.nubHitDepth, FlowBarMetrics.nubHitAlong)
        case .stack(let hovered, let labelWidth):
            var depth = FlowBarMetrics.stackInset + FlowBarMetrics.controlSize
            var along = FlowBarMetrics.stackAlong + 2 * slack
            if let hovered {
                depth = FlowBarMetrics.stackInset + controlDepth(hovered, hovered: hovered)
                if labelWidth > 0 {
                    let label = upright(width: labelWidth, height: FlowBarMetrics.labelAlong, edge: edge)
                    depth += FlowBarMetrics.labelGap + label.deep
                    // The label centres on its control, not on the stack, so a
                    // long one hanging off the mic needs room at that end.
                    let offset = abs(controlCentreOffset(hovered))
                    along = max(along, 2 * (offset + label.long / 2 + slack))
                }
            }
            return (depth + slack, along)
        case .level, .spinner, .text:
            guard let box = capsuleBox(for: state, edge: edge) else {
                return (FlowBarMetrics.nubHitDepth, FlowBarMetrics.nubHitAlong)
            }
            return (FlowBarMetrics.stackInset + box.depth + slack, box.along + 2 * slack)
        case .recording(_, let hovered, let badgeWidth):
            let thickness = hovered ? FlowBarMetrics.labelAlong : FlowBarMetrics.timerThickness
            let badge = upright(width: badgeWidth, height: thickness, edge: edge)
            let depth = FlowBarMetrics.stackInset + FlowBarMetrics.controlSize
                + FlowBarMetrics.labelGap + badge.deep + slack
            return (depth, max(FlowBarMetrics.controlSize, badge.long) + 2 * slack)
        case .nudge:
            let cardDepth = edge.isHorizontal ? FlowBarMetrics.nudgeHeight : FlowBarMetrics.nudgeWidth
            let cardAlong = edge.isHorizontal ? FlowBarMetrics.nudgeWidth : FlowBarMetrics.nudgeHeight
            let depth = FlowBarMetrics.nubInset + FlowBarMetrics.nubThickness
                + FlowBarMetrics.nudgeGap + cardDepth + slack
            return (depth, max(FlowBarMetrics.nubHitAlong, cardAlong) + 2 * slack)
        }
    }

    /// The panel size for a view state on `edge`.
    static func panelSize(for state: FlowBarViewState, edge: PillEdge) -> CGSize {
        let box = panelBox(for: state, edge: edge)
        return DockAxis.size(edge: edge, depth: box.depth, along: box.along)
    }

    // MARK: - Rects

    static func nubRect(axis: DockAxis) -> CGRect {
        axis.centered(depth: FlowBarMetrics.nubInset, deep: FlowBarMetrics.nubThickness,
                      long: FlowBarMetrics.nubLength)
    }

    /// Where a control is drawn inside the panel.
    static func controlRect(_ control: DockControl, axis: DockAxis, hovered: DockControl?) -> CGRect {
        let start = (axis.alongExtent - FlowBarMetrics.stackAlong) / 2
        return axis.rect(
            depth: FlowBarMetrics.stackInset,
            deep: controlDepth(control, hovered: hovered),
            along: start + controlOffset(control),
            long: controlAlong(control)
        )
    }

    /// The control's drawn rect plus 4 points on every side.
    static func controlHitRect(_ control: DockControl, axis: DockAxis, hovered: DockControl?) -> CGRect {
        controlRect(control, axis: axis, hovered: hovered).insetBy(dx: -FlowBarMetrics.hitPadding,
                                                                  dy: -FlowBarMetrics.hitPadding)
    }

    /// The label capsule for a control, 12 points inward from it and centred
    /// on it. It always reads horizontally, whichever dock it is on.
    static func labelRect(_ control: DockControl, axis: DockAxis, hovered: DockControl?, width: CGFloat) -> CGRect {
        let controlRect = controlRect(control, axis: axis, hovered: hovered)
        let centre = centerAlong(of: controlRect, axis: axis)
        let depth = FlowBarMetrics.stackInset + controlDepth(hovered ?? control, hovered: hovered)
            + FlowBarMetrics.labelGap
        let box = upright(width: width, height: FlowBarMetrics.labelAlong, edge: axis.edge)
        return axis.rect(depth: depth, deep: box.deep, along: centre - box.long / 2, long: box.long)
    }

    static func capsuleRect(for state: FlowBarViewState, axis: DockAxis) -> CGRect? {
        guard let box = capsuleBox(for: state, edge: axis.edge) else { return nil }
        return axis.centered(depth: FlowBarMetrics.stackInset, deep: box.depth, long: box.along)
    }

    static func recordingControlRect(axis: DockAxis) -> CGRect {
        axis.centered(depth: FlowBarMetrics.stackInset, deep: FlowBarMetrics.controlSize,
                      long: FlowBarMetrics.controlSize)
    }

    /// The timer capsule, or the Stop label while the control is hovered.
    /// Both read horizontally on every dock.
    static func recordingBadgeRect(axis: DockAxis, hovered: Bool, width: CGFloat) -> CGRect {
        let thickness = hovered ? FlowBarMetrics.labelAlong : FlowBarMetrics.timerThickness
        let box = upright(width: width, height: thickness, edge: axis.edge)
        let depth = FlowBarMetrics.stackInset + FlowBarMetrics.controlSize + FlowBarMetrics.labelGap
        return axis.centered(depth: depth, deep: box.deep, long: box.long)
    }

    /// The nudge card. It is always 300 by 140 on screen, whichever edge the
    /// dock is on, so the words never turn sideways.
    static func nudgeRect(axis: DockAxis) -> CGRect {
        let cardDepth = axis.edge.isHorizontal ? FlowBarMetrics.nudgeHeight : FlowBarMetrics.nudgeWidth
        let cardAlong = axis.edge.isHorizontal ? FlowBarMetrics.nudgeWidth : FlowBarMetrics.nudgeHeight
        let depth = FlowBarMetrics.nubInset + FlowBarMetrics.nubThickness + FlowBarMetrics.nudgeGap
        return axis.centered(depth: depth, deep: cardDepth, long: cardAlong)
    }

    /// Ignore on the left, Start note on the right, along the card's bottom.
    static func nudgeButtonRects(card: CGRect) -> (ignore: CGRect, start: CGRect) {
        let padding = FlowBarMetrics.nudgePadding
        let width = (card.width - 2 * padding - FlowBarMetrics.nudgeButtonGap) / 2
        let y = card.minY + padding
        let ignore = CGRect(x: card.minX + padding, y: y, width: width, height: FlowBarMetrics.nudgeButtonHeight)
        let start = CGRect(x: ignore.maxX + FlowBarMetrics.nudgeButtonGap, y: y,
                           width: width, height: FlowBarMetrics.nudgeButtonHeight)
        return (ignore, start)
    }

    private static func centerAlong(of rect: CGRect, axis: DockAxis) -> CGFloat {
        switch axis.edge {
        case .left, .right:
            return axis.panelSize.height - rect.midY
        case .bottom, .top:
            return rect.midX
        }
    }

    // MARK: - Hit testing

    /// The control under `point`, in panel coordinates. Clicks in the gaps
    /// between controls hit nothing, but they stay inside the dock, so the
    /// hover region does not break.
    static func control(at point: CGPoint, axis: DockAxis, hovered: DockControl?) -> DockControl? {
        for control in DockControl.allCases where controlHitRect(control, axis: axis, hovered: hovered).contains(point) {
            return control
        }
        return nil
    }

    /// What a click on the nudge card does.
    enum NudgeAction: Equatable {
        case ignore
        case startNote
    }

    static func nudgeAction(at point: CGPoint, axis: DockAxis) -> NudgeAction? {
        let card = nudgeRect(axis: axis)
        guard card.contains(point) else { return nil }
        let buttons = nudgeButtonRects(card: card)
        if buttons.ignore.contains(point) { return .ignore }
        if buttons.start.contains(point) { return .startNote }
        return nil
    }
}

/// The open and close intent behind the hover. Opening waits 120 ms so a
/// pointer crossing the edge does not flash the dock. Closing waits 400 ms so
/// moving from a control to its label, or across the 8 point gap between two
/// controls, never collapses it.
struct DockHoverIntent: Equatable {
    enum Phase: Equatable {
        case closed
        case opening
        case open
        case closing
    }

    /// What the caller should do with its timers after an event.
    enum Effect: Equatable {
        case none
        case startOpenTimer
        case startCloseTimer
        case cancelTimers
        case didOpen
        case didClose
    }

    private(set) var phase: Phase = .closed

    /// True while the controls are drawn, which includes the close delay.
    var isOpen: Bool { phase == .open || phase == .closing }

    mutating func pointerEntered() -> Effect {
        switch phase {
        case .closed:
            phase = .opening
            return .startOpenTimer
        case .closing:
            phase = .open
            return .cancelTimers
        case .opening, .open:
            return .none
        }
    }

    mutating func pointerExited() -> Effect {
        switch phase {
        case .open:
            phase = .closing
            return .startCloseTimer
        case .opening:
            phase = .closed
            return .cancelTimers
        case .closed, .closing:
            return .none
        }
    }

    mutating func openTimerFired() -> Effect {
        guard phase == .opening else { return .none }
        phase = .open
        return .didOpen
    }

    mutating func closeTimerFired() -> Effect {
        guard phase == .closing else { return .none }
        phase = .closed
        return .didClose
    }

    /// Escape collapses the dock at once. It never stops a recording.
    mutating func escape() -> Effect {
        guard phase != .closed else { return .none }
        phase = .closed
        return .didClose
    }

    /// Used when the dock has to shut for a reason other than the pointer,
    /// such as dictation starting.
    mutating func forceClosed() -> Effect {
        escape()
    }
}

/// Text measurement shared by the panel controller, which sizes the window,
/// and the SwiftUI views, which draw inside it. One function so the two can
/// never disagree about how wide a capsule is.
enum FlowBarText {
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CGFloat] = [:]

    static func width(_ string: String, size: CGFloat, weight: NSFont.Weight, monospaced: Bool = false) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let key = "\(size)|\(weight.rawValue)|\(monospaced)|\(string)"
        cacheLock.lock()
        if let cached = cache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let font = monospaced
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        let measured = (string as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        cacheLock.lock()
        cache[key] = measured
        cacheLock.unlock()
        return measured
    }

    /// The width of a hover label's words, shortcut included.
    static func labelTextWidth(for control: DockControl, newNote action: FlowBarDock.NewNoteAction) -> CGFloat {
        let label = FlowBarDock.labelText(for: control, newNote: action)
        var width = width(label.title, size: FlowBarMetrics.labelFontSize, weight: .medium)
        if let shortcut = label.shortcut {
            width += FlowBarMetrics.labelShortcutGap
            width += self.width(shortcut, size: FlowBarMetrics.labelFontSize, weight: .bold)
        }
        return width
    }

    static func labelCapsuleWidth(for control: DockControl, newNote action: FlowBarDock.NewNoteAction) -> CGFloat {
        FlowBarDock.labelWidth(textWidth: labelTextWidth(for: control, newNote: action))
    }

    static func textCapsuleWidth(_ capsule: FlowBarTextCapsule) -> CGFloat {
        FlowBarDock.textCapsuleWidth(
            glyph: capsule.glyph,
            textWidth: width(capsule.text, size: FlowBarMetrics.textCapsuleFontSize, weight: .medium),
            monoWidth: width(capsule.mono ?? "", size: FlowBarMetrics.monoFontSize, weight: .medium, monospaced: true)
        )
    }

    static func timerCapsuleWidth(_ text: String) -> CGFloat {
        FlowBarDock.timerWidth(
            textWidth: width(text, size: FlowBarMetrics.monoFontSize, weight: .medium, monospaced: true)
        )
    }

    static let commandMarker = "Command"

    static func commandMarkerWidth() -> CGFloat {
        width(commandMarker, size: FlowBarMetrics.textCapsuleFontSize, weight: .medium)
    }
}
