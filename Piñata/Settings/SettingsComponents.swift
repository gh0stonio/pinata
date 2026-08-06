import AppKit

@MainActor
enum SettingsLayout {
    static let summaryMinimumWidth: CGFloat = 216
    static let summaryMaximumWidth: CGFloat = 280
    static let rowLabelMinimumWidth: CGFloat = 200
    static let rowControlMinimumWidth: CGFloat = 240
    static let rowControlMaximumWidth: CGFloat = 430
    static let rowColumnGap: CGFloat = 20
    static let splitColumnGap: CGFloat = 20
    static var contentMinimumWidth: CGFloat {
        pageHorizontalPadding * 2
            + summaryMinimumWidth
            + splitColumnGap
            + rowLabelMinimumWidth
            + rowColumnGap
            + rowControlMinimumWidth
    }
    static let sectionGap: CGFloat = 16
    static let pageHorizontalPadding: CGFloat = 24
    static let pageVerticalPadding: CGFloat = 18
    static let blockVerticalPadding: CGFloat = 20
    static let titleToDetailGap: CGFloat = 5
    static let rowHeight: CGFloat = 64
    static let controlHeight: CGFloat = 32
    static let controlCornerRadius: CGFloat = 6
    static let choiceInset: CGFloat = 2
    static let choiceCornerRadius: CGFloat = 4
    static let colorChoiceDiameter: CGFloat = 24
    static let colorChoiceGap: CGFloat = 7
    static let stepperButtonWidth: CGFloat = 24
    static let navigationCornerRadius: CGFloat = 7
    static let compactRowHeight: CGFloat = 48
    static let compactRowCornerRadius: CGFloat = 8
    static let compactContentInset: CGFloat = 12
    static let compactIconSize: CGFloat = 14
    static let compactMetadataGap: CGFloat = 16
    static let compactChevronWidth: CGFloat = 10
    static let compactChevronHeight: CGFloat = 14
    static let navigationRowHeight: CGFloat = 28
    static let navigationIconSize: CGFloat = 18
    static let navigationItemGap: CGFloat = 12
    static let navigationLabelGap: CGFloat = 8
    static let navigationSectionGap: CGFloat = 24
    static let dividerThickness: CGFloat = 1
    static let skeletonHeight: CGFloat = 14
    static let skeletonCornerRadius: CGFloat = 4
    static let controlHorizontalPadding: CGFloat = 10
    static let breadcrumbHeight: CGFloat = 24
    static let breadcrumbGap: CGFloat = 6
    static let breadcrumbToContentGap: CGFloat = 2
    static let themeControlWidth: CGFloat = 122
    static let intensityControlWidth: CGFloat = 272
    static let appFontControlWidth: CGFloat = 180
    static let terminalFontControlWidth: CGFloat = 82
    static let repositoryPathControlWidth: CGFloat = 300
    static let choiceHorizontalPadding: CGFloat = 18
    static let accentCheckmarkSize: CGFloat = 15

    static var valueFont: NSFont {
        .monospacedSystemFont(
            ofSize: AppTheme.typography.settingsValue,
            weight: .regular
        )
    }

    static func applyControlSurface(_ view: NSView, clipsContents: Bool = false) {
        view.wantsLayer = true
        view.layer?.cornerRadius = controlCornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 1
        view.layer?.masksToBounds = clipsContents
        view.layer?.backgroundColor = AppTheme.controlBackground.cgColor
        view.layer?.borderColor = AppTheme.border.cgColor
    }

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

    static func applyTitleStyle(_ label: NSTextField) {
        label.textColor = AppTheme.primaryText
        label.font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 650)
    }

    static func applyDetailStyle(_ label: NSTextField) {
        label.textColor = AppTheme.tertiaryText
        label.font = AppTheme.font(ofSize: AppTheme.typography.settingsBody)
    }
}

