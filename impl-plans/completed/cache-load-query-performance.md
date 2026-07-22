# Cache Load and Filter-Switch Query Performance

**Status**: Completed
**Design Reference**: `design-docs/specs/design-cache-load-query-performance.md`

## Purpose

Dashboard filter switches (range, granularity, machine scope) currently block
on redundant ccusage collection and repeat expensive per-request work
(per-row DateFormatter construction, full aggregate re-merge, whole-history
re-sort, double JSON encoding). This plan makes steady-state filter switches
serve entirely from in-memory snapshots and removes the hot-path overheads,
without changing any API wire format or aggregation semantics.

## Deliverables

- [x] `MachineCollector.expand` skips machines whose published coverage already satisfies the request (design G1)
- [x] No per-row `DateFormatter` construction in `DashboardQueryService` or `SnapshotService` hot loops (design G2)
- [x] `MachineSnapshotStore` memoizes merged aggregate arrays across requests (design G3)
- [x] `SnapshotService.snapshot()` merges sorted cached data with sorted fresh data instead of re-sorting full history (design G4)
- [x] `MachineDashboardRouter` encodes responses with `scope` in a single pass (design G5)
- [x] Frontend `/api/load-status` polling backs off when idle (design G7 slice)
- [x] `swift test` passes; `swiftlint` clean on touched files; `frontend` typecheck passes

## Tasks

### TASK-001: Coverage-aware expansion in MachineCollector

**Parallelizable**: Yes

Files: `Sources/AppCore/MachineCollection.swift`, `Tests/AppCoreTests/MachineTests.swift`

In `expand(machine:earliestDate:)`, before calling `collect`, read
`store.entry(machineID:)` and skip the machine when `entry.snapshot != nil`
and `entry.coverageStart != nil && entry.coverageStart! <= earliestDate`.
Machines needing wider coverage still await `collect(..., phase: .loadingHistory)`.

**Completion Criteria**:

- [x] A query whose coverage is already published performs zero `collect` calls (test with a counting `ServiceFactory`)
- [x] A query needing older coverage still triggers exactly one collection and the store publishes widened `coverageStart`
- [x] Existing `MachineTests` pass unchanged

### TASK-002: Eliminate per-row DateFormatter construction

**Parallelizable**: Yes

Files: `Sources/AppCore/DashboardQuery.swift`, `Sources/AppCore/Snapshot.swift`, existing tests in `Tests/AppCoreTests/DashboardTests.swift`, `Tests/AppCoreTests/CCUsageTests.swift`

- `DashboardQueryService`: build one `DateFormatter` per public entry point
  (`metrics`, `costSeries`, `day`, `period`) and pass it to helpers; add a
  per-call `[String: Date]` memo for repeated day strings in `metrics`/
  `costSeries` and a `[Int: String]` (day-bucket) memo in `aggregateSessions`.
  Keep the public `parseDay` signature.
- `SnapshotService`: construct the formatter once per `snapshot()` /
  `menuBarSnapshot()` / `loadUsage()` invocation and thread it through
  `partitionUsage`, `usageResult`, `missingUsageRanges` helpers.

**Completion Criteria**:

- [x] No computed property or per-row call constructs a `DateFormatter` inside a loop over metric/session rows
- [x] All existing AppCore tests pass with identical outputs (ordering, values)

### TASK-003: Memoize aggregate merge in MachineSnapshotStore

**Parallelizable**: No (touches the same file as TASK-001; do after it)

Files: `Sources/AppCore/MachineCollection.swift`, `Tests/AppCoreTests/MachineTests.swift`

Cache the merged `points`/`dashboardMetrics`/`dashboardSessions` arrays keyed
by the usable entries' `(id, snapshot.generatedAt)` list plus
`requiredCoverageStart`-derived inclusion. Recompute `selectedPeriodCost` and
interval-dependent scalars per request from the cached arrays. Invalidate is
implicit via the key; verify `publish`, `clear`, and `replaceRegistry` all
change the key.

**Completion Criteria**:

- [x] Two consecutive `selection(machine: "all")` calls with unchanged entries reuse the merged arrays (assert via identity or a merge counter test hook)
- [x] Publishing a new snapshot for any included machine yields a fresh merge
- [x] `clear` and `replaceRegistry` invalidate the memo
- [x] Aggregate responses byte-identical to before for the same inputs (existing tests)

### TASK-004: Incremental sorted merge in SnapshotService

