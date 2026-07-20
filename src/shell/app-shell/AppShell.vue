<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref } from 'vue'
import { listen, type UnlistenFn } from '@tauri-apps/api/event'
import MainSurface from '../main-surface/MainSurface.vue'
import SidePanel from '../side-panel/SidePanel.vue'
import TitleBar from '../title-bar/TitleBar.vue'
import {
  createTaskRepoWorktree,
  createTask,
  createEmptyAppState,
  deleteTaskRepoWorktree,
  findRegisteredRepo,
  hasRegisteredRepo,
  loadAppState,
  plannedTaskRepoWorktreePath,
  saveAppState,
  updateTask,
  type AppState,
  type NewTaskInput,
  type RegisteredRepo,
  type Task,
  type TaskRepoGitOperation,
  type TaskRepo,
} from '../../features/app-state/app-state'
import OnboardingFlow from '../../features/onboarding/OnboardingFlow.vue'
import { onboardingKey } from '../../features/onboarding/onboarding'
import SettingsView from '../../features/settings/SettingsView.vue'
import { ensureTerminalSession, killTerminalSession } from '../../features/terminal/terminal'
import TaskDialog from '../../features/task-sidebar/task-dialog/TaskDialog.vue'
import TaskSidePanel from '../../features/task-sidebar/TaskSidePanel.vue'
import {
  type AppSettings,
  defaultSettings,
  loadSettings,
  saveSettings,
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

const startsInOnboarding = !localStorage.getItem(onboardingKey)
const leftSidePanelVisible = ref(true)
const rightSidePanelVisible = ref(false)
const settingsVisible = ref(false)
const newTaskVisible = ref(false)
const editingTaskId = ref<string | null>(null)
const onboardingVisible = ref(startsInOnboarding)
const bootstrapped = ref(false)
const taskDialogProgress = ref<TaskProgress | null>(null)
const appState = ref<AppState>(createEmptyAppState())
const settings = ref<AppSettings>(startsInOnboarding ? { ...defaultSettings } : loadSettings())
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
let unlistenOpenSettings: UnlistenFn | undefined
let unlistenGitProgress: UnlistenFn | undefined
let appStateTouched = false

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
  await saveAppState(next)
}

function selectTaskRepo(task: Task, taskRepo: TaskRepo) {
  persistAppState({
    ...appState.value,
    selection: {
      ...appState.value.selection,
      taskId: task.id,
      taskRepoIdByTaskId: {
        ...appState.value.selection.taskRepoIdByTaskId,
        [task.id]: taskRepo.id,
      },
      expandedTaskIds: Array.from(new Set([...appState.value.selection.expandedTaskIds, task.id])),
    },
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
      await killTerminalSession({ taskRepoId: plan.id }).catch(() => undefined)
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
        await ensureTerminalSession({ taskRepoId: plan.id, cwd: worktreePath })
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
        await killTerminalSession({ taskRepoId: plan.id })
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
    const firstTaskRepo = task.repos[0]
    const createPlans = createPlansForTask(task)

    startTaskProgress('Create task', createPlans, [])

    const nextTask = await runCreatePlans(task, createPlans)

    await persistAppStateAsync({
      ...appState.value,
      tasks: [nextTask, ...appState.value.tasks],
      selection: {
        ...appState.value.selection,
        taskId: nextTask.id,
        taskRepoIdByTaskId: {
          ...appState.value.selection.taskRepoIdByTaskId,
          [nextTask.id]: firstTaskRepo?.id ?? null,
        },
        expandedTaskIds: Array.from(
          new Set([nextTask.id, ...appState.value.selection.expandedTaskIds]),
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

    await persistAppStateAsync({
      ...appState.value,
      tasks: appState.value.tasks.map((item) => (item.id === task.id ? materializedTask : item)),
      selection: {
        ...appState.value.selection,
        taskRepoIdByTaskId: {
          ...appState.value.selection.taskRepoIdByTaskId,
          [task.id]:
            materializedTask.repos.find(
              (taskRepo) =>
                taskRepo.id === appState.value.selection.taskRepoIdByTaskId[task.id],
            )?.id ?? materializedTask.repos[0]?.id ?? null,
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
    const taskRepoIdByTaskId = { ...appState.value.selection.taskRepoIdByTaskId }
    const selectedFallbackTask = nextTasks[0]
    const cleanupPlans = cleanupPlansForTaskRepos(task, task.repos)

    delete taskRepoIdByTaskId[task.id]

    if (appState.value.selection.taskId === task.id && selectedFallbackTask) {
      taskRepoIdByTaskId[selectedFallbackTask.id] ??= selectedFallbackTask.repos[0]?.id ?? null
    }

    startTaskProgress('Delete task', [], cleanupPlans)

    await runCleanupPlans(cleanupPlans)

    await persistAppStateAsync({
      ...appState.value,
      tasks: nextTasks,
      selection: {
        ...appState.value.selection,
        taskId:
          appState.value.selection.taskId === task.id
            ? selectedFallbackTask?.id ?? null
            : appState.value.selection.taskId,
        taskRepoIdByTaskId,
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
    })
    .catch((error: unknown) => {
      console.error('Failed to load app state', error)
    })
    .finally(() => {
      bootstrapped.value = true
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
  unlistenOpenSettings?.()
  unlistenGitProgress?.()
})
</script>

<template>
  <div
    :class="styles.shell"
    :data-theme="settings.theme"
    :data-accent="settings.accent"
    :data-accent-intensity="settings.accentIntensity"
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
          ]"
        >
          <TaskSidePanel
            :app-state="appState"
            :visible="leftSidePanelVisible"
            :working-task-id="workingTaskId"
            @edit-task="openEditTask"
            @open-new-task="openNewTask"
            @select-task-repo="selectTaskRepo"
            @toggle-task="toggleTask"
          />
          <MainSurface :app-state="appState" />
          <SidePanel title="Side panel" empty="Nothing here yet." side="right" :visible="rightSidePanelVisible" />
        </div>

        <SettingsView
          v-if="settingsVisible"
          :theme="settings.theme"
          :accent="settings.accent"
          :accent-intensity="settings.accentIntensity"
          :app-state="appState"
          @close="closeSettings"
          @update-theme="(theme) => updateSettings({ theme })"
          @update-accent="(accent) => updateSettings({ accent })"
          @update-accent-intensity="(accentIntensity) => updateSettings({ accentIntensity })"
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
