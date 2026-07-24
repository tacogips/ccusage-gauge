# Provider-Neutral Remote-Machine Observability and Startup Logging

**Status**: Ready for Implementation
**Workflow Mode**: issue-resolution
**Issue Reference**: `workflowExecution:codex-design-and-implement-review-loop-session-627`;
`communication:comm-001485`; GitHub issue not supplied.
**Design Review**: Accepted by Step 3 in `communication:comm-001494`; no high or
mid findings.
**Codex Agent References**: None supplied. No external reference-repository
trace, intentional divergence, or Cursor adapter boundary applies.

## Source of Truth

- `design-docs/specs/design-remote-machine-collection.md#target-architecture`
- `design-docs/specs/architecture.md#remote-machine-collection`
- `design-docs/specs/command.md#remote-machine-observability-actions`
- `design-docs/specs/client-commands.md#command-tree`
- `design-docs/user-qa/2026-07-16-remote-machines-decisions.md#decisions`

The accepted design controls whenever this plan is less specific. Implementation
must not weaken its provider-neutral rule, host-key enforcement, diagnostic
sanitization, stale-data exclusion, versioned registry migration, or startup-log
durability contract.

## Current Baseline

The branch already contains the first remote-machine implementation:

- `Sources/AppCore/CCUsageCommandRunner.swift` has typed local/SSH runners.
- `Sources/AppCore/Machines.swift` persists schema version 1 and owns registry
  mutations.
- `Sources/AppCore/MachineCollection.swift` has a per-machine snapshot store and
  collector, but its public health/scope DTOs predate the accepted observability
  fields.
- `Sources/AppCore/MachineDashboardRouter.swift` provides machine-aware routes,
  CRUD, refresh, cache clear, and mutation gating.
- `Sources/AppCLI/Commands/ClientMachineCommands.swift` provides list/show/add,
  while the accepted proxy options and machine actions are not yet represented.
- `frontend/src/App.tsx` and `frontend/src/api.ts` provide baseline machine
  selection and registration.
- `Sources/AppCore/HTTPService.swift` is 1001 lines and must be split before
  behavior is added.
- No persistent bootstrap JSONL logger exists.

Implementation is therefore an additive, compatibility-preserving revision of
the existing feature, not a greenfield replacement.

## Deliverables

- [x] Responsibility-based HTTP split with every non-generated Swift file below
  1000 lines and routing behavior preserved.
- [x] Closed schema-version-2 registry with atomic version-1 migration and
  provider-neutral `direct`, `jump`, and fixed-protocol `command` adapters.
- [x] Deterministic typed and sanitized collection diagnostics with no raw
  stderr, connection values, paths, or secret material in public surfaces.
- [x] Exact machine-health, unavailability, last-hour gap, current-data
  exclusion, scope, and latest-event contracts.
- [x] Validated no-restart registry reload, connection test, and targeted
  refresh with revision/generation fencing.
- [x] State-root JSONL bootstrap logging with 10 MiB rotation, 72-hour retention,
  secure permissions, fallback behavior, and deterministic concurrency tests.
- [x] CLI and SolidJS support for proxy adapters, actions, prominent degraded
  status, exclusions, data gaps, and latest-event markers.
- [x] Focused Swift/frontend tests, provider-neutral audits, smoke coverage,
  synchronized documentation, and final command evidence.

## Execution Rules

- Remain on `feat/remote-machine-observability-logging`; do not commit or push.
- Preserve unrelated worktree changes and do not weaken or delete tests.
- Prefer existing SwiftPM targets. Add files by responsibility instead of a new
  module unless an existing target cannot keep the boundary testable.
- Keep every non-generated Swift file below 1000 lines. Do not add tests to
  `Tests/AppCoreTests/CCUsageTests.swift`, which is already near the limit.
- Use injected clocks, filesystems, process runners, and transports for
  deterministic failure, boundary, rotation, migration, and concurrency tests.
- Every planned focused test file defines a same-named Swift Testing suite.
  Confirm the suite appears in `swift test list` before relying on its exact
  `swift test --filter <SuiteName>` command; a zero-test match is a failure.
- Run the narrowest relevant Swift test after each Swift task and `swiftlint`
  after Swift edits when available. Record an unavailable tool as a limitation.
- Treat API changes as additive. Existing direct descriptors, existing client
  commands, legacy provenance decoding, and guarded `GET /api/refresh` remain
  compatible.
- No provider name, machine id, or tunnel product may select a code path, DTO,
  route, failure code, classifier, remediation, or UI label. GCE and IAP remain
  documentation examples only.
- Never log or expose secrets, private-key contents, credential values, raw
  stderr, raw exceptions, command lines, request bodies, or advice to disable
  host-key checking.
- After each task, append a dated Progress Log entry with status, changed files,
  commands and results, findings addressed, limitations, residual risks, and
  the next task. Checkboxes represent evidence, not intent.

## TASK-001: Characterize and Split the HTTP Boundary

**Depends On**: None

**Design References**:

- `design-docs/specs/design-remote-machine-collection.md#current-architecture-baseline`
- `design-docs/specs/architecture.md#dashboard-service`

**Write Scope**:

- `Sources/AppCore/HTTPService.swift`
- new responsibility files under `Sources/AppCore/`, expected to separate
  `DashboardSnapshotCache`, `DashboardRouter`, and `DashboardHTTPServer`
