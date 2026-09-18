import XCTest
import CoreGraphics
@testable import UndertoneApp

final class PillPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testNearestEdgePicksTheClosestSide() {
        XCTAssertEqual(PillPlacement.nearestEdge(center: CGPoint(x: 720, y: 5), in: screen), .bottom)
        XCTAssertEqual(PillPlacement.nearestEdge(center: CGPoint(x: 720, y: 895), in: screen), .top)
        XCTAssertEqual(PillPlacement.nearestEdge(center: CGPoint(x: 5, y: 450), in: screen), .left)
        XCTAssertEqual(PillPlacement.nearestEdge(center: CGPoint(x: 1435, y: 450), in: screen), .right)
    }

    func testNearestEdgeBreaksTiesTowardTheFirstCheckedEdge() {
        // Dead-center of a square screen is equidistant from all four edges.
        let square = CGRect(x: 0, y: 0, width: 900, height: 900)
        XCTAssertEqual(PillPlacement.nearestEdge(center: CGPoint(x: 450, y: 450), in: square), .bottom)
    }

    func testNormalizedOffsetForHorizontalEdgesReadsLeftToRight() {
        XCTAssertEqual(PillPlacement.normalizedOffset(center: CGPoint(x: 0, y: 0), edge: .bottom, in: screen), 0, accuracy: 0.0001)
        XCTAssertEqual(PillPlacement.normalizedOffset(center: CGPoint(x: 1440, y: 0), edge: .bottom, in: screen), 1, accuracy: 0.0001)
        XCTAssertEqual(PillPlacement.normalizedOffset(center: CGPoint(x: 720, y: 0), edge: .top, in: screen), 0.5, accuracy: 0.0001)
    }

    func testNormalizedOffsetForVerticalEdgesReadsBottomToTop() {
        XCTAssertEqual(PillPlacement.normalizedOffset(center: CGPoint(x: 0, y: 0), edge: .left, in: screen), 0, accuracy: 0.0001)
        XCTAssertEqual(PillPlacement.normalizedOffset(center: CGPoint(x: 0, y: 900), edge: .right, in: screen), 1, accuracy: 0.0001)
    }

    func testNormalizedOffsetClampsOutOfBoundsCenters() {
        XCTAssertEqual(PillPlacement.normalizedOffset(center: CGPoint(x: -500, y: 0), edge: .bottom, in: screen), 0, accuracy: 0.0001)
        XCTAssertEqual(PillPlacement.normalizedOffset(center: CGPoint(x: 5000, y: 0), edge: .bottom, in: screen), 1, accuracy: 0.0001)
    }

    func testFrameForBottomEdgeCentersHorizontallyAndInsetsVertically() {
        let size = CGSize(width: 240, height: 44)
        let frame = PillPlacement.frame(size: size, edge: .bottom, offset: 0.5, inset: 26, in: screen)
        XCTAssertEqual(frame.midX, screen.midX, accuracy: 0.0001)
        XCTAssertEqual(frame.minY, 26, accuracy: 0.0001)
        XCTAssertEqual(frame.size, size)
    }

    func testFrameForTopEdgeInsetsFromTheTop() {
        let size = CGSize(width: 240, height: 44)
        let frame = PillPlacement.frame(size: size, edge: .top, offset: 0.5, inset: 26, in: screen)
        XCTAssertEqual(frame.maxY, screen.maxY - 26, accuracy: 0.0001)
    }

    func testFrameForLeftAndRightEdgesCenterVerticallyAndKeepPillHorizontal() {
        let size = CGSize(width: 240, height: 44)
        let left = PillPlacement.frame(size: size, edge: .left, offset: 0.25, inset: 12, in: screen)
        XCTAssertEqual(left.minX, 12, accuracy: 0.0001)
        XCTAssertEqual(left.midY, screen.minY + 0.25 * screen.height, accuracy: 0.0001)
        XCTAssertEqual(left.width, 240, accuracy: 0.0001)

        let right = PillPlacement.frame(size: size, edge: .right, offset: 0.75, inset: 12, in: screen)
        XCTAssertEqual(right.maxX, screen.maxX - 12, accuracy: 0.0001)
        XCTAssertEqual(right.midY, screen.minY + 0.75 * screen.height, accuracy: 0.0001)
    }

    func testFrameClampsInsideTheScreenNearOffsetExtremes() {
        let size = CGSize(width: 240, height: 44)
        let atStart = PillPlacement.frame(size: size, edge: .bottom, offset: 0, inset: 26, in: screen)
        XCTAssertGreaterThanOrEqual(atStart.minX, screen.minX)
        let atEnd = PillPlacement.frame(size: size, edge: .bottom, offset: 1, inset: 26, in: screen)
        XCTAssertLessThanOrEqual(atEnd.maxX, screen.maxX)
    }

    func testIdleDockPanelIsTheNubHitArea() {
        // The idle panel is the 48 by 44 hit area, with the 48 by 8 nub drawn
        // inside it. The long side always runs along the docked edge.
        let horizontal = PillPlacement.frame(
            size: FlowBarDock.panelSize(for: .nub, edge: .bottom),
            edge: .bottom, offset: 0.5, inset: 0, in: screen
        )
        XCTAssertEqual(horizontal.size, CGSize(width: 48, height: 44))
        XCTAssertEqual(horizontal.minY, 0, accuracy: 0.0001)

        let vertical = PillPlacement.frame(
            size: FlowBarDock.panelSize(for: .nub, edge: .left),
            edge: .left, offset: 0.5, inset: 0, in: screen
        )
        XCTAssertEqual(vertical.size, CGSize(width: 44, height: 48))
        XCTAssertEqual(vertical.minX, 0, accuracy: 0.0001)
    }

    func testDockPanelSizeMatchesEdgeOrientation() {
        // The dock panel is placed flush with the edge and draws its own 6 and
        // 10 point insets, so it never appears sideways when it opens.
        let open = FlowBarViewState.stack(hovered: nil, labelWidth: 0)
        let bottom = PillPlacement.frame(size: FlowBarDock.panelSize(for: open, edge: .bottom),
                                         edge: .bottom, offset: 0.5, inset: 0, in: screen)
        XCTAssertEqual(bottom.width, 184, "160 of controls plus shadow room, running along the edge")
        XCTAssertEqual(bottom.height, 62, "10 inset, 40 of control, 12 of shadow room")

        let right = PillPlacement.frame(size: FlowBarDock.panelSize(for: open, edge: .right),
                                        edge: .right, offset: 0.5, inset: 0, in: screen)
        XCTAssertEqual(right.height, 184, "The same 184 now runs up the side")
        XCTAssertEqual(right.width, 62)
        XCTAssertEqual(right.maxX, screen.maxX, accuracy: 0.0001)
    }

    func testTheDictationCapsulePanelStandsOnEndOnTheSideDocks() {
        let listening = FlowBarViewState.level(locked: false, commandWidth: nil)
        let flat = FlowBarDock.panelSize(for: listening, edge: .bottom)
        XCTAssertEqual(flat.width, 144, "120 of capsule plus shadow room")
        XCTAssertEqual(flat.height, 62, "10 inset, 40 of capsule, 12 of shadow room")

        let side = FlowBarDock.panelSize(for: listening, edge: .right)
        XCTAssertEqual(side.width, 62)
        XCTAssertEqual(side.height, 144)
    }
}

