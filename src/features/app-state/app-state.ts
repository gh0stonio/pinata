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
  terminalTabs?: Record<string, TaskTerminalTabs>
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

export type TaskTerminalTabKind = 'shell'

export type TaskTerminalTab = {
  id: string
  title: string
  kind: TaskTerminalTabKind
  layout: TaskTerminalLayout
}

export type TaskTerminalTabs = {
  activeTabId: string
  tabs: TaskTerminalTab[]
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
  return selectedTerminalTab(task, fallbackTarget)?.layout
}

export function effectiveTerminalTabs(
  task: Task,
  fallbackTarget: TerminalTarget,
): TaskTerminalTabs | undefined {
  if (isTerminalSurfaceClosed(task, fallbackTarget.source)) {
    return undefined
  }

  return terminalTabsForTarget(task, fallbackTarget) ?? defaultTerminalTabs(fallbackTarget)
}

export function selectedTerminalTab(
  task: Task,
  fallbackTarget: TerminalTarget,
): TaskTerminalTab | undefined {
  const tabs = effectiveTerminalTabs(task, fallbackTarget)

  return tabs?.tabs.find((tab) => tab.id === tabs.activeTabId) ?? tabs?.tabs[0]
}

export function createTaskTerminalTab(task: Task, fallbackTarget: TerminalTarget): Task {
  const currentTabs = isTerminalSurfaceClosed(task, fallbackTarget.source)
    ? undefined
    : terminalTabsForTarget(task, fallbackTarget) ?? defaultTerminalTabs(fallbackTarget)
  const nextTab = newTerminalTab(fallbackTarget)

  return withTerminalTabsForTarget(task, fallbackTarget, {
    activeTabId: nextTab.id,
    tabs: [...(currentTabs?.tabs ?? []), nextTab],
  })
}

export function selectTaskTerminalTab(
  task: Task,
  fallbackTarget: TerminalTarget,
  tabId: string,
): Task {
  const tabs = effectiveTerminalTabs(task, fallbackTarget)

  if (!tabs?.tabs.some((tab) => tab.id === tabId) || tabs.activeTabId === tabId) {
    return task
  }

  return withTerminalTabsForTarget(task, fallbackTarget, {
    ...tabs,
    activeTabId: tabId,
  })
}

export function renameTaskTerminalTab(
  task: Task,
  fallbackTarget: TerminalTarget,
  tabId: string,
  title: string,
): Task {
  const tabs = effectiveTerminalTabs(task, fallbackTarget)
  const nextTitle = title.trim()

  if (!tabs || !nextTitle) {
    return task
  }

  return withTerminalTabsForTarget(task, fallbackTarget, {
    ...tabs,
    tabs: tabs.tabs.map((tab) => (tab.id === tabId ? { ...tab, title: nextTitle } : tab)),
  })
}

export function splitTaskTerminalLayout(
  task: Task,
  fallbackTarget: TerminalTarget,
  direction: TerminalSplitDirection,
): Task {
  const tabs = terminalTabsForTarget(task, fallbackTarget) ?? defaultTerminalTabs(fallbackTarget)
  const activeTab = tabs.tabs.find((tab) => tab.id === tabs.activeTabId) ?? tabs.tabs[0]
  const layout = activeTab.layout
  const activePane =
    layout.panes.find((pane) => pane.id === layout.activePaneId) ?? layout.panes[0]
  const newPaneId = `terminal-pane-${crypto.randomUUID()}`
  const newPane = {
    ...activePane,
    id: newPaneId,
    sessionId: newPaneId,
  }

  return withTerminalTabsForTarget(task, fallbackTarget, {
    activeTabId: activeTab.id,
    tabs: tabs.tabs.map((tab) =>
      tab.id === activeTab.id
        ? {
            ...tab,
            layout: {
              activePaneId: newPane.id,
              panes: [...layout.panes, newPane],
              root: splitTerminalNode(layout.root, activePane.id, direction, newPane.id),
            },
          }
        : tab,
    ),
  })
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

  const tabs = effectiveTerminalTabs(task, fallbackTarget)
  const activeTab = tabs?.tabs.find((tab) => tab.id === tabs.activeTabId) ?? tabs?.tabs[0]

  return tabs && activeTab
    ? withTerminalTabsForTarget(task, fallbackTarget, {
        activeTabId: activeTab.id,
        tabs: tabs.tabs.map((tab) =>
          tab.id === activeTab.id
            ? {
                ...tab,
                layout: {
                  ...layout,
                  activePaneId: paneId,
                },
              }
            : tab,
        ),
      })
    : task
}

export function focusTaskTerminalTarget(task: Task, target: TerminalTarget): Task {
  if (!isTerminalSurfaceClosed(task, target.source)) {
    return task
  }

  return withTerminalTabsForTarget(
    task,
    target,
    terminalTabsForTarget(task, target) ?? defaultTerminalTabs(target),
  )
}

export type CloseTaskTerminalPaneResult = {
  task: Task
  closedPane?: TaskTerminalPane
  closedLast: boolean
}

