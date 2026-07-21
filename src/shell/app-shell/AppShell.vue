<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, type CSSProperties } from 'vue'
import { listen, type UnlistenFn } from '@tauri-apps/api/event'
import { getCurrentWindow, type PhysicalPosition, type PhysicalSize } from '@tauri-apps/api/window'
import MainSurface from '../main-surface/MainSurface.vue'
import SidePanel from '../side-panel/SidePanel.vue'
import TitleBar from '../title-bar/TitleBar.vue'
import {
  activateTaskTerminalPane,
  closeTaskTerminalPane,
  createTaskRepoWorktree,
  createTask,
  DEFAULT_APP_LAYOUT,
  createEmptyAppState,
  deleteTaskRepoWorktree,
  effectiveTerminalLayout,
  findRegisteredRepo,
  focusTaskTerminalTarget,
  hasRegisteredRepo,
  loadAppState,
  plannedTaskRepoWorktreePath,
  saveAppState,
  selectedTerminalTarget,
  SIDE_PANEL_WIDTH_LIMITS,
  splitTaskTerminalLayout,
  taskSelectedSurface,
  terminalTargetForTaskSurface,
  terminalPanesForTask,
  terminalSessionIdsForTask,
  updateTask,
  type AppLayout,
  type AppState,
  type NewTaskInput,
  type RegisteredRepo,
  type Task,
  type TaskRepoGitOperation,
  type TaskRepo,
  type TaskSurfaceSelection,
  type TerminalSplitDirection,
} from '../../features/app-state/app-state'
import LayersIcon from '../../icons/LayersIcon.vue'
import OnboardingFlow from '../../features/onboarding/OnboardingFlow.vue'
import { onboardingKey } from '../../features/onboarding/onboarding'
import SettingsView from '../../features/settings/SettingsView.vue'
import {
  ensureTerminalSession,
  killTerminalSession,
  terminalProcessStatus,
} from '../../features/terminal/terminal'
import TaskDialog from '../../features/task-sidebar/task-dialog/TaskDialog.vue'
import TaskSidePanel from '../../features/task-sidebar/TaskSidePanel.vue'
import {
  type AppSettings,
  defaultSettings,
  loadSettings,
  saveSettings,
  terminalFontSizePxById,
} from '../../features/settings/settings'
import styles from './AppShell.module.css'

type TaskProgressStep = {
  id: string
  kind: 'prepare' | 'cleanup'
  label: string
  detail?: string
  status: 'pending' | 'running' | 'done' | 'error'
}

type TaskProgress = {
  title: string
  steps: TaskProgressStep[]
  error?: string
}

type TaskRepoGitPlan = TaskRepoGitOperation & {
  id: string
  repoName: string
}

type CreatedTaskRepoGitPlan = TaskRepoGitPlan & {
  worktreePath: string
}

type GitProgressEvent = {
  progressId: string
  phase: string
}

type SidePanelSide = 'left' | 'right'

type SidePanelResizeStart = {
  side: SidePanelSide
  startX: number
  startWidth: number
}

type PaneCloseConfirmation = {
  taskId: string
  paneId: string
  command?: string
  closeAppAfterClose: boolean
}

const MIN_WINDOW_WIDTH = 900
const MIN_WINDOW_HEIGHT = 600
const MAX_WINDOW_WIDTH = 4000
const MAX_WINDOW_HEIGHT = 3000
const WINDOW_LAYOUT_SAVE_DELAY = 300

const appWindow = getCurrentWindow()
const startsInOnboarding = !localStorage.getItem(onboardingKey)
const leftSidePanelVisible = ref(true)
const rightSidePanelVisible = ref(false)
const leftSidePanelWidth = ref(DEFAULT_APP_LAYOUT.sidePanels.leftWidth)
const rightSidePanelWidth = ref(DEFAULT_APP_LAYOUT.sidePanels.rightWidth)
const resizingSidePanel = ref<SidePanelSide | null>(null)
const settingsVisible = ref(false)
const newTaskVisible = ref(false)
const editingTaskId = ref<string | null>(null)
const onboardingVisible = ref(startsInOnboarding)
const bootstrapped = ref(false)
const taskDialogProgress = ref<TaskProgress | null>(null)
const paneCloseConfirmation = ref<PaneCloseConfirmation | null>(null)
const appState = ref<AppState>(createEmptyAppState())
const settings = ref<AppSettings>(startsInOnboarding ? { ...defaultSettings } : loadSettings())
const terminalFontSize = computed(() => terminalFontSizePxById[settings.value.terminalFontSize])
const editingTask = computed(() =>
  appState.value.tasks.find((task) => task.id === editingTaskId.value),
)
const taskDialogOpen = computed(() => newTaskVisible.value || Boolean(editingTask.value))
const taskDialogBusy = computed(() =>
  Boolean(
    taskDialogProgress.value &&
      !taskDialogProgress.value.error &&
      taskDialogProgress.value.steps.some(
        (step) => step.status === 'pending' || step.status === 'running',
      ),
  ),
)
const workingTaskId = computed(() => (taskDialogBusy.value ? editingTask.value?.id ?? null : null))
const bodyLayoutStyle = computed<CSSProperties>(() => ({
  '--left-side-panel-width': `${leftSidePanelWidth.value}px`,
  '--right-side-panel-width': `${rightSidePanelWidth.value}px`,
}))
let unlistenOpenSettings: UnlistenFn | undefined
let unlistenGitProgress: UnlistenFn | undefined
let unlistenWindowResized: UnlistenFn | undefined
let unlistenWindowMoved: UnlistenFn | undefined
let appStateTouched = false
let appStateSaveQueue: Promise<void> = Promise.resolve()
let sidePanelResizeStart: SidePanelResizeStart | undefined
let windowLayoutSaveTimer: number | undefined
let pendingWindowSize: PhysicalSize | undefined
let pendingWindowPosition: PhysicalPosition | undefined