- `Tests/AppCoreTests/HTTPServiceSplitTests.swift`, containing the explicitly
  named `HTTPServiceSplitTests` suite

**Parallelizable**: No. This establishes stable routing seams for later API work.

**Work**:

1. Capture existing router, snapshot-cache, static-asset, request-parser,
   listener lifecycle, shutdown, and restart behavior with focused tests.
2. Move cohesive types out of `HTTPService.swift` without changing public names,
   access control, routes, headers, body encoding, listener behavior, or resource
   lookup.
3. Keep `MachineDashboardRouter` composition intact and avoid widening mutable
   state or introducing cross-file global state.

**Deliverables**:

- behavior-preserving files organized by HTTP responsibility;
- regression tests for route delegation, listener start/stop/restart, and
  packaged/static assets; and
- all affected Swift files below 1000 lines.

**Completion Criteria**:

- [x] Existing dashboard and machine-route tests pass unchanged.
- [x] `HTTPService.swift` and every new Swift file are below 1000 lines.
- [x] No route, DTO, header, status, or listener behavior changes in this task.

**Verification**:

- `swift test --filter HTTPServiceSplitTests`
- `swift test --filter APIRouteTests`
- `swift build`
- `swiftlint Sources Tests`

## TASK-002: Implement Registry Version 2 and the Proxy Adapter Boundary

**Depends On**: TASK-001

**Design References**:

- `design-docs/specs/design-remote-machine-collection.md#ssh-command-boundary-and-allowlist`
- `design-docs/specs/design-remote-machine-collection.md#provider-neutral-ssh-proxy-adapter`
- `design-docs/specs/design-remote-machine-collection.md#persisted-registry-schema`
- `design-docs/specs/design-remote-machine-collection.md#serialized-registry-mutation-ownership`
- `design-docs/specs/client-commands.md#command-tree`
- `design-docs/specs/client-commands.md#http-mapping`

**Write Scope**:

- `Sources/AppCore/Machines.swift`, split into registry model, validation,
  persistence/migration, and mutation-owner files as needed
- `Sources/AppCore/CCUsageCommandRunner.swift`
- `Sources/AppCore/MachineHTTPModels.swift`
- `Sources/AppCore/DashboardAPIModels.swift`
- `Sources/AppCLI/Commands/ClientMachineCommands.swift`
- `Tests/AppCoreTests/SSHTransportTests.swift`
- `Tests/AppCoreTests/MachineRegistryV2Tests.swift`
- `Tests/AppCLITests/ProxyAdapterCommandTests.swift`

**Parallelizable**: No. Registry model splitting and shared AppCore/CLI test
compilation make this part of the ordered implementation chain.

**Work**:

1. Add the closed `SSHConnection.proxy` union:
   - omitted/direct adds no proxy behavior;
   - jump accepts only validated host, port, user, optional identity file, and
     optional known-hosts file;
   - command accepts only an absolute owner-safe executable and constructs the
     fixed `connect --host <validated-host> --port <validated-port>` invocation.
2. Reject raw `-J`, `ProxyJump`, `ProxyCommand`, proxy arguments, placeholders,
   environment/configuration values, credentials, shell fragments, and host-key
   weakening. Preserve independent target verification and jump-host
   verification.
3. Keep `-F /dev/null`, fixed option order, remote-token POSIX quoting, the
   closed `extraOptions` allowlist, and immediate pre-launch path validation.
4. Make schema version 2 the only written representation. Enforce exact required
   and optional fields, duplicate/unknown-key rejection at every level,
   deterministic id ordering, normalized API defaults, and omitted rather than
   null optional fields.
5. Decode the exact existing version-1 representation only as a migration
   source. Atomically synchronize and replace it with version 2 before registry
   publication or poller startup. Preserve original bytes and runtime state on
   failure and surface sanitized `registry_migration_failed`.
6. Extend API/CLI payloads with the structured proxy fields. CLI add options use
   mutually exclusive jump and command groups and never accept a raw proxy
   string or command-adapter arguments.

**Deliverables**:

- structured proxy and registry-v2 domain models;
- atomic version-1-to-version-2 migration;
- canonical SSH argv generation for direct, jump, and command adapters;
- additive API/client DTOs and CLI parsing; and
- adversarial fixtures for serialization, paths, arguments, shell input,
  duplicate keys, schema versions, and host-key policy.

**Completion Criteria**:

- [x] Existing direct descriptors remain source/API compatible.
- [x] Every successful save is canonical schema version 2.
- [x] A valid version-1 file migrates once before publication; every migration
  failure preserves its bytes and publishes no revision.
- [x] Target and jump-host identities are independently enforced.
- [x] The command adapter accepts no operator-supplied arguments and cannot
  weaken the target SSH handshake.
- [x] No provider-specific token exists in a code-facing contract.

**Verification**:

- `swift test --filter SSHTransportTests`
- `swift test --filter MachineRegistryV2Tests`
- `swift test --filter ProxyAdapterCommandTests`
- `swiftlint Sources Tests`

## TASK-003: Add Sanitized Diagnostics and Deterministic Health State

**Depends On**: TASK-002

**Design References**:

- `design-docs/specs/design-remote-machine-collection.md#typed-command-failures-and-health-sanitization`
- `design-docs/specs/design-remote-machine-collection.md#machine-collection-status-contract`

