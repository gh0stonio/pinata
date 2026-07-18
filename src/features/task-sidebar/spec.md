# Task Sidebar

## Source

Based on v0 spec 03 and `reference/src/term-sidebar.jsx`.

## Current scope

- Brand header, task count, task rows, repo rows, and repo hover metadata.
- New Task button and creation modal for registered repos.
- Creating a task persists task/repo records, selects the new task, expands it, and selects its
  first repo.
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
- Each task row is one button. Clicking any hovered part toggles expand/collapse only. Repo
  selection changes only from repo rows.
- Task label uses the shared meta scale: mono `--font-size-meta`, 0.08em tracking, weight 700.
- Task rows follow v0 spacing with the chevron aligned to the Tasks icon. Repo names align with task names.
- Task titles use mono `--font-size-heading`, `--color-text-secondary`, weight 600.
- Repo rows use mono `--font-size-body`, inactive `--color-text-secondary` at 500, active
  `--color-text-primary` at 700 with `--color-accent-subtle` fill.
- Task groups have a 6px gap.

## Deferred

- Archive task flow: task removal should become archive-first, not destructive delete. Archived
  tasks leave the active sidebar, appear in a Settings archive list, can be restored from there, and
  can be permanently deleted only from the archive view.
- Real git worktree creation during task creation.
- Real cleanup for confirmed task or task-repo deletion: remove task-owned worktrees and branches
  when they exist.
- Terminal spawn after task creation.
- Drag reorder.
- Diff counters, PR glyphs, checks donut.
