import AppKit

@MainActor
final class WorkspaceHeaderView: NSView {
    var onCreateTab: (() -> Void)?
    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?

    private let tabsStack = NSStackView()
    private let tabsScrollView = NSScrollView()
    private let separator = NSView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var tabTrackingArea: NSTrackingArea?
    private let newTabButton = PanelToggleButton(
        symbolName: "plus",
        accessibilityLabel: "New terminal tab",
        controlSide: AppTheme.workspaceTabHeight,
        symbolPointSize: AppTheme.workspaceNewTabSymbolSize,
        hoverStyle: .foregroundOnly
    )

    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.usesSingleLineMode = true
        tabsScrollView.translatesAutoresizingMaskIntoConstraints = false
        tabsScrollView.drawsBackground = false
        tabsScrollView.borderType = .noBorder
        tabsScrollView.hasHorizontalScroller = false
        tabsScrollView.hasVerticalScroller = false
        tabsScrollView.horizontalScrollElasticity = .automatic
        tabsScrollView.verticalScrollElasticity = .none
        tabsStack.translatesAutoresizingMaskIntoConstraints = false
        tabsStack.orientation = .horizontal
        tabsStack.alignment = .centerY
        tabsStack.spacing = AppTheme.workspaceTabSpacing
        tabsStack.setContentHuggingPriority(.required, for: .horizontal)
        tabsStack.addArrangedSubview(emptyLabel)
        tabsStack.addArrangedSubview(newTabButton)
        tabsScrollView.documentView = tabsStack

        addSubview(tabsScrollView)
        addSubview(separator)

