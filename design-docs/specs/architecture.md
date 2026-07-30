# ccusage-gauge Architecture

## Status

Proposed for implementation through milestones M0-M5.

## Product Boundary

`ccusage-gauge` is a macOS 14 or newer menu-bar application backed by testable
Swift domain services. It periodically invokes the installed `ccusage` CLI,
shows cost since the active reset boundary, and optionally serves a dashboard
from `127.0.0.1`.

`ccusage` v20.0.17-compatible aggregate JSON remains the authoritative usage
source. Host-local Codex and Claude JSONL event readers supply timestamped
session detail for reconciliation across each materialized dashboard range, but
do not replace aggregate costs or tokens. Per-machine source-root selection follows
`design-machine-session-source-directories.md`. Static configuration and
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

Each machine owns a validated Codex/Claude source plan. Local event loading
merges selected scan roots by stable event identity. SSH collection uses the
fixed positional adapter and per-agent environment isolation defined in
`design-machine-session-source-directories.md`; configured paths can select
data roots but can never add executables, arguments, environment names, or
shell fragments.

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

### Project-directory dimension and filtering

The original source issue is the workflow-input request “Add per-machine
sub-directory filtering and bar-graph subdirectory split to ccusage-gauge
dashboard.” The follow-up issue is “Explicit sub-directory display names with
rename UI/API and cross-machine label uniqueness.” No GitHub issue URL,
repository/number pair, Codex-agent reference, reference repository, or Cursor
CLI behavior was supplied. This section therefore maps both workflow intakes
directly onto the existing ccusage-gauge architecture; no reference-code
divergence or Cursor adapter is required.

Project directory is optional provenance attached to usage, not a path the
application opens or executes. Claude assistant events obtain it from the
event's `cwd`; Codex token events inherit the most recent `cwd` from their
session metadata. Forward and reverse JSONL scans must produce the same
association. A missing, empty, or unusable value becomes `nil`; otherwise the
source string is retained as an opaque exact-match value. Collection never
resolves symlinks, expands home-directory syntax, or tests the directory on the
local or remote filesystem.

Local machines read candidate event lines from their resolved session-source
scan scopes. This feature does not add a remote JSONL transport, remote parser,
or general-purpose file-reading operation to the SSH adapter. Existing SSH
machines therefore continue to use remote `ccusage` aggregates without
host-side event reconciliation, and their rows have `directory == nil` unless a
future aggregate format supplies optional directory provenance directly.
`GET /api/subdirectories` returns an empty directory list for such a machine,
the sidebar renders no nested choices beneath it, and the machine's
unattributed rows remain visible. The per-machine filter contract still prevents
another machine's directory selection from excluding those rows. Transporting
raw or projected remote session content is a separate security- and
privacy-sensitive feature requiring its own explicit scope and adversarial
design review.

`TimestampedUsageEvent`, `CCUsageCostRecord`, `CCUsageMetricRecord`, and
`CCUsageSessionMetricRecord` carry this optional `directory` value through
snapshot construction. Reconciled timestamped sessions copy the event
directory while retaining the existing authoritative daily cost and token
allocation. Aggregate, coalescing, snapshot-merge, and cache identities include
directory, with `nil` as a distinct identity, so otherwise equal rows from two
projects cannot collapse.

For a local machine, directory-provenance coverage follows aggregate snapshot
coverage rather than the former recent-event optimization. Initial week/history
warming, an older custom-range expansion, and a targeted refresh load JSONL
events for the same host-calendar days being materialized and reconcile them
with that range's aggregate rows. Thus directory filtering works for all
dashboard ranges whose source event logs are still present; it is not silently
limited to the recent graph window. Deleted or unavailable historical event
logs cannot be reconstructed from `ccusage` aggregates, so their usage remains
unattributed and follows the documented `nil` filtering semantics.

