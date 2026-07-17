# Design: Remote Machine ccusage Collection

## Goal

Periodically collect ccusage cost/usage data from multiple private GCP machines
(reachable only via port-forward / IAP tunnel, no remote->host push), store it on
the host per-machine, and let the dashboard show per-machine data, a cross-machine
aggregate, and a machine filter. Verified locally by emulating machines with
docker compose under colima.

## Current architecture (baseline)

- `CCUsageClient` (`Sources/AppCore/CCUsage.swift`) shells out to a local
  `ccusage` binary via `CCUsageProcessRunner` (runs `Process`, `blocks/daily/
  session --json`).
- `SnapshotService` (`Sources/AppCore/Snapshot.swift`) orchestrates loading,
  reconciliation, and a per-user `UsageAggregationCache` (SQLite), producing a
  single `CostSnapshot` for "this machine".
- `DashboardRouter` (`Sources/AppCore/HTTPService.swift`) serves `/api/*` from a
  `DashboardSnapshotCache` wrapping one snapshot provider, plus static assets.
- Frontend (`frontend/`, SolidJS + Vite) renders one machine's data with model /
  agent filters.

There is no machine dimension anywhere today; everything is implicitly local.

## Target architecture

```
ccusage-gauge serve
  MachineRegistry (host config: machines.json)
    ├─ "local"      -> LocalCCUsageTransport  -> SnapshotService -> cache: aggregates-local.sqlite3
    ├─ "gcp-web-1"  -> SSHCCUsageTransport(host:port) -> SnapshotService -> aggregates-gcp-web-1.sqlite3
    └─ "gcp-web-2"  -> SSHCCUsageTransport(host:port) -> SnapshotService -> aggregates-gcp-web-2.sqlite3
  MachineCollector: per-machine PollingService, each refreshes on interval
  MachineSnapshotStore: latest CostSnapshot per machine (+ collection status)
  DashboardRouter: reads ?machine=<id|all>, serves per-machine or merged snapshot
```

The machine id is the provenance key across registry entries, cache files,
snapshots, API rows, collection status, and frontend selection. It is never
inferred from a display name or SSH hostname.

### 1. Transport abstraction

Introduce `CCUsageCommandRunner` protocol that executes a ccusage subcommand and
returns stdout/stderr. Two implementations:

- `LocalCCUsageCommandRunner`: today's `CCUsageProcessRunner` behavior (runs the
  local `ccusage` binary).
- `SSHCCUsageCommandRunner`: runs `ssh` with the configured options and a remote
  command `ccusage <args>`; the tunnel/port-forward is assumed already open (the
  host connects to `127.0.0.1:<localPort>` or a configured host:port). For GCP,
  the port-forward is provided out-of-band (gcloud IAP tunnel or `ssh -L`); the
  registry stores the ssh target + options.

`CCUsageClient` is generalized to accept a `CCUsageCommandRunner` so all existing
decode logic (`blocks`, `daily`, `detailedDaily` fallback, `session`) is reused
unchanged over SSH.

#### Typed command failures and health sanitization

`CCUsageCommandRunner` returns successful stdout/stderr only for exit status
zero. On failure it throws an internal `CCUsageCommandFailure` that retains the
runner kind (`local` or `ssh`), failure phase, termination reason, exit status
when present, and bounded stderr for host-side diagnostics. The failure phase is
exactly one of `spawnFailed`, `timedOut`, `signalled`, `transportExited`, or
`commandExited`. `CCUsageClient` may wrap this value in `CCUsageError`, but must
preserve it as an associated typed value; it must not collapse runner failures
into an unqualified `nonzeroExit`. These details are never encoded into
dashboard DTOs or persisted as collection-health messages.

The runners classify process outcomes before `CCUsageClient` decodes stdout:

- a `Process.run()` or launch failure is `spawnFailed`;
- expiry of the configured deadline is `timedOut` regardless of the eventual
  status after runner termination;
- local-process termination with `terminationReason == .uncaughtSignal` is
  `signalled`;
- an SSH process that exits normally with status `255` is `transportExited`;
- an SSH process that exits normally with status `1...254` is `commandExited`
  and represents the remote ccusage command result. A remote command that itself
  chooses `255` is deliberately treated as transport failure because OpenSSH
  reserves that observable status and exposes no portable disambiguation;
- a local runner that exits normally with any nonzero status is
  `commandExited`; and
- status zero proceeds to the existing JSON decoder. Empty, malformed, or
  schema-incompatible stdout is a response failure, not a command failure.
  Stderr content never determines classification.

`MachineCollector` converts the first failing collection stage to the closed
sanitized health error below. Cancellation caused by disable, delete, shutdown,
or poller-generation replacement publishes no failure. The mapping is exact
and ordered:

| Internal failure | `lastError.code` | `lastError.message` |
| --- | --- | --- |
| `spawnFailed`, `timedOut`, `signalled`, or `transportExited` | `transport_failed` | `Command transport failed` |
| `commandExited` | `remote_command_failed` | `ccusage command failed` |
| JSON decoding, required-shape validation, or incompatible ccusage response | `invalid_response` | `ccusage response was invalid` |
| machine-owned cache open, migration, read, write, or transaction failure | `cache_failed` | `Usage cache operation failed` |
| any other non-cancellation collection invariant or orchestration failure | `internal_error` | `Collection failed` |

The same mapping applies to local and SSH machines. Internally retained exit
status and bounded stderr may support local logging, but logs redact command
arguments, host/user/identity values, and filesystem paths and never change the
public code or message.

#### SSH command boundary and allowlist

An argument array protects only the local process launch. OpenSSH serializes the
remote command for a remote POSIX shell, so the runner also owns an explicit
remote-token serialization boundary. It constructs arguments in exactly this
order:

```text
/usr/bin/ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes
  [-i <identityFile>] -p <port> [validated-extra-options] -- <user>@<host>
  '<remoteCcusagePath>' '<ccusage-arg-1>' ... '<ccusage-arg-n>'
```

Each remote command token is encoded with POSIX single-quote escaping before it
is handed to `ssh`; no token is interpolated into an unquoted command string.
The ccusage argument list comes only from the client's fixed subcommands and
flags, not from registry values or HTTP input. The fixed `-F /dev/null` prevents
ambient user SSH configuration from introducing proxy, command-hook,
environment, or remote-command behavior. The destination and all options appear
before the remote command, and `--` terminates local SSH option parsing.

