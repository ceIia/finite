import Foundation
import CoreGraphics
import QuartzCore

/// Affine transform for the infinite canvas.
struct CanvasTransform {
    static let minScale: CGFloat = 0.1
    static let maxScale: CGFloat = 5.0

    var offset: CGPoint = .zero
    var scale: CGFloat = 1.0

    var affineTransform: CGAffineTransform {
        CGAffineTransform(scaleX: scale, y: scale)
            .translatedBy(x: -offset.x, y: -offset.y)
    }

    func canvasPoint(from screenPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: screenPoint.x / scale + offset.x,
            y: screenPoint.y / scale + offset.y
        )
    }

    func screenPoint(from canvasPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: (canvasPoint.x - offset.x) * scale,
            y: (canvasPoint.y - offset.y) * scale
        )
    }

    func screenRect(from canvasRect: CGRect) -> CGRect {
        let bl = screenPoint(from: CGPoint(x: canvasRect.minX, y: canvasRect.minY))
        let tr = screenPoint(from: CGPoint(x: canvasRect.maxX, y: canvasRect.maxY))
        return CGRect(
            x: min(bl.x, tr.x),
            y: min(bl.y, tr.y),
            width: abs(tr.x - bl.x),
            height: abs(tr.y - bl.y)
        )
    }

    mutating func zoom(by factor: CGFloat, anchor: CGPoint) {
        let canvasAnchor = canvasPoint(from: anchor)
        scale = min(max(scale * factor, Self.minScale), Self.maxScale)
        offset = CGPoint(
            x: canvasAnchor.x - anchor.x / scale,
            y: canvasAnchor.y - anchor.y / scale
        )
    }

    mutating func pan(by delta: CGPoint) {
        offset = CGPoint(
            x: offset.x + delta.x / scale,
            y: offset.y + delta.y / scale
        )
    }

    var layerTransform: CATransform3D {
        CATransform3DMakeAffineTransform(affineTransform)
    }

    /// Compute a transform that fits the given rects within the viewport bounds with padding.
    static func zoomToFit(rects: [CGRect], in viewportSize: CGSize, padding: CGFloat = 40) -> CanvasTransform? {
        guard !rects.isEmpty else { return nil }

        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        for r in rects {
            minX = min(minX, r.minX)
            minY = min(minY, r.minY)
            maxX = max(maxX, r.maxX)
            maxY = max(maxY, r.maxY)
        }

        let contentW = maxX - minX
        let contentH = maxY - minY
        guard contentW > 0, contentH > 0 else { return nil }

        let availW = viewportSize.width - padding * 2
        let availH = viewportSize.height - padding * 2
        guard availW > 0, availH > 0 else { return nil }

        let fitScale = min(min(availW / contentW, availH / contentH), 2.0)
        let clampedScale = min(max(fitScale, minScale), maxScale)

        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2

        let newOffset = CGPoint(
            x: centerX - viewportSize.width / (2 * clampedScale),
            y: centerY - viewportSize.height / (2 * clampedScale)
        )

        return CanvasTransform(offset: newOffset, scale: clampedScale)
    }
}