final class PillDropZoneTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let pill = CGSize(width: 240, height: 44)

    private func zones() -> [PillDropZone] {
        PillPlacement.dropZones(pillSize: pill, inset: 26, in: screen)
    }

    private func zone(_ edge: PillEdge) -> PillDropZone {
        zones().first { $0.edge == edge }!
    }

    func testDropZonesCoverAllFourEdgesOnce() {
        XCTAssertEqual(zones().count, 4)
        XCTAssertEqual(Set(zones().map(\.edge)), Set(PillEdge.allCases))
    }

    func testDropZonesSitInsetFromEachEdgeAndCentered() {
        XCTAssertEqual(zone(.bottom).rect.minY, 26, accuracy: 0.0001)
        XCTAssertEqual(zone(.bottom).rect.midX, screen.midX, accuracy: 0.0001)
        XCTAssertEqual(zone(.top).rect.maxY, screen.maxY - 26, accuracy: 0.0001)
        XCTAssertEqual(zone(.left).rect.minX, 26, accuracy: 0.0001)
        XCTAssertEqual(zone(.left).rect.midY, screen.midY, accuracy: 0.0001)
        XCTAssertEqual(zone(.right).rect.maxX, screen.maxX - 26, accuracy: 0.0001)
    }

    func testDropZonesKeepThePillSizeByDefault() {
        for zone in zones() {
            XCTAssertEqual(zone.rect.size, pill)
        }
    }

    func testDropZonesCanStandThePillOnEndForSideEdges() {
        // Dragging always previews where the nub will land, whatever state the
        // dock is in when it moves.
        let nub = CGSize(width: FlowBarMetrics.nubLength, height: FlowBarMetrics.nubThickness)
        let standing = PillPlacement.dropZones(pillSize: nub, inset: FlowBarMetrics.nubInset,
                                               in: screen, matchEdgeOrientation: true)
        let byEdge = Dictionary(uniqueKeysWithValues: standing.map { ($0.edge, $0.rect.size) })
        XCTAssertEqual(byEdge[.bottom], CGSize(width: 48, height: 8))
        XCTAssertEqual(byEdge[.top], CGSize(width: 48, height: 8))
        XCTAssertEqual(byEdge[.left], CGSize(width: 8, height: 48))
        XCTAssertEqual(byEdge[.right], CGSize(width: 8, height: 48))
        XCTAssertEqual(standing.first { $0.edge == .bottom }?.rect.minY ?? -1, 6, accuracy: 0.0001)
    }

    func testDropZonesCanStandTheActivePillOnEndForSideEdges() {
        // The active pill drop zones must also stand vertical on the side
        // edges, so dragging the popped-out pill previews the same
        // orientation it will dock in.
        let active = pill // 240x44
        let standing = PillPlacement.dropZones(pillSize: active, inset: 26, in: screen, matchEdgeOrientation: true)
        let byEdge = Dictionary(uniqueKeysWithValues: standing.map { ($0.edge, $0.rect.size) })
        XCTAssertEqual(byEdge[.bottom], active)
        XCTAssertEqual(byEdge[.top], active)
        XCTAssertEqual(byEdge[.left], CGSize(width: 44, height: 240))
        XCTAssertEqual(byEdge[.right], CGSize(width: 44, height: 240))
    }

    func testArmedZonePicksTheNearestZoneWithinTheThreshold() {
        let bottom = zone(.bottom)
        let nudged = CGPoint(x: bottom.rect.midX + 20, y: bottom.rect.midY + 30)
        XCTAssertEqual(PillPlacement.armedZone(pillCenter: nudged, zones: zones())?.edge, .bottom)
    }

    func testArmedZoneArmsExactlyAtTheThresholdEdge() {
        let bottom = zone(.bottom)
        let atLimit = CGPoint(x: bottom.rect.midX, y: bottom.rect.midY + PillPlacement.magnetThreshold)
        XCTAssertEqual(PillPlacement.armedZone(pillCenter: atLimit, zones: zones())?.edge, .bottom)

        let justOutside = CGPoint(x: bottom.rect.midX, y: bottom.rect.midY + PillPlacement.magnetThreshold + 0.5)
        XCTAssertNil(PillPlacement.armedZone(pillCenter: justOutside, zones: zones()))
    }

    func testNoZoneIsArmedInTheMiddleOfTheScreen() {
        XCTAssertNil(PillPlacement.armedZone(pillCenter: CGPoint(x: screen.midX, y: screen.midY), zones: zones()))
    }

    func testArmedZoneRespectsACustomThreshold() {
        let bottom = zone(.bottom)
        let point = CGPoint(x: bottom.rect.midX, y: bottom.rect.midY + 100)
        XCTAssertNil(PillPlacement.armedZone(pillCenter: point, zones: zones(), threshold: 50))
        XCTAssertEqual(PillPlacement.armedZone(pillCenter: point, zones: zones(), threshold: 120)?.edge, .bottom)
    }

    func testMagnetThresholdIs140Points() {
        XCTAssertEqual(PillPlacement.magnetThreshold, 140, accuracy: 0.0001)
    }
}

