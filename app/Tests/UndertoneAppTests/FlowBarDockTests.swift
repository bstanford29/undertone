import XCTest
import CoreGraphics
@testable import UndertoneApp

// MARK: - Hover intent

final class DockHoverIntentTests: XCTestCase {
    func testAFreshDockIsClosed() {
        let intent = DockHoverIntent()
        XCTAssertEqual(intent.phase, .closed)
        XCTAssertFalse(intent.isOpen)
    }

    func testEnteringStartsTheOpenDelayAndOnlyTheTimerOpensIt() {
        var intent = DockHoverIntent()
        XCTAssertEqual(intent.pointerEntered(), .startOpenTimer)
        XCTAssertEqual(intent.phase, .opening)
        XCTAssertFalse(intent.isOpen)
        XCTAssertEqual(intent.openTimerFired(), .didOpen)
        XCTAssertTrue(intent.isOpen)
    }

    func testLeavingBeforeTheOpenDelayNeverOpensTheDock() {
        var intent = DockHoverIntent()
        _ = intent.pointerEntered()
        XCTAssertEqual(intent.pointerExited(), .cancelTimers)
        XCTAssertEqual(intent.phase, .closed)
        // A timer that fires after the pointer left must do nothing.
        XCTAssertEqual(intent.openTimerFired(), .none)
        XCTAssertFalse(intent.isOpen)
    }

    func testTheDockStaysDrawnThroughTheCloseDelay() {
        var intent = openDock()
        XCTAssertEqual(intent.pointerExited(), .startCloseTimer)
        XCTAssertEqual(intent.phase, .closing)
        XCTAssertTrue(intent.isOpen, "Leaving a control must not collapse the dock before the delay")
        XCTAssertEqual(intent.closeTimerFired(), .didClose)
        XCTAssertFalse(intent.isOpen)
    }

    func testComingBackDuringTheCloseDelayReopensWithoutAnotherWait() {
        var intent = openDock()
        _ = intent.pointerExited()
        XCTAssertEqual(intent.pointerEntered(), .cancelTimers)
        XCTAssertEqual(intent.phase, .open)
        XCTAssertTrue(intent.isOpen)
    }

    func testACloseTimerFromAnEarlierPassIsIgnoredOnceReopened() {
        var intent = openDock()
        _ = intent.pointerExited()
        _ = intent.pointerEntered()
        XCTAssertEqual(intent.closeTimerFired(), .none)
        XCTAssertTrue(intent.isOpen)
    }

    func testMovingWithinTheDockChangesNothing() {
        var intent = openDock()
        XCTAssertEqual(intent.pointerEntered(), .none)
        XCTAssertEqual(intent.phase, .open)
    }

    func testEscapeCollapsesTheDockAtOnce() {
        var intent = openDock()
        XCTAssertEqual(intent.escape(), .didClose)
        XCTAssertFalse(intent.isOpen)
        XCTAssertEqual(intent.escape(), .none, "Escape on a closed dock does nothing")
    }

    func testEscapeAlsoCancelsAnOpenThatHasNotLandedYet() {
        var intent = DockHoverIntent()
        _ = intent.pointerEntered()
        XCTAssertEqual(intent.escape(), .didClose)
        XCTAssertEqual(intent.phase, .closed)
    }

    func testTheDelaysMatchTheSpec() {
        XCTAssertEqual(FlowBarMetrics.hoverOpenDelay, 0.120, accuracy: 0.0001)
        XCTAssertEqual(FlowBarMetrics.hoverCloseDelay, 0.400, accuracy: 0.0001)
    }

    private func openDock() -> DockHoverIntent {
        var intent = DockHoverIntent()
        _ = intent.pointerEntered()
        _ = intent.openTimerFired()
        return intent
    }
}

// MARK: - Words

final class FlowBarLabelTests: XCTestCase {
    func testLabelTextPerControl() {
        let dictate = FlowBarDock.labelText(for: .dictate, isRecording: false)
        XCTAssertEqual(dictate.title, "Dictate")
        XCTAssertEqual(dictate.shortcut, "hold fn")

        let newNote = FlowBarDock.labelText(for: .newNote, isRecording: false)
        XCTAssertEqual(newNote.title, "New note")
        XCTAssertEqual(newNote.shortcut, "⌥M")

        let scratchpad = FlowBarDock.labelText(for: .scratchpad, isRecording: false)
        XCTAssertEqual(scratchpad.title, "Quick note")
        XCTAssertEqual(scratchpad.shortcut, "⌥S")
    }

    func testNewNoteBecomesStopWhileRecording() {
        let recording = FlowBarDock.labelText(for: .newNote, isRecording: true)
        XCTAssertEqual(recording.title, "Stop")
        XCTAssertEqual(recording.shortcut, "⌥M")
    }

    func testRecordingNeverRenamesTheOtherTwoControls() {
        XCTAssertEqual(FlowBarDock.labelText(for: .dictate, isRecording: true).title, "Dictate")
        XCTAssertEqual(FlowBarDock.labelText(for: .scratchpad, isRecording: true).title, "Quick note")
    }

    func testAccessibilityLabelNamesTheShortcut() {
        XCTAssertEqual(FlowBarDock.accessibilityLabel(for: .dictate), "Dictate, hold fn")
        XCTAssertEqual(FlowBarDock.accessibilityLabel(for: .newNote, isRecording: true), "Stop, ⌥M")
        XCTAssertEqual(FlowBarDock.accessibilityLabel(for: .scratchpad), "Quick note, ⌥S")
    }

    func testNoLabelUsesAnEmDash() {
        for control in DockControl.allCases {
            for recording in [true, false] {
                let label = FlowBarDock.labelText(for: control, isRecording: recording)
                XCTAssertFalse(label.title.contains("\u{2014}"))
                XCTAssertFalse((label.shortcut ?? "").contains("\u{2014}"))
            }
        }
    }

    func testNewNoteOffersResumeOnlyInsideTheWindowAfterAnAutoStop() {
        let now = Date()
        XCTAssertEqual(FlowBarDock.newNoteAction(isRecording: false, autoStoppedAt: nil, now: now), .start)
        XCTAssertEqual(
            FlowBarDock.newNoteAction(isRecording: false, autoStoppedAt: now.addingTimeInterval(-60), now: now),
            .resume
        )
        XCTAssertEqual(
            FlowBarDock.newNoteAction(isRecording: false, autoStoppedAt: now.addingTimeInterval(-11 * 60), now: now),
            .start,
            "Past the window the call is stale and New note means a new meeting"
        )
    }

    func testRecordingBeatsAPendingResume() {
        let now = Date()
        XCTAssertEqual(
            FlowBarDock.newNoteAction(isRecording: true, autoStoppedAt: now.addingTimeInterval(-60), now: now),
            .stop
        )
    }

    func testTheResumeWindowEndsAtTenMinutes() {
        let now = Date()
        XCTAssertEqual(FlowBarDock.resumeWindow, 10 * 60, accuracy: 0.0001)
        let justInside = now.addingTimeInterval(-FlowBarDock.resumeWindow + 1)
        XCTAssertEqual(FlowBarDock.newNoteAction(isRecording: false, autoStoppedAt: justInside, now: now), .resume)
        let onTheEdge = now.addingTimeInterval(-FlowBarDock.resumeWindow)
        XCTAssertEqual(FlowBarDock.newNoteAction(isRecording: false, autoStoppedAt: onTheEdge, now: now), .start)
    }

