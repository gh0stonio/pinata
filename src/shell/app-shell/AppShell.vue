<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from 'vue'
import { listen, type UnlistenFn } from '@tauri-apps/api/event'
import MainSurface from '../main-surface/MainSurface.vue'
import SidePanel from '../side-panel/SidePanel.vue'
import TitleBar from '../title-bar/TitleBar.vue'
import {
  createEmptyAppState,
  loadAppState,
  saveAppState,
  type AppState,
  type Task,
  type TaskRepo,
} from '../../features/app-state/app-state'
import SettingsView from '../../features/settings/SettingsView.vue'
import TaskSidePanel from '../../features/task-sidebar/TaskSidePanel.vue'
import { type AppSettings, loadSettings, saveSettings } from '../../features/settings/settings'
import styles from './AppShell.module.css'

const leftSidePanelVisible = ref(true)
const rightSidePanelVisible = ref(false)
const settingsVisible = ref(false)
const appState = ref<AppState>(createEmptyAppState())
const settings = ref<AppSettings>(loadSettings())
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

function handleKeydown(event: KeyboardEvent) {
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
  </div>
</template>
