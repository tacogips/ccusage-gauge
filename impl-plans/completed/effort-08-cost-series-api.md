# EDF-08: Cost-Series effortBreakdown Query and HTTP Contract

**Status**: Completed
**Plan ID**: EDF-08
**Wave**: 2
**Depends on**: EDF-01 (record `effort` fields)
**Design Reference**: `design-docs/specs/design-dashboard-dark-flat-effort-grouping.md` section 5 (Query and HTTP contract)
**Protocol**: `impl-plans/completed/dashboard-dark-flat-effort-overview.md` section 3

## Purpose

Add the optional `effortBreakdown=true|false` query item to
`GET /api/cost-series` on both routing surfaces:

- `HTTPService`, which is local-only;
- `MachineDashboardRouter`.

When the item is `true`, cost rows are effort-distinct and carry `effort`.
When it is omitted or `false`, responses must be **identical** to pre-change
behavior.

## Write paths

- `Sources/AppCore/DashboardQuery.swift`
- `Sources/AppCore/DashboardDirectoryAPI.swift`
- `Sources/AppCore/HTTPService.swift`
- `Sources/AppCore/MachineDashboardRouter.swift`
- `Sources/AppCore/MachineDashboardRouter+DirectoryQueries.swift`
- `Tests/AppCoreTests/EffortCostSeriesTests.swift` (new)

## Non-goals

- No effort filter parameter.
- No effort in `/api/metrics`, `/api/budget`, or the metrics or breakdown rows.
- `aggregateSessions` keeps `includeEffort: false` for the metrics and budget
  paths.
- No frontend change.

## Changes

1. `DashboardQuery.swift`:
   - `DashboardCostRow`: add `public let effort: String?` as the last stored
     property. The synthesized Codable omits it when `nil`. Update both
     `DashboardCostRow(...)` constructions in `costSeries`.
   - `costSeries(...)`: add the trailing parameter
     `effortBreakdown: Bool = false`.
   - Sub-daily (`15min`, `hourly`, `6hour`), non-directory path: generalize
     `collapsedSessions` with an `includeEffort: Bool` parameter. The key adds
     `effort` only when `includeEffort` is true, and the rebuilt record passes
     it. Call it with `includeEffort: effortBreakdown`.
   - Sub-daily, directory-resolved path
     (`directoryBreakdown || !directorySelections.isEmpty`): when
     `effortBreakdown` is false, apply these rules.
     - If no input session has a non-nil effort, pass the rows through
       unchanged, exactly as today.
     - Otherwise, merge rows keyed by
       `(timestamp, agent, model, machine, dataQuality, directory)`. Sum cost
       and token fields, keep first-occurrence order, and set `effort` to `nil`.
     - When `effortBreakdown` is true, pass rows through with their effort.
   - Row field: `effort: effortBreakdown ? record.effort : nil`.
   - Daily path:
     - If `directoryResolved || effortBreakdown`, use
       `aggregateSessions(..., includeDirectory: directoryResolved, includeEffort: effortBreakdown, directorySelections:)`.
       The key gains `effort` when included, and the returned
       `CCUsageMetricRecord` carries `effort:`. The sort tie-breaker appends
       `effort ?? ""`.
     - Otherwise keep `snapshot.dashboardMetrics`.
     - Row field: `effort: effortBreakdown ? record.effort : nil`, and keep
       the existing directory logic.
2. `DashboardDirectoryAPI.swift`:
   - `DashboardDirectoryRequest` gains `let effortBreakdown: Bool`.
   - `DashboardDirectoryRequestError` gains `case invalidBreakdown`.
   - Parse `effortBreakdown` items with the same rules as `directoryBreakdown`:
     allowed only when `acceptsBreakdown`, at most one item, and the value is
     absent or `"false"`, or `"true"`. Any violation throws `.invalidBreakdown`,
     never `.invalid`.
   - Leave `directoryBreakdown` violations throwing `.invalid`, as today.
   - Add a small shared mapping,
     `func dashboardDirectoryRequestFailure(_ error: Error) -> DashboardDirectoryRequestFailure`:
     - `.machineNotFound` maps to `404`, `machine_not_found`, "Machine not found";
     - `.invalidBreakdown` maps to `400`, `invalid_breakdown`,
       "effortBreakdown must be true or false";
     - anything else maps to `400`, `invalid_directory`,
       "Invalid directory selection".
