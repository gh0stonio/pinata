import AppKit

@MainActor
final class WorkspaceHeaderView: NSView {
    var onCreateTab: (() -> Void)?
    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?

    private let tabsStack = NSStackView()
    private let tabsScrollView = NSScrollView()
    private let separator = NSView()
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
        tabsScrollView.documentView = tabsStack

        addSubview(tabsScrollView)
        addSubview(newTabButton)
        addSubview(separator)

        NSLayoutConstraint.activate([
            tabsScrollView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: AppTheme.workspaceContentInset
            ),
            tabsScrollView.centerYAnchor.constraint(equalTo: centerYAnchor),
            tabsScrollView.heightAnchor.constraint(equalToConstant: AppTheme.workspaceTabHeight),
            tabsScrollView.trailingAnchor.constraint(
                equalTo: newTabButton.leadingAnchor,
                constant: -AppTheme.workspaceControlGap
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

            newTabButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newTabButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -AppTheme.workspaceContentInset
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
        tabsStack.arrangedSubviews.forEach {
            tabsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for tab in tabs {
            let item = WorkspaceTabItemView(
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
            tabsStack.addArrangedSubview(item)
            if tab.id == activeID {
                DispatchQueue.main.async {
                    item.scrollToVisible(item.bounds)
                }
            }
        }
    }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.background.cgColor
        separator.layer?.backgroundColor = AppTheme.border.cgColor
        tabsStack.arrangedSubviews
            .compactMap { $0 as? WorkspaceTabItemView }
            .forEach { $0.applyTheme() }
        newTabButton.applyTheme()
    }

    @objc private func createTab() {
        onCreateTab?()
    }

}

@MainActor
private final class WorkspaceTabItemView: NSView {
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?

    private let tabID: UUID
    private let selected: Bool
    private let backgroundLayer = CALayer()
    private let selectButton: WorkspaceTabButton
    private let closeButton: PanelToggleButton

    init(id: UUID, title: String, selected: Bool) {
        tabID = id
        self.selected = selected
        selectButton = WorkspaceTabButton(title: title, selected: selected)
        closeButton = PanelToggleButton(
            symbolName: "xmark",
            accessibilityLabel: "Close \(title)",
            controlSide: AppTheme.workspaceTabCloseControlSize,
            symbolPointSize: AppTheme.workspaceTabCloseSymbolSize,
            hoverStyle: .none
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.insertSublayer(backgroundLayer, at: 0)
        backgroundLayer.cornerRadius = AppTheme.workspaceControlCornerRadius

        addSubview(selectButton)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: AppTheme.workspaceTabHeight),
            selectButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectButton.topAnchor.constraint(equalTo: topAnchor),
            selectButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            closeButton.leadingAnchor.constraint(equalTo: selectButton.trailingAnchor),
            closeButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -AppTheme.workspaceTabCloseInset
            ),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        selectButton.target = self
        selectButton.action = #selector(selectTab)
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.toolTip = "Close \(title)"
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layout() {
        super.layout()
        backgroundLayer.frame = bounds
    }

    func applyTheme() {
        backgroundLayer.backgroundColor =
            (selected ? AppTheme.panelAccentBackground : NSColor.clear).cgColor
        backgroundLayer.borderColor = (
            selected ? AppTheme.panelAccentIcon.withAlphaComponent(0.35) : AppTheme.border
        ).cgColor
        backgroundLayer.borderWidth = selected ? 1 : 0
        selectButton.applyTheme()
        closeButton.normalForegroundColor =
            selected ? AppTheme.panelAccentIcon : AppTheme.tertiaryText
        closeButton.applyTheme()
    }

    @objc private func selectTab() {
        onSelect?(tabID)
    }

    @objc private func closeTab() {
        onClose?(tabID)
    }
}

@MainActor
private final class WorkspaceTabButton: NSButton {
    private let selected: Bool

    init(title: String, selected: Bool) {
        self.selected = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        imageHugsTitle = true
        self.title = title
        focusRingType = .none
        setAccessibilityLabel(title)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: AppTheme.workspaceTabHeight),
            widthAnchor.constraint(greaterThanOrEqualToConstant: AppTheme.workspaceTabMinimumWidth),
            widthAnchor.constraint(lessThanOrEqualToConstant: AppTheme.workspaceTabMaximumWidth),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        let foreground = selected ? AppTheme.panelAccentIcon : AppTheme.tertiaryText
        contentTintColor = foreground
        font = AppTheme.font(ofSize: AppTheme.typography.label, weight: 600)
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: font as Any,
                .foregroundColor: foreground,
            ]
        )
    }
}

@MainActor
final class PanelToggleButton: NSButton {
    enum HoverStyle {
        case background
        case foregroundOnly
        case none
    }
    var panelVisible = false {
        didSet { updateAppearance() }
    }
    var normalForegroundColor: NSColor? {
        didSet { updateAppearance() }
    }

    private var trackingArea: NSTrackingArea?
    private let backgroundLayer = CALayer()
    private let controlSide: CGFloat
    private let hoverStyle: HoverStyle
    private var isHovering = false

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
        backgroundLayer.cornerRadius = AppTheme.workspaceControlCornerRadius
        layer?.insertSublayer(backgroundLayer, at: 0)
        isBordered = false
        bezelStyle = .regularSquare
        image = Self.balancedSymbol(
            named: symbolName,
            accessibilityLabel: accessibilityLabel,
            pointSize: symbolPointSize
        )
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        setAccessibilityLabel(accessibilityLabel)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: controlSide),
            heightAnchor.constraint(equalToConstant: controlSide),
        ])
        updateAppearance()
    }

    override func layout() {
        super.layout()
        let side = min(controlSide, bounds.width, bounds.height)
        backgroundLayer.frame = CGRect(
            x: (bounds.width - side) / 2,
            y: (bounds.height - side) / 2,
            width: side,
            height: side
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateAppearance()
    }

    func applyTheme() {
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
        contentTintColor = if panelVisible {
            AppTheme.panelAccentIcon
        } else if isHovering && hoverStyle != .none {
            hoverStyle == .foregroundOnly
                ? AppTheme.primaryText
                : AppTheme.panelToggleHoverText
        } else {
            normalForegroundColor ?? AppTheme.tertiaryText
        }
        backgroundLayer.backgroundColor = if panelVisible {
            AppTheme.panelAccentBackground.cgColor
        } else if isHovering && hoverStyle == .background {
            AppTheme.panelToggleHoverBackground.cgColor
        } else {
            NSColor.clear.cgColor
        }
    }
}
