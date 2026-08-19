import AppKit
import CoreServices

private extension NSPasteboard.PasteboardType {
    static let sidebarTaskID = Self("io.pinata.sidebar-task-id")
}

@MainActor
private final class SidebarTaskStackView: NSStackView {
    var onMoveTask: ((UUID, UUID?, Bool, Bool) -> Void)?

    private struct DropTarget {
        let sourceID: UUID
        let relativeTaskID: UUID?
        let sectionPinned: Bool
        let after: Bool
        let edge: CGFloat
    }

    private let insertionLayer = CALayer()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        insertionLayer.cornerRadius = 1
        registerForDraggedTypes([.sidebarTaskID])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDropTarget(sender)?.operation ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDropTarget(sender)?.operation ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        clearInsertionIndicator()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        clearInsertionIndicator()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { clearInsertionIndicator() }
        guard let target = dropTarget(sender) else { return false }
        onMoveTask?(
            target.sourceID,
            target.relativeTaskID,
            target.after,
            target.sectionPinned
        )
        return true
    }

    private func updateDropTarget(
        _ sender: any NSDraggingInfo
    ) -> (operation: NSDragOperation, target: DropTarget)? {
        guard let target = dropTarget(sender) else {
            clearInsertionIndicator()
            return nil
        }
        if let source = arrangedSubviews
            .compactMap({ $0 as? SidebarTaskGroupView })
            .first(where: { $0.taskID == target.sourceID })
        {
            updateDraggingImage(sender, source: source)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        insertionLayer.backgroundColor = AppTheme.panelAccentIcon.withAlphaComponent(0.55).cgColor
        insertionLayer.frame = NSRect(
            x: 0,
            y: target.edge - 1,
            width: bounds.width,
            height: 2
        )
        if insertionLayer.superlayer == nil {
            layer?.addSublayer(insertionLayer)
        }
        return (.move, target)
    }

    private func clearInsertionIndicator() {
        insertionLayer.removeFromSuperlayer()
    }

    private func updateDraggingImage(
        _ sender: any NSDraggingInfo,
        source: SidebarTaskGroupView
    ) {
        let point = convert(sender.draggingLocation, from: nil)
        let size = source.dragPreviewSize
        let frame = NSRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        sender.enumerateDraggingItems(
            options: [],
            for: self,
            classes: [NSPasteboardItem.self],
            searchOptions: [:]
        ) { item, _, stop in
            item.setDraggingFrame(frame, contents: source.dragPreviewImage())
            stop.pointee = true
        }
    }

    private func dropTarget(
        _ sender: any NSDraggingInfo
    ) -> DropTarget? {
        guard
            let value = sender.draggingPasteboard.string(forType: .sidebarTaskID),
            let sourceID = UUID(uuidString: value)
        else { return nil }
        let tasks = arrangedSubviews.compactMap { $0 as? SidebarTaskGroupView }
        guard tasks.contains(where: { $0.taskID == sourceID }) else { return nil }
        let point = convert(sender.draggingLocation, from: nil)
        if let target = tasks.first(where: {
            $0.frame.insetBy(dx: 0, dy: -3).contains(point)
        }) {
            let after = isFlipped ? point.y > target.frame.midY : point.y < target.frame.midY
            let edge = after
                ? (isFlipped ? target.frame.maxY : target.frame.minY)
                : (isFlipped ? target.frame.minY : target.frame.maxY)
            return DropTarget(
                sourceID: sourceID,
                relativeTaskID: target.taskID,
                sectionPinned: target.isPinned,
                after: after,
                edge: edge
            )
        }
        guard let header = arrangedSubviews
            .compactMap({ $0 as? SidebarSectionHeaderView })
            .first(where: { $0.frame.insetBy(dx: 0, dy: -6).contains(point) })
        else { return nil }
        return DropTarget(
            sourceID: sourceID,
            relativeTaskID: nil,
            sectionPinned: header.isPinnedSection,
            after: false,
            edge: isFlipped ? header.frame.maxY : header.frame.minY
        )
    }
}

@MainActor
final class PanelViewController: NSViewController {
    var onTogglePanel: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onCreateTask: (() -> Void)?
    var onSelectTask: ((UUID) -> Void)?
    var onSelectRepository: ((TaskRepositoryScope) -> Void)?
    var onToggleTaskExpansion: ((UUID) -> Void)?
    var onSidebarTaskHover: ((UUID) -> Void)?
    var onSidebarRepositoryHover: ((TaskRepositoryScope) -> Void)?
    var onShowTaskMenu: ((UUID, NSRect) -> Void)?
    var onShowRepositoryMenu: ((TaskRepositoryScope, NSRect) -> Void)?
    var onMoveTask: ((UUID, UUID?, Bool, Bool) -> Void)?

    private weak var trackingRoot: PanelTrackingView?
    private weak var leftHeader: LeftSidebarHeaderView?
    private weak var brandView: SidebarBrandView?
    private let connectionStatusMonitor: SSHConnectionStatusMonitor
    private let newTaskButton = SidebarNewTaskButton(frame: .zero)
    private let taskScrollView = NSScrollView()
    private let taskDocument = NSView()
    private let taskStack = SidebarTaskStackView()
    private var taskMenuTaskID: UUID?
    private var repositoryMenuScope: TaskRepositoryScope?

    init(connectionStatusMonitor: SSHConnectionStatusMonitor) {
        self.connectionStatusMonitor = connectionStatusMonitor
        super.init(nibName: nil, bundle: nil)
        connectionStatusMonitor.addObserver { [weak self] in
            self?.refreshConnectionStatuses()
        }
    }

    convenience init() {
        self.init(connectionStatusMonitor: SSHConnectionStatusMonitor())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let rootView = PanelTrackingView()
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        rootView.setAccessibilityRole(.group)
        rootView.setAccessibilityLabel("Tasks")
        rootView.onHoverChanged = { [weak self] hovering in
            self?.onHoverChanged?(hovering)
        }
        trackingRoot = rootView
        view = rootView

        installLeftPanel()
    }

    func setToggleActive(_ active: Bool) {
        leftHeader?.setPanelActive(active)
    }

    func setFullScreen(_ fullScreen: Bool) {
        leftHeader?.setFullScreen(fullScreen)
    }

    func applyTheme() {
        view.layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        leftHeader?.applyTheme()
        brandView?.applyTheme()
        newTaskButton.applyTheme()
        taskStack.arrangedSubviews
            .compactMap { $0 as? SidebarSectionHeaderView }
            .forEach { $0.applyTheme() }
        taskStack.arrangedSubviews
            .compactMap { $0 as? SidebarTaskGroupView }
            .forEach { $0.applyTheme() }
        taskStack.arrangedSubviews
            .compactMap { $0 as? SidebarMessageView }
            .forEach { $0.applyTheme() }
    }

    func updateTasks(
        _ tasks: [WorkspaceTask],
        selection: WorkspaceScope?,
        expandedTaskIDs: Set<UUID>,
        taskActivities: [UUID: String] = [:],
        repositoryActivities: [TaskRepositoryScope: String] = [:],
        repositoryTargets: [UUID: RepositoryTarget] = [:],
        repositoryPaths: [UUID: String] = [:],
        repositoryBranches: [UUID: String] = [:],
        repositoryRemoteURLs: [UUID: String] = [:],
        pullRequestStatuses: [UUID: PullRequestRepositoryStatus] = [:],
        taskErrors: [UUID: String],
        repositoryErrors: [TaskRepositoryScope: String],
        loadError: String?
    ) {
        guard isViewLoaded else { return }
        taskStack.arrangedSubviews.forEach {
            taskStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        func addHeader(_ title: String, isPinnedSection: Bool) -> SidebarSectionHeaderView {
            let header = SidebarSectionHeaderView(
                title: title,
                isPinnedSection: isPinnedSection
            )
            taskStack.addView(header, in: .top)
            header.widthAnchor.constraint(equalTo: taskStack.widthAnchor).isActive = true
            taskStack.setCustomSpacing(AppTheme.sidebarTaskListTopSpacing, after: header)
            return header
        }

        func addTask(_ task: WorkspaceTask) {
            let group = SidebarTaskGroupView(
                task: task,
                selection: selection,
                expanded: expandedTaskIDs.contains(task.id),
                menuActive: taskMenuTaskID == task.id,
                activity: taskActivities[task.id],
                taskError: taskErrors[task.id],
                repositoryMenuScope: repositoryMenuScope,
                repositoryActivities: repositoryActivities,
                repositoryErrors: repositoryErrors,
                repositoryTargets: repositoryTargets,
                repositoryPaths: repositoryPaths,
                repositoryBranches: repositoryBranches,
                repositoryRemoteURLs: repositoryRemoteURLs,
                pullRequestStatuses: pullRequestStatuses,
                connectionStatusMonitor: connectionStatusMonitor
            )
            group.onSelectTask = { [weak self] in self?.onSelectTask?(task.id) }
            group.onToggleExpansion = { [weak self] in
                self?.onToggleTaskExpansion?(task.id)
            }
            group.onHoverTask = { [weak self] in
                self?.onSidebarTaskHover?(task.id)
            }
            group.onSelectRepository = { [weak self] repositoryID in
                self?.onSelectRepository?(
                    TaskRepositoryScope(taskID: task.id, repositoryID: repositoryID)
                )
            }
            group.onHoverRepository = { [weak self] repositoryID in
                self?.onSidebarRepositoryHover?(
                    TaskRepositoryScope(taskID: task.id, repositoryID: repositoryID)
                )
            }
            group.onShowMenu = { [weak self] anchorRect in
                self?.onShowTaskMenu?(task.id, anchorRect)
            }
            group.onShowRepositoryMenu = { [weak self] repositoryID, anchorRect in
                self?.onShowRepositoryMenu?(
                    TaskRepositoryScope(taskID: task.id, repositoryID: repositoryID),
                    anchorRect
                )
            }
            taskStack.addView(group, in: .top)
            group.widthAnchor.constraint(equalTo: taskStack.widthAnchor).isActive = true
        }

        func addMessage(_ message: String, error: Bool) -> SidebarMessageView {
            let view = SidebarMessageView(message, error: error)
            taskStack.addView(view, in: .top)
            view.widthAnchor.constraint(equalTo: taskStack.widthAnchor).isActive = true
            return view
        }

        let pinnedTasks = tasks.filter(\.isPinned)
        let pinnedHeader = addHeader("PINNED", isPinnedSection: true)
        if pinnedTasks.isEmpty {
            _ = addMessage("No pinned tasks yet.", error: false)
        } else {
            pinnedTasks.forEach(addTask)
        }
        taskStack.setCustomSpacing(
            AppTheme.sidebarSectionSpacing,
            after: taskStack.arrangedSubviews.last ?? pinnedHeader
        )

        _ = addHeader("TASKS", isPinnedSection: false)
        if let loadError {
            _ = addMessage(loadError, error: true)
        }
        if tasks.isEmpty, loadError == nil {
            _ = addMessage("No tasks yet.", error: false)
        } else {
            tasks.filter { !$0.isPinned }.forEach(addTask)
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        taskStack.addView(spacer, in: .top)
        spacer.widthAnchor.constraint(equalTo: taskStack.widthAnchor).isActive = true
        applyTheme()
    }

    func updatePullRequestStatuses(_ statuses: [UUID: PullRequestRepositoryStatus]) {
        guard isViewLoaded else { return }
        taskStack.arrangedSubviews
            .compactMap { $0 as? SidebarTaskGroupView }
            .forEach { $0.updatePullRequestStatuses(statuses) }
    }

    func setTaskMenuTask(_ taskID: UUID?) {
        taskMenuTaskID = taskID
        taskStack.arrangedSubviews
            .compactMap { $0 as? SidebarTaskGroupView }
            .forEach { $0.setMenuActive($0.taskID == taskID) }
    }

    func setRepositoryMenuScope(_ scope: TaskRepositoryScope?) {
        repositoryMenuScope = scope
        taskStack.arrangedSubviews
            .compactMap { $0 as? SidebarTaskGroupView }
            .forEach { $0.setRepositoryMenuActive(scope) }
    }

    private func refreshConnectionStatuses() {
        guard isViewLoaded else { return }
        taskStack.arrangedSubviews
            .compactMap { $0 as? SidebarTaskGroupView }
            .forEach { $0.refreshConnectionStatuses() }
    }

    private func installLeftPanel() {
        let topHeader = LeftSidebarHeaderView()
        let brand = SidebarBrandView()
        let scrollView = taskScrollView
        topHeader.onToggle = { [weak self] in self?.onTogglePanel?() }
        newTaskButton.onCreate = { [weak self] in self?.onCreateTask?() }

        topHeader.translatesAutoresizingMaskIntoConstraints = false
        brand.translatesAutoresizingMaskIntoConstraints = false
        newTaskButton.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        taskDocument.translatesAutoresizingMaskIntoConstraints = false
        taskStack.translatesAutoresizingMaskIntoConstraints = false
        taskStack.orientation = .vertical
        taskStack.alignment = .leading
        taskStack.distribution = .fill
        taskStack.spacing = 2
        taskStack.onMoveTask = { [weak self] sourceID, targetID, after, pinned in
            self?.onMoveTask?(sourceID, targetID, after, pinned)
        }
        taskDocument.addSubview(taskStack)
        scrollView.documentView = taskDocument
        view.addSubview(topHeader)
        view.addSubview(brand)
        view.addSubview(newTaskButton)
        view.addSubview(scrollView)

        leftHeader = topHeader
        brandView = brand
        NSLayoutConstraint.activate([
            topHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topHeader.topAnchor.constraint(equalTo: view.topAnchor),
            topHeader.heightAnchor.constraint(equalToConstant: AppTheme.workspaceHeaderHeight),

            brand.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: AppTheme.panelContentInset),
            brand.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -AppTheme.panelContentInset),
            brand.topAnchor.constraint(
                equalTo: topHeader.bottomAnchor,
                constant: AppTheme.panelContentInset
            ),

            newTaskButton.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: AppTheme.sidebarItemInset
            ),
            newTaskButton.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -AppTheme.sidebarItemInset
            ),
            newTaskButton.topAnchor.constraint(
                equalTo: brand.bottomAnchor,
                constant: AppTheme.sidebarNewTaskTopSpacing
            ),
            newTaskButton.heightAnchor.constraint(equalToConstant: AppTheme.sidebarNewTaskHeight),

            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(
                equalTo: newTaskButton.bottomAnchor,
                constant: AppTheme.sidebarNewTaskBottomSpacing
            ),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            taskDocument.leadingAnchor.constraint(
                equalTo: scrollView.contentView.leadingAnchor,
            ),
            taskDocument.trailingAnchor.constraint(
                equalTo: scrollView.contentView.trailingAnchor,
            ),
            taskDocument.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            taskDocument.bottomAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentView.bottomAnchor
            ),
            taskStack.leadingAnchor.constraint(
                equalTo: taskDocument.leadingAnchor,
                constant: AppTheme.sidebarItemInset
            ),
            taskStack.trailingAnchor.constraint(
                equalTo: taskDocument.trailingAnchor,
                constant: -AppTheme.sidebarItemInset
            ),
            taskStack.topAnchor.constraint(equalTo: taskDocument.topAnchor),
            taskStack.bottomAnchor.constraint(greaterThanOrEqualTo: taskDocument.bottomAnchor),
        ])
    }
}

@MainActor
private final class SidebarNewTaskButton: AppButton {
    var onCreate: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        role = .accent
        layer?.cornerRadius = AppTheme.workspaceControlCornerRadius
        layer?.cornerCurve = .continuous
        image = nil
        title = ""
        target = self
        action = #selector(create)
        setAccessibilityLabel("New task")
        toolTip = "New task"
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func applyTheme() {
        super.applyTheme()
        font = AppTheme.font(ofSize: AppTheme.typography.body, weight: 600)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let title = NSAttributedString(
            string: "New task",
            attributes: [
                .font: AppTheme.font(ofSize: AppTheme.typography.body, weight: 600),
                .foregroundColor: contentTintColor ?? AppTheme.panelAccentIcon,
            ]
        )
        let plus = NSAttributedString(
            string: "+",
            attributes: [
                .font: AppTheme.font(ofSize: AppTheme.sidebarNewTaskIconSize, weight: 500),
                .foregroundColor: contentTintColor ?? AppTheme.panelAccentIcon,
            ]
        )
        let titleSize = title.size()
        let plusSize = plus.size()
        let contentGap = AppTheme.workspaceTabSpacing
        let contentWidth = plusSize.width + contentGap + titleSize.width
        let leadingInset = floor((bounds.width - contentWidth) / 2)
        plus.draw(
            at: NSPoint(
                x: leadingInset,
                y: floor((bounds.height - plusSize.height) / 2)
            )
        )
        title.draw(
            at: NSPoint(
                x: leadingInset + plusSize.width + contentGap,
                y: floor((bounds.height - titleSize.height) / 2)
            )
        )
    }

    @objc private func create() {
        onCreate?()
    }
}

@MainActor
private struct SidebarRepositoryContext {
    let repositoryID: UUID
    let name: String
    let remoteURL: String?
    let branch: String?
    let path: String?
    let target: RepositoryTarget
    let connectionID: UUID?
    let connectionName: String?
    var status: SSHConnectionStatus
    var pullRequestStatus: PullRequestRepositoryStatus

    var pullRequests: [PullRequestSummary] {
        pullRequestStatus.related(to: branch)
    }
}

@MainActor
private final class SidebarTaskGroupView: NSStackView {
    var onSelectTask: (() -> Void)?
    var onToggleExpansion: (() -> Void)?
    var onHoverTask: (() -> Void)?
    var onSelectRepository: ((UUID) -> Void)?
    var onHoverRepository: ((UUID) -> Void)?
    var onShowMenu: ((NSRect) -> Void)?
    var onShowRepositoryMenu: ((UUID, NSRect) -> Void)?

