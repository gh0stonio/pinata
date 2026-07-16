<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from 'vue'
import MainSurface from '../main-surface/MainSurface.vue'
import SidePanel from '../side-panel/SidePanel.vue'
import TitleBar from '../title-bar/TitleBar.vue'
import styles from './AppShell.module.css'

const leftSidePanelVisible = ref(true)
const rightSidePanelVisible = ref(false)

function toggleLeftSidePanel() {
  leftSidePanelVisible.value = !leftSidePanelVisible.value
}

function toggleRightSidePanel() {
  rightSidePanelVisible.value = !rightSidePanelVisible.value
}

function handleKeydown(event: KeyboardEvent) {
  if (!event.metaKey && !event.ctrlKey) {
    return
  }

  if (event.key.toLowerCase() === 'b') {
    event.preventDefault()
    toggleLeftSidePanel()
  } else if (event.key.toLowerCase() === 'l') {
    event.preventDefault()
    toggleRightSidePanel()
  }
}

onMounted(() => {
  window.addEventListener('keydown', handleKeydown)
})

onBeforeUnmount(() => {
  window.removeEventListener('keydown', handleKeydown)
})
</script>

<template>
  <div :class="styles.shell" data-theme="pinata-dark" data-density="regular">
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
  </div>
</template>
