import AppKit

@MainActor
final class ConnectionsSettingsView: NSView, SettingsPageContent {
    private let connectionStore = SSHConnectionStore()
    private let repositoryStore = RepositoryRegistryStore()
    private let page = SettingsSplitPageView()
    private let hostContent = NSStackView()
    private let hostRows = NSStackView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var connections: [SSHConnection] = []
    private var configuredHosts: [SSHConfigHost] = []
    private var detailView: ConnectionRepositoriesView?
    private var folderPicker: RemoteFolderPickerModal?
    private var registrationTask: Task<Void, Never>?
    private var folderWarmTasks: [UUID: Task<[String: [String]], Error>] = [:]
    private var folderTrees: [UUID: [String: [String]]] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        installLayout()
        reloadConnections()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func scrollToTop() {
        guard detailView == nil, folderPicker == nil else { return }
        reloadConnections()
        page.scrollToTop()
    }

    func didDeselect() {
        registrationTask?.cancel()
        registrationTask = nil
        dismissFolderPicker()
        closeDetails()
    }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.background.cgColor
        page.applyTheme()
        errorLabel.textColor = AppTheme.error
        errorLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody)
        hostRows.arrangedSubviews.compactMap { $0 as? SettingsThemeApplying }.forEach { $0.applyTheme() }
        detailView?.applyTheme()
        folderPicker?.applyTheme()
    }

    private func installLayout() {
        wantsLayer = true
        addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: leadingAnchor),
            page.trailingAnchor.constraint(equalTo: trailingAnchor),
            page.topAnchor.constraint(equalTo: topAnchor),
            page.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hostContent.orientation = .vertical
        hostContent.alignment = .leading
        hostContent.spacing = 0
        hostRows.translatesAutoresizingMaskIntoConstraints = false
        hostRows.orientation = .vertical
        hostRows.alignment = .leading
        hostRows.spacing = 0
        errorLabel.isHidden = true
        [hostRows, errorLabel].forEach {
            hostContent.addArrangedSubview($0)
            $0.widthAnchor.constraint(equalTo: hostContent.widthAnchor).isActive = true
        }
        hostContent.setCustomSpacing(10, after: hostRows)
        page.addSection(
            title: "Connections",
            detail: "SSH hosts available on this Mac.",
            content: hostContent
        )
    }

    private func reloadConnections() {
        var loadError: String?
        do {
            connections = try connectionStore.load()
        } catch {
            connections = []
            loadError = "Could not load SSH connections: \(error.localizedDescription)"
        }
        do {
            configuredHosts = try SSHConfigReader().loadHosts()
                .filter { !$0.isGitTransport }
                .sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
        } catch {
            configuredHosts = []
            loadError = loadError ?? "Could not read ~/.ssh/config: \(error.localizedDescription)"
        }
        setError(loadError)

        hostRows.arrangedSubviews.forEach {
            hostRows.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let rows: [NSView] = configuredHosts.isEmpty
            ? [SettingsMessageRow("No remote SSH hosts found in ~/.ssh/config.")]
            : configuredHosts.map { host in
                let row = ConnectionRowView(host: host, connection: connection(for: host))
                row.onToggle = { [weak self] enabled in self?.setEnabled(enabled, for: host) }
                row.onRepositories = { [weak self] in self?.showRepositories(for: host) }
                return row
            }
        rows.forEach {
            hostRows.addArrangedSubview($0)
            $0.widthAnchor.constraint(equalTo: hostRows.widthAnchor).isActive = true
        }
        warmEnabledConnections()
        applyTheme()
    }

    private func connection(for host: SSHConfigHost) -> SSHConnection? {
        connections.first { $0.host == host.alias }
    }

    private func setEnabled(_ enabled: Bool, for host: SSHConfigHost) {
        do {
            var updated = connections
            if let index = updated.firstIndex(where: { $0.host == host.alias }) {
                updated[index].isEnabled = enabled
            } else if enabled {
                updated.append(SSHConnection(name: host.alias, host: host.alias, isEnabled: true))
            }
            try connectionStore.save(updated)
            connections = updated
            reloadConnections()
        } catch {
            setError(error.localizedDescription)
            reloadConnections()
        }
    }

    private func showRepositories(for host: SSHConfigHost) {
        let connection = connection(for: host)
        let repositories = (try? repositoryStore.load())?.filter {
            guard case .ssh(let connectionID) = $0.target else { return false }
            return connectionID == connection?.id
        } ?? []
        let detail = ConnectionRepositoriesView(host: host, connection: connection, repositories: repositories)
        detail.onBack = { [weak self] in self?.closeDetails() }
        detail.onBrowse = { [weak self] in self?.presentFolderPicker(for: host) }
        addSubview(detail)
        NSLayoutConstraint.activate([
            detail.leadingAnchor.constraint(equalTo: leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            detail.topAnchor.constraint(equalTo: topAnchor),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        detailView = detail
        page.isHidden = true
        applyTheme()
    }

    private func closeDetails() {
        detailView?.removeFromSuperview()
        detailView = nil
        page.isHidden = false
        reloadConnections()
    }

    private func presentFolderPicker(for host: SSHConfigHost) {
        guard let connection = connection(for: host), connection.isEnabled else { return }
        dismissFolderPicker()
        let picker = RemoteFolderPickerModal(
            connection: connection,
            initialFolderTree: folderTrees[connection.id] ?? [:],
            initialRootLoad: folderWarmTasks[connection.id]
        )
        picker.onCancel = { [weak self] in self?.dismissFolderPicker() }
        picker.onFolderTreeChange = { [weak self] tree in
            self?.folderTrees[connection.id] = tree
        }
        picker.onRegister = { [weak self] path in
            self?.registerRemoteRepository(at: path, for: host, connection: connection)
        }
        guard let presentationView = window?.contentView else { return }
        presentationView.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: presentationView.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: presentationView.trailingAnchor),
            picker.topAnchor.constraint(equalTo: presentationView.topAnchor),
            picker.bottomAnchor.constraint(equalTo: presentationView.bottomAnchor),
        ])
        folderPicker = picker
        applyTheme()
        presentationView.layoutSubtreeIfNeeded()
        picker.start()
    }

    private func warmEnabledConnections() {
        for connection in connections where connection.isEnabled {
            guard folderTrees[connection.id]?["~"] == nil,
                  folderWarmTasks[connection.id] == nil
            else { continue }
            let worker = Task.detached(priority: .userInitiated) {
                try RemoteDirectoryInspector().directoryTree(at: "~", connection: connection)
            }
            folderWarmTasks[connection.id] = worker
            Task { [weak self] in
                defer { self?.folderWarmTasks[connection.id] = nil }
                guard let tree = try? await worker.value, !Task.isCancelled else { return }
                self?.folderTrees[connection.id] = tree
            }
        }
    }

    private func dismissFolderPicker() {
        folderPicker?.removeFromSuperview()
        folderPicker = nil
    }

    private func registerRemoteRepository(
        at path: String,
        for host: SSHConfigHost,
        connection: SSHConnection
    ) {
        registrationTask?.cancel()
        let worker = Task.detached(priority: .userInitiated) {
            try RepositoryInspector().inspect(path: path, connection: connection)
        }
        registrationTask = Task { [weak self] in
            do {
                let repository = try await worker.value
                guard !Task.isCancelled, let self else { return }
                var repositories = try self.repositoryStore.load()
                guard !repositories.contains(where: {
                    $0.path == repository.path && $0.target == repository.target
                }) else {
                    throw ConnectionSettingsError.repositoryAlreadyRegistered
                }
                repositories.append(repository)
                try self.repositoryStore.save(repositories)
                self.dismissFolderPicker()
                self.closeDetails()
                self.showRepositories(for: host)
            } catch is CancellationError {
                return
            } catch {
                self?.folderPicker?.showError(error.localizedDescription)
            }
        }
    }

    private func setError(_ message: String?) {
        errorLabel.stringValue = message ?? ""
        errorLabel.isHidden = message == nil
    }
}

