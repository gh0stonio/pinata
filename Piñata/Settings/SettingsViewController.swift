import AppKit

@MainActor
final class SettingsViewController: NSViewController {
    var onChange: ((UserSettings) -> Bool)?
    var onClose: (() -> Void)?

    private var settings: UserSettings
    private let rail = NSView()
    private let content = NSView()
    private let backButton = NSButton(title: "Back to app", target: nil, action: nil)
    private let personalLabel = NSTextField(labelWithString: "PERSONAL")
    private let appearanceRow = SettingsNavigationRow(title: "Appearance", symbolName: "sun.max")
    private let codingLabel = NSTextField(labelWithString: "CODING")
    private let gitRow = SettingsNavigationRow(title: "Git & PR", image: GitPullRequestIcon.image)
    private let appearanceContent = SettingsPageView(title: "Appearance")
    private let gitContent = RepositorySettingsView()
    private let themeControl = FlatChoiceControl(labels: ["Piñata Dark", "Piñata Light"])
    private let accentControl = AccentChoiceControl()
    private let intensityControl = FlatChoiceControl(labels: ["Transparent", "Balanced", "Vibrant"])
    private let appFontControl = FlatChoiceControl(labels: ["Small", "Default", "Large"])
    private let terminalFontControl = FlatChoiceControl(labels: ["12px", "13px", "14px", "15px"])

    init(settings: UserSettings) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        view = root

        for panel in [rail, content] {
            panel.translatesAutoresizingMaskIntoConstraints = false
            panel.wantsLayer = true
            root.addSubview(panel)
        }
        content.layer?.cornerRadius = AppTheme.workspaceCornerRadius
        content.layer?.cornerCurve = .continuous
        content.layer?.borderWidth = 1
        content.layer?.masksToBounds = true

