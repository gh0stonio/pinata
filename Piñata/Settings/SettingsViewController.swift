import AppKit

@MainActor
final class SettingsViewController: NSViewController {
    var onChange: ((UserSettings) -> Bool)?

    private var settings: UserSettings
    private let rail = NSView()
    private let railSeparator = NSView()
    private let content = NSView()
    private var inputFocusMonitor: Any?
    private var navigationGroupViews: [SettingsNavigationGroupView] = []
    private var selectedPageIndex = 0
    private let themeControl = FlatChoiceControl(labels: ["dark", "light"])
    private let accentControl = AccentChoiceControl()
    private let intensityControl = FlatChoiceControl(labels: ["transparent", "balanced", "vibrant"])
    private let appFontControl = FlatChoiceControl(labels: ["small", "default", "large"])
    private let terminalFontControl = FontStepperControl()
    private let fileIconColorControl = FlatChoiceControl(labels: ["colored", "monochrome"])
    private lazy var appearanceContent = AppearanceSettingsContentView(
        themeControl: themeControl,
        accentControl: accentControl,
        intensityControl: intensityControl,
        fileIconColorControl: fileIconColorControl,
        appFontControl: appFontControl,
        terminalFontControl: terminalFontControl
    )
    private let gitContent = RepositorySettingsView()
    private let connectionsContent = ConnectionsSettingsView()
    private lazy var navigationGroups = [
        SettingsNavigationGroup(
            title: "PERSONAL",
            pages: [
                SettingsPageItem(
                    title: "Appearance",
                    image: NSImage(
                        systemSymbolName: "sun.max",
                        accessibilityDescription: nil
                    ) ?? NSImage(),
                    content: appearanceContent
                ),
            ]
        ),
        SettingsNavigationGroup(
            title: "CODING",
            pages: [
                SettingsPageItem(
                    title: "Git",
                    image: GitPullRequestIcon.image,
                    content: gitContent
                ),
                SettingsPageItem(
                    title: "Connections",
                    image: NSImage(
                        systemSymbolName: "network",
                        accessibilityDescription: nil
                    ) ?? NSImage(),
                    content: connectionsContent
                ),
            ]
        ),
    ]
    private var pages: [SettingsPageItem] { navigationGroups.flatMap(\.pages) }

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