    let taskID: UUID
    let isPinned: Bool
    private let taskRow: SidebarTaskRow
    private var repositoryRows: [SidebarRepositoryRow] = []

    init(
        task: WorkspaceTask,
        selection: WorkspaceScope?,
        expanded: Bool,
        menuActive: Bool,
        activity: String?,
        taskError: String?,
        repositoryMenuScope: TaskRepositoryScope?,
        repositoryActivities: [TaskRepositoryScope: String],
        repositoryErrors: [TaskRepositoryScope: String],
        repositoryTargets: [UUID: RepositoryTarget],
        repositoryPaths: [UUID: String],
        repositoryBranches: [UUID: String],
        repositoryRemoteURLs: [UUID: String],
        pullRequestStatuses: [UUID: PullRequestRepositoryStatus],
        connectionStatusMonitor: SSHConnectionStatusMonitor
    ) {
        taskID = task.id
        isPinned = task.isPinned
        let repositoryContexts = task.repositories.sorted(by: {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }).map { repository in
            let target = repositoryTargets[repository.repositoryID] ?? .local
            let connectionID: UUID?
            if case .ssh(let id) = target {
                connectionID = id
            } else {
                connectionID = nil
            }
            return SidebarRepositoryContext(
                repositoryID: repository.repositoryID,
                name: repository.name,
                remoteURL: repositoryRemoteURLs[repository.repositoryID],
                branch: repository.branch
                    ?? repository.worktreeProvisioning?.branch
                    ?? repositoryBranches[repository.repositoryID],
                path: repository.worktreePath
                    ?? repository.worktreeProvisioning?.path
                    ?? repositoryPaths[repository.repositoryID],
                target: target,
                connectionID: connectionID,
                connectionName: connectionID.flatMap { connectionStatusMonitor.name(for: $0) },
                status: connectionID.map { connectionStatusMonitor.status(for: $0) } ?? .disabled,
                pullRequestStatus: pullRequestStatuses[repository.repositoryID] ?? .idle
            )
        }
        let collapsedRepositoryError = expanded ? nil : task.repositories.lazy.compactMap {
            repositoryErrors[TaskRepositoryScope(
                taskID: task.id,
                repositoryID: $0.repositoryID
            )]
        }.first
        taskRow = SidebarTaskRow(
            taskID: task.id,
            title: task.title,
            hasRepositories: !task.repositories.isEmpty,
            expanded: expanded,
            selected: selection == .task(task.id),
            menuActive: menuActive,
            activity: activity,
            error: taskError ?? collapsedRepositoryError,
            repositoryContexts: repositoryContexts,
            connectionStatusMonitor: connectionStatusMonitor,
            createdAt: task.createdAt
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .vertical
        alignment = .leading
        spacing = 2
        addArrangedSubview(taskRow)
        taskRow.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        taskRow.onSelect = { [weak self] in self?.onSelectTask?() }
        taskRow.onToggleExpansion = { [weak self] in self?.onToggleExpansion?() }
        taskRow.onHover = { [weak self] in self?.onHoverTask?() }
        taskRow.onShowMenu = { [weak self] in self?.onShowMenu?($0) }

        if expanded {
            for repository in task.repositories.sorted(by: {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }) {
                let scope = TaskRepositoryScope(taskID: task.id, repositoryID: repository.repositoryID)
                let context = repositoryContexts.first { $0.repositoryID == repository.repositoryID }
                let row = SidebarRepositoryRow(
                    repository: repository,
                    selected: selection == .repository(scope),
                    menuActive: repositoryMenuScope == scope,
                    activity: repositoryActivities[scope] ?? (repository.worktreeProvisioning.map {
                        !$0.succeeded && $0.failureMessage == nil
                    } == true ? "creating" : nil),
                    error: repositoryErrors[scope],
                    context: context,
                    suppressActions: activity == "deleting",
                    connectionStatusMonitor: connectionStatusMonitor
                )
                row.onSelect = { [weak self] in
                    self?.onSelectRepository?(repository.repositoryID)
                }
                row.onHover = { [weak self] in
                    self?.onHoverRepository?(repository.repositoryID)
                }
                row.onShowMenu = { [weak self] anchorRect in
                    self?.onShowRepositoryMenu?(repository.repositoryID, anchorRect)
                }
                addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
                repositoryRows.append(row)
            }
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        taskRow.applyTheme()
        repositoryRows.forEach { $0.applyTheme() }
    }

    func setMenuActive(_ active: Bool) {
        taskRow.setMenuActive(active)
    }

    func setRepositoryMenuActive(_ scope: TaskRepositoryScope?) {
        repositoryRows.forEach { row in
            row.setMenuActive(
                scope?.taskID == taskID && scope?.repositoryID == row.repositoryID
            )
        }
    }

    func refreshConnectionStatuses() {
        taskRow.refreshConnectionStatuses()
        repositoryRows.forEach { $0.refreshConnectionStatus() }
    }

    func updatePullRequestStatuses(_ statuses: [UUID: PullRequestRepositoryStatus]) {
        taskRow.updatePullRequestStatuses(statuses)
        repositoryRows.forEach { row in
            guard let status = statuses[row.repositoryID] else { return }
            row.updatePullRequestStatus(status)
        }
    }

    var dragPreviewSize: NSSize { taskRow.bounds.size }

    func dragPreviewImage() -> NSImage? {
        taskRow.dragPreviewImage()
    }
}

@MainActor
private final class SidebarDisclosureButton: AppButton {
    override var usesAutomaticHoverTracking: Bool { false }
}

@MainActor
private final class SidebarMenuButton: AppButton {
    var forcedActive = false {
        didSet { applyTheme() }
    }

    override func applyTheme() {
        super.applyTheme()
        guard forcedActive else { return }
        layer?.backgroundColor = NSColor.clear.cgColor
        contentTintColor = AppTheme.primaryText
    }
}

@MainActor
private final class SidebarTrailingActionOverlay: NSView {
    let button = SidebarMenuButton(role: .hitTarget)

    private let gradient = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = [0, 0.55]
        layer?.addSublayer(gradient)

        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layout() {
        super.layout()
        gradient.frame = bounds
    }

    func apply(backgroundColor: NSColor) {
        gradient.colors = [
            backgroundColor.withAlphaComponent(0).cgColor,
            backgroundColor.cgColor,
        ]
    }
}

@MainActor
private final class SidebarTaskSelectButton: AppButton, NSDraggingSource {
    var taskID: UUID?
    var dragEnabled = true
    var dragImage: (() -> NSImage?)?

    override func mouseDown(with event: NSEvent) {
        let origin = convert(event.locationInWindow, from: nil)
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseDragged,
               dragEnabled,
               hypot(point.x - origin.x, point.y - origin.y) >= 4 {
                startDragging(with: next)
                return
            }
            if next.type == .leftMouseUp {
                if bounds.contains(point) { performClick(nil) }
                return
            }
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    private func startDragging(with event: NSEvent) {
        guard let taskID else { return }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(taskID.uuidString, forType: .sidebarTaskID)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        item.setDraggingFrame(bounds, contents: dragImage?())
        beginDraggingSession(with: [item], event: event, source: self)
    }
}

@MainActor
private final class SidebarTaskRow: AppHoverView {
    var onSelect: (() -> Void)?
    var onToggleExpansion: (() -> Void)?
    var onHover: (() -> Void)?
    var onShowMenu: ((NSRect) -> Void)?

    private let selected: Bool
    private let hasRepositories: Bool
    private var menuActive: Bool
    private let activity: String?
    private let error: String?
    private let selectButton = SidebarTaskSelectButton(role: .hitTarget)
    private let disclosureButton = SidebarDisclosureButton(role: .icon)
    private let menuOverlay = SidebarTrailingActionOverlay()
    private var menuButton: SidebarMenuButton { menuOverlay.button }
    private let titleLabel: NSTextField
    private let errorIcon = NSImageView()
    private let activityIndicator = NSProgressIndicator()
    private let statusLabel: NSTextField
    private let connectionStatusMonitor: SSHConnectionStatusMonitor
    private let createdAt: Date
    private var repositoryContexts: [SidebarRepositoryContext]
    private var infoPopoverHovering = false
    private var infoPopover: SidebarHoverPopover?
    private var infoCard: SidebarTaskAggregateInfoCard?

    init(
        taskID: UUID,
        title: String,
        hasRepositories: Bool,
        expanded: Bool,
        selected: Bool,
        menuActive: Bool,
        activity: String?,
        error: String?,
        repositoryContexts: [SidebarRepositoryContext],
        connectionStatusMonitor: SSHConnectionStatusMonitor,
        createdAt: Date
    ) {
        self.selected = selected
        self.hasRepositories = hasRepositories
        self.menuActive = menuActive
        self.activity = activity
        self.error = error
        self.repositoryContexts = repositoryContexts
        self.connectionStatusMonitor = connectionStatusMonitor
        self.createdAt = createdAt
        titleLabel = NSTextField(labelWithString: title)
        statusLabel = NSTextField(labelWithString: activity ?? "")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = AppTheme.workspaceControlCornerRadius
        toolTip = error

        [
            selectButton,
            disclosureButton,
            titleLabel,
            errorIcon,
            activityIndicator,
            statusLabel,
            menuOverlay,
        ].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        selectButton.target = self
        selectButton.action = #selector(selectTask)
        selectButton.taskID = taskID
        selectButton.dragEnabled = activity == nil
        selectButton.dragImage = { [weak self] in self?.dragPreviewImage() }
        selectButton.setAccessibilityLabel(title)
        disclosureButton.role = selected ? .accentIcon : .hitTarget
        disclosureButton.image = hasRepositories
            ? NSImage(
                systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                accessibilityDescription: expanded ? "Collapse" : "Expand"
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(
                    pointSize: AppTheme.sidebarDisclosureSymbolSize,
                    weight: .regular
                )
            )
            : nil
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleExpansion)
        disclosureButton.layer?.cornerRadius = AppTheme.workspaceControlCornerRadius
        disclosureButton.layer?.cornerCurve = .continuous
        menuButton.image = activity == nil
            ? NSImage(
                systemSymbolName: "ellipsis",
                accessibilityDescription: "Task actions"
            )
            : nil
        menuButton.isEnabled = activity == nil
        menuButton.target = self
        menuButton.action = #selector(showMenu)
        menuButton.setAccessibilityLabel("Task actions")
        menuButton.layer?.cornerRadius = AppTheme.workspaceControlCornerRadius
        menuButton.layer?.cornerCurve = .continuous
        menuButton.forcedActive = menuActive
        titleLabel.usesSingleLineMode = true
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isSelectable = true
        errorIcon.image = NSImage(
            systemSymbolName: "exclamationmark.circle.fill",
            accessibilityDescription: "Failed"
        )
        activityIndicator.style = .spinning
        activityIndicator.controlSize = .small
        if activity != nil, error == nil {
            activityIndicator.startAnimation(nil)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: AppTheme.sidebarTaskRowHeight),
            selectButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            selectButton.topAnchor.constraint(equalTo: topAnchor),
            selectButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            disclosureButton.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: AppTheme.sidebarDisclosureLeadingInset
            ),
            disclosureButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureButton.widthAnchor.constraint(
                equalToConstant: AppTheme.sidebarDisclosureControlWidth
            ),
            disclosureButton.heightAnchor.constraint(
                equalToConstant: AppTheme.sidebarDisclosureControlHeight
            ),
            titleLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: hasRepositories
                    ? AppTheme.sidebarTaskTitleDisclosureInset
                    : AppTheme.workspaceInset
            ),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: errorIcon.leadingAnchor,
                constant: -6
            ),
            menuOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            menuOverlay.topAnchor.constraint(equalTo: topAnchor),
            menuOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            menuOverlay.widthAnchor.constraint(equalToConstant: 88),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityIndicator.trailingAnchor.constraint(
                equalTo: statusLabel.leadingAnchor,
                constant: -6
            ),
            activityIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityIndicator.widthAnchor.constraint(equalToConstant: activity == nil ? 0 : 12),
            activityIndicator.heightAnchor.constraint(equalToConstant: 12),
            errorIcon.trailingAnchor.constraint(equalTo: activityIndicator.leadingAnchor),
            errorIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorIcon.widthAnchor.constraint(equalToConstant: error == nil ? 0 : 12),
            errorIcon.heightAnchor.constraint(equalToConstant: 12),
        ])
        updateTrailingVisibility()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        let appearance = AppTheme.buttonAppearance(
            role: selected ? .accent : .chrome,
            hovered: !selected && (isHovering || infoPopoverHovering || menuActive)
        )
        layer?.backgroundColor = appearance.background.cgColor
        let textColor = error == nil
            ? selected ? appearance.foreground : AppTheme.primaryText
            : AppTheme.error
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.body, weight: 500)
        titleLabel.textColor = textColor
        disclosureButton.applyTheme()
        menuButton.applyTheme()
        menuOverlay.apply(
            backgroundColor: AppTheme.renderedBackground(appearance.background)
        )
        errorIcon.contentTintColor = error == nil
            ? AppTheme.panelAccentIcon
            : AppTheme.error
        statusLabel.font = .monospacedSystemFont(
            ofSize: AppTheme.typography.label,
            weight: .regular
        )
        statusLabel.textColor = AppTheme.tertiaryText
    }

    override func hoverStateDidChange() {
        updateTrailingVisibility()
        applyTheme()
        if isHovering {
            onHover?()
            showInfoPopover()
        } else {
            dismissInfoPopover()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            infoPopover?.close()
        }
    }

    func setMenuActive(_ active: Bool) {
        menuActive = active
        if active {
            infoPopover?.close()
        }
        menuButton.forcedActive = active
        updateTrailingVisibility()
        applyTheme()
    }

    func refreshConnectionStatuses() {
        repositoryContexts.indices.forEach { index in
            guard let connectionID = repositoryContexts[index].connectionID else { return }
            repositoryContexts[index].status = connectionStatusMonitor.status(for: connectionID)
        }
        infoCard?.update(contexts: repositoryContexts)
    }

    func updatePullRequestStatuses(_ statuses: [UUID: PullRequestRepositoryStatus]) {
        var didChange = false
        for index in repositoryContexts.indices {
            guard let status = statuses[repositoryContexts[index].repositoryID],
                  repositoryContexts[index].pullRequestStatus != status
            else { continue }
            repositoryContexts[index].pullRequestStatus = status
            didChange = true
        }
        if didChange {
            infoCard?.update(contexts: repositoryContexts)
            if infoPopover?.isVisible == true {
                infoPopover?.refreshContentSize()
            }
        }
    }

    private func updateTrailingVisibility() {
        let showsMenu = activity == nil && (isHovering || infoPopoverHovering || menuActive)
        menuOverlay.isHidden = !showsMenu
        disclosureButton.isHidden = !hasRepositories
        errorIcon.isHidden = error == nil
        activityIndicator.isHidden = activity == nil || error != nil
        statusLabel.isHidden = activity == nil
    }

    private func showInfoPopover() {
        guard !menuActive, let window else { return }
        let card = infoCard ?? {
            let value = SidebarTaskAggregateInfoCard(
                createdAt: createdAt,
                contexts: repositoryContexts
            )
            infoCard = value
            return value
        }()
        card.update(contexts: repositoryContexts)
        let popover = infoPopover ?? {
            let value = SidebarHoverPopover(content: card)
            value.onHoverChanged = { [weak self] hovering in
                self?.infoPopoverHovering = hovering
                self?.updateTrailingVisibility()
                self?.applyTheme()
            }
            infoPopover = value
            return value
        }()
        popover.cancelScheduledClose()
        guard !popover.isVisible, window.isVisible else { return }
        popover.show(relativeTo: bounds, of: self)
    }

    private func dismissInfoPopover() {
        infoPopover?.scheduleClose(allowingCorridor: true)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hitView = super.hitTest(point) else { return nil }
        if !disclosureButton.isHidden,
            hitView === disclosureButton || hitView.isDescendant(of: disclosureButton)
        {
            return disclosureButton
        }
        if hitView === menuButton || hitView.isDescendant(of: menuButton) {
            return menuButton
        }
        return selectButton
    }

    func dragPreviewImage() -> NSImage? {
        let background = layer?.backgroundColor
        let menuHidden = menuOverlay.isHidden
        layer?.backgroundColor = NSColor.clear.cgColor
        menuOverlay.isHidden = true
        defer {
            layer?.backgroundColor = background
            menuOverlay.isHidden = menuHidden
        }
        if let bitmap = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: bitmap)
            let content = NSImage(size: bounds.size)
            content.addRepresentation(bitmap)
            let preview = NSImage(size: bounds.size)
            preview.lockFocus()
            AppTheme.controlBackground.setFill()
            NSBezierPath(
                roundedRect: bounds,
                xRadius: AppTheme.workspaceControlCornerRadius,
                yRadius: AppTheme.workspaceControlCornerRadius
            ).fill()
            content.draw(in: bounds)
            preview.unlockFocus()
            return preview
        }
        return nil
    }

    @objc private func selectTask() {
        onSelect?()
    }

    @objc private func toggleExpansion() {
        onToggleExpansion?()
    }

    @objc private func showMenu() {
        guard menuButton.window != nil else { return }
        infoPopover?.close()
        onShowMenu?(convert(bounds, to: nil))
    }
}

@MainActor
final class SidebarActionMenuView: NSView {
    struct Item {
        let title: String
        let symbol: String
        var destructive = false
    }

    var onSelect: ((Int) -> Void)?

    private let rows: [SidebarActionMenuRow]
    private let separator = NSView()

