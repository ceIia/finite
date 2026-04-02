import AppKit

/// Infinite canvas view with pan/zoom via sublayerTransform.
/// Handles hit zone routing, scroll state machine, marquee selection,
/// and magnification gestures.
class CanvasView: NSView {
    var canvasTransform = CanvasTransform() {
        didSet {
            applyTransform()
            gridView?.canvasTransform = canvasTransform
            onTransformChanged?()
        }
    }
    private(set) var terminalNodes: [TerminalNodeView] = []
    weak var nodeManager: TerminalNodeManager?
    weak var gridView: CanvasGridView?
    var onTransformChanged: (() -> Void)?
    private var magnificationGesture: NSMagnificationGestureRecognizer!
    private var cursorTrackingArea: NSTrackingArea?

    /// Snap guides to render (set by TerminalNodeView during drag/resize).
    var snapGuides: [SnapGuide] = [] {
        didSet { gridView?.snapGuides = snapGuides }
    }

    /// Marquee (rubber band) selection state — in canvas coordinates.
    private var marqueeStart: CGPoint?
    private(set) var marqueeRect: NSRect?

    /// Middle-mouse drag panning state.
    private var middleMousePanStart: NSPoint?

    // MARK: - Scroll State Machine

    private enum ScrollTarget {
        case undecided
        case deciding(surface: TerminalSurfaceView, buffer: [NSEvent]) // buffering first events
        case canvas
        case terminal(TerminalSurfaceView)
    }
    private var scrollTarget: ScrollTarget = .undecided

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private var scrollMonitor: Any?

    private func commonInit() {
        wantsLayer = true
        magnificationGesture = NSMagnificationGestureRecognizer(
            target: self, action: #selector(handleMagnification(_:))
        )
        addGestureRecognizer(magnificationGesture)
        installScrollMonitor()
    }

