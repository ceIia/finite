import AppKit

protocol WorkspaceManagerDelegate: AnyObject {
    func workspaceManager(_ manager: WorkspaceManager, didSwitchTo workspace: Workspace)
    func workspaceManager(_ manager: WorkspaceManager, didAdd workspace: Workspace)
    func workspaceManager(_ manager: WorkspaceManager, didRemove workspace: Workspace)
    func workspaceManager(_ manager: WorkspaceManager, didRename workspace: Workspace)
}

/// Manages multiple workspaces, each with its own set of terminals and canvas transform.
class WorkspaceManager {
    weak var delegate: WorkspaceManagerDelegate?
    private(set) var workspaces: [Workspace] = []
    private(set) var activeIndex: Int = 0
    private weak var canvasView: CanvasView?
    private weak var window: NSWindow?

    var activeWorkspace: Workspace { workspaces[activeIndex] }

    init(canvasView: CanvasView, window: NSWindow) {
        self.canvasView = canvasView
        self.window = window
    }

    // MARK: - Create / Delete / Rename

    @discardableResult
    func createWorkspace(name: String, switchTo: Bool = true) -> Workspace {
        guard let canvasView, let window else { fatalError("CanvasView/Window deallocated") }
        let workspace = Workspace(name: name, canvasView: canvasView, window: window)
        workspaces.append(workspace)
        delegate?.workspaceManager(self, didAdd: workspace)
        if switchTo {
            self.switchTo(workspace: workspace)
        }
        return workspace
    }

    /// Create a workspace with a pre-existing id (for state restoration).
    @discardableResult
    func createWorkspace(id: UUID, name: String, switchTo: Bool = true) -> Workspace {
        guard let canvasView, let window else { fatalError("CanvasView/Window deallocated") }
        let workspace = Workspace(id: id, name: name, canvasView: canvasView, window: window)
        workspaces.append(workspace)
        delegate?.workspaceManager(self, didAdd: workspace)
        if switchTo {
            self.switchTo(workspace: workspace)
        }
        return workspace
    }

    func deleteWorkspace(_ workspace: Workspace) {
        guard workspaces.count > 1 else { return }
        guard let idx = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }

        let isActive = idx == activeIndex

        // Close all terminals in the workspace
        for node in workspace.nodeManager.nodes {
            if let surface = node.terminalView.surface {
                ghostty_surface_request_close(surface)
            }
        }

        // If active, detach its nodes from the canvas
        if isActive {
            canvasView?.detachAllNodes()
        }

        workspaces.remove(at: idx)

        // Adjust activeIndex
        if isActive {
            let newIndex = min(idx, workspaces.count - 1)
            activeIndex = newIndex
            attachWorkspace(workspaces[newIndex])
        } else if idx < activeIndex {
            activeIndex -= 1
        }

        delegate?.workspaceManager(self, didRemove: workspace)
    }

    func renameWorkspace(_ workspace: Workspace, to name: String) {
        workspace.name = name
        delegate?.workspaceManager(self, didRename: workspace)
    }

    // MARK: - Switching

    func switchTo(workspace: Workspace) {
        guard let canvasView else { return }
        guard let targetIndex = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        if targetIndex == activeIndex && !canvasView.terminalNodes.isEmpty { return }

        let current = workspaces[activeIndex]

        // Save current transform and detach nodes
        current.canvasTransform = canvasView.canvasTransform
        canvasView.detachAllNodes()

        // Activate target
        activeIndex = targetIndex
        attachWorkspace(workspace)

        delegate?.workspaceManager(self, didSwitchTo: workspace)
    }

    func switchToNext() {
        let next = (activeIndex + 1) % workspaces.count
        switchTo(workspace: workspaces[next])
    }

    func switchToPrevious() {
        let prev = (activeIndex - 1 + workspaces.count) % workspaces.count
        switchTo(workspace: workspaces[prev])
    }

    // MARK: - Surface Routing

    /// Find the node manager that owns a given surface (searches all workspaces).
    func nodeManager(for surface: ghostty_surface_t) -> TerminalNodeManager? {
        for workspace in workspaces {
            if workspace.nodeManager.node(for: surface) != nil {
                return workspace.nodeManager
            }
        }
        return nil
    }

    /// Check if any workspace has terminals with running processes.
    func anyWorkspaceNeedsConfirmation() -> Bool {
        workspaces.contains { workspace in
            workspace.nodeManager.nodes.contains { node in
                guard let surface = node.terminalView.surface else { return false }
                return ghostty_surface_needs_confirm_quit(surface)
            }
        }
    }

    /// Check if all workspaces are empty.
    var allWorkspacesEmpty: Bool {
        workspaces.allSatisfy { $0.nodeManager.nodes.isEmpty }
    }

    /// Next workspace number for auto-naming.
    func nextWorkspaceName() -> String {
        let existing = workspaces.compactMap { ws -> Int? in
            guard ws.name.hasPrefix("Workspace ") else { return nil }
            return Int(ws.name.dropFirst("Workspace ".count))
        }
        let next = (existing.max() ?? 0) + 1
        return "Workspace \(next)"
    }

    // MARK: - Private

    private func attachWorkspace(_ workspace: Workspace) {
        guard let canvasView else { return }

        canvasView.attachNodes(workspace.nodeManager.nodes)
        canvasView.canvasTransform = workspace.canvasTransform
        canvasView.nodeManager = workspace.nodeManager

        // Restore keyboard focus
        if let focused = workspace.nodeManager.focusedNode {
            window?.makeFirstResponder(focused.terminalView)
        }
    }
}
