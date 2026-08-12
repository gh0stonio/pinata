import AppKit
import CoreText

struct AppTypography {
    let title: CGFloat
    let body: CGFloat
    let label: CGFloat
    let settingsHeading: CGFloat
    let settingsBody: CGFloat
    let settingsValue: CGFloat
    let settingsLabel: CGFloat
}

enum AppButtonRole {
    case accent
    case naked
    case chrome
    case icon
    case accentIcon
    case hitTarget
    case link
    case segmented
    case workspacePanelTab
    case swatch(NSColor)
}

struct AppButtonAppearance {
    let background: NSColor
    let foreground: NSColor
    let border: NSColor
    let borderWidth: CGFloat
}

@MainActor
enum AppTheme {
    static let leftPanelWidth: CGFloat = 264
    static let rightPanelWidth: CGFloat = 304
    static let settingsRailWidth: CGFloat = 260
    static let panelContentInset: CGFloat = 14
    static let fullScreenSidebarWidth: CGFloat = 320
    static let leftPanelRange: ClosedRange<CGFloat> = 200...440
    static let workspaceHeaderHeight: CGFloat = 36
    static let mainHeaderHeight: CGFloat = 44
    static let workspaceContentInset: CGFloat = 10
    static let paneHeaderHeight: CGFloat = 34
    static let workspaceInset: CGFloat = 8
    static let terminalContentInset: CGFloat = 10
    static let terminalVerticalInset: CGFloat = 2
    static let workspaceCornerRadius: CGFloat = 10
    static let minimumCenterWidth: CGFloat = 480
    static var minimumWindowWidth: CGFloat {
        leftPanelWidth
            + workspaceInset * 2
            + settingsRailWidth
            + SettingsLayout.dividerThickness
            + SettingsLayout.minimumPageWidth
    }
    static let minimumWindowHeight: CGFloat = 600
    static let defaultWindowHeight: CGFloat = 640
    static let resizeHandleWidth: CGFloat = 10
    static let keyboardResizeStep: CGFloat = 12
    static let sidebarSectionSpacing: CGFloat = 22
    static let sidebarBrandSize: CGFloat = 34
    static let sidebarToggleLeading: CGFloat = 82
    static let fullScreenSidebarToggleLeading: CGFloat = 12
    static var sidebarNewTaskIconSize: CGFloat { typography.body + 5 }
    static let sidebarNewTaskHeight: CGFloat = 38
    static let sidebarNewTaskTopSpacing: CGFloat = 20
    static let sidebarNewTaskBottomSpacing: CGFloat = sidebarSectionSpacing
    static let sidebarTaskListTopSpacing: CGFloat = 8
    static let sidebarSectionTitleInset: CGFloat = 28
    static let sidebarItemInset: CGFloat = 10
    static let sidebarTaskRowHeight: CGFloat = 29
    static let sidebarDisclosureSymbolSize: CGFloat = 8
    static let sidebarDisclosureLeadingInset: CGFloat = 2
    static let sidebarDisclosureControlWidth: CGFloat = 18
    static let sidebarDisclosureControlHeight: CGFloat = 22
    static let sidebarTaskTitleDisclosureInset: CGFloat = 22
    static let sidebarRepositoryTitleInset: CGFloat = 26
    static let taskModalCardWidth: CGFloat = 522
    static let taskModalPadding: CGFloat = 16
    static let taskModalFieldHeight: CGFloat = 40
    static let taskModalButtonHeight: CGFloat = 32
    static let taskModalCancelButtonMinimumWidth: CGFloat = 64
    static let taskModalCreateButtonMinimumWidth: CGFloat = 96
    static let taskModalButtonHorizontalPadding: CGFloat = 24
    static let taskModalButtonImageGap: CGFloat = 6
    static let taskModalButtonSpacing: CGFloat = 12
    static let taskModalButtonCornerRadius: CGFloat = 7
    static let taskModalRowHeight: CGFloat = 35
    static let taskModalEmptyRepositoryHeight: CGFloat = 82
    static let taskModalMaximumVisibleRepositories = 6
    static let taskModalListCornerRadius: CGFloat = 8
    static let taskModalContentGap: CGFloat = 8
    static let taskModalHelperGap: CGFloat = 6
    static let taskModalRepositoryBlockGap: CGFloat = 16
    static let taskModalRepositoryListGap: CGFloat = 8
    static let taskModalNoteGap: CGFloat = 12
    static let taskModalDividerTopSpacing: CGFloat = 16
    static let taskModalFooterControlSpacing: CGFloat = 9
    static let taskModalFooterBottomInset: CGFloat = 10
    static let taskModalRowHorizontalInset: CGFloat = 12
    static let taskModalRowContentGap: CGFloat = 10
    static let taskModalCheckboxSize: CGFloat = 14
    static let taskModalRepositoryIconSize: CGFloat = 13
    static let taskModalEmptyIconSize: CGFloat = 16
    static let taskModalEmptyIconTopInset: CGFloat = 16
    static let taskModalEmptyMessageGap: CGFloat = 10
    static let workspaceTabHeight: CGFloat = 26
    static let workspaceTabSpacing: CGFloat = 4
    static let workspaceTabHorizontalInset: CGFloat = 10
    static let workspaceTabContentGap: CGFloat = 6
    static let workspaceTabAccessoryGap: CGFloat = 8
    static let workspaceTabIconWidth: CGFloat = 18
    static let workspaceTabIconHeight: CGFloat = 16
    static let workspaceTabIconSymbolSize: CGFloat = 13
    static let workspaceControlGap: CGFloat = 2
    static let workspaceControlCornerRadius: CGFloat = 6
    static let workspaceDividerThickness: CGFloat = 1
    static let workspaceTabCloseInset: CGFloat = 10
    static let workspaceTabCloseHoverSize: CGFloat = 18
    static let workspaceTabCloseHoverCornerRadius: CGFloat = 4
    static var workspaceTabNeutralCloseHoverBackground: NSColor {
        primaryText.withAlphaComponent(0.12)
    }
    static let workspaceTabMinimumWidth: CGFloat = 82
    static let workspaceTabMaximumWidth: CGFloat = 180
    static let workspaceNewTabSymbolSize: CGFloat = 12
    static let workspaceTabCloseSymbolSize: CGFloat = 10
    static let panelToggleControlSize: CGFloat = 28
    static let workspacePanelHeaderInset: CGFloat = 14
    static let symbolVerticalAdjustment: CGFloat = 2
    static let paneMinimumSize: CGFloat = 80
    static let paneHeaderIconWidth: CGFloat = 18
    static let paneHeaderIconHeight: CGFloat = 14
    static let paneHeaderIconPointSize: CGFloat = 14
    static let paneHeaderContentGap: CGFloat = 6
    static let paneHeaderTrailingInset: CGFloat = 4
    static let paneHeaderActionGap: CGFloat = 2
    static let paneHeaderActionSize: CGFloat = 22
    static let splitHitSlop: CGFloat = 4
    static let inactivePaneAlpha: CGFloat = 0.82
    static let inactivePaneHeaderAlpha: CGFloat = 0.7
    static let sidebarToggleVerticalOffset: CGFloat = 1
    static let resizeIndicatorWidth: CGFloat = 2
    static let resizeIndicatorHeightRatio: CGFloat = 0.15
    static let resizeIndicatorCornerRadius: CGFloat = 1
    static let trafficLightVerticalOffset: CGFloat = 3

