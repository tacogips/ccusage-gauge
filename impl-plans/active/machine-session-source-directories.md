# Per-machine Codex and Claude Session-source Directories

**Status**: Implemented and Verified
**Workflow Mode**: issue-resolution
**Issue Reference**: workflow-input issue “Per-machine configurable
Codex/Claude session-source directories with default-dir opt-out”;
`workflowExecution:codex-design-and-implement-review-loop-session-641`
**Design Review**: Accepted after resolving the three Step 3 mid-severity
findings from workflow execution
`codex-design-and-implement-review-loop-session-640`.
**Codex Agent References**: None supplied. No external reference-repository
trace, intentional divergence, or Cursor adapter boundary applies.

## Source of Truth

- `design-docs/specs/design-machine-session-source-directories.md`
- `design-docs/specs/design-remote-machine-collection.md`
- `design-docs/specs/architecture.md`
- `design-docs/specs/command.md`
- `design-docs/specs/client-commands.md`

The accepted session-source design controls whenever this plan is less
specific. Implementation must preserve its backward-compatible omitted-field
defaults, schema-version-3 migration, local/SSH parity, source isolation,
path/command sanitization, deduplication, cache invalidation, and generation
fencing.

## Current Baseline

- `MachineDescriptor` has only identity, display, kind, enabled, and SSH fields.
- The closed persisted registry writes schema version 2, stores only SSH
  descriptors, and synthesizes a fixed local descriptor.
- `CodexUsageEventLoader.production` and
  `ClaudeUsageEventLoader.production` each select one default local root.
- `LocalCCUsageCommandRunner` and `SSHCCUsageCommandRunner` execute one
  environment-independent `ccusage` command per request.
- `SnapshotService` and `UsageAggregationCache` have no source-plan
  fingerprint.
- Machine HTTP CRUD, CLI add/list/show, and the dashboard admin form do not
  expose session-source configuration.
- `MachineCollection.swift` and `MachineDashboardRouter.swift` are already near
  the 1000-line limit; behavior additions require responsibility-based splits.
- `Tests/AppCoreTests/CCUsageTests.swift` and
  `Tests/AppCoreTests/MachineTests.swift` are also near the limit; new coverage
  belongs in focused new test files.

## Deliverables

- [x] Backward-compatible machine source fields and indexed path validation.
- [x] Closed registry schema version 3 with persisted local source settings,
  deterministic version-1/version-2 migration, rollback, and fail-closed load.
- [x] One immutable per-attempt source plan for local and SSH machines, with
  default opt-out, path resolution, containment/alias deduplication, and
  missing-source handling.
- [x] Local JSONL event aggregation and local/SSH multi-source `ccusage`
  aggregation with per-agent environment isolation.
- [x] Source-plan cache fingerprints and registry/collector/source-generation
  publication fencing.
- [x] Additive HTTP create/replace/patch/read contracts, including
  `PATCH /api/machines/local`.
- [x] CLI add/update/show support and dashboard repeatable source editors for
  local and SSH machines.
- [x] Focused Swift, CLI, and frontend tests plus complete verification evidence
  without a version bump or unrelated changes.

## Execution Rules

- Remain on `feature/machine-session-dirs`; do not switch branches.
- Preserve unrelated worktree changes and do not modify version declarations.
- Treat configured paths only as data. They may never select an executable,
  argument, environment-variable name, or shell fragment.
- Preserve raw environment-derived default semantics while keeping those values
  out of API, UI, diagnostics, logs, and fingerprints returned to clients.
- Keep every non-generated Swift file below 1000 lines. Split
  `MachineCollection.swift` and `MachineDashboardRouter.swift` by
  responsibility before adding behavior; create new focused test files instead
  of extending near-limit test files.
- Use existing SwiftPM targets and injected process/filesystem seams.
- After each Swift task, run the narrowest relevant tests and `mise run lint`.
- A focused suite must appear in `swift test list` before an exact
  `swift test --filter <SuiteName>` result is accepted; a zero-test match fails
  verification.
- After each task, append a dated Progress Log entry containing status, files,
  commands/results, findings addressed, limitations, residual risks, and the
  next task. Checkboxes record evidence, not intent.

