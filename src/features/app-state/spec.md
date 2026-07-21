# App State

## Purpose

Persist the durable product state that should survive app restarts: window layout, registered
repositories, tasks, and selection. Settings still own theme and accent separately.

## Storage

Rust owns the file:

```txt
~/Library/Application Support/dev.pinata.desktop/app-state.json
```

Vue loads it with `load_app_state` on app start. Vue saves through `save_app_state` when product
state changes. Rust also exposes git commands so Settings and Onboarding can validate local
checkouts and task creation can create or delete task-owned branches and worktrees.

## Schema

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
  terminalClosed?: boolean
  terminalLayout?: TaskTerminalLayout
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

type TaskTerminalLayout = {
  activePaneId: string
  panes: TaskTerminalPane[]
  root: TerminalLayoutNode
}

type TaskTerminalPane = {
  id: string
  sessionId: string
  cwd: string
  label: string
  source: TaskSurfaceSelection
}

type TerminalLayoutNode =
  | { kind: 'pane'; paneId: string }
  | {
      kind: 'split'
      direction: 'vertical' | 'horizontal'
      first: TerminalLayoutNode
      second: TerminalLayoutNode
    }

type TaskSurfaceSelection =
  | { kind: 'task-terminal' }
  | { kind: 'repo'; taskRepoId: string }
```

## Rules

- Use `task` in product code, not `workspace`.
- `layout.window` persists the normal logical window size and optional logical window position.
  Tauri restores both during startup, and the shell saves later resize or move events. Fullscreen
  resize and move events must not overwrite it.
- `layout.sidePanels` persists the left and right panel widths. Open or closed panel visibility is
  runtime shell state for now.
- `repoRegistry` is global repo config. `TaskRepo` is the repo instance inside a task.
- Every `Task` owns a default `TaskTerminal`. It starts in `~` and is the task's scratch or
  orchestration surface when no repo is selected.
- `Task.terminalLayout` is optional. Missing layout means "render the selected task surface as one
  pane". Once the user splits, Piñata persists the pane tree, active pane id, and each pane's
  `sessionId`, `cwd`, label, and source.
- `Task.terminalClosed` is optional. When true and no `Task.terminalLayout` exists, the selected
  task shows an empty main surface instead of auto-opening the default pane. Selecting the task,
  selecting a repo, pressing `⌘T`, or splitting clears it and reopens a pane.
- `TaskTerminalPane.source` records whether the pane was created from the task terminal or a
  specific task repo. Sidebar selection uses that source to focus a matching pane before replacing
  the active pane.
- Tasks may have zero repos. Repo-less tasks are valid and open their task terminal immediately.
- `repositoryDefaults.worktreeBasePath` is the shared worktree base. Per-repo
  `worktreeBasePath` is an optional override only.
- The effective repo worktree base is `repo.worktreeBasePath ?? <repository default>/<repo name>`.
- If a per-repo override starts with `./`, resolve it by joining the remainder onto the repo's
  canonical `source.path`. Example: `./worktrees` for `/repos/api` resolves to
  `/repos/api/worktrees`.
- A task repo worktree path is `<effective repo worktree base>/<6-char task-id hash>-<task slug>`.
  The leaf is derived from the immutable branch generated when that repo row is added, so later
  task renames do not silently move planned worktrees.
- Settings and Onboarding register repos by inspecting a local git checkout, then storing canonical
  path, branches, default branch, optional org, and optional worktree override in `repoRegistry`.
- Registration de-dupes by repo name or canonical source path.
- Settings removal deletes only the `repoRegistry` entry and is blocked while any `TaskRepo`
  references that `RegisteredRepo.id`.
- New Task always creates a task terminal. If repos are attached, it also stores the chosen base
  branch and topic branch (`feat/<6-char task-id hash>-<slug>`), creates repo branches and
  worktrees in one blocking transaction, persists `TaskRepo.worktreePath`, then selects the task
  terminal. Repositories run in parallel, while branch and worktree setup inside one repository stay
  sequential. Git creation resolves the base branch locally first, then falls back to
  `origin/<base branch>` when only the remote ref exists.
- Task editing can update task name, repo membership, and base branches. Existing `TaskRepo.id`,
  `branch`, and `worktreePath` are preserved when the registered repo stays in the task.
- Task editing that adds or removes repos resets the task terminal split layout and kills stale
  split-only sessions. This avoids panes pointing at deleted or newly hidden worktrees.
- Branch identity is immutable after a task repo row is created. Renaming a task must not rename
  existing planned or materialized branches; newly added repos use the existing task id hash plus
  the current task slug. If `worktreePath` exists, preserve the existing `TaskRepo.baseBranch` too
  and treat the base branch as locked in task edit UI.
- Task deletion kills the task terminal, removes task-owned worktrees and branches, then removes the
  task, its surface selection entry, and its expanded state. If the deleted task was selected,
  selection moves to the first remaining task terminal.
- Terminal processes are runtime state. `Task.terminal.id`, `TaskRepo.id`, and
  `TaskTerminalPane.sessionId` derive bundled tmux session names. Their persisted `cwd` values give
  the shell start directory if the session must be recreated.
- `selection.surfaceByTaskId` points at either the task terminal or a `TaskRepo.id`, not a
  `RegisteredRepo.id`.
- Rust and Vue normalize legacy state where `selection.taskRepoIdByTaskId` existed. `null` legacy
  repo selections become task-terminal selections.
- Do not persist derived git state here: diffs, PRs, auth health, ports, live terminal process
  details, or terminal scrollback.