    deinit {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Intercept ALL scroll events at the app level so the state machine
    /// works even when the cursor moves over a terminal mid-gesture.
    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            // Only handle events within our window
            guard event.window === self.window else { return event }
            self.handleScrollEvent(event)
            return nil // consume — we route it ourselves
        }
    }

    // MARK: - Terminal Node Management

    func addTerminalNode(_ node: TerminalNodeView) {
        terminalNodes.append(node)
        addSubview(node)
        node.canvasView = self
        node.terminalView.canvasView = self
        gridView?.needsDisplay = true
    }

    func removeTerminalNode(_ node: TerminalNodeView) {
        guard let idx = terminalNodes.firstIndex(where: { $0 === node }) else { return }
        terminalNodes.remove(at: idx)
        node.removeFromSuperview()
        gridView?.needsDisplay = true
    }

    func bringNodeToFront(_ node: TerminalNodeView) {
        guard let idx = terminalNodes.firstIndex(where: { $0 === node }) else { return }
        terminalNodes.remove(at: idx)
        terminalNodes.append(node)
        node.removeFromSuperview()
        addSubview(node)
        gridView?.needsDisplay = true
    }

    // MARK: - Transform

    private func applyTransform() {
        layer?.sublayerTransform = canvasTransform.layerTransform
    }

    // MARK: - Hit Testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }

        let canvasPoint = canvasTransform.canvasPoint(from: point)
        let rw = TerminalNodeView.resizeHandleWidth

        for node in terminalNodes.reversed() {
            let expandedFrame = node.frame.insetBy(dx: -rw, dy: -rw)
            if expandedFrame.contains(canvasPoint) {
                let nodeLocal = node.localPoint(from: canvasPoint)
                let zone = node.hitZone(for: nodeLocal)

                // Right-click: route everything to node for context menu
                if NSApp.currentEvent?.type == .rightMouseDown {
                    return node
                }

                switch zone {
                case .terminal:
                    // Hold Option to drag, Cmd to toggle selection
                    let mods = NSApp.currentEvent?.modifierFlags ?? []
                    if mods.contains(.option) || mods.contains(.command) {
                        return node
                    }
                    return node.terminalView
                case .titleBar:
                    return node
                case .resizeEdge, .resizeCorner:
                    return node
                }
            }
        }

        return self
    }

    // MARK: - Cursor Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = cursorTrackingArea {
            removeTrackingArea(existing)
        }
        cursorTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(cursorTrackingArea!)
    }

    override func mouseMoved(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let canvasPoint = canvasTransform.canvasPoint(from: localPoint)

        // Reset close button hover on all nodes
        var hoveredNode: TerminalNodeView?

        let rw = TerminalNodeView.resizeHandleWidth
        for node in terminalNodes.reversed() {
            let expandedFrame = node.frame.insetBy(dx: -rw, dy: -rw)
            if expandedFrame.contains(canvasPoint) {
                let nodeLocal = node.localPoint(from: canvasPoint)
                let zone = node.hitZone(for: nodeLocal)

                // Check close button hover
                if case .titleBar = zone,
                   nodeLocal.x < TerminalNodeView.closeButtonWidth,
                   nodeLocal.y > node.bounds.height - TerminalNodeView.titleBarHeight {
                    NSCursor.pointingHand.set()
                    hoveredNode = node
                } else {
                    TerminalNodeView.cursor(for: zone).set()
                }

                // Update hover state
                for n in terminalNodes where n !== hoveredNode {
                    if n.isCloseButtonHovered {
                        n.isCloseButtonHovered = false
                        gridView?.needsDisplay = true
                    }
                }
                if let hovered = hoveredNode, !hovered.isCloseButtonHovered {
                    hovered.isCloseButtonHovered = true
                    gridView?.needsDisplay = true
                }
                return
            }
        }

        // Reset all hover states when not over any node
        for n in terminalNodes where n.isCloseButtonHovered {
            n.isCloseButtonHovered = false
            gridView?.needsDisplay = true
        }

        NSCursor.arrow.set()
    }

    // MARK: - Mouse Handling (empty canvas: clear selection, marquee, double-click zoom)

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            zoomToFitAll()
            return
        }

        let cmdHeld = event.modifierFlags.contains(.command)
        if !cmdHeld {
            nodeManager?.clearSelection()
        }

        // Start marquee selection
        let localPoint = convert(event.locationInWindow, from: nil)
        let canvasPoint = canvasTransform.canvasPoint(from: localPoint)
        marqueeStart = canvasPoint
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = marqueeStart else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        let current = canvasTransform.canvasPoint(from: localPoint)
        marqueeRect = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        gridView?.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            marqueeStart = nil
            marqueeRect = nil
            gridView?.needsDisplay = true
        }
        guard let rect = marqueeRect, let manager = nodeManager else { return }
        let intersecting = terminalNodes.filter { $0.frame.intersects(rect) }
        let cmdHeld = event.modifierFlags.contains(.command)
        manager.marqueeSelect(nodes: intersecting, toggle: cmdHeld)
    }

    // MARK: - Middle Mouse Drag (pan canvas, Figma-style)

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        middleMousePanStart = event.locationInWindow
        NSCursor.closedHand.push()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2, middleMousePanStart != nil else {
            return super.otherMouseDragged(with: event)
        }
        canvasTransform.pan(by: CGPoint(x: -event.deltaX, y: event.deltaY))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, middleMousePanStart != nil else {
            return super.otherMouseUp(with: event)
        }
        middleMousePanStart = nil
        NSCursor.pop()
    }

    func zoomToFitAll(sidebarWidth: CGFloat = 0) {
        let rects = terminalNodes.map { $0.frame }
        var viewportSize = bounds.size
        viewportSize.width -= sidebarWidth
        guard let target = CanvasTransform.zoomToFit(rects: rects, in: viewportSize) else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            self.canvasTransform = target
        }
    }

    func zoomToFitNode(_ node: TerminalNodeView, sidebarWidth: CGFloat = 0) {
        var viewportSize = bounds.size
        viewportSize.width -= sidebarWidth
        guard let target = CanvasTransform.zoomToFit(rects: [node.frame], in: viewportSize) else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            self.canvasTransform = target
        }
    }

    // MARK: - Scroll Wheel (state machine via NSEvent monitor)

    private func handleScrollEvent(_ event: NSEvent) {
        let phase = event.phase
        let momentumPhase = event.momentumPhase

        // Gesture start — enter deciding state if over a terminal
        if phase == .began || phase == .mayBegin {
            let initial = determineScrollTarget(for: event)
            switch initial {
            case .terminal(let surface):
                scrollTarget = .deciding(surface: surface, buffer: [])
            default:
                scrollTarget = initial
            }
        }

        // Ctrl override: force canvas pan even if locked to terminal
        if event.modifierFlags.contains(.control) {
            scrollTarget = .canvas
        }

        // Cmd+scroll: zoom in/out using vertical scroll delta
        if event.modifierFlags.contains(.command) {
            let anchor = convert(event.locationInWindow, from: nil)
            let zoomSensitivity: CGFloat = 0.01
            let factor = 1.0 + event.scrollingDeltaY * zoomSensitivity
            canvasTransform.zoom(by: factor, anchor: anchor)
            return
        }

        // Route based on target
        switch scrollTarget {
        case .undecided:
            // Legacy mouse (no phase) — per-event routing
            let target = determineScrollTarget(for: event)
            switch target {
            case .terminal(let surface):
                surface.scrollWheel(with: event)
            case .canvas, .undecided, .deciding:
                canvasTransform.pan(by: CGPoint(x: -event.scrollingDeltaX, y: event.scrollingDeltaY))
            }

        case .deciding(let surface, var buffer):
            // Buffer the first few scroll events and check direction
            buffer.append(event)
            if buffer.count >= 3 {
                let totalDX = buffer.reduce(0) { $0 + abs($1.scrollingDeltaX) }
                let totalDY = buffer.reduce(0) { $0 + abs($1.scrollingDeltaY) }

                if totalDX > totalDY * 1.5 {
                    // Predominantly horizontal — canvas pan
                    scrollTarget = .canvas
                    for buffered in buffer {
                        canvasTransform.pan(by: CGPoint(x: -buffered.scrollingDeltaX, y: buffered.scrollingDeltaY))
                    }
                } else {
                    // Vertical or mixed — terminal scroll
                    scrollTarget = .terminal(surface)
                    for buffered in buffer {
                        surface.scrollWheel(with: buffered)
                    }
                }
            } else {
                scrollTarget = .deciding(surface: surface, buffer: buffer)
            }

        case .canvas:
            canvasTransform.pan(by: CGPoint(x: -event.scrollingDeltaX, y: event.scrollingDeltaY))

        case .terminal(let surface):
            surface.scrollWheel(with: event)
        }

        // Only reset when the entire gesture sequence is done:
        // - If momentum follows, wait for momentum end
        // - If no momentum, reset at phase end
        if momentumPhase == .ended || momentumPhase == .cancelled {
            scrollTarget = .undecided
        } else if (phase == .ended || phase == .cancelled) && momentumPhase == [] {
            scrollTarget = .undecided
        }
    }

    private func determineScrollTarget(for event: NSEvent) -> ScrollTarget {
        let localPoint = convert(event.locationInWindow, from: nil)
        let canvasPoint = canvasTransform.canvasPoint(from: localPoint)

        for node in terminalNodes.reversed() {
            if node.frame.contains(canvasPoint) {
                let nodeLocal = node.localPoint(from: canvasPoint)
                let zone = node.hitZone(for: nodeLocal)

                switch zone {
                case .terminal:
                    return .terminal(node.terminalView)
                case .titleBar, .resizeEdge, .resizeCorner:
                    return .canvas
                }
            }
        }

        return .canvas
    }

    // MARK: - Magnification Gesture (zoom)

    @objc private func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
        let anchor = gesture.location(in: self)
        let factor = 1.0 + gesture.magnification
        canvasTransform.zoom(by: factor, anchor: anchor)
        gesture.magnification = 0
    }
}

