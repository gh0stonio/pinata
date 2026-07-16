<script setup lang="ts">
import styles from './MainSurface.module.css'
</script>

<template>
  <main :class="styles.main">
    <section :class="styles.content" aria-labelledby="pinata-empty-title">
      <div :class="styles.emptyState">
        <h1 id="pinata-empty-title">No terminal yet</h1>
        <p>Create a task, pick a repo, then open a terminal.</p>
      </div>
    </section>
  </main>
</template>
