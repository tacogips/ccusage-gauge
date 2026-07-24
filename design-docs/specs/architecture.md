# ccusage-gauge Architecture

## Status

Proposed for implementation through milestones M0-M5.

## Product Boundary

`ccusage-gauge` is a macOS 14 or newer menu-bar application backed by testable
Swift domain services. It periodically invokes the installed `ccusage` CLI,
shows cost since the active reset boundary, and optionally serves a dashboard
from `127.0.0.1`.

`ccusage` v20.0.17-compatible JSON output is the sole usage source. The product
must not read or interpret Claude usage JSONL directly. Static configuration and
mutable user state have separate ownership and storage locations.

## Target Boundaries

- `AppCore` owns configuration, state persistence, reset-window calculations,
  tolerant decoding of `ccusage --json` responses, aggregation, asynchronous
  process execution, dashboard query services, and the localhost HTTP service.
- `AppCLI` exposes help/version and headless smoke or diagnostic operations. It
  must use `AppCore` rather than reproduce domain behavior.
- The menu-bar executable owns `NSStatusItem`, AppKit menus and dialogs,
  application lifecycle, opening the browser, and main-actor presentation.
- `AppCoreTests` verifies headless behavior with injected paths, clocks,
  calendars, process runners, and fixtures.
- `frontend/` owns the bun-built SolidJS SPA and a CSS framework. Its compiled
  files are immutable resources served by the Swift HTTP service.

SwiftPM target boundaries remain the default extension points. A new module is
justified only when one of these responsibilities cannot remain independently
testable inside the listed targets. Every Swift source file stays below 1000
lines.

## Runtime Data Flow

1. Startup resolves the configuration path and creates the default file only
   when it does not exist.
2. The application loads mutable state separately, using defaults if no state
   file exists.
3. Executable resolution checks an explicit configured `ccusagePath` first; if
   it is absent, resolution searches `PATH`. A configured but invalid path is a
   validation failure and is not silently replaced by another executable.
4. A background polling service invokes `ccusage blocks --json` and/or
   `ccusage daily --json`. Process launch, pipe reads, decoding, and aggregation
   do not execute on the main actor.
5. `AppCore` converts decoded records into model-summed cost points and applies
   the active reset window. A successful snapshot is delivered to the menu-bar
   presenter and retained for dashboard queries.
6. The presenter updates status and menu content on the main actor. A failed
   poll preserves the last successful snapshot while exposing a stale/error
   state; missing `ccusage` exposes installation or path guidance without
   terminating the app.
7. When enabled, the Swift HTTP service answers API queries from the same domain
   services and serves the compiled SPA. It never becomes an independent usage
   data source.

Polling is single-flight: a timer tick does not start a second `ccusage` process
while one is active. Shutdown cancels polling and stops the HTTP listener.

## Configuration and Mutable State

### Static configuration

Path: `~/.config/ccusage-gauge/ccusage-config.json`

The application creates missing parent directories and writes sensible defaults
once. After creation, this file is read-only from the application's perspective,
including when values are invalid or unknown keys are present. This preserves
compatibility with Nix-managed configuration. Mutable menu actions never rewrite
it.

The version-one generated configuration is normative and contains these exact
defaults:

- `ccusagePath`: `null`; a non-null value must be an absolute executable path,
  while `null` means search `PATH`.
- `defaultResetTerm`: `daily`; this is the initial cycle used only when mutable
  state has no selected cycle.
- `dashboardPort`: loopback port, default `18081`.
- `dashboardAutostart`: `true`; whether to start the service during app startup.
- `pollIntervalSeconds`: `20`; polling cadence in whole seconds.
- `cacheRetentionDays`: `365`; aggregate-cache lifetime in days from creation.

Accordingly, a newly created file is equivalent to:

```json
{
  "ccusagePath": null,
  "defaultResetTerm": "daily",
  "dashboardPort": 18081,
  "dashboardAutostart": true,
  "pollIntervalSeconds": 20,
  "cacheRetentionDays": 365
}
```

Validation requires an executable `ccusage`, a port in `1...65535`, a positive
poll interval, a positive cache-retention day count, and a supported default
reset term. Decode and validation errors are reported with the config path and
do not mutate the file.

### Aggregate cache

