import AppKit

@MainActor
enum SettingsLayout {
    static let contentTop: CGFloat = 34
    static let contentHorizontalMargin: CGFloat = 40
    static let contentMinimumWidth: CGFloat = 660
    static let contentMaximumWidth: CGFloat = 800
    static let titleToSectionGap: CGFloat = 18
    static let sectionContentGap: CGFloat = 12
    static let sectionGap: CGFloat = 24
    static let blockHorizontalPadding: CGFloat = 24
    static let blockVerticalPadding: CGFloat = 20
    static let rowHeight: CGFloat = 64
    static let expandedRowHeight: CGFloat = 92
    static let detailRowHeight: CGFloat = 70
    static let detailHeaderHeight: CGFloat = 80
    static let controlHeight: CGFloat = 32

    static func applySectionLabelStyle(_ label: NSTextField) {
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
}

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class SettingsPageView: NSView {
    private let scrollView = NSScrollView()
    private let document = SettingsDocumentView()
    private let contentStack = NSStackView()
    private let titleLabel: NSTextField
    private var sections: [SettingsSectionView] = []

    init(title: String) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        installLayout()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    @discardableResult
    func addSection(
        title: String,
        content: NSView,
        action: NSView? = nil
    ) -> SettingsSectionView {
        let section = SettingsSectionView(title: title, content: content, action: action)
        sections.append(section)
        contentStack.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        contentStack.setCustomSpacing(SettingsLayout.sectionGap, after: section)
        return section
    }

    func scrollToTop() {
        layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func applyTheme() {
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsDisplay, weight: 550)
        sections.forEach { $0.applyTheme() }
    }

    private func installLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        document.addSubview(contentStack)
        contentStack.addArrangedSubview(titleLabel)
        contentStack.setCustomSpacing(SettingsLayout.titleToSectionGap, after: titleLabel)

        let responsiveWidth = contentStack.widthAnchor.constraint(
            equalTo: document.widthAnchor,
            constant: -(SettingsLayout.contentHorizontalMargin * 2)
        )
        responsiveWidth.priority = .defaultLow
        let preferredWidth = contentStack.widthAnchor.constraint(
            equalToConstant: SettingsLayout.contentMaximumWidth
        )
        preferredWidth.priority = .defaultHigh
        let minimumWidth = contentStack.widthAnchor.constraint(
            greaterThanOrEqualToConstant: SettingsLayout.contentMinimumWidth
        )
        minimumWidth.priority = .init(rawValue: 749)
        let viewportHeight = document.heightAnchor.constraint(
            equalTo: scrollView.contentView.heightAnchor
        )
        viewportHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            viewportHeight,

            contentStack.topAnchor.constraint(equalTo: document.topAnchor, constant: SettingsLayout.contentTop),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
            contentStack.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            responsiveWidth,
            preferredWidth,
            minimumWidth,
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: SettingsLayout.contentMaximumWidth),
            contentStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: document.leadingAnchor,
                constant: SettingsLayout.contentHorizontalMargin
            ),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: document.trailingAnchor,
                constant: -SettingsLayout.contentHorizontalMargin
            ),
            titleLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])
    }
}

@MainActor
final class SettingsSheetController: NSWindowController, NSWindowDelegate {
    var onDismiss: (() -> Void)?

    private let root = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let separator = NSBox()
    private let scrollView = NSScrollView()
    private let scrollDocument = SettingsDocumentView()
    private var currentContent: NSView?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 700),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.minSize = NSSize(width: 680, height: 480)
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = root
        installLayout()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func setContent(_ content: NSView, title: String) {
        currentContent?.removeFromSuperview()
        currentContent = content
        titleLabel.stringValue = title
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollDocument.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scrollDocument.leadingAnchor, constant: 32),
            content.trailingAnchor.constraint(equalTo: scrollDocument.trailingAnchor, constant: -32),
            content.topAnchor.constraint(equalTo: scrollDocument.topAnchor, constant: 24),
            content.bottomAnchor.constraint(lessThanOrEqualTo: scrollDocument.bottomAnchor),
        ])
        root.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        applyTheme()
    }

    func present(from parent: NSWindow) {
        guard let panel = window, panel.sheetParent == nil else { return }
        parent.beginSheet(panel)
    }

    func dismiss() {
        guard let panel = window else { return }
        panel.sheetParent?.endSheet(panel)
    }

    func applyTheme() {
        root.layer?.backgroundColor = AppTheme.background.cgColor
        scrollView.backgroundColor = AppTheme.chromeBackground
        scrollDocument.layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.title, weight: 650)
        closeButton.contentTintColor = AppTheme.secondaryText
        (currentContent as? SettingsThemeApplying)?.applyTheme()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onDismiss?()
        return false
    }

    private func installLayout() {
        root.wantsLayer = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollDocument.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.isBordered = false
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.target = self
        closeButton.action = #selector(requestClose)
        closeButton.setAccessibilityLabel("Close")
        separator.boxType = .separator
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.verticalScrollElasticity = .none
        scrollDocument.wantsLayer = true
        scrollView.documentView = scrollDocument

        [titleLabel, closeButton, separator, scrollView].forEach(root.addSubview)
        let viewportHeight = scrollDocument.heightAnchor.constraint(
            equalTo: scrollView.contentView.heightAnchor
        )
        viewportHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -16),

            closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            closeButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),

            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: root.topAnchor, constant: 68),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            scrollDocument.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            scrollDocument.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            viewportHeight,

        ])
    }

    @objc private func requestClose() {
        onDismiss?()
    }
}

