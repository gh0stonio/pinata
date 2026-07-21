<script setup lang="ts">
import { computed } from 'vue'
import type { TaskTerminalPane, TerminalLayoutNode } from '../../features/app-state/app-state'
import TerminalSurface from '../../features/terminal/TerminalSurface.vue'
import styles from './MainSurface.module.css'

defineOptions({
  name: 'TerminalSplitNode',
})

const props = defineProps<{
  node: TerminalLayoutNode
  panes: Record<string, TaskTerminalPane>
  activePaneId: string
  terminalFontSize: number
}>()

const emit = defineEmits<{
  'select-pane': [paneId: string]
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
      :terminal-font-size="terminalFontSize"
      @select-pane="emit('select-pane', $event)"
    />
    <div :class="styles.splitDivider" aria-hidden="true" />
    <TerminalSplitNode
      :node="node.second"
      :panes="panes"
      :active-pane-id="activePaneId"
      :terminal-font-size="terminalFontSize"
      @select-pane="emit('select-pane', $event)"
    />
  </div>

  <section
    v-else-if="pane"
    :class="[styles.pane, pane.id !== activePaneId && styles.paneDim]"
    @pointerdown.capture="emit('select-pane', pane.id)"
  >
    <TerminalSurface
      :key="pane.sessionId"
      :session-id="pane.sessionId"
      :cwd="pane.cwd"
      :label="pane.label"
      :font-size="terminalFontSize"
    />
  </section>
</template>