        NSLayoutConstraint.activate([
            tabsScrollView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: AppTheme.workspaceContentInset
            ),
            tabsScrollView.centerYAnchor.constraint(equalTo: centerYAnchor),
            tabsScrollView.heightAnchor.constraint(equalToConstant: AppTheme.workspaceTabHeight),
            tabsScrollView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -AppTheme.workspaceContentInset
            ),
            tabsStack.leadingAnchor.constraint(
                equalTo: tabsScrollView.contentView.leadingAnchor
            ),
            tabsStack.centerYAnchor.constraint(
                equalTo: tabsScrollView.contentView.centerYAnchor
            ),
            tabsStack.heightAnchor.constraint(
                equalTo: tabsScrollView.contentView.heightAnchor
            ),
            tabsStack.widthAnchor.constraint(
                greaterThanOrEqualTo: tabsScrollView.contentView.widthAnchor
            ),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: AppTheme.workspaceDividerThickness),
        ])

        newTabButton.target = self
        newTabButton.action = #selector(createTab)
        newTabButton.toolTip = "New terminal tab (⌘T)"
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func setTabs(_ tabs: [(id: UUID, title: String)], activeID: UUID?) {
        tabsScrollView.isHidden = false
        newTabButton.isHidden = false
        emptyLabel.isHidden = true
        removeTabs()
        for tab in tabs {
            let item = TabButton(
                id: tab.id,
                title: tab.title,
                selected: tab.id == activeID
            )
            item.onSelect = { [weak self] id in
                self?.onSelectTab?(id)
            }
            item.onClose = { [weak self] id in
                self?.onCloseTab?(id)
            }
            tabsStack.insertArrangedSubview(item, at: tabsStack.arrangedSubviews.count - 1)
            if tab.id == activeID {
                DispatchQueue.main.async {
                    item.scrollToVisible(item.bounds)
                }
            }
        }
    }

    func setEmptyScope(_ title: String, allowsCreateTab: Bool = true) {
        removeTabs()
        tabsScrollView.isHidden = false
        newTabButton.isHidden = !allowsCreateTab
        emptyLabel.stringValue = title
        emptyLabel.isHidden = false
    }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.background.cgColor
        separator.layer?.backgroundColor = AppTheme.border.cgColor
        emptyLabel.font = .monospacedSystemFont(
            ofSize: AppTheme.typography.settingsValue,
            weight: .regular
        )
        emptyLabel.textColor = AppTheme.tertiaryText
        tabsStack.arrangedSubviews
            .compactMap { $0 as? TabButton }
            .forEach { $0.applyTheme() }
        newTabButton.applyTheme()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tabTrackingArea { removeTrackingArea(tabTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tabTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        updateHoveredTab(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredTab(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        tabsStack.arrangedSubviews
            .compactMap { $0 as? TabButton }
            .forEach { $0.setPointerState(hovered: false, closeHovered: false) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard tabsScrollView.frame.contains(localPoint) else {
            return super.hitTest(point)
        }
        for tab in tabsStack.arrangedSubviews.reversed() {
            if tab.bounds.contains(tab.convert(localPoint, from: self)) {
                return tab
            }
        }
        return super.hitTest(point)
    }

    @objc private func createTab() {
        onCreateTab?()
    }

    private func removeTabs() {
        tabsStack.arrangedSubviews
            .compactMap { $0 as? TabButton }
            .forEach {
                tabsStack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
    }

    private func updateHoveredTab(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let tabs = tabsStack.arrangedSubviews.compactMap { $0 as? TabButton }
        let hoveredTab = tabs
            .first { tab in
                tabsScrollView.frame.contains(location)
                    && tab.convert(tab.bounds, to: self).contains(location)
            }
        tabs.forEach { tab in
            let hovered = tab === hoveredTab
            tab.setPointerState(
                hovered: hovered,
                closeHovered: hovered && tab.closeHitRect.contains(
                    tab.convert(location, from: self)
                )
            )
        }
    }

}

@MainActor
final class TabButton: AppButton {
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?

    private let tabID: UUID
    private let selected: Bool
    private let terminalIcon = NSImageView()
    private let titleLabel: NSTextField
    private let closeIcon = NSImageView()
    private let closeHoverLayer = CALayer()
    private var closeHovered = false
    private var activationPoint: NSPoint?

    override var usesAutomaticHoverTracking: Bool { false }

    init(id: UUID, title: String, selected: Bool) {
        tabID = id
        self.selected = selected
        titleLabel = NSTextField(labelWithString: title)
        super.init(role: selected ? .accent : .naked)
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = AppTheme.workspaceControlCornerRadius
        target = self
        action = #selector(activate)
        closeHoverLayer.cornerRadius = AppTheme.workspaceTabCloseHoverCornerRadius
        layer?.addSublayer(closeHoverLayer)
        terminalIcon.image = NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(
                pointSize: AppTheme.workspaceTabIconSymbolSize,
                weight: .medium
            )
        )
        terminalIcon.imageScaling = .scaleProportionallyDown
        titleLabel.usesSingleLineMode = true
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeIcon.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close \(title)"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(
                pointSize: AppTheme.workspaceTabCloseSymbolSize,
                weight: .medium
            )
        )
        closeIcon.imageScaling = .scaleProportionallyDown
        [terminalIcon, titleLabel, closeIcon].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        setAccessibilityLabel(title)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Close \(title)") { [weak self] in
                guard let self else { return false }
                onClose?(tabID)
                return true
            },
        ])
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: AppTheme.workspaceTabHeight),
            widthAnchor.constraint(greaterThanOrEqualToConstant: AppTheme.workspaceTabMinimumWidth),
            widthAnchor.constraint(lessThanOrEqualToConstant: AppTheme.workspaceTabMaximumWidth),
            terminalIcon.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: AppTheme.workspaceTabHorizontalInset
            ),
            terminalIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            terminalIcon.widthAnchor.constraint(equalToConstant: AppTheme.workspaceTabIconWidth),
            terminalIcon.heightAnchor.constraint(equalToConstant: AppTheme.workspaceTabIconHeight),
            titleLabel.leadingAnchor.constraint(
                equalTo: terminalIcon.trailingAnchor,
                constant: AppTheme.workspaceTabContentGap
            ),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeIcon.leadingAnchor.constraint(
                equalTo: titleLabel.trailingAnchor,
                constant: AppTheme.workspaceTabAccessoryGap
            ),
            closeIcon.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -AppTheme.workspaceTabCloseInset
            ),
            closeIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeIcon.widthAnchor.constraint(equalToConstant: AppTheme.workspaceTabCloseSymbolSize),
            closeIcon.heightAnchor.constraint(equalToConstant: AppTheme.workspaceTabCloseSymbolSize),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func applyTheme() {
        super.applyTheme()
        let foreground = contentTintColor ?? AppTheme.tertiaryText
        let closeAppearance = AppTheme.buttonAppearance(
            role: selected ? .accentIcon : .icon,
            hovered: closeHovered
        )
        terminalIcon.contentTintColor = foreground
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.body, weight: 600)
        titleLabel.textColor = foreground
        closeIcon.contentTintColor = closeHovered ? closeAppearance.foreground : foreground
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let closeBackground = selected
            ? closeAppearance.background
            : AppTheme.workspaceTabNeutralCloseHoverBackground
        closeHoverLayer.backgroundColor = (closeHovered ? closeBackground : NSColor.clear).cgColor
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        closeHoverLayer.frame = NSRect(
            x: closeIcon.frame.midX - AppTheme.workspaceTabCloseHoverSize / 2,
            y: closeIcon.frame.midY - AppTheme.workspaceTabCloseHoverSize / 2,
            width: AppTheme.workspaceTabCloseHoverSize,
            height: AppTheme.workspaceTabCloseHoverSize
        )
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: AppTheme.workspaceTabHorizontalInset
                + AppTheme.workspaceTabIconWidth
                + AppTheme.workspaceTabContentGap
                + titleLabel.intrinsicContentSize.width
                + AppTheme.workspaceTabAccessoryGap
                + AppTheme.workspaceTabCloseSymbolSize
                + AppTheme.workspaceTabCloseInset,
            height: AppTheme.workspaceTabHeight
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        return self
    }

    var closeHitRect: NSRect {
        NSRect(
            x: closeIcon.frame.midX - AppTheme.workspaceTabCloseHoverSize / 2,
            y: closeIcon.frame.midY - AppTheme.workspaceTabCloseHoverSize / 2,
            width: AppTheme.workspaceTabCloseHoverSize,
            height: AppTheme.workspaceTabCloseHoverSize
        )
    }

    func setPointerState(hovered: Bool, closeHovered: Bool) {
        let closeChanged = self.closeHovered != closeHovered
        self.closeHovered = closeHovered
        let tabHovered = hovered && !selected
        let tabChanged = isHovering != tabHovered
        setHovering(tabHovered)
        if closeChanged, !tabChanged {
            applyTheme()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?(tabID)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        activationPoint = convert(event.locationInWindow, from: nil)
        defer { activationPoint = nil }
        super.mouseDown(with: event)
    }

    func performPointerAction(at point: NSPoint) {
        if closeHitRect.contains(point) {
            onClose?(tabID)
        } else {
            onSelect?(tabID)
        }
    }

    @objc private func activate() {
        guard let activationPoint else {
            onSelect?(tabID)
            return
        }
        performPointerAction(at: activationPoint)
    }
}

