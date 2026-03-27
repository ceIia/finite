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
                .glassOrMaterial(shape: .circle)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Glass Effect Compatibility

/// Uses `.glassEffect()` (Liquid Glass) on macOS 26+, falls back to
/// `.ultraThinMaterial` on earlier releases.
extension View {
    @ViewBuilder
    func glassOrMaterial(shape: GlassFallbackShape) -> some View {
        #if canImport(GlassEffect)
        if #available(macOS 26.0, *) {
            switch shape {
            case .circle:
                self.glassEffect(.regular, in: .circle)
            case .capsule:
                self.glassEffect(.regular, in: .capsule)
            case .roundedRectangle(let r):
                self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: r))
            }
        } else {
            _materialFallback(shape: shape)
        }
        #else
        _materialFallback(shape: shape)
        #endif
    }

    @ViewBuilder
    private func _materialFallback(shape: GlassFallbackShape) -> some View {
        switch shape {
        case .circle:
            self.background(.ultraThinMaterial).clipShape(Circle())
        case .capsule:
            self.background(.ultraThinMaterial).clipShape(Capsule())
        case .roundedRectangle(let r):
            self.background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: r))
        }
    }
}

enum GlassFallbackShape {
    case circle, capsule, roundedRectangle(cornerRadius: CGFloat)
}
