import AppKit

@MainActor
final class SettingsViewController: NSViewController {
    var onChange: ((UserSettings) -> Bool)?
    var onClose: (() -> Void)?

    private var settings: UserSettings
    private let rail = NSView()
    private let content = NSView()
    private let titleLabel = NSTextField(labelWithString: "Appearance")
    private let backButton = NSButton(title: " Back to app", target: nil, action: nil)
    private let sectionLabels = [
        NSTextField(labelWithString: "THEME"),
        NSTextField(labelWithString: "TEXT"),
    ]
    private let personalLabel = NSTextField(labelWithString: "PERSONAL")
    private let appearanceRow = SettingsNavigationRow(title: "Appearance", symbolName: "sun.max")
    private let themeControl = FlatChoiceControl(labels: ["Piñata Dark", "Piñata Light"])
    private let accentControl = AccentChoiceControl()
    private let intensityControl = FlatChoiceControl(labels: ["Transparent", "Balanced", "Vibrant"])
    private let appFontControl = FlatChoiceControl(labels: ["Small", "Default", "Large"])
    private let terminalFontControl = FlatChoiceControl(labels: ["12px", "13px", "14px", "15px"])
    private var primaryLabels: [NSTextField] = []
    private var secondaryLabels: [NSTextField] = []
    private var cards: [NSView] = []

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
        selectCurrentValues()
        applyTheme()
    }

    func applyTheme() {
        view.layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        rail.layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        content.layer?.backgroundColor = AppTheme.background.cgColor
        content.layer?.borderColor = AppTheme.border.cgColor
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsDisplay, weight: 550)
        backButton.contentTintColor = AppTheme.secondaryText
        backButton.font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 600)
        applySectionLabelStyle(personalLabel)
        appearanceRow.applyTheme()
        sectionLabels.forEach(applySectionLabelStyle)
        primaryLabels.forEach {
            $0.textColor = AppTheme.primaryText
            $0.font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 550)
        }
        secondaryLabels.forEach {
            $0.textColor = AppTheme.tertiaryText
            $0.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody)
        }
        cards.forEach {
            $0.layer?.backgroundColor = AppTheme.chromeBackground.cgColor
            $0.layer?.borderColor = AppTheme.border.cgColor
        }
        themeControl.applyTheme()
        accentControl.applyTheme()
        intensityControl.applyTheme()
        appFontControl.applyTheme()
        terminalFontControl.applyTheme()
    }

    private func applySectionLabelStyle(_ label: NSTextField) {
        let fontSize = AppTheme.typography.settingsLabel
        label.attributedStringValue = NSAttributedString(
            string: label.stringValue,
            attributes: [
                .font: AppTheme.font(ofSize: fontSize, weight: 600),
                .foregroundColor: AppTheme.tertiaryText,
                .kern: fontSize * 0.08,
            ]
        )
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

        rail.addSubview(backButton)
        rail.addSubview(personalLabel)
        rail.addSubview(appearanceRow)

        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rail.topAnchor.constraint(equalTo: view.topAnchor),
            rail.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rail.widthAnchor.constraint(equalToConstant: 280),

            backButton.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 20),
            backButton.trailingAnchor.constraint(equalTo: rail.trailingAnchor, constant: -20),
            backButton.topAnchor.constraint(equalTo: rail.topAnchor, constant: 40),
            backButton.heightAnchor.constraint(equalToConstant: 28),

            personalLabel.leadingAnchor.constraint(equalTo: backButton.leadingAnchor),
            personalLabel.topAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 20),

            appearanceRow.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 12),
            appearanceRow.trailingAnchor.constraint(equalTo: rail.trailingAnchor, constant: -12),
            appearanceRow.topAnchor.constraint(equalTo: personalLabel.bottomAnchor, constant: 8),
            appearanceRow.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func installContent() {
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(
                equalTo: rail.trailingAnchor,
                constant: AppTheme.workspaceInset
            ),
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

        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        sectionLabels.forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        let themeCard = makeCard(rows: [
            makeRow(
                title: "Color theme",
                description: "Piñata dark, or a matched light variant",
                control: themeControl,
                controlWidth: 210
            ),
            makeRow(
                title: "Accent color",
                description: "Highlights, active tabs and primary actions",
                control: accentControl,
                controlWidth: 210
            ),
            makeRow(
                title: "Accent intensity",
                description: "How loud accent surfaces should feel across the app",
                control: intensityControl,
                controlWidth: 250
            ),
        ])
        let textCard = makeCard(rows: [
            makeRow(
                title: "App font size",
                description: "Side panels, settings and task dialogs",
                control: appFontControl,
                controlWidth: 174
            ),
            makeRow(
                title: "Terminal font size",
                description: "Embedded terminal text only",
                control: terminalFontControl,
                controlWidth: 204
            ),
        ])

        for item in [titleLabel, sectionLabels[0], themeCard, sectionLabels[1], textCard] {
            column.addSubview(item)
        }

        let responsiveWidth = column.widthAnchor.constraint(
            equalTo: content.widthAnchor,
            constant: -80
        )
        responsiveWidth.priority = .defaultLow


        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 34),
            column.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            responsiveWidth,
            column.widthAnchor.constraint(greaterThanOrEqualToConstant: 660),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 750),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 40),
            column.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -40),
            column.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -40),

            titleLabel.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: column.topAnchor),

            sectionLabels[0].leadingAnchor.constraint(equalTo: column.leadingAnchor),
            sectionLabels[0].topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            themeCard.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            themeCard.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            themeCard.topAnchor.constraint(equalTo: sectionLabels[0].bottomAnchor, constant: 8),

            sectionLabels[1].leadingAnchor.constraint(equalTo: column.leadingAnchor),
            sectionLabels[1].topAnchor.constraint(equalTo: themeCard.bottomAnchor, constant: 16),
            textCard.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            textCard.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            textCard.topAnchor.constraint(equalTo: sectionLabels[1].bottomAnchor, constant: 8),
            textCard.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])

        for control in [themeControl, intensityControl, appFontControl, terminalFontControl] {
            control.onChange = { [weak self] _ in self?.settingChanged() }
        }
        accentControl.onChange = { [weak self] _ in self?.settingChanged() }
    }

    private func makeCard(rows: [NSView]) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = AppTheme.workspaceCornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.masksToBounds = true
        cards.append(card)

        let stack = NSStackView(views: rows)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fillEqually
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            card.heightAnchor.constraint(equalToConstant: CGFloat(rows.count * 56)),
        ])
        return card
    }

    private func makeRow(
        title: String,
        description: String,
        control: NSView,
        controlWidth: CGFloat
    ) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        let descriptionLabel = NSTextField(labelWithString: description)
        primaryLabels.append(titleLabel)
        secondaryLabels.append(descriptionLabel)

        let labels = NSStackView(views: [titleLabel, descriptionLabel])
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labels)
        row.addSubview(control)

        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 18),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -18),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.widthAnchor.constraint(equalToConstant: controlWidth),
            control.heightAnchor.constraint(equalToConstant: 28),
        ])
        return row
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
    private let icon = NSImageView()
    private let label: NSTextField

    init(title: String, symbolName: String) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.panelAccentBackground.cgColor
        icon.contentTintColor = AppTheme.panelAccentIcon
        label.textColor = AppTheme.panelAccentIcon
        label.font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 550)
    }
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