    func testTheLabelSaysWhatTheNextClickDoes() {
        XCTAssertEqual(FlowBarDock.labelText(for: .newNote, newNote: .start).title, "New note")
        XCTAssertEqual(FlowBarDock.labelText(for: .newNote, newNote: .stop).title, "Stop")
        XCTAssertEqual(FlowBarDock.labelText(for: .newNote, newNote: .resume).title, "Resume")
        for action in [FlowBarDock.NewNoteAction.start, .stop, .resume] {
            XCTAssertEqual(FlowBarDock.labelText(for: .newNote, newNote: action).shortcut, "⌥M")
        }
    }

    func testResumeNeverRenamesTheOtherControls() {
        XCTAssertEqual(FlowBarDock.labelText(for: .dictate, newNote: .resume).title, "Dictate")
        XCTAssertEqual(FlowBarDock.labelText(for: .scratchpad, newNote: .resume).title, "Quick note")
    }

    func testResumeReachesVoiceOverToo() {
        XCTAssertEqual(FlowBarDock.accessibilityLabel(for: .newNote, newNote: .resume), "Resume, ⌥M")
    }

    func testTimerReadsMinutesAndSeconds() {
        XCTAssertEqual(FlowBarDock.timerText(0), "0:00")
        XCTAssertEqual(FlowBarDock.timerText(9), "0:09")
        XCTAssertEqual(FlowBarDock.timerText(12 * 60 + 4), "12:04")
        XCTAssertEqual(FlowBarDock.timerText(59.9), "0:59")
    }

    func testTimerGrowsAnHourFieldOnlyWhenItNeedsOne() {
        XCTAssertEqual(FlowBarDock.timerText(3600), "1:00:00")
        XCTAssertEqual(FlowBarDock.timerText(3661), "1:01:01")
        XCTAssertEqual(FlowBarDock.timerText(-5), "0:00")
    }
}

// MARK: - What each state draws

final class RibbonContentTests: XCTestCase {
    private func ribbon(_ state: PillState, _ configure: (inout FlowBarDock.RibbonInputs) -> Void = { _ in }) -> RibbonSpec? {
        var inputs = FlowBarDock.RibbonInputs(pillState: state)
        configure(&inputs)
        return FlowBarDock.ribbon(for: inputs)
    }

    func testIdleAndTheMeetingCardDrawNoRibbon() {
        XCTAssertNil(ribbon(.idle))
        XCTAssertNil(ribbon(.meetingDetected(PreviewFixtures.detectedZoom)))
    }

    func testListeningIsOnlyTheDotAndTheWaveform() {
        XCTAssertEqual(ribbon(.listening(level: 0.4))?.pieces, [.dot(.listening), .waveform])
    }

    func testListeningShowsNoWordsAndNoAppName() {
        let pieces = ribbon(.listening(level: 0.4))?.pieces ?? []
        XCTAssertFalse(pieces.contains { if case .text = $0 { return true } else { return false } })
        XCTAssertFalse(pieces.contains { if case .mono = $0 { return true } else { return false } })
    }

    func testTheListeningCapsuleIsSizedToItsContent() {
        let spec = ribbon(.listening(level: 0.4))!
        XCTAssertEqual(spec.width, 14 + RibbonMetrics.dot + 10 + FlowingWaveform.blockLength + 14)
    }

    func testLockedAddsOnlyASmallLock() {
        let spec = ribbon(.listening(level: 0.4)) { $0.locked = true }
        XCTAssertEqual(spec?.pieces, [.dot(.listening), .glyph(.lock), .waveform])
    }

    func testCommandModeKeepsOnlyTheCommandChipAndTheWaveform() {
        XCTAssertEqual(ribbon(.listening(level: 0.4)) { $0.commandMode = true }?.pieces, [.commandChip, .waveform])
        XCTAssertEqual(ribbon(.listening(level: 0.4)) {
            $0.commandMode = true
            $0.locked = true
        }?.pieces, [.commandChip, .glyph(.lock), .waveform])
    }

    func testWorkingSaysCleaningAndNamesTheModel() {
        let spec = ribbon(.working) { $0.workingModel = "qwen3.5" }
        XCTAssertEqual(spec?.pieces, [.spinner, .text("Cleaning"), .mono("qwen3.5", reserve: "qwen3.5")])
    }

    func testAWorkingNoteReplacesCleaningAndDropsTheModel() {
        let spec = ribbon(.working) {
            $0.workingModel = "qwen3.5"
            $0.workingNote = "Release fn to insert"
        }
        XCTAssertEqual(spec?.pieces, [.spinner, .text("Release fn to insert")])
    }

    func testInsertedShowsTheReadingAndUndoOnlyWhenThereIsSomethingToUndo() {
        XCTAssertEqual(ribbon(.inserted(totalMS: 742.4)) { $0.canUndo = true }?.pieces,
                       [.glyph(.check), .mono("742 ms", reserve: "742 ms"), .button(.undo)])
        XCTAssertEqual(ribbon(.inserted(totalMS: 742.4))?.pieces,
                       [.glyph(.check), .mono("742 ms", reserve: "742 ms")])
    }

    func testKeptRawOffersWhy() {
        XCTAssertEqual(ribbon(.guarded(totalMS: 900)) { $0.canExplainGuard = true }?.pieces,
                       [.glyph(.warning), .text("Kept raw"), .button(.why)])
    }

    func testAnErrorOffersInsertAgainOnlyWhenTheTextWasSaved() {
        let message = "Couldn't type into Messages. Text saved."
        XCTAssertEqual(ribbon(.error(message)) { $0.errorOffersRetry = true }?.pieces,
                       [.glyph(.failure), .text(message), .button(.insertAgain)])
        XCTAssertEqual(ribbon(.error("Microphone unavailable"))?.pieces,
                       [.glyph(.failure), .text("Microphone unavailable")])
    }

    func testRecordingShowsTheRedDotTimerMetersAndStop() {
        XCTAssertEqual(ribbon(.recording(elapsed: 12 * 60 + 4))?.pieces,
                       [.dot(.recording), .mono("12:04", reserve: "00:00"), .meters, .button(.stop)])
    }

    func testANoticeIsACheckAndItsWords() {
        XCTAssertEqual(ribbon(.notice("Saved"))?.pieces, [.glyph(.check), .text("Saved")])
    }

    func testALearnedWordNoticeGetsARealUndoButton() {
        XCTAssertEqual(ribbon(.notice("Learned Velora · Undo")) { $0.canUndoLearning = true }?.pieces,
                       [.glyph(.check), .text("Learned Velora"), .button(.undoLearning)])
        XCTAssertEqual(ribbon(.notice("Learned Velora · Undo"))?.pieces,
                       [.glyph(.check), .text("Learned Velora")], "No button once the undo is spent")
    }

