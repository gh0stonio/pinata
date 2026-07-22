<script setup lang="ts">
import { computed, nextTick, onMounted, ref } from 'vue'
import type {
  AppState,
  TaskTerminalPane,
  TaskTerminalTab,
  TerminalSplitDirection,
} from '../../features/app-state/app-state'
import {
  effectiveTerminalLayout,
  effectiveTerminalTabs,
  selectedTerminalTarget,
} from '../../features/app-state/app-state'
import { terminalShellName } from '../../features/terminal/terminal'
import AppTooltip from '../../components/tooltip/AppTooltip.vue'
import LayersIcon from '../../icons/LayersIcon.vue'
import PlusIcon from '../../icons/PlusIcon.vue'
import TerminalIcon from '../../icons/TerminalIcon.vue'
import TrashIcon from '../../icons/TrashIcon.vue'
import XIcon from '../../icons/XIcon.vue'
import styles from './MainSurface.module.css'
import TerminalSplitNode from './TerminalSplitNode.vue'

const props = defineProps<{
  appState: AppState
  taskOperation?: { taskId: string; kind: 'create' | 'update' | 'delete' } | null
  terminalFontSize: number
  terminalCurrentPaths: Record<string, string>
  terminalProcessNames: Record<string, string>
}>()

const emit = defineEmits<{
  'select-terminal-pane': [taskId: string, paneId: string]
  'select-terminal-tab': [taskId: string, tabId: string]
  'open-terminal-tab': [taskId: string]
  'close-terminal-tab': [taskId: string, tabId: string]
  'rename-terminal-tab': [taskId: string, tabId: string, title: string]
  'split-terminal-pane': [taskId: string, paneId: string, direction: TerminalSplitDirection]
  'close-terminal-pane': [taskId: string, paneId: string]
  'terminal-output': [sessionId: string]
}>()

const shellName = ref('shell')
const editingTabId = ref<string | null>(null)
const editingTabTitle = ref('')
const focusedRenameTabId = ref<string | null>(null)