SQLite daily/session cache tables gain nullable directory columns and
per-host-day directory-provenance coverage through an idempotent additive
migration. Pre-change cached days begin as provenance-unscanned rather than
being treated as complete. Their first directory-aware snapshot load scans the
currently available local event logs and builds one complete replacement for
that day's derived session partition. In one transaction it removes the prior
session partition, inserts the replacement rows, and marks provenance coverage
scanned, even when the replacement contains no attributed events. Authoritative
daily aggregate rows are never removed or rewritten by this backfill.

Failure or interruption rolls back both the session replacement and coverage
marker, retains the previously published snapshot, and leaves the day eligible
for retry. A retry recomputes and replaces the complete partition; it never
merges the replacement additively with legacy `nil` rows. Snapshot publication
occurs only after commit, so no reader can observe both legacy and attributed
copies. Completed historical days are reused without repeated JSONL scans; the
current host day remains eligible for the same complete-partition replacement
on refresh. Previously encoded records still decode a missing directory as
`nil`. Unfiltered totals continue to come from authoritative aggregates and
must be identical before backfill, after successful backfill, and after any
failed or retried backfill.

Raw `ccusage` daily/session rows that do not identify a project remain
unattributed. An unfiltered query that does not request a directory breakdown
continues to use the existing authoritative aggregate path. A daily query with
one or more directory filters, or with the optional directory-breakdown request
enabled, instead derives its rows by grouping the reconciled dashboard sessions
by host calendar day, machine, agent, model, and directory. This supplies
directory-resolved rows for filtering or chart splitting without inventing
directory attribution for raw aggregate rows. Reconciliation preserves the
authoritative aggregate cost and token allocation, so the directory-resolved
rows, including their `nil` group, have the same unfiltered totals as the
aggregate path. Unattributed session rows remain visible when a machine has no
active directory selection and are excluded when that machine has one or more
selected directories.

The read API adds an optional, repeatable query item
`directory=<machine-id>:<full-directory>`. The complete value is percent
encoded, and the server separates the validated machine id at the first colon.
No `directory` item means the existing unfiltered behavior. One or more items
for a selected machine form an exact-match OR set for that machine; filters for
different machines never intersect or affect one another. A well-formed filter
for a known machine outside the current `machine` selection is ignored, which
makes an unchecked machine neutral even if a stale client retains its prior
values. Malformed entries and unknown machine ids return a non-sensitive `400`
or `404` response using existing selection conventions. Directory values must
not appear in persistent logs or error messages.

`/api/metrics`, `/api/cost-series`, and `/api/budget` accept the directory
items. Their rows expose optional `directory`; filtered totals and the budget's
spent-derived values are recomputed from the filtered rows. In addition,
`/api/cost-series` accepts the optional single query item
`directoryBreakdown=true`. Omission or `false` preserves the existing response
path and grouping when there are no directory filters. `true` requests
directory-resolved rows independently of filtering, including for daily
granularity; duplicate values or values other than `true` and `false` return
`400`. A directory filter also selects the directory-resolved path regardless
of this flag. Existing clients that omit both additions receive unchanged rows,
totals, and grouping.

The additive `GET /api/subdirectories?machine=<id>` route accepts the same
machine-selection contract as the snapshot-backed dashboard data routes: omit
`machine` or pass exactly `machine=all` for all enabled machines, or repeat
`machine=<id>` for one or more distinct canonical ids. The `all` sentinel
cannot be mixed with ids, and duplicate, empty, or non-canonical values return
`400`. The route returns stable, full-string-sorted values grouped by machine.
`names` is an optional map from full directory value to explicit display name:

```json
{"machines":[{"machine":"local","directories":["/Users/example/project"],"names":{"/Users/example/project":"Billing"}}]}
```