    init(items: [Item]) {
        precondition(items.count >= 2)
        rows = items.map {
            SidebarActionMenuRow(
                title: $0.title,
                symbol: $0.symbol,
                destructive: $0.destructive
            )
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -2)

        (rows.map { $0 as NSView } + [separator]).forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        rows.enumerated().forEach { index, row in
            row.onSelect = { [weak self] in self?.onSelect?(index) }
        }
        separator.wantsLayer = true

        let regularRows = rows.dropLast()
        let first = regularRows[regularRows.startIndex]
        let last = rows[rows.index(before: rows.endIndex)]
        var constraints = [
            first.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            first.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            first.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            first.heightAnchor.constraint(equalToConstant: AppTheme.sidebarTaskRowHeight),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            separator.topAnchor.constraint(equalTo: regularRows.last!.bottomAnchor, constant: 5),
            separator.heightAnchor.constraint(equalToConstant: 1),
            last.leadingAnchor.constraint(equalTo: first.leadingAnchor),
            last.trailingAnchor.constraint(equalTo: first.trailingAnchor),
            last.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 5),
            last.heightAnchor.constraint(equalTo: first.heightAnchor),
            last.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ]
        for (previous, row) in zip(regularRows, regularRows.dropFirst()) {
            constraints += [
                row.leadingAnchor.constraint(equalTo: first.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: first.trailingAnchor),
                row.topAnchor.constraint(equalTo: previous.bottomAnchor),
                row.heightAnchor.constraint(equalTo: first.heightAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.surface.cgColor
        layer?.borderColor = AppTheme.border.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        rows.forEach { $0.applyTheme() }
        separator.layer?.backgroundColor = AppTheme.border.cgColor
    }
}

@MainActor
private final class SidebarActionMenuRow: AppHoverView {
    var onSelect: (() -> Void)?

    private let destructive: Bool
    private let button = AppButton(role: .hitTarget)
    private let icon = NSImageView()
    private let label: NSTextField

    init(title: String, symbol: String, destructive: Bool = false) {
        self.destructive = destructive
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        label.usesSingleLineMode = true
        label.lineBreakMode = .byClipping
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.target = self
        button.action = #selector(selectItem)
        button.setAccessibilityLabel(title)
        [button, icon, label].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        layer?.backgroundColor = (isHovering
            ? AppTheme.controlBackground
            : NSColor.clear).cgColor
        let color = destructive
            ? AppTheme.error
            : isHovering ? AppTheme.primaryText : AppTheme.secondaryText
        icon.contentTintColor = color
        label.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody)
        label.textColor = color
    }

    override func hoverStateDidChange() {
        applyTheme()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : button
    }

    @objc private func selectItem() {
        onSelect?()
    }
}

@MainActor
private enum PullRequestIconAsset {
    static func image() -> NSImage? {
        if let url = Bundle.main.url(forResource: "git-pull-request", withExtension: "png"),
           let image = NSImage(contentsOf: url)
        {
            image.isTemplate = true
            return image
        }
        return NSImage(
            systemSymbolName: "arrow.triangle.pull",
            accessibilityDescription: "Pull request"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        )
    }
}

@MainActor
private final class SidebarRepositoryRow: AppHoverView {
    var onSelect: (() -> Void)?
    var onHover: (() -> Void)?
    var onShowMenu: ((NSRect) -> Void)?

    let repositoryID: UUID
    private let selected: Bool
    private var menuActive: Bool
    private let activity: String?
    private let error: String?
    private let suppressActions: Bool
    private let button = AppButton(role: .hitTarget)
    private let menuOverlay = SidebarTrailingActionOverlay()
    private var menuButton: SidebarMenuButton { menuOverlay.button }
    private let titleLabel: NSTextField
    private let sourceIcon = NSImageView()
    private let errorIcon = NSImageView()
    private let activityIndicator = NSProgressIndicator()
    private let statusLabel: NSTextField
    private let pullRequestIcon = NSImageView()
    private let pullRequestCountLabel = NSTextField(labelWithString: "")
    private let pullRequestBadge = NSStackView()
    private let connectionStatusMonitor: SSHConnectionStatusMonitor
    private let connectionID: UUID?
    private var repositoryContext: SidebarRepositoryContext?
    private var connectionStatus: SSHConnectionStatus
    private var infoPopoverHovering = false
    private let trailingInfoStack = NSStackView()
    private let connectionStatusDot = SSHConnectionStatusIndicator(status: .disabled)
    private var infoPopover: SidebarHoverPopover?
    private var infoCard: SidebarRepositoryInfoCard?

    init(
        repository: TaskRepositoryAttachment,
        selected: Bool,
        menuActive: Bool,
        activity: String?,
        error: String?,
        context: SidebarRepositoryContext?,
        suppressActions: Bool,
        connectionStatusMonitor: SSHConnectionStatusMonitor
    ) {
        repositoryID = repository.repositoryID
        self.selected = selected
        self.menuActive = menuActive
        self.activity = activity
        self.error = error
        self.suppressActions = suppressActions
        self.connectionStatusMonitor = connectionStatusMonitor
        repositoryContext = context
        connectionID = context?.connectionID
        connectionStatus = context?.status ?? .disabled
        titleLabel = NSTextField(labelWithString: repository.name)
        statusLabel = NSTextField(labelWithString: error == nil ? activity ?? "" : "failed")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = AppTheme.workspaceControlCornerRadius
        toolTip = error ?? (self.connectionID == nil ? repository.name : nil)
        sourceIcon.image = NSImage(
            systemSymbolName: self.connectionID == nil ? "laptopcomputer" : "globe",
            accessibilityDescription: self.connectionID == nil ? "Local repository" : "Remote repository"
        )
        sourceIcon.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        trailingInfoStack.orientation = .horizontal
        trailingInfoStack.alignment = .centerY
        trailingInfoStack.spacing = 6
        pullRequestBadge.orientation = .horizontal
        pullRequestBadge.alignment = .centerY
        pullRequestBadge.spacing = 2
        [pullRequestCountLabel, pullRequestIcon].forEach {
            pullRequestBadge.addArrangedSubview($0)
        }
        [pullRequestBadge, errorIcon, activityIndicator, statusLabel, connectionStatusDot].forEach {
            trailingInfoStack.addArrangedSubview($0)
        }
        [button, sourceIcon, titleLabel, trailingInfoStack, menuOverlay].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        button.target = self
        button.action = #selector(selectRepository)
        button.setAccessibilityLabel(repository.name)
        menuButton.image = activity == nil
            ? NSImage(
                systemSymbolName: "ellipsis",
                accessibilityDescription: "Repository actions"
            )
            : nil
        menuButton.isEnabled = activity == nil && !suppressActions
        menuButton.target = self
        menuButton.action = #selector(showMenu)
        menuButton.setAccessibilityLabel("Repository actions")
        menuButton.forcedActive = menuActive
        titleLabel.usesSingleLineMode = true
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isSelectable = true
        errorIcon.image = NSImage(
            systemSymbolName: "exclamationmark.circle.fill",
            accessibilityDescription: "Failed"
        )
        activityIndicator.style = .spinning
        activityIndicator.controlSize = .small
        pullRequestIcon.image = PullRequestIconAsset.image()
        pullRequestIcon.imageScaling = .scaleProportionallyDown
        pullRequestIcon.setAccessibilityLabel("Pull request status")
        pullRequestCountLabel.alignment = .center
        pullRequestCountLabel.setAccessibilityLabel("Pull request count")
        if activity != nil, error == nil {
            activityIndicator.startAnimation(nil)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: AppTheme.sidebarTaskRowHeight),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            sourceIcon.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: AppTheme.sidebarTaskTitleDisclosureInset
            ),
            sourceIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            sourceIcon.widthAnchor.constraint(equalToConstant: 12),
            sourceIcon.heightAnchor.constraint(equalToConstant: 12),
            titleLabel.leadingAnchor.constraint(
                equalTo: sourceIcon.trailingAnchor,
                constant: 6
            ),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingInfoStack.leadingAnchor, constant: -6),
            menuOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            menuOverlay.topAnchor.constraint(equalTo: topAnchor),
            menuOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            menuOverlay.widthAnchor.constraint(equalToConstant: 88),
            activityIndicator.widthAnchor.constraint(equalToConstant: activity == nil ? 0 : 12),
            activityIndicator.heightAnchor.constraint(equalToConstant: 12),
            errorIcon.widthAnchor.constraint(equalToConstant: error == nil ? 0 : 14),
            errorIcon.heightAnchor.constraint(equalToConstant: 12),
            connectionStatusDot.widthAnchor.constraint(equalToConstant: 8),
            connectionStatusDot.heightAnchor.constraint(equalToConstant: 8),
            pullRequestIcon.widthAnchor.constraint(equalToConstant: 14),
            pullRequestIcon.heightAnchor.constraint(equalToConstant: 14),
            trailingInfoStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            trailingInfoStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateTrailingVisibility()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var hoverTrackingOptions: NSTrackingArea.Options {
        [.activeAlways, .mouseEnteredAndExited, .inVisibleRect]
    }

    func applyTheme() {
        let appearance = AppTheme.buttonAppearance(
            role: selected ? .accent : .chrome,
            hovered: isHovering || infoPopoverHovering
        )
        layer?.backgroundColor = appearance.background.cgColor
        let textColor = error == nil
            ? selected ? AppTheme.panelAccentIcon : AppTheme.tertiaryText
            : AppTheme.error
        titleLabel.font = .monospacedSystemFont(
            ofSize: AppTheme.typography.label,
            weight: selected ? .semibold : .regular
        )
        titleLabel.textColor = textColor
        sourceIcon.contentTintColor = textColor
        menuButton.applyTheme()
        menuOverlay.apply(
            backgroundColor: AppTheme.renderedBackground(appearance.background)
        )
        errorIcon.contentTintColor = error == nil
            ? AppTheme.tertiaryText
            : AppTheme.error
        statusLabel.font = .monospacedSystemFont(
            ofSize: AppTheme.typography.label,
            weight: .regular
        )
        statusLabel.textColor = error == nil
            ? AppTheme.tertiaryText
            : AppTheme.error
        pullRequestCountLabel.font = AppTheme.font(ofSize: AppTheme.typography.label + 1, weight: 600)
        connectionStatusDot.status = connectionStatus
        updatePullRequestIcon()
    }

    override func hoverStateDidChange() {
        updateTrailingVisibility()
        applyTheme()
        if isHovering {
            onHover?()
            showInfoPopover()
        } else {
            dismissInfoPopover()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            infoPopover?.close()
        }
    }

    func setMenuActive(_ active: Bool) {
        menuActive = active
        if active {
            infoPopover?.close()
        }
        menuButton.forcedActive = active
        updateTrailingVisibility()
        applyTheme()
    }

    func refreshConnectionStatus() {
        guard let connectionID else { return }
        connectionStatus = connectionStatusMonitor.status(for: connectionID)
        repositoryContext?.status = connectionStatus
        applyTheme()
        if let repositoryContext {
            infoCard?.update(context: repositoryContext)
        }
    }

    func updatePullRequestStatus(_ status: PullRequestRepositoryStatus) {
        guard var repositoryContext,
              repositoryContext.pullRequestStatus != status
        else { return }
        repositoryContext.pullRequestStatus = status
        self.repositoryContext = repositoryContext
        infoCard?.hideChecks()
        infoCard?.update(context: repositoryContext)
        if infoPopover?.isVisible == true {
            infoPopover?.refreshContentSize()
        }
        applyTheme()
    }

    private func updateTrailingVisibility() {
        let showsMenu = !suppressActions
            && activity == nil
            && (isHovering || infoPopoverHovering || menuActive)
        menuOverlay.isHidden = !showsMenu
        errorIcon.isHidden = error == nil
        activityIndicator.isHidden = activity == nil || error != nil
        statusLabel.isHidden = error == nil && activity == nil
        connectionStatusDot.isHidden = connectionID == nil
    }

    private func updatePullRequestIcon() {
        let pullRequests = repositoryContext?.pullRequests ?? []
        let count = pullRequests.count
        pullRequestBadge.isHidden = count == 0
        pullRequestIcon.isHidden = count == 0
        pullRequestCountLabel.isHidden = count < 2
        pullRequestCountLabel.stringValue = count > 1 ? "\(count)" : ""
        pullRequestCountLabel.textColor = AppTheme.tertiaryText
        guard count == 1, let pullRequest = pullRequests.first else {
            pullRequestIcon.contentTintColor = AppTheme.tertiaryText
            pullRequestIcon.toolTip = nil
            pullRequestIcon.setAccessibilityValue(count > 1 ? "\(count) pull requests" : nil)
            return
        }
        let status = pullRequest.displayStatus
        pullRequestIcon.contentTintColor = AppTheme.pullRequestColor(status)
        pullRequestIcon.toolTip = nil
        pullRequestIcon.setAccessibilityValue(status.label)
    }

    private func showInfoPopover() {
        guard !menuActive, let window, let repositoryContext else { return }
        let card = infoCard ?? {
            let value = SidebarRepositoryInfoCard(context: repositoryContext)
            value.onChecksHover = { [weak self] source, checks, hovering in
                self?.handleChecksHover(from: source, checks: checks, hovering: hovering)
            }
            infoCard = value
            return value
        }()
        card.update(context: repositoryContext)
        let popover = infoPopover ?? {
            let value = SidebarHoverPopover(content: card)
            value.onHoverChanged = { [weak self] hovering in
                self?.infoPopoverHovering = hovering
                self?.updateTrailingVisibility()
                self?.applyTheme()
            }
            infoPopover = value
            return value
        }()
        popover.cancelScheduledClose()
        if !popover.isVisible {
            card.hideChecks()
        }
        guard !popover.isVisible, window.isVisible else { return }
        popover.show(relativeTo: bounds, of: self)
    }

    private func dismissInfoPopover() {
        infoPopover?.scheduleClose(allowingCorridor: true)
    }

