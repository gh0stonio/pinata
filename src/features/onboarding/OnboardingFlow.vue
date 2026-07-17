<script setup lang="ts">
import { open as openDialog } from '@tauri-apps/plugin-dialog'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { computed, ref } from 'vue'
import ArrowLeftIcon from '../../icons/ArrowLeftIcon.vue'
import ArrowRightIcon from '../../icons/ArrowRightIcon.vue'
import CheckIcon from '../../icons/CheckIcon.vue'
import FolderIcon from '../../icons/FolderIcon.vue'
import LayersIcon from '../../icons/LayersIcon.vue'
import MoonIcon from '../../icons/MoonIcon.vue'
import RepositoryIcon from '../../icons/RepositoryIcon.vue'
import SunIcon from '../../icons/SunIcon.vue'
import XIcon from '../../icons/XIcon.vue'
import logoUrl from '../../assets/brand/pinata-logo.png'
import {
  inspectRepository,
  type AppState,
  type RegisteredRepo,
  type RepositoryInspection,
} from '../app-state/app-state'
import {
  type Accent,
  type AccentIntensity,
  accentIntensities,
  type AppSettings,
  themes,
} from '../settings/settings'
import AccentSwatchPicker from '../../components/accent-swatch-picker/AccentSwatchPicker.vue'
import {
  onboardingAccentOptions,
  onboardingIntensityLabels,
  onboardingStripeColors,
  onboardingThemeLabels,
} from './onboarding'
import styles from './OnboardingFlow.module.css'

type FinishPayload = {
  openNewTask: boolean
  repositories: RegisteredRepo[]
}

const props = defineProps<{
  settings: AppSettings
  appState: AppState
}>()

const emit = defineEmits<{
  finish: [payload: FinishPayload]
  'update-settings': [settings: Partial<AppSettings>]
}>()

const step = ref(0)
const repositories = ref<RegisteredRepo[]>([])
const registerPath = ref('')
const registerError = ref('')
const registerBusy = ref(false)
const appWindow = getCurrentWindow()

const selectedAccent = computed(
  () =>
    onboardingAccentOptions.find((accent) => accent.id === props.settings.accent) ??
    onboardingAccentOptions[0],
)
const accentPreviewStyle = computed<Record<string, string>>(() => {
  const style: Record<string, string> = {}

  if (selectedAccent.value.id === 'mono') {
    return style
  }

  const intensityMix: Record<AccentIntensity, { dark: string; light: string }> = {
    transparent: { dark: '24%', light: '18%' },
    balanced: { dark: '50%', light: '38%' },
    vibrant: { dark: '72%', light: '56%' },
  }

  style['--preview-accent'] = selectedAccent.value.color
  style['--preview-accent-dark-mix'] = intensityMix[props.settings.accentIntensity].dark
  style['--preview-accent-light-mix'] = intensityMix[props.settings.accentIntensity].light

  return style
})
const accentIntensityDisabled = computed(() => props.settings.accent === 'mono')

function isDuplicateRepository(inspection: RepositoryInspection) {
  const normalizedName = inspection.name.trim().toLowerCase()
  const normalizedPath = inspection.path.trim()

  return [...props.appState.repoRegistry, ...repositories.value].some(
    (repo) => repo.name.toLowerCase() === normalizedName || repo.source.path === normalizedPath,
  )
}

function isDuplicatePath(path: string) {
  const normalizedPath = path.trim()

  if (!normalizedPath) {
    return false
  }

  return [...props.appState.repoRegistry, ...repositories.value].some(
    (repo) => repo.source.path === normalizedPath,
  )
}

function chooseTheme(theme: AppSettings['theme']) {
  emit('update-settings', { theme })
}

function chooseAccent(accent: Accent) {
  emit('update-settings', { accent })
}

function chooseAccentIntensity(accentIntensity: AccentIntensity) {
  if (accentIntensityDisabled.value) {
    return
  }

  emit('update-settings', { accentIntensity })
}

function goNext() {
  step.value = Math.min(3, step.value + 1)
}

function goBack() {
  step.value = Math.max(0, step.value - 1)
}

function updateRegisterPath(event: Event) {
  registerPath.value = (event.target as HTMLInputElement).value
  registerError.value = ''
}

