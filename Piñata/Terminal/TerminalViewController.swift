import AppKit

typealias PaneID = UUID

enum SplitAxis: String, Codable, Equatable, Sendable {
    case vertical
    case horizontal
}

indirect enum PaneNode: Codable, Equatable, Sendable {
    case pane(PaneID)
    case split(Split)

    struct Split: Codable, Equatable, Sendable {
        let id: UUID
        let axis: SplitAxis
        var ratio: CGFloat
        var first: PaneNode
        var second: PaneNode
    }

    var paneIDs: [PaneID] {
        switch self {
        case .pane(let id):
            [id]
        case .split(let split):
            split.first.paneIDs + split.second.paneIDs
        }
    }

    func replacing(_ paneID: PaneID, with replacement: PaneNode) -> PaneNode {
        switch self {
        case .pane(let id):
            return id == paneID ? replacement : self
        case .split(var split):
            split.first = split.first.replacing(paneID, with: replacement)
            split.second = split.second.replacing(paneID, with: replacement)
            return .split(split)
        }
    }

    func removing(_ paneID: PaneID) -> PaneNode? {
        switch self {
        case .pane(let id):
            return id == paneID ? nil : self
        case .split(var split):
            let first = split.first.removing(paneID)
            let second = split.second.removing(paneID)
            switch (first, second) {
            case (nil, nil):
                return nil
            case (let remaining?, nil), (nil, let remaining?):
                return remaining
            case (let first?, let second?):
                split.first = first
                split.second = second
                return .split(split)
            }
        }
    }

    func settingRatio(splitID: UUID, ratio: CGFloat) -> PaneNode {
        switch self {
        case .pane:
            return self
        case .split(var split):
            if split.id == splitID {
                split.ratio = ratio
            } else {
                split.first = split.first.settingRatio(splitID: splitID, ratio: ratio)
                split.second = split.second.settingRatio(splitID: splitID, ratio: ratio)
            }
            return .split(split)
        }
    }

    func nearestPane(to paneID: PaneID) -> PaneID? {
        switch self {
        case .pane:
            return nil
        case .split(let split):
            if split.first.paneIDs.contains(paneID) {
                return split.first.nearestPane(to: paneID) ?? split.second.paneIDs.first
            }
            if split.second.paneIDs.contains(paneID) {
                return split.second.nearestPane(to: paneID) ?? split.first.paneIDs.first
            }
            return nil
        }
    }
}

struct TerminalPaneSnapshot: Codable, Equatable, Sendable {
    var id: PaneID
    var workingDirectory: String
}

struct TerminalSessionSnapshot: Codable, Equatable, Sendable {
    var root: PaneNode
    var activePaneID: PaneID
    var panes: [TerminalPaneSnapshot]

    var isValid: Bool {
        let paneIDs = panes.map(\.id)
        return !paneIDs.isEmpty
            && Set(paneIDs).count == paneIDs.count
            && Set(root.paneIDs) == Set(paneIDs)
            && root.paneIDs.contains(activePaneID)
    }
}

@MainActor
final class TerminalViewController: NSViewController {
    private let runtime: GhosttyRuntime
    private var root: PaneNode
    private var activePaneID: PaneID
    private var paneControllers: [PaneID: TerminalPaneViewController] = [:]
    private var rootController: NSViewController?
    var onCloseLastPane: (() -> Void)?
    var onChange: (() -> Void)?

    init(
        runtime: GhosttyRuntime,
        workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        let paneID = UUID()
        self.runtime = runtime
        root = .pane(paneID)
        activePaneID = paneID
        super.init(nibName: nil, bundle: nil)
        paneControllers[paneID] = makePaneController(
            paneID: paneID,
            workingDirectory: workingDirectory
        )
    }

