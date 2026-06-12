<script setup lang="ts">
import { computed } from 'vue'
import type { ConnectionSnapshot, TimelineItem, Workspace } from '../../types/pinata'
import ComposerBox from './composer-box/ComposerBox.vue'
import styles from './MainWorkspace.module.css'
import TimelineView from './timeline-view/TimelineView.vue'
import WorkingIndicator from './working-indicator/WorkingIndicator.vue'

const props = defineProps<{
  connection: ConnectionSnapshot
  timeline: TimelineItem[]
  workspace: Workspace | null
  notice: string | null
}>()

const emit = defineEmits<{
  send: [message: string]
  abort: []
}>()

const isStreaming = computed(() => props.connection.status === 'streaming')
</script>

<template>
  <main :class="styles.main">
    <div :class="styles.tabBar">
      <div :class="styles.tabMeta">
        <span :class="styles.statusDot" :data-status="connection.status" />
        <span>{{ workspace?.name ?? 'No workspace' }}</span>
      </div>
    </div>

    <section :class="styles.workspace" aria-live="polite">
      <TimelineView :connection="connection" :timeline="timeline" :notice="notice" />

      <footer :class="styles.composerWrap">
        <WorkingIndicator v-if="isStreaming" />
        <div v-if="notice" :class="styles.notice">{{ notice }}</div>
        <div v-if="connection.toolActivity" :class="styles.notice">{{ connection.toolActivity }}</div>
        <div v-if="connection.status === 'error'" :class="styles.errorSummary">
          <strong>{{ connection.error?.title }}</strong>
          <span>{{ connection.error?.details }}</span>
        </div>

        <ComposerBox :connection="connection" :workspace="workspace" @send="emit('send', $event)" @abort="emit('abort')" />
      </footer>
    </section>
  </main>
</template>
