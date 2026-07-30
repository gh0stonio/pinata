import AppKit

@MainActor
final class RepositorySettingsView: NSView, NSTextFieldDelegate {
    private let store = RepositoryRegistryStore()
    private let defaultsStore = RepositoryDefaultsStore()
    private let inspector = RepositoryInspector()
    private let page = SettingsPageView(title: "Git & PR")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let registerButton = NSButton(title: "Register repo", target: nil, action: nil)
    private let defaultWorktreeField = SettingsTextField()
    private let defaultWorktreeCard = SettingsCardView()
    private let repositoryCard = SettingsCardView()
    private let repositoryContent = NSStackView()
    private var repositorySheet: SettingsSheetController?
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
        page.scrollToTop()
    }

    func applyTheme() {
        page.applyTheme()
        errorLabel.textColor = .systemRed
        errorLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody)
        registerButton.contentTintColor = AppTheme.secondaryText
        registerButton.font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 600)
        defaultWorktreeField.applyTheme()
        defaultWorktreeCard.applyTheme()
        repositoryCard.applyTheme()
        repositorySheet?.applyTheme()
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
            controlWidth: 320,
            minimumHeight: SettingsLayout.expandedRowHeight
        )
        defaultWorktreeCard.setRows([defaultRow])

        registerButton.isBordered = false
        registerButton.bezelStyle = .shadowlessSquare
        registerButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        registerButton.imagePosition = .imageLeading
        registerButton.target = self
        registerButton.action = #selector(registerRepository)

        errorLabel.isHidden = true
        repositoryContent.translatesAutoresizingMaskIntoConstraints = false
        repositoryContent.orientation = .vertical
        repositoryContent.alignment = .leading
        repositoryContent.spacing = 6
        repositoryContent.addArrangedSubview(errorLabel)
        repositoryContent.addArrangedSubview(repositoryCard)
        errorLabel.widthAnchor.constraint(equalTo: repositoryContent.widthAnchor).isActive = true
        repositoryCard.widthAnchor.constraint(equalTo: repositoryContent.widthAnchor).isActive = true

        page.addSection(title: "Worktrees", content: defaultWorktreeCard)
        page.addSection(
            title: "Repositories",
            content: repositoryContent,
            action: registerButton
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
        repositoryCard.setRows(rows)

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

        let sheet = repositorySheet ?? SettingsSheetController()
        sheet.onDismiss = { [weak self] in self?.closeDetails() }
        repositorySheet = sheet
        sheet.setContent(SettingsMessageRow("Loading repository metadata…"), title: repository.name)
        if let window { sheet.present(from: window) }

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
            context: context,
            defaultWorktreeBasePath: defaultsStore.loadWorktreeBasePath()
        )
        details.onSave = { [weak self] repository in self?.save(repository) }
        details.onRemove = { [weak self] in self?.remove(repository) }
        repositorySheet?.setContent(details, title: repository.name)
        applyTheme()
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
            reloadRepositories()
        } catch {
            setError(error.localizedDescription)
        }
    }

    private func remove(_ repository: RegisteredRepository) {
        repositories.removeAll { $0.id == repository.id }
        do {
            try store.save(repositories)
            setError(nil)
            closeDetails()
            reloadRepositories()
        } catch {
            setError(error.localizedDescription)
        }
    }

    private func closeDetails() {
        contextTask?.cancel()
        contextTask = nil
        selectedRepositoryID = nil
        repositorySheet?.dismiss()
        repositorySheet = nil
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
private final class RepositoryRowView: NSView, SettingsThemeApplying {
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
            heightAnchor.constraint(equalToConstant: SettingsLayout.rowHeight),
            repositoryIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsLayout.blockHorizontalPadding),
            repositoryIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            repositoryIcon.widthAnchor.constraint(equalToConstant: 18),
            repositoryIcon.heightAnchor.constraint(equalToConstant: 18),
            nameLabel.leadingAnchor.constraint(equalTo: repositoryIcon.trailingAnchor, constant: 16),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            metadataLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 24),
            metadataLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            metadataLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -16),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsLayout.blockHorizontalPadding),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            chevron.heightAnchor.constraint(equalToConstant: 14),
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
        layer?.backgroundColor = .clear
        nameLabel.textColor = AppTheme.primaryText
        nameLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 600)
        metadataLabel.textColor = AppTheme.tertiaryText
        metadataLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody, weight: 550)
        repositoryIcon.contentTintColor = AppTheme.tertiaryText
        chevron.contentTintColor = AppTheme.tertiaryText
    }

    @objc private func selectRepository() {
        onSelect?()
    }
}

@MainActor
private final class RepositoryDetailView: NSView, NSTextFieldDelegate, SettingsThemeApplying {
    var onSave: ((RegisteredRepository) -> Void)?
    var onRemove: (() -> Void)?

