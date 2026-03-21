import XCTest
@testable import Finite

final class SnapGuideEngineTests: XCTestCase {

    // MARK: - Drag Snapping

    func testSnapDragNoOtherFrames() {
        let moving = NSRect(x: 100, y: 100, width: 200, height: 150)
        let result = SnapGuideEngine.snapDrag(movingFrame: moving, otherFrames: [])
        XCTAssertEqual(result.adjustedPoint.x, 100)
        XCTAssertEqual(result.adjustedPoint.y, 100)
        XCTAssertTrue(result.guides.isEmpty)
    }

    func testSnapDragSnapsToAlignedEdge() {
        let moving = NSRect(x: 102, y: 100, width: 200, height: 150)
        let other = NSRect(x: 100, y: 300, width: 200, height: 150)
        let result = SnapGuideEngine.snapDrag(movingFrame: moving, otherFrames: [other], scale: 1.0)
        // Left edges are 2px apart, within threshold (8px) — should snap
        XCTAssertEqual(result.adjustedPoint.x, 100, accuracy: 0.5)
    }

    func testSnapDragDoesNotSnapBeyondThreshold() {
        let moving = NSRect(x: 120, y: 100, width: 200, height: 150)
        let other = NSRect(x: 100, y: 300, width: 200, height: 150)
        let result = SnapGuideEngine.snapDrag(movingFrame: moving, otherFrames: [other], scale: 1.0)
        // Left edges are 20px apart, beyond threshold — no snap
        XCTAssertEqual(result.adjustedPoint.x, 120, accuracy: 0.5)
    }

    func testSnapDragGeneratesGuides() {
        let moving = NSRect(x: 100, y: 100, width: 200, height: 150)
        let other = NSRect(x: 100, y: 300, width: 200, height: 150)
        let result = SnapGuideEngine.snapDrag(movingFrame: moving, otherFrames: [other], scale: 1.0)
        // Perfectly aligned left edges — should generate vertical guide
        XCTAssertFalse(result.guides.isEmpty)
        XCTAssertTrue(result.guides.contains { $0.orientation == .vertical })
    }

    func testSnapDragScaleAffectsThreshold() {
        // At scale 0.5, threshold = 8 / 0.5 = 16 canvas pixels
        let moving = NSRect(x: 115, y: 100, width: 200, height: 150)
        let other = NSRect(x: 100, y: 300, width: 200, height: 150)
        let result = SnapGuideEngine.snapDrag(movingFrame: moving, otherFrames: [other], scale: 0.5)
        // 15px apart, within 16px threshold at scale 0.5
        XCTAssertEqual(result.adjustedPoint.x, 100, accuracy: 0.5)
    }

    // MARK: - Resize Snapping

    func testSnapResizeNoOtherFrames() {
        let resizing = NSRect(x: 100, y: 100, width: 200, height: 150)
        let result = SnapGuideEngine.snapResize(resizingFrame: resizing, otherFrames: [])
        XCTAssertEqual(result.adjustedFrame, resizing)
        XCTAssertTrue(result.guides.isEmpty)
    }

    func testSnapResizeSnapsRightEdge() {
        let resizing = NSRect(x: 100, y: 100, width: 198, height: 150)
        let other = NSRect(x: 300, y: 100, width: 200, height: 150)
        let result = SnapGuideEngine.snapResize(resizingFrame: resizing, otherFrames: [other], scale: 1.0)
        // Right edge of resizing is 298, left edge of other is 300 — 2px, should snap
        XCTAssertEqual(result.adjustedFrame.maxX, 300, accuracy: 0.5)
    }
}
