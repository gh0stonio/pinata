import AppKit

@MainActor
enum SettingsLayout {
    static let rightColumnWidth: CGFloat = 330
    static let rowControlMaximumWidth: CGFloat = rightColumnWidth
    static let sectionGap: CGFloat = 20
    static let pageHorizontalPadding: CGFloat = 44
    static let pageVerticalPadding: CGFloat = 35
    static let pageBottomPadding: CGFloat = pageVerticalPadding
    static let detailPageTopPadding: CGFloat = 16
    static let twoColumnLabelMinimumWidth: CGFloat = 160
    static let blockVerticalPadding: CGFloat = 20
    static let sectionHeaderTopPadding: CGFloat = 8
    static let sectionHeaderBottomPadding: CGFloat = 4
    static let sectionHeaderContentGap: CGFloat = 2
    static let rowVerticalPadding: CGFloat = 8
    static let titleToDetailGap: CGFloat = 5
    static let rowToControlGap: CGFloat = 10
    static let rowColumnGap: CGFloat = 24
    static let rowHeight: CGFloat = 52
    static let rowGap: CGFloat = 2
    static let controlHeight: CGFloat = 32
    static let controlCornerRadius: CGFloat = 6
    static let choiceInset: CGFloat = 2
    static let choiceCornerRadius: CGFloat = 4
    static let colorChoiceDiameter: CGFloat = 24
    static let colorChoiceGap: CGFloat = 7
    static let stepperButtonWidth: CGFloat = 24
    static let navigationCornerRadius: CGFloat = 7
    static let compactRowHeight: CGFloat = 40
    static let compactRowCornerRadius: CGFloat = 8
    static let compactContentInset: CGFloat = 10
    static let compactIconSize: CGFloat = 13
    static let compactMetadataGap: CGFloat = 16
    static let compactChevronWidth: CGFloat = 10
    static let compactChevronHeight: CGFloat = 14
    static let navigationRowHeight: CGFloat = 28
    static let navigationRowGap: CGFloat = 2
    static let navigationIconSize: CGFloat = 18
    static let navigationItemGap: CGFloat = 12
    static let navigationLabelGap: CGFloat = 8
    static let navigationSectionGap: CGFloat = 24
    static let dividerThickness: CGFloat = 1
    static let skeletonHeight: CGFloat = 14
    static let skeletonCornerRadius: CGFloat = 4
    static let controlHorizontalPadding: CGFloat = 10
    static let breadcrumbHeight: CGFloat = 24
    static let detailHeaderTopPadding: CGFloat = 18
    static let breadcrumbGap: CGFloat = 6
    static let breadcrumbBackOffset: CGFloat = 16
    static let breadcrumbToContentGap: CGFloat = 2
    static let themeControlWidth: CGFloat = 122
    static let intensityControlWidth: CGFloat = 272
    static let appFontControlWidth: CGFloat = 180
    static let terminalFontControlWidth: CGFloat = 82
    static let repositoryPathControlWidth: CGFloat = rightColumnWidth
    static let choiceHorizontalPadding: CGFloat = 18
    static let accentCheckmarkSize: CGFloat = 15

    static var minimumTwoColumnContentWidth: CGFloat {
        repositoryPathControlWidth + rowColumnGap + twoColumnLabelMinimumWidth
    }

    static var minimumPageWidth: CGFloat {
        minimumTwoColumnContentWidth + pageHorizontalPadding * 2
    }

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

    static func applyGroupTitleStyle(_ label: NSTextField) {
        label.attributedStringValue = NSAttributedString(
            string: label.stringValue,
            attributes: [
                .font: AppTheme.font(ofSize: AppTheme.typography.label + 0.5, weight: 600),
                .foregroundColor: AppTheme.tertiaryText.withAlphaComponent(0.6),
                .kern: 0.6,
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
    private let sectionStack = NSStackView()
    private let topPadding: CGFloat

    var contentLeadingAnchor: NSLayoutXAxisAnchor { sectionStack.leadingAnchor }

    init(
        frame frameRect: NSRect = .zero,
        topPadding: CGFloat = SettingsLayout.pageVerticalPadding
    ) {
        self.topPadding = topPadding
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        installLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func addSection(
        title: String,
        detail: String,
        content: NSView,
        isDestructive: Bool = false
    ) {
        let header = SettingsSectionHeader(
            title: title,
            detail: detail,
            isDestructive: isDestructive
        )
        let section = SettingsSectionView(header: header, content: content)
        sectionStack.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: sectionStack.widthAnchor).isActive = true
        needsLayout = true
    }

    func scrollToTop() {
        layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func showVerticalScroller() {
        scrollView.autohidesScrollers = false
    }

    func applyTheme() {
        scrollView.drawsBackground = false
        document.layer?.backgroundColor = AppTheme.background.cgColor
        sectionStack.arrangedSubviews.compactMap { $0 as? SettingsThemeApplying }.forEach { $0.applyTheme() }
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
        document.translatesAutoresizingMaskIntoConstraints = false
        document.wantsLayer = true
        sectionStack.translatesAutoresizingMaskIntoConstraints = false
        sectionStack.orientation = .vertical
        sectionStack.alignment = .leading
        sectionStack.spacing = SettingsLayout.sectionGap
        document.addSubview(sectionStack)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor),
            document.widthAnchor.constraint(greaterThanOrEqualToConstant: SettingsLayout.minimumPageWidth),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            sectionStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: document.leadingAnchor,
                constant: SettingsLayout.pageHorizontalPadding
            ),
            sectionStack.trailingAnchor.constraint(
                lessThanOrEqualTo: document.trailingAnchor,
                constant: -SettingsLayout.pageHorizontalPadding
            ),
            sectionStack.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            sectionStack.topAnchor.constraint(
                equalTo: document.topAnchor,
                constant: topPadding
            ),
            document.bottomAnchor.constraint(
                greaterThanOrEqualTo: sectionStack.bottomAnchor,
                constant: SettingsLayout.pageBottomPadding
            ),
        ])
        let fillsAvailableWidth = sectionStack.widthAnchor.constraint(
            equalTo: document.widthAnchor,
            constant: -SettingsLayout.pageHorizontalPadding * 2
        )
        fillsAvailableWidth.priority = .defaultHigh
        fillsAvailableWidth.isActive = true
        let viewportWidth = document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        viewportWidth.priority = .init(rawValue: 999)
        viewportWidth.isActive = true
        applyTheme()
    }
}

