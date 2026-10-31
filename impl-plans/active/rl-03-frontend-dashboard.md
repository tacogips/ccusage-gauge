# rl-03: Dashboard Rate-Limit Panel and Selectable Pie Charts (frontend)

**Status**: Planned
**Wave**: 1 (no dependencies; uses the JSON contract pinned in the overview)
**Design Reference**: `design-docs/specs/design-subscription-rate-limits.md`,
sections Dashboard Frontend and Pie Chart Selection

## Intent and Context

The SolidJS dashboard (`frontend/src`, built with bun and vite, tested with
`bun test`) gains three things:

1. a rate-limit panel showing remaining percent and time to reset for the
   Claude Code and Codex 5h and weekly windows;
2. a pie chart section that shows several selected pies at once;
3. a toggle control that chooses the pies. The choice is persisted in the
   existing dashboard state (`pieCharts`) and defaults to `["budget"]`.

The dashboard has no pie chart today; the budget appears only as text in
`section.budget-note`, near `frontend/src/App.tsx:1322`.

## Non-Goals

- No change to existing range, filter, chart, or machine behavior.
- No change to the `budget-note` text.
- No rendering of `otherWindows`.
- No new persistence endpoint.
- Do not build assets. Do not run `bun run build`, `mise run frontend:build`,
  or `mise run build`. rl-09 regenerates `Sources/AppCore/Resources/Web`.

## writePaths

- `frontend/src/api.ts`
- `frontend/src/rateLimits.ts` (new; pure helpers)
- `frontend/src/RateLimitPanel.tsx` (new)
- `frontend/src/PieChartPanel.tsx` (new)
- `frontend/src/App.tsx`
- `frontend/src/styles.css`
- `frontend/tests/rateLimits.test.ts` (new)
- `impl-plans/active/rl-03-frontend-dashboard.md` (Progress Log only)

## Contract and File-Level Changes

### api.ts

- `PieChartID = "budget" | "claude5h" | "claudeWeekly" | "codex5h" | "codexWeekly"`.
- `RateLimitWindow`: `{ kind: "fiveHour" | "weekly" | "other"; windowSeconds: number; usedPercent: number; remainingPercent: number; resetsAt?: string | null }`.
- `ProviderRateLimits`: `{ provider: "claude" | "codex"; status: "ok" | "stale" | "unauthorized" | "unavailable"; errorCode?: string | null; message?: string | null; planType?: string | null; fetchedAt?: string | null; stale: boolean; fiveHour?: RateLimitWindow | null; weekly?: RateLimitWindow | null; otherWindows: RateLimitWindow[] }`.
- `RateLimitsResponse`: `{ generatedAt: string; scope: "local"; providers: ProviderRateLimits[] }`.
- `DashboardUIState` gains `pieCharts?: PieChartID[]`.

### rateLimits.ts

Pure functions, unit-tested:

- `pieChartIds`: the canonical order array.
- `normalizePieCharts(value: unknown): PieChartID[]` follows the same rules as
  the Swift side: unknown values dropped, duplicates removed, canonical order,
  and empty becomes `["budget"]`. A missing value also gives `["budget"]`.
- `togglePieChart(id, selection)` cannot empty the selection.
- `rateLimitWindowFor(id, response)` returns
  `{ provider?: ProviderRateLimits; window?: RateLimitWindow | null }`.
  `claude5h` maps to the Claude `fiveHour` window, `codexWeekly` to the Codex
  `weekly` window, and so on.
- `formatResetIn(resetsAt, now: Date): string` produces, for example,
  `"resets in 2h 13m"`, `"resets in 3d 4h"`, or `"resets in <1m"`. It returns
  `"reset time unknown"` for a null or invalid input and `"reset due"` when
  the time has passed.
- `rateLimitStatusLabel(provider, now)`:
  - `unauthorized` gives `"Sign in again with the CLI"`;
  - `stale` gives `"as of <local time of fetchedAt>"`;
  - `unavailable` gives `provider.message ?? "Unavailable"`;
  - `ok` gives `""`.
- `pieFraction(window)` is `min(max(usedPercent, 0), 100) / 100`.

### RateLimitPanel.tsx

- Props: the rate-limit response accessor, an error flag, and a `now`
  accessor.
- It shows two provider blocks, "Claude Code" and "Codex", labeled as this
  Mac's account.
- Each block has 5h and Weekly rows with remaining percent, the reset text,
  and the status label.
- A request error gives one panel-level "Rate limits unavailable" message.

### PieChartPanel.tsx

- Props: selection, `onToggle`, the budget response, and the rate-limit
  response.
- It renders the selected pies in canonical order as flat SVG: no
  border-radius, shadows, or gradients, following
  `design-dashboard-dark-flat-effort-grouping.md` and the existing
  `styles.css` tokens.
  - The budget pie uses `budget.visualFraction`. When that is null it shows
    an empty ring and "No budget set".
  - A rate-limit pie with no window shows an empty ring and its status label.
- It renders five toggle `<button>` elements with
  `aria-pressed={selected}`. When only one pie is selected, its button is
  `disabled`.

### App.tsx

Wiring only; no new business logic.

