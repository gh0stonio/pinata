<script setup lang="ts">
import styles from './SidePane.module.css'

const props = withDefaults(
  defineProps<{
    title: string
    empty: string
    visible: boolean
    side?: 'left' | 'right'
  }>(),
  { side: 'left' },
)
</script>

<template>
  <aside
    :class="[styles.pane, props.side === 'left' ? styles.left : styles.right, !visible && styles.hidden]"
    :aria-hidden="!visible"
    :aria-label="title"
  >
    <header :class="styles.header">{{ title }}</header>
    <div :class="styles.body">
      <slot>
        <p :class="styles.empty">{{ empty }}</p>
      </slot>
    </div>
  </aside>
</template>
