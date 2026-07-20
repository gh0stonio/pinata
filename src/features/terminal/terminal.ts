import { invoke } from '@tauri-apps/api/core'
import { emit } from '@tauri-apps/api/event'

const TERMINAL_INPUT_EVENT = 'pinata://terminal-input'

export type TerminalSessionInput = {
  taskRepoId: string
  cwd: string
}

export type TerminalAttachInput = TerminalSessionInput & {
  cols: number
  rows: number
}

export type TerminalWriteInput = {
  taskRepoId: string
  data: string
}

export type TerminalResizeInput = {
  taskRepoId: string
  cols: number
  rows: number
}

export type TerminalTaskRepoInput = {
  taskRepoId: string
}

export type TerminalOutputEvent = {
  taskRepoId: string
  data: string
}

export type TerminalExitEvent = {
  taskRepoId: string
}

export function ensureTerminalSession(input: TerminalSessionInput): Promise<void> {
  return invoke('terminal_ensure_session', { input })
}

export function attachTerminal(input: TerminalAttachInput): Promise<void> {
  return invoke('terminal_attach', { input })
}

export function writeTerminal(input: TerminalWriteInput): Promise<void> {
  return emit(TERMINAL_INPUT_EVENT, input)
}

export function resizeTerminal(input: TerminalResizeInput): Promise<void> {
  return invoke('terminal_resize', { input })
}

export function detachTerminal(input: TerminalTaskRepoInput): Promise<void> {
  return invoke('terminal_detach', { input })
}

export function killTerminalSession(input: TerminalTaskRepoInput): Promise<void> {
  return invoke('terminal_kill_session', { input })
}
