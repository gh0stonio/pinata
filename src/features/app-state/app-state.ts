import { invoke } from '@tauri-apps/api/core'

export type AppState = {
  version: 1
  layout: AppLayout
  repositoryDefaults: RepositoryDefaults
  repoRegistry: RegisteredRepo[]
  tasks: Task[]
  selection: AppSelection
}

export const DEFAULT_WORKTREE_BASE_PATH = '~/.pinata/worktrees'
export const TASK_TERMINAL_CWD = '~'
export const DEFAULT_APP_LAYOUT: AppLayout = {
  window: {
    width: 1200,
    height: 780,
  },
  sidePanels: {
    leftWidth: 264,
    rightWidth: 300,
  },
}
export const SIDE_PANEL_WIDTH_LIMITS = {
  left: {
    min: 200,
    max: 440,
  },
  right: {
    min: 260,
    max: 520,
  },
} as const

export type AppLayout = {
  window: AppWindowLayout
  sidePanels: AppSidePanelLayout
}

export type AppWindowLayout = {
  width: number
  height: number
  x?: number
  y?: number
}

export type AppSidePanelLayout = {
  leftWidth: number
  rightWidth: number
}

export type RepositoryDefaults = {
  worktreeBasePath: string
}

export type RegisteredRepo = {
  id: string
  name: string
  org?: string
  description?: string
  source: RepoSource
  branches: string[]
  defaultBranch: string
  worktreeBasePath?: string
  githubAccount?: string
}

export type RepositoryInspection = {
  name: string
  org?: string
  path: string
  branches: string[]
  defaultBranch: string
}

type RegisteredRepoOptions = {
  name?: string
  defaultBranch?: string
  worktreeBasePath?: string
}

type RegisteredRepoCandidate = {
  name?: string
  path?: string
}

export type RepoSource = {
  kind: 'local'
  path: string
}

export type Task = {
  id: string
  name: string
  color: string
  terminal: TaskTerminal
  repos: TaskRepo[]
}

export type TaskTerminal = {
  id: string
  cwd: string
}

export type TaskRepo = {
  id: string
  registeredRepoId: string
  baseBranch: string
  branch: string
  worktreePath?: string
}

export type NewTaskRepoInput = {
  registeredRepoId: string
  baseBranch: string
}

export type NewTaskInput = {
  name: string
  repos: NewTaskRepoInput[]
}

export type TaskRepoGitOperation = {
  sourcePath: string
  baseBranch: string
  branch: string
  worktreePath: string
  progressId?: string
}

export type AppSelection = {
  taskId: string | null
  surfaceByTaskId: Record<string, TaskSurfaceSelection>
  expandedTaskIds: string[]
  taskRepoIdByTaskId?: Record<string, string | null>
}

export type TaskSurfaceSelection =
  | { kind: 'task-terminal' }
  | { kind: 'repo'; taskRepoId: string }

export function createEmptyAppState(): AppState {
  return {
    version: 1,
    layout: {
      window: { ...DEFAULT_APP_LAYOUT.window },
      sidePanels: { ...DEFAULT_APP_LAYOUT.sidePanels },
    },
    repositoryDefaults: {
      worktreeBasePath: DEFAULT_WORKTREE_BASE_PATH,
    },
    repoRegistry: [],
    tasks: [],
    selection: {
      taskId: null,
      surfaceByTaskId: {},
      expandedTaskIds: [],
    },
  }
}

export function loadAppState(): Promise<AppState> {
  return invoke<AppState>('load_app_state').then(normalizeAppState)
}

export function saveAppState(state: AppState): Promise<void> {
  return invoke('save_app_state', { state: normalizeAppState(state) })
}

export function inspectRepository(path: string): Promise<RepositoryInspection> {
  return invoke<RepositoryInspection>('inspect_repository', { path })
}

export function createTaskRepoWorktree(input: TaskRepoGitOperation): Promise<string> {
  return invoke<string>('create_task_repo_worktree', { input })
}

export function deleteTaskRepoWorktree(input: TaskRepoGitOperation): Promise<void> {
  return invoke('delete_task_repo_worktree', { input })
}

export function findRegisteredRepo(state: AppState, id: string): RegisteredRepo | undefined {
  return state.repoRegistry.find((repo) => repo.id === id)
}

export function hasRegisteredRepo(repos: RegisteredRepo[], candidate: RegisteredRepoCandidate) {
  const normalizedName = candidate.name?.trim().toLowerCase()
  const normalizedPath = candidate.path?.trim()

  return repos.some(
    (repo) =>
      (Boolean(normalizedName) && repo.name.toLowerCase() === normalizedName) ||
      (Boolean(normalizedPath) && repo.source.path === normalizedPath),
  )
}

export function createRegisteredRepoFromInspection(
  inspection: RepositoryInspection,
  options: RegisteredRepoOptions = {},
): RegisteredRepo {
  const name = options.name?.trim() || inspection.name
  const defaultBranch = options.defaultBranch?.trim() || inspection.defaultBranch
  const worktreeBasePath = options.worktreeBasePath?.trim()

  return {
    id: `repo-${crypto.randomUUID()}`,
    name,
    org: inspection.org,
    source: { kind: 'local', path: inspection.path },
    branches: inspection.branches.includes(defaultBranch)
      ? inspection.branches
      : [defaultBranch, ...inspection.branches],
    defaultBranch,
    worktreeBasePath: worktreeBasePath || undefined,
  }
}

export function defaultRepoWorktreePath(defaults: RepositoryDefaults, repoName: string) {
  const basePath = (defaults.worktreeBasePath.trim() || DEFAULT_WORKTREE_BASE_PATH).replace(/\/+$/, '')

  return `${basePath}/${repoName}`
}

