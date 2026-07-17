# Spec 14 - Settings

> Prerequisite: read `APP.md`. Reference: `reference/src/term-settings.jsx`.

## Dependencies & links
- **Depends on:**
  - **Spec 02** - opened by the native macOS app menu Settings item or ⌘,; a full-screen overlay
    in the app's overlay stack.
  - **Spec 03 / repo registry** - the later **Git & PR** page hosts the register-a-repo flow and the
    registry (`registerRepo` / `loadRepoRegistry`, `APP.md` §4.6).
  - **Settings state** - the **Appearance** page writes `theme` + `accent` to
    `localStorage['pinata.settings.v1']`.
  - **Spec 15** - all controls are tokens; the accent swatches are the 7 accents.
- **Used by / links to:**
  - **Spec 03** - the New Task dialog can deep-link into Settings once repo setup ships.
  - Terminal settings will later live-wire `--ui-fs` / `--density` / `--motion` onto the terminal
    surface when spec 05 ships.
- **Shared contract:** `SettingsView({ theme, accent, appState, onClose, onUpdateTheme,
  onUpdateAccent, onUpdateAppState })`; settings object persisted at `localStorage['pinata.settings.v1']`;
  repo registration writes through app state; future settings keys stay in `features/settings/settings.ts`.

## Purpose

A full-screen settings surface (Codex-style: category **rail** + scoped **page**) for per-user
preferences. Opened with the native macOS Settings menu item or ⌘,; closed with "Back to app".

## Shell (`SettingsPage`)
- Full-screen overlay above the app, its own layout. **Left rail** (~264px, `--sidebar`): Back to
  app · grouped nav. **Right content**: centered column (max ~760px).
- Section chosen by `sel`; supports `initialSection` for deep-linking once more pages ship.

### Nav model (`NAV`)
- **Personal:** Appearance · Shortcuts
- **Coding:** Git & PR

General, Terminal, and Language servers stay out of `NAV` until their pages are wired. Agents and
Connections stay latent.

## Persistence
- One object → `localStorage['pinata.settings.v1']`, merged over `S_DEFAULTS`; `set(key, value)`
  writes through immediately.
- Theme + accent are settings today. If onboarding returns, it must read/write the same object.
- Terminal font size, density, and reduced motion are deferred until the Terminal page ships.

## Controls (reusable)
`SToggle` (accent-fill switch), `SSelect`, `SSegment` (**selected segment = `--surface` fill, no
border, no shadow** - reads by contrast alone; critical in light theme), `SText`, `SRow`,
`SCard`/`SSub`/`SGroup`. Reuse these; don't hand-roll control styles.

## Pages
- **Appearance** (see spec 15): theme segmented control writes `theme`; the 7 **accent** swatches
  write `accent`.
- **Shortcuts:** read-only keyboard map for active app shortcuts.
- **Git & PR:** repository registry only for now. Shows a global worktree base, a Register repo
  action, and compact repo rows that open a repository settings modal. The register modal accepts a
  local path with a native directory picker plus optional name, default branch, and worktree override.
  Repo rows show repo name plus inline quick-look metadata: org and default branch. The repository
  modal makes source path, org, default branch, and optional worktree override explicit. The override
  placeholder previews `<global worktree base>/<repo name>` and Reset clears the override back to
  that fallback. Selecting or changing the path calls Rust `inspect_repository`; non-git folders
  show an error and cannot be registered. Valid git folders populate repo name, canonical path,
  default branch, and branch list. Submitting rejects duplicates by name or canonical path, then
  appends to `appState.repoRegistry`. Repository settings follow the Codex settings rhythm: setting
  copy on the left, right-aligned value/control sized to its content, optional worktree override,
  reset action, and danger-zone removal. Remove deletes only the Piñata registration and is disabled
  with an explanatory tooltip while any task references the repo. Global and per-repo repository
  config edits apply from their field change. Worktree paths must be blank, absolute, or `~/` based;
  they do not need to exist yet. Worktree labels expose a small help tooltip explaining that path
  changes only affect future task worktrees.

## Later pages
- **Search:** filter settings nav once enough pages exist to justify it.
- **General:** Restore session · Prevent sleep · Confirm before deleting (`confirm_delete`, gates
  spec 03 confirms) · Share anonymous usage.
- **Terminal:** default shell · default split direction (⌘D) · scrollback · blinking cursor · copy
  on select. Add Text & Density here when implementing terminal: terminal font size (S/M/L/XL),
  density, and reduced motion live-wired to the terminal surface.
- **Git & PR additions:** Repo removal, Fetch & worktrees controls, GitHub CLI path, GitHub account,
  and authentication state.
- **Language servers:** global toggles (enable, format on save, inlay hints) + installed
  servers with active/disabled status.

## Latent (built, not in `NAV`)
- **Agents page** (`AgentsPage`) - default agent, auto-start, completion sound. Add to the Coding
  group to expose (consumed by specs 06/08).
- **Connections (SSH)** (`ConnectionsPage`) - full SSH page over `T_REMOTES` (list + toggles +
  status, detail card, error banner, connect/disconnect/retry). **Not in `NAV`.** To ship, add a
  nav item + route `sel==='connections'`. Ties to `RepoRemoteGate` (spec 10) for remote repos.

## Edge cases
- Deep-link selects the page on open. Theme/accent reflect instantly. Duplicate repo
  register is a no-op. Unknown keys fall back via merge.

## Acceptance criteria
- [ ] Rail + scoped page; Back to app closes; ⌘, toggles.
- [ ] Values persist to `pinata.settings.v1`; theme + accent update the root app theme immediately.
- [ ] Git & PR registers a local git checkout into `appState.repoRegistry` and persists it through
      app state.
- [ ] Non-git folders fail during inspection and keep Register disabled.
- [ ] Per-repo worktree path is optional and falls back to `<global worktree base>/<repo name>`.
- [ ] Registered repos can be removed only when no task references them.
- [ ] Global and per-repo repository config edits persist from their field change.
- [ ] Invalid worktree paths block Register/change and show an inline error.
- [ ] Worktree help explains that existing task worktrees keep their current paths.
- [ ] Segmented control's selected segment reads clearly in **both** themes (fill by contrast, no
      hairline, no shadow).
- [ ] Tokens only, flat, reduced-motion respected. No em-dashes.
