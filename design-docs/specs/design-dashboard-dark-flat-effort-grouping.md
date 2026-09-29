# Dashboard Dark Flat Theme, Foldable Panes, Active Range Buttons, Effort Grouping, and Distinct Model Colors

**Status**: Implemented
**Source issue**: workflow-input inline issue "Dashboard: dark flat theme, foldable
panes, active range buttons, effort grouping, distinct model colors". No GitHub
issue URL, Codex-agent reference, reference repository, or Cursor CLI behavior
was supplied, so this design maps the intake directly onto the existing
ccusage-gauge architecture.
**Scope**: `frontend/src` (SolidJS SPA), `frontend/tests`,
`Sources/AppCore` usage-event parsing, reconciliation, aggregate cache,
dashboard query, dashboard UI state, and HTTP parameter parsing, plus the
regenerated `Sources/AppCore/Resources/Web` assets.
**User decisions**: `design-docs/user-qa/2026-09-29-dashboard-theme-effort-decisions.md`

## 1. Requirements Mapping

| # | Requirement | Section |
|---|---|---|
| 1 | Dark base theme on every surface, chart, form control, and the machine admin panel | 2 |
| 2 | Flat design: no border-radius, shadows, or gradients (including chart bars) | 2 |
| 3 | Square buttons with clear hover, focus, and active states | 2, 4 |
| 4 | Left pane folds horizontally on wide screens | 3 |
| 5 | Stacked top pane and responsive header fold vertically on narrow screens | 3 |
| 6 | Range preset buttons show the active state, including after restore, and never for custom ranges | 4 |
| 7 | Opt-in model + reasoning-effort grouping, with effort carried from Swift parsing to the chart and an explicit unknown bucket | 5, 6 |
| 8 | Clearly distinct model colors, vendor hue families allowed, effort shades of the model color | 7 |

## 2. Dark Flat Theme

### Baseline and root cause context

`frontend/src/styles.css` hard-codes a light theme. A dark variant is layered on
top with 33 `:root[data-color-scheme="dark"] ...` override selectors. The scheme
is chosen by localStorage key `ccusage-gauge-color-scheme` or by
`prefers-color-scheme`, and a toggle in the stats actions switches it
(`App.tsx:404-408`, `:530-534`, `:1476-1488`). The stylesheet has 47
`border-radius` declarations (pill buttons use `999px`), 11 `box-shadow`s, two
body `radial-gradient`s, and a `drop-shadow` filter on `.cost-bar`. The SVG
chart uses `rx="2"` on bar rects and `rx="7"` on the tooltip (`App.tsx:297`,
`:334`). `uno.config.ts` contains only `presetUno()`, and no component uses
Uno rounded, shadow, or gradient utilities.

### Behavior

- Dark is the only theme. The light theme, the scheme toggle, and the
  `data-color-scheme` attribute are removed. Any stored
  `ccusage-gauge-color-scheme` value is ignored and not read. This is the
  default decision recorded in the user-QA file. Supporting light as well would
  double the flat restyle surface without an accepted requirement.
- Colors are defined once as CSS custom properties on `:root`: background,
  surface, raised surface, border, text, muted text, accent, accent text,
  danger, warning, focus ring, chart grid, chart axis, and tooltip. Component
  rules reference only these tokens. No per-scheme override selectors remain.
- `:root` declares `color-scheme: dark`, so native date inputs, selects,
  scrollbars, and checkboxes render dark. Inputs, selects, and checkboxes
  use `accent-color` and square corners.
- Contrast: body text and interactive labels reach at least a 4.5:1 contrast
  ratio against the surface they sit on. Muted text, borders of interactive
  controls, and chart axis labels reach at least 3:1.
- Flat design: every `border-radius` declaration is `0` (or removed). There
  are no `box-shadow`s, `text-shadow`s, gradients, or `filter: drop-shadow` on
  any element. Elevation and grouping use 1px token borders and surface-color
  steps. The SVG bar rects and the tooltip rect use `rx="0"` (or omit `rx`),
  and legend swatches are square.
- `MachineAdminPanel.tsx`, `DashboardComponents.tsx` (loading state, machine
  health panel, breakdown bars), the metric table, banners, the config
  `<details>` menu, and the custom-range calendar all use the same tokens and
  flat rules.
- Existing high-contrast stale/unavailable machine states keep a distinct
  warning or danger token so they stay distinguishable from normal state on the
  dark background.
