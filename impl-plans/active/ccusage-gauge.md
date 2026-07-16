# ccusage-gauge Menubar and Dashboard

**Status**: Ready for Implementation
**Workflow Mode**: issue-resolution
**Issue Reference**: `comm-001058` / `codex-design-and-implement-review-loop-session-558`
**Design References**: `design-docs/specs/architecture.md`, `design-docs/specs/command.md`
**Codex Agent References**: None supplied; no reference-behavior divergence applies.

## Purpose

Implement the accepted macOS 14+ product design: a Swift menu-bar cost gauge
whose only usage source is `ccusage --json`, with persisted budget/reset state
and a loopback Swift service serving a bun-built SolidJS dashboard. Preserve the
read-only static configuration boundary, the mutable-state boundary, Swift 6
concurrency safety, and existing Homebrew release workflows.

## Deliverables

- [ ] Testable `AppCore` configuration, state, reset-window, process,
  aggregation, polling, dashboard-query, and HTTP-service components.
- [ ] Extended `AppCLI` commands matching `design-docs/specs/command.md`.
- [ ] A macOS AppKit menu-bar executable with budget, reset-cycle, dashboard,
  status/error, and lifecycle actions.
- [ ] A bun + SolidJS + one-CSS-framework SPA under `frontend/`, compiled into
  immutable assets usable in development and packaged layouts.
- [ ] SwiftPM resources/targets, `flake.nix`, and `Taskfile.yml` wiring without
  regressing formula or Cask scaffolding.
- [ ] Unit fixtures and tests for storage, reset boundaries, JSON aggregation,
  polling, query APIs, and service behavior.
- [ ] Verification evidence and synchronized design/plan status.

## Execution Rules

- Complete tasks in dependency order and record each task's date, result,
  verification commands, and remaining work in the Progress Log.
- Keep every Swift file below 1000 lines and split by responsibility.
- Run SwiftLint after each Swift task when available, plus the narrowest relevant
  build/test before broader checks.
- Never read raw Claude usage JSONL. Invoke only fixed `ccusage blocks --json`
  and `ccusage daily --json` argument arrays through `Process`.
- Never copy, stage, package, or commit
  the user-provided visual reference image.
- Treat existing user changes as owned by the user and do not revert unrelated
  files.

## Tasks

### TASK-001: Establish package and test seams

**Depends On**: None
**Write Scope**: `Package.swift`, new target/resource directories only
**Parallelizable**: No

Add the accepted target/resource structure while retaining `AppCore`, `AppCLI`,
and current product names. Add an AppKit menu-bar executable and the minimum
Apple framework linkage needed by the chosen loopback HTTP implementation.
Define resource placement for compiled SPA assets without committing generated
dependency caches.

**Completion Criteria**:

- [ ] SwiftPM describes all accepted targets and macOS 14 deployment.
- [ ] Empty/new target boundaries compile before domain work begins.
- [ ] Existing CLI help/version tests remain valid or are deliberately updated.

**Verification**:

- `swift package describe`
- `swift build --target AppCore`
- `swift test --filter CommandTests`

### TASK-002: Implement static configuration and mutable state stores

**Depends On**: TASK-001
**Write Scope**: configuration/state files in `Sources/AppCore/`; focused store
tests in `Tests/AppCoreTests/`
**Parallelizable**: No

Implement injected production/test path resolution. Create the exact default
static configuration only when absent, validate it without rewriting existing
content, and use user-only permissions where supported. Implement atomic mutable
state persistence for budget, reset cycle, manual-reset timestamp, and reset
baseline. Report corrupt state without silently replacing it.

**Completion Criteria**:

- [ ] Generated config contains the five exact accepted defaults.
- [ ] Existing config remains byte-for-byte unchanged after load, validation,
  menu operations, and state writes.
- [ ] A configured invalid `ccusagePath` remains an error, not a PATH fallback.
- [ ] State round-trips every reset-cycle variant and baseline field atomically.
- [ ] Production and test paths are injectable rather than static globals.

