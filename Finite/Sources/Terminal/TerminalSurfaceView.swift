import AppKit
import os

private let logger = Logger(subsystem: "dev.finite", category: "TerminalSurfaceView")

/// NSView that hosts a single libghostty terminal surface.
/// Handles Metal rendering (via libghostty's internal CALayer), keyboard input,
/// mouse input, and IME via NSTextInputClient.
class TerminalSurfaceView: NSView, NSTextInputClient {

    /// The ghostty surface handle, created when the view moves to a window.
    private(set) var surface: ghostty_surface_t?

    /// Back-reference to the canvas (set when added via CanvasView.addTerminalNode).
    /// Used for coordinate transforms on pan/zoom.
    weak var canvasView: CanvasView?

    /// Back-reference to the containing node view (set in TerminalNodeView.init).
    weak var nodeView: TerminalNodeView?

    /// Called when the surface is created, passing the new surface handle.
    var onSurfaceCreated: ((ghostty_surface_t) -> Void)?

    /// Optional inherited config for duplication (set before view moves to window).
    var inheritedSurfaceConfig: ghostty_surface_config_s?
    /// Optional working directory override for duplication.
    var overrideWorkingDirectory: String?

    /// Whether we have marked (composing) text from IME.
    private var markedTextStorage = NSMutableAttributedString()
    private var isMarkedTextActive = false

    /// Text stashed by insertText during interpretKeyEvents, consumed by keyDown.
    private var insertedText: String?

