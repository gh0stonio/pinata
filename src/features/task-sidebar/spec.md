# Task Sidebar

## Source

Based on v0 spec 03 and `reference/src/term-sidebar.jsx`.

## Current scope

- Brand header, task rows, repo rows, and repo hover metadata.
- New Task button and creation modal for task-only or repo-attached tasks.
- Creating a task persists the task record with its default terminal, selects that task terminal,
  and opens the task in the main surface. If repos are attached, Piñata expands the task after git
  branch and worktree creation succeeds.
- Task creation and task edit switch the dialog body to a plain synchronous checklist while setting
  up or cleaning up task-owned repository worktrees. The checklist shows one row per repo, with no
  branch or worktree path detail. The repo name is the row label; the status column carries the live
  phase while a row runs, then `Ready`, `Cleaned`, `Queued`, or `Failed`. App-state persistence is
  part of the transaction but is not shown as a user step. The form returns only when git errors
  need user correction.
- The task dialog scrim preserves the top title-bar drag region while open, including blocking
  worktree progress states.
- During worktree creation, Rust streams git output and hook output into sanitized phase names such
  as `Preparing worktree`, `Updating files`, `Repository hooks`, `Installing packages`,
  `Linking project`, `Building project`, and `Checking constraints`. Raw command details are not
  displayed.
- Git setup and cleanup run repositories in parallel. Inside each repository operation, branch and
  worktree changes stay sequential in the Rust command.
- After each task repo worktree is created, Piñata ensures the matching bundled tmux terminal
  session exists. Terminal setup is part of the same blocking task transaction.
- A repo-less task skips git setup and opens its task terminal in the user's home directory.
- Task creation/edit does not show a generated branch preview. Repo hover metadata owns branch
  display after the row exists.
- Repo hover worktree metadata shows the planned final path:
  `<effective repo worktree base>/<6-char task-id hash>-<task slug>`. Existing `TaskRepo.worktreePath`
  wins once real worktree creation persists it.
- Task deletion is available from the edit modal danger zone and requires confirmation. The
  confirmation explains that task-owned branches and worktrees are deleted when present.
- Removing or replacing an already-saved repo row from task edit requires confirmation. Fresh
  unsaved rows remove immediately.
- Renaming a task never renames existing repo branches. Existing task repo rows keep their branch
  identity whether or not the worktree already exists; newly added repo rows use the current task
  id hash plus current task slug. Repos with an existing worktree keep their base branch too, and
  the base branch control is disabled in task edit.
- Selection and expanded tasks persist through app state.
- Clicking a task row selects the task terminal. Clicking the chevron expands or collapses attached
  repos. Clicking a repo row selects that repo terminal.
- Repo-less task rows do not reserve caret space. They read as a plain selectable task terminal row.
- Task label uses the shared meta scale: `--font-ui`, `--font-size-meta`, 0.08em tracking,
  weight 700.
- Task rows follow v0 spacing with the chevron aligned to the Tasks icon. Repo names align with task names.
- Task titles use `--font-ui`, `--font-size-body`, `--color-text-secondary`, weight 600.
- Repo rows use `--font-ui`, `--font-size-body`, inactive `--color-text-secondary` at 500, active
  `--color-text-primary` at 700 with `--color-accent-subtle` fill.
- Task names own the full remaining row width. Edit controls overlay the right edge on row hover or
  focus with a row-background fade, and do not reserve a layout column.
- Repo hover metadata values use `--font-mono` because branch and worktree paths are git/shell
  values.
- Task groups have a 6px gap.
- During task git work, repo selection highlight is suppressed and the task row shows a spinner.

## Deferred

- Archive task flow: task removal should become archive-first, not destructive delete. Archived
  tasks leave the active sidebar, appear in a Settings archive list, can be restored from there, and
  can be permanently deleted only from the archive view.
- Multiple terminals, tabs, and splits.
- Drag reorder.
- Diff counters, PR glyphs, checks donut.