    private func handleChecksHover(
        from source: NSView,
        checks: [PullRequestCheck],
        hovering: Bool
    ) {
        if hovering {
            guard !checks.isEmpty else {
                infoCard?.hideChecks()
                infoPopover?.refreshContentSize()
                return
            }
            infoCard?.showChecks(from: source, checks: checks)
            infoPopover?.refreshContentSize()
        } else {
            infoCard?.scheduleHideChecks(from: source) { [weak self] in
                self?.infoPopover?.refreshContentSize()
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hitView = super.hitTest(point) else { return nil }
        if hitView === menuButton || hitView.isDescendant(of: menuButton) {
            return menuButton
        }
        return button
    }

    @objc private func selectRepository() {
        onSelect?()
    }

    @objc private func showMenu() {
        guard menuButton.window != nil else { return }
        infoPopover?.close()
        onShowMenu?(convert(bounds, to: nil))
    }
}

enum SidebarHoverCorridor {
    static func contains(
        _ point: NSPoint,
        from origin: NSPoint?,
        to popoverFrame: NSRect
    ) -> Bool {
        guard let origin else { return false }
        let padding: CGFloat = 12
        let targetX = popoverFrame.minX + padding
        guard origin.x < targetX,
              point.x >= origin.x,
              point.x <= targetX
        else { return false }
        return pointInTriangle(
            point,
            origin,
            NSPoint(x: targetX, y: popoverFrame.maxY + padding),
            NSPoint(x: targetX, y: popoverFrame.minY - padding)
        )
    }

    private static func pointInTriangle(
        _ point: NSPoint,
        _ first: NSPoint,
        _ second: NSPoint,
        _ third: NSPoint
    ) -> Bool {
        let firstArea = cross(first, second, point)
        let secondArea = cross(second, third, point)
        let thirdArea = cross(third, first, point)
        let hasNegative = firstArea < 0 || secondArea < 0 || thirdArea < 0
        let hasPositive = firstArea > 0 || secondArea > 0 || thirdArea > 0
        return !(hasNegative && hasPositive)
    }

    private static func cross(
        _ first: NSPoint,
        _ second: NSPoint,
        _ point: NSPoint
    ) -> CGFloat {
        (second.x - first.x) * (point.y - first.y)
            - (second.y - first.y) * (point.x - first.x)
    }
}

@MainActor
private final class SidebarHoverPopover: NSPanel {
    private static weak var activePopover: SidebarHoverPopover?
    private static let handoffDelay: TimeInterval = 0.2
    private static let closeDelay: TimeInterval = 0.12
    private static let corridorDuration: TimeInterval = 0.45
    private static let pointerPollInterval: TimeInterval = 0.04
    private let chromeView: SidebarHoverPopoverView
    private var pointerTimer: Timer?
    private var pendingShow: DispatchWorkItem?
    private var closeDeadline: Date?
    private var corridorDeadline: Date?
    private var corridorOrigin: NSPoint?
    private weak var sourceView: NSView?
    private var isHovering = false
    var onHoverChanged: ((Bool) -> Void)?

    init(content: NSView) {
        chromeView = SidebarHoverPopoverView(content: content)
        super.init(
            contentRect: NSRect(origin: .zero, size: chromeView.intrinsicContentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        contentView = chromeView
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = true
        collectionBehavior = [.transient, .ignoresCycle]
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func show(relativeTo rect: NSRect, of view: NSView) {
        guard view.window != nil else { return }
        sourceView = view
        cancelScheduledClose()
        pendingShow?.cancel()
        pendingShow = nil
        if let activePopover = Self.activePopover, activePopover !== self {
            let workItem = DispatchWorkItem { [weak self, weak view] in
                guard let self,
                      let view,
                      self.pointerInsideSourceView(view)
                else { return }
                self.present(relativeTo: rect, of: view)
            }
            pendingShow = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.handoffDelay,
                execute: workItem
            )
            return
        }
        present(relativeTo: rect, of: view)
    }

    private func present(relativeTo rect: NSRect, of view: NSView) {
        pendingShow = nil
        if let activePopover = Self.activePopover, activePopover !== self {
            activePopover.close()
        }
        guard let window = view.window else { return }
        setContentSize(chromeView.intrinsicContentSize)
        let windowRect = view.convert(rect, to: nil)
        let screenRect = window.convertToScreen(windowRect)
        let size = frame.size
        setFrame(
            NSRect(
                x: screenRect.maxX,
                y: screenRect.maxY - size.height,
                width: size.width,
                height: size.height
            ),
            display: true
        )
        chromeView.layoutSubtreeIfNeeded()
        Self.activePopover = self
        orderFrontRegardless()
        startPointerTracking()
        updatePointerState()
    }

    func refreshContentSize() {
        cancelScheduledClose()
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        setContentSize(chromeView.intrinsicContentSize)
        setFrameTopLeftPoint(topLeft)
        chromeView.layoutSubtreeIfNeeded()
        updatePointerState()
    }

    func scheduleClose(allowingCorridor: Bool = false) {
        pendingShow?.cancel()
        pendingShow = nil
        guard isVisible else { return }
        closeDeadline = Date().addingTimeInterval(Self.closeDelay)
        if allowingCorridor {
            corridorOrigin = NSEvent.mouseLocation
            corridorDeadline = Date().addingTimeInterval(Self.corridorDuration)
        } else {
            corridorOrigin = nil
            corridorDeadline = nil
        }
    }

    func cancelScheduledClose() {
        closeDeadline = nil
        corridorOrigin = nil
        corridorDeadline = nil
    }

    private func startPointerTracking() {
        guard pointerTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pointerPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updatePointerState()
            }
        }
        pointerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updatePointerState() {
        guard isVisible else {
            stopPointerTracking()
            return
        }
        let mouseLocation = NSEvent.mouseLocation
        let pointerInsidePopover = frame.contains(mouseLocation)
        let pointerInsideSource = sourceView.map(pointerInsideSourceView) ?? false
        if pointerInsidePopover || pointerInsideSource {
            setHovering(true)
            closeDeadline = nil
            corridorOrigin = nil
            corridorDeadline = nil
            return
        }
        if let corridorDeadline,
           corridorDeadline > Date(),
           SidebarHoverCorridor.contains(mouseLocation, from: corridorOrigin, to: frame)
        {
            NSCursor.arrow.set()
            setHovering(true)
            closeDeadline = nil
            return
        }
        corridorOrigin = nil
        corridorDeadline = nil
        if let closeDeadline {
            if closeDeadline <= Date() {
                close()
            }
        } else {
            closeDeadline = Date().addingTimeInterval(Self.closeDelay)
        }
    }

    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        onHoverChanged?(hovering)
    }

    private func pointerInsideSourceView(_ view: NSView) -> Bool {
        guard let sourceWindow = view.window else { return false }
        let windowRect = view.convert(view.bounds, to: nil)
        return sourceWindow.convertToScreen(windowRect).contains(NSEvent.mouseLocation)
    }

    private func stopPointerTracking() {
        pointerTimer?.invalidate()
        pointerTimer = nil
    }

    override func close() {
        cancelScheduledClose()
        stopPointerTracking()
        pendingShow?.cancel()
        pendingShow = nil
        sourceView = nil
        setHovering(false)
        if Self.activePopover === self {
            Self.activePopover = nil
        }
        super.close()
    }
}

@MainActor
private final class SidebarHoverPopoverView: NSView {
    private let content: NSView

    init(content: NSView) {
        self.content = content
        let contentSize = content.intrinsicContentSize
        super.init(
            frame: NSRect(
                x: 0,
                y: 0,
                width: contentSize.width,
                height: contentSize.height
            )
        )
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override var intrinsicContentSize: NSSize {
        let contentSize = content.intrinsicContentSize
        return NSSize(
            width: contentSize.width,
            height: contentSize.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: 12,
            yRadius: 12
        )
        AppTheme.surface.setFill()
        path.fill()
        AppTheme.border.withAlphaComponent(0.32).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

@MainActor
private final class SidebarRepositoryInfoCard: NSView {
    var onChecksHover: ((NSView, [PullRequestCheck], Bool) -> Void)?

    private let repositoryRow: SidebarTaskInfoRepositoryRow
    private let pullRequestView: SidebarPullRequestInfoView
    private let divider = NSView()
    private let checksDivider = NSView()
    private let checksCard: SidebarChecksInfoCard
    private var widthConstraint: NSLayoutConstraint!
    private var checksDividerWidthConstraint: NSLayoutConstraint!
    private var checksCardWidthConstraint: NSLayoutConstraint!
    private var showsChecks = false
    private weak var activeChecksSource: NSView?
    private var hideChecksWorkItem: DispatchWorkItem?

    init(context: SidebarRepositoryContext) {
        repositoryRow = SidebarTaskInfoRepositoryRow(context: context)
        pullRequestView = SidebarPullRequestInfoView(
            status: context.pullRequestStatus,
            branch: context.branch,
            remoteURL: context.remoteURL
        )
        checksCard = SidebarChecksInfoCard(checks: [], height: 138)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.borderWidth = 0
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        checksDivider.translatesAutoresizingMaskIntoConstraints = false
        checksDivider.wantsLayer = true
        checksDivider.isHidden = true
        checksCard.isHidden = true
        pullRequestView.onChecksHover = { [weak self] source, checks, hovering in
            self?.onChecksHover?(source, checks, hovering)
        }
        addSubview(repositoryRow)
        addSubview(divider)
        addSubview(pullRequestView)
        addSubview(checksDivider)
        addSubview(checksCard)
        widthConstraint = widthAnchor.constraint(equalToConstant: 400)
        checksDividerWidthConstraint = checksDivider.widthAnchor.constraint(equalToConstant: 0)
        checksCardWidthConstraint = checksCard.widthAnchor.constraint(equalToConstant: 400)
        NSLayoutConstraint.activate([
            widthConstraint,
            repositoryRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            repositoryRow.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            repositoryRow.widthAnchor.constraint(equalToConstant: 368),
            divider.leadingAnchor.constraint(equalTo: repositoryRow.leadingAnchor),
            divider.topAnchor.constraint(equalTo: repositoryRow.bottomAnchor, constant: 10),
            divider.widthAnchor.constraint(equalTo: repositoryRow.widthAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            pullRequestView.leadingAnchor.constraint(equalTo: repositoryRow.leadingAnchor),
            pullRequestView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 10),
            pullRequestView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            pullRequestView.widthAnchor.constraint(equalTo: repositoryRow.widthAnchor),
            checksDivider.leadingAnchor.constraint(equalTo: repositoryRow.trailingAnchor, constant: 12),
            checksDivider.topAnchor.constraint(equalTo: repositoryRow.topAnchor),
            checksDivider.bottomAnchor.constraint(equalTo: pullRequestView.bottomAnchor),
            checksDividerWidthConstraint,
            checksCard.leadingAnchor.constraint(equalTo: checksDivider.trailingAnchor, constant: 12),
            checksCard.topAnchor.constraint(equalTo: repositoryRow.topAnchor),
            checksCardWidthConstraint,
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: showsChecks ? 825 : 400,
            height: 28 + 95 + 1 + pullRequestView.intrinsicContentSize.height + 20
        )
    }

    func update(context: SidebarRepositoryContext) {
        repositoryRow.update(context: context)
        pullRequestView.update(status: context.pullRequestStatus, branch: context.branch)
        invalidateIntrinsicContentSize()
        applyTheme()
    }

    func showChecks(from source: NSView, checks: [PullRequestCheck]) {
        hideChecksWorkItem?.cancel()
        activeChecksSource = source
        let contentHeight = max(0, intrinsicContentSize.height - 28)
        checksCard.update(checks: checks, height: contentHeight)
        checksCard.isHidden = false
        checksDivider.isHidden = false
        showsChecks = true
        checksDividerWidthConstraint.constant = 1
        checksCardWidthConstraint.constant = 400
        widthConstraint.constant = 825
        invalidateIntrinsicContentSize()
        needsLayout = true
        applyTheme()
    }

    func scheduleHideChecks(from source: NSView, onHidden: @escaping () -> Void) {
        guard source === activeChecksSource else { return }
        hideChecksWorkItem?.cancel()
        let sourceID = ObjectIdentifier(source)
        let workItem = DispatchWorkItem { [weak self, weak source] in
            guard let self else { return }
            let activeSourceID = self.activeChecksSource.map(ObjectIdentifier.init)
            guard (activeSourceID == nil || activeSourceID == sourceID),
                  !((source as? AppHoverView)?.isHovering ?? false),
                  !self.checksCard.isHovering,
                  !self.checksCard.containsPointer
            else { return }
            self.hideChecks()
            onHidden()
        }
        hideChecksWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    func hideChecks() {
        hideChecksWorkItem?.cancel()
        hideChecksWorkItem = nil
        activeChecksSource = nil
        checksCard.isHidden = true
        checksDivider.isHidden = true
        checksDividerWidthConstraint.constant = 0
        showsChecks = false
        widthConstraint.constant = 400
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func applyTheme() {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderColor = NSColor.clear.cgColor
        divider.layer?.backgroundColor = AppTheme.border.cgColor
        checksDivider.layer?.backgroundColor = AppTheme.border.cgColor
        repositoryRow.applyTheme()
        pullRequestView.applyTheme()
    }
}

@MainActor
private final class SidebarPullRequestRowsView: NSView {
    static let spacing: CGFloat = 4

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutRows()
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        layoutRows()
    }

    private func layoutRows() {
        var y: CGFloat = 0
        for view in subviews {
            let height: CGFloat = view is SidebarPullRequestInfoRow ? 44 : 22
            view.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height + Self.spacing
        }
    }
}

@MainActor
final class SidebarPullRequestInfoView: NSView {
    var onChecksHover: ((NSView, [PullRequestCheck], Bool) -> Void)?

    private let pullRequestIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Pull requests")
    private let refreshIndicator = NSProgressIndicator()
    private let countLabel = NSTextField(labelWithString: "")
    private let rowsView = SidebarPullRequestRowsView()
    private var rowsHeightConstraint: NSLayoutConstraint!
    private var rowViews: [NSView] = []
    private var status: PullRequestRepositoryStatus
    private var branch: String?
    private let remoteURL: String?
    private var hasRendered = false

    init(status: PullRequestRepositoryStatus, branch: String?, remoteURL: String?) {
        self.status = status
        self.branch = branch
        self.remoteURL = remoteURL
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        pullRequestIcon.image = PullRequestIconAsset.image()
        pullRequestIcon.imageScaling = .scaleProportionallyDown
        pullRequestIcon.setAccessibilityLabel("Pull request status")
        pullRequestIcon.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        refreshIndicator.style = .spinning
        refreshIndicator.controlSize = .small
        refreshIndicator.isDisplayedWhenStopped = false
        refreshIndicator.isHidden = true
        refreshIndicator.translatesAutoresizingMaskIntoConstraints = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.alignment = .right
        rowsView.translatesAutoresizingMaskIntoConstraints = false
        rowsHeightConstraint = rowsView.heightAnchor.constraint(equalToConstant: 22)
        addSubview(pullRequestIcon)
        addSubview(titleLabel)
        addSubview(refreshIndicator)
        addSubview(countLabel)
        addSubview(rowsView)
        NSLayoutConstraint.activate([
            pullRequestIcon.leadingAnchor.constraint(equalTo: leadingAnchor),
            pullRequestIcon.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            pullRequestIcon.widthAnchor.constraint(equalToConstant: 16),
            pullRequestIcon.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: pullRequestIcon.trailingAnchor, constant: 6),
            titleLabel.firstBaselineAnchor.constraint(equalTo: countLabel.firstBaselineAnchor),
            refreshIndicator.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            refreshIndicator.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            refreshIndicator.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -8),
            refreshIndicator.widthAnchor.constraint(equalToConstant: 12),
            refreshIndicator.heightAnchor.constraint(equalToConstant: 12),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            countLabel.topAnchor.constraint(equalTo: topAnchor),
            countLabel.heightAnchor.constraint(equalToConstant: 22),
            rowsView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowsView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowsView.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 6),
            rowsView.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowsHeightConstraint,
        ])
        update(status: status, branch: branch)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    var visiblePullRequestRows: [SidebarPullRequestInfoRow] {
        rowViews.compactMap { $0 as? SidebarPullRequestInfoRow }
    }

    var visibleMessage: String? {
        rowViews.compactMap { ($0 as? NSTextField)?.stringValue }.first
    }

    var visibleMessageAlignment: NSTextAlignment? {
        rowViews.compactMap { ($0 as? NSTextField)?.alignment }.first
    }

    var isShowingBackgroundRefresh: Bool {
        !refreshIndicator.isHidden
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        let pointInRows = convert(point, to: rowsView)
        if let row = visiblePullRequestRows.first(where: { $0.frame.contains(pointInRows) }) {
            let pointInRow = row.convert(pointInRows, from: rowsView)
            return row.hitTest(pointInRow) ?? row
        }
        return super.hitTest(point)
    }

    override var intrinsicContentSize: NSSize {
        let rowsHeight: CGFloat
        switch status.availability {
        case .loaded, .loading:
            rowsHeight = self.rowsHeight(
                for: status.related(to: branch),
                availability: status.availability
            )
        case .idle, .unavailable:
            rowsHeight = 22
        }
        return NSSize(width: 368, height: 28 + rowsHeight)
    }

    func update(status: PullRequestRepositoryStatus, branch: String?) {
        guard !hasRendered || self.status != status || self.branch != branch else { return }
        hasRendered = true
        self.status = status
        self.branch = branch
        let relatedPullRequests = status.related(to: branch)
        rowsHeightConstraint.constant = rowsHeight(for: relatedPullRequests, availability: status.availability)
        titleLabel.stringValue = "Pull requests"
        countLabel.stringValue = switch status.availability {
        case .idle: ""
        case .loading: relatedPullRequests.isEmpty ? "" : "\(relatedPullRequests.count)"
        case .unavailable: "Unavailable"
        case .loaded: "\(relatedPullRequests.count)"
        }
        let showsBackgroundRefresh = status.availability == .loading
            && !relatedPullRequests.isEmpty
        refreshIndicator.isHidden = !showsBackgroundRefresh
        if showsBackgroundRefresh {
            refreshIndicator.startAnimation(nil)
        } else {
            refreshIndicator.stopAnimation(nil)
        }
        if !relatedPullRequests.isEmpty,
           (status.availability == .loaded || status.availability == .loading)
        {
            pullRequestIcon.isHidden = false
            pullRequestIcon.toolTip = nil
            if relatedPullRequests.count == 1, let summary = relatedPullRequests.first {
                pullRequestIcon.contentTintColor = AppTheme.pullRequestColor(summary.displayStatus)
                pullRequestIcon.setAccessibilityValue(summary.displayStatus.label)
            } else {
                pullRequestIcon.contentTintColor = AppTheme.tertiaryText
                pullRequestIcon.setAccessibilityValue("\(relatedPullRequests.count) pull requests")
            }
        } else {
            pullRequestIcon.isHidden = true
            pullRequestIcon.toolTip = nil
            pullRequestIcon.setAccessibilityValue(nil)
        }
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll(keepingCapacity: true)
        switch status.availability {
        case .idle:
            addMessage("Pull request status not loaded.")
        case .loading:
            if relatedPullRequests.isEmpty {
                addMessage("Loading GitHub…", centered: true)
            } else {
                addRows(relatedPullRequests)
            }
        case .unavailable:
            addMessage(status.failureMessage ?? "GitHub PR status unavailable.")
        case .loaded:
            if relatedPullRequests.isEmpty {
                addMessage("No pull request for this branch.")
            } else {
                addRows(relatedPullRequests)
            }
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
        applyTheme()
    }

    private func rowsHeight(
        for pullRequests: [PullRequestSummary],
        availability: PullRequestAvailability
    ) -> CGFloat {
        switch availability {
        case .loaded, .loading:
            let showsMessage = pullRequests.isEmpty
            let messageHeight: CGFloat = showsMessage ? 22 : 0
            let rowsSpacing = CGFloat(max(0, pullRequests.count - 1))
                * SidebarPullRequestRowsView.spacing
            return max(
                22,
                messageHeight
                    + CGFloat(pullRequests.count) * 44
                    + rowsSpacing
            )
        case .idle, .unavailable:
            return 22
        }
    }

    func applyTheme() {
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody, weight: 600)
        titleLabel.textColor = AppTheme.primaryText
        countLabel.font = .monospacedSystemFont(ofSize: AppTheme.typography.label, weight: .regular)
        countLabel.textColor = AppTheme.tertiaryText
        rowViews.forEach { view in
            if let row = view as? SidebarPullRequestInfoRow {
                row.applyTheme()
            } else if let label = view as? NSTextField {
                label.font = .monospacedSystemFont(ofSize: AppTheme.typography.label, weight: .regular)
                label.textColor = AppTheme.secondaryText
            }
        }
    }

    private func addMessage(_ message: String, centered: Bool = false) {
        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = true
        label.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingTail
        label.alignment = centered ? .center : .natural
        label.toolTip = message
        rowViews.append(label)
        rowsView.addSubview(label)
    }

    private func addRows(_ pullRequests: [PullRequestSummary]) {
        pullRequests.forEach { summary in
            let row = SidebarPullRequestInfoRow(
                summary: summary,
                remoteURL: remoteURL
            )
            row.onChecksHover = { [weak self] source, checks, hovering in
                self?.onChecksHover?(source, checks, hovering)
            }
            row.translatesAutoresizingMaskIntoConstraints = true
            rowViews.append(row)
            rowsView.addSubview(row)
        }
    }
}

@MainActor
private final class SidebarChecksDonutView: NSView {
    private let checks: [PullRequestCheck]

    init(checks: [PullRequestCheck]) {
        self.checks = checks
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel("Checks")
        setAccessibilityValue(checks.isEmpty ? "No checks" : "\(checks.count) checks")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 16, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let lineWidth: CGFloat = 3
        let radius = min(bounds.width, bounds.height) / 2 - lineWidth / 2
        guard radius > 0 else { return }
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let background = NSBezierPath()
        background.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 0,
            endAngle: 360,
            clockwise: false
        )
        background.lineWidth = lineWidth
        AppTheme.border.setStroke()
        background.stroke()

        guard !checks.isEmpty else {
            AppTheme.tertiaryText.setStroke()
            background.stroke()
            return
        }

        let statuses: [PullRequestCheckStatus] = [.passed, .failed, .pending, .neutral, .unknown]
        var startAngle: CGFloat = 90
        for status in statuses {
            let count = checks.count(where: { $0.status == status })
            guard count > 0 else { continue }
            let endAngle = startAngle + 360 * CGFloat(count) / CGFloat(checks.count)
            let segment = NSBezierPath()
            segment.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: endAngle,
                clockwise: false
            )
            segment.lineWidth = lineWidth
            checkColor(for: status).setStroke()
            segment.stroke()
            startAngle = endAngle
        }
    }

    private func checkColor(for status: PullRequestCheckStatus) -> NSColor {
        switch status {
        case .passed: AppTheme.success
        case .failed: AppTheme.error
        case .pending: AppTheme.warning
        case .neutral: AppTheme.secondaryText
        case .unknown: AppTheme.warning
        }
    }
}

@MainActor
private final class SidebarCheckInfoRow: NSView {
    private let statusIcon = NSImageView()
    private let nameLabel: NSTextField
    private let status: PullRequestCheckStatus

    init(check: PullRequestCheck) {
        status = check.status
        nameLabel = NSTextField(labelWithString: check.name)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        statusIcon.image = NSImage(
            systemSymbolName: Self.symbolName(for: check.status),
            accessibilityDescription: check.status.label
        )
        statusIcon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.setAccessibilityLabel(check.status.label)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.usesSingleLineMode = true
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setAccessibilityLabel(check.name)
        addSubview(statusIcon)
        addSubview(nameLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            statusIcon.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusIcon.widthAnchor.constraint(equalToConstant: 16),
            statusIcon.heightAnchor.constraint(equalToConstant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func applyTheme() {
        statusIcon.contentTintColor = Self.color(for: status)
        nameLabel.font = .monospacedSystemFont(ofSize: AppTheme.typography.label, weight: .regular)
        nameLabel.textColor = AppTheme.primaryText
    }

    private static func symbolName(for status: PullRequestCheckStatus) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .pending: "clock.fill"
        case .neutral: "minus.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    private static func color(for status: PullRequestCheckStatus) -> NSColor {
        switch status {
        case .passed: AppTheme.success
        case .failed: AppTheme.error
        case .pending: AppTheme.warning
        case .neutral: AppTheme.secondaryText
        case .unknown: AppTheme.warning
        }
    }
}

@MainActor
private final class SidebarChecksInfoCard: AppHoverView {
    private let titleIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Checks")
    private let countLabel = NSTextField(labelWithString: "0")
    private let scrollView = NSScrollView()
    private let rowsStack = NSStackView()
    private var checks: [PullRequestCheck]
    private var cardHeight: CGFloat
    private var cardHeightConstraint: NSLayoutConstraint?
    private var shouldScrollToTop = false

    init(checks: [PullRequestCheck], height: CGFloat) {
        self.checks = checks
        cardHeight = height
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleIcon.image = NSImage(
            systemSymbolName: "checkmark.seal.fill",
            accessibilityDescription: "Checks"
        )
        titleIcon.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        titleIcon.translatesAutoresizingMaskIntoConstraints = false
        titleIcon.setAccessibilityLabel("Checks")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.alignment = .right
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        rowsStack.translatesAutoresizingMaskIntoConstraints = true
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 2
        scrollView.documentView = rowsStack
        addSubview(titleIcon)
        addSubview(titleLabel)
        addSubview(countLabel)
        addSubview(scrollView)
        cardHeightConstraint = heightAnchor.constraint(equalToConstant: height)
        cardHeightConstraint?.isActive = true
        NSLayoutConstraint.activate([
            titleIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleIcon.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleIcon.widthAnchor.constraint(equalToConstant: 18),
            titleIcon.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: titleIcon.trailingAnchor, constant: 7),
            titleLabel.centerYAnchor.constraint(equalTo: titleIcon.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -8),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            countLabel.centerYAnchor.constraint(equalTo: titleIcon.centerYAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: titleIcon.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
        update(checks: checks, height: height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 400, height: cardHeight)
    }

    override var hoverTrackingOptions: NSTrackingArea.Options {
        [.activeAlways, .mouseEnteredAndExited, .inVisibleRect]
    }

    var containsPointer: Bool {
        guard let window else { return false }
        let windowRect = convert(bounds, to: nil)
        return window.convertToScreen(windowRect).contains(NSEvent.mouseLocation)
    }

    override func layout() {
        super.layout()
        let viewport = scrollView.contentView.bounds.size
        let rowHeight: CGFloat = 26
        let contentHeight = CGFloat(checks.count) * rowHeight
            + CGFloat(max(0, checks.count - 1)) * rowsStack.spacing
        rowsStack.frame = NSRect(
            x: 0,
            y: 0,
            width: max(viewport.width, 1),
            height: max(contentHeight, viewport.height)
        )
        rowsStack.layoutSubtreeIfNeeded()
        if shouldScrollToTop {
            shouldScrollToTop = false
            scrollToTop()
        }
    }

    func update(checks: [PullRequestCheck], height: CGFloat) {
        self.checks = checks
        cardHeight = height
        cardHeightConstraint?.constant = height
        countLabel.stringValue = "\(checks.count)"
        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        checks.forEach { check in
            let row = SidebarCheckInfoRow(check: check)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        shouldScrollToTop = true
        invalidateIntrinsicContentSize()
        needsLayout = true
        applyTheme()
    }

    private func scrollToTop() {
        let viewportHeight = scrollView.contentView.bounds.height
        let documentHeight = rowsStack.bounds.height
        let offsetY = rowsStack.isFlipped
            ? 0
            : max(0, documentHeight - viewportHeight)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offsetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func applyTheme() {
        titleIcon.contentTintColor = AppTheme.tertiaryText
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody, weight: 600)
        titleLabel.textColor = AppTheme.primaryText
        countLabel.font = .monospacedSystemFont(ofSize: AppTheme.typography.label, weight: .regular)
        countLabel.textColor = AppTheme.tertiaryText
        rowsStack.arrangedSubviews.compactMap { $0 as? SidebarCheckInfoRow }.forEach {
            $0.applyTheme()
        }
    }
}

@MainActor
private final class SidebarPullRequestOpenButton: AppButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class SidebarPullRequestInfoRow: AppHoverView {
    var onChecksHover: ((NSView, [PullRequestCheck], Bool) -> Void)?
    var onOpen: ((URL) -> Void)?

    private let summary: PullRequestSummary
    private let pullRequestURL: URL?
    private let openButton = SidebarPullRequestOpenButton(role: .hitTarget)
    private let titleLabel: NSTextField
    private let metadataLabel: NSTextField
    private let checksDonut: SidebarChecksDonutView
    private let detailsStack = NSStackView()

    init(
        summary: PullRequestSummary,
        remoteURL: String?
    ) {
        self.summary = summary
        pullRequestURL = summary.url.flatMap(URL.init(string:))
            ?? PullRequestLinkResolver.url(remoteURL: remoteURL, number: summary.number)
        titleLabel = NSTextField(labelWithString: "#\(summary.number) \(summary.title)")
        metadataLabel = NSTextField(
            labelWithString: "\(summary.headBranch) → \(summary.baseBranch)"
        )
        checksDonut = SidebarChecksDonutView(checks: summary.checks)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open pull request #\(summary.number)")
        detailsStack.translatesAutoresizingMaskIntoConstraints = false
        detailsStack.orientation = .vertical
        detailsStack.alignment = .leading
        detailsStack.spacing = 2
        [titleLabel, metadataLabel].forEach { label in
            label.translatesAutoresizingMaskIntoConstraints = false
            detailsStack.addArrangedSubview(label)
            label.usesSingleLineMode = true
            label.lineBreakMode = .byTruncatingTail
            label.widthAnchor.constraint(equalTo: detailsStack.widthAnchor).isActive = true
        }
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.target = self
        openButton.action = #selector(openPullRequest)
        openButton.setAccessibilityLabel("Open pull request #\(summary.number)")
        addSubview(openButton)
        addSubview(detailsStack)
        addSubview(checksDonut)
        NSLayoutConstraint.activate([
            openButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            openButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            openButton.topAnchor.constraint(equalTo: topAnchor),
            openButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 44),
            detailsStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            detailsStack.trailingAnchor.constraint(equalTo: checksDonut.leadingAnchor, constant: -8),
            detailsStack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            detailsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            checksDonut.trailingAnchor.constraint(equalTo: trailingAnchor),
            checksDonut.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            checksDonut.widthAnchor.constraint(equalToConstant: 16),
            checksDonut.heightAnchor.constraint(equalToConstant: 16),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var hoverTrackingOptions: NSTrackingArea.Options {
        [.activeAlways, .mouseEnteredAndExited, .inVisibleRect]
    }

    override func hoverStateDidChange() {
        applyTheme()
        onChecksHover?(self, summary.checks, isHovering)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if pullRequestURL != nil {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return openButton
    }

    func applyTheme() {
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.label, weight: 600)
        titleLabel.textColor = isHovering && pullRequestURL != nil
            ? AppTheme.panelAccentIcon
            : AppTheme.primaryText
        metadataLabel.font = .monospacedSystemFont(ofSize: AppTheme.typography.label, weight: .regular)
        metadataLabel.textColor = AppTheme.secondaryText
        checksDonut.needsDisplay = true
    }

    @objc private func openPullRequest() {
        guard let pullRequestURL else { return }
        if let onOpen {
            onOpen(pullRequestURL)
        } else {
            NSWorkspace.shared.open(pullRequestURL)
        }
    }

}

@MainActor
private final class SidebarTaskAggregateInfoCard: NSView {
    private let titleLabel: NSTextField
    private let ageLabel: NSTextField
    private let repositoryValue = NSTextField(labelWithString: "0")
    private let sshValue = NSTextField(labelWithString: "0")
    private let connectedValue = NSTextField(labelWithString: "0")
    private let branchValue = NSTextField(labelWithString: "0")
    private let worktreeValue = NSTextField(labelWithString: "0")
    private let createdAt: Date
    private let contentWidth: CGFloat = 300
    private let horizontalInset: CGFloat = 16
    private let verticalInset: CGFloat = 14

    init(createdAt: Date, contexts: [SidebarRepositoryContext]) {
        self.createdAt = createdAt
        titleLabel = NSTextField(labelWithString: "Task overview")
        ageLabel = NSTextField(labelWithString: Self.ageLabel(for: createdAt))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.isSelectable = true
        ageLabel.isSelectable = true
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.borderWidth = 0

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        ageLabel.translatesAutoresizingMaskIntoConstraints = false
        ageLabel.alignment = .right
        header.addSubview(titleLabel)
        header.addSubview(ageLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: ageLabel.leadingAnchor, constant: -10),
            ageLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            ageLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])

        let metrics = NSStackView(views: [
            makeMetricRow(symbol: "folder", label: "Repositories", value: repositoryValue),
            makeMetricRow(symbol: "globe", label: "SSH connections", value: sshValue),
            makeMetricRow(symbol: "circle.fill", label: "Connected", value: connectedValue),
            makeMetricRow(symbol: "arrow.triangle.branch", label: "Branches", value: branchValue),
            makeMetricRow(symbol: "folder", label: "Worktrees", value: worktreeValue),
        ])
        metrics.orientation = .vertical
        metrics.alignment = .leading
        metrics.spacing = 5
        metrics.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [header, metrics])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: contentWidth + horizontalInset * 2),
            heightAnchor.constraint(equalToConstant: 194),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset),
            content.topAnchor.constraint(equalTo: topAnchor, constant: verticalInset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalInset),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            header.heightAnchor.constraint(equalToConstant: 26),
            metrics.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        update(contexts: contexts)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: contentWidth + horizontalInset * 2, height: 194)
    }

    func update(contexts: [SidebarRepositoryContext]) {
        let connectionIDs = Set(contexts.compactMap(\.connectionID))
        let connectedIDs = Set(
            contexts
                .filter { $0.status == .connected }
                .compactMap(\.connectionID)
        )
        repositoryValue.stringValue = "\(contexts.count)"
        sshValue.stringValue = "\(connectionIDs.count)"
        connectedValue.stringValue = connectionIDs.isEmpty
            ? "None"
            : "\(connectedIDs.count)/\(connectionIDs.count)"
        branchValue.stringValue = "\(Set(contexts.compactMap(\.branch)).count)"
        worktreeValue.stringValue = "\(contexts.filter { $0.path != nil }.count)"
        ageLabel.stringValue = Self.ageLabel(for: createdAt)
        applyTheme()
    }

    private func makeMetricRow(symbol: String, label: String, value: NSTextField) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let labelField = NSTextField(labelWithString: label)
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.isSelectable = true
        value.translatesAutoresizingMaskIntoConstraints = false
        value.isSelectable = true
        value.alignment = .right
        row.addSubview(icon)
        row.addSubview(labelField)
        row.addSubview(value)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 22),
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            labelField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            labelField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            value.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            value.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labelField.trailingAnchor.constraint(lessThanOrEqualTo: value.leadingAnchor, constant: -10),
        ])
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel(label)
        row.setAccessibilityValue(value.stringValue)
        return row
    }

