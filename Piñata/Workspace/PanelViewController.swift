import AppKit

private final class SidebarTaskDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class PanelViewController: NSViewController {
    var onTogglePanel: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onCreateTask: (() -> Void)?
    var onSelectTask: ((UUID) -> Void)?
    var onSelectRepository: ((TaskRepositoryScope) -> Void)?
    var onToggleTaskExpansion: ((UUID) -> Void)?

    private weak var trackingRoot: PanelTrackingView?
    private weak var leftHeader: LeftSidebarHeaderView?
    private weak var brandView: SidebarBrandView?
    private weak var sectionHeader: SidebarSectionHeaderView?
    private let newTaskButton = SidebarNewTaskButton(frame: .zero)
    private let taskScrollView = NSScrollView()
    private let taskDocument = SidebarTaskDocumentView()
    private let taskStack = NSStackView()
    private var sizingTaskDocument = false

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

    func applyTheme() {
        view.layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        leftHeader?.applyTheme()
        brandView?.applyTheme()
        sectionHeader?.applyTheme()
        newTaskButton.applyTheme()
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
        taskErrors: [UUID: String],
        repositoryErrors: [TaskRepositoryScope: String],
        loadError: String?
    ) {
        guard isViewLoaded else { return }
        taskStack.arrangedSubviews.forEach {
            taskStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if let loadError {
            taskStack.addArrangedSubview(SidebarMessageView(loadError, error: true))
        }
        if tasks.isEmpty, loadError == nil {
            taskStack.addArrangedSubview(SidebarMessageView("No tasks yet.", error: false))
        } else if !tasks.isEmpty {
            for task in tasks {
                let group = SidebarTaskGroupView(
                    task: task,
                    selection: selection,
                    expanded: expandedTaskIDs.contains(task.id),
                    taskError: taskErrors[task.id],
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
                taskStack.addArrangedSubview(group)
                group.widthAnchor.constraint(equalTo: taskStack.widthAnchor).isActive = true
            }
        }
        applyTheme()
        sizeTaskDocumentToViewport()
    }

    private func installLeftPanel() {
        let topHeader = LeftSidebarHeaderView()
        let brand = SidebarBrandView()
        let sectionHeader = SidebarSectionHeaderView(title: "TASKS")
        let scrollView = taskScrollView
        topHeader.onToggle = { [weak self] in self?.onTogglePanel?() }
        newTaskButton.onCreate = { [weak self] in self?.onCreateTask?() }

        topHeader.translatesAutoresizingMaskIntoConstraints = false
        brand.translatesAutoresizingMaskIntoConstraints = false
        sectionHeader.translatesAutoresizingMaskIntoConstraints = false
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
        taskDocument.addSubview(taskStack)
        scrollView.documentView = taskDocument
        view.addSubview(topHeader)
        view.addSubview(brand)
        view.addSubview(newTaskButton)
        view.addSubview(sectionHeader)
        view.addSubview(scrollView)

        leftHeader = topHeader
        brandView = brand
        self.sectionHeader = sectionHeader

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
                constant: -AppTheme.sidebarTrailingInset(for: AppTheme.sidebarItemInset)
            ),
            newTaskButton.topAnchor.constraint(
                equalTo: brand.bottomAnchor,
                constant: AppTheme.sidebarNewTaskTopSpacing
            ),
            newTaskButton.heightAnchor.constraint(equalToConstant: AppTheme.sidebarNewTaskHeight),

            sectionHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sectionHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sectionHeader.topAnchor.constraint(
                equalTo: newTaskButton.bottomAnchor,
                constant: AppTheme.sidebarNewTaskBottomSpacing
            ),

            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(
                equalTo: sectionHeader.bottomAnchor,
                constant: AppTheme.sidebarTaskListTopSpacing
            ),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            taskStack.leadingAnchor.constraint(
                equalTo: taskDocument.leadingAnchor,
                constant: AppTheme.sidebarItemInset
            ),
            taskStack.trailingAnchor.constraint(
                equalTo: taskDocument.trailingAnchor,
                constant: -AppTheme.sidebarTrailingInset(for: AppTheme.sidebarItemInset)
            ),
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

    private let taskRow: SidebarTaskRow
    private var repositoryRows: [SidebarRepositoryRow] = []

    init(
        task: WorkspaceTask,
        selection: WorkspaceScope?,
        expanded: Bool,
        taskError: String?,
        repositoryErrors: [TaskRepositoryScope: String]
    ) {
        taskRow = SidebarTaskRow(
            title: task.title,
            hasRepositories: !task.repositories.isEmpty,
            expanded: expanded,
            selected: selection == .task(task.id),
            error: taskError
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

        if expanded {
            for repository in task.repositories.sorted(by: {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }) {
                let scope = TaskRepositoryScope(taskID: task.id, repositoryID: repository.repositoryID)
                let row = SidebarRepositoryRow(
                    repository: repository,
                    selected: selection == .repository(scope),
                    error: repositoryErrors[scope]
                )
                row.onSelect = { [weak self] in
                    self?.onSelectRepository?(repository.repositoryID)
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
}

@MainActor
private final class SidebarDisclosureButton: AppButton {
    override var usesAutomaticHoverTracking: Bool { false }
}

@MainActor
private final class SidebarTaskRow: AppHoverView {
    var onSelect: (() -> Void)?
    var onToggleExpansion: (() -> Void)?

    private let selected: Bool
    private let error: String?
    private let selectButton = AppButton(role: .hitTarget)
    private let disclosureButton = SidebarDisclosureButton(role: .icon)
    private let titleLabel: NSTextField
    private let errorIcon = NSImageView()
    private let failedLabel: NSTextField

    init(title: String, hasRepositories: Bool, expanded: Bool, selected: Bool, error: String?) {
        self.selected = selected
        self.error = error
        titleLabel = NSTextField(labelWithString: title)
        failedLabel = NSTextField(labelWithString: error == nil ? "" : "failed")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = AppTheme.workspaceControlCornerRadius
        toolTip = error ?? title

        [selectButton, disclosureButton, titleLabel, errorIcon, failedLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        selectButton.target = self
        selectButton.action = #selector(selectTask)
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
        disclosureButton.isHidden = !hasRepositories
        disclosureButton.layer?.cornerRadius = AppTheme.workspaceControlCornerRadius
        disclosureButton.layer?.cornerCurve = .continuous
        titleLabel.usesSingleLineMode = true
        titleLabel.lineBreakMode = .byTruncatingTail
        errorIcon.image = NSImage(
            systemSymbolName: "exclamationmark.circle.fill",
            accessibilityDescription: "Failed"
        )
        errorIcon.isHidden = error == nil
        failedLabel.isHidden = error == nil

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
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: errorIcon.leadingAnchor, constant: -6),
            failedLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            failedLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorIcon.trailingAnchor.constraint(equalTo: failedLabel.leadingAnchor, constant: -6),
            errorIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorIcon.widthAnchor.constraint(equalToConstant: error == nil ? 0 : 12),
            errorIcon.heightAnchor.constraint(equalToConstant: 12),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        let appearance = AppTheme.buttonAppearance(
            role: selected ? .accent : .chrome,
            hovered: !selected && isHovering
        )
        layer?.backgroundColor = appearance.background.cgColor
        let textColor = error == nil
            ? selected ? appearance.foreground : AppTheme.primaryText
            : NSColor.systemRed
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.body, weight: 550)
        titleLabel.textColor = textColor
        disclosureButton.applyTheme()
        errorIcon.contentTintColor = error == nil ? AppTheme.panelAccentIcon : .systemRed
        failedLabel.font = .monospacedSystemFont(ofSize: AppTheme.typography.label, weight: .regular)
        failedLabel.textColor = .systemRed
    }

    override func hoverStateDidChange() {
        applyTheme()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hitView = super.hitTest(point) else { return nil }
        if !disclosureButton.isHidden,
            hitView === disclosureButton || hitView.isDescendant(of: disclosureButton)
        {
            return disclosureButton
        }
        return selectButton
    }

    @objc private func selectTask() {
        onSelect?()
    }

    @objc private func toggleExpansion() {
        onToggleExpansion?()
    }
}

@MainActor
private final class SidebarRepositoryRow: AppHoverView {
    var onSelect: (() -> Void)?

    private let selected: Bool
    private let error: String?
    private let button = AppButton(role: .hitTarget)
    private let titleLabel: NSTextField
    private let errorIcon = NSImageView()
    private let failedLabel: NSTextField

    init(repository: TaskRepositoryAttachment, selected: Bool, error: String?) {
        self.selected = selected
        self.error = error
        titleLabel = NSTextField(labelWithString: repository.name)
        failedLabel = NSTextField(labelWithString: error == nil ? "" : "failed")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = AppTheme.workspaceControlCornerRadius
        toolTip = error ?? repository.name
        [button, titleLabel, errorIcon, failedLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        button.target = self
        button.action = #selector(selectRepository)
        button.setAccessibilityLabel(repository.name)
        titleLabel.usesSingleLineMode = true
        titleLabel.lineBreakMode = .byTruncatingTail
        errorIcon.image = NSImage(
            systemSymbolName: "exclamationmark.circle.fill",
            accessibilityDescription: "Failed"
        )
        errorIcon.isHidden = error == nil
        failedLabel.isHidden = error == nil

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: AppTheme.sidebarRepositoryTitleInset
            ),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: errorIcon.leadingAnchor, constant: -6),
            failedLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            failedLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorIcon.trailingAnchor.constraint(equalTo: failedLabel.leadingAnchor, constant: -6),
            errorIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorIcon.widthAnchor.constraint(equalToConstant: error == nil ? 0 : 14),
            errorIcon.heightAnchor.constraint(equalToConstant: 12),
        ])
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
            : NSColor.systemRed
        titleLabel.font = .monospacedSystemFont(
            ofSize: AppTheme.typography.label,
            weight: selected ? .semibold : .regular
        )
        titleLabel.textColor = textColor
        errorIcon.contentTintColor = error == nil ? AppTheme.tertiaryText : .systemRed
        failedLabel.font = .monospacedSystemFont(ofSize: AppTheme.typography.label, weight: .regular)
        failedLabel.textColor = .systemRed
    }

    override func hoverStateDidChange() {
        applyTheme()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : button
    }

    @objc private func selectRepository() {
        onSelect?()
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
        label.textColor = error ? .systemRed : AppTheme.tertiaryText
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
    private let titleLabel: NSTextField

    init(title: String) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.usesSingleLineMode = true
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: AppTheme.sidebarSectionTitleInset
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
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.label, weight: 600)
        titleLabel.textColor = AppTheme.tertiaryText
    }
}
