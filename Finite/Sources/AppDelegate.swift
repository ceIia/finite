import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private static let defaultWindowSize = NSSize(width: 800, height: 600)
    private static let minimumWindowSize = NSSize(width: 400, height: 300)
    private static let windowBackground = NSColor(white: 0.08, alpha: 0.92)
    private static let defaultNodeSize = NSSize(width: 700, height: 500)
    private static let defaultNodeOrigin = CGPoint(x: 50, y: 50)
    private static let processCheckInterval: TimeInterval = 2.0
    private static let sidebarWidth: CGFloat = 220

    // These properties are all initialized in applicationDidFinishLaunching (before any
    // other code runs) and live for the entire app lifetime. IUOs are the standard pattern
    // for NSApplicationDelegate when not using storyboards.
    private var window: NSWindow!
    private var canvasView: CanvasView!
    private var workspaceManager: WorkspaceManager!
    private var sidebarModel: SidebarModel!
    private var sidebarOverlay: SidebarOverlayView!
    private var minimapView: MinimapView!
    private var sidebarToggleButton: SidebarToggleButton!
    private var newTerminalButton: NewTerminalButton!
    private var sidebarToggleLeading: NSLayoutConstraint!
    private var sidebarLeading: NSLayoutConstraint!
    private var isConfirmedClose = false
    private var processStateTimer: Timer?
    private var cachedProcessStates: [Bool] = []
    private var keyboardMonitor: Any?

    private var activeNodeManager: TerminalNodeManager {
        workspaceManager.activeWorkspace.nodeManager
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize the Ghostty runtime (config, app, callbacks)
        GhosttyRuntime.shared.initialize()

        // Create the main window
        let contentRect = NSRect(origin: .zero, size: Self.defaultWindowSize)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Finite"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = Self.minimumWindowSize
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = Self.windowBackground

        // Container view holds the canvas and the sidebar overlay
        let container = NSView(frame: contentRect)
        container.autoresizingMask = [.width, .height]
        window.contentView = container

        // Background view for dot grid and snap guides (not affected by sublayerTransform)
        let gridView = CanvasGridView(frame: contentRect)
        gridView.autoresizingMask = [.width, .height]
        container.addSubview(gridView)

        canvasView = CanvasView(frame: contentRect)
        canvasView.autoresizingMask = [.width, .height]
        canvasView.gridView = gridView
        gridView.canvasView = canvasView
        container.addSubview(canvasView)

        // Create workspace manager
        workspaceManager = WorkspaceManager(canvasView: canvasView, window: window)
        workspaceManager.delegate = self

        // Create sidebar model
        sidebarModel = SidebarModel()
        sidebarModel.onSelectNode = { [weak self] node, mods in
            self?.activeNodeManager.handleClick(node, modifiers: mods)
            self?.ensureNodeVisible(node)
        }
        sidebarModel.onPanToNode = { [weak self] node in
            self?.activeNodeManager.handleClick(node, modifiers: [])
            self?.panToNode(node)
        }
        sidebarModel.onHoverPulse = { [weak self] node in
            node.pulse()
            self?.minimapView.refresh()
        }
        sidebarModel.onCloseSelected = { [weak self] in
            self?.closeSelectedTerminals()
        }
        sidebarModel.onCloseSingle = { [weak self] node in
            self?.activeNodeManager.requestCloseNode(node)
        }
        sidebarModel.onDuplicateNode = { [weak self] node in
            self?.activeNodeManager.duplicateNode(node)
        }
        sidebarModel.onSelectWorkspace = { [weak self] id in
            guard let self else { return }
            if let workspace = self.workspaceManager.workspaces.first(where: { $0.id == id }) {
                self.workspaceManager.switchTo(workspace: workspace)
            }
        }
        sidebarModel.onCreateWorkspace = { [weak self] in
            self?.newWorkspace(nil)
        }
        sidebarModel.onDeleteWorkspace = { [weak self] id in
            guard let self else { return }
            if let workspace = self.workspaceManager.workspaces.first(where: { $0.id == id }) {
                self.deleteWorkspace(workspace)
            }
        }
        sidebarModel.onRenameWorkspace = { [weak self] id, name in
            guard let self else { return }
            if let workspace = self.workspaceManager.workspaces.first(where: { $0.id == id }) {
                self.workspaceManager.renameWorkspace(workspace, to: name)
            }
        }

        // Create sidebar overlay (glass panel inside the window)
        sidebarOverlay = SidebarOverlayView(sidebarView: SidebarView(model: sidebarModel))
        sidebarOverlay.translatesAutoresizingMaskIntoConstraints = false
        sidebarOverlay.isHidden = true
        container.addSubview(sidebarOverlay)

        sidebarLeading = sidebarOverlay.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12)
        NSLayoutConstraint.activate([
            sidebarOverlay.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 4),
            sidebarLeading,
            sidebarOverlay.widthAnchor.constraint(equalToConstant: 200),
            sidebarOverlay.heightAnchor.constraint(lessThanOrEqualTo: container.heightAnchor, multiplier: 0.6),
        ])

        // Wire runtime callbacks — surface-targeted ones route through workspaceManager
        GhosttyRuntime.shared.onSetTitle = { [weak self] surface, title in
            self?.workspaceManager.nodeManager(for: surface)?.handleSetTitle(surface, title)
        }

        GhosttyRuntime.shared.onSurfaceClosed = { [weak self] surface in
            self?.workspaceManager.nodeManager(for: surface)?.handleSurfaceClosed(surface)
        }

        GhosttyRuntime.shared.onNewTerminal = { [weak self] in
            self?.newTerminal(nil)
        }

        GhosttyRuntime.shared.onCloseTerminal = { [weak self] in
            self?.closeTerminal(nil)
        }

        GhosttyRuntime.shared.onRender = { [weak self] surface in
            self?.workspaceManager.nodeManager(for: surface)?.markActivity(for: surface)
        }

        GhosttyRuntime.shared.onPwdChanged = { [weak self] surface, pwd in
            self?.workspaceManager.nodeManager(for: surface)?.handlePwdChanged(surface, pwd)
        }

        GhosttyRuntime.shared.onCloseSurfaceRequested = { [weak self] surface, _ in
            guard let self else { return }
            guard let manager = self.workspaceManager.nodeManager(for: surface),
                  let node = manager.node(for: surface) else { return }
            manager.requestCloseNode(node)
        }

        // Minimap in bottom-right corner of the container
        minimapView = MinimapView(frame: .zero)
        minimapView.canvasView = canvasView
        minimapView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(minimapView)

        NSLayoutConstraint.activate([
            minimapView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            minimapView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            minimapView.widthAnchor.constraint(equalToConstant: 160),
            minimapView.heightAnchor.constraint(equalToConstant: 120),
        ])

        minimapView.startRefreshing()

        canvasView.onTransformChanged = { [weak self] in
            self?.minimapView.refresh()
        }

        // Toolbar buttons — sidebar toggle (top-left) and new terminal (top-right)
        sidebarToggleButton = GlassToolbarButton(systemName: "sidebar.left")
        sidebarToggleButton.translatesAutoresizingMaskIntoConstraints = false
        sidebarToggleButton.onAction = { [weak self] in self?.toggleSidebarPanel(nil) }
        container.addSubview(sidebarToggleButton)

        newTerminalButton = GlassToolbarButton(systemName: "plus", iconSize: 14)
        newTerminalButton.translatesAutoresizingMaskIntoConstraints = false
        newTerminalButton.onAction = { [weak self] in self?.newTerminal(nil) }
        container.addSubview(newTerminalButton)

        sidebarToggleLeading = sidebarToggleButton.leadingAnchor.constraint(
            equalTo: container.leadingAnchor, constant: 12
        )
        NSLayoutConstraint.activate([
            sidebarToggleButton.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            sidebarToggleLeading,
            sidebarToggleButton.widthAnchor.constraint(equalToConstant: 26),
            sidebarToggleButton.heightAnchor.constraint(equalToConstant: 26),

            newTerminalButton.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            newTerminalButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            newTerminalButton.widthAnchor.constraint(equalToConstant: 28),
            newTerminalButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        // Intercept shortcuts that can't be handled by the menu system:
        // - Escape (conditional on selection count, no menu equivalent)
        // - Cmd+Opt+Arrow (raw keycodes, must intercept before terminal sees them)
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let normalizedFlags = flags.subtracting([.function, .numericPad])

            // Escape (keyCode 53): clear multi-selection (only if >1 selected)
            if event.keyCode == 53 && self.activeNodeManager.selectedNodes.count > 1 {
                self.activeNodeManager.clearSelection()
                return nil
            }

            // Cmd+Opt+Arrow: navigation between terminals (keyCodes: 123=←, 124=→, 125=↓, 126=↑)
            if normalizedFlags == [.command, .option] {
                switch event.keyCode {
                case 123: self.navigateLeft(nil); return nil
                case 124: self.navigateRight(nil); return nil
                case 125: self.navigateDown(nil); return nil
                case 126: self.navigateUp(nil); return nil
                default: break
                }
            }

            // Cmd+1…9: switch to workspace by index
            if normalizedFlags == [.command],
               let chars = event.charactersIgnoringModifiers,
               let digit = chars.first?.wholeNumberValue,
               digit >= 1 && digit <= 9 {
                let index = digit - 1
                if index < self.workspaceManager.workspaces.count {
                    self.workspaceManager.switchTo(workspace: self.workspaceManager.workspaces[index])
                    return nil
                }
            }

            return event
        }

        // Restore saved state or create default workspace with terminal
        if let state = CanvasState.load(), let workspaceStates = state.workspaces, !workspaceStates.isEmpty {
            let activeIdx = state.activeWorkspaceIndex ?? 0

            for (i, wsState) in workspaceStates.enumerated() {
                let wsId = UUID(uuidString: wsState.id) ?? UUID()
                let workspace = workspaceManager.createWorkspace(id: wsId, name: wsState.name, switchTo: i == 0)

                if i == 0 {
                    // First workspace is already active, set its transform
                    canvasView.canvasTransform = CanvasTransform(
                        offset: CGPoint(x: wsState.offsetX, y: wsState.offsetY),
                        scale: wsState.scale
                    )
                    workspace.canvasTransform = canvasView.canvasTransform
                } else {
                    workspace.canvasTransform = CanvasTransform(
                        offset: CGPoint(x: wsState.offsetX, y: wsState.offsetY),
                        scale: wsState.scale
                    )
                }

                workspace.nodeManager.delegate = self
                for nodeState in wsState.nodes {
                    let node = workspace.nodeManager.createNode(
                        at: CGPoint(x: nodeState.x, y: nodeState.y),
                        size: NSSize(width: nodeState.width, height: nodeState.height),
                        workingDirectory: nodeState.workingDirectory
                    )
                    node.title = nodeState.title
                }
            }

            // Switch to the previously active workspace
            if activeIdx > 0 && activeIdx < workspaceManager.workspaces.count {
                workspaceManager.switchTo(workspace: workspaceManager.workspaces[activeIdx])
            }

            if let wx = state.windowX, let wy = state.windowY,
               let ww = state.windowWidth, let wh = state.windowHeight {
                let savedFrame = NSRect(x: wx, y: wy, width: ww, height: wh)
                window.setFrame(savedFrame, display: true)
            } else {
                window.center()
            }
        } else {
            // Fresh start: one workspace with one terminal
            let workspace = workspaceManager.createWorkspace(name: "Workspace 1")
            workspace.nodeManager.delegate = self
            canvasView.nodeManager = workspace.nodeManager
            workspace.nodeManager.createNode(at: Self.defaultNodeOrigin, size: Self.defaultNodeSize)
            window.center()
        }

        syncSidebar()
        window.makeKeyAndOrderFront(nil)

        // Poll for process state changes to update sidebar bolt icons
        processStateTimer = Timer.scheduledTimer(withTimeInterval: Self.processCheckInterval, repeats: true) { [weak self] _ in
            self?.checkProcessStates()
        }
    }

    private func checkProcessStates() {
        // Check across all workspaces
        var allStates: [Bool] = []
        for workspace in workspaceManager.workspaces {
            for node in workspace.nodeManager.nodes {
                let surface = node.terminalView.surface
                allStates.append(surface.map { ghostty_surface_needs_confirm_quit($0) } ?? false)
            }
        }
        if allStates != cachedProcessStates {
            cachedProcessStates = allStates
            sidebarModel.update(from: activeNodeManager)
            sidebarModel.updateWorkspaces(from: workspaceManager)
            minimapView.refresh()
        }
    }

    private func syncSidebar() {
        sidebarModel.update(from: activeNodeManager)
        sidebarModel.updateWorkspaces(from: workspaceManager)
        minimapView.nodeManager = activeNodeManager
        minimapView.refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Cmd+Q Running Process Check

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isConfirmedClose { return .terminateNow }

        guard workspaceManager.anyWorkspaceNeedsConfirmation() else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Quit Finite?"
        alert.informativeText = "One or more terminals have running processes. Quit anyway?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.isConfirmedClose = true
                NSApp.reply(toApplicationShouldTerminate: true)
            } else {
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }

        return .terminateLater
    }

    // MARK: - Close Confirmation

    /// Show a confirmation alert if any selected terminals have running processes.
    private func showCloseConfirmation(
        message: String,
        info: String = "One or more terminals have running processes.",
        buttonTitle: String = "Close",
        onConfirm: @escaping () -> Void
    ) {
        guard activeNodeManager.selectedNodesNeedConfirmation() else {
            onConfirm()
            return
        }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: buttonTitle)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                onConfirm()
            }
        }
    }

    // MARK: - Actions

    @objc func newTerminal(_ sender: Any?) {
        let node = activeNodeManager.createNode(size: Self.defaultNodeSize)
        ensureNodeVisible(node)
    }

    @objc func duplicateTerminal(_ sender: Any?) {
        guard let focused = activeNodeManager.focusedNode else { return }
        if let node = activeNodeManager.duplicateNode(focused) {
            ensureNodeVisible(node)
        }
    }

    @objc func closeTerminal(_ sender: Any?) {
        let selected = activeNodeManager.selectedNodeViews
        if selected.count > 1 {
            closeSelectedTerminals()
        } else if let focused = activeNodeManager.focusedNode {
            activeNodeManager.requestCloseNode(focused)
        }
    }

    private func closeSelectedTerminals() {
        let count = activeNodeManager.selectedNodeViews.count
        showCloseConfirmation(
            message: "Close \(count) terminals?",
            buttonTitle: "Close All"
        ) { [weak self] in
            self?.activeNodeManager.closeSelectedNodes()
        }
    }

    @objc func showAbout(_ sender: Any?) {
        let ghosttyVersion = Bundle.main.infoDictionary?["GhosttyVersion"] as? String ?? "unknown"
        let ghosttyCommit = Bundle.main.infoDictionary?["GhosttyCommit"] as? String ?? "unknown"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        let credits = NSAttributedString(
            string: "Ghostty \(ghosttyVersion) (\(ghosttyCommit))\nFinite \(version) (\(build))",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )

        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
        ])
    }

    @objc func checkForUpdates(_ sender: Any?) {
        SparkleUpdater.shared.checkForUpdates()
    }

    @objc func toggleSidebarPanel(_ sender: Any?) {
        if sidebarOverlay.isHidden {
            sidebarOverlay.isHidden = false
            sidebarOverlay.alphaValue = 0
            sidebarLeading.constant = -200
            sidebarOverlay.superview?.layoutSubtreeIfNeeded()
            sidebarLeading.constant = 12
            sidebarToggleLeading.constant = Self.sidebarWidth
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                self.sidebarOverlay.alphaValue = 1
                self.sidebarOverlay.superview?.layoutSubtreeIfNeeded()
            }
        } else {
            sidebarLeading.constant = -200
            sidebarToggleLeading.constant = 12
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                context.allowsImplicitAnimation = true
                self.sidebarOverlay.alphaValue = 0
                self.sidebarOverlay.superview?.layoutSubtreeIfNeeded()
            } completionHandler: {
                self.sidebarOverlay.isHidden = true
                self.sidebarOverlay.alphaValue = 1
                self.sidebarLeading.constant = 12
            }
        }
    }

    @objc func toggleMinimap(_ sender: Any?) {
        minimapView.isHidden.toggle()
    }

    @objc func zoomToFitAll(_ sender: Any?) {
        let sw: CGFloat = sidebarOverlay.isHidden ? 0 : Self.sidebarWidth
        canvasView.zoomToFitAll(sidebarWidth: sw)
    }

    @objc func zoomToFitFocused(_ sender: Any?) {
        if let focused = activeNodeManager.focusedNode {
            let sw: CGFloat = sidebarOverlay.isHidden ? 0 : Self.sidebarWidth
            canvasView.zoomToFitNode(focused, sidebarWidth: sw)
        }
    }

    @objc func deselectAll(_ sender: Any?) {
        activeNodeManager.clearSelection()
    }

    @objc func tidySelection(_ sender: Any?) {
        activeNodeManager.tidySelectedNodes()
    }

    // MARK: - Workspace Actions

    @objc func newWorkspace(_ sender: Any?) {
        let name = workspaceManager.nextWorkspaceName()
        let workspace = workspaceManager.createWorkspace(name: name)
        workspace.nodeManager.delegate = self
        workspace.nodeManager.createNode(at: Self.defaultNodeOrigin, size: Self.defaultNodeSize)
        syncSidebar()
    }

    @objc func nextWorkspace(_ sender: Any?) {
        workspaceManager.switchToNext()
    }

    @objc func previousWorkspace(_ sender: Any?) {
        workspaceManager.switchToPrevious()
    }

    private func deleteWorkspace(_ workspace: Workspace) {
        guard workspaceManager.workspaces.count > 1 else { return }

        let hasRunning = workspace.nodeManager.nodes.contains { node in
            guard let surface = node.terminalView.surface else { return false }
            return ghostty_surface_needs_confirm_quit(surface)
        }

        if hasRunning {
            let alert = NSAlert()
            alert.messageText = "Delete \"\(workspace.name)\"?"
            alert.informativeText = "This workspace has terminals with running processes. Delete anyway?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    self?.workspaceManager.deleteWorkspace(workspace)
                    self?.syncSidebar()
                }
            }
        } else {
            workspaceManager.deleteWorkspace(workspace)
            syncSidebar()
        }
    }

    // MARK: - Navigation

    private func navigate(_ direction: TerminalNodeManager.Direction) {
        guard let focused = activeNodeManager.focusedNode,
              let target = activeNodeManager.nearestNode(from: focused, direction: direction) else { return }
        activeNodeManager.handleClick(target, modifiers: [])
        ensureNodeVisible(target)
    }

    private func ensureNodeVisible(_ node: TerminalNodeView) {
        let nodeScreenRect = canvasView.canvasTransform.screenRect(from: node.frame)
        let visibleRect = canvasView.bounds.insetBy(dx: 40, dy: 40)
        if visibleRect.contains(nodeScreenRect) { return }

        // Pan so the node's center is in view (keep current zoom)
        let scale = canvasView.canvasTransform.scale
        let targetCenter = CGPoint(x: node.frame.midX, y: node.frame.midY)
        let newOffset = CGPoint(
            x: targetCenter.x - canvasView.bounds.midX / scale,
            y: targetCenter.y - canvasView.bounds.midY / scale
        )

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            self.canvasView.canvasTransform = CanvasTransform(
                offset: newOffset,
                scale: scale
            )
        }
    }

    private func panToNode(_ node: TerminalNodeView) {
        let scale = canvasView.canvasTransform.scale
        let targetCenter = CGPoint(x: node.frame.midX, y: node.frame.midY)
        let newOffset = CGPoint(
            x: targetCenter.x - canvasView.bounds.midX / scale,
            y: targetCenter.y - canvasView.bounds.midY / scale
        )

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            self.canvasView.canvasTransform = CanvasTransform(
                offset: newOffset,
                scale: scale
            )
        }
    }

    @objc func navigateLeft(_ sender: Any?) { navigate(.left) }
    @objc func navigateRight(_ sender: Any?) { navigate(.right) }
    @objc func navigateUp(_ sender: Any?) { navigate(.up) }
    @objc func navigateDown(_ sender: Any?) { navigate(.down) }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isConfirmedClose { return true }

        guard workspaceManager.anyWorkspaceNeedsConfirmation() else { return true }

        let alert = NSAlert()
        alert.messageText = "Close Finite?"
        alert.informativeText = "One or more terminals have running processes. Close anyway?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.isConfirmedClose = true
                sender.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardMonitor = nil
        }
        processStateTimer?.invalidate()
        processStateTimer = nil
        minimapView.stopRefreshing()

        CanvasState.save(from: workspaceManager, canvasView: canvasView, windowFrame: window.frame)

        for workspace in workspaceManager.workspaces {
            workspace.nodeManager.isClosingWindow = true
            for node in workspace.nodeManager.nodes {
                if let surface = node.terminalView.surface {
                    ghostty_surface_request_close(surface)
                }
            }
        }
    }
}