**Write Scope**:

- new diagnostic/classifier files under `Sources/AppCore/`
- `Sources/AppCore/MachineCollection.swift`, split by status DTO/state
  derivation, snapshot store, and collector responsibility as needed
- `Tests/AppCoreTests/MachineDiagnosticsTests.swift`
- `Tests/AppCoreTests/MachineHealthTests.swift`

**Parallelizable**: No. The health contract depends on the final transport
failure boundary.

**Work**:

1. Preserve typed runner kind, phase, termination reason, exit status, and
   bounded stderr internally through `CCUsageClient`.
2. Implement the ordered, fixture-driven SSH stderr classifier from the design:
   at most 4096 bytes, UTF-8 replacement, POSIX case-folding, whitespace/control
   normalization, and host-key before authentication before tunnel reachability.
3. Map failures to the exact closed public codes and application-owned strings:
   `host_key_verification_failed`, `auth_failed`, `tunnel_unreachable`,
   `timeout`, `remote_command_failed`, `transport_failed`, `invalid_response`,
   `cache_failed`, and fallback-only `internal_error`.
4. Extend `SanitizedCollectionError` additively with nullable `detail` and
   `remediation`; newly classified failures populate all four fields.
5. Extend collection status with consecutive failure count, first unavailable
   instant, stale-since instant, last-hour data gap, and the exact
   `disabled|error|neverCollected|stale|healthy` precedence. Add overlapping-
   condition tests proving that a failed first collection is `error`, a retained
   snapshot with an uncleared error is `stale`, and an age-stale snapshot cannot
   be classified as `healthy`. Success clears the
   active failure interval; cancellation and superseded generations publish
   nothing.
6. Keep raw stderr, matches, exit status, connection values, paths, raw
   exceptions, commands, and identity material out of API, CLI, UI, and logs.

**Deliverables**:

- closed diagnostic classifier and public DTO;
- one shared health-state derivation used by status and query errors; and
- deterministic fixtures for all classifier families, fallbacks, timestamps,
  age boundaries, consecutive failures, cancellation, and sanitization.

**Completion Criteria**:

- [x] Every accepted diagnostic family is independently distinguishable.
- [x] `internal_error` is used only after all narrower classifications fail.
- [x] Prominent status data can expose last success, sanitized failure,
  unavailable since, stale since, and last-hour gap deterministically.
- [x] Public/log outputs contain no raw diagnostic input or unsafe remediation.

**Verification**:

- `swift test --filter MachineDiagnosticsTests`
- `swift test --filter MachineHealthTests`
- `swiftlint Sources Tests`

## TASK-004: Enforce Current-Data Eligibility and Add Observability Metadata

**Depends On**: TASK-003

**Design References**:

- `design-docs/specs/design-remote-machine-collection.md#machine-aware-snapshot-and-api`
- `design-docs/specs/design-remote-machine-collection.md#latest-event-and-last-hour-marker-contract`
- `design-docs/specs/architecture.md#remote-machine-collection`

**Write Scope**:

- machine scope/status/selection files split from
  `Sources/AppCore/MachineCollection.swift`
- `Sources/AppCore/DashboardAPIModels.swift`
- `Sources/AppCore/DashboardQuery.swift`
- query/scope files split from `Sources/AppCore/MachineDashboardRouter.swift`
- `Tests/AppCoreTests/MachineCurrentDataTests.swift`
- `Tests/AppCoreTests/MachineLatestEventTests.swift`

**Parallelizable**: No. All query routes must share one finalized eligibility
and state derivation.

**Work**:

1. Derive the effective half-open interval and exact
   `current|historical` disposition before selecting rows.
2. For current intervals, exclude stale, error, never-collected, and disabled
   machines before rows, aggregates, totals, budgets, or summaries are
   calculated. Recompute values only from eligible source rows.
3. Preserve retained stale snapshots only for explicit historical queries.
   Concrete stale current queries return structured
   `503 current_data_unavailable`; all-machine queries return partial `200` only
   when at least one current-eligible snapshot remains.
4. Add the exact additive `DashboardScope` fields:
   `dataDisposition`, `excludedFromCurrentTotalsMachineIds`,
   `machineAvailability`, `lastHourDataGaps`, and `evaluatedAt`, while preserving
   existing fields and oldest-included `generatedAt`.
5. Add `machineLatestEvents` to every successful `/api/cost-series` response and
   recognized disabled, snapshot-unavailable, and current-data-unavailable
   response. Derive markers from unbucketed retained source timestamps before
   presentation filters, and keep marker metadata independent of row
   eligibility.
6. Apply the same provenance, scope, interval, and stale gate to
   `/api/recent`, `/api/day`, `/api/period`, `/api/metrics`,
   `/api/cost-series`, and `/api/budget`.

**Deliverables**:

- one interval/disposition and current-eligibility service;
- additive scope, availability, gap, and latest-event DTOs;
- structured current-data errors; and
- deterministic host-calendar, interval-boundary, stale-exclusion, marker, and
  all-machine partial-result tests.

**Completion Criteria**:

- [x] Retained stale history cannot enter any current row, series, total,
  budget, or summary.
- [x] Every excluded current machine has a concrete reason and unavailable
  instant, with the last-hour intersection when applicable.
