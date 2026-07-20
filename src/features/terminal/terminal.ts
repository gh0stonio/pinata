import { invoke } from '@tauri-apps/api/core'
import { emit } from '@tauri-apps/api/event'

const TERMINAL_INPUT_EVENT = 'pinata://terminal-input'

export type TerminalSessionInput = {
  sessionId: string
  cwd: string
}

export type TerminalAttachInput = TerminalSessionInput & {
  cols: number
  rows: number
}

export type TerminalWriteInput = {
  sessionId: string
  data: string
}

export type TerminalResizeInput = {
  sessionId: string
  cols: number
  rows: number
}

export type TerminalScrollInput = {
  sessionId: string
  lines: number
}

export type TerminalSessionOnlyInput = {
  sessionId: string
}

export type TerminalOutputEvent = {
  sessionId: string
  data: string
}

export type TerminalExitEvent = {
  sessionId: string
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

export function scrollTerminal(input: TerminalScrollInput): Promise<void> {
  return invoke('terminal_scroll', { input })
}

export function detachTerminal(input: TerminalSessionOnlyInput): Promise<void> {
  return invoke('terminal_detach', { input })
}

export function killTerminalSession(input: TerminalSessionOnlyInput): Promise<void> {
  return invoke('terminal_kill_session', { input })
}
