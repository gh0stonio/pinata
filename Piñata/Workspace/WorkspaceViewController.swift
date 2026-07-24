import AppKit

@MainActor
final class WorkspaceViewController: NSViewController {
    private let topBar = TopBarView()
    private let bodyView = NSView()
    private let leftPanelController = PanelViewController(role: .left)
    private let mainContentController: TerminalViewController
    private let rightPanelController = PanelViewController(role: .right)
    private let leftResizeHandle = PanelResizeHandle()
    private let rightResizeHandle = PanelResizeHandle()

    private var leftWidthConstraint: NSLayoutConstraint!
    private var rightWidthConstraint: NSLayoutConstraint!
    private var leftPanelVisible = true
    private var rightPanelVisible = false
    private var leftPanelWidth = AppTheme.leftPanelWidth
    private var rightPanelWidth = AppTheme.rightPanelWidth

    init(runtime: GhosttyRuntime) {
        mainContentController = TerminalViewController(runtime: runtime)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let rootView = NSView()
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = AppTheme.background.cgColor
        view = rootView

        bodyView.translatesAutoresizingMaskIntoConstraints = false
        bodyView.wantsLayer = true
        bodyView.layer?.masksToBounds = true
        bodyView.layer?.backgroundColor = AppTheme.background.cgColor

        addChild(leftPanelController)
        addChild(mainContentController)
        addChild(rightPanelController)

        let leftPanel = leftPanelController.view
        let mainContent = mainContentController.view
        let rightPanel = rightPanelController.view
        leftPanel.translatesAutoresizingMaskIntoConstraints = false
        mainContent.translatesAutoresizingMaskIntoConstraints = false
        rightPanel.translatesAutoresizingMaskIntoConstraints = false

        bodyView.addSubview(leftPanel)
        bodyView.addSubview(mainContent)
        bodyView.addSubview(rightPanel)
        bodyView.addSubview(leftResizeHandle)
        bodyView.addSubview(rightResizeHandle)
        rootView.addSubview(topBar)
        rootView.addSubview(bodyView)

        leftWidthConstraint = leftPanel.widthAnchor.constraint(equalToConstant: leftPanelWidth)
        rightWidthConstraint = rightPanel.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: rootView.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: AppTheme.titleBarHeight),

            bodyView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            bodyView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            bodyView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            bodyView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            leftPanel.leadingAnchor.constraint(equalTo: bodyView.leadingAnchor),
            leftPanel.topAnchor.constraint(equalTo: bodyView.topAnchor),
            leftPanel.bottomAnchor.constraint(equalTo: bodyView.bottomAnchor),
            leftWidthConstraint,

            mainContent.leadingAnchor.constraint(equalTo: leftPanel.trailingAnchor),
            mainContent.topAnchor.constraint(equalTo: bodyView.topAnchor),
            mainContent.bottomAnchor.constraint(equalTo: bodyView.bottomAnchor),

            rightPanel.leadingAnchor.constraint(equalTo: mainContent.trailingAnchor),
            rightPanel.trailingAnchor.constraint(equalTo: bodyView.trailingAnchor),
            rightPanel.topAnchor.constraint(equalTo: bodyView.topAnchor),
            rightPanel.bottomAnchor.constraint(equalTo: bodyView.bottomAnchor),
            rightWidthConstraint,

