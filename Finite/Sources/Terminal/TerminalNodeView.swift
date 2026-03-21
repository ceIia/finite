import AppKit

// Terminal node with title bar, resize handles, drag/move, focus indication,
// multi-selection, snap guides, cursor feedback, and cell size indicator.
class TerminalNodeView: NSView {

    // MARK: - Constants

    static let titleBarHeight: CGFloat = 24
    static let resizeHandleWidth: CGFloat = 6
    static let cornerHandleSize: CGFloat = 10
    static let minimumNodeSize = NSSize(width: 200, height: 150)
    static let closeButtonWidth: CGFloat = 28 // padding(6) + diameter(16) + padding(6)

    // MARK: - Hit Zones

    enum NodeHitZone {
        case titleBar
        case resizeEdge(Edge)
        case resizeCorner(Corner)
        case terminal

        enum Edge { case left, right, top, bottom }
        enum Corner { case topLeft, topRight, bottomLeft, bottomRight }
    }

    // MARK: - Interaction State

    private enum InteractionMode {
        case none
        case closePending
        case dragging(initialOrigin: CGPoint, initialMouseCanvas: CGPoint,
                      group: [(node: TerminalNodeView, initialOrigin: CGPoint)]?)
        case resizing(zone: NodeHitZone, initialFrame: NSRect, initialMouseCanvas: CGPoint)
    }

    // MARK: - Properties

    let titleBarView: NodeTitleBarView
    let terminalView: TerminalSurfaceView
    weak var canvasView: CanvasView?
    private var interactionMode: InteractionMode = .none
    private var didPushCursor = false

    var title: String = "Terminal" {
        didSet { canvasView?.gridView?.needsDisplay = true }
    }

    // MARK: - Focus & Selection (state only — appearance updated by manager's syncVisuals)

    var isFocused: Bool = false
    var isSelected: Bool = false
    var isCloseButtonHovered: Bool = false