`remoteCcusagePath` defaults to the bare name `ccusage`. A configured value must
be either one bare executable name or an absolute POSIX path. A bare name and
each absolute-path component must match `[A-Za-z0-9][A-Za-z0-9._+-]*`; empty,
`.` and `..` components, repeated separators, a trailing separator, leading
`-`, whitespace, control characters, backslashes, quotes, `$`, backticks, shell
metacharacters, and shell expansions are rejected. The value names one
executable only; it cannot contain arguments or an environment assignment.

`extraOptions` is a sequence of complete logical options, not arbitrary SSH
tokens. Only these forms are accepted and emitted in the order stored after the
fixed options above:

- `-4` or `-6` (at most one of the pair);
- `-o ConnectTimeout=<1...600>`;
- `-o ConnectionAttempts=<1...10>`;
- `-o ServerAliveInterval=<0...3600>`;
- `-o ServerAliveCountMax=<0...100>`;
- `-o LogLevel=ERROR|QUIET|FATAL`;
- `-o StrictHostKeyChecking=yes|accept-new`;
- `-o UserKnownHostsFile=<absolute-local-path>`.

The registry JSON represents every `-o` entry as one string exactly as shown;
the runner expands it to the two local argv elements `-o` and `name=value`.
Duplicates, case variants, abbreviations, whitespace variants, combined short
options, and every unlisted form are rejected. In particular, configuration
overrides (`-F`, `CanonicalizeHostname`, `Include`), proxy/jump behavior (`-J`,
`ProxyCommand`, `ProxyJump`), command hooks (`LocalCommand`,
`PermitLocalCommand`), environment forwarding (`SendEnv`, `SetEnv`), remote
command overrides (`RemoteCommand`, `RequestTTY`, `-t`), multiplexing/control
commands, forwarding/listening options, destination/user/port/identity overrides
(`Host`, `Hostname`, `User`, `Port`, `IdentityFile`, `-l`, `-p`, `-i`), and any
positional token are rejected.

`user` matches `[A-Za-z_][A-Za-z0-9._-]*`. `host` is a validated IPv4 address,
bracket-free IPv6 literal, `localhost`, or DNS name whose labels contain only
letters, digits, and interior hyphens; it cannot begin with `-`. When forming the
destination, the runner brackets an IPv6 literal as `user@[literal]` and uses
`user@host` for all other host forms. Identity and known-hosts paths are
absolute, normalized local paths without control characters; the identity must
resolve to a user-readable regular file and must not be group- or
world-accessible. Validation occurs on registry load, before persistence, and
immediately before launch so a changed file cannot bypass it.

Remote data source: on the real GCP box, `ccusage` reads that box's own
`~/.claude` / `~/.codex` logs. The timestamped-event reconciliation
(`ClaudeUsageEventLoader` / `CodexUsageEventLoader`) reads local files and cannot
run remotely, so remote machines use ccusage's own `session`/`daily` output
without host-side event reconciliation (dataQuality stays as ccusage reports).

### 2. Machine registry

`MachineDescriptor`:
- `id: String` (stable slug, primary key; used for cache filename + API filter)
- `displayName: String`
- `kind: local | ssh`
- `ssh: SSHConnection?` (`host`, `port`, `user`, `identityFile?`, `extraOptions[]`,
  `remoteCcusagePath?`) - only connection info, never secret material inline.
- `enabled: Bool`

Persisted at `~/.config/ccusage-gauge/machines.json` (0600). A synthetic `local`
machine is always present (kind = local) so the existing behavior is preserved
even with an empty registry.

#### Persisted registry schema

`machines.json` is a closed, versioned JSON document. Version 1 has exactly this
top-level representation:

```json
{
  "schemaVersion": 1,
  "machines": [
    {
      "id": "gcp-web-1",
      "displayName": "GCP web 1",
      "kind": "ssh",
      "enabled": true,
      "ssh": {
        "host": "127.0.0.1",
        "port": 2222,
        "user": "ccusage",
        "identityFile": "/run/secrets/id_ed25519",
        "extraOptions": [],
        "remoteCcusagePath": "ccusage"
      }
    }
  ]
}
```

Both top-level keys are required; `schemaVersion` must be the JSON integer `1`
and `machines` must be an array. Only SSH descriptors are persisted: every
array item requires exactly `id`, `displayName`, `kind: "ssh"`, `enabled`, and
`ssh`; persisting `local` or a `kind: "local"` item is invalid. Each `ssh`
object requires exactly `host`, `port`, `user`, `extraOptions`, and
`remoteCcusagePath`, with optional `identityFile`. `identityFile` is omitted
rather than encoded as `null`. All objects reject duplicate and unknown keys;
all arrays preserve their input order during validation, although a successful
write sorts descriptors by id for deterministic diffs. JSON numbers are not
accepted for Boolean or string fields, and `port` and `schemaVersion` reject
fractional or exponent spellings.

API request conveniences do not make persisted fields optional. An omitted API
`extraOptions` is normalized to `[]`, an omitted API `remoteCcusagePath` is
normalized to `"ccusage"`, and an omitted `identityFile` remains absent before
the complete version-1 document is written. The loader applies no other
defaults. In particular, a present unversioned document, missing key, `null`,
scalar top level, schema version below or above 1, or unknown field fails closed
as `registry_load_failed`; it is never interpreted as an empty registry and is
never rewritten automatically. Version 1 is the only accepted version for this
rollout. Any future representation change must introduce a new version plus an
explicit, tested, atomic migration; additive unknown-field compatibility is
deliberately not provided. The absent-file behavior remains the sole way to
start with an empty persisted SSH set.

Registry validation is performed before persistence and again when loading:

- ids are unique and satisfy the normative machine-id contract below;
- `local` is reserved for the synthetic descriptor and `all` is reserved for
  API selection; neither can be created. `local` cannot be replaced, disabled,
  or deleted through the API;
- display names satisfy the normative display-name contract below;
- SSH descriptors require host and user values matching the transport grammar,
  a port in `1...65535`, and a remote executable matching the grammar above;
  `identityFile` is an absolute path reference, never key content;
- SSH arguments follow the canonical order, remote-token quoting, fixed config
  isolation, and closed option allowlist above. Every option not explicitly
  allowed is rejected rather than passed through;
- registry writes use atomic replacement and restore user-only mode `0600`.