private enum ConnectionSettingsError: LocalizedError {
    case repositoryAlreadyRegistered

    var errorDescription: String? {
        switch self {
        case .repositoryAlreadyRegistered: "Repository already registered."
        }
    }
}

@MainActor
private final class ConnectionRowView: AppHoverView, SettingsThemeApplying {
    var onToggle: ((Bool) -> Void)?
    var onRepositories: (() -> Void)?

    private let icon = NSImageView()
    private let nameLabel: NSTextField
    private let detailLabel: NSTextField
    private let chevron = NSImageView()
    private let toggle = NSSwitch()
    private let repositoriesButton = AppButton(role: .hitTarget)

    init(host: SSHConfigHost, connection: SSHConnection?) {
        nameLabel = NSTextField(labelWithString: host.alias)
        detailLabel = NSTextField(labelWithString: host.detail)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = SettingsLayout.compactRowCornerRadius
        layer?.masksToBounds = true
        icon.image = NSImage(systemSymbolName: "network", accessibilityDescription: "SSH host")
        icon.imageScaling = .scaleProportionallyDown
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.imageScaling = .scaleProportionallyDown
        toggle.state = connection?.isEnabled == true ? .on : .off
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggleChanged)
        toggle.setAccessibilityLabel("Enable \(host.alias)")
        repositoriesButton.target = self
        repositoriesButton.action = #selector(showRepositories)
        repositoriesButton.setAccessibilityLabel("View repositories on \(host.alias)")
        [icon, nameLabel, detailLabel, chevron, toggle, repositoriesButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SettingsLayout.compactRowHeight),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsLayout.compactContentInset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: SettingsLayout.compactContentInset),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: SettingsLayout.compactMetadataGap),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -12),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsLayout.compactContentInset),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -16),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: SettingsLayout.compactChevronWidth),
            chevron.heightAnchor.constraint(equalToConstant: SettingsLayout.compactChevronHeight),
            repositoriesButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            repositoriesButton.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -8),
            repositoriesButton.topAnchor.constraint(equalTo: topAnchor),
            repositoriesButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.toolTip = host.detail
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.buttonAppearance(role: .naked, hovered: isHovering).background.cgColor
        nameLabel.textColor = AppTheme.primaryText
        nameLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 600)
        detailLabel.textColor = AppTheme.tertiaryText
        detailLabel.font = SettingsLayout.valueFont
        icon.contentTintColor = AppTheme.tertiaryText
        chevron.contentTintColor = AppTheme.tertiaryText
    }

    override func hoverStateDidChange() { applyTheme() }
    @objc private func toggleChanged() { onToggle?(toggle.state == .on) }
    @objc private func showRepositories() { onRepositories?() }
}