// MARK: - Canvas Grid Background

/// Draws the dot grid and snap guide lines in a separate view,
/// not affected by CanvasView's sublayerTransform.
class CanvasGridView: NSView {
    private static let gridSpacing: CGFloat = 20
    private static let dotRadius: CGFloat = 0.75
    private static let dotAlpha: CGFloat = 0.09
    private static let maxGridDots: CGFloat = 5000

    var canvasTransform = CanvasTransform() {
        didSet { needsDisplay = true }
    }

    weak var canvasView: CanvasView?

    var snapGuides: [SnapGuide] = [] {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // -- Dotted grid --
        let dotColor = NSColor.white.withAlphaComponent(Self.dotAlpha)

        let tl = canvasTransform.canvasPoint(from: CGPoint(x: bounds.minX, y: bounds.minY))
        let br = canvasTransform.canvasPoint(from: CGPoint(x: bounds.maxX, y: bounds.maxY))
        let visMinX = min(tl.x, br.x)
        let visMaxX = max(tl.x, br.x)
        let visMinY = min(tl.y, br.y)
        let visMaxY = max(tl.y, br.y)

        var spacing = Self.gridSpacing
        let estCount = ((visMaxX - visMinX) / spacing) * ((visMaxY - visMinY) / spacing)
        if estCount > Self.maxGridDots { spacing *= 2 }

        if estCount / 4 <= Self.maxGridDots {
            let startX = (visMinX / spacing).rounded(.down) * spacing
            let startY = (visMinY / spacing).rounded(.down) * spacing

            ctx.setFillColor(dotColor.cgColor)
            var cx = startX
            while cx <= visMaxX {
                var cy = startY
                while cy <= visMaxY {
                    let sp = canvasTransform.screenPoint(from: CGPoint(x: cx, y: cy))
                    let r = Self.dotRadius
                    ctx.fillEllipse(in: CGRect(x: sp.x - r, y: sp.y - r, width: r * 2, height: r * 2))
                    cy += spacing
                }
                cx += spacing
            }
        }

        // -- Snap guides --
        if !snapGuides.isEmpty {
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor)
            ctx.setLineWidth(1.0)

            for guide in snapGuides {
                let p1: CGPoint
                let p2: CGPoint
                switch guide.orientation {
                case .vertical:
                    p1 = canvasTransform.screenPoint(from: CGPoint(x: guide.position, y: guide.start))
                    p2 = canvasTransform.screenPoint(from: CGPoint(x: guide.position, y: guide.end))
                case .horizontal:
                    p1 = canvasTransform.screenPoint(from: CGPoint(x: guide.start, y: guide.position))
                    p2 = canvasTransform.screenPoint(from: CGPoint(x: guide.end, y: guide.position))
                }
                ctx.move(to: p1)
                ctx.addLine(to: p2)
            }
            ctx.strokePath()
        }