The machine id is immutable after creation because changing it would silently
orphan provenance and cache state. Renaming the display label remains allowed.

#### Registry startup, permission, and recovery contract

Registry loading is fail-closed. The app-specific directory
`~/.config/ccusage-gauge` must be a real directory owned by the current user,
must not be a symlink, and must have mode `0700`. An existing `machines.json`
must be a regular, single-link, current-user-owned file reached without
following a final symlink and must have mode `0600`. The loader reads at most
64 KiB, decodes the complete JSON document, rejects unknown or duplicate entries,
and applies every descriptor and SSH validation rule above before synthesizing
`local` or starting any listener, cache migration, collector, or poller.

A genuinely absent `machines.json` is the only empty-registry case. Startup may
then synthesize `local` only after creating or validating the app directory and
proving that a mode-`0600` temporary file can be created, synchronized, and
removed there. A present but unreadable, malformed, schema-invalid,
descriptor-invalid, wrong-owner, wrong-type, multiply linked, or
over-permissive registry causes `serve` and the menu-bar dashboard service to
fail startup with sanitized `registry_load_failed` or
`registry_permissions_invalid`. Failure to create, inspect, synchronize, or
atomically replace within the persistence directory is
`registry_persistence_failed`. There is no entry quarantine, automatic chmod,
automatic rewrite, backup promotion, or fallback to a synthetic-local-only
runtime when a registry file is present but invalid.

Recovery is explicit and offline: stop every process using the registry, then
correct the file's contents/ownership/mode or move/remove the invalid file and
restart. Removing it intentionally selects the empty-registry behavior and
does not delete any per-machine cache. Startup errors identify the registry
boundary and configured path but never include registry contents, identity
material, raw OS error text, or connection values. The service does not expose
HTTP repair while registry validity is unknown.

#### Machine id and display-name validation

Machine ids are canonical, case-sensitive ASCII strings. An id is 1...63 bytes,
must match `[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?`, and must not equal the
reserved values `local` or `all` for a persisted SSH descriptor. This grammar
permits a one-character id, forbids uppercase, underscores, leading/trailing
hyphens, consecutive path syntax, percent signs, separators, whitespace, dots,
and traversal components, and makes the id safe to append to
`aggregates-<machineId>.sqlite3` without further filename escaping. The
synthetic descriptor is the sole allowed owner of `local`. Ids are never
trimmed, case-folded, Unicode-normalized, or otherwise rewritten: a submitted
id either already matches this grammar or is rejected.

An item route is split into raw path segments before decoding. Its id segment
must contain valid percent triplets, decode exactly once as UTF-8, contain no
decoded `/`, `\\`, NUL, or invalid UTF-8, and then satisfy the id grammar. The
canonical re-encoding is the decoded id itself because every allowed byte is an
unreserved URL byte. Therefore percent-encoded spellings such as `%67cp-web-1`,
double encodings such as `%252f`, encoded separators, and mixed-case aliases are
rejected with `400 invalid_machine_id`; they never alias an existing id. The
`machine` query value is form-decoded exactly once as UTF-8, must be the literal
sentinel `all` or a canonical id (including synthetic `local`), and follows the
same rejection rules. A decoded `+` or space is invalid under the id grammar.

For `displayName`, the server trims leading and trailing Unicode whitespace and
normalizes the result to NFC before validation and persistence. The normalized
value must contain 1...80 Unicode scalar values, occupy at most 256 UTF-8 bytes,
and contain none of U+0000...U+001F, U+007F...U+009F, U+2028, or U+2029.
Internal ordinary spaces and non-ASCII printable characters are allowed.
Responses always return the normalized stored value. A name that becomes empty,
exceeds either limit, or contains a forbidden scalar is rejected.

Validation failures use these stable field paths and messages. Multiple
independent failures are returned together:

- absent required body fields map to their JSON path with `"is required"`;
- body `id` grammar or reserved-value failures map to `id` with
  `"must be 1...63 lowercase ASCII letters, digits, or interior hyphens"` or
  `"is reserved"` respectively;
- malformed/non-canonical item-route or query ids map to `id` or `machine` with
  `"must use a canonical machine id"`;
- display-name failures map to `displayName` with `"must contain 1...80 permitted
  Unicode scalars and at most 256 UTF-8 bytes"`;
- descriptor-shape failures map to `kind`, `enabled`, or `ssh`; SSH leaf
  failures map to `ssh.host`, `ssh.port`, `ssh.user`, `ssh.identityFile`,
  `ssh.extraOptions`, or `ssh.remoteCcusagePath`.

Non-conflict body descriptor validation returns `422 invalid_machine`. A
malformed or non-canonical route/query identifier returns
`400 invalid_machine_id`. A syntactically valid id that duplicates an entry, is
reserved, or attempts a forbidden local/id mutation returns
`409 machine_conflict` and may carry the `id: "is reserved"` field error; a
valid unknown id remains `404 machine_not_found`.

#### Registry HTTP contract

Registry routes are exact: `/api/machines` addresses the collection and
`/api/machines/{id}` addresses one percent-decoded id. Query-string targeting,
an id in an update body, trailing path components, and unknown JSON fields are
rejected. Responses use `application/json`; mutation requests require
`Content-Type: application/json`, use UTF-8 JSON, and are capped at 64 KiB.

- `GET /api/machines` returns `200` and `{"machines": [MachineResponse...]}` with
  synthetic `local` first and SSH machines in id order. `GET
  /api/machines/{id}` returns one
  `MachineResponse` or `404`.
- `POST /api/machines` creates an SSH machine. The body is a complete
  `MachineCreateRequest`; success returns `201`, the created
  `MachineResponse`, and `Location: /api/machines/{id}`. A duplicate id or the
  reserved id `local` returns `409`.
- `PUT /api/machines/{id}` replaces every mutable field of an SSH machine. The
  body is a complete `MachineReplaceRequest`; success returns `200` and the
  normalized `MachineResponse`. The path id remains immutable.
- `PATCH /api/machines/{id}` changes any non-empty subset of `displayName`,
  `enabled`, and `ssh`. When present, `ssh` is a complete replacement
  `SSHConnectionRequest`, not a recursive merge. Success returns `200` and the
  normalized `MachineResponse`.
- `DELETE /api/machines/{id}` atomically removes the descriptor, stops its
  poller, removes its in-memory snapshot/status, retains its host cache for
  possible recovery, and returns `204` with no body. Deleting `local` returns
  `409`; deleting an unknown id returns `404`.

