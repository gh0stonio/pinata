<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, type CSSProperties } from 'vue'
import { invoke } from '@tauri-apps/api/core'
import { listen, type UnlistenFn } from '@tauri-apps/api/event'
import { getCurrentWindow, type PhysicalPosition, type PhysicalSize } from '@tauri-apps/api/window'
import ConfirmationDialog from './ConfirmationDialog.vue'
import MainSurface from '../main-surface/MainSurface.vue'
import SidePanel from '../side-panel/SidePanel.vue'
import TitleBar from '../title-bar/TitleBar.vue'
import {
  activateTaskTerminalPane,
  closeTaskTerminalTab,
  closeTaskTerminalPane,
  createTaskTerminalTab,
  createTaskRepoWorktree,
  createTask,
  DEFAULT_APP_LAYOUT,
  createEmptyAppState,
  deleteTaskRepoWorktree,
  effectiveTerminalLayout,
  effectiveTerminalTabs,
  findRegisteredRepo,
  focusTaskTerminalTarget,
  hasRegisteredRepo,
  loadAppState,
  plannedTaskRepoWorktreePath,
  renameTaskTerminalTab,
  saveAppState,
  selectedTerminalTarget,
  selectTaskTerminalTab,
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
  type TaskTerminalPane,
  type TaskRepoGitOperation,
  type TaskRepo,
  type TaskSurfaceSelection,
  type TerminalSplitDirection,
} from '../../features/app-state/app-state'
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

type TaskOperationKind = 'create' | 'update' | 'delete'

type PendingTaskOperation = {
  taskId: string
  kind: TaskOperationKind
  progress: TaskProgress
  hidden: boolean
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
  paneId?: string
  tabId?: string
  command?: string
  closeAppAfterClose: boolean
}

const MIN_WINDOW_WIDTH = 900
const MIN_WINDOW_HEIGHT = 600
const MAX_WINDOW_WIDTH = 4000
const MAX_WINDOW_HEIGHT = 3000
const WINDOW_LAYOUT_SAVE_DELAY = 300
const TERMINAL_PROCESS_REFRESH_DELAY = 0
const TERMINAL_PROCESS_POLL_INTERVAL = 5000

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
const pendingTaskOperations = ref<Record<string, PendingTaskOperation>>({})
const activeTaskOperationId = ref<string | null>(null)
const paneCloseConfirmation = ref<PaneCloseConfirmation | null>(null)
const appCloseConfirmation = ref<'preference' | 'task-operation' | null>(null)
const appState = ref<AppState>(createEmptyAppState())
const settings = ref<AppSettings>(startsInOnboarding ? { ...defaultSettings } : loadSettings())
const terminalProcessNames = ref<Record<string, string>>({})
const terminalCurrentPaths = ref<Record<string, string>>({})
const terminalFontSize = computed(() => terminalFontSizePxById[settings.value.terminalFontSize])
const editingTask = computed(() =>
  appState.value.tasks.find((task) => task.id === editingTaskId.value),
)
const activeTaskOperation = computed(() =>
  activeTaskOperationId.value
    ? pendingTaskOperations.value[activeTaskOperationId.value] ?? null
    : null,
)
const visibleTaskProgress = computed(() => activeTaskOperation.value?.progress ?? null)
const taskDialogOpen = computed(
  () =>
    Boolean(activeTaskOperation.value && !activeTaskOperation.value.hidden) ||
    newTaskVisible.value ||
    Boolean(editingTask.value),
)
const workingTaskIds = computed(() =>
  Object.values(pendingTaskOperations.value)
    .filter((operation) => taskProgressIsBusy(operation.progress))
    .map((operation) => operation.taskId),
)
const resumableTaskProgressIds = computed(() =>
  Object.values(pendingTaskOperations.value)
    .filter((operation) => operation.hidden && taskProgressIsBusy(operation.progress))
    .map((operation) => operation.taskId),
)
const selectedPendingTaskOperation = computed(() =>
  appState.value.selection.taskId
    ? pendingTaskOperations.value[appState.value.selection.taskId] ?? null
    : null,
)
const taskSurfaceOperation = computed(() => {
  const operation = selectedPendingTaskOperation.value

  return operation ? { taskId: operation.taskId, kind: operation.kind } : null
})
const bodyLayoutStyle = computed<CSSProperties>(() => ({
  '--left-side-panel-width': `${leftSidePanelWidth.value}px`,
  '--right-side-panel-width': `${rightSidePanelWidth.value}px`,
}))
let unlistenOpenSettings: UnlistenFn | undefined
let unlistenGitProgress: UnlistenFn | undefined
let unlistenAppCloseRequested: UnlistenFn | undefined
let unlistenWindowResized: UnlistenFn | undefined
let unlistenWindowMoved: UnlistenFn | undefined
let unlistenWindowClose: UnlistenFn | undefined
let appStateTouched = false
let appStateSaveQueue: Promise<void> = Promise.resolve()
let sidePanelResizeStart: SidePanelResizeStart | undefined
let windowLayoutSaveTimer: number | undefined
let pendingWindowSize: PhysicalSize | undefined
let pendingWindowPosition: PhysicalPosition | undefined
let terminalProcessPollTimer: number | undefined
let terminalProcessRefreshTimer: number | undefined
let terminalProcessPollInFlight = false

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

