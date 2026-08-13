import AppKit
import Darwin
import GhosttyKit

@MainActor
private final class RemoteZmxInstallCoordinator {
    static let shared = RemoteZmxInstallCoordinator()

    private var installedConnectionIDs: Set<UUID> = []
    private var requests: [UUID: Task<Bool, Never>] = [:]

    func ensureInstalled(on connection: SSHConnection) async -> Bool {
        // ponytail: cache per app run; recheck after relaunch.
        if installedConnectionIDs.contains(connection.id) { return true }
        if let request = requests[connection.id] { return await request.value }

        let request = Task { [weak self] in
            guard self != nil else { return false }
            let installer = RemoteZmxInstaller()
            let installed = await Task.detached {
                installer.isInstalled(on: connection)
            }.value
            guard !installed else { return true }

            let alert = NSAlert()
            alert.messageText = "zmx is required on \(connection.name)"
            alert.informativeText = "Install zmx 0.7.0 in ~/.local/bin?"
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }

            do {
                try await Task.detached {
                    try installer.install(on: connection)
                }.value
                return true
            } catch {
                NSAlert(error: error).runModal()
                return false
            }
        }
        requests[connection.id] = request
        let installed = await request.value
        requests.removeValue(forKey: connection.id)
        if installed { installedConnectionIDs.insert(connection.id) }
        return installed
    }
}

@MainActor
final class GhosttySurfaceView: NSView, @preconcurrency NSTextInputClient {
    private let runtime: GhosttyRuntime
    private let terminalSession: ZmxTerminalClient
    private let ioBridge: GhosttyIOBridge
    private var markedTextStorage = NSMutableAttributedString()
    private var suppressFocusMouseUp = false
    private var trackingAreaToken: NSTrackingArea?
    private var surfaceCreationScheduled = false
    private var receivedTerminalOutput = false
    private var remoteStartTask: Task<Void, Never>?
    private var lastPixelWidth: UInt32 = 0
    private var lastPixelHeight: UInt32 = 0

    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?
    var workingDirectory: String
    let target: TerminalTarget
    var didFocus: (() -> Void)?
    var didConnect: (() -> Void)?
    var didFailToConnect: ((String) -> Void)?
    var didChangeTitle: ((String) -> Void)?
    var defaultTitle: String { URL(fileURLWithPath: UserShell.loginPath).lastPathComponent }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    init(
        runtime: GhosttyRuntime,
        workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        target: TerminalTarget = .local,
        sessionID: UUID
    ) {
        self.runtime = runtime
        self.workingDirectory = workingDirectory
        self.target = target
        terminalSession = ZmxTerminalClient(
            id: sessionID,
            workingDirectory: workingDirectory,
            target: target
        )
        ioBridge = GhosttyIOBridge()
        super.init(frame: .zero)
        ioBridge.session = terminalSession
        terminalSession.onOutput = { [weak self] data in
            guard let self else { return }
            if !receivedTerminalOutput {
                receivedTerminalOutput = true
                didConnect?()
            }
            processTerminalOutput(data)
        }
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    deinit {
        remoteStartTask?.cancel()
        terminalSession.disconnect()
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleSurfaceCreation()
        updateSurfaceGeometry()
    }

    override func layout() {
        super.layout()
        scheduleSurfaceCreation()
        updateSurfaceGeometry()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleSurfaceCreation()
        updateSurfaceGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? 2
        ghostty_surface_set_content_scale(surface, scale, scale)
        layer?.contentsScale = scale
        updateSurfaceGeometry()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            if let surface {
                ghostty_surface_set_focus(surface, true)
            }
            didFocus?()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, let surface {
            ghostty_surface_set_focus(surface, false)
        }
        return resigned
    }

    func setApplicationFocused(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused && window?.firstResponder === self)
    }

