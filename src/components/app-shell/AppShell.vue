<script setup lang="ts">
import { invoke } from '@tauri-apps/api/core'
import { listen, type UnlistenFn } from '@tauri-apps/api/event'
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import type {
  ConnectionSnapshot,
  ExtensionUiRequest,
  ExtensionUiResponse,
  PinataEvent,
  PinataState,
  TimelineItem,
  Workspace,
} from '../../types/pinata'
import MainWorkspace from '../main-workspace/MainWorkspace.vue'
import SidePane from '../side-pane/SidePane.vue'
import TitleBar from '../title-bar/TitleBar.vue'
import styles from './AppShell.module.css'

const emptyState: PinataState = {
  activeWorkspaceId: null,
  workspaces: [],
}

const emptyConnection: ConnectionSnapshot = {
  status: 'booting',
  message: 'Starting Piñata…',
  error: null,
  piExecutablePath: null,
  workspaceId: null,
  sessionId: null,
  sessionName: null,
  sessionFile: null,
  model: null,
  thinkingLevel: null,
  toolActivity: null,
}

const workspacesVisible = ref(true)
const contextVisible = ref(false)
const appState = ref<PinataState>(emptyState)
const connection = ref<ConnectionSnapshot>(emptyConnection)
const timeline = ref<TimelineItem[]>([])
const notice = ref<string | null>(null)
const actionError = ref<string | null>(null)
const extensionRequest = ref<ExtensionUiRequest | null>(null)
const extensionDraft = ref('')
const unlisteners: UnlistenFn[] = []

const activeWorkspace = computed<Workspace | null>(
  () => appState.value.workspaces.find((workspace) => workspace.id === appState.value.activeWorkspaceId) ?? null,
)

const isStreaming = computed(() => connection.value.status === 'streaming')

function toggleWorkspaces() {
  workspacesVisible.value = !workspacesVisible.value
}

function toggleContext() {
  contextVisible.value = !contextVisible.value
}

async function openWorkspace() {
  await invokeAction('open_workspace')
}

async function activateWorkspace(workspaceId: string) {
  if (workspaceId === appState.value.activeWorkspaceId) {
    return
  }

  await invokeAction('activate_workspace', { workspaceId })
}

async function sendPrompt(message: string) {
  await invokeAction('send_prompt', { message })
}

async function abortPrompt() {
  await invokeAction('abort_prompt')
}

async function invokeAction(command: string, args?: Record<string, unknown>) {
  actionError.value = null
  try {
    await invoke(command, args)
  } catch (error) {
    actionError.value = String(error)
  }
}

function handlePinataEvent(event: PinataEvent) {
  switch (event.type) {
    case 'appState':
      appState.value = event.state
      break
    case 'connection':
      connection.value = event.connection
      break
    case 'timelineReset':
      timeline.value = event.items
      break
    case 'timelineItemAdded':
      timeline.value = [...timeline.value, event.item]
      break
    case 'timelineItemUpdated':
      updateTimelineItem(event.item)
      break
    case 'timelineItemDelta':
      appendTimelineDelta(event.id, event.delta)
      break
    case 'timelineItemStatus':
      updateTimelineStatus(event.id, event.status)
      break
    case 'extensionUiRequest':
      handleExtensionRequest(event.request)
      break
    case 'notice':
      notice.value = event.message
      break
  }
}

function appendTimelineDelta(id: string, delta: string) {
  timeline.value = timeline.value.map((item) =>
    item.id === id ? { ...item, text: item.text + delta } : item,
  )
}

function updateTimelineStatus(id: string, status: TimelineItem['status']) {
  timeline.value = timeline.value.map((item) => (item.id === id ? { ...item, status } : item))
}

function updateTimelineItem(nextItem: TimelineItem) {
  timeline.value = timeline.value.map((item) => (item.id === nextItem.id ? nextItem : item))
}

function handleExtensionRequest(request: ExtensionUiRequest) {
  if (request.method === 'notify') {
    notice.value = cleanUiText(request.message ?? 'Pi extension notification.')
    return
  }

  if (request.method === 'setStatus') {
    notice.value = request.statusText ? cleanUiText(request.statusText) : null
    return
  }

  if (request.method === 'setTitle' || request.method === 'setWidget' || request.method === 'set_editor_text') {
    return
  }

  extensionRequest.value = request
  extensionDraft.value = request.prefill ?? ''
}

async function respondToExtension(response: ExtensionUiResponse) {
  extensionRequest.value = null
  extensionDraft.value = ''
  await invokeAction('respond_extension_ui', { response })
}

async function confirmExtension(confirmed: boolean) {
  const request = extensionRequest.value
  if (!request) {
    return
  }

  await respondToExtension({ id: request.id, confirmed })
}

async function chooseExtensionValue(value: string) {
  const request = extensionRequest.value
  if (!request) {
    return
  }

  await respondToExtension({ id: request.id, value })
}

async function submitExtensionDraft() {
  const request = extensionRequest.value
  if (!request) {
    return
  }

  await respondToExtension({ id: request.id, value: extensionDraft.value })
}

async function cancelExtension() {
  const request = extensionRequest.value
  if (!request) {
    return
  }

  await respondToExtension({ id: request.id, cancelled: true })
}

function cleanUiText(value: string) {
  return value.replace(/\u001b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])/g, '')
}

function displayValue(value: string | null | undefined) {
  const cleanValue = value ? cleanUiText(value) : value
  return cleanValue && cleanValue.trim().length > 0 ? cleanValue : '—'
}

