import AppKit

private extension NSPasteboard.PasteboardType {
    static let sidebarTaskID = Self("io.pinata.sidebar-task-id")
}

private final class SidebarTaskDocumentView: NSView {
    override var isFlipped: Bool { true }
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
    var onShowTaskMenu: ((UUID, NSRect) -> Void)?
    var onShowRepositoryMenu: ((TaskRepositoryScope, NSRect) -> Void)?
    var onMoveTask: ((UUID, UUID?, Bool, Bool) -> Void)?

    private weak var trackingRoot: PanelTrackingView?
    private weak var leftHeader: LeftSidebarHeaderView?
    private weak var brandView: SidebarBrandView?
    private let newTaskButton = SidebarNewTaskButton(frame: .zero)
    private let taskScrollView = NSScrollView()
    private let taskDocument = SidebarTaskDocumentView()
    private let taskStack = SidebarTaskStackView()
    private var sizingTaskDocument = false
    private var newTaskTrailingConstraint: NSLayoutConstraint!
    private var taskStackTrailingConstraint: NSLayoutConstraint!
    private var taskMenuTaskID: UUID?
    private var repositoryMenuScope: TaskRepositoryScope?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let rootView = PanelTrackingView()
        rootView.translatesAutoresizingMaskIntoConstraints = false
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

    override func viewDidLayout() {
        super.viewDidLayout()
        sizeTaskDocumentToViewport()
    }

    func setToggleActive(_ active: Bool) {
        leftHeader?.setPanelActive(active)
    }

    func setFullScreen(_ fullScreen: Bool) {
        leftHeader?.setFullScreen(fullScreen)
    }

