import Foundation

enum ThemePreference: String, Codable, CaseIterable {
    case dark = "pinata-dark"
    case light = "pinata-light"
}

struct ThemePalette {
    let background: UInt32
    let chromeBackground: UInt32
    let surface: UInt32
    let controlBackground: UInt32
    let controlSelection: UInt32
    let border: UInt32
    let primaryText: UInt32
    let secondaryText: UInt32
    let tertiaryText: UInt32
    let terminalBackground: UInt32
    let terminalForeground: UInt32
}

extension ThemePreference {
    var palette: ThemePalette {
        switch self {
        case .dark:
            ThemePalette(
                background: 0x282C34,
                chromeBackground: 0x21252B,
                surface: 0x2C323C,
                controlBackground: 0x343B47,
                controlSelection: 0x252A33,
                border: 0x353A3C,
                primaryText: 0xFFFFFF,
                secondaryText: 0xB6BDC0,
                tertiaryText: 0xA6AEB2,
                terminalBackground: 0x282C34,
                terminalForeground: 0xFFFFFF
            )
        case .light:
            ThemePalette(
                background: 0xEEF1F3,
                chromeBackground: 0xE7EBEE,
                surface: 0xFFFFFF,
                controlBackground: 0xE5E9EC,
                controlSelection: 0xFFFFFF,
                border: 0xCCD1D6,
                primaryText: 0x1A1F23,
                secondaryText: 0x39424A,
                tertiaryText: 0x4A5259,
                terminalBackground: 0xEEF1F3,
                terminalForeground: 0x1A1F23
            )
        }
    }
}

enum AccentPreference: String, Codable, CaseIterable {
    case coral
    case teal
    case gold
    case magenta
    case lime
    case azure
    case mono
}

enum AccentIntensity: String, Codable, CaseIterable {
    case transparent
    case balanced
    case vibrant
}

enum AppFontSize: String, Codable, CaseIterable {
    case small
    case regular
    case large
}

enum TerminalFontSize: String, Codable, CaseIterable {
    case tiny
    case extraSmall
    case small
    case regular
    case large
    case extraLarge = "xl"
}

extension TerminalFontSize {
    var points: Float {
        switch self {
        case .tiny: 10
        case .extraSmall: 11
        case .small: 12
        case .regular: 13
        case .large: 14
        case .extraLarge: 15
        }
    }
}

struct UserSettings: Codable, Equatable {

    var theme: ThemePreference
    var accent: AccentPreference
    var accentIntensity: AccentIntensity
    var appFontSize: AppFontSize
    var terminalFontSize: TerminalFontSize

    static let defaults = UserSettings(
        theme: .dark,
        accent: .coral,
        accentIntensity: .balanced,
        appFontSize: .regular,
        terminalFontSize: .regular,
    )
}

extension UserSettings {
    private enum CodingKeys: String, CodingKey {
        case theme
        case accent
        case accentIntensity
        case appFontSize
        case terminalFontSize
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaults
        theme = (try? values.decode(ThemePreference.self, forKey: .theme)) ?? defaults.theme
        accent = (try? values.decode(AccentPreference.self, forKey: .accent)) ?? defaults.accent
        accentIntensity = (try? values.decode(AccentIntensity.self, forKey: .accentIntensity))
            ?? defaults.accentIntensity
        appFontSize = (try? values.decode(AppFontSize.self, forKey: .appFontSize))
            ?? defaults.appFontSize
        terminalFontSize = (try? values.decode(TerminalFontSize.self, forKey: .terminalFontSize))
            ?? defaults.terminalFontSize
    }
}

struct UserSettingsStore {
    private static let key = "pinata.settings.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> UserSettings {
        guard
            let data = defaults.data(forKey: Self.key),
            let settings = try? JSONDecoder().decode(UserSettings.self, from: data)
        else {
            return .defaults
        }
        return settings
    }

    func save(_ settings: UserSettings) throws {
        defaults.set(try JSONEncoder().encode(settings), forKey: Self.key)
    }
}
