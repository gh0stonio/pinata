import AppKit

@MainActor
final class RepositorySettingsView: NSView, NSTextFieldDelegate, SettingsPageContent {
    private let store = RepositoryRegistryStore()
    private let defaultsStore = RepositoryDefaultsStore()
    private let inspector = RepositoryInspector()
    private let page = SettingsSplitPageView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let registerAction = RepositoryRegisterActionView()
    private let defaultWorktreeField = SettingsTextField()
    private let repositoryContent = NSStackView()
    private let repositoryRows = NSStackView()
    private var detailView: RepositoryDetailView?
    private var repositories: [RegisteredRepository] = []
    private var selectedRepositoryID: UUID?
    private var contextTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        installLayout()
        reloadRepositories()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func scrollToTop() {
        detailView?.scrollToTop() ?? page.scrollToTop()
    }

    private func resetToList() {
        guard detailView != nil else { return }
        closeDetails()
    }

    func didDeselect() {
        resetToList()
    }

    func applyTheme() {
        page.applyTheme()
        errorLabel.textColor = .systemRed
        errorLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody)
        registerAction.applyTheme()
        repositoryRows.arrangedSubviews.compactMap { $0 as? SettingsThemeApplying }.forEach {
            $0.applyTheme()
        }
        detailView?.applyTheme()
    }

    private func installLayout() {
        addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: leadingAnchor),
            page.trailingAnchor.constraint(equalTo: trailingAnchor),
            page.topAnchor.constraint(equalTo: topAnchor),
            page.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        defaultWorktreeField.stringValue = defaultsStore.loadWorktreeBasePath()
        defaultWorktreeField.delegate = self
        let defaultRow = SettingsRowView(
            title: "Default worktree base",
            description: "Used by every repository without an override. Changes only affect future worktrees.",
            control: defaultWorktreeField,
            controlWidth: 300,
            minimumHeight: SettingsLayout.rowHeight
        )

        registerAction.onAction = { [weak self] in self?.registerRepository() }

        errorLabel.isHidden = true
        repositoryContent.translatesAutoresizingMaskIntoConstraints = false
        repositoryContent.orientation = .vertical
        repositoryContent.alignment = .leading
        repositoryContent.spacing = 0
        repositoryRows.translatesAutoresizingMaskIntoConstraints = false
        repositoryRows.orientation = .vertical
        repositoryRows.alignment = .leading
        repositoryRows.spacing = 0
        repositoryContent.addArrangedSubview(repositoryRows)
        repositoryContent.addArrangedSubview(registerAction)
        repositoryContent.addArrangedSubview(errorLabel)
        errorLabel.widthAnchor.constraint(equalTo: repositoryContent.widthAnchor).isActive = true
        repositoryRows.widthAnchor.constraint(equalTo: repositoryContent.widthAnchor).isActive = true
        registerAction.widthAnchor.constraint(equalTo: repositoryContent.widthAnchor).isActive = true
        registerAction.heightAnchor.constraint(
            equalToConstant: SettingsLayout.compactRowHeight
        ).isActive = true

        page.addSection(
            title: "Worktrees",
            detail: "Where new task worktrees are created.",
            content: defaultRow
        )
        page.addSection(
            title: "Repositories",
            detail: "Repositories available to tasks and pull requests.",
            content: repositoryContent
        )
    }

    @objc private func registerRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a local Git repository"
        panel.prompt = "Register"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.register(directory: url)
        }
    }

    private func register(directory: URL) {
        do {
            let repository = try inspector.inspect(directory: directory)
            guard !repositories.contains(where: {
                $0.path == repository.path || $0.name.caseInsensitiveCompare(repository.name) == .orderedSame
            }) else {
                setError("Repository already registered.")
                return
            }
            repositories.append(repository)
            try store.save(repositories)
            setError(nil)
            reloadRepositories(selecting: repository.id)
        } catch {
            setError(error.localizedDescription)
        }
    }

    private func reloadRepositories(selecting repositoryID: UUID? = nil) {
        repositories = store.load().sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let rows: [NSView] = repositories.isEmpty
            ? [SettingsMessageRow("No repositories yet. Register one to attach code to tasks.")]
            : repositories.map { repository in
                let row = RepositoryRowView(repository: repository)
                row.onSelect = { [weak self] in self?.select(repository.id) }
                return row
            }
        repositoryRows.arrangedSubviews.forEach {
            repositoryRows.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for row in rows {
            repositoryRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: repositoryRows.widthAnchor).isActive = true
        }

        if let repositoryID,
           repositories.contains(where: { $0.id == repositoryID }) {
            select(repositoryID)
        }
        applyTheme()
    }

    private func select(_ repositoryID: UUID) {
        guard let repository = repositories.first(where: { $0.id == repositoryID }) else { return }
        selectedRepositoryID = repositoryID
        contextTask?.cancel()
        showDetails(RepositoryDetailView(repository: repository))

        contextTask = Task { [weak self] in
            let (refreshedRepository, context) = await Task.detached {
                let inspector = RepositoryInspector()
                let refreshedRepository = inspector.refresh(repository)
                return (refreshedRepository, inspector.context(for: refreshedRepository))
            }.value
            guard
                !Task.isCancelled,
                let self,
                self.selectedRepositoryID == repositoryID
            else { return }
            self.installDetails(for: refreshedRepository, context: context)
        }
    }

    private func installDetails(
        for repository: RegisteredRepository,
        context: RepositoryContext
    ) {
        let details = RepositoryDetailView(
            repository: repository,
            context: context
        )
        details.onSave = { [weak self] repository in self?.save(repository) }
        showDetails(details)
        applyTheme()
    }

    private func showDetails(_ details: RepositoryDetailView) {
        detailView?.removeFromSuperview()
        details.onBack = { [weak self] in self?.closeDetails() }
        addSubview(details)
        NSLayoutConstraint.activate([
            details.leadingAnchor.constraint(equalTo: leadingAnchor),
            details.trailingAnchor.constraint(equalTo: trailingAnchor),
            details.topAnchor.constraint(equalTo: topAnchor),
            details.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        detailView = details
        page.isHidden = true
    }

    private func save(_ repository: RegisteredRepository) {
        guard WorktreePathValidator.error(
            for: repository.worktreeBasePath ?? "",
            allowRepositoryRelative: true
        ) == nil else {
            return
        }
        guard let index = repositories.firstIndex(where: { $0.id == repository.id }) else { return }
        repositories[index] = repository
        do {
            try store.save(repositories)
            setError(nil)
            if detailView == nil {
                reloadRepositories()
            }
        } catch {
            setError(error.localizedDescription)
        }
    }

    private func closeDetails() {
        contextTask?.cancel()
        contextTask = nil
        selectedRepositoryID = nil
        detailView?.removeFromSuperview()
        detailView = nil
        page.isHidden = false
        page.scrollToTop()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === defaultWorktreeField else { return }
        let path = defaultWorktreeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = path.isEmpty ? RepositoryDefaultsStore.defaultWorktreeBasePath : path
        if let error = WorktreePathValidator.error(for: value, allowRepositoryRelative: false) {
            setError(error)
            defaultWorktreeField.stringValue = defaultsStore.loadWorktreeBasePath()
            return
        }
        defaultsStore.saveWorktreeBasePath(value)
        defaultWorktreeField.stringValue = value
        setError(nil)
    }

    private func setError(_ message: String?) {
        let message = message ?? ""
        errorLabel.stringValue = message
        errorLabel.isHidden = message.isEmpty
    }
}

@MainActor
private final class RepositoryRowView: SettingsHoverView, SettingsThemeApplying {
    var onSelect: (() -> Void)?

    private let nameLabel: NSTextField
    private let metadataLabel: NSTextField
    private let button = NSButton(title: "", target: nil, action: nil)
    private let repositoryIcon = NSImageView()
    private let chevron = NSImageView()

    init(repository: RegisteredRepository) {
        nameLabel = NSTextField(labelWithString: repository.name)
        metadataLabel = NSTextField(labelWithString: [repository.organization, repository.defaultBranch]
            .compactMap { $0 }
            .joined(separator: " · "))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = SettingsLayout.compactRowCornerRadius
        layer?.masksToBounds = true
        toolTip = [repository.path, repository.remoteURL].compactMap { $0 }.joined(separator: "\n")

        repositoryIcon.image = NSImage(
            systemSymbolName: "book.closed",
            accessibilityDescription: "Repository"
        )
        repositoryIcon.imageScaling = .scaleProportionallyDown
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.imageScaling = .scaleProportionallyDown
        [repositoryIcon, nameLabel, metadataLabel, chevron, button].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        button.isBordered = false
        button.target = self
        button.action = #selector(selectRepository)
        button.setAccessibilityLabel("Configure \(repository.name)")
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SettingsLayout.compactRowHeight),
            repositoryIcon.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SettingsLayout.compactContentInset
            ),
            repositoryIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            repositoryIcon.widthAnchor.constraint(equalToConstant: SettingsLayout.compactIconSize),
            repositoryIcon.heightAnchor.constraint(equalToConstant: SettingsLayout.compactIconSize),
            nameLabel.leadingAnchor.constraint(
                equalTo: repositoryIcon.trailingAnchor,
                constant: SettingsLayout.compactContentInset
            ),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            metadataLabel.leadingAnchor.constraint(
                equalTo: nameLabel.trailingAnchor,
                constant: SettingsLayout.compactMetadataGap
            ),
            metadataLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            metadataLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: chevron.leadingAnchor,
                constant: -SettingsLayout.compactMetadataGap
            ),
            chevron.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -SettingsLayout.compactContentInset
            ),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: SettingsLayout.compactChevronWidth),
            chevron.heightAnchor.constraint(equalToConstant: SettingsLayout.compactChevronHeight),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        layer?.backgroundColor = isHovering ? AppTheme.surface.cgColor : .clear
        nameLabel.textColor = AppTheme.primaryText
        nameLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 600)
        metadataLabel.textColor = AppTheme.tertiaryText
        metadataLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody, weight: 550)
        repositoryIcon.contentTintColor = AppTheme.tertiaryText
        chevron.contentTintColor = AppTheme.tertiaryText
    }

    override func hoverStateDidChange() {
        applyTheme()
    }

    @objc private func selectRepository() {
        onSelect?()
    }
}

