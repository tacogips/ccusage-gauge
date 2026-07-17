# Remote Machine ccusage Collection

**Status**: Ready for Implementation
**Workflow Mode**: issue-resolution
**Issue Reference**: implementation plan
`impl-plans/active/remote-machine-collection.md`; no external issue number or URL
was supplied.
**Design References**: `design-docs/specs/design-remote-machine-collection.md`,
`design-docs/specs/architecture.md`, `design-docs/specs/command.md`, and
`design-docs/user-qa/2026-07-16-remote-machines-decisions.md`
**Codex Agent References**: None supplied; no reference-behavior trace or
intentional divergence applies.

## Purpose

Implement the accepted SSH-exec remote collection design without re-litigating
its locked decisions: a synthetic local machine plus registered SSH machines,
host-only per-machine caches, machine-aware API/frontend behavior, and a
credential-ephemeral Docker Compose emulation under Colima.

## Deliverables

- [ ] Safe local/SSH command-runner abstraction with typed failure preservation.
- [ ] Fail-closed, versioned machine registry and serialized runtime mutations.
- [ ] Per-machine provenance, caches, snapshots, polling, health, and coverage.
- [ ] Machine-aware query, refresh, cache-clear, registry, and status APIs.
- [ ] `serve` and menu-bar runtime wiring that fails before bind on unsafe state.
- [ ] Frontend machine selection, attribution, registration, and health UI.
- [ ] Docker Compose emulation and a credential-isolation smoke test for Colima.
- [ ] Coverage enforcement, documentation, and recorded verification evidence.

## Execution Rules

- Complete tasks in dependency order. After each Swift task, run the narrowest
  relevant build/test and `swiftlint` when available; keep Swift files below
  1000 lines and split them by responsibility.
- Preserve unrelated dirty-worktree changes. Do not stage, commit, push, or use
  destructive cleanup unless separately requested.
- Preserve the accepted SSH-exec transport, closed option allowlist, POSIX token
  quoting, host-only per-machine SQLite caches, synthetic `local`, fail-closed
  registry rules, and ephemeral-key security model.
- Use standalone Docker Compose under Colima only. Never place credentials in
  image layers, named volumes, committed/runtime host files, the host's real
  `~/.ssh`, container arguments/environment/logs, or ordinary mounts.
- Build frontend assets with `cd frontend && bun install && bun run build`.
- Record each task's date, status, changed deliverables, commands/results,
  environmental limitations, and next task in the Progress Log.

## Phase A - Transport abstraction (AppCore)

### TASK-001: Introduce safe local and SSH command runners

**Depends On**: None
**Write Scope**: `Sources/AppCore/CCUsage.swift`, focused command-runner tests in
`Tests/AppCoreTests/`
**Parallelizable**: No

In `CCUsage.swift`, extract a `CCUsageCommandRunner` protocol:
   `func run(arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult`.
   - `LocalCCUsageCommandRunner`: wraps existing `CCUsageProcessRunner` + resolved
     executable URL (current behavior).
   - `CCUsageClient` takes a `CCUsageCommandRunner` (keep a convenience init from
     `executable` so existing call sites/tests compile).
Add `SSHCCUsageCommandRunner`: builds
   `/usr/bin/ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes [-i path]
   -p port [allowlisted options] -- user@host <quoted-remote-command>` and runs it
   via a `Process` runner. Serialize every remote token with POSIX single-quote
   escaping because OpenSSH crosses a remote-shell boundary. Validate the exact
   user, host, local-path, remote executable grammar and closed extra-option
   allowlist from the design; reject all unlisted config, proxy, hook,
   environment, remote-command, forwarding, and override forms. Add the design's
   typed `CCUsageCommandFailure` and preserve it through `CCUsageClient` and
   `CCUsageError`: launch failure -> `spawnFailed`, deadline expiry ->
   `timedOut`, signal termination -> `signalled`, SSH status 255 ->
   `transportExited`, SSH status 1...254 -> `commandExited`, and any nonzero
   local status -> `commandExited`. Do not retain the unqualified
   `CCUsageError.nonzeroExit` collapse. Test canonical argv, remote quoting,
   every allowed option family, representative rejected/alternate forms, and
   every process-outcome classification with an injected fake process runner
   (no real ssh).

**Completion Criteria**:

- [ ] Existing local behavior remains source-compatible through the convenience
  initializer and fixed argument arrays.
- [ ] SSH argv, destination formatting, POSIX remote-token quoting, path checks,
  and the complete allow/reject matrix match the accepted design.
- [ ] Typed spawn, timeout, signal, transport-exit, and command-exit failures are
  preserved and covered without invoking real SSH.

**Verification**:

- `swift test --filter CCUsageTests`
- `swiftlint Sources Tests` when available

