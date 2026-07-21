<script setup lang="ts">
import LayersIcon from '../../icons/LayersIcon.vue'
import styles from './ConfirmationDialog.module.css'

defineProps<{
  titleId: string
}>()

const emit = defineEmits<{
  drag: [event: MouseEvent]
}>()
</script>

<template>
  <div :class="styles.layer" role="dialog" aria-modal="true" :aria-labelledby="titleId">
    <div :class="styles.dragRegion" data-tauri-drag-region @mousedown="emit('drag', $event)" />

    <section :class="styles.dialog">
      <div :class="styles.header">
        <span :class="styles.icon" aria-hidden="true">
          <LayersIcon :size="18" />
        </span>
        <div>
          <slot name="body" />
        </div>
      </div>

      <div :class="styles.actions">
        <slot name="actions" />
      </div>
    </section>
  </div>
</template>