Path: `~/.cache/ccusage-gauge/aggregates-<machineId>.sqlite3`, or the equivalent
root set by `CCUSAGE_GAUGE_CACHE_HOME`. The synthetic local source uses
`aggregates-local.sqlite3`.

The cache stores completed historical daily and session aggregates. Snapshot
loading checks expiry on every regular polling pass, using `createdAt` and
`cacheRetentionDays`. An expired or corrupt cache is removed and rebuilt once.
With a valid cache, only dates after `cachedThrough` through the current local
day are requested from `ccusage`; block, daily, and session commands execute in
parallel, and the results are merged with cached history.

The cache uses the macOS system SQLite library with separate metadata, daily
metric, and session metric tables. Decimal costs are stored as text to preserve
exact values, writes use a transaction, and the legacy JSON cache is removed
when the SQLite store initializes.

Each cache file has one owning machine. Rows loaded from it are stamped with
that machine id before aggregation, even when older encoded records omitted the
machine field. Machine ids are validated slugs before they can influence a path;
callers cannot supply arbitrary path components. Remote caches exist only on the
host and nothing is persisted on a remote machine by ccusage-gauge.

The former single-local-machine path `aggregates.sqlite3` has a locked upgrade
contract. Before opening the local cache, a sole valid regular legacy database
is checkpointed, closed, permissioned to `0600`, and atomically renamed in the
same mode-`0700` directory to `aggregates-local.sqlite3`; there is no copy
fallback. If the destination already exists it is authoritative, is never
merged or overwritten, and any legacy source is retained but ignored with a
sanitized conflict warning. An invalid or unsafe legacy path is retained and
ignored while local history is rebuilt. A permission, checkpoint, race, or
rename failure is `cache_failed`, publishes no partial destination, and retries
later. Clearing a scope containing `local` serializes with collection and
atomically stages both path namespaces plus SQLite sidecars before publishing
the empty store, preventing later resurrection of legacy data.

### Mutable state

Path: `~/.local/ccusage-gauge/state.json`

The state store owns:

- optional nonnegative `budgetUSD`;
- selected aggregation period: `hourly`, `daily`, `weekly`, `monthly`, or `customHours` with a
  positive hour count;
- period baseline metadata, as defined below, which makes the selected effective
  boundary explicit and stable across restarts.

State changes use an atomic replacement in the same directory. Timestamps are
encoded as ISO 8601 instants. Corrupt state is reported and must not be silently
overwritten; the UI may continue with safe in-memory defaults until the user
chooses a recovery action in a later design.

Both stores accept injected base URLs in tests. Production path resolution must
not be captured in static globals so CLI and tests can safely isolate files.

### Persistent startup and bootstrap log

The menu-bar process and local CLI runtimes establish an `AppCore` bootstrap
logger before loading or creating configuration, state, machine-registry,
cache, or dashboard assets. Construction is side-effect free. After command
selection, menu-bar bootstrap and only CLI commands that enter a runtime call
`activate()` before configuration parsing; help and version return without
activation and retain their no-storage behavior. Activation validates or
creates the log directory, selects any fallback, acquires the maintenance lock,
and applies retention, but does not create the active log file until the first
append. Malformed configuration JSON, registry decoding or validation failure,
executable resolution failure, cache recovery failure, listener startup
failure, and other early bootstrap failures are therefore recorded before the
existing UI or stderr error is presented.

`AppPaths` exposes `logDirectory`. Its normal production value is
`~/.local/ccusage-gauge/logs`, derived from the same state root as
`~/.local/ccusage-gauge/state.json`; `CCUSAGE_GAUGE_STATE_HOME` therefore
relocates both. If creating or appending under an explicitly overridden state
root fails, the logger makes one attempt at the default
`~/.local/ccusage-gauge/logs` location. It records only that the primary
location was unavailable, never the rejected path or underlying exception. If
both locations fail, bootstrap continues to its normal UI or stderr error path
without recursive logging.

The directory is a current-user-owned real directory with mode `0700`; active
and rotated logs are current-user-owned regular single-link files with mode
`0600`. Symlinks, hard links, non-regular files, unsafe ownership, and broader
permissions fail closed for logging and are never repaired by following or
overwriting the unsafe object.

The active file is `ccusage-gauge.jsonl`. Each line is one bounded JSON object:

```json
{"timestamp":"2026-07-16T12:00:00.000Z","severity":"error","runtime":"menuBar","phase":"configurationLoad","code":"configuration_invalid","message":"Configuration could not be loaded"}
```

