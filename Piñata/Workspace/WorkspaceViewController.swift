import AppKit

@MainActor
final class WorkspaceViewController: NSViewController {
    private enum SidebarPresentation: String {
        case hidden
        case transient
        case docked
    }

    private struct TerminalTab {
        let id: UUID
        let title: String
        let controller: TerminalViewController
    }

    @MainActor
    private final class TerminalWorkspace {
        let title: String
        let workingDirectory: String
        var tabs: [TerminalTab]
        var activeTabID: UUID?
        var nextTabNumber = 2

        init(runtime: GhosttyRuntime, title: String, workingDirectory: String) {
            self.title = title
            self.workingDirectory = workingDirectory
            let tabID = UUID()
            tabs = [
                TerminalTab(
                    id: tabID,
                    title: title,
                    controller: TerminalViewController(
                        runtime: runtime,
                        workingDirectory: workingDirectory
                    )
                )
            ]
            activeTabID = tabID
        }
    }

    private static let sidebarDefaultsKey = "pinata.sidebar.presentation.v1"
    private static let leftPanelWidthDefaultsKey = "pinata.panel.left.width.v1"
    private static let revealDelay: TimeInterval = 0.15
    private static let dismissDelay: TimeInterval = 0.30
    private static let revealAnimationDuration: TimeInterval = 0.12
    private static let dismissAnimationDuration: TimeInterval = 0.10

    private let runtime: GhosttyRuntime
    private let workspaceCard = NSView()
    private let mainColumn = NSView()
    private let terminalHost = NSView()
    private let workspaceHeader = WorkspaceHeaderView()
    private let leftPanelController = PanelViewController()
    private let leftResizeHandle = PanelResizeHandle()
    private let edgeRevealZone = EdgeRevealView()
    private let taskStore: TaskRegistryStore
    private let repositoryStore = RepositoryRegistryStore()
    private let globalWorkspace: TerminalWorkspace
    private var taskWorkspaces: [UUID: TerminalWorkspace] = [:]
    private var repositoryWorkspaces: [TaskRepositoryScope: TerminalWorkspace] = [:]
    private var tasks: [WorkspaceTask]
    private var activeScope: WorkspaceScope?
    private var expandedTaskIDs = Set<UUID>()
    private var taskErrors: [UUID: String] = [:]
    private var repositoryErrors: [TaskRepositoryScope: String] = [:]
    private var taskLoadError: String?
    private var taskRegistryLoaded: Bool
    private var settingsController: SettingsViewController?
    private var newTaskModal: NewTaskModalView?
    private var leftResizeWindowWidth: CGFloat?

    private var leftWidthConstraint: NSLayoutConstraint!
    private var leftPanelLeadingConstraint: NSLayoutConstraint!
    private var leftPanelTopConstraint: NSLayoutConstraint!
    private var leftPanelBottomConstraint: NSLayoutConstraint!
    private var workspaceLeadingFromRoot: NSLayoutConstraint!
    private var workspaceLeadingFromSidebar: NSLayoutConstraint!
    private var workspaceTopConstraint: NSLayoutConstraint!
    private var workspaceBottomConstraint: NSLayoutConstraint!
    private var workspaceTrailingConstraint: NSLayoutConstraint!