    /// Called by the manager's syncVisuals() to update border/alpha appearance.
    func updateAppearance() {
        if case .none = interactionMode {} else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.animator().alphaValue = isFocused ? 1.0 : (isSelected ? 0.92 : 0.85)
        }
        if isFocused {
            layer?.borderWidth = 2
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        } else if isSelected {
            layer?.borderWidth = 1.5
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
        } else {
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    /// Brief highlight animation triggered by sidebar hover.
    func pulse() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = 1.0
            self.layer?.borderWidth = 3
            self.layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        } completionHandler: {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self.updateAppearance()
            }
        }
    }

    // MARK: - Cell Size Indicator

    private lazy var cellSizeIndicator: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
        label.layer?.cornerRadius = 6
        label.isHidden = true
        return label
    }()

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        let tbHeight = Self.titleBarHeight
        titleBarView = NodeTitleBarView(frame: NSRect(
            x: 0, y: frameRect.height - tbHeight,
            width: frameRect.width, height: tbHeight
        ))
        terminalView = TerminalSurfaceView(frame: NSRect(
            origin: .zero,
            size: NSSize(width: frameRect.width, height: frameRect.height - tbHeight)
        ))

        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = false
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        terminalView.nodeView = self
        terminalView.wantsLayer = true

        addSubview(terminalView)
        addSubview(titleBarView)

        titleBarView.onClose = { [weak self] in
            guard let self, let manager = self.canvasView?.nodeManager else { return }
            manager.requestCloseNode(self)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        layer?.masksToBounds = false
        applyTerminalCornerMask()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let tbHeight = Self.titleBarHeight
        titleBarView.frame = NSRect(
            x: 0, y: newSize.height - tbHeight,
            width: newSize.width, height: tbHeight
        )
        titleBarView.needsLayout = true
        terminalView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: newSize.width, height: newSize.height - tbHeight)
        )
        applyTerminalCornerMask()
    }

    private func applyTerminalCornerMask() {
        guard let tvLayer = terminalView.layer else { return }
        if tvLayer.mask == nil {
            tvLayer.mask = CAShapeLayer()
        }
        (tvLayer.mask as? CAShapeLayer)?.path = CGPath(
            roundedRect: terminalView.bounds,
            cornerWidth: 6, cornerHeight: 6, transform: nil
        )
    }

    /// Convert a canvas-space point to a point local to this node.
    func localPoint(from canvasPoint: CGPoint) -> CGPoint {
        CGPoint(x: canvasPoint.x - frame.origin.x, y: canvasPoint.y - frame.origin.y)
    }

    // MARK: - Hit Zone Detection

    func hitZone(for point: CGPoint) -> NodeHitZone {
        let rw = Self.resizeHandleWidth
        let cs = Self.cornerHandleSize
        let w = bounds.width
        let h = bounds.height

        let inTitleBar = point.y > h - Self.titleBarHeight

        let nearLeft = point.x < rw
        let nearRight = point.x > w - rw
        let nearBottom = point.y < rw
        let nearTop = point.y > h - rw

        let cornerLeft = point.x < cs
        let cornerRight = point.x > w - cs
        let cornerBottom = point.y < cs
        let cornerTop = point.y > h - cs

        // Check resize corners (top corners take priority over title bar)
        if cornerBottom && cornerLeft { return .resizeCorner(.bottomLeft) }
        if cornerBottom && cornerRight { return .resizeCorner(.bottomRight) }
        if cornerTop && cornerLeft { return .resizeCorner(.topLeft) }
        if cornerTop && cornerRight { return .resizeCorner(.topRight) }

        // Check resize edges (top edge takes priority over title bar)
        if nearLeft { return .resizeEdge(.left) }
        if nearRight { return .resizeEdge(.right) }
        if nearBottom { return .resizeEdge(.bottom) }
        if nearTop { return .resizeEdge(.top) }

        if inTitleBar { return .titleBar }

        return .terminal
    }

    // MARK: - Close Button Detection

    private func isInCloseButtonArea(_ nodeLocal: CGPoint) -> Bool {
        nodeLocal.x < Self.closeButtonWidth && nodeLocal.y > bounds.height - Self.titleBarHeight
    }

    // MARK: - Cursor Helpers

    static func cursor(for zone: NodeHitZone) -> NSCursor {
        switch zone {
        case .titleBar:
            return .openHand
        case .resizeEdge(.left), .resizeEdge(.right):
            return .resizeLeftRight
        case .resizeEdge(.top), .resizeEdge(.bottom):
            return .resizeUpDown
        case .resizeCorner:
            return .crosshair
        case .terminal:
            return .iBeam
        }
    }

    private func pushInteractionCursor() {
        switch interactionMode {
        case .dragging:
            NSCursor.closedHand.push()
            didPushCursor = true
        case .resizing(let zone, _, _):
            Self.cursor(for: zone).push()
            didPushCursor = true
        case .none, .closePending:
            break
        }
    }

    // MARK: - Interaction Highlight

    private func setInteractionHighlight(_ active: Bool) {
        if active {
            layer?.borderWidth = 2
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        } else {
            updateAppearance()
        }
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        guard let canvas = canvasView, let manager = canvas.nodeManager else { return }

        let canvasLocal = canvas.convert(event.locationInWindow, from: nil)
        let canvasPoint = canvas.canvasTransform.canvasPoint(from: canvasLocal)
        let nodeLocal = localPoint(from: canvasPoint)

        let zone = hitZone(for: nodeLocal)
        let optionHeld = event.modifierFlags.contains(.option)
        let cmdHeld = event.modifierFlags.contains(.command)

        // Determine if this is a drag-initiating zone
        let isDragZone: Bool
        switch zone {
        case .titleBar: isDragZone = true
        case .terminal: isDragZone = optionHeld || cmdHeld
        default: isDragZone = false
        }

        switch zone {
        case _ where isDragZone:
            // Close button: set pending, complete on mouseUp
            if case .titleBar = zone, isInCloseButtonArea(nodeLocal) {
                interactionMode = .closePending
                return
            }

            // Cmd+click: toggle selection, no drag
            if cmdHeld {
                manager.handleClick(self, modifiers: event.modifierFlags)
                return
            }

            // If unselected: sole-select + focus
            // If already selected: just focus (preserve group for drag)
            if !manager.isSelected(self) {
                manager.handleClick(self, modifiers: [])
            } else {
                manager.focusOnly(self)
            }

            // Build group drag info if multiple selected
            let groupDrag: [(node: TerminalNodeView, initialOrigin: CGPoint)]?
            if manager.selectedNodeViews.count > 1 {
                groupDrag = manager.selectedNodeViews.map { ($0, $0.frame.origin) }
            } else {
                groupDrag = nil
            }

            interactionMode = .dragging(
                initialOrigin: frame.origin,
                initialMouseCanvas: canvasPoint,
                group: groupDrag
            )
            pushInteractionCursor()
            setInteractionHighlight(true)

        case .resizeEdge, .resizeCorner:
            interactionMode = .resizing(
                zone: zone,
                initialFrame: frame,
                initialMouseCanvas: canvasPoint
            )
            pushInteractionCursor()
            setInteractionHighlight(true)
            showCellSizeIndicator()
        case .terminal, .titleBar:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let canvas = canvasView else { return }

        let canvasLocal = canvas.convert(event.locationInWindow, from: nil)
        let currentCanvas = canvas.canvasTransform.canvasPoint(from: canvasLocal)

        switch interactionMode {
        case .none, .closePending:
            break
        case .dragging(let initialOrigin, let initialMouse, let group):
            let delta = CGPoint(x: currentCanvas.x - initialMouse.x,
                                y: currentCanvas.y - initialMouse.y)
            var newOrigin = CGPoint(x: initialOrigin.x + delta.x,
                                    y: initialOrigin.y + delta.y)

            // Magnetic snapping (Cmd disables). Exclude all selected nodes from otherFrames.
            var snapDelta = CGPoint.zero
            if !event.modifierFlags.contains(.command), let canvas = canvasView {
                let selectedSet = Set(group?.map { ObjectIdentifier($0.node) } ?? [ObjectIdentifier(self)])
                let proposedFrame = NSRect(origin: newOrigin, size: frame.size)
                let otherFrames = canvas.terminalNodes.compactMap {
                    selectedSet.contains(ObjectIdentifier($0)) ? nil : $0.frame
                }
                let result = SnapGuideEngine.snapDrag(movingFrame: proposedFrame, otherFrames: otherFrames,
                                                       scale: canvas.canvasTransform.scale)
                snapDelta = CGPoint(x: result.adjustedPoint.x - newOrigin.x,
                                    y: result.adjustedPoint.y - newOrigin.y)
                newOrigin = result.adjustedPoint
                canvas.snapGuides = result.guides
            }

            setFrameOrigin(newOrigin)

            // Move all other selected nodes by the same delta
            if let group = group {
                for (node, initOrig) in group where node !== self {
                    let nodeOrigin = CGPoint(
                        x: initOrig.x + delta.x + snapDelta.x,
                        y: initOrig.y + delta.y + snapDelta.y
                    )
                    node.setFrameOrigin(nodeOrigin)
                }
            }

            canvasView?.gridView?.needsDisplay = true

        case .resizing(let zone, let initialFrame, let initialMouse):
            applyResize(zone: zone, initialFrame: initialFrame,
                        initialMouse: initialMouse, currentMouse: currentCanvas,
                        snapEnabled: !event.modifierFlags.contains(.command))
            updateCellSizeIndicator()
            canvasView?.gridView?.needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        // Handle close button release
        if case .closePending = interactionMode {
            interactionMode = .none
            // Check if cursor is still in close button area
            if let canvas = canvasView {
                let canvasLocal = canvas.convert(event.locationInWindow, from: nil)
                let canvasPoint = canvas.canvasTransform.canvasPoint(from: canvasLocal)
                let nodeLocal = CGPoint(x: canvasPoint.x - frame.origin.x,
                                        y: canvasPoint.y - frame.origin.y)
                if isInCloseButtonArea(nodeLocal) {
                    titleBarView.onClose?()
                }
            }
            return
        }

        let wasInteracting: Bool
        if case .none = interactionMode { wasInteracting = false } else { wasInteracting = true }
        interactionMode = .none
        if didPushCursor {
            NSCursor.pop()
            didPushCursor = false
        }
        setInteractionHighlight(false)
        hideCellSizeIndicator()
        canvasView?.snapGuides = []

        // Bring to front AFTER interaction completes (avoids breaking mouse tracking)
        if wasInteracting {
            canvasView?.bringNodeToFront(self)
        }
    }

    // MARK: - Right-Click Context Menu

    override func rightMouseDown(with event: NSEvent) {
        guard let manager = canvasView?.nodeManager else { return }

        // If right-clicking an unselected node, select only it
        if !manager.isSelected(self) {
            manager.handleClick(self, modifiers: [])
        }

        let menu = NSMenu()
        let selected = manager.selectedNodeViews

        if selected.count > 1 {
            let closeItem = NSMenuItem(title: "Close \(selected.count) Terminals", action: #selector(contextCloseSelected), keyEquivalent: "")
            closeItem.target = self
            menu.addItem(closeItem)

            let dupItem = NSMenuItem(title: "Duplicate Terminal", action: nil, keyEquivalent: "")
            dupItem.isEnabled = false
            menu.addItem(dupItem)
        } else {
            let closeItem = NSMenuItem(title: "Close Terminal", action: #selector(contextCloseSingle), keyEquivalent: "")
            closeItem.target = self
            menu.addItem(closeItem)

            let dupItem = NSMenuItem(title: "Duplicate Terminal", action: #selector(contextDuplicate), keyEquivalent: "")
            dupItem.target = self
            menu.addItem(dupItem)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func contextCloseSingle() {
        canvasView?.nodeManager?.requestCloseNode(self)
    }

    @objc private func contextCloseSelected() {
        guard let manager = canvasView?.nodeManager else { return }
        guard let window = window else {
            manager.closeSelectedNodes()
            return
        }

        guard manager.selectedNodesNeedConfirmation() else {
            manager.closeSelectedNodes()
            return
        }

        let count = manager.selectedNodeViews.count
        let alert = NSAlert()
        alert.messageText = "Close \(count) terminals?"
        alert.informativeText = "One or more terminals have running processes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close All")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                manager.closeSelectedNodes()
            }
        }
    }

    @objc private func contextDuplicate() {
        canvasView?.nodeManager?.duplicateNode(self)
    }

    // MARK: - Cell Size Indicator

    private func showCellSizeIndicator() {
        guard let canvas = canvasView else { return }
        if cellSizeIndicator.superview == nil {
            canvas.addSubview(cellSizeIndicator)
        }
        cellSizeIndicator.isHidden = false
        updateCellSizeIndicator()
    }

    private func updateCellSizeIndicator() {
        guard let surface = terminalView.surface else { return }
        let size = ghostty_surface_size(surface)
        cellSizeIndicator.stringValue = "  \(size.columns) × \(size.rows)  "
        cellSizeIndicator.sizeToFit()

        let indicatorW = cellSizeIndicator.frame.width
        let centerX = frame.midX - indicatorW / 2
        let topY = frame.maxY + 8
        cellSizeIndicator.frame.origin = CGPoint(x: centerX, y: topY)
    }

    private func hideCellSizeIndicator() {
        cellSizeIndicator.isHidden = true
        cellSizeIndicator.removeFromSuperview()
    }

    // MARK: - Resize Logic

    private func applyResize(zone: NodeHitZone, initialFrame: NSRect,
                             initialMouse: CGPoint, currentMouse: CGPoint,
                             snapEnabled: Bool) {
        let dx = currentMouse.x - initialMouse.x
        let dy = currentMouse.y - initialMouse.y
        let minW = Self.minimumNodeSize.width
        let minH = Self.minimumNodeSize.height

        var newFrame = initialFrame

        switch zone {
        case .resizeEdge(.left):
            let proposedW = initialFrame.width - dx
            let w = max(proposedW, minW)
            newFrame.origin.x = initialFrame.maxX - w
            newFrame.size.width = w

        case .resizeEdge(.right):
            newFrame.size.width = max(initialFrame.width + dx, minW)

        case .resizeEdge(.bottom):
            let proposedH = initialFrame.height - dy
            let h = max(proposedH, minH)
            newFrame.origin.y = initialFrame.maxY - h
            newFrame.size.height = h

        case .resizeEdge(.top):
            newFrame.size.height = max(initialFrame.height + dy, minH)

        case .resizeCorner(.bottomLeft):
            let w = max(initialFrame.width - dx, minW)
            let h = max(initialFrame.height - dy, minH)
            newFrame.origin.x = initialFrame.maxX - w
            newFrame.origin.y = initialFrame.maxY - h
            newFrame.size.width = w
            newFrame.size.height = h

        case .resizeCorner(.bottomRight):
            let h = max(initialFrame.height - dy, minH)
            newFrame.origin.y = initialFrame.maxY - h
            newFrame.size.width = max(initialFrame.width + dx, minW)
            newFrame.size.height = h

        case .resizeCorner(.topLeft):
            let w = max(initialFrame.width - dx, minW)
            newFrame.origin.x = initialFrame.maxX - w
            newFrame.size.width = w
            newFrame.size.height = max(initialFrame.height + dy, minH)

        case .resizeCorner(.topRight):
            newFrame.size.width = max(initialFrame.width + dx, minW)
            newFrame.size.height = max(initialFrame.height + dy, minH)

        case .titleBar, .terminal:
            break
        }

        if snapEnabled, let canvas = canvasView {
            let otherFrames = canvas.terminalNodes.compactMap { $0 === self ? nil : $0.frame }
            let result = SnapGuideEngine.snapResize(resizingFrame: newFrame, otherFrames: otherFrames,
                                                       scale: canvas.canvasTransform.scale)
            newFrame = result.adjustedFrame
            canvas.snapGuides = result.guides
        }

        frame = newFrame
    }
}
