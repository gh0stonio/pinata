<script setup lang="ts">
import { FitAddon } from '@xterm/addon-fit'
import { Terminal } from '@xterm/xterm'
import '@xterm/xterm/css/xterm.css'
import { listen, type UnlistenFn } from '@tauri-apps/api/event'
import { nextTick, onBeforeUnmount, onMounted, ref } from 'vue'
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
}>()

const terminalElement = ref<HTMLElement | null>(null)
const errorMessage = ref<string | null>(null)

let terminal: Terminal | undefined
let fitAddon: FitAddon | undefined
let unlistenOutput: UnlistenFn | undefined
let unlistenExit: UnlistenFn | undefined
let resizeObserver: ResizeObserver | undefined
let writeDisposer: { dispose: () => void } | undefined

function terminalTheme(element: HTMLElement) {
  const style = getComputedStyle(element)

  return {
    background: style.getPropertyValue('--color-background').trim(),
    black: style.getPropertyValue('--color-background-subtle').trim(),
    blue: style.getPropertyValue('--color-status-info').trim(),
    brightBlack: style.getPropertyValue('--color-text-placeholder').trim(),
    brightBlue: style.getPropertyValue('--color-status-info').trim(),
    brightCyan: style.getPropertyValue('--color-status-info').trim(),
    brightGreen: style.getPropertyValue('--color-status-success').trim(),
    brightMagenta: style.getPropertyValue('--color-status-special').trim(),
    brightRed: style.getPropertyValue('--color-status-danger').trim(),
    brightWhite: style.getPropertyValue('--color-text-primary').trim(),
    brightYellow: style.getPropertyValue('--color-status-warning').trim(),
    cursor: style.getPropertyValue('--color-text-primary').trim(),
    cyan: style.getPropertyValue('--color-status-info').trim(),
    foreground: style.getPropertyValue('--color-text-primary').trim(),
    green: style.getPropertyValue('--color-status-success').trim(),
    magenta: style.getPropertyValue('--color-status-special').trim(),
    red: style.getPropertyValue('--color-status-danger').trim(),
    selectionBackground: style.getPropertyValue('--color-fallback-selection').trim(),
    white: style.getPropertyValue('--color-text-secondary').trim(),
    yellow: style.getPropertyValue('--color-status-warning').trim(),
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
    fontSize: 13,
    letterSpacing: 0,
    lineHeight: 1.35,
    scrollback: 10000,
    theme: terminalTheme(element),
  })
  fitAddon = new FitAddon()
  terminal.loadAddon(fitAddon)
  terminal.open(element)
  await nextTick()
  await nextAnimationFrame()
  fitAddon.fit()

  writeDisposer = terminal.onData((data) => {
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

    terminal?.write(decodeOutput(event.payload.data))
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
    terminal.focus()
  } catch (error) {
    errorMessage.value = error instanceof Error ? error.message : String(error)
  }
}

function detach() {
  resizeObserver?.disconnect()
  resizeObserver = undefined
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
