import AppKit

@MainActor
final class WorkspaceViewController: NSViewController {
    private enum SidebarPresentation: String {
        case hidden
        case transient
        case docked
    }

    private enum InspectorPresentation {
        case closed
        case column
        case overlay
    }

    private struct TerminalTab {
        let id: UUID
        let title: String
        let controller: TerminalViewController
    }

    private static let sidebarDefaultsKey = "pinata.sidebar.presentation.v1"
    private static let leftPanelWidthDefaultsKey = "pinata.panel.left.width.v1"
    private static let rightPanelWidthDefaultsKey = "pinata.panel.right.width.v1"
    private static let revealDelay: TimeInterval = 0.15
    private static let dismissDelay: TimeInterval = 0.30

    private let runtime: GhosttyRuntime
    private let workspaceCard = NSView()
    private let mainColumn = NSView()
    private let terminalHost = NSView()
    private let workspaceHeader = WorkspaceHeaderView()
    private let leftPanelController = PanelViewController(role: .left)
    private let rightPanelController = PanelViewController(role: .right)
    private let leftResizeHandle = PanelResizeHandle()
    private let rightResizeHandle = PanelResizeHandle()
    private let edgeRevealZone = EdgeRevealView()
    private var terminalTabs: [TerminalTab]
    private var activeTerminalTabID: UUID?
    private var nextTerminalTabNumber = 2
    private var settingsController: SettingsViewController?
    private var rightPanelOpenBeforeSettings: Bool?
    private var leftResizeWindowWidth: CGFloat?
    private var rightResizeWorkspaceWidth: CGFloat?

    private var leftWidthConstraint: NSLayoutConstraint!
    private var rightWidthConstraint: NSLayoutConstraint!
    private var leftPanelLeadingConstraint: NSLayoutConstraint!
    private var leftPanelTopConstraint: NSLayoutConstraint!
    private var leftPanelBottomConstraint: NSLayoutConstraint!
    private var workspaceLeadingFromRoot: NSLayoutConstraint!
    private var workspaceLeadingFromSidebar: NSLayoutConstraint!
    private var workspaceTopConstraint: NSLayoutConstraint!
    private var workspaceBottomConstraint: NSLayoutConstraint!
    private var workspaceTrailingConstraint: NSLayoutConstraint!
    private var mainTrailingToCard: NSLayoutConstraint!
    private var mainTrailingToInspector: NSLayoutConstraint!

    private var sidebarPresentation: SidebarPresentation
    private var inspectorPresentation: InspectorPresentation = .closed
    private var rightPanelOpen = false
    private var leftPanelWidth = AppTheme.leftPanelWidth
    private var rightPanelWidth = AppTheme.rightPanelWidth
    private var fullScreen = false
    private var menuTracking = false
    private var keyEventMonitor: Any?
    private weak var observedWindow: NSWindow?
    private var trafficLightBaselineY: CGFloat?

