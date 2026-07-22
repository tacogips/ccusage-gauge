# Cache Load and Filter-Switch Query Performance

**Status**: Implemented
**Scope**: `Sources/AppCore` (SnapshotService, UsageAggregationCache, MachineCollector, MachineSnapshotStore, DashboardQueryService, MachineDashboardRouter), `frontend/src`

## 1. Question under analysis

1. Does the implementation read the aggregation cache appropriately at load time?
2. Is there remaining headroom to maximize performance at load and when the user
   switches filters (range, granularity, model, agent, machine) in the dashboard?

## 2. Findings: cache usage at load time

The cache is consulted correctly on the happy path:

- `UsageAggregationCache.load()` (`Sources/AppCore/AggregationCache.swift:57`)
  serves an in-memory payload after the first SQLite read, guarded by a
  retention check. The SQLite read returns rows pre-sorted (`ORDER BY date,
  agent, model` / `ORDER BY timestamp, agent, model`).
- `SnapshotService.snapshot()` (`Sources/AppCore/Snapshot.swift:337`) calls
  `validAggregationCache` and computes `missingUsageRanges` so ccusage is only
  invoked for days the cache does not cover (typically just "today" on steady
  state). Historical days are merged from the cache. This is correct.
- `MachineCollector.startPoller` warms week first (`loadingWeek`), then history
  (`loadingHistory`), then refreshes on an interval. Cache persistence via
  `aggregationCache.save` only rewrites when the covered range boundaries
  change (roughly daily). This is acceptable.

So the answer to question 1 is: yes, the day-bucketed metrics and session
metrics are cached and re-read appropriately. The gaps are elsewhere, listed
below in priority order.

## 3. Findings: performance gaps

### G1 (critical): every dashboard query with a coverage hint re-runs collection

`MachineDashboardRouter.queryRoute` (`Sources/AppCore/MachineDashboardRouter.swift:96`)
computes `requestedCoverageStart` for `/api/metrics`, `/api/cost-series`,
`/api/period`, `/api/day` and then unconditionally does:

```swift
if let coverage { await collector.expand(machine: requested, earliestDate: coverage) }
```

`MachineCollector.expand` -> `collect` (`Sources/AppCore/MachineCollection.swift:530`)
has **no check against the already-published `coverageStart`** of each machine
entry. Consequences:

- Every range/granularity switch in the UI (which issues fresh `/api/metrics`
  and `/api/cost-series` requests) triggers a full `service.snapshot()` per
  enabled machine: a ccusage CLI spawn (over SSH for remote machines) for the
  missing "today" range plus a `blocks` fetch for the whole week, and the HTTP
  response **awaits** all of it.
- Filter switching therefore costs seconds instead of being served purely from
  the in-memory snapshot that is already sufficient.

**Fix**: in `expand`, skip machines whose published entry already satisfies
`entry.snapshot != nil && entry.coverageStart <= earliestDate`. Only await
collection for machines that genuinely need wider coverage. Steady-state filter
switches then never touch ccusage.

### G2 (high): per-row `DateFormatter` construction in hot query loops

`DashboardQueryService.dayFormatter` (`Sources/AppCore/DashboardQuery.swift:294`)
is a computed property that builds a new `DateFormatter` on every access.
`parseDay`/`formatDay` are called once per row in:

- `metrics()` range filtering (`parseDay(row.date)` per metric row),
- `costSeries()` daily branch (`parseDay(record.date)` per row),
- `aggregateSessions()` (`formatDay(session.timestamp)` per session row).

`DateFormatter` construction costs on the order of hundreds of microseconds;
with tens of thousands of session rows this dominates every `/api/metrics` and
`/api/cost-series` response. The same computed-property pattern exists in
`SnapshotService.dayFormatter` (`Sources/AppCore/Snapshot.swift:670`), hit per
row in `partitionUsage` and `usageResult` on every collection cycle.

