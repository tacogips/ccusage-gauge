# Explicit Subdirectory Display Names and Global Label Uniqueness

**Status**: Implemented and Verified  
**Workflow Mode**: issue-resolution  
**Issue Reference**: workflow-input issue “Explicit sub-directory display
names with rename UI/API and cross-machine label uniqueness”;
`workflowExecution:codex-design-and-implement-review-loop-session-648`  
**Design Review**: Accepted by Step 3 in `communication:comm-001757`; no high
or mid findings.  
**Codex Agent References**: None supplied. No reference-repository trace,
intentional divergence, or Cursor adapter boundary applies.

## Source of Truth

- `design-docs/specs/architecture.md#project-directory-dimension-and-filtering`
- `impl-plans/active/dashboard-project-directory-filtering.md` documents the
  implemented, uncommitted directory-filtering baseline on which this work
  builds.

The accepted design controls whenever this plan is less specific. In
particular, explicit names are dashboard-host metadata keyed by canonical
machine id and opaque full directory string; they are not usage provenance,
per-browser dashboard state, or remote-machine configuration.

## Purpose and Scope

Add persistent explicit directory names, a set/clear HTTP contract on both
dashboard routing surfaces, inline rename behavior, and one deterministic
dashboard-wide label allocator. Explicit names replace the derived ten-code-
point base before collision allocation. Final labels must be unique across all
enabled machines while machine/path remains the stable filter, chart-series,
and color identity.

This follow-up does not change event provenance, directory filtering,
directory-resolved aggregation, remote collection, or the default non-
subdirectory chart path. It must preserve every prior uncommitted change and
must not modify unrelated files.

## Current Baseline

- `Sources/AppCore/DashboardStateStore.swift` persists singleton browser UI
  state in `dashboard-state.sqlite3`; it has no global machine/path name table.
- `Sources/AppCore/DashboardDirectoryAPI.swift` returns each machine with
  `directories: [String]` only.
- `Sources/AppCore/HTTPService.swift` and
  `Sources/AppCore/MachineDashboardRouter.swift` expose
  `GET /api/subdirectories` but no name mutation route.
- `dashboardMutationAllowed` in
  `Sources/AppCore/DashboardRangeLoading.swift` implements the required
  mutation header, loopback host, origin, and fetch-metadata checks.
- `frontend/src/machineScope.ts` allocates labels independently within each
  machine and has no explicit-name input.
- `frontend/src/App.tsx` displays derived labels and machine-qualifies
  multi-machine chart labels; it has no rename editor.
- `frontend/src/usageChartSeries.ts` and `frontend/src/seriesColors.ts`
  already keep subdirectory identity and color keyed by machine plus full path.
- `Sources/AppCore/HTTPService.swift` and
  `Sources/AppCore/MachineDashboardRouter.swift` are close to the 1000-line
  Swift limit. New route responsibility must be extracted or moved into
  focused files rather than growing either file beyond the limit.

## Deliverables

- [x] SQLite-backed dashboard-host name store with set, clear, read, reopen,
  validation, and retained-undiscovered-name behavior.
- [x] Backward-compatible subdirectory payload with optional per-machine
  `names`.
- [x] `PUT /api/subdirectories/name` on local and machine-scoped routers with
  identical pre-decoding mutation guards and sanitized failures.
- [x] Frontend rename client and inline editor with immediate confirmed label
  refresh, clear-to-fallback behavior, reload persistence, and recoverable
  errors.
- [x] One deterministic explicit-or-derived label allocation across every
  enabled machine in the catalog.
- [x] Sidebar and subdirectory chart labels use the same global result while
  machine/path selection, series identity, and color identity remain stable.
- [x] Focused Swift/frontend regressions, full verification, synchronized
  embedded assets, and an exact progress log.

## Execution and Progress Rules

- Preserve all existing dirty-worktree changes. Do not revert, discard,
  overwrite, or reformat unrelated work. Do not commit or push unless a later
  workflow step explicitly requires it.
- Use the accepted design as the behavior contract. Escalate a contract change
  for design review rather than silently changing it during implementation.
- Keep full directory values opaque. Do not resolve, normalize, open, execute,
  log, or echo them in error messages.
- Keep all new API fields optional for readers that only understand
  `directories`. A missing or empty `names` field must behave as no explicit
  names.
- Keep every non-generated Swift file below 1000 lines. Prefer focused store,
  route, and request/response files over adding substantial code to
  `HTTPService.swift` or `MachineDashboardRouter.swift`.
- After each task, append a dated Progress Log entry with status, changed
  files, commands/results, findings addressed, limitations, residual risks,
  and next task. Checkboxes record verified completion, not intent.

## Dependency Graph

```text
TASK-001 ----> TASK-002 --\
                           > TASK-004 --> TASK-005
TASK-003 ----------------/
```

TASK-003 may run in parallel with TASK-001 and TASK-002 because its write scope
is limited to frontend source/tests while TASK-001 and TASK-002 are limited to
Swift source/tests. TASK-004 is the backend/frontend integration join. No other
task is parallelizable.

## TASK-001: Persist Names and Extend the Directory Contract

**Depends On**: None  
**Parallelizable**: Yes, with TASK-003.

**Design References**:

- `design-docs/specs/architecture.md#project-directory-dimension-and-filtering`,
  paragraphs beginning “The additive `GET /api/subdirectories`” and
  “Explicit names are dashboard-host metadata”

**Write Scope**:

- `Sources/AppCore/DashboardStateStore.swift` only for shared SQLite
  conventions or a minimal integration point
- `Sources/AppCore/DashboardDirectoryNameStore.swift` (new, preferred)
- `Sources/AppCore/DashboardDirectoryAPI.swift`
- `Tests/AppCoreTests/DirectoryFeatureTests.swift`
- `Tests/AppCoreTests/DirectoryDisplayNameStoreTests.swift` (new if separation
  keeps existing tests focused)

**Work**:

1. Add a dedicated actor-backed name store using the same injected
   `dashboard-state.sqlite3` file as `DashboardStateStore`. Create a separate
   table idempotently, keyed by `(machine_id, directory)`, with normalized name
   and update time.
