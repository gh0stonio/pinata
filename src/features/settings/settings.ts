export type Theme = 'pinata-dark' | 'pinata-light'
export type Accent = 'coral' | 'teal' | 'gold' | 'magenta' | 'lime' | 'azure' | 'mono'
export type AccentIntensity = 'transparent' | 'balanced' | 'vibrant'
export type SettingsSection = 'appearance' | 'shortcuts' | 'git'

export type AppSettings = {
  theme: Theme
  accent: Accent
  accentIntensity: AccentIntensity
}

export const settingsKey = 'pinata.settings.v1'

export const themes: Array<{ id: Theme; name: string }> = [
  { id: 'pinata-dark', name: 'Piñata Dark' },
  { id: 'pinata-light', name: 'Piñata Light' },
]

export const accents: Array<{ id: Accent; name: string }> = [
  { id: 'coral', name: 'Coral' },
  { id: 'teal', name: 'Teal' },
  { id: 'gold', name: 'Gold' },
  { id: 'magenta', name: 'Magenta' },
  { id: 'lime', name: 'Lime' },
  { id: 'azure', name: 'Azure' },
  { id: 'mono', name: 'Mono' },
]

export const accentIntensities: Array<{ id: AccentIntensity; name: string }> = [
  { id: 'transparent', name: 'Transparent' },
  { id: 'balanced', name: 'Balanced' },
  { id: 'vibrant', name: 'Vibrant' },
]

export const shortcuts = [
  { keys: '⌘B', label: 'Toggle left side panel' },
  { keys: '⌘L', label: 'Toggle right side panel' },
  { keys: '⌘,', label: 'Open settings' },
]

export const defaultSettings: AppSettings = {
  theme: 'pinata-dark',
  accent: 'coral',
  accentIntensity: 'balanced',
}

function pickSetting<T extends string>(value: unknown, allowed: readonly T[], fallback: T): T {
  return typeof value === 'string' && allowed.includes(value as T) ? (value as T) : fallback
}

export function loadSettings(): AppSettings {
  try {
    const stored = JSON.parse(localStorage.getItem(settingsKey) ?? '{}') as Partial<AppSettings>

    return {
      theme: pickSetting(
        stored.theme,
        themes.map((theme) => theme.id),
        defaultSettings.theme,
      ),
      accent: pickSetting(
        stored.accent,
        accents.map((accent) => accent.id),
        defaultSettings.accent,
      ),
      accentIntensity: pickSetting(
        stored.accentIntensity,
        accentIntensities.map((intensity) => intensity.id),
        defaultSettings.accentIntensity,
      ),
    }
  } catch {
    return { ...defaultSettings }
  }
}

export function saveSettings(next: AppSettings) {
  localStorage.setItem(settingsKey, JSON.stringify(next))
}