    init(runtime: GhosttyRuntime) {
        let initialTabID = UUID()
        self.runtime = runtime
        terminalTabs = [
            TerminalTab(
                id: initialTabID,
                title: "Terminal",
                controller: TerminalViewController(runtime: runtime)
            )
        ]
        activeTerminalTabID = initialTabID
        let stored = UserDefaults.standard.string(forKey: Self.sidebarDefaultsKey)
        sidebarPresentation = stored == SidebarPresentation.hidden.rawValue ? .hidden : .docked
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.leftPanelWidthDefaultsKey) != nil {
            leftPanelWidth = min(
                max(CGFloat(defaults.double(forKey: Self.leftPanelWidthDefaultsKey)), AppTheme.leftPanelRange.lowerBound),
                AppTheme.leftPanelRange.upperBound
            )
        }
        if defaults.object(forKey: Self.rightPanelWidthDefaultsKey) != nil {
            rightPanelWidth = min(
                max(CGFloat(defaults.double(forKey: Self.rightPanelWidthDefaultsKey)), AppTheme.rightPanelRange.lowerBound),
                AppTheme.rightPanelRange.upperBound
            )
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let rootView = NSView()
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        view = rootView

        configureWorkspaceCard()
        configureControllers(in: rootView)
        configureConstraints(in: rootView)
        configureInteractions()
        applySidebarPresentation()
        updateInspectorPresentation(force: true)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        observeWindowIfNeeded()
        installKeyEventMonitorIfNeeded()
        fullScreen = view.window?.styleMask.contains(.fullScreen) == true
        applySidebarPresentation()
        activeTerminalController?.focusActiveTerminal()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        cancelScheduledTransitions()
        NotificationCenter.default.removeObserver(self)
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }
        observedWindow = nil
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateInspectorPresentation()
        updateTrafficLights()
    }

    @objc func toggleLeftPanel(_ sender: Any?) {
        cancelScheduledTransitions()
        sidebarPresentation = sidebarPresentation == .docked ? .hidden : .docked
        persistSidebarPresentation()
        applySidebarPresentation()
    }

    @objc func toggleRightPanel(_ sender: Any?) {
        guard settingsController == nil else { return }
        rightPanelOpen.toggle()
        updateInspectorPresentation(force: true)
    }

    @objc func splitTerminalVertically(_ sender: Any?) {
        guard settingsController == nil else { return }
        activeTerminalController?.splitActiveVertically()
    }

    @objc func splitTerminalHorizontally(_ sender: Any?) {
        guard settingsController == nil else { return }
        activeTerminalController?.splitActiveHorizontally()
    }

    @objc func closeTerminalPane(_ sender: Any?) {
        guard settingsController == nil else { return }
        activeTerminalController?.closeActivePane()
    }

    @objc func createTerminalTab(_ sender: Any?) {
        guard settingsController == nil else { return }
        let id = UUID()
        let tab = TerminalTab(
            id: id,
            title: "Terminal \(nextTerminalTabNumber)",
            controller: TerminalViewController(runtime: runtime)
        )
        nextTerminalTabNumber += 1
        terminalTabs.append(tab)
        activeTerminalTabID = id
        if isViewLoaded {
            installActiveTerminal()
        }
    }

    func toggleSettings(
        _ settings: UserSettings,
        onChange: @escaping (UserSettings) -> Bool
    ) {
        if settingsController != nil {
            dismissSettings()
            return
        }

        rightPanelOpenBeforeSettings = rightPanelOpen
        rightPanelOpen = false
        updateInspectorPresentation(force: true)

        let controller = SettingsViewController(settings: settings)
        controller.onChange = onChange
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        mainColumn.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: mainColumn.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: mainColumn.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: mainColumn.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: mainColumn.bottomAnchor),
        ])
        settingsController = controller
        workspaceHeader.setTabs(
            terminalTabs.map { (id: $0.id, title: $0.title) },
            activeID: nil
        )
        applySidebarPresentation()
        DispatchQueue.main.async {
            controller.focusInitialSection()
        }
    }

    func applyTheme() {
        view.layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        workspaceCard.layer?.backgroundColor = AppTheme.background.cgColor
        workspaceCard.layer?.borderColor = AppTheme.border.cgColor
        mainColumn.layer?.backgroundColor = AppTheme.background.cgColor
        workspaceHeader.applyTheme()
        leftPanelController.applyTheme()
        terminalTabs.forEach { $0.controller.applyTheme() }
        rightPanelController.applyTheme()
        leftResizeHandle.applyTheme()
        rightResizeHandle.applyTheme()
        settingsController?.applyTheme()
        applySidebarPresentation()
    }

    private func configureWorkspaceCard() {
        workspaceCard.translatesAutoresizingMaskIntoConstraints = false
        workspaceCard.wantsLayer = true
        workspaceCard.layer?.backgroundColor = AppTheme.background.cgColor
        workspaceCard.layer?.borderColor = AppTheme.border.cgColor
        workspaceCard.layer?.cornerCurve = .continuous
        workspaceCard.layer?.masksToBounds = true

        mainColumn.translatesAutoresizingMaskIntoConstraints = false
        mainColumn.wantsLayer = true
        mainColumn.layer?.backgroundColor = AppTheme.background.cgColor
    }

    private func configureControllers(in rootView: NSView) {
        addChild(leftPanelController)
        addChild(rightPanelController)

        let leftPanel = leftPanelController.view
        let rightPanel = rightPanelController.view
        leftPanel.translatesAutoresizingMaskIntoConstraints = false
        rightPanel.translatesAutoresizingMaskIntoConstraints = false
        rightPanel.layer?.cornerRadius = AppTheme.workspaceCornerRadius
        rightPanel.layer?.maskedCorners = [
            .layerMinXMinYCorner,
            .layerMinXMaxYCorner,
        ]
        rightPanel.layer?.cornerCurve = .continuous
        rightPanel.layer?.masksToBounds = true
        terminalHost.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.wantsLayer = true
        terminalHost.layer?.backgroundColor = AppTheme.background.cgColor

        rootView.addSubview(workspaceCard)
        workspaceCard.addSubview(mainColumn)
        mainColumn.addSubview(workspaceHeader)
        mainColumn.addSubview(terminalHost)
        workspaceCard.addSubview(rightPanel)
        workspaceCard.addSubview(rightResizeHandle)
        rootView.addSubview(leftPanel)
        rootView.addSubview(leftResizeHandle)
        rootView.addSubview(edgeRevealZone)
        installActiveTerminal()
    }

    private func configureConstraints(in rootView: NSView) {
        let leftPanel = leftPanelController.view
        let rightPanel = rightPanelController.view

        leftWidthConstraint = leftPanel.widthAnchor.constraint(equalToConstant: leftPanelWidth)
        rightWidthConstraint = rightPanel.widthAnchor.constraint(equalToConstant: rightPanelWidth)
        leftPanelLeadingConstraint = leftPanel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor)
        leftPanelTopConstraint = leftPanel.topAnchor.constraint(equalTo: rootView.topAnchor)
        leftPanelBottomConstraint = leftPanel.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        workspaceLeadingFromRoot = workspaceCard.leadingAnchor.constraint(
            equalTo: rootView.leadingAnchor,
            constant: AppTheme.workspaceInset
        )
        workspaceLeadingFromSidebar = workspaceCard.leadingAnchor.constraint(
            equalTo: leftPanel.trailingAnchor,
            constant: AppTheme.workspaceInset
        )
        workspaceTopConstraint = workspaceCard.topAnchor.constraint(
            equalTo: rootView.topAnchor,
            constant: AppTheme.workspaceInset
        )
        workspaceBottomConstraint = workspaceCard.bottomAnchor.constraint(
            equalTo: rootView.bottomAnchor,
            constant: -AppTheme.workspaceInset
        )
        workspaceTrailingConstraint = workspaceCard.trailingAnchor.constraint(
            equalTo: rootView.trailingAnchor,
            constant: -AppTheme.workspaceInset
        )
        mainTrailingToCard = mainColumn.trailingAnchor.constraint(equalTo: workspaceCard.trailingAnchor)
        mainTrailingToInspector = mainColumn.trailingAnchor.constraint(equalTo: rightPanel.leadingAnchor)

        NSLayoutConstraint.activate([
            leftPanelLeadingConstraint,
            leftPanelTopConstraint,
            leftPanelBottomConstraint,
            leftWidthConstraint,

            workspaceTopConstraint,
            workspaceBottomConstraint,
            workspaceTrailingConstraint,

            mainColumn.leadingAnchor.constraint(equalTo: workspaceCard.leadingAnchor),
            mainColumn.topAnchor.constraint(equalTo: workspaceCard.topAnchor),
            mainColumn.bottomAnchor.constraint(equalTo: workspaceCard.bottomAnchor),
            mainColumn.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),

            workspaceHeader.leadingAnchor.constraint(equalTo: mainColumn.leadingAnchor),
            workspaceHeader.trailingAnchor.constraint(equalTo: mainColumn.trailingAnchor),
            workspaceHeader.topAnchor.constraint(equalTo: mainColumn.topAnchor),
            workspaceHeader.heightAnchor.constraint(equalToConstant: AppTheme.mainHeaderHeight),

            terminalHost.leadingAnchor.constraint(equalTo: mainColumn.leadingAnchor),
            terminalHost.trailingAnchor.constraint(equalTo: mainColumn.trailingAnchor),
            terminalHost.topAnchor.constraint(equalTo: workspaceHeader.bottomAnchor),
            terminalHost.bottomAnchor.constraint(equalTo: mainColumn.bottomAnchor),

            rightPanel.trailingAnchor.constraint(equalTo: workspaceCard.trailingAnchor),
            rightPanel.topAnchor.constraint(equalTo: workspaceCard.topAnchor),
            rightPanel.bottomAnchor.constraint(equalTo: workspaceCard.bottomAnchor),
            rightWidthConstraint,

            leftResizeHandle.centerXAnchor.constraint(equalTo: leftPanel.trailingAnchor),
            leftResizeHandle.topAnchor.constraint(equalTo: rootView.topAnchor),
            leftResizeHandle.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            leftResizeHandle.widthAnchor.constraint(equalToConstant: 10),

            rightResizeHandle.centerXAnchor.constraint(equalTo: rightPanel.leadingAnchor),
            rightResizeHandle.topAnchor.constraint(equalTo: workspaceCard.topAnchor),
            rightResizeHandle.bottomAnchor.constraint(equalTo: workspaceCard.bottomAnchor),
            rightResizeHandle.widthAnchor.constraint(equalToConstant: 10),

            edgeRevealZone.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            edgeRevealZone.topAnchor.constraint(equalTo: rootView.topAnchor),
            edgeRevealZone.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            edgeRevealZone.widthAnchor.constraint(equalToConstant: AppTheme.edgeRevealWidth),
        ])
    }

    private func configureInteractions() {
        workspaceHeader.onCreateTab = { [weak self] in
            self?.createTerminalTab(nil)
        }
        workspaceHeader.onSelectTab = { [weak self] id in
            self?.selectTerminalTab(id)
        }
        workspaceHeader.onCloseTab = { [weak self] id in
            self?.closeTerminalTab(id)
        }
        workspaceHeader.onToggleRightPanel = { [weak self] in
            self?.toggleRightPanel(nil)
        }
        leftPanelController.onTogglePanel = { [weak self] in
            self?.toggleLeftPanel(nil)
        }
        rightPanelController.onTogglePanel = { [weak self] in
            self?.toggleRightPanel(nil)
        }
        leftPanelController.onHoverChanged = { [weak self] hovering in
            guard let self else { return }
            if hovering {
                self.cancelTransientDismissal()
            } else {
                self.scheduleTransientDismissal()
            }
        }
        edgeRevealZone.onHoverChanged = { [weak self] hovering in
            guard let self else { return }
            if hovering {
                self.scheduleTransientReveal()
            } else {
                self.cancelScheduledReveal()
            }
        }
        leftResizeHandle.onDrag = { [weak self] delta in
            self?.resizeLeftPanel(by: delta)
        }
        leftResizeHandle.onDragBegan = { [weak self] in
            self?.leftResizeWindowWidth = self?.view.bounds.width
        }
        leftResizeHandle.onDragEnded = { [weak self] in
            self?.leftResizeWindowWidth = nil
        }
        rightResizeHandle.onDrag = { [weak self] delta in
            self?.resizeRightPanel(by: delta)
        }
        rightResizeHandle.onDragBegan = { [weak self] in
            self?.rightResizeWorkspaceWidth = self?.workspaceCard.bounds.width
        }
        rightResizeHandle.onDragEnded = { [weak self] in
            self?.rightResizeWorkspaceWidth = nil
        }
        leftResizeHandle.onKeyboardResize = { [weak self] command in
            self?.resizeLeftPanel(with: command)
        }
        rightResizeHandle.onKeyboardResize = { [weak self] command in
            self?.resizeRightPanel(with: command)
        }
    }

    private var activeTerminalController: TerminalViewController? {
        guard let activeTerminalTabID else { return nil }
        return terminalTabs.first(where: { $0.id == activeTerminalTabID })?.controller
    }

    private func selectTerminalTab(_ id: UUID) {
        guard id != activeTerminalTabID, terminalTabs.contains(where: { $0.id == id }) else {
            return
        }
        activeTerminalTabID = id
        installActiveTerminal()
    }

    private func installActiveTerminal() {
        terminalHost.subviews.forEach { $0.removeFromSuperview() }
        workspaceHeader.setTabs(
            terminalTabs.map { (id: $0.id, title: $0.title) },
            activeID: activeTerminalTabID
        )
        guard
            let activeTerminalTabID,
            let controller = activeTerminalController
        else {
            return
        }
        controller.onCloseLastPane = { [weak self] in
            self?.closeTerminalTab(activeTerminalTabID)
        }
        if controller.parent !== self {
            addChild(controller)
        }
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: terminalHost.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor),
        ])
        DispatchQueue.main.async {
            controller.focusActiveTerminal()
        }
    }

    private func closeTerminalTab(_ id: UUID) {
        guard let index = terminalTabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = terminalTabs.remove(at: index)
        tab.controller.view.removeFromSuperview()
        tab.controller.removeFromParent()
        if activeTerminalTabID == id {
            activeTerminalTabID = terminalTabs.isEmpty
                ? nil
                : terminalTabs[min(index, terminalTabs.count - 1)].id
        }
        installActiveTerminal()
    }

    private func applySidebarPresentation() {
        guard isViewLoaded else { return }
        let leftPanel = leftPanelController.view
        let docked = sidebarPresentation == .docked
        let immersive = fullScreen && !docked
        let inset = immersive ? 0 : AppTheme.workspaceInset
        let panelInset = sidebarPresentation == .transient ? AppTheme.workspaceInset : 0
        let panelWidth = fullScreen && sidebarPresentation == .transient
            ? max(leftPanelWidth, AppTheme.fullScreenSidebarWidth)
            : leftPanelWidth

        workspaceLeadingFromRoot.isActive = !docked
        workspaceLeadingFromSidebar.isActive = docked
        workspaceTopConstraint.constant = inset
        workspaceBottomConstraint.constant = -inset
        workspaceTrailingConstraint.constant = -inset
        workspaceLeadingFromRoot.constant = inset
        leftPanelLeadingConstraint.constant = panelInset
        leftPanelTopConstraint.constant = panelInset
        leftPanelBottomConstraint.constant = -panelInset
        leftWidthConstraint.constant = panelWidth

        workspaceCard.layer?.cornerRadius = immersive ? 0 : AppTheme.workspaceCornerRadius
        workspaceCard.layer?.borderWidth = immersive ? 0 : 1
        workspaceCard.layer?.masksToBounds = true

        leftPanel.isHidden = sidebarPresentation == .hidden
        if sidebarPresentation != .transient {
            leftPanel.alphaValue = sidebarPresentation == .hidden ? 0 : 1
        }
        leftPanel.layer?.cornerRadius = sidebarPresentation == .transient
            ? AppTheme.workspaceCornerRadius
            : 0
        leftPanel.layer?.maskedCorners = [
            .layerMinXMinYCorner,
            .layerMaxXMinYCorner,
            .layerMinXMaxYCorner,
            .layerMaxXMaxYCorner,
        ]
        leftPanel.layer?.borderWidth = sidebarPresentation == .transient ? 1 : 0
        leftPanel.layer?.borderColor = AppTheme.border.cgColor
        leftPanel.layer?.cornerCurve = .continuous
        leftPanel.layer?.masksToBounds = sidebarPresentation == .transient

        leftResizeHandle.setEnabled(docked)
        edgeRevealZone.setEnabled(sidebarPresentation == .hidden)
        leftPanelController.setToggleActive(docked)
        leftPanelController.setFullScreen(fullScreen)
        updateTrafficLights()
        view.layoutSubtreeIfNeeded()
        updateInspectorPresentation(force: true)
    }

    private func updateInspectorPresentation(force: Bool = false) {
        guard isViewLoaded else { return }
        let next: InspectorPresentation
        if !rightPanelOpen {
            next = .closed
        } else if workspaceCard.bounds.width - rightPanelWidth >= AppTheme.minimumCenterWidth {
            next = .column
        } else {
            next = .overlay
        }
        guard force || next != inspectorPresentation else { return }
        inspectorPresentation = next

        let rightPanel = rightPanelController.view
        let open = next != .closed
        rightPanel.isHidden = !open
        rightResizeHandle.setEnabled(open && settingsController == nil)
        mainTrailingToInspector.isActive = next == .column
        mainTrailingToCard.isActive = next != .column
        workspaceHeader.setInspectorOpen(open)
        rightPanelController.setToggleActive(open)
        workspaceCard.layoutSubtreeIfNeeded()
    }

    private func scheduleTransientReveal() {
        guard sidebarPresentation == .hidden else { return }
        cancelScheduledReveal()
        perform(
            #selector(revealTransientSidebar),
            with: nil,
            afterDelay: Self.revealDelay
        )
    }

    @objc private func revealTransientSidebar() {
        guard sidebarPresentation == .hidden else { return }
        cancelScheduledTransitions()
        sidebarPresentation = .transient
        leftPanelController.view.alphaValue = shouldReduceMotion ? 1 : 0
        applySidebarPresentation()
        guard !shouldReduceMotion else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            leftPanelController.view.animator().alphaValue = 1
        }
    }

    private func scheduleTransientDismissal() {
        guard sidebarPresentation == .transient else { return }
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(attemptTransientDismissal),
            object: nil
        )
        perform(
            #selector(attemptTransientDismissal),
            with: nil,
            afterDelay: Self.dismissDelay
        )
    }

    @objc private func attemptTransientDismissal() {
        guard sidebarPresentation == .transient else { return }
        if shouldKeepTransientSidebarOpen {
            scheduleTransientDismissal()
        } else {
            dismissTransientSidebar(animated: true)
        }
    }

    private func dismissTransientSidebar(animated: Bool) {
        guard sidebarPresentation == .transient else { return }
        cancelScheduledTransitions()
        guard animated && !shouldReduceMotion else {
            completeTransientDismissal()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            leftPanelController.view.animator().alphaValue = 0
        }
        perform(
            #selector(completeTransientDismissal),
            with: nil,
            afterDelay: 0.10
        )
    }

    @objc private func completeTransientDismissal() {
        guard sidebarPresentation == .transient else { return }
        sidebarPresentation = .hidden
        applySidebarPresentation()
    }

    private func cancelTransientDismissal() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(attemptTransientDismissal),
            object: nil
        )
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(completeTransientDismissal),
            object: nil
        )
        guard sidebarPresentation == .transient else { return }
        leftPanelController.view.animator().alphaValue = 1
    }

    private var shouldKeepTransientSidebarOpen: Bool {
        if menuTracking || NSEvent.pressedMouseButtons != 0 {
            return true
        }
        guard
            let responder = view.window?.firstResponder as? NSView,
            responder !== view.window?.contentView
        else {
            return false
        }
        return responder == leftPanelController.view
            || responder.isDescendant(of: leftPanelController.view)
    }

    private var shouldReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func cancelScheduledReveal() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(revealTransientSidebar),
            object: nil
        )
    }

    private func cancelScheduledTransitions() {
        cancelScheduledReveal()
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(attemptTransientDismissal),
            object: nil
        )
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(completeTransientDismissal),
            object: nil
        )
    }

    private func persistSidebarPresentation() {
        guard sidebarPresentation != .transient else { return }
        UserDefaults.standard.set(sidebarPresentation.rawValue, forKey: Self.sidebarDefaultsKey)
    }

    private func observeWindowIfNeeded() {
        guard let window = view.window, observedWindow !== window else { return }
        NotificationCenter.default.removeObserver(self)
        observedWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillEnterFullScreen),
            name: NSWindow.willEnterFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidExitFullScreen),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidBeginTracking),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidEndTracking),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
    }

    private func installKeyEventMonitorIfNeeded() {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.settingsController != nil, event.keyCode == 53 {
                self.dismissSettings()
                return nil
            }
            guard self.sidebarPresentation == .transient, event.keyCode == 53 else {
                return event
            }
            self.dismissTransientSidebar(animated: true)
            return nil
        }
    }

    private func updateTrafficLights() {
        guard let window = view.window else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = types.compactMap(window.standardWindowButton)
        let visible = fullScreen || sidebarPresentation != .hidden
        buttons.forEach { $0.isHidden = !visible }

        guard
            !fullScreen,
            let anchor = window.standardWindowButton(.zoomButton)
        else {
            return
        }
        let baselineY = trafficLightBaselineY ?? anchor.frame.origin.y
        trafficLightBaselineY = baselineY
        for button in buttons {
            var frame = button.frame
            frame.origin.y = baselineY - 3
            button.frame = frame
        }
    }

    @objc private func windowWillEnterFullScreen(_ notification: Notification) {
        fullScreen = true
        applySidebarPresentation()
    }

    @objc private func windowDidExitFullScreen(_ notification: Notification) {
        fullScreen = false
        trafficLightBaselineY = nil
        applySidebarPresentation()
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        dismissTransientSidebar(animated: false)
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {
        menuTracking = true
        cancelTransientDismissal()
    }

    @objc private func menuDidEndTracking(_ notification: Notification) {
        menuTracking = false
        if sidebarPresentation == .transient {
            scheduleTransientDismissal()
        }
    }

    private func dismissSettings() {
        settingsController?.view.removeFromSuperview()
        settingsController?.removeFromParent()
        settingsController = nil
        rightPanelOpen = rightPanelOpenBeforeSettings ?? rightPanelOpen
        rightPanelOpenBeforeSettings = nil
        workspaceHeader.setTabs(
            terminalTabs.map { (id: $0.id, title: $0.title) },
            activeID: activeTerminalTabID
        )
        applySidebarPresentation()
        activeTerminalController?.focusActiveTerminal()
    }

    private func resizeLeftPanel(by delta: CGFloat) {
        guard sidebarPresentation == .docked else { return }
        let inspectorWidth = inspectorPresentation == .column ? rightPanelWidth : 0
        let minimumCenterWidth = settingsController == nil
            ? AppTheme.minimumCenterWidth
            : AppTheme.settingsRailWidth + SettingsLayout.contentMinimumWidth
        let maximumFromWindow = (leftResizeWindowWidth ?? view.bounds.width)
            - inspectorWidth
            - minimumCenterWidth
            - AppTheme.workspaceInset * 2
        let maximum = max(
            AppTheme.leftPanelRange.lowerBound,
            min(AppTheme.leftPanelRange.upperBound, maximumFromWindow)
        )
        leftPanelWidth = min(
            max(leftWidthConstraint.constant + delta, AppTheme.leftPanelRange.lowerBound),
            maximum
        )
        leftWidthConstraint.constant = leftPanelWidth
        UserDefaults.standard.set(Double(leftPanelWidth), forKey: Self.leftPanelWidthDefaultsKey)
        view.layoutSubtreeIfNeeded()
        updateInspectorPresentation(force: true)
    }

    private func resizeRightPanel(by delta: CGFloat) {
        guard rightPanelOpen else { return }
        let maximum = max(
            AppTheme.rightPanelRange.lowerBound,
            min(
                AppTheme.rightPanelRange.upperBound,
                (rightResizeWorkspaceWidth ?? workspaceCard.bounds.width) - AppTheme.minimumCenterWidth
            )
        )
        rightPanelWidth = min(
            max(rightWidthConstraint.constant - delta, AppTheme.rightPanelRange.lowerBound),
            maximum
        )
        rightWidthConstraint.constant = rightPanelWidth
        UserDefaults.standard.set(Double(rightPanelWidth), forKey: Self.rightPanelWidthDefaultsKey)
        workspaceCard.layoutSubtreeIfNeeded()
        updateInspectorPresentation(force: true)
    }

    private func resizeLeftPanel(with command: PanelResizeHandle.KeyboardCommand) {
        switch command {
        case .decrease:
            resizeLeftPanel(by: -12)
        case .increase:
            resizeLeftPanel(by: 12)
        case .minimum:
            resizeLeftPanel(by: -AppTheme.leftPanelRange.upperBound)
        case .maximum:
            resizeLeftPanel(by: AppTheme.leftPanelRange.upperBound)
        }
    }

    private func resizeRightPanel(with command: PanelResizeHandle.KeyboardCommand) {
        switch command {
        case .decrease:
            resizeRightPanel(by: 12)
        case .increase:
            resizeRightPanel(by: -12)
        case .minimum:
            resizeRightPanel(by: AppTheme.rightPanelRange.upperBound)
        case .maximum:
            resizeRightPanel(by: -AppTheme.rightPanelRange.upperBound)
        }
    }
}