    init(runtime: GhosttyRuntime, snapshot: TerminalSessionSnapshot) {
        self.runtime = runtime
        root = snapshot.root
        activePaneID = snapshot.activePaneID
        super.init(nibName: nil, bundle: nil)
        for pane in snapshot.panes {
            paneControllers[pane.id] = makePaneController(
                paneID: pane.id,
                workingDirectory: pane.workingDirectory
            )
        }
        if paneControllers[activePaneID] == nil {
            activePaneID = root.paneIDs.first ?? UUID()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = AppTheme.background.cgColor
        view = container
        rebuild()
        updateActivePane()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusActivePane()
    }

    func splitActiveVertically() {
        split(activePaneID, axis: .vertical)
    }

    func splitActiveHorizontally() {
        split(activePaneID, axis: .horizontal)
    }

    func closeActivePane() {
        close(activePaneID)
    }

    func focusActiveTerminal() {
        focusActivePane()
    }

    func applyTheme() {
        view.layer?.backgroundColor = AppTheme.background.cgColor
        paneControllers.values.forEach { $0.applyTheme() }
        if let rootController { invalidateSplitViews(in: rootController.view) }
        updateActivePane()
    }

    var sessionSnapshot: TerminalSessionSnapshot {
        TerminalSessionSnapshot(
            root: root,
            activePaneID: activePaneID,
            panes: root.paneIDs.compactMap { paneID in
                paneControllers[paneID].map {
                    TerminalPaneSnapshot(id: paneID, workingDirectory: $0.workingDirectory)
                }
            }
        )
    }

    func terminateSessions() {
        paneControllers.values.forEach { $0.terminateSession() }
    }

    private func invalidateSplitViews(in view: NSView) {
        if view is PaneSplitView { view.needsDisplay = true }
        view.subviews.forEach(invalidateSplitViews)
    }

    private func split(_ paneID: PaneID, axis: SplitAxis) {
        guard paneControllers.count < 8, let source = paneControllers[paneID] else {
            NSSound.beep()
            return
        }
        let newPaneID = UUID()
        paneControllers[newPaneID] = makePaneController(
            paneID: newPaneID,
            workingDirectory: source.workingDirectory
        )
        root = root.replacing(
            paneID,
            with: .split(.init(
                id: UUID(),
                axis: axis,
                ratio: 0.5,
                first: .pane(paneID),
                second: .pane(newPaneID)
            ))
        )
        activePaneID = newPaneID
        rebuild()
        updateActivePane()
        focusActivePane()
        onChange?()
    }

    private func close(_ paneID: PaneID) {
        guard paneControllers.count > 1 else {
            onCloseLastPane?()
            return
        }
        guard let nextRoot = root.removing(paneID) else { return }
        let nearest = root.nearestPane(to: paneID)
        if let removed = paneControllers.removeValue(forKey: paneID) {
            removed.terminateSession()
            removed.view.removeFromSuperview()
            removed.removeFromParent()
        }
        root = nextRoot
        if activePaneID == paneID {
            activePaneID = nearest ?? root.paneIDs[0]
        }
        rebuild()
        updateActivePane()
        focusActivePane()
        onChange?()
    }

    private func makePaneController(
        paneID: PaneID,
        workingDirectory: String
    ) -> TerminalPaneViewController {
        let controller = TerminalPaneViewController(
            paneID: paneID,
            runtime: runtime,
            workingDirectory: workingDirectory
        )
        controller.didFocus = { [weak self] paneID in
            self?.activate(paneID)
        }
        controller.didRequestSplit = { [weak self] paneID, axis in
            self?.split(paneID, axis: axis)
        }
        controller.didRequestClose = { [weak self] paneID in
            self?.close(paneID)
        }
        return controller
    }

    private func activate(_ paneID: PaneID) {
        guard paneControllers[paneID] != nil, activePaneID != paneID else { return }
        activePaneID = paneID
        updateActivePane()
        onChange?()
    }

    private func updateActivePane() {
        let canClose = paneControllers.count > 1 || onCloseLastPane != nil
        for (paneID, controller) in paneControllers {
            controller.setActive(paneID == activePaneID, canClose: canClose)
        }
    }

    private func focusActivePane() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.paneControllers[self.activePaneID]?.focus()
        }
    }

    private func rebuild() {
        for controller in paneControllers.values where controller.parent != nil {
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
        if let rootController {
            rootController.view.removeFromSuperview()
            rootController.removeFromParent()
        }

        let controller = makeNodeController(root)
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        rootController = controller
    }

    private func makeNodeController(_ node: PaneNode) -> NSViewController {
        switch node {
        case .pane(let paneID):
            guard let controller = paneControllers[paneID] else {
                preconditionFailure("Missing terminal pane")
            }
            return controller
        case .split(let split):
            let controller = SplitHostController(split: split) { [weak self] splitID, ratio in
                guard let self else { return }
                self.root = self.root.settingRatio(splitID: splitID, ratio: ratio)
                self.onChange?()
            }
            let first = NSSplitViewItem(viewController: makeNodeController(split.first))
            let second = NSSplitViewItem(viewController: makeNodeController(split.second))
            first.minimumThickness = AppTheme.paneMinimumSize
            second.minimumThickness = AppTheme.paneMinimumSize
            controller.addSplitViewItem(first)
            controller.addSplitViewItem(second)
            controller.scheduleInitialRatio()
            return controller
        }
    }
}

