import AppKit

protocol TerminalNodeManagerDelegate: AnyObject {
    func nodeManager(_ manager: TerminalNodeManager, didCreateNode node: TerminalNodeView)
    func nodeManager(_ manager: TerminalNodeManager, didRemoveNode node: TerminalNodeView)
    func nodeManager(_ manager: TerminalNodeManager, didFocusNode node: TerminalNodeView?)
    func nodeManager(_ manager: TerminalNodeManager, didUpdateTitleFor node: TerminalNodeView)
    func nodeManager(_ manager: TerminalNodeManager, didUpdateActivityFor node: TerminalNodeView)
    func nodeManager(_ manager: TerminalNodeManager, didUpdateSelection nodes: Set<ObjectIdentifier>)
    func nodeManagerDidRemoveLastNode(_ manager: TerminalNodeManager)
}

/// Manages terminal node lifecycle, focus, selection, and surface-to-node mapping.
class TerminalNodeManager {
    weak var delegate: TerminalNodeManagerDelegate?
    private(set) var nodes: [TerminalNodeView] = []
    private(set) weak var focusedNode: TerminalNodeView?
    private(set) var selectedNodes: Set<ObjectIdentifier> = []
    private var surfaceMap: [UnsafeMutableRawPointer: TerminalNodeView] = [:]
    private var activeNodes: Set<ObjectIdentifier> = []
    private var nodePWD: [ObjectIdentifier: String] = [:]
    private weak var canvasView: CanvasView?
    private weak var window: NSWindow?

    /// Set when the window is closing to suppress "close if empty" checks.
    var isClosingWindow = false
    /// Re-entrancy guard for setFocus/becomeFirstResponder cycle.
    private(set) var isHandlingFocus = false

    /// Gap between auto-placed nodes.
    private static let placementGap: CGFloat = 30
    /// Y-distance threshold for considering nodes in the same row during tidy.
    private static let tidyRowThreshold: CGFloat = 50

    init(canvasView: CanvasView, window: NSWindow) {
        self.canvasView = canvasView
        self.window = window
        canvasView.nodeManager = self
    }

    // MARK: - Node Creation

    /// Wire the surface-created callback for surface → node O(1) lookup.
    private func wireSurfaceCallback(_ node: TerminalNodeView) {
        node.terminalView.onSurfaceCreated = { [weak self, weak node] surface in
            guard let self, let node else { return }
            self.surfaceMap[surface] = node
            if node === self.focusedNode {
                self.window?.makeFirstResponder(node.terminalView)
            }
        }
    }

    @discardableResult
    func createNode(at origin: CGPoint? = nil, size: NSSize, workingDirectory: String? = nil) -> TerminalNodeView {
        let position: CGPoint
        if let origin = origin {
            position = origin
        } else {
            position = smartPlacement(size: size)
        }

        let node = TerminalNodeView(frame: NSRect(origin: position, size: size))
        wireSurfaceCallback(node)

        // Set working directory before adding to canvas (which triggers surface creation)
        node.terminalView.overrideWorkingDirectory = workingDirectory

        canvasView?.addTerminalNode(node)
        nodes.append(node)
        delegate?.nodeManager(self, didCreateNode: node)

        handleClick(node, modifiers: [])
        canvasView?.bringNodeToFront(node)
        return node
    }

    // MARK: - Duplicate

    @discardableResult
    func duplicateNode(_ source: TerminalNodeView) -> TerminalNodeView? {
        guard let sourceSurface = source.terminalView.surface else { return nil }

        let position = smartPlacement(size: source.frame.size, relativeTo: source)
        let size = source.frame.size

        let node = TerminalNodeView(frame: NSRect(origin: position, size: size))
        wireSurfaceCallback(node)

        // Pass inherited config and tracked PWD for duplication
        let inherited = ghostty_surface_inherited_config(sourceSurface, GHOSTTY_SURFACE_CONTEXT_WINDOW)
        node.terminalView.inheritedSurfaceConfig = inherited
        node.terminalView.overrideWorkingDirectory = pwd(for: source)

        canvasView?.addTerminalNode(node)
        nodes.append(node)
        delegate?.nodeManager(self, didCreateNode: node)

        handleClick(node, modifiers: [])
        canvasView?.bringNodeToFront(node)
        return node
    }

    // MARK: - Node Removal