The shared frontend/router JSON shapes are:

```json
{
  "id": "gcp-web-1",
  "displayName": "GCP web 1",
  "kind": "ssh",
  "enabled": true,
  "ssh": {
    "host": "127.0.0.1",
    "port": 2222,
    "user": "ccusage",
    "identityFile": "/Users/example/.ssh/ccusage-gcp",
    "extraOptions": ["-o ConnectTimeout=10"],
    "remoteCcusagePath": "/usr/local/bin/ccusage"
  }
}
```

`MachineCreateRequest` has exactly the fields shown above and requires
`id`, `displayName`, `kind: "ssh"`, `enabled`, and `ssh`.
`MachineReplaceRequest` omits `id` but otherwise has the same required fields.
`SSHConnectionRequest` requires `host`, `port`, and `user`; `identityFile` and
`remoteCcusagePath` may be omitted, and `extraOptions` may be omitted and
defaults to `[]`. In responses, `extraOptions` is always present and
`remoteCcusagePath` is the effective value (default `ccusage`); absent
`identityFile` is omitted. The local response is always
`{"id":"local","displayName":"Local","kind":"local","enabled":true}`
and omits `ssh`.

All CRUD errors use one stable envelope:

```json
{
  "error": {
    "code": "invalid_machine",
    "message": "Machine validation failed",
    "fieldErrors": {"ssh.port": "must be in 1...65535"}
  }
}
```

Malformed JSON, an empty PATCH, an id-bearing update body, and unknown fields
return `400`; unsupported media type returns `415`; descriptor/SSH validation
returns `422 invalid_machine` with field paths; missing ids return
`404 machine_not_found`; duplicate/reserved/local/immutable conflicts return
`409 machine_conflict`; unsupported methods return `405` with `Allow`; and an
atomic persistence failure returns sanitized `500 registry_persistence_failed`.
No error includes identity contents, raw command arguments, stderr, or an
unredacted filesystem failure. A successful mutation is not published until
the atomic registry save succeeds; its response reflects the persisted value.

#### Serialized registry mutation ownership

One process-wide registry mutation owner serializes every POST, PUT, PATCH, and
DELETE from request validation through runtime reconciliation. Each queued
mutation observes the latest committed registry revision and, without allowing
another mutation to interleave, performs this exact transaction:

1. construct the complete candidate registry from that revision and validate
   request fields, cross-entry uniqueness, persistence safety, and the complete
   resulting descriptors;
2. write a same-directory temporary file, enforce mode `0600`, synchronize the
   file, and atomically replace `machines.json` as the persistence commit point;
3. publish the new immutable registry revision to readers;
4. increment the affected machine's poller generation, cancel and await the old
   generation, reconcile snapshot/status retention or removal, and register the
   enabled replacement generation; and
5. return the HTTP response only after the runtime observes that revision.

Validation or any failure before the atomic replacement leaves the prior file,
published revision, snapshot/status state, and pollers unchanged. Runner construction is fully
validated before persistence; registering a new poller generation is a
non-throwing runtime operation, while any later command or cache failure is
ordinary collection health. Every collection publication carries both registry
revision and poller generation and is discarded unless both still match, so a
cancelled task cannot republish after an update or deletion. Reads may use a
published immutable revision concurrently, but no second registry mutation or
poller replacement bypasses this owner. Cache-clear reconciliation coordinates
with the same owner and its currently published revision before changing a
machine's store or poller.

The dashboard registration screen uses only these contracts: create targets the
collection, edit/toggle/delete target the item route, and an enable toggle sends
`PATCH /api/machines/{id}` with `{"enabled": <bool>}`.

### 3. Per-machine cache (host only)

`UsageAggregationCache` already keys off a `fileURL`. Cache path becomes
`~/.cache/ccusage-gauge/aggregates-<machineId>.sqlite3`. One `SnapshotService`
per machine, each with its own cache. Remotes never receive a cache; only the
host writes these files. Cache clear removes per-machine files.

#### Legacy local-cache upgrade contract

The pre-feature local cache is `aggregates.sqlite3`; its replacement is
`aggregates-local.sqlite3` in the same resolved cache directory. Before any
local cache connection or local poller starts, the process serializes upgrade
and clear operations through the cache owner and applies this one-time rule:

- If only the legacy file exists, open it without mutation to validate the
  SQLite header/schema, checkpoint and close any recoverable WAL state, set the
  cache directory to mode `0700` and the file to `0600`, recheck that the
  destination is absent, then atomically rename it to
  `aggregates-local.sqlite3`. Because both names are in one directory, there is
  no copy or cross-filesystem fallback. A crash exposes either the complete
  source name or the complete destination name, never a partially copied cache.
  Associated `-wal` and `-shm` files must not remain active after the checkpoint.
- If `aggregates-local.sqlite3` already exists, it is authoritative. The two
  databases are never merged and the destination is never overwritten. When
  both names exist, the legacy file is retained unchanged as a recoverable
  conflict artifact, ignored by all reads, and a sanitized warning is recorded;
  startup continues from the destination.
- A missing legacy file means a normal clean creation of the destination. A
  legacy path that is a symlink, not a regular file, invalid SQLite, or has an
  unsupported schema is not renamed or deleted. It is ignored as unusable and
  the destination is rebuilt from ccusage. Permission, checkpoint, destination
  race, or rename failures are `cache_failed`: leave the source name in place,
  do not create or publish a partial destination, retain the last in-memory
  snapshot if one exists, and retry on the next collection/startup. No failure
  falls back to reading the legacy path in place.
- Newly created cache files and any successfully migrated destination are mode
  `0600`; the cache directory is mode `0700`. Failure to enforce these modes is
  a cache failure, not a reason to continue with broader permissions.

`DELETE /api/cache` includes the legacy `aggregates.sqlite3` and its SQLite
sidecars whenever the selected scope contains `local`, in addition to the
selected per-machine files. Clear is atomic per machine and deliberately
partial across machines. The coordinator resolves and freezes the selected
registry revision, visits machine ids in lexical order (`local` first), and for
each machine exclusively pauses and awaits its poller and cache readers/writers.
For that machine, success means the old cache is no longer observable, an empty
snapshot/store state is published, and its poller resumes. Old data from a
successful clear must not reappear after restart. Cleanup may finish after the
response, but cleanup failure does not reverse a successful logical clear.