        for panel in [rail, railSeparator, content] {
            panel.translatesAutoresizingMaskIntoConstraints = false
            panel.wantsLayer = true
            root.addSubview(panel)
        }
        installRail()
        installContent()
        selectCurrentValues()
        applyTheme()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard inputFocusMonitor == nil else { return }
        inputFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            self?.dismissInputFocusIfNeeded(for: event)
            return event
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let inputFocusMonitor {
            NSEvent.removeMonitor(inputFocusMonitor)
            self.inputFocusMonitor = nil
        }
    }

    func applyTheme() {
        view.layer?.backgroundColor = AppTheme.background.cgColor
        rail.layer?.backgroundColor = AppTheme.background.cgColor
        railSeparator.layer?.backgroundColor = AppTheme.border.cgColor
        content.layer?.backgroundColor = AppTheme.background.cgColor
        navigationGroupViews.forEach { $0.applyTheme() }
        pages.forEach { $0.content.applyTheme() }
    }

    private func installRail() {
        let pageItems = pages
        for (index, page) in pageItems.enumerated() {
            page.row.isSelected = index == selectedPageIndex
            page.row.onSelect = { [weak self] in
                self?.selectPage(at: index)
                self?.pages[index].row.focus()
            }
            page.row.onMove = { [weak self] direction in
                self?.moveSelection(from: index, by: direction)
            }
        }
        navigationGroupViews = navigationGroups.map {
            SettingsNavigationGroupView(title: $0.title, rows: $0.pages.map(\.row))
        }
        let navigationStack = NSStackView(views: navigationGroupViews)
        navigationStack.translatesAutoresizingMaskIntoConstraints = false
        navigationStack.orientation = .vertical
        navigationStack.alignment = .leading
        navigationStack.spacing = SettingsLayout.navigationSectionGap
        rail.addSubview(navigationStack)

        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            rail.topAnchor.constraint(equalTo: view.topAnchor),
            rail.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            rail.widthAnchor.constraint(equalToConstant: AppTheme.settingsRailWidth),
            railSeparator.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            railSeparator.topAnchor.constraint(equalTo: rail.topAnchor),
            railSeparator.bottomAnchor.constraint(equalTo: rail.bottomAnchor),
            railSeparator.widthAnchor.constraint(equalToConstant: SettingsLayout.dividerThickness),
            navigationStack.leadingAnchor.constraint(
                equalTo: rail.leadingAnchor,
                constant: AppTheme.workspaceContentInset
            ),
            navigationStack.trailingAnchor.constraint(
                equalTo: rail.trailingAnchor,
                constant: -AppTheme.workspaceContentInset
            ),
            navigationStack.topAnchor.constraint(
                equalTo: rail.topAnchor,
                constant: AppTheme.workspaceContentInset
            ),
        ])
        navigationGroupViews.forEach {
            $0.widthAnchor.constraint(equalTo: navigationStack.widthAnchor).isActive = true
        }
    }

    private func installContent() {
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: railSeparator.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        for (index, page) in pages.enumerated() {
            let pageView = page.content.settingsView
            pageView.translatesAutoresizingMaskIntoConstraints = false
            pageView.isHidden = index != selectedPageIndex
            content.addSubview(pageView)
            NSLayoutConstraint.activate([
                pageView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                pageView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                pageView.topAnchor.constraint(equalTo: content.topAnchor),
                pageView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }

        themeControl.onChange = { [weak self] _ in self?.settingChanged() }
        intensityControl.onChange = { [weak self] _ in self?.settingChanged() }
        appFontControl.onChange = { [weak self] _ in self?.settingChanged() }
        terminalFontControl.onChange = { [weak self] _ in self?.settingChanged() }
        accentControl.onChange = { [weak self] _ in self?.settingChanged() }
        fileIconColorControl.onChange = { [weak self] _ in self?.settingChanged() }
    }

    private func selectPage(at index: Int) {
        let pageItems = pages
        guard pageItems.indices.contains(index) else { return }
        if pageItems.indices.contains(selectedPageIndex), selectedPageIndex != index {
            pageItems[selectedPageIndex].content.didDeselect()
        }
        selectedPageIndex = index
        for (pageIndex, page) in pageItems.enumerated() {
            page.row.isSelected = pageIndex == index
            page.content.settingsView.isHidden = pageIndex != index
        }
        view.layoutSubtreeIfNeeded()
        pageItems[index].content.scrollToTop()
    }

    private func selectCurrentValues() {
        themeControl.selectedIndex = ThemePreference.allCases.firstIndex(of: settings.theme) ?? 0
        accentControl.selectedIndex = AccentPreference.allCases.firstIndex(of: settings.accent) ?? 0
        intensityControl.selectedIndex = AccentIntensity.allCases.firstIndex(of: settings.accentIntensity) ?? 0
        appFontControl.selectedIndex = AppFontSize.allCases.firstIndex(of: settings.appFontSize) ?? 0
        terminalFontControl.selectedIndex = TerminalFontSize.allCases.firstIndex(of: settings.terminalFontSize) ?? 0
        fileIconColorControl.selectedIndex = FileIconColorPreference.allCases.firstIndex(
            of: settings.fileIconColor
        ) ?? 0
    }

    private func dismissInputFocusIfNeeded(for event: NSEvent) {
        guard let window = view.window, event.window === window else { return }
        let location = view.convert(event.locationInWindow, from: nil)
        guard view.bounds.contains(location) else { return }

        var hitView = view.hitTest(location)
        while let currentView = hitView {
            if currentView is SettingsTextField { return }
            hitView = currentView.superview
        }
        window.makeFirstResponder(nil)
    }

    func focusInitialSection() {
        pages.first?.row.focus()
    }

    private func moveSelection(from index: Int, by direction: Int) {
        let pageItems = pages
        guard !pageItems.isEmpty else { return }
        let nextIndex = min(max(index + direction, 0), pageItems.count - 1)
        selectPage(at: nextIndex)
        pageItems[nextIndex].row.focus()
    }

    private func settingChanged() {
        let next = UserSettings(
            theme: ThemePreference.allCases[themeControl.selectedIndex],
            accent: AccentPreference.allCases[accentControl.selectedIndex],
            accentIntensity: AccentIntensity.allCases[intensityControl.selectedIndex],
            appFontSize: AppFontSize.allCases[appFontControl.selectedIndex],
            terminalFontSize: TerminalFontSize.allCases[terminalFontControl.selectedIndex],
            fileIconColor: FileIconColorPreference.allCases[fileIconColorControl.selectedIndex]
        )
        if onChange?(next) == false {
            selectCurrentValues()
        } else {
            settings = next
        }
    }
}

@MainActor
private final class SettingsPageItem {
    let content: any SettingsPageContent
    let row: SettingsNavigationRow

    init(title: String, image: NSImage, content: any SettingsPageContent) {
        self.content = content
        row = SettingsNavigationRow(title: title, image: image)
    }
}

private struct SettingsNavigationGroup {
    let title: String
    let pages: [SettingsPageItem]
}

private final class SettingsNavigationGroupView: NSView, SettingsThemeApplying {
    private let label: NSTextField
    private let rows: [SettingsNavigationRow]

    init(title: String, rows: [SettingsNavigationRow]) {
        label = NSTextField(labelWithString: title)
        self.rows = rows
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [label] + rows)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SettingsLayout.navigationRowGap
        stack.setCustomSpacing(SettingsLayout.navigationLabelGap, after: label)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        rows.forEach {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            $0.heightAnchor.constraint(
                equalToConstant: SettingsLayout.navigationRowHeight
            ).isActive = true
        }
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        SettingsLayout.applySectionLabelStyle(label)
        rows.forEach { $0.applyTheme() }
    }
}

