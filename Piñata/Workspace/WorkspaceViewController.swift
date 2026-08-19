import AppKit

@MainActor
final class WorkspaceViewController: NSViewController {
    private enum SidebarPresentation: String {
        case hidden
        case transient
        case docked
    }

    private enum TaskDeletionState {
        case deleting(String)
        case failed(String)
    }

    private enum RepositoryRemovalState {
        case removing(String)
        case failed(String)
    }

    private struct TerminalTab {
        let id: UUID
        let title: String
        let controller: TerminalViewController
    }

    @MainActor
    private struct FileTab {
        let id: UUID
        let path: String
        let controller: FileEditorViewController
        var isPreview: Bool
        var title: String {
            "\(controller.hasUnsavedChanges ? "* " : "")\(URL(fileURLWithPath: path).lastPathComponent)"
        }
    }

    @MainActor
    private final class TerminalWorkspace {
        let title: String
        let workingDirectory: String
        let target: TerminalTarget
        var tabs: [TerminalTab]
        var fileTabs: [FileTab] = []
        var activeTabID: UUID?
        var nextTabNumber = 2

        init(
            runtime: GhosttyRuntime,
            title: String,
            workingDirectory: String,
            target: TerminalTarget = .local,
            startsWithTab: Bool = true
        ) {
            self.title = title
            self.workingDirectory = workingDirectory
            self.target = target
            if startsWithTab {
                let tabID = UUID()
                tabs = [
                    TerminalTab(
                        id: tabID,
                        title: title,
                        controller: TerminalViewController(
                            runtime: runtime,
                            workingDirectory: workingDirectory,
                            target: target
                        )
                    )
                ]
                activeTabID = tabID
            } else {
                tabs = []
                activeTabID = nil
            }
        }

        init(runtime: GhosttyRuntime, snapshot: StoredTerminalWorkspace) {
            title = snapshot.title
            workingDirectory = snapshot.workingDirectory
            target = snapshot.tabs.first?.terminal.panes.first?.target ?? .local
            tabs = snapshot.tabs.compactMap { tab in
                guard tab.terminal.isValid else { return nil }
                return TerminalTab(
                    id: tab.id,
                    title: tab.title,
                    controller: TerminalViewController(runtime: runtime, snapshot: tab.terminal)
                )
            }
            activeTabID = tabs.contains(where: { $0.id == snapshot.activeTabID })
                ? snapshot.activeTabID
                : tabs.first?.id
            nextTabNumber = max(2, snapshot.nextTabNumber)
        }

        func snapshot(for scope: StoredWorkspaceScope) -> StoredTerminalWorkspace {
            StoredTerminalWorkspace(
                scope: scope,
                title: title,
                workingDirectory: workingDirectory,
                tabs: tabs.map {
                    StoredTerminalTab(
                        id: $0.id,
                        title: $0.title,
                        terminal: $0.controller.sessionSnapshot
                    )
                },
                activeTabID: activeTabID,
                nextTabNumber: nextTabNumber
            )
        }
    }

    private static let sidebarDefaultsKey = "pinata.sidebar.presentation.v1"
    private static let leftPanelWidthDefaultsKey = "pinata.panel.left.width.v1"
    private static let rightPanelWidthDefaultsKey = "pinata.panel.right.width.v1"
    private static let dismissDelay: TimeInterval = 0.30
    private static let exitRevealGracePeriod: TimeInterval = 0.75
    private static let revealAnimationDuration: TimeInterval = 0.12
    private static let dismissAnimationDuration: TimeInterval = 0.10

    private let runtime: GhosttyRuntime
    private let workspaceCard = NSView()
    private let mainColumn = NSView()
    private let terminalHost = NSView()
    private let workspaceHeader = WorkspaceHeaderView()
    private let sshConnectionStatusMonitor = SSHConnectionStatusMonitor()
    private lazy var leftPanelController = PanelViewController(
        connectionStatusMonitor: sshConnectionStatusMonitor
    )
    private let rightPanelController = WorkspacePanelViewController()
    private let leftResizeHandle = PanelResizeHandle(
        indicatorOffset: AppTheme.workspaceInset
    )
    private let rightResizeHandle = PanelResizeHandle()
    private let taskStore: TaskRegistryStore
    private let sessionStore = AppSessionStore()
    private let repositoryStore = RepositoryRegistryStore()
    private let sshConnectionStore = SSHConnectionStore()
    private var taskWorkspaces: [UUID: TerminalWorkspace] = [:]
    private var repositoryWorkspaces: [TaskRepositoryScope: TerminalWorkspace] = [:]
    private var tasks: [WorkspaceTask]
    private var activeScope: WorkspaceScope?
    private var expandedTaskIDs = Set<UUID>()
    private var taskErrors: [UUID: String] = [:]
    private var repositoryErrors: [TaskRepositoryScope: String] = [:]
    private var retryingRepositoryScopes = Set<TaskRepositoryScope>()
    private var automaticProvisioningFocus: [UUID: TaskRepositoryScope] = [:]
    private var taskDeletionStates: [UUID: TaskDeletionState] = [:]
    private var repositoryRemovalStates: [TaskRepositoryScope: RepositoryRemovalState] = [:]
    private var taskLoadError: String?
    private var taskRegistryLoaded: Bool
    private var settingsController: SettingsViewController?
    private var newTaskModal: NewTaskModalView?
    private var deleteTaskModal: DeleteTaskModalView?
    private var taskActionMenu: SidebarActionMenuView?
    private var taskActionMenuMouseMonitor: Any?
    private var taskActionMenuTaskID: UUID?
    private var repositoryActionMenu: SidebarActionMenuView?
    private var repositoryActionMenuMouseMonitor: Any?
    private var repositoryActionMenuScope: TaskRepositoryScope?
    private var leftResizeWindowWidth: CGFloat?

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
    private var mainColumnTrailingToCard: NSLayoutConstraint!
    private var mainColumnTrailingToPanel: NSLayoutConstraint!
    private var workspaceHeaderHeightConstraint: NSLayoutConstraint!
    private var workspaceMinimumWidthConstraint: NSLayoutConstraint!

    private var sidebarPresentation: SidebarPresentation
    private var rightPanelVisible = false
    private var leftPanelWidth = AppTheme.leftPanelWidth
    private var rightPanelWidth = AppTheme.rightPanelWidth
    private var fullScreen = false
    private var menuTracking = false
    private var keyEventMonitor: Any?
    private weak var observedWindow: NSWindow?
    private var trafficLightBaselineY: CGFloat?
    private var trafficLightBaselineX: [NSWindow.ButtonType: CGFloat] = [:]
    private var sessionSaveWorkItem: DispatchWorkItem?

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
        taskStore = TaskRegistryStore()
        let loadedTasks: [WorkspaceTask]
        let didLoadTaskRegistry: Bool
        let loadError: String?
        do {
            loadedTasks = try taskStore.load()
            didLoadTaskRegistry = true
            loadError = nil
        } catch {
            loadedTasks = []
            didLoadTaskRegistry = false
            loadError = "Could not load tasks: \(error.localizedDescription)"
        }
        tasks = loadedTasks
        taskRegistryLoaded = didLoadTaskRegistry
        taskLoadError = loadError
        let restoredSession = try? sessionStore.load()
        expandedTaskIDs = restoredSession?.expandedTaskIDs.filter { taskID in
            loadedTasks.contains(where: { $0.id == taskID })
        } ?? []
        activeScope = restoredSession?.activeScope.flatMap { scope in
            Self.workspaceScope(from: scope, in: loadedTasks)
        }
        if let restoredSession {
            for snapshot in restoredSession.terminalWorkspaces {
                guard !snapshot.tabs.isEmpty,
                      let scope = Self.workspaceScope(from: snapshot.scope, in: loadedTasks)
                else { continue }
                let workspace = TerminalWorkspace(runtime: runtime, snapshot: snapshot)
                guard !workspace.tabs.isEmpty else { continue }
                switch scope {
                case .task(let taskID):
                    taskWorkspaces[taskID] = workspace
                case .repository(let repositoryScope):
                    repositoryWorkspaces[repositoryScope] = workspace
                }
            }
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
        let rootView = WorkspaceTrackingView()
        rootView.onExitLeft = { [weak self] in
            self?.revealTransientSidebar()
        }
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
        dismissTaskActionMenu()
        dismissRepositoryActionMenu()
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
        leftResizeHandle.refreshInteraction()
        rightResizeHandle.refreshInteraction()
    }

    @objc func toggleLeftPanel(_ sender: Any?) {
        cancelScheduledTransitions()
        sidebarPresentation = sidebarPresentation == .docked ? .hidden : .docked
        persistSidebarPresentation()
        applySidebarPresentation()
    }

    @objc func toggleRightPanel(_ sender: Any?) {
        rightPanelVisible.toggle()
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
        if let fileTab = activeFileTab {
            closeTerminalTab(fileTab.id)
            return
        }
        activeTerminalController?.closeActivePane()
    }

    @objc func createTerminalTab(_ sender: Any?) {
        guard settingsController == nil, newTaskModal == nil else { return }
        guard activeTaskDeletionState == nil, activeRepositoryRemovalState == nil else { return }
        if case .task(let taskID) = activeScope {
            guard taskErrors[taskID] == nil else { return }
            if taskWorkspaces[taskID] == nil {
                taskWorkspaces[taskID] = TerminalWorkspace(
                    runtime: runtime,
                    title: "Terminal",
                    workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
                )
                scheduleSessionSave()
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
                workingDirectory: workspace.workingDirectory,
                target: workspace.target
            )
        )
        if !isFirstTab {
            workspace.nextTabNumber += 1
        }
        workspace.tabs.append(tab)
        workspace.activeTabID = id
        scheduleSessionSave()
        if isViewLoaded {
            installActiveWorkspace()
        }
    }