@MainActor
private final class SettingsSectionView: NSView, SettingsThemeApplying {
    private let header: SettingsSectionHeader
    private let content: NSView

    init(header: SettingsSectionHeader, content: NSView) {
        self.header = header
        self.content = content
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(content)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(
                equalTo: header.bottomAnchor,
                constant: SettingsLayout.sectionHeaderContentGap
            ),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        header.applyTheme()
        (content as? SettingsThemeApplying)?.applyTheme()
    }
}

@MainActor
private final class SettingsSectionHeader: NSView, SettingsThemeApplying {
    private let titleLabel: NSTextField
    private let rule: SettingsDivider
    private let isDestructive: Bool

    init(title: String, detail _: String, isDestructive: Bool = false) {
        titleLabel = NSTextField(labelWithString: title.uppercased())
        rule = SettingsDivider()
        self.isDestructive = isDestructive
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        [titleLabel, rule].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(
                equalTo: topAnchor,
                constant: SettingsLayout.sectionHeaderTopPadding
            ),
            titleLabel.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -SettingsLayout.sectionHeaderBottomPadding
            ),
            rule.leadingAnchor.constraint(
                equalTo: titleLabel.trailingAnchor,
                constant: SettingsLayout.navigationLabelGap
            ),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func applyTheme() {
        if isDestructive {
            titleLabel.attributedStringValue = NSAttributedString(
                string: titleLabel.stringValue,
                attributes: [
                    .font: AppTheme.font(ofSize: AppTheme.typography.label + 0.5, weight: 600),
                    .foregroundColor: AppTheme.error.withAlphaComponent(0.8),
                    .kern: 0.6,
                ]
            )
        } else {
            SettingsLayout.applyGroupTitleStyle(titleLabel)
        }
        rule.applyTheme()
    }
}

@MainActor
private final class SettingsDivider: NSView, SettingsThemeApplying {
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
func settingsRowStack(_ rows: [SettingsRowView]) -> NSStackView {
    SettingsRowStack(rows: rows)
}

private final class SettingsRowStack: NSStackView, SettingsThemeApplying {
    init(rows: [SettingsRowView]) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = SettingsLayout.rowGap
        for row in rows {
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
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
final class SettingsActionButton: AppButton, SettingsThemeApplying {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        role = .link
        applyTheme()
    }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func applyTheme() {
        super.applyTheme()
        font = AppTheme.font(ofSize: AppTheme.typography.settingsHeading, weight: 600)
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
        var sharedConstraints = [
            heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight),
            preferredHeight,
        ]
        if let controlHeight {
            sharedConstraints.append(control.heightAnchor.constraint(equalToConstant: controlHeight))
        }
        let maximumControlWidth = controlWidth ?? SettingsLayout.rowControlMaximumWidth
        let preferredControlWidth = control.widthAnchor.constraint(
            equalToConstant: maximumControlWidth
        )
        preferredControlWidth.priority = .defaultHigh
        sharedConstraints += [
            preferredControlWidth,
            control.widthAnchor.constraint(lessThanOrEqualToConstant: maximumControlWidth),
        ]
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let rowConstraints = [
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(
                equalTo: topAnchor,
                constant: SettingsLayout.rowVerticalPadding
            ),
            titleLabel.trailingAnchor.constraint(
                equalTo: control.leadingAnchor,
                constant: -SettingsLayout.rowColumnGap
            ),
            helperLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            helperLabel.topAnchor.constraint(
                equalTo: titleLabel.bottomAnchor,
                constant: SettingsLayout.titleToDetailGap
            ),
            helperLabel.trailingAnchor.constraint(
                equalTo: control.leadingAnchor,
                constant: -SettingsLayout.rowColumnGap
            ),
            helperLabel.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor,
                constant: -SettingsLayout.rowVerticalPadding
            ),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.topAnchor.constraint(
                greaterThanOrEqualTo: topAnchor,
                constant: SettingsLayout.rowVerticalPadding
            ),
            control.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor,
                constant: -SettingsLayout.rowVerticalPadding
            ),
        ]
        NSLayoutConstraint.activate(sharedConstraints + rowConstraints)
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
        lineBreakMode = .byCharWrapping
        maximumNumberOfLines = 0
        alignment = .left
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
        let preferredHeight = heightAnchor.constraint(equalToConstant: SettingsLayout.rowHeight)
        preferredHeight.priority = .init(rawValue: 999)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsLayout.rowHeight),
            preferredHeight,
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
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

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            isEditing = true
            updateBorder()
        }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        isEditing = true
        updateBorder()
        super.mouseDown(with: event)
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
