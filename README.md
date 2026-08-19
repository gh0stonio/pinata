<p align="center">
  <img src="Pi%C3%B1ata/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" alt="Piñata logo" width="112" height="112" />
</p>

<h1 align="center">Piñata</h1>

<p align="center">
  <strong>Start anywhere. Keep it moving.</strong><br />
  A native macOS workspace for coding work in motion.
</p>

<p align="center">
  <a href="#what-it-is">What it is</a> |
  <a href="#product-direction">Product direction</a> |
  <a href="#current-state">Current state</a> |
  <a href="#development">Development</a>
</p>

## What It Is

Piñata is a terminal-first macOS workspace built around tasks rather than repositories.

Start with an idea, investigation, bug report, or agent prompt. Attach repositories when code needs to move, work through real native terminals, review the resulting changes, and keep the path to a pull request in one place.

Piñata does not pretend to be the agent. It gives `pi`, `claude`, `codex`, and plain shell sessions a durable native home.

## Product Direction

Piñata combines four parts of the coding workflow:

- **Tasks:** the primary unit of work, spanning one or more repositories.
- **Terminal:** native Ghostty surfaces for shells and coding agents.
- **Workspace:** files, diffs, checks, branches, and worktrees kept with the task.
- **Delivery:** Git and GitHub context through review and pull request creation.

The application is being rebuilt as a fully native macOS app. AppKit owns the application lifecycle, windows, menus, panes, focus, and platform integration. Ghostty will own terminal emulation and rendering.

## Current State

The current `main` branch includes:

- Swift 6 and AppKit.
- Standard Xcode macOS application target.
- Native application lifecycle, menu, and resizable window.
- Main actor isolation for UI state.
- Asset catalog with the Piñata application icon.
- macOS 14 or newer.
- App version `0.0.1`, build `1`.
- Native Ghostty terminal tabs and split panes.
- Task sidebar with pinned tasks, drag sorting, and collapsed/transient presentation.
- Create, rename, pin, attach repositories to, detach repositories from, and delete tasks.
- Local repository registration, Git metadata, branches, tags, and global or per-repository worktree defaults.
- Per-task Git worktrees with a Piñata branch, created from a freshly fetched repository default branch.
- Parallel worktree provisioning with current-step status, failure recovery, and retry actions.
- Theme, accent, font-size, terminal-size, and light/dark appearance settings.
- Worktree-aware terminals, task and repository action menus, and safe cleanup of Piñata-owned worktrees and branches.
- App-session restoration for selected scope, expanded tasks, terminal tabs, split layout, active pane, and working directories.
- Durable local terminal sessions: restored Ghostty panes reconnect to their existing shell or agent process after an app quit, with native Ghostty scrolling and no tmux dependency.

File browsing, diffs, reviews, checks, pull request workflows, and Pi discussion/daemon support are not implemented yet.

## Project Structure

```text
Piñata.xcodeproj/       Xcode project and shared scheme
Piñata/
  PinataApp.swift       AppKit entry point and application lifecycle
  Assets.xcassets/      Application assets and icon catalog
  Settings/             Shared settings layout, appearance, and repositories
  Terminal/             Ghostty runtime, surface, and AppKit host
  Workspace/            Workspace shell, session persistence, and side panels
Scripts/                Local dependency bootstrap
DerivedData/            Generated local Xcode output, ignored by Git
```

Xcode generates the application bundle, `Info.plist`, compiled assets, and local development signature. Build settings such as the bundle identifier, version, deployment target, and Swift language mode live in `Piñata.xcodeproj/project.pbxproj`.

See the [documentation map](docs/README.md) for the product workflow, current architecture, terminal sessions, and incoming Pi proposal.

## Development

### Requirements

- Apple silicon Mac.
- macOS 14 or newer.
- Xcode 16 or newer.
- Internet access for the first bootstrap.

Confirm the selected toolchain:

```bash
xcodebuild -version
xcode-select -p
```

The developer path should resolve to Xcode:

```text
/Applications/Xcode.app/Contents/Developer
```

If necessary:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

### Bootstrap terminal dependencies

Download the pinned Ghostty artifact:

```bash
./Scripts/bootstrap-ghostty.sh
```

Run this once before opening or building the project.

### Open in Xcode

```bash
open Piñata.xcodeproj
```

Use `Cmd+R` to build and run, or `Cmd+B` to build without launching.

### Build from the Terminal

```bash
xcodebuild \
  -project Piñata.xcodeproj \
  -scheme Piñata \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData \
  build
```

The generated app is available at:

```text
DerivedData/Build/Products/Debug/Piñata.app
```

Launch it with:

```bash
open DerivedData/Build/Products/Debug/Piñata.app
```

### Release Build

```bash
xcodebuild \
  -project Piñata.xcodeproj \
  -scheme Piñata \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData \
  build
```

A local Release build is optimized but is not prepared for public distribution. Developer ID signing and notarization will be configured before the first distributed release.

### Analyze

```bash
xcodebuild \
  -project Piñata.xcodeproj \
  -scheme Piñata \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData \
  analyze
```

### Test

```bash
xcodebuild \
  -project Piñata.xcodeproj \
  -scheme Piñata \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData \
  test
```

### Clean

```bash
xcodebuild \
  -project Piñata.xcodeproj \
  -scheme Piñata \
  -derivedDataPath DerivedData \
  clean
```

`DerivedData/` contains generated build products, indexes, caches, and logs. It can be removed safely when a completely fresh local build is needed.