    static private(set) var background = color(0x282C34)
    static private(set) var chromeBackground = color(0x21252B)
    static private(set) var chromeHoverBackground = color(0x2C3036)
    static private(set) var surface = color(0x2C323C)
    static private(set) var controlBackground = color(0x34393B)
    static private(set) var controlSelection = color(0x272C2E)
    static private(set) var border = color(0x353A3C)
    static private(set) var primaryText = color(0xD9D9D9)
    static private(set) var secondaryText = color(0xB6BDC0)
    static private(set) var tertiaryText = color(0xA6AEB2)
    static private(set) var error = color(0xF25555)
    static private(set) var success = color(0x31C971)
    static private(set) var accent = color(0xFF746B)
    static private(set) var panelAccentIcon = color(0xFF746B)
    static private(set) var panelAccentBackground = color(0xFF746B).withAlphaComponent(0.14)
    static private(set) var panelAccentHoverIcon = color(0xFF746B)
    static private(set) var panelAccentHoverBackground = color(0xFF746B).withAlphaComponent(0.24)
    static private(set) var typography = typography(for: AppFontSize.regular)

    static var interactiveHoverForeground: NSColor { primaryText }
    static var interactiveHoverBackground: NSColor { controlBackground }
    static var taskModalInputBackground: NSColor { controlSelection }
    static var taskModalOverlayBackground: NSColor { .black.withAlphaComponent(0.52) }

