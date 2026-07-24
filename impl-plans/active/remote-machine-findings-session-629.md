# Remote-Machine Review Findings F-001 through F-004

**Status**: Ready for Implementation
**Workflow Mode**: issue-resolution
**Issue Reference**: `workflowExecution:codex-design-and-implement-review-loop-session-629`;
findings `F-001`, `F-002`, `F-003`, and `F-004`; source review
`codex-recent-change-quality-loop-session-628`.
**Design Review**: Accepted in `communication:comm-001514`; no high or mid
design findings remain.
**Codex Agent References**: None supplied. No reference-repository trace,
intentional divergence, or Cursor adapter boundary applies.

## Source of Truth

- `design-docs/specs/design-remote-machine-collection.md#serialized-registry-mutation-ownership`
- `design-docs/specs/design-remote-machine-collection.md#registry-http-contract`
- `design-docs/specs/design-remote-machine-collection.md#latest-event-and-last-hour-marker-contract`
- `design-docs/specs/design-remote-machine-collection.md#dashboard-ui`
- `design-docs/user-qa/2026-07-16-remote-machines-decisions.md#decisions`

The accepted design controls any ambiguity in this plan. Work is limited to
resolving F-001 through F-004 and their regression coverage. Existing unrelated
worktree changes, provider-neutral behavior, SSH safety, sanitized diagnostics,
and current-data exclusion semantics must remain intact.

## Baseline and Deliverables

The current code persists a registry mutation through
`MachineRegistryMutationOwner`, then separately calls
`MachineCollector.applyRegistry` from `MachineDashboardRouter`. The frontend
clears per-machine action state after awaited refetches, renders latest-event and
gap details below rather than over the graph, and offers create but not full edit
for SSH descriptors.

- [x] F-001: one serialized owner coordinates candidate validation, durable
  persistence, collector reconciliation, revision publication, rollback, and
  recovery state before an HTTP response.
- [x] F-002: every targeted-refresh outcome clears the per-machine in-flight
  state, including failed or aborted post-refresh refetches.
- [x] F-003: recognized unavailable cost-series responses remain observable and
  latest-event markers and gap spans render as non-interactive graph overlays.
- [x] F-004: existing SSH descriptors can be fully edited across direct, jump,
  and command proxy variants through the authoritative PUT contract.
- [x] Focused Swift and frontend regression coverage, synchronized packaged
  assets, and final repository verification evidence.

## Execution and Progress Rules

- Do not commit or push.
- Preserve unrelated user changes; inspect the scoped diff before each task and
  at closeout.
- Prefer the existing `AppCore` target and dependency-injected filesystem,
  clock, collector, and fetch boundaries for deterministic failures.
- Keep every non-generated Swift file below 1000 lines. Do not add tests to
  `Tests/AppCoreTests/CCUsageTests.swift`, currently near the limit.
- Split `frontend/src/App.tsx`, currently over 1000 lines, by machine-admin,
  action-state, chart, and unavailable-response responsibilities before adding
  more UI behavior.
- Run the narrowest relevant test after each task. Run SwiftLint after Swift
  edits when available; record `swiftlint` as unavailable rather than silently
  skipping it.
- A task is complete only when its checkbox is backed by command evidence.
- After every task, append a dated Progress Log entry containing status, finding
  IDs, changed files, exact commands and results, limitations, residual risks,
  and the next task.

## TASK-001: Make Registry Mutation and Collector Reconciliation One Transaction

**Findings**: F-001
**Depends On**: None
**Parallelizable**: No

**Write Scope**:

- `Sources/AppCore/Machines.swift`
- `Sources/AppCore/MachineCollection.swift`
- `Sources/AppCore/MachineDashboardRouter.swift`
- new registry-transaction files under `Sources/AppCore/` if needed to preserve
  responsibility and file-length boundaries
- `Tests/AppCoreTests/MachineRegistryTransactionTests.swift`
- existing machine-route tests only where shared fixtures must be extended

**Work**:

1. Introduce an injected registry-runtime reconciliation boundary owned by the
   process-wide mutation actor. Route POST, PUT, PATCH, DELETE, and registry
   reload through that owner; the router must no longer persist first and call
   `collector.applyRegistry` separately.
