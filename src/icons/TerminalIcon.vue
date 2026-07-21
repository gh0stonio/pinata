<script setup lang="ts">
withDefaults(defineProps<{ size?: number }>(), {
  size: 14,
})
</script>

<template>
  <svg
    :width="size"
    :height="size"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    stroke-width="1.8"
    stroke-linecap="round"
    stroke-linejoin="round"
    aria-hidden="true"
  >
    <rect x="2.5" y="4" width="19" height="16" rx="2" />
    <path d="m5 8 3 3-3 3" />
    <path d="M12 16h5" />
  </svg>
</template>
