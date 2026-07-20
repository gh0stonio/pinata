# Spec 02 - App shell & navigation

> Prerequisite: read `APP.md` (esp. §7-§9). Reference: `reference/src/term-app.jsx`.

## Dependencies & links
- **Depends on:** **Spec 15 (Theming)** - the whole frame is tokens.
- **Hosts / owns (used by everyone):**
  - **Layout regions** for the sidebar (spec 03), center panes/tabs (specs 04-08), and right panel
    (specs 10-13).
  - **The overlay stack** - Settings (14), Onboarding (01), New Task dialog (03), Command palette
    (09), and the fixed menus below.
  - **Global selection state** (`selection.taskId`, `selection.taskRepoIdByTaskId`,
    `selection.expandedTaskIds`) and the **global keyboard handler** (`APP.md` §8). Specs 03-13
    read this state and receive callbacks from `App`.
- **Routes into other features:** the **PR-list menu** selects a repo + sets the right panel to the
  **PR** view and reveals it (spec 13/10); the task/repo **switchers** change selection consumed by
  every center/right surface; **⌘P** opens the palette (spec 09); **⌘,** opens Settings (spec 14).
- **Shared contract:** `App` passes each child its slice of state + callbacks (`selectTaskRepo`,
  `toggleTask`, future `selectTab`, `newTabInRepo`, `openFile`, `runCommand`, pane `ctx`,
  `setRightView`, …). Keep these names stable across specs.

## Purpose

The frame that holds everything: window chrome, the three-region layout, collapsible/resizable
panels, the global keyboard map, and the **breadcrumb switchers** that move between tasks and
repos. This is the second thing to build (after tokens) because every other feature mounts inside
it.

## Current scaffold scope

Today the shell owns `AppShell`, `TitleBar`, `SidePanel`, `MainSurface`, first-run Onboarding, and
the task side panel host. It renders the three-column frame, left/right panel toggles, app branding
in the left task side panel, persisted task/repo selection, the native settings menu bridge, and the
selected task repo terminal. The shell waits for persisted app state to bootstrap before mounting
app chrome, so startup never renders an empty default state for a frame. First-run Onboarding is
exclusive and mounts instead of the title bar/body until setup finishes. The title bar center stays
empty until breadcrumb switchers ship. Resizers, pane trees, and right-panel feature content are
future work from the sections below.

## Layout regions

See `APP.md` §9 for the diagram. Three columns inside a window shell (`.term-window`):

1. **Title bar** (`.term-titlebar`, fixed height).
2. **Body row** (flex): left **sidebar** (spec 03) · resizer · **center** (tab bar spec 08 + pane
   tree spec 04 + optional LSP bar) · resizer · right **panel** (specs 10-13).

The window fills the viewport. Left and right panels are independently collapsible and
drag-resizable; the center flexes to fill.

### Panel sizing
- `leftW` default 293, clamp **200-440**. `rightW` default 479, clamp **260-520**.
- Resizers (`SideResizer`) are thin hit targets *between* regions; on hover they show a 1px accent-
  neutral line; drag updates the width. They sit outside the scaled content so they stay usable.
- `leftCollapsed` / `rightCollapsed` fully hide a panel (width → 0, resizer hidden).

## Title bar (left → right)

- **Traffic lights** (`--tl-close/min/max`) - decorative macOS-style dots, fixed ~130px cluster.
- **Sidebar toggle** (`chip-btn`, `on` when sidebar visible) - collapse/expand left sidebar,
  tooltip shows ⌘B.
- **Center breadcrumb** (flex, centered, truncating):
  - **Task switcher** - task color chip + task name (mono, bold) + chevron. Click opens the
    **task menu** (fixed dropdown) listing all tasks with their color/status chip; choosing one
    selects it. Max-width ~260px, truncates.
  - Separator `/`.
  - **Repo switcher** - active repo name (mono) + chevron. Click opens the **repo menu** listing
    the current task's repos; choosing one selects it.
- **Right cluster** (fixed ~260px, right-aligned):
  - **⌘P** button (`chip-btn`, search icon) - opens the command palette (spec 06).
  - **PR count** button ("N PRs", pr icon) - opens the **PR list menu**: one row per repo with a
    PR, showing a checks donut (or gh-auth status), repo · #number · title, a checks/reviews/ahead
    summary, and a state pill. Choosing a row selects that repo, sets the right panel to the **PR**
    view, and reveals the panel. (See spec 13 for the PR view, spec 10 for the host.)
  - **Panel toggle** (`chip-btn`, `on` when panel visible) - collapse/expand the right panel,
    tooltip ⌘L.