## Phase B - Machine registry (AppCore + CLI)

### TASK-002: Implement the registry, mutation owner, and cache migration

**Depends On**: TASK-001
**Write Scope**: machine registry/path/cache files in `Sources/AppCore/`, startup
wiring seams in `Sources/AppCLI/`, and focused registry/cache tests
**Parallelizable**: No

Add `Machines.swift`: `MachineDescriptor`, `SSHConnection`, `MachineKind`,
   `MachineRegistry` (Codable), `MachineRegistryStore` (load/create/save at
   `machines.json`, 0600, always yields a synthetic `local`). Validation: unique
   ids, the design's canonical 1...63-byte lowercase machine-id grammar,
   reserved `local`/`all`, one-pass canonical route/query decoding, normalized
   bounded display names, stable field-error paths, complete SSH grammar,
   immutable synthetic `local`, no inline secret content, and revalidation
   immediately before launch. Make load fail closed: require a real
   current-user-owned mode-`0700` app directory and a regular, single-link,
   current-user-owned mode-`0600` registry opened without following a final
   symlink; bound and fully decode/revalidate it before any listener, cache
   migration, or poller starts. Only absence means empty. Prove a missing-file
   directory can safely create/sync/remove a temporary file. Map unsafe metadata
   or content to sanitized startup failure without chmod, quarantine, rewrite,
   backup promotion, or local-only fallback; document offline repair/removal.
   Implement the exact closed version-1 persisted envelope from the design:
   required integer `schemaVersion: 1`, required `machines`, SSH-only persisted
   descriptors, required canonical `extraOptions` and `remoteCcusagePath`,
   optional-but-never-null `identityFile`, deterministic id ordering, and
   duplicate/unknown-key rejection at every object level. Normalize API
   omission defaults before saving. Reject missing/unversioned/lower/higher
   versions without automatic rewrite; reserve future versions for explicit
   atomic migrations.
   Add a process-wide mutation actor that serializes complete-candidate
   validation, mode enforcement, temp-file sync, atomic replacement as commit,
   registry revision publication, old-generation cancellation/status
   reconciliation, and replacement registration before responding. Fence every
   poll publication by registry revision and poller generation.
`AppPaths`: add `machinesFile` + `aggregationCacheFile(forMachine:)` helper
   (`aggregates-<id>.sqlite3`).
   Add the locked local-cache upgrader before any local cache/poller opens:
   validate/checkpoint/close a sole regular `aggregates.sqlite3`, enforce cache
   directory `0700` and file `0600`, and atomically rename it in the same
   directory to `aggregates-local.sqlite3`. Never copy, merge, or overwrite.
   Destination wins conflicts while source is retained and ignored; invalid
   legacy input rebuilds cleanly; permission/checkpoint/race/rename failures
   map to `cache_failed` without a partial destination. Local cache clear must
   serialize with polling and atomically stage both namespaces and sidecars
   before publishing an empty store.

**Completion Criteria**:

- [ ] Version-1 registry parsing, validation, deterministic persistence, file
  safety, missing-file behavior, and sanitized failures match the design.
- [ ] One mutation owner commits disk state before revision/runtime publication
  and fences late poll results by revision and generation.
- [ ] Per-machine cache paths and the atomic local-cache migration/clear behavior
  preserve valid history and fail without partial destinations.

**Verification**:

- `swift test --filter MachineRegistry`
- `swift test --filter AggregationCache`
- `swiftlint Sources Tests` when available

## Phase C - Machine-aware records + snapshot store (AppCore)

### TASK-003: Add complete machine provenance

**Depends On**: TASK-002
**Write Scope**: record/snapshot/query DTO files in `Sources/AppCore/` and focused
coding, aggregation, and serialization tests
**Parallelizable**: No

Add non-optional `machine: String` (initializer default `"local"`) to
   `CCUsageCostRecord`, `CCUsageMetricRecord`, and
   `CCUsageSessionMetricRecord`. Add backward-compatible decoding that maps an
   absent key to `local`; encoding and APIs always emit the key. Update
   inits/call sites; every block, daily, and session cache/source read
   force-stamps the owning machine id. Add non-optional `machine` to
   `RecentPoint` and `DashboardCostRow`; copy provenance before bucketing and
   include machine in aggregation keys. Test legacy decode, explicit decode,
   default construction, always-present encoding, invalid provenance rejection,
   cache ownership stamping, and every response-row serialization path.

**Completion Criteria**:

- [ ] Legacy decoding/default construction yields `local`; new encoding and all
  row-producing APIs always include a validated machine id.
- [ ] Every source/cache read stamps its owning machine and aggregation keys keep
  otherwise-equal rows from different machines distinct.

**Verification**:

- `swift test --filter CCUsageTests`
- `swift test --filter DashboardTests`
- `swiftlint Sources Tests` when available