    private func applyTheme() {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderColor = NSColor.clear.cgColor
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody, weight: 600)
        titleLabel.textColor = AppTheme.primaryText
        ageLabel.font = .monospacedSystemFont(ofSize: AppTheme.typography.label, weight: .regular)
        ageLabel.textColor = AppTheme.tertiaryText
        [repositoryValue, sshValue, connectedValue, branchValue, worktreeValue].forEach {
            $0.font = .monospacedSystemFont(ofSize: AppTheme.typography.label, weight: .regular)
            $0.textColor = AppTheme.primaryText
        }
        subviews
            .flatMap { $0.subviews }
            .compactMap { $0 as? NSStackView }
            .flatMap(\.arrangedSubviews)
            .forEach { row in
                row.subviews.compactMap { $0 as? NSImageView }.forEach {
                    $0.contentTintColor = AppTheme.tertiaryText
                }
                row.subviews.compactMap { $0 as? NSTextField }.forEach {
                    if ![repositoryValue, sshValue, connectedValue, branchValue, worktreeValue].contains($0) {
                        $0.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody, weight: 400)
                        $0.textColor = AppTheme.secondaryText
                    }
                }
            }
    }

    private static func ageLabel(for date: Date) -> String {
        let elapsed = max(0, Date().timeIntervalSince(date))
        if elapsed < 60 { return "now" }
        if elapsed < 60 * 60 { return "\(Int(elapsed / 60))m" }
        if elapsed < 60 * 60 * 24 { return "\(Int(elapsed / (60 * 60)))h" }
        return "\(Int(elapsed / (60 * 60 * 24)))d"
    }
}

@MainActor
private final class SidebarTaskInfoRepositoryRow: NSView {
    let repositoryID: UUID
    private var context: SidebarRepositoryContext
    private let nameLabel: NSTextField
    private let connectionLabel: NSTextField
    private let branchLabel: NSTextField
    private let pathLabel: NSTextField
    private let statusDot = SSHConnectionStatusIndicator(status: .disabled)
    private var icons: [NSImageView] = []
    private let contentStack = NSStackView()

    init(context: SidebarRepositoryContext) {
        repositoryID = context.repositoryID
        self.context = context
        nameLabel = NSTextField(labelWithString: context.name)
        connectionLabel = NSTextField(labelWithString: "")
        branchLabel = NSTextField(labelWithString: "")
        pathLabel = NSTextField(labelWithString: "")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        [nameLabel, connectionLabel, branchLabel, pathLabel].forEach {
            $0.isSelectable = true
        }
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 3
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        let header = makeHeader()
        let connection = makeConnectionRow()
        let branch = makeMetadataRow(symbol: "arrow.triangle.branch", label: branchLabel)
        let path = makeMetadataRow(symbol: "folder", label: pathLabel)
        [header, connection, branch, path].forEach {
            contentStack.addArrangedSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.heightAnchor.constraint(equalToConstant: 26),
            connection.heightAnchor.constraint(equalToConstant: 20),
            branch.heightAnchor.constraint(equalToConstant: 20),
            path.heightAnchor.constraint(equalToConstant: 20),
            widthAnchor.constraint(equalToConstant: 368),
            heightAnchor.constraint(equalToConstant: 95),
        ])
        update(context: context)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 368, height: 95)
    }

    func update(context: SidebarRepositoryContext) {
        self.context = context
        nameLabel.stringValue = context.name
        connectionLabel.stringValue = context.connectionID == nil
            ? "Local repository"
            : context.connectionName ?? "SSH"
        branchLabel.stringValue = context.branch ?? "Branch unavailable"
        branchLabel.toolTip = context.branch.map { "Observed branch: \($0)" }
        branchLabel.setAccessibilityLabel("Observed branch")
        pathLabel.stringValue = context.path ?? "Path unavailable"
        pathLabel.toolTip = context.path
        statusDot.status = context.status
        statusDot.isHidden = context.connectionID == nil
        applyTheme()
    }

    func applyTheme() {
        nameLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody, weight: 600)
        nameLabel.textColor = AppTheme.primaryText
        connectionLabel.font = .monospacedSystemFont(ofSize: AppTheme.typography.label, weight: .regular)
        connectionLabel.textColor = context.connectionID == nil
            ? AppTheme.tertiaryText
            : AppTheme.secondaryText
        branchLabel.font = .monospacedSystemFont(ofSize: AppTheme.typography.label, weight: .regular)
        branchLabel.textColor = AppTheme.secondaryText
        pathLabel.font = .monospacedSystemFont(ofSize: AppTheme.typography.label, weight: .regular)
        pathLabel.textColor = AppTheme.secondaryText
        icons.forEach { $0.contentTintColor = AppTheme.tertiaryText }
        statusDot.status = context.status
    }

    private func makeHeader() -> NSView {
        let row = NSView()
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: "Repository")
        icon.translatesAutoresizingMaskIntoConstraints = false
        icons.append(icon)
        row.addSubview(icon)
        row.addSubview(nameLabel)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])
        return row
    }

    private func makeConnectionRow() -> NSView {
        let row = NSView()
        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: context.connectionID == nil ? "laptopcomputer" : "globe",
            accessibilityDescription: nil
        )
        icon.translatesAutoresizingMaskIntoConstraints = false
        icons.append(icon)
        connectionLabel.translatesAutoresizingMaskIntoConstraints = false
        connectionLabel.usesSingleLineMode = true
        connectionLabel.lineBreakMode = .byTruncatingMiddle
        row.addSubview(icon)
        row.addSubview(connectionLabel)
        row.addSubview(statusDot)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            connectionLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            connectionLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            connectionLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusDot.leadingAnchor, constant: -8),
            statusDot.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            statusDot.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
        ])
        return row
    }

    private func makeMetadataRow(symbol: String, label: NSTextField) -> NSView {
        let row = NSView()
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icons.append(icon)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingMiddle
        row.addSubview(icon)
        row.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])
        return row
    }
}

