<script setup lang="ts">
import { ref } from 'vue'
import ArrowLeftIcon from '../../icons/ArrowLeftIcon.vue'
import CommandIcon from '../../icons/CommandIcon.vue'
import SunIcon from '../../icons/SunIcon.vue'
import {
  type Accent,
  accents,
  type SettingsSection,
  shortcuts,
  type Theme,
  themes,
} from './settings'
import styles from './SettingsView.module.css'

defineProps<{
  theme: Theme
  accent: Accent
}>()

const emit = defineEmits<{
  close: []
  'update-theme': [theme: Theme]
  'update-accent': [accent: Accent]
}>()

const section = ref<SettingsSection>('appearance')

function selectSection(nextSection: SettingsSection) {
  section.value = nextSection
}
</script>

<template>
  <section :class="styles.overlay" aria-label="Settings">
    <aside :class="styles.rail">
      <button type="button" :class="styles.back" @click="emit('close')">
        <ArrowLeftIcon :class="styles.backIcon" />
        Back to app
      </button>

      <nav :class="styles.nav" aria-label="Settings sections">
        <section :class="styles.navGroup">
          <p :class="styles.navLabel">Personal</p>
          <button
            type="button"
            :class="[styles.navItem, section === 'appearance' && styles.navItemActive]"
            :aria-current="section === 'appearance' ? 'page' : undefined"
            @click="selectSection('appearance')"
          >
            <SunIcon :class="styles.navIcon" />
            <span>Appearance</span>
          </button>
          <button
            type="button"
            :class="[styles.navItem, section === 'shortcuts' && styles.navItemActive]"
            :aria-current="section === 'shortcuts' ? 'page' : undefined"
            @click="selectSection('shortcuts')"
          >
            <CommandIcon :class="styles.navIcon" />
            <span>Shortcuts</span>
          </button>
        </section>
      </nav>
    </aside>

    <main :class="styles.content">
      <div :class="styles.inner">
        <template v-if="section === 'appearance'">
          <h1 :class="styles.title">Appearance</h1>

          <section :class="styles.settingsGroup" aria-labelledby="theme-title">
            <p id="theme-title" :class="styles.groupLabel">Theme</p>
            <div :class="styles.card">
              <div :class="[styles.row, styles.rowFirst]">
                <div :class="styles.rowCopy">
                  <h2>Color theme</h2>
                  <p>Piñata dark, or a matched light variant</p>
                </div>
                <div :class="styles.segment" role="group" aria-label="Color theme">
                  <button
                    v-for="item in themes"
                    :key="item.id"
                    type="button"
                    :class="[styles.segmentButton, item.id === theme && styles.segmentButtonActive]"
                    :aria-pressed="item.id === theme"
                    @click="emit('update-theme', item.id)"
                  >
                    {{ item.name }}
                  </button>
                </div>
              </div>

              <div :class="styles.row">
                <div :class="styles.rowCopy">
                  <h2>Accent color</h2>
                  <p>Highlights, active tabs and primary actions</p>
                </div>
                <div :class="styles.swatches" role="group" aria-label="Accent color">
                  <button
                    v-for="item in accents"
                    :key="item.id"
                    type="button"
                    :class="[styles.swatch, item.id === accent && styles.swatchSelected]"
                    :data-accent-option="item.id"
                    :aria-label="item.name"
                    :aria-pressed="item.id === accent"
                    @click="emit('update-accent', item.id)"
                  >
                    <span v-if="item.id === accent" aria-hidden="true">✓</span>
                  </button>
                </div>
              </div>
            </div>
          </section>
        </template>

        <template v-else-if="section === 'shortcuts'">
          <h1 :class="styles.title">Shortcuts</h1>

          <section :class="styles.settingsGroup" aria-labelledby="shortcuts-title">
            <p id="shortcuts-title" :class="styles.groupLabel">Keyboard</p>
            <div :class="styles.card" aria-label="Keyboard shortcuts">
              <div
                v-for="(shortcut, index) in shortcuts"
                :key="shortcut.keys"
                :class="[styles.row, styles.shortcutRow, index === 0 && styles.rowFirst]"
              >
                <div :class="styles.rowCopy">
                  <h2>{{ shortcut.label }}</h2>
                </div>
                <kbd :class="styles.key">{{ shortcut.keys }}</kbd>
              </div>
            </div>
          </section>
        </template>
      </div>
    </main>
  </section>
</template>
