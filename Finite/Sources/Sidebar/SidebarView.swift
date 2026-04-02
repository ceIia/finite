import SwiftUI

struct NodeItem: Identifiable {
    let id: ObjectIdentifier
    let title: String
    let isFocused: Bool
    let isSelected: Bool
    let hasActivity: Bool
    let hasRunningProcess: Bool
    let node: TerminalNodeView?
}

struct WorkspaceItem: Identifiable {
    let id: UUID
    let name: String
    let terminalCount: Int
    let isActive: Bool
}

final class SidebarModel: ObservableObject {
    @Published var nodes: [NodeItem] = []
    @Published var workspaceItems: [WorkspaceItem] = []

    // Terminal callbacks
    var onSelectNode: ((TerminalNodeView, NSEvent.ModifierFlags) -> Void)?
    var onCloseSelected: (() -> Void)?
    var onCloseSingle: ((TerminalNodeView) -> Void)?
    var onDuplicateNode: ((TerminalNodeView) -> Void)?
    var onPanToNode: ((TerminalNodeView) -> Void)?
    var onHoverPulse: ((TerminalNodeView) -> Void)?

    // Workspace callbacks
    var onSelectWorkspace: ((UUID) -> Void)?
    var onCreateWorkspace: (() -> Void)?
    var onDeleteWorkspace: ((UUID) -> Void)?
    var onRenameWorkspace: ((UUID, String) -> Void)?

    func update(from manager: TerminalNodeManager) {
        nodes = manager.nodes.map { node in
            let hasRunning: Bool
            if let surface = node.terminalView.surface {
                hasRunning = ghostty_surface_needs_confirm_quit(surface)
            } else {
                hasRunning = false
            }
            return NodeItem(
                id: ObjectIdentifier(node),
                title: node.title,
                isFocused: node === manager.focusedNode,
                isSelected: manager.isSelected(node),
                hasActivity: manager.hasActivity(node),
                hasRunningProcess: hasRunning,
                node: node
            )
        }
    }

    func updateWorkspaces(from workspaceManager: WorkspaceManager) {
        workspaceItems = workspaceManager.workspaces.enumerated().map { index, workspace in
            WorkspaceItem(
                id: workspace.id,
                name: workspace.name,
                terminalCount: workspace.nodeManager.nodes.count,
                isActive: index == workspaceManager.activeIndex
            )
        }
    }
}

struct SidebarView: View {
    @ObservedObject var model: SidebarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Workspaces section
            HStack {
                Text("Workspaces")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { model.onCreateWorkspace?() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ForEach(model.workspaceItems) { item in
                SidebarWorkspaceRow(item: item, model: model)
                    .onTapGesture {
                        model.onSelectWorkspace?(item.id)
                    }
                    .contextMenu {
                        workspaceContextMenu(for: item)
                    }
            }
            .padding(.horizontal, 4)

            Divider()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            // Terminals section
            Text("Terminals")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(model.nodes) { item in
                        SidebarNodeRow(item: item, model: model)
                            .onTapGesture(count: 2) {
                                if let node = item.node {
                                    model.onPanToNode?(node)
                                }
                            }
                            .onTapGesture(count: 1) {
                                if let node = item.node {
                                    let mods = NSApp.currentEvent?.modifierFlags
                                        .intersection(.deviceIndependentFlagsMask) ?? []
                                    model.onSelectNode?(node, mods)
                                }
                            }
                            .contextMenu {
                                terminalContextMenu(for: item)
                            }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.bottom, 8)
        .frame(minWidth: 160, minHeight: 120)
    }

    @ViewBuilder
    private func workspaceContextMenu(for item: WorkspaceItem) -> some View {
        Button("Rename Workspace...") {
            promptRename(for: item)
        }
        if model.workspaceItems.count > 1 {
            Button("Delete Workspace") {
                model.onDeleteWorkspace?(item.id)
            }
        }
    }

    private func promptRename(for item: WorkspaceItem) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Rename Workspace"
            alert.informativeText = "Enter a new name for this workspace."
            alert.addButton(withTitle: "Rename")
            alert.addButton(withTitle: "Cancel")

            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            textField.stringValue = item.name
            alert.accessoryView = textField

            if let window = NSApp.keyWindow {
                alert.beginSheetModal(for: window) { response in
                    if response == .alertFirstButtonReturn {
                        let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)
                        if !newName.isEmpty {
                            model.onRenameWorkspace?(item.id, newName)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func terminalContextMenu(for item: NodeItem) -> some View {
        let selectedCount = model.nodes.filter { $0.isSelected }.count

        if selectedCount > 1 {
            Button("Close \(selectedCount) Terminals") {
                model.onCloseSelected?()
            }
            Button("Duplicate Terminal") {}
                .disabled(true)
        } else {
            Button("Close Terminal") {
                if let node = item.node {
                    model.onCloseSingle?(node)
                }
            }
            Button("Duplicate Terminal") {
                if let node = item.node {
                    model.onDuplicateNode?(node)
                }
            }
        }
    }
}

// MARK: - Workspace Row

struct SidebarWorkspaceRow: View {
    let item: WorkspaceItem
    let model: SidebarModel

    private var dotColor: Color {
        item.isActive ? .accentColor : Color.white.opacity(0.2)
    }

    private var rowBackground: Color {
        item.isActive ? Color.accentColor.opacity(0.12) : Color.clear
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)

            Text(item.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Text("\(item.terminalCount)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Terminal Node Row

struct SidebarNodeRow: View {
    let item: NodeItem
    let model: SidebarModel
    @State private var isPulsing = false
    @State private var hoverTimer: Timer?

    private var dotColor: Color {
        if item.isFocused { return .accentColor }
        if item.isSelected { return Color.accentColor.opacity(0.5) }
        if item.hasActivity { return .orange }
        return Color.white.opacity(0.2)
    }

    private var rowBackground: Color {
        if item.isFocused { return Color.accentColor.opacity(0.12) }
        if item.isSelected { return Color.accentColor.opacity(0.06) }
        if item.hasActivity { return Color.orange.opacity(0.08) }
        return Color.clear
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .scaleEffect(item.hasActivity && isPulsing ? 1.3 : 1.0)
                .animation(
                    item.hasActivity
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : .default,
                    value: isPulsing
                )
                .onAppear { isPulsing = true }

            Text(item.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            // Running process indicator
            if item.hasRunningProcess {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8))
                    .foregroundColor(.orange.opacity(0.7))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoverTimer?.invalidate()
            hoverTimer = nil
            if hovering, let node = item.node {
                hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
                    model.onHoverPulse?(node)
                }
            }
        }
        .onDisappear {
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
    }
}