@MainActor
private final class SettingsNavigationRow: AppHoverView {
    var onSelect: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var isSelected = true {
        didSet { applyTheme() }
    }

    private let icon = NSImageView()
    private let label: NSTextField
    private let button = SettingsNavigationButton(frame: .zero)

    init(title: String, image: NSImage) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = SettingsLayout.navigationCornerRadius

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = image
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = ""
        button.target = self
        button.action = #selector(selectRow)
        button.onMove = { [weak self] direction in self?.onMove?(direction) }
        button.setAccessibilityLabel(title)
        addSubview(icon)
        addSubview(label)
        addSubview(button)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SettingsLayout.navigationItemGap
            ),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: SettingsLayout.navigationIconSize),
            icon.heightAnchor.constraint(equalToConstant: SettingsLayout.navigationIconSize),
            label.leadingAnchor.constraint(
                equalTo: icon.trailingAnchor,
                constant: SettingsLayout.navigationItemGap
            ),
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
        let appearance = AppTheme.buttonAppearance(
            role: isSelected ? .accent : .naked,
            hovered: isHovering
        )
        layer?.backgroundColor = appearance.background.cgColor
        icon.contentTintColor = appearance.foreground
        label.textColor = appearance.foreground
        label.font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 550)
    }

    func focus() {
        window?.makeFirstResponder(button)
    }

    override func hoverStateDidChange() {
        applyTheme()
    }

    @objc private func selectRow() {
        onSelect?()
    }
}

