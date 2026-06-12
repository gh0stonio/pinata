<script setup lang="ts">
import { computed, nextTick, ref, watch } from 'vue'
import type { ConnectionSnapshot, Workspace } from '../../../types/pinata'
import styles from './ComposerBox.module.css'

const props = defineProps<{
  connection: ConnectionSnapshot
  workspace: Workspace | null
}>()

const emit = defineEmits<{
  send: [message: string]
  abort: []
}>()

const draft = ref('')
const input = ref<HTMLTextAreaElement | null>(null)

const hasWorkspace = computed(() => props.workspace !== null)
const isStreaming = computed(() => props.connection.status === 'streaming')
const canSend = computed(
  () => hasWorkspace.value && props.connection.status === 'ready' && draft.value.trim().length > 0,
)

const meta = computed(() => {
  const model = props.connection.model
  if (model) {
    return [model.provider, model.name ?? model.id, props.connection.thinkingLevel]
      .filter(Boolean)
      .join(' · ')
  }

  return props.connection.status === 'ready' ? 'Pi RPC ready' : props.connection.status
})

function submit() {
  const message = draft.value.trim()
  if (!message || !canSend.value) {
    return
  }

  draft.value = ''
  emit('send', message)
  void nextTick(resize)
}

function handleKeydown(event: KeyboardEvent) {
  if (event.key !== 'Enter' || event.shiftKey || event.isComposing) {
    return
  }

  event.preventDefault()
  submit()
}

function resize() {
  const element = input.value
  if (!element) {
    return
  }

  element.style.height = 'auto'

  const lineHeight = Number.parseFloat(window.getComputedStyle(element).lineHeight)
  const maxHeight = (Number.isFinite(lineHeight) ? lineHeight : 20) * 10
  const nextHeight = Math.min(element.scrollHeight, maxHeight)

  element.style.height = `${nextHeight}px`
  element.style.overflowY = element.scrollHeight > maxHeight ? 'auto' : 'hidden'
}

watch(
  draft,
  () => {
    void nextTick(resize)
  },
  { flush: 'post' },
)
</script>

<template>
  <form :class="styles.composer" @submit.prevent="submit">
    <textarea
      ref="input"
      v-model="draft"
      :class="styles.input"
      :disabled="!hasWorkspace || connection.status === 'error'"
      rows="1"
      placeholder="Ask Pi to keep going, or steer…"
      @keydown="handleKeydown"
      @input="resize"
    />

    <div :class="styles.actions">
      <span :class="styles.composerMeta">{{ meta }}</span>
      <div :class="styles.actionGroup">
        <button v-if="isStreaming" type="button" :class="styles.secondaryButton" @click="emit('abort')">
          Abort
        </button>
        <button type="submit" :class="styles.primaryButton" :disabled="!canSend" aria-label="Send prompt">
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" aria-hidden="true">
            <path d="M12 19V5" />
            <path d="M5 12l7-7 7 7" />
          </svg>
        </button>
      </div>
    </div>
  </form>
</template>