export type CloseTaskTerminalTabResult = {
  task: Task
  closedPanes: TaskTerminalPane[]
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
    const tabs = effectiveTerminalTabs(task, fallbackTarget)
    const activeTab = tabs?.tabs.find((tab) => tab.id === tabs.activeTabId) ?? tabs?.tabs[0]

    if (!tabs || !activeTab) {
      return {
        task: withClosedTerminalSurface(task, fallbackTarget),
        closedPane,
        closedLast: true,
      }
    }

    const result = closeTaskTerminalTab(task, fallbackTarget, activeTab.id)

    return {
      task: result.task,
      closedPane,
      closedLast: result.closedLast,
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
    task: withActiveTerminalTabLayout(task, fallbackTarget, {
      activePaneId,
      panes,
      root,
    }),
    closedPane,
    closedLast: false,
  }
}

export function closeTaskTerminalTab(
  task: Task,
  fallbackTarget: TerminalTarget,
  tabId: string,
): CloseTaskTerminalTabResult {
  const tabs = effectiveTerminalTabs(task, fallbackTarget)
  const tab = tabs?.tabs.find((item) => item.id === tabId)

  if (!tabs || !tab) {
    return { task, closedPanes: [], closedLast: false }
  }

  const nextTabs = tabs.tabs.filter((item) => item.id !== tabId)

  if (!nextTabs.length) {
    return {
      task: withClosedTerminalSurface(task, fallbackTarget),
      closedPanes: tab.layout.panes,
      closedLast: true,
    }
  }

  const activeTabId =
    tabs.activeTabId === tabId
      ? nextTerminalTabId(tabs, tabId) ?? nextTabs[0].id
      : tabs.activeTabId

  return {
    task: withTerminalTabsForTarget(task, fallbackTarget, {
      activeTabId,
      tabs: nextTabs,
    }),
    closedPanes: tab.layout.panes,
    closedLast: false,
  }
}