2. Implement set/upsert, clear/delete, per-machine/path reads, and reopen
   behavior. Serialize writes so the last successfully committed write wins.
   Retain rows for temporarily undiscovered paths.
3. Centralize request-name normalization: the `name` member is required and
   may be null; null, empty, or whitespace-only clears; non-empty values are
   edge-trimmed, contain no control characters, and are limited to 200 Unicode
   code points.
4. Validate canonical machine ids and non-empty opaque directory strings
   without filesystem access or path normalization.
5. Extend `MachineSubdirectories` with optional
   `names: [String: String]?`. Omit it when no discovered directory has a
   stored name, and never return a stored name for a path absent from the same
   `directories` array.
6. Add request/response DTOs for the rename contract while preserving decode
   compatibility for payloads that contain only `machine` and `directories`.
7. Add deterministic tests for set, overwrite, clear, whitespace clear,
   reopen persistence, invalid names, undiscovered-name retention, filtered
   disclosure, and old-payload decoding.

**Completion Criteria**:

- [x] Names persist in the dashboard database independently of
  `DashboardUIState`.
- [x] Set, overwrite, clear, and reopen semantics match the accepted design.
- [x] Invalid input cannot reach SQLite mutation.
- [x] Old subdirectory payloads decode unchanged.
- [x] `names` is omitted when empty and includes only discovered paths.
- [x] No directory or name value is added to an error or persistent log.

**Verification**:

- `swift test list | rg 'Directory(DisplayName|Feature)'`
- `swift test --filter DirectoryDisplayNameStoreTests`
- `swift test --filter DirectoryFeature`
- `task lint`
- `git diff --check -- Sources/AppCore/DashboardStateStore.swift Sources/AppCore/DashboardDirectoryNameStore.swift Sources/AppCore/DashboardDirectoryAPI.swift Tests/AppCoreTests`

## TASK-002: Add Guarded Rename Routes on Both Router Surfaces

**Depends On**: TASK-001  
**Parallelizable**: Yes, with TASK-003.

**Design References**:

- `design-docs/specs/architecture.md#project-directory-dimension-and-filtering`,
  paragraphs beginning “Both local `HTTPService` mode” and “Malformed JSON”

**Write Scope**:

- `Sources/AppCore/HTTPService.swift`
- `Sources/AppCore/MachineDashboardRouter.swift`
- `Sources/AppCore/MachineDashboardRouter+DirectoryQueries.swift`
- `Sources/AppCore/DashboardDirectoryNameRoutes.swift` (new if needed to keep
  router files below 1000 lines)
- production store-wiring call sites in `Sources/AppCLI/Runtime.swift` and
  `Sources/CCUsageGaugeMenuBar/MenuBarApp.swift` only if constructor injection
  requires them
- `Tests/AppCoreTests/DirectoryFeatureTests.swift`
- `Tests/AppCoreTests/DirectoryFeatureRegressionTests.swift`
- `Tests/AppCoreTests/DirectoryDisplayNameRouteTests.swift` (new, preferred for
  parity/security cases)

**Work**:

1. Inject or derive the name store from `AppPaths.dashboardStateFile` so local
   and machine-scoped production routes use dashboard-host persistence under
   `CCUSAGE_GAUGE_CACHE_HOME`.
2. Add `PUT /api/subdirectories/name` to both routing surfaces. The local-only
   route accepts only `local`; the machine router accepts canonical ids in its
   served registry scope. A directory need not be currently discovered.
3. Before body decoding, validation, snapshot access, or store access, apply
   the same `dashboardMutationAllowed` check on both surfaces. Reject
   `OPTIONS` through the same control-route policy and reject unsupported
   methods without mutation.
4. Decode and validate the required nullable name member only after the guard
   succeeds. Return the normalized confirmed value on set and `name: null` on
   clear.
5. Map malformed/invalid input to `400 invalid_directory_name`, unknown
   canonical machine to `404 machine_not_found`, and persistence failure to
   `503 directory_name_unavailable`, without echoing untrusted values.
6. Update `GET /api/subdirectories` on both surfaces to merge stored names
   into the discovered catalog. Fail with `503` on name-store reads instead of
   silently falling back to derived labels.
7. Extract route helpers or existing responsibility from near-limit router
   files before either exceeds 1000 lines.
8. Add route tests proving set, clear, GET reflection, restart/reopen
   persistence, absent-directory acceptance, local/machine validation,
   backward-compatible GET shape, read/write failure mapping, and identical
   guard rejection before decoding or persistence.

**Completion Criteria**:

- [x] Both routers expose behavior-equivalent rename endpoints.
- [x] Guard failure occurs before decoding and produces no observable store
  change.
- [x] Local and registry machine rules are enforced with sanitized errors.
- [x] Successful PUT is reflected by the next GET and after store reopen.
- [x] Store read failure cannot masquerade as cleared names.
- [x] Touched non-generated Swift files remain below 1000 lines.

**Verification**:

- `swift test list | rg 'Directory(DisplayName|Route)'`
- `swift test --filter DirectoryDisplayNameRouteTests`
- `swift test --filter DirectoryRouteRegressionTests`
- `swift test --filter DirectoryFeature`
- `task lint`
- `find Sources Tests -name '*.swift' -type f -exec wc -l {} + | sort -nr | head`
- `git diff --check -- Sources/AppCore Sources/AppCLI Sources/CCUsageGaugeMenuBar Tests/AppCoreTests`

## TASK-003: Add Frontend Name DTOs, Rename Client, and Global Labels

**Depends On**: None. The accepted JSON contract is sufficient.  
**Parallelizable**: Yes, with TASK-001 and TASK-002; write scopes are disjoint.

**Design References**:

- `design-docs/specs/architecture.md#project-directory-dimension-and-filtering`,
  paragraphs beginning “Directory labels are deterministic” and “Use the base
  label”

**Write Scope**:

- `frontend/src/api.ts`
- `frontend/src/machineScope.ts`
- `frontend/src/usageChartSeries.ts`
- `frontend/src/seriesColors.ts` only if a regression exposes an identity
  defect; palette assignments must remain unchanged
