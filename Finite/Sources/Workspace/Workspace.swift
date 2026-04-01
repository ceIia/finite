import AppKit

/// A workspace groups a set of terminal nodes with their own canvas transform.
/// All terminals stay alive in memory when the workspace is inactive.
class Workspace: Identifiable {
    let id: UUID
    var name: String
    let nodeManager: TerminalNodeManager
    var canvasTransform: CanvasTransform

    init(id: UUID = UUID(), name: String, canvasView: CanvasView, window: NSWindow) {
        self.id = id
        self.name = name
        self.nodeManager = TerminalNodeManager(canvasView: canvasView, window: window)
        self.canvasTransform = CanvasTransform()
    }
}
