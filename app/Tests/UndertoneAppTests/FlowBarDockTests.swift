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
        XCTAssertEqual(dictate.shortcut, "fn")

        let newNote = FlowBarDock.labelText(for: .newNote, isRecording: false)
        XCTAssertEqual(newNote.title, "New note")
        XCTAssertEqual(newNote.shortcut, "Opt+M")

        let scratchpad = FlowBarDock.labelText(for: .scratchpad, isRecording: false)
        XCTAssertEqual(scratchpad.title, "Quick note")
        XCTAssertNil(scratchpad.shortcut, "Quick note carries no shortcut on the capsule")
    }

    func testNewNoteBecomesStopWhileRecording() {
        let recording = FlowBarDock.labelText(for: .newNote, isRecording: true)
        XCTAssertEqual(recording.title, "Stop")
        XCTAssertEqual(recording.shortcut, "Opt+M")
    }

    func testRecordingNeverRenamesTheOtherTwoControls() {
        XCTAssertEqual(FlowBarDock.labelText(for: .dictate, isRecording: true).title, "Dictate")
        XCTAssertEqual(FlowBarDock.labelText(for: .scratchpad, isRecording: true).title, "Quick note")
    }

    func testAccessibilityLabelNamesTheShortcut() {
        XCTAssertEqual(FlowBarDock.accessibilityLabel(for: .dictate), "Dictate, fn")
        XCTAssertEqual(FlowBarDock.accessibilityLabel(for: .newNote, isRecording: true), "Stop, Opt+M")
        XCTAssertEqual(FlowBarDock.accessibilityLabel(for: .scratchpad), "Quick note")
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
            XCTAssertEqual(FlowBarDock.labelText(for: .newNote, newNote: action).shortcut, "Opt+M")
        }
    }

    func testResumeNeverRenamesTheOtherControls() {
        XCTAssertEqual(FlowBarDock.labelText(for: .dictate, newNote: .resume).title, "Dictate")
        XCTAssertEqual(FlowBarDock.labelText(for: .scratchpad, newNote: .resume).title, "Quick note")
    }

    func testResumeReachesVoiceOverToo() {
        XCTAssertEqual(FlowBarDock.accessibilityLabel(for: .newNote, newNote: .resume), "Resume, Opt+M")
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

// MARK: - Capsule contents and sizes

final class FlowBarCapsuleTests: XCTestCase {
    private let side = PillEdge.right
    private let flat = PillEdge.bottom

    func testInsertedDropsTheWordAndKeepsTheReading() {
        let capsule = FlowBarDock.textCapsule(for: .inserted(totalMS: 742), workingNote: nil)
        XCTAssertEqual(capsule?.glyph, .check)
        XCTAssertEqual(capsule?.text, "")
        XCTAssertEqual(capsule?.mono, "742 ms")
    }

    func testLearningNoticeHasSixSecondsForUndo() {
        XCTAssertEqual(FlowBarMetrics.transientHold(for: .notice("Learned Velora · Undo")), .seconds(6))
        XCTAssertEqual(FlowBarMetrics.transientHold(for: .notice("Saved")), FlowBarMetrics.transientHold)
    }

    func testGuardedAndErrorCarryTheirOwnGlyphs() {
        XCTAssertEqual(FlowBarDock.textCapsule(for: .guarded(totalMS: 900), workingNote: nil),
                       FlowBarTextCapsule(glyph: .warning, text: "Kept raw"))
        XCTAssertEqual(FlowBarDock.textCapsule(for: .error("Insertion failed: app changed"), workingNote: nil),
                       FlowBarTextCapsule(glyph: .failure, text: "Insertion failed: app changed"))
        XCTAssertEqual(FlowBarDock.textCapsule(for: .notice("Saved"), workingNote: nil),
                       FlowBarTextCapsule(glyph: .check, text: "Saved"))
        XCTAssertEqual(FlowBarDock.textCapsule(for: .notice("Meeting ended"), workingNote: nil),
                       FlowBarTextCapsule(glyph: .check, text: "Meeting ended"))
    }

    func testWorkingIsASpinnerUntilItHasSomethingToSay() {
        XCTAssertNil(FlowBarDock.textCapsule(for: .working, workingNote: nil))
        XCTAssertNil(FlowBarDock.textCapsule(for: .working, workingNote: ""))
        XCTAssertEqual(FlowBarDock.textCapsule(for: .working, workingNote: "Release fn to insert"),
                       FlowBarTextCapsule(text: "Release fn to insert"))
    }

    func testStatesWithoutACapsuleReturnNothing() {
        XCTAssertNil(FlowBarDock.textCapsule(for: .idle, workingNote: nil))
        XCTAssertNil(FlowBarDock.textCapsule(for: .listening(level: 0.4), workingNote: nil))
        XCTAssertNil(FlowBarDock.textCapsule(for: .recording(elapsed: 10), workingNote: nil))
    }

    func testDictationCapsuleIs40By120AlongEveryEdge() {
        let state = FlowBarViewState.level(locked: false, commandWidth: nil)
        for edge in PillEdge.allCases {
            let box = FlowBarDock.capsuleBox(for: state, edge: edge)
            XCTAssertEqual(box?.depth, 40, "\(edge)")
            XCTAssertEqual(box?.along, 120, "\(edge)")
        }
        XCTAssertEqual(FlowBarDock.capsuleBox(for: .spinner, edge: side)?.depth, 40)
        XCTAssertEqual(FlowBarDock.capsuleBox(for: .spinner, edge: side)?.along, 120)
    }

    func testDictationCapsuleGrowsSidewaysForTheCommandMarker() {
        let state = FlowBarViewState.level(locked: false, commandWidth: 60)
        // The word always reads horizontally, so a side dock grows inward and
        // a flat dock grows along the edge. Neither one rotates the text.
        let sideBox = FlowBarDock.capsuleBox(for: state, edge: side)
        XCTAssertEqual(sideBox?.depth, 40 + 60 + 16)
        XCTAssertEqual(sideBox?.along, 120)

        let flatBox = FlowBarDock.capsuleBox(for: state, edge: flat)
        XCTAssertEqual(flatBox?.depth, 40)
        XCTAssertEqual(flatBox?.along, 120 + 60 + 16)
    }

    func testTextCapsulesStayHorizontalOnASideDock() {
        let state = FlowBarViewState.text(FlowBarTextCapsule(text: "Kept raw"), width: 180)
        let sideBox = FlowBarDock.capsuleBox(for: state, edge: side)
        XCTAssertEqual(sideBox?.depth, 180, "It grows toward the interior, not along the edge")
        XCTAssertEqual(sideBox?.along, 40)

        let flatBox = FlowBarDock.capsuleBox(for: state, edge: flat)
        XCTAssertEqual(flatBox?.depth, 40)
        XCTAssertEqual(flatBox?.along, 180)
    }

    func testStatesWithNoCapsuleHaveNoCapsuleBox() {
        XCTAssertNil(FlowBarDock.capsuleBox(for: .nub, edge: side))
        XCTAssertNil(FlowBarDock.capsuleBox(for: .stack(hovered: nil, labelWidth: 0), edge: side))
        XCTAssertNil(FlowBarDock.capsuleBox(for: .recording(elapsed: 0, hovered: false, badgeWidth: 60), edge: side))
        XCTAssertNil(FlowBarDock.capsuleBox(for: .nudge(PreviewFixtures.detectedZoom), edge: side))
    }

    func testTextCapsuleWidthIsPaddingPlusEveryPieceAndTheGapsBetweenThem() {
        // Padding 16 both ends, a 16 point glyph, 8 point gaps.
        XCTAssertEqual(FlowBarDock.textCapsuleWidth(glyph: .none, textWidth: 100, monoWidth: 0), 132)
        XCTAssertEqual(FlowBarDock.textCapsuleWidth(glyph: .check, textWidth: 100, monoWidth: 0), 132 + 16 + 8)
        XCTAssertEqual(FlowBarDock.textCapsuleWidth(glyph: .check, textWidth: 0, monoWidth: 50), 32 + 16 + 8 + 50)
        XCTAssertEqual(FlowBarDock.textCapsuleWidth(glyph: .check, textWidth: 60, monoWidth: 50), 32 + 16 + 60 + 50 + 16)
    }

    func testLabelAndTimerPaddingMatchTheSpec() {
        XCTAssertEqual(FlowBarDock.labelWidth(textWidth: 100), 144)
        XCTAssertEqual(FlowBarDock.timerWidth(textWidth: 40), 60)
    }
}

// MARK: - Panel and control geometry

final class FlowBarLayoutTests: XCTestCase {
    private let right = PillEdge.right
    private let bottom = PillEdge.bottom

    func testTheIdlePanelIsExactlyTheNubHitArea() {
        XCTAssertEqual(FlowBarDock.panelSize(for: .nub, edge: right), CGSize(width: 44, height: 48))
        XCTAssertEqual(FlowBarDock.panelSize(for: .nub, edge: bottom), CGSize(width: 48, height: 44))
    }

    func testTheNubIsDrawn48By8SixPointsFromTheEdge() {
        let axis = DockAxis(edge: right, panelSize: FlowBarDock.panelSize(for: .nub, edge: right))
        let nub = FlowBarDock.nubRect(axis: axis)
        XCTAssertEqual(nub.size, CGSize(width: 8, height: 48))
        XCTAssertEqual(axis.panelSize.width - nub.maxX, 6, accuracy: 0.0001)

        let flatAxis = DockAxis(edge: bottom, panelSize: FlowBarDock.panelSize(for: .nub, edge: bottom))
        let flatNub = FlowBarDock.nubRect(axis: flatAxis)
        XCTAssertEqual(flatNub.size, CGSize(width: 48, height: 8))
        XCTAssertEqual(flatNub.minY, 6, accuracy: 0.0001)
    }

    func testTheStackRunsMicThenNewNoteThenQuickNoteAcross160Points() {
        XCTAssertEqual(FlowBarDock.controlOffset(.dictate), 0)
        XCTAssertEqual(FlowBarDock.controlOffset(.newNote), 72)
        XCTAssertEqual(FlowBarDock.controlOffset(.scratchpad), 120)
        let total = FlowBarDock.controlOffset(.scratchpad) + FlowBarDock.controlAlong(.scratchpad)
        XCTAssertEqual(total, FlowBarMetrics.stackAlong)
    }

    func testControlsAreTenPointsInFromTheEdge() {
        let state = FlowBarViewState.stack(hovered: nil, labelWidth: 0)
        let axis = DockAxis(edge: right, panelSize: FlowBarDock.panelSize(for: state, edge: right))
        for control in DockControl.allCases {
            let rect = FlowBarDock.controlRect(control, axis: axis, hovered: nil)
            XCTAssertEqual(axis.panelSize.width - rect.maxX, 10, accuracy: 0.0001, "\(control)")
        }
        XCTAssertEqual(FlowBarDock.controlRect(.dictate, axis: axis, hovered: nil).size,
                       CGSize(width: 40, height: 64))
        XCTAssertEqual(FlowBarDock.controlRect(.scratchpad, axis: axis, hovered: nil).size,
                       CGSize(width: 40, height: 40))
    }

    func testMicStandsOnEndOnASideDockAndLiesFlatOnABottomDock() {
        let state = FlowBarViewState.stack(hovered: nil, labelWidth: 0)
        let flatAxis = DockAxis(edge: bottom, panelSize: FlowBarDock.panelSize(for: state, edge: bottom))
        XCTAssertEqual(FlowBarDock.controlRect(.dictate, axis: flatAxis, hovered: nil).size,
                       CGSize(width: 64, height: 40))
    }

    func testControlsSitEightPointsApart() {
        let state = FlowBarViewState.stack(hovered: nil, labelWidth: 0)
        let axis = DockAxis(edge: right, panelSize: FlowBarDock.panelSize(for: state, edge: right))
        let mic = FlowBarDock.controlRect(.dictate, axis: axis, hovered: nil)
        let note = FlowBarDock.controlRect(.newNote, axis: axis, hovered: nil)
        let pad = FlowBarDock.controlRect(.scratchpad, axis: axis, hovered: nil)
        XCTAssertEqual(mic.minY - note.maxY, 8, accuracy: 0.0001)
        XCTAssertEqual(note.minY - pad.maxY, 8, accuracy: 0.0001)
    }

    func testHoveringNewNoteGrowsItInwardAndLeavesTheOthersAlone() {
        let state = FlowBarViewState.stack(hovered: .newNote, labelWidth: 0)
        let axis = DockAxis(edge: right, panelSize: FlowBarDock.panelSize(for: state, edge: right))
        let note = FlowBarDock.controlRect(.newNote, axis: axis, hovered: .newNote)
        XCTAssertEqual(note.width, 76)
        XCTAssertEqual(axis.panelSize.width - note.maxX, 10, accuracy: 0.0001,
                       "It grows toward the interior, so the ring stays by the edge")
        XCTAssertEqual(FlowBarDock.controlRect(.dictate, axis: axis, hovered: .newNote).width, 40)
    }

    func testHoveringAControlWidensThePanelEnoughForItsLabel() {
        let plain = FlowBarDock.panelBox(for: .stack(hovered: nil, labelWidth: 0), edge: right)
        let labelled = FlowBarDock.panelBox(for: .stack(hovered: .dictate, labelWidth: 150), edge: right)
        XCTAssertEqual(labelled.depth - plain.depth, 12 + 150, accuracy: 0.0001)
        XCTAssertEqual(labelled.along, plain.along)
    }

    func testTheLabelSits12PointsInwardFromTheHoveredControl() {
        let state = FlowBarViewState.stack(hovered: .dictate, labelWidth: 150)
        let axis = DockAxis(edge: right, panelSize: FlowBarDock.panelSize(for: state, edge: right))
        let control = FlowBarDock.controlRect(.dictate, axis: axis, hovered: .dictate)
        let label = FlowBarDock.labelRect(.dictate, axis: axis, hovered: .dictate, width: 150)
        XCTAssertEqual(control.minX - label.maxX, 12, accuracy: 0.0001)
        XCTAssertEqual(label.height, 46)
        XCTAssertEqual(label.midY, control.midY, accuracy: 0.0001, "The label centres on its control")
    }

    func testCapsulesThatHoldWordsStayUprightOnABottomDock() {
        // A label, a timer, and a text capsule all read left to right. Turning
        // them with the dock would stand the words on end.
        let label = FlowBarViewState.stack(hovered: .dictate, labelWidth: 150)
        let axis = DockAxis(edge: bottom, panelSize: FlowBarDock.panelSize(for: label, edge: bottom))
        let rect = FlowBarDock.labelRect(.dictate, axis: axis, hovered: .dictate, width: 150)
        XCTAssertEqual(rect.size, CGSize(width: 150, height: 46))

        let recording = FlowBarViewState.recording(elapsed: 724, hovered: false, badgeWidth: 60)
        let recordingAxis = DockAxis(edge: bottom, panelSize: FlowBarDock.panelSize(for: recording, edge: bottom))
        XCTAssertEqual(FlowBarDock.recordingBadgeRect(axis: recordingAxis, hovered: false, width: 60).size,
                       CGSize(width: 60, height: 28))
    }

    func testABottomDockPanelGrowsSidewaysForALongLabel() {
        // On a bottom dock a label reaches along the edge, not inward, and it
        // hangs off its own control rather than the middle of the stack.
        let state = FlowBarViewState.stack(hovered: .dictate, labelWidth: 150)
        let box = FlowBarDock.panelBox(for: state, edge: bottom)
        XCTAssertEqual(box.depth, 10 + 40 + 12 + 46 + 12, "Inward it only needs the 46 point label height")
        XCTAssertEqual(box.along, 2 * (48 + 75 + 12), "Sideways it needs room for a label hung off the mic")
    }

    func testTheLabelStaysCentredOnItsControlOnEveryDock() {
        for edge in PillEdge.allCases {
            for control in DockControl.allCases {
                let state = FlowBarViewState.stack(hovered: control, labelWidth: 150)
                let axis = DockAxis(edge: edge, panelSize: FlowBarDock.panelSize(for: state, edge: edge))
                let drawn = FlowBarDock.controlRect(control, axis: axis, hovered: control)
                let label = FlowBarDock.labelRect(control, axis: axis, hovered: control, width: 150)
                if edge.isHorizontal {
                    XCTAssertEqual(label.midX, drawn.midX, accuracy: 0.0001, "\(edge) \(control)")
                } else {
                    XCTAssertEqual(label.midY, drawn.midY, accuracy: 0.0001, "\(edge) \(control)")
                }
            }
        }
    }

    func testHitAreasAreTheDrawnSizePlusFourPoints() {
        let state = FlowBarViewState.stack(hovered: nil, labelWidth: 0)
        let axis = DockAxis(edge: right, panelSize: FlowBarDock.panelSize(for: state, edge: right))
        let drawn = FlowBarDock.controlRect(.scratchpad, axis: axis, hovered: nil)
        let hit = FlowBarDock.controlHitRect(.scratchpad, axis: axis, hovered: nil)
        XCTAssertEqual(hit.width - drawn.width, 8, accuracy: 0.0001)
        XCTAssertEqual(hit.height - drawn.height, 8, accuracy: 0.0001)
    }

    func testHitTestingFindsTheControlUnderThePointer() {
        let state = FlowBarViewState.stack(hovered: nil, labelWidth: 0)
        let axis = DockAxis(edge: right, panelSize: FlowBarDock.panelSize(for: state, edge: right))
        for control in DockControl.allCases {
            let rect = FlowBarDock.controlRect(control, axis: axis, hovered: nil)
            XCTAssertEqual(FlowBarDock.control(at: CGPoint(x: rect.midX, y: rect.midY), axis: axis, hovered: nil),
                           control)
        }
        // The far interior of the panel is inside the dock but on no control.
        XCTAssertNil(FlowBarDock.control(at: CGPoint(x: 2, y: 2), axis: axis, hovered: nil))
    }

    func testEveryStateFitsInsideItsOwnPanel() {
        let states: [FlowBarViewState] = [
            .nub,
            .stack(hovered: nil, labelWidth: 0),
            .stack(hovered: .dictate, labelWidth: 160),
            .stack(hovered: .newNote, labelWidth: 160),
            .stack(hovered: .scratchpad, labelWidth: 220),
            .level(locked: true, commandWidth: nil),
            .level(locked: false, commandWidth: 60),
            .spinner,
            .text(FlowBarTextCapsule(glyph: .check, mono: "742 ms"), width: 120),
            .recording(elapsed: 724, hovered: false, badgeWidth: 60),
            .recording(elapsed: 724, hovered: true, badgeWidth: 150),
            .nudge(PreviewFixtures.detectedZoom),
        ]
        for edge in PillEdge.allCases {
            for state in states {
                let size = FlowBarDock.panelSize(for: state, edge: edge)
                let axis = DockAxis(edge: edge, panelSize: size)
                let bounds = CGRect(origin: .zero, size: size)
                for rect in drawnRects(state: state, axis: axis) {
                    XCTAssertTrue(bounds.contains(rect),
                                  "\(state) on \(edge): \(rect) escapes \(bounds)")
                }
            }
        }
    }

    private func drawnRects(state: FlowBarViewState, axis: DockAxis) -> [CGRect] {
        switch state {
        case .nub:
            return [FlowBarDock.nubRect(axis: axis)]
        case .stack(let hovered, let labelWidth):
            var rects = DockControl.allCases.map { FlowBarDock.controlRect($0, axis: axis, hovered: hovered) }
            if let hovered, labelWidth > 0 {
                rects.append(FlowBarDock.labelRect(hovered, axis: axis, hovered: hovered, width: labelWidth))
            }
            return rects
        case .level, .spinner, .text:
            return [FlowBarDock.capsuleRect(for: state, axis: axis)].compactMap { $0 }
        case .recording(_, let hovered, let badgeWidth):
            return [
                FlowBarDock.recordingControlRect(axis: axis),
                FlowBarDock.recordingBadgeRect(axis: axis, hovered: hovered, width: badgeWidth),
            ]
        case .nudge:
            return [FlowBarDock.nubRect(axis: axis), FlowBarDock.nudgeRect(axis: axis)]
        }
    }

    func testTheRecordingTimerSits12PointsInwardFromTheControl() {
        let state = FlowBarViewState.recording(elapsed: 724, hovered: false, badgeWidth: 60)
        let axis = DockAxis(edge: right, panelSize: FlowBarDock.panelSize(for: state, edge: right))
        let control = FlowBarDock.recordingControlRect(axis: axis)
        let badge = FlowBarDock.recordingBadgeRect(axis: axis, hovered: false, width: 60)
        XCTAssertEqual(control.size, CGSize(width: 40, height: 40))
        XCTAssertEqual(control.minX - badge.maxX, 12, accuracy: 0.0001)
        XCTAssertEqual(badge.height, 28, "The timer capsule is 28 tall")
    }

    func testHoveringWhileRecordingSwapsTheTimerForA46TallLabel() {
        let state = FlowBarViewState.recording(elapsed: 724, hovered: true, badgeWidth: 150)
        let axis = DockAxis(edge: right, panelSize: FlowBarDock.panelSize(for: state, edge: right))
        XCTAssertEqual(FlowBarDock.recordingBadgeRect(axis: axis, hovered: true, width: 150).height, 46)
    }

    func testTheNudgeCardIs300By140TwelvePointsFromTheNub() {
        for edge in PillEdge.allCases {
            let state = FlowBarViewState.nudge(PreviewFixtures.detectedZoom)
            let axis = DockAxis(edge: edge, panelSize: FlowBarDock.panelSize(for: state, edge: edge))
            let card = FlowBarDock.nudgeRect(axis: axis)
            XCTAssertEqual(card.size, CGSize(width: 300, height: 132), "\(edge) keeps the card upright")
            let nub = FlowBarDock.nubRect(axis: axis)
            let gap: CGFloat
            switch edge {
            case .right: gap = nub.minX - card.maxX
            case .left: gap = card.minX - nub.maxX
            case .bottom: gap = card.minY - nub.maxY
            case .top: gap = nub.minY - card.maxY
            }
            XCTAssertEqual(gap, 12, accuracy: 0.0001, "\(edge)")
        }
    }

    func testNudgeButtonsSplitTheCardAndAnswerClicks() {
        let state = FlowBarViewState.nudge(PreviewFixtures.detectedZoom)
        let axis = DockAxis(edge: right, panelSize: FlowBarDock.panelSize(for: state, edge: right))
        let card = FlowBarDock.nudgeRect(axis: axis)
        let buttons = FlowBarDock.nudgeButtonRects(card: card)
        XCTAssertEqual(buttons.ignore.width, buttons.start.width, accuracy: 0.0001)
        XCTAssertEqual(buttons.start.minX - buttons.ignore.maxX, 8, accuracy: 0.0001)
        XCTAssertEqual(FlowBarDock.nudgeAction(at: CGPoint(x: buttons.ignore.midX, y: buttons.ignore.midY), axis: axis),
                       .ignore)
        XCTAssertEqual(FlowBarDock.nudgeAction(at: CGPoint(x: buttons.start.midX, y: buttons.start.midY), axis: axis),
                       .startNote)
        XCTAssertNil(FlowBarDock.nudgeAction(at: CGPoint(x: card.midX, y: card.maxY - 4), axis: axis),
                     "The card body is not a button")
        XCTAssertNil(FlowBarDock.nudgeAction(at: CGPoint(x: axis.panelSize.width - 2, y: 2), axis: axis))
    }

    func testTheAxisPutsDepthAndAlongWhereEachDockExpectsThem() {
        let size = CGSize(width: 200, height: 100)
        let vertical = DockAxis(edge: .right, panelSize: size)
        XCTAssertEqual(vertical.rect(depth: 10, deep: 40, along: 0, long: 20),
                       CGRect(x: 150, y: 80, width: 40, height: 20))
        let flat = DockAxis(edge: .bottom, panelSize: size)
        XCTAssertEqual(flat.rect(depth: 10, deep: 40, along: 0, long: 20),
                       CGRect(x: 0, y: 10, width: 20, height: 40))
        let top = DockAxis(edge: .top, panelSize: size)
        XCTAssertEqual(top.rect(depth: 10, deep: 40, along: 0, long: 20),
                       CGRect(x: 0, y: 50, width: 20, height: 40))
        let left = DockAxis(edge: .left, panelSize: size)
        XCTAssertEqual(left.rect(depth: 10, deep: 40, along: 0, long: 20),
                       CGRect(x: 10, y: 80, width: 40, height: 20))
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
        XCTAssertFalse(FlowBarDock.nudgeSubline.contains("\u{2014}"))
    }

    func testTheSublineSaysWhatDoesNotHappen() {
        XCTAssertEqual(FlowBarDock.nudgeSubline, "No bot joins. Recording stays on this Mac.")
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
    func testInsertedLeavesTwiceAsFastAsAWarning() {
        XCTAssertEqual(FlowBarMetrics.insertedHold, .milliseconds(900))
        XCTAssertEqual(FlowBarMetrics.transientHold, .milliseconds(1800))
        XCTAssertEqual(FlowBarMetrics.savedHold, .milliseconds(1200))
    }

    func testTheNudgeGivesTheUser20Seconds() {
        XCTAssertEqual(FlowBarMetrics.nudgeAutoDismiss, 20, accuracy: 0.0001)
    }

    func testTheFanOutTimingsMatchTheSpec() {
        XCTAssertEqual(FlowBarMetrics.fanOutDuration, 0.260, accuracy: 0.0001)
        XCTAssertEqual(FlowBarMetrics.fanOutStagger, 0.045, accuracy: 0.0001)
        XCTAssertEqual(FlowBarMetrics.collapseDuration, 0.160, accuracy: 0.0001)
        XCTAssertEqual(FlowBarMetrics.recordingPulsePeriod, 1.2, accuracy: 0.0001)
    }
}