The list is derived from the selected machines' retained, provenance-scanned
snapshot coverage, excludes `nil`, and exposes the full value only so the
loopback SPA can submit exact filters. A historical range expansion refreshes
the list after the expanded snapshot is published, so newly observed
directories become selectable. A `names` entry is returned only when its
directory is present in the same machine's `directories` array; stored names
for paths that are not currently discovered are retained but not disclosed.
The field is omitted when a machine has no applicable explicit names, so
clients that only decode `directories` remain compatible. The UI never
displays the full path by default. `DashboardCostRow`, metric response rows,
and their frontend counterparts encode `directory` only when present,
preserving decoding compatibility for pre-change snapshots, caches, saved API
fixtures, and clients.

Explicit names are dashboard-host metadata, not usage provenance and not
per-browser UI state. They are stored in the existing
`~/.cache/ccusage-gauge/dashboard-state.sqlite3` database, or the equivalent
file under `CCUSAGE_GAUGE_CACHE_HOME`, in a separate idempotently created table
keyed by canonical machine id and opaque full directory string, with the
normalized non-empty display name and update time.
The table is independent of the singleton `DashboardUIState` value, so an API
rename is visible to every browser and survives reloads and application
restarts. No name is sent to or persisted on a remote machine. Upsert and clear
operations are serialized by the store; the last successfully committed
request for a key wins. A stored name remains available if a directory
temporarily disappears and applies again if the exact machine/path key is
rediscovered.
Deleting a configured machine is different from temporary directory
disappearance: the registry transaction first persists a dashboard-name
deletion marker in a prepared phase, which immediately excludes that machine's
names from reads. After registry persistence succeeds, the transaction advances
the marker to a committed phase before publishing the runtime transition, then
immediately attempts to purge the rows while retaining the marker as a durable
barrier. Before restoring the previous registry after a failed runtime
transition, the transaction advances the marker to a rollback phase. After the
registry restoration is durable it removes that marker, so the unchanged names
become visible again. If post-commit purge fails, the committed machine deletion
remains successful, the marker continues to hide the names, and the mutation
owner records the machine id as pending metadata cleanup. It retries cleanup
with bounded same-process
backoff and on the next machine-catalog read; `GET /api/machines` exposes any
remaining ids through optional `metadataCleanupPendingMachineIds` so the SPA can
show a reconciliation warning. A rolled-back deletion removes the marker and
restores the unchanged names. Creating a machine under a previously used canonical id
atomically removes any retained rows and the marker before the registry commit,
so a replacement machine cannot inherit the deleted identity's labels. These
membership transitions apply equally to API mutations, bulk replacement, and
external registry reload.
Before either production dashboard router becomes available, startup
transactionally reconciles this metadata with the persisted registry. A
prepared marker for a machine id still present in the registry is removed so an
interrupted pre-persistence deletion cannot keep valid names hidden after
restart. A rollback marker for a machine id still present is also removed
without deleting names, covering termination or marker-cleanup failure after
the previous registry was restored. A committed marker for an id that is
already present again identifies machine-id reuse after a durable deletion:
startup purges the old names before removing the marker. Metadata for ids absent
from the registry is promoted to a committed marker and purged regardless of
its prior phase, completing cleanup that may have been interrupted after the
registry commit or before a rollback completed. A
reconciliation storage failure fails dashboard startup rather than serving
ambiguous or stale names.

Both local `HTTPService` mode and `MachineDashboardRouter` expose
`PUT /api/subdirectories/name` with this request shape:

```json
{"machine":"local","directory":"/Users/example/project","name":"Billing"}
```

`machine` must be a canonical id and must exist in the local or machine
registry scope served by that router. The local-only surface accepts only
`local`. `directory` is an opaque, non-empty string and is not resolved,
opened, normalized, or required to be present in the current snapshot. The
`name` member is required but its value may be `null`; a null, empty, or
whitespace-only value clears the row. Non-empty names are trimmed at their
edges, must contain no control characters, and are limited to 200 Unicode code
points. A successful set returns
`{"status":"ok","machine":"local","directory":"/Users/example/project","name":"Billing"}`;
a successful clear returns the same object with `name:null`.
The name-store write transaction rejects a machine id with an active deletion
marker. This closes a stale-authorization race with concurrent machine deletion;
the route returns the same sanitized `404 machine_not_found` response used when
the machine has already left the served registry.

