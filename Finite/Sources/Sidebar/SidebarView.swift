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

final class SidebarModel: ObservableObject {
    @Published var nodes: [NodeItem] = []
    var onSelectNode: ((TerminalNodeView, NSEvent.ModifierFlags) -> Void)?
    var onCloseSelected: (() -> Void)?
    var onCloseSingle: ((TerminalNodeView) -> Void)?
    var onDuplicateNode: ((TerminalNodeView) -> Void)?
    var onPanToNode: ((TerminalNodeView) -> Void)?
    var onHoverPulse: ((TerminalNodeView) -> Void)?

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
}

struct SidebarView: View {
    @ObservedObject var model: SidebarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                                contextMenuItems(for: item)
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
    private func contextMenuItems(for item: NodeItem) -> some View {
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
