<p align="center">
  <img src="src/assets/brand/pinata-logo-transparent.svg" alt="Piñata compass logo" width="96" height="96" />
</p>

<h1 align="center">Piñata</h1>

<p align="center">
  <strong>A native macOS home for Pi.</strong><br />
  Pi is the compass. We always head North.
</p>

<p align="center">
  <a href="https://tauri.app">Tauri 2</a> ·
  <a href="https://vuejs.org">Vue 3</a> ·
  <a href="https://www.rust-lang.org">Rust</a> ·
  <a href="https://vite.dev">Vite</a> ·
  <a href="https://www.typescriptlang.org">TypeScript</a>
</p>

---

## What is Piñata?

Piñata is an open-source native macOS desktop app for **Pi** — the model-agnostic, provider-flexible coding agent.

Pi already breaks the one-provider lock-in of many agentic coding tools. Piñata is the native interface around it: fast, minimal, beautiful, and built to speak Pi directly through JSON-RPC rather than scraping terminal output.

The long-term goal is simple:

> Make Pi feel like a first-class native macOS development environment.

Piñata is currently at the **initial V0.1 scaffold** stage. The app launches as a Tauri/Vue shell with the Adeberry design system, custom macOS titlebar, Workspaces area, main workspace, and Context area. Pi RPC, sessions, terminal, files, diffs, and ecosystem views are intentionally still ahead.

---

## Why Piñata exists

Most AI coding agents are tied to one vendor or one model family. Pi is different: it is open-source, model-agnostic, and designed for BYOK/provider flexibility.

But Pi is primarily terminal-first. Piñata exists to provide:

- a native macOS GUI for Pi
- a clean session/workspace model
- a first-class timeline for messages, reasoning, and tools
- integrated terminal and ports views
- Git diff/review workflows
- Pi skills/packages/provider visibility
- a fast, non-Electron desktop experience

Piñata is **not** intended to be a thin CLI wrapper. The target integration is Pi JSON-RPC over stdio.

---

## Current status

Current milestone: **V0.1 scaffold**

Implemented now:

- Tauri 2 app scaffold
- Vue 3 + Vite + TypeScript frontend
- pnpm + Corepack-pinned package manager metadata
- macOS-first window configuration
- custom titlebar with native macOS traffic lights
- Adeberry theme tokens extracted from the design source
- local Syne and JetBrains Mono font files
- CSS Modules for component-level styling
- Workspaces side area
- Main empty workspace
- Context side area
- animated side-area open/close behavior
- provisional Tauri icons generated from the transparent compass logo

Not implemented yet:

- Pi process detection/spawning
- Pi JSON-RPC transport
- chat streaming
- sessions/resume/fork
- terminal/PTTY integration
- file tree
- Git diff/review
- ports/dev-server detection
- Pi skills/packages/providers browser
- keyboard shortcuts
- persistence/settings

---

## Design direction

Piñata uses a restrained native desktop aesthetic:

- dark Adeberry graphite base
- semantic design tokens, not palette-leaky names
- Syne for UI/display text
- JetBrains Mono for code/metadata
- minimal UI until functionality exists
- no fake terminal/session/workspace content in the scaffold

The visual source of truth is preserved at:

```text
docs/design/Pinata.html
```

The transparent compass logo is preserved at:

```text
src/assets/brand/pinata-logo-transparent.svg
```

### Design-system rules

Use semantic tokens in components, for example:

```css
color: var(--color-text-primary);
background: var(--color-background);
border-color: var(--color-border-primary);
```

Avoid palette-specific or theme-specific names in component CSS. Components should not know whether a color came from Nord, Adeberry, Tokyo, etc.

Good token names:

```css
--color-background
--color-surface-primary
--color-surface-hover
--color-border-primary
--color-text-primary
--color-text-tertiary
--color-titlebar-background
--color-side-background
--color-status-success
```

Avoid names like:

```css
--nord9
--blue
--cyan
--sidebar
--chrome
```

---

## Tech stack