function clamp(value: number, min: number, max: number) {
  return Math.round(Math.min(max, Math.max(min, value)))
}

function clampSidePanelWidth(side: SidePanelSide, width: number) {
  const limits = SIDE_PANEL_WIDTH_LIMITS[side]

  return clamp(width, limits.min, limits.max)
}

function appLayout(state: AppState): AppLayout {
  return state.layout ?? DEFAULT_APP_LAYOUT
}

function applyStoredSidePanelWidths(state: AppState) {
  const layout = appLayout(state)

  leftSidePanelWidth.value = clampSidePanelWidth(
    'left',
    layout.sidePanels?.leftWidth ?? DEFAULT_APP_LAYOUT.sidePanels.leftWidth,
  )
  rightSidePanelWidth.value = clampSidePanelWidth(
    'right',
    layout.sidePanels?.rightWidth ?? DEFAULT_APP_LAYOUT.sidePanels.rightWidth,
  )
}

function persistSidePanelWidths() {
  persistAppState({
    ...appState.value,
    layout: {
      ...appLayout(appState.value),
      sidePanels: {
        leftWidth: leftSidePanelWidth.value,
        rightWidth: rightSidePanelWidth.value,
      },
    },
  })
}

function startSidePanelResize(side: SidePanelSide, event: PointerEvent) {
  if (event.button !== 0) {
    return
  }

  event.preventDefault()
  event.stopPropagation()

  sidePanelResizeStart = {
    side,
    startX: event.clientX,
    startWidth: side === 'left' ? leftSidePanelWidth.value : rightSidePanelWidth.value,
  }
  resizingSidePanel.value = side
  document.body.style.cursor = 'col-resize'
  document.body.style.userSelect = 'none'
  window.addEventListener('pointermove', resizeSidePanel)
  window.addEventListener('pointerup', stopSidePanelResize)
}

function resizeSidePanel(event: PointerEvent) {
  if (!sidePanelResizeStart) {
    return
  }

  const delta = event.clientX - sidePanelResizeStart.startX
  const width =
    sidePanelResizeStart.side === 'left'
      ? sidePanelResizeStart.startWidth + delta
      : sidePanelResizeStart.startWidth - delta

  if (sidePanelResizeStart.side === 'left') {
    leftSidePanelWidth.value = clampSidePanelWidth('left', width)
  } else {
    rightSidePanelWidth.value = clampSidePanelWidth('right', width)
  }
}

function stopSidePanelResize() {
  if (!sidePanelResizeStart) {
    return
  }

  sidePanelResizeStart = undefined
  resizingSidePanel.value = null
  document.body.style.cursor = ''
  document.body.style.userSelect = ''
  window.removeEventListener('pointermove', resizeSidePanel)
  window.removeEventListener('pointerup', stopSidePanelResize)
  persistSidePanelWidths()
}

function resizeSidePanelWithKeyboard(side: SidePanelSide, event: KeyboardEvent) {
  if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) {
    return
  }

  event.preventDefault()

  const limits = SIDE_PANEL_WIDTH_LIMITS[side]
  const currentWidth = side === 'left' ? leftSidePanelWidth.value : rightSidePanelWidth.value
  const step = 12
  let nextWidth = currentWidth

  if (event.key === 'Home') {
    nextWidth = limits.min
  } else if (event.key === 'End') {
    nextWidth = limits.max
  } else if (side === 'left') {
    nextWidth = currentWidth + (event.key === 'ArrowRight' ? step : -step)
  } else {
    nextWidth = currentWidth + (event.key === 'ArrowLeft' ? step : -step)
  }

  if (side === 'left') {
    leftSidePanelWidth.value = clampSidePanelWidth(side, nextWidth)
  } else {
    rightSidePanelWidth.value = clampSidePanelWidth(side, nextWidth)
  }

  persistSidePanelWidths()
}

async function persistPendingWindowLayout() {
  const size = pendingWindowSize
  const position = pendingWindowPosition

  pendingWindowSize = undefined
  pendingWindowPosition = undefined

  if ((!size && !position) || !bootstrapped.value) {
    return
  }

  const fullscreen = await appWindow.isFullscreen()

  if (fullscreen) {
    return
  }

  const scaleFactor = await appWindow.scaleFactor()
  const nextWindow = {
    ...(appLayout(appState.value).window ?? DEFAULT_APP_LAYOUT.window),
  }

  if (size) {
    const logicalSize = size.toLogical(scaleFactor)

    nextWindow.width = clamp(logicalSize.width, MIN_WINDOW_WIDTH, MAX_WINDOW_WIDTH)
    nextWindow.height = clamp(logicalSize.height, MIN_WINDOW_HEIGHT, MAX_WINDOW_HEIGHT)
  }

  if (position) {
    const logicalPosition = position.toLogical(scaleFactor)

    nextWindow.x = Math.round(logicalPosition.x)
    nextWindow.y = Math.round(logicalPosition.y)
  }

  persistAppState({
    ...appState.value,
    layout: {
      ...appLayout(appState.value),
      window: nextWindow,
    },
  })
}