### TASK-004: Implement per-machine collection and snapshot state

**Depends On**: TASK-001, TASK-002, TASK-003
**Write Scope**: collector/snapshot files in `Sources/AppCore/` and focused
collector, coverage, concurrency, and health-mapping tests
**Parallelizable**: No

Add a `MachineSnapshotStore` actor: per-machine snapshot, inclusive coverage start,
   transient load status, and `MachineCollectionStatus`.
   `MachineCollector`: builds a `SnapshotService` per enabled machine (local ->
   local runner + reconciliation loaders; ssh -> ssh runner, no event loaders),
   each with its own per-machine cache; a `PollingService`-style loop per machine.
   Map typed runner failures and collection stages to the design's exact closed
   health codes/messages: spawn/timeout/signal/SSH-255 -> `transport_failed`,
   command exit -> `remote_command_failed`, decode/shape -> `invalid_response`,
   cache operation -> `cache_failed`, unexpected orchestration ->
   `internal_error`. Poller cancellation publishes no error, and no typed
   details, status, stderr, arguments, or paths enter API health state.
   Store inclusive `coverageStart` and transient `DashboardLoadStatus` per
   machine. Make scheduled polling retain the earliest loaded coverage; coalesce
   same-machine loads and follow an in-flight load with any newly requested
   earlier expansion. At startup, sequence each enabled machine's initial work
   as a current-host-calendar-week load followed by a warm through the start of
   the previous host-calendar month. The warm sequence runs independently per
   machine, never publishes a narrower coverage boundary, and follows the same
   coalescing, failure-retention, cancellation, revision, and generation fences
   as scheduled/manual loads. Add focused tests that assert the current-week
   request occurs before the previous-month warm, warm requests are per-machine,
   successful warm coverage only moves earlier, and a failed/cancelled/late warm
   cannot replace the current-week snapshot or publish an error/result.

**Completion Criteria**:

- [ ] Each enabled machine owns one runner, snapshot service, cache, poll loop,
  coverage boundary, transient load status, and collection-health state.
- [ ] Same-machine loads coalesce without losing earlier coverage requests, and
  cancellation or late generations cannot publish an error/result.
- [ ] Each enabled machine performs the required ordered startup sequence:
  current-week load first, then previous-month warm; focused tests prove order,
  per-machine independence, earlier-only coverage, and safe warm failure.
- [ ] Public errors use only the accepted sanitized codes and never expose raw
  runner details, stderr, arguments, connection data, identity data, or paths.

**Verification**:

- `swift test --filter Snapshot`
- `swift test --filter MachineCollector`
- `swift test --filter StartupWarm`
- `swiftlint Sources Tests` when available

## Phase D - Machine-aware API (AppCore HTTPService)

### TASK-005: Implement machine-aware queries and control operations

**Depends On**: TASK-002, TASK-003, TASK-004
**Write Scope**: query routing, aggregation, load/refresh, cache-clear, and
mutation-policy code in `Sources/AppCore/HTTPService.swift` or responsibility-
split AppCore files, plus focused router/control tests
**Parallelizable**: No

Update `DashboardRouter` to resolve `?machine=` (default `all`). Provide a snapshot
   selector: single machine -> that snapshot; `all` -> merged snapshot (rows
   stamped with machine id, totals recomputed). Thread through every `/api/*`
   query route. Add non-optional machine attribution to response rows and a
   common `scope` object containing requested, included, stale, unavailable, and
   conservative generated-at values. Implement the design's `400` malformed,
   `404` unknown, `409` disabled, and `503` no-usable-snapshot bodies plus
   `Retry-After`; derive a concrete query error's `collectionState` through the
   same function and store revision as `/api/machine-status` (`disabled`,
   `neverCollected`, or `error` as applicable), while aggregate errors omit the
   singular state. Stale snapshots and partial all-machine results return `200`.
   For all-machine budget/reset metadata, use the host calendar and current host
   boundary, oldest included generation time, minimum positive refresh interval,
   one host budget, and row-derived spending/remaining/overage values. Preserve
   range-driven loading: expand insufficient selected-machine coverage, retain
   the earliest coverage across scheduled/manual refresh, and implement scoped
   `/api/refresh`, `/api/load-status`, and `/api/cache` contracts with the
   design's partial-success rules. For cache clear, freeze one registry
   revision and implement atomic per-machine transaction directories and commit
   markers, stable machine order, startup/pre-clear reconciliation, and
   deliberate cross-machine partial success: `200` all committed, `207` mixed,
   `500` none committed with per-item `cache_failed`. Return stable
   `complete|partial|failed` outcome plus ordered `clearedMachineIds` and
   `failedMachines`; include disabled descriptors in `all` and allow concrete
   disabled-cache deletion. Retain/resume cleanly rolled-back stores, empty/resume
   committed stores, and retain stale/stop pollers that require reconciliation.
   Treat registry POST/PUT/PATCH/DELETE,
   `GET /api/refresh`, and `DELETE /api/cache` as the complete explicit control
   mutation inventory. Before any work, require a recognized loopback authority,
   exact same-origin/fetch metadata for browser calls, and
   `X-CCUsage-Gauge-Mutation: 1`; allow header-bearing non-browser calls without
   browser metadata, reject all other cases with sanitized `403`, no CORS
   authorization, and no observable state change. Route cache-clear runtime
   reconciliation through the registry mutation actor's current revision while
   its cache owner serializes file/store operations.

