import AppKit

@MainActor
final class PanelViewController: NSViewController {
    enum Role {
        case left
        case right
    }

    var onTogglePanel: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private let role: Role
    private weak var trackingRoot: PanelTrackingView?
    private weak var leftHeader: LeftSidebarHeaderView?
    private weak var brandView: SidebarBrandView?
    private weak var sectionHeader: SidebarSectionHeaderView?
    private weak var rightHeader: RightPanelHeaderView?
    private weak var messageLabel: NSTextField?

    init(role: Role) {
        self.role = role
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let rootView = PanelTrackingView()
        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        rootView.setAccessibilityRole(.group)
        rootView.setAccessibilityLabel(role == .left ? "Tasks" : "Inspector")
        rootView.onHoverChanged = { [weak self] hovering in
            self?.onHoverChanged?(hovering)
        }
        trackingRoot = rootView
        view = rootView

        switch role {
        case .left:
            installLeftPanel()
        case .right:
            installRightPanel()
        }
    }

    func setToggleActive(_ active: Bool) {
        leftHeader?.setPanelActive(active)
        rightHeader?.setPanelActive(active)
    }

    func setFullScreen(_ fullScreen: Bool) {
        leftHeader?.setFullScreen(fullScreen)
    }

    func applyTheme() {
        view.layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        leftHeader?.applyTheme()
        brandView?.applyTheme()
        sectionHeader?.applyTheme()
        rightHeader?.applyTheme()
        messageLabel?.font = AppTheme.font(ofSize: AppTheme.typography.body)
        messageLabel?.textColor = AppTheme.tertiaryText
    }

    private func installLeftPanel() {
        let topHeader = LeftSidebarHeaderView()
        let brand = SidebarBrandView()
        let sectionHeader = SidebarSectionHeaderView(title: "TASKS")
        let messageLabel = makeMessageLabel("No tasks yet.")
        topHeader.onToggle = { [weak self] in self?.onTogglePanel?() }

        topHeader.translatesAutoresizingMaskIntoConstraints = false
        brand.translatesAutoresizingMaskIntoConstraints = false
        sectionHeader.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topHeader)
        view.addSubview(brand)
        view.addSubview(sectionHeader)
        view.addSubview(messageLabel)

        leftHeader = topHeader
        brandView = brand
        self.sectionHeader = sectionHeader
        self.messageLabel = messageLabel

        NSLayoutConstraint.activate([
            topHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topHeader.topAnchor.constraint(equalTo: view.topAnchor),
            topHeader.heightAnchor.constraint(equalToConstant: AppTheme.workspaceHeaderHeight),

            brand.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: AppTheme.panelContentInset),
            brand.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -AppTheme.panelContentInset),
            brand.topAnchor.constraint(equalTo: topHeader.bottomAnchor, constant: 14),

            sectionHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sectionHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sectionHeader.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 16),
            sectionHeader.heightAnchor.constraint(equalToConstant: AppTheme.paneHeaderHeight),

            messageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: AppTheme.panelContentInset),
            messageLabel.topAnchor.constraint(equalTo: sectionHeader.bottomAnchor, constant: 16),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -AppTheme.panelContentInset),
        ])
    }

    private func installRightPanel() {
        let header = RightPanelHeaderView()
        let messageLabel = makeMessageLabel("Nothing here yet.")
        header.onToggle = { [weak self] in self?.onTogglePanel?() }

        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(messageLabel)

        rightHeader = header
        self.messageLabel = messageLabel

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.heightAnchor.constraint(equalToConstant: AppTheme.mainHeaderHeight),

            messageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            messageLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -14),
        ])
    }

    private func makeMessageLabel(_ message: String) -> NSTextField {
        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = AppTheme.font(ofSize: AppTheme.typography.body)
        label.textColor = AppTheme.tertiaryText
        return label
    }
}

@MainActor
private final class PanelTrackingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

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
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}

@MainActor
private final class LeftSidebarHeaderView: NSView {
    var onToggle: (() -> Void)?

