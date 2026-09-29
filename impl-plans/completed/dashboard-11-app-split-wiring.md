# EDF-11: App.tsx Split, Range Active State, Fold Shell, and Wiring

**Status**: Completed
**Plan ID**: EDF-11
**Wave**: 3
**Depends on**: EDF-02, EDF-03, EDF-04, EDF-08, EDF-09, EDF-10
**Design Reference**: `design-docs/specs/design-dashboard-dark-flat-effort-grouping.md` sections 2 (theme removal), 3, 4, 6, 7 (color wiring), 8
**Protocol**: `impl-plans/completed/dashboard-dark-flat-effort-overview.md` section 3; CSS and markup contract in section 4

## Purpose

`frontend/src/App.tsx` has 1580 lines. This plan splits it by responsibility
and wires the new behavior:

- dark-only theme, with the light/dark toggle removed;
- the range preset active state, using `aria-pressed`;
- sidebar and header fold toggles, persisted;
- the "Model + effort" stack mode;
- the new model color allocator and effort shades.

After this plan, `bun run check` must exit 0.

## Write paths

- `frontend/src/App.tsx`
- `frontend/src/UsageChart.tsx` (new)
- `frontend/src/RangeControls.tsx` (new)
- `frontend/src/rangeControls.ts` (new)
- `frontend/src/DashboardLayout.tsx` (new)
- `frontend/src/dashboardLayoutState.ts` (new)
- `frontend/index.html`
- `frontend/tests/rangeControls.test.ts` (new)
- `frontend/tests/dashboardLayoutState.test.ts` (new)
- `frontend/tests/appMarkupGuards.test.ts` (new)

## Non-goals

- Do not edit `styles.css` (EDF-03), `seriesColors.ts` (EDF-09),
  `usageChartSeries.ts` or `dashboardDirectoryState.ts` (EDF-10), `api.ts`
  (EDF-04), or any Swift file.
- If a contract symbol is missing or wrong, record `BLOCKED-BY-FOREIGN` rather
  than editing another plan's file.
- Do not change data-fetch semantics, polling, machine admin flows, or
  directory rename flows. Only move code verbatim where a split requires it.
- Do not run `mise run frontend:build`. That belongs to EDF-12.

## Changes

1. **Extract the chart.** Move the `Bars` component (today `App.tsx:86-361`)
   to `src/UsageChart.tsx` as the exported `UsageChart`, with the props it
   uses today, minus `colorScheme` and `colorOverrides`. Add
   `colorForSeries: (identity: string) => string`.
   - Legend and series ordering use
     `[...].sort((a, b) => compareSeriesIdentities(props.stackBy, a, b))`
     instead of a plain `.sort()`.
   - The bar `rect` and the tooltip `rect` use `rx="0"`.
   - Keep the other logic identical: bucketing, lazy-load, tooltip, markers,
     and gaps.
2. **Extract the range controls.**
   - `src/rangeControls.ts` takes the `QuickRange` and `Range` types and the
     `quickRanges` list from `App.tsx:57-63`. It exports
     `rangeButtonPressed(current: Range, button: Range): boolean`, which is
     `current === button`, and
     `rangeSummaryLabel(range: Range, applied: { start: string; end: string }): string`.
     For a preset the summary is its label. For custom it is `Custom start to end`.
   - `src/RangeControls.tsx` renders the preset buttons and Custom in a
     container with `class="range-buttons toggle-group"`. Each button has
     `aria-pressed={String(rangeButtonPressed(range, value))}`. Custom has
     `aria-pressed={String(range === "custom")}` and
     `aria-expanded={String(isCustomEditorOpen)}`. The component also renders
     the existing custom calendar markup. Props are signals and callbacks from
     App: `range`, `select`, the editor-open state and setter, and the custom
     start, end, and apply values.
   - Remove `isCustomEditorOpen()` from Custom's pressed state. This is a
     design decision: Custom is pressed only for a custom range.
