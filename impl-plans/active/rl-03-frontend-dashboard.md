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
- `frontend/src/machineAdminControls.ts` (new; checkpoint amendment 1)
- `frontend/src/MachineAdminPanel.tsx` (checkpoint amendment 1; import change
  only)
- `frontend/tests/machineAdminPanel.test.ts` (checkpoint amendment 1; import
  specifier only)
- `impl-plans/active/rl-03-frontend-dashboard.md` (Progress Log only)

## Checkpoint Amendment 1: Pre-Existing frontend:test Failure (IR-M1)

**Context.** `mise run frontend:test` exits 1 with or without this plan's
changes. The one failure is `frontend/tests/machineAdminPanel.test.ts`, which
fails to load with
`SyntaxError: Export named 'jsxDEV' not found in module .../solid-js/dist/solid.js`.

- Baseline evidence: the failure reproduces at checkpoint a2f1a92
  (`tmp/subscription-rate-limits-20261031/reconcile-wave-001/baseline-frontend-test.log`,
  line 7) and on the combined tree
  (`tmp/subscription-rate-limits-20261031/reconcile-wave-001/frontend-test.log`).
- Cause: the test imports the pure function `machineControlsDisabled` from the
  `.tsx` module `frontend/src/MachineAdminPanel.tsx`. Under the bun 1.4.4 pin
  from b754cd2, bun transpiles that module with a dev JSX runtime that
  solid-js does not provide. This cause is inferred, not proven.

The integration review assigned this fix to rl-03. Without it, the required
`frontend:test` gate can never pass.

**Changes (smallest behavior-preserving fix):**

1. Create `frontend/src/machineAdminControls.ts`, a plain `.ts` file with no
   JSX. Move the existing
   `export function machineControlsDisabled(inFlight: Record<string, boolean>, machineID: string)`
   into it with an identical signature and body.
2. In `frontend/src/MachineAdminPanel.tsx`, delete the moved function and
   import it from `./machineAdminControls`. Re-export it
   (`export { machineControlsDisabled } from "./machineAdminControls";`) so any
   existing import path keeps compiling. The rendered markup and button
   `disabled` bindings stay unchanged.
3. In `frontend/tests/machineAdminPanel.test.ts`, change only the import
   specifier, from `../src/MachineAdminPanel` to `../src/machineAdminControls`.
   Leave every `describe`, `test` and `expect` line byte-identical.

**Invariants and forbidden changes:**

- Do not delete, skip, or weaken any machineAdminPanel assertion.
- Do not change `mise.toml` or the bun pin, and do not add `bunfig.toml` or
  other JSX/test configuration.
- Do not touch any other test file or any file owned by another plan.
- If the test still fails after the import change, record the exact error in
  the Progress Log. Do not guess at configuration changes.

**Verification (this amendment):**

- `git diff a2f1a92 -- frontend/tests/machineAdminPanel.test.ts > tmp/subscription-rate-limits-20261031/rl-03/machine-admin-test-diff.log 2>&1`
  must show exactly one changed line: the import specifier.
- `mise run frontend:test` must exit 0, the machineAdminPanel test must pass,
  the total test count must be at least 136, and there must be 0 failures and
  0 errors.

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
- [ ] Amendment 1: `mise run frontend:test` exits 0 with 0 failures.
  `machine-admin-test-diff.log` shows only the import specifier changed.
  `machineControlsDisabled` lives in `frontend/src/machineAdminControls.ts`.
- [ ] The branch output includes `checkpointProvenance` and `evidencePaths`
  (RF-3).

## Progress Log

- 2026-10-31: Plan created.

- 2026-10-31: Implemented dashboard contracts, normalization helpers, local rate-limit panel, selectable flat pies, shielded fetch and state persistence. Design alignment and no dependencies confirmed.
- Verification on the moving shared tree: `mise run frontend:check` exit 0; `cd frontend && bun test tests/rateLimits.test.ts tests/appMarkupGuards.test.ts` exit 0 (8 passed); `mise run frontend:test` exit 1 (135 passed, 1 failed: `tests/machineAdminPanel.test.ts` cannot import `jsxDEV` from Solid); App.tsx 1344 lines, limit check exit 0; generated Web status check exit 0. Logs: `tmp/subscription-rate-limits-20261031/rl-03/`. The aggregate failure concerns an existing test and component outside this plan's write paths; serial owner must investigate and rerun the aggregate. Formal reviews and final integration remain downstream.

- 2026-10-31: Checkpoint amendment 1 completed: moved `machineControlsDisabled` unchanged to `frontend/src/machineAdminControls.ts`, imported and re-exported it in `MachineAdminPanel.tsx`, and changed only the test import specifier. The earlier aggregate failure is resolved. On the shared tree, `mise run frontend:check` exited 0; `mise run frontend:test` exited 0 (136 passed, 0 failed); `cd frontend && bun test tests/machineAdminPanel.test.ts tests/appMarkupGuards.test.ts` exited 0 (4 passed). App.tsx is 1344 lines and the <=1375 check exited 0; Web asset status check exited 0 with no changes; `git diff a2f1a92 -- frontend/tests/machineAdminPanel.test.ts` exited 0 and shows only the import change. Evidence: `tmp/subscription-rate-limits-20261031/rl-03/amendment-*.log` and `machine-admin-test-diff.log`. Formal review and integration remain downstream.