**Completion Criteria**:

- [ ] Every query route supports canonical `machine=<id|all>`, emits complete
  provenance/scope, and returns the accepted single/aggregate status semantics.
- [ ] Coverage expansion, refresh, and load-status preserve earliest coverage
  and the specified partial-success/stale-retention behavior.
- [ ] Cache clear is atomic per machine, partial across `all`, crash-reconcilable,
  stable in ordering, and serialized with pollers/registry revision ownership.
- [ ] Every explicit control mutation enforces the exact loopback origin/fetch
  metadata/mutation-header policy before any observable state change.

**Verification**:

- `swift test --filter DashboardTests`
- `swift test --filter CacheClear`
- `swift test --filter MutationPolicy`
- `swiftlint Sources Tests` when available

### TASK-006: Implement machine registry and status HTTP contracts

**Depends On**: TASK-002, TASK-004, TASK-005
**Write Scope**: machine CRUD/status DTOs and routes in `Sources/AppCore/`, plus
focused HTTP contract tests
**Parallelizable**: No

Implement `GET/POST /api/machines` and
   `GET/PUT/PATCH/DELETE /api/machines/{id}` using the exact shared DTOs,
   status codes, headers, field-error envelope, reserved-local behavior, and
   atomic-save ordering in the design. Implement the exact
   `GET /api/machine-status?machine=<id|all>` envelope, canonical selection
   errors, local-first/id ordering, nullable timestamp and coverage fields,
   deterministic `disabled|neverCollected|healthy|stale|error` precedence, and
   closed sanitized-error codes. Disabled and unavailable machines remain
   successful status items rather than selection failures.

**Completion Criteria**:

- [ ] Collection/item CRUD exactly matches accepted DTOs, status codes, headers,
  validation envelopes, immutable-id/local rules, and persistence-before-runtime
  ordering.
- [ ] Machine-status uses local-first ordering, exact state precedence and
  nullability, sanitized closed errors, and shared revision-consistent state
  derivation with concrete query errors.

**Verification**:

- `swift test --filter MachineRoute`
- `swift test --filter MachineStatus`
- `swiftlint Sources Tests` when available

## Phase E - CLI wiring

### TASK-007: Wire the production runtimes

**Depends On**: TASK-002, TASK-004, TASK-005, TASK-006
**Write Scope**: `Sources/AppCLI/`, `Sources/CCUsageGaugeMenuBar/`, runtime
composition seams in `Sources/AppCore/`, and focused CLI/runtime tests
**Parallelizable**: No

`serve` builds the registry, `MachineCollector`, `MachineSnapshotStore`, and a
   `DashboardRouter` that reads from the store. Registry mutations restart the
   affected machine's poller through the sole mutation actor. Fail before bind
   on every unsafe/invalid registry or persistence-path condition. Keep
   single-machine `usage-snapshot` working (local). Add the optional `machines`
   list subcommand only if it does not delay or broaden the required feature.

**Completion Criteria**:

- [ ] CLI and menu-bar service load/validate the registry and migrate the local
  cache before listener or poller startup, and share the same mutation owner.
- [ ] Unsafe/invalid persistence state fails before bind; local-only
  `usage-snapshot` remains compatible.

**Verification**:

- `swift test --filter CommandTests`
- `swift test --filter HTTPServiceTests`
- `swift build`
- `swiftlint Sources Tests` when available

## Phase F - Frontend

### TASK-008: Add frontend machine workflows

**Depends On**: TASK-005 and TASK-006 DTOs frozen
**Write Scope**: `frontend/` and generated
`Sources/AppCore/Resources/Web/` assets only
**Parallelizable**: Yes, after TASK-005/TASK-006 DTOs are frozen; write scope is
disjoint from TASK-007

Update `api.ts` with machine types + `machine` param on all query, refresh, load-status,
    and cache calls; exact collection/item CRUD DTOs and
    `/api/machine-status` clients. Add `X-CCUsage-Gauge-Mutation: 1` to refresh,
    cache deletion, and registry mutation requests only.
