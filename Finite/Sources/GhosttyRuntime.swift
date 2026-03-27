import AppKit
import os

private let logger = Logger(subsystem: "com.helm.finite", category: "GhosttyRuntime")

/// Singleton managing the ghostty_app_t lifecycle and runtime callbacks.
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    /// The ghostty app handle, available after `initialize()`.
    private(set) var app: ghostty_app_t?
    /// The ghostty config handle, available after `initialize()`.
    private(set) var config: ghostty_config_t?
    /// Observers for NSApplication notifications (focus tracking).
    private var appObservers: [NSObjectProtocol] = []

    // MARK: - Surface View Registry

    /// Weak-reference registry for safe C callback → Swift object resolution.
    /// Avoids unsafe Unmanaged pointer casts that can crash on use-after-free.
    private var surfaceViews: [UnsafeMutableRawPointer: WeakRef<TerminalSurfaceView>] = [:]

    func registerSurfaceView(_ view: TerminalSurfaceView, pointer: UnsafeMutableRawPointer) {
        surfaceViews[pointer] = WeakRef(view)
    }

    func unregisterSurfaceView(pointer: UnsafeMutableRawPointer) {
        surfaceViews.removeValue(forKey: pointer)
    }

    func surfaceView(for pointer: UnsafeMutableRawPointer) -> TerminalSurfaceView? {
        surfaceViews[pointer]?.value
    }

    /// Called by the surface when it closes so the runtime can notify the manager.
    var onSurfaceClosed: ((ghostty_surface_t) -> Void)?

    /// Called when an action sets a surface title.
    var onSetTitle: ((ghostty_surface_t, String) -> Void)?

    /// Called when the user requests a new terminal (e.g. Cmd+N binding).
    var onNewTerminal: (() -> Void)?

    /// Called when the user requests closing the focused terminal.
    var onCloseTerminal: (() -> Void)?

    /// Called when Ghostty's close_surface_cb fires with needsConfirmClose=true.
    var onCloseSurfaceRequested: ((ghostty_surface_t, Bool) -> Void)?

    /// Called when a surface renders (activity indicator).
    var onRender: ((ghostty_surface_t) -> Void)?

    /// Called when the terminal's working directory changes (via OSC 7).
    var onPwdChanged: ((ghostty_surface_t, String) -> Void)?

    private init() {}

    private struct WeakRef<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }

    func initialize() {
        guard let cfg = ghostty_config_new() else {
            fatalError("Failed to create ghostty config — cannot start without Ghostty runtime")
        }

        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)

        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = false

        runtimeConfig.wakeup_cb = { _ in
            DispatchQueue.main.async {
                guard let app = GhosttyRuntime.shared.app else { return }
                ghostty_app_tick(app)
            }
        }

        runtimeConfig.action_cb = { app, target, action in
            return GhosttyRuntime.shared.handleAction(target: target, action: action)
        }

        runtimeConfig.read_clipboard_cb = { userdata, location, state in
            guard let userdata = userdata,
                  let surfaceView = GhosttyRuntime.shared.surfaceView(for: userdata),
                  let surface = surfaceView.surface else { return false }
            let pasteboard = NSPasteboard.general
            let value = pasteboard.string(forType: .string) ?? ""
            value.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
            }
            return true
        }

        runtimeConfig.confirm_read_clipboard_cb = { userdata, content, state, _ in
            guard let content = content,
                  let userdata = userdata,
                  let surfaceView = GhosttyRuntime.shared.surfaceView(for: userdata),
                  let surface = surfaceView.surface else { return }
            ghostty_surface_complete_clipboard_request(surface, content, state, true)
        }

        runtimeConfig.write_clipboard_cb = { _, location, content, len, _ in
            guard let content = content, len > 0 else { return }
            let buffer = UnsafeBufferPointer(start: content, count: Int(len))
            var text: String?
            for item in buffer {
                guard let dataPtr = item.data else { continue }
                let value = String(cString: dataPtr)
                if let mimePtr = item.mime {
                    let mime = String(cString: mimePtr)
                    if mime.hasPrefix("text/plain") {
                        text = value
                        break
                    }
                }
                if text == nil { text = value }
            }
            if let text = text {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }

        runtimeConfig.close_surface_cb = { userdata, needsConfirmClose in
            guard let userdata = userdata,
                  let surfaceView = GhosttyRuntime.shared.surfaceView(for: userdata),
                  let surface = surfaceView.surface else { return }
            DispatchQueue.main.async {
                if needsConfirmClose {
                    GhosttyRuntime.shared.onCloseSurfaceRequested?(surface, needsConfirmClose)
                } else {
                    GhosttyRuntime.shared.onSurfaceClosed?(surface)
                }
            }
        }

        guard let created = ghostty_app_new(&runtimeConfig, cfg) else {
            ghostty_config_free(cfg)
            fatalError("Failed to create ghostty app — cannot start without Ghostty runtime")
        }

        self.app = created
        self.config = cfg

        // Track app activation for focus state
        ghostty_app_set_focus(created, NSApp.isActive)

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, true)
        })

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, false)
        })
    }

    private func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
            let surface = target.target.surface
            guard let titlePtr = action.action.set_title.title else { return false }
            let title = String(cString: titlePtr)
            DispatchQueue.main.async { [weak self] in
                guard let surface = surface else { return }
                self?.onSetTitle?(surface, title)
            }
            return true

        case GHOSTTY_ACTION_NEW_WINDOW:
            DispatchQueue.main.async { [weak self] in
                self?.onNewTerminal?()
            }
            return true

        case GHOSTTY_ACTION_CLOSE_WINDOW:
            DispatchQueue.main.async { [weak self] in
                self?.onCloseTerminal?()
            }
            return true

        case GHOSTTY_ACTION_RENDER:
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return true }
            if let surface = target.target.surface {
                DispatchQueue.main.async { [weak self] in self?.onRender?(surface) }
            }
            return true

        case GHOSTTY_ACTION_PWD:
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
            let surface = target.target.surface
            guard let pwdPtr = action.action.pwd.pwd else { return true }
            let pwd = String(cString: pwdPtr)
            DispatchQueue.main.async { [weak self] in
                guard let surface = surface else { return }
                self?.onPwdChanged?(surface, pwd)
            }
            return true

        case GHOSTTY_ACTION_NEW_TAB,
             GHOSTTY_ACTION_NEW_SPLIT,
             GHOSTTY_ACTION_CELL_SIZE,
             GHOSTTY_ACTION_SET_TAB_TITLE,
             GHOSTTY_ACTION_MOUSE_SHAPE,
             GHOSTTY_ACTION_MOUSE_VISIBILITY,
             GHOSTTY_ACTION_MOUSE_OVER_LINK,
             GHOSTTY_ACTION_RENDERER_HEALTH,
             GHOSTTY_ACTION_SIZE_LIMIT,
             GHOSTTY_ACTION_INITIAL_SIZE,
             GHOSTTY_ACTION_COLOR_CHANGE,
             GHOSTTY_ACTION_OPEN_URL,
             GHOSTTY_ACTION_RING_BELL,
             GHOSTTY_ACTION_CONFIG_CHANGE,
             GHOSTTY_ACTION_RELOAD_CONFIG:
            // Accept but don't handle these yet
            return true

        default:
            return false
        }
    }
}
