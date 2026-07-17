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
state changes. Rust also exposes `inspect_repository` so Settings can validate a local git checkout
before adding it to `repoRegistry`.

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
- Settings registers repos by inspecting a local git checkout, then storing canonical path, branches,
  default branch, optional org, and optional worktree override in `repoRegistry`.
- Registration de-dupes by repo name or canonical source path.
- Settings removal deletes only the `repoRegistry` entry and is blocked while any `TaskRepo`
  references that `RegisteredRepo.id`.
- `selection.taskRepoIdByTaskId` points at `TaskRepo.id`, not `RegisteredRepo.id`.
- Do not persist derived git state here: diffs, PRs, auth health, ports, terminals, tabs, panes.
  Add those when their feature ships.
