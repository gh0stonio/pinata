<script setup lang="ts">
import { computed } from 'vue'
import type { TimelineItem } from '../../../types/pinata'
import FormattedText from '../formatted-text/FormattedText.vue'
import ToolActivityCard from '../tool-activity-card/ToolActivityCard.vue'
import styles from './TimelineItem.module.css'

const props = defineProps<{
  item: TimelineItem
}>()

const itemClasses = computed(() => [
  styles.timelineItem,
  props.item.role === 'user' && styles.userItem,
  props.item.role === 'assistant' && styles.assistantItem,
  props.item.role === 'activity' && styles.activityItem,
  props.item.status === 'streaming' && styles.streamingItem,
  props.item.status === 'error' && styles.errorItem,
])
</script>

<template>
  <article :class="itemClasses">
    <ToolActivityCard v-if="item.role === 'activity'" :item="item" />
    <FormattedText v-else :text="item.text" :variant="item.role" />
  </article>
</template>
