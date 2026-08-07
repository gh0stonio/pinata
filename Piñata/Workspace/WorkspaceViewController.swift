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

        init(
            runtime: GhosttyRuntime,
            title: String,
            workingDirectory: String,
            startsWithTab: Bool = true
        ) {
            self.title = title
            self.workingDirectory = workingDirectory
            if startsWithTab {
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
            } else {
                tabs = []
                activeTabID = nil
            }
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
    private var workspaceHeaderHeightConstraint: NSLayoutConstraint!

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
        installActiveWorkspace()
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
        if case .task(let taskID) = activeScope {
            guard taskErrors[taskID] == nil else { return }
            if taskWorkspaces[taskID] == nil {
                taskWorkspaces[taskID] = TerminalWorkspace(
                    runtime: runtime,
                    title: "Terminal",
                    workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
                )
                installActiveWorkspace()
                return
            }
        }
        guard let workspace = activeTerminalWorkspace else { return }
        let id = UUID()
        let isFirstTab = workspace.tabs.isEmpty
        let tab = TerminalTab(
            id: id,
            title: isFirstTab ? workspace.title : "\(workspace.title) \(workspace.nextTabNumber)",
            controller: TerminalViewController(
                runtime: runtime,
                workingDirectory: workspace.workingDirectory
            )
        )
        if !isFirstTab {
            workspace.nextTabNumber += 1
        }
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
        workspaceHeaderHeightConstraint = workspaceHeader.heightAnchor.constraint(
            equalToConstant: AppTheme.mainHeaderHeight
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
            workspaceHeaderHeightConstraint,

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
            nil
        case .task(let taskID):
            taskErrors[taskID] == nil ? taskWorkspaces[taskID] : nil
        case .repository(let scope):
            repositoryWorkspaces[scope]
        }
    }

    private var allTerminalWorkspaces: [TerminalWorkspace] {
        Array(taskWorkspaces.values) + Array(repositoryWorkspaces.values)
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
        if case .repository(let scope) = activeScope,
           let task = tasks.first(where: { $0.id == scope.taskID }),
           let attachment = task.repositories.first(where: { $0.repositoryID == scope.repositoryID }),
           let report = attachment.worktreeProvisioning,
           !report.succeeded {
            setWorkspaceHeaderVisible(false)
            installWorktreeProvisioning(report, repositoryName: attachment.name)
            return
        }
        guard let workspace = activeTerminalWorkspace else {
            setWorkspaceHeaderVisible(false)
            installScopeMessage()
            return
        }
        if workspace.tabs.isEmpty {
            setWorkspaceHeaderVisible(false)
            installScopeMessage()
            return
        }
        setWorkspaceHeaderVisible(true)
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

    private func installWorktreeProvisioning(
        _ report: WorktreeProvisioningReport,
        repositoryName: String
    ) {
        let view = WorktreeProvisioningView(
            repositoryName: repositoryName,
            report: report
        )
        view.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: terminalHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor),
        ])
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
        let state: WorkspaceEmptyStateView.State
        switch activeScope {
        case .task(let taskID):
            if let error = taskErrors[taskID] {
                state = .error(title: "Task failed", detail: error)
            } else {
                state = .readyToStart
            }
        case .repository(let scope):
            if let error = repositoryErrors[scope] {
                state = .error(title: "Repository workspace failed", detail: error)
            } else {
                state = .readyToStart
            }
        case nil:
            state = .chooseTask
        }
        let message = WorkspaceEmptyStateView(state: state)
        message.onCreateTask = { [weak self] in
            self?.presentNewTask(nil)
        }
        message.onCreateTerminal = { [weak self] in
            self?.createTerminalTab(nil)
        }
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

    private func setWorkspaceHeaderVisible(_ visible: Bool) {
        workspaceHeader.isHidden = !visible
        workspaceHeaderHeightConstraint.constant = visible ? AppTheme.mainHeaderHeight : 0
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
                    self.updateTaskSidebar()
                    return
                }
            } else {
                self.taskErrors[task.id] = self.taskLoadError ?? "Task storage is unavailable."
                self.updateTaskSidebar()
                return
            }

            let worktreeBasePath = RepositoryDefaultsStore().loadWorktreeBasePath()
            let provisioner = WorktreeProvisioner(globalBasePath: worktreeBasePath)
            for repository in repositories {
                let scope = TaskRepositoryScope(taskID: task.id, repositoryID: repository.id)
                let report = provisioner.preparing(
                    repository: repository,
                    taskID: task.id,
                    taskTitle: task.title
                )
                do {
                    try self.storeWorktreeProvisioning(report, for: scope, in: task)
                } catch {
                    self.repositoryErrors[scope] = error.localizedDescription
                }
            }
            if let firstRepository = task.repositories.first {
                self.activeScope = .repository(TaskRepositoryScope(
                    taskID: task.id,
                    repositoryID: firstRepository.repositoryID
                ))
            }
            self.updateTaskSidebar()
            self.installActiveWorkspace()

            let updates = AsyncStream<(TaskRepositoryScope, WorktreeProvisioningReport)> { continuation in
                Task.detached { [repositories, task, worktreeBasePath] in
                    await withTaskGroup(of: Void.self) { group in
                        for repository in repositories {
                            group.addTask {
                                let scope = TaskRepositoryScope(
                                    taskID: task.id,
                                    repositoryID: repository.id
                                )
                                let provisioner = WorktreeProvisioner(
                                    globalBasePath: worktreeBasePath
                                )
                                _ = provisioner.provision(
                                    repository: repository,
                                    taskID: task.id,
                                    taskTitle: task.title
                                ) { report in
                                    continuation.yield((scope, report))
                                }
                            }
                        }
                        await group.waitForAll()
                    }
                    continuation.finish()
                }
            }
            Task { @MainActor [weak self] in
                for await (scope, report) in updates {
                    self?.updateWorktreeProvisioning(report, for: scope, in: task)
                }
            }
        }
    }

    private func updateWorktreeProvisioning(
        _ report: WorktreeProvisioningReport,
        for scope: TaskRepositoryScope,
        in task: WorkspaceTask
    ) {
        do {
            try storeWorktreeProvisioning(report, for: scope, in: task)
            repositoryWorkspaces.removeValue(forKey: scope)
            if let failureMessage = report.failureMessage {
                repositoryErrors[scope] = failureMessage
            } else if report.succeeded,
                      let attachment = tasks.first(where: { $0.id == scope.taskID })?.repositories.first(where: {
                          $0.repositoryID == scope.repositoryID
                      }) {
                try installRepositoryWorkspace(
                    for: scope,
                    name: attachment.name,
                    workingDirectory: report.path
                )
                repositoryErrors.removeValue(forKey: scope)
            } else {
                repositoryErrors.removeValue(forKey: scope)
            }
        } catch {
            repositoryErrors[scope] = error.localizedDescription
        }
        updateTaskSidebar()
        if activeScope == .repository(scope) {
            installActiveWorkspace()
        }
    }

    private func storeWorktreeProvisioning(
        _ report: WorktreeProvisioningReport,
        for scope: TaskRepositoryScope,
        in task: WorkspaceTask
    ) throws {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == scope.taskID }) else { return }
        var attachments = tasks[taskIndex].repositories
        guard let attachmentIndex = attachments.firstIndex(where: { $0.repositoryID == scope.repositoryID }) else {
            return
        }
        let attachment = attachments[attachmentIndex]
        attachments[attachmentIndex] = TaskRepositoryAttachment(
            repositoryID: attachment.repositoryID,
            name: attachment.name,
            worktreePath: report.succeeded ? report.path : nil,
            worktreeProvisioning: report.succeeded ? nil : report
        )
        tasks[taskIndex] = WorkspaceTask(
            id: task.id,
            title: task.title,
            repositories: attachments,
            createdAt: task.createdAt
        )
        try taskStore.save(tasks)
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

        if let report = attachment.worktreeProvisioning, let failureMessage = report.failureMessage {
            repositoryErrors[scope] = failureMessage
            updateTaskSidebar()
            installActiveWorkspace()
            return
        }

        if repositoryWorkspaces[scope] == nil {
            do {
                let repositories = try repositoryStore.load()
                guard let repository = repositories.first(where: { $0.id == scope.repositoryID }) else {
                    throw WorkspaceTaskError.repositoryUnavailable(attachment.name)
                }
                let workingDirectory = attachment.worktreePath ?? repository.path
                try installRepositoryWorkspace(
                    for: scope,
                    name: attachment.name,
                    workingDirectory: workingDirectory,
                    startsWithTab: false
                )
                repositoryErrors.removeValue(forKey: scope)
            } catch {
                repositoryErrors[scope] = error.localizedDescription
            }
        }
        updateTaskSidebar()
        installActiveWorkspace()
    }

    private func installRepositoryWorkspace(
        for scope: TaskRepositoryScope,
        name: String,
        workingDirectory: String,
        startsWithTab: Bool = true
    ) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspaceTaskError.repositoryUnavailable(name)
        }
        repositoryWorkspaces[scope] = TerminalWorkspace(
            runtime: runtime,
            title: "~/\(name)",
            workingDirectory: workingDirectory,
            startsWithTab: startsWithTab
        )
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
        updateWindowMinimumSize()
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

    private func updateWindowMinimumSize() {
        guard let window = view.window else { return }

        let settingsMinimumWidth = AppTheme.settingsRailWidth
            + SettingsLayout.dividerThickness
            + SettingsLayout.contentMinimumWidth
        let sidebarWidth = sidebarPresentation == .docked ? leftPanelWidth : 0
        let minimumWidth = max(
            AppTheme.minimumWindowWidth,
            sidebarWidth + AppTheme.workspaceInset * 2 + settingsMinimumWidth
        )

        window.minSize = NSSize(width: minimumWidth, height: 600)
        guard window.contentView?.bounds.width ?? 0 < minimumWidth else { return }
        window.setContentSize(
            NSSize(width: minimumWidth, height: window.contentView?.bounds.height ?? 600)
        )
    }

    private func resizeLeftPanel(by delta: CGFloat) {
        guard sidebarPresentation == .docked else { return }
        let minimumCenterWidth = AppTheme.settingsRailWidth
            + SettingsLayout.dividerThickness
            + SettingsLayout.contentMinimumWidth
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
        updateWindowMinimumSize()
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

@MainActor
private final class WorktreeProvisioningView: NSView, SettingsThemeApplying {
    private let content = NSStackView()
    private let artwork: WorkspaceEmptyArtworkView
    private let repositoryLabel: NSTextField
    private let detailLabel: NSTextField
    private let currentAction: WorktreeCurrentActionView
    private let report: WorktreeProvisioningReport

    init(repositoryName: String, report: WorktreeProvisioningReport) {
        self.report = report
        let step = Self.visibleStep(in: report)
        artwork = WorkspaceEmptyArtworkView(
            kind: report.failureMessage == nil ? .worktree : .error
        )
        repositoryLabel = NSTextField(labelWithString: report.failureMessage == nil
            ? "Creating \(repositoryName) worktree"
            : "Could not create \(repositoryName) worktree")
        detailLabel = NSTextField(wrappingLabelWithString: report.failureMessage ?? "")
        currentAction = WorktreeCurrentActionView(step: step)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        installContent()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        repositoryLabel.textColor = report.failureMessage == nil ? AppTheme.primaryText : .systemRed
        detailLabel.textColor = .systemRed
        artwork.needsDisplay = true
        currentAction.applyTheme()
    }

    private func installContent() {
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 12
        addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -18),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])

        artwork.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(artwork)
        artwork.widthAnchor.constraint(equalToConstant: 184).isActive = true
        artwork.heightAnchor.constraint(equalToConstant: 122).isActive = true
        content.setCustomSpacing(20, after: artwork)

        repositoryLabel.font = AppTheme.font(ofSize: AppTheme.typography.title, weight: 650)
        detailLabel.font = AppTheme.font(ofSize: AppTheme.typography.body)
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 3
        detailLabel.lineBreakMode = .byTruncatingTail
        content.addArrangedSubview(repositoryLabel)
        content.setCustomSpacing(14, after: repositoryLabel)
        content.addArrangedSubview(currentAction)
        if report.failureMessage != nil {
            content.setCustomSpacing(12, after: currentAction)
            content.addArrangedSubview(detailLabel)
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 480).isActive = true
        }
    }

    private static func visibleStep(in report: WorktreeProvisioningReport) -> WorktreeProvisioningStep {
        if let failed = report.steps.last(where: { $0.status == .failed }) {
            return failed
        }
        if let running = report.steps.last(where: { $0.status == .running }) {
            return running
        }
        if let completed = report.steps.last(where: { $0.status == .completed }) {
            return completed
        }
        return report.steps.first(where: { $0.status == .pending })
            ?? WorktreeProvisioningStep(title: "Preparing", status: .running, detail: "")
    }
}