async function inspectPath(path = registerPath.value) {
  const nextPath = path.trim()

  if (!nextPath || registerBusy.value) {
    return null
  }

  if (isDuplicatePath(nextPath)) {
    registerPath.value = nextPath
    registerError.value = 'Repository already added.'
    return null
  }

  registerBusy.value = true
  registerError.value = ''
  registerPath.value = nextPath

  try {
    const inspection = await inspectRepository(nextPath)
    return inspection
  } catch (error) {
    registerError.value = error instanceof Error ? error.message : String(error)
    return null
  } finally {
    registerBusy.value = false
  }
}

async function browseRepositoryPath() {
  if (registerBusy.value) {
    return
  }

  registerError.value = ''

  try {
    const selected = await openDialog({
      directory: true,
      multiple: false,
      title: 'Select repository',
    })

    if (typeof selected === 'string') {
      await addRepositoryFromPath(selected)
    }
  } catch (error) {
    registerError.value = error instanceof Error ? error.message : String(error)
  }
}

function resetRegisterForm() {
  registerPath.value = ''
  registerError.value = ''
}

async function addRepositoryFromPath(path = registerPath.value) {
  if (registerBusy.value) {
    return
  }

  const inspection = await inspectPath(path)

  if (!inspection) {
    return
  }

  if (isDuplicateRepository(inspection)) {
    registerError.value = 'Repository already added.'
    return
  }

  repositories.value = [
    ...repositories.value,
    {
      id: `repo-${crypto.randomUUID()}`,
      name: inspection.name,
      org: inspection.org,
      source: { kind: 'local', path: inspection.path },
      branches: inspection.branches.includes(inspection.defaultBranch)
        ? inspection.branches
        : [inspection.defaultBranch, ...inspection.branches],
      defaultBranch: inspection.defaultBranch,
    },
  ]
  resetRegisterForm()
}

function removeRepository(repoId: string) {
  repositories.value = repositories.value.filter((repo) => repo.id !== repoId)
}

function finish(openNewTask: boolean) {
  emit('finish', {
    openNewTask,
    repositories: repositories.value,
  })
}

function startWindowDrag(event: MouseEvent) {
  if (event.buttons !== 1) {
    return
  }

  void appWindow.startDragging().catch(() => undefined)
}
</script>