**Verification**:

- `swift test --filter ConfigStoreTests`
- `swift test --filter StateStoreTests`
- `swiftlint Sources/AppCore Tests/AppCoreTests`

### TASK-003: Implement reset-baseline and budget domain logic

**Depends On**: TASK-002
**Write Scope**: reset/budget files in `Sources/AppCore/`; reset/budget test files
**Parallelizable**: No

Implement scheduled boundaries for daily, active-calendar weekly, monthly, and
positive custom-hour cycles. Validate/recompute persisted baselines using cycle,
manual reset, calendar, time zone, and scheduled boundary. Make reset-now and
cycle changes single atomic state transitions. Apply the clarified closed
accounting interval `[baseline.activeBoundaryAt, now]`: records exactly at both
bounds are included and records after `now` are excluded.

**Completion Criteria**:

- [ ] Baseline metadata never contributes monetary value.
- [ ] Valid baselines survive restart; stale baselines recompute and persist.
- [ ] Later manual reset wins; older manual reset does not replace a newer
  scheduled boundary.
- [ ] DST/calendar cases use injected fixed clocks, calendars, and time zones.
- [ ] Budget results preserve raw overage while capping only the visual fraction.

**Verification**:

- `swift test --filter ResetWindowTests`
- `swift test --filter BudgetSummaryTests`
- `swiftlint Sources/AppCore Tests/AppCoreTests`

### TASK-004: Implement ccusage resolution, execution, decoding, and aggregation

**Depends On**: TASK-001
**Write Scope**: process/decoding/aggregation files in `Sources/AppCore/`; JSON
fixtures and corresponding test files
**Parallelizable**: Yes, concurrently with TASK-002 and TASK-003 only while its
listed files remain disjoint

Resolve an explicit absolute executable first or search PATH only when the
configuration value is null. Add an asynchronous, timeout-capable process seam
that captures exit status/stdout/stderr without shell interpolation. Decode
v20.0.17-compatible blocks/daily JSON tolerantly and aggregate model costs once
per record using `Decimal`.

**Completion Criteria**:

- [ ] Missing, non-executable, timed-out, nonzero-exit, invalid-JSON, and missing
  required-field cases produce typed, non-sensitive errors.
- [ ] Unknown JSON fields are ignored and aggregate/model totals are not double
  counted.
- [ ] Fixtures document accepted block and daily shapes and include multiple
  models and boundary timestamps.
- [ ] No code reads raw usage JSONL or composes a shell command.

**Verification**:

- `swift test --filter CCUsageExecutableResolverTests`
- `swift test --filter CCUsageDecoderTests`
- `swift test --filter CostAggregationTests`
- `swiftlint Sources/AppCore Tests/AppCoreTests`

### TASK-005: Compose snapshots, polling, and dashboard queries

**Depends On**: TASK-003, TASK-004
**Write Scope**: snapshot/polling/query files in `Sources/AppCore/`; focused tests
**Parallelizable**: No

Compose validated state and ccusage records into one cost snapshot used by every
consumer. Add single-flight background polling with cancellation, last-success
retention, and stale/error state. Implement recent, selected-day, period, and
budget query services with injected calendar/time zone and stable response DTOs.

**Completion Criteria**:

- [ ] Menubar, CLI, and HTTP consumers share the same snapshot/query services.
- [ ] Concurrent timer ticks never overlap `ccusage` processes.
- [ ] Poll failures retain the last successful snapshot and expose freshness.
- [ ] Day and period grouping is correct across local boundaries.
- [ ] All domain/process work is `Sendable` and off the main actor.

**Verification**:

- `swift test --filter SnapshotServiceTests`
- `swift test --filter PollingServiceTests`
- `swift test --filter DashboardQueryTests`
- `swiftlint Sources/AppCore Tests/AppCoreTests`