A failure before a machine is logically cleared restores or retains its prior
cache, snapshot, and status before its poller resumes. It does not roll back
machines already cleared by an `all` request. If the service cannot safely
restore the prior state or publish the empty state, that machine's poller
remains stopped, its prior in-memory snapshot is retained as stale, and status
records sanitized `cache_failed`. Startup and every later clear must recover an
interrupted operation to exactly one safe outcome--the prior cache or the empty
cache--before opening that machine's cache. Ambiguous recovery fails closed as
`cache_failed` and requires offline repair. The concrete staging, durability,
and recovery mechanism is an implementation-plan concern, not a design
contract.

### 4. Machine-aware snapshot and API

- Source records (`CCUsageCostRecord`, `CCUsageMetricRecord`, and
  `CCUsageSessionMetricRecord`) have a non-optional `machine: String`.
  Initializers default it to `"local"` and custom decoders map an absent legacy
  JSON key to `"local"`; an empty value is rejected during decoding, and
  publication validates explicit provenance against the registry. Encoding
  always emits the key, including `"local"`. SQLite rows do not add a machine
  column because each file is machine-owned; every block, daily-metric, and
  session cache read overwrites decoded/default provenance with the owning
  machine id before publication.
- Every response element that represents usage or cost also has a non-optional
  `machine` field. This includes `RecentPoint` elements returned in `series` by
  `/api/recent`, `/api/day`, and `/api/period`; `CCUsageMetricRecord` elements
  returned in `rows` by `/api/metrics`; and `DashboardCostRow` elements returned
  in `rows` by `/api/cost-series`, whether derived from session or daily input.
  `DashboardCostRow.machine` is copied from its source record before bucketing;
  aggregation keys include machine so equal timestamp/agent/model values from
  different machines never collapse into an unattributed row. Non-row responses
  such as `/api/budget` use `scope` rather than inventing a row machine.
- `MachineSnapshotStore` (actor) holds a snapshot entry per machine containing
  the latest snapshot, inclusive coverage start, transient load status, and
  `MachineCollectionStatus` (attempt/success/error timestamps, sanitized error,
  active-collection flag, and refresh interval) used by the exact health DTO.
- `DashboardRouter` accepts `?machine=<id>` (single machine) or `machine=all`
  (default, merged). Merge = concatenate machine snapshots with each row stamped
  with its machine id, recompute totals. All existing endpoints (`/api/metrics`,
  `/api/cost-series`, `/api/period`, `/api/budget`, `/api/recent`, `/api/day`)
  gain machine awareness.
- New `/api/machines` (registry CRUD) and `/api/machine-status` (collection
  health per machine, for the dashboard).

Every enabled descriptor has at most one poller generation. A successful poll
atomically replaces that machine's snapshot and health state. A failed poll
retains the last successful snapshot, records a sanitized error, and marks the
data stale. Persisted registry mutation happens before collector reconfiguration;
the old generation is cancelled before the replacement is installed so an
outgoing task cannot overwrite the replacement's status.

`machine=all` merges the latest snapshots for enabled machines only. Merge
stamps every block/timeline, daily, and session source record with its source
id, concatenates records without discarding provenance, and recomputes every
route row and total from those records; it never adds already-computed snapshot
totals. A concrete machine response still emits that concrete id on every row.
Unknown ids return `404`; malformed or repeated conflicting machine parameters
return `400`.

Every successful query response includes a `scope` object without removing its
existing fields:

```json
{
  "requested": "all",
  "includedMachineIds": ["local", "gcp-web-1"],
  "staleMachineIds": ["gcp-web-1"],
  "unavailableMachineIds": ["gcp-web-2"],
  "generatedAt": "<oldest included snapshot timestamp>"
}
```

For a known enabled machine with no successful snapshot, query routes return
`503` with `error: "snapshot_unavailable"`, its machine id, the exact
`collectionState` derived by the machine-status state machine, and
`refreshIntervalSeconds`; the response also carries a `Retry-After` header with
that interval. Therefore the state is `neverCollected` before any failed
attempt and `error` when an uncleared latest collection error exists. A known
disabled machine returns `409` with `error: "machine_disabled"` and
`collectionState: "disabled"`; an unknown id remains `404`. A stale machine
with a retained successful snapshot returns `200`, includes the snapshot, and
lists the id in `scope.staleMachineIds`.

The error bodies are stable JSON contracts:

```json
{
  "error": "snapshot_unavailable",
  "machine": "gcp-web-2",
  "collectionState": "error",
  "refreshIntervalSeconds": 20,
  "scope": {
    "requested": "gcp-web-2",
    "includedMachineIds": [],
    "staleMachineIds": [],
    "unavailableMachineIds": ["gcp-web-2"],
    "generatedAt": null
  }
}
```

The example represents a failed first collection; before any failure its
`collectionState` would be `neverCollected`. The `409` body uses the same shape
with `error: "machine_disabled"`, the applicable `machine`, and
`collectionState: "disabled"`, but no `Retry-After`. The `404` body uses
`error: "machine_not_found"` and `machine` but omits `collectionState` because
no machine status exists. Malformed input uses `400` with
`error: "invalid_machine"` and omits both machine and collection state.

For `machine=all`, disabled machines are excluded. Enabled stale snapshots are
included, while enabled machines without snapshots are omitted and listed in
`scope.unavailableMachineIds`, whether their state is `neverCollected` or
`error`. If at least one usable snapshot exists, the API returns `200` even when
the result is partial. If none exists, it returns `503` with
`error: "snapshot_unavailable"`, the same scope arrays, and
`refreshIntervalSeconds`. An all-machine response omits singular `machine` and
`collectionState` fields because unavailable machines may have different
states; `/api/machine-status?machine=all` is the authoritative per-machine
detail. Query serialization calls the same state-derivation function as that
route, so a concrete machine cannot report a different state in the two
contracts at the same store revision.

All snapshot selection and query-range calculations use the host calendar and
timezone; remote calendars do not define aggregation boundaries. An all-machine
snapshot uses the current host reset cycle and recalculates
`activeBoundaryAt` at merge time. `generatedAt` is the minimum timestamp among
included snapshots, deliberately expressing the oldest component's freshness.
`refreshIntervalSeconds` is the minimum positive interval among enabled
machines, or the configured host interval if no snapshot exists. `budgetUSD` is
the one host-configured dashboard budget and is never summed per machine;
`spentUSD` is recomputed from all included rows within the host reset interval,
then remaining, overage, percentage, and visual fraction are derived from that
single budget. A concrete machine applies the same host budget and reset
boundary to that machine's rows only.

