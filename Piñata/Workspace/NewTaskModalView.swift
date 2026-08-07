import AppKit

@MainActor
final class NewTaskModalView: NSView, NSTextFieldDelegate {
    var onCancel: (() -> Void)?
    var onCreate: ((String, [RegisteredRepository]) -> Void)?

    private let repositories: [RegisteredRepository]
    private var selectedRepositoryIDs = Set<UUID>()
    private let card = NSView()
    private let titleLabel = NSTextField(labelWithString: "New task")
    private let titleField = SettingsTextField()
    private let helperLabel = NSTextField(
        wrappingLabelWithString: "Named after the work, not the branch. Piñata names branches from the pattern in Settings."
    )
    private let repositoryLabel = NSTextField(labelWithString: "REPOSITORIES  optional")
    private let repositoryStack = NewTaskRepositoryStackView()
    private let repositoryScrollView = NSScrollView()
    private let noteLabel = NSTextField(
        wrappingLabelWithString: "Leave these empty to start as a conversation, then attach repositories once the work needs to write code."
    )
    private let cancelButton = NewTaskActionButton(title: "Cancel", primary: false)
    private let createButton = NewTaskActionButton(title: "Create task", primary: true)
    private let divider = NSView()
    private var mouseDownMonitor: Any?

    private var repositoryHeight: CGFloat {
        guard !repositories.isEmpty else { return AppTheme.taskModalEmptyRepositoryHeight }
        return CGFloat(min(repositories.count, AppTheme.taskModalMaximumVisibleRepositories))
            * AppTheme.taskModalRowHeight
    }

