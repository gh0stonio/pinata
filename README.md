<p align="center">
  <img src="src/assets/brand/pinata-logo.png" alt="Piñata logo" width="112" height="112" />
</p>

<h1 align="center">Piñata</h1>

<p align="center">
  <strong>One task. Many repos. Real terminals.</strong><br />
  A native macOS workbench for coding agents, worktrees, reviews, and PRs before your desktop turns into confetti.
</p>

<p align="center">
  <a href="#what-it-is">What it is</a> |
  <a href="#current-slice">Current slice</a> |
  <a href="#docs">Docs</a> |
  <a href="#development">Development</a>
</p>

## What It Is

Piñata is a terminal-first workspace for tasks that may start as pure investigation, then grow into
one or many repositories.

Each task gets a home terminal for planning, agent runs, or scratch work. When code needs to move,
attach repos to the task and Piñata gives each repo its own branch, worktree, and terminal.

Piñata does not pretend to be the agent. It gives `pi`, `claude`, `codex`, and plain shell sessions
a durable native home.

## Current Slice

- Native Tauri 2 + Vue 3 macOS shell.
- Persisted app state, settings, window layout, and resizable panels.
- Repository registration with git metadata.
- Task creation, editing, deletion, and repo attachment.
- Embedded terminal sessions with bundled tmux and xterm.js.

## Docs

- [Product vision](docs/product-vision.md): positioning, capabilities, and how Piñata differs from other tools.
- [Architecture](docs/architecture.md): codebase map, lifecycle, state ownership, and native boundaries.
- Feature specs live beside each feature under [src/features](src/features).
- The v0 design reference lives at [docs/design/Pinata.html](docs/design/Pinata.html).

## Development

Install and run:

```bash
pnpm install
pnpm dev
```

Check:

```bash
pnpm check
cargo test --manifest-path src-tauri/Cargo.toml
```

Build:

```bash
pnpm build
```