| Area | Choice |
|---|---|
| Desktop shell | Tauri 2 |
| Native backend | Rust |
| Frontend | Vue 3 |
| Build tool | Vite |
| Language | TypeScript |
| Package manager | pnpm |
| Styling | CSS Modules + global design tokens |
| Fonts | Local Syne + JetBrains Mono |
| Future terminal | native PTY from Rust + xterm.js |
| Future Pi transport | JSON-RPC over stdio |
| Future Git integration | Rust/git2 |

---

## Repository layout

```text
.
├── docs/
│   └── design/
│       └── Piñata.html              # preserved visual/design source
├── src/
│   ├── assets/
│   │   ├── brand/                    # logo assets
│   │   └── fonts/                    # local bundled font files + licenses
│   ├── components/
│   │   ├── app-shell/                # shell layout and side-area state
│   │   ├── main-workspace/           # center workspace placeholder
│   │   ├── side-pane/                # reusable Workspaces/Context side pane
│   │   └── title-bar/                # custom macOS titlebar
│   ├── styles/
│   │   ├── globals.css               # reset/global base
│   │   ├── themes.css                # semantic design tokens
│   │   ├── typography.css            # local font-face declarations
│   │   └── density.css               # density multipliers
│   ├── App.vue
│   └── main.ts
├── src-tauri/
│   ├── capabilities/                 # Tauri permissions
│   ├── icons/                        # provisional generated app icons
│   ├── src/                          # Rust entrypoints
│   ├── Cargo.toml
│   └── tauri.conf.json
├── package.json
├── pnpm-lock.yaml
└── vite.config.ts
```

---

## Prerequisites

Piñata is macOS-first right now.

You need:

- macOS
- Xcode Command Line Tools
- Node.js 20+ recommended
- pnpm 10.12.1
- Rust stable via rustup
- Tauri desktop prerequisites

### 1. Install Xcode Command Line Tools

```bash
xcode-select --install
```

If they are already installed, this command may say so.

