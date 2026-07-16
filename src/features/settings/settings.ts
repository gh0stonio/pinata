export type Theme = 'pinata-dark' | 'pinata-light'
export type Accent = 'coral' | 'teal' | 'gold' | 'magenta' | 'lime' | 'azure' | 'mono'
export type SettingsSection = 'appearance' | 'shortcuts'

export type AppSettings = {
  theme: Theme
  accent: Accent
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

export const shortcuts = [
  { keys: '⌘B', label: 'Toggle left side panel' },
  { keys: '⌘L', label: 'Toggle right side panel' },
  { keys: '⌘,', label: 'Open settings' },
  { keys: 'Esc', label: 'Close settings' },
]

export const defaultSettings: AppSettings = {
  theme: 'pinata-dark',
  accent: 'coral',
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
    }
  } catch {
    return { ...defaultSettings }
  }
}

export function saveSettings(next: AppSettings) {
  localStorage.setItem(settingsKey, JSON.stringify(next))
}