- A `pieCharts` signal, initialized to `["budget"]`.
- In the `initializeDashboardState` `apply` callback, call
  `setPieCharts(normalizePieCharts(state.pieCharts))`.
- Add `pieCharts: pieCharts()` to the state object in the save
  `createEffect`.
- Declare the rate-limit resource and shield it immediately (PR-M1). This
  mirrors `budget` at `App.tsx:196-197`:
  `const [rateLimitsResource, { refetch: refreshRateLimits }] = createResource(() => getJSON<RateLimitsResponse>("/api/rate-limits"));`
  `const rateLimits = shieldResource(rateLimitsResource);`
  `shieldResource` is already imported from `./dashboardLoadingState` at
  `App.tsx:31`.
- Pass only the shielded `rateLimits` accessor to `RateLimitPanel` and
  `PieChartPanel`. The panel's error flag is `rateLimits.error != null`.
  `PieChartPanel` receives the existing shielded `budget` accessor.
- Refetch the rate limits wherever `refreshBudget()` is refetched on the
  timer and manual refresh paths. Use
  `Promise.resolve(refreshRateLimits()).catch(() => undefined)`, because
  Solid's `refetch` does not always return a Promise and a bare `.catch`
  fails `tsc`. A rejection therefore can never reject the surrounding
  `Promise.all`.
- Mount `PieChartPanel` and `RateLimitPanel` immediately before
  `section.budget-note`.

### styles.css

Minimal flat classes for the two panels and the toggle buttons.

## Key Pitfalls

- Rate-limit loading and errors must NOT feed the existing loading state,
  `errorMessage`, `hasFailedRequest`, or `isFetching` memos (around
  `App.tsx:340-375`). The rest of the dashboard must behave exactly as
  before when `/api/rate-limits` fails or returns 503.
- Never read `rateLimitsResource()` directly anywhere: not in JSX, not in
  memos, and not in props. Reading an errored Solid resource re-throws the
  error, and this app has no ErrorBoundary (see the comment in
  `frontend/src/dashboardLoadingState.ts:4-8`). An unshielded read would let
  one failed `/api/rate-limits` request freeze the whole dashboard. Use only
  the `rateLimits` value returned by `shieldResource`.
- Treat a missing key the same as `null` (use `== null`).
- Persisted state from older saves has no `pieCharts`; normalize it to
  `["budget"]`.
- `frontend/tests/appMarkupGuards.test.ts` checks the App markup. Keep it
  passing; never weaken its assertions.
- `App.tsx` is already 1330 lines. Keep additions to roughly 40 lines; all
  logic belongs in the new files.

## Patterns to Imitate

- `frontend/src/dashboardLayoutState.ts:restoredFoldState` for restore
  normalization.
- `frontend/tests/dashboardLayoutState.test.ts` for the `bun:test` style.
- `frontend/src/RangeControls.tsx` for `aria-pressed` buttons.

## Test Cases (frontend/tests/rateLimits.test.ts)

- `normalizePieCharts(undefined)` -> `["budget"]`.
- `normalizePieCharts(["codexWeekly","x","claude5h","claude5h"])` ->
  `["claude5h","codexWeekly"]`.
- `normalizePieCharts([])` -> `["budget"]`.
- `togglePieChart("budget", ["budget"])` -> `["budget"]`.
- `togglePieChart("codex5h", ["budget"])` -> `["budget","codex5h"]`.
- `rateLimitWindowFor("codexWeekly", sample)` -> the Codex `weekly` window.
  With `weekly: null` -> `window == null`.
- `formatResetIn` with now `12:00Z` and resetsAt `14:13Z` ->
  `"resets in 2h 13m"`. With null -> `"reset time unknown"`. With a past time
  -> `"reset due"`.
- `rateLimitStatusLabel` for each of the four statuses -> the expected
  string.
- `pieFraction` with `usedPercent` 120 -> 1. With 47 -> 0.47.
- Source-guard test (PR-M1). Read `../src/App.tsx` with `readFileSync`, as
  `frontend/tests/appMarkupGuards.test.ts:2-5` does, then assert:
  - the source contains `shieldResource(rateLimitsResource)`;
  - the line that defines `errorMessage` (the `dashboardErrorMessage(` call)
    does not contain `rateLimits`;
  - the `hasFailedRequest:` line does not contain `rateLimits`;
  - the `isFetching:` line does not contain `rateLimits`;
  - `rateLimitsResource(` (a raw read) appears nowhere in the source.

## Verification

1. `mise run frontend:check`: exit 0 (tsc --noEmit).
2. `mise run frontend:test`: exit 0, including the new suite (with the
   App.tsx shield source guard) and `appMarkupGuards.test.ts`.
3. `wc -l frontend/src/App.tsx`: at most about 1375 lines; record the value.
4. `git status --short Sources/AppCore/Resources/Web`: empty output (assets
   untouched).

## Done Criteria

- [ ] The contract types and functions exist with the exact names.
- [ ] All the listed tests pass.
- [ ] The rate-limit resource is read only through
  `shieldResource(rateLimitsResource)`, and the source-guard test passes.
- [ ] Verification 1-4 recorded in the Progress Log with exit codes.

## Progress Log

- 2026-10-31: Plan created.