2. For each queued mutation, derive and validate a complete candidate from the
   latest committed revision, stage every throwing collector/service dependency,
   retain validated prior registry bytes, and durably stage the candidate with
   synchronized same-directory atomic replacement.
3. Reconcile only affected generations: increment fences, cancel and await old
   pollers/in-flight loads, stage status/snapshot retention or removal, and
   install the enabled replacement. Publish the candidate registry, reconciled
   runtime, and advanced revision at one reader-visible boundary.
4. Define deterministic failure injection for persistence, runtime
   reconciliation, disk rollback, and runtime rollback. A clean rollback
   restores prior disk/runtime and returns
   `500 registry_reconciliation_failed` with
   `reconciliationRequired: false`.
5. If either rollback cannot restore coherence, retain the last published
   revision and reader-visible snapshot/status, stop the affected poller, latch
   reconciliation-required health, return
   `registry_reconciliation_failed` with `reconciliationRequired: true`, and
   reject later mutations with `503 registry_reconciliation_required`.
6. On restart, load one complete persisted revision, stage and reconcile all
   runtime dependencies before listener/poller publication, and clear the latch
   only after successful recovery.
7. Preserve revision/generation fencing so late results from cancelled,
   replaced, or removed pollers cannot publish.

**Deliverables**:

- a single mutation/reload transaction API consumed by the router;
- explicit clean-rollback and failed-rollback response mapping;
- reader-visible reconciliation-required health and restart recovery; and
- deterministic concurrency, ordering, rollback, latch, and late-publication
  tests.

**Completion Criteria**:

- [x] Concurrent create/replace/patch/delete requests linearize against the
  latest committed revision and lose no updates.
- [x] No HTTP success is returned until disk, published revision, snapshot/status
  state, and affected collector generation agree.
- [x] Persistence or prepublication staging failures expose no candidate state.
- [x] Both successful and failed rollback paths produce the exact accepted
  envelopes and recovery behavior.
- [x] Unaffected pollers continue and stale generations cannot publish.
- [x] Every touched non-generated Swift file remains below 1000 lines.

**Verification**:

- `swift test --filter MachineRegistryTransactionTests`
- `swift test --filter MutationPolicyTests`
- `swift test --filter MachineStatusTests`
- `swift build`
- `swiftlint Sources Tests`

## TASK-002: Extract Frontend Boundaries and Guarantee Action Cleanup

**Findings**: F-002
**Depends On**: TASK-001
**Parallelizable**: No

**Write Scope**:

- `frontend/src/App.tsx`
- `frontend/src/machineActions.ts`
- `frontend/src/MachineAdminPanel.tsx`
- `frontend/src/UsageChart.tsx`
- `frontend/src/machineAdmin.css`
- `frontend/src/usageChart.css`
- `frontend/src/styles.css` only for extraction/import cleanup
- `frontend/tests/machineActions.test.ts`
- existing frontend tests only where imports move without behavior change

**Work**:

1. Extract machine administration, machine action orchestration, and usage-chart
   rendering from `App.tsx` with explicit typed props and no behavior change.
   Establish the disjoint write scopes used by TASK-003 and TASK-004.
2. Model one per-machine action lifecycle that owns the targeted refresh request
   and all post-refresh refetches. Keep duplicate Test, Refresh, Edit,
   Enable/Disable, and Remove controls disabled only while that lifecycle is
   active.
3. Use one unconditional completion boundary that clears the in-flight state
   after request rejection, decoded `status: "failed"`, successful refetch, or
   any rejected/aborted refetch.
4. Preserve the action diagnostic until the next action or edit. Route refetch
   errors through the ordinary dashboard-load error surface without replacing
   the retained diagnostic.
5. Refetch registry, machine status, current metrics, cost series, and budget
   after both successful and failed targeted refresh results. A failed
   connection test performs no refetch.

**Deliverables**:

- maintainable frontend component/action boundaries;
- unconditional per-machine action cleanup; and
- deterministic request, decoded-failure, refetch-failure, abort, and retry
  tests.