@MainActor
private final class ConnectionRepositoriesView: NSView, SettingsThemeApplying {
    var onBack: (() -> Void)?
    var onBrowse: (() -> Void)?

    private let header: ConnectionHeaderView
    private let page = SettingsSplitPageView(topPadding: SettingsLayout.detailPageTopPadding)
    private let connectionDetails: NSStackView
    private let repositoryContent = NSStackView()
    private let repositoryRows = NSStackView()
    private let browseAction: RemoteRepositoryBrowseActionView

    init(host: SSHConfigHost, connection: SSHConnection?, repositories: [RegisteredRepository]) {
        header = ConnectionHeaderView(title: host.alias)
        connectionDetails = settingsRowStack([
            SettingsRowView(
                title: "Alias",
                description: "Configured in ~/.ssh/config.",
                control: SettingsValueLabel(host.alias),
                controlHeight: nil
            ),
            SettingsRowView(
                title: "Host",
                description: "Remote hostname.",
                control: SettingsValueLabel(host.hostName ?? host.alias),
                controlHeight: nil
            ),
            SettingsRowView(
                title: "User",
                description: "Remote login user.",
                control: SettingsValueLabel(host.user ?? "SSH default"),
                controlHeight: nil
            ),
            SettingsRowView(
                title: "Port",
                description: "SSH port.",
                control: SettingsValueLabel(host.port ?? "22"),
                controlHeight: nil
            ),
            SettingsRowView(
                title: "Identity file",
                description: "Key selected by this host.",
                control: SettingsValueLabel(host.identityFile ?? "SSH default"),
                controlHeight: nil
            ),
        ])
        browseAction = RemoteRepositoryBrowseActionView(enabled: connection?.isEnabled == true)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        installLayout(connection: connection, repositories: repositories)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.background.cgColor
        header.applyTheme()
        page.applyTheme()
        browseAction.applyTheme()
        repositoryRows.arrangedSubviews.compactMap { $0 as? SettingsThemeApplying }.forEach { $0.applyTheme() }
    }