    // Track previous modifier flags for flagsChanged delta detection
    private var previousModifierFlags: NSEvent.ModifierFlags = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.isOpaque = true
    }

    deinit {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        GhosttyRuntime.shared.unregisterSurfaceView(pointer: pointer)
        if let surface = surface {
            ghostty_surface_free(surface)
        }
    }

    // MARK: - Surface Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, surface == nil else { return }
        createSurface()
    }

    private func createSurface() {
        guard let app = GhosttyRuntime.shared.app else {
            logger.error("GhosttyRuntime not initialized when creating surface")
            return
        }
        guard let window = self.window else { return }

        var config: ghostty_surface_config_s
        if let inherited = inheritedSurfaceConfig {
            config = inherited
        } else {
            config = ghostty_surface_config_new()
        }
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = window.backingScaleFactor
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        if let pwd = overrideWorkingDirectory {
            pwd.withCString { ptr in
                config.working_directory = ptr
                surface = ghostty_surface_new(app, &config)
            }
        } else {
            surface = ghostty_surface_new(app, &config)
        }
        guard let surface = surface else {
            logger.error("Failed to create ghostty surface")
            return
        }

        // Set initial display, scale, and size
        if let screen = window.screen ?? NSScreen.main,
           let displayID = screen.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(surface, displayID)
        }

        let scaleFactor = window.backingScaleFactor
        ghostty_surface_set_content_scale(surface, Double(scaleFactor), Double(scaleFactor))

        let backingSize = convertToBacking(bounds).size
        let wpx = UInt32(max(backingSize.width, 1))
        let hpx = UInt32(max(backingSize.height, 1))
        ghostty_surface_set_size(surface, wpx, hpx)

        // Register with the runtime's surface registry for safe C callback resolution
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        GhosttyRuntime.shared.registerSurfaceView(self, pointer: pointer)

        ghostty_surface_refresh(surface)
        onSurfaceCreated?(surface)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface = surface, let window = self.window else { return }
        let scale = window.backingScaleFactor
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
        updateSurfaceSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let surface = surface else { return }
        let backingSize = convertToBacking(bounds).size
        let wpx = UInt32(max(backingSize.width, 1))
        let hpx = UInt32(max(backingSize.height, 1))
        guard wpx > 0, hpx > 0 else { return }
        ghostty_surface_set_size(surface, wpx, hpx)
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface = surface {
            ghostty_surface_set_focus(surface, true)
        }
        if result, let node = nodeView, let manager = node.canvasView?.nodeManager {
            // Only update selection if not already being handled by the manager
            if !manager.isHandlingFocus && manager.focusedNode !== node {
                manager.handleClick(node, modifiers: [])
            }
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface = surface {
            ghostty_surface_set_focus(surface, false)
        }
        return result
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        guard let surface = surface else { return }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let (translationMods, translationEvent) = buildTranslationEvent(from: event, surface: surface)

        insertedText = nil
        interpretKeyEvents([translationEvent])

        var keyEvent = buildGhosttyKeyEvent(from: event, action: action, translationMods: translationMods)

        // Use text from insertText (IME/composed) if available, else from translation event.
        // Drop control characters (< 0x20) so Ghostty encodes them via keycode+mods
        // (e.g. Shift+Tab → \e[Z instead of sending raw backtab U+0019).
        let text: String?
        if let inserted = insertedText {
            text = Self.shouldSendText(inserted) ? inserted : nil
        } else if isMarkedTextActive {
            text = nil
        } else if let computed = Self.textForKeyEvent(translationEvent), Self.shouldSendText(computed) {
            text = computed
        } else {
            text = nil
        }

        if let text = text {
            text.withCString { ptr in
                keyEvent.text = ptr
                _ = ghostty_surface_key(surface, keyEvent)
            }
        } else {
            keyEvent.text = nil
            _ = ghostty_surface_key(surface, keyEvent)
        }
    }

    /// Compute translation modifiers and build a translation event for IME / dead key composition.
    /// Ghostty tells us which modifiers should be used for text translation so that keys like
    /// Shift+Tab don't have shift consumed (allowing Ghostty to generate \e[Z).
    private func buildTranslationEvent(from event: NSEvent, surface: ghostty_surface_t) -> (NSEvent.ModifierFlags, NSEvent) {
        let ghosttyMods = ghostty_surface_key_translation_mods(surface, Self.ghosttyMods(event.modifierFlags))
        var translationMods = event.modifierFlags

        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let hasFlag: Bool
            switch flag {
            case .shift:   hasFlag = (ghosttyMods.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0
            case .control: hasFlag = (ghosttyMods.rawValue & GHOSTTY_MODS_CTRL.rawValue) != 0
            case .option:  hasFlag = (ghosttyMods.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0
            case .command: hasFlag = (ghosttyMods.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0
            default:       hasFlag = translationMods.contains(flag)
            }
            if hasFlag { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }

        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        return (translationMods, translationEvent)
    }

    /// Build the ghostty_input_key_s struct from an NSEvent and computed translation modifiers.
    private func buildGhosttyKeyEvent(from event: NSEvent, action: ghostty_input_action_e,
                                       translationMods: NSEvent.ModifierFlags) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = Self.ghosttyMods(event.modifierFlags)

        var consumedMods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if translationMods.contains(.shift) { consumedMods |= GHOSTTY_MODS_SHIFT.rawValue }
        if translationMods.contains(.option) { consumedMods |= GHOSTTY_MODS_ALT.rawValue }
        keyEvent.consumed_mods = ghostty_input_mods_e(rawValue: consumedMods)
        keyEvent.composing = isMarkedTextActive

        if event.type == .keyDown || event.type == .keyUp {
            if let chars = event.characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                keyEvent.unshifted_codepoint = codepoint.value
            }
        }
        return keyEvent
    }

    override func doCommand(by selector: Selector) {
        // Intentionally do not call super.
        // Prevents the system beep for keys like delete, tab, arrows, etc.
        // These keys are handled via keycode in ghostty_surface_key.
    }

    override func keyUp(with event: NSEvent) {
        guard let surface = surface else { return }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = Self.ghosttyMods(event.modifierFlags)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = 0
        _ = ghostty_surface_key(surface, keyEvent)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface = surface else { return }

        // Determine if this is a press or release by comparing with previous flags
        let newFlags = event.modifierFlags
        let action: ghostty_input_action_e = newFlags.rawValue > previousModifierFlags.rawValue
            ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        previousModifierFlags = newFlags

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = Self.ghosttyMods(newFlags)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = 0

        _ = ghostty_surface_key(surface, keyEvent)
    }

    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        guard let surface = surface else { return }
        window?.makeFirstResponder(self)
        let pos = localPosition(from: event)
        let mods = Self.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, pos.x, pos.y, mods)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        let mods = Self.ghosttyMods(event.modifierFlags)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface = surface else { return }
        let pos = localPosition(from: event)
        let mods = Self.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, pos.x, pos.y, mods)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        let mods = Self.ghosttyMods(event.modifierFlags)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface = surface else { return }
        let pos = localPosition(from: event)
        let mods = Self.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, pos.x, pos.y, mods)
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = surface else { return }
        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY

        // Build scroll mods as a packed int
        var scrollMods: Int32 = 0
        if event.hasPreciseScrollingDeltas {
            scrollMods |= (1 << 0) // precision bit
        }
        // Momentum phase
        let momentumPhase: ghostty_input_mouse_momentum_e
        switch event.momentumPhase {
        case .began: momentumPhase = GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: momentumPhase = GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: momentumPhase = GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: momentumPhase = GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: momentumPhase = GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: momentumPhase = GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default: momentumPhase = GHOSTTY_MOUSE_MOMENTUM_NONE
        }
        scrollMods |= (Int32(momentumPhase.rawValue) << 1)

        ghostty_surface_mouse_scroll(surface, deltaX, deltaY, scrollMods)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Remove existing tracking areas
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        // Add a tracking area for the entire view
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard surface != nil else { return }

        let chars: String
        if let attrStr = string as? NSAttributedString {
            chars = attrStr.string
        } else if let str = string as? String {
            chars = str
        } else {
            return
        }

        // Clear marked text
        isMarkedTextActive = false
        markedTextStorage.mutableString.setString("")

        // Stash text for keyDown to pick up via ghostty_surface_key.
        // Do NOT call ghostty_surface_text here — that would double-send.
        insertedText = chars
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let surface = surface else { return }

        if let attrStr = string as? NSAttributedString {
            markedTextStorage = NSMutableAttributedString(attributedString: attrStr)
        } else if let str = string as? String {
            markedTextStorage = NSMutableAttributedString(string: str)
        }

        isMarkedTextActive = markedTextStorage.length > 0

        // Sync preedit state with ghostty
        let preeditStr = markedTextStorage.string
        if preeditStr.isEmpty {
            ghostty_surface_preedit(surface, nil, 0)
        } else {
            preeditStr.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(preeditStr.utf8.count))
            }
        }
    }

    func unmarkText() {
        guard let surface = surface else { return }
        isMarkedTextActive = false
        markedTextStorage.mutableString.setString("")
        ghostty_surface_preedit(surface, nil, 0)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        guard isMarkedTextActive else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedTextStorage.length)
    }

    func hasMarkedText() -> Bool { isMarkedTextActive }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface = surface else { return .zero }
        var x: Double = 0
        var y: Double = 0
        var w: Double = 0
        var h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)

        if let canvas = canvasView, let node = superview {
            // IME point is in surface-local coords (top-left origin).
            // Convert to canvas coords, then through the canvas transform to screen space.
            let canvasPoint = CGPoint(
                x: node.frame.origin.x + x,
                y: node.frame.origin.y + (bounds.height - y - h)
            )
            let screenSpacePoint = canvas.canvasTransform.screenPoint(from: canvasPoint)
            let scaledSize = CGSize(
                width: w * canvas.canvasTransform.scale,
                height: h * canvas.canvasTransform.scale
            )
            let canvasViewRect = NSRect(origin: screenSpacePoint, size: scaledSize)
            let windowRect = canvas.convert(canvasViewRect, to: nil)
            return window?.convertToScreen(windowRect) ?? canvasViewRect
        }

        // Non-canvas path: direct conversion
        let viewRect = NSRect(x: x, y: bounds.height - y - h, width: w, height: h)
        let windowRect = convert(viewRect, to: nil)
        return window?.convertToScreen(windowRect) ?? viewRect
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    // MARK: - Helpers

    /// Convert an NSEvent's location to surface-local coordinates with Y flipped
    /// (ghostty expects origin at top-left).
    private func localPosition(from event: NSEvent) -> CGPoint {
        if let canvas = canvasView {
            // With sublayerTransform, AppKit's convert doesn't account for the
            // canvas transform. We convert window coords → canvas view local,
            // then inverse-transform to canvas space, then subtract our node origin.
            let canvasLocal = canvas.convert(event.locationInWindow, from: nil)
            let canvasPoint = canvas.canvasTransform.canvasPoint(from: canvasLocal)
            guard let node = superview as? TerminalNodeView else {
                return CGPoint(x: canvasPoint.x, y: bounds.height - canvasPoint.y)
            }
            let nodeLocal = node.localPoint(from: canvasPoint)
            return CGPoint(x: nodeLocal.x, y: bounds.height - nodeLocal.y)
        }
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }

    /// Translate NSEvent modifier flags to ghostty modifier bitmask.
    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        let rawFlags = flags.rawValue
        if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    /// Whether text should be delivered to ghostty. Control characters (< 0x20)
    /// like Tab, Escape, Backspace should be encoded by Ghostty via keycode+mods.
    static func shouldSendText(_ text: String) -> Bool {
        guard let first = text.utf8.first else { return false }
        return first >= 0x20
    }

    /// Returns text suitable for ghostty key events, handling control characters and PUA.
    static func textForKeyEvent(_ event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty else { return nil }

        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            // Control characters: return without control modifier so Ghostty can encode
            if scalar.value < 0x20 {
                if event.modifierFlags.contains(.control) {
                    return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
                }
            }
            // Private Use Area (function keys) should not be sent as text
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return chars
    }
}

// MARK: - NSScreen display ID helper

extension NSScreen {
    var displayID: UInt32? {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return screenNumber.uint32Value
    }
}
