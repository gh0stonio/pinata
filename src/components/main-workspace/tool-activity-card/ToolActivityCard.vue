<script setup lang="ts">
import { computed, ref } from 'vue'
import type { TimelineItem } from '../../../types/pinata'
import styles from './ToolActivityCard.module.css'

const props = defineProps<{
  item: TimelineItem
}>()

const text = computed(() => props.item.text.trim())
const commandDetail = computed(() => text.value.match(/^Ran `(.+)`$/)?.[1] ?? null)
const detail = computed(() => props.item.detail?.trim() ?? '')
const hasDetail = computed(() => detail.value.length > 0)
const isOpen = ref(false)

const explicitToolName = computed(() => {
  const value = text.value
  return (
    props.item.toolName ??
    value.match(/^(?:Used|Running|Completed)\s+([^.…]+)\s*…?$/i)?.[1] ??
    value.match(/^([^.…]+)\s+failed$/i)?.[1] ??
    null
  )
})

const toolKind = computed(() => {
  const value = `${explicitToolName.value ?? ''} ${text.value}`.toLowerCase()

  if (commandDetail.value || value.includes('bash') || value.includes('command')) {
    return 'bash'
  }
  if (value.includes('write')) {
    return 'write'
  }
  if (value.includes('edit')) {
    return 'edit'
  }
  if (value.includes('read')) {
    return 'read'
  }
  if (value.includes('mcp')) {
    return 'mcp'
  }

  return 'tool'
})

const label = computed(() => explicitToolName.value?.toLowerCase() ?? toolKind.value)

const title = computed(() => {
  const value = text.value

  if (commandDetail.value) {
    return commandDetail.value
  }

  if (!value) {
    return props.item.status === 'streaming' ? 'Waiting for tool details…' : 'Tool call'
  }

  if (/^Pi is preparing a tool call/i.test(value)) {
    return 'Preparing tool call…'
  }

  return value
})

function toggle() {
  if (hasDetail.value) {
    isOpen.value = !isOpen.value
  }
}
</script>

<template>
  <section :class="styles.card" :data-status="item.status" :data-tool="toolKind" :data-open="isOpen">
    <button type="button" :class="styles.header" :disabled="!hasDetail" @click="toggle">
      <span :class="styles.icon" aria-hidden="true">
        <svg v-if="toolKind === 'bash'" width="12" height="12" viewBox="0 0 24 24" fill="none">
          <path d="M5 8l4 4-4 4" />
          <path d="M12 17h7" />
        </svg>
        <svg v-else-if="toolKind === 'write'" width="12" height="12" viewBox="0 0 24 24" fill="none">
          <path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z" />
          <path d="M14 3v5h5" />
          <path d="M12 11v6" />
          <path d="M9 14h6" />
        </svg>
        <svg v-else-if="toolKind === 'edit'" width="12" height="12" viewBox="0 0 24 24" fill="none">
          <path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z" />
          <path d="M14 3v5h5" />
          <path d="M10 15l5-5" />
        </svg>
        <svg v-else width="12" height="12" viewBox="0 0 24 24" fill="none">
          <path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z" />
          <path d="M14 3v5h5" />
        </svg>
      </span>

      <span :class="styles.label">{{ label }}</span>
      <span :class="styles.title">{{ title }}</span>

      <svg
        v-if="item.status === 'streaming'"
        :class="[styles.stateIcon, styles.spinnerIcon]"
        width="13"
        height="13"
        viewBox="0 0 24 24"
        fill="none"
        aria-label="Running"
      >
        <path d="M12 3a9 9 0 0 1 9 9" />
      </svg>

      <svg
        v-else-if="item.status === 'error'"
        :class="styles.stateIcon"
        width="13"
        height="13"
        viewBox="0 0 24 24"
        fill="none"
        aria-label="Failed"
      >
        <path d="M18 6 6 18" />
        <path d="M6 6l12 12" />
      </svg>

      <svg
        v-if="hasDetail"
        :class="styles.chevronIcon"
        width="13"
        height="13"
        viewBox="0 0 24 24"
        fill="none"
        aria-hidden="true"
      >
        <path d="m6 9 6 6 6-6" />
      </svg>
    </button>

    <pre v-if="hasDetail && isOpen" :class="styles.body">{{ detail }}</pre>
  </section>
</template>
