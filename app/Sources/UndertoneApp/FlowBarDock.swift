import AppKit
import CoreGraphics
import Foundation

/// One of the three segments of the hover capsule. The order of `allCases`
/// is the order they sit in, left to right, on every dock.
enum DockControl: String, CaseIterable, Identifiable, Sendable {
    case dictate
    case newNote
    case scratchpad

    var id: String { rawValue }
}

/// What the dock draws right now. Hover is view state, not `PillState`, so
/// the model never has to know where the pointer is.
enum FlowBarViewState: Equatable {
    /// The rest state: one small nub at the edge with a status pinhole.
    case nub
    /// The three controls as one joined capsule, with the hovered segment
    /// lightened and labelled.
    case hover(DockControl?)
    /// The live ribbon: one 36 point capsule holding the pieces of a state.
    case ribbon(RibbonSpec)
    /// The meeting card, which the pill grows into.
    case nudge(DetectedMeeting)
}

/// A glyph drawn at the start of a ribbon.
enum RibbonGlyph: Equatable, Sendable {
    case check
    case warning
    case failure
    case lock
}

/// A pulsing status dot.
enum RibbonDot: Equatable, Sendable {
    /// Cyan, while you dictate.
    case listening
    /// Red, while a meeting records.
    case recording
}

/// A button inside the ribbon. Each one runs an action that already exists
/// elsewhere in the app, so the ribbon adds no new behavior of its own.
enum RibbonAction: Equatable, Sendable {
    /// Undo AI edit, the ⌥⇧Z path.
    case undo
    /// Opens the History row the 60% guard kept raw.
    case why
    /// Insert last again, the ⌥⇧V path.
    case insertAgain
    /// Stops meeting capture.
    case stop
    /// Undoes a word correction learning just added to the dictionary.
    case undoLearning

    var title: String {
        switch self {
        case .undo, .undoLearning: return "Undo"
        case .why: return "Why?"
        case .insertAgain: return "Insert again"
        case .stop: return ""
        }
    }

    var shortcut: String? {
        switch self {
        case .undo: return "⌥⇧Z"
        case .insertAgain: return "⌥⇧V"
        case .why, .stop, .undoLearning: return nil
        }
    }

    /// A solid light button. The others are ghost buttons.
    var isSolid: Bool { self == .insertAgain }

    var accessibilityLabel: String {
        switch self {
        case .undo: return "Undo AI edit, Option Shift Z"
        case .why: return "Why was the text kept raw"
        case .insertAgain: return "Insert again, Option Shift V"
        case .stop: return "Stop recording"
        case .undoLearning: return "Undo the learned word"
        }
    }
}

/// One piece of a ribbon, laid out left to right.
enum RibbonPiece: Equatable, Sendable {
    case dot(RibbonDot)
    /// The flowing waveform, driven by the real microphone level.
    case waveform
    case glyph(RibbonGlyph)
    case spinner
    case text(String)
    /// A monospaced reading. `reserve` is the widest text it will show, so a
    /// ticking clock does not resize the panel every second.
    case mono(String, reserve: String)
    /// The lavender Command chip.
    case commandChip
    case button(RibbonAction)
    /// The Me and Others meters of a meeting recording.
    case meters
}

/// Every size the ribbon is built from, in points, from the Direction A
/// mock-up.
enum RibbonMetrics {
    static let height: CGFloat = 36
    static let radius: CGFloat = 18
    /// From the docked edge to the ribbon.
    static let inset: CGFloat = 10
    static let gap: CGFloat = 10
    static let leadingPadding: CGFloat = 14
    /// A ribbon that ends in a chip or a button tucks it in closer.
    static let tightPadding: CGFloat = 6

    static let dot: CGFloat = 8
    static let glyph: CGFloat = 15
    static let spinner: CGFloat = 12
    static let textFont: CGFloat = 13
    static let monoFont: CGFloat = 12
    static let maxTextWidth: CGFloat = 300

    static let chipFont: CGFloat = 12
    static let commandPadding: CGFloat = 9
    static let commandHeight: CGFloat = 22

    static let buttonHeight: CGFloat = 24
    static let buttonPadding: CGFloat = 10
    static let buttonFont: CGFloat = 12
    static let keyFont: CGFloat = 11
    static let keyGap: CGFloat = 6
    static let stopButton: CGFloat = 24

    static let meterLabel: CGFloat = 18
    static let meterGap: CGFloat = 4
    static let meterTrack: CGFloat = 28

