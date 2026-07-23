import AppKit

@main
@MainActor
final class PinataApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var workspaceViewController: WorkspaceViewController?

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
        let workspaceViewController = WorkspaceViewController()
        window.contentViewController = workspaceViewController
        self.workspaceViewController = workspaceViewController
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }


    @objc private func toggleLeftPanel(_ sender: Any?) {
        workspaceViewController?.toggleLeftPanel(sender)
    }

    @objc private func toggleRightPanel(_ sender: Any?) {
        workspaceViewController?.toggleRightPanel(sender)
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
        NSApp.mainMenu = mainMenu
    }
}
