# EDF-04: Frontend Effort Contract

**Status**: Completed
**Plan ID**: EDF-04
**Wave**: 1
**Depends on**: none
**Design Reference**: `design-docs/specs/design-dashboard-dark-flat-effort-grouping.md` sections 5 (Query and HTTP contract), 6, 8
**Protocol**: `impl-plans/completed/dashboard-dark-flat-effort-overview.md` section 3

## Purpose

Pin the shared frontend types and effort ordering that EDF-09 (colors),
EDF-10 (series), and EDF-11 (App wiring) use in parallel.

## Write paths

- `frontend/src/effort.ts` (new)
- `frontend/src/api.ts`
- `frontend/tests/effort.test.ts` (new)
- `frontend/tests/api.test.ts`

## Non-goals

- Do not change `usageChartSeries.ts`, `dashboardDirectoryState.ts`,
  `seriesColors.ts`, or `App.tsx`.
- Do not add runtime request logic to `api.ts`. Only the type additions below
  are in scope.

## Changes

1. `frontend/src/effort.ts` exports:
   - `EFFORT_ORDER = ["minimal", "low", "medium", "high", "xhigh"] as const`;
   - `UNKNOWN_EFFORT = "unknown"`;
   - `effortRank(effort?: string): number`: the index in `EFFORT_ORDER`,
     `EFFORT_ORDER.length` for any other non-empty string, and
     `EFFORT_ORDER.length + 1` for `undefined` or an empty string;
   - `effortLabel(effort?: string): string`: returns the effort, or
     `"unknown"` for `undefined` or an empty string.
2. `frontend/src/api.ts`:
   - Add `effort?: string` to `CostRow` (currently `api.ts:56`).
   - In `DashboardUIState` (currently `api.ts:94-104`), set `stackBy` to
     `"model" | "machine" | "subdirectory" | "modelEffort"` and add optional
     `sidebarCollapsed?: boolean` and `headerCollapsed?: boolean`.
   - The fold flags stay optional so the existing `App.tsx` PUT payload keeps
     type-checking.
   - If `api.ts` has a runtime decoder or guard for cost rows or dashboard
     state (grep `CostRow` and `DashboardUIState` usage inside `api.ts`), make
     it accept and pass through the optional fields. If there is none, make no
     runtime change.

## Pitfalls

- Do not make the new `DashboardUIState` fields required. That would break
  `App.tsx` before EDF-11.
- Do not import from `usageChartSeries.ts` in `effort.ts`. It must stay
  dependency-free.

## Tests

- `frontend/tests/effort.test.ts`:
  - `effortRank("minimal") < effortRank("low") < effortRank("medium") < effortRank("high") < effortRank("xhigh") < effortRank("turbo") < effortRank(undefined)`;
  - `effortLabel(undefined) === "unknown"`, `effortLabel("") === "unknown"`,
    and `effortLabel("high") === "high"`.
- `frontend/tests/api.test.ts`: append one case. A cost-series response
  fixture with a row carrying `"effort": "high"` and a row without effort is
  returned through the existing fetch path the file already tests. The first
  row exposes `effort === "high"`, and the second has `effort === undefined`.
  Imitate the existing cost-series cases in that file.

## Verification

```text
mkdir -p /tmp/ccusage-gauge-effort
cd frontend && bun test tests/effort.test.ts tests/api.test.ts > /tmp/ccusage-gauge-effort/EDF-04-test.log 2>&1; echo "exit=$?"
cd frontend && bun run check > /tmp/ccusage-gauge-effort/EDF-04-check.log 2>&1; echo "exit=$?"; grep -E "src/(effort|api)\.ts" /tmp/ccusage-gauge-effort/EDF-04-check.log; echo "own-errors-grep-exit=$?"
```

Expected evidence:

- the tests exit 0;
- `own-errors-grep-exit=1`, meaning no type errors in `effort.ts` or `api.ts`;
- `bun run check` itself should still exit 0, because both changes are
  additive.

## Completion criteria

- [x] The exports exist with the exact names and signatures above.
- [x] The tests pass, and all logs are recorded.

## Progress Log

- 2026-09-29: Plan created.
- 2026-09-29: Implemented effort helpers, additive cost/dashboard UI types, and focused helper/API tests. `api.ts` has no runtime decoder, so no request behavior changed. `cd frontend && bun test tests/effort.test.ts tests/api.test.ts` passed 9 tests with 0 failures (log: `tmp/dashboard-dark-flat-effort-20260929/EDF-04/EDF-04-test.log`; exit 0). `cd frontend && bun run check` passed (log: `tmp/dashboard-dark-flat-effort-20260929/EDF-04/EDF-04-check.log`; exit 0); the required `grep -E "src/(effort|api)\.ts"` returned 1 because neither file had reported type errors. Review and workflow finalization remain downstream.
