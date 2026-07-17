<script setup lang="ts">
import { open as openDialog } from '@tauri-apps/plugin-dialog'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { computed, onBeforeUnmount, onMounted, reactive, ref } from 'vue'
import ArrowLeftIcon from '../../icons/ArrowLeftIcon.vue'
import ChevronDownIcon from '../../icons/ChevronDownIcon.vue'
import CommandIcon from '../../icons/CommandIcon.vue'
import GitBranchIcon from '../../icons/GitBranchIcon.vue'
import HelpIcon from '../../icons/HelpIcon.vue'
import PlusIcon from '../../icons/PlusIcon.vue'
import RepositoryIcon from '../../icons/RepositoryIcon.vue'
import SunIcon from '../../icons/SunIcon.vue'
import TrashIcon from '../../icons/TrashIcon.vue'
import XIcon from '../../icons/XIcon.vue'
import {
  DEFAULT_WORKTREE_BASE_PATH,
  defaultRepoWorktreePath,
  inspectRepository,
  type AppState,
  type RepositoryInspection,
  type RegisteredRepo,
} from '../app-state/app-state'
import {
  type Accent,
  type AccentIntensity,
  accentIntensities,
  accents,
  type SettingsSection,
  shortcuts,
  type Theme,
  themes,
} from './settings'
import AccentSwatchPicker from '../../components/accent-swatch-picker/AccentSwatchPicker.vue'
import styles from './SettingsView.module.css'

const props = defineProps<{
  theme: Theme
  accent: Accent
  accentIntensity: AccentIntensity
  appState: AppState
}>()

const emit = defineEmits<{
  close: []
  'update-theme': [theme: Theme]
  'update-accent': [accent: Accent]
  'update-accent-intensity': [accentIntensity: AccentIntensity]
  'update-app-state': [appState: AppState]
}>()

const section = ref<SettingsSection>('appearance')
const registering = ref(false)
const registeringBusy = ref(false)
const registerPath = ref('')
const registerName = ref('')
const registerDefaultBranch = ref('')
const registerWorktreeBasePath = ref('')
const registerError = ref('')
const registerInspection = ref<RepositoryInspection | null>(null)
const selectedRepoId = ref<string | null>(null)
const defaultWorktreeBaseError = ref('')
const repoWorktreeErrors = reactive<Record<string, string>>({})
const registerFormId = 'repo-register-form'
const registerPathInputId = 'repo-register-path'
const appWindow = getCurrentWindow()
const accentIntensityDisabled = computed(() => props.accent === 'mono')

const globalWorktreeBasePath = computed(() => props.appState.repositoryDefaults.worktreeBasePath)
const selectedRepo = computed(
  () => props.appState.repoRegistry.find((repo) => repo.id === selectedRepoId.value) ?? null,
)
const registerWorktreePlaceholder = computed(() =>
  repoWorktreePlaceholder(registerName.value.trim() || registerInspection.value?.name || 'repo'),
)
const registerWorktreeError = computed(() => validateWorktreePath(registerWorktreeBasePath.value))
const canRegisterRepo = computed(
  () => Boolean(registerInspection.value) && !registeringBusy.value && !registerWorktreeError.value,
)
const repoRemovalReasons = computed<Record<string, string>>(() =>
  Object.fromEntries(
    props.appState.repoRegistry.map((repo) => [repo.id, repoRemovalReason(repo)]),
  ),
)

function selectSection(nextSection: SettingsSection) {
  section.value = nextSection
}

function repoSummary(repo: RegisteredRepo) {
  const org = repo.org ? `${repo.org} · ` : ''

  return `${org}${repo.defaultBranch}`
}

function tasksUsingRepo(repoId: string) {
  return props.appState.tasks.filter((task) =>
    task.repos.some((taskRepo) => taskRepo.registeredRepoId === repoId),
  )
}

function repoRemovalReason(repo: RegisteredRepo) {
  const tasks = tasksUsingRepo(repo.id)

  if (!tasks.length) {
    return ''
  }

  if (tasks.length === 1) {
    const active = props.appState.selection.taskId === tasks[0].id ? 'active ' : ''
    return `Used by ${active}task "${tasks[0].name}". Remove it from that task first.`
  }

  return `Used by ${tasks.length} tasks. Remove it from those tasks first.`
}