The explicit state-changing HTTP control surface is exactly:

- `GET /api/refresh?machine=<id|all>`;
- `DELETE /api/cache?machine=<id|all>`; and
- `POST /api/machines`, plus `PUT`, `PATCH`, and `DELETE` on
  `/api/machines/{id}`.

Historical query expansion can populate a machine-owned cache as an idempotent
read-through computation, but it cannot change registry configuration, enabled
state, selection, or delete retained data and is not a control mutation.
Budget and aggregation-period changes remain menu-bar actions.

Every explicit control mutation uses the same loopback/same-origin gate before
body decoding, selection, collection, persistence, or deletion. The request
authority must be the configured loopback listener (`127.0.0.1` or `localhost`
with its actual port). A browser `Origin` must normalize to that exact served
origin; `Origin: null`, a non-loopback/mismatched scheme, host, or port, and
`Sec-Fetch-Site: cross-site` or `same-site` are rejected. When browser fetch
metadata is present without `Origin`, only `Sec-Fetch-Site: same-origin` is
accepted. All control mutations also require
`X-CCUsage-Gauge-Mutation: 1`; this protects the retained GET refresh contract
from cross-site image, form, or navigation requests. Same-origin frontend calls
set the header. Non-browser clients such as the CLI and smoke script may omit
`Origin` and fetch metadata but must set the mutation header.

A gate rejection returns `403` with
`{"error":{"code":"origin_rejected","message":"State-changing request rejected"}}`
and makes no observable state change. A missing or wrong mutation header uses
the same response so it does not disclose policy detail. Control responses do
not emit `Access-Control-Allow-Origin`; `OPTIONS` on a control path returns the
same `403`, so CORS preflight never grants these methods or headers.
`GET /api/machines` and `GET /api/machine-status`, load status,
and ordinary query routes remain read contracts. CRUD cannot mutate synthetic
`local`, validates the complete result before atomic save, and restarts only the
affected SSH poller. Status listing exposes no command lines, environment
values, raw stderr, or identity contents.

#### Historical coverage, refresh, and load status

The snapshot store keeps a per-machine entry, not only an unqualified latest
value: `{latestSnapshot, coverageStart, loadStatus, collectionStatus}`.
`coverageStart` is the inclusive host-calendar day known to be represented in
the latest snapshot and its machine-owned SQLite cache. It is `null` before the
first successful load and only moves earlier. Scheduled polls and manual
refreshes call that machine's `SnapshotService` with its retained
`coverageStart`, so a short default poll can never shrink previously loaded
custom-range history.

On startup, each enabled machine first loads the current-week coverage and then
warms through the start of the previous host-calendar month, matching existing
dashboard behavior. The warm runs independently per machine. Requests to
`/api/day`, `/api/period`, `/api/metrics`, or `/api/cost-series` derive a
`requestedCoverageStart` from `date`, `range`, or custom `start` before snapshot
selection. If a targeted machine does not cover that date, the router asks only
that machine's service to expand to the required day and awaits it. For
`machine=all`, expansions for all enabled machines run concurrently. In-flight
loads for the same machine are coalesced; a concurrent request for an earlier
day causes a follow-up expansion after the current load rather than publishing
less coverage. Publication atomically replaces the snapshot and advances
coverage only after the SQLite update and snapshot build both succeed.

A failed range expansion retains the previous snapshot and coverage. If that
coverage already satisfies a query, the stale data remains a `200`. If it does
not, a concrete-machine query returns `503 range_unavailable` with
`machine`, `requestedCoverageStart`, `availableCoverageStart`, and the normal
scope. An all-machine query omits machines lacking the requested coverage and
lists them in `scope.unavailableMachineIds`; it returns partial `200` when at
least one machine covers the range and `503 range_unavailable` when none do.
This is the same partial-result rule used for never-collected machines.

`GET /api/refresh?machine=<id|all>` preserves the existing GET contract.
`machine` defaults to `all`. A concrete id force-refreshes that enabled machine;
`all` concurrently force-refreshes every enabled machine. Each refresh uses its
retained coverage start, or current-week start when none exists, and coalesces
with in-flight work. A successful concrete refresh returns `200`:

```json
{
  "status": "ok",
  "requested": "gcp-web-1",
  "refreshedMachineIds": ["gcp-web-1"],
  "failedMachineIds": [],
  "generatedAt": "2026-07-16T12:00:00Z"
}
```

For `all`, at least one success returns `200` with `status: "ok"` when all
succeed or `status: "partial"` when any fail. No success returns `503` with
`error: "refresh_failed"`. Unknown, disabled, malformed, and conflicting machine values
use the same `404`, `409`, and `400` selection errors as query routes. Refresh
never enables a machine, expands beyond retained coverage, clears a cache, or
discards the last successful snapshot.

`GET /api/load-status?machine=<id|all>` also defaults to `all` and never starts
a load. It reports range/warm/refresh work for the selected concrete machine or
all enabled machines. It preserves the existing top-level fields and adds
machine detail:

```json
{
  "phase": "loadingHistory",
  "message": "Loading historical usage for 1 machine",
  "completed": 4,
  "total": 6,
  "isLoading": true,
  "requested": "all",
  "machines": [
    {
      "id": "gcp-web-1",
      "phase": "loadingHistory",
      "message": "Loading usage history",
      "completed": 1,
      "total": 3,
      "isLoading": true,
      "coverageStart": "2026-07-01",
      "requestedCoverageStart": "2026-04-01"
    }
  ]
}
```

Per-machine phases remain `idle`, `loadingWeek`, `loadingHistory`,
`refreshing`, `ready`, or `failed`. `requestedCoverageStart` is present only
during range expansion; `coverageStart` is a host-calendar `YYYY-MM-DD` or
`null`. For `all`, `completed` and `total` are sums over enabled targets,
`isLoading` is true if any target loads, and phase precedence is
`loadingHistory`, `loadingWeek`, `refreshing`, `failed`, `ready`, then `idle`.
The top-level message is derived from that phase and a machine count, never from
raw errors. A concrete disabled id returns `409`, an unknown id returns `404`,
and malformed selection returns `400`. `/api/machine-status` remains distinct:
it reports collection health and sanitized last-error/last-success timestamps,
whereas `/api/load-status` reports transient loading progress and coverage.

