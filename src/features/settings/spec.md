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
- **Shared contract:** `SettingsView({ theme, accent, onClose, onUpdateTheme, onUpdateAccent })`;
  settings object persisted at `localStorage['pinata.settings.v1']`; future settings keys stay in
  `features/settings/settings.ts`.

## Purpose

A full-screen settings surface (Codex-style: category **rail** + scoped **page**) for per-user
preferences. Opened with the native macOS Settings menu item or ⌘,; closed with "Back to app".

## Shell (`SettingsPage`)
- Full-screen overlay above the app, its own layout. **Left rail** (~264px, `--sidebar`): Back to
  app · grouped nav. **Right content**: centered column (max ~760px).
- Section chosen by `sel`; supports `initialSection` for deep-linking once more pages ship.

### Nav model (`NAV`)
- **Personal:** Appearance · Shortcuts

General, Terminal, Git & PR, and Language servers stay out of `NAV` until their pages are wired.
Agents and Connections stay latent.

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

## Later pages
- **Search:** filter settings nav once enough pages exist to justify it.
- **General:** Restore session · Prevent sleep · Confirm before deleting (`confirm_delete`, gates
  spec 03 confirms) · Share anonymous usage.
- **Terminal:** default shell · default split direction (⌘D) · scrollback · blinking cursor · copy
  on select. Add Text & Density here when implementing terminal: terminal font size (S/M/L/XL),
  density, and reduced motion live-wired to the terminal surface.
- **Git & PR** (`GitPage`) - includes the **repo registry**:
  - Fetch & worktrees (Auto-fetch, Prune worktrees on delete); GitHub CLI (`gh` path).
  - **Repositories**: a "N registered" count + **Register repo** button; a toggled **register form**
    (local path + Browse, name, Register → `registerRepo`, auto-expands the new repo); a list of
    **compact collapsible rows** (chevron · repo icon · name · `org · N branches · base` · gh dot)
    that expand to per-repo config (Remote, Default branch, Worktree path, GitHub account,
    Authentication). Deliberately compact so 10+ repos stay scannable.
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
- [ ] Segmented control's selected segment reads clearly in **both** themes (fill by contrast, no
      hairline, no shadow).
- [ ] Tokens only, flat, reduced-motion respected. No em-dashes.
