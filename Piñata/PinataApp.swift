import AppKit

@main
@MainActor
final class PinataApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var workspaceViewController: WorkspaceViewController?
    private var ghosttyRuntime: GhosttyRuntime?
    private let settingsStore = UserSettingsStore()
    private var settings = UserSettings.defaults

    static func main() {
        if TerminalServiceEntryPoint.runIfRequested() { return }
        let application = NSApplication.shared
        let delegate = PinataApp()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = settingsStore.load()
        AppTheme.configure(settings)
        NSApp.appearance = NSAppearance(
            named: settings.theme == .dark ? .darkAqua : .aqua
        )
        installMenu()

        let runtime: GhosttyRuntime
        do {
            runtime = try GhosttyRuntime(settings: settings)
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
            return
        }
        ghosttyRuntime = runtime

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: AppTheme.minimumWindowWidth, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Piñata"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = AppTheme.background
        window.minSize = NSSize(width: AppTheme.minimumWindowWidth, height: 600)
        let workspaceViewController = WorkspaceViewController(runtime: runtime)
        window.contentViewController = workspaceViewController
        self.workspaceViewController = workspaceViewController
        let restoredWindow = window.setFrameUsingName("PiñataMainWindow")
        window.setFrameAutosaveName("PiñataMainWindow")
        if !restoredWindow {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ghosttyRuntime?.setApplicationFocused(true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        ghosttyRuntime?.setApplicationFocused(false)
    }

    @objc private func toggleLeftPanel(_ sender: Any?) {
        workspaceViewController?.toggleLeftPanel(sender)
    }

    @objc private func createTask(_ sender: Any?) {
        workspaceViewController?.presentNewTask(sender)
    }

    @objc private func createTerminalTab(_ sender: Any?) {
        workspaceViewController?.createTerminalTab(sender)
    }

    @objc private func splitTerminalVertically(_ sender: Any?) {
        workspaceViewController?.splitTerminalVertically(sender)
    }

    @objc private func splitTerminalHorizontally(_ sender: Any?) {
        workspaceViewController?.splitTerminalHorizontally(sender)
    }

    @objc private func closeTerminalPane(_ sender: Any?) {
        workspaceViewController?.closeTerminalPane(sender)
    }

    @objc private func toggleSettings(_ sender: Any?) {
        workspaceViewController?.toggleSettings(settings) { [weak self] next in
            self?.applySettings(next) ?? false
        }
    }

    private func applySettings(_ next: UserSettings) -> Bool {
        do {
            if next.theme != settings.theme
                || next.terminalFontSize != settings.terminalFontSize
            {
                try ghosttyRuntime?.apply(next)
            }
            try settingsStore.save(next)
        } catch {
            NSAlert(error: error).runModal()
            return false
        }

        settings = next
        AppTheme.configure(next)
        NSApp.appearance = NSAppearance(
            named: next.theme == .dark ? .darkAqua : .aqua
        )
        window?.backgroundColor = AppTheme.background
        workspaceViewController?.applyTheme()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspaceViewController?.persistSession()
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Piñata")
        appMenu.addItem(
            withTitle: "About Piñata",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        let settingsItem = appMenu.addItem(
            withTitle: "Settings…",
            action: #selector(toggleSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Piñata",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let newTaskItem = fileMenu.addItem(
            withTitle: "New Task",
            action: #selector(createTask(_:)),
            keyEquivalent: "n"
        )
        newTaskItem.target = self
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let leftPanelItem = viewMenu.addItem(
            withTitle: "Toggle Left Panel",
            action: #selector(toggleLeftPanel(_:)),
            keyEquivalent: "b"
        )
        leftPanelItem.target = self
        let fullScreenItem = viewMenu.addItem(
            withTitle: "Toggle Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let terminalItem = NSMenuItem()
        let terminalMenu = NSMenu(title: "Terminal")
        let newTabItem = terminalMenu.addItem(
            withTitle: "New Terminal Tab",
            action: #selector(createTerminalTab(_:)),
            keyEquivalent: "t"
        )
        newTabItem.target = self
        terminalMenu.addItem(.separator())
        let splitVerticalItem = terminalMenu.addItem(
            withTitle: "Split Vertically",
            action: #selector(splitTerminalVertically(_:)),
            keyEquivalent: "d"
        )
        splitVerticalItem.target = self
        let splitHorizontalItem = terminalMenu.addItem(
            withTitle: "Split Horizontally",
            action: #selector(splitTerminalHorizontally(_:)),
            keyEquivalent: "d"
        )
        splitHorizontalItem.keyEquivalentModifierMask = [.command, .shift]
        splitHorizontalItem.target = self
        terminalMenu.addItem(.separator())
        let closePaneItem = terminalMenu.addItem(
            withTitle: "Close Pane",
            action: #selector(closeTerminalPane(_:)),
            keyEquivalent: "w"
        )
        closePaneItem.target = self
        terminalItem.submenu = terminalMenu
        mainMenu.addItem(terminalItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = mainMenu
    }
}