Malformed JSON or invalid machine, directory, or name values return `400` with
`invalid_directory_name`; an unknown canonical machine returns `404` with
`machine_not_found`; persistence failure returns `503` with
`directory_name_unavailable`. Responses and persistent logs never include
database details or untrusted path/name values in error messages. Both the
local-only `HTTPService` surface and `MachineDashboardRouter` apply the same
common loopback-authority, exact same-origin/fetch-metadata, and
`X-CCUsage-Gauge-Mutation: 1` gate. That gate runs before request-body decoding,
machine or directory validation, and store access, and a rejected request makes
no observable state change. `OPTIONS` is rejected under the same control-route
policy. The SPA sends the mutation header; non-browser automation may omit
browser origin and fetch metadata but must send the header. A failed write does
not update the effective name. A name-store read failure fails the subdirectory
request with `503` instead of silently presenting derived labels as if explicit
names had been cleared.

The SPA owns selected directories as a map keyed by machine id. Only a checked
machine renders its nested directory checkboxes. Unchecking it removes that
machine's active directory set and omits its directory query items; rechecking
therefore starts unfiltered. Selecting no nested checkbox also means unfiltered
for that machine. Machine, model, and agent filters continue to compose as
logical AND dimensions.

Directory labels are deterministic presentation values allocated in one pass
across every machine in the dashboard's subdirectory catalog. The SPA fetches
that catalog for all enabled machines independently of the active machine
filter, so toggling a machine does not renumber another machine's labels.
Retained snapshots for enabled stale machines remain inventory sources even
while their usage is excluded from current totals. Machine create, edit,
enable, disable, and removal operations refresh the catalog before presenting
the resulting global allocation.
Flatten the machine/path entries and sort first by machine id and then by full
directory string. For each entry, use its explicit name as the base when
present. Otherwise remove trailing path separators, take the deepest non-empty
component (using `/` as the label for the root), then take its first 10 Unicode
code points.

Use the base label when it is globally unused; otherwise append the smallest
`-2`, `-3`, and so on that produces a label not already allocated anywhere in
the catalog. The uniqueness check covers collisions between two derived names,
two explicit names, an explicit and a derived name, and a generated suffix
colliding with another entry's base. Explicit names are not truncated; any
suffix is appended to the complete explicit name. Full directory strings
paired with machine ids remain the stable selection and series identities, so
renaming changes presentation without changing filters, data grouping, or
color identity.

Each sidebar directory row provides an inline rename action. Starting an edit
copies the current explicit name, or an empty value when only a derived name
exists. Enter or blur submits the `PUT`; Escape cancels; submitting a blank
value clears the name and restores the derived fallback. After a successful
response the SPA updates its names catalog, reruns global label allocation, and
immediately updates both the sidebar and chart legend. A failed response leaves
the last confirmed label in place, keeps the edit recoverable, and shows a
non-sensitive inline error. A transport timeout, truncated response, or lost
response is not authoritative because the idempotent `PUT` may already have
committed. For that ambiguous result, the SPA refetches the catalog and compares
the exact normalized machine/path name: a match confirms and closes the edit;
a mismatch or failed refetch retains recoverable input and reports that the
outcome is unconfirmed rather than falsely declaring failure. A subsequent
subdirectory fetch remains the source of truth and proves persistence after
reload.

