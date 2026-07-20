# App State

## Purpose

Persist the durable product state that should survive app restarts: registered repositories, tasks,
and selection. Settings still own theme and accent separately.

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
  repositoryDefaults: {
    worktreeBasePath: string
  }
  repoRegistry: RegisteredRepo[]
  tasks: Task[]
  selection: {
    taskId: string | null
    taskRepoIdByTaskId: Record<string, string | null>
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
  repos: TaskRepo[]
}

type TaskRepo = {
  id: string
  registeredRepoId: string
  baseBranch: string
  branch: string
  worktreePath?: string
}
```

## Rules

- Use `task` in product code, not `workspace`.
- `repoRegistry` is global repo config. `TaskRepo` is the repo instance inside a task.
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
- New Task creates task records from registered repos only. It stores the chosen base branch and
  topic branch (`feat/<6-char task-id hash>-<slug>`), creates the branch and worktree synchronously,
  persists `TaskRepo.worktreePath`, then selects and expands the new task. Git creation resolves the
  base branch locally first, then falls back to `origin/<base branch>` when only the remote ref exists.
- Task editing can update task name, repo membership, and base branches. Existing `TaskRepo.id`,
  `branch`, and `worktreePath` are preserved when the registered repo stays in the task.
- Branch identity is immutable after a task repo row is created. Renaming a task must not rename
  existing planned or materialized branches; newly added repos use the existing task id hash plus
  the current task slug. If `worktreePath` exists, preserve the existing `TaskRepo.baseBranch` too
  and treat the base branch as locked in task edit UI.
- Task deletion removes task-owned worktrees and branches before removing the task, its selection
  entry, and its expanded state. If the deleted task was selected, selection moves to the first
  remaining task.
- Terminal sessions are runtime state. `TaskRepo.id` derives the bundled tmux session name and
  `TaskRepo.worktreePath` gives the shell start directory if the session must be recreated.
- `selection.taskRepoIdByTaskId` points at `TaskRepo.id`, not `RegisteredRepo.id`.
- Do not persist derived git state here: diffs, PRs, auth health, ports, or live terminal process
  details. Add durable terminal layout only when tabs and panes ship.