- [x] Cost-series success and recognized unavailable envelopes contain one
  latest-event item per resolved selected machine.
- [x] Stale latest-event metadata never makes stale rows eligible.

**Verification**:

- `swift test --filter MachineCurrentDataTests`
- `swift test --filter MachineLatestEventTests`
- `swift test --filter DashboardQueryTests`
- `swiftlint Sources Tests`

## TASK-005: Add Validated Reload, Connection Test, and Targeted Refresh

**Depends On**: TASK-002, TASK-003, TASK-004

**Design References**:

- `design-docs/specs/design-remote-machine-collection.md#serialized-registry-mutation-ownership`
- `design-docs/specs/design-remote-machine-collection.md#no-restart-connection-test-and-targeted-refresh`
- `design-docs/specs/command.md#remote-machine-observability-actions`

**Write Scope**:

- registry reload/reconciliation files under `Sources/AppCore/`
- `Sources/AppCore/MachineCollection.swift`
- action routing files split from `Sources/AppCore/MachineDashboardRouter.swift`
- `Sources/AppCore/MachineHTTPModels.swift`
- `Sources/AppCore/DashboardAPIClient.swift`
- `Sources/AppCLI/Commands/ClientCommand.swift`
- `Sources/AppCLI/Commands/ClientMachineCommands.swift`
- `Sources/AppCLI/ClientRuntime.swift`
- `Sources/AppCLI/Rendering/MachineRenderer.swift`
- `Tests/AppCoreTests/MachineActionTests.swift`
- `Tests/AppCLITests/MachineActionCommandTests.swift`
- `Tests/AppCLITests/MachineActionRenderingTests.swift`

**Parallelizable**: No. It mutates the registry/collector contract and freezes
the DTOs consumed by the frontend.

**Work**:

1. Route existing registry `POST`, `PUT`, `PATCH`, and `DELETE` through the same
   process-wide transaction owner. Each response waits for complete-candidate
   validation, synchronized mode-`0600` atomic persistence, immutable revision
   publication, affected-generation increment, cancellation and awaiting of the
   old poller, snapshot/status reconciliation, and non-throwing replacement
   registration. A pre-commit failure changes neither disk nor runtime;
   unaffected pollers continue; every late result is revision/generation fenced.
2. Before either action, reload and fully validate `machines.json` through the
   serialized registry owner. Migrate valid version 1 before publication.
   Invalid input returns `409 registry_reload_failed`, preserves the committed
   in-memory revision/pollers, and runs no action.
3. Publish a valid changed registry atomically, increment affected generations,
   cancel and await replaced pollers, reconcile status/snapshots, and fence every
   late publication by revision and generation.
4. Add guarded `POST /api/machines/{id}/test-connection`. Use the same validated
   runner with fixed `--version`; do not write cache, change collection status,
   replace snapshots, create tunnels, or execute caller-provided commands.
5. Add guarded `POST /api/machines/{id}/refresh`. Coalesce with current
   collection for the new revision, retain coverage and last snapshot, and
   return the exact additive `RefreshResponse` diagnostic semantics.
6. Add typed `DashboardAPIClient` methods and
   `ccusage-gauge client machines test-connection|refresh` commands. Preserve
   exact stdout/stderr, JSON, and exit-code rules.
7. Keep guarded `GET /api/refresh` compatible and apply the same mutation gate
   before reload, body decoding, selection, or work.

**Deliverables**:

- serialized disk reload and runtime reconciliation;
- complete CRUD persistence-to-runtime transactions before response;
- exact action routes and response DTOs;
- typed client/CLI action support; and
- deterministic filesystem, revision, generation, coalescing, cancellation,
  invalid-reload, migration, concurrent CRUD, disabled/unknown, unaffected
  poller, and output-stream tests.

**Completion Criteria**:

- [x] Valid disk edits are usable by test/refresh without app restart.
- [x] Every CRUD response observes its persisted revision and fully reconciled
  affected poller/store state; concurrent mutations lose no update.
- [x] Invalid or failed migration edits change neither runtime nor disk.
- [x] Test connection has no collection/cache/status side effects.
- [x] Targeted refresh never enables a machine, drops retained coverage, or
  weakens host-key policy.
- [x] Removed/replaced pollers cannot publish after the action response.

**Verification**:

- `swift test --filter MachineActionTests`
- `swift test --filter DashboardAPIClientTests`
- `swift test --filter MachineActionCommandTests`
- `swift test --filter MachineActionRenderingTests`
- `swiftlint Sources Tests`

## TASK-006: Implement Secure Persistent Bootstrap Logging

**Depends On**: TASK-001, TASK-005

**Design References**:

- `design-docs/specs/architecture.md#persistent-startup-and-bootstrap-log`
- `design-docs/specs/command.md#remote-machine-observability-actions`

**Write Scope**:

- `Sources/AppCore/Configuration.swift` for `AppPaths.logDirectory`
- `Sources/AppCore/BootstrapLogger.swift`
- `Sources/AppCore/BootstrapLogFileSystem.swift`
- `Sources/AppCore/BootstrapLogLock.swift`
- `Sources/AppCLI/RootCommand.swift`
- `Sources/AppCLI/Runtime.swift`
- `Sources/CCUsageGaugeMenuBar/MenuBarApp.swift`
- `Tests/AppCoreTests/BootstrapLoggerTests.swift`
- `Tests/AppCLITests/BootstrapLoggingCommandTests.swift`