- `frontend/tests/api.test.ts`
- `frontend/tests/machineScope.test.ts`
- `frontend/tests/usageChart.test.ts`
- `frontend/tests/seriesColors.test.ts`

**Work**:

1. Extend the subdirectory DTO with optional `names` and add a typed rename
   request/response helper that sends `PUT`, JSON, and
   `X-CCUsage-Gauge-Mutation: 1` through the existing mutation client.
2. Replace per-machine label allocation with one pure catalog-wide function.
   Flatten unique `(machine, path)` entries, sort by machine id then path, and
   choose the stored explicit name before the derived deepest-component,
   first-ten-Unicode-code-point fallback.
3. Allocate the base if unused; otherwise append the smallest available `-2`,
   `-3`, and later suffix. Cover derived/derived, explicit/explicit,
   mixed, cross-machine, and generated-suffix-versus-base collisions.
4. Keep machine plus full path as the stable lookup key. Label changes must
   not change filter values, chart-series identities, or subdirectory color
   keys.
5. Update chart-label helpers so attributed series consume the globally
   unique label without a machine-name prefix. Preserve a distinct
   machine-aware presentation for unattributed `No directory` series.
6. Add tests for optional old DTOs, PUT body/header/method, set and null-clear
   responses, Unicode fallback, deterministic ordering, every collision class,
   globally unique chart labels, and stable identity/color across rename.

**Completion Criteria**:

- [x] Existing payloads without `names` remain valid.
- [x] Rename requests use the exact accepted method, body, and mutation header.
- [x] One deterministic pass allocates unique labels across all machines.
- [x] Explicit names take precedence before suffix allocation.
- [x] Sidebar/chart consumers can resolve the same label by machine/path.
- [x] Rename does not alter selection, series, or color identity.

**Verification**:

- `cd frontend && bun test tests/api.test.ts tests/machineScope.test.ts tests/usageChart.test.ts tests/seriesColors.test.ts`
- `task frontend:check`
- `git diff --check -- frontend/src/api.ts frontend/src/machineScope.ts frontend/src/usageChartSeries.ts frontend/src/seriesColors.ts frontend/tests`

## TASK-004: Integrate Inline Rename and Shared Labels in the Dashboard

**Depends On**: TASK-002 and TASK-003  
**Parallelizable**: No.

**Design References**:

- `design-docs/specs/architecture.md#project-directory-dimension-and-filtering`,
  paragraphs beginning “The SPA owns selected directories”, “Each sidebar
  directory row”, and “The graph's stack control”

**Write Scope**:

- `frontend/src/App.tsx`
- `frontend/src/styles.css`
- focused rename/catalog component or state helper under `frontend/src/` if
  extraction improves testability
- `frontend/tests/dashboardDirectoryState.test.ts`
- focused rename UI/state tests under `frontend/tests/`
- `frontend/tests/usageChart.test.ts`

**Work**:

1. Fetch the subdirectory catalog for all enabled machines independently of
   the active machine filter, so checking or unchecking a machine cannot
   renumber another machine's label.
2. Build one memoized names/catalog input and one global machine/path label
   map. Use it for every sidebar entry and attributed
   `stackBy=subdirectory` chart label.
3. Add an inline edit action to each directory row. Initialize the editor from
   the explicit name or an empty value for derived labels; Enter and blur
   submit, Escape cancels, and blank submits a null clear.
4. On success, update the confirmed names catalog and rerun label allocation
   immediately; refetch may then reconcile with the server as source of truth.
   On failure, preserve the last confirmed label, retain recoverable edit
   input, and show a non-sensitive inline error.
5. Ensure a reload obtains the persisted name from
   `/api/subdirectories`. Clearing restores the derived fallback and may
   deterministically renumber colliding labels.
6. Remove machine qualification from attributed labels now that global
   allocation guarantees uniqueness. Keep unattributed series distinct and
   machine-aware.
7. Preserve selected directories, machine scope, chart series keys, and color
   assignments across set/clear operations.
8. Add focused tests for start/edit/cancel, Enter, blur, blank clear, failed
   save, immediate confirmed update, refetch persistence, cross-machine
   renumbering, sidebar/chart agreement, and stable identity/color.

**Completion Criteria**:

- [x] Inline set and clear update confirmed labels without a page reload.
- [x] Reload/refetch restores server-persisted names.
- [x] Failed mutation leaves the last confirmed presentation and state intact.
- [x] Active-machine toggles do not renumber unrelated labels.
- [x] Sidebar and chart use identical globally unique attributed labels.
- [x] Filters, series grouping, and colors retain machine/path identity.

**Verification**:

- `cd frontend && bun test`
- `task frontend:check`
- `task frontend:build`
- `git diff --check -- frontend/src frontend/tests Sources/AppCore/Resources/Web`

## TASK-005: Complete Integrated Verification, Assets, and Handoff

**Depends On**: TASK-004  
**Parallelizable**: No.

**Design References**:

- `design-docs/specs/architecture.md#project-directory-dimension-and-filtering`,
  final compatibility and verification paragraph

**Write Scope**:

- focused regressions required by failed verification
- `Sources/AppCore/Resources/Web/` generated assets
- accepted design documentation only for behavior-preserving clarification
- this plan's checkboxes and Progress Log

**Work**:

1. Run focused and full Swift/frontend verification and fix in-scope failures.
2. Exercise endpoint set and clear followed by GET using both router test
   surfaces; reopen the SQLite store and prove persistence.
3. Audit the two mutation origins for identical ordering: authority/header
   gate, then decode, validation, and store access.
4. Prove backward compatibility with subdirectory payloads that omit `names`
   and prove the default no-explicit-name fallback keeps the established
   derived label behavior except for accepted cross-machine sequencing.
5. Prove UI and API renames update both sidebar and chart presentation while
   machine/path identity and color remain unchanged.
6. Build frontend assets using the established task, verify packaged assets,
   and ensure generated hashes/index references are synchronized.
7. Run privacy searches, Swift file line counts, diff checks, and worktree
   scope review. Preserve all pre-existing unrelated changes.
8. Complete checkboxes and append exact command results, limitations, residual
   risks, and the next workflow handoff to the Progress Log.

**Completion Criteria**:

- [x] `swift build`, `swift test`, and `cd frontend && bun test` pass.
- [x] Focused persistence, endpoint parity, explicit-name, cross-machine, and
  rename UI tests pass.
- [x] `task frontend:check`, `task frontend:build`, `task smoke:assets`, and
  `task lint` pass or an exact environment limitation is recorded.
- [x] Embedded assets match frontend source.
- [x] No untrusted name/path enters errors or persistent logs.
- [x] Both mutation surfaces prove pre-decoding guard parity.
- [x] No unrelated dirty-worktree change is reverted or overwritten.
- [x] Design, implementation, tests, assets, and this plan agree.
- [x] A successful registry persistence rollback restores directory-name
  metadata even when runtime rollback fails and requires restart recovery.

**Verification**:

- `swift test --filter DirectoryFeature`
- `swift test --filter DirectoryDisplayNameStoreTests`
- `swift test --filter DirectoryDisplayNameRouteTests`
- `swift build`
- `swift test`
- `task lint`
- `cd frontend && bun test tests/machineScope.test.ts tests/api.test.ts tests/usageChart.test.ts`
- `cd frontend && bun test`
- `task frontend:check`
- `task frontend:build`
- `task smoke:assets`
- `find Sources Tests -name '*.swift' -type f -exec wc -l {} + | sort -nr | head`
- `rg -n 'directory_name|invalid_directory_name|subdirectories/name|X-CCUsage-Gauge-Mutation' Sources Tests frontend`
- `git diff --check`
- `git diff --stat`
- `git status --short`

## Overall Completion Criteria

- [x] A normalized explicit name is persisted globally by machine/path, can be
  cleared, and survives application/store reopen.
- [x] Both HTTP surfaces expose the same guarded, backward-compatible set/clear
  contract and GET reflection.
- [x] Explicit names override fallback bases and every attributed directory
  label is unique across the complete enabled-machine catalog, including
  retained snapshots for stale machines and catalog changes after machine
  create, edit, enable, disable, or removal.
- [x] Inline rename updates the sidebar and chart immediately after success and
  persists across reload.
- [x] No explicit-name state is stored in per-browser `DashboardUIState` or on
  remote machines.
- [x] Machine/path filter, series, and color identities do not change on
  rename.
- [x] Old clients and old subdirectory payloads remain valid.
- [x] Opaque directory keys retain their full UTF-8 contents in SQLite without
  embedded-NUL aliasing.
- [x] Shared dashboard SQLite contention cannot be mistaken for absent UI
  state, and a failed initial state load cannot trigger a default-state
  overwrite.
- [x] A committed machine mutation remains successful when a following
  catalog refresh fails; failed catalogs are retried once and any remaining
  stale state is reported as a reconciliation warning.
- [x] Local subdirectory inventory fails with `503
  directory_name_unavailable` when its required name store is unconfigured,
  rather than presenting derived labels as if explicit names were absent.
- [x] A confirmed rename remains visible if its reconciliation refetch fails;
  the SPA reports a retryable warning and clears it after a later successful
  catalog response.
- [x] A rename whose response is lost or times out is reconciled against the
  refreshed exact machine/path name before the SPA reports success or failure.
- [x] If both an ambiguous rename response and its reconciliation refetch fail,
  the SPA reports an unknown outcome and never claims that persistence
  succeeded.
- [x] Machine deletion durably hides and purges its explicit names, rolls the
  marker back if registry deletion fails, and clears stale metadata before a
  deleted canonical id can be reused.
- [x] Startup reconciles durable deletion markers with the authoritative
  persisted registry, restoring names for present machine ids after an
  interrupted prepared deletion or durable rollback, purging committed metadata
  before a deleted id is externally reused, and completing cleanup for absent
  ids.
- [x] Active deletion markers reject stale rename writes, and post-commit purge
  failure remains hidden, observable, and retryable in the running process
  without reclassifying the committed registry deletion.
- [x] Required focused/full verification and packaged-asset checks pass with
  exact evidence in the Progress Log.

## Accepted Review Feedback Addressed

- Step 3 confirmed persistence, API/UI behavior, router parity, global
  allocation, compatibility, identity stability, failures, and verification.
  TASK-001 through TASK-005 map each accepted boundary to deliverables and
  checks.
- Step 3 required preservation of unrelated dirty-worktree changes. This is an
  execution rule, a TASK-005 scope audit, and an overall completion criterion.
- Step 3 required identical pre-decoding mutation guards. TASK-002 specifies
  the exact order on both surfaces; TASK-005 audits and verifies parity.
- No Step 5 review feedback exists for this first plan iteration.
- Step 6 test-integrity review found that rename behavior was covered only by
  isolated helpers rather than the `App.tsx` orchestration boundary. The
  revision extracts the production save workflow and interaction intent,
  then tests Enter/blur, Escape/cancel, confirmed sidebar/chart refresh,
  stable identity/color, refetch reconstruction, and recoverable failure.
- The latest Step 6 test-integrity review found that the machine lifecycle
  catalog test still repeated one generic helper with cosmetic transition
  strings instead of executing production create/edit/enable/disable/remove
  orchestration. The corrective revision exports `saveMachineCatalog`,
  `toggleMachineCatalog`, and `removeMachineCatalog`, uses those exact
  boundaries from `App.tsx`, and executes their create, edit, enable, disable,
  removal, and failure branches before asserting all three catalog refreshes.
- The latest Step 7 adversarial review found embedded-NUL SQLite key aliasing
  and a shared-database contention path that could report absent state and
  overwrite it with defaults. The revision binds and reads explicit UTF-8 byte
  lengths, adds a five-second state-store busy timeout, distinguishes
  `SQLITE_DONE` from errors, gates frontend autosave on a successful initial
  state response, and adds deterministic key-aliasing, exclusive-lock, and
  frontend failure regressions.
- The latest Step 7 adversarial review found that a committed machine
  create/edit/toggle/remove could be reported as failed when a subsequent
  catalog refresh rejected. The revision retries each catalog independently,
  preserves the committed mutation result, exposes persistent refresh
  failures as a visible reload/reconciliation warning, and tests every
  production mutation boundary under post-commit refresh failure. It also
  replaces the contention test's fixed delay with an explicit task-start
  handshake and resolves the focused SwiftLint warning.
