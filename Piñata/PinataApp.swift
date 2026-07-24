import AppKit

@main
@MainActor
final class PinataApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var workspaceViewController: WorkspaceViewController?
    private var ghosttyRuntime: GhosttyRuntime?

    static func main() {
        let application = NSApplication.shared
        let delegate = PinataApp()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        _ = delegate
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()

        let runtime: GhosttyRuntime
        do {
            runtime = try GhosttyRuntime()
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
            return
        }
        ghosttyRuntime = runtime

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Piñata"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = AppTheme.background
        window.minSize = NSSize(width: 900, height: 600)
        let workspaceViewController = WorkspaceViewController(runtime: runtime)
        window.contentViewController = workspaceViewController
        self.workspaceViewController = workspaceViewController
        window.center()
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

    @objc private func toggleRightPanel(_ sender: Any?) {
        workspaceViewController?.toggleRightPanel(sender)
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Piñata",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let leftPanelItem = viewMenu.addItem(
            withTitle: "Toggle Left Panel",
            action: #selector(toggleLeftPanel(_:)),
            keyEquivalent: "b"
        )
        leftPanelItem.target = self
        let rightPanelItem = viewMenu.addItem(
            withTitle: "Toggle Right Panel",
            action: #selector(toggleRightPanel(_:)),
            keyEquivalent: "l"
        )
        rightPanelItem.target = self
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let terminalItem = NSMenuItem()
        let terminalMenu = NSMenu(title: "Terminal")
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
        NSApp.mainMenu = mainMenu
    }
}