    @objc func presentNewTask(_ sender: Any?) {
        presentTaskModal(editingTask: nil, focusTitle: true)
    }

    private func presentTaskModal(editingTask: WorkspaceTask?, focusTitle: Bool) {
        guard newTaskModal == nil else { return }
        if settingsController != nil {
            dismissSettings()
        }

        let repositories: [RegisteredRepository]
        let connections: [UUID: SSHConnection]
        let repositoryError: String?
        do {
            repositories = try repositoryStore.load()
            connections = Dictionary(
                uniqueKeysWithValues: ((try? sshConnectionStore.load()) ?? []).map { ($0.id, $0) }
            )
            repositoryError = nil
        } catch {
            repositories = []
            connections = [:]
            repositoryError = "Could not load repositories: \(error.localizedDescription)"
        }

        let modal = NewTaskModalView(
            repositories: repositories,
            connections: connections,
            repositoryError: repositoryError,
            editingTask: editingTask
        )
        modal.onCancel = { [weak self] in self?.dismissNewTaskModal() }
        modal.onCreate = { [weak self] title, repositories in
            if let editingTask {
                self?.updateTask(
                    title: title,
                    repositories: repositories,
                    taskID: editingTask.id
                )
            } else {
                self?.createTask(title: title, repositories: repositories)
            }
        }
        view.addSubview(modal)
        NSLayoutConstraint.activate([
            modal.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            modal.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            modal.topAnchor.constraint(equalTo: view.topAnchor),
            modal.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        newTaskModal = modal
        DispatchQueue.main.async {
            if focusTitle {
                modal.focusTitle()
            } else {
                modal.window?.makeFirstResponder(nil)
            }
        }
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

        let controller = SettingsViewController(
            settings: settings,
            connectionStatusMonitor: sshConnectionStatusMonitor
        )
        controller.onChange = onChange
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        workspaceCard.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: workspaceCard.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: workspaceCard.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: workspaceCard.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: workspaceCard.bottomAnchor),
        ])
        settingsController = controller
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
        terminalHost.layer?.backgroundColor = AppTheme.background.cgColor
        workspaceHeader.applyTheme()
        leftPanelController.applyTheme()
        rightPanelController.applyTheme()
        allTerminalWorkspaces.forEach { workspace in
            workspace.tabs.forEach { $0.controller.applyTheme() }
            workspace.fileTabs.forEach { $0.controller.applyTheme() }
        }
        leftResizeHandle.applyTheme()
        rightResizeHandle.applyTheme()
        settingsController?.applyTheme()
        newTaskModal?.applyTheme()
        deleteTaskModal?.applyTheme()
        taskActionMenu?.applyTheme()
        repositoryActionMenu?.applyTheme()
        applySidebarPresentation()
    }

    func refreshSSHConnectionStatuses() {
        sshConnectionStatusMonitor.refresh()
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
        terminalHost.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.wantsLayer = true
        terminalHost.layer?.backgroundColor = AppTheme.background.cgColor

        rootView.addSubview(workspaceCard)
        workspaceCard.addSubview(mainColumn)
        mainColumn.addSubview(workspaceHeader)
        mainColumn.addSubview(terminalHost)
        rootView.addSubview(leftPanel)
        rootView.addSubview(leftResizeHandle)
        workspaceCard.addSubview(rightPanel)
        workspaceCard.addSubview(rightResizeHandle)
        updateTaskSidebar()
    }

    private func configureConstraints(in rootView: NSView) {
        let leftPanel = leftPanelController.view
        let rightPanel = rightPanelController.view

        workspaceMinimumWidthConstraint = rootView.widthAnchor.constraint(
            greaterThanOrEqualToConstant: AppTheme.minimumWindowWidth
        )
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
        workspaceHeaderHeightConstraint = workspaceHeader.heightAnchor.constraint(
            equalToConstant: AppTheme.mainHeaderHeight
        )
        mainColumnTrailingToCard = mainColumn.trailingAnchor.constraint(
            equalTo: workspaceCard.trailingAnchor
        )
        mainColumnTrailingToPanel = mainColumn.trailingAnchor.constraint(
            equalTo: rightPanel.leadingAnchor
        )
        NSLayoutConstraint.activate([
            workspaceMinimumWidthConstraint,
            leftPanelLeadingConstraint,
            leftPanelTopConstraint,
            leftPanelBottomConstraint,
            leftWidthConstraint,
            rightWidthConstraint,

            workspaceTopConstraint,
            workspaceBottomConstraint,
            workspaceTrailingConstraint,

            mainColumn.leadingAnchor.constraint(equalTo: workspaceCard.leadingAnchor),
            mainColumnTrailingToCard,
            mainColumn.topAnchor.constraint(equalTo: workspaceCard.topAnchor),
            mainColumn.bottomAnchor.constraint(equalTo: workspaceCard.bottomAnchor),

            rightPanel.trailingAnchor.constraint(equalTo: workspaceCard.trailingAnchor),
            rightPanel.topAnchor.constraint(equalTo: workspaceCard.topAnchor),
            rightPanel.bottomAnchor.constraint(equalTo: workspaceCard.bottomAnchor),

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

            rightResizeHandle.centerXAnchor.constraint(equalTo: rightPanel.leadingAnchor),
            rightResizeHandle.topAnchor.constraint(equalTo: workspaceCard.topAnchor),
            rightResizeHandle.bottomAnchor.constraint(equalTo: workspaceCard.bottomAnchor),
            rightResizeHandle.widthAnchor.constraint(equalToConstant: AppTheme.resizeHandleWidth),

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
        workspaceHeader.onTogglePanel = { [weak self] in
            self?.toggleRightPanel(nil)
        }
        rightPanelController.onTogglePanel = { [weak self] in
            self?.toggleRightPanel(nil)
        }
        rightPanelController.onOpenFile = { [weak self] entry, permanent in
            self?.openFile(entry, permanent: permanent)
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
        leftPanelController.onSidebarTaskHover = { [weak self] taskID in
            guard let self else { return }
            if taskActionMenu != nil, taskActionMenuTaskID != taskID {
                dismissTaskActionMenu()
            }
            if repositoryActionMenu != nil {
                dismissRepositoryActionMenu()
            }
        }
        leftPanelController.onSidebarRepositoryHover = { [weak self] scope in
            guard let self else { return }
            if taskActionMenu != nil {
                dismissTaskActionMenu()
            }
            if repositoryActionMenu != nil, repositoryActionMenuScope != scope {
                dismissRepositoryActionMenu()
            }
        }
        leftPanelController.onMoveTask = { [weak self] sourceID, targetID, after, pinned in
            self?.moveTask(
                sourceID,
                relativeTo: targetID,
                after: after,
                pinned: pinned
            )
        }
        leftPanelController.onShowTaskMenu = { [weak self] taskID, anchorRect in
            self?.presentTaskActionMenu(taskID: taskID, anchorRect: anchorRect)
        }
        leftPanelController.onShowRepositoryMenu = { [weak self] scope, anchorRect in
            self?.presentRepositoryActionMenu(scope: scope, anchorRect: anchorRect)
        }
        leftPanelController.onHoverChanged = { [weak self] hovering in
            guard let self else { return }
            if hovering {
                self.cancelTransientDismissal()
            } else {
                self.scheduleTransientDismissal()
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
        rightResizeHandle.onDrag = { [weak self] delta in
            self?.resizeRightPanel(by: -delta)
        }
        rightResizeHandle.onKeyboardResize = { [weak self] command in
            self?.resizeRightPanel(with: command)
        }
    }

    private var activeTerminalWorkspace: TerminalWorkspace? {
        guard activeTaskDeletionState == nil, activeRepositoryRemovalState == nil else {
            return nil
        }
        return switch activeScope {
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

    private var activeFileTab: FileTab? {
        guard let workspace = activeTerminalWorkspace, let id = workspace.activeTabID else { return nil }
        return workspace.fileTabs.first(where: { $0.id == id })
    }

    private var activeTaskID: UUID? {
        switch activeScope {
        case .task(let taskID): taskID
        case .repository(let scope): scope.taskID
        case nil: nil
        }
    }

    private var activeTaskDeletionState: TaskDeletionState? {
        activeTaskID.flatMap { taskDeletionStates[$0] }
    }

    private var activeRepositoryRemovalState: RepositoryRemovalState? {
        guard case .repository(let scope) = activeScope else { return nil }
        return repositoryRemovalStates[scope]
    }

    private func selectTerminalTab(_ id: UUID) {
        guard
            let workspace = activeTerminalWorkspace,
            id != workspace.activeTabID,
            workspace.tabs.contains(where: { $0.id == id }) || workspace.fileTabs.contains(where: { $0.id == id })
        else { return }
        workspace.activeTabID = id
        scheduleSessionSave()
        installActiveWorkspace()
    }

    private func installActiveWorkspace() {
        terminalHost.subviews.forEach { $0.removeFromSuperview() }
        let workspace = activeTerminalWorkspace
        let repositoryName: String? = if case .repository(let scope) = activeScope {
            tasks.first(where: { $0.id == scope.taskID })?
                .repositories.first(where: { $0.repositoryID == scope.repositoryID })?.name
        } else {
            workspace?.title.replacingOccurrences(of: "~/", with: "")
        }
        rightPanelController.setFileRoot(
            name: repositoryName,
            workingDirectory: workspace?.workingDirectory,
            target: workspace?.target
        )
        if activeTaskDeletionState != nil || activeRepositoryRemovalState != nil {
            setWorkspaceHeaderVisible(false)
            installScopeMessage()
            return
        }
        if case .repository(let scope) = activeScope,
           let task = tasks.first(where: { $0.id == scope.taskID }),
           let attachment = task.repositories.first(where: { $0.repositoryID == scope.repositoryID }),
           let report = attachment.worktreeProvisioning,
           !report.succeeded {
            setWorkspaceHeaderVisible(false)
            installWorktreeProvisioning(
                report,
                repositoryName: attachment.name,
                scope: scope
            )
            return
        }
        guard let workspace else {
            setWorkspaceHeaderVisible(false)
            installScopeMessage()
            return
        }
        if workspace.tabs.isEmpty && workspace.fileTabs.isEmpty {
            setWorkspaceHeaderVisible(false)
            installScopeMessage()
            return
        }
        setWorkspaceHeaderVisible(true)
        workspaceHeader.setPreviewTabIDs(Set(workspace.fileTabs.filter(\.isPreview).map(\.id)))
        workspaceHeader.setFileTabIDs(Set(workspace.fileTabs.map(\.id)))
        workspaceHeader.setTabs(
            workspace.tabs.map { (id: $0.id, title: $0.title) }
                + workspace.fileTabs.map { (id: $0.id, title: $0.title) },
            activeID: workspace.activeTabID
        )
        if let fileTab = activeFileTab {
            install(fileTab.controller)
            return
        }
        guard
            let activeTabID = workspace.activeTabID,
            let controller = activeTerminalController
        else {
            return
        }
        controller.onCloseLastPane = { [weak self] in
            self?.closeTerminalTab(activeTabID)
        }
        controller.onChange = { [weak self] in
            self?.scheduleSessionSave()
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

    private func install(_ controller: NSViewController) {
        if controller.parent !== self { addChild(controller) }
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: terminalHost.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor),
        ])
    }

    private func openFile(_ entry: FileTreeEntry, permanent: Bool) {
        guard !entry.isDirectory, let workspace = activeTerminalWorkspace else { return }
        if let index = workspace.fileTabs.firstIndex(where: { $0.path == entry.path }) {
            if permanent { workspace.fileTabs[index].isPreview = false }
            workspace.activeTabID = workspace.fileTabs[index].id
            installActiveWorkspace()
            return
        }
        let previewsEnabled = UserSettingsStore().load().filePreviewsEnabled
        let isPreview = previewsEnabled && !permanent
        if isPreview, let index = workspace.fileTabs.firstIndex(where: { $0.isPreview }) {
            let tab = workspace.fileTabs.remove(at: index)
            tab.controller.view.removeFromSuperview()
            tab.controller.removeFromParent()
        }
        let controller = FileEditorViewController(path: entry.path, target: workspace.target)
        let id = UUID()
        controller.onStateChange = { [weak self] in
            guard let self, let workspace = self.activeTerminalWorkspace,
                  let index = workspace.fileTabs.firstIndex(where: { $0.id == id }) else { return }
            workspace.fileTabs[index].isPreview = false
            self.installActiveWorkspace()
        }
        workspace.fileTabs.append(FileTab(id: id, path: entry.path, controller: controller, isPreview: isPreview))
        workspace.activeTabID = id
        installActiveWorkspace()
    }

    private func installWorktreeProvisioning(
        _ report: WorktreeProvisioningReport,
        repositoryName: String,
        scope: TaskRepositoryScope
    ) {
        let view = WorktreeProvisioningView(
            repositoryName: repositoryName,
            report: report
        )
        view.onRetry = { [weak self] in
            self?.retryWorktreeProvisioning(scope)
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: terminalHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor),
        ])
    }

    private func retryWorktreeProvisioning(_ scope: TaskRepositoryScope) {
        guard
            let task = tasks.first(where: { $0.id == scope.taskID }),
            let attachment = task.repositories.first(where: {
                $0.repositoryID == scope.repositoryID
            }),
            let report = attachment.worktreeProvisioning,
            report.failureMessage != nil,
            taskDeletionStates[scope.taskID] == nil,
            repositoryRemovalStates[scope] == nil,
            retryingRepositoryScopes.insert(scope).inserted
        else { return }
        repositoryErrors.removeValue(forKey: scope)
        updateTaskSidebar()

        let repository: RegisteredRepository
        let connection: SSHConnection?
        do {
            let repositories = try repositoryStore.load()
            guard let match = repositories.first(where: { $0.id == scope.repositoryID }) else {
                throw WorkspaceTaskError.repositoryUnavailable(attachment.name)
            }
            repository = match
            connection = try sshConnection(for: repository)
        } catch {
            failWorktreeRetry(error.localizedDescription, report: report, for: scope)
            return
        }

        Task { @MainActor [weak self] in
            let failure = await Task.detached { [report, repository] in
                do {
                    try RepositoryInspector().removeWorktree(
                        at: report.path,
                        branchHint: report.branch,
                        taskID: scope.taskID,
                        from: repository,
                        connection: connection
                    )
                    return nil as String?
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self else { return }
            retryingRepositoryScopes.remove(scope)
            if let failure {
                failWorktreeRetry(failure, report: report, for: scope)
                return
            }
            guard
                taskDeletionStates[scope.taskID] == nil,
                repositoryRemovalStates[scope] == nil,
                let currentTask = tasks.first(where: { $0.id == scope.taskID })
            else {
                updateTaskSidebar()
                return
            }
            saveAndProvision([repository], for: currentTask)
        }
    }

    private func failWorktreeRetry(
        _ message: String,
        report: WorktreeProvisioningReport,
        for scope: TaskRepositoryScope
    ) {
        retryingRepositoryScopes.remove(scope)
        updateWorktreeProvisioning(
            WorktreeProvisioningReport(
                path: report.path,
                branch: report.branch,
                baseBranch: report.baseBranch,
                steps: [WorktreeProvisioningStep(
                    title: "Prepare retry",
                    status: .failed,
                    detail: message
                )]
            ),
            for: scope
        )
    }

    private func closeTerminalTab(_ id: UUID) {
        guard let workspace = activeTerminalWorkspace else { return }
        if let index = workspace.fileTabs.firstIndex(where: { $0.id == id }) {
            let tab = workspace.fileTabs.remove(at: index)
            tab.controller.view.removeFromSuperview()
            tab.controller.removeFromParent()
            if workspace.activeTabID == id {
                workspace.activeTabID = workspace.tabs.last?.id ?? workspace.fileTabs.last?.id
            }
            installActiveWorkspace()
            return
        }
        guard let index = workspace.tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = workspace.tabs.remove(at: index)
        tab.controller.terminateSessions()
        tab.controller.view.removeFromSuperview()
        tab.controller.removeFromParent()
        if workspace.activeTabID == id {
            workspace.activeTabID = workspace.tabs.isEmpty
                ? nil
                : workspace.tabs[min(index, workspace.tabs.count - 1)].id
        }
        scheduleSessionSave()
        installActiveWorkspace()
    }

    private func installScopeMessage() {
        let state: WorkspaceEmptyStateView.State
        let deletionTaskID = activeTaskID.flatMap { taskDeletionStates[$0] == nil ? nil : $0 }
        let removalScope: TaskRepositoryScope?
        if case .repository(let scope) = activeScope,
           repositoryRemovalStates[scope] != nil {
            removalScope = scope
        } else {
            removalScope = nil
        }
        if let deletionTaskID,
           let deletionState = taskDeletionStates[deletionTaskID],
           let task = tasks.first(where: { $0.id == deletionTaskID }) {
            switch deletionState {
            case .deleting(let step):
                state = .deletingTask(title: task.title, step: step)
            case .failed(let detail):
                state = .deletionFailed(title: task.title, detail: detail)
            }
        } else if let removalScope,
                  let removalState = repositoryRemovalStates[removalScope],
                  let attachment = tasks.first(where: { $0.id == removalScope.taskID })?
                    .repositories.first(where: { $0.repositoryID == removalScope.repositoryID }) {
            switch removalState {
            case .removing(let step):
                state = .removingRepository(title: attachment.name, step: step)
            case .failed(let detail):
                state = .repositoryRemovalFailed(title: attachment.name, detail: detail)
            }
        } else {
            state = switch activeScope {
        case .task(let taskID):
            if let error = taskErrors[taskID] {
                .error(title: "Task failed", detail: error)
            } else {
                .readyToStart
            }
        case .repository(let scope):
            if let error = repositoryErrors[scope] {
                .error(title: "Repository workspace failed", detail: error)
            } else {
                .readyToStart
            }
        case nil:
            .chooseTask
            }
        }
        let message = WorkspaceEmptyStateView(state: state)
        message.onCreateTask = { [weak self] in
            self?.presentNewTask(nil)
        }
        message.onCreateTerminal = { [weak self] in
            self?.createTerminalTab(nil)
        }
        message.onRetryDeletion = { [weak self] in
            guard let self else { return }
            if let deletionTaskID,
               let task = tasks.first(where: { $0.id == deletionTaskID }) {
                deleteTask(task)
            } else if let removalScope {
                removeRepository(removalScope)
            }
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
        scheduleSessionSave()
        installActiveWorkspace()
        DispatchQueue.main.async { [weak self] in
            self?.saveAndProvision(repositories, for: task)
        }
    }

    private func updateTask(
        title: String,
        repositories: [RegisteredRepository],
        taskID: UUID
    ) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        let task = tasks[taskIndex]
        let existingIDs = Set(task.repositories.map(\.repositoryID))
        let additions = repositories.filter { !existingIDs.contains($0.id) }
        guard task.title != title || !additions.isEmpty else { return }

        let updatedTask = WorkspaceTask(
            id: task.id,
            title: title,
            repositories: task.repositories + additions.map {
                TaskRepositoryAttachment(repositoryID: $0.id, name: $0.name)
            },
            createdAt: task.createdAt,
            isPinned: task.isPinned
        )
        dismissNewTaskModal()
        tasks[taskIndex] = updatedTask
        expandedTaskIDs.insert(task.id)
        updateTaskSidebar()
        scheduleSessionSave()
        DispatchQueue.main.async { [weak self] in
            self?.saveAndProvision(additions, for: updatedTask)
        }
    }

    private func saveAndProvision(
        _ repositories: [RegisteredRepository],
        for task: WorkspaceTask
    ) {
        guard taskRegistryLoaded else {
            taskErrors[task.id] = taskLoadError ?? "Task storage is unavailable."
            updateTaskSidebar()
            return
        }
        do {
            try taskStore.save(tasks)
            taskErrors.removeValue(forKey: task.id)
        } catch {
            taskErrors[task.id] = error.localizedDescription
            updateTaskSidebar()
            return
        }
        guard !repositories.isEmpty else {
            updateTaskSidebar()
            installActiveWorkspace()
            return
        }

        let worktreeBasePath = RepositoryDefaultsStore().loadWorktreeBasePath()
        var provisionableRepositories: [(repository: RegisteredRepository, connection: SSHConnection?)] = []
        for repository in repositories {
            let scope = TaskRepositoryScope(taskID: task.id, repositoryID: repository.id)
            let connection: SSHConnection?
            do {
                connection = try sshConnection(for: repository)
            } catch {
                repositoryErrors[scope] = error.localizedDescription
                continue
            }
            let provisioner = WorktreeProvisioner(
                globalBasePath: worktreeBasePath,
                connection: connection
            )
            let report = provisioner.preparing(
                repository: repository,
                taskID: task.id,
                taskTitle: task.title
            )
            do {
                try storeWorktreeProvisioning(report, for: scope)
                provisionableRepositories.append((repository, connection))
            } catch {
                repositoryErrors[scope] = error.localizedDescription
            }
        }
        if let firstRepository = provisionableRepositories.first?.repository {
            let scope = TaskRepositoryScope(
                taskID: task.id,
                repositoryID: firstRepository.id
            )
            activeScope = .repository(scope)
            automaticProvisioningFocus[task.id] = scope
        }
        updateTaskSidebar()
        scheduleSessionSave()
        installActiveWorkspace()

        let updates = AsyncStream<(TaskRepositoryScope, WorktreeProvisioningReport)> { continuation in
            Task.detached { [provisionableRepositories, task, worktreeBasePath] in
                await withTaskGroup(of: Void.self) { group in
                    for item in provisionableRepositories {
                        group.addTask {
                            let repository = item.repository
                            let scope = TaskRepositoryScope(
                                taskID: task.id,
                                repositoryID: repository.id
                            )
                            let provisioner = WorktreeProvisioner(
                                globalBasePath: worktreeBasePath,
                                connection: item.connection
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
                self?.updateWorktreeProvisioning(report, for: scope)
            }
        }
    }

    private func presentTaskActionMenu(taskID: UUID, anchorRect: NSRect) {
        guard let task = tasks.first(where: { $0.id == taskID }) else { return }
        if taskDeletionStates[taskID] != nil {
            selectTask(taskID)
            return
        }
        if let scope = repositoryRemovalStates.keys.first(where: { $0.taskID == taskID }) {
            selectRepository(scope)
            return
        }
        dismissRepositoryActionMenu()
        dismissTaskActionMenu()
        taskActionMenuTaskID = taskID
        leftPanelController.setTaskMenuTask(taskID)

        let menu = SidebarActionMenuView(items: [
            .init(
                title: task.isPinned ? "Unpin task" : "Pin task",
                symbol: task.isPinned ? "pin.slash" : "pin"
            ),
            .init(title: "Rename", symbol: "square.and.pencil"),
            .init(title: "Attach repositories", symbol: "book.closed"),
            .init(title: "Delete task…", symbol: "trash", destructive: true),
        ])
        menu.onSelect = { [weak self] index in
            self?.dismissTaskActionMenu()
            switch index {
            case 0: self?.toggleTaskPin(task.id)
            case 1: self?.presentTaskModal(editingTask: task, focusTitle: true)
            case 2: self?.presentTaskModal(editingTask: task, focusTitle: false)
            case 3: self?.confirmTaskDeletion(task.id)
            default: break
            }
        }
        let anchor = view.convert(anchorRect, from: nil)
        let size = NSSize(width: 174, height: 139)
        menu.frame = NSRect(
            x: min(anchor.maxX + 6, view.bounds.maxX - size.width - 8),
            y: min(max(8, anchor.maxY - size.height), view.bounds.maxY - size.height - 8),
            width: size.width,
            height: size.height
        )
        view.addSubview(menu, positioned: .above, relativeTo: nil)
        taskActionMenu = menu
        taskActionMenuMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self, weak menu] event in
            guard let self, let menu, event.window === view.window else { return event }
            let point = menu.convert(event.locationInWindow, from: nil)
            if !menu.bounds.contains(point) {
                dismissTaskActionMenu()
            }
            return event
        }
    }

    private func toggleTaskPin(_ taskID: UUID) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        let task = tasks[taskIndex]
        var updatedTasks = tasks
        updatedTasks[taskIndex] = WorkspaceTask(
            id: task.id,
            title: task.title,
            repositories: task.repositories,
            createdAt: task.createdAt,
            isPinned: !task.isPinned
        )
        do {
            try taskStore.save(updatedTasks)
            tasks = updatedTasks
            taskErrors.removeValue(forKey: taskID)
        } catch {
            taskErrors[taskID] = error.localizedDescription
        }
        updateTaskSidebar()
    }

    private func dismissTaskActionMenu() {
        if let taskActionMenuMouseMonitor {
            NSEvent.removeMonitor(taskActionMenuMouseMonitor)
            self.taskActionMenuMouseMonitor = nil
        }
        taskActionMenu?.removeFromSuperview()
        taskActionMenu = nil
        taskActionMenuTaskID = nil
        leftPanelController.setTaskMenuTask(nil)
    }

    private func presentRepositoryActionMenu(
        scope: TaskRepositoryScope,
        anchorRect: NSRect
    ) {
        guard let task = tasks.first(where: { $0.id == scope.taskID }),
              let attachment = task.repositories.first(where: {
                  $0.repositoryID == scope.repositoryID
              }) else { return }
        if taskDeletionStates[scope.taskID] != nil || repositoryRemovalStates[scope] != nil {
            selectRepository(scope)
            return
        }
        dismissTaskActionMenu()
        dismissRepositoryActionMenu()
        repositoryActionMenuScope = scope
        leftPanelController.setRepositoryMenuScope(scope)
        let isRemote: Bool
        if let repository = try? repositoryStore.load().first(where: { $0.id == attachment.repositoryID }),
           case .ssh = repository.target {
            isRemote = true
        } else {
            isRemote = false
        }

        var items: [SidebarActionMenuView.Item] = [
            .init(title: "Copy branch name", symbol: "doc.on.doc"),
        ]
        if !isRemote {
            items.append(.init(title: "Reveal worktree", symbol: "folder"))
        }
        items.append(.init(title: "Detach from task…", symbol: "xmark.circle", destructive: true))
        let menu = SidebarActionMenuView(items: items)
        menu.onSelect = { [weak self] index in
            self?.dismissRepositoryActionMenu()
            switch index {
            case 0: self?.copyBranchName(attachment)
            case 1 where isRemote: self?.confirmRepositoryRemoval(scope)
            case 1: self?.revealWorktree(attachment)
            case 2: self?.confirmRepositoryRemoval(scope)
            default: break
            }
        }
        let anchor = view.convert(anchorRect, from: nil)
        let size = NSSize(width: 220, height: isRemote ? 76 : 110)
        menu.frame = NSRect(
            x: min(anchor.maxX + 6, view.bounds.maxX - size.width - 8),
            y: min(max(8, anchor.maxY - size.height), view.bounds.maxY - size.height - 8),
            width: size.width,
            height: size.height
        )
        view.addSubview(menu, positioned: .above, relativeTo: nil)
        repositoryActionMenu = menu
        repositoryActionMenuMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .leftMouseDown
        ) { [weak self, weak menu] event in
            guard let self, let menu, event.window === view.window else { return event }
            let point = menu.convert(event.locationInWindow, from: nil)
            if !menu.bounds.contains(point) {
                dismissRepositoryActionMenu()
            }
            return event
        }
    }

    private func dismissRepositoryActionMenu() {
        if let repositoryActionMenuMouseMonitor {
            NSEvent.removeMonitor(repositoryActionMenuMouseMonitor)
            self.repositoryActionMenuMouseMonitor = nil
        }
        repositoryActionMenu?.removeFromSuperview()
        repositoryActionMenu = nil
        repositoryActionMenuScope = nil
        leftPanelController.setRepositoryMenuScope(nil)
    }

    private func copyBranchName(_ attachment: TaskRepositoryAttachment) {
        if let branch = attachment.branch ?? attachment.worktreeProvisioning?.branch,
           !branch.isEmpty {
            copyToPasteboard(branch)
            return
        }
        guard let path = attachment.worktreePath ?? attachment.worktreeProvisioning?.path else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            let branch = await Task.detached {
                try? RepositoryInspector().currentBranch(at: path)
            }.value
            guard let branch, !branch.isEmpty else {
                NSSound.beep()
                return
            }
            copyToPasteboard(branch)
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func revealWorktree(_ attachment: TaskRepositoryAttachment) {
        guard let path = attachment.worktreePath ?? attachment.worktreeProvisioning?.path,
              FileManager.default.fileExists(atPath: path) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func confirmRepositoryRemoval(_ scope: TaskRepositoryScope) {
        guard deleteTaskModal == nil,
              let task = tasks.first(where: { $0.id == scope.taskID }),
              let attachment = task.repositories.first(where: {
                  $0.repositoryID == scope.repositoryID
              }) else { return }
        let isProvisioning = attachment.worktreeProvisioning.map {
            !$0.succeeded && $0.failureMessage == nil
        } == true
        guard !isProvisioning else {
            NSSound.beep()
            return
        }
        let modal = DeleteTaskModalView(
            title: "Detach \"\(attachment.name)\" repository from task?",
            detail: "This removes its worktree and task branch. The original repository is not deleted.",
            actionTitle: "Detach"
        )
        modal.onCancel = { [weak self] in self?.dismissDeleteTaskModal() }
        modal.onDelete = { [weak self] in
            self?.dismissDeleteTaskModal()
            self?.removeRepository(scope)
        }
        view.addSubview(modal)
        NSLayoutConstraint.activate([
            modal.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            modal.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            modal.topAnchor.constraint(equalTo: view.topAnchor),
            modal.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        deleteTaskModal = modal
    }

    private func confirmTaskDeletion(_ taskID: UUID) {
        guard deleteTaskModal == nil,
              let task = tasks.first(where: { $0.id == taskID }) else { return }
        if taskDeletionStates[taskID] != nil {
            selectTask(taskID)
            return
        }
        let isProvisioning = task.repositories.contains { attachment in
            guard let report = attachment.worktreeProvisioning else { return false }
            return report.failureMessage == nil && !report.succeeded
        }
        guard !isProvisioning else { return }

        let modal = DeleteTaskModalView(taskTitle: task.title)
        modal.onCancel = { [weak self] in self?.dismissDeleteTaskModal() }
        modal.onDelete = { [weak self] in
            self?.dismissDeleteTaskModal()
            self?.deleteTask(task)
        }
        view.addSubview(modal)
        NSLayoutConstraint.activate([
            modal.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            modal.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            modal.topAnchor.constraint(equalTo: view.topAnchor),
            modal.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        deleteTaskModal = modal
    }

    private func dismissDeleteTaskModal() {
        deleteTaskModal?.removeFromSuperview()
        deleteTaskModal = nil
        activeTerminalController?.focusActiveTerminal()
    }

    private func deleteTask(_ task: WorkspaceTask) {
        guard tasks.contains(where: { $0.id == task.id }) else { return }
        var fileCachePaths = Set(repositoryWorkspaces.compactMap { scope, workspace in
            scope.taskID == task.id ? workspace.workingDirectory : nil
        }).union(task.repositories.compactMap {
            $0.worktreePath ?? $0.worktreeProvisioning?.path
        })
        if let path = taskWorkspaces[task.id]?.workingDirectory {
            fileCachePaths.insert(path)
        }
        activeScope = .task(task.id)
        expandedTaskIDs.insert(task.id)
        taskErrors.removeValue(forKey: task.id)
        taskDeletionStates[task.id] = .deleting("Closing terminals")
        updateTaskSidebar()
        installActiveWorkspace()

        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            closeTerminalWorkspaces(for: task.id)
            taskDeletionStates[task.id] = .deleting("Removing worktrees and branches")
            installActiveWorkspace()

            let attachments = task.repositories.filter {
                $0.worktreePath != nil || $0.worktreeProvisioning?.path != nil
            }
            let registeredRepositories: [RegisteredRepository]
            if attachments.isEmpty {
                registeredRepositories = []
            } else {
                do {
                    registeredRepositories = try repositoryStore.load()
                } catch {
                    failTaskDeletion(task.id, message: error.localizedDescription)
                    return
                }
            }

            let connections = (try? sshConnectionStore.load()) ?? []
            let errorMessage = await Task.detached { [attachments, registeredRepositories, connections] in
                let repositoriesByID = Dictionary(
                    uniqueKeysWithValues: registeredRepositories.map { ($0.id, $0) }
                )
                do {
                    for attachment in attachments {
                        guard let path = attachment.worktreePath
                                ?? attachment.worktreeProvisioning?.path else { continue }
                        guard let repository = repositoriesByID[attachment.repositoryID] else {
                            throw WorkspaceTaskError.repositoryUnavailable(attachment.name)
                        }
                        let connection: SSHConnection?
                        if case .ssh(let connectionID) = repository.target {
                            guard let value = connections.first(where: { $0.id == connectionID }) else {
                                throw WorkspaceTaskError.repositoryUnavailable(attachment.name)
                            }
                            connection = value
                        } else {
                            connection = nil
                        }
                        try RepositoryInspector().removeWorktree(
                            at: path,
                            branchHint: attachment.branch
                                ?? attachment.worktreeProvisioning?.branch,
                            taskID: task.id,
                            from: repository,
                            connection: connection
                        )
                    }
                    return nil as String?
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let errorMessage {
                failTaskDeletion(task.id, message: errorMessage)
                return
            }

            taskDeletionStates[task.id] = .deleting("Removing task")
            installActiveWorkspace()
            let remainingTasks = tasks.filter { $0.id != task.id }
            do {
                try taskStore.save(remainingTasks)
            } catch {
                failTaskDeletion(task.id, message: error.localizedDescription)
                return
            }
            rightPanelController.invalidateFileCaches(at: fileCachePaths)
            tasks = remainingTasks
            taskDeletionStates.removeValue(forKey: task.id)
            taskWorkspaces.removeValue(forKey: task.id)
            repositoryWorkspaces = repositoryWorkspaces.filter { $0.key.taskID != task.id }
            expandedTaskIDs.remove(task.id)
            taskErrors.removeValue(forKey: task.id)
            repositoryErrors = repositoryErrors.filter { $0.key.taskID != task.id }
            let deletedActiveScope: Bool
            switch activeScope {
            case .task(let taskID) where taskID == task.id:
                deletedActiveScope = true
            case .repository(let scope) where scope.taskID == task.id:
                deletedActiveScope = true
            default:
                deletedActiveScope = false
            }
            if deletedActiveScope {
                activeScope = tasks.first.map { .task($0.id) }
            }
            updateTaskSidebar()
            scheduleSessionSave()
            installActiveWorkspace()
        }
    }

    private func removeRepository(_ scope: TaskRepositoryScope) {
        guard let task = tasks.first(where: { $0.id == scope.taskID }),
              let attachment = task.repositories.first(where: {
                  $0.repositoryID == scope.repositoryID
              }) else { return }
        let fileCachePath = repositoryWorkspaces[scope]?.workingDirectory
            ?? attachment.worktreePath
            ?? attachment.worktreeProvisioning?.path
        activeScope = .repository(scope)
        repositoryErrors.removeValue(forKey: scope)
        repositoryRemovalStates[scope] = .removing("Closing terminals")
        updateTaskSidebar()
        installActiveWorkspace()

        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            view.window?.makeFirstResponder(nil)
            if let workspace = repositoryWorkspaces.removeValue(forKey: scope) {
                closeTerminals(in: workspace)
            }
            scheduleSessionSave()
            repositoryRemovalStates[scope] = .removing("Removing worktree and branch")
            updateTaskSidebar()
            installActiveWorkspace()

            if let path = attachment.worktreePath ?? attachment.worktreeProvisioning?.path {
                let repository: RegisteredRepository
                let connection: SSHConnection?
                do {
                    guard let match = try repositoryStore.load().first(where: {
                        $0.id == attachment.repositoryID
                    }) else {
                        throw WorkspaceTaskError.repositoryUnavailable(attachment.name)
                    }
                    repository = match
                    connection = try sshConnection(for: repository)
                } catch {
                    failRepositoryRemoval(scope, message: error.localizedDescription)
                    return
                }
                let errorMessage = await Task.detached { [attachment, path, repository] in
                    do {
                        try RepositoryInspector().removeWorktree(
                            at: path,
                            branchHint: attachment.branch
                                ?? attachment.worktreeProvisioning?.branch,
                            taskID: scope.taskID,
                            from: repository,
                            connection: connection
                        )
                        return nil as String?
                    } catch {
                        return error.localizedDescription
                    }
                }.value
                if let errorMessage {
                    failRepositoryRemoval(scope, message: errorMessage)
                    return
                }
            }

            guard let taskIndex = tasks.firstIndex(where: { $0.id == task.id }) else { return }
            let updatedTask = WorkspaceTask(
                id: task.id,
                title: task.title,
                repositories: tasks[taskIndex].repositories.filter {
                    $0.repositoryID != scope.repositoryID
                },
                createdAt: task.createdAt,
                isPinned: task.isPinned
            )
            var updatedTasks = tasks
            updatedTasks[taskIndex] = updatedTask
            do {
                try taskStore.save(updatedTasks)
            } catch {
                failRepositoryRemoval(scope, message: error.localizedDescription)
                return
            }
            if let fileCachePath {
                rightPanelController.invalidateFileCaches(at: [fileCachePath])
            }
            tasks = updatedTasks
            repositoryRemovalStates.removeValue(forKey: scope)
            repositoryErrors.removeValue(forKey: scope)
            activeScope = .task(task.id)
            updateTaskSidebar()
            scheduleSessionSave()
            installActiveWorkspace()
        }
    }

    private func closeTerminalWorkspaces(for taskID: UUID) {
        view.window?.makeFirstResponder(nil)
        if let workspace = taskWorkspaces.removeValue(forKey: taskID) {
            closeTerminals(in: workspace)
        }
        let repositoryScopes = repositoryWorkspaces.keys.filter { $0.taskID == taskID }
        for scope in repositoryScopes {
            guard let workspace = repositoryWorkspaces.removeValue(forKey: scope) else { continue }
            closeTerminals(in: workspace)
        }
    }

    private func closeTerminals(in workspace: TerminalWorkspace) {
        for tab in workspace.tabs {
            tab.controller.terminateSessions()
            if tab.controller.isViewLoaded {
                tab.controller.view.removeFromSuperview()
            }
            tab.controller.removeFromParent()
        }
        workspace.tabs.removeAll()
        workspace.fileTabs.forEach {
            $0.controller.view.removeFromSuperview()
            $0.controller.removeFromParent()
        }
        workspace.fileTabs.removeAll()
        workspace.activeTabID = nil
    }

    private func failTaskDeletion(_ taskID: UUID, message: String) {
        taskDeletionStates[taskID] = .failed(message)
        taskErrors[taskID] = "Deletion failed"
        updateTaskSidebar()
        if activeTaskID == taskID {
            installActiveWorkspace()
        }
    }

    private func failRepositoryRemoval(_ scope: TaskRepositoryScope, message: String) {
        repositoryRemovalStates[scope] = .failed(message)
        repositoryErrors[scope] = "Detach failed"
        updateTaskSidebar()
        if activeScope == .repository(scope) {
            installActiveWorkspace()
        }
    }

    private func updateWorktreeProvisioning(
        _ report: WorktreeProvisioningReport,
        for scope: TaskRepositoryScope
    ) {
        do {
            try storeWorktreeProvisioning(report, for: scope)
            if let workspace = repositoryWorkspaces.removeValue(forKey: scope) {
                closeTerminals(in: workspace)
            }
            if let failureMessage = report.failureMessage {
                repositoryErrors[scope] = failureMessage
            } else if report.succeeded,
                      let attachment = tasks.first(where: { $0.id == scope.taskID })?.repositories.first(where: {
                          $0.repositoryID == scope.repositoryID
                      }) {
                try installRepositoryWorkspace(
                    for: scope,
                    name: attachment.name,
                    workingDirectory: report.path,
                    target: try terminalTarget(for: registeredRepository(id: scope.repositoryID))
                )
                repositoryErrors.removeValue(forKey: scope)
            } else {
                repositoryErrors.removeValue(forKey: scope)
            }
        } catch {
            repositoryErrors[scope] = error.localizedDescription
        }
        let changedFocus = updateAutomaticProvisioningFocus(for: scope.taskID)
        updateTaskSidebar()
        scheduleSessionSave()
        if changedFocus || activeScope == .repository(scope) {
            installActiveWorkspace()
        }
    }

    private func updateAutomaticProvisioningFocus(for taskID: UUID) -> Bool {
        guard let focusedScope = automaticProvisioningFocus[taskID] else { return false }
        guard activeScope == .repository(focusedScope) else {
            automaticProvisioningFocus.removeValue(forKey: taskID)
            return false
        }
        guard let task = tasks.first(where: { $0.id == taskID }) else {
            automaticProvisioningFocus.removeValue(forKey: taskID)
            return false
        }
        guard let focusedAttachment = task.repositories.first(where: {
            $0.repositoryID == focusedScope.repositoryID
        }) else {
            automaticProvisioningFocus.removeValue(forKey: taskID)
            return false
        }
        if focusedAttachment.worktreePath != nil {
            automaticProvisioningFocus.removeValue(forKey: taskID)
            return false
        }
        guard focusedAttachment.worktreeProvisioning?.failureMessage != nil else { return false }
        guard let successfulAttachment = task.repositories.first(where: {
            $0.worktreePath != nil
        }) else { return false }

        activeScope = .repository(TaskRepositoryScope(
            taskID: taskID,
            repositoryID: successfulAttachment.repositoryID
        ))
        automaticProvisioningFocus.removeValue(forKey: taskID)
        return true
    }

    private func storeWorktreeProvisioning(
        _ report: WorktreeProvisioningReport,
        for scope: TaskRepositoryScope
    ) throws {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == scope.taskID }) else { return }
        let task = tasks[taskIndex]
        var attachments = tasks[taskIndex].repositories
        guard let attachmentIndex = attachments.firstIndex(where: { $0.repositoryID == scope.repositoryID }) else {
            return
        }
        let attachment = attachments[attachmentIndex]
        attachments[attachmentIndex] = TaskRepositoryAttachment(
            repositoryID: attachment.repositoryID,
            name: attachment.name,
            worktreePath: report.succeeded ? report.path : nil,
            worktreeProvisioning: report.succeeded ? nil : report,
            branch: report.succeeded ? report.branch : attachment.branch
        )
        var updatedTasks = tasks
        updatedTasks[taskIndex] = WorkspaceTask(
            id: task.id,
            title: task.title,
            repositories: attachments,
            createdAt: task.createdAt,
            isPinned: task.isPinned
        )
        try taskStore.save(updatedTasks)
        tasks = updatedTasks
    }

    private func selectTask(_ taskID: UUID) {
        guard tasks.contains(where: { $0.id == taskID }) else { return }
        automaticProvisioningFocus.removeValue(forKey: taskID)
        if settingsController != nil { dismissSettings() }
        activeScope = .task(taskID)
        if let task = tasks.first(where: { $0.id == taskID }), !task.repositories.isEmpty {
            expandedTaskIDs.insert(taskID)
        }
        updateTaskSidebar()
        scheduleSessionSave()
        installActiveWorkspace()
    }

    private func selectRepository(_ scope: TaskRepositoryScope) {
        guard
            let task = tasks.first(where: { $0.id == scope.taskID }),
            let attachment = task.repositories.first(where: { $0.repositoryID == scope.repositoryID })
        else { return }
        automaticProvisioningFocus.removeValue(forKey: scope.taskID)
        if settingsController != nil { dismissSettings() }
        activeScope = .repository(scope)
        expandedTaskIDs.insert(scope.taskID)

        if taskDeletionStates[scope.taskID] != nil || repositoryRemovalStates[scope] != nil {
            updateTaskSidebar()
            scheduleSessionSave()
            installActiveWorkspace()
            return
        }

        if let report = attachment.worktreeProvisioning, let failureMessage = report.failureMessage {
            repositoryErrors[scope] = failureMessage
            updateTaskSidebar()
            scheduleSessionSave()
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
                let target = try terminalTarget(for: repository)
                try installRepositoryWorkspace(
                    for: scope,
                    name: attachment.name,
                    workingDirectory: workingDirectory,
                    target: target,
                    startsWithTab: false
                )
                repositoryErrors.removeValue(forKey: scope)
            } catch {
                repositoryErrors[scope] = error.localizedDescription
            }
        }
        updateTaskSidebar()
        scheduleSessionSave()
        installActiveWorkspace()
    }

    private func installRepositoryWorkspace(
        for scope: TaskRepositoryScope,
        name: String,
        workingDirectory: String,
        target: TerminalTarget = .local,
        startsWithTab: Bool = true
    ) throws {
        if case .local = target {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw WorkspaceTaskError.repositoryUnavailable(name)
            }
        }
        repositoryWorkspaces[scope] = TerminalWorkspace(
            runtime: runtime,
            title: "~/\(name)",
            workingDirectory: workingDirectory,
            target: target,
            startsWithTab: startsWithTab
        )
    }

    private func sshConnection(for repository: RegisteredRepository) throws -> SSHConnection? {
        guard case .ssh(let connectionID) = repository.target else { return nil }
        guard let connection = try sshConnectionStore.load().first(where: { $0.id == connectionID }) else {
            throw WorkspaceTaskError.repositoryUnavailable(repository.name)
        }
        guard connection.isEnabled else {
            throw WorkspaceTaskError.repositoryUnavailable(repository.name)
        }
        return connection
    }

    private func terminalTarget(for repository: RegisteredRepository) throws -> TerminalTarget {
        if let connection = try sshConnection(for: repository) {
            return .ssh(connection)
        }
        return .local
    }

    private func registeredRepository(id: UUID) throws -> RegisteredRepository {
        guard let repository = try repositoryStore.load().first(where: { $0.id == id }) else {
            throw WorkspaceTaskError.repositoryUnavailable("repository")
        }
        return repository
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
        scheduleSessionSave()
    }

    private func moveTask(
        _ sourceID: UUID,
        relativeTo targetID: UUID?,
        after: Bool,
        pinned: Bool
    ) {
        let reordered = reorderTasks(
            tasks,
            moving: sourceID,
            relativeTo: targetID,
            after: after,
            inPinnedSection: pinned
        )
        guard reordered != tasks else { return }
        do {
            try taskStore.save(reordered)
            tasks = reordered
            taskErrors.removeValue(forKey: sourceID)
        } catch {
            taskErrors[sourceID] = error.localizedDescription
        }
        updateTaskSidebar()
    }

    private func updateTaskSidebar() {
        sshConnectionStatusMonitor.sync((try? sshConnectionStore.load()) ?? [])
        let registeredRepositories: [UUID: RegisteredRepository]
        do {
            registeredRepositories = try Dictionary(
                uniqueKeysWithValues: repositoryStore.load().map { ($0.id, $0) }
            )
        } catch {
            registeredRepositories = [:]
        }
        let repositoryTargets = registeredRepositories.mapValues(\.target)
        let repositoryPaths = registeredRepositories.mapValues(\.path)
        let repositoryBranches = registeredRepositories.compactMapValues {
            $0.currentBranch ?? $0.defaultBranch
        }
        var displayedRepositoryErrors = repositoryErrors
        for task in tasks {
            for repository in task.repositories {
                guard let failure = repository.worktreeProvisioning?.failureMessage else { continue }
                let scope = TaskRepositoryScope(
                    taskID: task.id,
                    repositoryID: repository.repositoryID
                )
                if displayedRepositoryErrors[scope] == nil {
                    displayedRepositoryErrors[scope] = failure
                }
            }
        }
        var repositoryActivities = repositoryRemovalStates.compactMapValues { state in
            if case .removing = state { "detaching" } else { nil }
        }
        for scope in retryingRepositoryScopes where repositoryActivities[scope] == nil {
            repositoryActivities[scope] = "retrying"
        }
        var taskActivities = taskDeletionStates.compactMapValues { state in
            if case .deleting = state { "deleting" } else { nil }
        }
        for task in tasks where taskActivities[task.id] == nil {
            let repositoryActivityValues = repositoryActivities.compactMap {
                $0.key.taskID == task.id ? $0.value : nil
            }
            if repositoryActivityValues.contains("detaching") {
                taskActivities[task.id] = "detaching"
            } else if repositoryActivityValues.contains("retrying") {
                taskActivities[task.id] = "retrying"
            } else if !expandedTaskIDs.contains(task.id), task.repositories.contains(where: {
                guard let report = $0.worktreeProvisioning else { return false }
                return !report.succeeded && report.failureMessage == nil
            }) {
                taskActivities[task.id] = "attaching"
            }
        }
        leftPanelController.updateTasks(
            tasks,
            selection: activeScope,
            expandedTaskIDs: expandedTaskIDs,
            taskActivities: taskActivities,
            repositoryActivities: repositoryActivities,
            repositoryTargets: repositoryTargets,
            repositoryPaths: repositoryPaths,
            repositoryBranches: repositoryBranches,
            taskErrors: taskErrors,
            repositoryErrors: displayedRepositoryErrors,
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
        let rightPanel = rightPanelController.view
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

        let panelPresented = rightPanelVisible && settingsController == nil
        rightPanel.isHidden = !panelPresented
        if panelPresented {
            rightPanelController.panelDidShow()
        } else {
            rightPanelController.panelDidHide()
        }
        mainColumnTrailingToCard.isActive = !panelPresented
        mainColumnTrailingToPanel.isActive = panelPresented
        workspaceHeader.setPanelVisible(panelPresented)

        leftResizeHandle.setEnabled(docked)
        rightResizeHandle.setEnabled(panelPresented)
        leftPanelController.setToggleActive(docked)
        leftPanelController.setFullScreen(fullScreen)
        updateTrafficLights()
        view.layoutSubtreeIfNeeded()
        leftResizeHandle.refreshInteraction()
        rightResizeHandle.refreshInteraction()
        updateWindowMinimumSize()
    }

    private func revealTransientSidebar() {
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
        scheduleTransientDismissal(after: Self.exitRevealGracePeriod)
    }

    private func scheduleTransientDismissal(after delay: TimeInterval? = nil) {
        guard sidebarPresentation == .transient else { return }
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(attemptTransientDismissal),
            object: nil
        )
        perform(
            #selector(attemptTransientDismissal),
            with: nil,
            afterDelay: delay ?? Self.dismissDelay
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
        if menuTracking
            || taskActionMenu != nil
            || repositoryActionMenu != nil
            || newTaskModal != nil
            || deleteTaskModal != nil
            || NSEvent.pressedMouseButtons != 0
        {
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

    private func cancelScheduledTransitions() {
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

    func persistSession() {
        sessionSaveWorkItem?.cancel()
        sessionSaveWorkItem = nil
        do {
            try sessionStore.save(AppSession(
                activeScope: storedScope(from: activeScope),
                expandedTaskIDs: expandedTaskIDs,
                terminalWorkspaces: storedTerminalWorkspaces
            ))
        } catch {
            NSLog("Could not persist app session: \(error.localizedDescription)")
        }
    }

    private func scheduleSessionSave() {
        sessionSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.persistSession() }
        sessionSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private var storedTerminalWorkspaces: [StoredTerminalWorkspace] {
        let taskSnapshots = taskWorkspaces
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { taskID, workspace in
                workspace.snapshot(for: .task(taskID))
            }
        let repositorySnapshots = repositoryWorkspaces
            .sorted {
                if $0.key.taskID != $1.key.taskID {
                    return $0.key.taskID.uuidString < $1.key.taskID.uuidString
                }
                return $0.key.repositoryID.uuidString < $1.key.repositoryID.uuidString
            }
            .map { scope, workspace in
                workspace.snapshot(for: .repository(
                    taskID: scope.taskID,
                    repositoryID: scope.repositoryID
                ))
            }
        return taskSnapshots + repositorySnapshots
    }

    private func storedScope(from scope: WorkspaceScope?) -> StoredWorkspaceScope? {
        switch scope {
        case .task(let taskID):
            .task(taskID)
        case .repository(let scope):
            .repository(taskID: scope.taskID, repositoryID: scope.repositoryID)
        case nil:
            nil
        }
    }

    private static func workspaceScope(
        from storedScope: StoredWorkspaceScope,
        in tasks: [WorkspaceTask]
    ) -> WorkspaceScope? {
        switch storedScope {
        case .task(let taskID):
            return tasks.contains(where: { $0.id == taskID }) ? .task(taskID) : nil
        case .repository(let taskID, let repositoryID):
            guard tasks.contains(where: {
                $0.id == taskID && $0.repositories.contains(where: { $0.repositoryID == repositoryID })
            }) else {
                return nil
            }
            return .repository(TaskRepositoryScope(taskID: taskID, repositoryID: repositoryID))
        }
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
            if self.taskActionMenu != nil,
               event.window === self.view.window,
               event.keyCode == 53 {
                self.dismissTaskActionMenu()
                return nil
            }
            if self.repositoryActionMenu != nil,
               event.window === self.view.window,
               event.keyCode == 53 {
                self.dismissRepositoryActionMenu()
                return nil
            }
            if self.deleteTaskModal != nil,
               event.window === self.view.window,
               event.keyCode == 53 {
                self.dismissDeleteTaskModal()
                return nil
            }
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
        let buttons = types.compactMap { type in
            window.standardWindowButton(type).map { (type, $0) }
        }
        let visible = fullScreen || sidebarPresentation != .hidden
        buttons.forEach { $0.1.isHidden = !visible }

        guard
            !fullScreen,
            let anchor = window.standardWindowButton(.zoomButton)
        else {
            return
        }
        let baselineY = trafficLightBaselineY ?? anchor.frame.origin.y
        trafficLightBaselineY = baselineY
        let panelOffset = sidebarPresentation == .transient ? AppTheme.workspaceInset : 0
        for (type, button) in buttons {
            let baselineX = trafficLightBaselineX[type] ?? button.frame.origin.x
            trafficLightBaselineX[type] = baselineX
            var frame = button.frame
            frame.origin.x = baselineX + panelOffset
            frame.origin.y = baselineY - AppTheme.trafficLightVerticalOffset - panelOffset
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
        trafficLightBaselineX.removeAll()
        applySidebarPresentation()
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        dismissTaskActionMenu()
        dismissRepositoryActionMenu()
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
        let minimumWidth = max(
            AppTheme.minimumWindowWidth,
            WorkspacePanelLayout.minimumWindowWidth(
                leftPanelVisible: sidebarPresentation == .docked,
                rightPanelVisible: rightPanelVisible && settingsController == nil,
                leftPanelWidth: leftPanelWidth,
                rightPanelWidth: rightPanelWidth
            )
        )
        workspaceMinimumWidthConstraint.constant = minimumWidth
        window.minSize = NSSize(
            width: minimumWidth,
            height: AppTheme.minimumWindowHeight
        )
        if window.contentView?.bounds.width ?? 0 < minimumWidth {
            window.setContentSize(
                NSSize(
                    width: minimumWidth,
                    height: window.contentView?.bounds.height ?? AppTheme.minimumWindowHeight
                )
            )
        }
    }

    private func resizeLeftPanel(by delta: CGFloat) {
        guard sidebarPresentation == .docked else { return }
        let maximumFromWindow = (leftResizeWindowWidth ?? view.bounds.width)
            - AppTheme.minimumCenterWidth
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

    private func resizeRightPanel(by delta: CGFloat) {
        guard rightPanelVisible, settingsController == nil else { return }
        rightPanelWidth = min(
            max(rightWidthConstraint.constant + delta, AppTheme.rightPanelRange.lowerBound),
            AppTheme.rightPanelRange.upperBound
        )
        rightWidthConstraint.constant = rightPanelWidth
        UserDefaults.standard.set(Double(rightPanelWidth), forKey: Self.rightPanelWidthDefaultsKey)
        view.layoutSubtreeIfNeeded()
        updateWindowMinimumSize()
    }

    private func resizeRightPanel(with command: PanelResizeHandle.KeyboardCommand) {
        switch command {
        case .decrease:
            resizeRightPanel(by: -AppTheme.keyboardResizeStep)
        case .increase:
            resizeRightPanel(by: AppTheme.keyboardResizeStep)
        case .minimum:
            resizeRightPanel(by: -AppTheme.rightPanelRange.upperBound)
        case .maximum:
            resizeRightPanel(by: AppTheme.rightPanelRange.upperBound)
        }
    }

}

@MainActor
private final class FileEditorViewController: NSViewController, NSTextViewDelegate {
    var onStateChange: (() -> Void)?

    private let path: String
    private let target: TerminalTarget
    private let scrollView = NSScrollView()
    private let textView = FileTextView()
    private let loadingView = NSStackView()
    private let loadingIndicator = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "")
    private lazy var syntaxHighlighter = SyntaxHighlighter(path: path)
    private var isLoading = true
    private var isDirty = false
    var hasUnsavedChanges: Bool { isDirty }

    init(path: String, target: TerminalTarget) {
        self.path = path
        self.target = target
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.borderType = .noBorder
        textView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isRichText = false
        textView.usesFindPanel = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .monospacedSystemFont(
            ofSize: CGFloat(UserSettingsStore().load().editorFontSize.points),
            weight: .regular
        )
        textView.delegate = self
        textView.onSave = { [weak self] in self?.save() }
        scrollView.documentView = textView
        root.addSubview(scrollView)
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        loadingView.orientation = .vertical
        loadingView.alignment = .centerX
        loadingView.spacing = 8
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.startAnimation(nil)
        loadingLabel.stringValue = "Loading \(URL(fileURLWithPath: path).lastPathComponent)…"
        loadingView.addArrangedSubview(loadingIndicator)
        loadingView.addArrangedSubview(loadingLabel)
        root.addSubview(loadingView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            loadingView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
        applyTheme()
        Task { [path, target] in
            do {
                let content = try await Task.detached { try FileEditorStore.read(path: path, target: target) }.value
                textView.string = content
                syntaxHighlighter.apply(to: textView)
                textView.isEditable = true
            } catch {
                textView.string = "Could not open file:\n\n\(error.localizedDescription)"
                textView.isEditable = false
            }
            isLoading = false
            loadingIndicator.stopAnimation(nil)
            loadingView.isHidden = true
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentView.bounds.width
        guard width > 0, textView.frame.width != width else { return }
        textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
    }

    func textDidChange(_ notification: Notification) {
        syntaxHighlighter.schedule(in: textView)
        guard !isLoading, !isDirty else { return }
        isDirty = true
        onStateChange?()
    }

    func applyTheme() {
        let settings = UserSettingsStore().load()
        let palette = EditorSyntaxPalette.pinata(appTheme: settings.theme)
        textView.font = .monospacedSystemFont(
            ofSize: CGFloat(settings.editorFontSize.points),
            weight: .regular
        )
        view.layer?.backgroundColor = AppTheme.background.cgColor
        scrollView.backgroundColor = palette.backgroundColor
        textView.backgroundColor = palette.backgroundColor
        textView.textColor = palette.foregroundColor
        textView.insertionPointColor = palette.foregroundColor
        loadingLabel.font = AppTheme.font(ofSize: AppTheme.typography.body, weight: 500)
        loadingLabel.textColor = AppTheme.tertiaryText
        syntaxHighlighter.apply(to: textView)
    }

    private func save() {
        guard !isLoading else { return }
        let value = textView.string
        textView.isEditable = false
        Task { [path, target] in
            do {
                try await Task.detached { try FileEditorStore.write(value, path: path, target: target) }.value
                isDirty = false
                onStateChange?()
            } catch {
                NSSound.beep()
            }
            textView.isEditable = true
        }
    }
}

private final class FileTextView: NSTextView {
    var onSave: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "s" {
            onSave?()
            return
        }
        super.keyDown(with: event)
    }
}

private enum FileEditorStore {
    private static let maximumBytes = 4 * 1024 * 1024

    static func read(path: String, target: TerminalTarget) throws -> String {
        let data: Data
        switch target {
        case .local:
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        case .ssh(let connection):
            data = try run(connection: connection, script: "cat -- \(SSHCommand.shellQuote(path))")
        }
        guard data.count <= maximumBytes else { throw FileTreeInspectionError.failed("File is larger than 4 MB.") }
        guard !data.contains(0), let value = String(data: data, encoding: .utf8) else {
            throw FileTreeInspectionError.failed("Only UTF-8 text files are supported.")
        }
        return value
    }

    static func write(_ value: String, path: String, target: TerminalTarget) throws {
        let data = Data(value.utf8)
        switch target {
        case .local:
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        case .ssh(let connection):
            let temp = "\(path).pinata-\(UUID().uuidString)"
            _ = try run(connection: connection, script: "cat > \(SSHCommand.shellQuote(temp)) && mv \(SSHCommand.shellQuote(temp)) \(SSHCommand.shellQuote(path))", input: data)
        }
    }

    private static func run(connection: SSHConnection, script: String, input: Data? = nil) throws -> Data {
        let fileManager = FileManager.default
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("pinata-editor-\(UUID().uuidString).out")
        let errorURL = fileManager.temporaryDirectory
            .appendingPathComponent("pinata-editor-\(UUID().uuidString).err")
        defer {
            try? fileManager.removeItem(at: outputURL)
            try? fileManager.removeItem(at: errorURL)
        }
        guard fileManager.createFile(atPath: outputURL.path, contents: nil),
              fileManager.createFile(atPath: errorURL.path, contents: nil) else {
            throw FileTreeInspectionError.failed("Could not prepare file editor.")
        }
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer {
            try? output.close()
            try? error.close()
        }
        let process = SSHCommand.makeProcess(connection: connection, command: ["sh", "-lc", script])
        process.standardOutput = output
        process.standardError = error
        if let input {
            let pipe = Pipe()
            process.standardInput = pipe
            try process.run()
            pipe.fileHandleForWriting.write(input)
            try pipe.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        process.waitUntilExit()
        try output.synchronize()
        try error.synchronize()
        let errorText = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw FileTreeInspectionError.failed(errorText.isEmpty ? "Could not update remote file." : errorText)
        }
        return try Data(contentsOf: outputURL)
    }
}

@MainActor
private final class WorktreeProvisioningView: NSView, SettingsThemeApplying {
    var onRetry: (() -> Void)?

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
        repositoryLabel.textColor = report.failureMessage == nil
            ? AppTheme.primaryText
            : AppTheme.error
        detailLabel.textColor = AppTheme.error
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
            content.setCustomSpacing(24, after: detailLabel)
            let retryButton = WorkspaceEmptyActionButton(
                title: "Retry",
                symbolName: "arrow.clockwise"
            )
            retryButton.target = self
            retryButton.action = #selector(retry(_:))
            content.addArrangedSubview(retryButton)
        }
    }

    @objc private func retry(_ sender: AppButton) {
        sender.isEnabled = false
        onRetry?()
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
        titleLabel.textColor = step.status == .failed ? AppTheme.error : AppTheme.secondaryText
        statusIcon.contentTintColor = step.status == .failed ? AppTheme.error : AppTheme.success
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
        case deletingTask(title: String, step: String)
        case deletionFailed(title: String, detail: String)
        case removingRepository(title: String, step: String)
        case repositoryRemovalFailed(title: String, detail: String)
        case error(title: String, detail: String)
    }

    private enum Action {
        case createTask
        case createTerminal
        case retryDeletion
        case retryDetach
    }

    var onCreateTask: (() -> Void)?
    var onCreateTerminal: (() -> Void)?
    var onRetryDeletion: (() -> Void)?

    init(state: State) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 14

        let artwork: WorkspaceEmptyArtworkView
        let title: String
        let detail: String
        let action: Action?
        let showsProgress: Bool
        switch state {
        case .chooseTask:
            artwork = WorkspaceEmptyArtworkView(kind: .chooseTask)
            title = "Pick a task, make a little magic."
            detail = "Your workspace is waiting. Choose a task from the sidebar to wake it up."
            action = .createTask
            showsProgress = false
        case .readyToStart:
            artwork = WorkspaceEmptyArtworkView(kind: .terminal)
            title = "This task is ready for takeoff."
            detail = "Open its first terminal and make a little productive noise."
            action = .createTerminal
            showsProgress = false
        case let .deletingTask(taskTitle, step):
            artwork = WorkspaceEmptyArtworkView(kind: .worktree)
            title = "Deleting \(taskTitle) task"
            detail = step
            action = nil
            showsProgress = true
        case let .deletionFailed(taskTitle, failureDetail):
            artwork = WorkspaceEmptyArtworkView(kind: .error)
            title = "Could not delete \(taskTitle) task"
            detail = failureDetail
            action = .retryDeletion
            showsProgress = false
        case let .removingRepository(repositoryTitle, step):
            artwork = WorkspaceEmptyArtworkView(kind: .worktree)
            title = "Detaching \(repositoryTitle) from task"
            detail = step
            action = nil
            showsProgress = true
        case let .repositoryRemovalFailed(repositoryTitle, failureDetail):
            artwork = WorkspaceEmptyArtworkView(kind: .error)
            title = "Could not detach \(repositoryTitle) from task"
            detail = failureDetail
            action = .retryDetach
            showsProgress = false
        case let .error(title: errorTitle, detail: errorDetail):
            artwork = WorkspaceEmptyArtworkView(kind: .error)
            title = errorTitle
            detail = errorDetail
            action = nil
            showsProgress = false
        }

        artwork.translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(artwork)
        artwork.widthAnchor.constraint(equalToConstant: 184).isActive = true
        artwork.heightAnchor.constraint(equalToConstant: 122).isActive = true
        setCustomSpacing(18, after: artwork)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.title, weight: 650)
        titleLabel.textColor = state.isError ? AppTheme.error : AppTheme.primaryText
        addArrangedSubview(titleLabel)
        setCustomSpacing(12, after: titleLabel)

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = AppTheme.font(ofSize: AppTheme.typography.body)
        detailLabel.textColor = AppTheme.tertiaryText
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 0
        addArrangedSubview(detailLabel)
        detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true

        if showsProgress {
            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.controlSize = .small
            progress.startAnimation(nil)
            addArrangedSubview(progress)
            setCustomSpacing(20, after: detailLabel)
        }

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
            case .retryDeletion:
                button = WorkspaceEmptyActionButton(
                    title: "Retry deletion",
                    symbolName: "arrow.clockwise"
                )
                button.action = #selector(retryDeletion)
            case .retryDetach:
                button = WorkspaceEmptyActionButton(
                    title: "Retry detach",
                    symbolName: "arrow.clockwise"
                )
                button.action = #selector(retryDeletion)
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

    @objc private func retryDeletion() {
        onRetryDeletion?()
    }
}

private extension WorkspaceEmptyStateView.State {
    var isError: Bool {
        switch self {
        case .error, .deletionFailed, .repositoryRemovalFailed: true
        default: false
        }
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
        let color = kind == .error ? AppTheme.error : AppTheme.panelAccentIcon
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
        color.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: rect.midX - 2, y: rect.minY + 42, width: 4, height: 18),
            xRadius: 2,
            yRadius: 2
        ).fill()
        NSBezierPath(
            ovalIn: NSRect(x: rect.midX - 3, y: rect.minY + 33, width: 6, height: 6)
        ).fill()
    }

}

@MainActor
private final class WorkspaceTrackingView: NSView {
    var onExitLeft: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseExited(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard location.x <= bounds.minX else { return }
        onExitLeft?()
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
    private let indicatorOffset: CGFloat
    private var enabled = true
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    override var acceptsFirstResponder: Bool { enabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { enabled }

    init(indicatorOffset: CGFloat = 0) {
        self.indicatorOffset = indicatorOffset
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize panel")

        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.cornerRadius = AppTheme.resizeIndicatorCornerRadius
        addSubview(line)
        NSLayoutConstraint.activate([
            line.centerXAnchor.constraint(
                equalTo: centerXAnchor,
                constant: indicatorOffset
            ),
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

    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        onDragBegan?()
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard enabled else { return }
        onDrag?(event.deltaX)
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
        refreshInteraction()
    }

    func refreshInteraction() {
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
