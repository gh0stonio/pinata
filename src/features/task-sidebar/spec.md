# Task Sidebar

## Source

Based on v0 spec 03 and `reference/src/term-sidebar.jsx`.

## Current scope

- Brand header, task count, task rows, repo rows, and repo hover metadata.
- Selection and expanded tasks persist through app state.
- Each task row is one button. Clicking any hovered part toggles expand/collapse only. Repo
  selection changes only from repo rows.
- Task label follows v0 eyebrow: mono 10px, 0.15em tracking, weight 600.
- Task rows follow v0 spacing with the chevron aligned to the Tasks icon. Repo names align with task names.
- Task titles follow v0: mono 12.5px, `--color-text-secondary`, weight 600.
- Repo rows follow v0: mono 12px, inactive `--color-text-secondary` at 500, active
  `--color-text-primary` at 700 with `--color-accent-subtle` fill.
- Task groups have a 6px gap.

## Deferred

- New Task dialog.
- Task edit popover.
- Drag reorder.
- Diff counters, PR glyphs, checks donut.
