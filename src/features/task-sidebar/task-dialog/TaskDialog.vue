<script setup lang="ts">
import { getCurrentWindow } from '@tauri-apps/api/window'
import { computed, onMounted, ref } from 'vue'
import CheckIcon from '../../../icons/CheckIcon.vue'
import ChevronDownIcon from '../../../icons/ChevronDownIcon.vue'
import GitBranchIcon from '../../../icons/GitBranchIcon.vue'
import LayersIcon from '../../../icons/LayersIcon.vue'
import PlusIcon from '../../../icons/PlusIcon.vue'
import RepositoryIcon from '../../../icons/RepositoryIcon.vue'
import TrashIcon from '../../../icons/TrashIcon.vue'
import XIcon from '../../../icons/XIcon.vue'
import {
  slugifyTaskName,
  type AppState,
  type NewTaskInput,
  type RegisteredRepo,
  type Task,
  type TaskRepo,
} from '../../app-state/app-state'
import styles from './TaskDialog.module.css'

const appWindow = getCurrentWindow()

type DialogRepoRow = {
  id: string
  taskRepoId?: string
  registeredRepoId: string
  baseBranch: string
  baseBranchLocked: boolean
}

type PendingConfirmation =
  | { kind: 'delete-task' }
  | { kind: 'remove-repo'; rowId: string; repoName: string }
  | { kind: 'replace-repo'; rowId: string; repoId: string; repoName: string; nextRepoName: string }

type ProgressStep = {
  id: string
  kind: 'prepare' | 'cleanup'
  label: string
  detail?: string
  status: 'pending' | 'running' | 'done' | 'error'
}

const props = defineProps<{
  appState: AppState
  task?: Task
  progress?: {
    title: string
    steps: ProgressStep[]
    error?: string
  } | null
}>()

const emit = defineEmits<{
  close: []
  create: [task: NewTaskInput]
  delete: [task: Task]
  'dismiss-progress': []
  update: [task: Task, input: NewTaskInput]
}>()

const nameInput = ref<HTMLInputElement | null>(null)
const taskName = ref(props.task?.name ?? '')
const rows = ref<DialogRepoRow[]>(initialRows())
const pendingConfirmation = ref<PendingConfirmation | null>(null)
const scrimPointerStartedOutside = ref(false)
const confirmPointerStartedOutside = ref(false)

const registry = computed(() => props.appState.repoRegistry)
const isEditing = computed(() => Boolean(props.task))
const taskSlug = computed(() => slugifyTaskName(taskName.value))
const isWorking = computed(() =>
  Boolean(
    props.progress &&
      !props.progress.error &&
      props.progress.steps.some((step) => step.status === 'pending' || step.status === 'running'),
  ),
)
const selectedRepoIds = computed(() => new Set(rows.value.map((row) => row.registeredRepoId)))
const canAddRepo = computed(() => rows.value.length < registry.value.length)
const hasChanges = computed(() => {
  if (!props.task) {
    return true
  }

  if (taskName.value.trim() !== props.task.name) {
    return true
  }

  return (
    rows.value.length !== props.task.repos.length ||
    rows.value.some((row, index) => {
      const taskRepo = props.task?.repos[index]

      return (
        !taskRepo ||
        row.registeredRepoId !== taskRepo.registeredRepoId ||
        row.baseBranch !== taskRepo.baseBranch
      )
    })
  )
})
const canSave = computed(
  () => taskSlug.value.length >= 2 && rows.value.length > 0 && hasValidRows() && hasChanges.value,
)
const progressSubtitle = computed(() => {
  if (!props.progress) {
    return ''
  }

  if (props.progress.error) {
    return 'Git stopped before Piñata saved the change.'
  }

  if (props.progress.title === 'Delete task') {
    return 'Cleaning up repository worktrees in parallel.'
  }

  if (props.progress.title === 'Update task') {
    return 'Updating repository worktrees in parallel.'
  }

  return 'Setting up repository worktrees in parallel.'
})

function progressStepStatusLabel(step: ProgressStep) {
  switch (step.status) {
    case 'done':
      return step.kind === 'cleanup' ? 'Cleaned' : 'Ready'
    case 'error':
      return 'Failed'
    case 'running':
      return step.detail ?? (step.kind === 'cleanup' ? 'Cleaning up' : 'Setting up')
    case 'pending':
      return 'Queued'
  }
}