    func testLearningNoticeHasSixSecondsForUndo() {
        XCTAssertEqual(FlowBarMetrics.transientHold(for: .notice("Learned Velora · Undo")), .seconds(6))
        XCTAssertEqual(FlowBarMetrics.transientHold(for: .notice("Saved")), FlowBarMetrics.transientHold)
    }

    @MainActor
    func testPublishedStateResizesTheActualPanelAfterAssignment() async throws {
        let model = AppModel(previewMode: true)
        model.pillEdge = .right
        let controller = PillPanelController(model: model)
        model.pillState = .working
        try await Task.sleep(for: .milliseconds(50))

        model.pillState = .notice("Learned Velora · Undo")
        try await Task.sleep(for: .milliseconds(50))

        let expected = FlowBarDock.panelSize(
            for: FlowBarState.viewState(model: model, hovered: nil, open: false),
            edge: .right, newNote: model.newNoteAction
        )
        XCTAssertEqual(controller.panelFrameForTesting.size, expected)
    }

    func testTheButtonsReuseTheExistingShortcuts() {
        XCTAssertEqual(RibbonAction.undo.shortcut, "⌥⇧Z")
        XCTAssertEqual(RibbonAction.insertAgain.shortcut, "⌥⇧V")
        XCTAssertTrue(RibbonAction.insertAgain.isSolid)
        XCTAssertFalse(RibbonAction.undo.isSolid)
    }
}

// MARK: - Ribbon geometry

final class RibbonGeometryTests: XCTestCase {
    func testTheRibbonIs36TallWithAnEighteenPointRadius() {
        XCTAssertEqual(RibbonMetrics.height, 36)
        XCTAssertEqual(RibbonMetrics.radius, 18)
        XCTAssertEqual(RibbonSpec([.dot(.listening), .waveform]).size.height, 36)
    }

    func testWidthIsPaddingPlusEveryPieceAndTheGapsBetweenThem() {
        let spec = RibbonSpec([.dot(.listening), .waveform])
        XCTAssertEqual(spec.width, 14 + 8 + FlowingWaveform.blockLength + 10 + 14)
    }

    func testARibbonEndingInAChipOrButtonTucksItIn() {
        XCTAssertEqual(RibbonSpec([.waveform, .commandChip]).trailingPadding, 6)
        XCTAssertEqual(RibbonSpec([.glyph(.check), .button(.undo)]).trailingPadding, 6)
        XCTAssertEqual(RibbonSpec([.spinner, .text("Cleaning")]).trailingPadding, 14)
    }

    func testPieceFramesRunLeftToRightWithTenPointGaps() {
        let spec = RibbonSpec([.glyph(.check), .mono("742 ms", reserve: "742 ms"), .button(.undo)])
        let frames = spec.pieceFrames
        XCTAssertEqual(frames[0].minX, 14)
        for index in 1..<frames.count {
            XCTAssertEqual(frames[index].minX, frames[index - 1].maxX + 10, accuracy: 0.001)
        }
        XCTAssertEqual(frames.last!.maxX + spec.trailingPadding, spec.width, accuracy: 0.001)
        XCTAssertEqual(frames[2].height, 24, "Buttons are 24 tall inside the 36 ribbon")
        XCTAssertEqual(frames[2].midY, 18, accuracy: 0.001)
    }

    func testAClickOnTheButtonFindsItAndAClickBesideItDoesNot() {
        let spec = RibbonSpec([.glyph(.check), .mono("742 ms", reserve: "742 ms"), .button(.undo)])
        let button = spec.pieceFrames[2]
        XCTAssertEqual(spec.action(at: CGPoint(x: button.midX, y: button.midY)), .undo)
        XCTAssertNil(spec.action(at: CGPoint(x: spec.pieceFrames[0].midX, y: 18)))
    }

    func testAClockReservesItsWidthSoTheRibbonDoesNotJitter() {
        let early = RibbonSpec([.mono("0:09", reserve: "0:00")])
        let later = RibbonSpec([.mono("0:59", reserve: "0:00")])
        XCTAssertEqual(early.width, later.width)
        XCTAssertEqual(FlowBarDock.zeroed("12:04"), "00:00")
        XCTAssertEqual(FlowBarDock.zeroed("1:02:04"), "0:00:00")
    }

    func testLongErrorTextIsCapped() {
        let long = String(repeating: "Insertion failed ", count: 20)
        XCTAssertEqual(RibbonSpec.width(of: .text(long)), RibbonMetrics.maxTextWidth)
    }

    func testOnTheBottomDockTheRibbonSitsTenPointsUpAndCentred() {
        let spec = RibbonSpec([.dot(.listening), .waveform])
        let panel = FlowBarDock.panelSize(for: .ribbon(spec), edge: .bottom)
        let rect = FlowBarDock.ribbonRect(spec, edge: .bottom, panelSize: panel)
        XCTAssertEqual(rect.minY, 10)
        XCTAssertEqual(rect.midX, panel.width / 2, accuracy: 0.001)
        XCTAssertEqual(panel.height, 10 + 36 + FlowBarMetrics.shadowSlack)
    }

    func testOnTheTopDockItHangsTenPointsDown() {
        let spec = RibbonSpec([.dot(.listening), .waveform])
        let panel = FlowBarDock.panelSize(for: .ribbon(spec), edge: .top)
        let rect = FlowBarDock.ribbonRect(spec, edge: .top, panelSize: panel)
        XCTAssertEqual(panel.height - rect.maxY, 10)
    }

    func testOnTheSideDocksAWordRibbonStaysHorizontalAndGrowsInward() {
        let spec = RibbonSpec([.commandChip, .glyph(.lock), .waveform])
        for edge in [PillEdge.left, .right] {
            let panel = FlowBarDock.panelSize(for: .ribbon(spec), edge: edge)
            let rect = FlowBarDock.ribbonRect(spec, edge: edge, panelSize: panel)
            XCTAssertEqual(rect.width, spec.width, "The ribbon keeps its width on \(edge)")
            XCTAssertEqual(rect.height, 36, "and stays 36 tall, so its words never rotate")
            XCTAssertEqual(rect.midY, panel.height / 2, accuracy: 0.001)
            if edge == .left {
                XCTAssertEqual(rect.minX, 10)
            } else {
                XCTAssertEqual(panel.width - rect.maxX, 10)
            }
        }
    }

    func testRibbonClicksMapFromPanelCoordinates() {
        let spec = RibbonSpec([.glyph(.warning), .text("Kept raw"), .button(.why)])
        for edge in PillEdge.allCases {
            let panel = FlowBarDock.panelSize(for: .ribbon(spec), edge: edge)
            let rect = FlowBarDock.ribbonRect(spec, edge: edge, panelSize: panel)
            let button = spec.pieceFrames[2]
            let point = CGPoint(x: rect.minX + button.midX, y: rect.maxY - button.midY)
            XCTAssertEqual(FlowBarDock.ribbonAction(at: point, spec: spec, edge: edge, panelSize: panel), .why)
        }
    }