`runtime` is `menuBar`, `configCheck`, `usageSnapshot`, `serve`, or `client`.
`phase` and `code` are closed application-owned identifiers. `message` is
sanitized application-owned text. Records never contain raw configuration,
stderr, environment contents, command arguments, SSH destinations or users,
identity/key values, filesystem paths, raw usage data, exception descriptions,
or request bodies. A single record is capped at 16 KiB and is encoded on one
line.

Before an append that would make the active file exceed 10 MiB, the logger
atomically renames it to
`ccusage-gauge-<UTC timestamp>-<monotonic sequence>.jsonl`, opens a new active
file, and then writes the complete record. Each successful `activate()` and
each rotation remove rotated files whose modification time is older than 72
hours. Retention never deletes the active file or unrelated directory entries.
Activation, rotation, and cleanup are serialized across tasks and processes
with an advisory lock; a lock or filesystem failure disables persistent logging
for that runtime and does not block application startup.

Clock, filesystem operations, size limit, retention duration, and destination
roots are injectable. Deterministic tests cover boundary-size rotation,
same-timestamp name collisions, retention just before/at 72 hours, unsafe file
types and permissions, fallback selection, concurrent append serialization,
and redaction of malformed JSON and SSH/process errors.

## Usage Integration and Aggregation

The process boundary accepts an executable URL, argument list, environment, and
timeout and returns stdout, stderr, and exit status. Only fixed argument arrays
are passed to `Process`; no shell command interpolation is used. A nonzero exit,
timeout, invalid JSON, or unsupported payload is a typed error suitable for UI
guidance and HTTP error mapping.

Decoders follow the ccusage 20.0.17+ `blocks --json`, `daily --json`, and
`session --json` shapes. Detailed daily loading first accepts the flag-free
ccusage 20.1+ shape, then falls back to and caches the 20.0.17
`daily --json --by-agent` shape when necessary. Agent/model breakdowns are the
source of truth for calendar-day, Monday-through-Sunday week, and calendar-month
gauge totals across supported agents, including Claude Code and Codex.
`session --json` supplies model cost and session last-activity
timestamps for hourly/custom-hour gauge totals and the dashboard's hourly graph.
They ignore unknown fields and tolerate additive schema evolution, while
requiring the time and cost fields necessary for a query. Cost is aggregated by
summing model-level cost values exactly once per record; a provided aggregate
must not be added again when model details are present. Fixtures document the
accepted schema and protect against double counting.

All internal monetary calculations use `Decimal`. JSON APIs emit numeric USD
values at a documented precision; UI rounding is presentation-only.

## Aggregation Period and Budget Rules

### Persisted reset baseline contract

The baseline is a persisted cache of the selected period boundary used to include or
exclude `ccusage` records. It is not a monetary balance, does not copy usage
cost, and must never be added to or subtracted from `ccusage` totals. Version one
stores this object in `state.json`:

- `scheduledBoundaryAt`: scheduled boundary calculated for the selected cycle;
- `activeBoundaryAt`: the scheduled boundary used for aggregation;
- `cycle`: a copy of the cycle used for the calculation, including the positive
  hour value for `customHours`;
- `calendarIdentifier` and `timeZoneIdentifier`: environment used for calendar
  boundaries;
- `computedAt`: evaluation instant, used for diagnostics and expiry checks.

All baseline timestamps are ISO 8601 instants. The baseline is valid only when
its cycle, calendar, time zone, active boundary, and scheduled boundary match
the current evaluation context. `computedAt` never changes the cost result.

Startup loads state, chooses the persisted cycle or the configured
`defaultResetTerm`, and validates the baseline. A missing or stale baseline is
recomputed before presenting cost and atomically persisted with the state.
Advancing into a new scheduled window similarly recomputes and persists it.
Corrupt state remains an error under the state-store policy and is not repaired
silently.

Changing the aggregation period recomputes all baseline fields and atomically
persists the selection and baseline. There is no manual-reset override.

Every menu-bar, CLI, and dashboard cost query uses `baseline.activeBoundaryAt`
as the lower bound after baseline validation. There is no parallel boundary
calculation at presentation or API layers. This persisted derivation ensures a
restart, cycle change, and subsequent poll all apply the same boundary contract
while `ccusage --json` remains the sole monetary source.

### Boundary calculation and aggregation