async function startWindowCloseConfirmation() {
  unlistenWindowClose = await appWindow.onCloseRequested((event) => {
    event.preventDefault()
    requestAppClose()
  })
}

function requestAppClose() {
  if (workingTaskIds.value.length > 0) {
    appCloseConfirmation.value = 'task-operation'
    return
  }

  if (settings.value.confirmBeforeAppClose) {
    appCloseConfirmation.value = 'preference'
    return
  }

  void confirmAppClose()
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
  activeTaskOperationId.value = null
  editingTaskId.value = null
  newTaskVisible.value = true
}

function openEditTask(task: Task) {
  if (pendingTaskOperations.value[task.id]) {
    showTaskProgress(task)
    return
  }

  activeTaskOperationId.value = null
  newTaskVisible.value = false
  editingTaskId.value = task.id
}

function closeTaskDialog() {
  const operation = activeTaskOperation.value

  if (operation && taskProgressIsBusy(operation.progress)) {
    pendingTaskOperations.value = {
      ...pendingTaskOperations.value,
      [operation.taskId]: { ...operation, hidden: true },
    }
    activeTaskOperationId.value = null
    newTaskVisible.value = false
    editingTaskId.value = null
    return
  }

  if (operation) {
    dismissTaskProgress()
    return
  }

  newTaskVisible.value = false
  editingTaskId.value = null
}

function dismissTaskProgress() {
  const operation = activeTaskOperation.value

  if (operation) {
    const nextOperations = { ...pendingTaskOperations.value }

    delete nextOperations[operation.taskId]
    pendingTaskOperations.value = nextOperations
    activeTaskOperationId.value = null
    editingTaskId.value = operation.taskId
    return
  }
}

function hideTaskProgress() {
  const operation = activeTaskOperation.value

  if (operation && taskProgressIsBusy(operation.progress)) {
    pendingTaskOperations.value = {
      ...pendingTaskOperations.value,
      [operation.taskId]: { ...operation, hidden: true },
    }
    activeTaskOperationId.value = null
    newTaskVisible.value = false
    editingTaskId.value = null
  }
}