    // Hover capsule
    static let segmentWidths: [DockControl: CGFloat] = [.dictate: 40, .newNote: 36, .scratchpad: 36]
    static let segmentHeight: CGFloat = 28
    static let segmentGap: CGFloat = 2
    static let capsulePadding: CGFloat = 4
    static let labelHeight: CGFloat = 26
    static let labelPadding: CGFloat = 12
    static let labelGap: CGFloat = 8
    static let labelFont: CGFloat = 12
    static let labelKeyGap: CGFloat = 8

    // Meeting card
    static let cardWidth: CGFloat = 236
    static let cardHeight: CGFloat = 92
    static let cardRadius: CGFloat = 14
    static let cardPadding: CGFloat = 12
    static let cardButtonGap: CGFloat = 6
}

/// A ribbon's pieces and the padding around them. Widths come from one
/// function, so the panel the controller sizes and the capsule the view draws
/// can never disagree.
struct RibbonSpec: Equatable, Sendable {
    let pieces: [RibbonPiece]

    init(_ pieces: [RibbonPiece]) {
        self.pieces = pieces
    }

    var leadingPadding: CGFloat { RibbonMetrics.leadingPadding }

    var trailingPadding: CGFloat {
        switch pieces.last {
        case .commandChip, .button: return RibbonMetrics.tightPadding
        default: return RibbonMetrics.leadingPadding
        }
    }

    var width: CGFloat {
        let content = pieces.map(Self.width(of:)).reduce(0, +)
        let gaps = CGFloat(max(0, pieces.count - 1)) * RibbonMetrics.gap
        return leadingPadding + content + gaps + trailingPadding
    }

    var size: CGSize { CGSize(width: width, height: RibbonMetrics.height) }

    /// Each piece's frame inside a ribbon whose origin is (0, 0), left to right.
    var pieceFrames: [CGRect] {
        var x = leadingPadding
        return pieces.map { piece in
            let width = Self.width(of: piece)
            let height = Self.height(of: piece)
            let frame = CGRect(x: x, y: (RibbonMetrics.height - height) / 2, width: width, height: height)
            x += width + RibbonMetrics.gap
            return frame
        }
    }

    /// The button under `point`, given in the ribbon's own coordinates.
    func action(at point: CGPoint) -> RibbonAction? {
        for (piece, frame) in zip(pieces, pieceFrames) {
            guard case .button(let action) = piece else { continue }
            if frame.insetBy(dx: -4, dy: -6).contains(point) { return action }
        }
        return nil
    }

    static func width(of piece: RibbonPiece) -> CGFloat {
        switch piece {
        case .dot: return RibbonMetrics.dot
        case .waveform: return FlowingWaveform.blockLength
        case .glyph(let glyph): return glyph == .lock ? 12 : RibbonMetrics.glyph
        case .spinner: return RibbonMetrics.spinner
        case .text(let text):
            return min(RibbonMetrics.maxTextWidth,
                       FlowBarText.width(text, size: RibbonMetrics.textFont, weight: .medium))
        case .mono(let text, let reserve):
            return max(FlowBarText.width(text, size: RibbonMetrics.monoFont, weight: .medium, monospaced: true),
                       FlowBarText.width(reserve, size: RibbonMetrics.monoFont, weight: .medium, monospaced: true))
        case .commandChip:
            return FlowBarText.width(FlowBarText.commandMarker, size: RibbonMetrics.chipFont, weight: .semibold)
                + 2 * RibbonMetrics.commandPadding
        case .button(let action):
            guard action != .stop else { return RibbonMetrics.stopButton }
            var width = FlowBarText.width(action.title, size: RibbonMetrics.buttonFont, weight: .semibold)
            if let shortcut = action.shortcut {
                width += RibbonMetrics.keyGap
                width += FlowBarText.width(shortcut, size: RibbonMetrics.keyFont, weight: .regular, monospaced: true)
            }
            return width + 2 * RibbonMetrics.buttonPadding
        case .meters:
            return RibbonMetrics.meterLabel + RibbonMetrics.meterGap + RibbonMetrics.meterTrack
        }
    }

    static func height(of piece: RibbonPiece) -> CGFloat {
        switch piece {
        case .commandChip: return RibbonMetrics.commandHeight
        case .button: return RibbonMetrics.buttonHeight
        default: return RibbonMetrics.height
        }
    }
}

