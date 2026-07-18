# Spec 15 - Theming & accents

> Prerequisite: read `APP.md` §6 (esp. "The Piñata theme pattern"). Reference: theme blocks in
> `reference/src/term.css`; base tokens in `styles.css`; accent palette + `accentById` in
> `term-data.jsx`; theme/accent application in `term-app.jsx`; controls in `term-settings.jsx` +
> `term-onboarding.jsx`.

## Dependencies & links
- **Depends on:** nothing - **build this first.**
- **Consumed by:** **every** spec. Tokens (`var(--*)`) are the only allowed colors; the accent is
  set inline on `.term-desktop`. Specifically: spec 01 (accent swatches + stripe), spec 14
  (theme/accent controls, live-wired `--ui-fs`/`--density`/`--motion`), spec 05 (terminal renderer
  palette), spec 07/12 (diff colors), and all chrome.
- **Shared contract:** `PINATA_ACCENTS` + `accentById(key)` (`term-data.jsx`); theme ids
  `pinata-dark`/`pinata-light` on `data-theme`; accent applied as inline `--accent`/`--on-accent`/
  `--accent-deep`; the `theme`+`accent` **tweaks** (shared with specs 01 + 14).

## Purpose

One graphite visual system, two themes (dark + light), and **one pickable brand accent** applied
sparingly. Source of truth for tokens, contrast, the accent mechanism, and the terminal palette.
Build **first** - nothing else looks right until it exists. (The *authoring pattern* for the two
themes is codified in `APP.md` §6.1; this spec is the exact values + rules.)

## Current implementation scope

`tokens.css` owns structural tokens: fonts, spacing, radii, fixed shell sizes, swatches, swatch
muted companions, and fallbacks. `themes.css` owns theme colors, input fills, accent colors, and
accent text colors. Component and feature CSS should consume tokens, not raw color or spacing
values.

`globals.css` owns shared low-level controls such as `.uiButton`, `.uiButtonPrimary`,
`.uiButtonDanger`, `.uiButtonNaked`, `.uiButtonSmall`, and `.uiButtonIcon`; feature CSS should not
create one-off button color systems. Feature classes may only add layout details such as width,
position, or local radius.

## Principles
- **Graphite + flat.** Neutral warm-gray (dark) / paper (light) surfaces. **No elevation shadows
  anywhere.** Separation = fills, hairline borders, color.
- **Accent = the few interactive moments only** (active tab underline, active chip, focus rings,
  terminal caret, text selection, toggles/checkboxes, primary buttons). Everything else graphite.
- **WCAG AA.** Every text/background pair meets AA, tuned against the actual background it sits on.
- **Terminal is its own palette,** `.pane`-scoped so it never bleeds into chrome.

## Themes (exact tokens)

Applied as `data-theme` on `.term-desktop`; selected via the `theme` tweak
(`'Piñata Dark'`/`'Piñata Light'` → `pinata-dark`/`pinata-light`).

### Piñata Dark (`pinata-dark`)
```
--bg:#1a1c1e  --bg-deep:#151719  --code-bg:#1a1c1e
--surface:#2c3032  --surface-2:#34393b  --elevated:#2f3335
--border:#353a3c  --border-soft:#2a2e30  --muted:#4a4f52
--text:#dfe3e5  --text-dim:#c2c7c9  --text-faint:#a6aeb2  --text-ghost:#8f989d
--purple:#b9a6e0 --green:#9cd389 --yellow:#e0c06a --red:#e08a8a --red-subtle:rgba(224,138,138,.18) --orange:#d9a06a --nord9/8:#86b8c7 (cyan)
--link:#86b8c7
--add-bg:rgba(156,211,137,.14) --add-fg:#9cd389  --del-bg:rgba(224,138,138,.13) --del-fg:#e08a8a
--titlebar/--sidebar:#262a2c  --scrim:rgba(0,0,0,.55)
```

### Piñata Light (`pinata-light`)
```
--bg:#eef1f3  --bg-deep:#e1e5e8  --code-bg:#f4f6f7
--surface:#ffffff  --surface-2:#e5e9ec  --elevated:#ffffff
--border:#ccd1d6  --border-soft:#dee3e7  --muted:#a7aeb5
--text:#1a1f23  --text-dim:#39424a  --text-faint:#4a5259  --text-ghost:#62686e
--purple:#7557b9 --green:#2f7643 --yellow:#856421 --red:#a05252 --red-subtle:rgba(160,82,82,.18) --orange:#905e2b --nord9/8:#2a7284 (cyan)
--link:#2a7284
--add-bg:rgba(47,118,67,.16) --add-fg:#2f7643  --del-bg:rgba(160,82,82,.17) --del-fg:#a05252
--titlebar/--sidebar:#e7ebee  --scrim:rgba(28,34,40,.34)
```

**Why light looks the way it does:** an earlier light theme was tonally compressed (bg/surface/
surface-2/borders all near-white → nothing separated). These values widen the range: a cool-gray
desktop behind white panels, stronger borders, a darker text ramp, and **darkened semantic colors**
(green/yellow/orange) so they pass AA as text (the diff `+/−` counts were the worst).