**Parallelizable**: No. Execute after TASK-005 so shared AppCore and test-target
compilation has one plan owner at a time.

**Work**:

1. Add a side-effect-free `AppCore` bootstrap logger and explicit `activate()`.
   Menu-bar and runtime CLI commands activate before configuration, state,
   registry, cache, executable, asset, or listener work; help/version remain
   side-effect free. Activation may validate/create the directory, select the
   fallback, acquire the maintenance lock, and apply retention, but must not
   create `ccusage-gauge.jsonl` until the first append.
2. Derive `~/.local/ccusage-gauge/logs` from the state root and add one fallback
   attempt to the default state-root log directory when an explicit override
   fails. Never record rejected paths or underlying exceptions.
3. Require current-user-owned real directories at `0700` and regular,
   single-link current-user-owned files at `0600`; do not follow or repair
   unsafe objects.
4. Append one-line JSON records using only closed runtime, phase, code,
   severity, and application-owned message values. Each encoded record is
   capped at exactly 16 KiB; oversized dynamic input is never copied or emitted.
5. Before an append exceeding 10 MiB, atomically rotate with UTC timestamp and
   collision-safe monotonic sequence. Remove only rotated files whose
   modification time is strictly older than 72 hours; retain a file exactly at
   the boundary and never delete the active or unrelated files.
6. Serialize activation, append, rotation, and cleanup across tasks/processes
   with an advisory lock. Logging failure must not mask or block the original
   runtime error.

**Deliverables**:

- secure state-root JSONL logger;
- early menu-bar and CLI lifecycle integration;
- closed sanitized record schema; and
- injected clock/filesystem/limit/retention tests for exact size boundaries,
  the 16 KiB record boundary, activation without active-file creation, first
  append creation, retention before/at 72 hours, collisions, permissions/types,
  fallback, concurrent append, malformed config, registry, SSH/process, and
  listener failures.

**Completion Criteria**:

- [x] Malformed config and other early runtime failures are persisted before
  their existing UI/stderr presentation when logging is available.
- [x] Help/version create no directories or files.
- [x] Activation performs maintenance without creating the active JSONL file;
  the first append creates it and no encoded record exceeds 16 KiB.
- [x] Rotation, retention, permissions, fallback, and concurrency match the
  accepted contract exactly.
- [x] Log records contain no raw config, stderr, exception text, environment,
  commands, request bodies, topology, paths, credentials, or usage data.

**Verification**:

- `swift test --filter BootstrapLoggerTests`
- `swift test --filter BootstrapLoggingCommandTests`
- `swiftlint Sources Tests`

## TASK-007: Implement the Frontend Observability and Action Experience

**Depends On**: TASK-002, TASK-003, TASK-004, TASK-005 DTO freeze, TASK-006

**Design References**:

- `design-docs/specs/design-remote-machine-collection.md#dashboard-ui`
- `design-docs/specs/design-remote-machine-collection.md#latest-event-and-last-hour-marker-contract`
- `design-docs/specs/architecture.md#frontend-contract`

**Write Scope**:

- `frontend/src/api.ts`
- `frontend/src/App.tsx`, split into machine configuration, health, action, and
  chart components before additions make it harder to maintain
- `frontend/src/styles.css` and focused component/style modules
- `frontend/tests/`
- `frontend/package.json`
- generated `Sources/AppCore/Resources/Web/` only after source tests/checks pass

**Parallelizable**: No. Start only after backend DTOs and bootstrap integration
are complete.

**Work**:

1. Add exact proxy-adapter request/response types and safe direct/jump/command
   form controls. Provide no raw SSH option, proxy string, shell command,
   adapter-argument, environment, or credential field.
2. Render persistent high-contrast stale/unavailable panels with last success,
   sanitized diagnostic, unavailable/stale since, last-hour gap, and explicit
   current-total exclusion.
3. Add per-SSH-machine Test connection and Refresh controls with per-machine
   in-flight suppression. Retain action results until the next edit/action and
   treat HTTP-200 `status: failed` as failure.
4. After refresh success or failure, refetch the design-specified registry,
   status, current metrics, cost-series, and budget sets. A failed connection
   test refetches nothing.
5. Render latest-event markers and data-gap spans for the last-hour sub-daily
   chart from successful or recognized unavailable responses. Distinguish
   observed, no-event, stale, and unavailable without implying stale inclusion.
6. Extract pure derivation/rendering helpers where possible and add Bun tests.
   Add a repository `frontend:test` task if absent.

**Deliverables**:

- typed frontend proxy, status, scope, marker, gap, and action contracts;
- maintainable machine/status/chart components;
- deterministic frontend tests for provider neutrality, panels, exclusions,
  action state/refetch behavior, markers, and data gaps; and
- synchronized production assets.

**Completion Criteria**:

- [x] The UI exposes every accepted status/action field without raw sensitive
  data or provider-specific labels.
- [x] Summary cards consume only server-selected eligible rows and visibly list
  excluded machines.
- [x] Action success/failure and refetch behavior match the design.
- [x] Frontend tests, typecheck, and clean build pass before assets are synced.

**Verification**:

- `cd frontend && bun test`
- `task frontend:check`
- `task frontend:build`

