# EDF-07: Aggregate Cache Effort Column and One-Time Local Backfill Trigger

**Status**: Not Started
**Plan ID**: EDF-07
**Wave**: 2
**Depends on**: EDF-01 (`CCUsageSessionMetricRecord.effort`)
**Design Reference**: `design-docs/specs/design-dashboard-dark-flat-effort-grouping.md` section 5 (Aggregate cache); `design-docs/specs/architecture.md` "Project-directory dimension and filtering" (backfill contract)
**Protocol**: `impl-plans/active/dashboard-dark-flat-effort-overview.md` section 3

## Purpose

Persist session-row effort in the SQLite aggregate cache. For the cache owned
by the reserved `local` machine only, reset directory-provenance coverage once
when the column is first added. The existing atomic backfill then re-derives
historical session partitions with effort. No new coverage table is added.

## Write paths

- `Sources/AppCore/AggregationCache.swift`
- `Tests/AppCoreTests/EffortAggregationCacheTests.swift` (new)

## Non-goals

- No `effort` column on `daily_metrics`. Authoritative daily rows never carry
  effort.
- No new coverage table and no change to
  `Snapshot.swift:missingUsageRanges`. It already requires
  `directoryCoveredRanges`.
- No change to cache paths, retention, or legacy-file upgrade logic.

## Changes (`Sources/AppCore/AggregationCache.swift`)

1. Schema:
   - Add `effort TEXT` to the `CREATE TABLE IF NOT EXISTS session_metrics`
     statement, so new databases get the column directly.
   - In the migration block, next to the existing
     `hasColumn("directory", in: "session_metrics", ...)` (around lines
     398-403), add: if `!hasColumn("effort", in: "session_metrics", ...)`, then
     run `ALTER TABLE session_metrics ADD COLUMN effort TEXT`. When
     `machineID` is the reserved local id, also run
     `DELETE FROM directory_coverage_ranges`.
   - Use the same constant or literal the code base uses for the local id.
     Grep `static let local` or `"local"` in `Machines.swift` and
     `AggregationCache.swift`. The actor's `machineID` defaults to `"local"`.
   - The ALTER and the DELETE must commit together. Wrap the pair in the file's
     existing transaction helper or `BEGIN IMMEDIATE` and `COMMIT`, with
     `ROLLBACK` on failure, unless the surrounding schema setup already runs
     inside a transaction. Do not nest transactions.
2. `readSessions` (around lines 488-518):
   - Select `effort` as column 10.
   - `ORDER BY timestamp, agent, model, directory, effort`.
   - Pass `effort: optionalText(statement, column: 10)`.
3. `insertSessions`:
   - Add `effort` to the column list and placeholders.
   - Bind it with `bindOptional(row.effort, to: 11, in: statement)`, after
     `directory` at index 10.
4. The column's presence is the idempotency marker. A second open of an
   already-migrated database must not clear coverage again.

## Pitfalls

- A fresh database already has the column through `CREATE`, so the migration
  branch must not run. Fresh databases have no coverage anyway.
- SSH-machine caches, meaning any `machineID` other than local, add the column
  but **must not** clear coverage. Clearing it would force a full-history
  remote refetch.
- `daily_metrics` rows must be untouched by the migration. Authoritative
  totals stay identical.
- `writeDatabase` fully rewrites tables from the payload. Make sure the effort
  column is written there through `insertSessions`, not dropped.
- Keep the file under 1000 lines. It is 767 today.

## Tests (`@Suite("EffortAggregationCacheTests")`)

Imitate the legacy-schema and database tests in
`Tests/AppCoreTests/CacheLifecycleTests.swift` and
`Tests/AppCoreTests/DirectoryFeatureRegressionTests.swift` (grep
`directory_coverage_ranges`, `ALTER`, or `sqlite3_exec`). Build a pre-change
database with raw SQLite: a `session_metrics` table without `effort`, plus
`directory_coverage_ranges` rows and `coverage_ranges` rows.

- A legacy database opened as `machineID: "local"`:
  - the load succeeds;
  - `directoryCoveredRanges` is empty;
  - `coveredRanges` is unchanged;
  - legacy session rows decode with `effort == nil`;
  - daily metric rows are identical to their pre-migration values.
- The same legacy database opened as `machineID: "build-host"`:
  - the column is added;
  - `directoryCoveredRanges` is preserved.
- After the local migration, save a payload with new coverage and reopen. The
  coverage is **not** cleared again.
- A fresh cache round-trips session rows with `effort "high"` and with `nil`.
  Two rows that differ only in effort both survive save and load.

## Verification

```text
mkdir -p /tmp/ccusage-gauge-effort
swift build > /tmp/ccusage-gauge-effort/EDF-07-build.log 2>&1; echo "exit=$?"
swift test --filter EffortAggregationCacheTests > /tmp/ccusage-gauge-effort/EDF-07-test.log 2>&1; echo "exit=$?"
swift test --filter CacheLifecycleTests > /tmp/ccusage-gauge-effort/EDF-07-lifecycle.log 2>&1; echo "exit=$?"
swift test --filter "DirectorySQLiteRegressionTests|DirectoryCacheMigrationTests|UsageAggregationCacheTests" > /tmp/ccusage-gauge-effort/EDF-07-regression.log 2>&1; echo "exit=$?"
swiftlint lint --quiet Sources/AppCore/AggregationCache.swift Tests/AppCoreTests/EffortAggregationCacheTests.swift > /tmp/ccusage-gauge-effort/EDF-07-lint.log 2>&1; echo "exit=$?"
wc -l Sources/AppCore/AggregationCache.swift
```

Expected evidence: every command exits 0, existing cache suites stay green, and
the file is under 1000 lines.

## Completion criteria

- [ ] Local-only reset, idempotency, SSH preservation, and round-trip tests pass.
- [ ] All logs recorded.

## Progress Log

- 2026-09-29: Plan created.