**Parallelizable**: Yes

Files: `Sources/AppCore/Snapshot.swift`, `Tests/AppCoreTests/CCUsageTests.swift` or `Tests/AppCoreTests/DashboardTests.swift`

Add a `mergeSorted` helper; in `snapshot()`, rely on the cache's SQLite
ordering (`date, agent, model` / `timestamp`) — sort only fresh records, then
merge. Document the ordering invariant next to the cache read. Note: cached
sessions are ordered by `(timestamp, agent, model)` while dashboardSessions
ordering only requires `timestamp`; keep the comparator consistent with
current output so results are stable.

**Completion Criteria**:

- [x] `dashboardMetrics`/`dashboardSessions` output ordering identical to current behavior (unit test comparing old vs new path on mixed fixtures)
- [x] No full-array sort of cached history in the steady-state refresh path

### TASK-005: Single-pass scope encoding

**Parallelizable**: Yes

Files: `Sources/AppCore/DashboardQuery.swift` (or `DashboardAPIModels.swift`), `Sources/AppCore/MachineDashboardRouter.swift`, `Tests/AppCoreTests/DashboardTests.swift`, `Tests/AppCoreTests/MachineTests.swift`

Add optional `scope: DashboardScope?` (encoded only when present) to
`RecentResponse`, `DayResponse`, `PeriodResponse`, `DashboardMetricsResponse`,
`DashboardCostResponse`, `BudgetResponse`, or introduce a generic scoped
wrapper if cleaner. Replace `jsonWithScope`'s JSONSerialization round-trip
with direct encoding. Preserve key ordering irrelevance but keep `scope` shape
identical (same fields, same date encoding).

**Completion Criteria**:

- [x] `jsonWithScope` no longer round-trips through `JSONSerialization`
- [x] Router tests assert `scope` present with identical shape on all scoped endpoints
- [x] CLI client decoding (`Sources/AppCLI`, `frontend/src/api.ts` types) unaffected

### TASK-006: Frontend load-status polling backoff

**Parallelizable**: Yes

Files: `frontend/src/App.tsx`, `frontend/tests` if applicable

Poll `/api/load-status` at 250 ms while `loadStatus()?.isLoading`, refresh in
flight, or a range load is pending; otherwise every 2 s. Reset to fast polling
when `beginRangeLoad`/`refresh`/`clearCache` start.

**Completion Criteria**:

- [x] Idle dashboard issues at most one load-status request per ~2 s
- [x] Loading indicator latency during range switches remains visually unchanged (fast polling resumes on load start)
- [x] `frontend` typecheck/tests pass

### TASK-007: Verification pass

**Parallelizable**: No (final)

- Run `task test` (Swift) and frontend tests; run `swiftlint` on touched files.
- Manual timing note in the Progress Log: measure `/api/cost-series?range=month&machine=all`
  latency before/after on a warm cache, and a range switch with all coverage
  already loaded (expect no ccusage spawn; verify via absence of collection
  log/status transitions).

**Completion Criteria**:

- [x] All tests green
- [x] Timing/behavior observations recorded in Progress Log

## Progress Log