@MainActor
private final class RepositoryRegisterActionView: SettingsHoverView, SettingsThemeApplying {
    var onAction: (() -> Void)?

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "Register a repository")
    private let button = NSButton(title: "", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyDown
        [icon, label, button].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        button.isBordered = false
        button.target = self
        button.action = #selector(registerRepository)
        button.setAccessibilityLabel("Register a repository")
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SettingsLayout.compactContentInset
            ),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: SettingsLayout.compactIconSize),
            icon.heightAnchor.constraint(equalToConstant: SettingsLayout.compactIconSize),
            label.leadingAnchor.constraint(
                equalTo: icon.trailingAnchor,
                constant: SettingsLayout.compactContentInset
            ),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        let color = isHovering ? AppTheme.accent : AppTheme.secondaryText
        icon.contentTintColor = color
        label.textColor = color
        label.font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 600)
    }

    override func hoverStateDidChange() {
        applyTheme()
    }

    @objc private func registerRepository() {
        onAction?()
    }
}

private struct RepositoryDetailCopy {
    let title: String
    let detail: String
}

private enum RepositoryDetailText {
    static let source = RepositoryDetailCopy(
        title: "Source",
        detail: "Where this repository lives and who owns it."
    )
    static let branches = RepositoryDetailCopy(
        title: "Branches",
        detail: "What new tasks are based on."
    )
    static let worktrees = RepositoryDetailCopy(
        title: "Worktrees",
        detail: "Overrides for this repository only."
    )
    static let localCheckout = RepositoryDetailCopy(
        title: "Local checkout",
        detail: "Where this repository lives"
    )
    static let organization = RepositoryDetailCopy(
        title: "Organization",
        detail: "Inferred from origin"
    )
    static let origin = RepositoryDetailCopy(
        title: "Origin",
        detail: "Primary Git remote"
    )
    static let currentBranch = RepositoryDetailCopy(
        title: "Current branch",
        detail: "Checked out in the source repo"
    )
    static let defaultBranch = RepositoryDetailCopy(
        title: "Default branch",
        detail: "Base branch for new tasks"
    )
    static let tags = RepositoryDetailCopy(
        title: "Tags",
        detail: "Up to 50 most recent"
    )
    static let worktreeOverride = RepositoryDetailCopy(
        title: "Worktree override",
        detail: "Defaults to the global base"
    )
    static let existingWorktrees = RepositoryDetailCopy(
        title: "Existing worktrees",
        detail: "Managed by Git, path changes do not move them"
    )

