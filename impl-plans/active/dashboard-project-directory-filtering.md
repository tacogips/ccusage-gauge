# Per-machine Project-directory Filtering and Chart Splitting

**Status**: Implemented and Verified
**Workflow Mode**: issue-resolution
**Issue Reference**: workflow-input issue “Add per-machine sub-directory
filtering and bar-graph subdirectory split to ccusage-gauge dashboard”;
`workflowExecution:codex-design-and-implement-review-loop-session-641`
**Design Review**: Accepted by Step 3 in `communication:comm-001732`; no high
or mid findings.
**Codex Agent References**: None supplied. No reference-repository trace,
intentional divergence, or Cursor adapter boundary applies.

## Source of Truth

- `design-docs/specs/architecture.md#project-directory-dimension-and-filtering`
- `design-docs/specs/design-machine-session-source-directories.md#collection-data-flow`
- `design-docs/specs/design-remote-machine-collection.md#1-transport-abstraction`

The accepted design controls whenever this plan is less specific. In
particular, implementation must preserve authoritative unfiltered totals,
optional-field compatibility, exact per-machine filtering, local-only JSONL
provenance, unattributed-row semantics, path redaction, and the unchanged
default chart path.

## Current Baseline

- `TimestampedUsageEvent`, `CCUsageCostRecord`, `CCUsageMetricRecord`, and
  `CCUsageSessionMetricRecord` have no project-directory field.
- `ClaudeUsageEventLoader` decodes assistant events without `cwd`.
  `CodexUsageEventLoader` tracks session/model context but not metadata `cwd`.
- `CostSnapshot.dashboardSessions`, snapshot merge/coalescing, and
  `UsageAggregationCache` do not distinguish project directory or record
  per-day provenance coverage.
- `DashboardQuery` groups only by time, machine, agent, and model.
  `MachineDashboardRouter` and the legacy router in `HTTPService.swift` accept
  no directory filters or breakdown request and expose no directory inventory.
- `frontend/src/api.ts` has no directory DTOs or query helper.
  `machineScope.ts` owns machine selection only, `seriesColors.ts` has model and
  machine namespaces, and `App.tsx` supports model/machine stacking only.
- `Snapshot.swift` and `MachineDashboardRouter.swift` are close to the
  repository's 1000-line Swift limit. New responsibilities should be placed in
  focused files or extensions instead of growing either file materially.
  `Tests/AppCoreTests/CCUsageTests.swift` is also near the limit, so directory
  coverage belongs in new focused test files.

## Deliverables

- [x] Optional opaque project-directory provenance decoded from Claude and
  Codex JSONL and carried by Swift records with legacy Codable compatibility.
- [x] Directory-aware snapshot reconciliation, merge/coalescing identities,
  SQLite persistence, per-day provenance coverage, and atomic historical
  backfill without changing authoritative unfiltered totals.
- [x] Optional per-machine directory filters, optional cost-series directory
  breakdown, optional row fields, and a selected-machine directory inventory
  route with sanitized failures.
- [x] Frontend directory DTO/query support, deterministic 10-character labels,
  collision sequencing, per-machine selection state, and a separate color
  namespace.
- [x] Checked-machine-only nested filters, cleared effects after machine
  uncheck, and a persisted-compatible subdirectory chart mode that defaults
  off.
- [x] Focused Swift and frontend regressions plus full build, test, lint,
  compatibility, privacy, and unchanged-default-path evidence.

## Execution and Progress Rules

- Preserve all unrelated worktree changes. Do not commit, push, revert, or
  change version declarations as part of this plan.
- Use existing SwiftPM targets. Keep each non-generated Swift source below
  1000 lines and split by responsibility before a planned edit would cross the
  limit.
- Keep directory strings as opaque provenance. Do not expand, canonicalize,
  open, execute, or include them in logs, errors, request diagnostics, or
  persistent bootstrap records.
- Keep new encoded fields and query items optional. Missing `directory` decodes
  as `nil`; omitted filters and omitted/false `directoryBreakdown` use the
  existing response and rendering paths.
- Use injected clocks, calendars, loaders, caches, and stores for deterministic
  range, backfill, rollback, and retry coverage.
- After Swift edits, run the narrowest relevant test and `mise run lint` when
  available. Confirm a focused suite appears in `swift test list` before
  accepting an exact `swift test --filter <SuiteName>` result.
