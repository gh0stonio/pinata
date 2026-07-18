<script setup lang="ts">
import { computed, ref } from 'vue'
import pinataLogo from '../../assets/brand/pinata-logo.png'
import ChevronDownIcon from '../../icons/ChevronDownIcon.vue'
import PencilIcon from '../../icons/PencilIcon.vue'
import PlusIcon from '../../icons/PlusIcon.vue'
import {
  findRegisteredRepo,
  plannedTaskRepoWorktreePath,
  type AppState,
  type Task,
  type TaskRepo,
} from '../app-state/app-state'
import styles from './TaskSidePanel.module.css'

const props = defineProps<{
  appState: AppState
  visible: boolean
}>()

const emit = defineEmits<{
  'edit-task': [task: Task]
  'open-new-task': []
  'select-task-repo': [task: Task, taskRepo: TaskRepo]
  'toggle-task': [task: Task]
}>()

const hoveredTask = ref<Task | null>(null)
const hoveredTaskRepo = ref<TaskRepo | null>(null)
const hoverTop = ref(0)
const hoverLeft = ref(0)

const hoverStyle = computed(() => ({
  top: `${hoverTop.value}px`,
  left: `${hoverLeft.value}px`,
}))

function showRepoHover(task: Task, taskRepo: TaskRepo, event: MouseEvent) {
  const rect = (event.currentTarget as HTMLElement).getBoundingClientRect()

  hoveredTask.value = task
  hoveredTaskRepo.value = taskRepo
  hoverTop.value = Math.max(8, Math.min(rect.top, window.innerHeight - 210))
  hoverLeft.value = Math.max(8, Math.min(rect.right + 4, window.innerWidth - 280))
}

function hideRepoHover() {
  hoveredTask.value = null
  hoveredTaskRepo.value = null
}

function isTaskExpanded(taskId: string) {
  return props.appState.selection.expandedTaskIds.includes(taskId)
}

function isTaskSelected(taskId: string) {
  return props.appState.selection.taskId === taskId
}

function isTaskRepoSelected(task: Task, taskRepo: TaskRepo) {
  return isTaskSelected(task.id) && props.appState.selection.taskRepoIdByTaskId[task.id] === taskRepo.id
}

function registeredRepoFor(taskRepo: TaskRepo) {
  return findRegisteredRepo(props.appState, taskRepo.registeredRepoId)
}

function taskRepoName(taskRepo: TaskRepo) {
  return registeredRepoFor(taskRepo)?.name ?? 'Unknown repo'
}

function taskRepoPath(task: Task, taskRepo: TaskRepo) {
  const registeredRepo = registeredRepoFor(taskRepo)

  if (!registeredRepo) {
    return taskRepo.worktreePath ?? 'Not set'
  }

  return plannedTaskRepoWorktreePath(
    props.appState.repositoryDefaults,
    task,
    taskRepo,
    registeredRepo,
  )
}
</script>

<template>
  <aside
    :class="[styles.sidebar, !visible && styles.hidden]"
    :aria-hidden="!visible"
    aria-label="Tasks"
  >
    <header :class="styles.brand">
      <img :class="styles.brandLogo" :src="pinataLogo" alt="" draggable="false" />
      <span :class="styles.wordmark">Piñata</span>
    </header>

    <div :class="styles.primaryAction">
      <button
        type="button"
        class="uiButton uiButtonPrimary"
        :class="styles.newTaskButton"
        @click="emit('open-new-task')"
      >
        <PlusIcon />
        New task
      </button>
    </div>

    <div :class="styles.labelRow">
      <span :class="styles.label">Tasks</span>
    </div>

    <div :class="styles.scroller">
      <p v-if="!appState.tasks.length" :class="styles.empty">Nothing here yet.</p>

      <ul v-else :class="styles.taskList" aria-label="Tasks">
        <li v-for="task in appState.tasks" :key="task.id" :class="styles.taskItem">
          <div :class="styles.taskRow">
            <button
              type="button"
              :class="styles.taskToggle"
              :aria-expanded="isTaskExpanded(task.id)"
              :aria-label="isTaskExpanded(task.id) ? `Collapse ${task.name}` : `Expand ${task.name}`"
              @click="emit('toggle-task', task)"
            >
              <span
                :class="[styles.chevron, isTaskExpanded(task.id) && styles.chevronOpen]"
                aria-hidden="true"
              >
                <ChevronDownIcon />
              </span>

              <span :class="styles.taskButton">
                <span :class="styles.taskName">{{ task.name }}</span>
              </span>
            </button>

            <button
              type="button"
              class="uiButton uiButtonIcon uiButtonNaked"
              :class="styles.taskAction"
              :aria-label="`Edit ${task.name}`"
              @click="emit('edit-task', task)"
            >
              <PencilIcon />
            </button>
          </div>

          <ul v-if="isTaskExpanded(task.id)" :class="styles.repoList" aria-label="Task repos">
            <li v-for="taskRepoItem in task.repos" :key="taskRepoItem.id" :class="styles.repoItem">
              <button
                type="button"
                :class="[
                  styles.repoButton,
                  isTaskRepoSelected(task, taskRepoItem) && styles.repoButtonActive,
                ]"
                @mouseenter="showRepoHover(task, taskRepoItem, $event)"
                @mouseleave="hideRepoHover"
                @click="emit('select-task-repo', task, taskRepoItem)"
              >
                <span :class="styles.repoMain">
                  <span :class="styles.repoName">{{ taskRepoName(taskRepoItem) }}</span>
                </span>
              </button>
            </li>
          </ul>
        </li>
      </ul>
    </div>

    <div
      v-if="hoveredTask && hoveredTaskRepo"
      :class="styles.hoverCard"
      :style="hoverStyle"
      role="tooltip"
    >
      <dl :class="styles.metaList">
        <div>
          <dt>Branch</dt>
          <dd>{{ hoveredTaskRepo.branch }}</dd>
        </div>
        <div>
          <dt>Base</dt>
          <dd>{{ hoveredTaskRepo.baseBranch }}</dd>
        </div>
        <div>
          <dt>Worktree</dt>
          <dd>{{ taskRepoPath(hoveredTask, hoveredTaskRepo) }}</dd>
        </div>
      </dl>
    </div>
  </aside>
</template>