function scheduleWindowLayoutSave(next: { size?: PhysicalSize; position?: PhysicalPosition }) {
  if (next.size) {
    pendingWindowSize = next.size
  }

  if (next.position) {
    pendingWindowPosition = next.position
  }

  if (windowLayoutSaveTimer) {
    window.clearTimeout(windowLayoutSaveTimer)
  }

  windowLayoutSaveTimer = window.setTimeout(() => {
    windowLayoutSaveTimer = undefined
    void persistPendingWindowLayout().catch((error: unknown) => {
      console.error('Failed to save window layout', error)
    })
  }, WINDOW_LAYOUT_SAVE_DELAY)
}

async function startWindowLayoutPersistence() {
  unlistenWindowResized = await appWindow.onResized(({ payload }) => {
    scheduleWindowLayoutSave({ size: payload })
  })
  unlistenWindowMoved = await appWindow.onMoved(({ payload }) => {
    scheduleWindowLayoutSave({ position: payload })
  })
}

function updateSettings(next: Partial<AppSettings>) {
  settings.value = { ...settings.value, ...next }
  saveSettings(settings.value)
}

function toggleLeftSidePanel() {
  leftSidePanelVisible.value = !leftSidePanelVisible.value
}

function toggleRightSidePanel() {
  rightSidePanelVisible.value = !rightSidePanelVisible.value
}

function openSettings() {
  settingsVisible.value = true
}

function openNewTask() {
  taskDialogProgress.value = null
  editingTaskId.value = null
  newTaskVisible.value = true
}

function openEditTask(task: Task) {
  taskDialogProgress.value = null
  newTaskVisible.value = false
  editingTaskId.value = task.id
}

function closeTaskDialog() {
  if (taskDialogBusy.value) {
    return
  }

  taskDialogProgress.value = null
  newTaskVisible.value = false
  editingTaskId.value = null
}

function dismissTaskProgress() {
  if (taskDialogBusy.value) {
    return
  }

  taskDialogProgress.value = null
}

function closeSettings() {
  settingsVisible.value = false
}

function startWindowDrag(event: MouseEvent) {
  if (event.button !== 0) {
    return
  }

  event.preventDefault()
  event.stopPropagation()

  void appWindow.startDragging().catch(() => undefined)
}

function finishOnboarding(payload: { openNewTask: boolean; repositories: RegisteredRepo[] }) {
  localStorage.setItem(onboardingKey, '1')
  onboardingVisible.value = false

  if (payload.repositories.length) {
    const existing = appState.value.repoRegistry
    const repositories = payload.repositories.filter(
      (repo) => !hasRegisteredRepo(existing, { name: repo.name, path: repo.source.path }),
    )

    if (repositories.length) {
      persistAppState({
        ...appState.value,
        repoRegistry: [...existing, ...repositories],
      })
    }
  }

  if (payload.openNewTask) {
    settingsVisible.value = false
    openNewTask()
  }
}

function persistAppState(next: AppState) {
  void persistAppStateAsync(next).catch((error: unknown) => {
    console.error('Failed to save app state', error)
  })
}

async function persistAppStateAsync(next: AppState) {
  appStateTouched = true
  appState.value = next

  const save = appStateSaveQueue.catch(() => undefined).then(() => saveAppState(next))
  appStateSaveQueue = save

  await save
}

function selectTask(task: Task) {
  const surface: TaskSurfaceSelection = { kind: 'task-terminal' }
  const terminal = terminalTargetForTaskSurface(appState.value, task, surface)

  persistAppState({
    ...appState.value,
    tasks: terminal
      ? appState.value.tasks.map((item) =>
          item.id === task.id ? focusTaskTerminalTarget(item, terminal) : item,
        )
      : appState.value.tasks,
    selection: {
      ...appState.value.selection,
      taskId: task.id,
      surfaceByTaskId: {
        ...appState.value.selection.surfaceByTaskId,
        [task.id]: surface,
      },
    },
  })
}

function selectTaskRepo(task: Task, taskRepo: TaskRepo) {
  const surface: TaskSurfaceSelection = { kind: 'repo', taskRepoId: taskRepo.id }
  const terminal = terminalTargetForTaskSurface(appState.value, task, surface)

  persistAppState({
    ...appState.value,
    tasks: terminal
      ? appState.value.tasks.map((item) =>
          item.id === task.id ? focusTaskTerminalTarget(item, terminal) : item,
        )
      : appState.value.tasks,
    selection: {
      ...appState.value.selection,
      taskId: task.id,
      surfaceByTaskId: {
        ...appState.value.selection.surfaceByTaskId,
        [task.id]: surface,
      },
      expandedTaskIds: Array.from(new Set([...appState.value.selection.expandedTaskIds, task.id])),
    },
  })
}

function selectedSurfaceForUpdatedTask(currentTask: Task, nextTask: Task): TaskSurfaceSelection {
  const surface = taskSelectedSurface(currentTask, appState.value.selection)

  if (surface.kind === 'repo' && nextTask.repos.some((repo) => repo.id === surface.taskRepoId)) {
    return surface
  }

  return { kind: 'task-terminal' }
}

function sameTaskSurface(left: TaskSurfaceSelection | undefined, right: TaskSurfaceSelection | undefined) {
  if (!left || !right || left.kind !== right.kind) {
    return false
  }

  if (left.kind === 'task-terminal') {
    return true
  }

  return right.kind === 'repo' && left.taskRepoId === right.taskRepoId
}

