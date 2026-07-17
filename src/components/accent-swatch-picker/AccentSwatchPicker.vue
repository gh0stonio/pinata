<script setup lang="ts">
import styles from './AccentSwatchPicker.module.css'

type AccentId = 'coral' | 'teal' | 'gold' | 'magenta' | 'lime' | 'azure' | 'mono'

defineProps<{
  accent: AccentId
  items: Array<{ id: AccentId; name: string }>
}>()

const emit = defineEmits<{
  select: [accent: AccentId]
}>()
</script>

<template>
  <div :class="styles.swatches" role="group" aria-label="Accent color">
    <button
      v-for="item in items"
      :key="item.id"
      type="button"
      :class="[styles.swatch, item.id === accent && styles.swatchSelected]"
      :data-accent-option="item.id"
      :aria-label="item.name"
      :aria-pressed="item.id === accent"
      @click="emit('select', item.id)"
    >
      <span v-if="item.id === accent" aria-hidden="true">✓</span>
    </button>
  </div>
</template>
