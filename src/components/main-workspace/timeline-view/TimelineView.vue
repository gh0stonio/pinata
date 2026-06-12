<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import type { ConnectionSnapshot, TimelineItem } from '../../../types/pinata'
import EmptyWorkspaceState from '../empty-workspace-state/EmptyWorkspaceState.vue'
import TimelineItemView from '../timeline-item/TimelineItem.vue'
import styles from './TimelineView.module.css'

const props = defineProps<{
  connection: ConnectionSnapshot
  timeline: TimelineItem[]
  notice: string | null
}>()

const timelineElement = ref<HTMLElement | null>(null)
const timelineEnd = ref<HTMLElement | null>(null)
let resizeObserver: ResizeObserver | null = null

const showEmptyState = computed(
  () => props.timeline.length === 0 && props.connection.status !== 'streaming',
)

function scrollToBottom() {
  if (timelineElement.value) {
    timelineElement.value.scrollTop = timelineElement.value.scrollHeight
  }
}

function queueScrollToBottom() {
  void nextTick(() => {
    scrollToBottom()
    requestAnimationFrame(() => {
      scrollToBottom()
      requestAnimationFrame(scrollToBottom)
    })
  })
}

watch(
  () => {
    const lastItem = props.timeline[props.timeline.length - 1]
    return [
      props.timeline.length,
      lastItem?.id,
      lastItem?.text.length,
      lastItem?.detail?.length,
      lastItem?.status,
      props.connection.status,
      props.connection.toolActivity,
      props.notice,
    ]
  },
  queueScrollToBottom,
  { flush: 'post' },
)

onMounted(() => {
  resizeObserver = new ResizeObserver(queueScrollToBottom)
  if (timelineElement.value) {
    resizeObserver.observe(timelineElement.value)
  }
})

onBeforeUnmount(() => {
  resizeObserver?.disconnect()
  resizeObserver = null
})
</script>

<template>
  <div ref="timelineElement" :class="styles.timeline">
    <EmptyWorkspaceState
      v-if="showEmptyState"
      :connection="connection"
      :has-timeline-items="timeline.length > 0"
    />

    <TimelineItemView v-for="item in timeline" :key="item.id" :item="item" />

    <div ref="timelineEnd" :class="styles.timelineEnd" aria-hidden="true" />
  </div>
</template>