function updateStoredTask(taskId: string, updater: (task: Task) => Task) {
  let changed = false
  const tasks = appState.value.tasks.map((task) => {
    if (task.id !== taskId) {
      return task
    }

    const nextTask = updater(task)
    changed ||= nextTask !== task

    return nextTask
  })

  if (!changed) {
    return
  }

  persistAppState({
    ...appState.value,
    tasks,
  })
}

function splitSelectedTerminal(direction: TerminalSplitDirection) {
  const task = appState.value.tasks.find((item) => item.id === appState.value.selection.taskId)

  if (!task) {
    return
  }

  const terminal = selectedTerminalTarget(appState.value, task)

  if (!terminal) {
    return
  }

  updateStoredTask(task.id, (currentTask) =>
    splitTaskTerminalLayout(currentTask, terminal, direction),
  )
}

function splitTerminalPane(
  taskId: string,
  paneId: string,
  direction: TerminalSplitDirection,
) {
  const task = appState.value.tasks.find((item) => item.id === taskId)

  if (!task) {
    return
  }

  const terminal = selectedTerminalTarget(appState.value, task)

  if (!terminal) {
    return
  }

  updateStoredTask(task.id, (currentTask) =>
    splitTaskTerminalLayout(
      activateTaskTerminalPane(currentTask, terminal, paneId),
      terminal,
      direction,
    ),
  )
}

function openSelectedTerminalPane() {
  const task = appState.value.tasks.find((item) => item.id === appState.value.selection.taskId)

  if (!task) {
    return
  }

  const terminal = selectedTerminalTarget(appState.value, task)

  if (!terminal) {
    return
  }

  updateStoredTask(task.id, (currentTask) => focusTaskTerminalTarget(currentTask, terminal))
}

function selectedTaskTerminalLayout(task: Task) {
  const terminal = selectedTerminalTarget(appState.value, task)

  return terminal ? effectiveTerminalLayout(task, terminal) : undefined
}

function paneSessionUsedByOtherPane(sessionId: string, paneId: string, tasks: Task[]) {
  return tasks.some((task) =>
    terminalPanesForTask(task).some(
      (pane) => pane.id !== paneId && pane.sessionId === sessionId,
    ),
  )
}

async function closeTerminalPane(
  taskId: string,
  paneId: string,
  closeAppAfterClose: boolean,
) {
  let closedPaneSessionId: string | undefined
  let closedLast = false
  let changed = false
  let nextSurface: TaskSurfaceSelection | undefined

  const tasks = appState.value.tasks.map((task) => {
    if (task.id !== taskId) {
      return task
    }

    const terminal = selectedTerminalTarget(appState.value, task)

    if (!terminal) {
      return task
    }

    const result = closeTaskTerminalPane(task, terminal, paneId)

    if (!result.closedPane) {
      return task
    }

    closedPaneSessionId = result.closedPane.sessionId
    closedLast = result.closedLast
    changed = result.task !== task
    const nextLayout = effectiveTerminalLayout(result.task, terminal)

    nextSurface =
      nextLayout?.panes.find((pane) => pane.id === nextLayout.activePaneId)?.source ??
      appState.value.selection.surfaceByTaskId[task.id]

    return result.task
  })

  if (!changed || !closedPaneSessionId) {
    return
  }

  if (!paneSessionUsedByOtherPane(closedPaneSessionId, paneId, tasks)) {
    await killTerminalSession({ sessionId: closedPaneSessionId }).catch(() => undefined)
  }

  await persistAppStateAsync({
    ...appState.value,
    tasks,
    selection: nextSurface
      ? {
          ...appState.value.selection,
          surfaceByTaskId: {
            ...appState.value.selection.surfaceByTaskId,
            [taskId]: nextSurface,
          },
        }
      : appState.value.selection,
  })

  if (closedLast && closeAppAfterClose) {
    await appWindow.close()
  }
}

async function closeActiveTerminalPane() {
  const task = appState.value.tasks.find((item) => item.id === appState.value.selection.taskId)
  const layout = task ? selectedTaskTerminalLayout(task) : undefined
  const activePane = layout?.panes.find((pane) => pane.id === layout.activePaneId)

  if (!task || !layout || !activePane) {
    return
  }

  const closeAppAfterClose = layout.panes.length === 1 && settings.value.closeAppOnLastPane
  const status = await terminalProcessStatus({ sessionId: activePane.sessionId }).catch(() => ({
    busy: false,
    command: undefined,
  }))

  if (status.busy) {
    paneCloseConfirmation.value = {
      taskId: task.id,
      paneId: activePane.id,
      command: status.command,
      closeAppAfterClose,
    }
    return
  }

  await closeTerminalPane(task.id, activePane.id, closeAppAfterClose)
}

async function requestCloseTerminalPane(taskId: string, paneId: string) {
  const task = appState.value.tasks.find((item) => item.id === taskId)
  const terminal = task ? selectedTerminalTarget(appState.value, task) : undefined
  const layout = task && terminal ? effectiveTerminalLayout(task, terminal) : undefined
  const pane = layout?.panes.find((item) => item.id === paneId)

  if (!task || !layout || !pane) {
    return
  }

  const closeAppAfterClose = layout.panes.length === 1 && settings.value.closeAppOnLastPane
  const status = await terminalProcessStatus({ sessionId: pane.sessionId }).catch(() => ({
    busy: false,
    command: undefined,
  }))

  if (status.busy) {
    paneCloseConfirmation.value = {
      taskId: task.id,
      paneId: pane.id,
      command: status.command,
      closeAppAfterClose,
    }
    return
  }

  await closeTerminalPane(task.id, pane.id, closeAppAfterClose)
}