export function terminalPanesForTask(task: Task) {
  return [
    ...(task.terminalLayout?.panes ?? []),
    ...Object.values(task.terminalLayouts ?? {}).flatMap((layout) => layout.panes),
    ...Object.values(task.terminalTabs ?? {}).flatMap((tabs) =>
      tabs.tabs.flatMap((tab) => tab.layout.panes),
    ),
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
  const terminalTabs = normalizeTerminalTabs(
    task.terminalTabs,
    terminal,
    task.repos,
    terminalLayouts,
    terminalLayout,
  )
  const terminalClosedBySurface = normalizeTerminalClosedBySurface(
    task.terminalClosedBySurface,
    task.repos,
  )

  return {
    ...task,
    terminal,
    terminalClosed: terminalLayout || terminalLayouts || terminalTabs
      ? false
      : Boolean(task.terminalClosed),
    terminalClosedBySurface,
    terminalLayout: undefined,
    terminalLayouts: undefined,
    terminalTabs,
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

function defaultTerminalTabs(fallbackTarget: TerminalTarget): TaskTerminalTabs {
  const tab = terminalTabForLayout(defaultTerminalTabId(fallbackTarget), defaultTerminalLayout(fallbackTarget))

  return {
    activeTabId: tab.id,
    tabs: [tab],
  }
}

function defaultTerminalTabId(fallbackTarget: TerminalTarget) {
  return `terminal-tab-${fallbackTarget.id}`
}

function terminalTabForLayout(id: string, layout: TaskTerminalLayout): TaskTerminalTab {
  return {
    id,
    title: 'shell',
    kind: 'shell',
    layout,
  }
}

function newTerminalTab(fallbackTarget: TerminalTarget): TaskTerminalTab {
  return terminalTabForLayout(
    `terminal-tab-${crypto.randomUUID()}`,
    defaultTerminalLayout({
      ...fallbackTarget,
      id: `terminal-pane-${crypto.randomUUID()}`,
    }),
  )
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

function withActiveTerminalTabLayout(
  task: Task,
  target: TerminalTarget,
  layout: TaskTerminalLayout,
): Task {
  const tabs = effectiveTerminalTabs(task, target) ?? defaultTerminalTabs(target)
  const activeTab = tabs.tabs.find((tab) => tab.id === tabs.activeTabId) ?? tabs.tabs[0]

  return withTerminalTabsForTarget(task, target, {
    activeTabId: activeTab.id,
    tabs: tabs.tabs.map((tab) => (tab.id === activeTab.id ? { ...tab, layout } : tab)),
  })
}

function withTerminalTabsForTarget(
  task: Task,
  target: TerminalTarget,
  tabs: TaskTerminalTabs | undefined,
): Task {
  const key = terminalSurfaceKey(target.source)
  const terminalLayouts = { ...(task.terminalLayouts ?? {}) }
  const terminalTabs = { ...(task.terminalTabs ?? {}) }
  const terminalClosedBySurface = { ...(task.terminalClosedBySurface ?? {}) }

  if (tabs?.tabs.length) {
    terminalTabs[key] = tabs
  } else {
    delete terminalTabs[key]
  }

  delete terminalLayouts[key]
  delete terminalClosedBySurface[key]

  return {
    ...task,
    terminalClosed: false,
    terminalClosedBySurface: Object.keys(terminalClosedBySurface).length
      ? terminalClosedBySurface
      : undefined,
    terminalLayout: undefined,
    terminalLayouts: Object.keys(terminalLayouts).length ? terminalLayouts : undefined,
    terminalTabs: Object.keys(terminalTabs).length ? terminalTabs : undefined,
  }
}

function withClosedTerminalSurface(task: Task, target: TerminalTarget): Task {
  const key = terminalSurfaceKey(target.source)
  const terminalLayouts = { ...(task.terminalLayouts ?? {}) }
  const terminalTabs = { ...(task.terminalTabs ?? {}) }
  const terminalClosedBySurface = { ...(task.terminalClosedBySurface ?? {}) }

  delete terminalLayouts[key]
  delete terminalTabs[key]
  terminalClosedBySurface[key] = true

  return {
    ...task,
    terminalClosed: false,
    terminalClosedBySurface,
    terminalLayout: undefined,
    terminalLayouts: Object.keys(terminalLayouts).length ? terminalLayouts : undefined,
    terminalTabs: Object.keys(terminalTabs).length ? terminalTabs : undefined,
  }
}

function terminalTabsForTarget(
  task: Task,
  target: TerminalTarget,
): TaskTerminalTabs | undefined {
  const key = terminalSurfaceKey(target.source)
  const tabs = normalizeTerminalTabsForSurface(
    task.terminalTabs?.[key],
    task.terminal,
    task.repos,
    target.source,
  )

  if (tabs) {
    return tabs
  }

  const legacyLayout = terminalLayoutForTarget(task, target)

  return legacyLayout ? terminalTabsFromLayout(key, legacyLayout) : undefined
}

function nextTerminalTabId(tabs: TaskTerminalTabs, closedTabId: string) {
  const index = tabs.tabs.findIndex((tab) => tab.id === closedTabId)

  return index >= 0
    ? tabs.tabs[index + 1]?.id ?? tabs.tabs[index - 1]?.id
    : undefined
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

function normalizeTerminalTabs(
  tabsBySurface: Record<string, TaskTerminalTabs> | undefined,
  terminal: TaskTerminal,
  repos: TaskRepo[],
  legacyLayouts: Record<string, TaskTerminalLayout> | undefined,
  legacyLayout: TaskTerminalLayout | undefined,
): Record<string, TaskTerminalTabs> | undefined {
  const entries = new Map<string, TaskTerminalTabs>()

  for (const [key, tabs] of Object.entries(tabsBySurface ?? {})) {
    const source = surfaceFromTerminalKey(key, repos)
    const normalizedTabs = source
      ? normalizeTerminalTabsForSurface(tabs, terminal, repos, source)
      : undefined

    if (normalizedTabs) {
      entries.set(key, normalizedTabs)
    }
  }

  for (const [key, layout] of Object.entries(legacyLayouts ?? {})) {
    const source = surfaceFromTerminalKey(key, repos)
    const surfaceLayout = source ? terminalLayoutForSurface(layout, source) : undefined

    if (surfaceLayout && !entries.has(key)) {
      entries.set(key, terminalTabsFromLayout(key, surfaceLayout))
    }
  }

  if (legacyLayout) {
    const sources: TaskSurfaceSelection[] = [
      { kind: 'task-terminal' },
      ...repos.map((repo) => ({ kind: 'repo' as const, taskRepoId: repo.id })),
    ]

    for (const source of sources) {
      const key = terminalSurfaceKey(source)
      const surfaceLayout = terminalLayoutForSurface(legacyLayout, source)

      if (surfaceLayout && !entries.has(key)) {
        entries.set(key, terminalTabsFromLayout(key, surfaceLayout))
      }
    }
  }

  return entries.size ? Object.fromEntries(entries) : undefined
}

function normalizeTerminalTabsForSurface(
  tabs: TaskTerminalTabs | undefined,
  terminal: TaskTerminal,
  repos: TaskRepo[],
  source: TaskSurfaceSelection,
): TaskTerminalTabs | undefined {
  if (!tabs?.tabs.length) {
    return undefined
  }

  const normalizedTabs = tabs.tabs.flatMap((tab) => {
    const layout = normalizeTerminalLayout(tab.layout, terminal, repos)
    const surfaceLayout = layout ? terminalLayoutForSurface(layout, source) : undefined

    return surfaceLayout
      ? [
          {
            id: tab.id.trim() || `terminal-tab-${crypto.randomUUID()}`,
            title: tab.title?.trim() || 'shell',
            kind: 'shell' as const,
            layout: surfaceLayout,
          },
        ]
      : []
  })

  if (!normalizedTabs.length) {
    return undefined
  }

  return {
    activeTabId: normalizedTabs.some((tab) => tab.id === tabs.activeTabId)
      ? tabs.activeTabId
      : normalizedTabs[0].id,
    tabs: normalizedTabs,
  }
}

function terminalTabsFromLayout(key: string, layout: TaskTerminalLayout): TaskTerminalTabs {
  const tab = terminalTabForLayout(`terminal-tab-${key}`, layout)

  return {
    activeTabId: tab.id,
    tabs: [tab],
  }
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