@MainActor
private final class SettingsNavigationButton: AppButton {
    var onMove: ((Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        role = .hitTarget
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126:
            onMove?(-1)
        case 125:
            onMove?(1)
        default:
            super.keyDown(with: event)
        }
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
private final class FlatChoiceControl: NSView, SettingsThemeApplying {
    var onChange: ((Int) -> Void)?
    var selectedIndex = 0 {
        didSet { applyTheme() }
    }

    private let buttons: [FlatChoiceButton]

    init(labels: [String]) {
        buttons = labels.enumerated().map { FlatChoiceButton(title: $0.element, index: $0.offset) }
        super.init(frame: .zero)
        SettingsLayout.applyControlSurface(self, clipsContents: true)

        let stack = NSStackView(views: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .height
        stack.spacing = 0
        stack.distribution = .fillProportionally
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsLayout.choiceInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsLayout.choiceInset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: SettingsLayout.choiceInset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -SettingsLayout.choiceInset),
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
        SettingsLayout.applyControlSurface(self, clipsContents: true)
        for button in buttons {
            button.isVisuallySelected = button.tag == selectedIndex
        }
    }

    @objc private func choiceSelected(_ sender: NSButton) {
        selectedIndex = sender.tag
        onChange?(selectedIndex)
    }
}

@MainActor
private final class FlatChoiceButton: AppButton {
    init(title: String, index: Int) {
        super.init(frame: .zero)
        role = .segmented
        self.title = title
        tag = index
        layer?.cornerRadius = SettingsLayout.choiceCornerRadius
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(
            width: size.width + SettingsLayout.choiceHorizontalPadding,
            height: size.height
        )
    }

    override func applyTheme() {
        super.applyTheme()
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: AppTheme.font(ofSize: AppTheme.typography.settingsBody, weight: 600),
                .foregroundColor: contentTintColor ?? AppTheme.secondaryText,
            ]
        )
        setAccessibilityValue(isVisuallySelected)
    }
}

@MainActor
private final class AccentChoiceControl: NSView, SettingsThemeApplying {
    static var requiredWidth: CGFloat {
        let count = CGFloat(AccentPreference.allCases.count)
        return count * SettingsLayout.colorChoiceDiameter
            + max(0, count - 1) * SettingsLayout.colorChoiceGap
    }

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
        stack.spacing = SettingsLayout.colorChoiceGap
        stack.distribution = .fillEqually
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
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
            button.isVisuallySelected = button.tag == selectedIndex
        }
    }

    @objc private func choiceSelected(_ sender: NSButton) {
        selectedIndex = sender.tag
        onChange?(selectedIndex)
    }
}

@MainActor
private final class AccentChoiceButton: AppButton {
    private let accent: AccentPreference

    init(accent: AccentPreference, index: Int) {
        self.accent = accent
        super.init(frame: .zero)
        role = .swatch(AppTheme.accentColor(for: accent))
        tag = index
        layer?.cornerRadius = SettingsLayout.colorChoiceDiameter / 2
        setAccessibilityLabel(accent.rawValue.capitalized)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: SettingsLayout.colorChoiceDiameter),
            heightAnchor.constraint(equalToConstant: SettingsLayout.colorChoiceDiameter),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func applyTheme() {
        applyAppearance(role: .swatch(AppTheme.accentColor(for: accent)))
        attributedTitle = NSAttributedString(
            string: isVisuallySelected ? "✓" : "",
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: SettingsLayout.accentCheckmarkSize,
                    weight: .bold
                ),
                .foregroundColor: contentTintColor ?? AppTheme.accentForegroundColor(for: accent),
            ]
        )
        setAccessibilityValue(isVisuallySelected)
    }
}

@MainActor
private final class FontStepperControl: NSView, SettingsThemeApplying {
    var onChange: ((Int) -> Void)?
    var selectedIndex = 0 {
        didSet { applyTheme() }
    }