## Dependency Graph

```text
TASK-001
   |
TASK-002
   |
TASK-003
   |
TASK-004
  /     \
TASK-005 TASK-006
  \     /
 TASK-007
```

Only TASK-005 and TASK-006 are parallelizable; their AppCLI/test and
frontend/test write scopes are disjoint after TASK-004 stabilizes the API.

## TASK-001: Add the Source Model, Validation, and Registry Version 3

**Depends On**: None

**Design References**:

- `design-machine-session-source-directories.md#goal-and-scope`
- `design-machine-session-source-directories.md#validation-and-normalization`
- `design-machine-session-source-directories.md#registry-persistence-and-compatibility`

**Write Scope**:

- `Sources/AppCore/Machines.swift`
- registry persistence files split from `Machines.swift` if needed
- `Sources/AppCore/MachineRegistryTransaction.swift`
- `Tests/AppCoreTests/MachineSessionSourceRegistryTests.swift`
- `Tests/AppCoreTests/MachineRegistryTransactionTests.swift`

**Parallelizable**: No. This defines shared models and persistence semantics for
every later task.

**Work**:

1. Add `codexSessionDirs`, `claudeConfigDirs`,
   `includeDefaultCodexDir`, and `includeDefaultClaudeDir` to
   `MachineDescriptor`, with initializer defaults of `[]`, `[]`, `true`, and
   `true`.
2. Make non-registry descriptor decoding use `decodeIfPresent` defaults so
   legacy API/test payloads remain compatible. Encode normalized fields in new
   responses and persisted version-3 descriptors.
3. Validate each configured path independently: 1...4096 UTF-8 bytes, absolute
   `/...`, exactly `~`, or `~/...`; reject NUL, CR/LF, ASCII controls,
   `~user`, and relative paths. Return indexed field keys.
4. Extend `MachineRegistry` to carry local source settings while retaining the
   synthesized immutable local identity/kind/enabled fields.
5. Write only the closed version-3
   `schemaVersion`/`localSessionSources`/`machines` envelope. Preserve ordered
   arrays and deterministic machine ordering.
6. Migrate exact valid version-1 and version-2 inputs atomically to version 3
   before publication. Preserve source bytes/runtime state on failure and keep
   unknown, duplicate, malformed, or unsupported representations fail-closed.
7. Extend registry transactions so local-source changes and SSH descriptor
   changes share persistence, rollback, revision, and runtime reconciliation.

**Deliverables**:

- additive descriptor/source model;
- indexed validation errors;
- persisted local settings and canonical version-3 registry;
- exact legacy migration and rollback coverage.

**Completion Criteria**:

- [x] Legacy descriptors without source fields decode to existing default
  behavior.
- [x] Valid version-1/version-2 registries migrate once to canonical version 3.
- [x] Version-3 round-trip preserves every source value and local configuration.
- [x] Invalid paths map to the exact indexed field while independent errors are
  retained.
- [x] Migration or reconciliation failure publishes no partial registry/runtime
  state.

**Verification**:

- `swift test list | rg "MachineSessionSourceRegistryTests|Machine registry transaction"`
- `swift test --filter MachineSessionSourceRegistryTests`
- `swift test --filter MachineRegistryTransactionTests`
- `mise run lint`

## TASK-002: Build Per-attempt Source Plans and Local Multi-root Loading

**Depends On**: TASK-001

**Design References**:

- `design-machine-session-source-directories.md#source-configuration-and-defaults`
- `design-machine-session-source-directories.md#collection-data-flow`

**Write Scope**:

- new `Sources/AppCore/MachineSessionSourcePlan.swift`
- `Sources/AppCore/CodexUsageEvents.swift`
- `Sources/AppCore/ClaudeUsageEvents.swift`
- new `Tests/AppCoreTests/MachineSessionSourcePlanTests.swift`
- new `Tests/AppCoreTests/MultiRootUsageEventTests.swift`

**Parallelizable**: No. The resolved plan becomes the input contract for remote
collection and cache fencing.

**Work**:

1. Build separate Codex and Claude plans at the start of every collection
   attempt from immutable descriptor settings and current host environment.
