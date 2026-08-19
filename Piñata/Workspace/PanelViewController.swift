import AppKit

@MainActor
final class PanelViewController: NSViewController {
    var onTogglePanel: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private weak var trackingRoot: PanelTrackingView?
    private weak var leftHeader: LeftSidebarHeaderView?
    private weak var brandView: SidebarBrandView?
    private weak var sectionHeader: SidebarSectionHeaderView?
    private weak var messageLabel: NSTextField?

    init() {
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
        rootView.setAccessibilityLabel("Tasks")
        rootView.onHoverChanged = { [weak self] hovering in
            self?.onHoverChanged?(hovering)
        }
        trackingRoot = rootView
        view = rootView

        installLeftPanel()
    }

    func setToggleActive(_ active: Bool) {
        leftHeader?.setPanelActive(active)
    }

    func setFullScreen(_ fullScreen: Bool) {
        leftHeader?.setFullScreen(fullScreen)
    }

    func applyTheme() {
        view.layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        leftHeader?.applyTheme()
        brandView?.applyTheme()
        sectionHeader?.applyTheme()
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
            brand.topAnchor.constraint(
                equalTo: topHeader.bottomAnchor,
                constant: AppTheme.panelContentInset
            ),

            sectionHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sectionHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sectionHeader.topAnchor.constraint(
                equalTo: brand.bottomAnchor,
                constant: AppTheme.panelSectionSpacing
            ),
            sectionHeader.heightAnchor.constraint(equalToConstant: AppTheme.paneHeaderHeight),

            messageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: AppTheme.panelContentInset),
            messageLabel.topAnchor.constraint(
                equalTo: sectionHeader.bottomAnchor,
                constant: AppTheme.panelSectionSpacing
            ),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -AppTheme.panelContentInset),
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
        leadingConstraint = toggle.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: AppTheme.sidebarToggleLeading
        )
        centerYConstraint = toggle.centerYAnchor.constraint(
            equalTo: centerYAnchor,
            constant: AppTheme.sidebarToggleVerticalOffset
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
        leadingConstraint.constant = fullScreen
            ? AppTheme.fullScreenSidebarToggleLeading
            : AppTheme.sidebarToggleLeading
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
            logo.widthAnchor.constraint(equalToConstant: AppTheme.sidebarBrandSize),
            logo.heightAnchor.constraint(equalToConstant: AppTheme.sidebarBrandSize),

            nameLabel.leadingAnchor.constraint(
                equalTo: logo.trailingAnchor,
                constant: AppTheme.workspaceContentInset
            ),
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