    private let decreaseButton = AppButton(role: .naked)
    private let valueLabel = NSTextField(labelWithString: "")
    private let increaseButton = AppButton(role: .naked)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        SettingsLayout.applyControlSurface(self, clipsContents: true)
        decreaseButton.title = "−"
        increaseButton.title = "+"
        [decreaseButton, valueLabel, increaseButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        decreaseButton.target = self
        decreaseButton.action = #selector(decrease)
        increaseButton.target = self
        increaseButton.action = #selector(increase)
        decreaseButton.setAccessibilityLabel("Decrease terminal font size")
        increaseButton.setAccessibilityLabel("Increase terminal font size")
        valueLabel.setAccessibilityLabel("Terminal font size")
        NSLayoutConstraint.activate([
            decreaseButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            decreaseButton.topAnchor.constraint(equalTo: topAnchor),
            decreaseButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            decreaseButton.widthAnchor.constraint(
                equalToConstant: SettingsLayout.stepperButtonWidth
            ),
            valueLabel.leadingAnchor.constraint(equalTo: decreaseButton.trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            increaseButton.leadingAnchor.constraint(equalTo: valueLabel.trailingAnchor),
            increaseButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            increaseButton.topAnchor.constraint(equalTo: topAnchor),
            increaseButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            increaseButton.widthAnchor.constraint(
                equalToConstant: SettingsLayout.stepperButtonWidth
            ),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        SettingsLayout.applyControlSurface(self, clipsContents: true)
        let font = AppTheme.font(ofSize: AppTheme.typography.settingsBody, weight: 600)
        valueLabel.stringValue = "\(TerminalFontSize.allCases[selectedIndex].points.formatted(.number.precision(.fractionLength(0))))px"
        valueLabel.textColor = AppTheme.primaryText
        valueLabel.font = font
        valueLabel.alignment = .center
        valueLabel.setAccessibilityValue(valueLabel.stringValue)
        for button in [decreaseButton, increaseButton] {
            button.font = font
        }
        decreaseButton.isEnabled = selectedIndex > 0
        increaseButton.isEnabled = selectedIndex < TerminalFontSize.allCases.count - 1
    }

    @objc private func decrease() {
        guard selectedIndex > 0 else { return }
        selectedIndex -= 1
        onChange?(selectedIndex)
    }

    @objc private func increase() {
        guard selectedIndex < TerminalFontSize.allCases.count - 1 else { return }
        selectedIndex += 1
        onChange?(selectedIndex)
    }
}

@MainActor
private final class AppearanceSettingsContentView: NSView, SettingsPageContent {
    private let page = SettingsSplitPageView()

    init(
        themeControl: FlatChoiceControl,
        accentControl: AccentChoiceControl,
        intensityControl: FlatChoiceControl,
        fileIconColorControl: FlatChoiceControl,
        appFontControl: FlatChoiceControl,
        terminalFontControl: FontStepperControl
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        installLayout(
            themeControl: themeControl,
            accentControl: accentControl,
            intensityControl: intensityControl,
            fileIconColorControl: fileIconColorControl,
            appFontControl: appFontControl,
            terminalFontControl: terminalFontControl
        )
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
        layer?.backgroundColor = AppTheme.background.cgColor
        page.applyTheme()
    }

    private func installLayout(
        themeControl: FlatChoiceControl,
        accentControl: AccentChoiceControl,
        intensityControl: FlatChoiceControl,
        fileIconColorControl: FlatChoiceControl,
        appFontControl: FlatChoiceControl,
        terminalFontControl: FontStepperControl
    ) {
        addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: leadingAnchor),
            page.trailingAnchor.constraint(equalTo: trailingAnchor),
            page.topAnchor.constraint(equalTo: topAnchor),
            page.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let themeRows = [
            SettingsRowView(
                title: "Color theme",
                description: "Piñata dark, or a matched light variant",
                control: themeControl,
                controlWidth: SettingsLayout.themeControlWidth
            ),
            SettingsRowView(
                title: "Accent color",
                description: "Highlights, active tabs and primary actions",
                control: accentControl,
                controlWidth: AccentChoiceControl.requiredWidth
            ),
            SettingsRowView(
                title: "Accent intensity",
                description: "How loud accent surfaces feel",
                control: intensityControl,
                controlWidth: SettingsLayout.intensityControlWidth
            ),
            SettingsRowView(
                title: "File icons",
                description: "Colored by type, or a neutral monochrome style",
                control: fileIconColorControl,
                controlWidth: SettingsLayout.fileIconColorControlWidth
            ),
        ]
        let textRows = [
            SettingsRowView(
                title: "App font size",
                description: "Side panels, settings and task dialogs",
                control: appFontControl,
                controlWidth: SettingsLayout.appFontControlWidth
            ),
            SettingsRowView(
                title: "Terminal font size",
                description: "Embedded terminal text only",
                control: terminalFontControl,
                controlWidth: SettingsLayout.terminalFontControlWidth
            ),
        ]
        page.addSection(
            title: "Theme",
            detail: "Colour of the chrome and how strongly the accent is used.",
            content: settingsRowStack(themeRows)
        )
        page.addSection(
            title: "Text",
            detail: "Type sizes for the app chrome and the embedded terminal.",
            content: settingsRowStack(textRows)
        )
    }
}
