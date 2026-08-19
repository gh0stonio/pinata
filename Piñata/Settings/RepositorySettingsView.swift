import AppKit

@MainActor
final class RepositorySettingsView: NSView, NSTextFieldDelegate, SettingsPageContent {
    private let store = RepositoryRegistryStore()
    private let connectionStore = SSHConnectionStore()
    private let defaultsStore = RepositoryDefaultsStore()
    private let page = SettingsSplitPageView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let registerAction = RepositoryRegisterActionView()
    private let defaultWorktreeField = SettingsTextField()
    private let branchPrefixField = SettingsTextField()
    private let repositoryContent = NSStackView()
    private let repositoryRows = NSStackView()
    private var detailView: RepositoryDetailView?
    private var repositories: [RegisteredRepository] = []
    private var registryLoaded = false
    private var selectedRepositoryID: UUID?
    private var contextTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?
    private var removalModal: DeleteTaskModalView?

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
        if let detailView {
            detailView.scrollToTop()
        } else {
            reloadRepositories()
            page.scrollToTop()
        }
    }

    private func resetToList() {
        guard detailView != nil else { return }
        closeDetails()
    }

    func didDeselect() {
        registrationTask?.cancel()
        registrationTask = nil
        resetToList()
    }

    func applyTheme() {
        page.applyTheme()
        errorLabel.textColor = AppTheme.error
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
            controlWidth: SettingsLayout.repositoryPathControlWidth,
            minimumHeight: SettingsLayout.rowHeight
        )

        branchPrefixField.stringValue = defaultsStore.loadTaskBranchPrefix()
        branchPrefixField.placeholderString = "Example: antoine.leveque/"
        branchPrefixField.delegate = self
        let branchPrefixRow = SettingsRowView(
            title: "Task branch prefix",
            description: "Used for new task branches as <prefix><task-slug>-<short-id>. Changes only affect future tasks.",
            control: branchPrefixField,
            controlWidth: SettingsLayout.repositoryPathControlWidth,
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
        repositoryRows.setContentHuggingPriority(.required, for: .vertical)
        registerAction.setContentHuggingPriority(.required, for: .vertical)
        repositoryContent.addArrangedSubview(repositoryRows)
        repositoryContent.addArrangedSubview(registerAction)
        repositoryContent.addArrangedSubview(errorLabel)
        repositoryContent.setCustomSpacing(8, after: repositoryRows)
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
            title: "Branches",
            detail: "How Piñata names new task branches.",
            content: branchPrefixRow
        )
        page.addSection(
            title: "Repositories",
            detail: "Local and remote repositories available to tasks. Add remote repositories from Connections.",
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
        guard registryLoaded else {
            setError("Repository registry is unavailable.")
            return
        }
        registrationTask?.cancel()
        let worker = Task.detached(priority: .userInitiated) {
            try RepositoryInspector().inspect(directory: directory)
        }
        registrationTask = Task { [weak self] in
            do {
                let repository = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, let self else { return }
                self.finishRegistration(repository)
            } catch is CancellationError {
                return
            } catch {
                self?.setError(error.localizedDescription)
            }
        }
    }

    private func finishRegistration(_ repository: RegisteredRepository) {
        do {
            guard !repositories.contains(where: { $0.path == repository.path && $0.target == repository.target }) else {
                setError("Repository already registered.")
                return
            }
            let updatedRepositories = repositories + [repository]
            try store.save(updatedRepositories)
            repositories = updatedRepositories
            setError(nil)
            reloadRepositories(selecting: repository.id)
        } catch {
            setError(error.localizedDescription)
        }
    }

    private func reloadRepositories(selecting repositoryID: UUID? = nil) {
        do {
            repositories = try store.load().sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            registryLoaded = true
            setError(nil)
        } catch {
            repositories = []
            registryLoaded = false
            setError("Could not load registered repositories: \(error.localizedDescription)")
        }
        let rows: [NSView]
        if !registryLoaded {
            rows = []
        } else if repositories.isEmpty {
            rows = [SettingsMessageRow("No repositories yet. Register one to attach code to tasks.")]
        } else {
            let connectionsByID = Dictionary(
                uniqueKeysWithValues: ((try? connectionStore.load()) ?? []).map { ($0.id, $0) }
            )
            rows = repositories.map { repository in
                let row = RepositoryRowView(
                    repository: repository,
                    source: RepositorySource(repository: repository, connections: connectionsByID)
                )
                row.onSelect = { [weak self] in self?.select(repository.id) }
                return row
            }
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
        let connection: SSHConnection?
        do {
            if case .ssh(let connectionID) = repository.target {
                guard let value = try connectionStore.load().first(where: { $0.id == connectionID }) else {
                    throw RepositorySettingsError.connectionUnavailable
                }
                guard value.isEnabled else {
                    throw RepositorySettingsError.connectionUnavailable
                }
                connection = value
            } else {
                connection = nil
            }
        } catch {
            installInspectionError(for: repository, error: error)
            return
        }
        let worker = Task.detached(priority: .userInitiated) { () throws -> (RegisteredRepository, RepositoryContext, GitHubCLIProfileResult) in
            let inspector = RepositoryInspector()
            let refreshedRepository = try inspector.refresh(repository, connection: connection)
            let context = try inspector.context(for: refreshedRepository, connection: connection)
            let target = connection.map(TerminalTarget.ssh) ?? .local
            let profiles = GitHubCLIProfileInspector.inspect(
                context: PullRequestQueryContext(
                    path: refreshedRepository.path,
                    target: target,
                    branches: [],
                    ghProfile: nil
                )
            )
            return (refreshedRepository, context, profiles)
        }
        contextTask = Task { [weak self] in
            do {
                let (refreshedRepository, context, profiles) = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard
                    !Task.isCancelled,
                    let self,
                    self.selectedRepositoryID == repositoryID
                else { return }
                self.installDetails(
                    for: refreshedRepository,
                    context: context,
                    profiles: profiles
                )
            } catch is CancellationError {
                return
            } catch {
                guard
                    !Task.isCancelled,
                    let self,
                    self.selectedRepositoryID == repositoryID
                else { return }
                self.installInspectionError(for: repository, error: error)
            }
        }
    }

    private func installDetails(
        for repository: RegisteredRepository,
        context: RepositoryContext,
        profiles: GitHubCLIProfileResult
    ) {
        let details = RepositoryDetailView(
            repository: repository,
            context: context,
            profiles: profiles
        )
        details.onSave = { [weak self] repository in self?.save(repository) ?? false }
        showDetails(details)
        applyTheme()
    }

    private func installInspectionError(for repository: RegisteredRepository, error: Error) {
        showDetails(RepositoryDetailView(repository: repository, errorMessage: error.localizedDescription))
        applyTheme()
    }

    private func showDetails(_ details: RepositoryDetailView) {
        detailView?.removeFromSuperview()
        details.onBack = { [weak self] in self?.closeDetails() }
        details.onRemove = { [weak self] repository in self?.confirmRemoval(of: repository) }
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

    private func confirmRemoval(of repository: RegisteredRepository) {
        guard removalModal == nil else { return }
        let modal = DeleteTaskModalView(
            title: "Remove \"\(repository.name)\"?",
            detail: "This unregisters the repository from Piñata. Its files, worktrees, and existing task attachments stay in place.",
            actionTitle: "Remove"
        )
        modal.onCancel = { [weak self] in self?.dismissRemovalModal() }
        modal.onDelete = { [weak self] in self?.remove(repository) }
        let host = window?.contentView ?? self
        host.addSubview(modal)
        NSLayoutConstraint.activate([
            modal.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            modal.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            modal.topAnchor.constraint(equalTo: host.topAnchor),
            modal.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        removalModal = modal
    }

    private func dismissRemovalModal() {
        removalModal?.removeFromSuperview()
        removalModal = nil
    }

    private func remove(_ repository: RegisteredRepository) {
        do {
            repositories = try store.remove(id: repository.id)
            dismissRemovalModal()
            closeDetails()
        } catch {
            dismissRemovalModal()
            closeDetails()
            setError("Could not remove repository: \(error.localizedDescription)")
        }
    }

    private func save(_ repository: RegisteredRepository) -> Bool {
        guard registryLoaded else {
            presentSaveError("Repository registry is unavailable.")
            return false
        }
        guard WorktreePathValidator.error(
            for: repository.worktreeBasePath ?? "",
            allowRepositoryRelative: true
        ) == nil else {
            return false
        }
        guard let index = repositories.firstIndex(where: { $0.id == repository.id }) else {
            return false
        }
        var updatedRepositories = repositories
        updatedRepositories[index] = repository
        do {
            try store.save(updatedRepositories)
            repositories = updatedRepositories
            setError(nil)
            return true
        } catch {
            presentSaveError(error.localizedDescription)
            return false
        }
    }

    private func presentSaveError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not save repository settings"
        alert.informativeText = message
        alert.runModal()
    }

    private func closeDetails() {
        contextTask?.cancel()
        contextTask = nil
        selectedRepositoryID = nil
        detailView?.removeFromSuperview()
        detailView = nil
        page.isHidden = false
        reloadRepositories()
        page.scrollToTop()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === defaultWorktreeField {
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
            return
        }
        guard notification.object as? NSTextField === branchPrefixField else { return }
        let prefix = branchPrefixField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = TaskBranchName.normalizedPrefix(prefix) else {
            setError(TaskBranchName.error(for: prefix) ?? "Use a valid Git branch prefix.")
            branchPrefixField.stringValue = defaultsStore.loadTaskBranchPrefix()
            return
        }
        defaultsStore.saveTaskBranchPrefix(normalized)
        branchPrefixField.stringValue = normalized
        setError(nil)
    }

    private func setError(_ message: String?) {
        let message = message ?? ""
        errorLabel.stringValue = message
        errorLabel.isHidden = message.isEmpty
    }
}

private struct RepositorySource {
    let connectionName: String?
    let isRemote: Bool

    init(repository: RegisteredRepository, connections: [UUID: SSHConnection]) {
        switch repository.target {
        case .local:
            connectionName = nil
            isRemote = false
        case .ssh(let connectionID):
            connectionName = connections[connectionID]?.name ?? "SSH connection"
            isRemote = true
        }
    }
}

private enum RepositorySettingsError: LocalizedError {
    case connectionUnavailable

    var errorDescription: String? {
        switch self {
        case .connectionUnavailable:
            "The SSH connection for this repository is no longer available."
        }
    }
}

@MainActor
private final class RepositoryRowView: AppHoverView, SettingsThemeApplying {
    var onSelect: (() -> Void)?

    private let nameLabel: NSTextField
    private let metadataLabel: NSTextField
    private let button = AppButton(role: .hitTarget)
    private let repositoryIcon = NSImageView()
    private let chevron = NSImageView()

    init(repository: RegisteredRepository, source: RepositorySource) {
        nameLabel = NSTextField(labelWithString: repository.name)
        let metadata = [repository.organization, repository.defaultBranch]
            .compactMap { $0 }
            .joined(separator: " · ")
        metadataLabel = NSTextField(labelWithString: source.connectionName.map {
            "\(metadata) (\($0))"
        } ?? metadata)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = SettingsLayout.compactRowCornerRadius
        layer?.masksToBounds = true
        toolTip = ([source.connectionName, repository.path, repository.remoteURL]
            .compactMap { $0 }
            .joined(separator: "\n"))

        repositoryIcon.image = NSImage(
            systemSymbolName: source.isRemote ? "globe" : "laptopcomputer",
            accessibilityDescription: source.isRemote ? "Remote repository" : "Local repository"
        )
        repositoryIcon.imageScaling = .scaleProportionallyDown
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.imageScaling = .scaleProportionallyDown
        [repositoryIcon, nameLabel, metadataLabel, chevron, button].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
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
        let appearance = AppTheme.buttonAppearance(role: .naked, hovered: isHovering)
        layer?.backgroundColor = appearance.background.cgColor
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
private final class RepositoryRegisterActionView: AppHoverView, SettingsThemeApplying {
    var onAction: (() -> Void)?

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "Register local repository")
    private let button = AppButton(role: .hitTarget)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyDown
        [icon, label, button].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        button.target = self
        button.action = #selector(registerRepository)
        button.setAccessibilityLabel("Register local repository")
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
        let appearance = AppTheme.buttonAppearance(role: .link, hovered: isHovering)
        icon.contentTintColor = appearance.foreground
        label.textColor = appearance.foreground
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
    static let checkout = RepositoryDetailCopy(
        title: "Repository checkout",
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
    static let ghProfile = RepositoryDetailCopy(
        title: "GitHub CLI profile",
        detail: "Account used for pull request data"
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
    var onSave: ((RegisteredRepository) -> Bool)?
    var onRemove: ((RegisteredRepository) -> Void)?

    private var repository: RegisteredRepository
    private let context: RepositoryContext?
    private let errorMessage: String?
    private let profiles: GitHubCLIProfileResult?
    private let breadcrumb: RepositoryBreadcrumbView
    private let page = SettingsSplitPageView(topPadding: SettingsLayout.detailPageTopPadding)
    private let branchPopup = SettingsPopupButton()
    private let ghProfilePopup = SettingsPopupButton()
    private let worktreeField = SettingsTextField()
    private var ghProfileChoices: [String?] = []

    init(
        repository: RegisteredRepository,
        context: RepositoryContext? = nil,
        errorMessage: String? = nil,
        profiles: GitHubCLIProfileResult? = nil
    ) {
        self.repository = repository
        self.context = context
        self.errorMessage = errorMessage
        self.profiles = profiles
        breadcrumb = RepositoryBreadcrumbView(repositoryName: repository.name)
        super.init(frame: .zero)
        installLayout()
        page.showVerticalScroller()
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
                equalTo: page.contentLeadingAnchor,
                constant: -SettingsLayout.breadcrumbBackOffset
            ),
            breadcrumb.topAnchor.constraint(
                equalTo: topAnchor,
                constant: SettingsLayout.detailHeaderTopPadding
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

        if let errorMessage {
            page.addSection(
                title: "Repository unavailable",
                detail: "Git metadata could not be loaded.",
                content: SettingsMessageRow(errorMessage)
            )
            installRemovalSection()
            return
        }

        guard let context else {
            installSkeleton()
            installRemovalSection()
            return
        }

        let sourceRows = [
            makeValueRow(RepositoryDetailText.checkout, value: repository.path),
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
        installGitHubProfileSection()

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
        worktreeField.placeholderString = "Example: ./worktrees (inside this repository)"
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
        installRemovalSection()
    }

    private func installRemovalSection() {
        let action = RepositoryRemoveActionView()
        action.onAction = { [weak self] in
            guard let self else { return }
            self.onRemove?(self.repository)
        }
        let row = SettingsRowView(
            title: "Remove repository",
            description: "Unregister it from Piñata. Its files and worktrees stay in place.",
            control: action,
            controlWidth: RepositoryRemoveActionView.width,
            controlHeight: RepositoryRemoveActionView.height
        )
        page.addSection(
            title: "Danger zone",
            detail: "",
            content: row,
            isDestructive: true
        )
    }

    private func installSkeleton() {
        page.addSection(
            title: RepositoryDetailText.source.title,
            detail: RepositoryDetailText.source.detail,
            content: settingsRowStack([
                makeSkeletonRow(RepositoryDetailText.checkout),
                makeSkeletonRow(RepositoryDetailText.organization),
                makeSkeletonRow(RepositoryDetailText.origin),
            ])
        )
        page.addSection(
            title: "GitHub CLI",
            detail: "Choose the account used for pull request data.",
            content: makeSkeletonRow(RepositoryDetailText.ghProfile)
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

    private func installGitHubProfileSection() {
        let result = profiles ?? GitHubCLIProfileResult(profiles: [], errorMessage: nil)
        ghProfilePopup.removeAllItems()
        ghProfileChoices = [nil]
        let activeLogin = result.profiles.first(where: \.isActive)?.login
        ghProfilePopup.addItem(withTitle: activeLogin.map {
            "Use active profile: \($0)"
        } ?? "Use active profile")
        for profile in result.profiles {
            ghProfileChoices.append(profile.login)
            ghProfilePopup.addItem(withTitle: profile.login)
        }
        if let selectedProfile = repository.ghProfile,
           !ghProfileChoices.contains(selectedProfile)
        {
            ghProfileChoices.append(selectedProfile)
            ghProfilePopup.addItem(withTitle: "\(selectedProfile) (unavailable)")
        }
        if let selectedProfile = repository.ghProfile,
           let index = ghProfileChoices.firstIndex(of: selectedProfile)
        {
            ghProfilePopup.selectItem(at: index)
        } else {
            ghProfilePopup.selectItem(at: 0)
        }
        ghProfilePopup.target = self
        ghProfilePopup.action = #selector(ghProfileChanged)
        ghProfilePopup.isEnabled = result.errorMessage == nil || !result.profiles.isEmpty
        page.addSection(
            title: "GitHub CLI",
            detail: result.errorMessage ?? "Defaults to the active gh profile on this machine.",
            content: makeControlRow(RepositoryDetailText.ghProfile, control: ghProfilePopup)
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
            controlWidth: SettingsLayout.repositoryPathControlWidth,
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
            controlWidth: SettingsLayout.repositoryPathControlWidth,
            minimumHeight: SettingsLayout.rowHeight
        )
    }

    private func makeSkeletonRow(_ copy: RepositoryDetailCopy) -> SettingsRowView {
        SettingsRowView(
            title: copy.title,
            description: copy.detail,
            control: SettingsSkeletonValueView(),
            controlWidth: SettingsLayout.repositoryPathControlWidth,
            controlHeight: SettingsLayout.skeletonHeight,
            minimumHeight: SettingsLayout.rowHeight
        )
    }

    @objc private func ghProfileChanged() {
        let index = ghProfilePopup.indexOfSelectedItem
        guard ghProfileChoices.indices.contains(index) else { return }
        let previousProfile = repository.ghProfile
        repository.ghProfile = ghProfileChoices[index]
        if onSave?(repository) == false {
            repository.ghProfile = previousProfile
            if let previousIndex = ghProfileChoices.firstIndex(of: previousProfile) {
                ghProfilePopup.selectItem(at: previousIndex)
            }
        }
    }

    @objc private func defaultBranchChanged() {
        guard let branch = branchPopup.selectedItem?.title else { return }
        let previousBranch = repository.defaultBranch
        repository.defaultBranch = branch
        if onSave?(repository) == false {
            repository.defaultBranch = previousBranch
            branchPopup.selectItem(withTitle: previousBranch)
        }
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
        let previousPath = repository.worktreeBasePath
        repository.worktreeBasePath = path.isEmpty ? nil : path
        if onSave?(repository) == false {
            repository.worktreeBasePath = previousPath
            worktreeField.stringValue = previousPath ?? ""
        }
    }
}

@MainActor
private final class RepositoryRemoveActionView: NSView, SettingsThemeApplying {
    static let width: CGFloat = 100
    static let height: CGFloat = 28

    var onAction: (() -> Void)?

    private let button = ModalActionButton(
        title: "Remove",
        primary: false,
        destructive: true
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.imageScaling = .scaleProportionallyDown
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        button.target = self
        button.action = #selector(removeRepository)
        button.setAccessibilityLabel("Remove repository")
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.heightAnchor.constraint(equalToConstant: Self.height),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func applyTheme() {
        button.applyTheme()
    }

    @objc private func removeRepository() { onAction?() }
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
