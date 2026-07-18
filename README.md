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
  <a href="#development">Development</a>
</p>

## Vision

Piñata is for the moment a change starts in one repo and quietly recruits three more.

Instead of juggling terminals, branches, worktrees, review tabs, and PR state by memory, you create
one task and attach every repo it touches. Each repo gets its own branch, worktree, and terminal
space. You run the harness you want, `pi`, `claude`, `codex`, or plain old shell, while Piñata keeps
the surrounding work in one native workbench.

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
- task/repo schema for registered repos, task repo instances, selection, and expanded tasks
- task side panel with task rows, repo rows, selected repo state, and repo metadata hover
- main surface reflects the selected repo until terminal spawn lands
- Settings view with theme, accent, shortcuts, and Git & PR repo registration
- Rust git inspection for local repository registration
- task creation, editing, and deletion UI using registered repos
- git branch and worktree creation for task repos
- git cleanup for confirmed task and task-repo deletion
- Space Grotesk for UI, JetBrains Mono for code

Not implemented yet:

- terminal spawn
- tabs and split panes
- files, review, and PR panels
- advanced settings

## Product Direction

The first usable v0 is built around this shape:

```text
Task
└─ Repo / worktree
   └─ Terminal tab
      └─ Split panes
```

| Layer | Meaning |
|---|---|
| Task | The thing you are trying to ship |
| Repo / worktree | One isolated branch checkout for that task |
| Terminal tab | A real shell where the user starts the tool they want |
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
| Code font | JetBrains Mono |
| Terminal direction | plain terminal surface, spawned natively, no agent RPC |

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

1. Add plain terminal spawning for the selected task repo.
2. Add tab and split pane handling.
3. Add files/review/PR panels.
4. Add advanced settings.