The graph's stack control adds `subdirectory` beside the existing `model` and
`machine` values. It defaults to the existing non-subdirectory state, so
subdirectory splitting is disabled until explicitly selected. Old persisted
`model` and `machine` values remain valid; missing or unknown saved values fall
back to `model`. The frontend sends `directoryBreakdown=true` to
`/api/cost-series` only while `subdirectory` stacking is selected; it omits the
item for model or machine stacking. Active directory filters remain separate
query items and continue to request directory-resolved rows even while another
stack mode is selected. When subdirectory stacking is off and no directory
filter is active, bucket totals and visual series match current behavior. When
it is on, the series identity combines machine and full directory so equal
names on different machines never merge. Its displayed name is the same
globally allocated explicit-or-derived label used by the sidebar; machine-name
prefixing is no longer needed to disambiguate discovered directories.
Unattributed rows use the existing distinct, machine-aware `No directory`
presentation unless an active directory filter has excluded them.
Subdirectory series use their own deterministic color namespace keyed by
stable machine/path identity, so a rename does not change series color and does
not perturb existing model or machine color assignments.

Compatibility and behavior are locked by tests for event decoding with and
without `cwd`, Codex session-metadata inheritance in both scan directions,
historical-range provenance loading, pre-change cache provenance backfill,
cache/snapshot decoding without directory, merge-key separation, machine-local
filtering, unattributed-row inclusion and exclusion, deterministic globally
unique label collision suffixes (including cross-machine derived, explicit,
mixed, and suffix-versus-base collisions), persistent name set/clear/reopen,
rename validation and both routing surfaces, mutation-gate parity and rejection
before decoding or persistence, optional-name response decoding,
sidebar and chart label refresh without identity/color changes, lost-response
rename reconciliation, rollback-phase restart recovery, nested-filter
visibility, historical-list refresh, machine-uncheck reset, query encoding,
daily directory-breakdown requests with and without active filters,
omitted/false breakdown compatibility, persisted stack-value fallback, atomic
backfill rollback/retry, no legacy-and-attributed session duplication, and
unchanged totals before and after successful or failed backfill. Targeted
checks precede the full implementation gate:

```text
swift test --filter DirectoryFeature
cd frontend && bun test machineScope
cd frontend && bun test api
swift build
swift test
cd frontend && bun test
```

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
replace, patch, and delete, `GET /api/refresh`, `DELETE /api/cache`, and
`PUT /api/subdirectories/name` on both the local-only and machine-scoped
dashboard routing surfaces.
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
The current persisted representation is the session-source design's closed
version-3 `schemaVersion`, `localSessionSources`, and `machines` envelope.
Exact version-1 and version-2 representations are accepted only as migration
sources and are atomically rewritten to version 3 before registry publication
or poller startup. Migration failure preserves the source bytes and fails
startup. Persisted `machines` remain SSH-only; local source settings live in
the dedicated top-level object. Every version rejects unknown or duplicate
fields; there is no implicit unversioned or unknown-field compatibility.
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

Every snapshot-backed dashboard data route defaults to all enabled machines
when `machine` is omitted. A caller may instead pass exactly `machine=all` or
repeat `machine=<id>` to select one or more distinct canonical ids. The `all`
sentinel cannot be mixed with concrete ids, and duplicate, empty, or
non-canonical values return `400`. Unknown ids return `404`; disabled ids return
`409`; enabled ids without a snapshot return `503`. Health and control routes
retain their separately documented single-id-or-`all` contracts. Retained stale
snapshots remain readable only for explicitly historical intervals. Before any
interval reaching the current host day is aggregated, selection excludes
machines whose derived state is stale, error, never-collected, or disabled.
Their retained rows therefore cannot enter current series, totals, budget
values, or summary cards.

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
- Registry tests must prove exact version-1/version-2 migration sources and the
  version-3 current envelope, atomic one-way migration, migration-failure
  preservation, normalized persisted defaults, deterministic ordering, and
  fail-closed unknown/version behavior.
- Cache-clear tests must prove per-machine atomicity, cross-machine partial
  results, rollback/store/poller rules, and recovery before and after logical
  publication of an empty cache.
- Cache-path and registry validation must prevent traversal and inline secret
  persistence.