@MainActor
private final class WorktreeCurrentActionView: NSView, SettingsThemeApplying {
    private let step: WorktreeProvisioningStep
    private let progressIndicator = NSProgressIndicator()
    private let statusIcon = NSImageView()
    private let titleLabel: NSTextField

    init(step: WorktreeProvisioningStep) {
        self.step = step
        titleLabel = NSTextField(labelWithString: Self.progressTitle(for: step.title))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        installContent()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        titleLabel.textColor = step.status == .failed ? .systemRed : AppTheme.secondaryText
        statusIcon.contentTintColor = step.status == .failed ? .systemRed : .systemGreen
    }

    private func installContent() {
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.body, weight: 500)
        titleLabel.usesSingleLineMode = true
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        if step.status == .running || step.status == .pending {
            addSubview(progressIndicator)
            progressIndicator.startAnimation(nil)
        } else {
            statusIcon.image = NSImage(
                systemSymbolName: step.status == .failed ? "xmark.circle.fill" : "checkmark.circle.fill",
                accessibilityDescription: nil
            )
            addSubview(statusIcon)
        }
        addSubview(titleLabel)
        let indicator = step.status == .running || step.status == .pending
            ? progressIndicator
            : statusIcon
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            indicator.leadingAnchor.constraint(equalTo: leadingAnchor),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 16),
            indicator.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private static func progressTitle(for title: String) -> String {
        switch title {
        case "Fetch origin": "Fetching origin"
        case "Create branch": "Creating branch"
        case "Create worktree": "Creating worktree"
        case "Run post-worktree hook": "Running post-worktree hook"
        case "Run post-checkout hook": "Running post-checkout hook"
        case "Run setup script": "Running setup script"
        default: title
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
private final class WorkspaceEmptyStateView: NSStackView {
    enum State {
        case chooseTask
        case readyToStart
        case error(title: String, detail: String)
    }

    private enum Action {
        case createTask
        case createTerminal
    }

    var onCreateTask: (() -> Void)?
    var onCreateTerminal: (() -> Void)?

    init(state: State) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 14

        let artwork: WorkspaceEmptyArtworkView
        let title: String
        let detail: String
        let action: Action?
        switch state {
        case .chooseTask:
            artwork = WorkspaceEmptyArtworkView(kind: .chooseTask)
            title = "Pick a task, make a little magic."
            detail = "Your workspace is waiting. Choose a task from the sidebar to wake it up."
            action = .createTask
        case .readyToStart:
            artwork = WorkspaceEmptyArtworkView(kind: .terminal)
            title = "This task is ready for takeoff."
            detail = "Open its first terminal and make a little productive noise."
            action = .createTerminal
        case let .error(title: errorTitle, detail: errorDetail):
            artwork = WorkspaceEmptyArtworkView(kind: .error)
            title = errorTitle
            detail = errorDetail
            action = nil
        }

        artwork.translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(artwork)
        artwork.widthAnchor.constraint(equalToConstant: 184).isActive = true
        artwork.heightAnchor.constraint(equalToConstant: 122).isActive = true
        setCustomSpacing(18, after: artwork)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.title, weight: 650)
        titleLabel.textColor = state.isError ? .systemRed : AppTheme.primaryText
        addArrangedSubview(titleLabel)
        setCustomSpacing(12, after: titleLabel)

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = AppTheme.font(ofSize: AppTheme.typography.body)
        detailLabel.textColor = AppTheme.tertiaryText
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 0
        addArrangedSubview(detailLabel)
        detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true

        if let action {
            let button: WorkspaceEmptyActionButton
            switch action {
            case .createTask:
                button = WorkspaceEmptyActionButton(title: "Create a task", symbolName: "plus")
                button.action = #selector(createTask)
            case .createTerminal:
                button = WorkspaceEmptyActionButton(
                    title: "Open first terminal",
                    symbolName: "terminal"
                )
                button.action = #selector(createTerminal)
            }
            button.target = self
            addArrangedSubview(button)
            setCustomSpacing(28, after: detailLabel)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    @objc private func createTerminal() {
        onCreateTerminal?()
    }

    @objc private func createTask() {
        onCreateTask?()
    }
}

private extension WorkspaceEmptyStateView.State {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

@MainActor
private final class WorkspaceEmptyActionButton: AppButton {
    private let terminalIcon = NSImageView()
    private let titleLabel: NSTextField

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: AppTheme.workspaceTabHorizontalInset
                + AppTheme.workspaceTabIconWidth
                + AppTheme.workspaceTabContentGap
                + titleLabel.intrinsicContentSize.width
                + AppTheme.workspaceTabHorizontalInset,
            height: 34
        )
    }

    init(title: String, symbolName: String) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(role: .accent)
        translatesAutoresizingMaskIntoConstraints = false
        self.title = ""
        setAccessibilityLabel(title)
        toolTip = title
        layer?.cornerRadius = AppTheme.workspaceControlCornerRadius
        layer?.cornerCurve = .continuous
        terminalIcon.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(
                pointSize: AppTheme.workspaceTabIconSymbolSize,
                weight: .medium
            )
        )
        terminalIcon.imageScaling = .scaleProportionallyDown
        titleLabel.usesSingleLineMode = true
        [terminalIcon, titleLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            terminalIcon.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: AppTheme.workspaceTabHorizontalInset
            ),
            terminalIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            terminalIcon.widthAnchor.constraint(equalToConstant: AppTheme.workspaceTabIconWidth),
            terminalIcon.heightAnchor.constraint(equalToConstant: AppTheme.workspaceTabIconHeight),
            titleLabel.leadingAnchor.constraint(
                equalTo: terminalIcon.trailingAnchor,
                constant: AppTheme.workspaceTabContentGap
            ),
            titleLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -AppTheme.workspaceTabHorizontalInset
            ),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyTheme()
        heightAnchor.constraint(equalToConstant: 34).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func applyTheme() {
        super.applyTheme()
        let foreground = contentTintColor ?? AppTheme.panelAccentIcon
        terminalIcon.contentTintColor = foreground
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.body, weight: 650)
        titleLabel.textColor = foreground
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        return self
    }
}