3. **Build the fold shell.**
   - `src/dashboardLayoutState.ts` exports
     `restoredFoldState(state: Partial<DashboardUIState> | undefined): { sidebarCollapsed: boolean; headerCollapsed: boolean }`.
     It returns `true` only for a literal `true`.
   - `src/DashboardLayout.tsx` exports `PaneFoldBar` (props `collapsed`,
     `onToggle`, `summary`) and `HeaderFoldBar` (props `title`, `rangeLabel`,
     `collapsed`, `onToggle`). Both render exactly the markup contract in
     overview section 4:
     - classes `pane-fold-bar`, `fold-toggle`, `pane-fold-summary`,
       `header-fold-bar`, `header-range-summary`, and `header-fold-toggle`;
     - `aria-expanded`;
     - `aria-controls` of `usage-filters-content` or
       `dashboard-header-content`;
     - accessible labels "Collapse filters", "Expand filters",
       "Collapse header", and "Expand header".
   - In `App.tsx`:
     - add `sidebarCollapsed` and `headerCollapsed` signals, both `false`;
     - `div.app-shell` gets `classList={{ "sidebar-collapsed": sidebarCollapsed() }}`;
     - the sidebar content is wrapped in `div#usage-filters-content.model-sidebar-content`,
       preceded by `PaneFoldBar`;
     - the header gets `classList={{ "header-collapsed": headerCollapsed() }}`,
       with the title in `HeaderFoldBar` and the config menu plus
       `.period-control` inside `div#dashboard-header-content.header-content`.
   - The pane summary is `Filters` plus the count of filter dimensions
     (models, agents, machines, directories) that currently exclude at least
     one available choice. Derive the count from existing memos.
4. **Persistence.** In the `initializeDashboardState` `apply` callback (today
   `App.tsx:1050-1061`), apply `restoredFoldState(state)`. Add
   `sidebarCollapsed: sidebarCollapsed()` and
   `headerCollapsed: headerCollapsed()` to the PUT payload (today
   `App.tsx:1081-1091`). Folding never changes any filter or range signal.
5. **Theme removal.**
   - Delete the `colorScheme` signal and `initialColorScheme`,
     including the localStorage key `ccusage-gauge-color-scheme` and the
     `prefers-color-scheme` read.
   - Delete the effect writing `document.documentElement.dataset.colorScheme`
     and the toggle button (today around `App.tsx:404-408`, `:530-534`, and
     `:1476-1488`).
   - Remove the `ColorScheme` import.
   - In `frontend/index.html`, set `<meta name="color-scheme" content="dark" />`.
6. **Colors.**
   - Create a memo:
     `modelColor = createMemo(() => allocateModelColors(models(), chartColors()?.dark?.models))`,
     where `models()` is the existing sorted catalog memo at `App.tsx:503`.
   - `colorForMachine(m)` is `seriesColor("machine", m, chartColors()?.dark?.machines)`.
   - Chart `colorForSeries` by stack mode:
     - `model`: `modelColor()(id)`;
     - `machine`: `colorForMachine(id)`;
     - `subdirectory`: `seriesColor("subdirectory", id)`;
     - `modelEffort`: split `id` with `modelEffortParts`, then
       `effortShade(modelColor()(model), effort)`.
   - Breakdown bars use `modelColor()` for models and `colorForMachine` for
     machines.
7. **Stack mode.**
   - The stack toggle container gets `class="stack-toggle toggle-group"`, and
     the fourth button is "Model + effort" (`setStackBy("modelEffort")`).
   - Every stack button has `aria-pressed`.
   - The chart title maps stack values to readable text:
     `model` to "model", `machine` to "machine", `subdirectory` to
     "subdirectory", and `modelEffort` to "model + effort".
8. **Other toggle groups.** The agent, granularity, and chart-metric button
   containers get the additional class `toggle-group`, and their buttons get
   `aria-pressed`. The existing `classList` `active` may stay.
9. **Size.** The final `wc -l frontend/src/App.tsx` must be below 1580. The
   target is 1350 or less. Any new logic goes into the new modules, not inline
   in `App.tsx`.

## Pitfalls

- Solid reactivity: pass accessors or props, not unwrapped values captured
  once, into the extracted components. Otherwise pressed state and fold state
  will not update.
- A restored `range` comes from `GET /api/dashboard-state`. The pressed state
  must derive from the same `range()` signal, not a separate "selected button"
  signal.