### 2. Install Rust

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup default stable
```

Verify:

```bash
rustc --version
cargo --version
```

### 3. Install/activate pnpm

This repo pins pnpm in `package.json`:

```json
"packageManager": "pnpm@10.12.1"
```

With Corepack:

```bash
corepack enable
corepack prepare pnpm@10.12.1 --activate
pnpm --version
```

If you use Volta and `pnpm` is not found, install it through Volta:

```bash
volta install pnpm@10.12.1
pnpm --version
```

### 4. Install Tauri prerequisites

Read the official Tauri prerequisites for your OS:

```text
https://tauri.app/start/prerequisites/
```

On macOS, Rust + Xcode Command Line Tools are the key pieces for this scaffold.

---

## Getting started

Clone and install:

```bash
git clone git@github.com:gh0stonio/pinata.git
cd pinata
pnpm install
```

Run Piñata as a native Tauri app:

```bash
pnpm dev
```

Type-check the Vue/TypeScript code:

```bash
pnpm check
```

Build the native app bundle:

```bash
pnpm build
```

Piñata is native-first, so there is intentionally no public Vue-only dev script. Tauri starts Vite internally through `src-tauri/tauri.conf.json`.

You can still call the Tauri CLI directly when needed:

```bash
pnpm tauri --help
```

---

## Development workflow

Before opening a PR or pushing a meaningful change, run:

```bash
pnpm check
```

For native shell, Rust, or release-bundle changes, also run:

```bash
pnpm build
```

During everyday app development, run:

```bash
pnpm dev
```

When editing UI:

- keep placeholder UI minimal
- avoid fake features that imply functionality exists
- use CSS Modules for component styling
- use semantic tokens from `src/styles/themes.css`
- keep state as local as possible
- do not introduce Pinia/router until there is real state/routing pressure
- do not add keyboard shortcuts until the behavior exists

When editing the design system:

- preserve Adeberry values from the design source unless intentionally changing the theme
- keep component CSS token-based
- avoid color literals in components except for rare native/platform calibration
- prefer semantic names over palette names

---

## Contributing

Piñata is intentionally early. Contributions are welcome, but the project should stay simple and honest at this stage.

### Good first contributions

- improve README/docs clarity
- refine the Tauri/Vue scaffold
- improve titlebar/window behavior on macOS
- tighten design tokens
- add small tests/tooling if they reduce future risk
- document Pi JSON-RPC assumptions before implementing them

### Please avoid for now

- adding mock-heavy demo UI
- adding global state libraries prematurely
- adding routing before settings/sessions require it
- implementing terminal/files/diff before Pi RPC foundation is clear
- introducing Electron-like complexity
- adding theme variants before Adeberry is stable

### Pull request expectations

A good PR should include:

1. a focused problem statement
2. screenshots or short screen recordings for visual changes
3. notes on any Tauri/macOS behavior changed
4. `pnpm check` passing, plus `pnpm build` for native shell or release-bundle changes
5. no unrelated formatting churn

---

## Roadmap

### V0.1 — Scaffold and first Pi connection

Current target.

- Tauri + Vue + Vite scaffold
- Adeberry design system
- local fonts/assets
- custom macOS titlebar
- spawn/detect Pi in RPC mode
- basic chat request/response streaming
- import/detect existing Pi auth/settings where possible

### V0.2 — Timeline

- user/assistant timeline items
- tool call cards
- reasoning cards
- file-change events
- status indicator: thinking/executing/idle

### V0.3 — Sessions

- list previous Pi sessions
- resume session
- fork session from a timeline entry
- surface tokens/cost/model/session metadata

### V0.4 — Pi ecosystem

- skills browser
- packages list
- providers/models overview
- read-only provider config first
- package install flow later

### V0.5 — Terminal

- native PTY from Rust
- xterm.js frontend
- split Pi/chat + terminal
- port tracking foundation

### V0.6 — Panels and tabs

- layout switcher
- multi-tab workspace
- Context views: files, review, ports, session, Pi ecosystem
- keyboard shortcuts once behavior exists

### V0.7 — Workspaces

- workspace list
- git/worktree awareness
- dirty/status indicators
- folder-without-git mode

### V0.8 — Git, AGENTS.md, preview

- inline diff viewer
- stage/commit primitives
- AGENTS.md editor
- browser/WebView preview panel

### V0.9 — Polish

- model/provider picker
- session config: environment + approval mode
- command palette
- all design themes after Adeberry stabilizes
- persisted app state

### V1.0 — Distribution

- bundle Pi appropriately
- signed/notarized macOS app
- DMG packaging
- auto-update
- onboarding
- GitHub integration

Post-launch ideas:

- best-of-N agent comparisons
- remote projects over SSH
- issue tracker handoff
- scheduled automations
- notification center

---

## Troubleshooting

### `cargo metadata` / `cargo not found`

Rust is missing or not loaded into your shell.

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
cargo --version
```

### `pnpm: command not found`

Use Corepack:

```bash
corepack enable
corepack prepare pnpm@10.12.1 --activate
```

Or, if using Volta:

```bash
volta install pnpm@10.12.1
```

### Tauri config changes are not visible

Fully stop and restart Tauri:

```bash
pnpm dev
```

Some `tauri.conf.json` changes are not picked up by Vite hot reload.

### Color picker reports `#1E2022` instead of `#1D2022`

The source uses `#1D2022` for the native background and CSS background. macOS screenshot/color picker tools can report display-profile/composited values, especially in WKWebView/native overlay regions.

Verify the CSS value in Web Inspector:

```js
getComputedStyle(document.querySelector('[data-theme]'))
  .getPropertyValue('--color-background')
```

Expected value:

```text
#1d2022
```

---

## Naming

The app is **Piñata**.

The compass logo marks π as North: Pi is what orients the environment.

Package/app identifiers:

- npm package: `pinata`
- Tauri product: `Piñata`
- bundle identifier: `dev.pinata.app`

---

## License

Piñata is licensed under the Apache License, Version 2.0.

See [`LICENSE`](LICENSE).
