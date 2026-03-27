import AppKit

// Title bar for terminal nodes — transparent, kept for hit testing only.
// Visual rendering is done by CanvasGridView to avoid sublayerTransform clipping.
class NodeTitleBarView: NSView {
    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }
}