function repoWorktreePlaceholder(repoName: string) {
  return defaultRepoWorktreePath(props.appState.repositoryDefaults, repoName)
}

function fieldValue(event: Event) {
  return (event.target as HTMLInputElement | HTMLSelectElement).value
}

function validateWorktreePath(path: string) {
  const value = path.trim()

  if (!value) {
    return ''
  }

  if (/[\0\r\n]/.test(value)) {
    return 'Use a single-line path.'
  }

  if (value !== '~' && !value.startsWith('~/') && !value.startsWith('/')) {
    return 'Use an absolute path or ~/ path.'
  }

  return ''
}

function openRepoConfig(repo: RegisteredRepo) {
  registering.value = false
  selectedRepoId.value = repo.id
}

function closeRepoConfig() {
  selectedRepoId.value = null
}

function startWindowDrag(event: MouseEvent) {
  if (event.buttons !== 1) {
    return
  }

  void appWindow.startDragging().catch(() => undefined)
}

function openRegistering() {
  selectedRepoId.value = null
  registering.value = true
  registerError.value = ''
}

function cancelRegistering() {
  registering.value = false
  registerPath.value = ''
  registerName.value = ''
  registerDefaultBranch.value = ''
  registerWorktreeBasePath.value = ''
  registerError.value = ''
  registerInspection.value = null
}

async function browseRepositoryPath() {
  registerError.value = ''

  try {
    const selected = await openDialog({
      directory: true,
      multiple: false,
      title: 'Select repository',
    })

    if (selected) {
      await inspectRegisterPath(selected)
    }
  } catch (error) {
    registerError.value = error instanceof Error ? error.message : String(error)
  }
}

function clearRegisterInspection() {
  registerInspection.value = null
  registerError.value = ''
  registerName.value = ''
  registerDefaultBranch.value = ''
}

function applyRepositoryInspection(inspection: RepositoryInspection) {
  registerInspection.value = inspection
  registerPath.value = inspection.path
  registerName.value = inspection.name
  registerDefaultBranch.value = inspection.defaultBranch
  registerWorktreeBasePath.value = ''
}

async function inspectRegisterPath(path = registerPath.value): Promise<RepositoryInspection | null> {
  const nextPath = path.trim()

  registerInspection.value = null

  if (!nextPath || registeringBusy.value) {
    return null
  }

  registerPath.value = nextPath
  registeringBusy.value = true
  registerError.value = ''

  try {
    const inspection = await inspectRepository(nextPath)
    applyRepositoryInspection(inspection)
    return inspection
  } catch (error) {
    registerError.value = error instanceof Error ? error.message : String(error)
    return null
  } finally {
    registeringBusy.value = false
  }
}

function updateRegisteredRepo(repoId: string, patch: Partial<RegisteredRepo>) {
  emit('update-app-state', {
    ...props.appState,
    repoRegistry: props.appState.repoRegistry.map((repo) =>
      repo.id === repoId ? { ...repo, ...patch } : repo,
    ),
  })
}

function hasDuplicateRepo(name: string, path: string) {
  const normalizedName = name.toLowerCase()

  return props.appState.repoRegistry.some(
    (repo) => repo.name.toLowerCase() === normalizedName || repo.source.path === path,
  )
}

function updateRepositoryDefaults(event: Event) {
  const worktreeBasePath = fieldValue(event).trim() || DEFAULT_WORKTREE_BASE_PATH
  const error = validateWorktreePath(worktreeBasePath)

  if (error) {
    defaultWorktreeBaseError.value = error
    return
  }

  emit('update-app-state', {
    ...props.appState,
    repositoryDefaults: {
      ...props.appState.repositoryDefaults,
      worktreeBasePath,
    },
  })
  defaultWorktreeBaseError.value = ''
}