const selectedTask = computed(() =>
  props.appState.tasks.find((task) => task.id === props.appState.selection.taskId),
)
const selectedTaskOperation = computed(
  () =>
    props.taskOperation && selectedTask.value?.id === props.taskOperation.taskId
      ? props.taskOperation
      : null,
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

const terminalTabs = computed(() => {
  const task = selectedTask.value
  const terminal = selectedTerminal.value

  return task && terminal ? effectiveTerminalTabs(task, terminal) : undefined
})

const panesById = computed<Record<string, TaskTerminalPane>>(() => {
  const layout = terminalLayout.value

  if (!layout) {
    return {}
  }

  return Object.fromEntries(layout.panes.map((pane) => [pane.id, pane]))
})

function folderNameFromPath(path: string) {
  const trimmedPath = path.trim()

  if (!trimmedPath) {
    return shellName.value
  }

  if (trimmedPath === '~') {
    return '~'
  }

  const normalizedPath = trimmedPath.replace(/\/+$/, '')
  const pathParts = normalizedPath.split('/').filter(Boolean)
  const folderName = pathParts[pathParts.length - 1]

  return folderName || normalizedPath
}

function activePaneForTab(tab: TaskTerminalTab) {
  return tab.layout.panes.find((pane) => pane.id === tab.layout.activePaneId) ?? tab.layout.panes[0]
}

function defaultTabTitle(tab: TaskTerminalTab) {
  const activePane = activePaneForTab(tab)

  if (!activePane) {
    return shellName.value
  }

  return folderNameFromPath(props.terminalCurrentPaths[activePane.sessionId] ?? activePane.cwd)
}

function tabTitle(tab: TaskTerminalTab) {
  return tab.kind === 'shell' && tab.title === 'shell' ? defaultTabTitle(tab) : tab.title
}

function emitSelectTerminalPane(paneId: string) {
  const task = selectedTask.value

  if (task) {
    emit('select-terminal-pane', task.id, paneId)
  }
}

function emitSelectTerminalTab(tabId: string) {
  const task = selectedTask.value

  if (task) {
    emit('select-terminal-tab', task.id, tabId)
  }
}

function emitCloseTerminalTab(tabId: string) {
  const task = selectedTask.value

  if (task) {
    emit('close-terminal-tab', task.id, tabId)
  }
}

function startRenameTab(tab: TaskTerminalTab) {
  editingTabId.value = tab.id
  editingTabTitle.value = tabTitle(tab)
}

function setRenameInput(element: unknown, tabId: string) {
  if (!(element instanceof HTMLInputElement)) {
    return
  }

  if (focusedRenameTabId.value === tabId) {
    return
  }

  focusedRenameTabId.value = tabId

  void nextTick(() => {
    requestAnimationFrame(() => {
      element.focus()
      element.select()
    })
  })
}

function selectRenameInput(event: FocusEvent) {
  const input = event.target

  if (input instanceof HTMLInputElement) {
    input.select()
  }
}

function commitRenameTab(tab: TaskTerminalTab) {
  const task = selectedTask.value
  const title = editingTabTitle.value.trim()

  if (editingTabId.value !== tab.id) {
    return
  }

  editingTabId.value = null
  focusedRenameTabId.value = null

  if (!task) {
    return
  }

  if (!title) {
    if (tab.title !== 'shell') {
      emit('rename-terminal-tab', task.id, tab.id, '')
    }

    return
  }

  if (title !== tabTitle(tab)) {
    emit('rename-terminal-tab', task.id, tab.id, title)
  }
}

function cancelRenameTab() {
  editingTabId.value = null
  focusedRenameTabId.value = null
}

function emitOpenTerminalTab() {
  const task = selectedTask.value

  if (task) {
    emit('open-terminal-tab', task.id)
  }
}

function emitSplitTerminalPane(paneId: string, direction: TerminalSplitDirection) {
  const task = selectedTask.value

  if (task) {
    emit('split-terminal-pane', task.id, paneId, direction)
  }
}

function emitCloseTerminalPane(paneId: string) {
  const task = selectedTask.value

  if (task) {
    emit('close-terminal-pane', task.id, paneId)
  }
}

onMounted(() => {
  void terminalShellName()
    .then((name) => {
      shellName.value = name || 'shell'
    })
    .catch(() => undefined)
})
</script>

<template>
  <main :class="styles.main">
    <section
      v-if="selectedTaskOperation"
      :class="styles.content"
      aria-labelledby="task-operation-title"
    >
      <div :class="[styles.emptyState, styles.operationState]" role="status">
        <TrashIcon
          v-if="selectedTaskOperation.kind === 'delete'"
          :class="[styles.operationIcon, styles.deleteIcon]"
          aria-hidden="true"
        />
        <LayersIcon v-else :class="[styles.operationIcon, styles.updateIcon]" aria-hidden="true" />
        <h1 id="task-operation-title">
          Task is being
          {{
            selectedTaskOperation.kind === 'delete'
              ? 'deleted'
              : selectedTaskOperation.kind === 'create'
                ? 'created'
                : 'updated'
          }}
        </h1>
        <p>
          Its terminals and attached repositories are unavailable until
          {{ selectedTaskOperation.kind === 'delete' ? 'cleanup' : 'setup' }} finishes.
        </p>
      </div>
    </section>

    <section v-else-if="selectedTask && terminalLayout && terminalTabs" :class="styles.terminalHost">
      <div :class="styles.tabBar" role="tablist" aria-label="Terminal tabs">
        <div
          v-for="tab in terminalTabs.tabs"
          :key="tab.id"
          :class="[styles.tabItem, tab.id === terminalTabs.activeTabId && styles.tabItemActive]"
        >
          <div
            v-if="editingTabId === tab.id"
            :class="[styles.tabButton, styles.tabRenameShell]"
          >
            <TerminalIcon :size="16" />
            <input
              :ref="(element) => setRenameInput(element, tab.id)"
              v-model="editingTabTitle"
              :class="styles.tabRenameInput"
              aria-label="Rename terminal tab"
              autocomplete="off"
              @blur="commitRenameTab(tab)"
              @focus="selectRenameInput"
              @keydown.enter.prevent.stop="commitRenameTab(tab)"
              @keydown.esc.prevent.stop="cancelRenameTab"
              @keydown.stop
            >
            <small v-if="tab.layout.panes.length > 1" :class="styles.tabPaneCount">
              {{ tab.layout.panes.length }}
            </small>
          </div>
          <button
            v-else
            type="button"
            :class="styles.tabButton"
            role="tab"
            :aria-selected="tab.id === terminalTabs.activeTabId"
            @click="emitSelectTerminalTab(tab.id)"
            @dblclick.stop="startRenameTab(tab)"
          >
            <TerminalIcon :size="16" />
            <span>{{ tabTitle(tab) }}</span>
            <small v-if="tab.layout.panes.length > 1" :class="styles.tabPaneCount">
              {{ tab.layout.panes.length }}
            </small>
          </button>
          <button
            type="button"
            :class="styles.tabCloseButton"
            aria-label="Close tab"
            @click.stop="emitCloseTerminalTab(tab.id)"
          >
            <XIcon :size="13" />
          </button>
        </div>

        <AppTooltip label="New terminal tab" shortcut="⌘T" placement="top-start">
          <button
            type="button"
            :class="styles.tabAddButton"
            aria-label="New terminal tab"
            @click="emitOpenTerminalTab"
          >
            <PlusIcon :size="13" />
          </button>
        </AppTooltip>
      </div>

      <TerminalSplitNode
        :node="terminalLayout.root"
        :panes="panesById"
        :active-pane-id="terminalLayout.activePaneId"
        :shell-name="shellName"
        :terminal-process-names="terminalProcessNames"
        :terminal-font-size="terminalFontSize"
        @select-pane="emitSelectTerminalPane"
        @split-pane="emitSplitTerminalPane"
        @close-pane="emitCloseTerminalPane"
        @terminal-output="emit('terminal-output', $event)"
      />
    </section>

    <section v-else :class="styles.content" aria-labelledby="pinata-empty-title">
      <div :class="styles.emptyState">
        <h1 id="pinata-empty-title">
          {{ selectedTask ? 'No pane open' : 'No terminal yet' }}
        </h1>
        <p>
          <template v-if="selectedTask">
            Press <kbd :class="styles.key">⌘T</kbd> to open a terminal tab.
          </template>
          <template v-else>
            Create a task to open a terminal.
          </template>
        </p>
      </div>
    </section>
  </main>
</template>
