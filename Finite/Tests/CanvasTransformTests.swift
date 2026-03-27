import XCTest
@testable import Finite

final class CanvasTransformTests: XCTestCase {

    // MARK: - Default State

    func testDefaultTransform() {
        let t = CanvasTransform()
        XCTAssertEqual(t.offset, .zero)
        XCTAssertEqual(t.scale, 1.0)
    }

    // MARK: - Point Conversion Roundtrip

    func testCanvasToScreenRoundtrip() {
        let t = CanvasTransform(offset: CGPoint(x: 100, y: 200), scale: 2.0)
        let canvasPoint = CGPoint(x: 150, y: 250)
        let screen = t.screenPoint(from: canvasPoint)
        let back = t.canvasPoint(from: screen)
        XCTAssertEqual(back.x, canvasPoint.x, accuracy: 0.001)
        XCTAssertEqual(back.y, canvasPoint.y, accuracy: 0.001)
    }

    func testScreenToCanvasRoundtrip() {
        let t = CanvasTransform(offset: CGPoint(x: -50, y: 30), scale: 0.5)
        let screenPoint = CGPoint(x: 300, y: 400)
        let canvas = t.canvasPoint(from: screenPoint)
        let back = t.screenPoint(from: canvas)
        XCTAssertEqual(back.x, screenPoint.x, accuracy: 0.001)
        XCTAssertEqual(back.y, screenPoint.y, accuracy: 0.001)
    }

    // MARK: - screenPoint / canvasPoint

    func testScreenPointAtIdentity() {
        let t = CanvasTransform()
        let p = t.screenPoint(from: CGPoint(x: 10, y: 20))
        XCTAssertEqual(p.x, 10)
        XCTAssertEqual(p.y, 20)
    }

    func testScreenPointWithScale() {
        let t = CanvasTransform(offset: .zero, scale: 2.0)
        let p = t.screenPoint(from: CGPoint(x: 10, y: 20))
        XCTAssertEqual(p.x, 20)
        XCTAssertEqual(p.y, 40)
    }

    func testScreenPointWithOffset() {
        let t = CanvasTransform(offset: CGPoint(x: 5, y: 10), scale: 1.0)
        let p = t.screenPoint(from: CGPoint(x: 15, y: 30))
        XCTAssertEqual(p.x, 10)
        XCTAssertEqual(p.y, 20)
    }

    func testCanvasPointWithScaleAndOffset() {
        let t = CanvasTransform(offset: CGPoint(x: 100, y: 100), scale: 2.0)
        let p = t.canvasPoint(from: CGPoint(x: 200, y: 200))
        XCTAssertEqual(p.x, 200)
        XCTAssertEqual(p.y, 200)
    }

    // MARK: - screenRect

    func testScreenRect() {
        let t = CanvasTransform(offset: .zero, scale: 2.0)
        let canvasRect = CGRect(x: 10, y: 20, width: 30, height: 40)
        let screen = t.screenRect(from: canvasRect)
        XCTAssertEqual(screen.origin.x, 20, accuracy: 0.001)
        XCTAssertEqual(screen.origin.y, 40, accuracy: 0.001)
        XCTAssertEqual(screen.width, 60, accuracy: 0.001)
        XCTAssertEqual(screen.height, 80, accuracy: 0.001)
    }

    // MARK: - Zoom

    func testZoomClampsToMinScale() {
        var t = CanvasTransform(offset: .zero, scale: 0.2)
        t.zoom(by: 0.1, anchor: .zero) // 0.2 * 0.1 = 0.02, clamped to 0.1
        XCTAssertEqual(t.scale, CanvasTransform.minScale, accuracy: 0.001)
    }

    func testZoomClampsToMaxScale() {
        var t = CanvasTransform(offset: .zero, scale: 4.0)
        t.zoom(by: 2.0, anchor: .zero) // 4.0 * 2.0 = 8.0, clamped to 5.0
        XCTAssertEqual(t.scale, CanvasTransform.maxScale, accuracy: 0.001)
    }

    func testZoomPreservesAnchor() {
        var t = CanvasTransform(offset: .zero, scale: 1.0)
        let anchor = CGPoint(x: 100, y: 100)
        let canvasBefore = t.canvasPoint(from: anchor)
        t.zoom(by: 2.0, anchor: anchor)
        let canvasAfter = t.canvasPoint(from: anchor)
        XCTAssertEqual(canvasBefore.x, canvasAfter.x, accuracy: 0.001)
        XCTAssertEqual(canvasBefore.y, canvasAfter.y, accuracy: 0.001)
    }

    // MARK: - Pan

    func testPan() {
        var t = CanvasTransform(offset: .zero, scale: 1.0)
        t.pan(by: CGPoint(x: 50, y: -30))
        XCTAssertEqual(t.offset.x, 50, accuracy: 0.001)
        XCTAssertEqual(t.offset.y, -30, accuracy: 0.001)
    }

    func testPanScalesWithZoom() {
        var t = CanvasTransform(offset: .zero, scale: 2.0)
        t.pan(by: CGPoint(x: 100, y: 100))
        // delta / scale = 100 / 2 = 50
        XCTAssertEqual(t.offset.x, 50, accuracy: 0.001)
        XCTAssertEqual(t.offset.y, 50, accuracy: 0.001)
    }

    // MARK: - zoomToFit

    func testZoomToFitEmptyReturnsNil() {
        let result = CanvasTransform.zoomToFit(rects: [], in: CGSize(width: 800, height: 600))
        XCTAssertNil(result)
    }

    func testZoomToFitSingleRect() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let result = CanvasTransform.zoomToFit(rects: [rect], in: CGSize(width: 800, height: 600), padding: 0)
        XCTAssertNotNil(result)
        // Content exactly fits viewport at scale 2.0, capped at 2.0
        XCTAssertEqual(result!.scale, 2.0, accuracy: 0.001)
    }

    func testZoomToFitMultipleRects() {
        let rects = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 900, y: 0, width: 100, height: 100),
        ]
        let result = CanvasTransform.zoomToFit(rects: rects, in: CGSize(width: 1000, height: 600), padding: 0)
        XCTAssertNotNil(result)
        // Content spans 0..1000 x 0..100, viewport is 1000x600
        // Scale = min(1000/1000, 600/100, 2.0) = 1.0
        XCTAssertEqual(result!.scale, 1.0, accuracy: 0.001)
    }
}
