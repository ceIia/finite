import AppKit

/// Small overview of all canvas nodes and the viewport, shown in the bottom-right corner.
/// Uses colored block rendering from terminal text content — no ScreenCaptureKit needed.
class MinimapView: NSView {

    private static let minimapSize = NSSize(width: 160, height: 120)
    private static let padding: CGFloat = 8
    private static let refreshInterval: TimeInterval = 1.0

    weak var canvasView: CanvasView?
    weak var nodeManager: TerminalNodeManager?

    // Thumbnail cache
    private var thumbnails: [ObjectIdentifier: CGImage] = [:]
    private var refreshTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: .zero, size: Self.minimapSize))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    /// Trigger a redraw on the next display cycle.
    func refresh() {
        needsDisplay = true
    }

    // MARK: - Periodic Refresh

    func startRefreshing() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshAllThumbnails()
        }
    }

    func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Thumbnail Capture (colored blocks from terminal text)

    private func refreshAllThumbnails() {
        guard !isHidden else { return }
        guard let manager = nodeManager, !manager.nodes.isEmpty else { return }

        for node in manager.nodes {
            let id = ObjectIdentifier(node)
            guard let surface = node.terminalView.surface else { continue }

            let size = ghostty_surface_size(surface)
            let cols = Int(size.columns)
            let rows = Int(size.rows)
            guard cols > 0, rows > 0 else { continue }

            // Build selection covering the entire viewport
            var selection = ghostty_selection_s()
            selection.top_left = ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0, y: 0
            )
            selection.bottom_right = ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: UInt32(max(cols - 1, 0)),
                y: UInt32(max(rows - 1, 0))
            )

            var text = ghostty_text_s()
            let ok = ghostty_surface_read_text(surface, selection, &text)
            guard ok, let textPtr = text.text else { continue }

            let content = String(cString: textPtr)
            ghostty_surface_free_text(surface, &text)

            // Render colored blocks: 1px per col, 2px per row
            let bmpW = cols
            let bmpH = rows * 2
            guard bmpW > 0, bmpH > 0 else { continue }

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil, width: bmpW, height: bmpH,
                bitsPerComponent: 8, bytesPerRow: bmpW * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }

            // Fill background dark
            ctx.setFillColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: bmpW, height: bmpH))

            var col = 0
            var row = 0

            for ch in content {
                if ch == "\n" {
                    row += 1
                    col = 0
                    continue
                }

                if col < cols && row < rows {
                    let brightness: CGFloat
                    if ch == " " || ch == "\t" {
                        brightness = 0.1
                    } else if ch.isLetter || ch.isNumber {
                        brightness = 0.8
                    } else {
                        brightness = 0.5
                    }

                    let px = col
                    // CGContext has origin at bottom-left; row 0 should be at top
                    let py0 = bmpH - 1 - (row * 2)
                    let py1 = bmpH - 1 - (row * 2 + 1)

                    ctx.setFillColor(red: brightness, green: brightness, blue: brightness, alpha: 1.0)
                    ctx.fill(CGRect(x: px, y: py0, width: 1, height: 1))
                    ctx.fill(CGRect(x: px, y: py1, width: 1, height: 1))
                }
                col += 1
            }

            if let image = ctx.makeImage() {
                thumbnails[id] = image
            }
        }

        // Clean up thumbnails for removed nodes
        if let manager = nodeManager {
            let currentIDs = Set(manager.nodes.map { ObjectIdentifier($0) })
            for key in thumbnails.keys where !currentIDs.contains(key) {
                thumbnails.removeValue(forKey: key)
            }
        }

        refresh()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas = canvasView, let manager = nodeManager else { return }
        let nodes = manager.nodes
        guard !nodes.isEmpty else { return }

        // Compute bounding box of all nodes with some margin
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        for node in nodes {
            let f = node.frame
            minX = min(minX, f.minX)
            minY = min(minY, f.minY)
            maxX = max(maxX, f.maxX)
            maxY = max(maxY, f.maxY)
        }

        // Include the viewport in the bounding box
        let vp = viewportRect(canvas: canvas)
        minX = min(minX, vp.minX)
        minY = min(minY, vp.minY)
        maxX = max(maxX, vp.maxX)
        maxY = max(maxY, vp.maxY)

        let margin: CGFloat = 50
        minX -= margin; minY -= margin
        maxX += margin; maxY += margin

        let worldW = maxX - minX
        let worldH = maxY - minY
        guard worldW > 0, worldH > 0 else { return }

        let drawArea = bounds.insetBy(dx: Self.padding, dy: Self.padding)
        let scaleX = drawArea.width / worldW
        let scaleY = drawArea.height / worldH
        let s = min(scaleX, scaleY)

        func mapRect(_ r: NSRect) -> NSRect {
            NSRect(
                x: drawArea.origin.x + (r.origin.x - minX) * s,
                y: drawArea.origin.y + (r.origin.y - minY) * s,
                width: r.width * s,
                height: r.height * s
            )
        }

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Draw nodes
        for node in nodes {
            let rect = mapRect(node.frame)
            let id = ObjectIdentifier(node)

            // Try to draw thumbnail
            if let thumb = thumbnails[id] {
                ctx.saveGState()
                // CGContext draws images flipped relative to NSView coords
                ctx.translateBy(x: rect.origin.x, y: rect.origin.y + rect.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(thumb, in: CGRect(origin: .zero, size: rect.size))
                ctx.restoreGState()

                // Draw border overlay for state
                let borderColor: NSColor
                if node === manager.focusedNode {
                    borderColor = .controlAccentColor
                } else if manager.isSelected(node) {
                    borderColor = NSColor.controlAccentColor.withAlphaComponent(0.4)
                } else if manager.hasActivity(node) {
                    borderColor = .orange
                } else {
                    borderColor = NSColor.white.withAlphaComponent(0.2)
                }
                borderColor.setStroke()
                let borderPath = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
                borderPath.lineWidth = 1
                borderPath.stroke()
            } else {
                // Fallback: colored rectangle with title
                let color: NSColor
                if node === manager.focusedNode {
                    color = NSColor.controlAccentColor.withAlphaComponent(0.5)
                } else if manager.isSelected(node) {
                    color = NSColor.controlAccentColor.withAlphaComponent(0.3)
                } else if manager.hasActivity(node) {
                    color = NSColor.orange.withAlphaComponent(0.5)
                } else {
                    color = NSColor.white.withAlphaComponent(0.2)
                }
                color.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()

                // Draw title as small text
                if rect.width > 10, rect.height > 8 {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: max(6, rect.height * 0.2)),
                        .foregroundColor: NSColor.white.withAlphaComponent(0.6),
                    ]
                    let title = node.title as NSString
                    let titleRect = NSRect(x: rect.minX + 1, y: rect.midY - 4,
                                           width: rect.width - 2, height: 8)
                    title.draw(in: titleRect, withAttributes: attrs)
                }
            }
        }

        // Draw viewport rect
        let vpMapped = mapRect(vp)
        NSColor.white.withAlphaComponent(0.7).setStroke()
        let vpPath = NSBezierPath(rect: vpMapped)
        vpPath.lineWidth = 1
        vpPath.stroke()
    }

    private func viewportRect(canvas: CanvasView) -> NSRect {
        let t = canvas.canvasTransform
        let topLeft = t.canvasPoint(from: CGPoint(x: canvas.bounds.minX, y: canvas.bounds.minY))
        let bottomRight = t.canvasPoint(from: CGPoint(x: canvas.bounds.maxX, y: canvas.bounds.maxY))
        return NSRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }
}