    func testEveryStateFitsInsideItsOwnPanel() {
        let specs: [RibbonSpec] = [
            RibbonSpec([.commandChip, .glyph(.lock), .waveform]),
            RibbonSpec([.glyph(.failure), .text("Couldn't type into Messages. Text saved."), .button(.insertAgain)]),
            RibbonSpec([.dot(.recording), .mono("12:04", reserve: "00:00"), .meters, .button(.stop)]),
        ]
        let bounds = { (size: CGSize) in CGRect(origin: .zero, size: size) }
        for edge in PillEdge.allCases {
            for spec in specs {
                let panel = FlowBarDock.panelSize(for: .ribbon(spec), edge: edge)
                XCTAssertTrue(bounds(panel).contains(FlowBarDock.ribbonRect(spec, edge: edge, panelSize: panel)))
            }
            for hovered in [nil] + DockControl.allCases.map(Optional.some) {
                let panel = FlowBarDock.panelSize(for: .hover(hovered), edge: edge)
                XCTAssertTrue(bounds(panel).contains(
                    FlowBarDock.capsuleRect(hovered: hovered, newNote: .start, edge: edge, panelSize: panel)))
                if let hovered {
                    XCTAssertTrue(bounds(panel).contains(
                        FlowBarDock.labelRect(hovered, newNote: .start, edge: edge, panelSize: panel)),
                        "\(hovered) label on \(edge)")
                }
            }
            let nudge = FlowBarDock.panelSize(for: .nudge(PreviewFixtures.detectedZoom), edge: edge)
            XCTAssertTrue(bounds(nudge).contains(FlowBarDock.cardRect(edge: edge, panelSize: nudge)))
        }
    }
}

// MARK: - Nub and hover capsule

final class NubAndCapsuleTests: XCTestCase {
    func testTheNubIs44By6SixPointsFromTheEdge() {
        let panel = FlowBarDock.panelSize(for: .nub, edge: .bottom)
        XCTAssertEqual(panel, CGSize(width: 48, height: 44), "The panel is the hit area")
        let nub = FlowBarDock.nubRect(edge: .bottom, panelSize: panel)
        XCTAssertEqual(nub.size, CGSize(width: 44, height: 6))
        XCTAssertEqual(nub.minY, 6)
        XCTAssertEqual(FlowBarMetrics.nubDot, 4)
    }

    func testTheNubStandsOnEndOnASideDock() {
        let panel = FlowBarDock.panelSize(for: .nub, edge: .left)
        let nub = FlowBarDock.nubRect(edge: .left, panelSize: panel)
        XCTAssertEqual(nub.size, CGSize(width: 6, height: 44))
        XCTAssertEqual(nub.minX, 6)
    }

    func testTheCapsuleJoinsThreeSegments28TallInside36() {
        XCTAssertEqual(FlowBarDock.capsuleWidth, 4 + 40 + 2 + 36 + 2 + 36 + 4)
        var previous: CGRect?
        for control in DockControl.allCases {
            let frame = FlowBarDock.segmentFrame(control)
            XCTAssertEqual(frame.height, 28)
            XCTAssertEqual(frame.midY, 18, accuracy: 0.001)
            if let previous { XCTAssertEqual(frame.minX, previous.maxX + 2, accuracy: 0.001) }
            previous = frame
        }
    }

    func testTheLabelSitsEightPointsAboveTheHoveredSegmentAndCentredOnIt() {
        let panel = FlowBarDock.panelSize(for: .hover(.newNote), edge: .bottom)
        let capsule = FlowBarDock.capsuleRect(hovered: .newNote, newNote: .start, edge: .bottom, panelSize: panel)
        let segment = FlowBarDock.segmentRect(.newNote, hovered: .newNote, newNote: .start, edge: .bottom, panelSize: panel)
        let label = FlowBarDock.labelRect(.newNote, newNote: .start, edge: .bottom, panelSize: panel)
        XCTAssertEqual(label.minY, capsule.maxY + 8)
        XCTAssertEqual(label.midX, segment.midX, accuracy: 0.001)
        XCTAssertEqual(label.height, 26)
    }

    func testOnTheTopDockTheLabelHangsBelow() {
        let panel = FlowBarDock.panelSize(for: .hover(.dictate), edge: .top)
        let capsule = FlowBarDock.capsuleRect(hovered: .dictate, newNote: .start, edge: .top, panelSize: panel)
        let label = FlowBarDock.labelRect(.dictate, newNote: .start, edge: .top, panelSize: panel)
        XCTAssertEqual(label.maxY, capsule.minY - 8)
    }

    func testTheCapsuleStaysPutAsTheLabelMovesBetweenSegments() {
        var centres: Set<CGFloat> = []
        for hovered in [nil] + DockControl.allCases.map(Optional.some) {
            let panel = FlowBarDock.panelSize(for: .hover(hovered), edge: .bottom)
            let capsule = FlowBarDock.capsuleRect(hovered: hovered, newNote: .start, edge: .bottom, panelSize: panel)
            XCTAssertEqual(capsule.midX, panel.width / 2, accuracy: 0.001)
            centres.insert(capsule.minY)
        }
        XCTAssertEqual(centres, [10], "Always 10 points up from the edge")
    }

    func testHitTestingFindsTheSegmentUnderThePointerWithNoDeadGap() {
        let panel = FlowBarDock.panelSize(for: .hover(nil), edge: .bottom)
        for control in DockControl.allCases {
            let segment = FlowBarDock.segmentRect(control, hovered: nil, newNote: .start, edge: .bottom, panelSize: panel)
            XCTAssertEqual(FlowBarDock.control(at: CGPoint(x: segment.midX, y: segment.midY), hovered: nil,
                                               newNote: .start, edge: .bottom, panelSize: panel), control)
        }
        let dictate = FlowBarDock.segmentRect(.dictate, hovered: nil, newNote: .start, edge: .bottom, panelSize: panel)
        let inTheGap = CGPoint(x: dictate.maxX + 0.5, y: dictate.midY)
        XCTAssertNotNil(FlowBarDock.control(at: inTheGap, hovered: nil, newNote: .start, edge: .bottom, panelSize: panel))
        XCTAssertNil(FlowBarDock.control(at: CGPoint(x: 1, y: panel.height - 1), hovered: nil,
                                         newNote: .start, edge: .bottom, panelSize: panel))
    }

    func testTheCardIs236WideAndItsButtonsAnswerClicks() {
        let panel = FlowBarDock.panelSize(for: .nudge(PreviewFixtures.detectedZoom), edge: .bottom)
        let card = FlowBarDock.cardRect(edge: .bottom, panelSize: panel)
        XCTAssertEqual(card.width, 236)
        let buttons = FlowBarDock.cardButtonRects(card: card)
        XCTAssertEqual(FlowBarDock.nudgeAction(at: CGPoint(x: buttons.notNow.midX, y: buttons.notNow.midY),
                                               edge: .bottom, panelSize: panel), .ignore)
        XCTAssertEqual(FlowBarDock.nudgeAction(at: CGPoint(x: buttons.start.midX, y: buttons.start.midY),
                                               edge: .bottom, panelSize: panel), .startNote)
        XCTAssertNil(FlowBarDock.nudgeAction(at: CGPoint(x: card.midX, y: card.maxY - 6),
                                             edge: .bottom, panelSize: panel))
    }

