import type { Accent, AccentIntensity, Theme } from '../settings/settings'

export const onboardingKey = 'pinata.onboarded.v1'

export const onboardingStripeColors = [
  'var(--color-swatch-coral)',
  'var(--color-swatch-teal)',
  'var(--color-swatch-gold)',
  'var(--color-swatch-magenta)',
  'var(--color-swatch-lime)',
  'var(--color-swatch-azure)',
]

export type OnboardingAccentOption = {
  id: Accent
  name: string
  color: string
  check: string
}

export const onboardingAccentOptions: OnboardingAccentOption[] = [
  {
    id: 'coral',
    name: 'Coral',
    color: 'var(--color-swatch-coral)',
    check: 'var(--color-swatch-check-dark)',
  },
  {
    id: 'teal',
    name: 'Teal',
    color: 'var(--color-swatch-teal)',
    check: 'var(--color-swatch-check-dark)',
  },
  {
    id: 'gold',
    name: 'Gold',
    color: 'var(--color-swatch-gold)',
    check: 'var(--color-swatch-check-dark)',
  },
  {
    id: 'magenta',
    name: 'Magenta',
    color: 'var(--color-swatch-magenta)',
    check: 'var(--color-swatch-check-dark)',
  },
  {
    id: 'lime',
    name: 'Lime',
    color: 'var(--color-swatch-lime)',
    check: 'var(--color-swatch-check-dark)',
  },
  {
    id: 'azure',
    name: 'Azure',
    color: 'var(--color-swatch-azure)',
    check: 'var(--color-swatch-check-light)',
  },
  {
    id: 'mono',
    name: 'Mono',
    color: 'var(--color-text-primary)',
    check: 'var(--color-background)',
  },
]

export const onboardingThemeLabels: Record<Theme, string> = {
  'pinata-dark': 'Piñata Dark',
  'pinata-light': 'Piñata Light',
}

export const onboardingIntensityLabels: Record<AccentIntensity, string> = {
  transparent: 'Transparent',
  balanced: 'Balanced',
  vibrant: 'Vibrant',
}
