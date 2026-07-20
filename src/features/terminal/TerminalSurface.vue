<script setup lang="ts">
import { FitAddon } from '@xterm/addon-fit'
import { Terminal } from '@xterm/xterm'
import '@xterm/xterm/css/xterm.css'
import { listen, type UnlistenFn } from '@tauri-apps/api/event'
import { nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import type { TaskRepo } from '../app-state/app-state'
import {
  attachTerminal,
  detachTerminal,
  resizeTerminal,
  writeTerminal,
  type TerminalExitEvent,
  type TerminalOutputEvent,
} from './terminal'
import styles from './TerminalSurface.module.css'

const props = defineProps<{
  taskRepo: TaskRepo
  repoName: string
  fontSize: number
}>()

const terminalElement = ref<HTMLElement | null>(null)
const errorMessage = ref<string | null>(null)

let terminal: Terminal | undefined
let fitAddon: FitAddon | undefined
let unlistenOutput: UnlistenFn | undefined
let unlistenExit: UnlistenFn | undefined
let resizeObserver: ResizeObserver | undefined
let themeObserver: MutationObserver | undefined
let writeDisposer: { dispose: () => void } | undefined

function cssToken(style: CSSStyleDeclaration, name: string, fallback: string) {
  return style.getPropertyValue(name).trim() || style.getPropertyValue(fallback).trim()
}

function terminalTheme(element: HTMLElement) {
  const style = getComputedStyle(element)

  return {
    background: cssToken(style, '--color-terminal-background', '--color-background'),
    black: cssToken(style, '--color-terminal-black', '--color-background-subtle'),
    blue: cssToken(style, '--color-terminal-blue', '--color-status-info'),
    brightBlack: cssToken(style, '--color-terminal-bright-black', '--color-text-placeholder'),
    brightBlue: cssToken(style, '--color-terminal-blue', '--color-status-info'),
    brightCyan: cssToken(style, '--color-terminal-cyan', '--color-status-info'),
    brightGreen: cssToken(style, '--color-terminal-green', '--color-status-success'),
    brightMagenta: cssToken(style, '--color-terminal-magenta', '--color-status-special'),
    brightRed: cssToken(style, '--color-terminal-red', '--color-status-danger'),
    brightWhite: cssToken(style, '--color-terminal-bright-white', '--color-text-primary'),
    brightYellow: cssToken(style, '--color-terminal-yellow', '--color-status-warning'),
    cursor: cssToken(style, '--color-terminal-foreground', '--color-text-primary'),
    cyan: cssToken(style, '--color-terminal-cyan', '--color-status-info'),
    foreground: cssToken(style, '--color-terminal-foreground', '--color-text-primary'),
    green: cssToken(style, '--color-terminal-green', '--color-status-success'),
    magenta: cssToken(style, '--color-terminal-magenta', '--color-status-special'),
    red: cssToken(style, '--color-terminal-red', '--color-status-danger'),
    selectionBackground: cssToken(
      style,
      '--color-terminal-selection',
      '--color-fallback-selection',
    ),
    white: cssToken(style, '--color-terminal-white', '--color-text-secondary'),
    yellow: cssToken(style, '--color-terminal-yellow', '--color-status-warning'),
  }
}

function fitAndResize() {
  if (!terminal || !fitAddon) {
    return
  }

  fitAddon.fit()
  void resizeTerminal({
    taskRepoId: props.taskRepo.id,
    cols: terminal.cols,
    rows: terminal.rows,
  }).catch(() => undefined)
}

function decodeOutput(data: string) {
  const binary = globalThis.atob(data)
  const bytes = new Uint8Array(binary.length)

  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index)
  }

  return bytes
}

function nextAnimationFrame() {
  return new Promise<void>((resolve) => {
    requestAnimationFrame(() => resolve())
  })
}

function isScrolledToBottom() {
  if (!terminal) {
    return true
  }

  return terminal.buffer.active.viewportY >= terminal.buffer.active.baseY
}

async function attach() {
  const element = terminalElement.value
  const cwd = props.taskRepo.worktreePath

  if (!element || !cwd) {
    return
  }

  terminal = new Terminal({
    allowProposedApi: false,
    convertEol: false,
    cursorBlink: true,
    cursorStyle: 'block',
    fontFamily: '"JetBrains Mono", ui-monospace, "SF Mono", Menlo, Monaco, monospace',
    fontSize: props.fontSize,
    letterSpacing: 0,
    lineHeight: 1.35,
    scrollback: 10000,
    theme: terminalTheme(element),
  })
  fitAddon = new FitAddon()
  terminal.loadAddon(fitAddon)
  terminal.open(element)
  const themeRoot = element.closest('[data-theme]')

  if (themeRoot) {
    themeObserver = new MutationObserver(() => {
      if (terminal) {
        terminal.options.theme = terminalTheme(element)
      }
    })
    themeObserver.observe(themeRoot, { attributes: true, attributeFilter: ['data-theme'] })
  }
  await nextTick()
  await nextAnimationFrame()
  fitAddon.fit()

  writeDisposer = terminal.onData((data) => {
    terminal?.scrollToBottom()

    void writeTerminal({
      taskRepoId: props.taskRepo.id,
      data,
    }).catch((error: unknown) => {
      errorMessage.value = error instanceof Error ? error.message : String(error)
    })
  })

  unlistenOutput = await listen<TerminalOutputEvent>('pinata://terminal-output', (event) => {
    if (event.payload.taskRepoId !== props.taskRepo.id) {
      return
    }

    const shouldStickToBottom = isScrolledToBottom()
    terminal?.write(decodeOutput(event.payload.data), () => {
      if (shouldStickToBottom) {
        terminal?.scrollToBottom()
      }
    })
  })
  unlistenExit = await listen<TerminalExitEvent>('pinata://terminal-exit', (event) => {
    if (event.payload.taskRepoId === props.taskRepo.id) {
      errorMessage.value = 'Terminal session ended.'
    }
  })

  resizeObserver = new ResizeObserver(fitAndResize)
  resizeObserver.observe(element)

  try {
    await attachTerminal({
      taskRepoId: props.taskRepo.id,
      cwd,
      cols: terminal.cols,
      rows: terminal.rows,
    })
    fitAndResize()
    terminal.scrollToBottom()
    terminal.focus()
  } catch (error) {
    errorMessage.value = error instanceof Error ? error.message : String(error)
  }
}

function detach() {
  resizeObserver?.disconnect()
  resizeObserver = undefined
  themeObserver?.disconnect()
  themeObserver = undefined
  unlistenOutput?.()
  unlistenOutput = undefined
  unlistenExit?.()
  unlistenExit = undefined
  writeDisposer?.dispose()
  writeDisposer = undefined
  terminal?.dispose()
  terminal = undefined
  fitAddon = undefined

  void detachTerminal({ taskRepoId: props.taskRepo.id }).catch(() => undefined)
}

onMounted(() => {
  void attach()
})

watch(
  () => props.fontSize,
  () => {
    if (!terminal) {
      return
    }

    terminal.options.fontSize = props.fontSize
    void nextTick().then(fitAndResize)
  },
)

onBeforeUnmount(detach)
</script>

<template>
  <section :class="styles.surface" :aria-label="`${repoName} terminal`">
    <div :class="styles.terminalFrame">
      <div ref="terminalElement" :class="styles.terminal" />
    </div>
    <div v-if="errorMessage" :class="styles.error" role="alert">
      <strong>Terminal unavailable</strong>
      <span>{{ errorMessage }}</span>
    </div>
  </section>
</template>