2. Include each effective default only when enabled; append configured roots in
   stored order; expand explicit `~`; standardize paths; resolve existing
   symlink aliases; and append the agent-specific `sessions/` or `projects/`
   scan scope.
3. Deduplicate equal and contained scopes from shallowest to deepest while
   preserving deterministic tie order. Retain lexical identity for missing
   paths and skip missing/non-directory scopes without failing.
4. Keep environment-derived empty/relative defaults compatible with the
   existing local URL/process semantics and never expose their values.
5. Load all selected local roots through the existing event loaders and merge
   by stable Codex/Claude event identity.
6. Treat defaults-disabled with no explicit roots as a valid healthy empty
   source plan.

**Deliverables**:

- immutable per-attempt plan and resolved source identities;
- deterministic equal/nested/symlink deduplication;
- multi-root local event loading for both agents;
- valid empty-source behavior.

**Completion Criteria**:

- [x] Two disjoint roots contribute to one machine's totals for each agent.
- [x] Equal, nested, and symlink-alias selections do not double count.
- [x] Disabled defaults contribute nothing.
- [x] Missing roots are skipped and a later attempt observes a newly created or
  retargeted source.
- [x] One attempt never changes its captured plan mid-load.

**Verification**:

- `swift test list | rg "MachineSessionSourcePlanTests|MultiRootUsageEventTests"`
- `swift test --filter MachineSessionSourcePlanTests`
- `swift test --filter MultiRootUsageEventTests`
- `mise run lint`

## TASK-003: Add Isolated Multi-source Commands, Cache Fingerprints, and Fencing

**Depends On**: TASK-002

**Design References**:

- `design-machine-session-source-directories.md#collection-data-flow`
- `design-machine-session-source-directories.md#cache-coherence`
- `design-remote-machine-collection.md#ssh-command-boundary-and-allowlist`

**Write Scope**:

- `Sources/AppCore/CCUsageCommandRunner.swift`
- `Sources/AppCore/CCUsage.swift`
- new `Sources/AppCore/CCUsageMultiSourceCoordinator.swift`
- `Sources/AppCore/Snapshot.swift`, split by source-loading responsibility if
  additions would approach 1000 lines
- `Sources/AppCore/AggregationCache.swift`
- `Sources/AppCore/CostSnapshotMerge.swift`
- `Sources/AppCore/MachineCollectorRangeLoading.swift`
- `Sources/AppCore/MachineRangeLoad.swift`
- `Sources/AppCore/MachineCollection.swift`, split before behavior changes
- new `Tests/AppCoreTests/MultiSourceCommandTests.swift`
- new `Tests/AppCoreTests/SourceFingerprintCacheTests.swift`
- `Tests/AppCoreTests/CCUsageCommandRunnerTests.swift`

**Parallelizable**: No. Command merging, cache reuse, and publication fencing
must be completed as one coherent collection contract.

**Work**:

1. Add a typed internal source context to local and SSH runners. Derive a fresh
   local environment per invocation and mutate only `CODEX_HOME` and
   `CLAUDE_CONFIG_DIR`; isolate the non-selected agent with the fixed
   non-directory sentinel.
2. Implement the SSH fixed positional adapter and one path-probe operation per
   attempt. Pass agent, raw execution value, validated executable, and fixed
   ccusage arguments only as separately quoted positional values. Retain
   current direct suffixes for unsourced diagnostics.
3. Execute fixed block/daily/session work once per selected agent source.
   Retry only a failed source invocation and fail the machine rather than
   publish partial totals when a selected existing source fails.
4. Merge decoded rows deterministically under one machine id: sum numeric
   fields by the accepted aggregation keys, union models, retain source event
   identities once, and stamp machine provenance after source-local merge.
5. Count source/range work units in progress while preserving one public
   snapshot/health result per machine.
6. Persist an internal source-configuration fingerprint containing the
   semantics version, agent, include-default flags, normalized roots, and
   current resolved plan including missing/non-directory state.
7. Before cache reuse, purge the affected machine cache on a missing/mismatched
   fingerprint. Advance source generation and fence publication by registry
   revision, collector generation, and plan fingerprint.