Update `App.tsx` with a machine selector in the sidebar ("All machines" + entries), scope
    label on stats/chart/table, machine column/attribution when scope = all.
Add a machines registration screen (add/edit/remove ssh info, enable toggle, show
    collection status). Build with `bun run build` -> assets land in
    `Sources/AppCore/Resources/Web/assets`.

**Completion Criteria**:

- [ ] All query/control/CRUD/status requests use the accepted shared contract;
  the mutation header appears on control mutations only.
- [ ] All-machine and concrete-machine views show unambiguous provenance/scope,
  and registration/enable/edit/remove/status flows expose sanitized failures.
- [ ] The production frontend build updates packaged assets without committing
  dependency caches.

**Verification**:

- `cd frontend && bun install && bun run build`
- `task frontend:check`
- `swift build`

## Phase G - Docker Compose emulation + verification

The accepted and only emulation topology is standalone Docker Compose under
Colima. Docker Swarm, `docker stack deploy`, and credential-storage fallbacks
are forbidden. Missing prerequisites are recorded as verification limitations;
they do not block creation of the emulation assets or authorize another
topology.

### TASK-009: Build the Compose emulation topology

**Depends On**: TASK-001, TASK-002, TASK-007, TASK-008
**Write Scope**: `deploy/emulation/` and `deploy/emulation/.runtime/` ignore rule
**Parallelizable**: No

Add `deploy/emulation/`:
    - `Dockerfile.machine`: minimal image with `sshd` + a `ccusage` stub script
      that emits canned per-machine JSON (blocks/daily/session) so no node/ccusage
      install is needed in the container; seeded numbers differ per machine.
    - `Dockerfile.collector`: multi-stage Linux Swift build producing
      `/usr/local/bin/ccusage-gauge` with packaged web resources. The
      unprivileged runtime installs only its Swift runtime dependencies, SQLite
      runtime, OpenSSH client, CA certificates, curl, and a valid zero-cost local
      `ccusage` stub. Its entrypoint validates secret/config/cache access and
      execs `ccusage-gauge serve --port 18081`; it never copies or logs a secret.
    - `compose.yaml`: define `machine-a`, `machine-b`, `keygen`, and one
      collector. Give every service that receives key material its own
      service-scoped `tmpfs` secret directory. `keygen` creates one ed25519
      client-authentication pair only in its tmpfs and remains alive for the
      run. Each SSH machine also has a separate host-key tmpfs, generates its
      own unique ephemeral ed25519 host key at startup after verifying the mount
      type, applies `root:root`/`0600` to the private key and `0644` to its public
      key, and starts `sshd` with only that explicit `HostKey` path. A
      provisioning command
      pipes the private key directly from keygen into collector tmpfs and pipes
      only the public key into each machine tmpfs; set the identity to mode
      `0400` and authorized-key ownership/modes required by `sshd`. Never expand
      key bytes into arguments, environment, tracing, captured output, or logs,
      and fail before collection unless every destination is a tmpfs mount.
      Standalone Compose file-backed `secrets:` are not used for credentials.
      Bind collector cache/config to disposable, gitignored
      `deploy/emulation/.runtime/` directories that are scanned to exclude keys.
      Never use host `~/.ssh`, host files for emulation keys, ordinary credential mounts, image
      layers, named volumes, container writable layers, environment, arguments,
      or logs for key material. The production `identityFile` contract may
      reference an operator-managed host file, but the application must never
      copy its key contents into application-managed persistence. Publish fixed
      machine SSH ports but no collector API port. Registry entries use the
      Compose host-gateway and published SSH
      ports instead of service DNS or direct port 22, preserving the forwarded-
      port boundary. Production packaging remains a host `serve` process.

**Completion Criteria**:

- [ ] Compose defines two distinct SSH machines, keygen, and one unprivileged
  collector with no published collector API port.
- [ ] Client and host keys exist only in service-scoped tmpfs mounts and are
  transferred by non-logging pipes; runtime/config/cache mounts remain
  credential-free and disposable.
- [ ] Registry connections traverse host-gateway published SSH ports, preserving
  the forwarded-port boundary.

**Verification**:

- `docker compose -f deploy/emulation/compose.yaml config`
- `git check-ignore deploy/emulation/.runtime/`

### TASK-010: Add the end-to-end emulation smoke test

**Depends On**: TASK-009
**Write Scope**: `scripts/smoke-remote-machines.sh` only
**Parallelizable**: No