## TASK-008: Complete Cross-Layer Regression, Smoke, and Documentation Coverage

**Depends On**: TASK-002 through TASK-007

**Design References**:

- `design-docs/specs/design-remote-machine-collection.md#local-emulation-docker-compose--colima`
- `design-docs/specs/design-remote-machine-collection.md#rollout-and-compatibility`
- `design-docs/specs/architecture.md#rollout-and-verification-constraints`
- `design-docs/user-qa/2026-07-16-remote-machines-decisions.md#decisions`

**Write Scope**:

- new focused tests under `Tests/AppCoreTests/` and `Tests/AppCLITests/`
- `scripts/smoke-remote-machines.sh`
- `scripts/smoke-dashboard.sh` and `scripts/smoke-isolated-runtime.sh` only when
  required to exercise accepted behavior
- `deploy/emulation/` only for provider-neutral direct/forwarded SSH fixtures
- `Taskfile.yml`
- `README.md`
- accepted design documents only for implementation-status synchronization
- this implementation plan

**Parallelizable**: No. This integrates all cross-layer contracts.

**Work**:

1. Fill remaining deterministic matrices: direct/jump/command neutrality;
   classifier precedence/fallback; current/historical interval boundaries;
   stale exclusion on every route; recognized error envelopes; latest-event
   markers; registry migration/reload; action concurrency; logging rotation,
   retention, permissions, fallback, redaction, and concurrent append.
2. Preserve the accepted baseline contracts with explicit regression suites:
   legacy-only local-cache migration, destination-wins conflict handling,
   unsafe legacy input, WAL checkpoint/mode enforcement, injected migration
   failures with no partial destination, restart retry, both local cache
   namespaces and sidecars on clear, per-machine crash recovery, complete/mixed/
   zero-success cache-clear responses, and no stale-cache resurrection.
3. Re-run explicit mutation-origin tests for every CRUD, refresh, action, and
   cache-delete route; prove rejected origin/fetch/header/preflight cases make no
   registry, cache, poller, status, or refresh change. Re-run complete machine
   provenance across block/timeline, daily, session, recent/day/period, metrics,
   and every cost-series granularity, including otherwise-equal cross-machine
   rows. Re-run coverage retention, per-machine expansion, concurrent
   all-machine expansion, failed-expansion retention, and startup warm ordering.
4. Extend remote-machine smoke coverage to prove guarded test connection and
   targeted refresh after a validated registry edit, retained stale history,
   partial current aggregates, exact exclusion metadata, latest-event metadata,
   sanitized failure output, and recovery. Keep standalone Compose under Colima
   and the existing ephemeral tmpfs credential model.
5. Add or update Taskfile entries for frontend tests and smoke execution without
   changing release/publish behavior.
6. Update README and implementation-status documentation with provider-neutral
   terminology, log location/rotation/retention, action commands, safe
   remediation, and exact environment limitations.
7. Audit added code-facing text for GCE/IAP/GCP/provider-specific branching,
   unsafe host-key advice, raw stderr exposure, fixed machine ids, and secret or
   machine-local path leakage.
8. Run the repository-supported `task test:coverage` path and retain its
   architecture-independent SwiftPM/`llvm-cov` discovery. It must measure
   executable lines in `Sources/AppCore` and `Sources/AppCLI`, exclude tests,
   generated code, and copied web resources, and fail below 80.0%. Missing
   tooling or an unreadable artifact is a failed gate, not an environment skip.

**Deliverables**:

- complete deterministic Swift/frontend regression coverage;
- enhanced provider-neutral smoke assertions;
- task automation and operator documentation; and
- audit evidence with exact limitations where the environment prevents a
  runtime check.

**Completion Criteria**:

- [x] Every Step 1 acceptance criterion maps to at least one deterministic test
  or explicit smoke assertion.
- [x] Local-cache migration/clear recovery, mutation-origin rejection,
  complete row provenance, and coverage retention remain explicitly verified.
- [x] Direct, jump, command, local-forward, and equivalent tunnel behavior share
  one code-facing contract.
- [x] Smoke failures report exact environment limitations without claiming
  unexecuted runtime or credential-isolation proof.
- [x] Documentation and plan status match the implemented behavior.
- [x] `task test:coverage` reports at least 80.0% executable-line coverage for
  AppCore and AppCLI; missing tools or artifacts remain verification failures.

**Verification**:

- `task test`
- `task test:coverage`
- `task lint`
- `task frontend:test`
- `task frontend:check`
- `task frontend:build`
- `bash -n scripts/smoke-remote-machines.sh`
- `task smoke:remote-machines`
- `if rg -n -i 'gce|iap|gcp|google cloud' Sources frontend/src; then exit 1; fi`
- `if rg -n 'StrictHostKeyChecking=no|UserKnownHostsFile=/dev/null' Sources frontend/src; then exit 1; fi`

## TASK-009: Run Final Gates and Record Closeout Evidence

**Depends On**: TASK-001 through TASK-008

**Design References**:

- `design-docs/specs/design-remote-machine-collection.md#rollout-and-compatibility`
- `design-docs/specs/architecture.md#rollout-and-verification-constraints`

**Write Scope**:

- `impl-plans/active/remote-machine-collection.md`
- documentation corrections required by final evidence

**Parallelizable**: No.