@MainActor
private final class TerminalPaneViewController: NSViewController {
    let paneID: PaneID
    let terminalView: GhosttySurfaceView
    private let header: PaneHeaderView

    var didFocus: ((PaneID) -> Void)?
    var didRequestSplit: ((PaneID, SplitAxis) -> Void)?
    var didRequestClose: ((PaneID) -> Void)?

    init(paneID: PaneID, runtime: GhosttyRuntime, workingDirectory: String) {
        self.paneID = paneID
        terminalView = GhosttySurfaceView(
            runtime: runtime,
            workingDirectory: workingDirectory,
            sessionID: paneID
        )
        header = PaneHeaderView(title: PaneHeaderView.displayTitle(terminalView.defaultTitle))
        super.init(nibName: nil, bundle: nil)

        terminalView.didFocus = { [weak self] in
            guard let self else { return }
            self.didFocus?(self.paneID)
        }
        terminalView.didChangeTitle = { [weak header] title in
            header?.setTitle(title)
        }
        header.didActivate = { [weak self] in
            guard let self else { return }
            self.focus()
        }
        header.didSplitVertically = { [weak self] in
            guard let self else { return }
            self.didRequestSplit?(self.paneID, .vertical)
        }
        header.didSplitHorizontally = { [weak self] in
            guard let self else { return }
            self.didRequestSplit?(self.paneID, .horizontal)
        }
        header.didClose = { [weak self] in
            guard let self else { return }
            self.didRequestClose?(self.paneID)
        }
    }

    var workingDirectory: String { terminalView.workingDirectory }

    func terminateSession() {
        terminalView.terminateSession()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = AppTheme.background.cgColor

        header.translatesAutoresizingMaskIntoConstraints = false
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)
        container.addSubview(terminalView)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.heightAnchor.constraint(equalToConstant: AppTheme.paneHeaderHeight),
            terminalView.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: AppTheme.terminalContentInset
            ),
            terminalView.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -AppTheme.terminalContentInset
            ),
            terminalView.topAnchor.constraint(
                equalTo: header.bottomAnchor,
                constant: AppTheme.terminalVerticalInset
            ),
            terminalView.bottomAnchor.constraint(
                equalTo: container.bottomAnchor,
                constant: -AppTheme.terminalVerticalInset
            ),
        ])
        view = container
    }

    func setActive(_ active: Bool, canClose: Bool) {
        header.setActive(active, canClose: canClose)
        terminalView.alphaValue = active ? 1 : AppTheme.inactivePaneAlpha
    }

    func applyTheme() {
        view.layer?.backgroundColor = AppTheme.background.cgColor
        header.applyTheme()
    }

    func focus() {
        view.window?.makeFirstResponder(terminalView)
    }
}