- The latest Step 7 adversarial review found that deleting a machine retained
  its `(machine_id, directory)` names, allowing a different machine created
  under the same id to inherit sensitive or misleading labels. The revision
  integrates the name store with the serialized registry transaction:
  deletion first writes a durable read-blocking marker, rollback removes it,
  successful deletion purges the rows, and creation clears any retained rows
  plus marker before commit. Store and full HTTP delete/recreate/catalog
  regressions cover the lifecycle.
- The latest Step 7 adversarial rerun found that termination after the durable
  marker write but before registry persistence or rollback could leave a
  present machine's names permanently hidden across restart. The revision
  reconciles metadata against the loaded registry before either production
  router becomes available, restores present-machine markers, completes
  absent-machine cleanup, and adds restart plus simultaneous
  addition/removal regressions.
- The session-648 Step 7 adversarial rerun found that final deletion cleanup
  silently swallowed storage failure and that a stale authorized rename could
  write beneath a retained deletion marker. The revision makes finalization
  return completion state, records and exposes pending machine ids, retries
  cleanup with bounded backoff and catalog reads, rejects marked name writes
  transactionally, and adds focused persistence, route, transaction, and
  frontend warning regressions.
- The session-648 Step 7 implementation review found that the local
  subdirectory inventory treated an unconfigured name store as an empty store.
  The revision now maps that configuration failure to the accepted sanitized
  `503 directory_name_unavailable` response and supplies an explicit store in
  the backward-compatibility inventory fixture.
- The same implementation review found that a successful rename could lose
  its confirmed presentation when the follow-up catalog refetch failed. The
  revision retains a last-confirmed catalog fallback, awaits and absorbs the
  reconciliation failure without reclassifying the committed rename, exposes
  a visible retry warning, and tests the production workflow boundary.
- The latest Step 7 adversarial review found that termination after registry
  rollback but before marker cancellation could make startup misclassify the
  restored machine as id reuse. The revision persists rollback intent before
  restoring the registry, preserves names for active rollback markers, and
  tests both interruption and marker-cancellation failure across restart.
- The same adversarial review found that a committed rename could be reported
  as failed when its response was lost. The revision distinguishes
  authoritative HTTP failures from transport ambiguity, refetches and compares
  the normalized exact machine/path name, and keeps unconfirmed input
  recoverable.
- Step 6 self-review found that an ambiguous rename followed by a failed
  catalog refetch reused the confirmed-save warning. The revision now carries
  an explicit confirmed-save versus ambiguous-outcome discriminator to the
  production warning and tests both messages.

## Risks and Mitigations

- **Concurrent store access may diverge between UI-state and name actors**:
  share the same injected SQLite file, use an idempotent independent table,
  serialize name mutations, apply consistent busy waiting, distinguish
  contention from an absent row, gate autosave after load failure, and test
  reopen plus exclusive-lock behavior.
- **Router security behavior may drift**: use the shared
  `dashboardMutationAllowed` predicate and parity tests that prove rejection
  before body decoding and store access.
- **Global labels may renumber unexpectedly**: allocate from the all-enabled
  catalog in stable machine/path order and test active-scope toggles,
  cross-machine collisions, and suffix-versus-base collisions.
- **Rename may accidentally change chart grouping or color**: retain
  machine/path identity throughout and add before/after identity/color
  regressions.
- **Optimistic UI may display uncommitted state**: update labels only from a
  successful response, retain the last confirmed catalog on failure, and
  reconcile with GET.
- **Post-mutation catalog refresh may partially fail**: retry each catalog
  once without reclassifying the committed mutation, preserve the server
  result, and show a reload/reconciliation warning for any remaining stale
  catalog.
- **Post-rename catalog reconciliation may fail**: retain the confirmed
  response as the presentation fallback, keep periodic catalog refresh active,
  and show a warning until a successful response replaces the fallback.
- **A rename response may be lost after commit**: treat transport and decoding
  failures as ambiguous, reconcile the exact normalized name through the
  catalog, retain recoverable input when confirmation is unavailable, and
  label failed reconciliation as an unknown outcome rather than a confirmed
  save.
- **Stored paths may disappear temporarily**: retain the row but disclose it
  only when the exact directory is rediscovered.
- **Deleted machine ids may be reused or deletion may be interrupted**: stage
  a durable read-blocking prepared marker before registry deletion, promote it
  to committed after registry persistence, durably mark rollback intent before
  restoring the prior registry, purge after commit, clear all prior identity
  metadata before creation under the same id, and reconcile every marker phase
  with the persisted registry before production routers become available after
  restart.
- **Post-commit name cleanup may fail while registry deletion is already
  durable**: retain the marker, record the pending machine id, retry with
  bounded same-process backoff and catalog reads, and expose a sanitized SPA
  warning until cleanup succeeds.
- **Rename authorization may become stale during concurrent deletion**:
  reject set and clear transactions while the machine deletion marker is
  active, mapping the race to sanitized `404 machine_not_found`.
- **Near-limit router files may exceed repository limits**: extract focused
  route/store responsibility and enforce line-count verification.
- **Generated assets may drift**: rebuild only after source/tests pass, then
  run packaged-asset smoke checks and diff validation.
- **Sensitive directory/name values may leak**: use stable error codes and
  application-owned messages; audit logs, errors, and tests before handoff.

## Progress Log

- 2026-07-29 — PLAN — created from the Step 3-accepted architecture update and
  the implemented dirty-worktree directory-filtering baseline — no Codex-agent
  references or Step 5 findings exist — tasks, disjoint parallel window,
  completion criteria, exact verification, guard parity, identity stability,
  asset synchronization, and progress-log expectations are explicit — next
  step is independent Step 5 plan review.
- 2026-07-29 — TASK-001 — complete — added
  `DashboardDirectoryNameStore`, normalized set/overwrite/clear/reopen
  persistence in the shared dashboard SQLite file, optional filtered `names`
  payloads, DTO compatibility, and store regressions — `swift test --filter
  DirectoryDisplayName` passed 6 tests — next TASK-002.