    private func installLayout(connection: SSHConnection?, repositories: [RegisteredRepository]) {
        wantsLayer = true
        [header, page].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        header.onBack = { [weak self] in self?.onBack?() }
        repositoryContent.orientation = .vertical
        repositoryContent.alignment = .leading
        repositoryContent.spacing = 0
        repositoryRows.orientation = .vertical
        repositoryRows.alignment = .leading
        repositoryRows.spacing = 0
        repositoryRows.setContentHuggingPriority(.required, for: .vertical)
        browseAction.setContentHuggingPriority(.required, for: .vertical)
        let rows: [NSView] = repositories.isEmpty
            ? [SettingsMessageRow("No remote repositories yet.")]
            : repositories.map(ConnectionRepositoryRowView.init)
        rows.forEach {
            repositoryRows.addArrangedSubview($0)
            $0.widthAnchor.constraint(equalTo: repositoryRows.widthAnchor).isActive = true
        }
        browseAction.onAction = { [weak self] in self?.onBrowse?() }
        [repositoryRows, browseAction].forEach {
            repositoryContent.addArrangedSubview($0)
            $0.widthAnchor.constraint(equalTo: repositoryContent.widthAnchor).isActive = true
        }
        repositoryContent.setCustomSpacing(8, after: repositoryRows)
        page.addSection(
            title: "Connection",
            detail: "Resolved from ~/.ssh/config.",
            content: connectionDetails
        )
        page.addSection(
            title: "Repositories",
            detail: connection?.isEnabled == true
                ? "Remote repositories available to tasks."
                : "Enable this connection to browse and register repositories.",
            content: repositoryContent
        )
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsLayout.pageHorizontalPadding),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsLayout.pageHorizontalPadding),
            header.topAnchor.constraint(equalTo: topAnchor, constant: SettingsLayout.detailHeaderTopPadding),
            page.leadingAnchor.constraint(equalTo: leadingAnchor),
            page.trailingAnchor.constraint(equalTo: trailingAnchor),
            page.topAnchor.constraint(equalTo: header.bottomAnchor, constant: SettingsLayout.breadcrumbToContentGap),
            page.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

@MainActor
private final class RemoteRepositoryBrowseActionView: AppHoverView, SettingsThemeApplying {
    var onAction: (() -> Void)?

