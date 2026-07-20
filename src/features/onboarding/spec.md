# Onboarding

## Source

Based on v0 spec 01 and `reference/src/term-onboarding.jsx`.

## Current scope

- First-run overlay gated by `localStorage['pinata.onboarded.v1']`.
- Mounted as an exclusive startup screen after app-state bootstrap, so the empty app shell never
  flashes behind first-run setup.
- Onboarding starts from Settings defaults: Piñata Dark, Coral, Balanced.
- Four-step flow: Welcome, Appearance, Repositories, Done.
- Appearance writes the shared Settings object: `theme`, `accent`, and Piñata's added
  `accentIntensity`; accent selection reuses `src/components/accent-swatch-picker`.
- Accent intensity is surfaced during onboarding and disabled for Mono because Mono has fixed
  neutral strength.
- Theme previews use the selected accent intensity and show the app with the side panel closed.
- Primary onboarding actions use the same intensity-aware accent tokens as tinted app actions.
- Repository step starts empty, uses the native directory picker, validates the selected folder
  through Rust `inspect_repository`, immediately adds valid repos to the temporary list with
  fetched metadata, then persists them into `appState.repoRegistry` on finish.
- Repository setup is optional. Users can finish onboarding with zero repos and create a task that
  opens its home terminal in `~`.
- Added repository rows surface the repo name first, then git org when available, default branch,
  and local path.
- Done step can finish normally or open the New Task dialog.

## Deferred

- Command palette action to replay onboarding.
- Onboarding-specific repository branch override.
- Onboarding route for importing existing work from other tools.