8. Split near-limit collection files by source-planning, range-loading, or
   publication responsibility before adding code.

**Deliverables**:

- source-aware local and SSH command execution;
- fixed remote adapter/probe with no raw shell interpolation;
- deterministic aggregate merging;
- cache fingerprint storage/invalidation;
- per-attempt generation fencing and progress accounting.

**Completion Criteria**:

- [x] Local and SSH multi-source totals include every disjoint selected source
  exactly once.
- [x] The other agent's enabled default is not repeated per source invocation.
- [x] Configured strings cannot alter executable, argv shape, environment name,
  or adapter source.
- [x] Missing-to-present, symlink-retarget, and remote-default changes invalidate
  stale cache state before reuse.
- [x] An older in-flight plan cannot publish after a source-generation advance.
- [x] One source failure publishes no partial machine snapshot.

**Verification**:

- `swift test list | rg "MultiSourceCommandTests|SourceFingerprintCacheTests|CCUsageCommandRunnerTests"`
- `swift test --filter MultiSourceCommandTests`
- `swift test --filter SourceFingerprintCacheTests`
- `swift test --filter CCUsageCommandRunnerTests`
- `mise run lint`

## TASK-004: Extend Machine HTTP Contracts and Runtime Mutation

**Depends On**: TASK-003

**Design References**:

- `design-machine-session-source-directories.md#http-contract`
- `design-machine-session-source-directories.md#dashboard-contract`
- `architecture.md#remote-machine-collection`

**Write Scope**:

- `Sources/AppCore/MachineHTTPModels.swift`
- `Sources/AppCore/DashboardAPIModels.swift`
- `Sources/AppCore/DashboardAPIClient.swift`
- `Sources/AppCore/MachineRegistryTransaction.swift`
- `Sources/AppCore/MachineDashboardRouter.swift`, split into a focused machine
  route file before additions
- new `Tests/AppCoreTests/MachineSessionSourceAPITests.swift`
- `Tests/AppCoreTests/MachineRegistryTransactionTests.swift`

**Parallelizable**: No. This stabilizes the API and mutation boundary consumed
by CLI and frontend work.

**Work**:

1. Add optional source fields to create/replace request decoding with omitted
   defaults; add tri-state optional fields to patch decoding so omission
   preserves and an explicit empty array clears.
2. Return normalized fields on all machine reads, including `local`.
3. Accept source fields on SSH POST/PUT/PATCH and accept only those four fields
   on `PATCH /api/machines/local`. Preserve local identity/kind/enabled/SSH
   immutability and current PUT/DELETE conflict behavior.
4. Keep unknown fields/type/shape errors at `400`; return indexed
   `422 invalid_machine` validation errors.
5. Persist first, reconcile the affected service/source generation, fence older
   publication, and return only after disk/runtime/revision agree. Preserve
   existing rollback and reconciliation-required behavior.
6. Keep responses limited to configured strings; do not expose expanded paths,
   remote probe results, environment values, argv, stderr, or credentials.

**Deliverables**:

- additive HTTP and dashboard-client DTOs;
- SSH and local source mutations;
- stable field errors and sanitization;
- API/reconciliation integration tests.

**Completion Criteria**:

- [x] Create/update/read round-trips all four fields for local and SSH machines.
- [x] Omitted legacy fields keep default locations enabled.
- [x] Empty arrays and false flags survive persistence and response encoding.
- [x] Indexed invalid paths return `422`; malformed/unknown JSON remains `400`.
- [x] Failed persistence or runtime reconciliation returns no partially applied
  source configuration.

**Verification**:

- `swift test list | rg "MachineSessionSourceAPITests|Machine registry transaction"`
- `swift test --filter MachineSessionSourceAPITests`
- `swift test --filter MachineRegistryTransactionTests`
- `mise run lint`

## TASK-005: Add CLI Source Creation, Update, and Rendering

**Depends On**: TASK-004

**Design References**:

- `design-machine-session-source-directories.md#cli-contract`
- `client-commands.md#command-tree`
- `client-commands.md#http-mapping`

**Write Scope**:

- `Sources/AppCLI/Commands/ClientMachineCommands.swift`
- `Sources/AppCLI/Rendering/MachineRenderer.swift`
- `Tests/AppCLITests/ParsingTests.swift`
- `Tests/AppCLITests/RendererTests.swift`
- `Tests/AppCLITests/IntegrationTests.swift`

**Parallelizable**: Yes, with TASK-006 after TASK-004.

**Work**:

1. Add repeatable create options and default-exclusion flags.
2. Add `client machines update <id>` with replace-list semantics, explicit
   clear-list flags, mutually exclusive include/exclude pairs, tri-state patch
   values, and a no-fields usage error.
3. Render configured strings and include-default values in list/show/add/update
   output without resolving paths or reading identity files.
4. Add parser, exact request-body/header, renderer, and server round-trip tests
   for local and SSH updates.

**Completion Criteria**:

- [x] CLI add and update emit the exact accepted JSON and mutation header.
- [x] Omitted update flags preserve server state; clear flags send empty arrays.
- [x] Conflicting include/exclude flags and empty updates fail as usage errors.
- [x] Human and JSON output expose configured values only.

**Verification**:

- `swift test --filter CommandParsingTests`
- `swift test --filter RendererTests`
- `swift test --filter ClientServerRoundTripTests`
- `swift run ccusage-gauge client machines update --help`
- `mise run lint`

## TASK-006: Add Dashboard Source Editors and Error Mapping

**Depends On**: TASK-004

**Design References**:

- `design-machine-session-source-directories.md#dashboard-contract`

**Write Scope**:

- `frontend/src/api.ts`
- `frontend/src/machineForm.ts`
- `frontend/src/machineActions.ts`
- `frontend/src/MachineAdminPanel.tsx`
- frontend styles used by the admin panel
- `frontend/tests/api.test.ts`
- `frontend/tests/machineForm.test.ts`
- `frontend/tests/machineActions.test.ts`
- `frontend/tests/machineAdminPanel.test.ts`
- generated `Sources/AppCore/Resources/Web/` assets only through
  `mise run frontend:build`

**Parallelizable**: Yes, with TASK-005 after TASK-004.

**Work**:

1. Carry all four fields in machine/API types and initialize edit/create drafts
   from normalized server values.
2. Add ordered repeatable Codex and Claude directory rows, Add/Remove controls,
   and include-default checkboxes for local and SSH machines.
3. Preserve SSH-only controls and fields; local saves use PATCH and expose no
   enable/disable, delete, test-connection, or SSH fields.
4. Mirror path validation for immediate feedback while keeping server
   validation authoritative.
5. Map indexed server field keys to the corresponding row and show unmapped
   errors in the form-level alert.
6. Preserve the draft on failed save and update/close only after the persisted
   response succeeds.

**Completion Criteria**:

- [x] Users can add, remove, reorder-by-edit, clear, and save both source lists.
- [x] Default toggles work for local and SSH machines, including valid
  defaults-disabled empty lists.
- [x] Indexed server errors appear on the correct row and no error is dropped.
- [x] Generated assets match the tested frontend source.

**Verification**:

- `mise run frontend:check`
- `mise run frontend:test`
- `mise run frontend:build`
- `git diff --check`

## TASK-007: Complete Cross-boundary Verification and Documentation

**Depends On**: TASK-003, TASK-004, TASK-005, TASK-006

**Design References**:

- `design-machine-session-source-directories.md#verification-and-rollout`
- all source-of-truth documents listed above

**Write Scope**:

- focused integration tests needed to close uncovered acceptance criteria
- `design-docs/specs/design-machine-session-source-directories.md`
- `design-docs/specs/design-remote-machine-collection.md`
- `design-docs/specs/architecture.md`
- `design-docs/specs/command.md`
- `design-docs/specs/client-commands.md`
- this implementation plan's checkboxes and Progress Log

**Parallelizable**: No. This audits the integrated implementation.

**Work**:

1. Run the full Swift/frontend gates and resolve regressions without weakening
   tests.
2. Exercise a lightweight machine API create/update/read round-trip when the
   local environment permits.