Add `scripts/smoke-remote-machines.sh`: self-check Colima, Docker Engine,
    Docker Compose, image-build, host-gateway, and tmpfs prerequisites -> start
    Colima when available and needed -> `docker compose build` and bring up the
    project -> generate the one-time client-authentication pair in keygen tmpfs
    -> pipe it into the service tmpfs destinations -> generate one machine-local
    host key in each SSH server's host-key tmpfs -> validate placement,
    ownership, modes, and non-empty distinct host-key fingerprints ->
    wait for the collector -> call its loopback API only via
    `docker compose exec collector curl http://127.0.0.1:18081` -> register machines via
    `/api/machines` -> assertions, setting
    `X-CCUsage-Gauge-Mutation: 1` on every state-changing call:
    per-machine `/api/metrics?machine=machine-a`, aggregate `?machine=all`, and
    filter/provenance correctness -> assert synthetic `local` is healthy with
    zero cost and aggregate totals equal `machine-a + machine-b` -> deliberately
    stop or make one registered SSH machine unavailable while retaining its
    last usable snapshot, then assert the accepted degraded/partial contracts:
    concrete status is sanitized `stale` or `error` as appropriate; `machine=all`
    returns `200` when at least one usable snapshot remains; scope lists exact
    included/stale/unavailable machine ids with no raw SSH/process details; rows
    retain machine provenance; totals include only the declared included
    machines; and the aggregate error path returns `503` only when no usable
    snapshot remains -> verify the
    collector has no published HTTP port, all credential destinations are
    tmpfs, and keys are absent from images, ordinary mounts, writable layers,
    runtime data, process environment/arguments, logs, named volumes, and Git
    candidates -> always run `docker compose down`, remove the credential-free
    runtime directory, and verify no emulation container or client/host-key
    tmpfs remains; when lifecycle regeneration is explicitly tested, assert a
    clean subsequent start produces host-key fingerprints different from the
    prior run. If a prerequisite is unavailable, emit the exact limitation and
    exit without claiming runtime or credential-isolation success.

**Completion Criteria**:

- [ ] The script validates prerequisites, builds/starts/provisions the topology,
  exercises local, concrete remote, aggregate, provenance, and health behavior,
  and always performs bounded cleanup.
- [ ] Runtime assertions cover a deliberately degraded remote machine and prove
  the accepted partial-state status, scope, provenance, totals, sanitization,
  stale retention, and no-usable-snapshot contracts.
- [ ] It proves key placement/isolation and the absence of credentials from all
  forbidden locations without printing key bytes.
- [ ] Missing Colima/Docker prerequisites produce an explicit limitation and do
  not claim runtime or isolation success.

**Verification**:

- `bash -n scripts/smoke-remote-machines.sh`
- `scripts/smoke-remote-machines.sh`

### TASK-011: Add coverage, documentation, and closeout evidence

**Depends On**: TASK-001 through TASK-010
**Write Scope**: `.gitignore`, `README.md`, `Taskfile.yml`, coverage tooling under
`scripts/`, tests needed for the threshold, and this implementation plan
**Parallelizable**: No

Update `.gitignore` (`deploy/emulation/.runtime/`), `README`, and
    `Taskfile.yml` with emulation tasks. Add `task test:coverage` backed by a
    repository script that runs `swift test --enable-code-coverage`, discovers
    the SwiftPM coverage artifact and test binary without an architecture-fixed
    path, invokes the active toolchain's `llvm-cov`, includes executable lines
    in `Sources/AppCore` and `Sources/AppCLI`, excludes tests/generated code/web
    resources, and fails below 80.0% total line coverage or when tooling or
    artifacts are unavailable.

**Completion Criteria**:

- [ ] Documentation and task automation describe only the accepted standalone
  Compose/Colima topology and its prerequisite limitations.
- [ ] Executable lines in `Sources/AppCore` and `Sources/AppCLI` meet the 80.0%
  threshold through architecture-independent coverage artifact discovery.
- [ ] All verification commands and any environmental limitation are recorded;
  all task/deliverable checkboxes reflect evidence rather than intent.
- [ ] Final-gate evidence records each command, exit result, and material
  assertion for frontend typecheck/build, Swift build/test/coverage/lint, CLI
  smoke, loopback HTTP smoke, SwiftPM/Formula/Cask release-layout scaffolding,
  remote-machine emulation, whitespace, and worktree hygiene. A skipped command
  remains an explicit unmet criterion unless the design permits an environmental
  limitation; Colima/Docker limitations never count as runtime/isolation proof.

**Verification**:

- `task test:coverage`
- `task frontend:check`
- `task frontend:build`
- `task build`
- `task test`
- `task lint` when SwiftLint is available
- `task smoke:isolated-runtime` (CLI and isolated-path evidence)
- `task smoke:dashboard` (loopback HTTP readiness, routes, shutdown, restart,
  and final port-release evidence)
- `task smoke:assets` (SwiftPM, Formula, and Cask packaged-resource layouts plus
  missing-resource diagnostics)
- `scripts/build-homebrew-release.sh --dry-run darwin-arm64 darwin-x64`
- `scripts/build-homebrew-cask-release.sh --dry-run darwin-arm64 darwin-x64`
  on macOS (release-script scaffolding only; do not publish)
