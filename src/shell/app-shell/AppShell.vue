<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from 'vue'
import { listen, type UnlistenFn } from '@tauri-apps/api/event'
import MainSurface from '../main-surface/MainSurface.vue'
import SidePanel from '../side-panel/SidePanel.vue'
import TitleBar from '../title-bar/TitleBar.vue'
import SettingsView from '../../features/settings/SettingsView.vue'
import { type AppSettings, loadSettings, saveSettings } from '../../features/settings/settings'
import styles from './AppShell.module.css'

const leftSidePanelVisible = ref(true)
const rightSidePanelVisible = ref(false)
const settingsVisible = ref(false)
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

function handleKeydown(event: KeyboardEvent) {
  if (settingsVisible.value) {
    if (event.key === 'Escape' || ((event.metaKey || event.ctrlKey) && event.key === ',')) {
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
      <SidePanel title="Side panel" empty="Nothing here yet." side="left" :visible="leftSidePanelVisible" />
      <MainSurface />
      <SidePanel title="Side panel" empty="Nothing here yet." side="right" :visible="rightSidePanelVisible" />
    </div>

    <SettingsView
      v-if="settingsVisible"
      :theme="settings.theme"
      :accent="settings.accent"
      @close="closeSettings"
      @update-theme="(theme) => updateSettings({ theme })"
      @update-accent="(accent) => updateSettings({ accent })"
    />
  </div>
</template>