- After every task, append a dated Progress Log entry containing task status,
  changed files, commands/results, findings addressed, limitations, residual
  risks, and the next task. Checkboxes represent completed evidence, not intent.

## Dependency Graph

```text
TASK-001
  /     \
TASK-002 TASK-004
   |
TASK-003
  \     /
  TASK-005
     |
  TASK-006
```

TASK-002 and TASK-004 may run in parallel after TASK-001 because their write
scopes are disjoint. All other tasks are serialized at their dependency joins.

## TASK-001: Add Directory Provenance to Events and Core Records

**Depends On**: None

**Design References**:

- `architecture.md#project-directory-dimension-and-filtering`, paragraphs 2
  and 4
- `design-machine-session-source-directories.md#collection-data-flow`

**Write Scope**:

- `Sources/AppCore/CCUsage.swift`
- `Sources/AppCore/ClaudeUsageEvents.swift`
- `Sources/AppCore/CodexUsageEvents.swift`
- `Tests/AppCoreTests/UsageDirectoryEventTests.swift` (new)
- focused fixtures under `Tests/AppCoreTests/Fixtures/` if required

**Parallelizable**: No. This establishes the shared provenance contract used by
snapshot, cache, query, API, and frontend work.

**Work**:

1. Add `directory: String?` to `TimestampedUsageEvent`,
   `CCUsageCostRecord`, `CCUsageMetricRecord`, and
   `CCUsageSessionMetricRecord`. Preserve source compatibility with defaulted
   initializer arguments and decode missing keys as `nil`; omit the key when
   encoding `nil`.
2. Decode Claude assistant-event `cwd`. Convert missing, empty, or unusable
   values to `nil`; otherwise retain the original string as the opaque
   exact-match identity.
3. Decode Codex session-metadata `cwd` and associate each token event with the
   effective session directory while retaining existing session/model context.
   Make forward and reverse scans produce identical event-directory
   associations, including context changes and range-boundary scans.
4. Keep event identity and deduplication behavior stable apart from carrying
   directory provenance. Do not use directory as a filesystem operation or
   expose it through diagnostics.
5. Add focused tests for Claude/Codex events with and without `cwd`, empty
   values, multiple contexts, forward/reverse parity, and legacy record
   decoding/encoding.

**Completion Criteria**:

- [x] All four record/event types carry optional directory provenance.
- [x] Pre-change payloads decode without errors and preserve prior values.
- [x] Claude and Codex fixtures establish deterministic `cwd` association in
  forward and reverse scans.
- [x] Event identities and unfiltered event counts remain unchanged.
- [x] No touched Swift source exceeds 1000 lines.

**Verification**:

- `swift test list | rg 'UsageDirectoryEventTests'`
- `swift test --filter UsageDirectoryEventTests`
- `mise run lint`
- `git diff --check -- Sources/AppCore/CCUsage.swift Sources/AppCore/ClaudeUsageEvents.swift Sources/AppCore/CodexUsageEvents.swift Tests/AppCoreTests/UsageDirectoryEventTests.swift`

## TASK-002: Thread Provenance through Snapshots, Range Loading, and Cache

**Depends On**: TASK-001

**Design References**:

- `architecture.md#project-directory-dimension-and-filtering`, paragraphs
  4-8
- `design-machine-session-source-directories.md#collection-data-flow`
- `design-remote-machine-collection.md#1-transport-abstraction`, remote data
  source boundary

**Write Scope**:

- `Sources/AppCore/Snapshot.swift`
- `Sources/AppCore/Snapshot+SessionSources.swift`
- new focused snapshot/directory extension files under `Sources/AppCore/`
- `Sources/AppCore/CostSnapshotMerge.swift`
- `Sources/AppCore/MultiSourceUsageCoalescing.swift`
- `Sources/AppCore/AggregationCache.swift`
- new focused cache migration/provenance files under `Sources/AppCore/`
- `Sources/AppCore/DashboardRangeLoading.swift`
- `Sources/AppCore/MachineCollectorRangeLoading.swift`
- `Sources/AppCore/MachineRangeLoad.swift`
- `Tests/AppCoreTests/DirectorySnapshotTests.swift` (new)
- `Tests/AppCoreTests/DirectoryCacheMigrationTests.swift` (new)
- `Tests/AppCoreTests/DirectoryRangeLoadingTests.swift` (new)