    private func scheduleSurfaceCreation() {
        guard surface == nil, !surfaceCreationScheduled, window != nil else { return }
        surfaceCreationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.surfaceCreationScheduled = false
            self.window?.contentView?.layoutSubtreeIfNeeded()
            guard
                self.surface == nil,
                self.window != nil,
                self.bounds.width > 0,
                self.bounds.height > 0
            else {
                return
            }
            do {
                try self.createSurface()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func createSurface() throws {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let created = workingDirectory.withCString { directory in
            var config = ghostty_surface_config_new()
            config.platform_tag = GHOSTTY_PLATFORM_MACOS
            config.platform.macos = ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(self).toOpaque()
            )
            config.userdata = Unmanaged.passUnretained(self).toOpaque()
            config.scale_factor = scale
            config.working_directory = directory
            config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT
            config.io_mode = GHOSTTY_SURFACE_IO_MANUAL
            config.io_write_cb = ghosttyManualIOWrite
            config.io_write_userdata = Unmanaged.passUnretained(ioBridge).toOpaque()
            return ghostty_surface_new(runtime.app, &config)
        }
        guard let created else { throw GhosttyError.surfaceCreation }
        surface = created
        ghostty_surface_set_focus(created, window?.firstResponder === self)
        updateSurfaceGeometry()
        startTerminalSession()
        runtime.tick()
    }

    private func startTerminalSession() {
        guard case .ssh(let connection) = target else {
            terminalSession.start()
            return
        }
        remoteStartTask?.cancel()
        remoteStartTask = Task { [weak self] in
            do {
                try await Task.detached {
                    try SSHCommand.test(connection: connection)
                }.value
                guard !Task.isCancelled,
                      let self,
                      await RemoteZmxInstallCoordinator.shared.ensureInstalled(on: connection)
                else { return }
                self.terminalSession.start()
            } catch is CancellationError {
                return
            } catch {
                self?.presentConnectionFailure(error.localizedDescription)
            }
        }
    }

    private func presentConnectionFailure(_ message: String) {
        didFailToConnect?(message)
        processTerminalOutput(Data("\r\n[Piñata] \(message)\r\n".utf8))

        let alert = NSAlert()
        alert.messageText = "SSH connection failed"
        alert.informativeText = message
        alert.addButton(withTitle: "Reconnect")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            startTerminalSession()
        }
    }