    func testTheCardNamesTheCallAndAsksOneQuestion() {
        XCTAssertEqual(FlowBarDock.cardTitle(for: PreviewFixtures.detectedZoom), "Zoom call")
        XCTAssertEqual(FlowBarDock.cardTitle(for: PreviewFixtures.detectedMeetInChrome), "Google Meet in Chrome")
        XCTAssertEqual(FlowBarDock.cardQuestion, "Take notes on this Mac?")
    }
}

// MARK: - Side docks stand on end

final class SideDockTests: XCTestCase {
    private func column(_ configure: (inout FlowBarDock.RibbonInputs) -> Void = { _ in }) -> ColumnSpec? {
        var inputs = FlowBarDock.RibbonInputs(pillState: .listening(level: 0.4))
        configure(&inputs)
        return FlowBarDock.column(for: inputs)
    }

    func testListeningOnASideDockIsADotOnTopTheWaveformThenTheLock() {
        XCTAssertEqual(column()?.pieces, [.dot(.listening), .waveform])
        XCTAssertEqual(column { $0.locked = true }?.pieces, [.dot(.listening), .waveform, .glyph(.lock)])
        XCTAssertNil(FlowBarDock.column(for: FlowBarDock.RibbonInputs(pillState: .inserted(totalMS: 742))),
                     "States with words stay horizontal ribbons")
    }

    func testTheColumnIs36WideAndAsTallAsItsPieces() {
        let spec = column()!
        XCTAssertEqual(spec.size.width, 36)
        XCTAssertEqual(spec.capsuleLength, 12 + 8 + 8 + FlowingWaveform.blockLength + 12)
        let frames = spec.pieceFrames
        XCTAssertLessThan(frames[0].minY, frames[1].minY, "The dot sits above the waveform")
        for frame in frames { XCTAssertEqual(frame.midX, 18, accuracy: 0.001) }
    }

    func testTheColumnHugsItsEdge() {
        let spec = column()!
        for edge in [PillEdge.left, .right] {
            let panel = FlowBarDock.panelSize(for: .column(spec), edge: edge)
            let rect = FlowBarDock.columnCapsuleRect(spec, edge: edge, panelSize: panel)
            XCTAssertEqual(rect.size, CGSize(width: 36, height: spec.capsuleLength))
            XCTAssertEqual(edge == .left ? rect.minX : panel.width - rect.maxX, 10)
            XCTAssertEqual(rect.midY, panel.height / 2, accuracy: 0.001)
        }
    }

    func testCommandPutsItsChipBesideTheColumnTowardTheInterior() {
        let spec = column { $0.commandMode = true }!
        XCTAssertEqual(spec.pieces, [.waveform])
        for edge in [PillEdge.left, .right] {
            let panel = FlowBarDock.panelSize(for: .column(spec), edge: edge)
            let capsule = FlowBarDock.columnCapsuleRect(spec, edge: edge, panelSize: panel)
            let chip = FlowBarDock.columnLabelRect(spec, edge: edge, panelSize: panel)!
            XCTAssertTrue(CGRect(origin: .zero, size: panel).contains(chip))
            XCTAssertEqual(chip.midY, capsule.midY, accuracy: 0.001)
            if edge == .left { XCTAssertGreaterThan(chip.minX, capsule.maxX) }
            else { XCTAssertLessThan(chip.maxX, capsule.minX) }
        }
        XCTAssertNil(FlowBarDock.columnLabelRect(column()!, edge: .left, panelSize: .zero))
    }

    func testTheHoverCapsuleStacksDictateOnTop() {
        let panel = FlowBarDock.panelSize(for: .hover(nil), edge: .left)
        let rects = DockControl.allCases.map {
            FlowBarDock.segmentRect($0, hovered: nil, newNote: .start, edge: .left, panelSize: panel)
        }
        XCTAssertGreaterThan(rects[0].minY, rects[1].maxY, "AppKit y runs up, so Dictate is highest")
        XCTAssertGreaterThan(rects[1].minY, rects[2].maxY)
        for (control, rect) in zip(DockControl.allCases, rects) {
            XCTAssertEqual(rect.width, 28)
            XCTAssertEqual(FlowBarDock.control(at: CGPoint(x: rect.midX, y: rect.midY), hovered: nil,
                                               newNote: .start, edge: .left, panelSize: panel), control)
        }
    }

    func testTheSideLabelSitsBesideTheHoveredSegmentAndFits() {
        for edge in [PillEdge.left, .right] {
            for control in DockControl.allCases {
                let panel = FlowBarDock.panelSize(for: .hover(control), edge: edge)
                let capsule = FlowBarDock.capsuleRect(hovered: control, newNote: .start, edge: edge, panelSize: panel)
                let segment = FlowBarDock.segmentRect(control, hovered: control, newNote: .start, edge: edge, panelSize: panel)
                let label = FlowBarDock.labelRect(control, newNote: .start, edge: edge, panelSize: panel)
                XCTAssertTrue(CGRect(origin: .zero, size: panel).contains(label), "\(control) on \(edge)")
                XCTAssertEqual(label.midY, segment.midY, accuracy: 0.001)
                XCTAssertEqual(edge == .left ? capsule.minX : panel.width - capsule.maxX, 10)
                if edge == .left { XCTAssertEqual(label.minX, capsule.maxX + 8) }
                else { XCTAssertEqual(label.maxX, capsule.minX - 8) }
            }
        }
    }
}

// MARK: - Tone chip and Flow menu

final class ToneAndMenuTests: XCTestCase {
    func testThePresetsReadAsTheirNamesAndAnythingElseIsCustom() {
        let variants = ToneCatalog.defaults.merging(["com.openai.codex": "Short."]) { $1 }
        XCTAssertEqual(ToneCatalog.tone(for: "com.apple.MobileSMS", variants: variants), .casual)
        XCTAssertEqual(ToneCatalog.tone(for: "com.apple.mail", variants: variants), .formal)
        XCTAssertEqual(ToneCatalog.tone(for: "com.openai.codex", variants: variants), .custom)
        XCTAssertEqual(ToneCatalog.tone(for: "com.mitchellh.ghostty", variants: variants), .neutral)
        XCTAssertEqual(ToneCatalog.tone(for: nil, variants: variants), .neutral)
    }

    func testTheDefaultsMatchTheEngine() {
        // engine/undertone/config.py ships these two texts as app_prompt_variants.
        XCTAssertEqual(ToneCatalog.defaults["com.apple.MobileSMS"], ToneCatalog.casualText)
        XCTAssertEqual(ToneCatalog.defaults["com.apple.mail"], ToneCatalog.formalText)
    }

    func testSettingNeutralRemovesTheEntryAndCustomLeavesItAlone() {
        var variants = ToneCatalog.defaults
        variants = ToneCatalog.setting(.neutral, for: "com.apple.mail", in: variants)
        XCTAssertNil(variants["com.apple.mail"])
        variants = ToneCatalog.setting(.formal, for: "com.openai.codex", in: variants)
        XCTAssertEqual(variants["com.openai.codex"], ToneCatalog.formalText)
        let custom = ["x.y": "Mine."]
        XCTAssertEqual(ToneCatalog.setting(.custom, for: "x.y", in: custom), custom)
    }