- `uno.config.ts` is left unchanged unless implementation shows a preset
  default (preflight) reintroducing radius or shadow on rendered elements.

### Buttons

All `<button>` elements share one base rule: square corners, 1px token border,
surface background, and token text. The states are:

- hover: raised-surface background;
- `:focus-visible`: 2px solid focus-ring outline with an offset (never a
  shadow);
- `:active` (pointer down): a darker surface step;
- disabled: muted text and `cursor: not-allowed`;
- pressed/selected (`aria-pressed="true"`): accent background with accent
  text, and a visible border change so the state does not rely on hue alone.

The pressed rule has specificity at least equal to every base or group button
rule, so no later group rule can hide it (see section 4). Pill shapes are
removed from the range, agent, granularity, metric, stack, machine-action, and
admin buttons.

## 3. Foldable Panes

### Baseline

`.app-shell` is a two-column grid (`245px minmax(0,1fr)`, `styles.css:13`).
The header (`App.tsx:1375-1435`) holds the title, the config `<details>` menu,
and `.period-control` (range buttons, refresh status, custom calendar). At
`max-width: 1180px` the header stacks into a column. At `max-width: 980px` the
grid collapses to one column and the sidebar becomes a static block above the
content. No fold state exists today.

### Behavior

Two persisted booleans drive folding. Both default to `false` (expanded):

- `sidebarCollapsed` applies to the filter pane in every layout.
  - Wide layout (above 980px): a visible toggle at the top of the sidebar
    collapses it horizontally to a narrow rail. The rail shows only the expand
    toggle and a vertical or abbreviated "Filters" label. The grid column
    shrinks to the rail width, and the main content, including the scrollable
    chart viewport, takes the freed width through grid reflow. The chart has no
    JS width measurement today (it scrolls horizontally). Any width-dependent
    logic added during the split must react to container resize, not only to
    window resize.
  - Narrow layout (980px and below): the stacked pane collapses vertically to a
    single full-width bar. The bar shows the expand toggle and a summary of how
    many filters are active.
- `headerCollapsed` applies only while the header is in its stacked layout
  (1180px and below). A toggle collapses the header vertically to one row: the
  title, the active range label, and the expand toggle. Above 1180px the toggle
  is hidden and the header always renders expanded, whatever the stored value.

Rules common to both toggles:

- A toggle is a `<button>` with `aria-expanded`, `aria-controls` pointing at
  the controlled region, and an accessible label ("Collapse filters", "Expand
  filters", "Collapse header", "Expand header").
- Collapsed content is hidden from layout and from the tab order. Its
  component state is kept, and collapsing never changes filter, range,
  directory, or machine selections, so the data queries are unaffected.
- Folding is instant. A CSS transition is optional and must not animate
  `border-radius` or add shadows.
- Collapsing the header while the custom-range editor is open hides the
  editor without applying or discarding its draft.

## 4. Range Preset Active State (bug)

### Root cause

The markup already sets `classList={{ active: range() === value }}`
(`App.tsx:1413-1417`), and the comparison is correct. `styles.css:107`
(`.range-buttons button.active`, specificity 0,2,1) is overridden by the
dark-scheme rule at `styles.css:257`
(`:root[data-color-scheme="dark"] .range-buttons button`, specificity 0,3,1).
That rule resets the background and text color, and no dark `.active` override
exists. The same rule hides the agent-button active state, and a sibling rule
(`:271`) hides the granularity-button active text color. Dark mode is the
default whenever the OS prefers dark, so the bug is visible by default.

### Behavior

- Every toggle-group button declares its pressed state with `aria-pressed`
  (`"true"` or `"false"`). The groups are range presets, Custom, agent,
  granularity, chart metric, and stack mode. The single shared pressed rule
  from section 2 styles `[aria-pressed="true"]`. The legacy `.active` class
  may be kept only if it carries no conflicting styles.
- Exactly one range button is pressed at a time:
  - a preset (`recent12h`, `today`, `yesterday`, `week`, `month`) is pressed
    only when `range()` equals that preset;
  - Custom is pressed only when `range() === "custom"`.
- Opening the custom editor while a preset is applied does not press Custom.
  Instead the Custom button exposes the open editor with `aria-expanded`.
  Applying a custom range sets `range()` to `custom`, so no preset stays
  pressed.
- Restored state: the range restored from `GET /api/dashboard-state` feeds the
  same signal, so the restored preset (or Custom) is pressed after reload with
  no special handling.
- The pressed decision is a pure exported helper, for example
  `rangeButtonPressed(range, button)`, so it can be unit tested.

## 5. Effort Capture and Data Flow (Swift)

### Source facts

- Codex: each rollout `turn_context` line carries the model and the reasoning
  effort in effect for that turn, at `payload.effort` (`"minimal"`, `"low"`,
  `"medium"`, `"high"`, `"xhigh"`, or absent or `null` when the model has no
  reasoning setting). Effort can change between turns in one session, exactly
  like `model`. The implementation plan's first Swift step confirms the key
  against a sanitized current rollout sample and records it in a test fixture.
  If the key differs, only the decoded key name changes. The contract below
  does not.
- Claude: `ClaudeUsageEvents.swift` decodes only `type`, `timestamp`,
  `sessionId`, `requestId`, `cwd`, and `message` (`id`, `role`, `model`,
  `usage`). Claude Code transcript lines are not known to record a
  reasoning-effort level. In this change, every Claude event has
  `effort == nil` and falls into the unknown bucket. Parsing a Claude field is
  out of scope unless the plan's verification of a current transcript finds a
  recorded effort key (see the user-QA open question).
- SSH machines: remote collection uses only `ccusage` aggregates and has no
  event loaders, so all remote rows have `effort == nil`.
- `ccusage` aggregate rows (daily metrics and fallback sessions) never carry
  effort.

### Normalization

A decoded effort is trimmed and lowercased. It is kept only if it matches
`[a-z0-9_-]{1,32}`. Anything else (absent, `null`, empty, or non-matching)
becomes `nil`. Effort is opaque provenance: it is never used as a path,
command, or log value.

### Parsing (`CodexUsageEvents.swift`)

Effort follows `model`, not `directory`:

- `CodexScanContext` gains `effort: String?`.
- A `turn_context` with a non-empty model sets `context.model` and sets
  `context.effort` to the normalized `payload.effort`. A `turn_context` without
  an effort resets `context.effort` to `nil`. Effort is not inherited from an
  earlier turn.
- In the forward parser, in resume from a cached scan context, and in the
  reverse rescan, token counts get the effort of the same `turn_context` that
  names their model. The reverse scan records the effort alongside the model
  for each pending batch, and also captures the effort in effect at the end of
  the file, next to `contextModel`. This makes a later resume of appended lines
  attribute the right effort.
- Forward, reverse, and resumed scans produce identical `(identity, model,
  effort)` associations for the same file.
- `TimestampedUsageEvent` gains `effort: String?` (default `nil`). Its
  `identity` does not change: effort never affects deduplication.
- `UsageEventFileScanCache` is in-memory only (`UsageEventFileScanCache.swift`),
  so it needs no persisted schema change. It carries the new event field and
  context field automatically.

### Records, reconciliation, and merge keys

- `CCUsageSessionMetricRecord` gains optional `effort`. It is decoded with
  `decodeIfPresent`, and the synthesized encoder omits it when `nil`, so earlier
  encoded snapshots and caches decode as unknown. `CCUsageClient` copies
  `effort` wherever it already re-stamps `directory` when setting `machine`.
- The record that carries session-derived daily rows in the query layer (today
  `CCUsageMetricRecord` from `aggregateSessions`) carries an optional effort in
  the same way. Daily authoritative `ccusage` metrics never carry effort, and
  `daily_metrics` gains no effort column.
- Reconciliation (`Snapshot.swift` `reconciledTimestampedSessions`) keeps
  splitting the authoritative daily cost and tokens by the existing
  per-event weights within `(day, agent, model)`. Each per-event record carries
  the event's effort, and the 15-minute bucket key adds effort. Per-model totals
  are therefore identical to the pre-change totals. Only the bucket
  granularity gains the effort dimension.
- The session merge and coalescing keys (`MultiSourceUsageCoalescing.swift`
  `SessionCoalesceKey`, `CostSnapshotMerge.swift` `SessionRowKey`) include
  effort, with `nil` as a distinct identity. Otherwise two effort rows could
  collapse or be deduplicated.
- `Snapshot.swift` is 966 lines. If the change would reach 1000 lines,
  reconciliation moves into a new `Snapshot+Reconciliation.swift` extension
  file with no behavior change.

### Aggregate cache (`AggregationCache.swift`)

- `session_metrics` gains a nullable `effort TEXT` column through the existing
  idempotent `hasColumn` plus `ALTER TABLE` migration pattern. Reads and writes
  bind it with `bindOptional`, and the session ordering adds it as a final
  tie-breaker.
- Backfill reuses the existing directory-provenance mechanism rather than adding
  a new coverage table. In the same transaction that adds the `effort` column
  to the cache owned by the reserved `local` machine id, the migration clears
  `directory_coverage_ranges`. The next snapshot load then treats historical
  days as provenance-unscanned. It replaces each day's derived session
  partition from the currently available event logs, now with effort, using the
  existing atomic replace, rollback, and retry contract from
  `architecture.md` ("Project-directory dimension and filtering"). Authoritative
  daily rows are never rewritten, so unfiltered totals do not change before,
  during, or after the backfill.
- Caches owned by SSH machines add the column without clearing coverage. Their
  rows have no event provenance, and a reset would only force a pointless
  full-history remote refetch.
- Days whose event logs no longer exist keep `effort == nil` (unknown). No data
  is dropped.
- The migration runs once. The column's presence is the idempotency marker, so
  later launches never clear coverage again.

### Query and HTTP contract

- `GET /api/cost-series` accepts an optional single query item
  `effortBreakdown=true|false`. The validation rules match `directoryBreakdown`:
  - at most one occurrence;
  - only `true` or `false`;
  - accepted only on `/api/cost-series`.
  Anything else returns `400` with code `invalid_breakdown` and the fixed
  message "effortBreakdown must be true or false".
  - Parsing is added to the existing `dashboardDirectoryRequest`
    (`DashboardDirectoryAPI.swift`). `DashboardDirectoryRequest` gains
    `effortBreakdown: Bool`, and a distinct error case keeps
    `invalid_directory` unchanged for directory errors.
  - The parsed value flows through the existing `directoryRequest` plumbing in
    `HTTPService` and `MachineDashboardRouter`.
  - `MachineDashboardRouter.swift` is 998 lines. The error-to-response mapping
    for the new case goes into a shared helper in an extension or API file, so
    the router stays under 1000 lines.
- Omitted or `false`: responses are unchanged from pre-change behavior, with the
  same rows, row count, grouping, and totals. The sub-daily paths
  (`15min`, `hourly`, `6hour`) collapse effort out of the session rows, both in
  the non-directory `collapsedSessions` path and in the directory-resolved
  path, so the finer effort buckets never leak into existing responses.
- `true`:
  - Sub-daily rows keep effort-distinct session rows.
  - Daily rows use the session-derived `aggregateSessions` path grouped by
    `(day, agent, model, machine, [directory if directory-resolved], effort)`,
    the same way `directoryBreakdown` selects session-derived daily rows.
  - Directory filters and `directoryBreakdown` compose independently with
    `effortBreakdown`.
  - Totals equal the non-breakdown totals for the same scope. For daily, this
    follows from the existing reconciliation guarantee that session-derived
    daily rows match the aggregate totals.
- `DashboardCostRow` gains optional `effort`, encoded only when present and only
  when `effortBreakdown=true`. With the breakdown on, a row without `effort` is
  the explicit unknown bucket. `/api/metrics`, `/api/budget`, the metric table,
  and the breakdown panel stay model-only and unchanged.

### Dashboard UI state (`DashboardStateStore.swift`)

- The accepted `stackBy` values become `model`, `machine`, `subdirectory`, and
  `modelEffort`, in both the decode coercion and `validate()`. Missing or
  unknown values still fall back to `model`, so model-only remains the default.
- `DashboardUIState` gains `sidebarCollapsed: Bool` and
  `headerCollapsed: Bool`. They are decoded with `decodeIfPresent`, default to
  `false`, and are always encoded. Rows persisted before this change decode
  unchanged.

## 6. Effort Grouping (Frontend)

- `StackBy` (`usageChartSeries.ts`, `api.ts`) adds `modelEffort`. The stack
  control renders a fourth button labeled "Model + effort". `restoredStackBy`
  accepts it, and the default stays `model`.
- `costSeriesDataPath` (`dashboardDirectoryState.ts`) appends
  `effortBreakdown=true` only while `stackBy === "modelEffort"`. It keeps
  appending `directoryBreakdown=true` only for `subdirectory`. Switching the
  stack mode refetches cost series exactly as the subdirectory mode does today.
- Series identity is `` `${model}\u001f${effort ?? ""}` ``. Series across
  machines merge by model and effort, as model mode merges by model. The label
  is `` `${model} (${effort})` ``, or `` `${model} (unknown)` `` when effort is
  absent.
- Legend and stacking order: by model name first, then by effort rank
  `minimal < low < medium < high < xhigh`. Unranked effort values follow
  alphabetically, and `unknown` comes last.
- Summing all `modelEffort` series for a model in a bucket gives the same value
  as that model's `model` series for the same query scope.
- The model filter keeps filtering by `row.model`, so it selects all effort
  variants of the chosen models.

## 7. Distinct Model Colors

### Baseline defect

`seriesColors.ts` returns `palette[scheme][kind][stableHash(`${kind}:${key}`) % 8]`.
Two models can hash to the same slot, and neighboring palette hues are close.
This produces near-identical colors such as the reported sol and luna models.
User overrides from `/api/chart-colors` (configuration `chartColors`) win per
key.

### Behavior

- Only the dark palette remains. The SPA uses the configured `dark.models` and
  `dark.machines` overrides and ignores `light`. The server configuration and
  `/api/chart-colors` contract are unchanged.
- Vendor classification from the model name (case-insensitive):
  - names containing `claude` are `anthropic`;
  - names starting with `gpt-`, `codex`, or `o` followed by a digit are
    `openai`;
  - everything else is `other`.
- Each vendor owns a curated dark-theme family in a separate hue region:
  - `anthropic`: warm reds, oranges, and ambers;
  - `openai`: greens, teals, cyans, and blues;
  - `other`: violets and magentas.
  Each family has at least 5 colors. Within a family, every pair of colors
  differs by CIE76 deltaE >= 20. Every color reaches at least 3:1 contrast
  against the chart background.
- Allocation removes hash collisions within the model catalog:
  - The catalog is the sorted distinct model names of the currently loaded
    period rows for the current machine scope. It is the same list the sidebar
    model filter shows, and it does not depend on which models are checked.
  - Models are processed in sorted order per vendor. Each takes its preferred
    slot `stableHash(model) % familySize`, or else the next free slot by
    deterministic linear probing.
  - While a vendor has no more models than its family has slots, every model
    gets a unique color.
  - Past capacity, slots are reused in the same probe order. This is documented
    in code, not an error.
  - A configured override takes precedence and does not consume a slot.
- Stability: the same catalog always yields the same colors across reloads.
  Adding or removing a model can move only models whose preferred slot is
  contested, and the colors do not depend on filter selections. This
  set-dependence is intentional and documented in `seriesColors.ts`.
- Effort shades: an effort series uses the model's allocated (or overridden)
  base color, adjusted in lightness while keeping hue:
  - lightness increases with effort rank: `minimal` darkest, then `low`,
    `medium` equal to the base color, `high`, and `xhigh` lightest;
  - unranked values map deterministically to an intermediate step;
  - `unknown` is the base color with strongly reduced saturation.
  Any two effort variants of one model differ by deltaE >= 11.
- The machine and subdirectory color namespaces keep their current
  hash-based assignment, using only the dark palette. The breakdown bars keep
  using the model allocator.

## 8. Frontend Module Boundaries

`App.tsx` is 1580 lines and is split by responsibility. It must end with fewer
lines than before, and no new logic is added to it inline. The minimum
extractions are:

- `UsageChart.tsx`: the `Bars` SVG chart component (today `App.tsx:86-361`),
  with flat `rx="0"` rects.
- `RangeControls.tsx`: range preset buttons, the Custom toggle, and the
  custom calendar, using the pure `rangeButtonPressed` helper.
- `DashboardLayout.tsx` (or an equivalently named module): the fold shell,
  meaning the sidebar and header fold toggles and collapsed renderings, fed by
  the persisted fold signals.
- `seriesColors.ts` holds vendor classification, allocation, and effort
  shading. `usageChartSeries.ts` holds the `modelEffort` identity, label, and
  order.

Persistence stays in the existing `GET`/`PUT /api/dashboard-state` flow
(`dashboardStatePersistence.ts` orchestration plus the `App.tsx` save effect).
The payload adds `sidebarCollapsed` and `headerCollapsed`, and `stackBy` may
be `modelEffort`. A missing field restores to `false` or `model`.

## 9. Validation and Tests

Swift (`Tests/AppCoreTests`, extending the existing suites):

- Codex effort decoding:
  - effort present;
  - mid-session change;
  - a `turn_context` without effort resets it to `nil`;
  - normalization and rejection of invalid values;
  - forward, reverse, and resume parity (`UsageEventIncrementalScanTests`).
- Claude events carry `effort == nil`.
- Reconciliation splits buckets by effort while leaving per-model and total
  cost and tokens unchanged.
- Coalescing and snapshot-merge keep rows that differ only in effort
  (`MultiSourceUsageCoalescingTests`).
- Aggregate cache:
  - the column is added idempotently;
  - the local cache clears provenance coverage exactly once;
  - an SSH-machine cache does not clear coverage;
  - effort round-trips;
  - a pre-change database decodes as `nil`;
  - unfiltered totals are unchanged across the backfill.
- `costSeries`:
  - omitted or `false` `effortBreakdown` gives rows identical to a pre-change
    baseline at every granularity, with and without directory filters and
    breakdown;
  - `true` gives effort-distinct rows, and totals equal the non-breakdown
    totals.
- HTTP `effortBreakdown` validation on both `HTTPService` and
  `MachineDashboardRouter`: duplicate, invalid value, and non-cost-series route
  each return `400`.
- `DashboardUIState`:
  - `modelEffort` accepted and round-tripped;
  - an unknown `stackBy` falls back to `model`;
  - fold fields are missing-tolerant and round-trip.

Frontend (`frontend/tests`):

- `seriesColors.test.ts`:
  - vendor classification;
  - a catalog containing the reported sol and luna models gets distinct colors;
  - uniqueness up to family capacity;
  - same catalog gives the same colors;
  - override precedence without slot consumption;
  - the family deltaE and contrast thresholds, computed from the palette
    constants;
  - effort shade ordering, distinctness, and the unknown shade.
- `usageChart.test.ts`:
  - `modelEffort` identity, labels, the unknown bucket, and sort order;
  - per-model sums across effort series equal the model-mode series.
- `dashboardDirectoryState.test.ts`: `effortBreakdown=true` is sent only for
  `modelEffort`, and `restoredStackBy` accepts `modelEffort`.
- `api.test.ts`: the optional `effort` field decodes.
- `dashboardStatePersistence.test.ts` (or the module that owns restore):
  missing fold fields restore to expanded.
- The range helper test covers preset pressed, Custom pressed only for the
  custom range, restored-state range, and editor-open-without-apply.
- A stylesheet guard test reads `src/styles.css` and asserts:
  - no non-zero `border-radius`;
  - no `box-shadow` other than `none`;
  - no `gradient(`;
  - no `drop-shadow`;
  - no `data-color-scheme` selectors.
  It also asserts the chart module renders no non-zero `rx`.

Gate commands, in order, with the frontend build run last before commit:

```text
swift build
swift test --filter IncrementalScanTests
swift test --filter Directory
swift test --filter MultiSourceUsageCoalescingTests
swift test --filter CacheLifecycleTests
swift test --filter DashboardStateStoreTests
swiftlint lint <changed Swift files>
mise run frontend:test
mise run frontend:check
mise run test
mise run lint
mise run frontend:build
```

The exact suite that holds each new Swift test is the implementation plan's
choice. The filters above name the existing suites to extend. Optional E2E
evidence: run `swift run ccusage-gauge serve` and capture screenshots at desktop
(about 1440px) and narrow (about 800px) widths, covering expanded and collapsed
panes, a pressed preset after reload, and `modelEffort` stacking.

## 10. Rollout Constraints and Risks

- Regenerated `Sources/AppCore/Resources/Web` assets are committed only from a
  final `mise run frontend:build` run after all frontend edits, so stale bundles
  are not committed.
- On the first launch after upgrade, the local cache performs one provenance
  backfill of historical days whose event logs still exist, the same cost as the
  earlier directory migration. SSH machines are not refetched.
- Effort splits sub-daily buckets into more session rows in memory and in the
  cache (at most one row per effort value per bucket). Responses without
  `effortBreakdown` collapse them, so their payload size does not change.
- Removing the light theme is a visible change. It is recorded as a reversible
  default in the user-QA file.
- Color allocation depends on the catalog. It is stable for a fixed catalog and
  documented in code.
- Out of scope: effort filters, effort in `/api/metrics` or budget, Claude
  effort parsing without a verified source field, remote event transport, and
  light-theme parity.