final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class SettingsSplitPageView: NSView, SettingsThemeApplying {
    private let scrollView = NSScrollView()
    private let document = SettingsDocumentView()
    private let leftStack = NSStackView()
    private let rightStack = NSStackView()
    private var sectionCount = 0
    private var previousSummary: NSView?
    private var previousContent: NSView?
    private var isSizingDocument = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        installLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layout() {
        super.layout()
        sizeDocumentToViewport()
    }

    func addSection(title: String, detail: String, content: NSView) {
        if sectionCount > 0 {
            let divider = SettingsSplitDivider()
            document.addSubview(divider)
            if let previousSummary, let previousContent {
                let nextSectionGap = SettingsLayout.sectionGap * 2
                    - SettingsLayout.blockVerticalPadding / 2
                    + SettingsLayout.dividerThickness
                leftStack.setCustomSpacing(nextSectionGap, after: previousSummary)
                rightStack.setCustomSpacing(nextSectionGap, after: previousContent)
                NSLayoutConstraint.activate([
                    divider.leadingAnchor.constraint(equalTo: leftStack.leadingAnchor),
                    divider.trailingAnchor.constraint(equalTo: rightStack.trailingAnchor),
                    divider.topAnchor.constraint(
                        equalTo: previousSummary.bottomAnchor,
                        constant: SettingsLayout.sectionGap
                    ),
                ])
            }
        }
        let summary = SettingsSplitSummary(title: title, detail: detail)
        summary.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        leftStack.addArrangedSubview(summary)
        rightStack.addArrangedSubview(content)
        summary.widthAnchor.constraint(equalTo: leftStack.widthAnchor).isActive = true
        content.widthAnchor.constraint(equalTo: rightStack.widthAnchor).isActive = true
        summary.heightAnchor.constraint(equalTo: content.heightAnchor).isActive = true
        previousSummary = summary
        previousContent = content
        sectionCount += 1
    }

    func scrollToTop() {
        layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func applyTheme() {
        scrollView.drawsBackground = false
        document.layer?.backgroundColor = AppTheme.background.cgColor
        leftStack.arrangedSubviews.compactMap { $0 as? SettingsThemeApplying }.forEach { $0.applyTheme() }
        rightStack.arrangedSubviews.compactMap { $0 as? SettingsThemeApplying }.forEach { $0.applyTheme() }
        document.subviews.compactMap { $0 as? SettingsSplitDivider }.forEach { $0.applyTheme() }
    }

    private func installLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = true
        document.wantsLayer = true
        [leftStack, rightStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.orientation = .vertical
            $0.alignment = .leading
            $0.spacing = 0
            document.addSubview($0)
        }
        addSubview(scrollView)
        let preferredSummaryWidth = leftStack.widthAnchor.constraint(
            equalTo: document.widthAnchor,
            multiplier: 0.25
        )
        preferredSummaryWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftStack.leadingAnchor.constraint(
                equalTo: document.leadingAnchor,
                constant: SettingsLayout.pageHorizontalPadding
            ),
            leftStack.topAnchor.constraint(
                equalTo: document.topAnchor,
                constant: SettingsLayout.pageVerticalPadding
            ),
            leftStack.widthAnchor.constraint(greaterThanOrEqualToConstant: SettingsLayout.summaryMinimumWidth),
            leftStack.widthAnchor.constraint(lessThanOrEqualToConstant: SettingsLayout.summaryMaximumWidth),
            preferredSummaryWidth,
            rightStack.leadingAnchor.constraint(
                equalTo: leftStack.trailingAnchor,
                constant: SettingsLayout.splitColumnGap
            ),
            rightStack.trailingAnchor.constraint(
                equalTo: document.trailingAnchor,
                constant: -SettingsLayout.pageHorizontalPadding
            ),
            rightStack.widthAnchor.constraint(greaterThanOrEqualToConstant: SettingsLayout.rowLabelMinimumWidth + SettingsLayout.rowColumnGap + SettingsLayout.rowControlMinimumWidth),
            rightStack.topAnchor.constraint(equalTo: leftStack.topAnchor),
            document.bottomAnchor.constraint(
                greaterThanOrEqualTo: leftStack.bottomAnchor,
                constant: SettingsLayout.pageVerticalPadding
            ),
            document.bottomAnchor.constraint(
                greaterThanOrEqualTo: rightStack.bottomAnchor,
                constant: SettingsLayout.pageVerticalPadding
            ),
        ])
        applyTheme()
    }

    private func sizeDocumentToViewport() {
        guard !isSizingDocument else { return }
        let viewport = scrollView.contentView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }

        isSizingDocument = true
        defer { isSizingDocument = false }

        let width = max(viewport.width, SettingsLayout.contentMinimumWidth)
        document.setFrameSize(NSSize(width: width, height: max(viewport.height, document.frame.height)))
        document.layoutSubtreeIfNeeded()
        let contentHeight = max(leftStack.frame.maxY, rightStack.frame.maxY)
            + SettingsLayout.pageVerticalPadding
        document.setFrameSize(NSSize(width: width, height: max(viewport.height, contentHeight)))
    }
}

