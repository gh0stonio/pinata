<script setup lang="ts">
import styles from './MainWorkspace.module.css'
</script>

<template>
  <main :class="styles.main">
    <div :class="styles.tabBar" aria-hidden="true" />

    <section :class="styles.workspace" aria-labelledby="pinata-empty-title">
      <div :class="styles.emptyState">
        <h1 id="pinata-empty-title">What should we build?</h1>
        <p>Connect Pi RPC to start the first session.</p>
      </div>
    </section>
  </main>
</template>