### TASK-006: Extend the CLI contract

**Depends On**: TASK-002, TASK-005
**Write Scope**: `Sources/AppCore/Command.swift`, `Sources/AppCLI/`, CLI tests
**Parallelizable**: No

Implement side-effect-free help/version and the accepted `config-check`,
`usage-snapshot [--json]`, and foreground `serve` command parsing. Reuse
AppCore services, stable exit codes, injected development/test paths, JSON error
codes, and non-sensitive diagnostics.

**Completion Criteria**:

- [ ] Command behavior and exit codes match `design-docs/specs/command.md`.
- [ ] Help/version create neither config nor state.
- [ ] `config-check` creates only a missing static config and never rewrites one.
- [ ] Snapshot uses the persisted active boundary and ccusage JSON only.
- [ ] Invalid options exit 2; runtime failures exit 1.

**Verification**:

- `swift test --filter CommandTests`
- `swift build --product ccusage-gauge`
- `swift run ccusage-gauge --help`
- `swiftlint Sources/AppCore Sources/AppCLI Tests/AppCoreTests`

### TASK-007: Implement the loopback HTTP service and API

**Depends On**: TASK-005
**Write Scope**: HTTP/service/resource files in `Sources/AppCore/`; service tests
**Parallelizable**: No

Implement a portable POSIX loopback listener with deterministic start/stop and no
extra service process. Bind only `127.0.0.1`, serve immutable assets with the
accepted resolution order, and expose the accepted read-only routes. Validate
query parameters and return stable JSON or machine-readable, non-sensitive
errors with the specified status classes.

**Completion Criteria**:

- [ ] Repeated start/stop is safe and stop releases the port.
- [ ] Listener never binds a wildcard/non-loopback address.
- [ ] `/api/recent`, `/api/day`, `/api/period`, and `/api/budget` use TASK-005
  services and return stable JSON.
- [ ] API bad input, unknown routes, query failures, and missing assets map to
  the accepted status/error behavior.
- [ ] SPA fallback excludes API paths and no directory listing is exposed.

**Verification**:

- `swift test --filter HTTPServiceTests`
- `swift test --filter APIRouteTests`
- `swift build --target AppCore`
- `swiftlint Sources/AppCore Tests/AppCoreTests`

### TASK-008: Build the AppKit menu-bar executable

**Depends On**: TASK-005, TASK-007
**Write Scope**: menu-bar target sources/resources and target-specific tests if
applicable
**Parallelizable**: No

Create the `NSStatusItem` lifecycle and menu presentation. Show formatted cost
since reset; budget pie/spent/remaining state; budget editing; reset-now; cycle
selection including custom hours; dashboard start/stop/open; errors/guidance;
and quit. Keep AppKit mutation on the main actor and domain/poll work outside it.
Honor dashboard autostart and stop all resources on termination.

**Completion Criteria**:

- [ ] Missing ccusage produces guidance and no crash.
- [ ] Budget and reset menu actions atomically update only mutable state.
- [ ] Polling never blocks the UI and status/menu refresh on the main actor.
- [ ] Open-dashboard starts the service when required and opens the configured
  loopback URL.
- [ ] The application behaves as a menu-bar app without an ordinary Dock window.

**Verification**:

- `swift build --target CCUsageGaugeMenuBar`
- `swift test --filter MenuBarIntegrationTests`
- `swiftlint Sources Tests`

### TASK-009: Build the SolidJS dashboard source

**Depends On**: TASK-005 response DTOs finalized
**Write Scope**: `frontend/` only
**Parallelizable**: Yes, concurrently with TASK-007 and TASK-008 because its
write scope is disjoint after API response DTOs are frozen

Create a bun-managed SolidJS SPA with one CSS framework. Implement the green-bar
recent series, local date selection, time-of-day breakdown, period total, and
Today/Yesterday/This week/This month quick choices. Consume same-origin APIs and
show explicit loading, empty, and failure states. Do not commit `node_modules`
or other generated caches.