`DELETE /api/cache?machine=<id|all>` applies the same selection rules, defaults
to `all`, and uses the atomic-per-machine/partial-across-machines protocol above.
Its stable response is:

```json
{
  "requested": "all",
  "outcome": "partial",
  "clearedMachineIds": ["local", "machine-a"],
  "failedMachines": [
    {
      "id": "machine-b",
      "code": "cache_failed",
      "message": "Usage cache could not be cleared",
      "reconciliationRequired": false
    }
  ]
}
```

`outcome` is exactly `complete`, `partial`, or `failed`, and the arrays follow
selection order. Status is `200` when every selected machine commits, `207`
when at least one commits and at least one fails, and sanitized `500` when none
commits; every failed item uses `code: "cache_failed"`, so the `failed` response
does not introduce a second error envelope. A concrete selection therefore
returns only `200` or `500`, never `207`. For this administrative deletion,
`all` freezes synthetic `local` plus every persisted descriptor, including
disabled machines, and a known disabled concrete machine may also be cleared.
Malformed and unknown selections retain `400` and `404` and perform no clear.
`reconciliationRequired` is true only when rollback or startup recovery could
not restore a safe pre-clear or cleared state; that machine's
poller remains stopped and its prior snapshot remains visible as stale with
`cache_failed`. Successfully cleared machines publish no old snapshot, reset
coverage/load state, and resume their pollers to repopulate default current-week
coverage. Failed machines that rolled back cleanly keep their prior store and
resume their existing pollers. Cache deletion never changes registry entries.

#### Machine collection-status contract

`GET /api/machine-status?machine=<id|all>` is the only machine-health route and
defaults to `all`. It accepts exactly one `machine` query item and no other
query keys. `all` returns every registered descriptor, including disabled
machines, with synthetic `local` first and remaining machines ordered by id. A
known concrete id returns the same envelope with exactly one array item;
disabled is a reportable health state and therefore still returns `200`.

The exact response shape is:

```json
{
  "requested": "all",
  "generatedAt": "2026-07-16T12:00:00.000Z",
  "machines": [
    {
      "id": "gcp-web-1",
      "displayName": "GCP web 1",
      "kind": "ssh",
      "enabled": true,
      "collectionState": "stale",
      "snapshotAvailable": true,
      "collectionInProgress": false,
      "stale": true,
      "coverageStart": "2026-06-01",
      "snapshotGeneratedAt": "2026-07-16T11:58:00.000Z",
      "lastAttemptAt": "2026-07-16T11:59:40.000Z",
      "lastSuccessAt": "2026-07-16T11:58:01.000Z",
      "lastErrorAt": "2026-07-16T11:59:41.000Z",
      "lastError": {
        "code": "transport_failed",
        "message": "Command transport failed"
      },
      "refreshIntervalSeconds": 20
    }
  ]
}
```

Every item always emits every field shown. `coverageStart` is an inclusive
host-calendar `YYYY-MM-DD` or `null`. All `*At` fields and top-level
`generatedAt` use UTC RFC 3339 with exactly millisecond precision; item
timestamps are `null` until their corresponding event exists.
`snapshotGeneratedAt` comes from the retained snapshot; `lastAttemptAt` is when
the latest scheduled/manual collection began; `lastSuccessAt` is when a
snapshot was last published atomically; and `lastErrorAt` is when the latest
uncleared collection error completed. A success clears `lastErrorAt` and
`lastError`. `collectionInProgress` reports an active collection independently
of the retained health state. `refreshIntervalSeconds` is always the positive
configured interval for that machine. `snapshotAvailable` is true exactly when
`snapshotGeneratedAt` is non-null; `coverageStart` is null when it is false and
otherwise reports the retained snapshot entry's inclusive coverage.

`collectionState` is exactly one of `disabled`, `neverCollected`, `healthy`,
`stale`, or `error`, selected in this precedence order:

1. `disabled` when `enabled` is false; `stale` is false even if a snapshot is
   retained.
2. `error` when enabled, no snapshot is available, and an uncleared latest
   error exists.
3. `neverCollected` when enabled and no snapshot or uncleared error exists,
   including while its first collection is in progress.
4. `stale` when enabled with a snapshot and either an uncleared latest error
   exists or `generatedAt - snapshotGeneratedAt` exceeds two complete refresh
   intervals.
5. `healthy` when enabled with a snapshot and none of the preceding rules
   applies.

The Boolean `stale` is true only for `collectionState: "stale"`.
`snapshotAvailable` reflects retained snapshot presence in every state. The
only permitted `lastError.code` values are `transport_failed`,
`remote_command_failed`, `invalid_response`, `cache_failed`, and
`internal_error`. Their exact messages are `Command transport failed`, `ccusage
command failed`, `ccusage response was invalid`, `Usage cache operation failed`,
and `Collection failed`, respectively, using the normative typed-failure table
in the transport section. Raw stderr, exit status, termination reason, command
arguments, host/user/identity values, exception text, and filesystem paths are
never exposed. An age-only stale item has null error fields.

Malformed, empty, repeated, conflicting, non-canonical, or extra query values
return `400` with
`{"error":{"code":"invalid_machine_selection","message":"Invalid machine selection","fieldErrors":{"machine":"must use one canonical machine id or all"}}}`.
A canonical unknown id returns `404` with
`{"error":{"code":"machine_not_found","message":"Machine not found","fieldErrors":{"machine":"was not found"}}}`.
The route never returns `409` or `503`: disabled, failed, and never-collected
machines are successful health representations. Other methods return `405`
with `Allow: GET`; internal status-read failures return sanitized
`500 machine_status_unavailable` in the same error envelope.

### 5. Dashboard UI

- Machine selector in the sidebar: "All machines" + one entry per registered
  machine; drives the `machine` query param and a visible label of the current
  scope on the stats/charts/table.
- Row-level machine attribution: metric table + chart legend/tooltip show the
  machine id when scope = all.
- A "Machines" registration screen (add/edit/remove ssh connection info, toggle
  enabled) plus the per-machine collection state, freshness, last successful
  collection, and sanitized current error defined by the health DTO.

## Local emulation (Docker Compose + Colima)

The accepted verification topology is standalone Docker Compose under Colima.
Docker Swarm, `docker stack deploy`, and any other deployment topology are out
of scope. Emulation uses an isolated collector container so its SSH identity can
remain in container memory while `serve` keeps its production loopback-only
listener contract. Production packaging remains a host process and does not
depend on Docker.