- `aria-pressed` must be the string `"true"` or `"false"`. Do not omit it for
  the false case.
- Hidden collapsed regions come from CSS `display: none` (EDF-03). Do not
  unmount them. Unmounting would reset component state such as rename editors
  and the custom-range draft.
- Keep `id="usage-filters-content"` and `id="dashboard-header-content"` unique.

## Tests

- `frontend/tests/rangeControls.test.ts`:
  - `rangeButtonPressed("today", "today")` is `true`, and
    `rangeButtonPressed("today", "yesterday")` is `false`;
  - for the current range `"custom"`, every preset returns `false` and Custom
    returns `true`;
  - for a restored `"week"`, only `week` is pressed;
  - `rangeSummaryLabel` covers a preset label and the custom format.
- `frontend/tests/dashboardLayoutState.test.ts`:
  - `undefined` gives both flags `false`;
  - `{}` gives both flags `false`;
  - `{ sidebarCollapsed: true }` gives `true` and `false`;
  - `{ headerCollapsed: "yes" as any }` gives `headerCollapsed: false`.
- `frontend/tests/appMarkupGuards.test.ts` reads the sources as text and
  checks:
  - `src/UsageChart.tsx` has no `rx="` other than `rx="0"`;
  - `src/App.tsx` contains none of `colorScheme`, `dataset.colorScheme`,
    `ccusage-gauge-color-scheme`, or `prefers-color-scheme`;
  - `src/RangeControls.tsx` contains `aria-pressed` and `toggle-group`;
  - `src/App.tsx` contains `"modelEffort"` and `sidebarCollapsed`;
  - `index.html` contains `content="dark"`.

## Verification

```text
mkdir -p /tmp/ccusage-gauge-effort
cd frontend && bun test > /tmp/ccusage-gauge-effort/EDF-11-test.log 2>&1; echo "exit=$?"
cd frontend && bun run check > /tmp/ccusage-gauge-effort/EDF-11-check.log 2>&1; echo "exit=$?"
cd frontend && bun run build > /tmp/ccusage-gauge-effort/EDF-11-vite-build.log 2>&1; echo "exit=$?"
wc -l frontend/src/App.tsx
```

`bun run build` writes only to the git-ignored `frontend/dist`. It proves the
bundle compiles.

Expected evidence:

- the full frontend test run exits 0;
- the typecheck exits 0 with no errors anywhere;
- the vite build exits 0;
- `App.tsx` has fewer than 1580 lines.

## Completion criteria

- [x] All new modules exist with the exported names above.
- [x] `grep -c "aria-pressed" frontend/src/App.tsx frontend/src/RangeControls.tsx`
      reports at least one match in each file.
- [x] `bun test` exits 0 (115 tests, 0 failures).
- [x] `bun run check` exits 0.
- [x] `bun run build` exits 0.
- [x] `frontend/src/App.tsx` is below 1580 lines (1320).
- [x] Complete logs recorded at `/tmp/ccusage-gauge-effort/EDF-11-test.log`,
      `/tmp/ccusage-gauge-effort/EDF-11-check.log`, and
      `/tmp/ccusage-gauge-effort/EDF-11-vite-build.log`.

## Progress Log

- 2026-09-29: Plan created.
- 2026-09-30: Extracted `UsageChart`, range controls/helpers, and fold layout
  state/components. Wired dark-only model/machine/subdirectory/effort colors,
  model+effort stacking, pressed range/group state, fold restore/persistence,
  and mounted fold regions. Removed runtime theme selection and set the HTML
  color-scheme metadata to dark.
- 2026-09-30: `bun test` passed 115/115 across 20 files;
  `bun run check` and `bun run build` exited 0. `App.tsx` is 1320 lines.
  Exact logs: `/tmp/ccusage-gauge-effort/EDF-11-test.log`,
  `/tmp/ccusage-gauge-effort/EDF-11-check.log`, and
  `/tmp/ccusage-gauge-effort/EDF-11-vite-build.log`.
- 2026-09-30: Explicit `.ts`/`.tsx` import suffixes disambiguate the required
  `rangeControls.ts` and `RangeControls.tsx` names on the case-insensitive
  macOS filesystem; focused TS5097 suppressions preserve the project check.
