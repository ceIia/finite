import AppKit
import SwiftUI

/// Reusable liquid glass toolbar button wrapping a SwiftUI GlassIconButton.
class GlassToolbarButton: NSView {
    var onAction: (() -> Void)?

    init(systemName: String, iconSize: CGFloat = 13) {
        super.init(frame: .zero)
        wantsLayer = true

        let hostingView = NSHostingView(rootView: GlassIconButton(
            systemName: systemName,
            iconSize: iconSize,
            action: { [weak self] in self?.onAction?() }
        ))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override var acceptsFirstResponder: Bool { false }
}

// Convenience aliases to preserve the existing API used by AppDelegate.
typealias SidebarToggleButton = GlassToolbarButton
typealias NewTerminalButton = GlassToolbarButton

// MARK: - SwiftUI Liquid Glass Button

private struct GlassIconButton: View {
    let systemName: String
    let iconSize: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: iconSize * 2, height: iconSize * 2)
                .glassEffect(.regular, in: .circle)
        }
        .buttonStyle(.plain)
    }
}
