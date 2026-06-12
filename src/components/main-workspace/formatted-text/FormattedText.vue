<script setup lang="ts">
import { computed } from 'vue'
import styles from './FormattedText.module.css'
import { parseMarkdown } from './markdown'

const props = defineProps<{
  text: string
  variant: 'user' | 'assistant'
}>()

const blocks = computed(() => parseMarkdown(props.text))
const textClasses = computed(() => [styles.text, props.variant === 'user' && styles.userText])
</script>

<template>
  <div :class="textClasses">
    <template v-for="(block, blockIndex) in blocks" :key="blockIndex">
      <p v-if="block.kind === 'paragraph'" :class="styles.paragraph">
        <template v-for="(part, partIndex) in block.parts" :key="partIndex">
          <strong v-if="part.kind === 'bold'">{{ part.text }}</strong>
          <code v-else-if="part.kind === 'code'" :class="styles.inlineCode">{{ part.text }}</code>
          <template v-else>{{ part.text }}</template>
        </template>
      </p>

      <blockquote v-else-if="block.kind === 'quote'" :class="styles.quote">
        <template v-for="(part, partIndex) in block.parts" :key="partIndex">
          <strong v-if="part.kind === 'bold'">{{ part.text }}</strong>
          <code v-else-if="part.kind === 'code'" :class="styles.inlineCode">{{ part.text }}</code>
          <template v-else>{{ part.text }}</template>
        </template>
      </blockquote>

      <ul v-else-if="block.kind === 'list'" :class="styles.list">
        <li v-for="(item, itemIndex) in block.items" :key="itemIndex">
          <span>
            <template v-for="(part, partIndex) in item" :key="partIndex">
              <strong v-if="part.kind === 'bold'">{{ part.text }}</strong>
              <code v-else-if="part.kind === 'code'" :class="styles.inlineCode">{{ part.text }}</code>
              <template v-else>{{ part.text }}</template>
            </template>
          </span>
        </li>
      </ul>

      <pre v-else :class="styles.codeBlock"><code>{{ block.code }}</code></pre>
    </template>
  </div>
</template>