async function registerRepository() {
  if (!registerPath.value.trim() || registeringBusy.value) {
    return
  }

  registerError.value = ''

  const inspection = registerInspection.value ?? (await inspectRegisterPath())

  if (!inspection) {
    return
  }

  registeringBusy.value = true

  try {
    const name = registerName.value.trim() || inspection.name
    const defaultBranch = registerDefaultBranch.value.trim() || inspection.defaultBranch
    const worktreeBasePath = registerWorktreeBasePath.value.trim()
    const worktreeError = validateWorktreePath(worktreeBasePath)

    if (hasDuplicateRepo(name, inspection.path)) {
      registerError.value = 'Repository already registered.'
      return
    }

    if (worktreeError) {
      registerError.value = worktreeError
      return
    }

    const repo: RegisteredRepo = {
      id: `repo-${crypto.randomUUID()}`,
      name,
      org: inspection.org,
      source: { kind: 'local', path: inspection.path },
      branches: inspection.branches.includes(defaultBranch)
        ? inspection.branches
        : [defaultBranch, ...inspection.branches],
      defaultBranch,
      worktreeBasePath: worktreeBasePath || undefined,
    }

    emit('update-app-state', {
      ...props.appState,
      repoRegistry: [...props.appState.repoRegistry, repo],
    })
    cancelRegistering()
    selectedRepoId.value = repo.id
  } catch (error) {
    registerError.value = error instanceof Error ? error.message : String(error)
  } finally {
    registeringBusy.value = false
  }
}

function updateRepoDefaultBranch(repo: RegisteredRepo, event: Event) {
  updateRegisteredRepo(repo.id, { defaultBranch: fieldValue(event) })
}

function validateRepoWorktreePath(repo: RegisteredRepo, event: Event) {
  repoWorktreeErrors[repo.id] = validateWorktreePath(fieldValue(event))
}

function resetRepoWorktreeBasePath(repo: RegisteredRepo) {
  repoWorktreeErrors[repo.id] = ''
  updateRegisteredRepo(repo.id, { worktreeBasePath: undefined })
}

function updateRepoWorktreeBasePath(repo: RegisteredRepo, event: Event) {
  const worktreeBasePath = fieldValue(event).trim()
  const worktreeError = validateWorktreePath(worktreeBasePath)

  repoWorktreeErrors[repo.id] = worktreeError

  if (worktreeError) {
    return
  }

  updateRegisteredRepo(repo.id, { worktreeBasePath: worktreeBasePath || undefined })
}

function removeRegisteredRepo(repo: RegisteredRepo) {
  if (repoRemovalReasons.value[repo.id]) {
    return
  }

  emit('update-app-state', {
    ...props.appState,
    repoRegistry: props.appState.repoRegistry.filter((candidate) => candidate.id !== repo.id),
  })
  delete repoWorktreeErrors[repo.id]
  closeRepoConfig()
}

function closeActiveModal() {
  if (registering.value) {
    cancelRegistering()
    return true
  }

  if (selectedRepoId.value) {
    closeRepoConfig()
    return true
  }

  return false
}

function handleModalKeydown(event: KeyboardEvent) {
  if (event.key !== 'Escape' || !closeActiveModal()) {
    return
  }

  event.preventDefault()
  event.stopPropagation()
}

onMounted(() => {
  window.addEventListener('keydown', handleModalKeydown)
})

onBeforeUnmount(() => {
  window.removeEventListener('keydown', handleModalKeydown)
})
</script>