function showTaskProgress(task: Task) {
  const operation = pendingTaskOperations.value[task.id]

  if (operation) {
    pendingTaskOperations.value = {
      ...pendingTaskOperations.value,
      [task.id]: { ...operation, hidden: false },
    }
    activeTaskOperationId.value = task.id
    newTaskVisible.value = false
    editingTaskId.value = null
  }
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

async function updateAppStateAsync(update: (current: AppState) => AppState) {
  await persistAppStateAsync(update(appState.value))
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
  queueTerminalProcessRefresh()
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
  queueTerminalProcessRefresh()
}

function openSelectedTerminalTab() {
  const task = appState.value.tasks.find((item) => item.id === appState.value.selection.taskId)

  if (!task) {
    return
  }

  openTerminalTab(task.id)
}

function openTerminalTab(taskId: string) {
  const task = appState.value.tasks.find((item) => item.id === taskId)

  if (!task) {
    return
  }

  const terminal = selectedTerminalTarget(appState.value, task)

  if (!terminal) {
    return
  }

  updateStoredTask(task.id, (currentTask) => createTaskTerminalTab(currentTask, terminal))
  queueTerminalProcessRefresh()
}

function selectedTaskTerminalLayout(task: Task) {
  const terminal = selectedTerminalTarget(appState.value, task)

  return terminal ? effectiveTerminalLayout(task, terminal) : undefined
}

function selectedTaskTerminalTabs(task: Task) {
  const terminal = selectedTerminalTarget(appState.value, task)

  return terminal ? effectiveTerminalTabs(task, terminal) : undefined
}

function selectedTaskTerminalSessionIds() {
  const task = appState.value.tasks.find((item) => item.id === appState.value.selection.taskId)
  const tabs = task ? selectedTaskTerminalTabs(task) : undefined

  return tabs?.tabs.flatMap((tab) => tab.layout.panes.map((pane) => pane.sessionId)) ?? []
}

async function refreshTerminalProcessNames() {
  if (terminalProcessPollInFlight) {
    return
  }

  const sessionIds = Array.from(new Set(selectedTaskTerminalSessionIds()))

  if (!sessionIds.length) {
    terminalProcessNames.value = {}
    terminalCurrentPaths.value = {}
    return
  }

  terminalProcessPollInFlight = true

  try {
    const statuses = await Promise.all(
      sessionIds.map(async (sessionId) => ({
        sessionId,
        status: await terminalProcessStatus({ sessionId }).catch(() => ({
          busy: false,
          command: undefined,
          currentPath: undefined,
        })),
      })),
    )

    terminalProcessNames.value = Object.fromEntries(
      statuses
        .filter(({ status }) => status.busy && status.command)
        .map(({ sessionId, status }) => [sessionId, status.command as string]),
    )
    terminalCurrentPaths.value = Object.fromEntries(
      statuses
        .filter(({ status }) => status.currentPath)
        .map(({ sessionId, status }) => [sessionId, status.currentPath as string]),
    )
  } finally {
    terminalProcessPollInFlight = false
  }
}

function startTerminalProcessPolling() {
  window.clearInterval(terminalProcessPollTimer)
  void refreshTerminalProcessNames()
  terminalProcessPollTimer = window.setInterval(() => {
    void refreshTerminalProcessNames()
  }, TERMINAL_PROCESS_POLL_INTERVAL)
}

function queueTerminalProcessRefresh() {
  if (terminalProcessRefreshTimer) {
    return
  }

  terminalProcessRefreshTimer = window.setTimeout(() => {
    terminalProcessRefreshTimer = undefined
    void refreshTerminalProcessNames()
  }, TERMINAL_PROCESS_REFRESH_DELAY)
}

function handleTerminalOutput(sessionId: string) {
  if (selectedTaskTerminalSessionIds().includes(sessionId)) {
    queueTerminalProcessRefresh()
  }
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

async function closeTerminalTab(taskId: string, tabId: string, force = false) {
  const task = appState.value.tasks.find((item) => item.id === taskId)
  const terminal = task ? selectedTerminalTarget(appState.value, task) : undefined
  const tabs = task && terminal ? effectiveTerminalTabs(task, terminal) : undefined
  const tab = tabs?.tabs.find((item) => item.id === tabId)

  if (!task || !terminal || !tabs || !tab) {
    return
  }

  const closeAppAfterClose = tabs.tabs.length === 1 && settings.value.closeAppOnLastPane

  if (!force) {
    const statuses = await Promise.all(
      tab.layout.panes.map((pane) =>
        terminalProcessStatus({ sessionId: pane.sessionId }).catch(() => ({
          busy: false,
          command: undefined,
        })),
      ),
    )
    const busyStatus = statuses.find((status) => status.busy)

    if (busyStatus) {
      paneCloseConfirmation.value = {
        taskId,
        tabId,
        command: busyStatus.command,
        closeAppAfterClose,
      }
      return
    }
  }

  let closedPanes: TaskTerminalPane[] = []
  let closedLast = false
  let changed = false

  const tasks = appState.value.tasks.map((item) => {
    if (item.id !== taskId) {
      return item
    }

    const result = closeTaskTerminalTab(item, terminal, tabId)

    if (!result.closedPanes.length) {
      return item
    }

    closedPanes = result.closedPanes
    closedLast = result.closedLast
    changed = result.task !== item

    return result.task
  })

  if (!changed || !closedPanes.length) {
    return
  }

  await Promise.allSettled(
    closedPanes
      .filter((pane) => !paneSessionUsedByOtherPane(pane.sessionId, pane.id, tasks))
      .map((pane) => killTerminalSession({ sessionId: pane.sessionId })),
  )

  await persistAppStateAsync({
    ...appState.value,
    tasks,
  })

  if (closedLast && closeAppAfterClose) {
    await appWindow.close()
  }
}

async function closeActiveTerminalPane() {
  const task = appState.value.tasks.find((item) => item.id === appState.value.selection.taskId)
  const layout = task ? selectedTaskTerminalLayout(task) : undefined
  const tabs = task ? selectedTaskTerminalTabs(task) : undefined
  const activePane = layout?.panes.find((pane) => pane.id === layout.activePaneId)

  if (!task || !layout || !activePane) {
    return
  }

  const closeAppAfterClose =
    layout.panes.length === 1 && tabs?.tabs.length === 1 && settings.value.closeAppOnLastPane
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
  const tabs = task && terminal ? effectiveTerminalTabs(task, terminal) : undefined
  const pane = layout?.panes.find((item) => item.id === paneId)

  if (!task || !layout || !pane) {
    return
  }

  const closeAppAfterClose =
    layout.panes.length === 1 && tabs?.tabs.length === 1 && settings.value.closeAppOnLastPane
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

function cancelAppClose() {
  appCloseConfirmation.value = null
}

async function confirmAppClose() {
  appCloseConfirmation.value = null
  await invoke('confirm_app_close')
}

async function confirmPaneClose() {
  const confirmation = paneCloseConfirmation.value

  if (!confirmation) {
    return
  }

  paneCloseConfirmation.value = null

  if (confirmation.tabId) {
    await closeTerminalTab(confirmation.taskId, confirmation.tabId, true)
    return
  }

  if (confirmation.paneId) {
    await closeTerminalPane(
      confirmation.taskId,
      confirmation.paneId,
      confirmation.closeAppAfterClose,
    )
  }
}

function selectTerminalTab(taskId: string, tabId: string) {
  updateStoredTask(taskId, (task) => {
    const terminal = selectedTerminalTarget(appState.value, task)

    return terminal ? selectTaskTerminalTab(task, terminal, tabId) : task
  })
  queueTerminalProcessRefresh()
}

function renameTerminalTab(taskId: string, tabId: string, title: string) {
  updateStoredTask(taskId, (task) => {
    const terminal = selectedTerminalTarget(appState.value, task)

    return terminal ? renameTaskTerminalTab(task, terminal, tabId, title) : task
  })
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
  queueTerminalProcessRefresh()
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
  taskId: string,
  kind: TaskOperationKind,
  title: string,
  createPlans: TaskRepoGitPlan[],
  cleanupPlans: TaskRepoGitPlan[],
) {
  pendingTaskOperations.value = {
    ...pendingTaskOperations.value,
    [taskId]: {
      taskId,
      kind,
      progress: progressForPlans(title, createPlans, cleanupPlans),
      hidden: false,
    },
  }
  activeTaskOperationId.value = taskId
  newTaskVisible.value = false
  editingTaskId.value = null
}

function taskProgressIsBusy(progress: TaskProgress) {
  return (
    !progress.error &&
    progress.steps.some((step) => step.status === 'pending' || step.status === 'running')
  )
}

function progressForPlans(
  title: string,
  createPlans: TaskRepoGitPlan[],
  cleanupPlans: TaskRepoGitPlan[],
): TaskProgress {
  return {
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

function setPendingTaskOperationProgress(taskId: string, progress: TaskProgress) {
  const operation = pendingTaskOperations.value[taskId]

  if (!operation) {
    return
  }

  pendingTaskOperations.value = {
    ...pendingTaskOperations.value,
    [taskId]: { ...operation, progress },
  }
}

function updateTaskProgressStep(
  id: string,
  status: TaskProgressStep['status'],
  operationTaskId: string,
) {
  const progress = pendingTaskOperations.value[operationTaskId]?.progress

  if (!progress) {
    return
  }

  const nextProgress: TaskProgress = {
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

  setPendingTaskOperationProgress(operationTaskId, nextProgress)
}

function updateTaskProgressPhase(progressId: string, phase: string) {
  const operation = Object.values(pendingTaskOperations.value).find((item) =>
    item.progress.steps.some((step) => step.id === progressId),
  )
  const progress = operation?.progress

  if (!progress) {
    return
  }

  const nextProgress = {
    ...progress,
    steps: progress.steps.map((step) =>
      step.id === progressId && step.status === 'running' ? { ...step, detail: phase } : step,
    ),
  }

  if (operation) {
    setPendingTaskOperationProgress(operation.taskId, nextProgress)
  }
}

function failTaskProgress(
  error: unknown,
  taskId: string,
  kind: TaskOperationKind,
  title: string,
) {
  const operation = pendingTaskOperations.value[taskId]
  const progress = operation?.progress
  const message = error instanceof Error ? error.message : String(error)

  if (!progress) {
    pendingTaskOperations.value = {
      ...pendingTaskOperations.value,
      [taskId]: {
        taskId,
        kind,
        hidden: false,
        progress: {
          title,
          error: message,
          steps: [
            {
              id: `error-${taskId}`,
              kind: kind === 'delete' ? 'cleanup' : 'prepare',
              label: 'Operation failed',
              detail: message,
              status: 'error',
            },
          ],
        },
      },
    }
    activeTaskOperationId.value = taskId
    return
  }

  const failingStep =
    progress.steps.find((step) => step.status === 'running') ??
    progress.steps.find((step) => step.status === 'pending')

  const nextProgress: TaskProgress = {
    ...progress,
    error: message,
    steps: progress.steps.map((step) =>
      step.id === failingStep?.id ? { ...step, status: 'error' } : step,
    ),
  }

  setPendingTaskOperationProgress(taskId, nextProgress)
}

function finishTaskOperation(taskId: string) {
  const nextOperations = { ...pendingTaskOperations.value }

  delete nextOperations[taskId]
  pendingTaskOperations.value = nextOperations

  if (activeTaskOperationId.value === taskId) {
    activeTaskOperationId.value = null
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
  operationTaskId: string,
  createdPlans: TaskRepoGitPlan[] = [],
) {
  if (!plans.length) {
    return task
  }

  for (const plan of plans) {
    updateTaskProgressStep(`create-${plan.id}`, 'running', operationTaskId)
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
        updateTaskProgressStep(`create-${plan.id}`, 'done', operationTaskId)
        await flushTaskProgress()

        return createdPlan
      } catch (error) {
        updateTaskProgressStep(`create-${plan.id}`, 'error', operationTaskId)
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

async function runCleanupPlans(plans: TaskRepoGitPlan[], operationTaskId: string) {
  if (!plans.length) {
    return
  }

  for (const plan of plans) {
    updateTaskProgressStep(`cleanup-${plan.id}`, 'running', operationTaskId)
    updateTaskProgressPhase(`cleanup-${plan.id}`, 'Removing worktree')
  }
  await flushTaskProgress()

  const results = await Promise.allSettled(
    plans.map(async (plan) => {
      try {
        await killTerminalSession({ sessionId: plan.id })
        await deleteTaskRepoWorktree(plan)
        updateTaskProgressStep(`cleanup-${plan.id}`, 'done', operationTaskId)
      } catch (error) {
        updateTaskProgressStep(`cleanup-${plan.id}`, 'error', operationTaskId)
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
  const task = createTask(input)

  try {
    const createPlans = createPlansForTask(task)

    if (createPlans.length) {
      startTaskProgress(task.id, 'create', 'Create task', createPlans, [])
    }

    newTaskVisible.value = false
    await updateAppStateAsync((current) => ({
      ...current,
      tasks: [task, ...current.tasks],
      selection: {
        ...current.selection,
        taskId: task.id,
        surfaceByTaskId: {
          ...current.selection.surfaceByTaskId,
          [task.id]: { kind: 'task-terminal' },
        },
        expandedTaskIds: Array.from(
          new Set(
            task.repos.length
              ? [task.id, ...current.selection.expandedTaskIds]
              : current.selection.expandedTaskIds,
          ),
        ),
      },
    }))

    const nextTask = await runCreatePlans(task, createPlans, task.id)

    await updateAppStateAsync((current) => ({
      ...current,
      tasks: current.tasks.map((item) => (item.id === task.id ? nextTask : item)),
    }))

    finishTaskOperation(task.id)
  } catch (error) {
    failTaskProgress(error, task.id, 'create', 'Create task')
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
      startTaskProgress(task.id, 'update', 'Update task', createPlans, cleanupPlans)
    }

    const createdPlans: TaskRepoGitPlan[] = []
    const materializedTask = await runCreatePlans(nextTask, createPlans, task.id, createdPlans)

    try {
      await runCleanupPlans(cleanupPlans, task.id)
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
          terminalTabs: undefined,
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

    await updateAppStateAsync((current) => ({
      ...current,
      tasks: current.tasks.map((item) => (item.id === task.id ? nextMaterializedTask : item)),
      selection: {
        ...current.selection,
        surfaceByTaskId: {
          ...current.selection.surfaceByTaskId,
          [task.id]: selectedSurfaceForUpdatedTask(task, nextMaterializedTask),
        },
      },
    }))
    finishTaskOperation(task.id)
    if (editingTaskId.value === task.id) {
      editingTaskId.value = null
    }
  } catch (error) {
    failTaskProgress(error, task.id, 'update', 'Update task')
  }
}

async function deleteExistingTask(task: Task) {
  try {
    const cleanupPlans = cleanupPlansForTaskRepos(task, task.repos)

    if (cleanupPlans.length) {
      startTaskProgress(task.id, 'delete', 'Delete task', [], cleanupPlans)
    }

    await runCleanupPlans(cleanupPlans, task.id)
    await Promise.allSettled(
      terminalSessionIdsForTask(task).map((sessionId) => killTerminalSession({ sessionId })),
    )

    await updateAppStateAsync((current) => {
      const nextTasks = current.tasks.filter((item) => item.id !== task.id)
      const surfaceByTaskId = { ...current.selection.surfaceByTaskId }
      const selectedFallbackTask = nextTasks[0]

      delete surfaceByTaskId[task.id]

      if (current.selection.taskId === task.id && selectedFallbackTask) {
        surfaceByTaskId[selectedFallbackTask.id] ??= { kind: 'task-terminal' }
      }

      return {
        ...current,
        tasks: nextTasks,
        selection: {
          ...current.selection,
          taskId:
            current.selection.taskId === task.id
              ? selectedFallbackTask?.id ?? null
              : current.selection.taskId,
          surfaceByTaskId,
          expandedTaskIds: current.selection.expandedTaskIds.filter((id) => id !== task.id),
        },
      }
    })
    finishTaskOperation(task.id)
    if (editingTaskId.value === task.id) {
      editingTaskId.value = null
    }
  } catch (error) {
    failTaskProgress(error, task.id, 'delete', 'Delete task')
  }
}

function handleKeydown(event: KeyboardEvent) {
  if (appCloseConfirmation.value) {
    if (event.key === 'Escape') {
      event.preventDefault()
      cancelAppClose()
    }

    return
  }

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
    openSelectedTerminalTab()
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
  void startWindowCloseConfirmation().catch((error: unknown) => {
    console.error('Failed to listen for window close', error)
  })
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
      startTerminalProcessPolling()
      void startWindowLayoutPersistence().catch((error: unknown) => {
        console.error('Failed to listen for window layout changes', error)
      })
    })
  void listen('pinata://open-settings', openSettings).then((unlisten) => {
    unlistenOpenSettings = unlisten
  })
  void listen('pinata://request-app-close', requestAppClose).then((unlisten) => {
    unlistenAppCloseRequested = unlisten
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
  window.clearInterval(terminalProcessPollTimer)
  window.clearTimeout(terminalProcessRefreshTimer)
  void persistPendingWindowLayout().catch((error: unknown) => {
    console.error('Failed to save window layout', error)
  })
  unlistenOpenSettings?.()
  unlistenGitProgress?.()
  unlistenAppCloseRequested?.()
  unlistenWindowResized?.()
  unlistenWindowMoved?.()
  unlistenWindowClose?.()
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
            :working-task-ids="workingTaskIds"
            :resumable-task-progress-ids="resumableTaskProgressIds"
            @edit-task="openEditTask"
            @open-new-task="openNewTask"
            @show-task-progress="showTaskProgress"
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
            :task-operation="taskSurfaceOperation"
            :terminal-font-size="terminalFontSize"
            :terminal-current-paths="terminalCurrentPaths"
            :terminal-process-names="terminalProcessNames"
            @close-terminal-tab="(taskId, tabId) => void closeTerminalTab(taskId, tabId)"
            @close-terminal-pane="requestCloseTerminalPane"
            @open-terminal-tab="openTerminalTab"
            @rename-terminal-tab="renameTerminalTab"
            @select-terminal-pane="selectTerminalPane"
            @select-terminal-tab="selectTerminalTab"
            @split-terminal-pane="splitTerminalPane"
            @terminal-output="handleTerminalOutput"
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
          :confirm-before-app-close="settings.confirmBeforeAppClose"
          :close-app-on-last-pane="settings.closeAppOnLastPane"
          :app-state="appState"
          @close="closeSettings"
          @update-theme="(theme) => updateSettings({ theme })"
          @update-accent="(accent) => updateSettings({ accent })"
          @update-accent-intensity="(accentIntensity) => updateSettings({ accentIntensity })"
          @update-app-font-size="(appFontSize) => updateSettings({ appFontSize })"
          @update-terminal-font-size="(terminalFontSize) => updateSettings({ terminalFontSize })"
          @update-confirm-before-app-close="
            (confirmBeforeAppClose) => updateSettings({ confirmBeforeAppClose })
          "
          @update-close-app-on-last-pane="
            (closeAppOnLastPane) => updateSettings({ closeAppOnLastPane })
          "
          @update-app-state="persistAppState"
          @reset-settings="updateSettings(defaultSettings)"
        />

        <TaskDialog
          v-if="taskDialogOpen"
          :app-state="appState"
          :progress="visibleTaskProgress"
          :task="activeTaskOperation ? undefined : editingTask || undefined"
          @close="closeTaskDialog"
          @create="createNewTask"
          @delete="deleteExistingTask"
          @dismiss-progress="dismissTaskProgress"
          @hide-progress="hideTaskProgress"
          @update="updateExistingTask"
        />

        <ConfirmationDialog
          v-if="paneCloseConfirmation"
          title-id="pane-close-title"
          @drag="startWindowDrag"
        >
          <template #body>
            <h2 id="pane-close-title">
              {{ paneCloseConfirmation.tabId ? 'Close terminal tab?' : 'Close active pane?' }}
            </h2>
            <p>
              This {{ paneCloseConfirmation.tabId ? 'tab' : 'pane' }} is running
              <strong>{{ paneCloseConfirmation.command || 'a process' }}</strong>. Closing it
              will stop
              {{ paneCloseConfirmation.tabId ? 'its terminal sessions' : 'that terminal session' }}.
            </p>
            <p v-if="paneCloseConfirmation.closeAppAfterClose">
              This is the last pane, so Piñata will close too.
            </p>
          </template>

          <template #actions>
            <button type="button" class="uiButton" @click="cancelPaneClose">
              Keep {{ paneCloseConfirmation.tabId ? 'tab' : 'pane' }}
            </button>
            <button type="button" class="uiButton uiButtonDanger" @click="confirmPaneClose">
              Close {{ paneCloseConfirmation.tabId ? 'tab' : 'pane' }}
            </button>
          </template>
        </ConfirmationDialog>

      </template>

      <OnboardingFlow
        v-else
        :settings="settings"
        :app-state="appState"
        @update-settings="updateSettings"
        @finish="finishOnboarding"
      />
    </template>

    <ConfirmationDialog
      v-if="appCloseConfirmation"
      title-id="app-close-title"
      @drag="startWindowDrag"
    >
      <template #body>
        <template v-if="appCloseConfirmation === 'task-operation'">
          <h2 id="app-close-title">Close during task changes?</h2>
          <p>
            Task setup or cleanup is still running. Closing now interrupts that work, and its
            progress cannot be restored after reopening.
          </p>
        </template>
        <template v-else>
          <h2 id="app-close-title">Close Piñata?</h2>
          <p>Terminal sessions will stop when the app closes.</p>
        </template>
      </template>

      <template #actions>
        <button type="button" class="uiButton" @click="cancelAppClose">
          Keep open
        </button>
        <button type="button" class="uiButton uiButtonDanger" @click="confirmAppClose">
          {{ appCloseConfirmation === 'task-operation' ? 'Close anyway' : 'Close app' }}
        </button>
      </template>
    </ConfirmationDialog>
  </div>
</template>