**Work**:

1. Run focused failures first, then the full repository gates.
2. Record each exact command, exit result, material assertion, limitation, and
   residual risk in the Progress Log.
3. Inspect the final diff for unrelated changes, credentials, private URLs,
   machine-local absolute paths, provider-specific code-facing contracts,
   generated asset/source mismatch, files at or above 1000 lines, and accidental
   test removal.
4. Confirm the branch is unchanged and no commit was created.
5. Move this plan to `impl-plans/completed/` only after implementation review
   accepts and every non-environmental completion criterion passes.
6. Exercise packaged resources and release scaffolding without publishing:
   `task smoke:assets`, Formula archive dry runs, and Cask archive dry runs.
   The Cask dry run executes on macOS; a non-macOS runner records the exact
   platform limitation and leaves that check unverified rather than passing it.

**Completion Criteria**:

- [x] Focused tests and all full gates pass, or each permitted environment
  limitation is exact and leaves the affected criterion visibly unverified.
- [x] No non-generated Swift file is 1000 lines or longer.
- [x] No commit or push was created.
- [x] Coverage is at least 80.0%; `task build`, packaged-resource checks, and
  non-publishing Formula/Cask scaffolding checks have explicit results.
- [x] Final progress evidence lists changed files, review decisions, addressed
  findings, verification results, limitations, TODOs, and residual risks.

**Verification**:

- `task test`
- `task test:coverage`
- `task lint`
- `task frontend:test`
- `task frontend:check`
- `task frontend:build`
- `task build`
- `nix flake check`
- `task smoke:assets`
- `task smoke:isolated-runtime`
- `task smoke:dashboard`
- `task smoke:remote-machines`
- `scripts/build-homebrew-release.sh --dry-run darwin-arm64 darwin-x64`
- `scripts/build-homebrew-cask-release.sh --dry-run darwin-arm64 darwin-x64`
  on macOS; otherwise record the exact platform limitation as unverified
- `find Sources Tests -type f -name '*.swift' -exec wc -l {} + | awk '$2 != "total" && $1 >= 1000 {print; bad=1} END {exit bad}'`
- `git diff --check`
- `git status --short --branch`

## Dependency Summary

- TASK-001 establishes stable HTTP seams.
- TASK-001 -> TASK-002 registry/proxy transport.
- TASK-002 -> TASK-003 diagnostics and health state.
- TASK-003 -> TASK-004 eligibility, scope, gaps, and latest events.
- TASK-002 + TASK-003 + TASK-004 -> TASK-005 reload and actions.
- TASK-001 + TASK-005 -> TASK-006 bootstrap logging.
- TASK-002 through TASK-006 -> TASK-007 frontend.
- TASK-002 through TASK-007 -> TASK-008 integrated regression/smoke/docs.
- TASK-001 through TASK-008 -> TASK-009 final gates.

## Parallel Work Windows

No tasks are authorized to write in parallel in this revision. The plan uses the
ordered TASK-001 through TASK-009 sequence because AppCore compilation, shared
test targets, DTO freeze, generated assets, and final integration create common
coordination boundaries. Generated web assets have one owner, TASK-007.

## Overall Completion Criteria

- [x] TASK-001 through TASK-009 are complete with dated evidence.
- [x] All five accepted design references are implemented without undocumented
  divergence.
- [x] No code-facing behavior is provider-specific.
- [x] Host-key verification remains enforced independently for final targets
  and jump hosts; no unsafe remediation is emitted.
- [x] Structured diagnostics distinguish every accepted family and expose no raw
  sensitive detail.
- [x] Prominent health includes last success, sanitized failure,
  unavailable/stale since, and last-hour gap.
- [x] Cost-series success and recognized unavailable envelopes expose per-machine
  latest-event metadata.
- [x] Valid registry edits support connection test and targeted refresh without
  restart; invalid edits preserve committed runtime state.
- [x] Stale retained rows never enter current series, totals, budgets, or
  summaries.
- [x] Early failures are logged under the state root with secure JSONL,
  10 MiB rotation, and 72-hour retention when logging is available.
- [x] Required Swift/frontend/full/smoke commands pass or exact permitted
  environment limitations remain explicit.
- [x] `task test:coverage` reports at least 80.0% AppCore/AppCLI executable-line
  coverage; missing coverage tooling or artifacts are failures.
- [x] `task build`, `task smoke:assets`, Formula dry runs, and the macOS Cask
  dry runs pass without publishing; a non-macOS Cask limitation remains
  explicitly unverified.
- [x] Every non-generated Swift file is below 1000 lines.
- [x] No tests were weakened or deleted, and no commit or push was created.

## Risks and Mitigations

- **Proxy serialization or injection**: centralize canonical argv/remote-token
  construction, reject raw proxy/argument/configuration inputs, and use
  adversarial direct/jump/command fixtures.
- **Host identity weakening**: keep target verification outside the transport
  adapter and assert independent jump-host verification and unsafe-option
  rejection.
- **Migration or reload data loss**: use synchronized same-directory atomic
  replacement, preserve original version-1 bytes on failure, and fence runtime
  publication behind a committed revision.
- **Late collector publication**: attach registry revision and generation to
  every publication, cancel/await replaced pollers, and race reload/refresh/
  delete in deterministic tests.