    private var currentDisplayID: UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (window?.screen?.deviceDescription[key] as? NSNumber)?.uint32Value
    }

    private func updateSurfaceGeometry() {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let backing = convertToBacking(bounds.size)
        let width = UInt32(max(1, backing.width.rounded()))
        let height = UInt32(max(1, backing.height.rounded()))
        guard width != lastPixelWidth || height != lastPixelHeight else { return }
        lastPixelWidth = width
        lastPixelHeight = height
        if let displayID = currentDisplayID, displayID != 0 {
            ghostty_surface_set_display_id(surface, displayID)
        }
        ghostty_surface_set_size(surface, width, height)
        let size = ghostty_surface_size(surface)
        terminalSession.resize(columns: size.columns, rows: size.rows)
        ghostty_surface_refresh(surface)
        layer?.setNeedsDisplay()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if window.firstResponder !== self {
            window.makeFirstResponder(self)
            suppressFocusMouseUp = true
            return
        }
        sendMousePosition(event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modifiers(event))
    }

    override func mouseUp(with event: NSEvent) {
        if suppressFocusMouseUp {
            suppressFocusMouseUp = false
            return
        }
        sendMousePosition(event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modifiers(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard window?.firstResponder === self else {
            window?.makeFirstResponder(self)
            return
        }
        sendMousePosition(event)
        if !ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modifiers(event)) {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMousePosition(event)
        if !ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, modifiers(event)) {
            super.rightMouseUp(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        sendMousePosition(event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, modifiers(event))
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMousePosition(event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, modifiers(event))
    }

    override func mouseMoved(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    private func sendMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modifiers(event))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaToken {
            removeTrackingArea(trackingAreaToken)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaToken = area
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            x *= 2
            y *= 2
        }
        let precision: Int32 = event.hasPreciseScrollingDeltas ? 1 : 0
        let momentum = Int32(momentumValue(event.momentumPhase)) << 1
        ghostty_surface_mouse_scroll(surface, x, y, precision | momentum)
    }

    override func keyDown(with event: NSEvent) {
        if shouldSendPhysicalKey(event),
           sendKey(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS) {
            return
        }
        interpretKeyEvents([event])
    }

    override func keyUp(with event: NSEvent) {
        if shouldSendPhysicalKey(event) {
            _ = sendKey(event, action: GHOSTTY_ACTION_RELEASE)
        }
    }

    private func shouldSendPhysicalKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return physicalKey(event) != nil || flags.contains(.control) || flags.contains(.command)
    }

    @discardableResult
    private func sendKey(_ event: NSEvent, action: ghostty_input_action_e) -> Bool {
        guard let surface else { return false }
        let text = event.characters ?? ""
        return text.withCString { pointer in
            var key = ghostty_input_key_s()
            key.action = action
            key.mods = modifiers(event)
            key.consumed_mods = GHOSTTY_MODS_NONE
            key.keycode = UInt32(event.keyCode)
            key.text = text.isEmpty ? nil : pointer
            key.unshifted_codepoint = event.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0
            key.composing = hasMarkedText()
            return ghostty_surface_key(surface, key)
        }
    }

    private func physicalKey(_ event: NSEvent) -> ghostty_input_key_e? {
        switch event.keyCode {
        case 36, 76: GHOSTTY_KEY_ENTER
        case 48: GHOSTTY_KEY_TAB
        case 49: GHOSTTY_KEY_SPACE
        case 51: GHOSTTY_KEY_BACKSPACE
        case 53: GHOSTTY_KEY_ESCAPE
        case 115: GHOSTTY_KEY_HOME
        case 116: GHOSTTY_KEY_PAGE_UP
        case 117: GHOSTTY_KEY_DELETE
        case 119: GHOSTTY_KEY_END
        case 121: GHOSTTY_KEY_PAGE_DOWN
        case 123: GHOSTTY_KEY_ARROW_LEFT
        case 124: GHOSTTY_KEY_ARROW_RIGHT
        case 125: GHOSTTY_KEY_ARROW_DOWN
        case 126: GHOSTTY_KEY_ARROW_UP
        default: letterPhysicalKey(event.charactersIgnoringModifiers)
        }
    }

    private func letterPhysicalKey(_ characters: String?) -> ghostty_input_key_e? {
        switch characters?.lowercased() {
        case "a": GHOSTTY_KEY_A
        case "b": GHOSTTY_KEY_B
        case "c": GHOSTTY_KEY_C
        case "d": GHOSTTY_KEY_D
        case "e": GHOSTTY_KEY_E
        case "f": GHOSTTY_KEY_F
        case "g": GHOSTTY_KEY_G
        case "h": GHOSTTY_KEY_H
        case "i": GHOSTTY_KEY_I
        case "j": GHOSTTY_KEY_J
        case "k": GHOSTTY_KEY_K
        case "l": GHOSTTY_KEY_L
        case "m": GHOSTTY_KEY_M
        case "n": GHOSTTY_KEY_N
        case "o": GHOSTTY_KEY_O
        case "p": GHOSTTY_KEY_P
        case "q": GHOSTTY_KEY_Q
        case "r": GHOSTTY_KEY_R
        case "s": GHOSTTY_KEY_S
        case "t": GHOSTTY_KEY_T
        case "u": GHOSTTY_KEY_U
        case "v": GHOSTTY_KEY_V
        case "w": GHOSTTY_KEY_W
        case "x": GHOSTTY_KEY_X
        case "y": GHOSTTY_KEY_Y
        case "z": GHOSTTY_KEY_Z
        default: nil
        }
    }

    private func modifiers(_ event: NSEvent) -> ghostty_input_mods_e {
        var value = UInt32(GHOSTTY_MODS_NONE.rawValue)
        let flags = event.modifierFlags
        if flags.contains(.shift) { value |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { value |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { value |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { value |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { value |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(value)
    }

    private func momentumValue(_ phase: NSEvent.Phase) -> Int {
        if phase.contains(.began) { return 1 }
        if phase.contains(.stationary) { return 2 }
        if phase.contains(.changed) { return 3 }
        if phase.contains(.ended) { return 4 }
        if phase.contains(.cancelled) { return 5 }
        if phase.contains(.mayBegin) { return 6 }
        return 0
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c" where ghostty_surface_has_selection(surface):
                return performBinding("copy_to_clipboard")
            case "v":
                return performBinding("paste_from_clipboard")
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func copy(_ sender: Any?) {
        _ = performBinding("copy_to_clipboard")
    }

    @objc func paste(_ sender: Any?) {
        _ = performBinding("paste_from_clipboard")
    }

    private func performBinding(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString {
            ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count))
        }
    }

    func terminateSession() {
        terminalSession.close()
    }

    private func processTerminalOutput(_ data: Data) {
        guard let surface else { return }
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            ghostty_surface_process_output(
                surface,
                baseAddress.assumingMemoryBound(to: CChar.self),
                UInt(bytes.count)
            )
        }
        ghostty_surface_refresh(surface)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let value = (string as? NSAttributedString)?.string ?? String(describing: string)
        markedTextStorage = NSMutableAttributedString()
        guard let surface else { return }
        value.withCString {
            ghostty_surface_preedit(surface, "", 0)
            ghostty_surface_text(surface, $0, UInt(value.utf8.count))
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attributed = string as? NSAttributedString {
            markedTextStorage = NSMutableAttributedString(attributedString: attributed)
        } else {
            markedTextStorage = NSMutableAttributedString(string: String(describing: string))
        }
        guard let surface else { return }
        markedTextStorage.string.withCString {
            ghostty_surface_preedit(surface, $0, UInt(markedTextStorage.string.utf8.count))
        }
    }

    func unmarkText() {
        markedTextStorage = NSMutableAttributedString()
        guard let surface else { return }
        ghostty_surface_preedit(surface, "", 0)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        markedTextStorage.length == 0
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: markedTextStorage.length)
    }

    func hasMarkedText() -> Bool { markedTextStorage.length > 0 }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x = 0.0
        var y = 0.0
        var width = 0.0
        var height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let local = NSRect(x: x, y: bounds.height - y - height, width: width, height: height)
        return window.convertToScreen(convert(local, to: nil))
    }

    override func doCommand(by selector: Selector) {
        let keyCode: UInt16?
        switch selector {
        case #selector(moveUp(_:)): keyCode = 126
        case #selector(moveDown(_:)): keyCode = 125
        case #selector(moveLeft(_:)): keyCode = 123
        case #selector(moveRight(_:)): keyCode = 124
        case #selector(deleteBackward(_:)): keyCode = 51
        case #selector(insertNewline(_:)): keyCode = 36
        case #selector(insertTab(_:)): keyCode = 48
        case #selector(cancelOperation(_:)): keyCode = 53
        default: keyCode = nil
        }
        guard let keyCode, let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) else {
            return
        }
        _ = sendKey(event, action: GHOSTTY_ACTION_PRESS)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return false
        }
        let paths = urls.map { Self.shellQuote($0.path) }.joined(separator: " ") + " "
        insertText(paths, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

}

enum UserShell {
    static var loginPath: String {
        if let record = getpwuid(getuid()), let shell = record.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}

private final class GhosttyIOBridge: @unchecked Sendable {
    weak var session: ZmxTerminalClient?
}

private func ghosttyManualIOWrite(
    _ userdata: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<CChar>?,
    _ length: UInt
) {
    guard let userdata, let bytes else { return }
    let bridge = Unmanaged<GhosttyIOBridge>.fromOpaque(userdata).takeUnretainedValue()
    bridge.session?.send(Data(bytes: bytes, count: Int(length)))
}