@MainActor
private final class SidebarMessageView: NSView {
    private let error: Bool
    private let label: NSTextField

    init(_ message: String, error: Bool) {
        self.error = error
        label = NSTextField(wrappingLabelWithString: message)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        label.font = AppTheme.font(ofSize: AppTheme.typography.body)
        label.textColor = error ? AppTheme.error : AppTheme.tertiaryText
    }
}

@MainActor
private final class PanelTrackingView: AppHoverView {
    var onHoverChanged: ((Bool) -> Void)?

    override func hoverStateDidChange() {
        onHoverChanged?(isHovering)
    }
}

@MainActor
private final class FileTreeNode: NSObject {
    enum Content {
        case entry(FileTreeEntry)
        case loading
        case error(String)
        case message(String)
    }

    var content: Content
    let path: String

    init(content: Content, path: String) {
        self.content = content
        self.path = path
    }

    var entry: FileTreeEntry? {
        guard case .entry(let entry) = content else { return nil }
        return entry
    }
}

private final class FileTreeEventHandlerBox: @unchecked Sendable {
    let onChange: @Sendable ([String]) -> Void

    init(onChange: @escaping @Sendable ([String]) -> Void) {
        self.onChange = onChange
    }
}

private final class FileTreeRootWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?

    init?(
        path: String,
        queue: DispatchQueue,
        onChange: @escaping @Sendable ([String]) -> Void
    ) {
        let handler = FileTreeEventHandlerBox(onChange: onChange)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<FileTreeEventHandlerBox>.fromOpaque(info).retain()
                return UnsafeRawPointer(info)
            },
            release: { info in
                guard let info else { return }
                Unmanaged<FileTreeEventHandlerBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, count, eventPaths, _, _ in
                guard let info else { return }
                let handler = Unmanaged<FileTreeEventHandlerBox>
                    .fromOpaque(info)
                    .takeUnretainedValue()
                let paths = Unmanaged<CFArray>
                    .fromOpaque(eventPaths)
                    .takeUnretainedValue() as? [String] ?? []
                if count > 0 { handler.onChange(paths) }
            },
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagWatchRoot
            )
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    func cancel() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        cancel()
    }
}

private final class FileTreeClipView: NSClipView {
    private var maximumX: CGFloat {
        max(0, (documentView?.frame.width ?? bounds.width) - bounds.width)
    }

    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: NSPoint(x: min(max(0, newOrigin.x), maximumX), y: newOrigin.y))
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        bounds.origin.x = min(max(0, bounds.origin.x), maximumX)
        return bounds
    }
}

private final class FileTreeScrollView: NSScrollView {
    var requiredDocumentWidth: CGFloat = 0 {
        didSet { needsLayout = true }
    }

    override func layout() {
        super.layout()
        guard let documentView else { return }
        let width = max(contentView.bounds.width, requiredDocumentWidth)
        guard width > 0 else { return }
        if let tableView = documentView as? NSTableView {
            tableView.tableColumns.first?.width = width
        }
        guard abs(documentView.frame.width - width) > 0.5 else { return }
        var frame = documentView.frame
        frame.size.width = width
        documentView.frame = frame
    }
}

private final class FileTreeOutlineView: NSOutlineView {
    override func makeView(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        owner: Any?
    ) -> NSView? {
        let view = super.makeView(withIdentifier: identifier, owner: owner)
        guard identifier == NSOutlineView.disclosureButtonIdentifier,
              let button = view as? NSButton
        else { return view }

        let configuration = NSImage.SymbolConfiguration(
            pointSize: AppTheme.sidebarDisclosureSymbolSize,
            weight: .regular
        )
        button.image = NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: "Expand"
        )?.withSymbolConfiguration(configuration)
        button.alternateImage = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: "Collapse"
        )?.withSymbolConfiguration(configuration)
        button.contentTintColor = AppTheme.tertiaryText
        button.isBordered = false
        return button
    }
}

@MainActor
private final class FileTreeCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FileTreeCell")

    var onActivate: ((NSEvent) -> Void)?
    var onRetry: (() -> Void)?

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let retry = NSButton(title: "Retry", target: nil, action: nil)
    private static let loadingPulseKey = "loadingPulse"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        icon.imageAlignment = .alignCenter
        icon.imageScaling = .scaleProportionallyDown
        title.usesSingleLineMode = true
        title.lineBreakMode = .byTruncatingTail
        retry.isBordered = false
        retry.target = self
        retry.action = #selector(retryLoad)
        addSubview(icon)
        addSubview(title)
        addSubview(retry)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layout() {
        super.layout()
        let contentInset: CGFloat = 2
        let iconSize: CGFloat = 14
        let iconGap: CGFloat = 3
        let retryWidth: CGFloat = retry.isHidden
            ? 0
            : ceil(retry.intrinsicContentSize.width) + 4
        let titleX: CGFloat = icon.isHidden ? contentInset : contentInset + iconSize + iconGap
        let titleHeight = min(bounds.height, ceil(title.intrinsicContentSize.height))
        let retryHeight = min(bounds.height, ceil(retry.intrinsicContentSize.height))
        icon.frame = NSRect(
            x: contentInset,
            y: floor((bounds.height - iconSize) / 2),
            width: iconSize,
            height: iconSize
        )
        retry.frame = NSRect(
            x: max(titleX, bounds.width - retryWidth - 4),
            y: floor((bounds.height - retryHeight) / 2),
            width: retryWidth,
            height: retryHeight
        )
        title.frame = NSRect(
            x: titleX,
            y: floor((bounds.height - titleHeight) / 2) + 1,
            width: max(0, bounds.width - titleX - retryWidth - (retryWidth > 0 ? 8 : 0)),
            height: titleHeight
        )
    }

    override func mouseDown(with event: NSEvent) {
        if onActivate != nil {
            onActivate?(event)
        } else {
            super.mouseDown(with: event)
        }
    }

    func configure(with node: FileTreeNode, font: NSFont, retryFont: NSFont) {
        onActivate = nil
        onRetry = nil
        retry.isHidden = true
        icon.isHidden = false
        title.layer?.removeAnimation(forKey: Self.loadingPulseKey)
        title.alphaValue = 1
        title.font = font
        title.textColor = AppTheme.secondaryText
        retry.font = retryFont
        retry.contentTintColor = AppTheme.accent

        switch node.content {
        case .entry(let entry):
            let name = entry.name
            title.stringValue = name.isEmpty ? entry.path : name
            let descriptor = FileTreeIconResolver.descriptor(
                for: title.stringValue,
                isDirectory: entry.isDirectory
            )
            icon.image = FileTreeIconResolver.image(for: descriptor)
            icon.contentTintColor = FileTreeIconResolver.tintColor(for: descriptor)
        case .loading:
            title.stringValue = "Loading…"
            title.textColor = AppTheme.tertiaryText
            icon.isHidden = true
            title.wantsLayer = true
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.4
            pulse.toValue = 1
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            title.layer?.add(pulse, forKey: Self.loadingPulseKey)
        case .error(let message):
            title.stringValue = message
            title.textColor = AppTheme.error
            icon.isHidden = true
            retry.isHidden = false
        case .message(let message):
            title.stringValue = message
            title.textColor = AppTheme.tertiaryText
            icon.isHidden = true
        }
        needsLayout = true
    }

    @objc private func retryLoad() {
        onRetry?()
    }
}