    func removeNode(_ node: TerminalNodeView) {
        // Remove from surface map
        if let surface = node.terminalView.surface {
            surfaceMap.removeValue(forKey: surface)
        }

        // Remove from tracking
        let id = ObjectIdentifier(node)
        nodes.removeAll { $0 === node }
        selectedNodes.remove(id)
        activeNodes.remove(id)
        nodePWD.removeValue(forKey: id)

        // Update focus to next available node
        if focusedNode === node {
            if let next = nodes.last {
                setFocus(next)
                selectedNodes = [ObjectIdentifier(next)]
            } else {
                focusedNode = nil
                delegate?.nodeManager(self, didFocusNode: nil)
            }
        }

        syncVisuals()
        delegate?.nodeManager(self, didRemoveNode: node)

        // Animate removal: fade out
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            node.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.canvasView?.removeTerminalNode(node)
        }

        if nodes.isEmpty && !isClosingWindow {
            delegate?.nodeManagerDidRemoveLastNode(self)
        }
    }

    // MARK: - Focus (internal — does NOT change selection or call bringToFront)

    private func setFocus(_ node: TerminalNodeView) {
        if node === focusedNode { return }
        isHandlingFocus = true
        focusedNode = node
        window?.makeFirstResponder(node.terminalView)
        isHandlingFocus = false
        clearActivity(for: node)
        delegate?.nodeManager(self, didFocusNode: node)
    }

    /// Focus a node without changing selection. Used when clicking an already-selected node.
    func focusOnly(_ node: TerminalNodeView) {
        setFocus(node)
        syncVisuals()
    }

    // MARK: - Unified Click Handler

    /// Single entry point for all click-based selection/focus changes.
    func handleClick(_ node: TerminalNodeView, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            // Cmd+click: toggle in/out of selection, don't change focus
            let id = ObjectIdentifier(node)
            if selectedNodes.contains(id) && selectedNodes.count > 1 && node !== focusedNode {
                selectedNodes.remove(id)
            } else {
                selectedNodes.insert(id)
            }
        } else if modifiers.contains(.shift) {
            // Shift+click: range select between focused and clicked node
            if let focusedIdx = nodes.firstIndex(where: { $0 === focusedNode }),
               let clickedIdx = nodes.firstIndex(where: { $0 === node }) {
                let range = min(focusedIdx, clickedIdx)...max(focusedIdx, clickedIdx)
                for i in range {
                    selectedNodes.insert(ObjectIdentifier(nodes[i]))
                }
            } else {
                selectedNodes.insert(ObjectIdentifier(node))
            }
        } else {
            // Plain click: focus + sole selection
            selectedNodes = [ObjectIdentifier(node)]
            setFocus(node)
        }
        syncVisuals()
    }

    // MARK: - Selection

    /// Clear selection to just the focused node.
    func clearSelection() {
        if let focused = focusedNode {
            selectedNodes = [ObjectIdentifier(focused)]
        } else {
            selectedNodes = []
        }
        syncVisuals()
    }

    /// Marquee (rubber band) selection: select all nodes intersecting the rect.
    func marqueeSelect(nodes intersecting: [TerminalNodeView], toggle: Bool) {
        if toggle {
            for node in intersecting {
                let id = ObjectIdentifier(node)
                if selectedNodes.contains(id) {
                    if selectedNodes.count > 1 && node !== focusedNode {
                        selectedNodes.remove(id)
                    }
                } else {
                    selectedNodes.insert(id)
                }
            }
        } else {
            if intersecting.isEmpty {
                if let focused = focusedNode {
                    selectedNodes = [ObjectIdentifier(focused)]
                } else {
                    selectedNodes = []
                }
            } else {
                selectedNodes = Set(intersecting.map { ObjectIdentifier($0) })
                if let focused = focusedNode, !selectedNodes.contains(ObjectIdentifier(focused)) {
                    setFocus(intersecting[0])
                } else if focusedNode == nil, let first = intersecting.first {
                    setFocus(first)
                }
            }
        }
        syncVisuals()
    }

    func isSelected(_ node: TerminalNodeView) -> Bool {
        selectedNodes.contains(ObjectIdentifier(node))
    }

    var selectedNodeViews: [TerminalNodeView] {
        nodes.filter { selectedNodes.contains(ObjectIdentifier($0)) }
    }

    // MARK: - Visual Sync (single source of truth)

    func syncVisuals() {
        for node in nodes {
            node.isFocused = (node === focusedNode)
            node.isSelected = selectedNodes.contains(ObjectIdentifier(node))
            node.updateAppearance()
        }
        delegate?.nodeManager(self, didUpdateSelection: selectedNodes)
        canvasView?.gridView?.needsDisplay = true
    }

    // MARK: - Close with Confirmation

    func requestCloseNode(_ node: TerminalNodeView) {
        guard let surface = node.terminalView.surface else { return }
        if ghostty_surface_needs_confirm_quit(surface) {
            let alert = NSAlert()
            alert.messageText = "Close Terminal?"
            alert.informativeText = "This terminal has a running process. Close anyway?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            if let window = window {
                alert.beginSheetModal(for: window) { response in
                    if response == .alertFirstButtonReturn {
                        ghostty_surface_request_close(surface)
                    }
                }
            }
        } else {
            ghostty_surface_request_close(surface)
        }
    }

    func closeSelectedNodes() {
        for node in selectedNodeViews {
            if let surface = node.terminalView.surface {
                ghostty_surface_request_close(surface)
            }
        }
    }

    func selectedNodesNeedConfirmation() -> Bool {
        selectedNodeViews.contains { node in
            guard let surface = node.terminalView.surface else { return false }
            return ghostty_surface_needs_confirm_quit(surface)
        }
    }

    // MARK: - Activity Tracking

    func markActivity(for surface: ghostty_surface_t) {
        guard let node = node(for: surface), node !== focusedNode else { return }
        let id = ObjectIdentifier(node)
        guard !activeNodes.contains(id) else { return }
        activeNodes.insert(id)
        delegate?.nodeManager(self, didUpdateActivityFor: node)
    }

    func clearActivity(for node: TerminalNodeView) {
        let id = ObjectIdentifier(node)
        if activeNodes.remove(id) != nil {
            delegate?.nodeManager(self, didUpdateActivityFor: node)
        }
    }

    func hasActivity(_ node: TerminalNodeView) -> Bool {
        activeNodes.contains(ObjectIdentifier(node))
    }

    // MARK: - PWD Tracking

    func handlePwdChanged(_ surface: ghostty_surface_t, _ pwd: String) {
        guard let node = node(for: surface) else { return }
        nodePWD[ObjectIdentifier(node)] = pwd
    }

    func pwd(for node: TerminalNodeView) -> String? {
        nodePWD[ObjectIdentifier(node)]
    }

    // MARK: - Surface Lookup

    func node(for surface: ghostty_surface_t) -> TerminalNodeView? { surfaceMap[surface] }

    // MARK: - Runtime Callbacks

    func handleSurfaceClosed(_ surface: ghostty_surface_t) {
        guard let node = node(for: surface) else { return }
        removeNode(node)
    }

    func handleSetTitle(_ surface: ghostty_surface_t, _ title: String) {
        guard let node = node(for: surface) else { return }
        node.title = title
        delegate?.nodeManager(self, didUpdateTitleFor: node)

        // Update window title for focused node
        if node === focusedNode {
            window?.title = title
        }
    }

    // MARK: - Smart Placement

    private func smartPlacement(size: NSSize, relativeTo ref: TerminalNodeView? = nil) -> CGPoint {
        guard !nodes.isEmpty else { return .init(x: 50, y: 50) }

        let reference = ref ?? focusedNode ?? closestNode(to: viewportCenter()) ?? nodes.last!
        let gap = Self.placementGap
        let refFrame = reference.frame

        // Try RIGHT, BELOW, LEFT, ABOVE
        let candidates: [CGPoint] = [
            CGPoint(x: refFrame.maxX + gap, y: refFrame.origin.y),
            CGPoint(x: refFrame.origin.x, y: refFrame.origin.y - size.height - gap),
            CGPoint(x: refFrame.origin.x - size.width - gap, y: refFrame.origin.y),
            CGPoint(x: refFrame.origin.x, y: refFrame.maxY + gap),
        ]

        for candidate in candidates {
            let candidateRect = NSRect(origin: candidate, size: size)
            let overlaps = nodes.contains { $0.frame.intersects(candidateRect) }
            if !overlaps { return candidate }
        }

        // Fallback: right side even if overlapping
        return candidates[0]
    }

    private func viewportCenter() -> CGPoint {
        guard let canvas = canvasView else { return .zero }
        let boundsCenter = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        return canvas.canvasTransform.canvasPoint(from: boundsCenter)
    }

    private func closestNode(to point: CGPoint) -> TerminalNodeView? {
        nodes.min(by: { a, b in
            let da = hypot(a.frame.midX - point.x, a.frame.midY - point.y)
            let db = hypot(b.frame.midX - point.x, b.frame.midY - point.y)
            return da < db
        })
    }

    // MARK: - Spatial Navigation

    enum Direction { case left, right, up, down }

    func nearestNode(from node: TerminalNodeView, direction: Direction) -> TerminalNodeView? {
        let center = CGPoint(x: node.frame.midX, y: node.frame.midY)
        var best: TerminalNodeView?
        var bestDist = CGFloat.greatestFiniteMagnitude

        for candidate in nodes where candidate !== node {
            let cc = CGPoint(x: candidate.frame.midX, y: candidate.frame.midY)
            let dx = cc.x - center.x
            let dy = cc.y - center.y

            let inDirection: Bool
            switch direction {
            case .left:  inDirection = dx < 0
            case .right: inDirection = dx > 0
            case .up:    inDirection = dy > 0
            case .down:  inDirection = dy < 0
            }

            if inDirection {
                let dist = hypot(dx, dy)
                if dist < bestDist {
                    bestDist = dist
                    best = candidate
                }
            }
        }
        return best
    }

    // MARK: - Tidy / Arrange Selected

    func tidySelectedNodes() {
        let selected = selectedNodeViews
        guard selected.count > 1 else { return }

        let gap = Self.placementGap

        // Bounding box of all selected nodes
        var bbMinX = CGFloat.greatestFiniteMagnitude
        var bbMinY = CGFloat.greatestFiniteMagnitude
        var bbMaxX = -CGFloat.greatestFiniteMagnitude
        var bbMaxY = -CGFloat.greatestFiniteMagnitude

        for node in selected {
            bbMinX = min(bbMinX, node.frame.minX)
            bbMinY = min(bbMinY, node.frame.minY)
            bbMaxX = max(bbMaxX, node.frame.maxX)
            bbMaxY = max(bbMaxY, node.frame.maxY)
        }

        let centerX = (bbMinX + bbMaxX) / 2
        let centerY = (bbMinY + bbMaxY) / 2

        // Sort: top-to-bottom rows, left-to-right within rows
        let threshold = Self.tidyRowThreshold
        let sorted = selected.sorted { a, b in
            let ay = a.frame.midY
            let by = b.frame.midY
            if abs(ay - by) < threshold {
                return a.frame.midX < b.frame.midX
            }
            return ay > by
        }

        // Grid layout
        let cols = Int(ceil(sqrt(Double(sorted.count))))
        let maxW = selected.map { $0.frame.width }.max() ?? 700
        let maxH = selected.map { $0.frame.height }.max() ?? 500

        let cellW = maxW + gap
        let cellH = maxH + gap

        let rows = Int(ceil(Double(sorted.count) / Double(cols)))
        let gridW = CGFloat(cols) * cellW - gap
        let gridH = CGFloat(rows) * cellH - gap

        let startX = centerX - gridW / 2
        let startY = centerY + gridH / 2

        var targets: [(node: TerminalNodeView, target: CGPoint)] = []
        for (i, node) in sorted.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = startX + CGFloat(col) * cellW
            let y = startY - CGFloat(row) * cellH - maxH + node.frame.height
            targets.append((node, CGPoint(x: x, y: y)))
        }

        // Check for overlaps with non-selected nodes and shift if needed
        let nonSelected = nodes.filter { !selectedNodes.contains(ObjectIdentifier($0)) }
        var groupRect = NSRect(
            x: startX, y: startY - gridH,
            width: gridW + gap, height: gridH + gap
        )

        for ns in nonSelected {
            if ns.frame.intersects(groupRect.insetBy(dx: -gap, dy: -gap)) {
                let shiftX = ns.frame.maxX + gap - groupRect.minX
                groupRect.origin.x += shiftX
                for i in targets.indices {
                    targets[i].target.x += shiftX
                }
            }
        }

        // Animate
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (node, target) in targets {
                node.animator().setFrameOrigin(target)
            }
        }

        canvasView?.gridView?.needsDisplay = true
    }
}
