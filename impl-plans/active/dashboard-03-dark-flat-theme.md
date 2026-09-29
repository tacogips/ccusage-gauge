# EDF-03: Dark Flat Theme Stylesheet

**Status**: Not Started
**Plan ID**: EDF-03
**Wave**: 1
**Depends on**: none
**Design Reference**: `design-docs/specs/design-dashboard-dark-flat-effort-grouping.md` sections 2, 3 (fold presentation), 4 (pressed style)
**Protocol**: `impl-plans/active/dashboard-dark-flat-effort-overview.md` section 3 (CSS contract in section 4)

## Purpose

Rewrite `frontend/src/styles.css` as a single dark, flat, square theme built
on CSS custom properties. Add the CSS for the pinned toggle-group pressed state
and the fold classes. EDF-11 changes the markup to match; this plan only
styles it.

Repository context:

- The light theme sits in plain rules.
- The dark theme is 33 `:root[data-color-scheme="dark"] ...` override
  selectors at `styles.css:245-277`.
- The stylesheet has:
  - 47 `border-radius` declarations, including `999px` pills;
  - 11 `box-shadow`s;
  - `radial-gradient` body backgrounds at `:5` and `:246`;
  - a `drop-shadow` filter on `.cost-bar` at `:202-203`.
- The range-button bug is caused by `:root[data-color-scheme="dark"] .range-buttons button`
  (0,3,1) overriding `.range-buttons button.active` (0,2,1).

## Write paths

- `frontend/src/styles.css`
- `frontend/src/DashboardComponents.tsx` (only if a class hook is missing; expected unchanged)
- `frontend/src/MachineAdminPanel.tsx` (only if a class hook is missing; expected unchanged)
- `frontend/tests/flatThemeStyles.test.ts` (new)

## Non-goals

- Do not touch `src/App.tsx`, `uno.config.ts`, `src/index.tsx`, or any `.ts`
  logic. EDF-11 owns App markup.
- Do not rename existing classes. Only add the contract classes listed below.
- No light theme and no `prefers-color-scheme` media query.

## Changes (`frontend/src/styles.css`)

1. The first rule is `:root { ... }`. It declares `color-scheme: dark;` and
   these tokens as 6-digit hex values:
   - pinned values: `--color-bg: #0f1115`, `--color-surface: #15171c`;
   - free values: `--color-surface-raised`, `--color-border`,
     `--color-control-border`, `--color-text`, `--color-text-muted`,
     `--color-accent`, `--color-accent-text`, `--color-danger`, `--color-warning`, `--color-focus`,
     `--color-chart-grid`, `--color-chart-axis`, `--color-tooltip-bg`;
   - `--rail-width: 44px`.
   EDF-09's contrast test assumes the chart sits on `#15171c`.
2. Every other rule references colors only through `var(--color-...)`. Hex,
   `rgb(`, and `rgba(` literals may appear only inside the `:root` block.
3. Contrast targets:
   - `--color-text` on `--color-bg` and on `--color-surface`: at least 4.5:1;
   - `--color-text-muted` on `--color-surface`: at least 3:1;
   - `--color-accent-text` on `--color-accent`: at least 4.5:1;
   - `--color-control-border` on `--color-surface` and on `--color-bg`: at
     least 3:1 (borders of interactive controls);
   - `--color-chart-axis` on `--color-surface`: at least 3:1;
   - `--color-border` on `--color-surface`: at least 1.5:1. It is for
     non-interactive separators only (cards, panels, dividers), so it stays
     visible.
4. Flat design:
   - Delete every `border-radius` or set it to `0`.
   - Delete every `box-shadow`, `text-shadow`, `filter: drop-shadow(...)`, and
     gradient.
   - Delete all `:root[data-color-scheme=...]` rules.
   - Separate surfaces with 1px `var(--color-border)` borders and background
     steps.
   - Legend swatches (`.chart-legend i` or the equivalent existing selector)
     and `.breakdown-swatch` are square.
5. Buttons. The base `button` rule has `border-radius: 0`, a 1px border using
   `var(--color-control-border)`, a surface background, and text color. States:
   - `:hover:not(:disabled)`: `--color-surface-raised`;
   - `:focus-visible`: `outline: 2px solid var(--color-focus); outline-offset: 2px`;
   - `:active`: one background step darker;
   - `:disabled`: muted text and `cursor: not-allowed`.
   Remove the group-specific background and color rules for
   `.range-buttons button`, `.agent-buttons button`, and the granularity and
   stack buttons, keeping only layout such as gap and padding. Add exactly one
   pressed rule:
   `.toggle-group button[aria-pressed="true"] { background: var(--color-accent); color: var(--color-accent-text); border-color: var(--color-accent-text) }`.
   No other rule may set `background` or `color` on buttons inside
   `.toggle-group` with equal or higher specificity. The legacy `.active` class
   may keep only non-color layout properties.