`compose.yaml` defines four roles:

- `machine-a` and `machine-b` run minimal `sshd` images with distinct canned
  block, daily, and session JSON. Each publishes a fixed SSH port to emulate an
  already-open host forward. Each machine has a separate host-key `tmpfs`; its
  startup creates a unique ephemeral ed25519 SSH host key there with private-key
  ownership `root:root` and mode `0600`, public-key mode `0644`, and starts
  `sshd` with an explicit `HostKey` path in that `tmpfs`.
- `keygen` creates one ephemeral ed25519 pair only inside a dedicated container
  `tmpfs` for client authentication. It stays alive for the smoke run so the
  authentication pair is generated once.
- `collector` runs the Linux `ccusage-gauge serve --port 18081` build with a
  valid zero-cost local `ccusage` stub. Its API port is not published; smoke
  requests execute with `docker compose exec` against
  `http://127.0.0.1:18081` inside the collector namespace.

Every service receiving key material has a dedicated `tmpfs` secret directory.
The provisioning script streams the private key from `keygen` directly through
a pipe into the collector tmpfs and streams only the public key into each SSH
machine tmpfs. It sets the private key to mode `0400`, sets the authorized-key
files to the ownership and modes required by `sshd`, and never expands key bytes
into shell arguments, environment variables, command tracing, captured output,
or logs. It must fail before collection if any destination is not a tmpfs mount.
Compose file-backed `secrets:` entries are not used for credentials because they
are ordinary bind mounts in standalone Compose.

SSH server host keys follow a separate, machine-local lifecycle. Neither the
image nor `keygen` supplies them: each machine generates its own host key after
verifying that its host-key directory is a `tmpfs`, refuses to start if the
private key is missing or has ownership/mode other than `root:root`/`0600`, and
passes only that explicit key path to `sshd`. The key never leaves the machine
container. `docker compose down` destroys both machine host-key tmpfs mounts;
the next smoke run generates new keys rather than reusing prior material.

No credential may enter an image layer, host file, committed file, bind mount,
named volume, container writable layer, cache/config directory, process
environment, process argument, or log. In particular, the host's real `~/.ssh`
is never mounted or read. The collector's disposable registry and per-machine
SQLite caches may use gitignored `deploy/emulation/.runtime/` bind mounts, but
that tree is scanned to prove it contains no key material. Remote-machine
containers never receive caches or registry state.

The collector reaches each machine through its published SSH port and the
Compose host-gateway address; service DNS and direct container port 22 are not
used as substitutes. The registry therefore exercises the forwarded-port SSH
boundary, including non-default ports, `-F /dev/null`, `IdentitiesOnly=yes`, and
the tmpfs identity path.

`scripts/smoke-remote-machines.sh` performs these ordered boundaries:

1. Check Colima, Docker Engine, Docker Compose, image-build, host-gateway, and
   tmpfs prerequisites; start Colima when available and needed.
2. Build and start the Compose project, generate and pipe the one-time client
   authentication keypair, generate one machine-local SSH host key per server,
   verify every key directory is `tmpfs`, verify authentication and host-key
   ownership/modes, assert the two host-key fingerprints are non-empty and
   distinct, then start collection.
3. Register the two SSH machines through the guarded mutation API and assert
   concrete-machine results, `all` totals, provenance, filtering, synthetic
   zero-cost `local`, health, and partial-state contracts.
4. Prove the collector API is unpublished and keys are absent from images,
   ordinary mounts, named volumes, writable layers, runtime data, environment,
   arguments, logs, and Git candidates.
5. Always run `docker compose down`, remove the gitignored credential-free
   runtime directory, and verify no emulation container or key-bearing tmpfs
   remains. A subsequent clean start must produce host-key fingerprints that
   differ from the prior run when lifecycle regeneration is explicitly tested.

Missing Colima, Docker, Compose, host-gateway, or tmpfs support is recorded as an
explicit verification limitation; it does not authorize Swarm or weaker key
storage. No smoke result may claim credential isolation unless all placement,
absence, and cleanup checks pass.

## Rollout and compatibility

- Existing `CCUsageClient` initializers and local `usage-snapshot` behavior stay
  source-compatible; absent machine provenance decodes as `local`, while newly
  encoded records and API rows always contain the non-optional machine field.
- `serve` adopts the registry, one poller per enabled machine, and the
  per-machine snapshot store. An empty registry is therefore equivalent to one
  enabled local machine.
- The host cache path is `aggregates-<machineId>.sqlite3`; remote machines never
  receive cache or registry files. Cache contents read from a machine-owned file
  are stamped with that owning id before entering the snapshot store.
- On the first multi-machine startup, a sole valid `aggregates.sqlite3` local
  cache is preserved by the atomic upgrade contract above. An existing
  `aggregates-local.sqlite3` always wins a source/destination conflict without a
  merge or overwrite. Local cache clear removes both namespaces so ignored
  legacy history cannot reappear after a later restart.
- Frontend source and packaged assets are updated in one change and verified by
  a clean bun build.
- Required verification is `swift build`, `swift test`, `task test:coverage`,
  `cd frontend && bun install && bun run build`, and
  `bash scripts/smoke-remote-machines.sh`, plus `swiftlint` when available after
  Swift changes. `task test:coverage` is the repository-supported coverage
  entry point. It runs `swift test --enable-code-coverage`, derives the coverage
  artifact and test binary from SwiftPM rather than hard-coding an architecture
  path, and uses the active Swift toolchain's `llvm-cov` to measure executable
  line coverage for `Sources/AppCore` and `Sources/AppCLI`. Tests, generated
  code, and copied web resources are excluded. The command fails unless total
  line coverage is at least 80.0%; a missing tool or unreadable coverage
  artifact is a verification failure, not a skipped gate.

## Non-goals

- No remote push, no agent deployment, no Prometheus.
- No credential material copied into application-managed persistence, including
  the registry, caches, logs, API payloads, image layers, bind mounts, named
  volumes, or container writable layers. Production may reference an
  operator-managed host identity file through `identityFile` without copying
  it. Emulation client-authentication and SSH-server host private keys exist
  only in service-scoped container `tmpfs` mounts for the smoke-run lifetime.
- Timestamped-event reconciliation is not performed for remote machines.
