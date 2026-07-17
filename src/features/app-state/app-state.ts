import { invoke } from '@tauri-apps/api/core'

export type AppState = {
  version: 1
  repositoryDefaults: RepositoryDefaults
  repoRegistry: RegisteredRepo[]
  tasks: Task[]
  selection: AppSelection
}

export const DEFAULT_WORKTREE_BASE_PATH = '~/.pinata/worktrees'

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

export type RepoSource = {
  kind: 'local'
  path: string
}

export type Task = {
  id: string
  name: string
  color: string
  repos: TaskRepo[]
}

export type TaskRepo = {
  id: string
  registeredRepoId: string
  baseBranch: string
  branch: string
  worktreePath?: string
}

export type AppSelection = {
  taskId: string | null
  taskRepoIdByTaskId: Record<string, string | null>
  expandedTaskIds: string[]
}

export function createEmptyAppState(): AppState {
  return {
    version: 1,
    repositoryDefaults: {
      worktreeBasePath: DEFAULT_WORKTREE_BASE_PATH,
    },
    repoRegistry: [],
    tasks: [],
    selection: {
      taskId: null,
      taskRepoIdByTaskId: {},
      expandedTaskIds: [],
    },
  }
}

export function loadAppState(): Promise<AppState> {
  return invoke<AppState>('load_app_state')
}

export function saveAppState(state: AppState): Promise<void> {
  return invoke('save_app_state', { state })
}

export function inspectRepository(path: string): Promise<RepositoryInspection> {
  return invoke<RepositoryInspection>('inspect_repository', { path })
}

export function findRegisteredRepo(state: AppState, id: string): RegisteredRepo | undefined {
  return state.repoRegistry.find((repo) => repo.id === id)
}

export function defaultRepoWorktreePath(defaults: RepositoryDefaults, repoName: string) {
  const basePath = (defaults.worktreeBasePath.trim() || DEFAULT_WORKTREE_BASE_PATH).replace(/\/+$/, '')

  return `${basePath}/${repoName}`
}

export function effectiveRepoWorktreeBasePath(
  defaults: RepositoryDefaults,
  repo: Pick<RegisteredRepo, 'name' | 'worktreeBasePath'>,
) {
  return repo.worktreeBasePath?.trim() || defaultRepoWorktreePath(defaults, repo.name)
}