    func testSettingsNamesAppsFromTheirBundleIDs() {
        XCTAssertEqual(ToneCatalog.fallbackName(for: "com.apple.MobileSMS"), "Messages")
        XCTAssertEqual(ToneCatalog.fallbackName(for: "org.example.Writer"), "Writer")
    }

    private func titles(_ entries: [FlowMenu.Entry]) -> [String] {
        entries.compactMap {
            switch $0 {
            case .item(let title, _, _, _, _, _): return title
            case .submenu(let title, _, _): return title
            case .separator: return nil
            }
        }
    }

    func testTheFlowMenuHoldsWhatPeopleChangeMidDay() {
        let entries = FlowMenu.entries(cleanupLevel: "medium", microphones: [])
        XCTAssertEqual(titles(entries), ["Insert last again", "Copy last transcript", "Microphone", "Cleanup",
                                         "Hide for an hour", "Settings…"])
    }

    func testTheCleanupSubmenuChecksTheCurrentLevelAndSetsANewOne() {
        let entries = FlowMenu.entries(cleanupLevel: "high", microphones: [])
        guard case .submenu(_, let detail, let children)? = entries.first(where: {
            if case .submenu("Cleanup", _, _) = $0 { return true } else { return false }
        }) else { return XCTFail("No Cleanup submenu") }
        XCTAssertEqual(detail, "High")
        let checked = children.compactMap { entry -> FlowMenu.Command? in
            if case .item(_, _, _, let command, true, _) = entry { return command } else { return nil }
        }
        XCTAssertEqual(checked, [.setCleanup("high")])
    }

    func testTheMicrophoneSubmenuShowsDevicesButDoesNotPickOne() {
        let mics = [AudioInputDevices.Device(id: 1, name: "MacBook Pro Microphone", isDefault: true),
                    AudioInputDevices.Device(id: 2, name: "Studio Display Microphone", isDefault: false)]
        let entries = FlowMenu.entries(cleanupLevel: "medium", microphones: mics)
        guard case .submenu(_, let detail, let children)? = entries.first(where: {
            if case .submenu("Microphone", _, _) = $0 { return true } else { return false }
        }) else { return XCTFail("No Microphone submenu") }
        XCTAssertEqual(detail, "MacBook Pro Microphone")
        for child in children {
            if case .item(let title, _, _, let command, _, let enabled) = child, title != "Sound Settings…" {
                XCTAssertNil(command)
                XCTAssertFalse(enabled)
            }
        }
    }

    func testOnlyCopyLastTouchesTheClipboardAndOnlyWhenChosen() {
        let commands = FlowMenu.entries(cleanupLevel: "medium", microphones: []).compactMap { entry -> FlowMenu.Command? in
            if case .item(_, _, _, let command, _, _) = entry { return command } else { return nil }
        }
        XCTAssertEqual(commands.filter { $0 == .copyLast }.count, 1)
    }
}

// MARK: - The nudge card's words

final class MeetingNudgeTextTests: XCTestCase {
    func testANativeCallAppNamesItself() {
        XCTAssertEqual(FlowBarDock.nudgeReason(for: PreviewFixtures.detectedZoom),
                       "Zoom is using the microphone.")
        XCTAssertEqual(FlowBarDock.nudgeReason(for: PreviewFixtures.detectedTeams),
                       "Teams is using the microphone.")
        XCTAssertEqual(FlowBarDock.nudgeReason(for: PreviewFixtures.detectedFaceTime),
                       "FaceTime is using the microphone.")
    }

    func testABrowserNamesItselfAndTheTabItFound() {
        XCTAssertEqual(FlowBarDock.nudgeReason(for: PreviewFixtures.detectedMeetInChrome),
                       "Chrome is using the microphone and a Google Meet tab is open.")
    }

    func testAnUnknownMicOwnerStaysGenericRatherThanGuessing() {
        let unknown = DetectedMeeting(appName: "Voice Memos", suggestedTitle: "New recording",
                                      bundleID: "com.apple.VoiceMemos")
        XCTAssertEqual(unknown.platform, .unknown)
        XCTAssertEqual(FlowBarDock.nudgeReason(for: unknown), "Call is using the microphone.")
    }

    func testTheCardReadsTheDetectorsPlatformRatherThanGuessingAgain() {
        XCTAssertEqual(PreviewFixtures.detectedZoom.platform, .zoom)
        XCTAssertEqual(PreviewFixtures.detectedTeams.platform, .teams)
        XCTAssertEqual(PreviewFixtures.detectedMeetInChrome.platform, .meet)
    }

    func testTheReasonFollowsThePlatformEvenWhenTheBundleIDWouldSayOtherwise() {
        // The detector can read a background tab this view cannot see. If the
        // card re-classified the bundle id it would name the browser, not the
        // call the detector is tracking.
        let teamsInChrome = DetectedMeeting(
            appName: "Chrome", suggestedTitle: "Standup", bundleID: "com.google.Chrome",
            platform: .teams, source: .micOwner, pid: 900, browserName: "Chrome"
        )
        XCTAssertEqual(FlowBarDock.nudgeReason(for: teamsInChrome),
                       "Chrome is using the microphone and a Teams tab is open.")
        XCTAssertEqual(FlowBarDock.startNoteTitle(for: teamsInChrome), "Teams · Standup")
    }

    func testANativeCallWithNoBrowserNameNeverClaimsATab() {
        XCTAssertFalse(FlowBarDock.nudgeReason(for: PreviewFixtures.detectedZoom).contains("tab"))
        XCTAssertNil(PreviewFixtures.detectedZoom.browserName)
    }

    func testTheCardNeverUsesAnEmDash() {
        for detected in [PreviewFixtures.detectedZoom, PreviewFixtures.detectedTeams,
                         PreviewFixtures.detectedMeetInChrome] {
            XCTAssertFalse(FlowBarDock.nudgeReason(for: detected).contains("\u{2014}"))
        }
        XCTAssertFalse(FlowBarDock.nudgeTitle.contains("\u{2014}"))
        XCTAssertFalse(FlowBarDock.cardQuestion.contains("\u{2014}"))
    }

    func testStartNoteNamesThePlatformAndTheWindow() {
        XCTAssertEqual(FlowBarDock.startNoteTitle(for: PreviewFixtures.detectedZoom),
                       "Zoom · Sprint plan review")
        XCTAssertEqual(FlowBarDock.startNoteTitle(for: PreviewFixtures.detectedTeams),
                       "Teams · Northwind intake sync")
    }

    func testStartNoteDoesNotRepeatAPlatformTheTitleAlreadyHas() {
        let zoomTitled = DetectedMeeting(appName: "Zoom", suggestedTitle: "Zoom Meeting",
                                         bundleID: "us.zoom.xos")
        XCTAssertEqual(FlowBarDock.startNoteTitle(for: zoomTitled), "Zoom Meeting")
    }