Calendar boundaries use the user's current time zone:

- `hourly`: the current local clock hour, from `HH:00:00` through `HH:59:59`;
- `daily`: the current local day, from `00:00:00` through `23:59:59`;
- `weekly`: Monday `00:00:00` through Sunday `23:59:59`;
- `monthly`: start of the current local month;
- `customHours(n)`: `n` hours before the evaluation instant.

Usage outside the selected interval is excluded. Tests use fixed clocks,
calendars, and time zones and cover exact boundaries, Monday-based weeks,
daylight-saving-relevant calendar transitions, cycle changes, and restart persistence.

Cost is the sum of records in the selected period. Calendar-day, week, and month
totals use exact daily agent/model rows; hourly and rolling custom-hour totals use
session last-activity timestamps. Baseline metadata contributes no cost. With a positive
budget, spent is the nonnegative cost, remaining is
`max(budget - spent, 0)`, and the visual fraction is capped at 100% while the raw
over-budget amount remains available. Without a budget, the UI shows an unset
state rather than inventing a denominator.

## Menu-Bar Behavior

The status item renders a dynamic pie whose filled sector is the capped budget
fraction, followed by formatted USD cost in the selected period. Its menu exposes:

- budget usage as spent versus remaining, including a pie-chart presentation;
- a budget editor persisted to the mutable state file;
- aggregation-period choices, including hourly and a positive custom-hour value;
- dashboard start, stop, and open actions;
- a Settings submenu backed by `SMAppService.mainApp` for Launch at Login;
- a warning status icon and Error Details submenu when ccusage validation or
  collection fails, including the config path and a retry action;
- current refresh or configuration errors and missing-`ccusage` guidance;
- quit.

On startup and each refresh, domain work runs away from the main actor. Only
AppKit object creation and mutation run on the main actor. Opening the dashboard
starts it first when necessary, then opens
`http://127.0.0.1:<dashboardPort>/`.

## Dashboard Service

The service listens only on IPv4 loopback `127.0.0.1`, never `0.0.0.0`, IPv6
any-address, or a network interface selected from configuration. Startup fails
clearly if the configured port cannot be bound. Stop closes the listener and
active resources deterministically; repeated start and stop actions are safe.

Version-one routes are:

- `GET /` and SPA asset paths: compiled frontend files, with SPA fallback only
  for non-API navigation paths;
- `GET /api/recent`: model-summed timestamped cost series;
- `GET /api/day?date=YYYY-MM-DD`: time-of-day breakdown for the selected local
  date and its total;
- `GET /api/period?range=today|yesterday|week|month`: total and series for a
  predefined local-calendar period;
- `GET /api/period?range=custom&start=YYYY-MM-DD&end=YYYY-MM-DD`: total and
  series for inclusive whole local days, rejecting missing, malformed, or
  reverse-ordered bounds;
- `GET /api/metrics?range=all|today|yesterday|week|month`: exact daily
  agent/model cost and token breakdowns for the selected period;
- `GET /api/metrics?range=custom&start=YYYY-MM-DD&end=YYYY-MM-DD`: the same
  detailed metrics for inclusive whole local days;
- `GET /api/cost-series?granularity=15min|hourly|daily&range=...`: filtered
  graph source rows; 15-minute and hourly views use session last-activity
  timestamps while daily uses exact daily agent/model breakdowns;
- `GET /api/budget`: budget, selected-period cost, remaining amount, aggregation period,
  active boundary, and the effective menu-bar refresh interval.

The dashboard defaults to a rolling last-12-hours hourly query. It requests only
the selected period, so Today, Yesterday, This Week, This Month, and custom
historical data are loaded lazily rather than through an all-history catalog.
It automatically refetches the selected-period metrics, cost series, and budget
at the effective menu-bar refresh interval. A changed menu-bar interval is
returned by `/api/budget` and reschedules dashboard polling without requiring a
page reload. Background refreshes retain the last completed dashboard state;
the loading screen is reserved for requests that do not yet have a completed
value, such as the initial page load. A non-blocking `Updating…` status remains
visible while a background refresh is in progress.

User-initiated range changes use a blocking transition: the previous graph is
cleared and the initial loading state remains until both selected-period metrics
and cost-series resources finish. Timer and manual refreshes continue to use the
non-blocking background state.

Graph granularity changes use the same blocking transition and complete after
the replacement cost-series resource finishes loading.

