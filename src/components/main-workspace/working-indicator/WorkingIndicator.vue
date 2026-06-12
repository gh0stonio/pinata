<script setup lang="ts">
import styles from './WorkingIndicator.module.css'
</script>

<template>
  <div :class="styles.workingIndicator" role="status">
    <span :class="styles.workingGlyph" aria-hidden="true">
      <span />
      <span />
      <span />
      <span />
      <span />
      <span />
    </span>
    <span>Working...</span>
  </div>
</template>
