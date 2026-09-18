import CoreGraphics

/// The screen edge the persistent pill docks to.
enum PillEdge: String, CaseIterable, Identifiable, Codable {
    case bottom
    case top
    case left
    case right

    var id: String { rawValue }

    /// `true` for the edges that run left-to-right, where the pill's offset
    /// moves it horizontally along the edge.
    var isHorizontal: Bool {
        self == .bottom || self == .top
    }
}

/// Pure geometry for placing and docking the pill panel. Kept free of AppKit
/// types so it can be unit tested without a screen.
enum PillPlacement {
    /// The edge of `screenFrame` closest to `center`.
    static func nearestEdge(center: CGPoint, in screenFrame: CGRect) -> PillEdge {
        let distanceToBottom = center.y - screenFrame.minY
        let distanceToTop = screenFrame.maxY - center.y
        let distanceToLeft = center.x - screenFrame.minX
        let distanceToRight = screenFrame.maxX - center.x
        let distances: [(PillEdge, CGFloat)] = [
            (.bottom, distanceToBottom), (.top, distanceToTop),
            (.left, distanceToLeft), (.right, distanceToRight),
        ]
        return distances.min { $0.1 < $1.1 }!.0
    }

    /// `center`'s position along `edge`, normalized to 0...1 across
    /// `screenFrame`. Bottom/top read left-to-right; left/right read
    /// bottom-to-top.
    static func normalizedOffset(center: CGPoint, edge: PillEdge, in screenFrame: CGRect) -> Double {
        let fraction: CGFloat
        if edge.isHorizontal {
            fraction = screenFrame.width > 0 ? (center.x - screenFrame.minX) / screenFrame.width : 0.5
        } else {
            fraction = screenFrame.height > 0 ? (center.y - screenFrame.minY) / screenFrame.height : 0.5
        }
        return Double(min(1, max(0, fraction)))
    }

    /// The panel frame for `size` docked to `edge` at `offset`, `inset`
    /// points from that edge, clamped inside `screenFrame`.
    static func frame(size: CGSize, edge: PillEdge, offset: Double, inset: CGFloat, in screenFrame: CGRect) -> CGRect {
        let clampedOffset = CGFloat(min(1, max(0, offset)))
        var origin: CGPoint
        switch edge {
        case .bottom:
            let x = screenFrame.minX + clampedOffset * screenFrame.width - size.width / 2
            origin = CGPoint(x: x, y: screenFrame.minY + inset)
        case .top:
            let x = screenFrame.minX + clampedOffset * screenFrame.width - size.width / 2
            origin = CGPoint(x: x, y: screenFrame.maxY - inset - size.height)
        case .left:
            let y = screenFrame.minY + clampedOffset * screenFrame.height - size.height / 2
            origin = CGPoint(x: screenFrame.minX + inset, y: y)
        case .right:
            let y = screenFrame.minY + clampedOffset * screenFrame.height - size.height / 2
            origin = CGPoint(x: screenFrame.maxX - inset - size.width, y: y)
        }
        var frame = CGRect(origin: origin, size: size)
        clamp(&frame, inside: screenFrame)
        return frame
    }

    /// Keeps `frame` fully inside `bounds`, sliding it in rather than
    /// resizing it. A pill wider or taller than `bounds` is centered.
    private static func clamp(_ frame: inout CGRect, inside bounds: CGRect) {
        if frame.width >= bounds.width {
            frame.origin.x = bounds.midX - frame.width / 2
        } else {
            frame.origin.x = min(max(frame.origin.x, bounds.minX), bounds.maxX - frame.width)
        }
        if frame.height >= bounds.height {
            frame.origin.y = bounds.midY - frame.height / 2
        } else {
            frame.origin.y = min(max(frame.origin.y, bounds.minY), bounds.maxY - frame.height)
        }
    }
}

/// One of the four docked positions offered while the pill is dragged.
struct PillDropZone: Equatable, Identifiable {
    let edge: PillEdge
    let rect: CGRect

    var id: PillEdge { edge }
}

extension PillPlacement {
    /// How close the pill center must come to a zone center before that zone
    /// arms and the drop snaps to it.
    static let magnetThreshold: CGFloat = 140

    /// Cursor travel below this, from mouse-down to mouse-up, is a click
    /// rather than a drag. The Record control uses that so a press still
    /// starts capture while a real drag still docks the pill.
    static let clickSlop: CGFloat = 4

    /// `true` when `current` stayed inside `slop` of `origin`.
    static func isClick(from origin: CGPoint, to current: CGPoint, slop: CGFloat = clickSlop) -> Bool {
        let dx = current.x - origin.x
        let dy = current.y - origin.y
        return (dx * dx + dy * dy) < slop * slop
    }

    /// The four docked rects a pill of `pillSize` would occupy, one per edge,
    /// each centered along its edge. Set `matchEdgeOrientation` to stand the
    /// pill on end for the left and right edges.
    static func dropZones(
        pillSize: CGSize,
        inset: CGFloat,
        in screenFrame: CGRect,
        matchEdgeOrientation: Bool = false
    ) -> [PillDropZone] {
        PillEdge.allCases.map { edge in
            let size: CGSize
            if matchEdgeOrientation, !edge.isHorizontal {
                size = CGSize(width: pillSize.height, height: pillSize.width)
            } else {
                size = pillSize
            }
            return PillDropZone(
                edge: edge,
                rect: frame(size: size, edge: edge, offset: 0.5, inset: inset, in: screenFrame)
            )
        }
    }

    /// The zone whose center is nearest `pillCenter`, or `nil` when every
    /// zone center sits further away than `threshold`.
    static func armedZone(
        pillCenter: CGPoint,
        zones: [PillDropZone],
        threshold: CGFloat = magnetThreshold
    ) -> PillDropZone? {
        let ranked = zones.map { zone -> (PillDropZone, CGFloat) in
            let dx = zone.rect.midX - pillCenter.x
            let dy = zone.rect.midY - pillCenter.y
            return (zone, (dx * dx + dy * dy).squareRoot())
        }
        guard let nearest = ranked.min(by: { $0.1 < $1.1 }), nearest.1 <= threshold else { return nil }
        return nearest.0
    }
}

/// The live state of a pill drag. Pure geometry so the move, the cancel, and
/// the armed zone can be tested without a screen.
struct PillDragState: Equatable {
    /// The panel frame when the drag started. A cancel returns here.
    let originFrame: CGRect
    /// Screen cursor at mouse-down, used to distinguish a click from a drag.
    let originCursor: CGPoint
    /// Cursor position at mouse-down, relative to the frame origin.
    let grabOffset: CGPoint
    /// The zone currently under the magnet, if any.
    var armedEdge: PillEdge?
    /// `true` once the cursor has left click slop, so a plain click is not a drag.
    var didMove = false

    init(originFrame: CGRect, cursor: CGPoint) {
        self.originFrame = originFrame
        self.originCursor = cursor
        self.grabOffset = CGPoint(x: cursor.x - originFrame.minX, y: cursor.y - originFrame.minY)
    }

    /// The frame that keeps the grabbed point under `cursor`, moving 1:1.
    func frame(forCursor cursor: CGPoint) -> CGRect {
        CGRect(
            origin: CGPoint(x: cursor.x - grabOffset.x, y: cursor.y - grabOffset.y),
            size: originFrame.size
        )
    }

    /// The frame to animate back to when the user presses Escape.
    var cancelledFrame: CGRect { originFrame }
}