@MainActor
private final class PaneHeaderView: NSView {
    var didActivate: (() -> Void)?
    var didSplitVertically: (() -> Void)?
    var didSplitHorizontally: (() -> Void)?
    var didClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var active = true
    private let verticalButton = PaneActionButton(
        symbolName: "square.split.2x1",
        accessibilityLabel: "Split vertically",
        toolTip: "Split vertically (⌘D)",
    )
    private let horizontalButton = PaneActionButton(
        symbolName: "square.split.1x2",
        accessibilityLabel: "Split horizontally",
        toolTip: "Split horizontally (⇧⌘D)",
    )
    private let closeButton = PaneActionButton(
        symbolName: "xmark",
        accessibilityLabel: "Close pane",
        toolTip: "Close pane (⌘W)"
    )

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = AppTheme.background.cgColor

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        icon.contentTintColor = AppTheme.tertiaryText
        icon.symbolConfiguration = .init(
            pointSize: AppTheme.paneHeaderIconPointSize,
            weight: .medium
        )
        icon.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.label, weight: 600)
        titleLabel.textColor = AppTheme.secondaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for button in [verticalButton, horizontalButton, closeButton] {
            addSubview(button)
        }
        addSubview(icon)
        addSubview(titleLabel)

        verticalButton.target = self
        verticalButton.action = #selector(splitVertically)
        horizontalButton.target = self
        horizontalButton.action = #selector(splitHorizontally)
        closeButton.target = self
        closeButton.action = #selector(closePane)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: AppTheme.workspaceContentInset
            ),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: AppTheme.paneHeaderIconWidth),
            icon.heightAnchor.constraint(equalToConstant: AppTheme.paneHeaderIconHeight),
            titleLabel.leadingAnchor.constraint(
                equalTo: icon.trailingAnchor,
                constant: AppTheme.paneHeaderContentGap
            ),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            verticalButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor,
                constant: AppTheme.paneHeaderContentGap
            ),
            closeButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -AppTheme.paneHeaderTrailingInset
            ),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            horizontalButton.trailingAnchor.constraint(
                equalTo: closeButton.leadingAnchor,
                constant: -AppTheme.paneHeaderActionGap
            ),
            horizontalButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            verticalButton.trailingAnchor.constraint(
                equalTo: horizontalButton.leadingAnchor,
                constant: -AppTheme.paneHeaderActionGap
            ),
            verticalButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }


    override func mouseDown(with event: NSEvent) {
        didActivate?()
        window?.performDrag(with: event)
    }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.background.cgColor
        icon.contentTintColor = AppTheme.tertiaryText
        titleLabel.font = AppTheme.font(ofSize: AppTheme.typography.label, weight: 600)
        titleLabel.textColor = active ? AppTheme.secondaryText : AppTheme.tertiaryText
        for button in [verticalButton, horizontalButton, closeButton] {
            button.applyTheme()
        }
    }

    func setTitle(_ title: String) {
        guard !title.isEmpty else { return }
        titleLabel.stringValue = Self.displayTitle(title)
    }

    static func displayTitle(_ title: String) -> String {
        guard
            let at = title.firstIndex(of: "@"),
            let colon = title[title.index(after: at)...].firstIndex(of: ":")
        else {
            return title
        }
        let host = title[title.index(after: at)..<colon].lowercased()
        let localHost = ProcessInfo.processInfo.hostName.lowercased()
        let localShortHost = localHost.split(separator: ".", maxSplits: 1).first.map(String.init)
        guard host == localHost || host == localShortHost else { return title }

        let directory = title[title.index(after: colon)...]
            .trimmingCharacters(in: .whitespaces)
        return directory.isEmpty ? title : directory
    }

    func setActive(_ active: Bool, canClose: Bool) {
        self.active = active
        titleLabel.textColor = active ? AppTheme.secondaryText : AppTheme.tertiaryText
        alphaValue = active ? 1 : AppTheme.inactivePaneHeaderAlpha
        closeButton.isEnabled = canClose
    }

    @objc private func splitVertically() {
        didSplitVertically?()
    }

    @objc private func splitHorizontally() {
        didSplitHorizontally?()
    }

    @objc private func closePane() {
        didClose?()
    }
}