/// Every size and duration the dock is built from that is not ribbon
/// geometry: the nub, the drag zones, the hover timing, and the holds.
enum FlowBarMetrics {
    // Nub
    static let nubLength: CGFloat = 44
    static let nubThickness: CGFloat = 6
    static let nubRadius: CGFloat = 3
    static let nubInset: CGFloat = 6
    static let nubDot: CGFloat = 4
    /// The nub is too thin to aim at, so the panel covers 48 along the edge
    /// by 44 inward, the same trick the Dock uses.
    static let nubHitAlong: CGFloat = 48
    static let nubHitDepth: CGFloat = 44
    static let hitPadding: CGFloat = 4

    /// Room around the drawn content so the shadow is not clipped by the
    /// panel edge.
    static let shadowSlack: CGFloat = 12

    // Timing
    static let hoverOpenDelay: TimeInterval = 0.120
    static let hoverCloseDelay: TimeInterval = 0.400
    static let fanOutDuration: TimeInterval = 0.220
    static let collapseDuration: TimeInterval = 0.160
    static let nubFadeDuration: TimeInterval = 0.140
    static let labelFadeDuration: TimeInterval = 0.140
    static let reducedMotionFade: TimeInterval = 0.120
    static let pulsePeriod: TimeInterval = 1.2

    // Holds. A hovered ribbon stays up past these until the pointer leaves.
    static let insertedHold: Duration = .seconds(2)
    static let guardedHold: Duration = .seconds(3)
    static let errorHold: Duration = .seconds(4)
    static let transientHold: Duration = .milliseconds(1800)
    static let learningHold: Duration = .seconds(6)
    static let savedHold: Duration = .milliseconds(1200)
    static let meetingEndedHold: Duration = .seconds(3)
    static let nudgeAutoDismiss: TimeInterval = 20

    /// The hold for a settled state. `AppModel.hold(for:)` owns the rule.
    static func transientHold(for state: PillState) -> Duration {
        AppModel.hold(for: state)
    }
}

/// Panel-local geometry for the nub. `depth` measures inward from the docked
/// edge and `along` measures along it, so one set of numbers describes all
/// four docks.
struct DockAxis: Equatable {
    let edge: PillEdge
    let panelSize: CGSize

    init(edge: PillEdge, panelSize: CGSize) {
        self.edge = edge
        self.panelSize = panelSize
    }

    static func size(edge: PillEdge, depth: CGFloat, along: CGFloat) -> CGSize {
        edge.isHorizontal ? CGSize(width: along, height: depth) : CGSize(width: depth, height: along)
    }

    var alongExtent: CGFloat { edge.isHorizontal ? panelSize.width : panelSize.height }

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

    func centered(depth: CGFloat, deep: CGFloat, long: CGFloat) -> CGRect {
        rect(depth: depth, deep: deep, along: (alongExtent - long) / 2, long: long)
    }
}

/// Where horizontal content sits in the panel on each dock. The ribbon never
/// turns: on the top and bottom docks it runs along the edge, and on the side
/// docks it grows inward from the edge, still reading left to right.
enum RibbonLayout {
    /// The panel that holds `content` on `edge`. `labelRoom` is extra space on
    /// the interior side (above on the side docks too) for the hover label.
    static func panelSize(content: CGSize, edge: PillEdge, labelRoom: CGFloat = 0) -> CGSize {
        let slack = FlowBarMetrics.shadowSlack
        switch edge {
        case .bottom, .top:
            return CGSize(width: content.width + 2 * slack,
                          height: RibbonMetrics.inset + content.height + labelRoom + slack)
        case .left, .right:
            return CGSize(width: RibbonMetrics.inset + content.width + slack,
                          height: content.height + 2 * (slack + labelRoom))
        }
    }

    /// The content rect in the panel's AppKit (bottom-left origin) space.
    static func contentRect(content: CGSize, edge: PillEdge, panelSize: CGSize) -> CGRect {
        let origin: CGPoint
        switch edge {
        case .bottom:
            origin = CGPoint(x: (panelSize.width - content.width) / 2, y: RibbonMetrics.inset)
        case .top:
            origin = CGPoint(x: (panelSize.width - content.width) / 2,
                             y: panelSize.height - RibbonMetrics.inset - content.height)
        case .left:
            origin = CGPoint(x: RibbonMetrics.inset, y: (panelSize.height - content.height) / 2)
        case .right:
            origin = CGPoint(x: panelSize.width - RibbonMetrics.inset - content.width,
                             y: (panelSize.height - content.height) / 2)
        }
        return CGRect(origin: origin, size: content)
    }
}

