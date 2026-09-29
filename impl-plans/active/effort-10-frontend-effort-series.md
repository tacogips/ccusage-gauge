# EDF-10: Frontend modelEffort Series Identity, Ordering, and Request Path

**Status**: Not Started
**Plan ID**: EDF-10
**Wave**: 2
**Depends on**: EDF-04 (`src/effort.ts`, `CostRow.effort`)
**Design Reference**: `design-docs/specs/design-dashboard-dark-flat-effort-grouping.md` section 6
**Protocol**: `impl-plans/active/dashboard-dark-flat-effort-overview.md` section 3

## Purpose

Add the `modelEffort` stack mode to the pure series and request helpers:

- series identity and label, including the explicit unknown bucket;
- legend and stacking order;
- the `effortBreakdown=true` request item;
- persisted-value restore.

## Write paths

- `frontend/src/usageChartSeries.ts`
- `frontend/src/dashboardDirectoryState.ts`
- `frontend/tests/usageChart.test.ts`
- `frontend/tests/dashboardDirectoryState.test.ts`

## Non-goals

- Do not edit `App.tsx` (EDF-11), `seriesColors.ts` (EDF-09), or `api.ts`
  (EDF-04).
- No change to directory label logic.

## Changes

1. `usageChartSeries.ts`:
   - `export type StackBy = "model" | "machine" | "subdirectory" | "modelEffort";`
   - `chartSeriesIdentity`: `modelEffort` returns
     `` `${row.model}\u001f${row.effort ?? ""}` ``. Other modes are unchanged.
   - `export function modelEffortParts(identity: string): { model: string; effort?: string }`
     is the inverse. An empty effort part gives `effort: undefined`. Split on
     the **last** `\u001f`.
   - `chartSeriesLabel`: `modelEffort` returns
     `` `${model} (${effortLabel(effort)})` ``, which gives
     `"gpt-6-luna (high)"` or `"claude-opus-4-8 (unknown)"`. Import
     `effortLabel` from `./effort`.
   - `export function compareSeriesIdentities(stackBy: StackBy, a: string, b: string): number`
     - For `modelEffort`, compare by model name (`localeCompare`), then
       `effortRank`, then the effort string, so unranked values sort
       alphabetically and unknown sorts last.
     - Other modes compare `a.localeCompare(b)`. This matches today's
       `[...].sort()` result for plain ASCII identities. Verify that the
       existing tests still pass.
2. `dashboardDirectoryState.ts`:
   - `costSeriesDataPath` appends `effortBreakdown=true` only when
     `stackBy === "modelEffort"`, using the same `appendQuery` helper, and
     still appends `directoryBreakdown=true` only for `subdirectory`.
   - `restoredStackBy` accepts `"modelEffort"`.
   - `defaultStackBy` stays `"model"`.
3. `frontend/tests/dashboardDirectoryState.test.ts`: migrate both
   `seriesColor("light", "subdirectory", identity)` calls (the directory-rename
   flow) to the EDF-09 contract `seriesColor("subdirectory", identity)`. Keep
   each assertion's intent: the color is stable across the rename flow.

## Pitfalls

- EDF-09 runs in the same wave. If EDF-09 has not landed yet, only the
  rename-flow cases may fail because the old `seriesColor` signature is still
  present. Treat that as foreign breakage under overview protocol 6: retry up
  to 3 times about 2 minutes apart, then record
  `BLOCKED-BY-FOREIGN frontend/src/seriesColors.ts <error>` with the log path.
  Do not edit `seriesColors.ts`. EDF-11's full `bun test` is the proof that the
  migrated calls pass.
- Model names could contain spaces or dots. Never split the identity on
  anything but `\u001f`.
- Do not send both breakdown flags. Only one stack mode is active at a time.
- Keep the `subdirectory` identity format unchanged. Its colors and labels are
  keyed on it.

## Tests

- `frontend/tests/usageChart.test.ts`: append a `describe("modelEffort series")`.
  - A row `{model: "gpt-6-luna", effort: "high"}` has identity
    `"gpt-6-luna\u001fhigh"` and label `"gpt-6-luna (high)"`.
  - A row without effort has identity `"gpt-6-luna\u001f"` and label
    `"gpt-6-luna (unknown)"`. Its round-trip through `modelEffortParts` gives
    `effort === undefined`.
  - Sorting the identities for `[xhigh, unknown, low, turbo, high]` of one
    model gives `low, high, xhigh, turbo, unknown`. Across two models, the
    model order comes first.
  - Rows for one model with efforts high, low, and none, each with cost, give
    per-model sums across `modelEffort` identities equal to the sum under
    `model` identity for the same bucket.
  - Existing identities for `model`, `machine`, and `subdirectory` are
    unchanged. The existing tests stay green.
- `frontend/tests/dashboardDirectoryState.test.ts`:
  - `costSeriesDataPath("/api/cost-series?granularity=hourly&range=today", ["local"], {}, "modelEffort")`
    contains `effortBreakdown=true` and not `directoryBreakdown`;
  - `"model"` contains neither item;
  - `"subdirectory"` contains `directoryBreakdown=true` and not
    `effortBreakdown`;
  - `restoredStackBy("modelEffort") === "modelEffort"`;
  - `restoredStackBy("x") === "model"`;
  - the existing directory-rename color-stability test still passes with the
    migrated `seriesColor("subdirectory", identity)` call.

## Verification

```text
mkdir -p /tmp/ccusage-gauge-effort
cd frontend && bun test tests/usageChart.test.ts tests/dashboardDirectoryState.test.ts > /tmp/ccusage-gauge-effort/EDF-10-test.log 2>&1; echo "exit=$?"
cd frontend && bun run check > /tmp/ccusage-gauge-effort/EDF-10-check.log 2>&1; echo "exit=$?"; grep -E "src/(usageChartSeries|dashboardDirectoryState)\.ts" /tmp/ccusage-gauge-effort/EDF-10-check.log; echo "own-errors-grep-exit=$?"
```

Expected evidence: the tests exit 0 and `own-errors-grep-exit=1`. `App.tsx`
errors are allowed at this wave. If EDF-09 has not landed, the rename-flow
cases may fail on the old `seriesColor` signature. That is recorded as
`BLOCKED-BY-FOREIGN frontend/src/seriesColors.ts <error>`, and EDF-11's full
`bun test` is the final proof that the migrated calls pass.

## Completion criteria

- [ ] `modelEffortParts` and `compareSeriesIdentities` are exported with the
      exact signatures above.
- [ ] The tests pass, and all logs are recorded.

## Progress Log

- 2026-09-29: Plan created.