All three menus are `FixedMenu` dropdowns anchored to their button (auto-repositioned to stay in
viewport, close on outside-click / Escape). Only one menu open at a time (opening one clears the
others).

## Center column

- **Current scope:** `MainSurface` renders the selected `TaskRepo` terminal once that repo has a
  persisted `worktreePath`. The terminal feature owns xterm rendering, Rust PTY transport, and the
  bundled tmux session. See `src/features/terminal/spec.md`.
- **Empty state:** with no selected task repo, or with a repo that has not finished worktree setup,
  the center shows a simple empty state.

Future center work from v0:

- **Tab bar** (`.term-tabbar`) - the active repo's tabs + a `+` new-terminal button. Full behaviour
  in spec 08.
- **Pane area** - the active tab's pane tree (`TabPanes`, spec 04), or an **EmptyRepo** state ("No
  tabs in <repo>" + a New terminal button) when the repo has no tabs.
- **LSP status bar** (`LspBar`) - only when a **file** tab is active. A thin mono strip: per-server
  status dots (`ts-go`, `eslint`, `rust-analyzer`, …; ready = `--ck-pass`, indexing = pulsing
  `--ck-run`) + the repo name at the right. Decorative/status only.

## Selection state (in `App`)

- `selection.taskId` - current task id. `selection.taskRepoIdByTaskId[taskId]` - current task repo
  per task. `selection.expandedTaskIds` - which tasks are expanded in the left side panel.
- Clicking a task row toggles expand/collapse only. Clicking a repo row selects that repo and its
  task. Future tab selection should be remembered per repo once terminal tabs land.

## Overlays (z-order, all mounted by `App`)

Onboarding is a first-run exclusive screen, mounted after app-state bootstrap and before app chrome.
For the normal app, Settings (top, own rail) → New Task dialog (scrim) → Command palette (scrim) →
fixed menus (task/repo/PR/task-edit) → toast (bottom-center). Settings closes through Back to app or
⌘,; transient overlays close on Escape / outside-click as appropriate. A `toast(msg)` helper shows a
bottom-center confirmation (check icon + message) that auto-dismisses (~2.6s).

Every full-screen overlay or scrim must keep the top `--titlebar-height` region draggable with
`data-tauri-drag-region` plus `app-region: drag`. This is the default for all future modal work,
including blocking progress flows.

## Keyboard

Implement the full global map from `APP.md` §8 in one central keydown handler. Notes:
- ⌘B toggles the sidebar; ⌘L toggles the right panel.
- ⌘T new terminal in active repo; ⌘N new task; ⌘D / ⌘⇧D split active pane row/col; ⌘W close active
  pane; ⌘, settings; ⌘P palette.
- The handler depends on the active tab/repo/task, so it must see current selection (re-bind or read
  latest state). Pane-local inputs (shell/agent/rename fields) must not swallow these shortcuts.

## States & edge cases

- **No task selected / empty project:** center shows an empty state; breadcrumb hides repo half.
- **Task with no repos:** repo switcher empty; center shows EmptyRepo.
- **Repo with no tabs:** center shows EmptyRepo with a "New terminal" CTA.
- **Both panels collapsed:** center fills the window; toggles still available in the title bar.
- **Remote-down gate:** there is a latent `RepoRemoteGate` path (shown instead of the center when a
  repo's remote is unreachable). Currently `remoteDown` is always false; wire it if production adds
  remote repos.

## Acceptance criteria

- [ ] Three regions render; left/right independently collapse and drag-resize within their clamps.
- [ ] Task and repo switchers open menus and change selection; selection is remembered per level.
- [ ] ⌘P / ⌘N / ⌘T / ⌘D / ⌘⇧D / ⌘W / ⌘B / ⌘L / ⌘, all work globally and don't fire from inside
      text inputs unintentionally.
- [ ] PR-count button opens the PR list and routes to the PR view for the chosen repo.
- [ ] LSP bar appears only for file tabs. Toasts confirm task create/update.
- [ ] Flat (no shadows), tokens only, reduced-motion respected. No em-dashes.