- `bash -n scripts/smoke-remote-machines.sh`
- `bash scripts/smoke-remote-machines.sh`
- `git diff --check`
- `git status --short`

## Testing

- Unit: SSH canonical argv/quoting/allowlist/rejections; registry load and full
  validation, including every id boundary, reserved id, Unicode display-name
  normalization/limit, stable field-error mapping, and canonical percent decode;
  exact version-1 envelope encoding/decoding and deterministic ordering; missing,
  unversioned, lower, higher, duplicate-key, unknown-field, default-normalized,
  null-optional, and persisted-local rejection; legacy and explicit provenance
  coding for block/daily/session records; per-machine cache path and ownership
  stamping; merged-snapshot totals, host budget/reset/time semantics,
  stale/partial/no-snapshot selection, response scope, and non-optional machine
  serialization for `/api/recent`, `/api/day`, `/api/period`, `/api/metrics`, and
  every `/api/cost-series` granularity. Prove equal timestamp/agent/model rows
  from different machines remain distinct and attributable, plus
  router machine parameter/status behavior. Exercise all machine-status states,
  precedence, ordering, nullability, timestamp format, selection errors, stale
  age boundary, and error sanitization. Assert exact runner classifications for
  spawn failure, timeout, signal, SSH exit 255, SSH exits 1 and 254, and local
  nonzero exit; assert decode and cache failures map to their closed public
  codes/messages while typed details remain absent. Assert concrete query 503
  state is `neverCollected` before a failed attempt and `error` after one,
  disabled query state is `disabled`, and query/status state derivation is
  identical for the same store revision; aggregate errors omit a singular
  state. Cover per-machine coverage
  retention, concurrent all-machine range expansion, failed expansion with
  stale retention, refresh scope/partial results, load-status aggregation, and
  cache-clear scope. Cover the ordered startup current-week load followed by
  previous-host-calendar-month warm for every enabled machine, per-machine warm
  independence, earlier-only coverage publication, coalescing, and failed,
  cancelled, or late-generation warm retention. Cover concrete and all-machine
  clear complete success,
  mixed `207`, none-committed `500`, stable ordering, middle-machine staging
  failure, clean rollback, rollback failure with stopped poller/stale snapshot,
  committed-unlink retry, crash before/after commit marker, startup
  reconciliation, and unaffected-machine continuity. Exercise every CRUD
  route/body/status/error contract,
  including enable PATCH and local/duplicate/validation/persistence failures.
  Cover missing-registry startup, safe empty creation, malformed/unknown-field/
  invalid-descriptor files, oversized input, symlink/non-file/multi-link/wrong-
  owner/broad-mode registry and directory rejection, unwritable/create/sync/
  pre-commit rename failures, no local-only fallback, and restart after offline
  repair or intentional removal. Race concurrent create/update/delete requests and prove
  ordered revisions, no lost update, persistence-before-publish, response-after-
  replacement, unaffected poller continuity, and rejection of late generation
  publications. For every registry mutation, refresh, and cache-delete route,
  test exact allowed loopback origins, mismatched host/port/scheme, null origin,
  same-site and cross-site fetch metadata, absent/wrong mutation header,
  non-browser header-bearing calls, denied preflight/no CORS headers, and
  unchanged registry/cache/poller/refresh state after rejection.
  Cover local-cache upgrade with legacy-only history preservation, destination-
  only startup, source/destination conflict precedence without merge, missing
  source clean creation, symlink/non-file/invalid-schema rejection and rebuild,
  WAL checkpointing, mode enforcement, injected checkpoint/chmod/race/rename
  failures with no partial destination, restart retry, and local cache clear of
  both namespaces/sidecars without legacy resurrection.
- Integration: `swift test` full suite stays green. `task test:coverage` passes
  the repository's 80.0% executable-line threshold.
- E2E: colima smoke script (Phase G) is the "local operation verification".
  Its evidence includes healthy local/two-remote collection and a deliberately
  degraded remote asserting the exact partial-state, stale/unavailable scope,
  provenance, included-only totals, sanitization, and no-usable-snapshot rules.

## Dependency Summary

- Transport foundation: TASK-001.
- Registry/cache foundation: TASK-001 -> TASK-002.
- Provenance: TASK-002 -> TASK-003.
- Collection state: TASK-001 + TASK-002 + TASK-003 -> TASK-004.
- Query/control API: TASK-002 + TASK-003 + TASK-004 -> TASK-005.
- Registry/status API: TASK-002 + TASK-004 + TASK-005 -> TASK-006.
- Runtime composition: TASK-002 + TASK-004 + TASK-005 + TASK-006 -> TASK-007.
- Frontend: frozen TASK-005/TASK-006 DTOs -> TASK-008.
- Emulation: TASK-001 + TASK-002 + TASK-007 + TASK-008 -> TASK-009 -> TASK-010.
- Coverage/documentation/closeout: TASK-001 through TASK-010 -> TASK-011.

