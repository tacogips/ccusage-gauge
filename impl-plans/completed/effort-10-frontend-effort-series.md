# EDF-10: Frontend modelEffort Series Identity, Ordering, and Request Path

**Status**: Completed
**Plan ID**: EDF-10
**Wave**: 2
**Depends on**: EDF-04 (`src/effort.ts`, `CostRow.effort`)
**Design Reference**: `design-docs/specs/design-dashboard-dark-flat-effort-grouping.md` section 6
**Protocol**: `impl-plans/completed/dashboard-dark-flat-effort-overview.md` section 3

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

- [x] `modelEffortParts` and `compareSeriesIdentities` are exported with the
      exact signatures above.
- [x] The focused tests pass, and all implementation logs are recorded.

## Progress Log

- 2026-09-29: Plan created.
- 2026-09-29: Implementation intent snapshot before source edits. Existing-file SHA-256 values: `frontend/src/usageChartSeries.ts` `0b8338c9bfeebde305aa46848162bb3712587552cd155b624291b6e21da700a8`; `frontend/src/dashboardDirectoryState.ts` `c57f825e630a0be9887c990540985fee97704a75b7c85e95df6aeeec710f0ecb`; `frontend/tests/usageChart.test.ts` `f1411cf119434c04be0efbf4b97e66aa5da109a2bc254b513f53180a21f7a119`; `frontend/tests/dashboardDirectoryState.test.ts` `3a05ca0e8a3f7161f592d748e49b6d8f708e4f54f513ef0d71c10983d39d45a5`; plan pre-edit SHA-256 `e6c6d20c5764ae05f25611a8ea27c71c90417f2a96444b0007ebc813e90c02b3`. Intended edits: add modelEffort identity, last-separator parser, label, and comparator to `usageChartSeries.ts`; gate request and restore behavior in `dashboardDirectoryState.ts`; add contract tests to both owned test files and migrate exactly two rename-flow color calls; record exact verification and post-edit hashes here. Exact per-file intent is preserved in `tmp/dashboard-dark-flat-effort-20260929/EDF-10/attempt-1/edit-intents.json`.
- 2026-09-29: Implemented EDF-10. `usageChartSeries.ts` now represents model+effort with model/U+001F/effort identity, splits at the last separator, labels missing effort as `unknown`, and sorts model first then effort rank/string; other stack modes retain localeCompare ordering. `dashboardDirectoryState.ts` adds `effortBreakdown=true` only for modelEffort and restores that mode while retaining model as default. Tests cover the identity/label/parser, required ordering, total preservation, request exclusivity, restore behavior, and both rename-flow calls now use `seriesColor("subdirectory", identity)`.
- Verification: `cd frontend && bun test tests/usageChart.test.ts tests/dashboardDirectoryState.test.ts` exited 0; 22 tests passed, 0 failed (81 assertions); full log `/tmp/ccusage-gauge-effort/EDF-10-test-attempt-2.log`. `cd frontend && bun run check` exited 2 due to five existing `App.tsx` references to the old color API while EDF-11 wiring is pending; full log `/tmp/ccusage-gauge-effort/EDF-10-check-attempt-1.log`. The required own-file grep `grep -E "src/(usageChartSeries|dashboardDirectoryState)\.ts" /tmp/ccusage-gauge-effort/EDF-10-check-attempt-1.log` exited 1 (no matching errors). This is the plan's allowed waves 1-2 `App.tsx` carve-out. `git diff --check` exited 0.
- Post-edit SHA-256: `frontend/src/usageChartSeries.ts` `c7d2347268dceb26dd2f09e3cfd6f6a8a2df2982b598f978df3cccdb680a241e`; `frontend/src/dashboardDirectoryState.ts` `aadec9bc3965866b39967e08befb3aca02e9560719da6b6eb460f353492fc76c`; `frontend/tests/usageChart.test.ts` `21dbe026bc35623816223fc898c1c659d315dcdc2a3bd41bbfa925ff53c396e5`; `frontend/tests/dashboardDirectoryState.test.ts` `286b1fa4aa23744e4c9bcf430d15c9878778fa88fd8cab1a2d13e5ced32bd402`.
- Verification wrapper note: the first shell attempt used zsh's read-only `status` variable and exited before starting Bun; it has no test result. The corrected foreground run above is the source-matched passing result. Formal review, EDF-11 integration, and final asset build remain downstream workflow steps.