        installRail()
        installContent()
        installGitContent()
        selectCurrentValues()
        applyTheme()
    }

    func applyTheme() {
        view.layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        rail.layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        content.layer?.backgroundColor = AppTheme.background.cgColor
        content.layer?.borderColor = AppTheme.border.cgColor
        appearanceContent.applyTheme()
        backButton.contentTintColor = AppTheme.secondaryText
        backButton.font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 600)
        SettingsLayout.applySectionLabelStyle(personalLabel)
        appearanceRow.applyTheme()
        SettingsLayout.applySectionLabelStyle(codingLabel)
        gitRow.applyTheme()
        gitContent.applyTheme()
        themeControl.applyTheme()
        accentControl.applyTheme()
        intensityControl.applyTheme()
        appFontControl.applyTheme()
        terminalFontControl.applyTheme()
    }

    private func installRail() {
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.isBordered = false
        backButton.alignment = .left
        backButton.image = NSImage(systemSymbolName: "arrow.left", accessibilityDescription: nil)
        backButton.imagePosition = .imageLeading
        backButton.imageHugsTitle = true
        backButton.target = self
        backButton.action = #selector(closeSettings)

        personalLabel.translatesAutoresizingMaskIntoConstraints = false
        personalLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsLabel, weight: 600)
        appearanceRow.translatesAutoresizingMaskIntoConstraints = false
        codingLabel.translatesAutoresizingMaskIntoConstraints = false
        gitRow.translatesAutoresizingMaskIntoConstraints = false
        gitRow.isSelected = false
        appearanceRow.onSelect = { [weak self] in self?.showGit(false) }
        gitRow.onSelect = { [weak self] in self?.showGit(true) }

        rail.addSubview(backButton)
        rail.addSubview(personalLabel)
        rail.addSubview(appearanceRow)
        rail.addSubview(codingLabel)
        rail.addSubview(gitRow)

        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rail.topAnchor.constraint(equalTo: view.topAnchor),
            rail.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rail.widthAnchor.constraint(equalToConstant: AppTheme.settingsRailWidth),

            backButton.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 20),
            backButton.trailingAnchor.constraint(equalTo: rail.trailingAnchor, constant: -20),
            backButton.topAnchor.constraint(equalTo: rail.topAnchor, constant: 40),
            backButton.heightAnchor.constraint(equalToConstant: 28),

            personalLabel.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: AppTheme.panelContentInset),
            personalLabel.topAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 20),

            appearanceRow.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: AppTheme.panelContentInset),
            appearanceRow.trailingAnchor.constraint(equalTo: rail.trailingAnchor, constant: -AppTheme.panelContentInset),
            appearanceRow.topAnchor.constraint(equalTo: personalLabel.bottomAnchor, constant: 8),
            appearanceRow.heightAnchor.constraint(equalToConstant: 32),
            codingLabel.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: AppTheme.panelContentInset),
            codingLabel.topAnchor.constraint(equalTo: appearanceRow.bottomAnchor, constant: 24),
            gitRow.leadingAnchor.constraint(equalTo: appearanceRow.leadingAnchor),
            gitRow.trailingAnchor.constraint(equalTo: appearanceRow.trailingAnchor),
            gitRow.topAnchor.constraint(equalTo: codingLabel.bottomAnchor, constant: 8),
            gitRow.heightAnchor.constraint(equalTo: appearanceRow.heightAnchor),
        ])
    }

    private func installContent() {
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            content.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -AppTheme.workspaceInset
            ),
            content.topAnchor.constraint(
                equalTo: view.topAnchor,
                constant: AppTheme.workspaceInset
            ),
            content.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -AppTheme.workspaceInset
            ),
        ])

        content.addSubview(appearanceContent)
        NSLayoutConstraint.activate([
            appearanceContent.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            appearanceContent.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            appearanceContent.topAnchor.constraint(equalTo: content.topAnchor),
            appearanceContent.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let themeCard = SettingsCardView(rows: [
            SettingsRowView(
                title: "Color theme",
                description: "Piñata dark, or a matched light variant",
                control: themeControl,
                controlWidth: 210
            ),
            SettingsRowView(
                title: "Accent color",
                description: "Highlights, active tabs and primary actions",
                control: accentControl,
                controlWidth: 210
            ),
            SettingsRowView(
                title: "Accent intensity",
                description: "How loud accent surfaces should feel across the app",
                control: intensityControl,
                controlWidth: 250
            ),
        ])
        let textCard = SettingsCardView(rows: [
            SettingsRowView(
                title: "App font size",
                description: "Side panels, settings and task dialogs",
                control: appFontControl,
                controlWidth: 174
            ),
            SettingsRowView(
                title: "Terminal font size",
                description: "Embedded terminal text only",
                control: terminalFontControl,
                controlWidth: 204
            ),
        ])
        appearanceContent.addSection(title: "Theme", content: themeCard)
        appearanceContent.addSection(title: "Text", content: textCard)

        for control in [themeControl, intensityControl, appFontControl, terminalFontControl] {
            control.onChange = { [weak self] _ in self?.settingChanged() }
        }
        accentControl.onChange = { [weak self] _ in self?.settingChanged() }
    }

    private func installGitContent() {
        content.addSubview(gitContent)
        NSLayoutConstraint.activate([
            gitContent.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            gitContent.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            gitContent.topAnchor.constraint(equalTo: content.topAnchor),
            gitContent.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        gitContent.isHidden = true
    }

    private func showGit(_ visible: Bool) {
        gitContent.isHidden = !visible
        appearanceContent.isHidden = visible
        appearanceRow.isSelected = !visible
        gitRow.isSelected = visible
        view.layoutSubtreeIfNeeded()
        if visible {
            gitContent.scrollToTop()
        } else {
            appearanceContent.scrollToTop()
        }
    }

    private func selectCurrentValues() {
        themeControl.selectedIndex = ThemePreference.allCases.firstIndex(of: settings.theme) ?? 0
        accentControl.selectedIndex = AccentPreference.allCases.firstIndex(of: settings.accent) ?? 0
        intensityControl.selectedIndex = AccentIntensity.allCases.firstIndex(of: settings.accentIntensity) ?? 0
        appFontControl.selectedIndex = AppFontSize.allCases.firstIndex(of: settings.appFontSize) ?? 0
        terminalFontControl.selectedIndex = TerminalFontSize.allCases.firstIndex(of: settings.terminalFontSize) ?? 0
    }

    private func settingChanged() {
        let next = UserSettings(
            theme: ThemePreference.allCases[themeControl.selectedIndex],
            accent: AccentPreference.allCases[accentControl.selectedIndex],
            accentIntensity: AccentIntensity.allCases[intensityControl.selectedIndex],
            appFontSize: AppFontSize.allCases[appFontControl.selectedIndex],
            terminalFontSize: TerminalFontSize.allCases[terminalFontControl.selectedIndex]
        )
        if onChange?(next) == false {
            selectCurrentValues()
        } else {
            settings = next
        }
    }

    @objc private func closeSettings() {
        onClose?()
    }
}

@MainActor
private final class SettingsNavigationRow: NSView {
    var onSelect: (() -> Void)?
    var isSelected = true {
        didSet { applyTheme() }
    }

    private let icon = NSImageView()
    private let label: NSTextField
    private let button = NSButton(title: "", target: nil, action: nil)

    convenience init(title: String, symbolName: String) {
        self.init(
            title: title,
            image: NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage()
        )
    }

    init(title: String, image: NSImage) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = image
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        button.target = self
        button.action = #selector(selectRow)
        button.setAccessibilityLabel(title)
        addSubview(icon)
        addSubview(label)
        addSubview(button)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        let foreground = isSelected ? AppTheme.panelAccentIcon : AppTheme.secondaryText
        layer?.backgroundColor = isSelected ? AppTheme.panelAccentBackground.cgColor : .clear
        icon.contentTintColor = foreground
        label.textColor = foreground
        label.font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 550)
    }

    @objc private func selectRow() {
        onSelect?()
    }
}
private enum GitPullRequestIcon {
    static let image: NSImage = {
        let image = Bundle.main.url(forResource: "git-pull-request", withExtension: "png")
            .flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
            ?? NSImage()
        image.isTemplate = true
        return image
    }()
}

