<p align="center">
  <img src="src/assets/brand/pinata-logo.png" alt="Piñata logo" width="112" height="112" />
</p>

<h1 align="center">Piñata</h1>

<p align="center">
  <strong>One task. Many repos. Real terminals.</strong><br />
  A native macOS workbench for coding agents, worktrees, reviews, and PRs before your desktop turns into confetti.
</p>

<p align="center">
  <a href="#vision">Vision</a> |
  <a href="#current-state">Current state</a> |
  <a href="#product-direction">Product direction</a> |
  <a href="#architecture">Architecture</a> |
  <a href="#development">Development</a>
</p>

## Vision

Piñata is for the moment a change starts in one repo and quietly recruits three more.

Instead of juggling terminals, branches, worktrees, review tabs, and PR state by memory, you create
one task. That task has its own home terminal for planning, investigation, or agent work. Attach
repos only when the task needs code changes, and each attached repo gets its own branch, worktree,
and terminal. You run the harness you want, `pi`, `claude`, `codex`, or plain old shell, while
Piñata keeps the surrounding work in one native workbench.

The product stays terminal-first. Piñata does not pretend to be the agent, scrape terminal output,
or hide the shell. It gives the shell a proper home.

## Current State

This repo is now past the empty scaffold. The shell is still deliberately small, but durable
task/repo state and the first task side panel are in place.

Implemented:

- Tauri 2 app shell
- Vue 3 + Vite + TypeScript
- custom macOS title bar
- left task side panel, main content, right side panel
- Rust-backed app state persisted in the macOS app data directory
- persisted window size/position and resizable side panel widths
- task/repo schema for registered repos, task terminals, task repo instances, selection, and expanded tasks
- task side panel with task rows, repo rows, selected surface state, and repo metadata hover
- task terminal in `~` plus repo terminals in task-owned worktrees
- Settings view with theme, accent, shortcuts, and Git & PR repo registration
- Rust git inspection for local repository registration
- task creation, editing, and deletion UI using registered repos
- git branch and worktree creation for task repos
- git cleanup for confirmed task and task-repo deletion
- Space Grotesk for UI, JetBrains Mono for terminal and code-like values

Not implemented yet:

- tabs and split panes
- files, review, and PR panels
- advanced settings

## Product Direction

The first usable v0 is built around this shape:

```text
Task
├─ Task terminal
└─ Repo / worktree
   └─ Repo terminal
      └─ Split panes
```

| Layer | Meaning |
|---|---|
| Task | The context you are trying to think through or ship |
| Task terminal | A home shell for planning, investigation, and agent orchestration |
| Repo / worktree | One isolated branch checkout for that task |
| Repo terminal | A real shell inside that repo worktree |
| Split panes | iTerm-style room for parallel work |

Later layers add files, diffs, review, checks, and PR context around that same task.

## Stack

| Area | Choice |
|---|---|
| Desktop shell | Tauri 2 |
| Native backend | Rust |
| Frontend | Vue 3 |
| Build tool | Vite |
| Language | TypeScript |
| Package manager | pnpm |
| Styling | CSS Modules + global tokens |
| UI font | Space Grotesk |
| Terminal/code font | JetBrains Mono |
| Terminal runtime | embedded xterm.js + bundled tmux, no agent RPC |

## Repository Layout

```text
.
├── docs/design/Pinata.html
├── src/
│   ├── assets/
│   ├── features/
│   ├── icons/
│   ├── shell/
│   ├── styles/
│   ├── App.vue
│   └── main.ts
├── src-tauri/
├── package.json
└── vite.config.ts
```

## Architecture

For the codebase map, app lifecycle, state ownership, and branch/worktree flow, see
[docs/architecture.md](docs/architecture.md).

## Development

Install and run:

```bash
pnpm install
pnpm dev
```

Type-check:

```bash
pnpm check
```

Build:

```bash
pnpm build
```

## Next Work

1. Add terminal tabs and split pane handling.
2. Add files/review/PR panels.
3. Add task archive and restore flows.
4. Add advanced settings.