@MainActor
final class SettingsSectionView: NSView {
    private let titleLabel: NSTextField
    private let content: NSView
    private let action: NSView?

    init(title: String, content: NSView, action: NSView? = nil) {
        titleLabel = NSTextField(labelWithString: title.uppercased())
        self.content = content
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        installLayout()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        SettingsLayout.applySectionLabelStyle(titleLabel)
        (content as? SettingsThemeApplying)?.applyTheme()
    }

    private func installLayout() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(content)
        if let action {
            action.translatesAutoresizingMaskIntoConstraints = false
            addSubview(action)
        }

        var constraints = [
            heightAnchor.constraint(greaterThanOrEqualToConstant: 1),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(
                equalTo: titleLabel.bottomAnchor,
                constant: SettingsLayout.sectionContentGap
            ),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        if let action {
            constraints += [
                action.trailingAnchor.constraint(equalTo: trailingAnchor),
                action.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -12),
            ]
        } else {
            constraints.append(titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }
}

@MainActor
protocol SettingsThemeApplying: AnyObject {
    func applyTheme()
}

@MainActor
private final class SettingsCardDivider: NSView, SettingsThemeApplying {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.tertiaryText.withAlphaComponent(0.10).cgColor
    }
}

@MainActor
final class SettingsCardView: NSView, SettingsThemeApplying {
    private let stack = NSStackView()

    init(rows: [NSView] = []) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setRows(rows)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    var rows: [NSView] {
        stack.arrangedSubviews.filter { !($0 is SettingsCardDivider) }
    }

    func setRows(_ rows: [NSView]) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        rows.enumerated().forEach { index, row in
            if index > 0 { addRow(SettingsCardDivider()) }
            addRow(row)
        }
    }

    func addRow(_ row: NSView) {
        row.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        stack.arrangedSubviews.compactMap { $0 as? SettingsThemeApplying }.forEach {
            $0.applyTheme()
        }
    }
}

@MainActor
final class SettingsDangerZoneView: NSView, SettingsThemeApplying {
    var onAction: (() -> Void)?

    private let headingLabel = NSTextField(labelWithString: "Danger Zone")
    private let container = NSView()
    private let titleLabel: NSTextField
    private let descriptionLabel: NSTextField
    private let actionButton: NSButton

    init(title: String, description: String, actionTitle: String) {
        titleLabel = NSTextField(labelWithString: title)
        descriptionLabel = NSTextField(labelWithString: description)
        actionButton = NSButton(title: actionTitle, target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        installLayout()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        let danger = NSColor.systemRed
        headingLabel.textColor = danger
        headingLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 650)
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 650)
        descriptionLabel.textColor = AppTheme.secondaryText
        descriptionLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody)
        container.layer?.borderColor = danger.cgColor
        actionButton.contentTintColor = danger
        actionButton.font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 650)
        actionButton.layer?.backgroundColor = danger.withAlphaComponent(0.14).cgColor
    }

    private func installLayout() {
        [headingLabel, container].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        [titleLabel, descriptionLabel, actionButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }

        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.cornerCurve = .continuous
        container.layer?.borderWidth = 1
        actionButton.wantsLayer = true
        actionButton.layer?.cornerRadius = 10
        actionButton.layer?.cornerCurve = .continuous
        actionButton.isBordered = false
        actionButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        actionButton.imagePosition = .imageLeading
        actionButton.imageHugsTitle = true
        actionButton.target = self
        actionButton.action = #selector(performAction)

        NSLayoutConstraint.activate([
            headingLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            headingLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            headingLabel.topAnchor.constraint(equalTo: topAnchor, constant: 32),

            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: headingLabel.bottomAnchor, constant: 16),
            container.heightAnchor.constraint(equalToConstant: 96),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -24),

            descriptionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            descriptionLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -24),

            actionButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            actionButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 132),
            actionButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @objc private func performAction() {
        onAction?()
    }
}

@MainActor
final class SettingsDetailHeaderView: NSView, SettingsThemeApplying {
    private let titleLabel: NSTextField
    private let subtitleLabel: NSTextField
    private let action: NSView