**Completion Criteria**:

- [ ] The production build emits deterministic static assets.
- [ ] All accepted views and period controls are usable at narrow and desktop
  widths.
- [ ] No frontend code invokes ccusage or reads local files.
- [ ] API and empty-series failures remain visible and recoverable.

**Verification**:

- `cd frontend && bun install --frozen-lockfile`
- `cd frontend && bun run build`
- `cd frontend && bun run check`

### TASK-010: Wire frontend tooling and packaged asset layouts

**Depends On**: TASK-007, TASK-009
**Write Scope**: `flake.nix`, `Taskfile.yml`, SwiftPM resource declarations,
`scripts/smoke-packaged-assets.sh`, packaging scripts only where asset placement
requires it, and focused asset-resolver tests
**Parallelizable**: No

Add bun and required frontend tooling to the Nix shell, Taskfile install/check/
build tasks, and a reproducible copy/embed step for Swift service assets. Validate
development override, SwiftPM resource, formula executable-adjacent, and Cask app
bundle lookup without changing unrelated release behavior.

Add the executable `scripts/smoke-packaged-assets.sh` with
`--layout swiftpm|formula|cask|all` and `--expect-missing-diagnostics` modes. It
must build frontend assets once, stage each selected layout in a fresh temporary
directory using the same relative paths produced by SwiftPM and the Formula/Cask
release scripts, launch the staged service on an ephemeral loopback port, wait
for readiness, and verify that `/` returns the staged index. Its missing-assets
mode must remove the staged asset root for each layout and assert the documented
diagnostic status/body without exposing a directory listing. Always terminate
and wait for the probe service through a trap and remove staging directories.
Keep focused resolver tests for precedence and diagnostics so the SwiftPM bundle
case is exercised directly rather than inferred from release-script `--help`.

**Completion Criteria**:

- [ ] `nix develop` exposes bun and the documented frontend commands.
- [ ] Swift builds can consume built assets without committing dependency caches.
- [ ] Formula and Cask scripts retain their original CLI contracts.
- [ ] SwiftPM, Formula, and Cask staging each deliver the expected index through
  the real resolver from their accepted packaged location.
- [ ] Every supported layout has an explicit missing-assets check that produces
  a diagnostic response rather than a directory listing or crash.
- [ ] Asset smoke processes are stopped and awaited and leave no bound ports or
  temporary staging trees.

**Verification**:

- `nix develop --command bun --version`
- `cd frontend && bun run check`
- `task frontend:build`
- `swift test --filter StaticAssetResolverTests`
- `scripts/smoke-packaged-assets.sh --layout swiftpm`
- `scripts/smoke-packaged-assets.sh --layout formula`
- `scripts/smoke-packaged-assets.sh --layout cask`
- `scripts/smoke-packaged-assets.sh --layout all --expect-missing-diagnostics`
- `task build`
- `scripts/build-homebrew-release.sh --help`
- `scripts/build-homebrew-cask-release.sh --help`

### TASK-011: Run integrated service and failure-path smoke checks

**Depends On**: TASK-006, TASK-008, TASK-010
**Write Scope**: `scripts/smoke-dashboard.sh`,
`scripts/smoke-isolated-runtime.sh`, deterministic ccusage smoke fixtures, and
their `Taskfile.yml` entry points
**Parallelizable**: No

Create an executable `scripts/smoke-dashboard.sh` that installs a deterministic
fixture-backed fake `ccusage` in a fresh temporary root, writes an isolated
config pointing to that absolute executable, and starts the foreground dashboard
in the background on `127.0.0.1:18081`. The script must capture the PID, poll a
readiness endpoint with a bounded timeout, curl `/` and every JSON route, and
assert fixture-derived values rather than merely HTTP success. It must send
SIGTERM, `wait` for exit 0, prove the listener is gone, restart the same command
on port 18081, reach readiness again, then stop/wait once more and prove the port
is free. A trap must perform cleanup on every failure path so no foreground
command blocks later checks.