The router coalesces concurrent API snapshot reads through an actor-isolated
in-flight task and briefly reuses the completed result. A frontend refresh can
therefore request metrics, cost series, and budget concurrently while AppCore
runs only one snapshot load instead of one full `ccusage` process group per
endpoint.

The server starts snapshot prewarming as soon as its listener starts. Normal
read endpoints reuse that completed snapshot for up to 60 seconds, making range
changes a local filter operation. `GET /api/refresh` forces one coalesced fresh
snapshot; the frontend waits for it before refetching the three visible
resources, which then resolve from the refreshed cache.

Successful responses use JSON and stable field names. Bad parameters return
`400`; missing routes return `404`; `ccusage` or internal query failures return
`503` or `500` with a machine-readable error code and non-sensitive message.
No route accepts arbitrary filesystem paths or executes arbitrary commands. The
explicit state-changing HTTP control surface comprises machine-registry create,
replace, patch, and delete, `GET /api/refresh`, and `DELETE /api/cache`.
Read-through historical queries may populate their selected machine caches but
cannot change configuration or delete retained data. Budget and
aggregation-period mutations remain menu-bar actions. Every explicit control
mutation uses the common loopback authority, exact same-origin/fetch-metadata,
and `X-CCUsage-Gauge-Mutation: 1` gate defined by the remote-machine design.

Static assets are resolved in this order: an explicit development override,
SwiftPM resources in development, then resources adjacent to the packaged
executable/application bundle. Resolution is read-only and failure produces a
diagnostic response rather than exposing a directory listing. Formula and Cask
build validation must exercise their respective layouts.

## Remote Machine Collection

The dedicated behavior and security design is
`design-docs/specs/design-remote-machine-collection.md`. `serve` loads
`~/.config/ccusage-gauge/machines.json`, always adds the reserved synthetic
`local` descriptor, and creates one independently cancellable poller per enabled
machine. Local collection retains local event reconciliation. SSH collection
executes the configured remote ccusage binary through a direct endpoint or the
dedicated design's structured SSH proxy adapter and reuses the existing JSON
decoder, but does not read host event logs or install a remote daemon. An
already-open local forward is a direct endpoint.

The collection boundary is provider-neutral. Direct SSH, `ProxyJump`,
`ProxyCommand`, local forwarding, and equivalent operator-managed tunnels share
one transport, status, diagnostic, action, and API contract. GCE and IAP may
appear only as deployment examples and never select code paths, fields, routes,
classifiers, remediation, or UI labels.

Proxy behavior is isolated behind an optional closed adapter on the SSH
descriptor. `jump` accepts validated structured hop metadata; `command` accepts
only an absolute owner-safe stdio-adapter executable. The application supplies
the validated target host and port through one fixed invocation. Raw `-J`,
`ProxyJump`, `ProxyCommand`, adapter arguments, environment/configuration
values, SSH configuration files, and shell fragments are never accepted.
Direct endpoints, local forwards, jump hops, and command adapters all preserve
target host-key verification; jump hops additionally enforce their own verified
host identity. No adapter accepts inline credential contents or exposes raw
adapter output.

The registry stores connection configuration only and is atomically written
with mode `0600` inside a mode-`0700`, current-user-owned directory. Registry
CRUD is serialized with affected collector reconciliation: the owner publishes
the new immutable revision only after durable staging and runtime replacement
agree. Runtime failure rolls disk and collector state back; failed compensation
stops the affected generation and rejects later mutations until restart
recovery reconciles one complete persisted revision. Registry load is
fail-closed: only an absent file means an empty SSH registry; unsafe
ownership/type/permissions, malformed JSON, invalid descriptors, or an unsafe
persistence path fail service startup without quarantine or local-only fallback.
Recovery requires an offline correction or intentional removal of the file.
The current persisted representation is the dedicated design's closed
version-2 `schemaVersion` plus `machines` envelope. The exact existing
version-1 representation is accepted only as a migration source and is
atomically rewritten to version 2 with direct-by-omission proxy semantics before
registry publication or poller startup. Migration failure preserves the
version-1 bytes and fails startup. Both versions store SSH descriptors only and
reject unknown or duplicate fields; there is no implicit unversioned or
unknown-field compatibility.
Machine ids are immutable, unique safe slugs; `local` cannot be disabled,
replaced, or deleted. SSH host, user, port, identity path reference, extra
options, and remote executable are validated before use. Process arguments are
arrays rather than local-shell strings. Ambient SSH config is disabled, remote
tokens are POSIX-quoted, options use the closed allowlist, and values capable of
changing config, hooks, environment, forwarding, or the remote-command boundary
are rejected as specified in the dedicated design. Raw proxy options are also
rejected; only the separately validated structured proxy adapter may select jump
or command behavior.