            mainContent.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),

            leftResizeHandle.centerXAnchor.constraint(equalTo: leftPanel.trailingAnchor),
            leftResizeHandle.topAnchor.constraint(equalTo: bodyView.topAnchor),
            leftResizeHandle.bottomAnchor.constraint(equalTo: bodyView.bottomAnchor),
            leftResizeHandle.widthAnchor.constraint(equalToConstant: 10),

            rightResizeHandle.centerXAnchor.constraint(equalTo: rightPanel.leadingAnchor),
            rightResizeHandle.topAnchor.constraint(equalTo: bodyView.topAnchor),
            rightResizeHandle.bottomAnchor.constraint(equalTo: bodyView.bottomAnchor),
            rightResizeHandle.widthAnchor.constraint(equalToConstant: 10),
        ])

        leftResizeHandle.onDrag = { [weak self] delta in
            self?.resizeLeftPanel(by: delta)
        }
        rightResizeHandle.onDrag = { [weak self] delta in
            self?.resizeRightPanel(by: delta)
        }
        leftResizeHandle.onKeyboardResize = { [weak self] command in
            self?.resizeLeftPanel(with: command)
        }
        rightResizeHandle.onKeyboardResize = { [weak self] command in
            self?.resizeRightPanel(with: command)
        }
        leftPanelController.setContentWidth(leftPanelWidth)
        rightPanelController.setContentWidth(rightPanelWidth)
        rightResizeHandle.setEnabled(false)
        rightPanelController.setContentVisible(false)

        topBar.onToggleLeftPanel = { [weak self] in
            self?.toggleLeftPanel(nil)
        }
        topBar.onToggleRightPanel = { [weak self] in
            self?.toggleRightPanel(nil)
        }
        updateTopBarState()
    }

    @objc func toggleLeftPanel(_ sender: Any?) {
        setLeftPanelVisible(!leftPanelVisible)
    }

    @objc func toggleRightPanel(_ sender: Any?) {
        setRightPanelVisible(!rightPanelVisible)
    }

    private func setLeftPanelVisible(_ visible: Bool) {
        guard visible != leftPanelVisible else { return }

        leftPanelVisible = visible
        leftPanelController.setContentWidth(leftPanelWidth)
        leftPanelController.setContentVisible(visible)
        leftResizeHandle.setEnabled(visible)
        leftWidthConstraint.constant = visible ? leftPanelWidth : 0
        bodyView.layoutSubtreeIfNeeded()
        updateTopBarState()
    }

    private func setRightPanelVisible(_ visible: Bool) {
        guard visible != rightPanelVisible else { return }

        rightPanelVisible = visible
        rightPanelController.setContentWidth(rightPanelWidth)
        rightPanelController.setContentVisible(visible)
        rightResizeHandle.setEnabled(visible)
        rightWidthConstraint.constant = visible ? rightPanelWidth : 0
        bodyView.layoutSubtreeIfNeeded()
        updateTopBarState()
    }

    private func resizeLeftPanel(by delta: CGFloat) {
        guard leftPanelVisible else { return }
        let maximum = min(
            AppTheme.leftPanelRange.upperBound,
            bodyView.bounds.width - (rightPanelVisible ? rightPanelWidth : 0)
        )
        leftPanelWidth = min(
            max(leftWidthConstraint.constant + delta, AppTheme.leftPanelRange.lowerBound),
            maximum
        )
        leftWidthConstraint.constant = leftPanelWidth
        leftPanelController.setContentWidth(leftPanelWidth)
    }

    private func resizeRightPanel(by delta: CGFloat) {
        guard rightPanelVisible else { return }
        let maximum = min(
            AppTheme.rightPanelRange.upperBound,
            bodyView.bounds.width - (leftPanelVisible ? leftPanelWidth : 0)
        )
        rightPanelWidth = min(
            max(rightWidthConstraint.constant - delta, AppTheme.rightPanelRange.lowerBound),
            maximum
        )
        rightWidthConstraint.constant = rightPanelWidth
        rightPanelController.setContentWidth(rightPanelWidth)
    }

    private func resizeLeftPanel(with command: PanelResizeHandle.KeyboardCommand) {
        switch command {
        case .decrease:
            resizeLeftPanel(by: -12)
        case .increase:
            resizeLeftPanel(by: 12)
        case .minimum:
            resizeLeftPanel(by: -AppTheme.leftPanelRange.upperBound)
        case .maximum:
            resizeLeftPanel(by: AppTheme.leftPanelRange.upperBound)
        }
    }

    private func resizeRightPanel(with command: PanelResizeHandle.KeyboardCommand) {
        switch command {
        case .decrease:
            resizeRightPanel(by: 12)
        case .increase:
            resizeRightPanel(by: -12)
        case .minimum:
            resizeRightPanel(by: AppTheme.rightPanelRange.upperBound)
        case .maximum:
            resizeRightPanel(by: -AppTheme.rightPanelRange.upperBound)
        }
    }

    private func updateTopBarState() {
        topBar.setPanelVisibility(left: leftPanelVisible, right: rightPanelVisible)
    }
}

@MainActor
private final class PanelResizeHandle: NSView {
    enum KeyboardCommand {
        case decrease
        case increase
        case minimum
        case maximum
    }

    var onDrag: ((CGFloat) -> Void)?
    var onKeyboardResize: ((KeyboardCommand) -> Void)?

    private let line = NSView()
    private var enabled = true

    override var acceptsFirstResponder: Bool { enabled }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize panel")

        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.backgroundColor = AppTheme.border.cgColor
        addSubview(line)

        NSLayoutConstraint.activate([
            line.centerXAnchor.constraint(equalTo: centerXAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        enabled ? super.hitTest(point) : nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard enabled else { return }
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.deltaX)
    }

    override func keyDown(with event: NSEvent) {
        let command: KeyboardCommand?

        switch event.keyCode {
        case 123: command = .decrease
        case 124: command = .increase
        case 115: command = .minimum
        case 119: command = .maximum
        default: command = nil
        }

        if let command {
            onKeyboardResize?(command)
        } else {
            super.keyDown(with: event)
        }
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        alphaValue = enabled ? 1 : 0
        window?.invalidateCursorRects(for: self)
    }
}
