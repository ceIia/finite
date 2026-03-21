import Foundation
import CoreGraphics
import os

private let logger = Logger(subsystem: "dev.finite", category: "CanvasState")

/// Persisted canvas state — node layout and canvas transform.
struct CanvasState: Codable {
    struct NodeState: Codable {
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat
        var title: String
        var workingDirectory: String?
    }

    var nodes: [NodeState]
    var offsetX: CGFloat
    var offsetY: CGFloat
    var scale: CGFloat
    var windowX: CGFloat?
    var windowY: CGFloat?
    var windowWidth: CGFloat?
    var windowHeight: CGFloat?

    private static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/finite")
    private static let stateFile = configDir.appendingPathComponent("state.json")

    static func save(from manager: TerminalNodeManager, transform: CanvasTransform, windowFrame: NSRect? = nil) {
        let nodeStates = manager.nodes.map { node in
            NodeState(
                x: node.frame.origin.x,
                y: node.frame.origin.y,
                width: node.frame.width,
                height: node.frame.height,
                title: node.title,
                workingDirectory: manager.pwd(for: node)
            )
        }

        let state = CanvasState(
            nodes: nodeStates,
            offsetX: transform.offset.x,
            offsetY: transform.offset.y,
            scale: transform.scale,
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
        return try? JSONDecoder().decode(CanvasState.self, from: data)
    }
}