**Fix**: construct the formatter once per call (or use manual `yyyy-MM-dd`
parsing plus `Calendar`, as `selectedPeriodCost` already does), and memoize
`String -> Date` / `Date -> day-string` per invocation. Row dates repeat
heavily (only ~30-90 unique days), so a small dictionary reduces formatter work
to O(unique days).

### G3 (high): aggregate snapshot merged from scratch on every request

`MachineSnapshotStore.aggregateSelection` -> `merge`
(`Sources/AppCore/MachineCollection.swift:277-316`) flatMaps all machines'
`points`, `dashboardMetrics`, and `dashboardSessions` into fresh arrays and
recomputes `selectedPeriodCost` for **every** API request. The frontend always
queries `machine=all` and issues several requests per filter switch (metrics,
cost-series, budget), so the same merge is repeated with unchanged inputs.

**Fix**: memoize the merged `CostSnapshot` inside the actor, keyed by the set of
included machine IDs plus each included snapshot's `generatedAt` (or a
monotonic version bumped in `publish`/`clear`/`replaceRegistry`). Invalidate on
any publish. Requests between refresh cycles then reuse one merged snapshot.

### G4 (medium): full-history re-sort on every refresh cycle

`SnapshotService.snapshot()` (`Sources/AppCore/Snapshot.swift:362-365`) sorts
`dashboardMetrics` and `dashboardSessions` over the entire history on every
poll (default cycle), even though the cached portion is already sorted from
SQLite and only the fresh (today) portion is new.

**Fix**: sort only the fresh partition and merge two sorted sequences, or skip
re-sorting the cached prefix. Preserve the documented ordering invariant.

### G5 (medium): scope attachment double-encodes every response

`MachineDashboardRouter.jsonWithScope`
(`Sources/AppCore/MachineDashboardRouter.swift:551`) encodes the payload with
`JSONEncoder`, decodes it with `JSONSerialization`, injects `scope`, and
re-serializes. Large `cost-series` payloads pay roughly 3x encoding cost.

**Fix**: encode in one pass with a generic wrapper that emits the payload's
keys plus `scope` (e.g. encode the value and scope into one keyed container via
a `ScopedResponse<T: Encodable>` using `superEncoder`/flat encoding, or add
`scope` fields to the response structs).

### G6 (low): `points` (blocks) are never cached

`snapshot()` always fetches `client.blocks` for the full initial range
(`Sources/AppCore/Snapshot.swift:355`) on every cycle; block records are not
persisted in the aggregation cache. Cost is bounded (one ccusage call) and the
data is mutable intraday, so this is acceptable; optional follow-up only.

### G7 (low): frontend polling and refetch behavior

- `/api/load-status` is polled every 250 ms forever (`frontend/src/App.tsx:634`),
  even when everything is `ready`. Back off to ~2 s when `isLoading` is false.
- Switching a range back and forth refetches identical URLs with no
  stale-while-revalidate reuse. Optional: keep last response per path and show
  it instantly while revalidating.
- The metric table renders all filtered rows unvirtualized; acceptable for
  current volumes, noted for the future.

### G8 (informational)

- `AggregationCache.readDatabase` runs `createSchema` (DDL + pragmas) on the
  read path; harmless but avoidable.
- `MachineCollector.startPoller` line 555 has an if-branch whose two arms are
  identical (`descriptor.id == "local" ? default : default`); not a
  performance issue but worth cleaning while nearby.

## 4. Design of the fixes

### 4.1 Coverage-aware expansion (G1)

Add a pre-check in `MachineCollector.expand`:

```swift
public func expand(machine requested: String, earliestDate: Date) async {
  let targets = ... // as today
  await withTaskGroup(of: Void.self) { group in
    for descriptor in targets {
      group.addTask { [weak self] in
        guard let self else { return }
        if let entry = await self.store.entry(machineID: descriptor.id),
           entry.snapshot != nil,
           let coverage = entry.coverageStart, coverage <= earliestDate {
          return  // already covered; serve from memory
        }
        _ = try? await self.collect(descriptor: descriptor, earliestDate: earliestDate, phase: .loadingHistory)
      }
    }
  }
}
```