        // -- Marquee selection rectangle --
        if let marquee = canvasView?.marqueeRect {
            let screenBL = canvasTransform.screenPoint(from: CGPoint(x: marquee.minX, y: marquee.minY))
            let screenTR = canvasTransform.screenPoint(from: CGPoint(x: marquee.maxX, y: marquee.maxY))
            let marqueeScreen = CGRect(
                x: min(screenBL.x, screenTR.x),
                y: min(screenBL.y, screenTR.y),
                width: abs(screenTR.x - screenBL.x),
                height: abs(screenTR.y - screenBL.y)
            )
            ctx.saveGState()
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor)
            ctx.fill(marqueeScreen)
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.4).cgColor)
            ctx.setLineWidth(1.0)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(marqueeScreen)
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.restoreGState()
        }

        // -- Title bars (drawn here to avoid sublayerTransform clipping) --
        drawTitleBars(ctx)
    }

    private static let closeButtonRadius: CGFloat = 8
    private static let closeButtonPadding: CGFloat = 6
    private static let titleBarCornerRadiusFactor: CGFloat = 6

    private func drawTitleBars(_ ctx: CGContext) {
        guard let nodes = canvasView?.terminalNodes, !nodes.isEmpty else { return }

        let scale = canvasTransform.scale
        let scaledFontSize = max(7, min(11 * scale, 24))
        let titleFont = NSFont.systemFont(ofSize: scaledFontSize, weight: .medium)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
        ]

        for node in nodes {
            let screenRect = titleBarScreenRect(for: node)
            guard screenRect.intersects(bounds) else { continue }

            let bgPath = titleBarPath(screenRect: screenRect, cornerRadius: Self.titleBarCornerRadiusFactor * scale)
            drawTitleBarBackground(ctx, node: node, screenRect: screenRect, bgPath: bgPath)
            drawCloseButton(ctx, screenRect: screenRect, isHovered: node.isCloseButtonHovered, scale: scale)
            drawTitleText(ctx, title: node.title, screenRect: screenRect, attrs: titleAttrs, scale: scale)
        }
    }

    private func titleBarScreenRect(for node: TerminalNodeView) -> CGRect {
        let titleBarHeight = TerminalNodeView.titleBarHeight
        let nodeFrame = node.frame
        let tbCanvasRect = CGRect(
            x: nodeFrame.minX,
            y: nodeFrame.maxY - titleBarHeight,
            width: nodeFrame.width,
            height: titleBarHeight
        )
        return canvasTransform.screenRect(from: tbCanvasRect)
    }

    private func titleBarPath(screenRect: CGRect, cornerRadius: CGFloat) -> CGMutablePath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: screenRect.minX, y: screenRect.minY))
        path.addLine(to: CGPoint(x: screenRect.minX, y: screenRect.maxY - cornerRadius))
        path.addQuadCurve(to: CGPoint(x: screenRect.minX + cornerRadius, y: screenRect.maxY),
                          control: CGPoint(x: screenRect.minX, y: screenRect.maxY))
        path.addLine(to: CGPoint(x: screenRect.maxX - cornerRadius, y: screenRect.maxY))
        path.addQuadCurve(to: CGPoint(x: screenRect.maxX, y: screenRect.maxY - cornerRadius),
                          control: CGPoint(x: screenRect.maxX, y: screenRect.maxY))
        path.addLine(to: CGPoint(x: screenRect.maxX, y: screenRect.minY))
        path.closeSubpath()
        return path
    }

    private func drawTitleBarBackground(_ ctx: CGContext, node: TerminalNodeView, screenRect: CGRect, bgPath: CGPath) {
        ctx.saveGState()
        ctx.setFillColor(NSColor(white: 0.12, alpha: 0.95).cgColor)
        ctx.addPath(bgPath)
        ctx.fillPath()
        ctx.restoreGState()

        if node.isSelected && !node.isFocused {
            ctx.saveGState()
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor)
            ctx.addPath(bgPath)
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: screenRect.minX, y: screenRect.minY))
        ctx.addLine(to: CGPoint(x: screenRect.maxX, y: screenRect.minY))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawCloseButton(_ ctx: CGContext, screenRect: CGRect, isHovered: Bool, scale: CGFloat) {
        let scaledRadius = Self.closeButtonRadius * scale
        let scaledPadding = Self.closeButtonPadding * scale
        let btnCenterX = screenRect.minX + scaledPadding + scaledRadius
        let btnRect = CGRect(
            x: btnCenterX - scaledRadius,
            y: screenRect.midY - scaledRadius,
            width: scaledRadius * 2,
            height: scaledRadius * 2
        )

        ctx.saveGState()
        ctx.setFillColor(isHovered
            ? NSColor.systemRed.withAlphaComponent(0.6).cgColor
            : NSColor.white.withAlphaComponent(0.08).cgColor)
        ctx.fillEllipse(in: btnRect)

        let xInset = scaledRadius * 0.55
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(isHovered ? 1.0 : 0.7).cgColor)
        ctx.setLineWidth(max(1.0, 1.5 * scale))
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: btnRect.minX + xInset, y: btnRect.minY + xInset))
        ctx.addLine(to: CGPoint(x: btnRect.maxX - xInset, y: btnRect.maxY - xInset))
        ctx.move(to: CGPoint(x: btnRect.maxX - xInset, y: btnRect.minY + xInset))
        ctx.addLine(to: CGPoint(x: btnRect.minX + xInset, y: btnRect.maxY - xInset))
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawTitleText(_ ctx: CGContext, title: String, screenRect: CGRect,
                               attrs: [NSAttributedString.Key: Any], scale: CGFloat) {
        let scaledPadding = Self.closeButtonPadding * scale
        let scaledRadius = Self.closeButtonRadius * scale
        let btnRight = screenRect.minX + scaledPadding + scaledRadius * 2 + scaledPadding

        let textLeadingEdge = btnRight
        let availableWidth = screenRect.maxX - textLeadingEdge - scaledPadding
        guard availableWidth > 0 else { return }

        let attrString = NSAttributedString(string: title, attributes: attrs)
        let textSize = attrString.size()
        let textHeight = textSize.height
        let textY = screenRect.midY - textHeight / 2
        let textWidth = min(textSize.width, availableWidth)
        let textX = textLeadingEdge + (availableWidth - textWidth) / 2
        let textRect = CGRect(x: textX, y: textY, width: availableWidth, height: textHeight)

        ctx.saveGState()
        ctx.clip(to: textRect)
        attrString.draw(at: CGPoint(x: textX, y: textY))
        ctx.restoreGState()
    }
}