- 2026-07-29 — TASK-002 — complete — added the guarded common PUT contract to
  local and machine router surfaces, dashboard-host store wiring, GET
  reflection, sanitized validation/failure mapping, and pre-decoding parity
  tests; extracted HTTP responsibilities to keep `HTTPService.swift` at 988
  lines and `MachineDashboardRouter.swift` at 985 — focused Swift tests and
  `swift build` passed — next TASK-003.
- 2026-07-29 — TASK-003 — complete — added optional frontend name DTOs, the
  mutation-header rename client, one machine/path-sorted global allocator, all
  explicit/derived collision classes, and stable series/color identity tests
  — focused bun tests passed 32 tests and `tsc --noEmit` passed — next TASK-004.
- 2026-07-29 — TASK-004 — complete — added all-enabled-machine catalog loading,
  inline Enter/blur save, Escape/cancel, blank clear, confirmed-state patch,
  recoverable failures, shared sidebar/chart labels, and focused state tests —
  full `bun test` passed 62 tests with 145 expectations and frontend typecheck
  passed — next TASK-005.
- 2026-07-29 — TASK-005 — complete — `swift build`, full `swift test` (235
  tests), full `bun test` (62 tests), `bun run check`, `task frontend:build`,
  `task smoke:assets`, `git diff --check`, embedded-asset byte comparisons,
  and line-count checks passed; `task lint` exited zero with warnings, then the
  new test warning was removed and focused lint on all new Swift files reported
  zero violations —
  synchronized `index-CQCw7eat.css` and `index-BCx7ObJE.js` — preserved the
  pre-existing dirty directory-filtering work and recorded no unresolved
  implementation risk — next step is Step 7 implementation review.
- 2026-07-29 — STEP-6-REVISION — complete — addressed the test-integrity
  `mid` finding by extracting `submitDirectoryRename` and
  `directoryRenameIntent` from `App.tsx`, using that boundary in production,
  and adding focused orchestration regressions for Enter/blur save,
  Escape/cancel, immediate shared sidebar/chart labels, stable series
  identity/color, persisted-catalog refetch, and failed-save recovery —
  targeted `bun test tests/dashboardDirectoryState.test.ts` passed 9 tests,
  full `bun test` passed 65 tests with 163 expectations,
  `task frontend:check`, `task frontend:build`, `swift build`, full
  `swift test` (235 tests), `task lint`, and `git diff --check` passed;
  both direct packaged-asset smoke commands exited zero and synchronized
  assets matched frontend output byte-for-byte — the combined
  `task smoke:assets` wrapper exceeded its 60-second orchestration limit only
  after both smoke commands printed their pass results, so the two commands
  were rerun directly — next step is the repeated test-integrity gate.
- 2026-07-29 — STEP-7-ADVERSARIAL-REVISION — complete — made
  `/api/subdirectories` use historical inventory disposition so enabled stale
  machines retain their last discovered directories during global label
  allocation; centralized machine-catalog refresh and wired it into create,
  edit, enable, disable, and removal flows; added stale-inventory and lifecycle
  refresh regressions — focused `swift test --filter DirectoryDisplayName`
  passed 7 tests, focused SwiftLint reported zero violations, full `swift
  build` completed, full `swift test` passed 236 tests, full `bun test` passed
  66 tests with 168 expectations, `bun run check` passed, frontend build and
  asset synchronization passed, both packaged-asset smoke commands passed,
  embedded assets matched byte-for-byte, `git diff --check` passed, and router
  files remain below 1000 lines — the final standalone full Swift test wrapper
  timed out only after printing the complete passing result — both adversarial
  `mid` findings are addressed; the pre-existing low shared-SQLite contention
  risk remains unchanged — next step is repeated implementation review.
- 2026-07-29 — STEP-6-TEST-INTEGRITY-REVISION — complete — replaced the inert
  transition loop with `runMachineCatalogMutation`, a production orchestration
  boundary used by `App.tsx` create/edit, enable/disable, and removal paths;
  focused tests now execute each named mutation before asserting machine,
  status, and subdirectory refreshes and prove failed mutations publish no
  refresh — focused `bun test tests/machineActions.test.ts` passed 7 tests with
  28 expectations, `bun run check` passed, full `bun test` passed 67 tests with
  180 expectations, the frontend production build and embedded-asset sync
  passed, both packaged-asset smoke modes passed, `diff -qr frontend/dist
  Sources/AppCore/Resources/Web` and `git diff --check` passed — synchronized
  `index-CQCw7eat.css` and `index-Drxkygo4.js` — next step is the repeated
  test-integrity gate.
- 2026-07-29 — STEP-6-TEST-INTEGRITY-REVISION-2 — complete — corrected the
  prior lifecycle-test claim after the repeated gate showed that transition
  strings were inert: extracted `saveMachineCatalog`, `toggleMachineCatalog`,
  and `removeMachineCatalog` as the production boundaries used by `App.tsx`;
  replaced the cosmetic loop with tests that execute create, edit, enable,
  disable, removal, and failed removal against those exact boundaries and
  assert mutation/selection ordering before machine, status, and subdirectory
  refreshes — focused `bun test tests/machineActions.test.ts` passed 9 tests
  with 28 expectations, `bun run check` passed, full `bun test` passed 69 tests
  with 180 expectations, frontend build and embedded-asset synchronization
  passed, both packaged-asset smoke modes passed sequentially, embedded assets
  matched byte-for-byte, `git diff --check` passed, `swift build` completed,
  and full `swift test` passed 236 tests in 55 suites before the command wrapper
  timeout — synchronized `index-CQCw7eat.css` and `index-DCxP8YVg.js`; the
  pre-existing low shared-SQLite contention risk is unchanged — next step is
  the repeated test-integrity gate.