An actor-owned snapshot store retains the latest successful snapshot and
sanitized health status independently for each machine. A failed refresh does
not erase the last successful snapshot. One mutation owner serializes candidate
validation, synchronized atomic persistence, immutable revision publication,
old-generation cancellation, and affected-poller replacement before replying.
Poll publications are revision/generation fenced; unaffected pollers continue
running.

Every existing query route accepts `machine=<id|all>`, defaulting to `all`.
Concrete ids select exactly one snapshot. Unknown ids return `404`; invalid
parameters return `400`; disabled ids return `409`; enabled ids without a
snapshot return `503`. Retained stale snapshots remain readable only for
explicitly historical intervals. Before any interval reaching the current host
day is aggregated, selection excludes machines whose derived state is stale,
error, never-collected, or disabled. Their retained rows therefore cannot enter
current series, totals, budget values, or summary cards.

The all-machines view merges only snapshots eligible for the requested interval
and returns partial `200` results when at least one machine remains. It stamps
every block/timeline, daily, and session record with non-optional source
provenance and emits `machine` on every recent/day/period series point, metric
row, and cost-series row. Aggregation keys preserve machine identity, and totals
and the single host-budget summary are recomputed from eligible rows instead of
summing precomputed values. Query scope identifies every excluded machine, its
concrete unavailable-since time and reason, and the intersection of its data gap
with the last hour. Host calendar and reset rules define aggregate boundaries,
while the oldest included generation time describes aggregate freshness.

`GET /api/machines` provides registry listing and SSH CRUD, while
`GET /api/machine-status` reports healthy, stale, disabled, never-collected, and
structured sanitized SSH proxy/tunnel failure details. `/api/cost-series`
carries each
selected machine's latest-event marker in both successful responses and
recognized data-availability error envelopes. Marker derivation is independent
of current-row eligibility, so an all-stale or concrete-stale selection still
reports marker metadata without allowing retained stale rows into totals.
Guarded per-machine test-connection and targeted refresh actions reload
validated registry configuration and make edits usable without a process
restart. Registry mutations, connection tests, manual refreshes, and cache
deletion share the dedicated design's loopback authority, same-origin,
fetch-metadata, and mutation-header policy; rejected requests change no state
and receive no CORS authorization.

Diagnostic classification is closed and ordered across host-key,
authentication, proxy/tunnel reachability, timeout, remote-command,
invalid-response, and cache failures. Only failures outside those typed
boundaries use the sanitized `internal_error` fallback; raw stderr and exception
text never cross into APIs, UI, CLI output, or persistent logs.

Cache clear is atomic for each selected machine and partial across `all`.
Complete, mixed, and zero-success results use stable `200`, `207`, and `500`
responses with per-item `cache_failed`; `all` includes disabled descriptors. A
clean rollback retains and resumes the old store, while an unrecoverable
interruption retains stale data and stops only that machine's poller. Startup
must resolve an interrupted clear to either the complete prior state or the
complete empty state before opening the cache. Concrete durability and recovery
mechanisms belong to the implementation plan.

## Frontend Contract

The SolidJS SPA is built by bun and produces static assets. A left sidebar
selects All machines or one registered machine and filters exact `ccusage`
daily breakdown rows by model and agent. The selected scope is visible, and
rows expose machine attribution in all-machines scope. A Machines screen manages
SSH descriptors, their closed direct/jump/command adapter fields, enablement,
and collection health without displaying secret contents or accepting raw
proxy commands. It provides guarded Test connection and Refresh controls and retains
each sanitized action result until the next edit or action. Stale or unavailable
machines have a persistent high-contrast state that includes last success,
failure reason, unavailable-since time, and the last-hour data gap. Summary
cards identify excluded machines and consume only server-selected eligible
rows. The top-right
aggregation control provides Today, Yesterday, This week, This month, and a
Custom choice that reveals From/To date calendar controls. The graph always
shows cost and provides Hourly and Daily aggregation controls, defaulting to
Hourly. Its sub-daily view renders each selected machine's latest-event marker
and unavailable spans from successful or recognized data-availability
responses without treating stale retained history as current usage.
The selected period and filters drive all totals, the green-bar cost series, and
daily detail;
mixed-model block costs are never used for dashboard model filtering. The SPA
reads only the same-origin JSON API, treats API failures and empty series as
first-class UI states, and does not invoke `ccusage` or access local files.