    private let enabled: Bool
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "Browse remote folders")
    private let button = AppButton(role: .hitTarget)

    init(enabled: Bool) {
        self.enabled = enabled
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyDown
        [icon, label, button].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        button.target = self
        button.action = #selector(browse)
        button.isEnabled = enabled
        button.setAccessibilityLabel("Browse remote folders")
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SettingsLayout.compactRowHeight),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsLayout.compactContentInset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: SettingsLayout.compactIconSize),
            icon.heightAnchor.constraint(equalToConstant: SettingsLayout.compactIconSize),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: SettingsLayout.compactContentInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func applyTheme() {
        let appearance = AppTheme.buttonAppearance(role: .link, hovered: isHovering && enabled)
        icon.contentTintColor = enabled ? appearance.foreground : AppTheme.tertiaryText
        label.textColor = enabled ? appearance.foreground : AppTheme.tertiaryText
        label.font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 600)
    }

    override func hoverStateDidChange() { applyTheme() }
    @objc private func browse() { onAction?() }
}

@MainActor
private final class ConnectionRepositoryRowView: NSView, SettingsThemeApplying {
    private let icon = NSImageView()
    private let nameLabel: NSTextField
    private let metadataLabel: NSTextField

    init(repository: RegisteredRepository) {
        nameLabel = NSTextField(labelWithString: repository.name)
        metadataLabel = NSTextField(labelWithString: repository.path)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: "Repository")
        icon.imageScaling = .scaleProportionallyDown
        [icon, nameLabel, metadataLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SettingsLayout.compactRowHeight),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsLayout.compactContentInset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: SettingsLayout.compactIconSize),
            icon.heightAnchor.constraint(equalToConstant: SettingsLayout.compactIconSize),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: SettingsLayout.compactContentInset),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            metadataLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: SettingsLayout.compactMetadataGap),
            metadataLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsLayout.compactContentInset),
            metadataLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func applyTheme() {
        nameLabel.textColor = AppTheme.primaryText
        nameLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 600)
        metadataLabel.textColor = AppTheme.tertiaryText
        metadataLabel.font = SettingsLayout.valueFont
        icon.contentTintColor = AppTheme.tertiaryText
    }
}

@MainActor
private final class RemoteFolderPickerModal: NSView, SettingsThemeApplying {
    var onCancel: (() -> Void)?
    var onRegister: ((String) -> Void)?
    var onFolderTreeChange: (([String: [String]]) -> Void)?

    private let connection: SSHConnection
    private let card = NSView()
    private let titleLabel = NSTextField(labelWithString: "Choose remote repository")
    private let hostLabel: NSTextField
    private let closeButton = AppButton(role: .hitTarget)
    private let pathField = SettingsTextField()
    private let upButton = AppButton(role: .hitTarget)
    private let folderDocument = SettingsDocumentView()
    private let folderRows = NSStackView()
    private let folderScrollView = NSScrollView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let divider = NSView()
    private let cancelButton = ModalActionButton(title: "Cancel", primary: false)
    private let registerButton = ModalActionButton(title: "Register repository", primary: true)
    private var currentPath = "~"
    private var selectedPath: String?
    private var folderCache: [String: [String]] = [:]
    private let initialRootLoad: Task<[String: [String]], Error>?
    private var loadTask: Task<Void, Never>?
    private var folderFetchTasks: [String: Task<[String: [String]], Error>] = [:]
    private var isSizingFolderRows = false