function modelLabel() {
  const model = connection.value.model
  const modelText = model ? [model.provider, model.name ?? model.id].filter(Boolean).join(' / ') : null
  const thinkingText = connection.value.thinkingLevel ? `Reasoning: ${connection.value.thinkingLevel}` : null

  return [modelText, thinkingText].filter(Boolean).join(' · ') || '—'
}

onMounted(async () => {
  const unlisten = await listen<PinataEvent>('pinata-event', (event) => {
    handlePinataEvent(event.payload)
  })
  unlisteners.push(unlisten)
  await invokeAction('bootstrap_app')
})

onBeforeUnmount(() => {
  for (const unlisten of unlisteners) {
    unlisten()
  }
})
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
      <SidePane title="Workspaces" empty="No workspaces yet." side="left" :visible="workspacesVisible">
        <div :class="styles.sideContent">
          <button type="button" :class="styles.openButton" :disabled="isStreaming" @click="openWorkspace">
            Open Workspace…
          </button>

          <p v-if="isStreaming" :class="styles.sideHint">Pi is currently responding.</p>

          <div v-if="appState.workspaces.length > 0" :class="styles.workspaceList">
            <button
              v-for="workspaceItem in appState.workspaces"
              :key="workspaceItem.id"
              type="button"
              :class="[
                styles.workspaceItem,
                workspaceItem.id === appState.activeWorkspaceId && styles.workspaceItemActive,
              ]"
              :disabled="isStreaming && workspaceItem.id !== appState.activeWorkspaceId"
              @click="activateWorkspace(workspaceItem.id)"
            >
              <span :class="styles.workspaceName">{{ workspaceItem.name }}</span>
              <span :class="styles.workspacePath">{{ workspaceItem.path }}</span>
            </button>
          </div>

          <p v-else :class="styles.emptyText">No workspaces yet.</p>
        </div>
      </SidePane>

      <MainWorkspace
        :connection="connection"
        :timeline="timeline"
        :workspace="activeWorkspace"
        :notice="notice ?? actionError"
        @send="sendPrompt"
        @abort="abortPrompt"
      />

      <SidePane title="Context" empty="No context yet." side="right" :visible="contextVisible">
        <div :class="styles.contextContent">
          <section :class="styles.contextSection">
            <h2>Workspace</h2>
            <dl>
              <div>
                <dt>Name</dt>
                <dd>{{ displayValue(activeWorkspace?.name) }}</dd>
              </div>
              <div>
                <dt>Path</dt>
                <dd>{{ displayValue(activeWorkspace?.path) }}</dd>
              </div>
            </dl>
          </section>

          <section :class="styles.contextSection">
            <h2>Pi</h2>
            <dl>
              <div>
                <dt>Status</dt>
                <dd>{{ connection.status }}</dd>
              </div>
              <div>
                <dt>Executable</dt>
                <dd>{{ displayValue(connection.piExecutablePath) }}</dd>
              </div>
            </dl>
          </section>

          <section :class="styles.contextSection">
            <h2>Session</h2>
            <dl>
              <div>
                <dt>Name</dt>
                <dd>{{ displayValue(connection.sessionName) }}</dd>
              </div>
              <div>
                <dt>ID</dt>
                <dd>{{ displayValue(connection.sessionId) }}</dd>
              </div>
              <div>
                <dt>File</dt>
                <dd>{{ displayValue(connection.sessionFile) }}</dd>
              </div>
            </dl>
          </section>

          <section :class="styles.contextSection">
            <h2>Model</h2>
            <p>{{ modelLabel() }}</p>
          </section>

          <section v-if="connection.error" :class="[styles.contextSection, styles.errorContext]">
            <h2>Error</h2>
            <p>{{ connection.error.message }}</p>
            <pre v-if="connection.error.details">{{ connection.error.details }}</pre>
          </section>
        </div>
      </SidePane>
    </div>

    <div v-if="extensionRequest" :class="styles.modalScrim">
      <section :class="styles.modal" role="dialog" aria-modal="true">
        <header :class="styles.modalHeader">
          <h2>{{ extensionRequest.title ?? 'Pi extension request' }}</h2>
          <p v-if="extensionRequest.message">{{ extensionRequest.message }}</p>
        </header>

        <div v-if="extensionRequest.method === 'select'" :class="styles.optionList">
          <button
            v-for="option in extensionRequest.options ?? []"
            :key="option"
            type="button"
            :class="styles.optionButton"
            @click="chooseExtensionValue(option)"
          >
            {{ option }}
          </button>
        </div>

        <textarea
          v-else-if="extensionRequest.method === 'editor'"
          v-model="extensionDraft"
          :class="styles.modalTextarea"
          rows="8"
        />

        <input
          v-else-if="extensionRequest.method === 'input'"
          v-model="extensionDraft"
          :class="styles.modalInput"
          :placeholder="extensionRequest.placeholder"
        />

        <footer :class="styles.modalActions">
          <button type="button" :class="styles.modalSecondary" @click="cancelExtension">Cancel</button>
          <button
            v-if="extensionRequest.method === 'confirm'"
            type="button"
            :class="styles.modalPrimary"
            @click="confirmExtension(true)"
          >
            Confirm
          </button>
          <button
            v-else-if="extensionRequest.method !== 'select'"
            type="button"
            :class="styles.modalPrimary"
            @click="submitExtensionDraft"
          >
            Send
          </button>
        </footer>
      </section>
    </div>
  </div>
</template>
