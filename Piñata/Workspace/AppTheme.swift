import AppKit
import CoreText

struct AppTypography {
    let body: CGFloat
    let label: CGFloat
    let settingsDisplay: CGFloat
    let settingsHeading: CGFloat
    let settingsBody: CGFloat
    let settingsLabel: CGFloat
}

@MainActor
enum AppTheme {
    static let titleBarHeight: CGFloat = 46
    static let leftPanelWidth: CGFloat = 264
    static let rightPanelWidth: CGFloat = 300
    static let leftPanelRange: ClosedRange<CGFloat> = 200...440
    static let rightPanelRange: ClosedRange<CGFloat> = 260...520

    static private(set) var background = color(0x282C34)
    static private(set) var chromeBackground = color(0x21252B)
    static private(set) var surface = color(0x2C323C)
    static private(set) var controlBackground = color(0x34393B)
    static private(set) var controlSelection = color(0x272C2E)
    static private(set) var border = color(0x353A3C)
    static private(set) var subtleBorder = color(0x2A2F31)
    static private(set) var primaryText = color(0xFFFFFF)
    static private(set) var secondaryText = color(0xB6BDC0)
    static private(set) var tertiaryText = color(0xA6AEB2)
    static private(set) var panelAccentIcon = color(0xFF746B)
    static private(set) var panelAccentBackground = color(0xFF746B).withAlphaComponent(0.14)
    static private(set) var panelToggleHoverText = color(0xB6BDC0)
    static private(set) var panelToggleHoverBackground = color(0x2F3335)
    static private(set) var typography = typography(for: AppFontSize.regular)
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
        surface = color(palette.surface)
        controlBackground = color(palette.controlBackground)
        controlSelection = color(palette.controlSelection)
        border = color(palette.border)
        subtleBorder = color(palette.subtleBorder)
        primaryText = color(palette.primaryText)
        secondaryText = color(palette.secondaryText)
        tertiaryText = color(palette.tertiaryText)

        let panelAccent = panelAccentColors(
            theme: settings.theme,
            accent: settings.accent,
            intensity: settings.accentIntensity
        )
        panelAccentIcon = panelAccent.icon
        panelAccentBackground = panelAccent.background
        panelToggleHoverText = color(settings.theme == .dark ? 0xB6BDC0 : 0x444D55)
        panelToggleHoverBackground = color(settings.theme == .dark ? 0x2F3335 : 0xDFE5E9)
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
                body: 12,
                label: 10.5,
                settingsDisplay: 23,
                settingsHeading: 12,
                settingsBody: 11.5,
                settingsLabel: 9.5
            )
        case .regular:
            AppTypography(
                body: 13,
                label: 11,
                settingsDisplay: 24,
                settingsHeading: 13,
                settingsBody: 12,
                settingsLabel: 10
            )
        case .large:
            AppTypography(
                body: 14,
                label: 12,
                settingsDisplay: 25,
                settingsHeading: 14,
                settingsBody: 13,
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

    private static func panelAccentColors(
        theme: ThemePreference,
        accent: AccentPreference,
        intensity: AccentIntensity
    ) -> (icon: NSColor, background: NSColor) {
        let primary = accentColor(for: accent)
        let alpha: CGFloat = switch intensity {
        case .transparent: 0
        case .balanced: theme == .dark ? 0.14 : 0.10
        case .vibrant: theme == .dark ? 0.80 : 0.72
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