@MainActor
private final class PaneActionButton: AppButton {
    init(symbolName: String, accessibilityLabel: String, toolTip: String) {
        super.init(frame: .zero)
        role = .icon
        translatesAutoresizingMaskIntoConstraints = false
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
        imageScaling = .scaleProportionallyDown
        layer?.cornerRadius = AppTheme.workspaceControlCornerRadius
        self.toolTip = toolTip
        setAccessibilityLabel(accessibilityLabel)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: AppTheme.paneHeaderActionSize),
            heightAnchor.constraint(equalToConstant: AppTheme.paneHeaderActionSize),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

@MainActor
private final class PaneSplitView: NSSplitView {
    private var trackingArea: NSTrackingArea?
    private var hoveringDivider = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        guard let firstPane = subviews.first else { return }
        let point = convert(event.locationInWindow, from: nil)
        let divider = if isVertical {
            NSRect(
                x: firstPane.frame.maxX,
                y: bounds.minY,
                width: dividerThickness,
                height: bounds.height
            )
        } else {
            NSRect(
                x: bounds.minX,
                y: firstPane.frame.maxY,
                width: bounds.width,
                height: dividerThickness
            )
        }
        let hitArea = divider.insetBy(
            dx: isVertical ? -AppTheme.splitHitSlop : 0,
            dy: isVertical ? 0 : -AppTheme.splitHitSlop
        )
        let hovering = hitArea.contains(point)
        guard hovering != hoveringDivider else { return }
        hoveringDivider = hovering
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveringDivider = false
        needsDisplay = true
    }

    override func drawDivider(in rect: NSRect) {
        (hoveringDivider ? AppTheme.separator : AppTheme.border).setFill()
        rect.fill()
    }
}

@MainActor
private final class SplitHostController: NSSplitViewController {
    private let splitID: UUID
    private let initialRatio: CGFloat
    private let ratioChanged: (UUID, CGFloat) -> Void
    private var installedInitialRatio = false
    private var suppressRatioChange = true

    init(split: PaneNode.Split, ratioChanged: @escaping (UUID, CGFloat) -> Void) {
        splitID = split.id
        initialRatio = split.ratio
        self.ratioChanged = ratioChanged
        super.init(nibName: nil, bundle: nil)
        splitView = PaneSplitView()
        splitView.isVertical = split.axis == .vertical
        splitView.dividerStyle = .thin
        splitView.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        installInitialRatio()
    }

    func scheduleInitialRatio() {
        DispatchQueue.main.async { [weak self] in
            self?.installInitialRatio()
        }
    }

    private func installInitialRatio() {
        guard !installedInitialRatio, splitViewItems.count == 2 else { return }
        let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let available = total - splitView.dividerThickness
        guard available > 0 else { return }
        splitView.setPosition(available * initialRatio, ofDividerAt: 0)
        installedInitialRatio = true
        DispatchQueue.main.async { [weak self] in
            self?.suppressRatioChange = false
        }
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !suppressRatioChange, splitViewItems.count == 2 else { return }
        let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let available = total - splitView.dividerThickness
        guard available > 0 else { return }
        let first = splitViewItems[0].viewController.view.frame
        ratioChanged(splitID, (splitView.isVertical ? first.width : first.height) / available)
    }

    override func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        splitView.isVertical
            ? proposedEffectiveRect.insetBy(dx: -AppTheme.splitHitSlop, dy: 0)
            : proposedEffectiveRect.insetBy(dx: 0, dy: -AppTheme.splitHitSlop)
    }
}