    init(title: String, subtitle: String, action: NSView) {
        titleLabel = NSTextField(labelWithString: title)
        subtitleLabel = NSTextField(labelWithString: subtitle)
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        [titleLabel, subtitleLabel, action].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SettingsLayout.detailHeaderHeight),
            titleLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SettingsLayout.blockHorizontalPadding
            ),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -16),
            action.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -SettingsLayout.blockHorizontalPadding
            ),
            action.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsDisplay, weight: 550)
        subtitleLabel.textColor = AppTheme.tertiaryText
        subtitleLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody)
    }
}

@MainActor
final class SettingsRowView: NSView, SettingsThemeApplying {
    private let titleLabel: NSTextField
    private let helperLabel: NSTextField
    private let control: NSView

    init(
        title: String,
        description: String,
        control: NSView,
        controlWidth: CGFloat? = nil,
        controlHeight: CGFloat? = SettingsLayout.controlHeight,
        minimumHeight: CGFloat = SettingsLayout.rowHeight,
        allowsVerticalExpansion: Bool = false
    ) {
        titleLabel = NSTextField(labelWithString: title)
        helperLabel = NSTextField(wrappingLabelWithString: description)
        self.control = control
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let labels = NSStackView(views: [titleLabel, helperLabel])
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labels)
        addSubview(control)

        let heightConstraint = allowsVerticalExpansion
            ? heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight)
            : heightAnchor.constraint(equalToConstant: minimumHeight)
        var constraints = [
            heightConstraint,
            labels.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SettingsLayout.blockHorizontalPadding
            ),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.topAnchor.constraint(
                greaterThanOrEqualTo: topAnchor,
                constant: SettingsLayout.blockVerticalPadding / 2
            ),
            labels.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor,
                constant: -(SettingsLayout.blockVerticalPadding / 2)
            ),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),
            control.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -SettingsLayout.blockHorizontalPadding
            ),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            control.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
        ]
        if let controlHeight {
            constraints.append(control.heightAnchor.constraint(equalToConstant: controlHeight))
        }
        if let controlWidth {
            constraints.append(control.widthAnchor.constraint(equalToConstant: controlWidth))
        } else {
            constraints += [
                control.widthAnchor.constraint(lessThanOrEqualToConstant: 430),
                control.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            ]
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        NSLayoutConstraint.activate(constraints)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        titleLabel.textColor = AppTheme.primaryText
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 550)
        helperLabel.textColor = AppTheme.tertiaryText
        helperLabel.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody)
        (control as? SettingsThemeApplying)?.applyTheme()
    }
}

@MainActor
final class SettingsValueLabel: NSTextField, SettingsThemeApplying {
    init(_ value: String) {
        super.init(frame: .zero)
        stringValue = value
        isEditable = false
        isSelectable = true
        isBordered = false
        drawsBackground = false
        isBezeled = false
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        alignment = .right
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        textColor = AppTheme.secondaryText
        font = .monospacedSystemFont(ofSize: AppTheme.typography.settingsBody, weight: .regular)
    }
}

@MainActor
final class SettingsMessageRow: NSView, SettingsThemeApplying {
    private let label: NSTextField

    init(_ message: String) {
        label = NSTextField(wrappingLabelWithString: message)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SettingsLayout.rowHeight),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsLayout.blockHorizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsLayout.blockHorizontalPadding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        label.textColor = AppTheme.tertiaryText
        label.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody)
    }
}

@MainActor
final class SettingsTextField: NSTextField, SettingsThemeApplying {
    private var isEditing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = SettingsTextFieldCell(textCell: "")
        isEditable = true
        isSelectable = true
        isEnabled = true
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.wraps = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        textColor = AppTheme.primaryText
        layer?.backgroundColor = AppTheme.controlBackground.cgColor
        font = .monospacedSystemFont(ofSize: AppTheme.typography.settingsBody, weight: .regular)
        updateBorder()
    }

    override func mouseDown(with event: NSEvent) {
        isEditing = true
        updateBorder()
        super.mouseDown(with: event)
        isEditing = true
        updateBorder()
    }

    override func textShouldBeginEditing(_ textObject: NSText) -> Bool {
        let shouldBegin = super.textShouldBeginEditing(textObject)
        if shouldBegin {
            isEditing = true
            updateBorder()
        }
        return shouldBegin
    }

    override func textShouldEndEditing(_ textObject: NSText) -> Bool {
        let shouldEnd = super.textShouldEndEditing(textObject)
        if shouldEnd {
            isEditing = false
            updateBorder()
        }
        return shouldEnd
    }

    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        isEditing = true
        updateBorder()
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        isEditing = false
        updateBorder()
    }

    private func updateBorder() {
        layer?.borderColor = (isEditing
            ? AppTheme.accent
            : AppTheme.border).cgColor
    }
}

private final class SettingsTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let rect = super.drawingRect(forBounds: rect)
        let height = min(cellSize.height, rect.height)
        return NSRect(
            x: rect.minX + 10,
            y: rect.minY + (rect.height - height) / 2,
            width: max(0, rect.width - 20),
            height: height
        )
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: drawingRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: drawingRect(forBounds: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }
}
