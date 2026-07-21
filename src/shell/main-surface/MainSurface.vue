<script setup lang="ts">
import { computed } from 'vue'
import type { AppState, TaskTerminalPane } from '../../features/app-state/app-state'
import {
  effectiveTerminalLayout,
  selectedTerminalTarget,
} from '../../features/app-state/app-state'
import styles from './MainSurface.module.css'
import TerminalSplitNode from './TerminalSplitNode.vue'

const props = defineProps<{
  appState: AppState
  terminalFontSize: number
}>()

const emit = defineEmits<{
  'select-terminal-pane': [taskId: string, paneId: string]
}>()

const selectedTask = computed(() =>
  props.appState.tasks.find((task) => task.id === props.appState.selection.taskId),
)

const selectedTerminal = computed(() => {
  const task = selectedTask.value

  return task ? selectedTerminalTarget(props.appState, task) : undefined
})

const terminalLayout = computed(() => {
  const task = selectedTask.value
  const terminal = selectedTerminal.value

  return task && terminal ? effectiveTerminalLayout(task, terminal) : undefined
})

const panesById = computed<Record<string, TaskTerminalPane>>(() => {
  const layout = terminalLayout.value

  if (!layout) {
    return {}
  }

  return Object.fromEntries(layout.panes.map((pane) => [pane.id, pane]))
})
</script>

<template>
  <main :class="styles.main">
    <TerminalSplitNode
      v-if="selectedTask && terminalLayout"
      :node="terminalLayout.root"
      :panes="panesById"
      :active-pane-id="terminalLayout.activePaneId"
      :terminal-font-size="terminalFontSize"
      @select-pane="emit('select-terminal-pane', selectedTask.id, $event)"
    />

    <section v-else :class="styles.content" aria-labelledby="pinata-empty-title">
      <div :class="styles.emptyState">
        <h1 id="pinata-empty-title">
          {{ selectedTask ? 'No pane open' : 'No terminal yet' }}
        </h1>
        <p>
          <template v-if="selectedTask">
            Press <kbd :class="styles.key">⌘T</kbd> to reopen a pane.
          </template>
          <template v-else>
            Create a task to open a terminal.
          </template>
        </p>
      </div>
    </section>
  </main>
</template>