## Security and Privacy Boundaries

- The server is loopback-only. Registry create/replace/patch/delete, manual
  refresh, and cache deletion are the explicit state-changing HTTP controls and
  all use one fail-closed same-origin plus mutation-header gate.
- `ccusage` arguments are fixed and never composed through a local shell.
- SSH destinations, ports, option arguments, identity path references, and the
  remote executable are validated; no inline private key is accepted or logged.
- API errors, logs, and UI guidance exclude environment values, raw usage
  payloads, and unrelated local paths.
- Registry safety is mandatory rather than best-effort: unsafe ownership, file
  type, links, permissions, JSON, descriptors, or persistence paths fail startup.
  Other configuration and state files use user-only permissions when created.
- The user-provided HEIC image is a visual reference only and must not be
  copied into the repository, build resources, release archives, or Git.

## Rollout and Verification Constraints

Implementation proceeds in dependency order: documentation; `AppCore` contracts
and tests; menu-bar integration; web service and API; frontend and packaging;
then full verification and documentation synchronization. Narrow target builds
and tests run after each Swift milestone, followed by `swiftlint`. The final gate
includes `task frontend:build`, `task build`, `task test`, CLI smoke checks,
loopback HTTP checks, and release-scaffolding checks.

The feature must not disturb existing Homebrew formula or Cask scripts. Built
frontend assets must have an explicit packaged-resource location for both release
forms. No commit or push is implied by this design.

Remote-machine rollout additionally requires `swift build`, `swift test`,
`task test:coverage`, a clean `cd frontend && bun install && bun run build`,
and `bash scripts/smoke-remote-machines.sh`. `task test:coverage` is the single
repository-supported unit-coverage command: it runs SwiftPM with coverage,
reports executable line coverage for `Sources/AppCore` and `Sources/AppCLI`
while excluding tests, generated code, and copied web resources, and fails
below 80.0%. Phase G uses Docker Compose under
Colima only. An emulation-only collector keeps `serve` loopback-bound and
unpublished; smoke calls run through `docker compose exec`. One keygen container
creates the ephemeral SSH keypair in tmpfs and provisioning pipes it only into
the collector and SSH-machine tmpfs mounts. Compose file-backed secrets, Swarm,
host key files, host `~/.ssh` mounts, credential bind mounts or volumes, and key
material in writable layers, runtime data, environments, arguments, or logs are
forbidden. Missing Colima, Docker, Compose, host-gateway, or tmpfs prerequisites
are explicit verification limitations, never authorization for a weaker
fallback.

## Risks Requiring Implementation Evidence

- The exact v20.0.17 payload variants must be captured as sanitized fixtures
  before finalizing Codable contracts.
- Swift 6 actor isolation must be verified around `Process`, polling, AppKit, and
  listener lifecycle rather than bypassed with unchecked concurrency.
- Calendar-period boundary tests must establish behavior across local
  time-zone changes and daylight-saving transitions.
- Asset discovery must be tested from SwiftPM, Homebrew formula, and app-bundle
  layouts.
- The selected HTTP implementation must preserve loopback-only binding without
  regressing package and release portability.
- SSH argument-boundary tests must prove registry values cannot add commands or
  override the validated destination and remote executable.
- Registry/poller concurrency tests must prove cancelled generations cannot
  publish status after replacement.
- Aggregate tests must prove block/timeline, metric, session, and serialized
  response-row provenance and totals without double counting across machine
  snapshots.
- Registry tests must prove exact version-1 source and version-2 current
  envelopes, atomic one-way migration, migration-failure preservation,
  normalized persisted defaults, deterministic ordering, and fail-closed
  unknown/version behavior.
- Cache-clear tests must prove per-machine atomicity, cross-machine partial
  results, rollback/store/poller rules, and recovery before and after logical
  publication of an empty cache.
- Cache-path and registry validation must prevent traversal and inline secret
  persistence.