@MainActor
final class PanelToggleButton: AppButton {
    enum HoverStyle {
        case background
        case foregroundOnly
    }
    var panelVisible = false {
        didSet { updateAppearance() }
    }
    var normalForegroundColor: NSColor? {
        didSet { updateAppearance() }
    }

    private let controlSide: CGFloat
    private let hoverStyle: HoverStyle

    init(
        symbolName: String,
        accessibilityLabel: String,
        controlSide: CGFloat = AppTheme.panelToggleControlSize,
        symbolPointSize: CGFloat? = nil,
        hoverStyle: HoverStyle = .background
    ) {
        self.controlSide = controlSide
        self.hoverStyle = hoverStyle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = AppTheme.workspaceControlCornerRadius
        image = Self.balancedSymbol(
            named: symbolName,
            accessibilityLabel: accessibilityLabel,
            pointSize: symbolPointSize
        )
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setAccessibilityLabel(accessibilityLabel)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: controlSide),
            heightAnchor.constraint(equalToConstant: controlSide),
        ])
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func applyTheme() {
        updateAppearance()
    }

    private static func balancedSymbol(
        named name: String,
        accessibilityLabel: String,
        pointSize: CGFloat?
    ) -> NSImage? {
        guard let baseImage = NSImage(
            systemSymbolName: name,
            accessibilityDescription: accessibilityLabel
        ) else {
            return nil
        }
        let source = pointSize.flatMap {
            baseImage.withSymbolConfiguration(.init(pointSize: $0, weight: .medium))
        } ?? baseImage
        if pointSize != nil {
            source.isTemplate = true
            return source
        }
        let size = NSSize(
            width: source.size.width,
            height: source.size.height + AppTheme.symbolVerticalAdjustment
        )
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    private func updateAppearance() {
        let role: AppButtonRole = if panelVisible {
            .accent
        } else if hoverStyle == .background {
            .icon
        } else {
            .hitTarget
        }
        let appearance = AppTheme.buttonAppearance(
            role: role,
            hovered: isHovering,
            enabled: isEnabled
        )
        applyAppearance(role: role)
        contentTintColor = if panelVisible || isHovering {
            appearance.foreground
        } else {
            normalForegroundColor ?? appearance.foreground
        }
    }
}
