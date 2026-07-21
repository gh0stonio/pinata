<script setup lang="ts">
import { computed } from 'vue'
import type {
  TaskTerminalPane,
  TerminalLayoutNode,
  TerminalSplitDirection,
} from '../../features/app-state/app-state'
import TerminalSurface from '../../features/terminal/TerminalSurface.vue'
import AppTooltip from '../../components/tooltip/AppTooltip.vue'
import SplitHorizontalIcon from '../../icons/SplitHorizontalIcon.vue'
import SplitVerticalIcon from '../../icons/SplitVerticalIcon.vue'
import TerminalIcon from '../../icons/TerminalIcon.vue'
import XIcon from '../../icons/XIcon.vue'
import styles from './MainSurface.module.css'

defineOptions({
  name: 'TerminalSplitNode',
})

const props = defineProps<{
  node: TerminalLayoutNode
  panes: Record<string, TaskTerminalPane>
  activePaneId: string
  shellName: string
  terminalFontSize: number
}>()

const emit = defineEmits<{
  'select-pane': [paneId: string]
  'split-pane': [paneId: string, direction: TerminalSplitDirection]
  'close-pane': [paneId: string]
}>()

const pane = computed(() => (props.node.kind === 'pane' ? props.panes[props.node.paneId] : undefined))
</script>

<template>
  <div
    v-if="node.kind === 'split'"
    :class="[
      styles.split,
      node.direction === 'vertical' ? styles.splitVertical : styles.splitHorizontal,
    ]"
  >
    <TerminalSplitNode
      :node="node.first"
      :panes="panes"
      :active-pane-id="activePaneId"
      :shell-name="shellName"
      :terminal-font-size="terminalFontSize"
      @select-pane="emit('select-pane', $event)"
      @split-pane="(paneId, direction) => emit('split-pane', paneId, direction)"
      @close-pane="emit('close-pane', $event)"
    />
    <div :class="styles.splitDivider" aria-hidden="true" />
    <TerminalSplitNode
      :node="node.second"
      :panes="panes"
      :active-pane-id="activePaneId"
      :shell-name="shellName"
      :terminal-font-size="terminalFontSize"
      @select-pane="emit('select-pane', $event)"
      @split-pane="(paneId, direction) => emit('split-pane', paneId, direction)"
      @close-pane="emit('close-pane', $event)"
    />
  </div>

  <section
    v-else-if="pane"
    :class="[styles.pane, pane.id !== activePaneId && styles.paneDim]"
    @pointerdown.capture="emit('select-pane', pane.id)"
  >
    <header :class="styles.paneHeader">
      <div :class="styles.paneTitle">
        <TerminalIcon :size="13" />
        <span>{{ shellName }}</span>
      </div>

      <div :class="styles.paneActions">
        <AppTooltip label="Split vertically" shortcut="⌘D" placement="top-end">
          <button
            type="button"
            :class="styles.paneActionButton"
            aria-label="Split vertically"
            @click.stop="emit('split-pane', pane.id, 'vertical')"
          >
            <SplitVerticalIcon :size="13" />
          </button>
        </AppTooltip>
        <AppTooltip label="Split horizontally" shortcut="⇧⌘D" placement="top-end">
          <button
            type="button"
            :class="styles.paneActionButton"
            aria-label="Split horizontally"
            @click.stop="emit('split-pane', pane.id, 'horizontal')"
          >
            <SplitHorizontalIcon :size="13" />
          </button>
        </AppTooltip>
        <AppTooltip label="Close pane" shortcut="⌘W" placement="top-end">
          <button
            type="button"
            :class="styles.paneActionButton"
            aria-label="Close pane"
            @click.stop="emit('close-pane', pane.id)"
          >
            <XIcon :size="13" />
          </button>
        </AppTooltip>
      </div>
    </header>

    <div :class="styles.paneBody">
      <TerminalSurface
        :key="pane.sessionId"
        :session-id="pane.sessionId"
        :cwd="pane.cwd"
        :label="pane.label"
        :font-size="terminalFontSize"
      />
    </div>
  </section>
</template>