**Parallelizable**: Yes, with TASK-004 only. Backend Swift/test and frontend
TypeScript/test write scopes are disjoint.

**Work**:

1. Copy event directory into reconciled timestamped sessions. Include optional
   directory, with `nil` distinct, in snapshot merge, coalescing, replacement,
   and cache identities so attributed rows from different projects never
   collapse.
2. Extend SQLite daily/session persistence with nullable directory columns and
   add idempotent per-host-day directory-provenance coverage. Preserve existing
   machine-owned cache semantics and additive migration of pre-change files.
3. Treat migrated historical days as provenance-unscanned. On first
   directory-aware load, scan available local events for the materialized day,
   build a complete derived-session replacement, and atomically replace the
   session partition and mark coverage. Roll back both on interruption or
   failure.
4. Ensure retry replaces rather than additively merges legacy `nil` and
   attributed sessions. Keep the current host day refreshable while reusing
   completed historical coverage.
5. Expand local event loading to every host-calendar day materialized by
   initial history/week warming, custom-range expansion, and targeted refresh.
   Keep SSH collection aggregate-only and directory-unattributed unless an
   aggregate source later supplies provenance.
6. Preserve authoritative aggregate daily rows and exact unfiltered cost/token
   totals before, during, and after successful, failed, or retried backfill.
7. Add migration, rollback, retry, no-double-counting, historical-log-missing,
   range-expansion, remote-`nil`, and unchanged-total regressions.

**Completion Criteria**:

- [x] Snapshot/session identities separate equal rows by optional directory.
- [x] Old SQLite caches migrate idempotently and remain readable.
- [x] Backfill publishes only complete committed partitions and retries safely.
- [x] Directory coverage follows all materialized local dashboard ranges.
- [x] SSH behavior and unfiltered totals remain unchanged.
- [x] Near-limit Swift files are split before exceeding 1000 lines.

**Verification**:

- `swift test list | rg 'Directory(Snapshot|CacheMigration|RangeLoading)Tests'`
- `swift test --filter DirectorySnapshotTests`
- `swift test --filter DirectoryCacheMigrationTests`
- `swift test --filter DirectoryRangeLoadingTests`
- `mise run lint`
- `find Sources Tests -name '*.swift' -type f -exec wc -l {} + | sort -nr | head`
- `git diff --check -- Sources/AppCore Tests/AppCoreTests`

## TASK-003: Add Directory-aware Queries and Backward-compatible HTTP APIs

**Depends On**: TASK-002

**Design References**:

- `architecture.md#project-directory-dimension-and-filtering`, paragraphs
  8-12
- `design-remote-machine-collection.md#4-machine-aware-snapshot-and-api`

**Write Scope**:

- `Sources/AppCore/DashboardQuery.swift`
- new query/filter responsibility files under `Sources/AppCore/`
- `Sources/AppCore/DashboardAPIModels.swift`
- `Sources/AppCore/MachineDashboardRouter.swift`
- new machine-router directory route/parser files under `Sources/AppCore/`
- `Sources/AppCore/HTTPService.swift`
- `Sources/AppCore/DashboardAPIClient.swift` when client DTO/query support is
  required
- `Tests/AppCoreTests/DashboardDirectoryQueryTests.swift` (new)
- `Tests/AppCoreTests/MachineDirectoryAPITests.swift` (new)
- `Tests/AppCoreTests/LegacyDirectoryAPITests.swift` (new)

**Parallelizable**: No. It consumes the finalized cache/snapshot semantics and
defines the server contract used by UI integration.

**Work**:

1. Add optional `directory` to `DashboardCostRow` and metric response rows.
   Preserve omitted-key compatibility and all existing grouping when no
   directory behavior is requested.
2. Introduce an internal per-machine exact-match directory selection. Parse
   repeatable `directory=<machine-id>:<full-directory>` values by splitting at
   the first colon after percent decoding. OR values within one machine and
   keep selections independent across machines.
3. Ignore valid filters for known machines outside the active machine scope.
   Return existing-style sanitized `400`/`404` errors for malformed values or
   unknown machine ids without echoing directory strings.
4. Apply optional directory filters to `/api/metrics`,
   `/api/cost-series`, and `/api/budget`. Exclude unattributed rows only for a
   machine with an active directory selection; leave them visible otherwise.