    func testStartNoteFallsBackWhenTheWindowHasNoTitle() {
        let blank = DetectedMeeting(appName: "Zoom", suggestedTitle: "   ", bundleID: "us.zoom.xos")
        XCTAssertEqual(FlowBarDock.startNoteTitle(for: blank), "Zoom call")
    }
}

// MARK: - When the card is allowed up

@MainActor
final class MeetingNudgeGateTests: XCTestCase {
    private func meetings() -> MeetingModel {
        MeetingModel(engine: EngineClient(path: "/dev/null/undertone-test.sock"), previewMode: true)
    }

    private func shows(enabled: Bool = true, persistent: Bool = true, ignored: Bool = false,
                       busy: Bool = false, pillIsIdle: Bool = true) -> Bool {
        AppModel.shouldShowNudge(enabled: enabled, persistent: persistent, ignored: ignored,
                                 busy: busy, pillIsIdle: pillIsIdle)
    }

    func testAFreshDetectionRaisesTheCard() {
        XCTAssertTrue(shows())
    }

    func testEveryGateCanHoldTheCardDownOnItsOwn() {
        XCTAssertFalse(shows(enabled: false), "Detect calls automatically is off")
        XCTAssertFalse(shows(persistent: false), "The dock is not on screen")
        XCTAssertFalse(shows(ignored: true), "The user already dismissed this call")
        XCTAssertFalse(shows(busy: true), "A capture is already running")
        XCTAssertFalse(shows(pillIsIdle: false), "The dock is showing something else")
    }

    /// The dock reads one Ignore memory, the one `MeetingModel` owns. A second
    /// copy in `AppModel` would let the two disagree about what was dismissed.
    func testIgnoreRoundTripsThroughTheMeetingModel() {
        let model = meetings()
        let zoom = PreviewFixtures.detectedZoom
        XCTAssertTrue(shows(ignored: model.isIgnored(zoom)))

        model.ignore(zoom)
        XCTAssertTrue(model.isIgnored(zoom))
        XCTAssertFalse(shows(ignored: model.isIgnored(zoom)), "The same call must not come back")

        // A different call is a different value, so it is not suppressed.
        XCTAssertFalse(model.isIgnored(PreviewFixtures.detectedTeams))
        XCTAssertTrue(shows(ignored: model.isIgnored(PreviewFixtures.detectedTeams)))
    }

    func testClearingTheIgnoreLetsTheSameCallBackIn() {
        let model = meetings()
        model.ignore(PreviewFixtures.detectedZoom)
        model.clearIgnored()
        XCTAssertFalse(model.isIgnored(PreviewFixtures.detectedZoom))
        XCTAssertTrue(shows(ignored: model.isIgnored(PreviewFixtures.detectedZoom)))
    }
}

// MARK: - Quick note routing

final class QuickNoteRouterTests: XCTestCase {
    private let home = "/Users/test"
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: iso)!
    }

    func testARecordingMeetingTakesTheNote() {
        let destination = QuickNoteRouter.destination(
            recordingSessionID: "sess-1", vaultPath: "/Vault",
            date: date("2026-09-16 10:00"), home: home, timeZone: utc
        )
        XCTAssertEqual(destination, .meetingNotes(sessionID: "sess-1"))
        XCTAssertNil(destination.filePath, "The engine stores meeting notes, not a file here")
    }

    func testWithNoMeetingTheVaultDailyNoteTakesIt() {
        let destination = QuickNoteRouter.destination(
            recordingSessionID: nil, vaultPath: "/Vault",
            date: date("2026-09-16 10:00"), home: home, timeZone: utc
        )
        XCTAssertEqual(destination, .dailyNote(path: "/Vault/Daily/2026-09-16.md"))
    }

    func testWithNoVaultTheNoteStaysBesideUndertone() {
        let destination = QuickNoteRouter.destination(
            recordingSessionID: nil, vaultPath: nil,
            date: date("2026-09-16 10:00"), home: home, timeZone: utc
        )
        XCTAssertEqual(destination, .localFallback(path: "/Users/test/.undertone/quicknotes/2026-09-16.md"))
    }

    func testABlankVaultPathCountsAsNoVault() {
        let destination = QuickNoteRouter.destination(
            recordingSessionID: nil, vaultPath: "   ",
            date: date("2026-09-16 10:00"), home: home, timeZone: utc
        )
        XCTAssertEqual(destination, .localFallback(path: "/Users/test/.undertone/quicknotes/2026-09-16.md"))
    }

    func testABlankSessionIDIsNotARecordingMeeting() {
        let destination = QuickNoteRouter.destination(
            recordingSessionID: "", vaultPath: "/Vault",
            date: date("2026-09-16 10:00"), home: home, timeZone: utc
        )
        XCTAssertEqual(destination, .dailyNote(path: "/Vault/Daily/2026-09-16.md"))
    }

    func testTheStampIsTheLocalCalendarDay() {
        XCTAssertEqual(QuickNoteRouter.dateStamp(date("2026-01-02 12:00"), timeZone: utc), "2026-01-02")
        XCTAssertEqual(QuickNoteRouter.dateStamp(date("2026-12-31 23:59"), timeZone: utc), "2026-12-31")
    }

    func testAppendingNeverOverwritesWhatIsAlreadyThere() {
        XCTAssertEqual(QuickNoteRouter.appended(existing: "First line", addition: "Second"),
                       "First line\nSecond")
        XCTAssertEqual(QuickNoteRouter.appended(existing: nil, addition: "Only"), "Only")
        XCTAssertEqual(QuickNoteRouter.appended(existing: "", addition: "Only"), "Only")
    }

    func testAppendingCollapsesTrailingBlankLinesToExactlyOne() {
        XCTAssertEqual(QuickNoteRouter.appended(existing: "First\n\n\n", addition: "Second"),
                       "First\nSecond")
        XCTAssertEqual(QuickNoteRouter.appended(existing: "\n\n", addition: "Only"), "Only")
    }

    func testAppendingTrimsTheNewTextButKeepsItsShape() {
        XCTAssertEqual(QuickNoteRouter.appended(existing: "First", addition: "  Second\nthird  "),
                       "First\nSecond\nthird")
    }

    func testAppendToFileCreatesTheFolderThenAddsWithoutLosingAnything() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("undertone-quicknote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Daily/2026-09-16.md").path

        try QuickNoteRouter.appendToFile("First note", path: path)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "First note\n")

        try QuickNoteRouter.appendToFile("Second note", path: path)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "First note\nSecond note\n")
    }
}

// MARK: - Option chords

final class OptionShortcutTests: XCTestCase {
    func testOptionMAndOptionSAreTheOnlyOptionOnlyChords() {
        let option: CGEventFlags = [.maskAlternate]
        XCTAssertEqual(HotkeyMonitor.optionShortcut(for: 46, flags: option, autorepeat: false), "m")
        XCTAssertEqual(HotkeyMonitor.optionShortcut(for: 1, flags: option, autorepeat: false), "s")
        XCTAssertNil(HotkeyMonitor.optionShortcut(for: 9, flags: option, autorepeat: false))
    }