@MainActor
private final class SettingsSplitSummary: NSView, SettingsThemeApplying {
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField

    init(title: String, detail: String) {
        titleLabel = NSTextField(labelWithString: title)
        detailLabel = NSTextField(wrappingLabelWithString: detail)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        [titleLabel, detailLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(
                equalTo: topAnchor,
                constant: SettingsLayout.blockVerticalPadding / 2
            ),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailLabel.topAnchor.constraint(
                equalTo: titleLabel.bottomAnchor,
                constant: SettingsLayout.titleToDetailGap
            ),
            detailLabel.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor,
                constant: -(SettingsLayout.blockVerticalPadding / 2)
            ),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        SettingsLayout.applyTitleStyle(titleLabel)
        SettingsLayout.applyDetailStyle(detailLabel)
    }
}

@MainActor
private final class SettingsSplitDivider: NSView, SettingsThemeApplying {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: SettingsLayout.dividerThickness).isActive = true
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.border.cgColor
    }
}

@MainActor
protocol SettingsThemeApplying: AnyObject {
    func applyTheme()
}

@MainActor
protocol SettingsPageContent: SettingsThemeApplying {
    var settingsView: NSView { get }
    func scrollToTop()
    func didDeselect()
}

extension SettingsPageContent where Self: NSView {
    var settingsView: NSView { self }
    func didDeselect() {}
}

@MainActor
class SettingsHoverView: NSView {
    private var trackingArea: NSTrackingArea?
    private(set) var isHovering = false {
        didSet { hoverStateDidChange() }
    }

    func hoverStateDidChange() {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
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
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }
}

@MainActor
func settingsRowStack(_ rows: [SettingsRowView]) -> NSStackView {
    SettingsRowStack(rows: rows)
}

private final class SettingsRowStack: NSStackView, SettingsThemeApplying {
    init(rows: [SettingsRowView]) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0
        rows.forEach {
            addArrangedSubview($0)
            $0.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        arrangedSubviews.compactMap { $0 as? SettingsThemeApplying }.forEach { $0.applyTheme() }
    }
}

@MainActor
final class SettingsActionButton: NSButton, SettingsThemeApplying {
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { applyTheme() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .shadowlessSquare
        focusRingType = .none
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        contentTintColor = isHovering ? AppTheme.accent : AppTheme.secondaryText
        font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 600)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
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
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }
}