const confirmationTitle = computed(() => {
  if (pendingConfirmation.value?.kind === 'remove-repo') {
    return `Remove ${pendingConfirmation.value.repoName}?`
  }

  if (pendingConfirmation.value?.kind === 'replace-repo') {
    return `Replace ${pendingConfirmation.value.repoName}?`
  }

  return 'Delete task?'
})
const confirmationBody = computed(() => {
  if (pendingConfirmation.value?.kind === 'remove-repo') {
    return 'This removes the repository from this task and deletes its task-owned branch and worktree when present. Registered repositories stay untouched.'
  }

  if (pendingConfirmation.value?.kind === 'replace-repo') {
    return `This removes ${pendingConfirmation.value.repoName} from this task and deletes its task-owned branch and worktree when present. ${pendingConfirmation.value.nextRepoName} will be added instead. Registered repositories stay untouched.`
  }

  return 'This deletes the task and its task-owned branches and worktrees when present. Registered repositories stay untouched.'
})
const confirmationActionLabel = computed(() =>
  pendingConfirmation.value?.kind === 'delete-task'
    ? 'Delete'
    : pendingConfirmation.value?.kind === 'replace-repo'
      ? 'Replace'
      : 'Remove',
)

function initialRows(): DialogRepoRow[] {
  if (props.task) {
    return props.task.repos.map(rowFromTaskRepo)
  }

  const firstRepo = props.appState.repoRegistry[0]

  return firstRepo ? [rowFromRepo(firstRepo)] : []
}

function rowFromRepo(repo: RegisteredRepo): DialogRepoRow {
  return {
    id: `dialog-repo-${crypto.randomUUID()}`,
    registeredRepoId: repo.id,
    baseBranch: repo.defaultBranch,
    baseBranchLocked: false,
  }
}

function rowFromTaskRepo(taskRepo: TaskRepo): DialogRepoRow {
  return {
    id: `dialog-${taskRepo.id}`,
    taskRepoId: taskRepo.id,
    registeredRepoId: taskRepo.registeredRepoId,
    baseBranch: taskRepo.baseBranch,
    baseBranchLocked: Boolean(taskRepo.worktreePath),
  }
}

function repoForRow(row: DialogRepoRow) {
  return registry.value.find((repo) => repo.id === row.registeredRepoId)
}

function branchesForRow(row: DialogRepoRow) {
  const repo = repoForRow(row)

  if (!repo) {
    return ['main']
  }

  return repo.branches.length ? repo.branches : [repo.defaultBranch]
}

function isRepoUsedByAnotherRow(repoId: string, rowId: string) {
  return rows.value.some((row) => row.id !== rowId && row.registeredRepoId === repoId)
}

function fieldValue(event: Event) {
  return (event.target as HTMLSelectElement).value
}

function hasValidRows() {
  if (!rows.value.length) {
    return false
  }

  const ids = new Set<string>()

  return rows.value.every((row) => {
    if (!registry.value.some((repo) => repo.id === row.registeredRepoId) || ids.has(row.registeredRepoId)) {
      return false
    }

    ids.add(row.registeredRepoId)
    return Boolean(row.baseBranch)
  })
}

function addRepoRow() {
  if (isWorking.value) {
    return
  }

  const nextRepo = registry.value.find((repo) => !selectedRepoIds.value.has(repo.id))

  if (nextRepo) {
    rows.value = [...rows.value, rowFromRepo(nextRepo)]
  }
}

function removeRepoRow(rowId: string) {
  rows.value = rows.value.filter((row) => row.id !== rowId)
}

function requestRemoveRepoRow(row: DialogRepoRow) {
  if (isWorking.value || rows.value.length <= 1) {
    return
  }

  if (!props.task || !row.taskRepoId) {
    removeRepoRow(row.id)
    return
  }

  pendingConfirmation.value = {
    kind: 'remove-repo',
    rowId: row.id,
    repoName: repoForRow(row)?.name ?? 'repository',
  }
}

function requestDeleteTask() {
  if (!isWorking.value && props.task) {
    pendingConfirmation.value = { kind: 'delete-task' }
  }
}

function cancelConfirmation() {
  pendingConfirmation.value = null
}

function confirmDangerAction() {
  const confirmation = pendingConfirmation.value

  if (!confirmation) {
    return
  }

  pendingConfirmation.value = null

  if (confirmation.kind === 'remove-repo') {
    removeRepoRow(confirmation.rowId)
    return
  }

  if (confirmation.kind === 'replace-repo') {
    applyRowRepoUpdate(confirmation.rowId, confirmation.repoId)
    return
  }

  if (props.task) {
    emit('delete', props.task)
  }
}

function applyRowRepoUpdate(rowId: string, repoId: string) {
  const nextRepo = registry.value.find((repo) => repo.id === repoId)

  if (!nextRepo) {
    return
  }

  rows.value = rows.value.map((row) =>
    row.id === rowId
      ? {
          ...row,
          taskRepoId: undefined,
          registeredRepoId: nextRepo.id,
          baseBranch: nextRepo.defaultBranch,
          baseBranchLocked: false,
        }
      : row,
  )
}