// MARK: - TerminalNodeManagerDelegate

extension AppDelegate: TerminalNodeManagerDelegate {
    private func syncUI(_ manager: TerminalNodeManager) {
        sidebarModel.update(from: activeNodeManager)
        sidebarModel.updateWorkspaces(from: workspaceManager)
        minimapView.refresh()
    }

    func nodeManager(_ manager: TerminalNodeManager, didCreateNode node: TerminalNodeView) { syncUI(manager) }
    func nodeManager(_ manager: TerminalNodeManager, didRemoveNode node: TerminalNodeView) {
        syncUI(manager)
        if let focused = manager.focusedNode {
            ensureNodeVisible(focused)
        }
    }
    func nodeManager(_ manager: TerminalNodeManager, didFocusNode node: TerminalNodeView?) { syncUI(manager) }
    func nodeManager(_ manager: TerminalNodeManager, didUpdateTitleFor node: TerminalNodeView) { syncUI(manager) }
    func nodeManager(_ manager: TerminalNodeManager, didUpdateActivityFor node: TerminalNodeView) { syncUI(manager) }
    func nodeManager(_ manager: TerminalNodeManager, didUpdateSelection selectedNodes: Set<ObjectIdentifier>) { syncUI(manager) }
    func nodeManagerDidRemoveLastNode(_ manager: TerminalNodeManager) {
        // Only close if ALL workspaces are empty
        if workspaceManager.allWorkspacesEmpty {
            window.close()
        }
    }
}

// MARK: - WorkspaceManagerDelegate

extension AppDelegate: WorkspaceManagerDelegate {
    func workspaceManager(_ manager: WorkspaceManager, didSwitchTo workspace: Workspace) {
        syncSidebar()
    }

    func workspaceManager(_ manager: WorkspaceManager, didAdd workspace: Workspace) {
        syncSidebar()
    }

    func workspaceManager(_ manager: WorkspaceManager, didRemove workspace: Workspace) {
        syncSidebar()
    }

    func workspaceManager(_ manager: WorkspaceManager, didRename workspace: Workspace) {
        syncSidebar()
    }
}