<template>
  <section :class="styles.overlay" aria-label="Piñata onboarding">
    <div :class="styles.dragRegion" data-tauri-drag-region @mousedown="startWindowDrag" />

    <div :class="styles.panel" role="dialog" aria-modal="true" aria-label="Piñata onboarding">
      <div :class="styles.stripe" aria-hidden="true">
        <span
          v-for="color in onboardingStripeColors"
          :key="color"
          :style="{ background: color }"
        />
      </div>

      <div :class="styles.body">
        <div :key="step" :class="styles.step">
          <template v-if="step === 0">
            <div :class="styles.welcome">
              <p :class="styles.eyebrow">Welcome to</p>
              <h1 id="onboarding-title" :class="styles.welcomeTitle">Piñata</h1>
              <img :class="styles.logo" :src="logoUrl" alt="" />
              <p :class="styles.welcomeCopy">
                A terminal-first workbench for running coding agents across all your repos at once.
                <br />
                Set up the essentials in under a minute.
              </p>

              <div :class="styles.features">
                <div :class="styles.feature">
                  <span :class="styles.featureIcon" :style="{ color: onboardingStripeColors[5] }">
                    <LayersIcon />
                  </span>
                  <span>
                    <strong>One task, many repos</strong>
                    <small>Group every repository a change touches into one focused task.</small>
                  </span>
                </div>
                <div :class="styles.feature">
                  <span :class="styles.featureIcon" :style="{ color: onboardingStripeColors[3] }">
                    <RepositoryIcon />
                  </span>
                  <span>
                    <strong>Agents in every pane</strong>
                    <small>Run Pi, Claude Code or Codex side by side in split terminals.</small>
                  </span>
                </div>
                <div :class="styles.feature">
                  <span :class="styles.featureIcon" :style="{ color: onboardingStripeColors[1] }">
                    <CheckIcon />
                  </span>
                  <span>
                    <strong>Review & ship</strong>
                    <small>Keep diffs, checks and PRs close to the terminal work.</small>
                  </span>
                </div>
              </div>
            </div>
          </template>

          <template v-else-if="step === 1">
            <header :class="styles.stepHeader">
              <p :class="styles.eyebrow">Appearance</p>
              <h2>Pick your look</h2>
              <p>Choose how Piñata starts. You can change this anytime from Settings.</p>
            </header>

            <div :class="styles.themeGrid">
              <button
                v-for="theme in themes"
                :key="theme.id"
                type="button"
                :class="[styles.themeCard, theme.id === settings.theme && styles.themeCardActive]"
                @click="chooseTheme(theme.id)"
              >
                <span
                  :class="styles.themeMock"
                  :data-preview-theme="theme.id"
                  :style="accentPreviewStyle"
                  aria-hidden="true"
                >
                  <span :class="styles.mockBar">
                    <span />
                    <span />
                    <span />
                  </span>
                  <span :class="styles.mockContent">
                    <span :class="styles.mockMain">
                      <span />
                      <span />
                      <span />
                      <span />
                    </span>
                  </span>
                </span>
                <span :class="styles.themeCardFooter">
                  <span :class="styles.themeModeIcon">
                    <SunIcon v-if="theme.id === 'pinata-light'" />
                    <MoonIcon v-else />
                  </span>
                  <span>
                    <strong>{{ theme.name }}</strong>
                  </span>
                  <span :class="[styles.check, theme.id === settings.theme && styles.checkActive]">
                    <CheckIcon v-if="theme.id === settings.theme" />
                  </span>
                </span>
              </button>
            </div>

            <div :class="styles.accentBlock">
              <div :class="styles.accentHeader">
                <p :class="styles.eyebrow">Accent color</p>
                <span>{{ selectedAccent.name }}</span>
              </div>
              <AccentSwatchPicker
                :accent="settings.accent"
                :items="onboardingAccentOptions"
                @select="chooseAccent"
              />
            </div>

            <div :class="styles.intensityBlock">
              <div>
                <p :class="styles.eyebrow">Accent intensity</p>
                <span>
                  {{
                    accentIntensityDisabled
                      ? 'Mono keeps a fixed neutral accent'
                      : 'Tune how loud accent surfaces feel'
                  }}
                </span>
              </div>
              <div
                :class="[styles.segment, accentIntensityDisabled && styles.segmentDisabled]"
                role="group"
                aria-label="Accent intensity"
                :aria-disabled="accentIntensityDisabled"
              >
                <button
                  v-for="intensity in accentIntensities"
                  :key="intensity.id"
                  type="button"
                  :class="[
                    styles.segmentButton,
                    intensity.id === settings.accentIntensity && styles.segmentButtonActive,
                  ]"
                  :disabled="accentIntensityDisabled"
                  :aria-pressed="intensity.id === settings.accentIntensity"
                  @click="chooseAccentIntensity(intensity.id)"
                >
                  {{ intensity.name }}
                </button>
              </div>
            </div>
          </template>

          <template v-else-if="step === 2">
            <header :class="styles.stepHeader">
              <p :class="styles.eyebrow">Repositories</p>
              <h2>Add your first repository</h2>
              <p>
                Point Piñata at a local git checkout. Add at least one to get going. You can
                register more anytime from Settings.
              </p>
            </header>

            <form :class="styles.registerCard" @submit.prevent="addRepositoryFromPath()">
              <div :class="styles.pathRow">
                <label :class="styles.pathField">
                  <FolderIcon />
                  <input
                    type="text"
                    :value="registerPath"
                    placeholder="~/dev/my-repo..."
                    spellcheck="false"
                    @input="updateRegisterPath"
                    @blur="addRepositoryFromPath()"
                  />
                </label>
                <button
                  type="button"
                  class="uiButton"
                  :disabled="registerBusy"
                  @click="browseRepositoryPath"
                >
                  {{ registerBusy ? 'Checking...' : 'Browse...' }}
                </button>
              </div>

              <p v-if="registerError" :class="styles.formError" role="alert">
                {{ registerError }}
              </p>
            </form>

            <p :class="[styles.eyebrow, styles.addedLabel]">
              {{ repositories.length ? `Added · ${repositories.length}` : 'Added' }}
            </p>

            <div v-if="repositories.length" :class="styles.addedRepos">
              <div v-for="repo in repositories" :key="repo.id" :class="styles.addedRepo">
                <span :class="styles.repoTile"><RepositoryIcon /></span>
                <span :class="styles.addedRepoCopy">
                  <span :class="styles.addedRepoTitle">
                    <strong>{{ repo.name }}</strong>
                    <span v-if="repo.org" :class="styles.addedRepoOrg">{{ repo.org }}</span>
                    <span :class="styles.addedRepoBranch">{{ repo.defaultBranch }}</span>
                  </span>
                  <small :class="styles.addedRepoPath">{{ repo.source.path }}</small>
                </span>
                <span :class="styles.readyPill"><CheckIcon /> Ready</span>
                <button
                  type="button"
                  class="uiButton uiButtonIcon uiButtonNaked"
                  :class="styles.removeRepo"
                  aria-label="Remove repository"
                  @click="removeRepository(repo.id)"
                >
                  <XIcon />
                </button>
              </div>
            </div>

            <div v-else :class="styles.emptyRepos">
              <p>No repositories yet. Add a folder above to continue.</p>
            </div>
          </template>

          <template v-else>
            <div :class="styles.done">
              <span :class="styles.successMark">
                <span :class="styles.successHalo" aria-hidden="true" />
                <span :class="styles.successIcon"><CheckIcon /></span>
              </span>
              <h2>You're all set!</h2>
              <p>
                Your setup is ready. Create your first task and Piñata will use these repos as
                its starting point.
              </p>

              <div :class="styles.recap">
                <div :class="styles.recapRow">
                  <span :class="styles.repoTile">
                    <SunIcon v-if="settings.theme === 'pinata-light'" />
                    <MoonIcon v-else />
                  </span>
                  <span>
                    <small>Theme</small>
                    <strong>{{ onboardingThemeLabels[settings.theme] }}</strong>
                  </span>
                  <span :class="styles.recapCheck"><CheckIcon /></span>
                </div>
                <div :class="styles.recapRow">
                  <span
                    :class="styles.recapSwatch"
                    :style="{ background: selectedAccent.color, color: selectedAccent.check }"
                  />
                  <span>
                    <small>Accent</small>
                    <strong>
                      {{ selectedAccent.name }} ·
                      {{ onboardingIntensityLabels[settings.accentIntensity] }}
                    </strong>
                  </span>
                  <span :class="styles.recapCheck"><CheckIcon /></span>
                </div>
                <div :class="styles.recapRow">
                  <span :class="styles.repoTile"><RepositoryIcon /></span>
                  <span>
                    <small>Repositories</small>
                    <strong>
                      {{ repositories.length }}
                      {{ repositories.length === 1 ? 'repository' : 'repositories' }} ready
                    </strong>
                  </span>
                  <span :class="styles.recapCheck"><CheckIcon /></span>
                </div>
              </div>
            </div>
          </template>
        </div>
      </div>

      <footer :class="styles.footer">
        <div :class="styles.footerSide">
          <button v-if="step > 0" type="button" class="uiButton" @click="goBack">
            <ArrowLeftIcon />
            Back
          </button>
        </div>

        <div :class="styles.dots" aria-hidden="true">
          <span
            v-for="dot in 4"
            :key="dot"
            :class="[
              styles.dot,
              step === dot - 1 && styles.dotActive,
              step > dot - 1 && styles.dotDone,
            ]"
          />
        </div>

        <div :class="[styles.footerSide, styles.footerRight]">
          <button
            v-if="step === 0"
            type="button"
            class="uiButton uiButtonPrimary"
            @click="goNext"
          >
            Get started
            <ArrowRightIcon />
          </button>
          <button
            v-else-if="step === 1"
            type="button"
            class="uiButton uiButtonPrimary"
            @click="goNext"
          >
            Continue
            <ArrowRightIcon />
          </button>
          <button
            v-else-if="step === 2"
            type="button"
            class="uiButton uiButtonPrimary"
            :disabled="repositories.length === 0"
            @click="goNext"
          >
            Continue
            <ArrowRightIcon />
          </button>
          <template v-else>
            <button type="button" class="uiButton" @click="finish(false)">
              Explore on my own
            </button>
            <button type="button" class="uiButton uiButtonPrimary" @click="finish(true)">
              Create first task
              <ArrowRightIcon />
            </button>
          </template>
        </div>
      </footer>
    </div>
  </section>
</template>