function updateRowRepo(row: DialogRepoRow, repoId: string) {
  if (isWorking.value) {
    return
  }

  const nextRepo = registry.value.find((repo) => repo.id === repoId)

  if (!nextRepo || row.registeredRepoId === repoId) {
    return
  }

  if (props.task && row.taskRepoId) {
    pendingConfirmation.value = {
      kind: 'replace-repo',
      rowId: row.id,
      repoId,
      repoName: repoForRow(row)?.name ?? 'repository',
      nextRepoName: nextRepo.name,
    }
    return
  }

  applyRowRepoUpdate(row.id, repoId)
}

function updateRowBase(rowId: string, baseBranch: string) {
  if (isWorking.value || rows.value.find((row) => row.id === rowId)?.baseBranchLocked) {
    return
  }

  rows.value = rows.value.map((row) => (row.id === rowId ? { ...row, baseBranch } : row))
}

function taskInput(): NewTaskInput {
  return {
    name: taskName.value.trim(),
    repos: rows.value.map((row) => ({
      registeredRepoId: row.registeredRepoId,
      baseBranch: row.baseBranch,
    })),
  }
}

function saveTask() {
  if (isWorking.value || !canSave.value) {
    return
  }

  if (props.task) {
    emit('update', props.task, taskInput())
  } else {
    emit('create', taskInput())
  }
}

function handleEscape() {
  if (isWorking.value) {
    return
  }

  if (pendingConfirmation.value) {
    cancelConfirmation()
    return
  }

  emit('close')
}

function handleScrimPointerDown(event: PointerEvent) {
  scrimPointerStartedOutside.value = event.target === event.currentTarget
}

function handleScrimPointerUp(event: PointerEvent) {
  if (isWorking.value) {
    scrimPointerStartedOutside.value = false
    return
  }

  if (scrimPointerStartedOutside.value && event.target === event.currentTarget) {
    emit('close')
  }

  scrimPointerStartedOutside.value = false
}

function startWindowDrag(event: MouseEvent) {
  if (event.buttons !== 1) {
    return
  }

  void appWindow.startDragging().catch(() => undefined)
}

function handleConfirmPointerDown(event: PointerEvent) {
  confirmPointerStartedOutside.value = event.target === event.currentTarget
}

function handleConfirmPointerUp(event: PointerEvent) {
  if (confirmPointerStartedOutside.value && event.target === event.currentTarget) {
    cancelConfirmation()
  }

  confirmPointerStartedOutside.value = false
}

onMounted(() => {
  nameInput.value?.focus()
})
</script>