    func setResizable(_ resizable: Bool) {
        let inset = AppTheme.sidebarItemInset
            - (resizable ? AppTheme.resizeHandleWidth / 2 : 0)
        newTaskTrailingConstraint.constant = -inset
        taskStackTrailingConstraint.constant = -inset
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
            taskStack.addArrangedSubview(header)
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
                repositoryErrors: repositoryErrors
            )
            group.onSelectTask = { [weak self] in self?.onSelectTask?(task.id) }
            group.onToggleExpansion = { [weak self] in
                self?.onToggleTaskExpansion?(task.id)
            }
            group.onSelectRepository = { [weak self] repositoryID in
                self?.onSelectRepository?(
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
            taskStack.addArrangedSubview(group)
            group.widthAnchor.constraint(equalTo: taskStack.widthAnchor).isActive = true
        }

        let pinnedTasks = tasks.filter(\.isPinned)
        let pinnedHeader = addHeader("PINNED", isPinnedSection: true)
        pinnedTasks.forEach(addTask)
        if let lastPinned = taskStack.arrangedSubviews.last as? SidebarTaskGroupView {
            taskStack.setCustomSpacing(AppTheme.sidebarSectionSpacing, after: lastPinned)
        } else {
            taskStack.setCustomSpacing(AppTheme.sidebarSectionSpacing, after: pinnedHeader)
        }

        _ = addHeader("TASKS", isPinnedSection: false)
        if let loadError {
            taskStack.addArrangedSubview(SidebarMessageView(loadError, error: true))
        }
        if tasks.isEmpty, loadError == nil {
            taskStack.addArrangedSubview(SidebarMessageView("No tasks yet.", error: false))
        } else {
            tasks.filter { !$0.isPinned }.forEach(addTask)
        }
        applyTheme()
        sizeTaskDocumentToViewport()
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
        taskDocument.translatesAutoresizingMaskIntoConstraints = true
        taskStack.translatesAutoresizingMaskIntoConstraints = false
        taskStack.orientation = .vertical
        taskStack.alignment = .leading
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
        newTaskTrailingConstraint = newTaskButton.trailingAnchor.constraint(
            equalTo: view.trailingAnchor,
            constant: -AppTheme.sidebarItemInset
        )
        taskStackTrailingConstraint = taskStack.trailingAnchor.constraint(
            equalTo: taskDocument.trailingAnchor,
            constant: -AppTheme.sidebarItemInset
        )

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
            newTaskTrailingConstraint,
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
            taskStack.leadingAnchor.constraint(
                equalTo: taskDocument.leadingAnchor,
                constant: AppTheme.sidebarItemInset
            ),
            taskStackTrailingConstraint,
            taskStack.topAnchor.constraint(equalTo: taskDocument.topAnchor),
            taskDocument.bottomAnchor.constraint(greaterThanOrEqualTo: taskStack.bottomAnchor),
        ])
    }

    private func sizeTaskDocumentToViewport() {
        guard !sizingTaskDocument else { return }
        let viewport = taskScrollView.contentView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        sizingTaskDocument = true
        defer { sizingTaskDocument = false }
        taskDocument.setFrameSize(
            NSSize(width: viewport.width, height: max(viewport.height, taskDocument.frame.height))
        )
        taskDocument.layoutSubtreeIfNeeded()
        taskDocument.setFrameSize(
            NSSize(width: viewport.width, height: max(viewport.height, taskStack.frame.maxY))
        )
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
private final class SidebarTaskGroupView: NSStackView {
    var onSelectTask: (() -> Void)?
    var onToggleExpansion: (() -> Void)?
    var onSelectRepository: ((UUID) -> Void)?
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
        repositoryErrors: [TaskRepositoryScope: String]
    ) {
        taskID = task.id
        isPinned = task.isPinned
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
            error: taskError ?? collapsedRepositoryError
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
        taskRow.onShowMenu = { [weak self] in self?.onShowMenu?($0) }

        if expanded {
            for repository in task.repositories.sorted(by: {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }) {
                let scope = TaskRepositoryScope(taskID: task.id, repositoryID: repository.repositoryID)
                let row = SidebarRepositoryRow(
                    repository: repository,
                    selected: selection == .repository(scope),
                    menuActive: repositoryMenuScope == scope,
                    activity: repositoryActivities[scope] ?? (repository.worktreeProvisioning.map {
                        !$0.succeeded && $0.failureMessage == nil
                    } == true ? "creating" : nil),
                    error: repositoryErrors[scope]
                )
                row.onSelect = { [weak self] in
                    self?.onSelectRepository?(repository.repositoryID)
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
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 28),
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

    init(
        taskID: UUID,
        title: String,
        hasRepositories: Bool,
        expanded: Bool,
        selected: Bool,
        menuActive: Bool,
        activity: String?,
        error: String?
    ) {
        self.selected = selected
        self.hasRepositories = hasRepositories
        self.menuActive = menuActive
        self.activity = activity
        self.error = error
        titleLabel = NSTextField(labelWithString: title)
        statusLabel = NSTextField(labelWithString: activity ?? "")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = AppTheme.workspaceControlCornerRadius
        toolTip = error ?? title

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
            hovered: !selected && (isHovering || menuActive)
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
    }

    func setMenuActive(_ active: Bool) {
        menuActive = active
        menuButton.forcedActive = active
        updateTrailingVisibility()
        applyTheme()
    }

    private func updateTrailingVisibility() {
        let showsMenu = activity == nil && (isHovering || menuActive)
        menuOverlay.isHidden = !showsMenu
        disclosureButton.isHidden = !hasRepositories
        errorIcon.isHidden = error == nil
        activityIndicator.isHidden = activity == nil || error != nil
        statusLabel.isHidden = activity == nil
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
        layer?.backgroundColor = AppTheme.chromeBackground.cgColor
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
            ? AppTheme.chromeHoverBackground
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
private final class SidebarRepositoryRow: AppHoverView {
    var onSelect: (() -> Void)?
    var onShowMenu: ((NSRect) -> Void)?

    let repositoryID: UUID
    private let selected: Bool
    private var menuActive: Bool
    private let activity: String?
    private let error: String?
    private let button = AppButton(role: .hitTarget)
    private let menuOverlay = SidebarTrailingActionOverlay()
    private var menuButton: SidebarMenuButton { menuOverlay.button }
    private let titleLabel: NSTextField
    private let errorIcon = NSImageView()
    private let activityIndicator = NSProgressIndicator()
    private let statusLabel: NSTextField

    init(
        repository: TaskRepositoryAttachment,
        selected: Bool,
        menuActive: Bool,
        activity: String?,
        error: String?
    ) {
        repositoryID = repository.repositoryID
        self.selected = selected
        self.menuActive = menuActive
        self.activity = activity
        self.error = error
        titleLabel = NSTextField(labelWithString: repository.name)
        statusLabel = NSTextField(labelWithString: error == nil ? activity ?? "" : "failed")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = AppTheme.workspaceControlCornerRadius
        toolTip = error ?? repository.name
        [button, titleLabel, errorIcon, activityIndicator, statusLabel, menuOverlay].forEach {
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
        menuButton.isEnabled = activity == nil
        menuButton.target = self
        menuButton.action = #selector(showMenu)
        menuButton.setAccessibilityLabel("Repository actions")
        menuButton.forcedActive = menuActive
        titleLabel.usesSingleLineMode = true
        titleLabel.lineBreakMode = .byTruncatingTail
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
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: AppTheme.sidebarRepositoryTitleInset
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
            errorIcon.widthAnchor.constraint(equalToConstant: error == nil ? 0 : 14),
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
            hovered: isHovering
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
    }

    override func hoverStateDidChange() {
        updateTrailingVisibility()
        applyTheme()
    }

    func setMenuActive(_ active: Bool) {
        menuActive = active
        menuButton.forcedActive = active
        updateTrailingVisibility()
        applyTheme()
    }

    private func updateTrailingVisibility() {
        let showsMenu = activity == nil && (isHovering || menuActive)
        menuOverlay.isHidden = !showsMenu
        errorIcon.isHidden = error == nil
        activityIndicator.isHidden = activity == nil || error != nil
        statusLabel.isHidden = error == nil && activity == nil
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
        onShowMenu?(convert(bounds, to: nil))
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
