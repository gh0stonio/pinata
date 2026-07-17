<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { listen, type UnlistenFn } from '@tauri-apps/api/event'
import MainSurface from '../main-surface/MainSurface.vue'
import SidePanel from '../side-panel/SidePanel.vue'
import TitleBar from '../title-bar/TitleBar.vue'
import {
  createTask,
  createEmptyAppState,
  loadAppState,
  saveAppState,
  updateTask,
  type AppState,
  type NewTaskInput,
  type Task,
  type TaskRepo,
} from '../../features/app-state/app-state'
import SettingsView from '../../features/settings/SettingsView.vue'
import TaskDialog from '../../features/task-sidebar/task-dialog/TaskDialog.vue'
import TaskSidePanel from '../../features/task-sidebar/TaskSidePanel.vue'
import { type AppSettings, loadSettings, saveSettings } from '../../features/settings/settings'
import styles from './AppShell.module.css'

const leftSidePanelVisible = ref(true)
const rightSidePanelVisible = ref(false)
const settingsVisible = ref(false)
const newTaskVisible = ref(false)
const editingTaskId = ref<string | null>(null)
const appState = ref<AppState>(createEmptyAppState())
const settings = ref<AppSettings>(loadSettings())
const editingTask = computed(() =>
  appState.value.tasks.find((task) => task.id === editingTaskId.value),
)
const taskDialogOpen = computed(() => newTaskVisible.value || Boolean(editingTask.value))
let unlistenOpenSettings: UnlistenFn | undefined

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
  editingTaskId.value = null
  newTaskVisible.value = true
}

function openEditTask(task: Task) {
  newTaskVisible.value = false
  editingTaskId.value = task.id
}

function closeTaskDialog() {
  newTaskVisible.value = false
  editingTaskId.value = null
}

function closeSettings() {
  settingsVisible.value = false
}

function persistAppState(next: AppState) {
  appState.value = next
  void saveAppState(next).catch((error: unknown) => {
    console.error('Failed to save app state', error)
  })
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

function createNewTask(input: NewTaskInput) {
  const task = createTask(input)
  const firstTaskRepo = task.repos[0]

  persistAppState({
    ...appState.value,
    tasks: [task, ...appState.value.tasks],
    selection: {
      ...appState.value.selection,
      taskId: task.id,
      taskRepoIdByTaskId: {
        ...appState.value.selection.taskRepoIdByTaskId,
        [task.id]: firstTaskRepo?.id ?? null,
      },
      expandedTaskIds: Array.from(new Set([task.id, ...appState.value.selection.expandedTaskIds])),
    },
  })
  closeTaskDialog()
}

function updateExistingTask(task: Task, input: NewTaskInput) {
  const nextTask = updateTask(task, input)

  persistAppState({
    ...appState.value,
    tasks: appState.value.tasks.map((item) => (item.id === task.id ? nextTask : item)),
    selection: {
      ...appState.value.selection,
      taskRepoIdByTaskId: {
        ...appState.value.selection.taskRepoIdByTaskId,
        [task.id]:
          nextTask.repos.find(
            (taskRepo) =>
              taskRepo.id === appState.value.selection.taskRepoIdByTaskId[task.id],
          )?.id ?? nextTask.repos[0]?.id ?? null,
      },
    },
  })
  closeTaskDialog()
}

function deleteExistingTask(task: Task) {
  const nextTasks = appState.value.tasks.filter((item) => item.id !== task.id)
  const taskRepoIdByTaskId = { ...appState.value.selection.taskRepoIdByTaskId }
  const selectedFallbackTask = nextTasks[0]

  delete taskRepoIdByTaskId[task.id]

  if (appState.value.selection.taskId === task.id && selectedFallbackTask) {
    taskRepoIdByTaskId[selectedFallbackTask.id] ??= selectedFallbackTask.repos[0]?.id ?? null
  }

  persistAppState({
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
}

function handleKeydown(event: KeyboardEvent) {
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
      appState.value = state
    })
    .catch((error: unknown) => {
      console.error('Failed to load app state', error)
    })
  void listen('pinata://open-settings', openSettings).then((unlisten) => {
    unlistenOpenSettings = unlisten
  })
})

onBeforeUnmount(() => {
  window.removeEventListener('keydown', handleKeydown)
  unlistenOpenSettings?.()
})
</script>

<template>
  <div
    :class="styles.shell"
    :data-theme="settings.theme"
    :data-accent="settings.accent"
    data-density="regular"
  >
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
      :app-state="appState"
      @close="closeSettings"
      @update-theme="(theme) => updateSettings({ theme })"
      @update-accent="(accent) => updateSettings({ accent })"
      @update-app-state="persistAppState"
    />

    <TaskDialog
      v-if="newTaskVisible || editingTask"
      :app-state="appState"
      :task="editingTask || undefined"
      @close="closeTaskDialog"
      @create="createNewTask"
      @delete="deleteExistingTask"
      @update="updateExistingTask"
    />
  </div>
</template>