    init(
        connection: SSHConnection,
        initialFolderTree: [String: [String]],
        initialRootLoad: Task<[String: [String]], Error>?
    ) {
        self.connection = connection
        folderCache = initialFolderTree
        self.initialRootLoad = initialRootLoad
        hostLabel = NSTextField(labelWithString: connection.name)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        installLayout()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    deinit {
        loadTask?.cancel()
        folderFetchTasks.values.forEach { $0.cancel() }
    }

    func start() {
        pathField.stringValue = currentPath
        loadFolders()
    }

    override func layout() {
        super.layout()
        sizeFolderRowsToViewport()
    }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.taskModalOverlayBackground.cgColor
        card.layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        card.layer?.borderColor = AppTheme.border.cgColor
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 650)
        hostLabel.textColor = AppTheme.secondaryText
        hostLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody, weight: 550)
        pathField.applyTheme()
        pathField.layer?.backgroundColor = AppTheme.taskModalInputBackground.cgColor
        errorLabel.textColor = AppTheme.error
        errorLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody)
        divider.layer?.backgroundColor = AppTheme.border.cgColor
        closeButton.applyTheme()
        upButton.applyTheme()
        cancelButton.applyTheme()
        registerButton.applyTheme()
        folderRows.arrangedSubviews.compactMap { $0 as? SettingsThemeApplying }.forEach { $0.applyTheme() }
        folderScrollView.backgroundColor = AppTheme.taskModalInputBackground
        folderScrollView.contentView.layer?.backgroundColor = AppTheme.taskModalInputBackground.cgColor
        folderDocument.layer?.backgroundColor = AppTheme.taskModalInputBackground.cgColor
    }

    private func installLayout() {
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = AppTheme.workspaceCornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.masksToBounds = true
        addSubview(card)
        [titleLabel, hostLabel, closeButton, pathField, upButton, folderScrollView, errorLabel, divider, cancelButton, registerButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview($0)
        }
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.target = self
        closeButton.action = #selector(cancel)
        upButton.image = NSImage(systemSymbolName: "arrow.turn.up.left", accessibilityDescription: "Go up")
        upButton.target = self
        upButton.action = #selector(goUp)
        pathField.delegate = self
        pathField.target = self
        pathField.action = #selector(openTypedPath)
        folderDocument.translatesAutoresizingMaskIntoConstraints = true
        folderDocument.wantsLayer = true
        folderRows.translatesAutoresizingMaskIntoConstraints = false
        folderRows.orientation = .vertical
        folderRows.alignment = .leading
        folderRows.spacing = 0
        folderDocument.addSubview(folderRows)
        folderScrollView.drawsBackground = true
        folderScrollView.borderType = .noBorder
        folderScrollView.hasVerticalScroller = true
        folderScrollView.autohidesScrollers = true
        folderScrollView.wantsLayer = true
        folderScrollView.contentView.wantsLayer = true
        folderScrollView.contentView.postsBoundsChangedNotifications = true
        folderScrollView.layer?.cornerRadius = SettingsLayout.compactRowCornerRadius
        folderScrollView.layer?.masksToBounds = true
        folderScrollView.documentView = folderDocument
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(folderScrollBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: folderScrollView.contentView
        )
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        registerButton.target = self
        registerButton.action = #selector(registerCurrentFolder)
        registerButton.isEnabled = false
        divider.wantsLayer = true
        errorLabel.isHidden = true
        let preferredWidth = card.widthAnchor.constraint(equalToConstant: AppTheme.taskModalCardWidth)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            preferredWidth,
            card.heightAnchor.constraint(equalToConstant: 560),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: AppTheme.taskModalPadding),
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: AppTheme.taskModalPadding),
            hostLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            hostLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            closeButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -AppTheme.taskModalPadding),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
            upButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            upButton.topAnchor.constraint(equalTo: hostLabel.bottomAnchor, constant: 22),
            upButton.widthAnchor.constraint(equalToConstant: 38),
            upButton.heightAnchor.constraint(equalToConstant: SettingsLayout.controlHeight),
            pathField.leadingAnchor.constraint(equalTo: upButton.trailingAnchor, constant: 8),
            pathField.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -AppTheme.taskModalPadding),
            pathField.centerYAnchor.constraint(equalTo: upButton.centerYAnchor),
            pathField.heightAnchor.constraint(equalToConstant: SettingsLayout.controlHeight),
            folderScrollView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            folderScrollView.trailingAnchor.constraint(equalTo: pathField.trailingAnchor),
            folderScrollView.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 14),
            folderScrollView.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -10),
            errorLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: pathField.trailingAnchor),
            errorLabel.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -12),
            divider.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            divider.bottomAnchor.constraint(equalTo: registerButton.topAnchor, constant: -12),
            cancelButton.trailingAnchor.constraint(equalTo: registerButton.leadingAnchor, constant: -12),
            cancelButton.centerYAnchor.constraint(equalTo: registerButton.centerYAnchor),
            cancelButton.heightAnchor.constraint(equalToConstant: AppTheme.taskModalButtonHeight),
            registerButton.trailingAnchor.constraint(equalTo: pathField.trailingAnchor),
            registerButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -AppTheme.taskModalFooterBottomInset),
            registerButton.heightAnchor.constraint(equalToConstant: AppTheme.taskModalButtonHeight),
            folderRows.leadingAnchor.constraint(equalTo: folderDocument.leadingAnchor),
            folderRows.trailingAnchor.constraint(equalTo: folderDocument.trailingAnchor),
            folderRows.topAnchor.constraint(equalTo: folderDocument.topAnchor),
        ])
    }

    private func loadFolders() {
        loadTask?.cancel()
        pathField.stringValue = currentPath
        errorLabel.isHidden = true
        let path = currentPath
        if let cached = folderCache[path] {
            showFolders(cached)
            return
        }
        showLoading()
        let worker = path == "~" ? initialRootLoad ?? fetchTask(for: path) : fetchTask(for: path)
        loadTask = Task { [weak self] in
            do {
                let tree = try await worker.value
                guard !Task.isCancelled, let self else { return }
                self.store(tree, for: path)
                guard self.currentPath == path else { return }
                self.showFolders(self.folderCache[path] ?? [])
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.currentPath == path else { return }
                self.showError(error.localizedDescription)
            }
        }
    }

    private func fetchTask(for path: String) -> Task<[String: [String]], Error> {
        if let task = folderFetchTasks[path] { return task }
        let task = Task.detached(priority: .userInitiated) { [connection] in
            try RemoteDirectoryInspector().directoryTree(at: path, connection: connection)
        }
        folderFetchTasks[path] = task
        return task
    }

    private func prefetch(_ path: String) {
        guard folderCache[path] == nil else { return }
        let worker = fetchTask(for: path)
        Task { [weak self] in
            guard let self else { return }
            guard let tree = try? await worker.value, !Task.isCancelled else { return }
            self.store(tree, for: path)
        }
    }

    private func store(_ tree: [String: [String]], for path: String) {
        folderCache.merge(tree) { _, fresh in fresh }
        folderFetchTasks[path] = nil
        onFolderTreeChange?(folderCache)
    }

    private func showFolders(_ folders: [String]) {
        folderRows.alphaValue = 1
        folderRows.arrangedSubviews.forEach {
            folderRows.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let rows: [NSView] = folders.isEmpty
            ? [SettingsMessageRow("No folders found here.")]
            : folders.map { path in
                let row = RemoteFolderPickerRow(path: path)
                row.isSelected = path == selectedPath
                row.onSelect = { [weak self] in
                    self?.select(path)
                }
                row.onOpen = { [weak self] in
                    self?.navigate(to: path)
                }
                return row
            }
        rows.forEach {
            folderRows.addArrangedSubview($0)
            $0.widthAnchor.constraint(equalTo: folderRows.widthAnchor).isActive = true
        }
        applyTheme()
        layoutSubtreeIfNeeded()
        sizeFolderRowsToViewport()
        folderScrollView.contentView.scroll(to: .zero)
        folderScrollView.reflectScrolledClipView(folderScrollView.contentView)
    }

    private func showLoading() {
        guard folderRows.arrangedSubviews.isEmpty else {
            folderRows.alphaValue = 0.45
            return
        }
        replaceFolderRows(with: [SettingsMessageRow("Loading folders…")])
    }

    private func replaceFolderRows(with rows: [NSView]) {
        folderRows.arrangedSubviews.forEach {
            folderRows.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        rows.forEach {
            folderRows.addArrangedSubview($0)
            $0.widthAnchor.constraint(equalTo: folderRows.widthAnchor).isActive = true
        }
        needsLayout = true
    }

    private func navigate(to path: String) {
        selectedPath = nil
        registerButton.isEnabled = false
        currentPath = path
        loadFolders()
    }

    private func select(_ path: String) {
        selectedPath = path
        registerButton.isEnabled = true
        folderRows.arrangedSubviews.compactMap { $0 as? RemoteFolderPickerRow }.forEach {
            $0.isSelected = $0.path == path
        }
        prefetch(path)
    }

    private func sizeFolderRowsToViewport() {
        guard !isSizingFolderRows else { return }
        let viewport = folderScrollView.contentView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        isSizingFolderRows = true
        defer { isSizingFolderRows = false }
        folderDocument.setFrameSize(NSSize(width: viewport.width, height: max(1, viewport.height)))
        folderDocument.layoutSubtreeIfNeeded()
        let height = max(folderRows.frame.maxY, viewport.height)
        folderDocument.setFrameSize(NSSize(width: viewport.width, height: height))
    }

    private func refreshFolderRowHoverStates() {
        folderRows.arrangedSubviews.compactMap { $0 as? RemoteFolderPickerRow }.forEach {
            $0.refreshHoverState()
        }
    }

    @objc private func folderScrollBoundsDidChange() {
        refreshFolderRowHoverStates()
    }

    func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }

    @objc private func goUp() {
        guard let parent = RemoteDirectoryInspector.parent(of: currentPath) else { return }
        navigate(to: parent)
    }

    @objc private func openTypedPath() {
        let path = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        navigate(to: path)
    }

    @objc private func registerCurrentFolder() {
        guard let selectedPath else { return }
        onRegister?(selectedPath)
    }
    @objc private func cancel() { onCancel?() }
}