**Contrast (measured, both themes):** text ≥ 13:1, dim ≥ ~9:1, faint ≥ ~5:1, **ghost ≥ 4.5:1 on
its real backgrounds**. Keep the 4-step ramp as a real hierarchy. Retuning a gray → re-verify vs
`--bg`, `--surface`, `--surface-2`, and `--sidebar`.

> Legacy blocks (`tokyo`, `nord`, `warp`) remain in `term.css` from earlier exploration. Only
> `pinata-dark`/`pinata-light` ship; treat the rest as dead unless deliberately revived.

## Accent

The 7 accents (`PINATA_ACCENTS`) - **vivid** brand colors, each with a legible `on` and a
deeper companion:

| key | label | color | on | deep |
|-----|-------|-------|-----|------|
| `coral` | Coral | `#FF746B` | `#36100d` | `#FF574F` |
| `teal` | Teal | `#20D6C9` | `#02211f` | `#00BFB2` |
| `gold` | Gold | `#FFD447` | `#2f2300` | `#F0B600` |
| `magenta` | Magenta | `#FF62B4` | `#351025` | `#EE3E9F` |
| `lime` | Lime | `#A7EA45` | `#162707` | `#8ED025` |
| `azure` | Azure | `#4D9DFF` | `#071f3d` | `#277FEA` |
| `mono` | Mono | `var(--text)` | `var(--bg)` | `var(--text-dim)` |

- **Default: `coral`.** **Mono** is the theme-neutral "no fun" option (auto-inverts with the theme).
- The onboarding top stripe uses the 6 chromatic accents; stripe + logo are the only full-color
  brand marks outside the chosen accent.
- Swatch hover/selected borders use each accent's deeper companion, not a shared gray border.

### Application
- Stored as the `accent` tweak. `App` resolves `accentById(t.accent)` and sets **inline vars on
  `.term-desktop`**: `--accent`/`--on-accent`/`--accent-deep`, overriding the theme's fallback. So
  theme and accent are orthogonal - any accent works on either theme.

### Where accent appears (and must not)
Appears: active tab top-border, active chip tint + accent text, selection/active rings,
terminal + input caret, text selection, toggle knobs, checkboxes, primary buttons
(`--color-accent-primary` fill + `--color-accent-text`), New Task button tint, palette
selected-row icon, "view diff" chips.
Must **not**: body text, surfaces, borders, semantic colors, the 16 ANSI terminal colors.

### Visibility (opacity, never hue)
Tints are exposed as tokens: `--color-accent-subtle`, `--color-accent-hover`,
`--color-accent-border`, `--color-accent-icon`, and `--color-selection-background`.
`accentIntensity` selects transparent, balanced, or vibrant token strengths through
`data-accent-intensity`. Too faint on some accent → **raise token strength, never change component
CSS.**

## Terminal palette (`.pane`-scoped; production = terminal renderer theme)
Higher-contrast, close to a default terminal palette, scoped to `.pane`:
- **Dark `.pane`:** `--code-bg:#1a1c1e` (matches app bg; deliberately not darker), text `#e6e9ea`,
  soft-pastel ANSI: green `#8fd9ac`, blue `#9dc0f2`, cyan `#8ad6dc`, magenta `#d4aee6`, orange
  `#eab488`, yellow `#e6d38f`, red `#f0a3a3`.
- **Light `.pane`:** `--code-bg:#ffffff`, near-black text, saturated-dark ANSI: green `#0a7a30`,
  blue `#0a4fc2`, cyan `#067173`, magenta `#9420a0`, orange `#a8530c`, yellow `#7f6200`, red
  `#c01818`.

**Terminal renderer mapping (spec 05):** `background←--code-bg`, `foreground←--text`,
`cursor←--accent`, `selection←translucent --accent`, 16 ANSI slots from the `.pane` values
(normals + brights).
Resolve tokens to hex with `getComputedStyle`. Rebuild on theme change; only bg/fg/cursor/selection
follow the accent - **never remap the 16 ANSI hues.**

## Type & motion
- **Space Grotesk** (UI/head), **JetBrains Mono** (terminal/code/labels). Chrome typography uses
  shared tokens: display clamp `24px` to `34px`, title `17.5px`, heading `14px`, body `13px`,
  meta `12px`, label `11px`.
- `--ui-fs`/`--density`/`--motion` live-wired from Settings (spec 14). Honor `--motion` +
  `prefers-reduced-motion`; functional pulses only, no decorative loops.

## Acceptance criteria
- [ ] Both themes ship with the exact token sets; switching is instant and complete (no stale
      color).
- [ ] All text/bg pairs meet WCAG AA in both themes; ghost→text is a visible hierarchy.
- [ ] No drop shadows anywhere; separation is fills/borders/color.
- [ ] Accent applied on the root, recolors only accent moments; all 7 (incl. Mono) work on both
      themes; intensity is controlled by `data-accent-intensity`; body/surfaces/semantics/ANSI
      never take the accent.
- [ ] Terminal palette is `.pane`-scoped and higher-contrast; terminal renderer mapping holds for
      production (spec 05).
- [ ] No em-dashes anywhere in CSS comments or content.
- [ ] Button colors, hover, focus, and disabled states come from shared `.uiButton*` variants,
      except for special controls such as nav rows, segmented controls, swatches, selectable list
      rows, and titlebar chrome.