    static var separator: NSColor {
        tertiaryText.withAlphaComponent(0.28)
    }
    private static let spaceGroteskRegistered: Bool = {
        guard
            let url = Bundle.main.url(
                forResource: "SpaceGrotesk-VariableFont_wght",
                withExtension: "ttf"
            )
        else {
            return false
        }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    static func configure(_ settings: UserSettings) {
        let palette = settings.theme.palette
        background = color(palette.background)
        chromeBackground = color(palette.chromeBackground)
        chromeHoverBackground = color(palette.chromeHoverBackground)
        surface = color(palette.surface)
        controlBackground = color(palette.controlBackground)
        controlSelection = color(palette.controlSelection)
        border = color(palette.border)
        primaryText = color(palette.primaryText)
        secondaryText = color(palette.secondaryText)
        tertiaryText = color(palette.tertiaryText)
        error = color(settings.theme == .dark ? 0xF25555 : 0xBC2C2C)
        success = color(settings.theme == .dark ? 0x31C971 : 0x208A4F)

        accent = accentColor(for: settings.accent)
        let panelAccent = panelAccentColors(
            theme: settings.theme,
            accent: settings.accent,
            intensity: settings.accentIntensity
        )
        panelAccentIcon = panelAccent.icon
        panelAccentBackground = panelAccent.background
        let panelAccentHover = panelAccentColors(
            theme: settings.theme,
            accent: settings.accent,
            intensity: settings.accentIntensity,
            hovered: true
        )
        panelAccentHoverIcon = panelAccentHover.icon
        panelAccentHoverBackground = panelAccentHover.background
        typography = typography(for: settings.appFontSize)
    }

    static func font(ofSize size: CGFloat, weight: CGFloat = 400) -> NSFont {
        guard spaceGroteskRegistered else {
            return .systemFont(ofSize: size, weight: systemWeight(for: weight))
        }
        let descriptor = NSFontDescriptor(
            name: "SpaceGrotesk-Light",
            size: size
        ).addingAttributes([
            .variation: [
                NSNumber(value: 0x77676874): NSNumber(value: weight)
            ]
        ])
        return NSFont(descriptor: descriptor, size: size)
            ?? .systemFont(ofSize: size, weight: systemWeight(for: weight))
    }

    private static func systemWeight(for weight: CGFloat) -> NSFont.Weight {
        switch weight {
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        default: .bold
        }
    }

    private static func typography(for size: AppFontSize) -> AppTypography {
        switch size {
        case .small:
            AppTypography(
                title: 16.5,
                body: 12,
                label: 10.5,
                settingsHeading: 12,
                settingsBody: 11.5,
                settingsValue: 10.5,
                settingsLabel: 9.5
            )
        case .regular:
            AppTypography(
                title: 17.5,
                body: 13,
                label: 11,
                settingsHeading: 13,
                settingsBody: 12,
                settingsValue: 11,
                settingsLabel: 10
            )
        case .large:
            AppTypography(
                title: 18.5,
                body: 14,
                label: 12,
                settingsHeading: 14,
                settingsBody: 13,
                settingsValue: 12,
                settingsLabel: 10.5
            )
        }
    }

    static func accentColor(for accent: AccentPreference) -> NSColor {
        switch accent {
        case .coral: color(0xFF746B)
        case .teal: color(0x20D6C9)
        case .gold: color(0xFFD447)
        case .magenta: color(0xFF62B4)
        case .lime: color(0xA7EA45)
        case .azure: color(0x4D9DFF)
        case .mono: primaryText
        }
    }

    static func accentForegroundColor(for accent: AccentPreference) -> NSColor {
        accessibleNeutralIcon(against: accentColor(for: accent))
    }

    static func buttonAppearance(
        role: AppButtonRole,
        hovered: Bool,
        enabled: Bool = true,
        selected: Bool = false
    ) -> AppButtonAppearance {
        guard enabled else {
            let background: NSColor = switch role {
            case .accent: controlBackground
            default: .clear
            }
            return AppButtonAppearance(
                background: background,
                foreground: tertiaryText,
                border: .clear,
                borderWidth: 0
            )
        }

        switch role {
        case .accent:
            let foreground = panelAccentIcon
            return AppButtonAppearance(
                background: panelAccentBackground,
                foreground: foreground,
                border: foreground.withAlphaComponent(0.55),
                borderWidth: 1
            )
        case .naked:
            return AppButtonAppearance(
                background: hovered ? interactiveHoverBackground : .clear,
                foreground: hovered ? interactiveHoverForeground : secondaryText,
                border: .clear,
                borderWidth: 0
            )
        case .chrome:
            return AppButtonAppearance(
                background: hovered ? chromeHoverBackground : .clear,
                foreground: hovered ? interactiveHoverForeground : secondaryText,
                border: .clear,
                borderWidth: 0
            )
        case .icon:
            return AppButtonAppearance(
                background: hovered ? interactiveHoverBackground : .clear,
                foreground: hovered ? interactiveHoverForeground : tertiaryText,
                border: .clear,
                borderWidth: 0
            )
        case .accentIcon:
            return AppButtonAppearance(
                background: hovered ? panelAccentHoverBackground : .clear,
                foreground: hovered ? panelAccentHoverIcon : panelAccentIcon,
                border: .clear,
                borderWidth: 0
            )
        case .hitTarget:
            return AppButtonAppearance(
                background: .clear,
                foreground: hovered ? interactiveHoverForeground : tertiaryText,
                border: .clear,
                borderWidth: 0
            )
        case .link:
            return AppButtonAppearance(
                background: .clear,
                foreground: hovered ? panelAccentIcon : secondaryText,
                border: .clear,
                borderWidth: 0
            )
        case .segmented:
            return AppButtonAppearance(
                background: selected
                    ? controlSelection
                    : hovered ? interactiveHoverBackground : .clear,
                foreground: selected || hovered ? interactiveHoverForeground : secondaryText,
                border: .clear,
                borderWidth: 0
            )
        case .workspacePanelTab:
            return AppButtonAppearance(
                background: selected ? controlSelection : .clear,
                foreground: selected || hovered ? primaryText : secondaryText,
                border: selected ? border : .clear,
                borderWidth: selected ? 1 : 0
            )
        case let .swatch(color):
            return AppButtonAppearance(
                background: color,
                foreground: accessibleNeutralIcon(against: color),
                border: hovered ? primaryText.withAlphaComponent(0.72) : .clear,
                borderWidth: hovered ? 2 : 0
            )
        }
    }

    static func renderedBackground(_ background: NSColor) -> NSColor {
        composited(background, over: chromeBackground)
    }

    private static func panelAccentColors(
        theme: ThemePreference,
        accent: AccentPreference,
        intensity: AccentIntensity,
        hovered: Bool = false
    ) -> (icon: NSColor, background: NSColor) {
        let primary = accentColor(for: accent)
        let alpha: CGFloat = switch intensity {
        case .transparent: hovered ? (theme == .dark ? 0.08 : 0.06) : 0
        case .balanced: hovered ? (theme == .dark ? 0.24 : 0.18) : (theme == .dark ? 0.14 : 0.10)
        case .vibrant: hovered ? (theme == .dark ? 0.92 : 0.86) : (theme == .dark ? 0.80 : 0.72)
        }
        let background = primary.withAlphaComponent(alpha)

        let renderedBackground = composited(background, over: chromeBackground)
        if intensity != .vibrant {
            return (
                contrastAdjusted(primary, against: renderedBackground, minimumRatio: 4.5),
                background
            )
        }

        return (accessibleNeutralIcon(against: renderedBackground), background)
    }

    private static func contrastAdjusted(
        _ foreground: NSColor,
        against background: NSColor,
        minimumRatio: CGFloat
    ) -> NSColor {
        guard contrastRatio(foreground, background) < minimumRatio else {
            return foreground
        }

        let target = highestContrastIcon(against: background)
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        for _ in 0..<16 {
            let midpoint = (lower + upper) / 2
            if contrastRatio(blend(foreground, with: target, amount: midpoint), background)
                >= minimumRatio
            {
                upper = midpoint
            } else {
                lower = midpoint
            }
        }
        return blend(foreground, with: target, amount: upper)
    }

    private static func highestContrastIcon(against background: NSColor) -> NSColor {
        let dark = color(0x1A1F23)
        let light = color(0xFFFFFF)
        return contrastRatio(dark, background) >= contrastRatio(light, background) ? dark : light
    }
    private static func accessibleNeutralIcon(against background: NSColor) -> NSColor {
        let preferred = highestContrastIcon(against: background)
        guard contrastRatio(preferred, background) < 4.5 else {
            return preferred
        }

        let black = color(0x000000)
        let white = color(0xFFFFFF)
        return contrastRatio(black, background) >= contrastRatio(white, background) ? black : white
    }

    private static func composited(_ foreground: NSColor, over background: NSColor) -> NSColor {
        let foreground = srgbComponents(foreground)
        let background = srgbComponents(background)
        let inverseAlpha = 1 - foreground.alpha
        return NSColor(
            srgbRed: foreground.red * foreground.alpha + background.red * inverseAlpha,
            green: foreground.green * foreground.alpha + background.green * inverseAlpha,
            blue: foreground.blue * foreground.alpha + background.blue * inverseAlpha,
            alpha: 1
        )
    }

    private static func blend(_ start: NSColor, with end: NSColor, amount: CGFloat) -> NSColor {
        let start = srgbComponents(start)
        let end = srgbComponents(end)
        let inverseAmount = 1 - amount
        return NSColor(
            srgbRed: start.red * inverseAmount + end.red * amount,
            green: start.green * inverseAmount + end.green * amount,
            blue: start.blue * inverseAmount + end.blue * amount,
            alpha: 1
        )
    }

    private static func contrastRatio(_ first: NSColor, _ second: NSColor) -> CGFloat {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        let lighter = max(firstLuminance, secondLuminance)
        let darker = min(firstLuminance, secondLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ color: NSColor) -> CGFloat {
        let components = srgbComponents(color)
        func linearize(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(components.red)
            + 0.7152 * linearize(components.green)
            + 0.0722 * linearize(components.blue)
    }

    private static func srgbComponents(
        _ color: NSColor
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        guard let color = color.usingColorSpace(.sRGB) else {
            preconditionFailure("App theme colors must use the sRGB color space")
        }
        return (color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent)
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

@MainActor
class AppHoverView: NSView {
    private var trackingAreaReference: NSTrackingArea?
    private(set) var isHovering = false

    func hoverStateDidChange() {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
        updateHoverStateForCurrentPointer()
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    func refreshHoverState() {
        updateHoverStateForCurrentPointer()
    }

    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        hoverStateDidChange()
    }

    private func updateHoverStateForCurrentPointer() {
        guard let window else {
            setHovering(false)
            return
        }
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        setHovering(bounds.contains(convert(pointInWindow, from: nil)))
    }
}

@MainActor
class AppButton: NSButton {
    var usesAutomaticHoverTracking: Bool { true }

    var role: AppButtonRole = .naked {
        didSet { applyTheme() }
    }
    var isVisuallySelected = false {
        didSet { applyTheme() }
    }
    override var isEnabled: Bool {
        didSet { applyTheme() }
    }

    private var trackingAreaReference: NSTrackingArea?
    private(set) var isHovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    init(role: AppButtonRole) {
        self.role = role
        super.init(frame: .zero)
        configure()
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

    func applyTheme() {
        applyAppearance(role: role)
    }

    func applyAppearance(role: AppButtonRole) {
        let appearance = AppTheme.buttonAppearance(
            role: role,
            hovered: isHovering,
            enabled: isEnabled,
            selected: isVisuallySelected
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = appearance.background.cgColor
        layer?.borderColor = appearance.border.cgColor
        layer?.borderWidth = appearance.borderWidth
        CATransaction.commit()
        contentTintColor = appearance.foreground
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        guard usesAutomaticHoverTracking else {
            trackingAreaReference = nil
            return
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func mouseMoved(with event: NSEvent) {
        setHovering(true)
    }

    func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        applyTheme()
    }

    private func configure() {
        wantsLayer = true
        title = ""
        isBordered = false
        bezelStyle = .shadowlessSquare
        focusRingType = .none
        applyTheme()
    }
}