5. Add optional single `directoryBreakdown=true|false` to
   `/api/cost-series`. A true value or any directory filter selects
   directory-resolved grouping from reconciled sessions, including daily
   granularity. Omission/false with no filter must use the current aggregate
   path and return unchanged totals/grouping.
6. Add `GET /api/subdirectories` with the accepted machine-selection rules.
   Return full-string-sorted, non-`nil` values grouped by selected machine from
   retained provenance-scanned coverage. Remote aggregate-only machines return
   empty lists.
7. Implement the same additive behavior in the machine-aware router and the
   legacy single-snapshot router where applicable. Split the near-limit machine
   router by responsibility rather than crossing 1000 lines.
8. Add route/query tests for per-machine isolation, multiple selections,
   stale unchecked-machine filters, unattributed semantics, daily breakdown,
   inventory refresh, malformed input, redaction, old payload decoding, and
   omitted/false compatibility.

**Completion Criteria**:

- [x] Directory query fields are optional and existing clients remain valid.
- [x] Filters affect only their addressed selected machine.
- [x] Daily and sub-daily directory-resolved rows reconcile to authoritative
  unfiltered totals.
- [x] `/api/subdirectories` follows machine availability/scope rules and
  returns no `nil` values.
- [x] No directory value appears in any error or persistent log.
- [x] Omitted filters/breakdown produce byte-shape-compatible optional fields
  and behavior-equivalent totals/grouping.

**Verification**:

- `swift test list | rg '(DashboardDirectoryQuery|MachineDirectoryAPI|LegacyDirectoryAPI)Tests'`
- `swift test --filter DashboardDirectoryQueryTests`
- `swift test --filter MachineDirectoryAPITests`
- `swift test --filter LegacyDirectoryAPITests`
- `mise run lint`
- `rg -n 'directory|directoryBreakdown|subdirectories' Sources/AppCore Tests/AppCoreTests`
- `git diff --check -- Sources/AppCore Tests/AppCoreTests`

## TASK-004: Build Frontend Directory Types, State Helpers, Labels, and Colors

**Depends On**: TASK-001

**Design References**:

- `architecture.md#project-directory-dimension-and-filtering`, paragraphs
  9-13

**Write Scope**:

- `frontend/src/api.ts`
- `frontend/src/machineScope.ts`
- `frontend/src/seriesColors.ts`
- new focused directory-state helpers under `frontend/src/`
- `frontend/tests/api.test.ts`
- `frontend/tests/machineScope.test.ts`
- `frontend/tests/seriesColors.test.ts`
- new focused frontend test files when clearer

**Parallelizable**: Yes, with TASK-002 only. No Swift or backend-test files are
in scope.

**Work**:

1. Add optional directory fields to `MetricRow` and `CostRow`, the additive
   subdirectory response DTO, and `subdirectory` to the saved stack union.
2. Add deterministic query construction for per-machine selections. Omit
   directory items for empty selections and for machines outside the active
   machine scope; percent encode each complete value.
3. Represent selections as a map keyed by machine id. Provide pure helpers to
   clear entries when a machine becomes unchecked and to report nested-filter
   visibility only for checked machines.
4. Derive labels by removing trailing separators, selecting the deepest
   non-empty component (root uses `/`), and taking the first 10 Unicode code
   points. Within each machine, sort full values and allocate the base label,
   then the first available `-2`, `-3`, and later suffix, including
   suffix-versus-base collisions.
5. Extend `SeriesKind` and palettes with a separate `subdirectory` namespace.
   Include machine plus full directory in the color identity so equal paths on
   different machines do not merge or perturb model/machine colors.
6. Test query omission/encoding, selection clearing/visibility, label
   truncation and all collision cases, Unicode handling, root/trailing
   separators, and deterministic color separation.

**Completion Criteria**:

- [x] Frontend DTOs accept old and new API payloads.
- [x] Query helpers preserve machine-local selection and omission rules.
- [x] Labels implement the exact 10-character and sequence contract.
- [x] Visibility and clear-on-uncheck behavior are covered by pure tests.
- [x] Existing model/machine colors remain unchanged.

**Verification**:

- `cd frontend && bun test tests/api.test.ts tests/machineScope.test.ts tests/seriesColors.test.ts`
- `mise run frontend:check`
- `git diff --check -- frontend/src frontend/tests`

## TASK-005: Integrate Nested Filters and Subdirectory Chart Mode