@MainActor
private final class EdgeRevealView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var enabled = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        guard enabled else {
            trackingArea = nil
            return
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        guard enabled else { return }
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard enabled else { return }
        onHoverChanged?(false)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        isHidden = !enabled
        updateTrackingAreas()
    }
}

@MainActor
private final class PanelResizeHandle: NSView {
    enum KeyboardCommand {
        case decrease
        case increase
        case minimum
        case maximum
    }

    var onDrag: ((CGFloat) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onKeyboardResize: ((KeyboardCommand) -> Void)?

    private let line = NSView()
    private var enabled = true
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    override var acceptsFirstResponder: Bool { enabled }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize panel")

        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.cornerRadius = 1
        addSubview(line)
        NSLayoutConstraint.activate([
            line.centerXAnchor.constraint(equalTo: centerXAnchor),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.15),
            line.widthAnchor.constraint(equalToConstant: 2),
        ])
        updateLineVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        guard enabled else {
            trackingArea = nil
            return
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateLineVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateLineVisibility()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard enabled else { return }
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.deltaX)
    }

    override func mouseDown(with event: NSEvent) {
        onDragBegan?()
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onDragEnded?()
    }

    override func keyDown(with event: NSEvent) {
        let command: KeyboardCommand?
        switch event.keyCode {
        case 123: command = .decrease
        case 124: command = .increase
        case 115: command = .minimum
        case 119: command = .maximum
        default: command = nil
        }
        if let command {
            onKeyboardResize?(command)
        } else {
            super.keyDown(with: event)
        }
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        isHidden = !enabled
        updateTrackingAreas()
        updateLineVisibility()
        window?.invalidateCursorRects(for: self)
    }

    func applyTheme() {
        updateLineVisibility()
    }

    private func updateLineVisibility() {
        line.layer?.backgroundColor = AppTheme.separator.cgColor
        line.alphaValue = enabled && isHovering ? 1 : 0
    }
}