    private var repository: RegisteredRepository
    private let context: RepositoryContext
    private let defaultWorktreeBasePath: String
    private let stack = NSStackView()
    private let branchPopup = NSPopUpButton()
    private let worktreeField = SettingsTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    init(
        repository: RegisteredRepository,
        context: RepositoryContext,
        defaultWorktreeBasePath: String
    ) {
        self.repository = repository
        self.context = context
        self.defaultWorktreeBasePath = defaultWorktreeBasePath
        super.init(frame: .zero)
        installLayout()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        stack.arrangedSubviews.compactMap { $0 as? SettingsThemeApplying }.forEach { $0.applyTheme() }
        branchPopup.contentTintColor = AppTheme.primaryText
        branchPopup.font = .monospacedSystemFont(ofSize: AppTheme.typography.settingsBody, weight: .regular)
        worktreeField.applyTheme()
        errorLabel.textColor = .systemRed
        errorLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody)
    }

    private func installLayout() {
        translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        addSubview(stack)

        addRow(title: "Source", helper: "Local Git checkout", value: repository.path)
        if let organization = repository.organization {
            addRow(title: "Organization", helper: "Inferred from origin", value: organization)
        }
        addRow(title: "Origin", helper: "Primary Git remote", value: repository.remoteURL ?? "None")
        addRow(title: "Current branch", helper: "Checked out in the source repository", value: repository.currentBranch ?? "Detached HEAD")

        branchPopup.addItems(withTitles: repository.branches)
        if !repository.branches.contains(repository.defaultBranch) {
            branchPopup.insertItem(withTitle: repository.defaultBranch, at: 0)
        }
        branchPopup.selectItem(withTitle: repository.defaultBranch)
        branchPopup.target = self
        branchPopup.action = #selector(defaultBranchChanged)
        addRow(title: "Default branch", helper: "Base branch for new tasks", control: branchPopup)

        worktreeField.stringValue = repository.worktreeBasePath ?? ""
        worktreeField.placeholderString = "./worktrees (inside this repo folder)"
        worktreeField.delegate = self
        var fallbackBase = defaultWorktreeBasePath
        while fallbackBase.count > 1, fallbackBase.hasSuffix("/") {
            fallbackBase.removeLast()
        }
        let fallback = fallbackBase == "/"
            ? "/\(repository.name)"
            : "\(fallbackBase)/\(repository.name)"
        addRow(
            title: "Worktree override",
            helper: "Optional. Default: \(fallback). Changes only affect future worktrees.",
            control: worktreeField
        )

        addRow(
            title: "Branches",
            helper: "\(repository.branches.count) local branches",
            value: repository.branches.isEmpty ? "None" : repository.branches.joined(separator: "\n")
        )
        addRow(
            title: "Tags",
            helper: "Up to 50 most recent tags",
            value: context.tags.isEmpty ? "None" : context.tags.joined(separator: "\n")
        )
        addRow(
            title: "Remotes",
            helper: "Fetch and push endpoints",
            value: context.remotes.isEmpty ? "None" : context.remotes.map {
                "\($0.name) (\($0.kind))  \($0.url)"
            }.joined(separator: "\n")
        )
        addRow(
            title: "Existing worktrees",
            helper: "Managed by Git; path changes above do not move these",
            value: context.worktrees.isEmpty ? "None" : context.worktrees.map {
                [$0.branch, $0.path].compactMap { $0 }.joined(separator: "  ")
            }.joined(separator: "\n")
        )

        let github = context.github
        addRow(title: "GitHub CLI", helper: github.version ?? "Command line integration", value: github.executablePath ?? "Not installed")
        addRow(title: "GitHub authentication", helper: "Active gh account", value: github.authenticationStatus)
        addRow(title: "GitHub repository", helper: github.description ?? "Resolved from the current checkout", value: github.repositoryName ?? "Unavailable")
        if let repositoryURL = github.repositoryURL {
            addRow(title: "GitHub URL", helper: "Canonical repository URL", value: repositoryURL)
        }
        if let defaultBranch = github.defaultBranch {
            addRow(title: "GitHub default branch", helper: "Reported by GitHub", value: defaultBranch)
        }

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isHidden = true
        stack.addArrangedSubview(errorLabel)
        errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true

        let danger = makeDangerRow()
        stack.addArrangedSubview(danger)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            danger.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func addRow(title: String, helper: String, value: String) {
        addRow(
            title: title,
            helper: helper,
            control: SettingsValueLabel(value),
            controlHeight: nil
        )
    }

    private func addRow(
        title: String,
        helper: String,
        control: NSView,
        controlHeight: CGFloat? = SettingsLayout.controlHeight
    ) {
        let row = SettingsRowView(
            title: title,
            description: helper,
            control: control,
            controlHeight: controlHeight,
            minimumHeight: SettingsLayout.detailRowHeight,
            allowsVerticalExpansion: controlHeight == nil
        )
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func makeDangerRow() -> NSView {
        let danger = SettingsDangerZoneView(
            title: "Remove repository",
            description: "Remove this repository from Piñata. Local files stay untouched.",
            actionTitle: "Remove"
        )
        danger.onAction = { [weak self] in self?.onRemove?() }
        return danger
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
            errorLabel.stringValue = error
            errorLabel.isHidden = false
            return
        }
        errorLabel.isHidden = true
        repository.worktreeBasePath = path.isEmpty ? nil : path
        onSave?(repository)
    }
}