function cancelPaneClose() {
  paneCloseConfirmation.value = null
}

async function confirmPaneClose() {
  const confirmation = paneCloseConfirmation.value

  if (!confirmation) {
    return
  }

  paneCloseConfirmation.value = null
  await closeTerminalPane(
    confirmation.taskId,
    confirmation.paneId,
    confirmation.closeAppAfterClose,
  )
}

function selectTerminalPane(taskId: string, paneId: string) {
  let selectedSurface: TaskSurfaceSelection | undefined
  let changed = false
  const tasks = appState.value.tasks.map((task) => {
    if (task.id !== taskId) {
      return task
    }

    const terminal = selectedTerminalTarget(appState.value, task)

    if (!terminal) {
      return task
    }

    const nextTask = activateTaskTerminalPane(task, terminal, paneId)
    const layout = effectiveTerminalLayout(nextTask, terminal)
    const pane = layout?.panes.find((item) => item.id === paneId)

    selectedSurface = pane?.source
    changed ||= nextTask !== task

    return nextTask
  })
  const currentSurface = appState.value.selection.surfaceByTaskId[taskId]

  if (!changed && sameTaskSurface(currentSurface, selectedSurface)) {
    return
  }

  persistAppState({
    ...appState.value,
    tasks,
    selection: selectedSurface && !sameTaskSurface(currentSurface, selectedSurface)
      ? {
          ...appState.value.selection,
          surfaceByTaskId: {
            ...appState.value.selection.surfaceByTaskId,
            [taskId]: selectedSurface,
          },
        }
      : appState.value.selection,
  })
}

function toggleTask(task: Task) {
  const expandedTaskIds = new Set(appState.value.selection.expandedTaskIds)

  if (expandedTaskIds.has(task.id)) {
    expandedTaskIds.delete(task.id)
  } else {
    expandedTaskIds.add(task.id)
  }

  persistAppState({
    ...appState.value,
    selection: {
      ...appState.value.selection,
      expandedTaskIds: Array.from(expandedTaskIds),
    },
  })
}

function taskRepoGitPlan(task: Task, taskRepo: TaskRepo): TaskRepoGitPlan {
  const repo = findRegisteredRepo(appState.value, taskRepo.registeredRepoId)

  if (!repo) {
    throw new Error('registered repository is missing')
  }

  return {
    id: taskRepo.id,
    repoName: repo.name,
    sourcePath: repo.source.path,
    baseBranch: taskRepo.baseBranch,
    branch: taskRepo.branch,
    worktreePath:
      taskRepo.worktreePath ??
      plannedTaskRepoWorktreePath(appState.value.repositoryDefaults, task, taskRepo, repo),
  }
}

function createPlansForTask(task: Task) {
  return task.repos
    .filter((taskRepo) => !taskRepo.worktreePath)
    .map((taskRepo) => taskRepoGitPlan(task, taskRepo))
}

function cleanupPlansForTaskRepos(task: Task, repos: TaskRepo[]) {
  return repos.map((taskRepo) => taskRepoGitPlan(task, taskRepo))
}

function startTaskProgress(
  title: string,
  createPlans: TaskRepoGitPlan[],
  cleanupPlans: TaskRepoGitPlan[],
) {
  taskDialogProgress.value = {
    title,
    steps: [
      ...createPlans.map((plan) => ({
        id: `create-${plan.id}`,
        kind: 'prepare' as const,
        label: plan.repoName,
        detail: plan.branch,
        status: 'pending' as const,
      })),
      ...cleanupPlans.map((plan) => ({
        id: `cleanup-${plan.id}`,
        kind: 'cleanup' as const,
        label: plan.repoName,
        detail: plan.branch,
        status: 'pending' as const,
      })),
    ],
  }
}

function updateTaskProgressStep(id: string, status: TaskProgressStep['status']) {
  const progress = taskDialogProgress.value

  if (!progress) {
    return
  }

  taskDialogProgress.value = {
    ...progress,
    steps: progress.steps.map((step) =>
      step.id === id
        ? {
            ...step,
            detail: status === 'done' ? undefined : step.detail,
            status,
          }
        : step,
    ),
  }
}

function updateTaskProgressPhase(progressId: string, phase: string) {
  const progress = taskDialogProgress.value

  if (!progress) {
    return
  }

  taskDialogProgress.value = {
    ...progress,
    steps: progress.steps.map((step) =>
      step.id === progressId && step.status === 'running' ? { ...step, detail: phase } : step,
    ),
  }
}

function failTaskProgress(error: unknown) {
  const progress = taskDialogProgress.value
  const message = error instanceof Error ? error.message : String(error)

  if (!progress) {
    taskDialogProgress.value = {
      title: 'Git setup failed',
      error: message,
      steps: [
        {
          id: 'error',
          kind: 'prepare',
          label: 'Git setup',
          detail: message,
          status: 'error',
        },
      ],
    }
    return
  }

  const failingStep =
    progress.steps.find((step) => step.status === 'running') ??
    progress.steps.find((step) => step.status === 'pending')

  taskDialogProgress.value = {
    ...progress,
    error: message,
    steps: progress.steps.map((step) =>
      step.id === failingStep?.id ? { ...step, status: 'error' } : step,
    ),
  }
}