extension RemoteFolderPickerModal: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === pathField else { return }
        openTypedPath()
    }
}

@MainActor
private final class RemoteFolderPickerRow: AppHoverView, SettingsThemeApplying {
    let path: String
    var onSelect: (() -> Void)?
    var onOpen: (() -> Void)?
    var isSelected = false {
        didSet { applyTheme() }
    }
    private let icon = NSImageView()
    private let nameLabel: NSTextField
    private let button = AppButton(role: .hitTarget)

    init(path: String) {
        self.path = path
        nameLabel = NSTextField(labelWithString: URL(fileURLWithPath: path).lastPathComponent)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = SettingsLayout.compactRowCornerRadius
        toolTip = path
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
        icon.imageScaling = .scaleProportionallyDown
        [icon, nameLabel, button].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        button.target = self
        button.action = #selector(activate)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func applyTheme() {
        let appearance = AppTheme.buttonAppearance(
            role: .segmented,
            hovered: isHovering,
            selected: isSelected
        )
        layer?.backgroundColor = appearance.background.cgColor
        icon.contentTintColor = AppTheme.tertiaryText
        nameLabel.textColor = isSelected ? appearance.foreground : AppTheme.primaryText
        nameLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 550)
    }

    override func hoverStateDidChange() { applyTheme() }
    @objc private func activate() {
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            onOpen?()
        } else {
            onSelect?()
        }
    }
}

@MainActor
private final class ConnectionHeaderView: NSView, SettingsThemeApplying {
    var onBack: (() -> Void)?
    private let backButton = SettingsActionButton(title: "Connections", target: nil, action: nil)
    private let separator = NSTextField(labelWithString: "/")
    private let titleLabel: NSTextField

    init(title: String) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        [backButton, separator, titleLabel].forEach {
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
            separator.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: SettingsLayout.breadcrumbGap),
            separator.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: separator.trailingAnchor, constant: SettingsLayout.breadcrumbGap),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: SettingsLayout.breadcrumbHeight),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func applyTheme() {
        backButton.applyTheme()
        separator.textColor = AppTheme.tertiaryText
        separator.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody)
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody, weight: 550)
    }

    @objc private func goBack() { onBack?() }
}