Create an executable `scripts/smoke-isolated-runtime.sh` that captures the
pre-run absence or checksum/metadata of the operator's real config and state,
then runs all commands with an injected temporary HOME/base paths. First verify
config creation and fixture-backed snapshot/state writes occur only below the
temporary root. Next write an isolated config whose `ccusagePath` is a nonexistent
absolute path while placing an executable fake `ccusage` earlier in PATH; the
fake executable must leave an invocation marker if called. Assert `config-check`
and `usage-snapshot --json` exit exactly 1, emit actionable missing-executable
guidance without a crash, never create the marker, and therefore never fall back
to PATH. Finally assert the real config/state absence or checksum/metadata is
unchanged. Keep a separately labeled live `ccusage` aggregation smoke optional;
fixture-backed coverage is mandatory and deterministic. Do not require a GUI
screenshot loop.

**Completion Criteria**:

- [ ] Index and all four API route groups return expected content/status.
- [ ] API values are checked against versioned deterministic blocks/daily JSON
  fixtures, including a model-summed total.
- [ ] The service binds `127.0.0.1:18081` by default and releases it on stop.
- [ ] Background launch uses bounded readiness polling; both service runs are
  terminated and awaited, and the same port can be rebound between runs.
- [ ] A bogus configured absolute ccusage path produces exit 1 and actionable
  guidance, with no PATH fallback, fake-executable marker, signal crash, or
  operator-home write.
- [ ] Isolated config/state checks do not touch the operator's real home files.
- [ ] Live ccusage check is recorded as passed or unavailable with fixture tests
  still passing; it is not silently omitted.

**Verification**:

- `task smoke:isolated-runtime`
- `task smoke:dashboard`
- `scripts/smoke-isolated-runtime.sh`
- `scripts/smoke-dashboard.sh --port 18081 --assets frontend/dist`
- `CCUSAGE_GAUGE_LIVE_SMOKE=1 scripts/smoke-isolated-runtime.sh --live-ccusage`
  (record pass or explicit tool-unavailable skip; never substitute it for the
  deterministic fixture run)

### TASK-012: Complete repository verification and documentation sync

**Depends On**: TASK-011
**Write Scope**: design documents, this plan, and verification notes only
**Parallelizable**: No

Run the full project checks, inspect the complete diff, confirm the prohibited
image is absent, and update design documents for any implemented choices that
remain within the accepted behavior. Mark completed tasks and record residual
TODOs. Move this plan to `impl-plans/completed/` only when every completion
criterion is met; otherwise leave it active with explicit blockers.

**Completion Criteria**:

- [ ] Full build/test/lint/frontend checks pass or each environmental skip has
  an explicit reason and equivalent evidence.
- [ ] Design and command docs accurately describe shipped behavior.
- [ ] No unrelated file changes, secrets, private URLs, or machine-local paths
  are introduced, except the explicit prohibited-path warning in documentation.
- [ ] `IMG_1875.HEIC` is absent from tracked files and release inputs.
- [ ] Progress Log contains dated evidence for TASK-001 through TASK-012.

**Verification**:

- `cd frontend && bun run check`
- `task frontend:build`
- `task build`
- `task test`
- `task lint`
- `task smoke:assets`
- `task smoke:isolated-runtime`
- `task smoke:dashboard`
- `git diff --check`
- `git status --short`
- `git diff -- design-docs impl-plans`
- `git ls-files | rg '(^|/)IMG_1875\\.HEIC$'`

## Dependency Summary