async function rollbackCreatedWorktrees(plans: TaskRepoGitPlan[]) {
  await Promise.allSettled(
    plans.map(async (plan) => {
      await killTerminalSession({ sessionId: plan.id }).catch(() => undefined)
      await deleteTaskRepoWorktree(plan)
    }),
  )
}

function rejectedResult<T>(result: PromiseSettledResult<T>): result is PromiseRejectedResult {
  return result.status === 'rejected'
}

function fulfilledResult<T>(result: PromiseSettledResult<T>): result is PromiseFulfilledResult<T> {
  return result.status === 'fulfilled'
}

function waitForPaint() {
  return new Promise<void>((resolve) => {
    requestAnimationFrame(() => resolve())
  })
}

async function flushTaskProgress() {
  await nextTick()
  await waitForPaint()
}

async function runCreatePlans(
  task: Task,
  plans: TaskRepoGitPlan[],
  createdPlans: TaskRepoGitPlan[] = [],
) {
  if (!plans.length) {
    return task
  }

  for (const plan of plans) {
    updateTaskProgressStep(`create-${plan.id}`, 'running')
    updateTaskProgressPhase(`create-${plan.id}`, 'Starting worktree')
  }
  await flushTaskProgress()

  const results = await Promise.allSettled(
    plans.map(async (plan): Promise<CreatedTaskRepoGitPlan> => {
      try {
        const worktreePath = await createTaskRepoWorktree({
          ...plan,
          progressId: `create-${plan.id}`,
        })
        const createdPlan = { ...plan, worktreePath }
        createdPlans.push(createdPlan)
        updateTaskProgressPhase(`create-${plan.id}`, 'Starting terminal')
        await ensureTerminalSession({ sessionId: plan.id, cwd: worktreePath })
        updateTaskProgressStep(`create-${plan.id}`, 'done')
        await flushTaskProgress()

        return createdPlan
      } catch (error) {
        updateTaskProgressStep(`create-${plan.id}`, 'error')
        await flushTaskProgress()
        throw error
      }
    }),
  )
  const created = results.filter(fulfilledResult).map((result) => result.value)
  const failed = results.find(rejectedResult)

  if (failed) {
    await rollbackCreatedWorktrees(createdPlans)
    throw failed.reason
  }

  return {
    ...task,
    repos: task.repos.map((taskRepo) => {
      const createdPlan = created.find((plan) => plan.id === taskRepo.id)

      return createdPlan ? { ...taskRepo, worktreePath: createdPlan.worktreePath } : taskRepo
    }),
  }
}

async function runCleanupPlans(plans: TaskRepoGitPlan[]) {
  if (!plans.length) {
    return
  }

  for (const plan of plans) {
    updateTaskProgressStep(`cleanup-${plan.id}`, 'running')
    updateTaskProgressPhase(`cleanup-${plan.id}`, 'Removing worktree')
  }
  await flushTaskProgress()

  const results = await Promise.allSettled(
    plans.map(async (plan) => {
      try {
        await killTerminalSession({ sessionId: plan.id })
        await deleteTaskRepoWorktree(plan)
        updateTaskProgressStep(`cleanup-${plan.id}`, 'done')
      } catch (error) {
        updateTaskProgressStep(`cleanup-${plan.id}`, 'error')
        throw error
      } finally {
        await flushTaskProgress()
      }
    }),
  )
  const failed = results.find(rejectedResult)

  if (failed) {
    throw failed.reason
  }
}

async function createNewTask(input: NewTaskInput) {
  try {
    const task = createTask(input)
    const createPlans = createPlansForTask(task)

    if (createPlans.length) {
      startTaskProgress('Create task', createPlans, [])
    }

    const nextTask = await runCreatePlans(task, createPlans)

    await persistAppStateAsync({
      ...appState.value,
      tasks: [nextTask, ...appState.value.tasks],
      selection: {
        ...appState.value.selection,
        taskId: nextTask.id,
        surfaceByTaskId: {
          ...appState.value.selection.surfaceByTaskId,
          [nextTask.id]: { kind: 'task-terminal' },
        },
        expandedTaskIds: Array.from(
          new Set(
            nextTask.repos.length
              ? [nextTask.id, ...appState.value.selection.expandedTaskIds]
              : appState.value.selection.expandedTaskIds,
          ),
        ),
      },
    })
    closeTaskDialog()
  } catch (error) {
    failTaskProgress(error)
  }
}