## Parallel Work Windows

- TASK-008 may run beside TASK-007 only after TASK-005 and TASK-006 freeze the
  shared HTTP DTOs. TASK-008 writes `frontend/` and generated web resources;
  TASK-007 writes CLI/menu-bar/runtime composition files. Coordinate the single
  generated-assets handoff before either task verifies `swift build`.
- All other tasks are sequential because they share AppCore contracts, runtime
  ownership, cache/registry behavior, generated resources, emulation inputs, or
  final evidence. Do not infer additional parallelism from phase grouping.

## Overall Completion Criteria

- [ ] TASK-001 through TASK-011 and all deliverables are checked only after their
  recorded completion criteria and commands pass.
- [ ] The implementation matches all four accepted design references with no
  undocumented divergence and no change to the locked topology/security model.
- [ ] `task frontend:check`, `task frontend:build`, `task build`, `task test`,
  `task test:coverage`, and `task lint` when SwiftLint is available pass with
  commands, exit results, and material assertions recorded.
- [ ] `task smoke:isolated-runtime`, `task smoke:dashboard`, and
  `task smoke:assets` pass with explicit CLI, loopback HTTP, shutdown/restart,
  port-release, SwiftPM/Formula/Cask layout, and missing-resource evidence; both
  Homebrew release builders pass their macOS dry-run scaffolding checks without
  publishing or mutating a tap.
- [ ] `scripts/smoke-remote-machines.sh` passes its prerequisite checks and E2E
  assertions, including degraded/partial machine-state contracts, or records
  the exact Colima/Docker limitation without claiming runtime or credential-
  isolation success.
- [ ] No credentials, private URLs, machine-local absolute paths, emulation
  runtime data, or unrelated worktree changes enter the feature deliverables.
- [ ] The final progress entry lists changed files, residual risks/TODOs, review
  findings and decisions, and verification commands/results; the plan moves to
  `impl-plans/completed/` only after implementation and required review accept.

## Risks and Mitigations

- Registry/cache filesystem races or unsafe metadata: use bounded no-follow
  inspection, current-user ownership/mode checks, synchronized atomic commits,
  injected fault tests, and fail before listener/poller startup.
- Stale poll publication or lost mutation: centralize mutations, publish immutable
  revisions, fence collector generations, and race CRUD/replacement tests.
- Shell/SSH injection or ambient configuration: fixed argv ordering, `-F
  /dev/null`, closed option parsing, canonical destination validation, token-by-
  token POSIX quoting, and immediate pre-launch revalidation.
- Cross-machine attribution or totals drift: force-stamp ownership at source and
  cache boundaries, include machine in every aggregation key/row, and recompute
  aggregate totals from included rows under host time/budget semantics.
- Cache-clear crash consistency: use per-machine transaction directories/commit
  markers, deterministic startup reconciliation, and explicit partial success.
- Credential leakage in emulation: use only service-scoped tmpfs key locations,
  pipe transfers without tracing/capture, scan every forbidden sink, and always
  tear down the Compose project.
- Colima/Docker/tooling unavailable: still deliver and statically validate assets;
  record the exact limitation and never substitute Swarm, file-backed secrets,
  or another credential-storage/topology model.
- Swift file growth and actor complexity: split by responsibility below 1000
  lines, validate focused tests after each task, and run SwiftLint when available.

## Progress Log

- 2026-07-17 — PLAN — ready — created the actionable plan from the Step 3-
  accepted design and locked user decisions; added explicit deliverables,
  TASK-001 through TASK-011, dependencies, disjoint write scopes, verification,
  completion gates, and risks — `git diff --no-index --check /dev/null
  impl-plans/active/remote-machine-collection.md` passed — no
  Step 5 feedback or Codex-agent reference input was supplied; next task is
  TASK-001.
- 2026-07-17 — PLAN-REVIEW — revised — addressed PLAN-001 through PLAN-004:
  added ordered startup current-week/previous-month warm work and tests to
  TASK-004; replaced the nonexistent conditional frontend typecheck with
  `task frontend:check`; added degraded/partial machine-state assertions to
  TASK-010; and made architecture final-gate commands and evidence explicit in
  TASK-011 and overall completion — verification pending below; independent
  Step 5 review and implementation remain next.

Future entries must use: `YYYY-MM-DD — TASK-NNN — status — changed deliverables
and files — commands/results — findings addressed — blockers, residual risks, or
next task`. A task remains incomplete when a required command is unavailable;
record the limitation and the unverified criterion rather than checking it.