- 2026-07-29 — STEP-7-ADVERSARIAL-PERSISTENCE-REVISION — complete — preserved
  opaque directory keys by binding explicit UTF-8 lengths and decoding SQLite
  text with `sqlite3_column_bytes`; made dashboard-state access wait up to five
  seconds for the shared database and reject non-row/non-done step results;
  extracted frontend state initialization so autosave is enabled only after a
  successful initial response; added embedded-NUL non-aliasing,
  exclusive-writer wait, successful initialization ordering, and failed-load
  autosave regressions — `swift test --filter DirectoryDisplayName` passed 9
  tests in 2 suites, full `swift test` passed 238 tests in 55 suites, focused
  frontend tests passed 27 tests with 81 expectations, full `bun test` passed
  71 tests with 184 expectations, and TypeScript emitted no errors before the
  environment wrapper timeout; `task frontend:build`, both packaged-asset
  smoke modes, `diff -qr frontend/dist Sources/AppCore/Resources/Web`, and
  `git diff --check` passed; focused SwiftLint emitted no findings before the
  wrapper timeout; synchronized `index-CQCw7eat.css` and
  `index-DNf5YEkQ.js` — both adversarial `mid` findings are addressed; the
  accepted low risk of unbounded authorized undiscovered-path rows remains —
  next step is repeated implementation review.
- 2026-07-29 — STEP-7-ADVERSARIAL-PARTIAL-FAILURE-REVISION — complete —
  changed `runMachineCatalogMutation` to retry machine, status, and
  subdirectory catalogs independently and preserve a committed mutation when
  refresh still fails; added a visible post-save reconciliation warning and
  production-boundary regressions for create, edit, toggle, and remove;
  replaced the SQLite contention test's fixed delay with an explicit
  task-start handshake; changed SQLite text decoding to failable UTF-8 and
  eliminated the focused SwiftLint warning — focused frontend tests passed 20
  tests with 82 expectations and TypeScript checking passed; focused Swift
  tests passed 9 tests in 2 suites and focused SwiftLint found 0 violations;
  full frontend tests passed 73 tests with 198 expectations; frontend build
  and embedded-asset synchronization produced `index-CQCw7eat.css` and
  `index-Bu7P_-yN.js`; `swift build` and all 238 Swift tests passed; both
  packaged-asset smoke modes, embedded-asset comparison, and `git diff
  --check` passed; full SwiftLint completed with 35 pre-existing warnings and
  0 serious violations — the accepted low risk of unbounded authorized
  undiscovered-path rows remains — next step is repeated implementation
  review.
- 2026-07-29 — STEP-7-ADVERSARIAL-MACHINE-LIFECYCLE-REVISION — complete —
  added a durable directory-name deletion marker and integrated its prepare,
  rollback, finalize, and id-reuse cleanup operations with the serialized
  machine-registry transaction; production CLI and menu-bar wiring share the
  lifecycle-aware name store; added store, failed-delete rollback, and full
  HTTP delete/recreate/catalog regressions; updated the architecture and
  completion criteria — `swift test --filter DirectoryDisplayName` passed 11
  tests, `swift test --filter MachineRegistryTransaction` passed 4 tests,
  `swift build` passed, and full `swift test` passed 241 tests in 55 suites;
  `cd frontend && bun test` passed 73 tests with 198 expectations and `cd
  frontend && bun run check` passed; focused SwiftLint completed with 0
  serious violations and only pre-existing warnings, while full SwiftLint
  printed its complete 35-warning, 0-serious result before the environment
  wrapper timeout; `git diff --check`, embedded-asset comparison, and the
  under-1000-line source audit passed — the machine-id inheritance finding is
  resolved; mounted Solid DOM coverage and authorized undiscovered-row bounds
  remain accepted low risks — next step is repeated implementation review.
- 2026-07-29 — STEP-6-IMPLEMENT-SELF-REVIEW — complete — found that the first
  lifecycle revision covered direct create/delete but not external registry
  reload or bulk replacement; moved metadata preparation, rollback, finalizing,
  and id-reuse cleanup to the shared registry membership transition and added
  a remove/re-add reload regression — `swift test --filter
  MachineRegistryTransaction` passed 5 tests and `swift test --filter
  DirectoryDisplayName` passed 11 tests; focused SwiftLint passed with zero
  findings; `swift build` passed; full `swift test` passed 242 tests in 55
  suites; `cd frontend && bun test` passed 73 tests with 198 expectations and
  `cd frontend && bun run check` passed — independent review may proceed.
- 2026-07-29 — STEP-7-ADVERSARIAL-CRASH-RECOVERY-REVISION — complete —
  added transactional startup reconciliation for directory-name deletion
  markers, wired it before both production routers, restored names for
  registered ids after interrupted rollback, completed cleanup for absent ids,
  and directly tested simultaneous SSH-machine addition/removal lifecycle
  behavior — `swift test --filter MachineRegistryTransaction` passed 6 tests;
  `swift test --filter DirectoryDisplayName` passed 13 tests; `swift build`
  passed; full `swift test` printed a complete 245-test, 55-suite pass before
  the environment wrapper timeout; `cd frontend && bun test` passed 73 tests
  with 198 expectations and `cd frontend && bun run check` passed; focused
  SwiftLint found only 2 pre-existing warnings and 0 serious violations, while
  full SwiftLint completed with the existing 35 warnings and 0 serious
  violations; `git diff --check`, embedded-asset comparison, and the
  under-1000-line source audit passed — the crash-consistency `mid` finding and
  simultaneous replacement coverage gap are resolved; mounted Solid DOM
  coverage remains an accepted low risk — next step is repeated implementation
  review.
- 2026-07-29 — STEP-7-ADVERSARIAL-CLEANUP-REVISION — complete — updated the
  workflow trace to session-648; made deletion finalization return completion
  state; retained committed registry deletion while recording, automatically
  retrying, catalog-retrying, and exposing pending metadata cleanup; made
  marked-machine set/clear rejection atomic with the name mutation; added
  stale-authorized-route, rollback recovery, failed-finalization retry, and SPA
  warning regressions — focused Swift tests passed 22 tests in 3 suites;
  targeted frontend tests passed 43 tests with 132 expectations; full `swift
  test` passed 248 tests in 55 suites before the command wrapper timeout; full
  `bun test` passed 75 tests with 201 expectations; `bun run check`, `swift
  build`, `task frontend:build`, both packaged-asset smoke modes, `diff -qr
  frontend/dist Sources/AppCore/Resources/Web`, and `git diff --check` passed;
  full SwiftLint completed with the existing 35 warnings and 0 serious
  violations; touched production Swift files remain below 1000 lines —
  synchronized `index-CQCw7eat.css` and `index-DSC9Inlb.js` — both session-648
  adversarial `mid` findings are addressed; mounted Solid DOM coverage and
  authorized undiscovered-row bounds remain accepted low risks — next step is
  repeated implementation and adversarial review.