**Completion Criteria**:

- [x] Every action/refetch outcome re-enables controls without a page reload.
- [x] A later action can start after any failed or aborted refetch.
- [x] A refetch failure preserves the action diagnostic and reaches the normal
  load-error surface.
- [x] `App.tsx` is reduced below 1000 lines with cohesive extracted components.

**Verification**:

- `cd frontend && bun test tests/machineActions.test.ts`
- `cd frontend && bun test`
- `task frontend:check`

## TASK-003: Preserve Unavailable Cost-Series State and Render Graph Overlays

**Findings**: F-003
**Depends On**: TASK-002
**Parallelizable**: Yes, in parallel with TASK-004 only; write scopes are
disjoint after TASK-002.

**Write Scope**:

- `frontend/src/api.ts`
- `frontend/src/costSeriesState.ts`
- `frontend/src/UsageChart.tsx`
- `frontend/src/usageChart.css`
- `frontend/src/machineObservability.ts`
- `frontend/tests/costSeriesState.test.ts`
- `frontend/tests/usageChart.test.tsx`
- `Tests/AppCoreTests/MachineUnavailableResponseTests.swift`
- backend DTO/router files only if the contract test proves an accepted
  unavailable envelope is incomplete

**Work**:

1. Decode `snapshot_unavailable`, `current_data_unavailable`, and
   `range_unavailable` cost-series responses into a typed observable data state
   rather than reducing them to a generic fetch error. Preserve sanitized error,
   full scope, availability, refresh interval, requested/available coverage,
   `machineLatestEvents`, and last-hour gaps.
2. Add Swift contract tests proving every recognized availability response
   contains the accepted metadata for every resolved selected machine. Make
   only the narrowest server correction required if a test exposes a gap.
3. Pass success and recognized-unavailable marker/gap metadata to
   `UsageChart`. For sub-daily graphs, render markers at `latestEventAt` and
   clipped last-hour gap spans in a dedicated SVG overlay sharing the chart
   domain.
4. Keep overlays non-interactive and independent of series rows, axes, totals,
   and tooltips. Distinguish observed, no-event, stale, and unavailable states.
5. Keep adjacent accessible text for off-domain or missing events: latest time,
   No event, Stale since, or Unavailable since. Never imply that stale rows
   contributed to current totals.

**Deliverables**:

- typed observable unavailable-response state;
- backend envelope contract coverage;
- SVG marker and gap overlay rendering; and
- response-state, clipping, accessibility, off-domain, and no-row tests.

**Completion Criteria**:

- [x] Recognized unavailable responses retain all accepted observability data.
- [x] Markers and gaps overlay sub-daily charts even when no series rows are
  eligible.
- [x] Overlays do not alter axes, totals, data eligibility, or chart
  interaction.
- [x] Missing/off-domain markers remain understandable through accessible text.

**Verification**:

- `swift test --filter MachineUnavailableResponseTests`
- `cd frontend && bun test tests/costSeriesState.test.ts`
- `cd frontend && bun test tests/usageChart.test.tsx`
- `task frontend:check`
- `swiftlint Sources Tests` when backend Swift changes

## TASK-004: Add Complete Existing-Machine SSH and Proxy Editing

**Findings**: F-004
**Depends On**: TASK-002
**Parallelizable**: Yes, in parallel with TASK-003 only; write scopes are
disjoint after TASK-002.

**Write Scope**:

- `frontend/src/MachineAdminPanel.tsx`
- `frontend/src/machineForm.ts`
- `frontend/src/machineAdmin.css`
- `frontend/tests/machineForm.test.ts`
- `frontend/tests/machineAdminPanel.test.tsx`

**Work**:

1. Define a typed form draft shared by create and edit. Initialize edit from the
   selected persisted descriptor with display name, enabled state, host, port,
   user, identity file, all allowlisted `extraOptions`, remote executable path,
   and complete direct/jump/command proxy discriminator and fields.
2. Keep machine id visible and immutable. Switching proxy kind clears fields
   owned only by the previous variant.
3. Apply the same field-level validation and closed proxy union to create and
   edit. Expose structured allowlisted options only; add no raw SSH argv, shell
   command, environment, credential-content, or unbounded proxy field.