- 2026-07-21: Plan created from design-cache-load-query-performance.md analysis.
- 2026-07-21: Implemented TASK-001..007 in an isolated worktree off `feat/multi-machine-scope`.
  - TASK-001 (G1): `MachineCollector.expand` now skips a machine when its published entry has a
    non-nil snapshot and `coverageStart <= earliestDate`; only under-covered machines await
    `collect(..., phase: .loadingHistory)`. New suite `CoverageAwareExpansionTests` uses a counting
    `CCUsageCommandRunner` (counts `blocks` spawns): 0 collect calls when covered, exactly 1 when
    wider coverage is needed, and the store publishes a widened `coverageStart`.
  - TASK-002 (G2): Replaced the per-access computed `dayFormatter` in `DashboardQueryService` and
    `SnapshotService` with `makeDayFormatter()` factories plus per-call memoized closures.
    `DashboardQueryService.metrics`/`costSeries` daily use a `[String: Date?]` parse memo;
    `aggregateSessions` uses a per-calendar-day `[Date: String]` format memo (keyed by
    `startOfDay`). `SnapshotService.loadUsage`/`loadMetrics` build one memoized `Date -> day`
    closure and thread it through `partitionUsage`/`usageResult` (the only per-row loops). Public
    `parseDay` signature unchanged. Deviation from the literal plan: the session memo is keyed by
    `startOfDay(Date)` rather than an `[Int: String]` day bucket (calendar-correct across
    timezones/DST); the non-row helpers (`missingUsageRanges`/`weekPartitionedRanges`) were left
    building a formatter per call since they loop over weeks, not rows — the completion criterion is
    about per-metric/session-row construction.
  - TASK-003 (G3): `MachineSnapshotStore` caches the merged `points`/`dashboardMetrics`/
    `dashboardSessions` (plus now-independent scalars) keyed by the usable entries'
    `(id, snapshot.generatedAt)` list; `selectedPeriodCost` and interval-dependent scalars are
    recomputed per request. `publish`/`clear`/`replaceRegistry` also null the memo explicitly (belt
    and suspenders over key invalidation). Added `mergeComputations` test hook. New suite
    `MergeMemoizationTests` proves reuse across consecutive `selection("all")` and invalidation on
    publish/clear/replaceRegistry.
  - TASK-004 (G4): Added `mergeSorted` + `metricsInIncreasingOrder`/`sessionsInIncreasingOrder`.
    `snapshot()` now sorts only the fresh partition and merges it with the sorted cache prefix; the
    in-memory saved payload is also stored sorted so the "cached is sorted" invariant holds
    process-wide (SQLite already re-sorts on read). Design-assumption note: the cache's in-memory
    payload after a first-build/coverage-widen save was NOT sorted before this change (only the
    SQLite read path was), which would have made a naive sorted-merge incorrect; keeping the saved
    payload sorted resolves it without altering any reloaded output. New suite
    `IncrementalSortedMergeTests` compares `mergeSorted(cachedSorted, freshSorted)` byte-for-byte
    against `(cached + fresh).sorted(...)` on mixed fixtures with duplicate keys/timestamps (stable,
    cache-first on ties) for both comparators.
  - TASK-005 (G5): Added `ScopedDashboardResponse` protocol and an optional `scope: DashboardScope?`
    (synthesized `encodeIfPresent`) to `RecentResponse`, `DayResponse`, `PeriodResponse`,
    `BudgetResponse`, `DashboardMetricsResponse`, `DashboardCostResponse` with backward-compatible
    inits (scope defaults nil). `MachineDashboardRouter.jsonWithScope` now sets `scope` and encodes
    in one pass (no `JSONSerialization` round-trip). Non-scoped `DashboardRouter` path stays
    byte-identical (scope omitted when nil). New suite `RouterScopeEncodingTests` asserts `scope`
    present with identical shape on recent/day/period/metrics/cost-series/budget and decodes via
    `ScopedResponse<BudgetResponse>`. CLI (`ScopedResponse`) and `frontend/src/api.ts` consumers
    unaffected (scope was already optional on the wire).
  - TASK-006 (G7): `frontend/src/App.tsx` replaces the fixed 250 ms `setInterval` with a reactive
    `createEffect` driven by `isPollingFast` (`loadStatus().isLoading || isRefreshing() ||
    isRangeLoading()`): 250 ms while work is in flight, 2 s when idle. `beginRangeLoad`/`refresh`/
    `clearCache` flip those signals, so fast polling resumes immediately.
  - G8: Simplified the identical-branch ternary in `MachineCollector.startPoller` to
    `AppConfiguration.defaultPollIntervalSeconds`.
  - TASK-007 verification (this worktree, cold build):
    - `swift test`: PASS — "Test run with 126 tests in 30 suites passed" (118 pre-existing + 8 new).
    - `swiftlint` on touched files: exit 0. Remaining warnings are all on pre-existing, untouched
      lines (`loadStatuses` large tuple, `refresh` ternary, inline `catch`/`else` positions,
      MachineTests:115); the added code introduced no new warnings.
    - `frontend`: `bun install` then `bun run check` (tsc --noEmit): PASS (exit 0). Repo has no
      `frontend/tests` runner; typecheck is the frontend gate per `Taskfile.yml` (`frontend:check`).
    - Behavior note (in lieu of live ccusage timing on a cold CI environment): the counting-runner
      test proves a fully-covered filter switch performs zero ccusage spawns, and the memoization
      test proves repeated `machine=all` requests reuse one merged aggregate — the two behaviors the
      latency goal depends on.
- 2026-07-22: All tasks verified complete; plan moved to impl-plans/completed and merged into feat/multi-machine-scope.