    private let toggle = PanelToggleButton(
        symbolName: "sidebar.left",
        accessibilityLabel: "Toggle tasks"
    )
    private var leadingConstraint: NSLayoutConstraint!
    private var centerYConstraint: NSLayoutConstraint!

    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(toggle)
        leadingConstraint = toggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 82)
        centerYConstraint = toggle.centerYAnchor.constraint(
            equalTo: centerYAnchor,
            constant: 1
        )
        NSLayoutConstraint.activate([
            leadingConstraint,
            centerYConstraint,
        ])
        toggle.target = self
        toggle.action = #selector(togglePanel)
        toggle.toolTip = "Toggle tasks (⌘B)"
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func setPanelActive(_ active: Bool) {
        toggle.panelVisible = active
    }

    func setFullScreen(_ fullScreen: Bool) {
        leadingConstraint.constant = fullScreen ? 12 : 82
    }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        toggle.applyTheme()
    }

    @objc private func togglePanel() {
        onToggle?()
    }
}

@MainActor
private final class SidebarBrandView: NSView {
    private let logo = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "Piñata")

    override var mouseDownCanMoveWindow: Bool { true }

    init() {
        super.init(frame: .zero)

        logo.image = NSImage(named: "BrandLogo")
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(logo)
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            logo.leadingAnchor.constraint(equalTo: leadingAnchor),
            logo.topAnchor.constraint(equalTo: topAnchor),
            logo.bottomAnchor.constraint(equalTo: bottomAnchor),
            logo.widthAnchor.constraint(equalToConstant: 34),
            logo.heightAnchor.constraint(equalToConstant: 34),

            nameLabel.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            nameLabel.centerYAnchor.constraint(equalTo: logo.centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Piñata")
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        nameLabel.font = AppTheme.font(ofSize: AppTheme.typography.title, weight: 700)
        nameLabel.textColor = AppTheme.primaryText.withAlphaComponent(0.86)
    }
}

@MainActor
private final class SidebarSectionHeaderView: NSView {
    private let titleLabel: NSTextField

    init(title: String) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.usesSingleLineMode = true
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: AppTheme.panelContentInset),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.label, weight: 600)
        titleLabel.textColor = AppTheme.tertiaryText
    }
}

@MainActor
private final class RightPanelHeaderView: NSView {
    var onToggle: (() -> Void)?

    private let filesButton = PanelTabButton(title: "Files", selected: true)
    private let reviewButton = PanelTabButton(title: "Review")
    private let pullRequestButton = PanelTabButton(title: "PR")
    private let closeButton = PanelToggleButton(
        symbolName: "sidebar.right",
        accessibilityLabel: "Toggle inspector"
    )

    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        reviewButton.isEnabled = false
        pullRequestButton.isEnabled = false

        let tabs = NSStackView(views: [filesButton, reviewButton, pullRequestButton])
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.orientation = .horizontal
        tabs.alignment = .centerY
        tabs.spacing = 2
        addSubview(tabs)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            tabs.centerYAnchor.constraint(equalTo: centerYAnchor),
            tabs.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        closeButton.target = self
        closeButton.action = #selector(togglePanel)
        closeButton.toolTip = "Toggle inspector (⌘L)"
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func setPanelActive(_ active: Bool) {
        closeButton.panelVisible = active
    }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        filesButton.applyTheme()
        reviewButton.applyTheme()
        pullRequestButton.applyTheme()
        closeButton.applyTheme()
    }

    @objc private func togglePanel() {
        onToggle?()
    }
}

@MainActor
private final class PanelTabButton: NSButton {
    private let selected: Bool

    init(title: String, selected: Bool = false) {
        self.selected = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        isBordered = false
        bezelStyle = .regularSquare
        self.title = title
        focusRingType = .none
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 46),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        contentTintColor = selected ? AppTheme.primaryText : AppTheme.tertiaryText
        layer?.backgroundColor = selected ? AppTheme.controlSelection.cgColor : NSColor.clear.cgColor
        font = AppTheme.font(ofSize: AppTheme.typography.label, weight: selected ? 600 : 500)
    }
}