3. `HTTPService.swift`:
   - Add a `catch DashboardDirectoryRequestError.invalidBreakdown` clause, or
     route through the shared mapping.
   - Pass `effortBreakdown: directoryRequest.effortBreakdown` to both
     `costSeries` calls (around lines 657-672).
4. `MachineDashboardRouter.swift`: it is **998 lines** and must stay under
   1000.
   - Replace the two catch clauses in `queryRoute` (around lines 134-138) with
     one `catch` that uses `dashboardDirectoryRequestFailure`.
   - Pass the whole `directoryRequest` to `costResponse` instead of two
     separate arguments. This nets zero or fewer lines.
   - Put any other added logic in
     `MachineDashboardRouter+DirectoryQueries.swift`.
5. `MachineDashboardRouter+DirectoryQueries.swift`: `costResponse` accepts the
   `DashboardDirectoryRequest`, or an added `effortBreakdown: Bool`, and
   forwards it to `costSeries`.

## Pitfalls

- The **pre-change identity invariant**: for requests without
  `effortBreakdown`, rows must stay identical for snapshots whose sessions have
  no effort. That means the same rows, the same order, and the same count.
  For snapshots whose sessions do have effort, the rows equal the pre-change
  rows for the same data without effort. The daily non-breakdown path keeps
  using authoritative `dashboardMetrics`.
- Do not put effort in the `metrics` or `budget` `aggregateSessions` calls.
- The invalid-breakdown error must not reuse the `invalid_directory` code.
- `effortBreakdown` on `/api/metrics` or any non-cost-series route returns
  `400 invalid_breakdown`, because `acceptsBreakdown` is false there.
- Grep `effortBreakdown` in the final diff. Both HTTPService call sites and the
  router path must pass it through.

## Tests (`@Suite("EffortCostSeriesTests")`)

Imitate the `directoryBreakdown` query and HTTP cases in
`Tests/AppCoreTests/DirectoryFeatureTests.swift` and
`DirectoryFeatureRegressionTests.swift`. Build `CostSnapshot` fixtures
directly.

- Snapshot sessions without effort:
  - `costSeries` with `effortBreakdown` omitted equals `effortBreakdown: false`
    for granularities `15min`, `hourly`, `6hour`, and `daily`;
  - the results equal the rows produced before this change. Encode both to
    JSON and compare; there is no `effort` key.
- Snapshot sessions with effort `high`, `low`, and `nil` at the same
  timestamp, model, and machine:
  - Without the breakdown, the result is 1 row with the summed cost and no
    `effort` key. This holds with and without a directory filter and
    `directoryBreakdown`.
  - With `effortBreakdown: true`, the result is 3 rows. Two carry `effort`,
    one omits it, and their total equals the non-breakdown total.
  - For daily with `effortBreakdown: true`, rows are grouped by effort, and
    the totals equal the session-derived totals.
- `effortBreakdown: true` combined with a directory filter gives rows that are
  both directory-filtered and effort-distinct.
- HTTP on both `HTTPService` and `MachineDashboardRouter`, reusing the existing
  request helpers in the directory tests:
  - `effortBreakdown=true` returns 200 with `effort` in the JSON rows;
  - `effortBreakdown=maybe` returns 400 with `invalid_breakdown`;
  - a duplicate `effortBreakdown` item returns 400 with `invalid_breakdown`;
  - `/api/metrics?effortBreakdown=true` returns 400 with `invalid_breakdown`;
  - `directoryBreakdown=maybe` still returns 400 with `invalid_directory`.

## Verification