3. Audit all changed files for raw SSH command/environment leakage, unrelated
   changes, version bumps, files at/over 1000 lines, and generated-asset drift.
4. Confirm deterministic tests cover validation, descriptor compatibility,
   version-1/version-2 migration and rollback, local/SSH persistence,
   multi-root sums, default opt-out, nested/symlink deduplication, remote
   positional serialization, source failure, fingerprint invalidation, and
   stale-attempt fencing.
5. Update design wording only for implementation-discovered clarifications that
   preserve the accepted behavior. Record any intentional deviation as a
   blocker for design review rather than silently changing the contract.
6. Complete plan checkboxes and append final command evidence and residual risks
   to the Progress Log.

**Completion Criteria**:

- [x] All acceptance criteria are linked to passing automated evidence.
- [x] `swift build`, `swift test`, frontend typecheck/test/build, and lint pass.
- [x] Machine source API round-trip passes or its concrete environmental
  limitation is recorded.
- [x] Changed files remain within target scope, every non-generated Swift file
  is below 1000 lines, and no version changed.
- [x] Design docs, generated assets, implementation behavior, and this plan
  agree.

**Verification**:

- `mise run lint`
- `swift build`
- `swift test`
- `mise run frontend:check`
- `mise run frontend:test`
- `mise run frontend:build`
- `find Sources Tests -name '*.swift' -type f -exec wc -l {} + | sort -nr | head`
- `rg -n "CODEX_HOME|CLAUDE_CONFIG_DIR|remoteCcusagePath|stderr" Sources frontend/src`
- `git diff --check`
- `git diff --stat`
- `git status --short`

## Completion Criteria

- [x] Each machine persists independent Codex/Claude lists and default flags,
  with omitted-field compatibility.
- [x] Local and SSH machines enumerate, deduplicate, isolate, and aggregate all
  selected sources under one machine id.
- [x] Defaults disabled means only explicit sources are read; zero sources is a
  valid healthy empty snapshot.
- [x] Source changes, filesystem-plan changes, and environment-plan changes
  invalidate only the affected machine cache and fence stale publication.
- [x] API, CLI, and dashboard support complete local/SSH administration with
  indexed validation and no secret/raw-command leakage.
- [x] Focused and full verification passes, documentation is synchronized, and
  no unrelated feature or version change is present.

## Progress Log

- 2026-07-27: Plan created from the Step 3-accepted design. No Step 5 feedback
  exists yet. Implementation has not started.
- 2026-07-27: TASK-001 through TASK-006 implemented across the machine model,
  schema-version-3 registry migration, source planning, isolated local/SSH
  command execution, cache metadata, HTTP/CLI contracts, dashboard editors,
  focused Swift tests, and frontend tests. Existing in-scope worktree changes
  were preserved and completed rather than replaced.
- 2026-07-27: Resolved all rerun feedback. Environment-derived empty and
  relative `CODEX_HOME`/`CLAUDE_CONFIG_DIR` values remain untrimmed and retain
  prior execution semantics. Validation accepts dot/dot-dot components,
  repeated separators, and trailing separators. Source plans are rebuilt for
  every attempt; local and SSH canonical scan targets, missing/non-directory
  state, and captured remote defaults participate in fingerprints. Cache
  generations fence stale A-to-B-to-A publications.
- 2026-07-27: TASK-007 verification completed. `swift build` passed;
  `swift test --skip-build` passed 199 tests in 44 suites; focused
  `swift test --filter MultiSourceCommandTests` passed 5 tests after the final
  multi-directory assertion update; `mise run frontend:check` passed;
  `mise run frontend:test` passed 30 tests; `mise run frontend:build` passed and
  synchronized packaged assets; `mise run lint` passed with 0 serious violations
  and 32 warnings; CLI update help, `git diff --check`, line-count audit, and
  version-diff audit passed. API create/patch/read is covered by
  `MachineSessionSourceAPITests`; no live server or SSH host was required.
- 2026-07-27: Residual risk is limited to live remote-host interoperability of
  the fixed POSIX source probe, which is deterministically covered through
  argument serialization and probe-result decoding tests but was not exercised
  against an external SSH host in this environment. No known high- or
  mid-severity implementation finding remains.