4. Save edit as one full `PUT /api/machines/{id}` replacement. Update/close only
   after the persisted response succeeds. On validation or request failure,
   preserve the prior row and the complete draft with a field-specific error.
5. Cancel performs no request or mutation. Starting an edit clears the prior
   action diagnostic as defined by the design.

**Deliverables**:

- shared create/edit draft and validation;
- complete direct/jump/command edit UI;
- full PUT persistence; and
- initialization, variant-switch, validation, success, failure, and cancel
  regression tests.

**Completion Criteria**:

- [x] Every persisted SSH and proxy field round-trips through edit without loss.
- [x] Direct, jump, and command variants initialize and save correctly.
- [x] Failed saves retain both the prior row and all entered draft values.
- [x] Machine id cannot be changed and cancel performs no network request.

**Verification**:

- `cd frontend && bun test tests/machineForm.test.ts`
- `cd frontend && bun test tests/machineAdminPanel.test.tsx`
- `task frontend:check`

## TASK-005: Integrate, Package, and Close the Four Findings

**Findings**: F-001, F-002, F-003, F-004
**Depends On**: TASK-001, TASK-002, TASK-003, TASK-004
**Parallelizable**: No

**Write Scope**:

- generated `Sources/AppCore/Resources/Web/` from the verified frontend build
- focused test/smoke fixtures required to close the four findings
- `scripts/smoke-dashboard.sh` and `scripts/smoke-remote-machines.sh` only when
  needed for accepted end-to-end assertions
- `README.md`, `design-docs/specs/architecture.md`,
  `design-docs/specs/command.md`, and
  `design-docs/specs/client-commands.md` only where implementation status or
  operator-facing behavior must be synchronized with the accepted design
- this implementation plan's Progress Log

**Work**:

1. Run the focused finding suites first and correct only regressions introduced
   within this plan's scope.
2. Run full Swift/frontend verification, then build and synchronize packaged
   frontend assets.
3. Exercise one successful mutation transaction, clean reconciliation rollback,
   failed rollback latch/restart recovery, failed post-refresh refetch,
   unavailable overlay, and edit round-trip at the highest deterministic level
   supported by the repository.
4. Inspect the final scoped diff for unrelated changes, generated-asset drift,
   sensitive material, provider-specific branching, unsafe host-key advice, raw
   diagnostics, and non-generated Swift files at or above 1000 lines.
5. Audit README, architecture, command, and client-command documentation against
   the implemented transaction errors, unavailable-state presentation, and
   machine editing behavior. Apply only synchronization corrections; route any
   proposed contract change back to design review.
6. Record exact pass/fail/unavailable evidence and residual risks in the
   Progress Log. Do not claim an unavailable environment-dependent smoke check
   passed.

**Deliverables**:

- synchronized source and packaged frontend assets;
- complete focused and full verification evidence; and
- operator and architecture documentation synchronized with implemented
  behavior; and
- issue-by-issue closeout mapping for F-001 through F-004.

**Completion Criteria**:

- [x] F-001 has concurrent mutation and both rollback-path evidence.
- [x] F-002 has failed/aborted refetch cleanup and subsequent-action evidence.
- [x] F-003 has unavailable response-state and in-chart overlay evidence.
- [x] F-004 has complete SSH/proxy edit persistence and failure-retention
  evidence.
- [x] All required full gates pass, or any external limitation is explicit.
- [x] README and architecture/command documentation match the accepted design
  and implemented behavior, with no unreviewed contract changes.
- [x] Unrelated user changes remain untouched and no commit or push occurred.

**Verification**:

- `task test`
- `task test:coverage`
- `task lint`
- `task frontend:test`
- `task frontend:check`
- `task frontend:build`
- `nix flake check`
- `task smoke:isolated-runtime`
- `task smoke:dashboard`
- `task smoke:remote-machines`
- `git diff --check`
- `rg --files -g '*.swift' | xargs wc -l | sort -nr`
- `git status --short`

## Dependency Summary