- Foundation: TASK-001.
- Domain storage and reset: TASK-001 -> TASK-002 -> TASK-003.
- Usage ingestion: TASK-001 -> TASK-004.
- Shared snapshot/query layer: TASK-003 + TASK-004 -> TASK-005.
- CLI: TASK-002 + TASK-005 -> TASK-006.
- Service: TASK-005 -> TASK-007.
- Menu bar: TASK-005 + TASK-007 -> TASK-008.
- Frontend: frozen TASK-005 DTOs -> TASK-009; TASK-007 + TASK-009 -> TASK-010.
- Integration and closeout: TASK-006 + TASK-008 + TASK-010 -> TASK-011 ->
  TASK-012.

## Parallel Work Windows

- TASK-004 may run beside TASK-002/TASK-003 because process/fixture files and
  store/reset files are disjoint; coordinate only public AppCore protocol names.
- TASK-009 may run beside TASK-007/TASK-008 after response DTOs are frozen because
  it writes only `frontend/`.
- All other tasks are sequential due to shared package, AppCore composition,
  resource-wiring, or documentation files.

## Overall Completion Criteria

- [ ] All acceptance criteria in the authoritative workflow input are met.
- [ ] Static config is create-once/read-only and mutable state is isolated under
  `~/.local/ccusage-gauge/`.
- [ ] Every cost value originates from model-summed `ccusage --json` records and
  the clarified inclusive lower/upper reset interval is tested.
- [ ] Menubar, CLI, and dashboard share AppCore behavior and remain responsive.
- [ ] Dashboard is loopback-only, serves the SPA, and exposes only read-only v1
  APIs.
- [ ] Swift, frontend, smoke, release-scaffolding, and repository hygiene checks
  have recorded evidence.
- [ ] Packaged assets have real SwiftPM/Formula/Cask success and missing-root
  evidence; service smoke evidence includes readiness, fixture values, shutdown,
  wait, same-port restart, and final port release.
- [ ] Isolated-path evidence proves invalid configured `ccusagePath` returns 1,
  rejects PATH fallback, and leaves the operator's real config/state unchanged.
- [ ] Design docs match implementation and this plan is either completed or
  retains explicit residual TODOs.

## Risks and Mitigations

- Swift 6 actor/sendability errors: isolate AppKit on the main actor and make
  process, polling, listener, and DTO boundaries explicitly `Sendable`; validate
  each target incrementally.
- ccusage schema drift: tolerate additive fields, require accounting fields,
  pin v20.0.17-shaped fixtures, and prevent aggregate/model double counting.
- Reset math and DST errors: inject clock/calendar/time zone and test both exact
  bounds, scheduled rollover, manual reset, cycle change, and restart.
- Listener/parser correctness: bind only IPv4 loopback, cap request sizes, reject
  invalid methods/parameters, expose no filesystem input, and test stop/rebind.
- Frontend asset layout differences: validate development, SwiftPM, formula, and
  Cask resolution in TASK-010 before closeout.
- Tool availability: add bun through Nix, run SwiftLint when available, and log
  environmental limitations without treating them as functional success.
- Scope overrun: preserve task order; leave unfinished work as dated TODOs rather
  than weakening completion criteria.

## Progress Log

- 2026-07-15: Plan created from accepted architecture and command design. Step 3
  low-severity feedback was addressed by changing the reset aggregation wording
  from “half-open” to the closed interval `[baseline.activeBoundaryAt, now]` and
  stating that records exactly at either bound are included. No implementation
  tasks have started.
- 2026-07-15: Step 4 self-review revision retained the accepted architecture and
  dependency graph, then made TASK-010 packaged-layout checks executable through
  a named SwiftPM/Formula/Cask asset smoke script and resolver tests. TASK-011 now
  requires deterministic fixture data, bounded readiness, background PID
  management, shutdown/wait, same-port restart/final release, temporary path
  injection, explicit invalid-path exit 1, PATH-fallback rejection, and proof
  that operator config/state are unchanged. TASK-012 retains explicit frontend
  typechecking, full task checks, documentation sync, and dated evidence.

Future entries must use: `YYYY-MM-DD — TASK-NNN — status — changed deliverables
— commands/results — blockers or next task`.