async function updateExistingTask(task: Task, input: NewTaskInput) {
  try {
    const nextTask = updateTask(task, input)
    const removedRepos = task.repos.filter(
      (taskRepo) => !nextTask.repos.some((nextRepo) => nextRepo.id === taskRepo.id),
    )
    const createPlans = createPlansForTask(nextTask)
    const cleanupPlans = cleanupPlansForTaskRepos(task, removedRepos)
    const hasGitWork = createPlans.length > 0 || cleanupPlans.length > 0

    if (hasGitWork) {
      startTaskProgress('Update task', createPlans, cleanupPlans)
    }

    const createdPlans: TaskRepoGitPlan[] = []
    const materializedTask = await runCreatePlans(nextTask, createPlans, createdPlans)

    try {
      await runCleanupPlans(cleanupPlans)
    } catch (error) {
      await rollbackCreatedWorktrees(createdPlans)
      throw error
    }

    const resetTerminalLayout = createPlans.length > 0 || cleanupPlans.length > 0
    const nextMaterializedTask = resetTerminalLayout
      ? {
          ...materializedTask,
          terminalClosedBySurface: undefined,
          terminalLayout: undefined,
          terminalLayouts: undefined,
        }
      : materializedTask

    if (resetTerminalLayout) {
      const retainedSessionIds = new Set([
        nextMaterializedTask.terminal.id,
        ...nextMaterializedTask.repos.map((repo) => repo.id),
      ])

      await Promise.allSettled(
        terminalSessionIdsForTask(task)
          .filter((sessionId) => !retainedSessionIds.has(sessionId))
          .map((sessionId) => killTerminalSession({ sessionId })),
      )
    }

    await persistAppStateAsync({
      ...appState.value,
      tasks: appState.value.tasks.map((item) =>
        item.id === task.id ? nextMaterializedTask : item,
      ),
      selection: {
        ...appState.value.selection,
        surfaceByTaskId: {
          ...appState.value.selection.surfaceByTaskId,
          [task.id]: selectedSurfaceForUpdatedTask(task, nextMaterializedTask),
        },
      },
    })
    closeTaskDialog()
  } catch (error) {
    failTaskProgress(error)
  }
}

async function deleteExistingTask(task: Task) {
  try {
    const nextTasks = appState.value.tasks.filter((item) => item.id !== task.id)
    const surfaceByTaskId = { ...appState.value.selection.surfaceByTaskId }
    const selectedFallbackTask = nextTasks[0]
    const cleanupPlans = cleanupPlansForTaskRepos(task, task.repos)

    delete surfaceByTaskId[task.id]

    if (appState.value.selection.taskId === task.id && selectedFallbackTask) {
      surfaceByTaskId[selectedFallbackTask.id] ??= { kind: 'task-terminal' }
    }

    if (cleanupPlans.length) {
      startTaskProgress('Delete task', [], cleanupPlans)
    }

    await runCleanupPlans(cleanupPlans)
    await Promise.allSettled(
      terminalSessionIdsForTask(task).map((sessionId) => killTerminalSession({ sessionId })),
    )

    await persistAppStateAsync({
      ...appState.value,
      tasks: nextTasks,
      selection: {
        ...appState.value.selection,
        taskId:
          appState.value.selection.taskId === task.id
            ? selectedFallbackTask?.id ?? null
            : appState.value.selection.taskId,
        surfaceByTaskId,
        expandedTaskIds: appState.value.selection.expandedTaskIds.filter((id) => id !== task.id),
      },
    })
    closeTaskDialog()
  } catch (error) {
    failTaskProgress(error)
  }
}

function handleKeydown(event: KeyboardEvent) {
  if (!bootstrapped.value) {
    return
  }

  if (onboardingVisible.value) {
    return
  }

  if (paneCloseConfirmation.value) {
    if (event.key === 'Escape') {
      event.preventDefault()
      cancelPaneClose()
    }

    return
  }

  if (taskDialogOpen.value) {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'n') {
      event.preventDefault()
    }

    return
  }

  if (settingsVisible.value) {
    if ((event.metaKey || event.ctrlKey) && event.key === ',') {
      event.preventDefault()
      closeSettings()
    }

    return
  }

  if (!event.metaKey && !event.ctrlKey) {
    return
  }

  if (event.key.toLowerCase() === 'b') {
    event.preventDefault()
    toggleLeftSidePanel()
  } else if (event.key.toLowerCase() === 'd') {
    event.preventDefault()
    splitSelectedTerminal(event.shiftKey ? 'horizontal' : 'vertical')
  } else if (event.key.toLowerCase() === 't') {
    event.preventDefault()
    openSelectedTerminalPane()
  } else if (event.key.toLowerCase() === 'w') {
    event.preventDefault()
    void closeActiveTerminalPane()
  } else if (event.key.toLowerCase() === 'l') {
    event.preventDefault()
    toggleRightSidePanel()
  } else if (event.key.toLowerCase() === 'n') {
    event.preventDefault()
    openNewTask()
  } else if (event.key === ',') {
    event.preventDefault()
    openSettings()
  }
}

onMounted(() => {
  window.addEventListener('keydown', handleKeydown)
  void loadAppState()
    .then((state) => {
      if (appStateTouched) {
        return
      }

      appState.value = state
      applyStoredSidePanelWidths(state)
    })
    .catch((error: unknown) => {
      console.error('Failed to load app state', error)
    })
    .finally(() => {
      bootstrapped.value = true
      void startWindowLayoutPersistence().catch((error: unknown) => {
        console.error('Failed to listen for window layout changes', error)
      })
    })
  void listen('pinata://open-settings', openSettings).then((unlisten) => {
    unlistenOpenSettings = unlisten
  })
  void listen<GitProgressEvent>('pinata://git-progress', (event) => {
    updateTaskProgressPhase(event.payload.progressId, event.payload.phase)
  }).then((unlisten) => {
    unlistenGitProgress = unlisten
  })
})

onBeforeUnmount(() => {
  window.removeEventListener('keydown', handleKeydown)
  stopSidePanelResize()
  if (windowLayoutSaveTimer) {
    window.clearTimeout(windowLayoutSaveTimer)
    windowLayoutSaveTimer = undefined
  }
  void persistPendingWindowLayout().catch((error: unknown) => {
    console.error('Failed to save window layout', error)
  })
  unlistenOpenSettings?.()
  unlistenGitProgress?.()
  unlistenWindowResized?.()
  unlistenWindowMoved?.()
})
</script>

