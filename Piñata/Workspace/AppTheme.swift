import AppKit

@MainActor
enum AppTheme {
    static let titleBarHeight: CGFloat = 46
    static let leftPanelWidth: CGFloat = 264
    static let rightPanelWidth: CGFloat = 300
    static let leftPanelRange: ClosedRange<CGFloat> = 200...440
    static let rightPanelRange: ClosedRange<CGFloat> = 260...520

    static let background = NSColor(srgbRed: 0x1A / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1)
    static let chromeBackground = NSColor(srgbRed: 0x26 / 255, green: 0x2A / 255, blue: 0x2C / 255, alpha: 1)
    static let border = NSColor(srgbRed: 0x35 / 255, green: 0x3A / 255, blue: 0x3C / 255, alpha: 1)
    static let subtleBorder = NSColor(srgbRed: 0x2A / 255, green: 0x2F / 255, blue: 0x31 / 255, alpha: 1)
    static let primaryText = NSColor(srgbRed: 0xDF / 255, green: 0xE3 / 255, blue: 0xE5 / 255, alpha: 1)
    static let secondaryText = NSColor(srgbRed: 0xB6 / 255, green: 0xBD / 255, blue: 0xC0 / 255, alpha: 1)
    static let tertiaryText = NSColor(srgbRed: 0xA6 / 255, green: 0xAE / 255, blue: 0xB2 / 255, alpha: 1)
    static let accent = NSColor(srgbRed: 0xFF / 255, green: 0x74 / 255, blue: 0x6B / 255, alpha: 1)
}
