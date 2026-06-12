<script setup lang="ts">
import { ref } from 'vue'
import MainWorkspace from '../main-workspace/MainWorkspace.vue'
import SidePane from '../side-pane/SidePane.vue'
import TitleBar from '../title-bar/TitleBar.vue'
import styles from './AppShell.module.css'

const workspacesVisible = ref(true)
const contextVisible = ref(false)

function toggleWorkspaces() {
  workspacesVisible.value = !workspacesVisible.value
}

function toggleContext() {
  contextVisible.value = !contextVisible.value
}
</script>

<template>
  <div :class="styles.shell" data-theme="adeberry" data-density="regular">
    <TitleBar
      :workspaces-visible="workspacesVisible"
      :context-visible="contextVisible"
      @toggle-workspaces="toggleWorkspaces"
      @toggle-context="toggleContext"
    />

    <div
      :class="[
        styles.workspace,
        !workspacesVisible && styles.workspacesHidden,
        contextVisible && styles.contextVisible,
      ]"
    >
      <SidePane title="Workspaces" empty="No workspaces yet." side="left" :visible="workspacesVisible" />
      <MainWorkspace />
      <SidePane title="Context" empty="No context yet." side="right" :visible="contextVisible" />
    </div>
  </div>
</template>
