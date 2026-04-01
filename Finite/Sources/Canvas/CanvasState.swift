import Foundation
import CoreGraphics
import os

private let logger = Logger(subsystem: "com.helm.finite", category: "CanvasState")

/// Persisted canvas state — supports multiple workspaces.
struct CanvasState: Codable {
    struct NodeState: Codable {
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat
        var title: String
        var workingDirectory: String?
    }

    struct WorkspaceState: Codable {
        var id: String
        var name: String
        var nodes: [NodeState]
        var offsetX: CGFloat
        var offsetY: CGFloat
        var scale: CGFloat
    }

    // New multi-workspace format
    var workspaces: [WorkspaceState]?
    var activeWorkspaceIndex: Int?

    // Legacy single-workspace format (for migration)
    var nodes: [NodeState]?
    var offsetX: CGFloat?
    var offsetY: CGFloat?
    var scale: CGFloat?

    // Window frame (shared)
    var windowX: CGFloat?
    var windowY: CGFloat?
    var windowWidth: CGFloat?
    var windowHeight: CGFloat?

    private static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/finite")
    private static let stateFile = configDir.appendingPathComponent("state.json")

    static func save(from workspaceManager: WorkspaceManager, canvasView: CanvasView, windowFrame: NSRect? = nil) {
        // Save current workspace's transform from the live canvas
        workspaceManager.activeWorkspace.canvasTransform = canvasView.canvasTransform

        let workspaceStates = workspaceManager.workspaces.map { workspace in
            let nodeStates = workspace.nodeManager.nodes.map { node in
                NodeState(
                    x: node.frame.origin.x,
                    y: node.frame.origin.y,
                    width: node.frame.width,
                    height: node.frame.height,
                    title: node.title,
                    workingDirectory: workspace.nodeManager.pwd(for: node)
                )
            }
            return WorkspaceState(
                id: workspace.id.uuidString,
                name: workspace.name,
                nodes: nodeStates,
                offsetX: workspace.canvasTransform.offset.x,
                offsetY: workspace.canvasTransform.offset.y,
                scale: workspace.canvasTransform.scale
            )
        }

        let state = CanvasState(
            workspaces: workspaceStates,
            activeWorkspaceIndex: workspaceManager.activeIndex,
            windowX: windowFrame?.origin.x,
            windowY: windowFrame?.origin.y,
            windowWidth: windowFrame?.width,
            windowHeight: windowFrame?.height
        )

        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateFile, options: .atomic)
        } catch {
            logger.error("Failed to save canvas state: \(error.localizedDescription)")
        }
    }

    static func load() -> CanvasState? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        guard var state = try? JSONDecoder().decode(CanvasState.self, from: data) else { return nil }

        // Migrate legacy single-workspace format
        if state.workspaces == nil, let nodes = state.nodes {
            let legacyWorkspace = WorkspaceState(
                id: UUID().uuidString,
                name: "Workspace 1",
                nodes: nodes,
                offsetX: state.offsetX ?? 0,
                offsetY: state.offsetY ?? 0,
                scale: state.scale ?? 1
            )
            state.workspaces = [legacyWorkspace]
            state.activeWorkspaceIndex = 0
        }

        return state
    }
}