**Depends On**: TASK-003 and TASK-004

**Design References**:

- `architecture.md#project-directory-dimension-and-filtering`, paragraphs
  10-14

**Write Scope**:

- `frontend/src/App.tsx`
- `frontend/src/styles.css`
- focused UI/chart components extracted under `frontend/src/` if useful
- `frontend/tests/usageChart.test.ts`
- focused directory-filter UI tests under `frontend/tests/`

**Parallelizable**: No. This is the backend/frontend integration point.

**Work**:

1. Load `/api/subdirectories` for the current machine scope and refresh it after
   range expansion publishes new coverage.
2. Add per-machine directory selection state. Append active directory query
   items to metrics, cost-series, and budget requests. Normalize the map
   whenever machine selection changes so individual and bulk unchecks hide and
   remove that machine's active filters; rechecking starts unfiltered.
3. Render each checked machine's nested directory checkboxes beneath its
   machine row using derived labels. Render no nested list for unchecked
   machines or machines whose directory inventory is empty. Keep full paths as
   internal identities and do not display them by default.
4. Extend `stackBy` and the chart control with `subdirectory`. Restore saved
   `model`, `machine`, and `subdirectory`; treat missing or unknown values as
   `model`. The initial/default value remains `model`.
5. Send `directoryBreakdown=true` only for subdirectory stacking; active
   directory filters remain independent. Build series identities from machine
   plus full directory. In a single-machine view, use the derived directory
   label for display; in a multi-machine view, qualify that label with the
   machine display identity so equal derived labels remain unambiguous across
   machines. Render a distinct `No directory` series for unattributed rows
   that remain included.
6. Preserve the existing rows, buckets, totals, labels, and color behavior when
   subdirectory stacking is off and no directory filter is selected.
7. Add focused tests for checked-only nested visibility, clear-on-uncheck,
   query changes, saved-state fallback, no-directory rendering, cross-machine
   series separation, single-machine derived labels, machine-qualified
   multi-machine display labels with equal derived directory labels, and
   default-off chart equivalence.

**Completion Criteria**:

- [x] Checked machines alone show their directory filters.
- [x] Unchecking a machine immediately clears its directory-filter effect.
- [x] Per-machine selections narrow all dashboard data requests consistently.
- [x] Subdirectory stacking is opt-in and distinguishes machines and
  unattributed rows; multi-machine display labels identify their machine.
- [x] Old saved state restores safely and default rendering is unchanged.
- [x] Frontend typecheck and focused tests pass.

**Verification**:

- `cd frontend && bun test`
- `mise run frontend:check`
- `mise run frontend:build`
- `git diff --check -- frontend/src frontend/tests Sources/AppCore/Resources/Web`

## TASK-006: Complete Integrated Verification and Documentation

**Depends On**: TASK-005

**Design References**:

- `architecture.md#project-directory-dimension-and-filtering`, final
  compatibility/test paragraph
- all source-of-truth documents above

**Write Scope**:

- focused regressions required by failed verification
- accepted design docs only for implementation-discovered clarifications that
  do not change behavior
- this plan's checkboxes and Progress Log
- synchronized generated frontend assets

**Parallelizable**: No. This is the final integrated audit.

**Work**:

1. Run focused and full Swift/frontend tests, build, typecheck, lint, coverage,
   and packaged-asset verification.
2. Prove the default regression: with no directory filters and non-subdirectory
   stacking, response totals/grouping and chart rendering match the pre-change
   behavior.
3. Prove backward compatibility by decoding pre-change records, snapshots,
   SQLite caches, saved frontend state, and API payloads without directory
   fields.
4. Audit directory handling from parser through API/UI, cache keys, and merge
   keys. Search public error/log creation paths and verify full directory
   values are absent.
5. Confirm changed files are in scope, Swift files remain below 1000 lines,
   generated assets match frontend source, and `git diff --check` passes.
6. Update design documentation only when implementation reveals a
   behavior-preserving clarification. Escalate any contract change for design
   review rather than silently editing the accepted behavior.
7. Complete all mise run checkboxes and record exact command outcomes, unavailable
   tooling, residual risks, and implementation handoff in the Progress Log.

**Completion Criteria**:

- [x] `swift build`, `swift test`, and frontend `bun test` pass.
- [x] Typecheck, lint, coverage, and packaged frontend assets pass or an exact
  environment limitation is recorded without claiming completion.
