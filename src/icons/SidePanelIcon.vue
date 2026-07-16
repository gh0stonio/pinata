<script setup lang="ts">
import { computed } from 'vue'

const props = defineProps<{
  side: 'left' | 'right'
  open: boolean
}>()

const dividerX = computed(() => (props.open ? (props.side === 'left' ? 9 : 15) : props.side === 'left' ? 15 : 9))
const path = computed(() => {
  if (props.open) {
    return props.side === 'left' ? 'M14 9l-2 3 2 3' : 'M10 9l2 3-2 3'
  }

  return props.side === 'left' ? 'M10 9l2 3-2 3' : 'M14 9l-2 3 2 3'
})
</script>

<template>
  <svg
    width="15"
    height="15"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    stroke-width="1.6"
    stroke-linecap="round"
    stroke-linejoin="round"
    aria-hidden="true"
  >
    <rect x="3" y="4" width="18" height="16" rx="2" />
    <line :x1="dividerX" y1="4" :x2="dividerX" y2="20" />
    <path :d="path" />
  </svg>
</template>
