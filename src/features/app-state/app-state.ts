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
  terminalClosed?: boolean
  terminalClosedBySurface?: Record<string, boolean>
  terminalLayout?: TaskTerminalLayout
  terminalLayouts?: Record<string, TaskTerminalLayout>
}

export type TaskTerminal = {
  id: string
  cwd: string
}

export type TerminalSplitDirection = 'vertical' | 'horizontal'

export type TerminalTarget = {
  id: string
  cwd: string
  label: string
  source: TaskSurfaceSelection
}

export type TaskTerminalPane = {
  id: string
  sessionId: string
  cwd: string
  label: string
  source: TaskSurfaceSelection
}

export type TerminalLayoutNode =
  | { kind: 'pane'; paneId: string }
  | {
      kind: 'split'
      direction: TerminalSplitDirection
      first: TerminalLayoutNode
      second: TerminalLayoutNode
    }

export type TaskTerminalLayout = {
  activePaneId: string
  panes: TaskTerminalPane[]
  root: TerminalLayoutNode
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

export function terminalTargetForTaskSurface(
  state: Pick<AppState, 'repoRegistry'>,
  task: Task,
  surface: TaskSurfaceSelection,
): TerminalTarget | undefined {
  if (surface.kind === 'repo') {
    const taskRepo = task.repos.find((repo) => repo.id === surface.taskRepoId)
    const registeredRepo = taskRepo
      ? state.repoRegistry.find((repo) => repo.id === taskRepo.registeredRepoId)
      : undefined

    return taskRepo?.worktreePath && registeredRepo
      ? {
          id: taskRepo.id,
          cwd: taskRepo.worktreePath,
          label: registeredRepo.name,
          source: surface,
        }
      : undefined
  }

  return {
    id: task.terminal.id,
    cwd: task.terminal.cwd,
    label: task.name,
    source: surface,
  }
}

export function selectedTerminalTarget(state: AppState, task: Task) {
  return terminalTargetForTaskSurface(state, task, taskSelectedSurface(task, state.selection))
}

export function effectiveTerminalLayout(
  task: Task,
  fallbackTarget: TerminalTarget,
): TaskTerminalLayout | undefined {
  if (isTerminalSurfaceClosed(task, fallbackTarget.source)) {
    return undefined
  }

  const layout = terminalLayoutForTarget(task, fallbackTarget)

  if (layout) {
    return layout
  }

  const pane = terminalPaneForTarget(fallbackTarget)

  return {
    activePaneId: pane.id,
    panes: [pane],
    root: { kind: 'pane', paneId: pane.id },
  }
}

export function splitTaskTerminalLayout(
  task: Task,
  fallbackTarget: TerminalTarget,
  direction: TerminalSplitDirection,
): Task {
  const layout = terminalLayoutForTarget(task, fallbackTarget) ?? defaultTerminalLayout(fallbackTarget)
  const activePane =
    layout.panes.find((pane) => pane.id === layout.activePaneId) ?? layout.panes[0]
  const newPaneId = `terminal-pane-${crypto.randomUUID()}`
  const newPane = {
    ...activePane,
    id: newPaneId,
    sessionId: newPaneId,
  }

  return withTerminalLayoutForTarget(
    task,
    fallbackTarget,
    {
      activePaneId: newPane.id,
      panes: [...layout.panes, newPane],
      root: splitTerminalNode(layout.root, activePane.id, direction, newPane.id),
    },
  )
}

export function activateTaskTerminalPane(
  task: Task,
  fallbackTarget: TerminalTarget,
  paneId: string,
): Task {
  const layout = effectiveTerminalLayout(task, fallbackTarget)

  if (!layout?.panes.some((pane) => pane.id === paneId)) {
    return task
  }

  if (layout.activePaneId === paneId) {
    return task
  }

  return withTerminalLayoutForTarget(
    task,
    fallbackTarget,
    {
      ...layout,
      activePaneId: paneId,
    },
  )
}

export function focusTaskTerminalTarget(task: Task, target: TerminalTarget): Task {
  if (!isTerminalSurfaceClosed(task, target.source)) {
    return task
  }

  return withTerminalLayoutForTarget(task, target, terminalLayoutForTarget(task, target))
}

export type CloseTaskTerminalPaneResult = {
  task: Task
  closedPane?: TaskTerminalPane
  closedLast: boolean
}

export function closeTaskTerminalPane(
  task: Task,
  fallbackTarget: TerminalTarget,
  paneId: string,
): CloseTaskTerminalPaneResult {
  const layout = effectiveTerminalLayout(task, fallbackTarget)
  const closedPane = layout?.panes.find((pane) => pane.id === paneId)

  if (!layout || !closedPane) {
    return { task, closedLast: false }
  }

  if (layout.panes.length === 1) {
    return {
      task: withClosedTerminalSurface(task, fallbackTarget),
      closedPane,
      closedLast: true,
    }
  }

  const panes = layout.panes.filter((pane) => pane.id !== paneId)
  const paneIds = new Set(panes.map((pane) => pane.id))
  const root = removeTerminalPaneNode(layout.root, paneId)
  const activePaneId = nextActivePaneId(layout, paneIds, paneId, root)

  if (!root || !activePaneId) {
    return {
      task: withClosedTerminalSurface(task, fallbackTarget),
      closedPane,
      closedLast: true,
    }
  }

  return {
    task: withTerminalLayoutForTarget(
      task,
      fallbackTarget,
      {
        activePaneId,
        panes,
        root,
      },
    ),
    closedPane,
    closedLast: false,
  }
}

export function terminalPanesForTask(task: Task) {
  return [
    ...(task.terminalLayout?.panes ?? []),
    ...Object.values(task.terminalLayouts ?? {}).flatMap((layout) => layout.panes),
  ]
}

export function terminalSessionIdsForTask(task: Task) {
  return Array.from(
    new Set([
      task.terminal.id,
      ...task.repos.map((repo) => repo.id),
      ...terminalPanesForTask(task).map((pane) => pane.sessionId),
    ]),
  )
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
  const terminal =
    task.terminal?.id && task.terminal.cwd ? task.terminal : taskTerminalForTaskId(task.id)
  const terminalLayout = normalizeTerminalLayout(task.terminalLayout, terminal, task.repos)
  const terminalLayouts = normalizeTerminalLayouts(task.terminalLayouts, terminal, task.repos)
  const terminalClosedBySurface = normalizeTerminalClosedBySurface(
    task.terminalClosedBySurface,
    task.repos,
  )

  return {
    ...task,
    terminal,
    terminalClosed: terminalLayout || terminalLayouts ? false : Boolean(task.terminalClosed),
    terminalClosedBySurface,
    terminalLayout,
    terminalLayouts,
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

function terminalPaneForTarget(target: TerminalTarget): TaskTerminalPane {
  return {
    id: target.id,
    sessionId: target.id,
    cwd: target.cwd,
    label: target.label,
    source: target.source,
  }
}

function defaultTerminalLayout(fallbackTarget: TerminalTarget): TaskTerminalLayout {
  const pane = terminalPaneForTarget(fallbackTarget)

  return {
    activePaneId: pane.id,
    panes: [pane],
    root: { kind: 'pane', paneId: pane.id },
  }
}

function terminalSurfaceKey(source: TaskSurfaceSelection) {
  return source.kind === 'task-terminal' ? 'task-terminal' : `repo:${source.taskRepoId}`
}

function surfaceFromTerminalKey(
  key: string,
  repos: TaskRepo[],
): TaskSurfaceSelection | undefined {
  if (key === 'task-terminal') {
    return { kind: 'task-terminal' }
  }

  const repoId = key.startsWith('repo:') ? key.slice(5) : undefined

  return repoId && repos.some((repo) => repo.id === repoId)
    ? { kind: 'repo', taskRepoId: repoId }
    : undefined
}

function isTerminalSurfaceClosed(task: Task, source: TaskSurfaceSelection) {
  const key = terminalSurfaceKey(source)

  return Boolean(task.terminalClosedBySurface?.[key] ?? task.terminalClosed)
}

function withTerminalLayoutForTarget(
  task: Task,
  target: TerminalTarget,
  layout: TaskTerminalLayout | undefined,
): Task {
  const key = terminalSurfaceKey(target.source)
  const terminalLayouts = { ...(task.terminalLayouts ?? {}) }
  const terminalClosedBySurface = { ...(task.terminalClosedBySurface ?? {}) }

  if (layout) {
    terminalLayouts[key] = layout
  } else {
    delete terminalLayouts[key]
  }

  delete terminalClosedBySurface[key]

  return {
    ...task,
    terminalClosed: false,
    terminalClosedBySurface: Object.keys(terminalClosedBySurface).length
      ? terminalClosedBySurface
      : undefined,
    terminalLayout: undefined,
    terminalLayouts: Object.keys(terminalLayouts).length ? terminalLayouts : undefined,
  }
}

function withClosedTerminalSurface(task: Task, target: TerminalTarget): Task {
  const key = terminalSurfaceKey(target.source)
  const terminalLayouts = { ...(task.terminalLayouts ?? {}) }
  const terminalClosedBySurface = { ...(task.terminalClosedBySurface ?? {}) }

  delete terminalLayouts[key]
  terminalClosedBySurface[key] = true

  return {
    ...task,
    terminalClosed: false,
    terminalClosedBySurface,
    terminalLayout: undefined,
    terminalLayouts: Object.keys(terminalLayouts).length ? terminalLayouts : undefined,
  }
}

function terminalLayoutForTarget(
  task: Task,
  target: TerminalTarget,
): TaskTerminalLayout | undefined {
  const key = terminalSurfaceKey(target.source)
  const keyedLayout = normalizeTerminalLayout(
    task.terminalLayouts?.[key],
    task.terminal,
    task.repos,
  )

  if (keyedLayout) {
    return terminalLayoutForSurface(keyedLayout, target.source)
  }

  const legacyLayout = normalizeTerminalLayout(task.terminalLayout, task.terminal, task.repos)

  return legacyLayout ? terminalLayoutForSurface(legacyLayout, target.source) : undefined
}

function terminalLayoutForSurface(
  layout: TaskTerminalLayout,
  source: TaskSurfaceSelection,
): TaskTerminalLayout | undefined {
  const panes = layout.panes.filter((pane) => sameTerminalSource(pane.source, source))
  const paneIds = new Set(panes.map((pane) => pane.id))
  const root = normalizeTerminalNode(layout.root, paneIds)

  if (!panes.length || !root) {
    return undefined
  }

  return {
    activePaneId: paneIds.has(layout.activePaneId) ? layout.activePaneId : panes[0].id,
    panes,
    root,
  }
}

function normalizeTerminalLayouts(
  layouts: Record<string, TaskTerminalLayout> | undefined,
  terminal: TaskTerminal,
  repos: TaskRepo[],
): Record<string, TaskTerminalLayout> | undefined {
  const normalizedEntries = Object.entries(layouts ?? {}).flatMap(([key, layout]) => {
    const source = surfaceFromTerminalKey(key, repos)
    const normalizedLayout = normalizeTerminalLayout(layout, terminal, repos)
    const surfaceLayout = source && normalizedLayout
      ? terminalLayoutForSurface(normalizedLayout, source)
      : undefined

    return surfaceLayout ? [[key, surfaceLayout] as const] : []
  })

  return normalizedEntries.length ? Object.fromEntries(normalizedEntries) : undefined
}

function normalizeTerminalClosedBySurface(
  closedBySurface: Record<string, boolean> | undefined,
  repos: TaskRepo[],
): Record<string, boolean> | undefined {
  const entries = Object.entries(closedBySurface ?? {}).filter(
    ([key, closed]) => closed && surfaceFromTerminalKey(key, repos),
  )

  return entries.length ? Object.fromEntries(entries) : undefined
}

function normalizeTerminalLayout(
  layout: TaskTerminalLayout | undefined,
  terminal?: TaskTerminal,
  repos: TaskRepo[] = [],
): TaskTerminalLayout | undefined {
  if (!layout?.panes.length) {
    return undefined
  }

  const panes = layout.panes
    .filter((pane) => pane.id.trim() && pane.sessionId.trim() && pane.cwd.trim())
    .map((pane) => ({
      ...pane,
      source: terminalPaneSource(pane, terminal, repos),
    }))
  const paneIds = new Set(panes.map((pane) => pane.id))
  const root = normalizeTerminalNode(layout.root, paneIds)

  if (!panes.length || !root) {
    return undefined
  }

  return {
    activePaneId: paneIds.has(layout.activePaneId) ? layout.activePaneId : panes[0].id,
    panes,
    root,
  }
}

function normalizeTerminalNode(
  node: TerminalLayoutNode | undefined,
  paneIds: Set<string>,
): TerminalLayoutNode | undefined {
  if (!node) {
    return undefined
  }

  if (node.kind === 'pane') {
    return paneIds.has(node.paneId) ? node : undefined
  }

  const first = normalizeTerminalNode(node.first, paneIds)
  const second = normalizeTerminalNode(node.second, paneIds)

  if (first && second) {
    return { ...node, first, second }
  }

  return first ?? second
}

function splitTerminalNode(
  node: TerminalLayoutNode,
  paneId: string,
  direction: TerminalSplitDirection,
  newPaneId: string,
): TerminalLayoutNode {
  if (node.kind === 'pane') {
    return node.paneId === paneId
      ? {
          kind: 'split',
          direction,
          first: node,
          second: { kind: 'pane', paneId: newPaneId },
        }
      : node
  }

  return {
    ...node,
    first: splitTerminalNode(node.first, paneId, direction, newPaneId),
    second: splitTerminalNode(node.second, paneId, direction, newPaneId),
  }
}

function removeTerminalPaneNode(
  node: TerminalLayoutNode,
  paneId: string,
): TerminalLayoutNode | undefined {
  if (node.kind === 'pane') {
    return node.paneId === paneId ? undefined : node
  }

  const first = removeTerminalPaneNode(node.first, paneId)
  const second = removeTerminalPaneNode(node.second, paneId)

  if (first && second) {
    return { ...node, first, second }
  }

  return first ?? second
}

function nextActivePaneId(
  layout: TaskTerminalLayout,
  paneIds: Set<string>,
  closedPaneId: string,
  root: TerminalLayoutNode | undefined,
): string | undefined {
  if (paneIds.has(layout.activePaneId)) {
    return layout.activePaneId
  }

  const closestPaneId = closestTerminalPaneId(layout.root, closedPaneId)

  if (closestPaneId && paneIds.has(closestPaneId)) {
    return closestPaneId
  }

  return root ? firstTerminalPaneId(root) : undefined
}

function closestTerminalPaneId(
  node: TerminalLayoutNode,
  paneId: string,
): string | undefined {
  if (node.kind === 'pane') {
    return undefined
  }

  if (terminalNodeHasPane(node.first, paneId)) {
    return closestTerminalPaneId(node.first, paneId) ?? firstTerminalPaneId(node.second)
  }

  if (terminalNodeHasPane(node.second, paneId)) {
    return closestTerminalPaneId(node.second, paneId) ?? firstTerminalPaneId(node.first)
  }

  return undefined
}

function firstTerminalPaneId(node: TerminalLayoutNode): string | undefined {
  return node.kind === 'pane' ? node.paneId : firstTerminalPaneId(node.first)
}

function terminalNodeHasPane(node: TerminalLayoutNode, paneId: string): boolean {
  if (node.kind === 'pane') {
    return node.paneId === paneId
  }

  return terminalNodeHasPane(node.first, paneId) || terminalNodeHasPane(node.second, paneId)
}

function terminalPaneSource(
  pane: TaskTerminalPane,
  terminal: TaskTerminal | undefined,
  repos: TaskRepo[],
): TaskSurfaceSelection {
  const source = pane.source

  if (source?.kind === 'repo' && repos.some((repo) => repo.id === source.taskRepoId)) {
    return source
  }

  if (source?.kind === 'task-terminal') {
    return source
  }

  if (terminal && (pane.sessionId === terminal.id || pane.id === terminal.id)) {
    return { kind: 'task-terminal' }
  }

  const repo = repos.find((item) => item.id === pane.sessionId || item.id === pane.id)

  return repo ? { kind: 'repo', taskRepoId: repo.id } : { kind: 'task-terminal' }
}

function sameTerminalSource(left: TaskSurfaceSelection, right: TaskSurfaceSelection) {
  if (left.kind !== right.kind) {
    return false
  }

  if (left.kind === 'task-terminal') {
    return true
  }

  return right.kind === 'repo' && left.taskRepoId === right.taskRepoId
}