- 2026-07-30 — STEP-7-IMPLEMENTATION-REVIEW-REVISION — complete — made the
  local `/api/subdirectories` route reject an unconfigured directory-name
  store with sanitized `503 directory_name_unavailable`; added the absent-store
  route regression and configured the existing inventory compatibility fixture;
  retained confirmed rename catalogs across failed reconciliation refetches,
  awaited and contained the refetch failure, and added a visible automatically
  cleared warning plus production-workflow regression — focused frontend tests
  passed 44 tests with 135 expectations, full frontend tests passed 76 tests
  with 204 expectations, `bun run check` passed, focused Swift route tests
  passed 7 tests, the directory regression suite passed 3 tests, and full
  `swift test` passed 249 tests in 55 suites before the command wrapper timeout;
  `swift build`, frontend build, both packaged-asset smoke modes, embedded-asset
  comparison, `git diff --check`, and source line-count checks passed; SwiftLint
  completed with 35 pre-existing warnings and 0 serious violations —
  synchronized `index-CQCw7eat.css` and `index-DWevJCDN.js` — both Step 7
  implementation-review `mid` findings are addressed; mounted Solid DOM
  coverage and authorized undiscovered-row bounds remain accepted low risks —
  next step is repeated test-integrity and implementation review.
- 2026-07-30 — STEP-7-IMPLEMENTATION-REVIEW-LIFECYCLE-REVISION — complete —
  added durable prepared/committed deletion-marker phases; registry
  transactions now promote deletion markers immediately after registry
  persistence and roll back both registry and metadata if promotion fails;
  startup preserves names only for interrupted prepared deletions and purges
  committed names before an externally re-added id becomes active; added
  direct restart/id-reuse, legacy-schema migration, and phase-commit rollback
  regressions — focused persistence and transaction tests passed 19 tests in 2
  suites; `swift build` passed; full `swift test` passed 252 tests in 55 suites;
  full frontend `bun test` passed 76 tests with 204 expectations; SwiftLint
  completed with 35 pre-existing warnings and 0 serious violations — next step
  is repeated implementation review.
- 2026-07-30 — STEP-7-ADVERSARIAL-ROLLBACK-REVISION — complete — separated
  registry persistence rollback success from runtime reconciliation failure so
  a failed deletion cancels its metadata tombstone whenever the durable
  registry was restored, while preserving the reconciliation-required latch
  for an incoherent runtime; added a double-runtime-failure restart regression
  proving the active machine retains its explicit directory names — `swift test
  --filter MachineRegistryTransactionTests` passed 9 tests before the command
  wrapper timeout; `swift build` passed and full `swift test` passed 253 tests
  in 55 suites before the wrapper timeout; full frontend `bun test` passed 76
  tests with 204 expectations and `bun run check` passed; focused SwiftLint
  found 0 violations, `git diff --check` passed, and touched production Swift
  files remain below 1000 lines — the compound rollback `mid` finding is
  addressed; mounted Solid DOM rename ordering, timer-driven cleanup timing,
  and authorized undiscovered-row bounds remain accepted low risks — next step
  is repeated implementation and adversarial review.
- 2026-07-30 — STEP-7-ADVERSARIAL-ROLLBACK-AMBIGUITY-REVISION — complete —
  added a durable rollback deletion-marker phase before registry restoration,
  removed that marker before runtime rollback, and made startup preserve active
  rollback metadata while continuing to purge committed id-reuse metadata;
  distinguished authoritative rename HTTP failures from lost, truncated, or
  timed-out responses and reconciled ambiguous outcomes against the normalized
  exact machine/path catalog value; added interruption, marker-cancellation,
  commit-then-response-loss, and unconfirmed-outcome regressions — focused
  Swift tests passed 29 tests in 3 suites; targeted frontend tests passed 47
  tests with 144 expectations; `swift build` and full `swift test` passed 255
  tests in 55 suites; full `bun test` passed 79 tests with 213 expectations;
  `bun run check`, `task frontend:build`, both packaged-asset smoke modes,
  embedded-asset comparison, and `git diff --check` passed; focused SwiftLint
  found 0 violations and full SwiftLint completed with 35 pre-existing warnings
  and 0 serious violations; production Swift files remain below 1000 lines;
  synchronized `index-CQCw7eat.css` and `index-Cv9jvAFc.js` — both latest Step
  7 adversarial `mid` findings are addressed; mounted Solid DOM rename ordering,
  timer-driven cleanup timing, and authorized undiscovered-row bounds remain
  accepted low risks — next step is repeated implementation and adversarial
  review.
- 2026-07-30 — STEP-6-SELF-REVIEW-AMBIGUOUS-WARNING-REVISION — complete —
  distinguished confirmed-save catalog refresh failures from ambiguous rename
  outcomes in the production callback; changed the ambiguous warning so it
  never claims persistence succeeded; added regression coverage for transport
  failure followed by catalog failure and retained the existing confirmed-save
  warning contract — focused frontend tests passed 14 tests with 59
  expectations; full frontend tests passed 80 tests with 220 expectations;
  the direct TypeScript compiler check passed with 0 errors after the `bun run
  check` wrapper timed out; `task frontend:build`, both packaged-asset smoke
  modes, embedded-asset comparison, and `git diff --check` passed; synchronized
  `index-CQCw7eat.css` and `index-Dfav_8ML.js` — the Step 6 self-review `mid`
  finding is addressed; mounted Solid DOM rename ordering, timer-driven cleanup
  timing, and authorized undiscovered-row bounds remain accepted low risks —
  next step is repeated self-review.

Future entries use:
`YYYY-MM-DD — TASK-NNN — status — changed files/deliverables — commands/results — findings addressed — limitations/residual risks — next task`.
