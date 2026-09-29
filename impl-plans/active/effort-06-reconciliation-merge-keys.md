# EDF-06: Effort in Reconciliation, Coalescing, and Snapshot Merge

**Status**: Not Started
**Plan ID**: EDF-06
**Wave**: 2
**Depends on**: EDF-01 (record `effort` fields)
**Design Reference**: `design-docs/specs/design-dashboard-dark-flat-effort-grouping.md` section 5 (Records, reconciliation, and merge keys)
**Protocol**: `impl-plans/active/dashboard-dark-flat-effort-overview.md` section 3

## Purpose

Carry the event effort into reconciled 15-minute session buckets. Keep rows
that differ only in effort distinct through the coalescing and snapshot merge
paths, so no row is dropped or replaced. Per-model totals must not change.

## Write paths

- `Sources/AppCore/Snapshot.swift`
- `Sources/AppCore/Snapshot+Reconciliation.swift` (new, only if needed for the 1000-line limit)
- `Sources/AppCore/MultiSourceUsageCoalescing.swift`
- `Sources/AppCore/CostSnapshotMerge.swift`
- `Tests/AppCoreTests/EffortReconciliationTests.swift` (new)

## Non-goals

- Do not change cost allocation weights, `AgentModelDay` grouping, or the
  fallback-dropping rule in `usageResult`.
- Do not add effort to metric (daily) or point keys. Only session paths carry
  effort.
- No query or cache changes. Those are EDF-07 and EDF-08.

## Changes

1. `Snapshot.swift` `reconciledTimestampedSessions`:
   - The per-event `CCUsageSessionMetricRecord(...)` (around line 242) passes
     `effort: event.effort`.
   - `AgentModelBucket` (line 9) gains `let effort: String?`. The bucket key
     (around line 251) sets `effort: event.effort`.
   - The output record (around line 276) passes `effort: key.effort`.
   - The sort stays `(timestamp, model)`. Tests compare order-insensitively.
2. `MultiSourceUsageCoalescing.swift`:
   - `SessionCoalesceKey` gains `let effort: String?`.
   - Every construction of that key and every rebuilt session record inside
     the session-coalescing function passes the row's effort.
   - Grep `directory: row.directory` within the session function. The metric
     and point functions stay unchanged.
3. `CostSnapshotMerge.swift`:
   - `SessionRowKey` gains `let effort: String?`.
   - Its key construction (the session block, around lines 65-85) passes
     `effort: $0.effort`.
   - `CostPointKey` and `MetricRowKey` stay unchanged.
4. Line limit:
   - Record `wc -l Sources/AppCore/Snapshot.swift` before and after the change.
   - If the result is 990 lines or more, move `reconciledTimestampedSessions`,
     `AgentModelDay`, and `AgentModelBucket` unchanged into the new file
     `Sources/AppCore/Snapshot+Reconciliation.swift`. Keep the same access
     levels, widening `private` to `fileprivate` or internal only as far as
     compilation requires, and make no behavior change.

## Pitfalls

- Coalescing uses **sum** semantics and merge uses **replace-by-key**
  semantics. Without effort in `SessionRowKey`, two effort rows with the same
  timestamp, model, and directory would replace each other, which silently
  loses cost. Both keys must include effort.
- `nil` effort is its own identity. Do not coerce it to `""` in keys.
- Do not touch `MachineCollection.swift`. The cross-machine merge is a plain
  concatenation.

## Tests (`@Suite("EffortReconciliationTests")`)

Imitate `Tests/AppCoreTests/DirectoryFeatureTests.swift` reconciliation and
merge cases, and `Tests/AppCoreTests/MultiSourceUsageCoalescingTests.swift`.

- One day, one agent and model, with 3 timestamped events in the same
  15-minute bucket: 2 with `effort "high"` and 1 with `effort "low"`.
  Reconciliation produces 2 bucket rows, one per effort.
  - The sum of `costUSD` and of each token field equals the result for the same
    events without effort, which is one row.
  - The per-model total equals the daily aggregate.
- Events with `effort == nil` land in a separate `nil` bucket row. No row is
  dropped.
- Coalescing two sources whose rows differ only in effort keeps 2 rows. Two
  rows with identical keys, including effort, are summed into 1.
- `mergingSnapshots` with an existing snapshot row (`effort "high"`) and a
  fresh row that differs only in effort (`"low"`, same timestamp, model,
  machine, quality, and directory) keeps both. A fresh row with the same
  effort replaces the existing one.

## Verification

```text
mkdir -p /tmp/ccusage-gauge-effort
swift build > /tmp/ccusage-gauge-effort/EDF-06-build.log 2>&1; echo "exit=$?"
swift test --filter EffortReconciliationTests > /tmp/ccusage-gauge-effort/EDF-06-test.log 2>&1; echo "exit=$?"
swift test --filter MultiSourceUsageCoalescingTests > /tmp/ccusage-gauge-effort/EDF-06-coalesce.log 2>&1; echo "exit=$?"
swift test --filter Directory > /tmp/ccusage-gauge-effort/EDF-06-directory.log 2>&1; echo "exit=$?"
swiftlint lint --quiet Sources/AppCore/Snapshot.swift Sources/AppCore/MultiSourceUsageCoalescing.swift Sources/AppCore/CostSnapshotMerge.swift Tests/AppCoreTests/EffortReconciliationTests.swift > /tmp/ccusage-gauge-effort/EDF-06-lint.log 2>&1; echo "exit=$?"
wc -l Sources/AppCore/Snapshot.swift Sources/AppCore/Snapshot+Reconciliation.swift
```

Add `Sources/AppCore/Snapshot+Reconciliation.swift` to the swiftlint command
only if that file was created. The `wc` output may report it missing if it was
not created.

Expected evidence: every command exits 0, the existing coalescing and directory
suites stay green, and `Snapshot.swift` is under 1000 lines.

## Completion criteria

- [ ] Both `SessionCoalesceKey` and `SessionRowKey` contain `effort`.
- [ ] Tests prove totals are unchanged and that no row is dropped or replaced.
- [ ] All logs recorded.

## Progress Log

- 2026-09-29: Plan created.