```text
mkdir -p /tmp/ccusage-gauge-effort
swift build > /tmp/ccusage-gauge-effort/EDF-08-build.log 2>&1; echo "exit=$?"
swift test --filter EffortCostSeriesTests > /tmp/ccusage-gauge-effort/EDF-08-test.log 2>&1; echo "exit=$?"
swift test --filter Directory > /tmp/ccusage-gauge-effort/EDF-08-directory.log 2>&1; echo "exit=$?"
swift test --filter "DashboardQueryTests|APIRouteTests" > /tmp/ccusage-gauge-effort/EDF-08-dashboard.log 2>&1; echo "exit=$?"
swiftlint lint --quiet Sources/AppCore/DashboardQuery.swift Sources/AppCore/DashboardDirectoryAPI.swift Sources/AppCore/HTTPService.swift Sources/AppCore/MachineDashboardRouter.swift "Sources/AppCore/MachineDashboardRouter+DirectoryQueries.swift" Tests/AppCoreTests/EffortCostSeriesTests.swift > /tmp/ccusage-gauge-effort/EDF-08-lint.log 2>&1; echo "exit=$?"
wc -l Sources/AppCore/MachineDashboardRouter.swift Sources/AppCore/DashboardQuery.swift Sources/AppCore/HTTPService.swift
```

Expected evidence:

- every command exits 0;
- the existing directory and dashboard suites stay green;
- `MachineDashboardRouter.swift` is at most 998 lines, and the other files are
  under 1000.

## Completion criteria

- [x] The identity-invariant tests and HTTP error-code tests pass.
- [x] `MachineDashboardRouter.swift` is under 1000 lines.
- [x] All logs recorded.

## Progress Log

- 2026-09-29: Plan created.
- 2026-09-29: Implemented optional `effortBreakdown` parsing and error mapping, cost-series effort-preserving aggregation, default-response collapse behavior, and forwarding through local and machine HTTP routes. Added `EffortCostSeriesTests.swift` covering omitted/false identity across all granularities, effort totals and unknown rows, directory filter/breakdown composition, malformed and duplicate query items, non-cost-series rejection, and both HTTP routers.
- 2026-09-29 verification on final implementation/test source: `swift build` exit 0 (`/tmp/ccusage-gauge-effort/EDF-08-build-final.log`); `swift test --filter EffortCostSeriesTests` exit 0, 5 tests (`.../EDF-08-test-final2.log`); `swift test --filter Directory` exit 0, 47 tests (`.../EDF-08-directory-final2.log`); `swift test --filter 'DashboardQueryTests|APIRouteTests'` exit 0, 17 tests (`.../EDF-08-dashboard-final2.log`); plan SwiftLint command exit 0 (`.../EDF-08-lint-final.log`) with four existing warnings in `MachineDashboardRouter.swift`. Strict selected-file SwiftLint reports those four baseline violations; the `HEAD` copy reports the same diagnostic categories, while new EDF-08 code and tests have no reported violations (`.../EDF-08-lint-strict-final.log`, baseline comparison input `tmp/dashboard-dark-flat-effort-20260929/EDF-08/attempt-1/MachineDashboardRouter.baseline.swift` and `.../EDF-08-lint-baseline.log`). Router is 995 lines.
- 2026-09-29: Earlier build attempt failed on a non-exhaustive catch and was corrected; an initial test attempt encountered a concurrent malformed `EffortReconciliationTests.swift` edit outside EDF-08, then the final focused test rerun passed after that shared file was corrected. Logs retained at `/tmp/ccusage-gauge-effort/EDF-08-build.log` and `/tmp/ccusage-gauge-effort/EDF-08-test.log`.
- 2026-09-30: Reran the assigned verification on the current shared source identity (recorded in `tmp/dashboard-dark-flat-effort-20260929/EDF-08/resume-20260930/source-identity.txt`): `swift build` exit 0; `swift test --filter EffortCostSeriesTests` exit 0 (5/5); `swift test --filter Directory` exit 0 (47/47); `swift test --filter 'DashboardQueryTests|APIRouteTests'` exit 0 (17/17); `git diff --check` exit 0. The regular selected-file SwiftLint command exited 0 with four warnings in `MachineDashboardRouter.swift`. The strict selected-file gate exited 1; its four diagnostics are existing baseline categories (the saved pre-change router has those categories plus one extra statement-position diagnostic), so no EDF-08-specific lint issue was introduced. Full logs are in `tmp/dashboard-dark-flat-effort-20260929/EDF-08/resume-20260930/`. Router remains 995 lines.
- Formal adversarial and combined-tree integration review remain assigned to downstream workflow steps.
