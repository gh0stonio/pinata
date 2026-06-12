<script setup lang="ts">
import { getCurrentWindow } from '@tauri-apps/api/window'
import styles from './TitleBar.module.css'

defineProps<{
  workspacesVisible: boolean
  contextVisible: boolean
}>()

const emit = defineEmits<{
  'toggle-workspaces': []
  'toggle-context': []
}>()

const appWindow = getCurrentWindow()

function startWindowDrag(event: MouseEvent) {
  if (event.buttons !== 1) {
    return
  }

  if ((event.target as HTMLElement | null)?.closest('button')) {
    return
  }

  void appWindow.startDragging().catch(() => undefined)
}
</script>

<template>
  <header :class="styles.titleBar" data-tauri-drag-region @mousedown="startWindowDrag">
    <div :class="styles.leftGroup" data-tauri-drag-region>
      <div :class="styles.trafficLightReserve" data-tauri-drag-region />

      <button
        type="button"
        :class="[styles.tButton, workspacesVisible && styles.active]"
        :aria-pressed="workspacesVisible"
        aria-label="Toggle Workspaces"
        title="Toggle Workspaces"
        @mousedown.stop
        @click.stop="emit('toggle-workspaces')"
      >
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" aria-hidden="true">
          <rect x="3" y="4" width="18" height="16" rx="2" />
          <line x1="9" y1="4" x2="9" y2="20" />
          <path d="M14 9l-2 3 2 3" />
        </svg>
      </button>
    </div>

    <div :class="styles.context" data-tauri-drag-region>
      <span :class="styles.brandTitle">Piñata</span>
    </div>

    <div :class="styles.rightGroup" data-tauri-drag-region>
      <button
        type="button"
        :class="[styles.tButton, contextVisible && styles.active]"
        :aria-pressed="contextVisible"
        aria-label="Toggle Context"
        title="Toggle Context"
        @mousedown.stop
        @click.stop="emit('toggle-context')"
      >
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" aria-hidden="true">
          <rect x="3" y="4" width="18" height="16" rx="2" />
          <line x1="15" y1="4" x2="15" y2="20" />
          <path d="M10 9l2 3-2 3" />
        </svg>
      </button>
    </div>
  </header>
</template>