```text
TASK-001 -> TASK-002 -> TASK-003 --\
                     \-> TASK-004 ----> TASK-005
```

TASK-003 and TASK-004 are the only parallel window. They start after TASK-002
extracts stable component boundaries and must retain the disjoint write scopes
listed above. Any newly discovered shared-file edit closes that parallel window
and requires serial execution.

## Overall Completion Criteria

- Disk, published registry revision, collector generation, and reader-visible
  status are coherent at every successful registry response.
- Registry rollback and restart recovery are deterministic and fail closed.
- Machine controls cannot remain disabled after refresh/refetch failure.
- Unavailable responses preserve observability, and markers/gaps are true graph
  overlays with accessible fallback labels.
- Existing SSH descriptors round-trip every editable direct/jump/command field.
- Focused tests map one-to-one to F-001 through F-004, full gates pass, packaged
  assets match frontend source, and unrelated worktree changes remain intact.

## Risks and Mitigations

- **Cross-resource atomicity**: filesystem and runtime state cannot share a
  native transaction. Use staged dependencies, one actor-owned publication
  point, compensating rollback, revision/generation fences, and a fail-closed
  reconciliation latch.
- **Rollback tests becoming nondeterministic**: inject persistence and runtime
  boundaries instead of relying on timing or real filesystem faults.
- **Frontend state hidden by generic resource errors**: model recognized
  availability payloads as data states and reserve the generic boundary for
  malformed or unrelated errors.
- **Overlay geometry drift**: derive bars, markers, and spans from one chart
  domain and test clipping at both visible boundaries.
- **Edit field loss across proxy variants**: use one typed draft serializer and
  explicit variant clearing with round-trip fixtures for every union case.
- **Concurrent task conflicts**: permit only TASK-003/TASK-004 parallelism and
  stop parallel work if either needs a shared file.
- **Dirty worktree overlap**: inspect scoped diffs before edits and preserve all
  unrelated user changes.

## Addressed Feedback

- Step 3 accepted the design with no revision request.
- DSR-001 is reflected in TASK-001's exact reconciliation envelopes, latch,
  rollback paths, and restart recovery.
- DSR-002 is reflected in TASK-003's complete `range_unavailable` metadata and
  overlay consumption.
- Step 3 acceptance for F-001 through F-004 maps directly to TASK-001 through
  TASK-004, with TASK-005 providing independent closeout evidence.

## Progress Log

- 2026-07-24: Plan created for workflow session 629. Status is Ready for
  Implementation. No implementation code, commit, or push performed.
- 2026-07-24: F-001 through F-004 implemented and independently reverified.
  `task test` passed 151 tests in 36 suites; `task frontend:test` passed 22
  tests; `task frontend:check`, `task frontend:build`, `task build`,
  `nix flake check`, `nix develop -c task lint`, `task smoke:assets`,
  `task smoke:isolated-runtime`, `task smoke:dashboard`,
  `task smoke:remote-machines`, and `git diff --check` passed. SwiftLint
  reported 29 warnings and zero serious violations. All source Swift files and
  `frontend/src/App.tsx` remain below 1000 lines. The implementation remains
  provider-neutral; GCE/IAP occur only as motivating documentation examples and
  in a negative-output assertion. Full completion remains open because measured
  AppCore/AppCLI executable-line coverage is 76.01%, below the accepted 80.0%
  gate. The existing coverage script was not changed. No commit or push was
  performed.
- 2026-07-24: Closeout completed after Swift 6.3 coverage compatibility,
  cache-lifecycle and mutation-policy coverage, unavailable-scope regression
  tests, all-unavailable UI handling, and hardened bootstrap-log fallback/write
  behavior were added. `task test` passed 164 tests in 37 suites;
  `task test:coverage` passed at 80.22% (7124/8881); frontend tests passed 24
  tests; frontend typecheck/build, Swift build, Nix-shell SwiftLint (32
  warnings, zero serious), `nix flake check`, all asset/isolated/dashboard/remote
  smoke tests, Formula and Cask dry runs, and `git diff --check` passed. Riela
  final review session `ccusage-gauge-final-review-session-6` accepted the
  implementation with no findings. No commit or push was performed.