    init(repositories: [RegisteredRepository], repositoryError: String? = nil) {
        self.repositories = repositories
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = AppTheme.workspaceCornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.masksToBounds = true
        addSubview(card)

        configureContent(repositoryError: repositoryError)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func focusTitle() {
        window?.makeFirstResponder(titleField)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
            self.mouseDownMonitor = nil
        }
        guard window != nil else { return }
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self, event.window === window else { return event }
            let point = titleField.convert(event.locationInWindow, from: nil)
            if !titleField.bounds.contains(point) {
                window?.makeFirstResponder(nil)
            }
            return event
        }
    }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.taskModalOverlayBackground.cgColor
        card.layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        card.layer?.borderColor = AppTheme.border.cgColor
        divider.layer?.backgroundColor = AppTheme.border.cgColor
        let repositoryBackground = repositories.isEmpty ? NSColor.clear : AppTheme.controlSelection
        repositoryScrollView.backgroundColor = repositoryBackground
        repositoryScrollView.contentView.layer?.backgroundColor = repositoryBackground.cgColor
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 650)
        titleLabel.textColor = AppTheme.primaryText
        titleField.applyTheme()
        titleField.layer?.backgroundColor = AppTheme.taskModalInputBackground.cgColor
        helperLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody)
        helperLabel.textColor = AppTheme.tertiaryText
        repositoryLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsLabel, weight: 600)
        repositoryLabel.textColor = AppTheme.tertiaryText
        noteLabel.font = NSFontManager.shared.convert(
            AppTheme.font(ofSize: AppTheme.typography.settingsBody),
            toHaveTrait: .italicFontMask
        )
        noteLabel.textColor = AppTheme.tertiaryText
        repositoryStack.arrangedSubviews
            .compactMap { $0 as? NewTaskRepositoryRow }
            .forEach { $0.applyTheme() }
        repositoryStack.arrangedSubviews
            .compactMap { $0 as? NewTaskRepositoryEmptyView }
            .forEach { $0.applyTheme() }
        cancelButton.applyTheme()
        createButton.applyTheme()
    }

    func controlTextDidChange(_ notification: Notification) {
        updateValidation()
    }

    private func configureContent(repositoryError: String?) {
        [titleLabel, titleField, helperLabel, repositoryLabel, repositoryScrollView,
         noteLabel, divider, cancelButton, createButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview($0)
        }

        titleField.placeholderString = "What are you working on?"
        titleField.delegate = self
        titleField.target = self
        titleField.action = #selector(createTask)

        helperLabel.maximumNumberOfLines = 2
        noteLabel.maximumNumberOfLines = 2
        noteLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody)

        repositoryScrollView.drawsBackground = true
        repositoryScrollView.borderType = .noBorder
        repositoryScrollView.hasVerticalScroller =
            repositories.count > AppTheme.taskModalMaximumVisibleRepositories
        repositoryScrollView.autohidesScrollers = true
        repositoryScrollView.wantsLayer = true
        repositoryScrollView.contentView.wantsLayer = true
        repositoryScrollView.layer?.cornerRadius = AppTheme.taskModalListCornerRadius
        repositoryScrollView.layer?.cornerCurve = .continuous
        repositoryScrollView.layer?.masksToBounds = true
        repositoryStack.translatesAutoresizingMaskIntoConstraints = false
        repositoryStack.orientation = .vertical
        repositoryStack.alignment = .leading
        repositoryStack.spacing = 0
        repositoryScrollView.documentView = repositoryStack

        if repositories.isEmpty {
            let emptyView = NewTaskRepositoryEmptyView(
                message: repositoryError
                    ?? "No repositories registered yet. Add one later in Settings.",
                error: repositoryError != nil
            )
            repositoryStack.addArrangedSubview(emptyView)
            NSLayoutConstraint.activate([
                emptyView.widthAnchor.constraint(equalTo: repositoryStack.widthAnchor),
                emptyView.heightAnchor.constraint(
                    equalToConstant: AppTheme.taskModalEmptyRepositoryHeight
                ),
            ])
            noteLabel.stringValue =
                "Tasks can start as conversations. Attach a repository later when the work needs code."
        } else {
            repositories.enumerated().forEach { index, repository in
                let row = NewTaskRepositoryRow(
                    repository: repository,
                    showsSeparator: index < repositories.count - 1
                )
                row.onToggle = { [weak self] repositoryID, selected in
                    if selected {
                        self?.selectedRepositoryIDs.insert(repositoryID)
                    } else {
                        self?.selectedRepositoryIDs.remove(repositoryID)
                    }
                }
                repositoryStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: repositoryStack.widthAnchor).isActive = true
            }
        }

        divider.wantsLayer = true
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        createButton.target = self
        createButton.action = #selector(createTask)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: AppTheme.taskModalCardWidth),

            titleLabel.leadingAnchor.constraint(
                equalTo: card.leadingAnchor,
                constant: AppTheme.taskModalPadding
            ),
            titleLabel.trailingAnchor.constraint(
                equalTo: card.trailingAnchor,
                constant: -AppTheme.taskModalPadding
            ),
            titleLabel.topAnchor.constraint(
                equalTo: card.topAnchor,
                constant: AppTheme.taskModalPadding
            ),

            titleField.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            titleField.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            titleField.topAnchor.constraint(
                equalTo: titleLabel.bottomAnchor,
                constant: AppTheme.taskModalContentGap
            ),
            titleField.heightAnchor.constraint(equalToConstant: AppTheme.taskModalFieldHeight),

            helperLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            helperLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            helperLabel.topAnchor.constraint(
                equalTo: titleField.bottomAnchor,
                constant: AppTheme.taskModalHelperGap
            ),

            repositoryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            repositoryLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            repositoryLabel.topAnchor.constraint(
                equalTo: helperLabel.bottomAnchor,
                constant: AppTheme.taskModalRepositoryBlockGap
            ),

            repositoryScrollView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            repositoryScrollView.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            repositoryScrollView.topAnchor.constraint(
                equalTo: repositoryLabel.bottomAnchor,
                constant: AppTheme.taskModalRepositoryListGap
            ),
            repositoryScrollView.heightAnchor.constraint(equalToConstant: repositoryHeight),
            repositoryStack.leadingAnchor.constraint(equalTo: repositoryScrollView.contentView.leadingAnchor),
            repositoryStack.trailingAnchor.constraint(equalTo: repositoryScrollView.contentView.trailingAnchor),
            repositoryStack.topAnchor.constraint(equalTo: repositoryScrollView.contentView.topAnchor),
            repositoryStack.widthAnchor.constraint(equalTo: repositoryScrollView.contentView.widthAnchor),

            noteLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            noteLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            noteLabel.topAnchor.constraint(
                equalTo: repositoryScrollView.bottomAnchor,
                constant: AppTheme.taskModalNoteGap
            ),

            divider.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            divider.topAnchor.constraint(
                equalTo: noteLabel.bottomAnchor,
                constant: AppTheme.taskModalDividerTopSpacing
            ),
            divider.heightAnchor.constraint(equalToConstant: AppTheme.workspaceDividerThickness),

            createButton.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            createButton.topAnchor.constraint(
                equalTo: divider.bottomAnchor,
                constant: AppTheme.taskModalFooterControlSpacing
            ),
            createButton.bottomAnchor.constraint(
                equalTo: card.bottomAnchor,
                constant: -AppTheme.taskModalFooterBottomInset
            ),
            createButton.heightAnchor.constraint(equalToConstant: AppTheme.taskModalButtonHeight),
            createButton.widthAnchor.constraint(
                greaterThanOrEqualToConstant: AppTheme.taskModalCreateButtonMinimumWidth
            ),
            cancelButton.trailingAnchor.constraint(
                equalTo: createButton.leadingAnchor,
                constant: -AppTheme.taskModalButtonSpacing
            ),
            cancelButton.centerYAnchor.constraint(equalTo: createButton.centerYAnchor),
            cancelButton.heightAnchor.constraint(equalTo: createButton.heightAnchor),
            cancelButton.widthAnchor.constraint(
                greaterThanOrEqualToConstant: AppTheme.taskModalCancelButtonMinimumWidth
            ),
        ])
        updateValidation()
    }

    private func updateValidation() {
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        createButton.isEnabled = !title.isEmpty
    }

    @objc private func cancel() {
        onCancel?()
    }

    @objc private func createTask() {
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            NSSound.beep()
            return
        }
        let selected = repositories.filter { selectedRepositoryIDs.contains($0.id) }
        onCreate?(title, selected)
    }
}