- [x] Parser-to-UI directory provenance and filtering are covered end to end.
- [x] Default-path totals/rendering and all pre-change decodes are unchanged.
- [x] Full paths are absent from logs and errors.
- [x] Documentation, implementation, generated assets, tests, and this plan
  agree with no unrelated changes.

**Verification**:

- `swift build`
- `swift test`
- `mise run lint`
- `mise run test:coverage`
- `cd frontend && bun test`
- `mise run frontend:check`
- `mise run frontend:build`
- `mise run smoke:assets`
- `find Sources Tests -name '*.swift' -type f -exec wc -l {} + | sort -nr | head`
- `git diff --check`
- `git diff --stat`
- `git status --short`

## Overall Completion Criteria

- [x] Optional directory provenance is threaded from Claude/Codex events
  through Swift records, reconciliation, cache, query, API, frontend types, and
  chart series.
- [x] Per-machine directory filters are visible only for checked machines,
  clear on uncheck, and never affect another machine.
- [x] Label generation uses the first 10 Unicode characters of the deepest
  component and deterministic collision suffixes within each machine.
- [x] Subdirectory chart splitting defaults off; the off/no-filter path matches
  current behavior.
- [x] Missing-directory rows remain visible without active directory selection
  and are excluded for the selected machine when a filter is active.
- [x] Old records, snapshots, caches, payloads, and saved UI state remain
  compatible.
- [x] SSH machines remain aggregate-only/unattributed unless a future aggregate
  format provides provenance.
- [x] Required Swift/frontend verification and privacy audits pass, with exact
  results recorded in the Progress Log.

## Risks and Mitigations

- **Historical logs may be unavailable**: retain a tested `nil` group and never
  infer attribution from aggregate rows.
- **Initial provenance backfill may be expensive**: persist per-day coverage,
  scan completed days once, and keep the current day as the only routinely
  replaceable partition.
- **Backfill may duplicate usage**: replace complete derived-session partitions
  atomically and prove unchanged authoritative totals across failure/retry.
- **Directory-aware grouping may change default totals**: keep the current
  aggregate path for omitted filters/breakdown and add equivalence regressions.
- **Machine filters may leak across scopes**: key selections by canonical
  machine id, omit unchecked machines, and test multi-machine OR semantics.
- **Full paths are sensitive**: expose them only in the loopback data contract
  needed for exact selection; never place them in visible default labels,
  logs, errors, or diagnostics.
- **Near-limit Swift files may become invalid**: split snapshot/router/cache
  responsibilities before adding substantial behavior and enforce line-count
  verification.
- **Generated frontend assets may drift**: build and synchronize once after
  source/test success, then run packaged-asset smoke verification.

## Progress Log

- 2026-07-28 — PLAN — created from the Step 3-accepted design and workflow
  intake — reviewed current Swift, cache, router, frontend, test, Taskfile, and
  active-plan boundaries — no Step 5 feedback or Codex-agent reference input
  exists — implementation has not started; next task is TASK-001.
- 2026-07-28 — PLAN-SELF-REVIEW — accepted — confirmed all six tasks map to
  the accepted design without unsupported architecture; deliverables,
  dependency joins, the one disjoint parallel window, completion criteria,
  focused/full tests, typecheck, documentation, privacy audits, and progress-log
  expectations are explicit — no design or plan finding; independent Step 5
  review is next.
- 2026-07-28 — PLAN-REVISION — addressed Step 5 mid finding at the TASK-005
  chart integration boundary — specified derived labels for single-machine
  views, machine-qualified labels for multi-machine views, and an explicit
  equal-label multi-machine regression — no design revision required;
  independent Step 5 re-review is next.
- 2026-07-28 — TASK-001 — complete — added optional directory provenance to
  Claude/Codex events and core usage records, including forward/reverse Codex
  metadata association and legacy Codable behavior — `swift test --filter
  UsageDirectoryEventTests` passed 4 tests — no unresolved finding; TASK-002
  followed.
- 2026-07-28 — TASK-002 — complete — threaded directory identity through
  reconciliation, merge/coalescing, historical range loading, and additive
  SQLite migration with atomically published per-day coverage — focused cache
  and historical-warmup regressions passed — unavailable historical logs and
  aggregate-only SSH provenance remain documented residual risks; TASK-003
  followed.