@MainActor
final class WorkspacePanelViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onTogglePanel: (() -> Void)?
    var onOpenFile: ((FileTreeEntry, Bool) -> Void)?

    private struct FileRoot: Equatable {
        let name: String
        let path: String
        let target: TerminalTarget
    }

    private struct PrefetchCandidate: Sendable {
        let path: String
        let depth: Int
    }

    private static let prefetchDepth = 2
    private static let prefetchBatchSize = 8
    private static let prefetchDirectoryLimit = 64
    private static let prefetchEntryLimit = 5_000
    private static let cachedDirectoryLimit = 256
    private static let cachedEntryLimit = 20_000
    private static let liveRefreshDebounce = Duration.milliseconds(150)
    private static let remotePollInterval = Duration.seconds(2)

    private let divider = NSView()
    private let sections = NSStackView()
    private let emptyState = NSTextField(labelWithString: "Nothing here yet.")
    private let fileScrollView = FileTreeScrollView()
    private let fileOutline = FileTreeOutlineView()
    private let fileColumn = NSTableColumn(identifier: .init("FileTreeColumn"))
    private var fileTreeFont = AppTheme.font(ofSize: AppTheme.typography.body)
    private var fileTreeRetryFont = AppTheme.font(
        ofSize: AppTheme.typography.label,
        weight: 600
    )
    private let fileCacheStore: FileTreeCacheStore
    private let fileCacheQueue = DispatchQueue(label: "dev.pinata.file-tree-cache")
    private let fileWatchQueue = DispatchQueue(label: "dev.pinata.file-tree-watch")
    private let toggleButton = PanelToggleButton(
        symbolName: "sidebar.right",
        accessibilityLabel: "Toggle workspace panel"
    )
    private var sectionButtons: [WorkspacePanelTabButton] = []
    private var selectedSection = 0
    private var fileRoot: FileRoot?
    private var fileEntries: [String: [FileTreeEntry]] = [:]
    private lazy var fileCaches = (try? fileCacheStore.load()) ?? [:]
    private var fileErrors: [String: String] = [:]
    private var expandedPaths = Set<String>()
    private var fileNodes: [String: FileTreeNode] = [:]
    private var fileLoadTasks: [String: Task<[FileTreeEntry], Error>] = [:]
    private var filePrefetchTask: Task<Void, Never>?
    private var filePrefetchID: UUID?
    private var prefetchingPaths = Set<String>()
    private var fileRefreshTask: Task<Void, Never>?
    private var fileRefreshID: UUID?
    private var refreshingPaths = Set<String>()
    private var fileCacheDirty = false
    private var fileEntryAccessOrder: [String: UInt64] = [:]
    private var fileEntryAccessCounter: UInt64 = 0
    private var filePrefetchResumeTask: Task<Void, Never>?
    private var deferredReloadPaths = Set<String>()
    private var isFileTreeLiveScrolling = false
    private var isRestoringExpandedPaths = false
    private var isReloadingFileTree = false
    private var isCollapsingFileBranch = false
    private var isPanelVisible = false
    private var localRootWatcher: FileTreeRootWatcher?
    private var remotePollingTask: Task<Void, Never>?
    private var remoteDirectorySignatures: [String: String] = [:]
    private var liveRefreshDebounceTask: Task<Void, Never>?
    private var liveRefreshTask: Task<Void, Never>?
    private var liveRefreshID: UUID?
    private var pendingLiveRefreshPaths = Set<String>()

    init(fileCacheStore: FileTreeCacheStore = FileTreeCacheStore()) {
        self.fileCacheStore = fileCacheStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let rootView = NSView()
        rootView.wantsLayer = true
        rootView.setAccessibilityRole(.group)
        rootView.setAccessibilityLabel("Workspace panel")
        view = rootView

        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        toggleButton.panelVisible = true
        toggleButton.target = self
        toggleButton.action = #selector(togglePanel)
        toggleButton.toolTip = "Toggle workspace panel (⌘L)"
        sections.translatesAutoresizingMaskIntoConstraints = false
        sections.orientation = .horizontal
        sections.alignment = .centerY
        sections.spacing = 4
        let titles: [String] = ["Files", "Review", "PR"]
        for (index, title) in titles.enumerated() {
            let button = WorkspacePanelTabButton(title: title, index: index)
            button.target = self
            button.action = #selector(selectSection(_:))
            sections.addArrangedSubview(button)
            sectionButtons.append(button)
        }
        sectionButtons.first?.isVisuallySelected = true
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        fileScrollView.translatesAutoresizingMaskIntoConstraints = false
        fileScrollView.hasVerticalScroller = true
        fileScrollView.hasHorizontalScroller = true
        fileScrollView.autohidesScrollers = true
        fileScrollView.horizontalScrollElasticity = .none
        fileScrollView.drawsBackground = false
        fileScrollView.contentView = FileTreeClipView()
        fileScrollView.contentView.drawsBackground = false
        fileOutline.addTableColumn(fileColumn)
        fileOutline.outlineTableColumn = fileColumn
        fileOutline.headerView = nil
        fileOutline.backgroundColor = .clear
        fileOutline.rowHeight = 24
        fileOutline.intercellSpacing = .zero
        fileOutline.indentationPerLevel = 16
        fileOutline.selectionHighlightStyle = .none
        fileOutline.focusRingType = .none
        fileOutline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        fileOutline.autoresizesOutlineColumn = false
        fileOutline.autoresizingMask = []
        fileOutline.dataSource = self
        fileOutline.delegate = self
        fileColumn.minWidth = 120
        fileColumn.width = AppTheme.rightPanelWidth
        fileColumn.resizingMask = []
        fileScrollView.documentView = fileOutline
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(flushFileCaches),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fileTreeWillStartLiveScroll),
            name: NSScrollView.willStartLiveScrollNotification,
            object: fileScrollView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fileTreeDidEndLiveScroll),
            name: NSScrollView.didEndLiveScrollNotification,
            object: fileScrollView
        )

        rootView.addSubview(divider)
        rootView.addSubview(sections)
        rootView.addSubview(emptyState)
        rootView.addSubview(fileScrollView)
        rootView.addSubview(toggleButton)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            divider.topAnchor.constraint(equalTo: rootView.topAnchor),
            divider.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: AppTheme.workspaceDividerThickness),

            sections.leadingAnchor.constraint(
                equalTo: rootView.leadingAnchor,
                constant: AppTheme.workspacePanelHeaderInset
            ),
            sections.centerYAnchor.constraint(
                equalTo: rootView.topAnchor,
                constant: AppTheme.mainHeaderHeight / 2
            ),
            sections.heightAnchor.constraint(equalToConstant: AppTheme.workspaceTabHeight),
            sections.trailingAnchor.constraint(lessThanOrEqualTo: toggleButton.leadingAnchor),

            emptyState.leadingAnchor.constraint(
                equalTo: rootView.leadingAnchor,
                constant: AppTheme.workspacePanelHeaderInset
            ),
            emptyState.topAnchor.constraint(
                equalTo: rootView.topAnchor,
                constant: AppTheme.mainHeaderHeight + AppTheme.workspacePanelHeaderInset
            ),

            fileScrollView.leadingAnchor.constraint(
                equalTo: rootView.leadingAnchor,
                constant: AppTheme.workspaceFileTreeInset
            ),
            fileScrollView.trailingAnchor.constraint(
                equalTo: rootView.trailingAnchor,
                constant: -AppTheme.workspaceFileTreeInset
            ),
            fileScrollView.topAnchor.constraint(
                equalTo: rootView.topAnchor,
                constant: AppTheme.mainHeaderHeight + AppTheme.workspaceFileTreeInset
            ),
            fileScrollView.bottomAnchor.constraint(
                equalTo: rootView.bottomAnchor,
                constant: -AppTheme.workspaceFileTreeInset
            ),

            toggleButton.centerYAnchor.constraint(
                equalTo: rootView.topAnchor,
                constant: AppTheme.mainHeaderHeight / 2
            ),
            toggleButton.trailingAnchor.constraint(
                equalTo: rootView.trailingAnchor,
                constant: -AppTheme.workspacePanelHeaderInset
            ),
        ])
        applyTheme()
        updateContent()
    }

    func setFileRoot(name: String?, workingDirectory: String?, target: TerminalTarget?) {
        let root: FileRoot? = switch (name, workingDirectory, target) {
        case let (.some(name), .some(path), .some(target)):
            FileRoot(name: name, path: path, target: target)
        default: nil
        }
        guard root != fileRoot else { return }
        persistFileCaches()
        stopFileMonitoring()
        fileLoadTasks.values.forEach { $0.cancel() }
        filePrefetchTask?.cancel()
        filePrefetchResumeTask?.cancel()
        fileRefreshTask?.cancel()
        fileLoadTasks = [:]
        filePrefetchTask = nil
        filePrefetchID = nil
        prefetchingPaths = []
        fileRefreshTask = nil
        fileRefreshID = nil
        refreshingPaths = []
        deferredReloadPaths = []
        isFileTreeLiveScrolling = false
        fileNodes = [:]
        let cached = root.flatMap {
            fileCaches[FileTreeCacheKey(path: $0.path, target: $0.target)]
        }
        if let root, case .ssh = root.target {
            fileEntries = [:]
        } else {
            fileEntries = cached?.entries ?? [:]
        }
        fileEntryAccessOrder = [:]
        fileEntryAccessCounter = 0
        touchFileEntries(fileEntries.keys)
        fileErrors = [:]
        fileRoot = root
        expandedPaths = root.map {
            normalizedExpandedPaths(
                cached?.expandedPaths ?? [$0.path],
                root: $0,
                cachedEntries: cached?.entries ?? [:]
            )
        } ?? []
        let loadedDirectoryCount = fileEntries.count
        trimInactiveFileEntries()
        if fileEntries.count != loadedDirectoryCount { fileCacheDirty = true }
        if isViewLoaded {
            fileOutline.reloadData()
            restoreExpandedPaths()
            updateFileTreeWidth()
            updateContent()
        }
        if let root {
            if fileEntries[root.path] == nil {
                loadChildren(of: root.path)
            } else {
                refreshCachedDirectory(at: root.path, root: root)
            }
        }
    }

    func invalidateFileCaches(at paths: Set<String>) {
        guard !paths.isEmpty else { return }
        fileCaches = fileCaches.filter { !paths.contains($0.key.path) }
        fileCacheDirty = true
        guard let root = fileRoot, paths.contains(root.path) else {
            persistFileCaches()
            return
        }
        stopFileMonitoring()
        fileLoadTasks.values.forEach { $0.cancel() }
        filePrefetchTask?.cancel()
        filePrefetchResumeTask?.cancel()
        fileRefreshTask?.cancel()
        fileEntries = [:]
        fileErrors = [:]
        filePrefetchTask = nil
        filePrefetchID = nil
        prefetchingPaths = []
        filePrefetchResumeTask = nil
        fileRefreshTask = nil
        fileRefreshID = nil
        refreshingPaths = []
        deferredReloadPaths = []
        isFileTreeLiveScrolling = false
        fileNodes = [:]
        fileEntryAccessOrder = [:]
        if isViewLoaded {
            fileOutline.reloadData()
            updateFileTreeWidth()
        }
        persistFileCaches(captureCurrent: false)
    }

    func panelDidShow() {
        isPanelVisible = true
        guard selectedSection == 0 else { return }
        ensureFileRootExpanded()
        restoreExpandedPaths()
        updateFileMonitoring()
        if let root = fileRoot {
            enqueueLiveRefresh(paths: visibleDirectoryPaths(for: root), debounce: false)
        }
    }

    func panelDidHide() {
        isPanelVisible = false
        stopFileMonitoring()
        persistFileCaches()
    }

    func applyTheme() {
        view.layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        divider.layer?.backgroundColor = AppTheme.border.cgColor
        toggleButton.applyTheme()
        fileTreeFont = AppTheme.font(ofSize: AppTheme.typography.body)
        fileTreeRetryFont = AppTheme.font(ofSize: AppTheme.typography.label, weight: 600)
        emptyState.font = AppTheme.font(ofSize: AppTheme.typography.body)
        emptyState.textColor = AppTheme.tertiaryText
        sectionButtons.forEach {
            $0.font = AppTheme.font(ofSize: AppTheme.typography.label, weight: 600)
            $0.applyTheme()
        }
        if isViewLoaded {
            fileOutline.reloadData()
            updateFileTreeWidth()
        }
        updateContent()
    }

    @objc private func selectSection(_ sender: NSButton) {
        sectionButtons.forEach { $0.isVisuallySelected = $0 === sender }
        selectedSection = sender.tag
        updateContent()
    }

    @objc private func togglePanel() {
        onTogglePanel?()
    }

    private func updateContent() {
        guard isViewLoaded else { return }
        let showsFiles = selectedSection == 0
        fileScrollView.isHidden = !showsFiles
        emptyState.isHidden = showsFiles
        guard showsFiles, isPanelVisible else {
            stopFileMonitoring()
            return
        }
        ensureFileRootExpanded()
        restoreExpandedPaths()
        updateFileMonitoring()
    }

    private func ensureFileRootExpanded() {
        guard let root = fileRoot else { return }
        let inserted = expandedPaths.insert(root.path).inserted
        guard isViewLoaded, let node = rootNode(for: root.path) else { return }
        if !fileOutline.isItemExpanded(node) {
            isRestoringExpandedPaths = true
            fileOutline.expandItem(node)
            isRestoringExpandedPaths = false
        }
        if inserted { saveCurrentFileCache() }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        guard let item else { return fileRoot == nil ? 1 : 1 }
        guard let node = item as? FileTreeNode, let entry = node.entry, entry.isDirectory else {
            return 0
        }
        if let entries = fileEntries[entry.path] { return entries.count }
        return 1
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        guard let item else {
            guard let root = fileRoot else {
                return FileTreeNode(
                    content: .message("Select a workspace to browse files."),
                    path: "message:empty"
                )
            }
            return node(
                for: FileTreeEntry(
                    path: root.path,
                    isDirectory: true,
                    displayName: root.name
                )
            )
        }
        guard let parent = item as? FileTreeNode, let entry = parent.entry else {
            return FileTreeNode(content: .message(""), path: "message:invalid")
        }
        if let entries = fileEntries[entry.path] { return node(for: entries[index]) }
        if let message = fileErrors[entry.path] {
            return FileTreeNode(content: .error(message), path: "error:\(entry.path)")
        }
        return FileTreeNode(content: .loading, path: "loading:\(entry.path)")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let entry = (item as? FileTreeNode)?.entry, entry.isDirectory else { return false }
        return fileEntries[entry.path]?.isEmpty != true
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? FileTreeNode else { return nil }
        let cell = outlineView.makeView(
            withIdentifier: FileTreeCellView.identifier,
            owner: self
        ) as? FileTreeCellView ?? FileTreeCellView(frame: .zero)
        cell.configure(with: node, font: fileTreeFont, retryFont: fileTreeRetryFont)
        if let entry = node.entry, entry.isDirectory {
            cell.onActivate = { [weak self, weak outlineView, weak node] event in
                guard let self, let outlineView, let node else { return }
                if event.modifierFlags.contains(.command) {
                    self.collapseFileBranch(node)
                } else if outlineView.isItemExpanded(node) {
                    outlineView.collapseItem(node)
                } else {
                    outlineView.expandItem(node)
                }
            }
        } else if let entry = node.entry {
            cell.onActivate = { [weak self] event in
                self?.onOpenFile?(entry, event.clickCount >= 2)
            }
        }
        if case .error = node.content {
            let path = String(node.path.dropFirst("error:".count))
            cell.onRetry = { [weak self] in
                self?.fileErrors[path] = nil
                self?.reloadDirectory(path)
                self?.prioritizeLoad(of: path)
            }
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let entry = (item as? FileTreeNode)?.entry, entry.isDirectory else { return false }
        expandedPaths.insert(entry.path)
        touchFileEntries([entry.path])
        DispatchQueue.main.async { [weak self] in
            self?.updateFileTreeWidth()
            self?.updateFileMonitoring()
        }
        if isRestoringExpandedPaths {
            if fileEntries[entry.path] == nil { prioritizeLoad(of: entry.path) }
            return true
        }
        saveCurrentFileCache()
        if let entries = fileEntries[entry.path], let root = fileRoot {
            startPrefetching(from: entries, root: root)
            if entry.path != root.path {
                refreshCachedDirectory(at: entry.path, root: root)
            }
        } else {
            prioritizeLoad(of: entry.path)
        }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        guard let node = item as? FileTreeNode, let entry = node.entry else { return false }
        if isCollapsingFileBranch || isReloadingFileTree { return true }
        expandedPaths = expandedPaths.filter { !contains($0, in: entry.path) }
        saveCurrentFileCache()
        DispatchQueue.main.async { [weak self] in
            self?.updateFileTreeWidth()
            self?.updateFileMonitoring()
        }
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            DispatchQueue.main.async { [weak self, weak node] in
                guard let node else { return }
                self?.collapseFileBranch(node)
            }
        }
        return true
    }

    private func collapseFileBranch(_ node: FileTreeNode) {
        guard let entry = node.entry, entry.isDirectory else { return }
        isCollapsingFileBranch = true
        fileOutline.collapseItem(node, collapseChildren: true)
        isCollapsingFileBranch = false
        expandedPaths = expandedPaths.filter { !contains($0, in: entry.path) }
        saveCurrentFileCache()
        updateFileMonitoring()
    }

    private func node(for entry: FileTreeEntry) -> FileTreeNode {
        if let node = fileNodes[entry.path] {
            node.content = .entry(entry)
            return node
        }
        let node = FileTreeNode(content: .entry(entry), path: entry.path)
        fileNodes[entry.path] = node
        return node
    }

    private func restoreExpandedPaths(_ paths: Set<String>? = nil) {
        guard isViewLoaded, selectedSection == 0 else { return }
        isRestoringExpandedPaths = true
        defer { isRestoringExpandedPaths = false }
        for path in (paths ?? expandedPaths).sorted(by: { pathDepth($0) < pathDepth($1) }) {
            guard let node = fileNodes[path] ?? rootNode(for: path) else { continue }
            fileOutline.expandItem(node)
        }
    }

    private func rootNode(for path: String) -> FileTreeNode? {
        guard let root = fileRoot, root.path == path else { return nil }
        return node(
            for: FileTreeEntry(path: root.path, isDirectory: true, displayName: root.name)
        )
    }

    private func pathDepth(_ path: String) -> Int {
        path.split(separator: "/").count
    }

    private func normalizedExpandedPaths(
        _ paths: Set<String>,
        root: FileRoot,
        cachedEntries: [String: [FileTreeEntry]]
    ) -> Set<String> {
        var normalized: Set<String> = [root.path]
        let rootChildren = Set(
            (cachedEntries[root.path] ?? [])
                .filter(\.isDirectory)
                .map(\.path)
        )
        for path in paths.sorted(by: { pathDepth($0) < pathDepth($1) }) {
            guard path != root.path else { continue }
            let isRootChild = rootChildren.contains(path)
            let hasExpandedParent = RemoteDirectoryInspector
                .parent(of: path)
                .map { normalized.contains($0) } ?? false
            if isRootChild || hasExpandedParent {
                normalized.insert(path)
            }
        }
        return normalized
    }

    private func reloadDirectory(_ path: String) {
        reloadDirectories([path])
    }

    private func reloadDirectories(_ paths: [String]) {
        guard isViewLoaded else { return }
        if isFileTreeLiveScrolling {
            deferredReloadPaths.formUnion(paths)
            return
        }
        let pathsToRestore = expandedPaths.filter { expandedPath in
            paths.contains(where: { changedPath in
                contains(expandedPath, in: changedPath)
            })
        }
        var didReload = false
        isReloadingFileTree = true
        for path in paths {
            guard let node = fileNodes[path] ?? rootNode(for: path) else { continue }
            fileOutline.reloadItem(node, reloadChildren: true)
            didReload = true
        }
        isReloadingFileTree = false
        if didReload {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.restoreExpandedPaths(pathsToRestore)
                self.updateFileTreeWidth()
            }
        }
    }

    private func updateFileTreeWidth() {
        guard let root = fileRoot else {
            fileScrollView.requiredDocumentWidth = 0
            fileScrollView.layoutSubtreeIfNeeded()
            return
        }
        var requiredWidth: CGFloat = 0
        var entries = [(FileTreeEntry(path: root.path, isDirectory: true, displayName: root.name), 0)]
        while let (entry, level) = entries.popLast() {
            let name = entry.name.isEmpty ? entry.path : entry.name
            let labelWidth = ceil(
                (name as NSString).size(withAttributes: [.font: fileTreeFont]).width
            )
            requiredWidth = max(
                requiredWidth,
                CGFloat(level + 1) * fileOutline.indentationPerLevel + 17 + labelWidth + 12
            )
            guard entry.isDirectory,
                  expandedPaths.contains(entry.path),
                  let children = fileEntries[entry.path]
            else { continue }
            entries.append(contentsOf: children.map { ($0, level + 1) })
        }
        fileScrollView.requiredDocumentWidth = requiredWidth
        fileScrollView.layoutSubtreeIfNeeded()
    }

    private func contains(_ path: String, in branch: String) -> Bool {
        path == branch || path.hasPrefix(branch.hasSuffix("/") ? branch : branch + "/")
    }

    @objc private func fileTreeWillStartLiveScroll() {
        isFileTreeLiveScrolling = true
        filePrefetchResumeTask?.cancel()
        filePrefetchTask?.cancel()
        filePrefetchTask = nil
        filePrefetchID = nil
        prefetchingPaths = []
    }

    @objc private func fileTreeDidEndLiveScroll() {
        isFileTreeLiveScrolling = false
        let paths = Array(deferredReloadPaths)
        deferredReloadPaths = []
        reloadDirectories(paths)

        filePrefetchResumeTask?.cancel()
        filePrefetchResumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled,
                  let self,
                  !self.isFileTreeLiveScrolling,
                  let root = self.fileRoot,
                  let entries = self.fileEntries[root.path]
            else { return }
            self.startPrefetching(from: entries, root: root)
        }
    }

    private func prioritizeLoad(of path: String) {
        guard fileEntries[path] == nil else { return }
        fileErrors[path] = nil
        if prefetchingPaths.contains(path) {
            filePrefetchTask?.cancel()
            filePrefetchTask = nil
            filePrefetchID = nil
            prefetchingPaths = []
        }
        if refreshingPaths.contains(path) {
            fileRefreshTask?.cancel()
            fileRefreshTask = nil
            fileRefreshID = nil
            refreshingPaths = []
        }
        loadChildren(of: path)
    }

    private func loadChildren(of path: String) {
        guard let root = fileRoot,
              fileLoadTasks[path] == nil,
              !prefetchingPaths.contains(path),
              !refreshingPaths.contains(path)
        else { return }
        let task = Task.detached(priority: .userInitiated) {
            try FileTreeInspector().children(at: path, target: root.target)
        }
        fileLoadTasks[path] = task
        Task { [weak self] in
            var loadedEntries: [FileTreeEntry]?
            do {
                let entries = try await task.value
                guard !Task.isCancelled, let self, self.fileRoot == root else { return }
                self.fileEntries[path] = entries
                if path == root.path,
                   case .ssh = root.target,
                   let cached = self.fileCaches[
                       FileTreeCacheKey(path: root.path, target: root.target)
                   ] {
                    self.fileEntries.merge(cached.entries) { current, _ in current }
                }
                self.touchFileEntries([path])
                self.trimInactiveFileEntries()
                self.fileErrors[path] = nil
                loadedEntries = entries
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.fileRoot == root else { return }
                self.fileErrors[path] = error.localizedDescription
            }
            self?.fileLoadTasks[path] = nil
            self?.reloadDirectory(path)
            if path == root.path { self?.restoreExpandedPaths() }
            self?.saveCurrentFileCache()
            self?.updateFileMonitoring()
            if let loadedEntries {
                self?.startPrefetching(from: loadedEntries, root: root)
            }
        }
    }

    private func saveCurrentFileCache() {
        guard let root = fileRoot, fileEntries[root.path] != nil else { return }
        fileCacheDirty = true
        touchFileEntries([root.path])
        trimInactiveFileEntries()
    }

    private func captureCurrentFileCache() {
        guard let root = fileRoot, fileEntries[root.path] != nil else { return }
        let key = FileTreeCacheKey(path: root.path, target: root.target)
        let activeExpandedPaths = activeExpandedPaths()
        expandedPaths = activeExpandedPaths
        fileCaches[key] = FileTreeCache(
            key: key,
            entries: limitedFileEntries(),
            expandedPaths: activeExpandedPaths,
            updatedAt: Date()
        )
        let retainedKeys = Set(
            fileCaches.values
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(FileTreeCacheStore.maximumCacheCount)
                .map(\.key)
        )
        fileCaches = fileCaches.filter { retainedKeys.contains($0.key) }
        fileCacheDirty = true
    }

    private func persistFileCaches(captureCurrent: Bool = true) {
        guard fileCacheDirty else { return }
        if captureCurrent { captureCurrentFileCache() }
        fileCacheDirty = false
        let store = fileCacheStore
        let caches = fileCaches
        fileCacheQueue.async {
            try? store.save(caches)
        }
    }

    @objc private func flushFileCaches() {
        if fileCacheDirty { captureCurrentFileCache() }
        fileCacheDirty = false
        let caches = fileCaches
        fileCacheQueue.sync {
            try? fileCacheStore.save(caches)
        }
    }

    private func touchFileEntries<S: Sequence>(_ paths: S) where S.Element == String {
        for path in paths where fileEntries[path] != nil {
            fileEntryAccessCounter &+= 1
            fileEntryAccessOrder[path] = fileEntryAccessCounter
        }
    }

    private func activeExpandedPaths() -> Set<String> {
        Set(fileNodes.compactMap { path, node in
            fileOutline.row(forItem: node) >= 0 && fileOutline.isItemExpanded(node) ? path : nil
        })
    }

    private func trimInactiveFileEntries() {
        guard let root = fileRoot else { return }
        var directoryCount = fileEntries.count
        var entryCount = fileEntries.values.reduce(0) { $0 + $1.count }
        guard directoryCount > Self.cachedDirectoryLimit
                || entryCount > Self.cachedEntryLimit
        else { return }
        let protected = activeExpandedPaths().union([root.path])
        let candidates = fileEntries.keys
            .filter { !protected.contains($0) }
            .sorted { fileEntryAccessOrder[$0, default: 0] < fileEntryAccessOrder[$1, default: 0] }
        for path in candidates {
            guard directoryCount > Self.cachedDirectoryLimit
                    || entryCount > Self.cachedEntryLimit
            else { break }
            let prefix = path.hasSuffix("/") ? path : path + "/"
            let removedPaths = fileEntries.keys.filter {
                $0 == path || $0.hasPrefix(prefix)
            }
            for removedPath in removedPaths {
                entryCount -= fileEntries.removeValue(forKey: removedPath)?.count ?? 0
                fileEntryAccessOrder.removeValue(forKey: removedPath)
            }
            fileNodes = fileNodes.filter { key, _ in
                key == path || !key.hasPrefix(prefix)
            }
            directoryCount -= removedPaths.count
        }
    }

    private func limitedFileEntries() -> [String: [FileTreeEntry]] {
        guard let root = fileRoot else { return [:] }
        let paths = fileEntries.keys.sorted {
            if $0 == root.path { return true }
            if $1 == root.path { return false }
            return fileEntryAccessOrder[$0, default: 0] > fileEntryAccessOrder[$1, default: 0]
        }
        var result: [String: [FileTreeEntry]] = [:]
        var entryCount = 0
        for path in paths {
            guard result.count < Self.cachedDirectoryLimit,
                  let entries = fileEntries[path],
                  entryCount + entries.count <= Self.cachedEntryLimit
            else { continue }
            result[path] = entries
            entryCount += entries.count
        }
        return result
    }

    private func monitoredDirectoryPaths() -> Set<String> {
        guard isPanelVisible,
              selectedSection == 0,
              let root = fileRoot
        else { return [] }
        let canRetryRemoteRoot = if case .ssh = root.target {
            fileErrors[root.path] != nil
        } else {
            false
        }
        let canMonitorRoot = fileEntries[root.path] != nil || canRetryRemoteRoot
        guard canMonitorRoot else { return [] }
        var paths: Set<String> = [root.path]
        for (path, node) in fileNodes
        where (fileEntries[path] != nil || fileErrors[path] != nil)
            && fileOutline.isItemExpanded(node) {
            paths.insert(path)
        }
        return paths
    }

    private func updateFileMonitoring() {
        guard let root = fileRoot else {
            stopFileMonitoring()
            return
        }
        let paths = monitoredDirectoryPaths()
        guard !paths.isEmpty else {
            stopFileMonitoring()
            return
        }

        switch root.target {
        case .local:
            remotePollingTask?.cancel()
            remotePollingTask = nil
            remoteDirectorySignatures = [:]
            if localRootWatcher == nil {
                localRootWatcher = FileTreeRootWatcher(
                    path: root.path,
                    queue: fileWatchQueue
                ) { [weak self] eventPaths in
                    Task { @MainActor [weak self] in
                        self?.handleLocalFileEvents(eventPaths)
                    }
                }
            }
        case .ssh(let connection):
            localRootWatcher?.cancel()
            localRootWatcher = nil
            guard remotePollingTask == nil else { return }
            remotePollingTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.remotePollInterval)
                    guard !Task.isCancelled else { return }
                    guard let paths = self?.remotePollPaths(for: root) else {
                        if self?.fileRoot != root { return }
                        continue
                    }
                    let inspection = Task.detached(priority: .utility) {
                        try FileTreeInspector().directorySignatures(
                            at: paths,
                            connection: connection
                        )
                    }
                    let signatures: [String: String]
                    do {
                        signatures = try await withTaskCancellationHandler {
                            try await inspection.value
                        } onCancel: {
                            inspection.cancel()
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        guard !Task.isCancelled,
                              let self,
                              self.fileRoot == root
                        else { return }
                        self.remoteDirectorySignatures = [:]
                        self.showDirectoryError(at: root.path, message: error.localizedDescription)
                        continue
                    }
                    guard !Task.isCancelled,
                          let self,
                          self.fileRoot == root
                    else { return }
                    let currentPaths = Set(paths)
                    self.remoteDirectorySignatures = self.remoteDirectorySignatures.filter {
                        currentPaths.contains($0.key)
                    }
                    let changed = Set(paths.filter { path in
                        !self.remoteDirectorySignatures.keys.contains(path)
                            || self.remoteDirectorySignatures[path] != signatures[path]
                    })
                    self.remoteDirectorySignatures.merge(signatures) { _, new in new }
                    self.enqueueLiveRefresh(paths: changed, debounce: false)
                }
            }
        }
    }

    private func stopFileMonitoring() {
        localRootWatcher?.cancel()
        localRootWatcher = nil
        remotePollingTask?.cancel()
        remotePollingTask = nil
        remoteDirectorySignatures = [:]
        liveRefreshDebounceTask?.cancel()
        liveRefreshDebounceTask = nil
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
        liveRefreshID = nil
        pendingLiveRefreshPaths = []
    }

    private func handleLocalFileEvents(_ eventPaths: [String]) {
        let monitored = monitoredDirectoryPaths()
        var changed = Set<String>()
        for eventPath in eventPaths {
            let path = URL(fileURLWithPath: eventPath).standardizedFileURL.path
            var matched = false
            if monitored.contains(path) {
                changed.insert(path)
                matched = true
            }
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            if monitored.contains(parent) {
                changed.insert(parent)
                matched = true
            }
            if !matched,
               let ancestor = monitored
                .filter({ contains(path, in: $0) })
                .max(by: { pathDepth($0) < pathDepth($1) }) {
                changed.insert(ancestor)
            }
        }
        enqueueLiveRefresh(paths: changed, debounce: true)
    }

    private func remotePollPaths(for root: FileRoot) -> [String]? {
        guard fileRoot == root,
              isPanelVisible,
              selectedSection == 0,
              NSApp.isActive,
              let window = view.window,
              window.isVisible,
              !window.isMiniaturized,
              window.occlusionState.contains(.visible),
              liveRefreshTask == nil
        else { return nil }
        return Array(visibleDirectoryPaths(for: root))
    }

    private func visibleDirectoryPaths(for root: FileRoot) -> Set<String> {
        var paths: Set<String> = [root.path]
        let rows = fileOutline.rows(in: fileScrollView.contentView.bounds)
        guard rows.location != NSNotFound else { return paths }
        for row in rows.location..<(rows.location + rows.length) {
            guard let node = fileOutline.item(atRow: row) as? FileTreeNode,
                  let entry = node.entry,
                  entry.isDirectory,
                  fileEntries[entry.path] != nil || fileErrors[entry.path] != nil,
                  fileOutline.isItemExpanded(node)
            else { continue }
            paths.insert(entry.path)
        }
        return paths
    }

    private func enqueueLiveRefresh(paths: Set<String>, debounce: Bool) {
        guard isPanelVisible, selectedSection == 0 else { return }
        pendingLiveRefreshPaths.formUnion(paths.filter {
            fileEntries[$0] != nil || fileErrors[$0] != nil
        })
        guard !pendingLiveRefreshPaths.isEmpty else { return }
        liveRefreshDebounceTask?.cancel()
        liveRefreshDebounceTask = nil
        if debounce {
            liveRefreshDebounceTask = Task { [weak self] in
                try? await Task.sleep(for: Self.liveRefreshDebounce)
                guard !Task.isCancelled, let self else { return }
                self.liveRefreshDebounceTask = nil
                self.performPendingLiveRefresh()
            }
        } else {
            performPendingLiveRefresh()
        }
    }

    private func performPendingLiveRefresh() {
        guard liveRefreshTask == nil,
              let root = fileRoot,
              isPanelVisible,
              selectedSection == 0
        else { return }
        let monitoredPaths = monitoredDirectoryPaths()
        pendingLiveRefreshPaths.formIntersection(monitoredPaths)
        let paths = pendingLiveRefreshPaths
            .filter { !refreshingPaths.contains($0) }
        pendingLiveRefreshPaths.subtract(paths)
        guard !paths.isEmpty else { return }

        let refreshID = UUID()
        liveRefreshID = refreshID
        let target = root.target
        let inspection = Task.detached(priority: .utility) {
            try FileTreeInspector().children(at: Array(paths), target: target)
        }
        liveRefreshTask = Task { [weak self] in
            let refreshed: [String: [FileTreeEntry]]
            do {
                refreshed = try await withTaskCancellationHandler {
                    try await inspection.value
                } onCancel: {
                    inspection.cancel()
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.liveRefreshID == refreshID,
                      self.fileRoot == root
                else { return }
                self.liveRefreshTask = nil
                self.liveRefreshID = nil
                self.remoteDirectorySignatures = [:]
                for path in paths {
                    self.showDirectoryError(at: path, message: error.localizedDescription)
                }
                return
            }
            guard let self, self.liveRefreshID == refreshID else { return }
            self.liveRefreshTask = nil
            self.liveRefreshID = nil
            guard !Task.isCancelled,
                  self.fileRoot == root
            else { return }
            var changedPaths: [String] = []
            for path in paths {
                guard let entries = refreshed[path] else {
                    self.remoteDirectorySignatures.removeValue(forKey: path)
                    self.showDirectoryError(
                        at: path,
                        message: "Remote folder is unavailable."
                    )
                    continue
                }
                if self.installFileEntries(entries, at: path) { changedPaths.append(path) }
            }
            if !changedPaths.isEmpty {
                self.reloadDirectories(changedPaths)
                self.saveCurrentFileCache()
                self.updateFileMonitoring()
            }
            if !self.pendingLiveRefreshPaths.isEmpty {
                self.performPendingLiveRefresh()
            }
        }
    }

    private func refreshCachedDirectory(at path: String, root: FileRoot) {
        guard fileEntries[path] != nil, !refreshingPaths.contains(path) else { return }
        fileRefreshTask?.cancel()
        let refreshID = UUID()
        fileRefreshID = refreshID
        refreshingPaths = [path]

        fileRefreshTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let target = root.target
            let inspection = Task.detached(priority: .utility) {
                try FileTreeInspector().children(at: path, target: target)
            }
            let refreshed: [FileTreeEntry]
            do {
                refreshed = try await withTaskCancellationHandler {
                    try await inspection.value
                } onCancel: {
                    inspection.cancel()
                }
            } catch is CancellationError {
                return
            } catch {
                guard fileRefreshID == refreshID, fileRoot == root else { return }
                refreshingPaths = []
                fileRefreshTask = nil
                remoteDirectorySignatures.removeValue(forKey: path)
                showDirectoryError(at: path, message: error.localizedDescription)
                return
            }
            guard fileRefreshID == refreshID else { return }
            refreshingPaths = []
            fileRefreshTask = nil
            guard !Task.isCancelled,
                  fileRoot == root,
                  fileEntries[path] != nil
            else { return }

            if installFileEntries(refreshed, at: path) {
                if path == root.path || expandedPaths.contains(path) {
                    reloadDirectory(path)
                }
                saveCurrentFileCache()
                updateFileMonitoring()
            }
            if path == root.path, let entries = fileEntries[root.path] {
                startPrefetching(from: entries, root: root)
            }
            if !pendingLiveRefreshPaths.isEmpty {
                performPendingLiveRefresh()
            }
        }
    }

    private func discardCachedBranch(at path: String) {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        fileEntries = fileEntries.filter { key, _ in
            key != path && !key.hasPrefix(prefix)
        }
        expandedPaths = expandedPaths.filter { key in
            key != path && !key.hasPrefix(prefix)
        }
        fileNodes = fileNodes.filter { key, _ in
            key != path && !key.hasPrefix(prefix)
        }
        fileEntryAccessOrder = fileEntryAccessOrder.filter { key, _ in
            key != path && !key.hasPrefix(prefix)
        }
    }

    private func showDirectoryError(at path: String, message: String) {
        let changed = fileEntries.removeValue(forKey: path) != nil || fileErrors[path] != message
        fileErrors[path] = message
        guard changed else { return }
        reloadDirectory(path)
    }

    private func installFileEntries(_ entries: [FileTreeEntry], at path: String) -> Bool {
        fileErrors[path] = nil
        guard fileEntries[path] != nil else {
            fileEntries[path] = entries
            touchFileEntries([path])
            trimInactiveFileEntries()
            return true
        }
        return replaceFileEntries(at: path, with: entries)
    }

    private func replaceFileEntries(at path: String, with entries: [FileTreeEntry]) -> Bool {
        guard let previous = fileEntries[path], previous != entries else { return false }
        let refreshedPaths = Set(entries.map(\.path))
        for removed in previous where !refreshedPaths.contains(removed.path) {
            if removed.isDirectory {
                discardCachedBranch(at: removed.path)
            } else {
                fileNodes.removeValue(forKey: removed.path)
            }
        }
        fileEntries[path] = entries
        touchFileEntries([path])
        trimInactiveFileEntries()
        return true
    }

    private func startPrefetching(from entries: [FileTreeEntry], root: FileRoot) {
        filePrefetchTask?.cancel()
        filePrefetchTask = nil
        prefetchingPaths = []
        guard !isFileTreeLiveScrolling else { return }
        let prefetchID = UUID()
        filePrefetchID = prefetchID
        let initial = entries.compactMap { entry in
            entry.isDirectory ? PrefetchCandidate(path: entry.path, depth: 1) : nil
        }
        guard !initial.isEmpty else { return }

        filePrefetchTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            var queue = initial
            var queuedPaths = Set(initial.map(\.path))
            var directoryCount = 0
            var entryCount = 0

            while !queue.isEmpty,
                  !Task.isCancelled,
                  directoryCount < Self.prefetchDirectoryLimit,
                  entryCount < Self.prefetchEntryLimit {
                var batch: [PrefetchCandidate] = []
                while !queue.isEmpty, batch.count < Self.prefetchBatchSize {
                    let candidate = queue.removeFirst()
                    if fileEntries[candidate.path] == nil,
                       fileLoadTasks[candidate.path] == nil {
                        batch.append(candidate)
                    }
                }
                guard !batch.isEmpty else { continue }

                let paths = batch.map(\.path)
                let target = root.target
                prefetchingPaths.formUnion(paths)
                let inspection = Task.detached(priority: .utility) {
                    try? FileTreeInspector().children(at: paths, target: target)
                }
                let loaded = await withTaskCancellationHandler {
                    await inspection.value
                } onCancel: {
                    inspection.cancel()
                }
                guard filePrefetchID == prefetchID else { return }
                prefetchingPaths.subtract(paths)
                guard !Task.isCancelled, fileRoot == root else { return }

                directoryCount += batch.count
                var changedPaths: [String] = []
                for candidate in batch {
                    guard let children = loaded?[candidate.path] else { continue }
                    if fileEntries[candidate.path] == nil {
                        fileEntries[candidate.path] = children
                        touchFileEntries([candidate.path])
                        changedPaths.append(candidate.path)
                    }
                    entryCount += children.count
                    guard candidate.depth < Self.prefetchDepth,
                          directoryCount + queue.count < Self.prefetchDirectoryLimit,
                          entryCount < Self.prefetchEntryLimit
                    else { continue }
                    for child in children where child.isDirectory {
                        guard queuedPaths.insert(child.path).inserted else { continue }
                        queue.append(
                            PrefetchCandidate(path: child.path, depth: candidate.depth + 1)
                        )
                    }
                }
                reloadDirectories(changedPaths.filter { expandedPaths.contains($0) })
                trimInactiveFileEntries()
                if !changedPaths.isEmpty { saveCurrentFileCache() }
            }
        }
    }
}