<template>
  <div
    :class="styles.shell"
    :data-theme="settings.theme"
    :data-accent="settings.accent"
    :data-accent-intensity="settings.accentIntensity"
    :data-app-font-size="settings.appFontSize"
    data-density="regular"
  >
    <template v-if="bootstrapped">
      <template v-if="!onboardingVisible">
        <TitleBar
          :left-side-panel-visible="leftSidePanelVisible"
          :right-side-panel-visible="rightSidePanelVisible"
          @toggle-left-side-panel="toggleLeftSidePanel"
          @toggle-right-side-panel="toggleRightSidePanel"
        />

        <div
          :class="[
            styles.body,
            !leftSidePanelVisible && styles.leftSidePanelHidden,
            rightSidePanelVisible && styles.rightSidePanelVisible,
            resizingSidePanel && styles.sidePanelResizing,
          ]"
          :style="bodyLayoutStyle"
        >
          <TaskSidePanel
            :app-state="appState"
            :visible="leftSidePanelVisible"
            :working-task-id="workingTaskId"
            @edit-task="openEditTask"
            @open-new-task="openNewTask"
            @select-task="selectTask"
            @select-task-repo="selectTaskRepo"
            @toggle-task="toggleTask"
          />
          <button
            type="button"
            :class="[
              styles.sideResizer,
              styles.leftSideResizer,
              resizingSidePanel === 'left' && styles.sideResizerActive,
            ]"
            :aria-hidden="!leftSidePanelVisible"
            :tabindex="leftSidePanelVisible ? 0 : -1"
            aria-label="Resize left side panel"
            @keydown="resizeSidePanelWithKeyboard('left', $event)"
            @pointerdown="startSidePanelResize('left', $event)"
          />
          <MainSurface
            :app-state="appState"
            :terminal-font-size="terminalFontSize"
            @close-terminal-pane="requestCloseTerminalPane"
            @select-terminal-pane="selectTerminalPane"
            @split-terminal-pane="splitTerminalPane"
          />
          <button
            type="button"
            :class="[
              styles.sideResizer,
              styles.rightSideResizer,
              resizingSidePanel === 'right' && styles.sideResizerActive,
            ]"
            :aria-hidden="!rightSidePanelVisible"
            :tabindex="rightSidePanelVisible ? 0 : -1"
            aria-label="Resize right side panel"
            @keydown="resizeSidePanelWithKeyboard('right', $event)"
            @pointerdown="startSidePanelResize('right', $event)"
          />
          <SidePanel title="Side panel" empty="Nothing here yet." side="right" :visible="rightSidePanelVisible" />
        </div>

        <SettingsView
          v-if="settingsVisible"
          :theme="settings.theme"
          :accent="settings.accent"
          :accent-intensity="settings.accentIntensity"
          :app-font-size="settings.appFontSize"
          :terminal-font-size="settings.terminalFontSize"
          :close-app-on-last-pane="settings.closeAppOnLastPane"
          :app-state="appState"
          @close="closeSettings"
          @update-theme="(theme) => updateSettings({ theme })"
          @update-accent="(accent) => updateSettings({ accent })"
          @update-accent-intensity="(accentIntensity) => updateSettings({ accentIntensity })"
          @update-app-font-size="(appFontSize) => updateSettings({ appFontSize })"
          @update-terminal-font-size="(terminalFontSize) => updateSettings({ terminalFontSize })"
          @update-close-app-on-last-pane="
            (closeAppOnLastPane) => updateSettings({ closeAppOnLastPane })
          "
          @update-app-state="persistAppState"
        />

        <TaskDialog
          v-if="newTaskVisible || editingTask"
          :app-state="appState"
          :progress="taskDialogProgress"
          :task="editingTask || undefined"
          @close="closeTaskDialog"
          @create="createNewTask"
          @delete="deleteExistingTask"
          @dismiss-progress="dismissTaskProgress"
          @update="updateExistingTask"
        />

        <div
          v-if="paneCloseConfirmation"
          :class="styles.confirmLayer"
          role="dialog"
          aria-modal="true"
          aria-labelledby="pane-close-title"
        >
          <div :class="styles.dragRegion" data-tauri-drag-region @mousedown="startWindowDrag" />

          <section :class="styles.confirmDialog">
            <div :class="styles.confirmHeader">
              <span :class="styles.confirmIcon" aria-hidden="true">
                <LayersIcon :size="18" />
              </span>
              <div>
                <h2 id="pane-close-title">Close active pane?</h2>
                <p>
                  This pane is running
                  <strong>{{ paneCloseConfirmation.command || 'a process' }}</strong>. Closing it
                  will stop that terminal session.
                </p>
                <p v-if="paneCloseConfirmation.closeAppAfterClose">
                  This is the last pane, so Piñata will close too.
                </p>
              </div>
            </div>

            <div :class="styles.confirmActions">
              <button type="button" class="uiButton" @click="cancelPaneClose">
                Keep pane
              </button>
              <button type="button" class="uiButton uiButtonDanger" @click="confirmPaneClose">
                Close pane
              </button>
            </div>
          </section>
        </div>
      </template>

      <OnboardingFlow
        v-else
        :settings="settings"
        :app-state="appState"
        @update-settings="updateSettings"
        @finish="finishOnboarding"
      />
    </template>
  </div>
</template>