@MainActor
private final class FlatChoiceControl: NSView {
    var onChange: ((Int) -> Void)?
    var selectedIndex = 0 {
        didSet { applyTheme() }
    }

    private let buttons: [FlatChoiceButton]

    init(labels: [String]) {
        buttons = labels.enumerated().map { FlatChoiceButton(title: $0.element, index: $0.offset) }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true

        let stack = NSStackView(views: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .height
        stack.spacing = 0
        stack.distribution = .fillProportionally
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        buttons.forEach {
            $0.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        }

        buttons.forEach {
            $0.target = self
            $0.action = #selector(choiceSelected(_:))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.controlBackground.cgColor
        for button in buttons {
            button.applyTheme(selected: button.tag == selectedIndex)
        }
    }

    @objc private func choiceSelected(_ sender: NSButton) {
        selectedIndex = sender.tag
        onChange?(selectedIndex)
    }
}

@MainActor
private final class FlatChoiceButton: NSButton {
    init(title: String, index: Int) {
        super.init(frame: .zero)
        self.title = title
        tag = index
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 5
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 18, height: size.height)
    }

    func applyTheme(selected: Bool) {
        layer?.backgroundColor = selected ? AppTheme.controlSelection.cgColor : NSColor.clear.cgColor
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: AppTheme.font(ofSize: AppTheme.typography.settingsBody, weight: 600),
                .foregroundColor: selected ? AppTheme.primaryText : AppTheme.secondaryText,
            ]
        )
        setAccessibilityValue(selected)
    }
}

@MainActor
private final class AccentChoiceControl: NSView {
    var onChange: ((Int) -> Void)?
    var selectedIndex = 0 {
        didSet { applyTheme() }
    }

    private let buttons = AccentPreference.allCases.enumerated().map {
        AccentChoiceButton(accent: $0.element, index: $0.offset)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let stack = NSStackView(views: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 7
        stack.distribution = .fillEqually
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        buttons.forEach {
            $0.target = self
            $0.action = #selector(choiceSelected(_:))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        for button in buttons {
            button.applyTheme(selected: button.tag == selectedIndex)
        }
    }

    @objc private func choiceSelected(_ sender: NSButton) {
        selectedIndex = sender.tag
        onChange?(selectedIndex)
    }
}

@MainActor
private final class AccentChoiceButton: NSButton {
    private let accent: AccentPreference

    init(accent: AccentPreference, index: Int) {
        self.accent = accent
        super.init(frame: .zero)
        tag = index
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 12
        setAccessibilityLabel(accent.rawValue.capitalized)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme(selected: Bool) {
        layer?.backgroundColor = AppTheme.accentColor(for: accent).cgColor
        layer?.borderWidth = 0
        attributedTitle = NSAttributedString(
            string: selected ? "✓" : "",
            attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .bold),
                .foregroundColor: AppTheme.accentForegroundColor(for: accent),
            ]
        )
        setAccessibilityValue(selected)
    }
}
