import AppKit

/// Snap guide line drawn during drag/resize when nodes align.
struct SnapGuide {
    enum Orientation { case horizontal, vertical }
    let orientation: Orientation
    let position: CGFloat   // x for vertical, y for horizontal
    let start: CGFloat
    let end: CGFloat
}

/// Result of a snap calculation — adjusted point plus guide lines to draw.
struct SnapResult {
    let adjustedPoint: CGPoint
    let guides: [SnapGuide]
}

/// Result of a snap calculation for resize — adjusted frame plus guide lines.
struct SnapResizeResult {
    let adjustedFrame: NSRect
    let guides: [SnapGuide]
}

enum SnapGuideEngine {
    /// Screen-space threshold in points. Divided by scale to get canvas-space threshold.
    static let screenThreshold: CGFloat = 8

    // MARK: - Drag Snapping

    static func snapDrag(movingFrame: NSRect, otherFrames: [NSRect],
                         scale: CGFloat = 1.0) -> SnapResult {
        let threshold = screenThreshold / max(scale, 0.1)
        var bestDX: CGFloat?
        var bestDY: CGFloat?
        var guides: [SnapGuide] = []

        let movingEdgesX: [CGFloat] = [movingFrame.minX, movingFrame.midX, movingFrame.maxX]
        let movingEdgesY: [CGFloat] = [movingFrame.minY, movingFrame.midY, movingFrame.maxY]

        for other in otherFrames {
            let otherEdgesX: [CGFloat] = [other.minX, other.midX, other.maxX]
            let otherEdgesY: [CGFloat] = [other.minY, other.midY, other.maxY]

            for mx in movingEdgesX {
                for ox in otherEdgesX {
                    let dist = ox - mx
                    if abs(dist) < threshold {
                        if bestDX == nil || abs(dist) < abs(bestDX!) {
                            bestDX = dist
                        }
                    }
                }
            }

            for my in movingEdgesY {
                for oy in otherEdgesY {
                    let dist = oy - my
                    if abs(dist) < threshold {
                        if bestDY == nil || abs(dist) < abs(bestDY!) {
                            bestDY = dist
                        }
                    }
                }
            }
        }

        var adjusted = movingFrame.origin
        if let dx = bestDX { adjusted.x += dx }
        if let dy = bestDY { adjusted.y += dy }

        let snappedFrame = NSRect(origin: adjusted, size: movingFrame.size)

        // Generate guide lines for the snapped position
        for other in otherFrames {
            let otherEdgesX: [CGFloat] = [other.minX, other.midX, other.maxX]
            let otherEdgesY: [CGFloat] = [other.minY, other.midY, other.maxY]
            let snappedEdgesX: [CGFloat] = [snappedFrame.minX, snappedFrame.midX, snappedFrame.maxX]
            let snappedEdgesY: [CGFloat] = [snappedFrame.minY, snappedFrame.midY, snappedFrame.maxY]

            for sx in snappedEdgesX {
                for ox in otherEdgesX {
                    if abs(sx - ox) < 0.5 {
                        let minY = min(snappedFrame.minY, other.minY) - 4
                        let maxY = max(snappedFrame.maxY, other.maxY) + 4
                        guides.append(SnapGuide(orientation: .vertical, position: ox,
                                                start: minY, end: maxY))
                    }
                }
            }

            for sy in snappedEdgesY {
                for oy in otherEdgesY {
                    if abs(sy - oy) < 0.5 {
                        let minX = min(snappedFrame.minX, other.minX) - 4
                        let maxX = max(snappedFrame.maxX, other.maxX) + 4
                        guides.append(SnapGuide(orientation: .horizontal, position: oy,
                                                start: minX, end: maxX))
                    }
                }
            }
        }

        return SnapResult(adjustedPoint: adjusted, guides: guides)
    }

    // MARK: - Resize Snapping

    static func snapResize(resizingFrame: NSRect, otherFrames: [NSRect],
                           scale: CGFloat = 1.0) -> SnapResizeResult {
        let threshold = screenThreshold / max(scale, 0.1)

        // Find the closest snap target for each edge independently
        struct EdgeSnap {
            let targetPos: CGFloat
            let distance: CGFloat
            let otherFrame: NSRect
        }

        var rightSnap: EdgeSnap?
        var leftSnap: EdgeSnap?
        var topSnap: EdgeSnap?
        var bottomSnap: EdgeSnap?

        let frame = resizingFrame

        for other in otherFrames {
            let otherEdgesX: [CGFloat] = [other.minX, other.midX, other.maxX]
            let otherEdgesY: [CGFloat] = [other.minY, other.midY, other.maxY]

            for ox in otherEdgesX {
                let rightDist = abs(frame.maxX - ox)
                if rightDist < threshold && (rightSnap == nil || rightDist < rightSnap!.distance) {
                    rightSnap = EdgeSnap(targetPos: ox, distance: rightDist, otherFrame: other)
                }
                let leftDist = abs(frame.minX - ox)
                if leftDist < threshold && (leftSnap == nil || leftDist < leftSnap!.distance) {
                    leftSnap = EdgeSnap(targetPos: ox, distance: leftDist, otherFrame: other)
                }
            }

            for oy in otherEdgesY {
                let topDist = abs(frame.maxY - oy)
                if topDist < threshold && (topSnap == nil || topDist < topSnap!.distance) {
                    topSnap = EdgeSnap(targetPos: oy, distance: topDist, otherFrame: other)
                }
                let bottomDist = abs(frame.minY - oy)
                if bottomDist < threshold && (bottomSnap == nil || bottomDist < bottomSnap!.distance) {
                    bottomSnap = EdgeSnap(targetPos: oy, distance: bottomDist, otherFrame: other)
                }
            }
        }

        // Apply all snaps at once and generate guides
        var result = resizingFrame
        var guides: [SnapGuide] = []

        if let snap = rightSnap {
            result.size.width = snap.targetPos - result.origin.x
            let minY = min(result.minY, snap.otherFrame.minY) - 4
            let maxY = max(result.maxY, snap.otherFrame.maxY) + 4
            guides.append(SnapGuide(orientation: .vertical, position: snap.targetPos,
                                    start: minY, end: maxY))
        }
        if let snap = leftSnap {
            let oldMaxX = result.maxX
            result.origin.x = snap.targetPos
            result.size.width = oldMaxX - snap.targetPos
            let minY = min(result.minY, snap.otherFrame.minY) - 4
            let maxY = max(result.maxY, snap.otherFrame.maxY) + 4
            guides.append(SnapGuide(orientation: .vertical, position: snap.targetPos,
                                    start: minY, end: maxY))
        }
        if let snap = topSnap {
            result.size.height = snap.targetPos - result.origin.y
            let minX = min(result.minX, snap.otherFrame.minX) - 4
            let maxX = max(result.maxX, snap.otherFrame.maxX) + 4
            guides.append(SnapGuide(orientation: .horizontal, position: snap.targetPos,
                                    start: minX, end: maxX))
        }
        if let snap = bottomSnap {
            let oldMaxY = result.maxY
            result.origin.y = snap.targetPos
            result.size.height = oldMaxY - snap.targetPos
            let minX = min(result.minX, snap.otherFrame.minX) - 4
            let maxX = max(result.maxX, snap.otherFrame.maxX) + 4
            guides.append(SnapGuide(orientation: .horizontal, position: snap.targetPos,
                                    start: minX, end: maxX))
        }

        return SnapResizeResult(adjustedFrame: result, guides: guides)
    }
}