@MainActor
private final class NewTaskRepositoryEmptyView: NSView {
    private let error: Bool
    private let icon = NSImageView()
    private let messageLabel: NSTextField

    init(message: String, error: Bool) {
        self.error = error
        messageLabel = NSTextField(wrappingLabelWithString: message)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = AppTheme.taskModalListCornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        icon.image = NSImage(
            systemSymbolName: error ? "exclamationmark.triangle" : "book.closed",
            accessibilityDescription: error ? "Repository error" : "No repositories"
        )
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 2
        [icon, messageLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.topAnchor.constraint(
                equalTo: topAnchor,
                constant: AppTheme.taskModalEmptyIconTopInset
            ),
            icon.widthAnchor.constraint(equalToConstant: AppTheme.taskModalEmptyIconSize),
            icon.heightAnchor.constraint(equalToConstant: AppTheme.taskModalEmptyIconSize),
            messageLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: AppTheme.taskModalPadding
            ),
            messageLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -AppTheme.taskModalPadding
            ),
            messageLabel.topAnchor.constraint(
                equalTo: icon.bottomAnchor,
                constant: AppTheme.taskModalEmptyMessageGap
            ),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        layer?.borderColor = AppTheme.border.cgColor
        icon.contentTintColor = error ? .systemRed : AppTheme.tertiaryText
        messageLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody)
        messageLabel.textColor = error ? .systemRed : AppTheme.tertiaryText
    }
}

private final class NewTaskRepositoryStackView: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class NewTaskRepositoryRow: AppHoverView {
    var onToggle: ((UUID, Bool) -> Void)?

    private let repository: RegisteredRepository
    private let showsSeparator: Bool
    private var selected = false
    private let checkbox = NSImageView()
    private let nameLabel: NSTextField
    private let repositoryIcon = NSImageView()
    private let separator = NSView()
    private let button = AppButton(role: .hitTarget)

    init(repository: RegisteredRepository, showsSeparator: Bool) {
        self.repository = repository
        self.showsSeparator = showsSeparator
        nameLabel = NSTextField(labelWithString: repository.name)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        repositoryIcon.image = NSImage(
            systemSymbolName: "book.closed",
            accessibilityDescription: "Repository"
        )
        separator.wantsLayer = true
        button.target = self
        button.action = #selector(toggle)
        button.setAccessibilityLabel(repository.name)
        button.setAccessibilityRole(.checkBox)
        [checkbox, nameLabel, repositoryIcon, separator, button].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: AppTheme.taskModalRowHeight),
            checkbox.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: AppTheme.taskModalRowHorizontalInset
            ),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: AppTheme.taskModalCheckboxSize),
            checkbox.heightAnchor.constraint(equalToConstant: AppTheme.taskModalCheckboxSize),
            nameLabel.leadingAnchor.constraint(
                equalTo: checkbox.trailingAnchor,
                constant: AppTheme.taskModalRowContentGap
            ),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: repositoryIcon.leadingAnchor,
                constant: -AppTheme.taskModalRowContentGap
            ),
            repositoryIcon.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -AppTheme.taskModalRowHorizontalInset
            ),
            repositoryIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            repositoryIcon.widthAnchor.constraint(
                equalToConstant: AppTheme.taskModalRepositoryIconSize
            ),
            repositoryIcon.heightAnchor.constraint(
                equalToConstant: AppTheme.taskModalRepositoryIconSize
            ),
            separator.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: AppTheme.taskModalRowHorizontalInset
            ),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: AppTheme.workspaceDividerThickness),
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
        let appearance = AppTheme.buttonAppearance(
            role: .naked,
            hovered: isHovering
        )
        checkbox.image = NSImage(
            systemSymbolName: selected ? "checkmark.square.fill" : "square",
            accessibilityDescription: nil
        )
        checkbox.contentTintColor = selected ? AppTheme.accent : AppTheme.tertiaryText
        nameLabel.font = .monospacedSystemFont(
            ofSize: AppTheme.typography.settingsValue,
            weight: .regular
        )
        nameLabel.textColor = selected ? AppTheme.primaryText : AppTheme.secondaryText
        repositoryIcon.contentTintColor = AppTheme.tertiaryText
        separator.layer?.backgroundColor = AppTheme.border.cgColor
        separator.isHidden = !showsSeparator
        layer?.backgroundColor = appearance.background.cgColor
        button.setAccessibilityValue(selected ? 1 : 0)
    }

    override func hoverStateDidChange() {
        applyTheme()
    }

    @objc private func toggle() {
        selected.toggle()
        applyTheme()
        onToggle?(repository.id, selected)
    }
}

@MainActor
private final class NewTaskActionButton: AppButton {
    init(title: String, primary: Bool) {
        super.init(frame: .zero)
        role = primary ? .accent : .naked
        self.title = title
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = AppTheme.taskModalButtonCornerRadius
        layer?.cornerCurve = .continuous
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func applyTheme() {
        super.applyTheme()
        font = AppTheme.font(ofSize: AppTheme.typography.settingsBody, weight: 650)
    }
}
