import AppKit

@MainActor
final class TopBarView: NSView {
    var onToggleLeftPanel: (() -> Void)?
    var onToggleRightPanel: (() -> Void)?

    private let leftToggle = PanelToggleButton(
        symbolName: "sidebar.left",
        accessibilityLabel: "Toggle left panel"
    )
    private let rightToggle = PanelToggleButton(
        symbolName: "sidebar.right",
        accessibilityLabel: "Toggle right panel"
    )
    private let separator = NSView()
    private var leftLeadingConstraint: NSLayoutConstraint?
    private weak var observedWindow: NSWindow?

    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = AppTheme.chromeBackground.cgColor

        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = AppTheme.border.cgColor

        addSubview(leftToggle)
        addSubview(rightToggle)
        addSubview(separator)

        leftLeadingConstraint = leftToggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 92)
        NSLayoutConstraint.activate([
            leftLeadingConstraint!,
            leftToggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightToggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            rightToggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])

        leftToggle.target = self
        leftToggle.action = #selector(toggleLeftPanel)
        rightToggle.target = self
        rightToggle.action = #selector(toggleRightPanel)
        leftToggle.toolTip = "Toggle left panel (⌘B)"
        rightToggle.toolTip = "Toggle right panel (⌘L)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard observedWindow !== window else { return }

        NotificationCenter.default.removeObserver(self)
        observedWindow = window

        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(fullscreenStateChanged),
                name: NSWindow.willEnterFullScreenNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(fullscreenStateChanged),
                name: NSWindow.willExitFullScreenNotification,
                object: window
            )
        }

        updateTrafficLightReserve()
    }

    override func layout() {
        super.layout()
        alignTrafficLights()
    }

    func setPanelVisibility(left: Bool, right: Bool) {
        leftToggle.panelVisible = left
        rightToggle.panelVisible = right
    }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.chromeBackground.cgColor
        separator.layer?.backgroundColor = AppTheme.border.cgColor
        leftToggle.applyTheme()
        rightToggle.applyTheme()
    }

    @objc private func toggleLeftPanel() {
        onToggleLeftPanel?()
    }

    @objc private func toggleRightPanel() {
        onToggleRightPanel?()
    }

    @objc private func fullscreenStateChanged(_ notification: Notification) {
        updateTrafficLightReserve(
            fullScreen: notification.name == NSWindow.willEnterFullScreenNotification
        )
    }

    private func alignTrafficLights() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let centerInWindow = convert(
            NSPoint(x: bounds.midX, y: bounds.midY),
            to: nil
        )

        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard
                let button = window.standardWindowButton(buttonType),
                let buttonContainer = button.superview
            else {
                continue
            }

            let centerInContainer = buttonContainer.convert(centerInWindow, from: nil)
            button.setFrameOrigin(
                NSPoint(
                    x: button.frame.origin.x,
                    y: round(centerInContainer.y - button.frame.height / 2)
                )
            )
        }
    }

    private func updateTrafficLightReserve(fullScreen: Bool? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            leftLeadingConstraint?.constant =
                (fullScreen ?? window?.styleMask.contains(.fullScreen) == true) ? 14 : 92
            layoutSubtreeIfNeeded()
        }
    }
}

@MainActor
private final class PanelToggleButton: NSButton {
    var panelVisible = false {
        didSet { updateAppearance() }
    }

    private var trackingArea: NSTrackingArea?
    private let backgroundLayer = CALayer()
    private var isHovering = false

    init(symbolName: String, accessibilityLabel: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        backgroundLayer.cornerRadius = 6
        layer?.insertSublayer(backgroundLayer, at: 0)
        isBordered = false
        bezelStyle = .regularSquare
        image = Self.balancedSymbol(named: symbolName, accessibilityLabel: accessibilityLabel)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        setAccessibilityLabel(accessibilityLabel)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        updateAppearance()
    }

    override func layout() {
        super.layout()
        let side = min(28, bounds.width, bounds.height)
        backgroundLayer.frame = CGRect(
            x: (bounds.width - side) / 2,
            y: (bounds.height - side) / 2,
            width: side,
            height: side
        )
    }

    private static func balancedSymbol(named name: String, accessibilityLabel: String) -> NSImage? {
        guard let source = NSImage(
            systemSymbolName: name,
            accessibilityDescription: accessibilityLabel
        ) else {
            return nil
        }
        let size = NSSize(width: source.size.width, height: source.size.height + 2)
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
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

    private func updateAppearance() {
        contentTintColor = if panelVisible {
            AppTheme.panelAccentIcon
        } else if isHovering {
            AppTheme.panelToggleHoverText
        } else {
            AppTheme.tertiaryText
        }
        backgroundLayer.backgroundColor = if panelVisible {
            AppTheme.panelAccentBackground.cgColor
        } else if isHovering {
            AppTheme.panelToggleHoverBackground.cgColor
        } else {
            NSColor.clear.cgColor
        }
    }
}
