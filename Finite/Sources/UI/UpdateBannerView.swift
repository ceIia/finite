import AppKit
import SwiftUI

class UpdateBannerView: NSView {
    var onUpdate: (() -> Void)?
    var onDismiss: (() -> Void)?

    private var hostingView: NSHostingView<UpdateBanner>?

    init() {
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func show(sha: String) {
        let banner = UpdateBanner(
            sha: sha,
            onUpdate: { [weak self] in self?.onUpdate?() },
            onDismiss: { [weak self] in self?.onDismiss?() }
        )

        if let existing = hostingView {
            existing.rootView = banner
        } else {
            let hosting = NSHostingView(rootView: banner)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.topAnchor.constraint(equalTo: topAnchor),
                hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
                hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            hostingView = hosting
        }

        guard isHidden else { return }
        isHidden = false
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            self.animator().alphaValue = 1
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            self.animator().alphaValue = 0
        } completionHandler: {
            self.isHidden = true
        }
    }

    override var acceptsFirstResponder: Bool { false }
}

// MARK: - SwiftUI Banner

private struct UpdateBanner: View {
    let sha: String
    let onUpdate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))

            Text("Ghostty update available")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))

            Text(sha)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))

            Spacer()

            Button(action: onUpdate) {
                Text("Update & Restart")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.15))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassOrMaterial(shape: .capsule)
    }
}