@MainActor
private final class WorkspacePanelTabButton: AppButton {
    init(title: String, index: Int) {
        super.init(role: .workspacePanelTab)
        self.title = title
        tag = index
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = AppTheme.workspaceControlCornerRadius
        setAccessibilityLabel(title)
        heightAnchor.constraint(equalToConstant: AppTheme.workspaceTabHeight).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 16, height: size.height)
    }
}

@MainActor
private final class LeftSidebarHeaderView: NSView {
    var onToggle: (() -> Void)?

    private let toggle = PanelToggleButton(
        symbolName: "sidebar.left",
        accessibilityLabel: "Toggle tasks"
    )
    private var leadingConstraint: NSLayoutConstraint!
    private var centerYConstraint: NSLayoutConstraint!

    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(toggle)
        leadingConstraint = toggle.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: AppTheme.sidebarToggleLeading
        )
        centerYConstraint = toggle.centerYAnchor.constraint(
            equalTo: centerYAnchor,
            constant: AppTheme.sidebarToggleVerticalOffset
        )
        NSLayoutConstraint.activate([
            leadingConstraint,
            centerYConstraint,
        ])
        toggle.target = self
        toggle.action = #selector(togglePanel)
        toggle.toolTip = "Toggle tasks (⌘B)"
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func setPanelActive(_ active: Bool) {
        toggle.panelVisible = active
    }

    func setFullScreen(_ fullScreen: Bool) {
        leadingConstraint.constant = fullScreen
            ? AppTheme.fullScreenSidebarToggleLeading
            : AppTheme.sidebarToggleLeading
    }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        toggle.applyTheme()
    }

    @objc private func togglePanel() {
        onToggle?()
    }
}

@MainActor
private final class SidebarBrandView: NSView {
    private let logo = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "Piñata")

    override var mouseDownCanMoveWindow: Bool { true }

    init() {
        super.init(frame: .zero)

        logo.image = NSImage(named: "BrandLogo")
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(logo)
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            logo.leadingAnchor.constraint(equalTo: leadingAnchor),
            logo.topAnchor.constraint(equalTo: topAnchor),
            logo.bottomAnchor.constraint(equalTo: bottomAnchor),
            logo.widthAnchor.constraint(equalToConstant: AppTheme.sidebarBrandSize),
            logo.heightAnchor.constraint(equalToConstant: AppTheme.sidebarBrandSize),

            nameLabel.leadingAnchor.constraint(
                equalTo: logo.trailingAnchor,
                constant: AppTheme.workspaceContentInset
            ),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            nameLabel.centerYAnchor.constraint(equalTo: logo.centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Piñata")
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        nameLabel.font = AppTheme.font(ofSize: AppTheme.typography.title, weight: 700)
        nameLabel.textColor = AppTheme.primaryText.withAlphaComponent(0.86)
    }
}

@MainActor
private final class SidebarSectionHeaderView: NSView {
    let isPinnedSection: Bool
    private let titleLabel: NSTextField

    init(title: String, isPinnedSection: Bool) {
        self.isPinnedSection = isPinnedSection
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.usesSingleLineMode = true
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: AppTheme.sidebarSectionTitleInset - AppTheme.sidebarItemInset
            ),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        titleLabel.attributedStringValue = NSAttributedString(
            string: titleLabel.stringValue,
            attributes: [
                .font: AppTheme.font(ofSize: AppTheme.typography.label + 0.5, weight: 600),
                .foregroundColor: AppTheme.tertiaryText.withAlphaComponent(0.6),
                .kern: 0.6,
            ]
        )
    }
}
