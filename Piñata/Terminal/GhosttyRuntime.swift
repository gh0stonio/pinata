import AppKit
import Foundation
import GhosttyKit

private final class GhosttyRuntimeState: @unchecked Sendable {
    var app: ghostty_app_t?
}

@MainActor
final class GhosttyRuntime {
    nonisolated(unsafe) let app: ghostty_app_t
    nonisolated(unsafe) private let config: ghostty_config_t
    private let callbackState: GhosttyRuntimeState
    nonisolated(unsafe) private let callbackOpaque: UnsafeMutableRawPointer

    init() throws {
        GhosttyResources.configureEnvironment()

        let initialization = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard initialization == GHOSTTY_SUCCESS else {
            throw GhosttyError.initialization(Int32(initialization))
        }
        guard let config = ghostty_config_new() else {
            throw GhosttyError.appCreation
        }
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        self.config = config

        let state = GhosttyRuntimeState()
        let opaque = Unmanaged.passRetained(state).toOpaque()
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = opaque
        runtimeConfig.supports_selection_clipboard = false
        runtimeConfig.wakeup_cb = ghosttyRuntimeWakeup
        runtimeConfig.action_cb = ghosttyRuntimeAction
        runtimeConfig.read_clipboard_cb = ghosttyRuntimeReadClipboard
        runtimeConfig.confirm_read_clipboard_cb = ghosttyRuntimeConfirmClipboard
        runtimeConfig.write_clipboard_cb = ghosttyRuntimeWriteClipboard
        runtimeConfig.close_surface_cb = ghosttyRuntimeCloseSurface

        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            Unmanaged<GhosttyRuntimeState>.fromOpaque(opaque).release()
            ghostty_config_free(config)
            throw GhosttyError.appCreation
        }
        self.app = app
        callbackState = state
        callbackOpaque = opaque
        state.app = app
    }

    deinit {
        callbackState.app = nil
        ghostty_app_free(app)
        ghostty_config_free(config)
        Unmanaged<GhosttyRuntimeState>.fromOpaque(callbackOpaque).release()
    }

    func tick() {
        ghostty_app_tick(app)
    }

    func setApplicationFocused(_ focused: Bool) {
        ghostty_app_set_focus(app, focused)
    }
}

private enum GhosttyResources {
    static func configureEnvironment() {
        guard let resources = Bundle.main.resourceURL else { return }
        setenv("GHOSTTY_RESOURCES_DIR", resources.appendingPathComponent("ghostty").path, 1)
        setenv("TERMINFO", resources.appendingPathComponent("terminfo").path, 1)
    }
}

private func ghosttyRuntimeWakeup(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    let state = Unmanaged<GhosttyRuntimeState>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
        guard let app = state.app else { return }
        ghostty_app_tick(app)
    }
}

private func ghosttyRuntimeAction(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    guard
        target.tag == GHOSTTY_TARGET_SURFACE,
        action.tag == GHOSTTY_ACTION_PWD,
        let surface = target.target.surface,
        let userdata = ghostty_surface_userdata(surface),
        let path = action.action.pwd.pwd
    else {
        return false
    }
    let directory = String(cString: path)
    let terminal = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
        terminal.workingDirectory = directory
    }
    return true
}

private func ghosttyRuntimeReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    guard
        let userdata,
        let surface = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue().surface
    else {
        return false
    }
    let read = { NSPasteboard.general.string(forType: .string) }
    let value = Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    guard let value else { return false }
    value.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
    return true
}

private func ghosttyRuntimeConfirmClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    guard
        let userdata,
        let string,
        let surface = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue().surface
    else {
        return
    }
    String(cString: string).withCString {
        ghostty_surface_complete_clipboard_request(
            surface,
            $0,
            state,
            request == GHOSTTY_CLIPBOARD_REQUEST_PASTE
        )
    }
}

private func ghosttyRuntimeWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ length: Int,
    _ confirm: Bool
) {
    guard content != nil, length > 0, !confirm else { return }
    var text: String?
    for index in 0..<length {
        let item = content![index]
        guard let mime = item.mime, let data = item.data else { continue }
        if String(cString: mime) == "text/plain" {
            text = String(cString: data)
            break
        }
    }
    guard let text else { return }
    DispatchQueue.main.async {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private func ghosttyRuntimeCloseSurface(
    _ userdata: UnsafeMutableRawPointer?,
    _ processAlive: Bool
) {
    guard let userdata else { return }
    let terminal = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    DispatchQueue.main.async {
        terminal.restartAfterProcessExit(processAlive)
    }
}

enum GhosttyError: LocalizedError {
    case initialization(Int32)
    case appCreation
    case surfaceCreation

    var errorDescription: String? {
        switch self {
        case .initialization(let result): "Ghostty initialization failed with status \(result)."
        case .appCreation: "Ghostty app creation failed."
        case .surfaceCreation: "Ghostty terminal surface creation failed."
        }
    }
}