    private var sidebarPresentation: SidebarPresentation
    private var leftPanelWidth = AppTheme.leftPanelWidth
    private var fullScreen = false
    private var menuTracking = false
    private var keyEventMonitor: Any?
    private weak var observedWindow: NSWindow?
    private var trafficLightBaselineY: CGFloat?

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
        taskStore = TaskRegistryStore()
        globalWorkspace = TerminalWorkspace(
            runtime: runtime,
            title: "Terminal",
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
        do {
            tasks = try taskStore.load().sorted { $0.createdAt > $1.createdAt }
            taskRegistryLoaded = true
        } catch {
            tasks = []
            taskRegistryLoaded = false
            taskLoadError = "Could not load tasks: \(error.localizedDescription)"
        }
        let stored = UserDefaults.standard.string(forKey: Self.sidebarDefaultsKey)
        sidebarPresentation = stored == SidebarPresentation.hidden.rawValue ? .hidden : .docked
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.leftPanelWidthDefaultsKey) != nil {
            leftPanelWidth = min(
                max(CGFloat(defaults.double(forKey: Self.leftPanelWidthDefaultsKey)), AppTheme.leftPanelRange.lowerBound),
                AppTheme.leftPanelRange.upperBound
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
        updateTrafficLights()
    }

    @objc func toggleLeftPanel(_ sender: Any?) {
        cancelScheduledTransitions()
        sidebarPresentation = sidebarPresentation == .docked ? .hidden : .docked
        persistSidebarPresentation()
        applySidebarPresentation()
    }

    @objc func splitTerminalVertically(_ sender: Any?) {
        guard settingsController == nil, newTaskModal == nil else { return }
        activeTerminalController?.splitActiveVertically()
    }

    @objc func splitTerminalHorizontally(_ sender: Any?) {
        guard settingsController == nil, newTaskModal == nil else { return }
        activeTerminalController?.splitActiveHorizontally()
    }

    @objc func closeTerminalPane(_ sender: Any?) {
        guard settingsController == nil, newTaskModal == nil else { return }
        activeTerminalController?.closeActivePane()
    }

    @objc func createTerminalTab(_ sender: Any?) {
        guard settingsController == nil, newTaskModal == nil else { return }
        if case .task(let taskID) = activeScope, taskWorkspaces[taskID] == nil {
            guard taskErrors[taskID] == nil else { return }
            taskWorkspaces[taskID] = TerminalWorkspace(
                runtime: runtime,
                title: "Terminal",
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
            )
            installActiveWorkspace()
            return
        }
        guard let workspace = activeTerminalWorkspace else { return }
        let id = UUID()
        let tab = TerminalTab(
            id: id,
            title: "\(workspace.title) \(workspace.nextTabNumber)",
            controller: TerminalViewController(
                runtime: runtime,
                workingDirectory: workspace.workingDirectory
            )
        )
        workspace.nextTabNumber += 1
        workspace.tabs.append(tab)
        workspace.activeTabID = id
        if isViewLoaded {
            installActiveWorkspace()
        }
    }

    @objc func presentNewTask(_ sender: Any?) {
        guard newTaskModal == nil else { return }
        if settingsController != nil {
            dismissSettings()
        }

        let repositories: [RegisteredRepository]
        let repositoryError: String?
        do {
            repositories = try repositoryStore.load()
            repositoryError = nil
        } catch {
            repositories = []
            repositoryError = "Could not load repositories: \(error.localizedDescription)"
        }

        let modal = NewTaskModalView(
            repositories: repositories,
            repositoryError: repositoryError
        )
        modal.onCancel = { [weak self] in self?.dismissNewTaskModal() }
        modal.onCreate = { [weak self] title, repositories in
            self?.createTask(title: title, repositories: repositories)
        }
        view.addSubview(modal)
        NSLayoutConstraint.activate([
            modal.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            modal.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            modal.topAnchor.constraint(equalTo: view.topAnchor),
            modal.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        newTaskModal = modal
        DispatchQueue.main.async { modal.focusTitle() }
    }

    func toggleSettings(
        _ settings: UserSettings,
        onChange: @escaping (UserSettings) -> Bool
    ) {
        guard newTaskModal == nil else { return }
        if settingsController != nil {
            dismissSettings()
            return
        }

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
        if let workspace = activeTerminalWorkspace {
            workspaceHeader.setTabs(
                workspace.tabs.map { (id: $0.id, title: $0.title) },
                activeID: nil
            )
        } else {
            workspaceHeader.setEmptyScope("no tabs in this scope", allowsCreateTab: false)
        }
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
        allTerminalWorkspaces.forEach { workspace in
            workspace.tabs.forEach { $0.controller.applyTheme() }
        }
        leftResizeHandle.applyTheme()
        settingsController?.applyTheme()
        newTaskModal?.applyTheme()
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

        let leftPanel = leftPanelController.view
        leftPanel.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.wantsLayer = true
        terminalHost.layer?.backgroundColor = AppTheme.background.cgColor

        rootView.addSubview(workspaceCard)
        workspaceCard.addSubview(mainColumn)
        mainColumn.addSubview(workspaceHeader)
        mainColumn.addSubview(terminalHost)
        rootView.addSubview(leftPanel)
        rootView.addSubview(leftResizeHandle)
        rootView.addSubview(edgeRevealZone)
        updateTaskSidebar()
        installActiveWorkspace()
    }

    private func configureConstraints(in rootView: NSView) {
        let leftPanel = leftPanelController.view

        leftWidthConstraint = leftPanel.widthAnchor.constraint(equalToConstant: leftPanelWidth)
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
        NSLayoutConstraint.activate([
            leftPanelLeadingConstraint,
            leftPanelTopConstraint,
            leftPanelBottomConstraint,
            leftWidthConstraint,

            workspaceTopConstraint,
            workspaceBottomConstraint,
            workspaceTrailingConstraint,

            mainColumn.leadingAnchor.constraint(equalTo: workspaceCard.leadingAnchor),
            mainColumn.trailingAnchor.constraint(equalTo: workspaceCard.trailingAnchor),
            mainColumn.topAnchor.constraint(equalTo: workspaceCard.topAnchor),
            mainColumn.bottomAnchor.constraint(equalTo: workspaceCard.bottomAnchor),

            workspaceHeader.leadingAnchor.constraint(equalTo: mainColumn.leadingAnchor),
            workspaceHeader.trailingAnchor.constraint(equalTo: mainColumn.trailingAnchor),
            workspaceHeader.topAnchor.constraint(equalTo: mainColumn.topAnchor),
            workspaceHeader.heightAnchor.constraint(equalToConstant: AppTheme.mainHeaderHeight),

            terminalHost.leadingAnchor.constraint(equalTo: mainColumn.leadingAnchor),
            terminalHost.trailingAnchor.constraint(equalTo: mainColumn.trailingAnchor),
            terminalHost.topAnchor.constraint(equalTo: workspaceHeader.bottomAnchor),
            terminalHost.bottomAnchor.constraint(equalTo: mainColumn.bottomAnchor),

            leftResizeHandle.centerXAnchor.constraint(equalTo: leftPanel.trailingAnchor),
            leftResizeHandle.topAnchor.constraint(equalTo: rootView.topAnchor),
            leftResizeHandle.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            leftResizeHandle.widthAnchor.constraint(equalToConstant: AppTheme.resizeHandleWidth),

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
        leftPanelController.onTogglePanel = { [weak self] in
            self?.toggleLeftPanel(nil)
        }
        leftPanelController.onCreateTask = { [weak self] in
            self?.presentNewTask(nil)
        }
        leftPanelController.onSelectTask = { [weak self] taskID in
            self?.selectTask(taskID)
        }
        leftPanelController.onSelectRepository = { [weak self] scope in
            self?.selectRepository(scope)
        }
        leftPanelController.onToggleTaskExpansion = { [weak self] taskID in
            self?.toggleTaskExpansion(taskID)
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
        leftResizeHandle.onKeyboardResize = { [weak self] command in
            self?.resizeLeftPanel(with: command)
        }
    }

    private var activeTerminalWorkspace: TerminalWorkspace? {
        switch activeScope {
        case nil:
            globalWorkspace
        case .task(let taskID):
            taskErrors[taskID] == nil ? taskWorkspaces[taskID] : nil
        case .repository(let scope):
            repositoryWorkspaces[scope]
        }
    }

    private var allTerminalWorkspaces: [TerminalWorkspace] {
        [globalWorkspace] + Array(taskWorkspaces.values) + Array(repositoryWorkspaces.values)
    }

    private var activeTerminalController: TerminalViewController? {
        guard
            let workspace = activeTerminalWorkspace,
            let activeTabID = workspace.activeTabID
        else { return nil }
        return workspace.tabs.first(where: { $0.id == activeTabID })?.controller
    }

    private func selectTerminalTab(_ id: UUID) {
        guard
            let workspace = activeTerminalWorkspace,
            id != workspace.activeTabID,
            workspace.tabs.contains(where: { $0.id == id })
        else { return }
        workspace.activeTabID = id
        installActiveWorkspace()
    }

    private func installActiveWorkspace() {
        terminalHost.subviews.forEach { $0.removeFromSuperview() }
        guard let workspace = activeTerminalWorkspace else {
            let allowsCreateTab: Bool
            if case .task(let taskID) = activeScope {
                allowsCreateTab = taskErrors[taskID] == nil
            } else {
                allowsCreateTab = false
            }
            workspaceHeader.setEmptyScope(
                "no tabs in this scope",
                allowsCreateTab: allowsCreateTab
            )
            installScopeMessage()
            return
        }
        workspaceHeader.setTabs(
            workspace.tabs.map { (id: $0.id, title: $0.title) },
            activeID: workspace.activeTabID
        )
        guard
            let activeTabID = workspace.activeTabID,
            let controller = activeTerminalController
        else {
            return
        }
        controller.onCloseLastPane = { [weak self] in
            self?.closeTerminalTab(activeTabID)
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
        guard
            let workspace = activeTerminalWorkspace,
            let index = workspace.tabs.firstIndex(where: { $0.id == id })
        else { return }
        let tab = workspace.tabs.remove(at: index)
        tab.controller.view.removeFromSuperview()
        tab.controller.removeFromParent()
        if workspace.activeTabID == id {
            workspace.activeTabID = workspace.tabs.isEmpty
                ? nil
                : workspace.tabs[min(index, workspace.tabs.count - 1)].id
        }
        installActiveWorkspace()
    }

    private func installScopeMessage() {
        let title: String
        let detail: String?
        switch activeScope {
        case .task(let taskID):
            if let error = taskErrors[taskID] {
                title = "Task failed"
                detail = error
            } else {
                title = "No tabs in this scope"
                detail = nil
            }
        case .repository(let scope):
            title = "Repository workspace failed"
            detail = repositoryErrors[scope]
        case nil:
            return
        }
        let message = WorkspaceScopeMessageView(title: title, detail: detail)
        message.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.addSubview(message)
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: terminalHost.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: terminalHost.centerYAnchor),
            message.leadingAnchor.constraint(
                greaterThanOrEqualTo: terminalHost.leadingAnchor,
                constant: 24
            ),
            message.trailingAnchor.constraint(
                lessThanOrEqualTo: terminalHost.trailingAnchor,
                constant: -24
            ),
        ])
    }

    private func createTask(title: String, repositories: [RegisteredRepository]) {
        let task = WorkspaceTask(
            title: title,
            repositories: repositories.map {
                TaskRepositoryAttachment(repositoryID: $0.id, name: $0.name)
            }
        )
        dismissNewTaskModal()
        tasks.insert(task, at: 0)
        activeScope = .task(task.id)
        if !task.repositories.isEmpty {
            expandedTaskIDs.insert(task.id)
        }
        updateTaskSidebar()
        installActiveWorkspace()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.taskRegistryLoaded {
                do {
                    try self.taskStore.save(self.tasks)
                    self.taskErrors.removeAll()
                } catch {
                    self.taskErrors[task.id] = error.localizedDescription
                }
            } else {
                self.taskErrors[task.id] = self.taskLoadError ?? "Task storage is unavailable."
            }
            self.updateTaskSidebar()
            if self.activeScope == .task(task.id) {
                self.installActiveWorkspace()
            }
        }
    }

    private func selectTask(_ taskID: UUID) {
        guard tasks.contains(where: { $0.id == taskID }) else { return }
        if settingsController != nil { dismissSettings() }
        activeScope = .task(taskID)
        if let task = tasks.first(where: { $0.id == taskID }), !task.repositories.isEmpty {
            expandedTaskIDs.insert(taskID)
        }
        updateTaskSidebar()
        installActiveWorkspace()
    }

    private func selectRepository(_ scope: TaskRepositoryScope) {
        guard
            let task = tasks.first(where: { $0.id == scope.taskID }),
            let attachment = task.repositories.first(where: { $0.repositoryID == scope.repositoryID })
        else { return }
        if settingsController != nil { dismissSettings() }
        activeScope = .repository(scope)
        expandedTaskIDs.insert(scope.taskID)

        if repositoryWorkspaces[scope] == nil {
            do {
                let repositories = try repositoryStore.load()
                guard let repository = repositories.first(where: { $0.id == scope.repositoryID }) else {
                    throw WorkspaceTaskError.repositoryUnavailable(attachment.name)
                }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: repository.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    throw WorkspaceTaskError.repositoryUnavailable(attachment.name)
                }
                repositoryWorkspaces[scope] = TerminalWorkspace(
                    runtime: runtime,
                    title: "~/\(attachment.name)",
                    workingDirectory: repository.path
                )
                repositoryErrors.removeValue(forKey: scope)
            } catch {
                repositoryErrors[scope] = error.localizedDescription
            }
        }
        updateTaskSidebar()
        installActiveWorkspace()
    }

    private func toggleTaskExpansion(_ taskID: UUID) {
        if expandedTaskIDs.contains(taskID) {
            if case .repository(let scope) = activeScope, scope.taskID == taskID {
                NSSound.beep()
                return
            }
            expandedTaskIDs.remove(taskID)
        } else {
            expandedTaskIDs.insert(taskID)
        }
        updateTaskSidebar()
    }

    private func updateTaskSidebar() {
        leftPanelController.updateTasks(
            tasks,
            selection: activeScope,
            expandedTaskIDs: expandedTaskIDs,
            taskErrors: taskErrors,
            repositoryErrors: repositoryErrors,
            loadError: taskLoadError
        )
    }

    private func dismissNewTaskModal() {
        newTaskModal?.removeFromSuperview()
        newTaskModal = nil
        activeTerminalController?.focusActiveTerminal()
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
            context.duration = Self.revealAnimationDuration
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
            context.duration = Self.dismissAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            leftPanelController.view.animator().alphaValue = 0
        }
        perform(
            #selector(completeTransientDismissal),
            with: nil,
            afterDelay: Self.dismissAnimationDuration
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
            if self.newTaskModal != nil,
               event.window === self.view.window,
               event.keyCode == 53 {
                self.dismissNewTaskModal()
                return nil
            }
            if self.settingsController != nil,
               event.window === self.view.window,
               event.keyCode == 53 {
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
            frame.origin.y = baselineY - AppTheme.trafficLightVerticalOffset
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
        installActiveWorkspace()
        applySidebarPresentation()
        activeTerminalController?.focusActiveTerminal()
    }

    private func resizeLeftPanel(by delta: CGFloat) {
        guard sidebarPresentation == .docked else { return }
        let minimumCenterWidth = settingsController == nil
            ? AppTheme.minimumCenterWidth
            : AppTheme.settingsRailWidth + SettingsLayout.contentMinimumWidth
        let maximumFromWindow = (leftResizeWindowWidth ?? view.bounds.width)
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
    }

    private func resizeLeftPanel(with command: PanelResizeHandle.KeyboardCommand) {
        switch command {
        case .decrease:
            resizeLeftPanel(by: -AppTheme.keyboardResizeStep)
        case .increase:
            resizeLeftPanel(by: AppTheme.keyboardResizeStep)
        case .minimum:
            resizeLeftPanel(by: -AppTheme.leftPanelRange.upperBound)
        case .maximum:
            resizeLeftPanel(by: AppTheme.leftPanelRange.upperBound)
        }
    }

}

private enum WorkspaceTaskError: LocalizedError {
    case repositoryUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .repositoryUnavailable(let name):
            "The registered path for \(name) is unavailable."
        }
    }
}

@MainActor
private final class WorkspaceScopeMessageView: NSStackView {
    init(title: String, detail: String?) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 8

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 650)
        titleLabel.textColor = detail == nil ? AppTheme.secondaryText : .systemRed
        addArrangedSubview(titleLabel)

        if let detail {
            let detailLabel = NSTextField(wrappingLabelWithString: detail)
            detailLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody)
            detailLabel.textColor = AppTheme.tertiaryText
            detailLabel.alignment = .center
            detailLabel.maximumNumberOfLines = 0
            addArrangedSubview(detailLabel)
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
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
        line.layer?.cornerRadius = AppTheme.resizeIndicatorCornerRadius
        addSubview(line)
        NSLayoutConstraint.activate([
            line.centerXAnchor.constraint(equalTo: centerXAnchor),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.heightAnchor.constraint(
                equalTo: heightAnchor,
                multiplier: AppTheme.resizeIndicatorHeightRatio
            ),
            line.widthAnchor.constraint(equalToConstant: AppTheme.resizeIndicatorWidth),
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
