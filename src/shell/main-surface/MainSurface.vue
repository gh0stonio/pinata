<script setup lang="ts">
import { computed } from 'vue'
import type { AppState } from '../../features/app-state/app-state'
import {
  findRegisteredRepo,
  selectedTaskRepo as selectedTaskRepoForTask,
} from '../../features/app-state/app-state'
import TerminalSurface from '../../features/terminal/TerminalSurface.vue'
import styles from './MainSurface.module.css'

const props = defineProps<{
  appState: AppState
  terminalFontSize: number
}>()

const selectedTask = computed(() =>
  props.appState.tasks.find((task) => task.id === props.appState.selection.taskId),
)

const selectedTaskRepo = computed(() => {
  const task = selectedTask.value

  if (!task) {
    return undefined
  }

  return selectedTaskRepoForTask(task, props.appState.selection)
})

const selectedRegisteredRepo = computed(() => {
  const taskRepo = selectedTaskRepo.value
  return taskRepo ? findRegisteredRepo(props.appState, taskRepo.registeredRepoId) : undefined
})

const selectedTerminal = computed(() => {
  const task = selectedTask.value
  const taskRepo = selectedTaskRepo.value
  const registeredRepo = selectedRegisteredRepo.value

  if (!task) {
    return undefined
  }

  if (taskRepo) {
    return taskRepo.worktreePath && registeredRepo
      ? {
          id: taskRepo.id,
          cwd: taskRepo.worktreePath,
          label: registeredRepo.name,
        }
      : undefined
  }

  return {
    id: task.terminal.id,
    cwd: task.terminal.cwd,
    label: task.name,
  }
})
</script>

<template>
  <main :class="styles.main">
    <TerminalSurface
      v-if="selectedTerminal"
      :key="selectedTerminal.id"
      :session-id="selectedTerminal.id"
      :cwd="selectedTerminal.cwd"
      :label="selectedTerminal.label"
      :font-size="terminalFontSize"
    />

    <section v-else :class="styles.content" aria-labelledby="pinata-empty-title">
      <div :class="styles.emptyState">
        <h1 id="pinata-empty-title">
          {{ selectedRegisteredRepo ? selectedRegisteredRepo.name : 'No terminal yet' }}
        </h1>
        <p>
          {{
            selectedTask
              ? 'Repository terminal is not ready yet.'
              : 'Create a task to open a terminal.'
          }}
        </p>
      </div>
    </section>
  </main>
</template>