    func testAnOptionChordNeedsOptionAloneAndNoRepeat() {
        let option: CGEventFlags = [.maskAlternate]
        XCTAssertNil(HotkeyMonitor.optionShortcut(for: 46, flags: [], autorepeat: false))
        XCTAssertNil(HotkeyMonitor.optionShortcut(for: 46, flags: option, autorepeat: true))
        XCTAssertNil(HotkeyMonitor.optionShortcut(for: 46, flags: [.maskAlternate, .maskShift], autorepeat: false),
                     "Option+Shift+M is the existing Meetings chord")
        XCTAssertNil(HotkeyMonitor.optionShortcut(for: 46, flags: [.maskAlternate, .maskCommand], autorepeat: false))
        XCTAssertNil(HotkeyMonitor.optionShortcut(for: 46, flags: [.maskAlternate, .maskControl], autorepeat: false))
    }

    func testCapsLockAndFnDoNotBlockAnOptionChord() {
        let base: CGEventFlags = [.maskAlternate]
        XCTAssertEqual(HotkeyMonitor.optionShortcut(for: 1, flags: base.union(.maskAlphaShift), autorepeat: false), "s")
        XCTAssertEqual(HotkeyMonitor.optionShortcut(for: 1, flags: base.union(.maskSecondaryFn), autorepeat: false), "s")
    }

    func testTheTapConsumesAnOptionChordAndItsMatchingKeyUp() {
        let monitor = HotkeyMonitor()
        var seen: [Character] = []
        monitor.onOptionShortcut = { seen.append($0) }
        XCTAssertTrue(monitor.consumeShortcut(type: .keyDown, keyCode: 46, flags: [.maskAlternate], autorepeat: false))
        XCTAssertTrue(monitor.consumeShortcut(type: .keyUp, keyCode: 46, flags: [], autorepeat: false))
        XCTAssertEqual(seen, ["m"])
        XCTAssertEqual(monitor.lastShortcutSeen?.chordName, "⌥M")
    }

    func testOptionShiftMStillGoesToTheOldHandler() {
        let monitor = HotkeyMonitor()
        var plain: [Character] = []
        var option: [Character] = []
        monitor.onShortcut = { plain.append($0) }
        monitor.onOptionShortcut = { option.append($0) }
        XCTAssertTrue(monitor.consumeShortcut(type: .keyDown, keyCode: 46,
                                              flags: [.maskAlternate, .maskShift], autorepeat: false))
        XCTAssertEqual(plain, ["m"])
        XCTAssertTrue(option.isEmpty)
        XCTAssertEqual(monitor.lastShortcutSeen?.chordName, "⌥⇧M")
    }

    func testThePermissionsRosterListsEveryChordOnce() {
        let chords = HotkeyMonitor.chordRoster.map(\.chord)
        XCTAssertEqual(Set(chords).count, chords.count)
        XCTAssertTrue(chords.contains("⌥M"))
        XCTAssertTrue(chords.contains("⌥S"))
    }

    func testSettingsListsOnlyChordsTheTapHandles() {
        let chords = DictationSettingsTab.shortcuts.map(\.1).filter { $0.hasPrefix("⌥") }
        XCTAssertEqual(chords, HotkeyMonitor.chordRoster.map(\.chord))
        XCTAssertFalse(chords.contains("⌥⇧H"))
    }
}

// MARK: - The click toggle

final class HotkeyClickToggleTests: XCTestCase {
    func testAClickLatchesRecordingOnAndTheNextClickStopsIt() {
        var state = HotkeyStateMachine()
        XCTAssertEqual(state.clickToggle(), .start)
        XCTAssertTrue(state.locked, "A click is lock mode, so the pill shows the lock glyph")
        XCTAssertEqual(state.clickToggle(), .stop)
        XCTAssertFalse(state.locked)
    }

    func testAHoldKeyTapStillStopsADictationStartedByAClick() {
        var state = HotkeyStateMachine()
        _ = state.clickToggle()
        XCTAssertEqual(state.press(at: 10), .stop)
        XCTAssertFalse(state.locked)
    }

    func testAClickAfterAHoldKeyTapDoesNotReadAsADoubleTap() {
        var state = HotkeyStateMachine()
        _ = state.press(at: 1)
        _ = state.release(at: 1.5)
        XCTAssertEqual(state.clickToggle(), .start)
        // The click cleared the tap history, so the next press is a plain stop.
        XCTAssertEqual(state.press(at: 1.6), .stop)
    }

    func testEscapeStillStopsADictationStartedByAClick() {
        var state = HotkeyStateMachine()
        _ = state.clickToggle()
        XCTAssertTrue(state.stopIfLocked())
        XCTAssertFalse(state.locked)
    }
}

// MARK: - Holds

final class FlowBarHoldTests: XCTestCase {
    func testInsertedHoldsTwoSecondsAndAnErrorFour() {
        XCTAssertEqual(AppModel.hold(for: .inserted(totalMS: 742)), .seconds(2))
        XCTAssertEqual(AppModel.hold(for: .error("x")), .seconds(4))
        XCTAssertEqual(AppModel.hold(for: .guarded(totalMS: 900)), .seconds(3))
        XCTAssertEqual(FlowBarMetrics.savedHold, .milliseconds(1200))
    }

    func testTheNudgeGivesTheUser20Seconds() {
        XCTAssertEqual(FlowBarMetrics.nudgeAutoDismiss, 20, accuracy: 0.0001)
    }

    func testTheOpenTimingsMatchTheSpec() {
        XCTAssertEqual(FlowBarMetrics.hoverOpenDelay, 0.120, accuracy: 0.0001)
        XCTAssertEqual(FlowBarMetrics.collapseDuration, 0.160, accuracy: 0.0001)
        XCTAssertEqual(FlowBarMetrics.pulsePeriod, 1.2, accuracy: 0.0001)
    }

    func testAFailedInsertSaysTheTextIsSafe() {
        XCTAssertEqual(AppModel.pillFailureMessage(.appChanged, appName: "Messages"),
                       "Couldn't type into Messages. Text saved.")
        XCTAssertEqual(AppModel.pillFailureMessage(.typeFailed, appName: nil), "Couldn't type it in. Text saved.")
        XCTAssertEqual(AppModel.pillFailureMessage(.notTrusted, appName: "Mail"), "Accessibility permission required")
    }
}

// MARK: - Double-tap lock switch

final class DoubleTapLockSettingTests: XCTestCase {
    func testWithLockOffADoubleTapIsTwoDictationsNeverALock() {
        var state = HotkeyStateMachine()
        state.doubleTapLock = false
        XCTAssertEqual(state.press(at: 0), .start)
        XCTAssertEqual(state.release(at: 0.1), .stopImmediately, "No second tap to wait for")
        XCTAssertEqual(state.press(at: 0.2), .start)
        XCTAssertFalse(state.locked)
    }

    func testWithLockOnTheSameTapsLatch() {
        var state = HotkeyStateMachine()
        XCTAssertEqual(state.press(at: 0), .start)
        XCTAssertEqual(state.release(at: 0.1), .stopAfterDelay)
        _ = state.press(at: 0.2)
        XCTAssertTrue(state.locked)
    }
}