- 2026-07-28 — TASK-003 — complete — added optional directory-aware dashboard
  queries, exact per-machine filters, daily/sub-daily breakdown, sanitized
  request parsing, and machine-aware plus legacy inventory/API routes — `swift
  test --filter DashboardDirectoryQueryTests` passed 3 tests and `swift test
  --filter MachineDirectoryAPITests` passed 2 tests — full directory values are
  excluded from errors and logs; TASK-005 integration followed.
- 2026-07-28 — TASK-004 — complete — added frontend DTOs, deterministic encoded
  query construction, machine-local state helpers, Unicode-aware 10-character
  collision labels, and a stable subdirectory color namespace — focused
  frontend tests passed 20 tests and `bun run check` passed — TASK-005
  followed.
- 2026-07-28 — TASK-005 — complete — integrated checked-machine-only nested
  filters, clear-on-uncheck behavior, consistent metrics/cost/budget filtering,
  default-off subdirectory stacking, persisted-state fallback, unattributed
  series, and machine-qualified multi-machine labels — `cd frontend && bun
  test` passed 52 tests in 11 files; `mise run frontend:build` and `task
  smoke:assets` passed — TASK-006 followed.
- 2026-07-28 — TASK-006 — complete — `swift build` passed; full `swift test`
  and coverage execution passed 227 tests in 53 suites; `mise run test:coverage`
  reported 82.78% executable line coverage (10059/12151); `mise run lint` completed
  with 35 warnings and 0 serious violations; frontend
  typecheck, build, tests, packaged-asset smoke checks, privacy search, and
  `git diff --check` passed — touched non-generated Swift source files remain
  below 1000 lines — no high or mid implementation finding remains; ready for
  Step 7 review.
- 2026-07-28 — IMPLEMENTATION-SELF-REVIEW-REVISION — complete — addressed
  `communication:comm-001740` mid findings by sorting default collapsed
  sessions with `sessionsInIncreasingOrder` and adding exact default order,
  genuine legacy SQLite migration, transactional rollback/retry, historical
  JSONL attribution, merge-key separation, inventory refresh, breakdown
  compatibility, multiple Codex context, suffix-versus-base collision,
  cross-machine series, and unattributed-label regressions — focused tests,
  full `swift test` (227 tests), `cd frontend && bun test` (52 tests),
  typecheck, lint, coverage, asset build/smoke, and diff checks passed — both
  findings are resolved; independent Step 7 review is next.
- 2026-07-28 — IMPLEMENTATION-SELF-REVIEW-REVISION-2 — complete — addressed
  `communication:comm-001742` by preserving already-covered authoritative
  daily metric rows during provenance backfill while atomically replacing the
  covered session partition and publishing directory coverage — the
  rollback/retry regression now supplies a conflicting incoming daily metric
  and proves the authoritative daily row and total remain unchanged after both
  failure and successful retry — focused SQLite regressions, `swift build`,
  full `swift test` (227 tests in 53 suites), `mise run test:coverage` (82.78%,
  10059/12151), `mise run lint` (35 warnings, 0 serious violations), frontend tests
  (52 tests), typecheck, asset build/smoke, and diff checks passed — the
  remaining mid finding is resolved; independent Step 7 review is next.
- 2026-07-28 — IMPLEMENTATION-TEST-INTEGRITY-REVISION — complete — addressed
  `communication:comm-001745` by extracting production-used frontend
  orchestration for metrics/cost/budget request paths, default stack restore,
  breakdown omission, and nested-filter visibility; added focused frontend
  integration-state coverage plus legacy and machine-aware HTTP route
  regressions for filtered metrics, daily cost, budget, active selections, and
  stale out-of-scope selections — `swift build` passed; `swift test` passed 229
  tests in 53 suites; `mise run test:coverage` passed at 82.74% (10054/12151);
  `mise run lint` completed with 35 warnings and 0 serious violations; `cd frontend
  && bun test` passed 56 tests in 12 files; direct TypeScript checking and
  `mise run frontend:build` passed; both packaged-asset smoke modes reported
  passed, although the task wrapper remained open until the external timeout
  after emitting both success results; diff and line-count checks passed — the
  Step 6 test-integrity mid finding is resolved; independent review is next.

Future entries use:
`YYYY-MM-DD — TASK-NNN — status — changed files/deliverables — commands/results — findings addressed — limitations/residual risks — next task`.