@MainActor
private final class WorkspaceEmptyArtworkView: NSView {
    enum Kind {
        case chooseTask
        case terminal
        case worktree
        case error
    }

    private let kind: Kind

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let color = kind == .error ? NSColor.systemRed : AppTheme.panelAccentIcon
        let card = NSRect(x: 28, y: 12, width: 128, height: 92)
        let shadow = card.offsetBy(dx: -13, dy: 11)
        drawCard(shadow, fill: AppTheme.controlSelection, border: AppTheme.border)
        drawCard(card, fill: AppTheme.surface, border: color.withAlphaComponent(0.5))

        switch kind {
        case .chooseTask:
            drawSidebar(in: card, color: color)
        case .terminal:
            drawTerminal(in: card, color: color)
        case .worktree:
            drawWorktree(in: card, color: color)
        case .error:
            drawError(in: card, color: color)
        }
    }

    private func drawCard(_ rect: NSRect, fill: NSColor, border: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        fill.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawSidebar(in rect: NSRect, color: NSColor) {
        let sidebar = NSRect(x: rect.minX + 13, y: rect.minY + 13, width: 32, height: 66)
        let path = NSBezierPath(roundedRect: sidebar, xRadius: 5, yRadius: 5)
        AppTheme.chromeBackground.setFill()
        path.fill()
        color.withAlphaComponent(0.76).setFill()
        NSBezierPath(roundedRect: NSRect(x: sidebar.minX + 5, y: sidebar.maxY - 17, width: 22, height: 6), xRadius: 3, yRadius: 3).fill()
        for offset in [31, 44, 57] {
            AppTheme.tertiaryText.withAlphaComponent(0.36).setFill()
            NSBezierPath(roundedRect: NSRect(x: sidebar.minX + 5, y: sidebar.maxY - CGFloat(offset), width: 17, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
        }
        let workspace = NSRect(x: rect.minX + 58, y: rect.minY + 23, width: 51, height: 47)
        let workspacePath = NSBezierPath(roundedRect: workspace, xRadius: 5, yRadius: 5)
        AppTheme.chromeBackground.setFill()
        workspacePath.fill()
        color.withAlphaComponent(0.68).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: workspace.minX + 8, y: workspace.maxY - 16, width: 35, height: 6),
            xRadius: 3,
            yRadius: 3
        ).fill()
        AppTheme.tertiaryText.withAlphaComponent(0.3).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: workspace.minX + 8, y: workspace.maxY - 30, width: 25, height: 4),
            xRadius: 2,
            yRadius: 2
        ).fill()
    }

    private func drawTerminal(in rect: NSRect, color: NSColor) {
        let headerY = rect.maxY - 21
        color.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 13, y: headerY, width: 8, height: 8), xRadius: 4, yRadius: 4).fill()
        AppTheme.tertiaryText.withAlphaComponent(0.36).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 25, y: headerY + 2, width: 35, height: 4), xRadius: 2, yRadius: 2).fill()
        let prompt = NSAttributedString(
            string: ">_",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 23, weight: .bold),
                .foregroundColor: color,
            ]
        )
        prompt.draw(at: NSPoint(x: rect.minX + 20, y: rect.minY + 27))
        AppTheme.primaryText.withAlphaComponent(0.58).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 57, y: rect.minY + 40, width: 40, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
        AppTheme.tertiaryText.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 57, y: rect.minY + 27, width: 25, height: 4), xRadius: 2, yRadius: 2).fill()
    }

    private func drawWorktree(in rect: NSRect, color: NSColor) {
        let headerY = rect.maxY - 21
        color.withAlphaComponent(0.7).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: rect.minX + 13, y: headerY, width: 8, height: 8),
            xRadius: 4,
            yRadius: 4
        ).fill()
        AppTheme.tertiaryText.withAlphaComponent(0.36).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: rect.minX + 25, y: headerY + 2, width: 35, height: 4),
            xRadius: 2,
            yRadius: 2
        ).fill()

        let root = NSPoint(x: rect.minX + 35, y: rect.minY + 25)
        let split = NSPoint(x: root.x, y: rect.minY + 49)
        let branch = NSPoint(x: rect.minX + 72, y: split.y)
        let branchPath = NSBezierPath()
        branchPath.move(to: root)
        branchPath.line(to: split)
        branchPath.line(to: branch)
        color.withAlphaComponent(0.82).setStroke()
        branchPath.lineWidth = 3
        branchPath.lineCapStyle = .round
        branchPath.stroke()
        for point in [root, split, branch] {
            AppTheme.surface.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)).fill()
            color.setStroke()
            let node = NSBezierPath(ovalIn: NSRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9))
            node.lineWidth = 2.2
            node.stroke()
        }

        AppTheme.primaryText.withAlphaComponent(0.48).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: rect.minX + 87, y: rect.minY + 46, width: 24, height: 5),
            xRadius: 2.5,
            yRadius: 2.5
        ).fill()
        AppTheme.tertiaryText.withAlphaComponent(0.28).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: rect.minX + 87, y: rect.minY + 32, width: 16, height: 4),
            xRadius: 2,
            yRadius: 2
        ).fill()
    }

    private func drawError(in rect: NSRect, color: NSColor) {
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: rect.midX, y: rect.maxY - 18))
        triangle.line(to: NSPoint(x: rect.minX + 35, y: rect.minY + 24))
        triangle.line(to: NSPoint(x: rect.maxX - 35, y: rect.minY + 24))
        triangle.close()
        color.withAlphaComponent(0.18).setFill()
        triangle.fill()
        color.withAlphaComponent(0.82).setStroke()
        triangle.lineWidth = 2
        triangle.stroke()
        let mark = NSAttributedString(
            string: "!",
            attributes: [
                .font: AppTheme.font(ofSize: 28, weight: 700),
                .foregroundColor: color,
            ]
        )
        mark.draw(at: NSPoint(x: rect.midX - 4, y: rect.minY + 33))
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