    static func localBranches(count: Int) -> RepositoryDetailCopy {
        RepositoryDetailCopy(title: "Local branches", detail: "\(count) total")
    }
}

@MainActor
private final class RepositoryDetailView: NSView, NSTextFieldDelegate, SettingsThemeApplying {
    var onBack: (() -> Void)?
    var onSave: ((RegisteredRepository) -> Void)?

    private var repository: RegisteredRepository
    private let context: RepositoryContext?
    private let breadcrumb: RepositoryBreadcrumbView
    private let page = SettingsSplitPageView()
    private let branchPopup = SettingsPopupButton()
    private let worktreeField = SettingsTextField()

    init(
        repository: RegisteredRepository,
        context: RepositoryContext? = nil
    ) {
        self.repository = repository
        self.context = context
        breadcrumb = RepositoryBreadcrumbView(repositoryName: repository.name)
        super.init(frame: .zero)
        installLayout()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func scrollToTop() {
        page.scrollToTop()
    }

    func applyTheme() {
        page.applyTheme()
        breadcrumb.applyTheme()
    }

    private func installLayout() {
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(breadcrumb)
        addSubview(page)
        NSLayoutConstraint.activate([
            breadcrumb.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SettingsLayout.pageHorizontalPadding
            ),
            breadcrumb.topAnchor.constraint(
                equalTo: topAnchor,
                constant: SettingsLayout.blockVerticalPadding / 2
            ),
            breadcrumb.heightAnchor.constraint(equalToConstant: SettingsLayout.breadcrumbHeight),
            page.leadingAnchor.constraint(equalTo: leadingAnchor),
            page.trailingAnchor.constraint(equalTo: trailingAnchor),
            page.topAnchor.constraint(
                equalTo: breadcrumb.bottomAnchor,
                constant: SettingsLayout.breadcrumbToContentGap
            ),
            page.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        breadcrumb.onBack = { [weak self] in self?.onBack?() }

        guard let context else {
            installSkeleton()
            return
        }

        let sourceRows = [
            makeValueRow(RepositoryDetailText.localCheckout, value: repository.path),
            makeValueRow(
                RepositoryDetailText.organization,
                value: repository.organization ?? "None"
            ),
            makeValueRow(
                RepositoryDetailText.origin,
                value: repository.remoteURL ?? "None"
            ),
        ]
        page.addSection(
            title: RepositoryDetailText.source.title,
            detail: RepositoryDetailText.source.detail,
            content: settingsRowStack(sourceRows)
        )

        branchPopup.addItems(withTitles: repository.branches)
        if !repository.branches.contains(repository.defaultBranch) {
            branchPopup.insertItem(withTitle: repository.defaultBranch, at: 0)
        }
        branchPopup.selectItem(withTitle: repository.defaultBranch)
        branchPopup.target = self
        branchPopup.action = #selector(defaultBranchChanged)
        let branchRows = [
            makeValueRow(
                RepositoryDetailText.currentBranch,
                value: repository.currentBranch ?? "Detached HEAD"
            ),
            makeControlRow(RepositoryDetailText.defaultBranch, control: branchPopup),
            makeValueRow(
                RepositoryDetailText.localBranches(count: repository.branches.count),
                value: repository.branches.isEmpty ? "None" : repository.branches.joined(separator: ", ")
            ),
            makeValueRow(
                RepositoryDetailText.tags,
                value: context.tags.isEmpty ? "None" : context.tags.joined(separator: ", ")
            ),
        ]
        page.addSection(
            title: RepositoryDetailText.branches.title,
            detail: RepositoryDetailText.branches.detail,
            content: settingsRowStack(branchRows)
        )

        worktreeField.stringValue = repository.worktreeBasePath ?? ""
        worktreeField.placeholderString = "./worktrees (inside this repo folder)"
        worktreeField.delegate = self
        let override = makeControlRow(
            RepositoryDetailText.worktreeOverride,
            control: worktreeField
        )
        let worktreeRows = [
            override,
            makeValueRow(
                RepositoryDetailText.existingWorktrees,
                value: context.worktrees.isEmpty ? "None" : context.worktrees.map {
                    [$0.branch, $0.path].compactMap { $0 }.joined(separator: ", ")
                }.joined(separator: ", ")
            ),
        ]
        page.addSection(
            title: RepositoryDetailText.worktrees.title,
            detail: RepositoryDetailText.worktrees.detail,
            content: settingsRowStack(worktreeRows)
        )
    }

    private func installSkeleton() {
        page.addSection(
            title: RepositoryDetailText.source.title,
            detail: RepositoryDetailText.source.detail,
            content: settingsRowStack([
                makeSkeletonRow(RepositoryDetailText.localCheckout),
                makeSkeletonRow(RepositoryDetailText.organization),
                makeSkeletonRow(RepositoryDetailText.origin),
            ])
        )
        page.addSection(
            title: RepositoryDetailText.branches.title,
            detail: RepositoryDetailText.branches.detail,
            content: settingsRowStack([
                makeSkeletonRow(RepositoryDetailText.currentBranch),
                makeSkeletonRow(RepositoryDetailText.defaultBranch),
                makeSkeletonRow(RepositoryDetailText.localBranches(count: repository.branches.count)),
                makeSkeletonRow(RepositoryDetailText.tags),
            ])
        )
        page.addSection(
            title: RepositoryDetailText.worktrees.title,
            detail: RepositoryDetailText.worktrees.detail,
            content: settingsRowStack([
                makeSkeletonRow(RepositoryDetailText.worktreeOverride),
                makeSkeletonRow(RepositoryDetailText.existingWorktrees),
            ])
        )
    }

    private func makeValueRow(
        _ copy: RepositoryDetailCopy,
        value: String
    ) -> SettingsRowView {
        SettingsRowView(
            title: copy.title,
            description: copy.detail,
            control: SettingsValueLabel(value),
            controlHeight: nil
        )
    }

    private func makeControlRow(
        _ copy: RepositoryDetailCopy,
        control: NSView
    ) -> SettingsRowView {
        SettingsRowView(
            title: copy.title,
            description: copy.detail,
            control: control,
            minimumHeight: SettingsLayout.rowHeight
        )
    }

    private func makeSkeletonRow(_ copy: RepositoryDetailCopy) -> SettingsRowView {
        SettingsRowView(
            title: copy.title,
            description: copy.detail,
            control: SettingsSkeletonValueView(),
            controlHeight: SettingsLayout.skeletonHeight,
            minimumHeight: SettingsLayout.rowHeight
        )
    }

    @objc private func defaultBranchChanged() {
        guard let branch = branchPopup.selectedItem?.title else { return }
        repository.defaultBranch = branch
        onSave?(repository)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === worktreeField else { return }
        let path = worktreeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = WorktreePathValidator.error(for: path, allowRepositoryRelative: true) {
            worktreeField.stringValue = repository.worktreeBasePath ?? ""
            worktreeField.toolTip = error
            return
        }
        worktreeField.toolTip = nil
        repository.worktreeBasePath = path.isEmpty ? nil : path
        onSave?(repository)
    }
}

@MainActor
private final class RepositoryBreadcrumbView: NSView, SettingsThemeApplying {
    var onBack: (() -> Void)?

    private let backButton = SettingsActionButton(title: "Repositories", target: nil, action: nil)
    private let separator = NSTextField(labelWithString: "/")
    private let nameLabel: NSTextField

    init(repositoryName: String) {
        nameLabel = NSTextField(labelWithString: repositoryName)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        [backButton, separator, nameLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        backButton.image = NSImage(systemSymbolName: "arrow.left", accessibilityDescription: nil)
        backButton.imagePosition = .imageLeading
        backButton.target = self
        backButton.action = #selector(goBack)
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(
                equalTo: backButton.trailingAnchor,
                constant: SettingsLayout.breadcrumbGap
            ),
            separator.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.leadingAnchor.constraint(
                equalTo: separator.trailingAnchor,
                constant: SettingsLayout.breadcrumbGap
            ),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        backButton.applyTheme()
        separator.textColor = AppTheme.tertiaryText
        separator.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody)
        nameLabel.textColor = AppTheme.primaryText
        nameLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody, weight: 550)
    }

    @objc private func goBack() {
        onBack?()
    }
}