- **Stale-data leakage**: centralize interval disposition and eligibility before
  aggregation, recompute totals from eligible source rows, and test every route
  plus client-side filtering.
- **Diagnostic leakage or misclassification**: bound and discard normalized
  stderr, use closed ordered signatures/application-owned output, and inspect
  API, CLI, UI, and log fixtures.
- **Logger races or unsafe filesystem objects**: inject filesystem/clock/limits,
  use ownership/type/mode checks and an advisory lock, and test collisions,
  retention boundaries, fallbacks, and concurrent append.
- **File growth and routing regression**: split HTTP, registry, collection, and
  frontend responsibilities before adding behavior; enforce line counts and
  focused regression tests.
- **Frontend/server drift**: freeze additive DTOs before frontend work, test
  recognized error-body decoding, and build/sync generated assets once.
- **Colima, Docker, Nix, or SwiftLint unavailable**: record exact limitations;
  do not substitute weaker topology/security behavior or claim a skipped gate.

## Progress Log

- 2026-07-23 — PLAN — revised — replaced the superseded greenfield/version-1
  plan with a current-baseline implementation plan for accepted registry
  version 2, structured provider-neutral proxy adapters, sanitized diagnostics,
  deterministic health/gaps, current-data exclusion, latest-event metadata,
  no-restart actions, secure bootstrap logging, frontend behavior, and full
  verification — source review included `Package.swift`, `.swiftlint.yml`,
  `Taskfile.yml`, GitHub workflows, current source/test boundaries, Swift line
  counts, all five accepted design documents, and Step 3 acceptance
  `comm-001494` — no Step 5 feedback or Codex-agent reference input was
  supplied — next task is TASK-001.
- 2026-07-23 — PLAN-SELF-REVIEW — revised — addressed every finding from
  `comm-001496`: serialized all task execution to remove ambiguous parallel
  ownership; added the exact 16 KiB record cap and lazy active-log creation;
  expanded TASK-005 to cover complete CRUD persistence-to-runtime transactions;
  added cache migration/clear, origin-policy, provenance, and coverage
  regressions; and bound focused commands to explicitly named suites with
  `swift test list` zero-match protection — design revision remains unnecessary;
  independent Step 5 plan review is next.
- 2026-07-23 — PLAN-SELF-REVIEW — revised — addressed both findings from
  `comm-001498`: restored `task test:coverage` with the accepted 80.0%
  AppCore/AppCLI threshold and non-skippable tooling/artifact failures; restored
  `task build`, `task smoke:assets`, Formula dry-run, and macOS Cask dry-run
  release-scaffolding gates without publishing, including the exact non-macOS
  unverified limitation — independent Step 5 plan review is next.
- 2026-07-23 — STEP-5-REVISION — revised — addressed `comm-001501`: corrected
  TASK-003 to the exact `disabled`, `error`, `neverCollected`, `stale`,
  `healthy` precedence and added overlapping-condition test expectations; added
  anchored source-of-truth and per-task design references for implementation
  traceability — no accepted design change was required; Step 5 re-review is
  next.
- 2026-07-23 — PLAN-SELF-REVIEW — accepted — confirmed all nine tasks map to
  anchored accepted-design sections without unsupported architecture; verified
  explicit deliverables, serialized dependencies, non-parallel write ownership,
  completion criteria, progress evidence, focused Swift/frontend tests,
  typecheck/build/coverage/documentation/smoke/release gates, the corrected
  health-state precedence, and prior feedback closure — no high, mid, or low
  findings; Step 5 independent re-review is next.
- 2026-07-24 — IMPLEMENTATION-VERIFY — partial — implemented secure bootstrap
  JSONL logging, provider-neutral remote transports and diagnostics,
  transactional no-restart registry actions, stale/current-data exclusion,
  availability gaps and latest-event overlays, and complete SSH/proxy editing;
  addressed review findings F-001 through F-004 — `task test` passed 151 tests
  in 36 suites; frontend tests passed 22 tests; frontend typecheck/build,
  Swift build, Nix flake evaluation, Nix-shell SwiftLint, packaged-assets,
  isolated-runtime, dashboard, and Docker remote-machine smoke tests passed;
  `git diff --check` passed and source files remain below 1000 lines — measured
  AppCore/AppCLI executable-line coverage is 76.01%, below the required 80.0%,
  so overall completion remains open; the existing coverage test was not
  modified; no commit or push was performed.
- 2026-07-24 — FINAL-VERIFY — complete — added Swift 6.3 coverage-tool
  compatibility and focused cache, router, logger, and all-unavailable UI
  regressions; `task test` passed 164 tests in 37 suites and
  `task test:coverage` passed at 80.22% (7124/8881); 24 frontend tests,
  typecheck/build, Swift build, Nix-shell SwiftLint (32 warnings, zero serious),
  `nix flake check`, packaged-assets, isolated-runtime, dashboard, Docker
  remote-machine smoke, Formula/Cask dry runs, and `git diff --check` passed;
  Riela final review session `ccusage-gauge-final-review-session-6` returned
  accepted with zero findings; no commit or push was performed.

Future entries use:
`YYYY-MM-DD — TASK-NNN — status — changed deliverables and files — commands/results — findings addressed — blockers, residual risks, next task`.
A task remains incomplete when a required command is unavailable; record the
limitation and unverified criterion instead of checking it.
