<script setup lang="ts">
import { computed } from 'vue'
import type { ConnectionSnapshot } from '../../../types/pinata'
import styles from './EmptyWorkspaceState.module.css'

const props = defineProps<{
  connection: ConnectionSnapshot
  hasTimelineItems: boolean
}>()

const title = computed(() => {
  switch (props.connection.status) {
    case 'booting':
    case 'loadingAppState':
      return 'Starting Piñata'
    case 'noWorkspace':
      return 'Choose a workspace'
    case 'locatingPi':
      return 'Looking for Pi'
    case 'startingPi':
      return 'Starting Pi'
    case 'restoringSession':
      return 'Restoring session'
    case 'hydratingTimeline':
      return 'Loading conversation'
    case 'ready':
      return props.hasTimelineItems ? 'Ready' : 'What should we build?'
    case 'streaming':
      return 'Pi is responding'
    case 'error':
      return props.connection.error?.title ?? 'Connection error'
  }
})

const message = computed(() => {
  if (props.connection.status === 'ready' && !props.hasTimelineItems) {
    return 'Send the first prompt for this workspace.'
  }

  return props.connection.error?.message ?? props.connection.message ?? 'Open a workspace to start Pi.'
})
</script>

<template>
  <section :class="styles.emptyState" aria-labelledby="pinata-empty-title">
    <h1 id="pinata-empty-title">{{ title }}</h1>
    <p>{{ message }}</p>
  </section>
</template>