@MainActor
final class SettingsSkeletonValueView: NSView, SettingsThemeApplying {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = SettingsLayout.skeletonCornerRadius
        layer?.masksToBounds = true
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        layer?.backgroundColor = AppTheme.controlBackground.withAlphaComponent(0.72).cgColor
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
        minimumHeight: CGFloat = SettingsLayout.rowHeight
    ) {
        titleLabel = NSTextField(wrappingLabelWithString: title)
        helperLabel = NSTextField(wrappingLabelWithString: description)
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 0
        helperLabel.lineBreakMode = .byWordWrapping
        helperLabel.maximumNumberOfLines = 0
        self.control = control
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        [titleLabel, helperLabel, control].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(titleLabel)
        addSubview(helperLabel)
        addSubview(control)

        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        helperLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        let preferredHeight = heightAnchor.constraint(equalToConstant: minimumHeight)
        preferredHeight.priority = .init(rawValue: 999)
        var constraints = [
            heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight),
            preferredHeight,
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(
                equalTo: topAnchor,
                constant: SettingsLayout.blockVerticalPadding / 2
            ),
            titleLabel.trailingAnchor.constraint(
                equalTo: control.leadingAnchor,
                constant: -SettingsLayout.rowColumnGap
            ),
            titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: SettingsLayout.rowLabelMinimumWidth),
            helperLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            helperLabel.topAnchor.constraint(
                equalTo: titleLabel.bottomAnchor,
                constant: SettingsLayout.titleToDetailGap
            ),
            helperLabel.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor,
                constant: -(SettingsLayout.blockVerticalPadding / 2)
            ),
            helperLabel.trailingAnchor.constraint(
                equalTo: control.leadingAnchor,
                constant: -SettingsLayout.rowColumnGap
            ),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.topAnchor.constraint(
                equalTo: topAnchor,
                constant: SettingsLayout.blockVerticalPadding / 2
            ),
            control.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor,
                constant: -(SettingsLayout.blockVerticalPadding / 2)
            ),
        ]
        if let controlHeight {
            constraints.append(control.heightAnchor.constraint(equalToConstant: controlHeight))
        }
        if let controlWidth {
            constraints.append(control.widthAnchor.constraint(equalToConstant: controlWidth))
        } else {
            let preferredControlWidth = control.widthAnchor.constraint(
                equalToConstant: SettingsLayout.rowControlMaximumWidth
            )
            preferredControlWidth.priority = .defaultHigh
            constraints += [
                preferredControlWidth,
                control.widthAnchor.constraint(
                    lessThanOrEqualToConstant: SettingsLayout.rowControlMaximumWidth
                ),
                control.widthAnchor.constraint(greaterThanOrEqualToConstant: SettingsLayout.rowControlMinimumWidth),
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
        SettingsLayout.applyTitleStyle(titleLabel)
        SettingsLayout.applyDetailStyle(helperLabel)
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
        setContentCompressionResistancePriority(.required, for: .vertical)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        textColor = AppTheme.secondaryText
        font = SettingsLayout.valueFont
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
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsLayout.rowHeight),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsLayout.pageHorizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsLayout.pageHorizontalPadding),
            label.topAnchor.constraint(
                equalTo: topAnchor,
                constant: SettingsLayout.blockVerticalPadding / 2
            ),
            label.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -(SettingsLayout.blockVerticalPadding / 2)
            ),
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
        SettingsLayout.applyControlSurface(self, clipsContents: true)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        textColor = AppTheme.primaryText
        SettingsLayout.applyControlSurface(self, clipsContents: true)
        font = SettingsLayout.valueFont
        updateBorder()
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

@MainActor
final class SettingsPopupButton: NSPopUpButton, SettingsThemeApplying {
    init() {
        super.init(frame: .zero, pullsDown: false)
        isBordered = false
        bezelStyle = .shadowlessSquare
        focusRingType = .none
        controlSize = .large
        SettingsLayout.applyControlSurface(self, clipsContents: true)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        contentTintColor = AppTheme.primaryText
        font = SettingsLayout.valueFont
        SettingsLayout.applyControlSurface(self, clipsContents: true)
    }
}

private final class SettingsTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let rect = super.drawingRect(forBounds: rect)
        let height = min(cellSize.height, rect.height)
        return NSRect(
            x: rect.minX + SettingsLayout.controlHorizontalPadding,
            y: rect.minY + (rect.height - height) / 2,
            width: max(0, rect.width - SettingsLayout.controlHorizontalPadding * 2),
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
