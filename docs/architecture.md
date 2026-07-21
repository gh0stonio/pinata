# Piñata Architecture

This document is the map of the current app. It explains what each layer owns, how data moves
through the Tauri and Vue boundary, and where to start when changing a feature.

## Contents

- [Product Shape](#product-shape)
- [Runtime Stack](#runtime-stack)
- [Source Tree](#source-tree)
- [Ownership Boundaries](#ownership-boundaries)
- [App Boot Lifecycle](#app-boot-lifecycle)
- [Root Render Tree](#root-render-tree)
- [AppShell Orchestration](#appshell-orchestration)
- [Persistent App State](#persistent-app-state)
- [Settings State](#settings-state)
- [Tauri Command Boundary](#tauri-command-boundary)
- [Native Menu And Window Behavior](#native-menu-and-window-behavior)
- [Settings Lifecycle](#settings-lifecycle)
- [Onboarding Lifecycle](#onboarding-lifecycle)
- [Repository Registration Lifecycle](#repository-registration-lifecycle)
- [Worktree Path Rules](#worktree-path-rules)
- [Task Sidebar Interaction Model](#task-sidebar-interaction-model)
- [Task Creation Lifecycle](#task-creation-lifecycle)
- [Task Edit Lifecycle](#task-edit-lifecycle)
- [Task Deletion Lifecycle](#task-deletion-lifecycle)
- [Git Progress Events](#git-progress-events)
- [Modal and Overlay Rules](#modal-and-overlay-rules)
- [Styling System](#styling-system)
- [Feature Specs](#feature-specs)
- [Where To Change Things](#where-to-change-things)
- [Terminal Runtime](#terminal-runtime)
- [Current High-Impact Operations](#current-high-impact-operations)
- [Mental Model](#mental-model)

## Product Shape

Piñata is a terminal-first macOS workbench. The core product model is:

```text
Task
+-- Task terminal
+-- Attached repo
    +-- Registered repository config
    +-- Task-owned git branch
    +-- Task-owned worktree
    +-- Repo terminal
```

The app does not own agent output. The terminal surface is a real shell where users start `pi`,
`claude`, `codex`, or any other harness themselves.

## Runtime Stack

| Layer | Technology | Main files | Owns |
|---|---|---|---|
| Native app | Tauri 2 | `src-tauri/src/lib.rs` | macOS menu, command registration, native plugins |
| Backend | Rust | `src-tauri/src/app_state.rs`, `src-tauri/src/repository.rs`, `src-tauri/src/terminal.rs` | persisted app state, git inspection, branch and worktree commands, PTY attachment |
| Frontend | Vue 3 + TypeScript | `src/main.ts`, `src/App.vue`, `src/shell/app-shell/AppShell.vue` | UI tree, product flows, state orchestration |
| Terminal runtime | xterm.js + bundled tmux | `src/features/terminal/*`, `src-tauri/resources/tmux/*` | embedded terminal rendering, durable shell sessions |
| Styling | CSS modules + tokens | `src/styles/*`, `*.module.css` | themes, spacing, typography, flat visual system |
| Shared UI | Vue components | `src/components/*`, `src/icons/*` | reusable controls and icons |

## Source Tree

```text
.
+-- docs/
|   +-- architecture.md
|   +-- design/Pinata.html
+-- src/
|   +-- assets/                 # logo, app icon, bundled fonts
|   +-- components/             # shared app-level UI components
|   +-- features/
|   |   +-- app-state/          # durable schema, TS helpers, Tauri invokers
|   |   +-- onboarding/         # first-run setup flow
|   |   +-- settings/           # full-screen settings surface
|   |   +-- task-sidebar/       # left task panel and task dialog
|   |   +-- terminal/           # xterm surface and terminal Tauri wrappers
|   +-- icons/                  # centralized SVG icon components
|   +-- shell/
|   |   +-- app-shell/          # root orchestrator
|   |   +-- main-surface/       # center selected task or repo terminal host
|   |   +-- side-panel/         # generic right side panel scaffold
|   |   +-- title-bar/          # custom macOS title bar
|   +-- styles/                 # design tokens, themes, globals
|   +-- App.vue                 # mounts AppShell
|   +-- main.ts                 # Vue entrypoint
+-- src-tauri/
    +-- src/
    |   +-- app_state.rs        # app-state.json load/save
    |   +-- repository.rs       # git inspection and task worktree commands
    |   +-- terminal.rs         # bundled tmux sessions and PTY attach
    |   +-- lib.rs              # Tauri setup, menu, command registration
    |   +-- main.rs             # native entrypoint
    +-- resources/tmux/         # embedded tmux binary and dylibs
    +-- tauri.conf.json
```

## Ownership Boundaries

| Concern | Owner | Reason |
|---|---|---|
| Visual state, modals, selection, keyboard shortcuts | Vue | It is UI state and needs immediate rendering |
| Durable product state | Rust file, shaped by TS helpers | Rust reads and writes the app data JSON file |
| Theme, accent, accent intensity | `localStorage` through `settings.ts` | User preference, cheap synchronous startup read |
| First-run onboarding flag | `localStorage['pinata.onboarded.v1']` | Only gates whether onboarding appears |
| Git repository inspection | Rust | Needs local filesystem and `git` access |
| Branch and worktree creation/deletion | Rust | High-impact filesystem operations stay native and testable |
| Terminal session runtime | Rust + bundled tmux | Durable shell processes must survive webview and app restarts |
| Terminal rendering and keyboard input | Vue + xterm.js | Browser-side terminal emulator owns pixels, input, and fit |
| Branch/worktree transaction orchestration | Vue `AppShell` | It coordinates UI progress, rollback calls, and final app-state save |

## App Boot Lifecycle

```mermaid
sequenceDiagram
    participant main as "src/main.ts"
    participant app as "App.vue"
    participant shell as "AppShell.vue"
    participant settings as "settings.ts"
    participant rust as "Rust app_state"
    participant ui as "Rendered UI"

    main->>app: mount Vue app
    app->>shell: render AppShell
    shell->>settings: synchronously load theme settings
    shell->>rust: invoke load_app_state
    rust-->>shell: AppState or default AppState
    shell->>shell: set bootstrapped = true
    alt onboarding flag missing
        shell->>ui: render OnboardingFlow only
    else onboarded
        shell->>ui: render TitleBar, task panel, main surface, right panel
    end
```

Important detail: app chrome waits for `bootstrapped`. This prevents the empty scaffold from
flashing before persisted state loads.

## Root Render Tree

Normal app mode:

```mermaid
flowchart TB
    AppShell["AppShell.vue"]
    TitleBar["TitleBar"]
    Body["Body grid"]
    Left["TaskSidePanel"]
    Main["MainSurface"]
    Right["SidePanel, right"]
    Settings["SettingsView, conditional"]
    TaskDialog["TaskDialog, conditional"]

    AppShell --> TitleBar
    AppShell --> Body
    Body --> Left
    Body --> Main
    Body --> Right
    AppShell --> Settings
    AppShell --> TaskDialog
```

First-run mode:

```mermaid
flowchart TB
    AppShell["AppShell.vue"]
    Onboarding["OnboardingFlow"]

    AppShell --> Onboarding
```

Onboarding is exclusive. It does not render behind the normal app shell.

## AppShell Orchestration

`AppShell.vue` is the only place that coordinates durable product changes across features.
Feature components emit intent. `AppShell` decides what state changes, what Rust command runs, and
when app state is saved.

```mermaid
flowchart LR
    Feature["Feature component"]
    Shell["AppShell"]
    Model["app-state.ts helpers"]
    Rust["Tauri command"]
    State["appState ref"]
    File["app-state.json"]

    Feature -->|"emit intent"| Shell
    Shell --> Model
    Shell --> Rust
    Model --> Shell
    Rust --> Shell
    Shell --> State
    Shell --> File
```

Current `AppShell` responsibilities:

| Area | State or function | Notes |
|---|---|---|
| Panels | `leftSidePanelVisible`, `rightSidePanelVisible` | Header shortcuts and buttons toggle these |
| Settings | `settingsVisible`, `settings` | Settings values come from `localStorage` |
| Onboarding | `onboardingVisible` | First-run flow owns the screen until completed |
| Task modal | `newTaskVisible`, `editingTaskId`, `taskDialogProgress` | One dialog handles create, edit, delete, and git progress |
| App state | `appState`, `persistAppState`, `persistAppStateAsync` | Fire-and-forget for low-risk UI edits, awaited for task git transactions |
| Git progress | `listen('pinata://git-progress')` | Rust phase events update the running progress row |

This keeps feature components mostly presentational. `TaskDialog` validates form shape and asks for
confirmation, but it does not create branches, delete worktrees, or save `app-state.json` itself.

## Persistent App State

Rust stores product state in:

```text
~/Library/Application Support/dev.pinata.desktop/app-state.json
```

The TypeScript and Rust schemas mirror each other.

```ts
type AppState = {
  version: 1
  layout: {
    window: {
      width: number
      height: number
      x?: number
      y?: number
    }
    sidePanels: {
      leftWidth: number
      rightWidth: number
    }
  }
  repositoryDefaults: {
    worktreeBasePath: string
  }
  repoRegistry: RegisteredRepo[]
  tasks: Task[]
  selection: {
    taskId: string | null
    surfaceByTaskId: Record<string, TaskSurfaceSelection>
    expandedTaskIds: string[]
  }
}

type RegisteredRepo = {
  id: string
  name: string
  org?: string
  description?: string
  source: { kind: 'local'; path: string }
  branches: string[]
  defaultBranch: string
  worktreeBasePath?: string
  githubAccount?: string
}

type Task = {
  id: string
  name: string
  color: string
  terminal: TaskTerminal
  repos: TaskRepo[]
}

type TaskTerminal = {
  id: string
  cwd: '~'
}

type TaskRepo = {
  id: string
  registeredRepoId: string
  baseBranch: string
  branch: string
  worktreePath?: string
}

type TaskSurfaceSelection =
  | { kind: 'task-terminal' }
  | { kind: 'repo'; taskRepoId: string }
```

State rules:

- `layout.window` stores the normal logical app window size and optional logical window position.
  Rust restores both during startup, and fullscreen window events are ignored by the shell saver.
- `layout.sidePanels` stores the left and right panel widths. Panel visibility is runtime shell
  state for now.
- `repoRegistry` is global repository config.
- `TaskRepo` is a repository instance inside one task.
- Every task owns a default task terminal that starts in `~`.
- Tasks may have zero attached repos.
- Selection points to either the task terminal or `TaskRepo.id`, never `RegisteredRepo.id`.
- Registered repository removal is blocked while any task references it.
- Task branch identity is immutable after the row is created.
- Task rename does not rename existing branches or move existing worktrees.
- Terminal live process state is not in app state. `Task.terminal.id` and `TaskRepo.id` derive tmux
  session names. Their `cwd` or `worktreePath` values let Piñata recreate sessions if the tmux
  server is gone.
- `Task.terminalClosed` records that the user closed the final pane for a task. This suppresses the
  implicit default pane until the user explicitly selects the task, selects a repo, or splits again.

Write behavior:

- `load_app_state` returns the default empty state when the file does not exist.
- `save_app_state` rejects unsupported schema versions, creates the app data directory if needed,
  then writes pretty JSON directly.
- Low-risk interactions call `persistAppState`, which updates the Vue ref immediately and logs save
  failures.
- Git transactions call `persistAppStateAsync`, so the modal closes only after git work and the
  final state save both succeed.

## Settings State

Settings live in:

```text
localStorage['pinata.settings.v1']
```

Current settings:

```ts
type AppSettings = {
  theme: 'pinata-dark' | 'pinata-light'
  accent: 'coral' | 'teal' | 'gold' | 'magenta' | 'lime' | 'azure' | 'mono'
  accentIntensity: 'transparent' | 'balanced' | 'vibrant'
  appFontSize: 'small' | 'regular' | 'large'
  terminalFontSize: 'small' | 'regular' | 'large' | 'xl'
  closeAppOnLastPane: boolean
}
```

`AppShell` applies these values as data attributes on the root shell:

```html
<div
  data-theme="pinata-dark"
  data-accent="coral"
  data-accent-intensity="balanced"
  data-app-font-size="regular"
>
```

Theme CSS reads those attributes and exposes semantic tokens like `--color-accent-primary`,
`--color-surface-primary`, and `--color-text-secondary`.

## Tauri Command Boundary

Vue calls Rust through typed wrappers in feature folders.

```mermaid
flowchart LR
    Vue["Vue feature code"]
    Wrappers["typed TS wrappers"]
    Tauri["Tauri invoke"]
    Rust["Rust commands"]

    Vue --> Wrappers
    Wrappers --> Tauri
    Tauri --> Rust
```

Registered commands:

| Command | Rust file | Purpose |
|---|---|---|
| `load_app_state` | `app_state.rs` | Read app-state JSON from app data dir |
| `save_app_state` | `app_state.rs` | Write app-state JSON |
| `inspect_repository` | `repository.rs` | Validate git checkout, infer repo metadata |
| `create_task_repo_worktree` | `repository.rs` | Create task-owned branch and worktree |
| `delete_task_repo_worktree` | `repository.rs` | Remove task-owned worktree and branch |
| `terminal_ensure_session` | `terminal.rs` | Ensure a bundled tmux session exists for a selected task surface |
| `terminal_attach` | `terminal.rs` | Attach xterm to the selected tmux session through a PTY |
| `terminal_resize` | `terminal.rs` | Resize the selected terminal PTY to match xterm |
| `terminal_scroll` | `terminal.rs` | Bridge wheel scrolling to tmux pane history |
| `terminal_cancel_scroll` | `terminal.rs` | Leave tmux scrollback before sending shell input |
| `terminal_clear` | `terminal.rs` | Clear the selected xterm buffer and tmux pane history |
| `terminal_detach` | `terminal.rs` | Drop the PTY attachment while keeping tmux alive |
| `terminal_kill_session` | `terminal.rs` | Kill a selected task or repo terminal session during cleanup |
| `terminal_process_status` | `terminal.rs` | Ask tmux and the pane tty whether a foreground process is running |

## Native Menu And Window Behavior

`src-tauri/src/lib.rs` owns native app setup:

- Registers the Rust commands above.
- Installs the dialog plugin used by Settings and Onboarding folder pickers.
- Builds the macOS app menu, including `Settings...` with `CmdOrCtrl+,`.
- Emits `pinata://open-settings` when the native Settings menu item is selected.
- The native Window menu does not include Close Window, so `Cmd+W` stays available for Piñata pane
  closing.

`AppShell` listens for `pinata://open-settings` and opens `SettingsView`.

Window dragging is handled in every top-level surface that can cover the title bar:

| Surface | Drag owner |
|---|---|
| Normal app | `TitleBar.vue` |
| Settings | `SettingsView.vue` drag region |
| Onboarding | `OnboardingFlow.vue` drag region |
| Task dialog, including blocking git progress | `TaskDialog.vue` drag region |
| Pane close warning | `AppShell.vue` drag region |

Default rule: future full-screen or modal surfaces must keep the top title-bar height draggable.

## Settings Lifecycle

Settings has two kinds of data:

```text
User preferences:
  localStorage['pinata.settings.v1']

Product registry:
  app-state.json via emit('update-app-state')
```

Appearance edits update `theme`, `accent`, and `accentIntensity` immediately. `AppShell` reflects
them as root `data-*` attributes so CSS tokens update without a reload.

Git & PR edits update durable app state:

- Global worktree base validates on change, then saves to `repositoryDefaults.worktreeBasePath`.
- Register repo opens a modal, validates the folder through `inspect_repository`, then appends a
  `RegisteredRepo`.
- Registered repo rows open a modal with source path, org, default branch, worktree override, and
  danger-zone removal.
- Default branch and per-repo worktree override apply from their field change after validation.
- Repository removal deletes only the registry entry and is disabled while any task references it.

## Onboarding Lifecycle

Onboarding is gated by:

```text
localStorage['pinata.onboarded.v1']
```

First run uses default settings from `settings.ts`: Piñata Dark, Coral, Balanced. The normal app
chrome is not rendered behind onboarding.

```mermaid
sequenceDiagram
    participant flow as "OnboardingFlow"
    participant settings as "settings.ts"
    participant rust as "inspect_repository"
    participant shell as "AppShell"
    participant file as "app-state.json"

    flow->>settings: update theme, accent, intensity
    flow->>rust: inspect selected repo folders
    rust-->>flow: repository metadata
    flow->>shell: finish(openNewTask, repositories)
    shell->>shell: set pinata.onboarded.v1
    shell->>file: save deduped repositories
    opt openNewTask
        shell->>shell: open TaskDialog
    end
```

Repository rows collected during onboarding are temporary until finish. Finish de-dupes against the
current registry by name and canonical path before saving.

## Repository Registration Lifecycle

Registration happens from Settings or Onboarding.

```mermaid
sequenceDiagram
    participant ui as "Settings or Onboarding"
    participant picker as "Native folder picker"
    participant rust as "inspect_repository"
    participant state as "AppState"

    ui->>picker: choose folder
    picker-->>ui: local path
    ui->>rust: inspect_repository(path)
    rust->>rust: git rev-parse --show-toplevel
    rust->>rust: read branches, default branch, origin org
    rust-->>ui: RepositoryInspection
    ui->>state: create RegisteredRepo
    ui->>state: save through save_app_state
```

Validation:

- Non-git folders are rejected.
- Paths are canonicalized by Rust.
- Duplicate registration is blocked by repo name or canonical path.
- `org` is inferred only for GitHub remotes today.

## Worktree Path Rules

There are three levels:

```text
Global default:
  ~/.pinata/worktrees

Registered repo effective base:
  repo.worktreeBasePath ?? <global default>/<repo name>

Task repo worktree:
  <effective repo base>/<6-char task-id hash>-<task slug>
```

Repo-local override rule:

```text
./worktrees
```

means:

```text
<registered repo source path>/worktrees
```

Example:

```text
repo source path: /Users/me/dev/api
override:         ./worktrees
effective base:   /Users/me/dev/api/worktrees
task worktree:    /Users/me/dev/api/worktrees/a1b2c3-auth-fix
```

The task worktree leaf comes from the immutable task branch. This is why editing a task name later
does not silently move an already-planned or already-created worktree.

## Task Sidebar Interaction Model

The left side panel is the task navigation surface.

```mermaid
flowchart TB
    Panel["TaskSidePanel"]
    New["New task button"]
    TaskRow["Task row"]
    RepoRow["Repo row"]
    Hover["Repo hover metadata"]

    Panel --> New
    Panel --> TaskRow
    TaskRow --> RepoRow
    RepoRow --> Hover
```

Interaction rules:

- New Task opens `TaskDialog` in create mode.
- Clicking a task row selects the task terminal.
- Clicking a task chevron toggles expand or collapse.
- Clicking a repo row selects that `TaskRepo`.
- Dragging a side panel edge resizes that panel inside its clamp and persists the new width on
  pointer release.
- Expanded task ids and selected task surfaces persist in app state.
- Repo hover metadata shows branch, base branch, and planned or persisted worktree path.
- During blocking task git work, the working task shows progress and repo selection highlight is
  suppressed.

## Task Creation Lifecycle

```mermaid
sequenceDiagram
    participant dialog as "TaskDialog"
    participant shell as "AppShell"
    participant state as "app-state.ts"
    participant rust as "repository.rs"
    participant file as "app-state.json"

    dialog->>shell: create(NewTaskInput)
    shell->>state: createTask(input)
    shell->>state: create task terminal target
    shell->>shell: build git plans for repos without worktreePath
    opt attached repos
        shell->>dialog: show progress-only modal
    end
    par each repo
        shell->>rust: create_task_repo_worktree(plan)
        rust->>rust: validate repo, branch, path
        rust->>rust: git worktree add -b branch path base
        rust-->>shell: progress events
        rust-->>shell: canonical worktree path
    end
    shell->>state: attach worktreePath to each TaskRepo
    shell->>file: save_app_state(nextState)
    shell->>dialog: close
```

Creation is synchronous from the user's point of view when repos are attached. The modal stays open
until git work finishes. Repo-less tasks skip git work and select the task terminal immediately.

Parallelism:

- Repositories run in parallel.
- Inside one repository, branch creation and worktree creation are one sequential `git worktree add`
  operation.

Failure behavior:

- If a repo fails, the modal shows the error and returns to the form only when the user chooses.
- Repos that succeeded in the same transaction are rolled back with `delete_task_repo_worktree`.
- App state is not saved until all git work succeeds.
- Rust also cleans up a partially-created worktree and branch if `git worktree add` fails after
  creating them.

## Task Edit Lifecycle

Task edit reuses the same dialog and transaction path.

```mermaid
flowchart TB
    Edit["User edits task"]
    Update["updateTask(task, input)"]
    Added["Repos added"]
    Removed["Repos removed"]
    Existing["Repos kept"]
    Create["Create added repo worktrees"]
    Cleanup["Delete removed repo worktrees"]
    Save["Save next AppState"]

    Edit --> Update
    Update --> Added
    Update --> Removed
    Update --> Existing
    Added --> Create
    Removed --> Cleanup
    Existing --> Save
    Create --> Save
    Cleanup --> Save
```

Rules:

- Existing repo rows keep their `TaskRepo.id`.
- Existing repo rows keep their `branch`.
- Existing materialized repo rows keep their `baseBranch`.
- Newly-added repos get the task id hash plus the current task name slug.
- Removing all repos is valid. The task stays alive with its task terminal.
- Removing or replacing a saved repo row requires confirmation.

## Task Deletion Lifecycle

```mermaid
sequenceDiagram
    participant dialog as "TaskDialog"
    participant shell as "AppShell"
    participant rust as "repository.rs"
    participant file as "app-state.json"

    dialog->>dialog: confirm danger action
    dialog->>shell: delete(task)
    shell->>dialog: show cleanup progress
    par each attached repo
        shell->>rust: delete_task_repo_worktree(plan)
        rust->>rust: git worktree remove --force path
        rust->>rust: git branch -D branch
    end
    shell->>file: save app state without task
    shell->>dialog: close
```

Deletion only targets task-owned branches and worktrees. Registered repositories and their source
folders stay untouched.

## Git Progress Events

Rust emits:

```text
pinata://git-progress
```

Payload:

```ts
type GitProgressEvent = {
  progressId: string
  phase: string
}
```

Rust reads `git worktree add` stdout and stderr and maps raw output to friendly phases. Current
examples:

| Raw signal | UI phase |
|---|---|
| `Preparing worktree` | `Preparing worktree` |
| `Updating files:` | `Updating files` |
| `post-checkout` | `Repository hooks` |
| `installing dependencies` | `Installing dependencies` |
| `┌ Linking the project` | `Linking project` |
| `┌ Building the project` | `Building project` |
| `┌ Checking constraints` | `Checking constraints` |

The UI never displays raw hook output in the progress rows.

## Modal and Overlay Rules

All full-screen overlays are mounted from `AppShell`.

Current overlays:

- `SettingsView`
- `TaskDialog`
- `OnboardingFlow`, exclusive during first run

Rules:

- Keep overlays flat. No shadows.
- Keep the top `--titlebar-height` draggable even during blocking progress.
- Outside-click close should be based on pointer down and pointer up both starting outside, not just
  releasing outside.
- Blocking git progress disables close actions until the transaction finishes or fails.

## Styling System

Piñata uses global design tokens plus CSS modules.

Core files:

| File | Purpose |
|---|---|
| `src/styles/tokens.css` | spacing, radius, font scale, layout sizes |
| `src/styles/themes.css` | theme and accent semantic colors |
| `src/styles/typography.css` | bundled font faces |
| `src/styles/density.css` | density hook for future terminal settings |
| `src/styles/globals.css` | global reset and shared button classes |
| `src/styles/spec.md` | design system rules |

Rules:

- Prefer semantic tokens over raw colors.
- Prefer spacing tokens over hardcoded pixel values.
- Use `uiButton` classes for buttons.
- Use `src/components` for shared controls used by multiple features.
- Use `src/icons` for icons.
- No shadows. Separation comes from fill, border, and spacing.

## Feature Specs

Each feature keeps a local `spec.md` close to its code.

| Spec | Describes |
|---|---|
| `src/shell/spec.md` | frame, keyboard, overlays, title bar, layout |
| `src/features/app-state/spec.md` | persisted product state and invariants |
| `src/features/onboarding/spec.md` | first-run flow |
| `src/features/settings/spec.md` | settings pages and repo registry |
| `src/features/task-sidebar/spec.md` | task panel, task dialog, task git work |
| `src/features/terminal/spec.md` | embedded terminal renderer and tmux runtime |
| `src/styles/spec.md` | visual design system |

Use this file for the big picture. Use feature specs when changing one feature.

## Where To Change Things

| Goal | Start here | Usually also touches |
|---|---|---|
| Add a durable app-state field | `src/features/app-state/app-state.ts` | `src-tauri/src/app_state.rs`, app-state spec |
| Add a Rust command | `src-tauri/src/*.rs` | `src-tauri/src/lib.rs`, TS wrapper in `app-state.ts` |
| Change task create/edit/delete | `src/shell/app-shell/AppShell.vue` | `TaskDialog.vue`, app-state helpers, task-sidebar spec |
| Change terminal runtime | `src/features/terminal/*` | `src-tauri/src/terminal.rs`, terminal spec |
| Change task sidebar visuals | `TaskSidePanel.vue` | `TaskSidePanel.module.css`, task-sidebar spec |
| Change settings | `SettingsView.vue` | `settings.ts`, settings spec |
| Change onboarding | `OnboardingFlow.vue` | onboarding spec |
| Change theme or spacing | `src/styles/*` | styles spec |
| Add reusable visual control | `src/components/<control>` | feature imports |
| Add icon | `src/icons/<Name>Icon.vue` | consuming component |

## Terminal Runtime

The terminal starts as one embedded shell for the selected task surface. A task surface is either
the task terminal or one attached repo terminal. When the user splits, the task stores a durable
pane tree. Each pane owns its own tmux-backed session and remembers the task surface it came from.

```mermaid
flowchart LR
    Surface["Task.terminal or TaskRepo"]
    Layout["Task.terminalLayout"]
    MainSurface["MainSurface"]
    SplitNode["TerminalSplitNode"]
    TerminalSurface["TerminalSurface + xterm.js"]
    RustTerminal["Rust terminal.rs"]
    PTY["portable-pty attachment"]
    Tmux["bundled tmux private session"]
    Shell["user shell in cwd"]

    Surface --> MainSurface
    Layout --> MainSurface
    MainSurface --> SplitNode
    SplitNode --> TerminalSurface
    TerminalSurface <--> RustTerminal
    RustTerminal <--> PTY
    PTY <--> Tmux
    Tmux <--> Shell
```

Runtime rules:

- `xterm.js` is only the terminal renderer and input surface.
- Rust owns PTY read/write/resize and emits `pinata://terminal-output` with base64-encoded byte
  chunks.
- Keystrokes use `pinata://terminal-input`, a fire-and-forget event, so typing does not wait on a
  command response.
- Bundled `tmux` owns durability. Closing Piñata detaches from tmux; it does not kill the shell.
- Piñata uses the embedded `src-tauri/resources/tmux/bin/tmux-*` binary in dev and packaged builds.
- The `tmux` server uses a private socket under the app data directory.
- Piñata disables the tmux status bar so the xterm surface owns the full content area.
- Piñata keeps tmux mouse mode off so xterm owns selection. Wheel gestures are stopped before they
  can reach the shell and are mapped to tmux pane history. The next user input exits tmux scrollback
  before sending bytes to the shell, so typing snaps back to the live cursor.
- The first pane uses deterministic session names from `Task.terminal.id` or `TaskRepo.id`.
  Split-created panes use persisted `terminal-pane-*` session ids.
- Each pane stores a source, either task terminal or one task repo. Split-created panes inherit the
  active pane source. Sidebar clicks focus a matching source pane first; if none exists, Piñata
  retargets the active pane.
- Clicking a pane makes it active and updates the task sidebar selection to that pane source.
- The shell starts in `Task.terminal.cwd` for task terminals, `TaskRepo.worktreePath` for repo
  terminals, and the stored pane `cwd` for split-created panes.
- The default shell is the user's `SHELL`; missing or invalid shell falls back to `/bin/zsh`.
- `Cmd+D` creates a vertical split. `Cmd+Shift+D` creates a horizontal split. The new pane opens in
  the same cwd as the active pane and becomes active.
- `Cmd+W` closes the active pane. If tmux and the pane tty report a foreground command that is not
  the user's shell, Piñata asks before stopping that pane session. Shim wrappers like `volta-shim`
  are resolved to the launched command when possible.
- Closing the last pane stores `Task.terminalClosed` and shows an empty main surface. If
  `closeAppOnLastPane` is enabled in Settings, Piñata closes after stopping that final pane session.
- `Cmd+T` reopens the selected task's current terminal target from that empty surface.
- Task edits that add or remove repos reset the task split layout and kill split-only sessions so
  stale panes do not point at removed worktrees.

Task lifecycle integration:

- Task create: create task terminal target, create attached repo worktrees if any, persist app
  state.
- Task edit with added repo: create worktree, ensure terminal session, persist app state.
- Task edit with removed repo: kill terminal session, delete worktree and branch, persist app state.
- Task delete: kill the task terminal session, each task repo terminal session, and any split pane
  sessions, delete worktrees and branches, persist app state.

Deferred:

- Multiple terminal tabs per repository.
- Resizing split dividers.
- Restoring xterm scrollback from `tmux capture-pane` on attach.

## Current High-Impact Operations

| Operation | Why high impact | Current guard |
|---|---|---|
| Delete task | Deletes task-owned branches and worktrees | Confirmation modal |
| Remove saved repo from task | Deletes that task repo branch and worktree when present | Confirmation modal |
| Replace saved repo in task | Deletes old task repo branch and worktree when present | Confirmation modal |
| Remove registered repo from Settings | Could orphan tasks | Disabled while referenced by any task |
| Change repo worktree base | Affects future task worktrees | Help copy, no existing worktrees moved |
| Close terminal pane with foreground command | Stops the pane's tmux session | Confirmation modal |

## Mental Model

Keep this split clear:

```text
RegisteredRepo
  "This local checkout exists and Piñata can use it."

Task
  "This is the unit of work the user wants to ship."

TaskRepo
  "This task uses this registered repo with this base branch,
   task branch, and task worktree."
```

Most bugs come from mixing those three levels.
