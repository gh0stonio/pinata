<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import ChevronDownIcon from '../../../icons/ChevronDownIcon.vue'
import GitBranchIcon from '../../../icons/GitBranchIcon.vue'
import LayersIcon from '../../../icons/LayersIcon.vue'
import PlusIcon from '../../../icons/PlusIcon.vue'
import RepositoryIcon from '../../../icons/RepositoryIcon.vue'
import TrashIcon from '../../../icons/TrashIcon.vue'
import XIcon from '../../../icons/XIcon.vue'
import {
  taskBranchForName,
  slugifyTaskName,
  type AppState,
  type NewTaskInput,
  type RegisteredRepo,
  type Task,
  type TaskRepo,
} from '../../app-state/app-state'
import styles from './TaskDialog.module.css'

type DialogRepoRow = {
  id: string
  registeredRepoId: string
  baseBranch: string
}

const props = defineProps<{
  appState: AppState
  task?: Task
}>()

const emit = defineEmits<{
  close: []
  create: [task: NewTaskInput]
  delete: [task: Task]
  update: [task: Task, input: NewTaskInput]
}>()

const nameInput = ref<HTMLInputElement | null>(null)
const taskName = ref(props.task?.name ?? '')
const rows = ref<DialogRepoRow[]>(initialRows())

const registry = computed(() => props.appState.repoRegistry)
const isEditing = computed(() => Boolean(props.task))
const taskSlug = computed(() => slugifyTaskName(taskName.value))
const branchPreview = computed(() => taskBranchForName(taskName.value))
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
  }
}

function rowFromTaskRepo(taskRepo: TaskRepo): DialogRepoRow {
  return {
    id: `dialog-${taskRepo.id}`,
    registeredRepoId: taskRepo.registeredRepoId,
    baseBranch: taskRepo.baseBranch,
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
  const nextRepo = registry.value.find((repo) => !selectedRepoIds.value.has(repo.id))

  if (nextRepo) {
    rows.value = [...rows.value, rowFromRepo(nextRepo)]
  }
}

function removeRepoRow(rowId: string) {
  rows.value = rows.value.filter((row) => row.id !== rowId)
}

function updateRowRepo(rowId: string, repoId: string) {
  const nextRepo = registry.value.find((repo) => repo.id === repoId)

  if (!nextRepo) {
    return
  }

  rows.value = rows.value.map((row) =>
    row.id === rowId
      ? {
          ...row,
          registeredRepoId: nextRepo.id,
          baseBranch: nextRepo.defaultBranch,
        }
      : row,
  )
}

function updateRowBase(rowId: string, baseBranch: string) {
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
  if (!canSave.value) {
    return
  }

  if (props.task) {
    emit('update', props.task, taskInput())
  } else {
    emit('create', taskInput())
  }
}

onMounted(() => {
  nameInput.value?.focus()
})
</script>

<template>
  <div
    :class="styles.scrim"
    role="presentation"
    @click.self="emit('close')"
    @keydown.esc.stop.prevent="emit('close')"
  >
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
          <h2 id="new-task-title">{{ isEditing ? 'Edit task' : 'New task' }}</h2>
          <p>{{ isEditing ? 'Update the name and repositories it spans.' : 'A name and the repositories it spans.' }}</p>
        </div>
        <button type="button" :class="styles.iconButton" aria-label="Close task dialog" @click="emit('close')">
          <XIcon />
        </button>
      </header>

      <div :class="styles.body">
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
          />
        </label>

        <div :class="styles.branchPreview" aria-live="polite">
          <GitBranchIcon />
          <span>branch</span>
          <strong>{{ branchPreview }}</strong>
        </div>

        <section :class="styles.repoSection" aria-labelledby="task-repos-title">
          <div :class="styles.sectionHeader">
            <p id="task-repos-title">Repositories</p>
            <button
              type="button"
              :class="styles.secondaryButton"
              :disabled="!canAddRepo"
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
                  @change="updateRowRepo(row.id, fieldValue($event))"
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
                :class="styles.iconButton"
                :disabled="rows.length <= 1"
                aria-label="Remove repository"
                @click="removeRepoRow(row.id)"
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
              <button type="button" :class="styles.dangerButton" @click="emit('delete', task)">
                <TrashIcon />
                Delete
              </button>
            </div>
          </div>
        </section>

        <footer :class="styles.footer">
          <button type="button" :class="styles.ghostButton" @click="emit('close')">Cancel</button>
          <button type="button" :class="styles.primaryButton" :disabled="!canSave" @click="saveTask">
            <GitBranchIcon />
            {{ isEditing ? 'Save changes' : 'Create task' }}
          </button>
        </footer>
      </div>
    </section>
  </div>
</template>
