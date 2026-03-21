import AppKit
import SwiftUI

/// Floating liquid glass overlay for the sidebar, rendered inside the main window.
class SidebarOverlayView: NSView {
    private let hostingView: NSHostingView<GlassContainer<SidebarView>>

    init(sidebarView: SidebarView) {
        let container = GlassContainer(content: sidebarView)
        hostingView = NSHostingView(rootView: container)
        super.init(frame: .zero)

        wantsLayer = true

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

// MARK: - SwiftUI Glass Container

struct GlassContainer<Content: View>: View {
    let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
}