/// Pure layout for the dock: panel sizes, rects, hit testing, and the words
/// on every label. No AppKit state, so it is all unit testable.
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

    /// The hover label's two parts: the name, then the key in mono.
    static func labelText(for control: DockControl, newNote action: NewNoteAction) -> (title: String, shortcut: String?) {
        switch control {
        case .dictate:
            return ("Dictate", "hold fn")
        case .newNote:
            switch action {
            case .start: return ("New note", "⌥M")
            case .stop: return ("Stop", "⌥M")
            case .resume: return ("Resume", "⌥M")
            }
        case .scratchpad:
            return ("Quick note", "⌥S")
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

    // MARK: - Nudge words

    static let nudgeTitle = "Meeting detected"

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

    // MARK: - What each state draws

    /// Everything a ribbon reads, gathered so the choice of pieces can be
    /// tested without an `AppModel`, a screen, or an engine.
    struct RibbonInputs: Equatable {
        var pillState: PillState
        var locked = false
        var commandMode = false
        var workingNote: String?
        /// The cleanup model for the current level, such as "qwen3.5".
        var workingModel: String?
        var canUndo = false
        var canExplainGuard = false
        var errorOffersRetry = false
        /// A learned word can still be undone from its notice.
        var canUndoLearning = false
    }

    static let cleaningText = "Cleaning"

    /// The ribbon for a state, or nil for the states that draw the nub, the
    /// hover capsule, or the meeting card instead.
    static func ribbon(for inputs: RibbonInputs) -> RibbonSpec? {
        switch inputs.pillState {
        case .idle, .meetingDetected:
            return nil
        case .listening:
            // Only the signal that you are being heard: the dot or the
            // Command chip, a lock glyph when locked, and the waveform.
            var pieces: [RibbonPiece] = [inputs.commandMode ? .commandChip : .dot(.listening)]
            if inputs.locked { pieces.append(.glyph(.lock)) }
            pieces.append(.waveform)
            return RibbonSpec(pieces)
        case .working:
            var pieces: [RibbonPiece] = [.spinner, .text(inputs.workingNote ?? cleaningText)]
            if inputs.workingNote == nil, let model = inputs.workingModel, !model.isEmpty {
                pieces.append(.mono(model, reserve: model))
            }
            return RibbonSpec(pieces)
        case .inserted(let totalMS):
            let reading = "\(Int(totalMS.rounded())) ms"
            var pieces: [RibbonPiece] = [.glyph(.check), .mono(reading, reserve: reading)]
            if inputs.canUndo { pieces.append(.button(.undo)) }
            return RibbonSpec(pieces)
        case .guarded:
            var pieces: [RibbonPiece] = [.glyph(.warning), .text("Kept raw")]
            if inputs.canExplainGuard { pieces.append(.button(.why)) }
            return RibbonSpec(pieces)
        case .error(let message):
            var pieces: [RibbonPiece] = [.glyph(.failure), .text(message)]
            if inputs.errorOffersRetry { pieces.append(.button(.insertAgain)) }
            return RibbonSpec(pieces)
        case .notice(let message):
            // "Learned Qwen · Undo" becomes words plus a real Undo button.
            if AppModel.isLearningNoticeText(message) {
                let words = String(message.dropLast(" · Undo".count))
                var pieces: [RibbonPiece] = [.glyph(.check), .text(words)]
                if inputs.canUndoLearning { pieces.append(.button(.undoLearning)) }
                return RibbonSpec(pieces)
            }
            return RibbonSpec([.glyph(.check), .text(message)])
        case .recording(let elapsed):
            let timer = timerText(elapsed)
            return RibbonSpec([.dot(.recording), .mono(timer, reserve: zeroed(timer)), .meters, .button(.stop)])
        }
    }

    /// "12:04" with every digit made a zero: the widest a timer of that shape
    /// draws, so the panel resizes only when an hour field appears.
    static func zeroed(_ text: String) -> String {
        String(text.map { $0.isNumber ? "0" : $0 })
    }

    // MARK: - Hover capsule

    static var capsuleWidth: CGFloat {
        let segments = DockControl.allCases.compactMap { RibbonMetrics.segmentWidths[$0] }.reduce(0, +)
        let gaps = CGFloat(DockControl.allCases.count - 1) * RibbonMetrics.segmentGap
        return 2 * RibbonMetrics.capsulePadding + segments + gaps
    }

    /// A segment's frame inside a capsule whose origin is (0, 0).
    static func segmentFrame(_ control: DockControl) -> CGRect {
        var x = RibbonMetrics.capsulePadding
        for candidate in DockControl.allCases {
            let width = RibbonMetrics.segmentWidths[candidate] ?? 0
            if candidate == control {
                return CGRect(x: x, y: (RibbonMetrics.height - RibbonMetrics.segmentHeight) / 2,
                              width: width, height: RibbonMetrics.segmentHeight)
            }
            x += width + RibbonMetrics.segmentGap
        }
        return .zero
    }

    /// The label capsule's width for a control.
    static func labelWidth(for control: DockControl, newNote action: NewNoteAction) -> CGFloat {
        FlowBarText.labelTextWidth(for: control, newNote: action) + 2 * RibbonMetrics.labelPadding
    }

    /// The hover content: the capsule centered, widened when the hovered
    /// label hangs past either end of it.
    static func hoverContentSize(hovered: DockControl?, newNote action: NewNoteAction) -> CGSize {
        guard let hovered else { return CGSize(width: capsuleWidth, height: RibbonMetrics.height) }
        let offset = abs(segmentFrame(hovered).midX - capsuleWidth / 2)
        let width = max(capsuleWidth, 2 * (offset + labelWidth(for: hovered, newNote: action) / 2))
        return CGSize(width: width, height: RibbonMetrics.height)
    }

    static func labelRoom(hovered: DockControl?) -> CGFloat {
        hovered == nil ? 0 : RibbonMetrics.labelGap + RibbonMetrics.labelHeight
    }

    /// The capsule in panel coordinates.
    static func capsuleRect(hovered: DockControl?, newNote action: NewNoteAction,
                            edge: PillEdge, panelSize: CGSize) -> CGRect {
        let content = RibbonLayout.contentRect(
            content: hoverContentSize(hovered: hovered, newNote: action), edge: edge, panelSize: panelSize
        )
        return CGRect(x: content.midX - capsuleWidth / 2, y: content.minY,
                      width: capsuleWidth, height: RibbonMetrics.height)
    }

    /// A segment in panel coordinates.
    static func segmentRect(_ control: DockControl, hovered: DockControl?, newNote action: NewNoteAction,
                            edge: PillEdge, panelSize: CGSize) -> CGRect {
        let capsule = capsuleRect(hovered: hovered, newNote: action, edge: edge, panelSize: panelSize)
        return segmentFrame(control).offsetBy(dx: capsule.minX, dy: capsule.minY)
    }

    /// The hovered segment's label: centred on it, above the capsule, or
    /// below it on the top dock where above is off screen.
    static func labelRect(_ control: DockControl, newNote action: NewNoteAction,
                          edge: PillEdge, panelSize: CGSize) -> CGRect {
        let capsule = capsuleRect(hovered: control, newNote: action, edge: edge, panelSize: panelSize)
        let segment = segmentFrame(control).offsetBy(dx: capsule.minX, dy: capsule.minY)
        let width = labelWidth(for: control, newNote: action)
        let y = edge == .top
            ? capsule.minY - RibbonMetrics.labelGap - RibbonMetrics.labelHeight
            : capsule.maxY + RibbonMetrics.labelGap
        return CGRect(x: segment.midX - width / 2, y: y, width: width, height: RibbonMetrics.labelHeight)
    }

    /// The segment under `point`. Each segment owns the full capsule height
    /// and half of each gap, so there is no dead strip between them.
    static func control(at point: CGPoint, hovered: DockControl?, newNote action: NewNoteAction,
                        edge: PillEdge, panelSize: CGSize) -> DockControl? {
        let capsule = capsuleRect(hovered: hovered, newNote: action, edge: edge, panelSize: panelSize)
        let hitArea = capsule.insetBy(dx: -FlowBarMetrics.hitPadding, dy: -FlowBarMetrics.hitPadding)
        guard hitArea.contains(point) else { return nil }
        let localX = point.x - capsule.minX
        for control in DockControl.allCases {
            let frame = segmentFrame(control)
            let half = RibbonMetrics.segmentGap / 2
            let isFirst = control == DockControl.allCases.first
            let isLast = control == DockControl.allCases.last
            let minX = isFirst ? -.infinity : frame.minX - half
            let maxX = isLast ? .infinity : frame.maxX + half
            if localX >= minX, localX < maxX { return control }
        }
        return nil
    }

    // MARK: - Panel

    /// The panel size for a view state on `edge`.
    static func panelSize(for state: FlowBarViewState, edge: PillEdge,
                          newNote action: NewNoteAction = .start) -> CGSize {
        switch state {
        case .nub:
            return DockAxis.size(edge: edge, depth: FlowBarMetrics.nubHitDepth, along: FlowBarMetrics.nubHitAlong)
        case .hover(let hovered):
            return RibbonLayout.panelSize(content: hoverContentSize(hovered: hovered, newNote: action),
                                          edge: edge, labelRoom: labelRoom(hovered: hovered))
        case .ribbon(let spec):
            return RibbonLayout.panelSize(content: spec.size, edge: edge)
        case .nudge:
            return RibbonLayout.panelSize(content: cardSize, edge: edge)
        }
    }

    static func nubRect(edge: PillEdge, panelSize: CGSize) -> CGRect {
        DockAxis(edge: edge, panelSize: panelSize).centered(
            depth: FlowBarMetrics.nubInset, deep: FlowBarMetrics.nubThickness, long: FlowBarMetrics.nubLength
        )
    }

    static func ribbonRect(_ spec: RibbonSpec, edge: PillEdge, panelSize: CGSize) -> CGRect {
        RibbonLayout.contentRect(content: spec.size, edge: edge, panelSize: panelSize)
    }

    /// The ribbon button under `point`, in panel coordinates.
    static func ribbonAction(at point: CGPoint, spec: RibbonSpec, edge: PillEdge, panelSize: CGSize) -> RibbonAction? {
        let rect = ribbonRect(spec, edge: edge, panelSize: panelSize)
        // Piece frames run top-down inside the ribbon; AppKit runs bottom-up.
        let local = CGPoint(x: point.x - rect.minX, y: rect.maxY - point.y)
        return spec.action(at: local)
    }

    // MARK: - Meeting card

    static var cardSize: CGSize { CGSize(width: RibbonMetrics.cardWidth, height: RibbonMetrics.cardHeight) }

    static func cardRect(edge: PillEdge, panelSize: CGSize) -> CGRect {
        RibbonLayout.contentRect(content: cardSize, edge: edge, panelSize: panelSize)
    }

    /// Not now on the left, Start notes on the right, along the card's bottom.
    static func cardButtonRects(card: CGRect) -> (notNow: CGRect, start: CGRect) {
        let padding = RibbonMetrics.cardPadding
        let width = (card.width - 2 * padding - RibbonMetrics.cardButtonGap) / 2
        let y = card.minY + padding
        let notNow = CGRect(x: card.minX + padding, y: y, width: width, height: RibbonMetrics.buttonHeight)
        let start = CGRect(x: notNow.maxX + RibbonMetrics.cardButtonGap, y: y,
                           width: width, height: RibbonMetrics.buttonHeight)
        return (notNow, start)
    }

    /// What a click on the meeting card does.
    enum NudgeAction: Equatable {
        case ignore
        case startNote
    }

    static func nudgeAction(at point: CGPoint, edge: PillEdge, panelSize: CGSize) -> NudgeAction? {
        let card = cardRect(edge: edge, panelSize: panelSize)
        guard card.contains(point) else { return nil }
        let buttons = cardButtonRects(card: card)
        if buttons.notNow.insetBy(dx: -2, dy: -4).contains(point) { return .ignore }
        if buttons.start.insetBy(dx: -2, dy: -4).contains(point) { return .startNote }
        return nil
    }

    /// The card's title: "Zoom call", or "Meet in Chrome" for a browser tab.
    static func cardTitle(for detected: DetectedMeeting) -> String {
        guard let browser = detected.browserName else { return "\(detected.platform.displayName) call" }
        return "\(detected.platform.displayName) in \(browser)"
    }

    static let cardQuestion = "Take notes on this Mac?"
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
/// never disagree about how wide a piece is.
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
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        let measured = (string as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        cacheLock.lock()
        cache[key] = measured
        cacheLock.unlock()
        return measured
    }

    /// The width of a hover label's words, key included.
    static func labelTextWidth(for control: DockControl, newNote action: FlowBarDock.NewNoteAction) -> CGFloat {
        let label = FlowBarDock.labelText(for: control, newNote: action)
        var width = width(label.title, size: RibbonMetrics.labelFont, weight: .medium)
        if let shortcut = label.shortcut {
            width += RibbonMetrics.labelKeyGap
            width += self.width(shortcut, size: RibbonMetrics.keyFont, weight: .bold, monospaced: true)
        }
        return width
    }

    static let commandMarker = "Command"
}