<template>
  <section :class="styles.overlay" aria-label="Settings">
    <div :class="styles.dragRegion" data-tauri-drag-region @mousedown="startWindowDrag" />

    <aside :class="styles.rail">
      <button type="button" class="uiButton" :class="styles.back" @click="emit('close')">
        <ArrowLeftIcon :class="styles.backIcon" />
        Back to app
      </button>

      <nav :class="styles.nav" aria-label="Settings sections">
        <section :class="styles.navGroup">
          <p :class="styles.navLabel">Personal</p>
          <button
            type="button"
            :class="[styles.navItem, section === 'appearance' && styles.navItemActive]"
            :aria-current="section === 'appearance' ? 'page' : undefined"
            @click="selectSection('appearance')"
          >
            <SunIcon :class="styles.navIcon" />
            <span>Appearance</span>
          </button>
          <button
            type="button"
            :class="[styles.navItem, section === 'shortcuts' && styles.navItemActive]"
            :aria-current="section === 'shortcuts' ? 'page' : undefined"
            @click="selectSection('shortcuts')"
          >
            <CommandIcon :class="styles.navIcon" />
            <span>Shortcuts</span>
          </button>
        </section>

        <section :class="styles.navGroup">
          <p :class="styles.navLabel">Coding</p>
          <button
            type="button"
            :class="[styles.navItem, section === 'git' && styles.navItemActive]"
            :aria-current="section === 'git' ? 'page' : undefined"
            @click="selectSection('git')"
          >
            <GitBranchIcon :class="styles.navIcon" />
            <span>Git & PR</span>
          </button>
        </section>
      </nav>
    </aside>

    <main :class="styles.content">
      <div :class="styles.inner">
        <template v-if="section === 'appearance'">
          <h1 :class="styles.title">Appearance</h1>

          <section :class="styles.settingsGroup" aria-labelledby="theme-title">
            <p id="theme-title" :class="styles.groupLabel">Theme</p>
            <div :class="styles.card">
              <div :class="[styles.row, styles.rowFirst]">
                <div :class="styles.rowCopy">
                  <h2>Color theme</h2>
                  <p>Piñata dark, or a matched light variant</p>
                </div>
                <div :class="styles.segment" role="group" aria-label="Color theme">
                  <button
                    v-for="item in themes"
                    :key="item.id"
                    type="button"
                    :class="[styles.segmentButton, item.id === theme && styles.segmentButtonActive]"
                    :aria-pressed="item.id === theme"
                    @click="emit('update-theme', item.id)"
                  >
                    {{ item.name }}
                  </button>
                </div>
              </div>

              <div :class="styles.row">
                <div :class="styles.rowCopy">
                  <h2>Accent color</h2>
                  <p>Highlights, active tabs and primary actions</p>
                </div>
                <AccentSwatchPicker
                  :accent="accent"
                  :items="accents"
                  @select="(item) => emit('update-accent', item)"
                />
              </div>

              <div :class="styles.row">
                <div :class="styles.rowCopy">
                  <h2>Accent intensity</h2>
                  <p>
                    {{
                      accentIntensityDisabled
                        ? 'Mono keeps a fixed neutral accent'
                        : 'How loud accent surfaces should feel across the app'
                    }}
                  </p>
                </div>
                <div
                  :class="[styles.segment, accentIntensityDisabled && styles.segmentDisabled]"
                  role="group"
                  aria-label="Accent intensity"
                  :aria-disabled="accentIntensityDisabled"
                >
                  <button
                    v-for="item in accentIntensities"
                    :key="item.id"
                    type="button"
                    :class="[
                      styles.segmentButton,
                      item.id === accentIntensity && styles.segmentButtonActive,
                    ]"
                    :disabled="accentIntensityDisabled"
                    :aria-pressed="item.id === accentIntensity"
                    @click="emit('update-accent-intensity', item.id)"
                  >
                    {{ item.name }}
                  </button>
                </div>
              </div>
            </div>
          </section>
        </template>

        <template v-else-if="section === 'git'">
          <h1 :class="styles.title">Git & PR</h1>

          <section :class="styles.settingsGroup" aria-labelledby="worktrees-title">
            <p id="worktrees-title" :class="styles.groupLabel">Worktrees</p>
            <div :class="styles.card">
              <div :class="[styles.row, styles.rowFirst]">
                <div :class="styles.rowCopy">
                  <h2 :class="styles.configTitle">
                    Default worktree base
                    <button
                      type="button"
                      :class="styles.helpButton"
                      aria-label="Worktree base changes only affect future task worktrees."
                    >
                      <HelpIcon />
                      <span :class="styles.helpTooltip" role="tooltip">
                        Changes only affect future task worktrees. Existing worktrees keep their
                        current path.
                      </span>
                    </button>
                  </h2>
                  <p>Used by every repository unless that repository defines an override.</p>
                </div>
                <div :class="styles.rowControl">
                  <div :class="styles.pathPicker">
                    <input
                      :class="[
                        styles.fieldInput,
                        styles.monoInput,
                        styles.defaultInput,
                        defaultWorktreeBaseError && styles.fieldInputInvalid,
                      ]"
                      type="text"
                      :value="globalWorktreeBasePath"
                      spellcheck="false"
                      :aria-invalid="Boolean(defaultWorktreeBaseError)"
                      @change="updateRepositoryDefaults"
                    />
                    <span
                      v-if="defaultWorktreeBaseError"
                      :class="styles.fieldErrorPopover"
                      role="alert"
                    >
                      {{ defaultWorktreeBaseError }}
                    </span>
                  </div>
                </div>
              </div>
            </div>
          </section>

          <section :class="styles.settingsGroup" aria-labelledby="repositories-title">
            <div :class="styles.groupHeader">
              <p id="repositories-title" :class="styles.groupLabel">Repositories</p>
              <button
                type="button"
                class="uiButton uiButtonSmall"
                :class="styles.groupAction"
                :aria-controls="registerFormId"
                :aria-expanded="registering"
                @click="openRegistering"
              >
                <PlusIcon />
                Register repo
              </button>
            </div>

            <div :class="[styles.card, styles.repoList]">
              <div v-if="!appState.repoRegistry.length" :class="styles.emptyRegistry">
                No repositories yet. Register one to start creating tasks.
              </div>

              <template v-else>
                <div
                  v-for="(repo, index) in appState.repoRegistry"
                  :key="repo.id"
                  :class="[styles.repoConfig, index === 0 && styles.repoConfigFirst]"
                >
                  <button
                    type="button"
                    :class="styles.repoHeader"
                    aria-haspopup="dialog"
                    @click="openRepoConfig(repo)"
                  >
                    <RepositoryIcon :class="styles.repoIcon" />
                    <span :class="styles.repoName">{{ repo.name }}</span>
                    <span :class="styles.repoMeta">{{ repoSummary(repo) }}</span>
                    <ChevronDownIcon :class="styles.repoArrow" />
                  </button>
                </div>
              </template>
            </div>
          </section>

          <div
            v-if="registering"
            :class="styles.modalLayer"
            role="presentation"
            @click.self="cancelRegistering"
          >
            <section
              :class="styles.modal"
              role="dialog"
              aria-modal="true"
              aria-labelledby="repo-register-title"
            >
              <header :class="styles.modalHeader">
                <div :class="styles.modalTitle">
                  <RepositoryIcon :class="styles.modalIcon" />
                  <div>
                    <h2 id="repo-register-title">Register a repository</h2>
                    <p>Point Piñata at a local git checkout.</p>
                  </div>
                </div>
                <button
                  type="button"
                  class="uiButton uiButtonIcon uiButtonNaked"
                  aria-label="Close repository registration"
                  @click="cancelRegistering"
                >
                  <XIcon />
                </button>
              </header>

              <form
                :id="registerFormId"
                :class="styles.registerForm"
                @submit.prevent="registerRepository"
              >
                <div :class="styles.field">
                  <label :for="registerPathInputId">Local path</label>
                  <div :class="styles.pathPicker">
                    <input
                      :id="registerPathInputId"
                      v-model="registerPath"
                      :class="[
                        styles.fieldInput,
                        styles.monoInput,
                        registerError && styles.fieldInputInvalid,
                      ]"
                      type="text"
                      placeholder="/Users/you/dev/repo"
                      autocomplete="off"
                      spellcheck="false"
                      :aria-invalid="Boolean(registerError)"
                      required
                      @input="clearRegisterInspection"
                      @change="inspectRegisterPath()"
                    />
                    <button
                      type="button"
                      class="uiButton uiButtonSmall"
                      @click="browseRepositoryPath"
                    >
                      Browse
                    </button>
                    <span
                      v-if="registerError"
                      :class="styles.fieldErrorPopover"
                      role="alert"
                    >
                      {{ registerError }}
                    </span>
                  </div>
                </div>

                <div :class="styles.formGrid">
                  <label :class="styles.field">
                    <span>Name</span>
                    <input
                      v-model="registerName"
                      :class="styles.fieldInput"
                      type="text"
                      placeholder="Inferred from git root"
                      autocomplete="off"
                    />
                  </label>

                  <label :class="styles.field">
                    <span>Default branch</span>
                    <input
                      v-model="registerDefaultBranch"
                      :class="[styles.fieldInput, styles.monoInput]"
                      type="text"
                      placeholder="Auto"
                      autocomplete="off"
                      spellcheck="false"
                    />
                  </label>
                </div>

                <label :class="styles.field">
                  <span>Worktree override</span>
                  <div :class="styles.pathPicker">
                    <input
                      v-model="registerWorktreeBasePath"
                      :class="[
                        styles.fieldInput,
                        styles.monoInput,
                        registerWorktreeError && styles.fieldInputInvalid,
                      ]"
                      type="text"
                      :placeholder="registerWorktreePlaceholder"
                      autocomplete="off"
                      spellcheck="false"
                      :aria-invalid="Boolean(registerWorktreeError)"
                    />
                    <button
                      type="button"
                      class="uiButton uiButtonSmall"
                      :disabled="!registerWorktreeBasePath"
                      @click="registerWorktreeBasePath = ''"
                    >
                      Reset
                    </button>
                    <span
                      v-if="registerWorktreeError"
                      :class="styles.fieldErrorPopover"
                      role="alert"
                    >
                      {{ registerWorktreeError }}
                    </span>
                  </div>
                </label>

                <div :class="styles.formActions">
                  <button type="button" class="uiButton uiButtonSmall" @click="cancelRegistering">
                    Cancel
                  </button>
                  <button
                    type="submit"
                    class="uiButton uiButtonSmall uiButtonPrimary"
                    :disabled="!canRegisterRepo"
                  >
                    <PlusIcon />
                    {{ registeringBusy ? 'Inspecting' : 'Register' }}
                  </button>
                </div>
              </form>
            </section>
          </div>

          <div
            v-if="selectedRepo"
            :class="styles.modalLayer"
            role="presentation"
            @click.self="closeRepoConfig"
          >
            <section
              :class="styles.modal"
              role="dialog"
              aria-modal="true"
              aria-labelledby="repo-settings-title"
            >
              <header :class="styles.modalHeader">
                <div :class="styles.modalTitle">
                  <RepositoryIcon :class="styles.modalIcon" />
                  <div>
                    <h2 id="repo-settings-title">{{ selectedRepo.name }}</h2>
                  </div>
                </div>
                <button
                  type="button"
                  class="uiButton uiButtonIcon uiButtonNaked"
                  aria-label="Close repository settings"
                  @click="closeRepoConfig"
                >
                  <XIcon />
                </button>
              </header>

              <div :class="styles.modalBody">
                <div :class="styles.configRow">
                  <div :class="styles.configCopy">
                    <h2>Source</h2>
                    <p>Local git checkout</p>
                  </div>
                  <span :class="styles.configValue">{{ selectedRepo.source.path }}</span>
                </div>

                <div v-if="selectedRepo.org" :class="styles.configRow">
                  <div :class="styles.configCopy">
                    <h2>Organization</h2>
                    <p>Inferred from git origin</p>
                  </div>
                  <span :class="styles.configValue">{{ selectedRepo.org }}</span>
                </div>

                <div :class="styles.configRow">
                  <div :class="styles.configCopy">
                    <h2>Default branch</h2>
                    <p>Base branch for new tasks</p>
                  </div>
                  <select
                    :class="styles.fieldInput"
                    :value="selectedRepo.defaultBranch"
                    @change="updateRepoDefaultBranch(selectedRepo, $event)"
                  >
                    <option v-for="branch in selectedRepo.branches" :key="branch" :value="branch">
                      {{ branch }}
                    </option>
                  </select>
                </div>

                <div :class="styles.configRow">
                  <div :class="styles.configCopy">
                    <h2 :class="styles.configTitle">
                      Worktree override
                      <span :class="styles.optionalBadge">Optional</span>
                      <button
                        type="button"
                        :class="styles.helpButton"
                        aria-label="Worktree path changes only affect future task worktrees."
                      >
                        <HelpIcon />
                        <span :class="styles.helpTooltip" role="tooltip">
                          Changes only affect future task worktrees. Existing worktrees keep their
                          current path.
                        </span>
                      </button>
                    </h2>
                    <p>Empty uses the global base plus repo name.</p>
                  </div>
                  <div :class="styles.configControl">
                    <div :class="[styles.pathPicker, styles.pathPickerInline]">
                      <input
                        :class="[
                          styles.fieldInput,
                          styles.monoInput,
                          styles.fieldInputWithAction,
                          repoWorktreeErrors[selectedRepo.id] && styles.fieldInputInvalid,
                        ]"
                        type="text"
                        :value="selectedRepo.worktreeBasePath ?? ''"
                        :placeholder="repoWorktreePlaceholder(selectedRepo.name)"
                        spellcheck="false"
                        :aria-invalid="Boolean(repoWorktreeErrors[selectedRepo.id])"
                        @input="validateRepoWorktreePath(selectedRepo, $event)"
                        @change="updateRepoWorktreeBasePath(selectedRepo, $event)"
                      />
                      <button
                        type="button"
                        class="uiButton uiButtonIcon uiButtonNaked"
                        :class="styles.inputIconButton"
                        :disabled="!selectedRepo.worktreeBasePath"
                        aria-label="Reset worktree override"
                        @click="resetRepoWorktreeBasePath(selectedRepo)"
                      >
                        <XIcon />
                      </button>
                      <span
                        v-if="repoWorktreeErrors[selectedRepo.id]"
                        :class="styles.fieldErrorPopover"
                        role="alert"
                      >
                        {{ repoWorktreeErrors[selectedRepo.id] }}
                      </span>
                    </div>
                  </div>
                </div>

                <section :class="styles.dangerZone" aria-labelledby="repo-danger-title">
                  <h3 id="repo-danger-title">Danger Zone</h3>
                  <div :class="styles.dangerPanel">
                    <div :class="styles.configRow">
                      <div :class="styles.configCopy">
                        <h2>Remove repository</h2>
                        <p>Remove this repository from Piñata. Local files stay untouched.</p>
                      </div>
                      <span
                        :class="styles.actionTooltipWrap"
                        :tabindex="repoRemovalReasons[selectedRepo.id] ? 0 : undefined"
                      >
                        <button
                          type="button"
                          class="uiButton uiButtonSmall uiButtonDanger"
                          :disabled="Boolean(repoRemovalReasons[selectedRepo.id])"
                          @click="removeRegisteredRepo(selectedRepo)"
                        >
                          <TrashIcon />
                          Remove
                        </button>
                        <span
                          v-if="repoRemovalReasons[selectedRepo.id]"
                          :class="styles.actionTooltip"
                          role="tooltip"
                        >
                          {{ repoRemovalReasons[selectedRepo.id] }}
                        </span>
                      </span>
                    </div>
                  </div>
                </section>
              </div>
            </section>
          </div>
        </template>

        <template v-else-if="section === 'shortcuts'">
          <h1 :class="styles.title">Shortcuts</h1>

          <section :class="styles.settingsGroup" aria-labelledby="shortcuts-title">
            <p id="shortcuts-title" :class="styles.groupLabel">Keyboard</p>
            <div :class="styles.card" aria-label="Keyboard shortcuts">
              <div
                v-for="(shortcut, index) in shortcuts"
                :key="shortcut.keys"
                :class="[styles.row, styles.shortcutRow, index === 0 && styles.rowFirst]"
              >
                <div :class="styles.rowCopy">
                  <h2>{{ shortcut.label }}</h2>
                </div>
                <kbd :class="styles.key">{{ shortcut.keys }}</kbd>
              </div>
            </div>
          </section>
        </template>
      </div>
    </main>
  </section>
</template>