function joinPath(basePath: string, childPath: string) {
  const base = basePath.replace(/\/+$/, '')
  const child = childPath.replace(/^\/+/, '')

  return child ? `${base}/${child}` : base
}

export function effectiveRepoWorktreeBasePath(
  defaults: RepositoryDefaults,
  repo: Pick<RegisteredRepo, 'name' | 'source' | 'worktreeBasePath'>,
) {
  const override = repo.worktreeBasePath?.trim()

  if (override?.startsWith('./')) {
    return joinPath(repo.source.path, override.slice(2))
  }

  return override || defaultRepoWorktreePath(defaults, repo.name)
}

export function plannedTaskRepoWorktreePath(
  defaults: RepositoryDefaults,
  task: Pick<Task, 'id' | 'name'>,
  taskRepo: Pick<TaskRepo, 'branch' | 'worktreePath'>,
  repo: Pick<RegisteredRepo, 'name' | 'source' | 'worktreeBasePath'>,
) {
  if (taskRepo.worktreePath) {
    return taskRepo.worktreePath
  }

  const taskLeaf =
    slugifyTaskName(taskRepo.branch.replace(/^feat\//, '')) ||
    `${shortTaskIdHash(task.id)}-${taskNameSlug(task.name)}`

  return joinPath(effectiveRepoWorktreeBasePath(defaults, repo), taskLeaf)
}

export function taskTerminalForTaskId(taskId: string): TaskTerminal {
  return {
    id: `task-terminal-${taskId}`,
    cwd: TASK_TERMINAL_CWD,
  }
}

export function taskSelectedSurface(task: Task, selection: AppSelection): TaskSurfaceSelection {
  const surface = selection.surfaceByTaskId[task.id]

  if (surface?.kind === 'repo' && task.repos.some((repo) => repo.id === surface.taskRepoId)) {
    return surface
  }

  return { kind: 'task-terminal' }
}

export function selectedTaskRepo(task: Task, selection: AppSelection) {
  const surface = taskSelectedSurface(task, selection)

  return surface.kind === 'repo'
    ? task.repos.find((repo) => repo.id === surface.taskRepoId)
    : undefined
}

export function normalizeAppState(state: AppState): AppState {
  const tasks = state.tasks.map(normalizeTask)
  const taskIds = new Set(tasks.map((task) => task.id))
  const legacySelection = state.selection.taskRepoIdByTaskId ?? {}
  const surfaceByTaskId: Record<string, TaskSurfaceSelection> = {}

  for (const task of tasks) {
    const surface = state.selection.surfaceByTaskId?.[task.id]
    const legacyTaskRepoId = legacySelection[task.id]

    if (surface?.kind === 'repo' && task.repos.some((repo) => repo.id === surface.taskRepoId)) {
      surfaceByTaskId[task.id] = surface
    } else if (legacyTaskRepoId && task.repos.some((repo) => repo.id === legacyTaskRepoId)) {
      surfaceByTaskId[task.id] = { kind: 'repo', taskRepoId: legacyTaskRepoId }
    } else {
      surfaceByTaskId[task.id] = { kind: 'task-terminal' }
    }
  }

  const selectedTaskId = state.selection.taskId && taskIds.has(state.selection.taskId)
    ? state.selection.taskId
    : tasks[0]?.id ?? null

  return {
    ...state,
    tasks,
    selection: {
      taskId: selectedTaskId,
      surfaceByTaskId,
      expandedTaskIds: state.selection.expandedTaskIds.filter((taskId) => taskIds.has(taskId)),
    },
  }
}

export function slugifyTaskName(name: string) {
  return name
    .trim()
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
}

function taskNameSlug(name: string) {
  return slugifyTaskName(name) || 'task'
}

function shortTaskIdHash(taskId: string) {
  let hash = 2166136261

  for (let index = 0; index < taskId.length; index += 1) {
    hash ^= taskId.charCodeAt(index)
    hash = Math.imul(hash, 16777619)
  }

  return (hash >>> 0).toString(16).padStart(8, '0').slice(0, 6)
}

function taskBranchForTask(taskId: string, taskName: string) {
  return `feat/${shortTaskIdHash(taskId)}-${taskNameSlug(taskName)}`
}

export function createTask(input: NewTaskInput): Task {
  const name = input.name.trim()
  const id = `task-${taskNameSlug(name)}-${crypto.randomUUID()}`
  const branch = taskBranchForTask(id, name)

  return {
    id,
    name,
    color: '#8f989d',
    terminal: taskTerminalForTaskId(id),
    repos: input.repos.map((repo) => ({
      id: `task-repo-${crypto.randomUUID()}`,
      registeredRepoId: repo.registeredRepoId,
      baseBranch: repo.baseBranch,
      branch,
    })),
  }
}

function normalizeTask(task: Task): Task {
  return {
    ...task,
    terminal:
      task.terminal?.id && task.terminal.cwd
        ? task.terminal
        : taskTerminalForTaskId(task.id),
  }
}

export function updateTask(task: Task, input: NewTaskInput): Task {
  const name = input.name.trim()
  const branch = taskBranchForTask(task.id, name)

  return {
    ...task,
    name,
    repos: input.repos.map((repo) => {
      const existingRepo = task.repos.find(
        (taskRepo) => taskRepo.registeredRepoId === repo.registeredRepoId,
      )

      return {
        id: existingRepo?.id ?? `task-repo-${crypto.randomUUID()}`,
        registeredRepoId: repo.registeredRepoId,
        baseBranch: existingRepo?.worktreePath ? existingRepo.baseBranch : repo.baseBranch,
        branch: existingRepo?.branch ?? branch,
        worktreePath: existingRepo?.worktreePath,
      }
    }),
  }
}
