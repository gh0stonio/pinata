<script setup lang="ts">
import { getCurrentWindow } from '@tauri-apps/api/window'
import { onBeforeUnmount, onMounted, ref } from 'vue'
import SidePanelIcon from '../../icons/SidePanelIcon.vue'
import styles from './TitleBar.module.css'

defineProps<{
  leftSidePanelVisible: boolean
  rightSidePanelVisible: boolean
}>()

const emit = defineEmits<{
  'toggle-left-side-panel': []
  'toggle-right-side-panel': []
}>()

const appWindow = getCurrentWindow()
const isFullscreen = ref(false)
let unlistenResize: (() => void) | undefined

async function syncFullscreenState() {
  try {
    isFullscreen.value = await appWindow.isFullscreen()
  } catch {
    isFullscreen.value = false
  }
}

function startWindowDrag(event: MouseEvent) {
  if (event.buttons !== 1) {
    return
  }

  if ((event.target as HTMLElement | null)?.closest('button')) {
    return
  }

  void appWindow.startDragging().catch(() => undefined)
}

onMounted(() => {
  void syncFullscreenState()
  void appWindow
    .onResized(() => {
      void syncFullscreenState()
    })
    .then((unlisten) => {
      unlistenResize = unlisten
    })
    .catch(() => undefined)
})

onBeforeUnmount(() => {
  unlistenResize?.()
})
</script>

<template>
  <header
    :class="[styles.titleBar, isFullscreen && styles.fullscreen]"
    data-tauri-drag-region
    @mousedown="startWindowDrag"
  >
    <div :class="styles.leftGroup" data-tauri-drag-region>
      <div :class="styles.trafficLightReserve" data-tauri-drag-region />

      <button
        type="button"
        :class="[styles.tButton, leftSidePanelVisible && styles.active]"
        :aria-pressed="leftSidePanelVisible"
        :aria-label="leftSidePanelVisible ? 'Collapse left side panel' : 'Open left side panel'"
        @mousedown.stop
        @click.stop="emit('toggle-left-side-panel')"
      >
        <SidePanelIcon side="left" :open="leftSidePanelVisible" />
        <span :class="[styles.tooltip, styles.leftTooltip]">
          <span>{{ leftSidePanelVisible ? 'Collapse side panel' : 'Open side panel' }}</span>
          <kbd>⌘B</kbd>
        </span>
      </button>
    </div>

    <div :class="styles.center" data-tauri-drag-region />

    <div :class="styles.rightGroup" data-tauri-drag-region>
      <button
        type="button"
        :class="[styles.tButton, rightSidePanelVisible && styles.active]"
        :aria-pressed="rightSidePanelVisible"
        :aria-label="rightSidePanelVisible ? 'Collapse right side panel' : 'Open right side panel'"
        @mousedown.stop
        @click.stop="emit('toggle-right-side-panel')"
      >
        <SidePanelIcon side="right" :open="rightSidePanelVisible" />
        <span :class="[styles.tooltip, styles.rightTooltip]">
          <span>{{ rightSidePanelVisible ? 'Collapse side panel' : 'Open side panel' }}</span>
          <kbd>⌘L</kbd>
        </span>
      </button>
    </div>
  </header>
</template>
