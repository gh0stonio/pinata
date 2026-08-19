# File browser architecture

## Product contract

The Files tab in the right workspace panel browses the active workspace's initial working directory. Its root does not follow `cd` commands executed inside a terminal pane.

- A repository attachment uses the attachment's repository name and worktree path.
- A task-only workspace uses its initial workspace directory.
- Local and SSH-backed workspaces share the same tree behavior.
- Expanding a folder loads its direct children. Command-clicking a folder collapses its complete expanded branch.
- The right panel is independently resizable from `220` to `560` points and preserves its width in `UserDefaults`.

## Panel ownership

The two side panels are separate components because they have different responsibilities and layout rules.

| Component | Responsibility |
| --- | --- |
| `PanelViewController` | Left task navigation, pinned sections, task rows, and transient sidebar presentation. |
| `WorkspacePanelViewController` | Right Files, Review, and PR tabs, file-tree loading, caching, and refresh. |
| `WorkspaceViewController` | Places both panels, owns their independent width constraints and resize handles, and supplies the active file root. |

Panel-specific spacing, visibility, and state must remain inside the owning component. Shared theme tokens and small controls may be reused, but a change to one panel must not mutate the other's constraints or presentation state.

## Loading model

The tree loads incrementally so opening a large repository does not enumerate its complete contents.

1. Load the root's direct children.
2. Prefetch up to two descendant levels in small batches.
3. Give an explicit folder expansion priority over background prefetch.
4. Stop prefetch while the user is live-scrolling and defer outline reloads until scrolling ends.

One prefetch run is capped at `64` directories and `5,000` entries. Cached but inactive directory listings are also evicted when the current workspace exceeds `256` directories or `20,000` entries. Expanded listings stay available while they are required to render the visible tree.

## Persistent cache

File-tree state is stored at `Application Support/<bundle-id>/file-tree-cache-v1.json`.

The cache key combines the root path with its target. Local and SSH roots with the same path cannot share data, and an SSH key includes the connection identity and host. Each cache stores directory listings, expanded paths, and its update time.

- Keep at most `24` workspace roots.
- Keep at most `256` directory listings and `20,000` entries per persisted root.
- Persist at workspace changes, panel close, and application termination instead of rewriting the JSON file after every folder load.
- Remove a root's cache when its task or repository attachment is deleted.
- Show local persisted entries immediately, then refresh relevant directories in the background.
- For SSH roots, validate and load the current root before exposing cached descendant listings. Hide cached children and show Retry whenever SSH validation or refresh fails.

## Change detection

### Local workspaces

One recursive FSEvents stream watches the workspace root. Directory events are coalesced and mapped to loaded expanded ancestors before reloading. The implementation must not create one file descriptor per expanded directory.

### SSH workspaces

SSH refresh uses lightweight directory signatures before requesting listings. Polling runs every two seconds only when all of these conditions hold:

- the right panel is open;
- the Files tab is selected;
- the application and window are visible and active;
- the folder is the root or a visible expanded directory;
- no previous live refresh is still running.

Only directories whose signatures changed are listed again. Hiding the panel or changing workspace cancels polling. A transient SSH failure clears the signature baseline and retries on the next interval.

Remote listings use NUL-delimited records so tabs and newlines in filenames do not corrupt parsing. File type comes from the filesystem listing, never from a folder's name.

Each listing includes an explicit root marker. A valid empty directory produces an empty listing, while a missing or temporarily unavailable directory produces no result and cannot overwrite the last good cache.

## Icons and settings

`FileTreeIconResolver` maps known file names and suffixes to semantic SF Symbols and falls back to generic file or folder icons. Directory detection always wins over name-based icon matching.

Appearance settings expose colored and monochrome file icons. This preference is backward compatible and defaults to colored for older settings data.

## Lifecycle and performance invariants

- No filesystem or SSH monitoring while the right panel is hidden or another right-panel tab is selected.
- No SSH listing loop while the app is inactive, minimized, or occluded.
- No complete repository enumeration for initial display or refresh.
- No outline reload during live scrolling.
- The tree column tracks the visible viewport and the clip view rejects horizontal scrolling.
- Cancel load, prefetch, refresh, and monitor work when the root changes.
- Prune removed directory branches from entries, expanded paths, node identity, and access tracking.
- Bound both persisted roots and inactive in-memory directory listings.

These constraints are part of the feature contract. Changes to caching, outline rendering, or panel layout must preserve them and keep the local file-tree integration test, cache-bound test, SSH parser test, and workspace panel layout test passing.