6. Form controls: `input`, `select`, `textarea`, and `details > summary` get
   square corners, token colors, and `accent-color: var(--color-accent)` for
   checkboxes. The `input`, `select`, and `textarea` borders use
   `var(--color-control-border)`. Date inputs inherit `color-scheme: dark`.
7. Chart SVG classes (`.cost-bar`, the axis, grid, and tooltip classes that
   exist today; grep `App.tsx` for the class names) use token fills and
   strokes. The tooltip background uses `--color-tooltip-bg`.
8. Fold presentation (markup contract in overview section 4):
   - Default, wide layout above 980px:
     - `.app-shell.sidebar-collapsed` sets
       `grid-template-columns: var(--rail-width) minmax(0, 1fr)`.
     - `.sidebar-collapsed .model-sidebar-content { display: none }`.
     - `.sidebar-collapsed .pane-fold-summary` is rendered vertically with
       `writing-mode: vertical-rl`.
     - `.pane-fold-bar` is a flex row, or a column while collapsed.
   - Inside `@media (max-width: 980px)`:
     - `.app-shell.sidebar-collapsed` keeps a single column.
     - `.pane-fold-bar` is a full-width horizontal bar.
     - The summary uses a normal writing mode.
     - Content stays hidden while collapsed.
   - Header:
     - `.header-fold-toggle` and `.header-range-summary` default to
       `display: none`.
     - Inside `@media (max-width: 1180px)` they are shown, and
       `header.header-collapsed .header-content { display: none }`.
     - Above 1180px the header content is always visible, whatever the class
       says.
9. Stale and unavailable machine states and error banners use `--color-warning`
   or `--color-danger` backgrounds or borders, so they stay distinct.
10. Keep the existing breakpoints (1180, 1100, 980, 700) and the
    reduced-motion rule. Fold transitions are optional and must not animate
    radius or shadow.

## Tests (`frontend/tests/flatThemeStyles.test.ts`)

The test reads `src/styles.css` as text through `import.meta.dir`, the same way
other tests read files, and checks:

- styles.css has no `border-radius` value other than `0` or `0px`, matching
  regex `border-radius\s*:\s*(?!0(px)?\s*[;}])`, which must return zero
  matches;
- no `box-shadow` or `text-shadow` other than `none`;
- no `gradient(`, no `drop-shadow`, no `data-color-scheme`;
- the stylesheet contains `color-scheme: dark`,
  `.toggle-group button[aria-pressed="true"]`, `.sidebar-collapsed`,
  `.header-collapsed`, `.pane-fold-bar`, `.header-fold-toggle`,
  `--color-control-border`, and `--color-surface: #15171c`;
- hex, `rgb(`, and `rgba(` literals appear only inside the first `:root { }`
  block;
- the WCAG contrast ratios in item 3 are met, including
  `--color-control-border` (at least 3:1 on `--color-surface` and
  `--color-bg`) and `--color-chart-axis` (at least 3:1 on
  `--color-surface`), parsing the hex tokens from
  `:root` with a small relative-luminance helper inside the test file.

## Verification

```text
mkdir -p /tmp/ccusage-gauge-effort
cd frontend && bun test tests/flatThemeStyles.test.ts > /tmp/ccusage-gauge-effort/EDF-03-test.log 2>&1; echo "exit=$?"
cd frontend && bun test tests/machineAdminPanel.test.ts > /tmp/ccusage-gauge-effort/EDF-03-admin.log 2>&1; echo "exit=$?"
cd frontend && bun run check > /tmp/ccusage-gauge-effort/EDF-03-check.log 2>&1; echo "exit=$?"; grep -E "src/(DashboardComponents|MachineAdminPanel)\.tsx" /tmp/ccusage-gauge-effort/EDF-03-check.log; echo "own-errors-grep-exit=$?"
```

Expected evidence:

- both bun tests exit 0;
- the grep for own-file type errors finds nothing (`own-errors-grep-exit=1`).
  Errors in `src/App.tsx` are allowed until EDF-11 (overview protocol 7).

## Completion criteria

- [ ] `grep -c "data-color-scheme" frontend/src/styles.css` is 0.
- [ ] `grep -c "999px" frontend/src/styles.css` is 0. The complete
      non-zero-radius check is the guard test.
- [ ] The guard test passes, and all logs are recorded.

## Progress Log

- 2026-09-29: Plan created.