final class PillDragStateTests: XCTestCase {
    private let origin = CGRect(x: 600, y: 26, width: 260, height: 64)

    func testDragMovesTheFrameOneToOneWithTheCursor() {
        let grab = CGPoint(x: 700, y: 50)
        let state = PillDragState(originFrame: origin, cursor: grab)
        let moved = state.frame(forCursor: CGPoint(x: 780, y: 190))
        XCTAssertEqual(moved.minX, origin.minX + 80, accuracy: 0.0001)
        XCTAssertEqual(moved.minY, origin.minY + 140, accuracy: 0.0001)
        XCTAssertEqual(moved.size, origin.size)
    }

    func testGrabOffsetKeepsTheGrabbedPointUnderTheCursor() {
        let grab = CGPoint(x: 610, y: 30)
        let state = PillDragState(originFrame: origin, cursor: grab)
        let moved = state.frame(forCursor: grab)
        XCTAssertEqual(moved, origin)
    }

    func testCancelRestoresTheOriginFrameAfterMoving() {
        var state = PillDragState(originFrame: origin, cursor: CGPoint(x: 700, y: 50))
        state.didMove = true
        _ = state.frame(forCursor: CGPoint(x: 100, y: 800))
        XCTAssertEqual(state.cancelledFrame, origin)
    }

    func testADragStartsWithNothingArmedAndNoMovement() {
        let state = PillDragState(originFrame: origin, cursor: CGPoint(x: 700, y: 50))
        XCTAssertNil(state.armedEdge)
        XCTAssertFalse(state.didMove)
        XCTAssertEqual(state.originCursor, CGPoint(x: 700, y: 50))
    }
}

final class PillClickSlopTests: XCTestCase {
    private let origin = CGPoint(x: 100, y: 40)

    func testStationaryPressIsAClick() {
        XCTAssertTrue(PillPlacement.isClick(from: origin, to: origin))
    }

    func testMovementInsideSlopIsAClick() {
        XCTAssertTrue(PillPlacement.isClick(from: origin, to: CGPoint(x: 103, y: 41)))
    }

    func testMovementAtSlopIsADrag() {
        XCTAssertFalse(PillPlacement.isClick(from: origin, to: CGPoint(x: 104, y: 40)))
    }

    func testMovementBeyondSlopIsADrag() {
        XCTAssertFalse(PillPlacement.isClick(from: origin, to: CGPoint(x: 140, y: 80)))
    }

    func testClickSlopIsFourPoints() {
        XCTAssertEqual(PillPlacement.clickSlop, 4, accuracy: 0.0001)
    }
}
