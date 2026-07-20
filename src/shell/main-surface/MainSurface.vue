<script setup lang="ts">
import { computed } from 'vue'
import type { AppState } from '../../features/app-state/app-state'
import { findRegisteredRepo } from '../../features/app-state/app-state'
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

  const selectedTaskRepoId = props.appState.selection.taskRepoIdByTaskId[task.id]
  return task.repos.find((repo) => repo.id === selectedTaskRepoId) ?? task.repos[0]
})

const selectedRegisteredRepo = computed(() => {
  const taskRepo = selectedTaskRepo.value
  return taskRepo ? findRegisteredRepo(props.appState, taskRepo.registeredRepoId) : undefined
})
</script>

<template>
  <main :class="styles.main">
    <TerminalSurface
      v-if="selectedTaskRepo?.worktreePath && selectedRegisteredRepo"
      :key="selectedTaskRepo.id"
      :task-repo="selectedTaskRepo"
      :repo-name="selectedRegisteredRepo.name"
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
              ? 'Terminal spawn comes next for this task.'
              : 'Create a task, pick a repo, then open a terminal.'
          }}
        </p>
      </div>
    </section>
  </main>
</template>
