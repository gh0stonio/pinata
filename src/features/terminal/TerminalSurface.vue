<script setup lang="ts">
import { FitAddon } from '@xterm/addon-fit'
import { Terminal } from '@xterm/xterm'
import '@xterm/xterm/css/xterm.css'
import { listen, type UnlistenFn } from '@tauri-apps/api/event'
import { nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import {
  attachTerminal,
  cancelTerminalScroll,
  clearTerminal,
  detachTerminal,
  resizeTerminal,
  scrollTerminal,
  writeTerminal,
  type TerminalExitEvent,
  type TerminalOutputEvent,
} from './terminal'
import styles from './TerminalSurface.module.css'

const props = defineProps<{
  sessionId: string
  cwd: string
  label: string
  fontSize: number
}>()

const emit = defineEmits<{
  output: [sessionId: string]
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
let terminalDomElement: HTMLElement | undefined
let wheelRemainder = 0
let isBrowsingScrollback = false
let scrollbackCancel: Promise<void> | undefined

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
    sessionId: props.sessionId,
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

function copyTerminalSelection() {
  const selection = terminal?.getSelection()

  if (!selection) {
    return false
  }

  void globalThis.navigator.clipboard?.writeText(selection).catch(() => undefined)

  return true
}

function clearTerminalScreen() {
  terminal?.clearSelection()
  terminal?.clear()
  terminal?.scrollToBottom()

  void clearTerminal({ sessionId: props.sessionId }).catch((error: unknown) => {
    errorMessage.value = error instanceof Error ? error.message : String(error)
  })
}

function handleTerminalKey(event: KeyboardEvent) {
  if (!event.metaKey || event.ctrlKey || event.altKey) {
    return true
  }

  const key = event.key.toLowerCase()

  if (key === 'k') {
    event.preventDefault()
    event.stopPropagation()
    clearTerminalScreen()
    return false
  }

  if (key === 'c' && terminal?.hasSelection()) {
    event.preventDefault()
    event.stopPropagation()
    copyTerminalSelection()
    return false
  }

  return true
}

function handleTerminalContextMenu(event: MouseEvent) {
  event.preventDefault()
  event.stopPropagation()

  copyTerminalSelection()
}

function wheelDeltaToLines(event: WheelEvent) {
  if (!terminal) {
    return 0
  }

  if (event.deltaMode === WheelEvent.DOM_DELTA_LINE) {
    return event.deltaY
  }

  if (event.deltaMode === WheelEvent.DOM_DELTA_PAGE) {
    return event.deltaY * terminal.rows
  }

  return event.deltaY / (props.fontSize * 1.35)
}

function handleTerminalWheel(event: WheelEvent) {
  if (!terminal || event.deltaY === 0) {
    return false
  }

  event.preventDefault()
  event.stopPropagation()

  wheelRemainder += wheelDeltaToLines(event)

  const lines = wheelRemainder > 0 ? Math.floor(wheelRemainder) : Math.ceil(wheelRemainder)

  if (lines === 0) {
    return false
  }

  const clampedLines = Math.max(-terminal.rows, Math.min(terminal.rows, lines))

  isBrowsingScrollback = true
  void scrollTerminal({
    sessionId: props.sessionId,
    lines: clampedLines,
  }).catch((error: unknown) => {
    errorMessage.value = error instanceof Error ? error.message : String(error)
  })
  wheelRemainder -= lines

  return false
}

function leaveScrollbackBeforeInput() {
  if (!isBrowsingScrollback && !scrollbackCancel) {
    return Promise.resolve()
  }

  isBrowsingScrollback = false

  if (!scrollbackCancel) {
    scrollbackCancel = cancelTerminalScroll({ sessionId: props.sessionId })
      .catch((error: unknown) => {
        errorMessage.value = error instanceof Error ? error.message : String(error)
      })
      .finally(() => {
        scrollbackCancel = undefined
      })
  }

  return scrollbackCancel
}

async function attach() {
  const element = terminalElement.value
  const cwd = props.cwd

  if (!element || !cwd) {
    return
  }

  terminal = new Terminal({
    allowProposedApi: false,
    altClickMovesCursor: false,
    convertEol: false,
    cursorBlink: true,
    cursorStyle: 'block',
    fontFamily: '"JetBrains Mono", ui-monospace, "SF Mono", Menlo, Monaco, monospace',
    fontSize: props.fontSize,
    letterSpacing: 0,
    lineHeight: 1.35,
    macOptionClickForcesSelection: true,
    rightClickSelectsWord: false,
    smoothScrollDuration: 80,
    scrollback: 10000,
    scrollOnUserInput: true,
    theme: terminalTheme(element),
  })
  fitAddon = new FitAddon()
  terminal.loadAddon(fitAddon)
  terminal.open(element)
  terminal.attachCustomKeyEventHandler(handleTerminalKey)
  terminal.attachCustomWheelEventHandler(handleTerminalWheel)
  element.addEventListener('contextmenu', handleTerminalContextMenu)
  terminalDomElement = element
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

    void leaveScrollbackBeforeInput().then(() => {
      void writeTerminal({
        sessionId: props.sessionId,
        data,
      }).catch((error: unknown) => {
        errorMessage.value = error instanceof Error ? error.message : String(error)
      })
    })
  })

  unlistenOutput = await listen<TerminalOutputEvent>('pinata://terminal-output', (event) => {
    if (event.payload.sessionId !== props.sessionId) {
      return
    }

    const shouldStickToBottom = isScrolledToBottom()
    terminal?.write(decodeOutput(event.payload.data), () => {
      if (shouldStickToBottom) {
        terminal?.scrollToBottom()
      }
    })
    emit('output', props.sessionId)
  })
  unlistenExit = await listen<TerminalExitEvent>('pinata://terminal-exit', (event) => {
    if (event.payload.sessionId === props.sessionId) {
      errorMessage.value = 'Terminal session ended.'
    }
  })

  resizeObserver = new ResizeObserver(fitAndResize)
  resizeObserver.observe(element)

  try {
    await attachTerminal({
      sessionId: props.sessionId,
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
  terminalDomElement?.removeEventListener('contextmenu', handleTerminalContextMenu)
  terminalDomElement = undefined
  wheelRemainder = 0
  isBrowsingScrollback = false
  scrollbackCancel = undefined
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

  void detachTerminal({ sessionId: props.sessionId }).catch(() => undefined)
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
  <section :class="styles.surface" :aria-label="`${label} terminal`">
    <div :class="styles.terminalFrame">
      <div ref="terminalElement" :class="styles.terminal" />
    </div>
    <div v-if="errorMessage" :class="styles.error" role="alert">
      <strong>Terminal unavailable</strong>
      <span>{{ errorMessage }}</span>
    </div>
  </section>
</template>