<template>
  <div
    :class="styles.scrim"
    role="presentation"
    @pointerdown="handleScrimPointerDown"
    @pointerup="handleScrimPointerUp"
    @keydown.esc.stop.prevent="handleEscape"
  >
    <div :class="styles.dragRegion" data-tauri-drag-region @mousedown="startWindowDrag" />

    <section
      :class="styles.dialog"
      role="dialog"
      aria-modal="true"
      aria-labelledby="new-task-title"
    >
      <header :class="styles.header">
        <span :class="styles.headerIcon">
          <LayersIcon />
        </span>
        <div :class="styles.headerCopy">
          <h2 id="new-task-title">
            {{ progress ? progress.title : isEditing ? 'Edit task' : 'New task' }}
          </h2>
          <p>
            {{
              progress
                ? progressSubtitle
                : isEditing
                  ? 'Update the name and repositories it spans.'
                  : 'A name and the repositories it spans.'
            }}
          </p>
        </div>
        <button
          type="button"
          class="uiButton uiButtonIcon uiButtonNaked"
          aria-label="Close task dialog"
          :disabled="isWorking"
          @click="emit('close')"
        >
          <XIcon />
        </button>
      </header>

      <div v-if="progress" :class="[styles.body, styles.progressBody]">
        <ul :class="styles.progressList" aria-live="polite">
          <li
            v-for="step in progress.steps"
            :key="step.id"
            :class="styles.progressStep"
            :data-status="step.status"
          >
            <span :class="styles.progressMark" aria-hidden="true">
              <CheckIcon v-if="step.status === 'done'" />
              <XIcon v-else-if="step.status === 'error'" />
              <span v-else-if="step.status === 'running'" :class="styles.progressSpinner" />
            </span>
            <span :class="styles.progressCopy">
              <strong>{{ step.label }}</strong>
            </span>
            <span :class="styles.progressState">{{ progressStepStatusLabel(step) }}</span>
          </li>
        </ul>

        <p v-if="progress.error" :class="styles.progressError">{{ progress.error }}</p>

        <footer v-if="progress.error" :class="styles.progressActions">
          <button type="button" class="uiButton uiButtonSmall" @click="emit('dismiss-progress')">
            Back to form
          </button>
        </footer>
      </div>

      <div v-else :class="styles.body">
        <label :class="styles.field">
          <span>Task name</span>
          <input
            ref="nameInput"
            v-model="taskName"
            :class="styles.fieldInput"
            type="text"
            placeholder="API rate limiting"
            autocomplete="off"
            spellcheck="false"
            :disabled="isWorking"
          />
        </label>

        <section :class="styles.repoSection" aria-labelledby="task-repos-title">
          <div :class="styles.sectionHeader">
            <p id="task-repos-title">Repositories</p>
            <button
              type="button"
              class="uiButton uiButtonSmall"
              :disabled="isWorking || !canAddRepo"
              @click="addRepoRow"
            >
              <PlusIcon />
              Add repo
            </button>
          </div>

          <div v-if="!registry.length" :class="styles.emptyRepos">
            No registered repositories yet.
          </div>

          <div v-else :class="styles.repoRows">
            <div v-for="row in rows" :key="row.id" :class="styles.repoRow">
              <div :class="styles.selectWrap">
                <RepositoryIcon :class="styles.selectIcon" />
                <select
                  :class="[styles.fieldInput, styles.repoSelect]"
                  :value="row.registeredRepoId"
                  :disabled="isWorking"
                  @change="updateRowRepo(row, fieldValue($event))"
                >
                  <option
                    v-for="repo in registry"
                    :key="repo.id"
                    :value="repo.id"
                    :disabled="isRepoUsedByAnotherRow(repo.id, row.id)"
                  >
                    {{ repo.name }}
                  </option>
                </select>
                <ChevronDownIcon :class="styles.selectChevron" />
              </div>

              <span :class="styles.fromLabel">from</span>

              <div :class="styles.selectWrap">
                <select
                  :class="[styles.fieldInput, styles.branchSelect]"
                  :value="row.baseBranch"
                  :disabled="isWorking || row.baseBranchLocked"
                  :aria-label="row.baseBranchLocked ? 'Base branch locked after worktree creation' : 'Base branch'"
                  @change="updateRowBase(row.id, fieldValue($event))"
                >
                  <option v-for="branch in branchesForRow(row)" :key="branch" :value="branch">
                    {{ branch }}
                  </option>
                </select>
                <ChevronDownIcon :class="styles.selectChevron" />
              </div>

              <button
                type="button"
                class="uiButton uiButtonIcon uiButtonNaked"
                :disabled="isWorking || rows.length <= 1"
                aria-label="Remove repository"
                @click="requestRemoveRepoRow(row)"
              >
                <XIcon />
              </button>
            </div>
          </div>

        </section>

        <section v-if="task" :class="styles.dangerZone" aria-labelledby="task-danger-title">
          <h3 id="task-danger-title">Danger Zone</h3>
          <div :class="styles.dangerPanel">
            <div :class="styles.configRow">
              <div :class="styles.configCopy">
                <h2>Delete task</h2>
                <p>Delete this task. Local repositories stay untouched.</p>
              </div>
              <button
                type="button"
                class="uiButton uiButtonSmall uiButtonDanger"
                :disabled="isWorking"
                @click="requestDeleteTask"
              >
                <TrashIcon />
                Delete
              </button>
            </div>
          </div>
        </section>

        <footer :class="styles.footer">
          <button
            type="button"
            class="uiButton uiButtonSmall"
            :disabled="isWorking"
            @click="emit('close')"
          >
            Cancel
          </button>
          <button
            type="button"
            class="uiButton uiButtonSmall uiButtonPrimary"
            :disabled="isWorking || !canSave"
            @click="saveTask"
          >
            <GitBranchIcon />
            {{ isWorking ? 'Working' : isEditing ? 'Save changes' : 'Create task' }}
          </button>
        </footer>
      </div>
    </section>

    <div
      v-if="pendingConfirmation"
      :class="styles.confirmLayer"
      role="presentation"
      @pointerdown="handleConfirmPointerDown"
      @pointerup="handleConfirmPointerUp"
    >
      <section
        :class="styles.confirmDialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="task-confirm-title"
      >
        <header :class="styles.confirmHeader">
          <span :class="styles.confirmIcon">
            <TrashIcon />
          </span>
          <div>
            <h2 id="task-confirm-title">{{ confirmationTitle }}</h2>
            <p>{{ confirmationBody }}</p>
          </div>
        </header>
        <footer :class="styles.confirmActions">
          <button type="button" class="uiButton uiButtonSmall" @click="cancelConfirmation">
            Cancel
          </button>
          <button
            type="button"
            class="uiButton uiButtonSmall uiButtonDanger"
            @click="confirmDangerAction"
          >
            <TrashIcon />
            {{ confirmationActionLabel }}
          </button>
        </footer>
      </section>
    </div>
  </div>
</template>
