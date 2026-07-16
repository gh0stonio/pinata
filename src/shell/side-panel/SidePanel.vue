<script setup lang="ts">
import styles from './SidePanel.module.css'

defineProps<{
  title: string
  empty: string
  visible: boolean
  side: 'left' | 'right'
}>()
</script>

<template>
  <aside
    :class="[styles.pane, side === 'left' ? styles.left : styles.right, !visible && styles.hidden]"
    :aria-hidden="!visible"
    :aria-label="title"
  >
    <header :class="styles.header">{{ title }}</header>
    <div :class="styles.content">
      <p :class="styles.empty">{{ empty }}</p>
      <slot />
    </div>
  </aside>
</template>