Behavioral contract preserved: when coverage is insufficient the request still
awaits collection (so `store.selection(requiredCoverageStart:)` succeeds);
when coverage is sufficient the request is served from the published snapshot
without touching ccusage. Freshness continues to come from the poller and the
explicit `/api/refresh` path.

### 4.2 Formatter hygiene (G2)

- In `DashboardQueryService`, replace the computed `dayFormatter` with helpers
  that create one formatter per public call and thread it through private
  helpers, plus a per-call `[String: Date]` / `[Date-day: String]` memo.
  `parseDay` stays public with unchanged signature (it may build one formatter
  per call; it is not in a loop at the router).
- In `SnapshotService`, build the formatter once per `snapshot()` /
  `loadUsage()` invocation and pass it into `partitionUsage` / `usageResult`.
- No output ordering or values change; existing tests must pass unchanged.

### 4.3 Merge memoization (G3)

Inside `MachineSnapshotStore`:

```swift
private struct MergeCacheKey: Equatable {
  let machineIDs: [String]
  let generatedAts: [Date]
  let requiredCoverageStart: Date?   // affects the usable set only
}
private var mergeCache: (key: MergeCacheKey, snapshot: CostSnapshot)?
```

`aggregateSelection` computes the usable set as today, forms the key from the
usable entries, and reuses `mergeCache` when the key matches. Note `merge`
also depends on `now` through `selectedPeriodCost`; keep correctness by
caching the merged arrays (`points`, `dashboardMetrics`, `dashboardSessions`)
and recomputing only the cheap scalar cost/interval fields per request, or by
bucketing `now` to the refresh interval. Prefer the former: cache the merged
arrays, recompute `selectedPeriodCost` per request (linear scan over the
selected interval is comparatively cheap and interval-bounded). Invalidate by
construction: the key changes whenever any included snapshot is republished,
cleared, or the registry changes.

### 4.4 Incremental sort (G4)

In `snapshot()`: cached metrics/sessions are already sorted. Sort only
`freshMetrics`/`freshSessions` (small: today plus newly fetched ranges) and
merge the two sorted sequences. Extract a `mergeSorted(_:_:by:)` helper in
`Snapshot.swift` with unit tests. The persisted cache write path is unchanged.

### 4.5 Single-pass scope encoding (G5)

Add `struct ScopedPayload<T: Encodable>: Encodable` that encodes `T`'s keyed
fields and a `scope` key in one container. Simplest robust approach without
reflection: give each dashboard response struct an optional `scope:
DashboardScope?` field (encoded when present) and drop `jsonWithScope`'s
JSONSerialization round-trip; the router sets `scope` before encoding.
`Tests/AppCoreTests/DashboardTests.swift` and
`Tests/AppCoreTests/MachineTests.swift` guard the wire format.

### 4.6 Frontend load-status backoff (G7, minimal slice)

Poll `/api/load-status` at 250 ms while `isLoading`, else every 2 s; reset to
250 ms when a refresh or range load begins. No other frontend behavior change
in this iteration.

## 5. Non-goals

- Persisting block records (`points`) in the aggregation cache (G6).
- Frontend response caching / stale-while-revalidate and table virtualization.
- Incremental (append-only) SQLite cache writes.

## 6. Risks

- G1: skipping expansion must not skip machines whose snapshot exists but whose
  coverage is narrower than requested; the guard therefore compares
  `coverageStart <= earliestDate` and requires a non-nil snapshot.
- G3: memoized merged arrays must never leak across registry revisions; keying
  on machine IDs + generatedAt covers publish/clear/replace because all three
  mutate those inputs.
- G5: wire-format regressions; covered by existing router/dashboard tests plus
  new assertions that `scope` remains present with identical shape.
