# Design: Remote Machine ccusage Collection

## Goal

Periodically collect ccusage cost/usage data from multiple private machines
reachable through direct SSH, an operator-managed proxy, port forward, or
equivalent tunnel, with no remote-to-host push. Store it on the host per machine
and let the dashboard show per-machine data, a cross-machine aggregate, and a
machine filter. GCE and IAP are deployment examples only; the behavior and
contracts are provider-neutral. Verification emulates machines locally with
Docker Compose under Colima.

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
    ├─ "remote-a"   -> SSHCCUsageTransport(host:port) -> SnapshotService -> aggregates-remote-a.sqlite3
    └─ "remote-b"   -> SSHCCUsageTransport(host:port) -> SnapshotService -> aggregates-remote-b.sqlite3
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
  command `ccusage <args>`. It connects directly to the configured endpoint by
  default and may use the structured provider-neutral proxy adapter below. An
  already-open local forward is represented as a direct endpoint. No cloud
  provider, proxy product, or machine id selects a runner or behavior.

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
  Stderr content never determines the runner failure phase; the later health
  sanitizer may match bounded SSH stderr against the closed diagnostic
  signatures below.

`MachineCollector` converts the first failing collection stage to a structured,
sanitized health error. Cancellation caused by disable, delete, shutdown, or
poller-generation replacement publishes no failure. Public errors add optional
`detail` and `remediation` strings to the existing `code` and `message` fields.
All four strings are selected from bounded application-owned text; raw stderr,
commands, destinations, identity values, environment values, and paths are
never copied into API, UI, CLI, or persistent-log output.

The mapping is ordered:

| Internal failure | `lastError.code` | Public meaning and safe remediation |
| --- | --- | --- |
| SSH `transportExited` whose sanitized stderr signature indicates host-key rejection or mismatch | `host_key_verification_failed` | Verify the presented fingerprint with the machine administrator, then update the configured known-hosts file; never disable host-key checking. |
| SSH `transportExited` whose signature indicates rejected credentials or unavailable authentication methods | `auth_failed` | Verify the configured user, identity-file reference and permissions, and server-side authorization. |
| SSH `transportExited` whose signature indicates refusal, reset, name-resolution failure, no route, or an unavailable forwarded endpoint | `tunnel_unreachable` | Verify that the configured proxy or tunnel is running and that its host and port match the active endpoint. |
| `timedOut` for either runner | `timeout` | Verify endpoint or executable responsiveness and the configured connection timeout, then retry. |
| `commandExited` | `remote_command_failed` | The selected `ccusage` executable ran but rejected the fixed command; verify the executable version and installation. |
| any other SSH spawn, signal, or transport failure | `transport_failed` | SSH could not complete and no narrower safe classification was available; verify the executable and connection configuration. |
| local `spawnFailed` or `signalled` | `transport_failed` | The local executable could not be launched or completed. |
| JSON decoding, required-shape validation, or incompatible ccusage response | `invalid_response` | `ccusage` returned an incompatible response; verify its supported version. |
| machine-owned cache open, migration, read, write, or transaction failure | `cache_failed` | The host cache could not be used; inspect the persistent startup/runtime log and filesystem ownership. |
| any other non-cancellation collection invariant or orchestration failure | `internal_error` | Collection failed without a safe public diagnostic. |

The public diagnostic strings are exact:

| `code` | `message` | `detail` | `remediation` |
| --- | --- | --- | --- |
| `host_key_verification_failed` | `SSH host-key verification failed` | `The SSH server identity could not be verified.` | `Verify the server fingerprint with the machine administrator, then update the configured known-hosts file.` |
| `auth_failed` | `SSH authentication failed` | `The SSH server rejected the configured credentials.` | `Verify the configured user, identity-file reference and permissions, and server-side authorization.` |
| `tunnel_unreachable` | `SSH tunnel is unreachable` | `The configured SSH endpoint did not accept a connection.` | `Verify that the configured proxy or tunnel is running and that its host and port match the active endpoint.` |
| `timeout` | `Connection timed out` | `The command did not complete before the configured timeout.` | `Verify endpoint responsiveness and the configured connection timeout, then retry.` |
| `remote_command_failed` | `ccusage command failed` | `The configured ccusage executable rejected the requested operation.` | `Verify the remote ccusage installation and supported version.` |
| `transport_failed` | `Command transport failed` | `The command could not be started or completed.` | `Verify the executable and connection configuration, then retry.` |
| `invalid_response` | `ccusage response was invalid` | `ccusage returned an incompatible response.` | `Verify the installed ccusage version and retry.` |
| `cache_failed` | `Usage cache operation failed` | `The host usage cache could not be used.` | `Inspect the persistent log and verify state and cache directory ownership.` |
| `internal_error` | `Collection failed` | `Collection failed without a safe specific diagnostic.` | `Inspect the persistent log and retry.` |

`SanitizedCollectionError` retains non-null `code` and `message` and adds
nullable `detail` and `remediation` for source compatibility. Every newly
classified failure emitted by collection or a machine action supplies all four
fields using exactly one row above.

`internal_error` is the closed fallback classification. It is used only after
the typed host-key, authentication, proxy/tunnel reachability, timeout,
remote-command, invalid-response, and cache classifications do not apply; it
never carries raw exception text or stderr.

SSH stderr classification is deterministic and fixture driven. The classifier
decodes at most 4096 bytes as UTF-8 with replacement, applies POSIX
case-folding, replaces ASCII control/whitespace runs with one space, and
performs ordered substring matching:

1. Host-key verification:
   `host key verification failed`,
   `remote host identification has changed`,
   `offending ecdsa key in`,
   `offending ed25519 key in`,
   `offending rsa key in`, or
   `no host key is known for`.
2. Authentication:
   `permission denied`,
   `authentication failed`,
   `no supported authentication methods available`,
   `too many authentication failures`, or
   `sign_and_send_pubkey: signing failed`.
3. Tunnel/endpoint reachability:
   `connection refused`,
   `connection timed out`,
   `operation timed out`,
   `no route to host`,
   `could not resolve hostname`,
   `name or service not known`,
   `connection reset by peer`,
   `connection closed by`,
   `kex_exchange_identification`, or
   `stdio forwarding failed`.

Host-key signatures therefore take precedence over authentication,
authentication over tunnel reachability, and tunnel reachability over the
generic transport fallback. Exit status alone never distinguishes those three
cases. The classifier discards normalized stderr after classification and never
includes input or matched substrings in public output. Diagnosis identifies the
failing observable boundary of the configured SSH adapter; it does not claim to
inspect an operator-managed network beyond the direct endpoint, jump hop, or
proxy command represented by that adapter.

These diagnostics are provider-neutral. GCE and IAP are deployment examples,
not code-facing concepts: API fields, routes, error codes, public strings,
classifiers, and remediation must not branch on a cloud provider, machine ID,
or tunnel product. The same contracts apply to direct SSH, the structured
`ProxyJump` and `ProxyCommand` adapters below, direct endpoints backed by local
forwards, and equivalent operator-supplied stdio adapters.

#### SSH command boundary and allowlist

An argument array protects only the local process launch. OpenSSH serializes the
remote command for a remote POSIX shell, so the runner also owns an explicit
remote-token serialization boundary. It constructs arguments in exactly this
order:

```text
/usr/bin/ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes
  [-i <identityFile>] -p <port> [validated-extra-options]
  [validated-proxy-adapter-options] -- <user>@<host>
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
overrides (`-F`, `CanonicalizeHostname`, `Include`), raw proxy/jump options
(`-J`, `ProxyCommand`, `ProxyJump`), command hooks (`LocalCommand`,
`PermitLocalCommand`), environment forwarding (`SendEnv`, `SetEnv`), remote
command overrides (`RemoteCommand`, `RequestTTY`, `-t`), multiplexing/control
commands, forwarding/listening options, destination/user/port/identity overrides
(`Host`, `Hostname`, `User`, `Port`, `IdentityFile`, `-l`, `-p`, `-i`), and any
positional token are rejected. Proxy behavior is accepted only through the
structured adapter contract below, so an `extraOptions` string can never bypass
its validation.

`user` matches `[A-Za-z_][A-Za-z0-9._-]*`. `host` is a validated IPv4 address,
bracket-free IPv6 literal, `localhost`, or DNS name whose labels contain only
letters, digits, and interior hyphens; it cannot begin with `-`. When forming the
destination, the runner brackets an IPv6 literal as `user@[literal]` and uses
`user@host` for all other host forms. Identity and known-hosts paths are
absolute, normalized local paths without control characters; the identity must
resolve to a user-readable regular file and must not be group- or
world-accessible. Validation occurs on registry load, before persistence, and
immediately before launch so a changed file cannot bypass it.

#### Provider-neutral SSH proxy adapter

`SSHConnection.proxy` is optional. Omission means `{"kind":"direct"}` and
preserves existing descriptors. The closed adapter union is:

- `direct`: no additional fields. The configured `host` and `port` may be the
  final machine or an operator-managed local-forward endpoint.
- `jump`: requires a structured `host`, `port`, and `user`, with optional
  `identityFile` and `knownHostsFile`. These values use the same host, port,
  user, path, ownership, and permission validation as the final target. The
  adapter constructs jump behavior from those fields; it never accepts a raw
  `-J` or `ProxyJump` value.
- `command`: requires only an absolute `executable`. It must resolve to a
  current-user-executable regular file that is not group- or world-writable.
  The registry, API, CLI, and frontend accept no adapter arguments,
  environment, inline configuration, placeholders, or credential values. The
  application constructs one fixed invocation:
  `<executable> connect --host <validated-target-host> --port
  <validated-target-port>`. It POSIX-quotes those application-owned tokens when
  forming the canonical OpenSSH `ProxyCommand`; there is no raw shell-string
  field. The executable implements a provider-neutral stdio bridge and owns any
  external configuration or credential lookup outside ccusage-gauge.

The target SSH handshake always enforces the target's configured host-key
policy. A `jump` adapter additionally enforces host-key verification for the
jump host and fails closed if either host cannot be verified. A `command`
adapter supplies only a byte transport to the target SSH handshake and cannot
disable target verification. Disabled host-key verification, a null
known-hosts destination, and any adapter request to weaken verification are
invalid.

Adapter configuration contains connection metadata and file references only.
Private keys, tokens, passwords, environment values, arbitrary command
arguments, and other credential contents are never accepted inline. The command
adapter executable path may be returned as connection metadata, but no external
configuration or credential value is read or returned. Adapter executable output
is subject to the same bounded SSH stderr classifier and is discarded after
classification. Collection, test-connection, targeted refresh, status, API,
CLI, and frontend behavior are otherwise identical for `direct`, `jump`, and
`command`.

Deterministic fixtures cover direct endpoints, local forwards, structured jump
hops, the fixed command-adapter invocation, rejected command arguments,
environment/configuration fields, shell fragments, and raw proxy options,
target and jump host-key failures, authentication failures, adapter
reachability failures, and sanitized output.

Remote data source: on each remote machine, `ccusage` reads that machine's own
`~/.claude` / `~/.codex` logs. The timestamped-event reconciliation
(`ClaudeUsageEventLoader` / `CodexUsageEventLoader`) reads local files and cannot
run remotely, so remote machines use ccusage's own `session`/`daily` output
without host-side event reconciliation (dataQuality stays as ccusage reports).

### 2. Machine registry

`MachineDescriptor`:
- `id: String` (stable slug, primary key; used for cache filename + API filter)
- `displayName: String`
- `kind: local | ssh`
- `ssh: SSHConnection?` (`host`, `port`, `user`, `identityFile?`,
  `extraOptions[]`, `proxy?`, `remoteCcusagePath?`) - only connection info and
  adapter metadata, never secret material inline.
- `enabled: Bool`

Persisted at `~/.config/ccusage-gauge/machines.json` (0600). A synthetic `local`
machine is always present (kind = local) so the existing behavior is preserved
even with an empty registry.

#### Persisted registry schema

`machines.json` is a closed, versioned JSON document. Version 2 has exactly this
top-level representation:

```json
{
  "schemaVersion": 2,
  "machines": [
    {
      "id": "remote-a",
      "displayName": "Remote A",
      "kind": "ssh",
      "enabled": true,
      "ssh": {
        "host": "127.0.0.1",
        "port": 2222,
        "user": "ccusage",
        "identityFile": "/run/secrets/id_ed25519",
        "extraOptions": [],
        "proxy": {
          "kind": "jump",
          "host": "relay.example.internal",
          "port": 22,
          "user": "relay",
          "knownHostsFile": "/run/secrets/known_hosts"
        },
        "remoteCcusagePath": "ccusage"
      }
    }
  ]
}
```

Both top-level keys are required; `schemaVersion` must be the JSON integer `2`
and `machines` must be an array. Only SSH descriptors are persisted: every
array item requires exactly `id`, `displayName`, `kind: "ssh"`, `enabled`, and
`ssh`; persisting `local` or a `kind: "local"` item is invalid. Each `ssh`
object requires exactly `host`, `port`, `user`, `extraOptions`, and
`remoteCcusagePath`, with optional `identityFile` and `proxy`. `identityFile`
and `proxy` are omitted rather than encoded as `null`. A persisted `proxy`
object is either exactly `{"kind":"direct"}`, a `jump` object with required
`kind`, `host`, `port`, and `user` plus optional `identityFile` and
`knownHostsFile`, or a `command` object with exactly `kind` and `executable`.
All objects reject duplicate and unknown keys; all arrays preserve their input
order during validation, although a successful write sorts descriptors by id
for deterministic diffs. JSON numbers are not accepted for Boolean or string
fields, and ports and `schemaVersion` reject fractional or exponent spellings.

API request conveniences do not make persisted fields optional. An omitted API
`extraOptions` is normalized to `[]`, an omitted API `remoteCcusagePath` is
normalized to `"ccusage"`, and omitted `identityFile` and `proxy` fields remain
absent before the complete version-2 document is written. An absent proxy has
direct semantics. API and response compatibility remains additive: existing
pre-proxy API requests that omit `proxy` retain their behavior, while responses
omit `proxy` for direct-by-omission descriptors.

The existing closed version-1 representation remains a recognized migration
source. It must satisfy the exact currently implemented version-1 key sets and
validation rules; version-1 SSH objects cannot contain `proxy`. On load, the
registry owner validates and decodes the complete version-1 document, constructs
the equivalent version-2 document with every proxy omitted, writes and
synchronizes a mode-`0600` same-directory temporary file, and atomically replaces
`machines.json` before publishing a registry revision or starting any poller.
Migration failure leaves the original version-1 bytes and runtime state
unchanged and fails startup as sanitized `registry_migration_failed`. A
successful migration is one-way; all later API mutations persist version 2.
The same transaction applies when a machine action reload encounters a valid
version-1 file: migration commits before the new revision is published and the
test or refresh begins.

The loader applies no other defaults or migration. A present unversioned
document, missing key, `null`, scalar top level, malformed version-1 or
version-2 object, version below 1 or above 2, or unknown field fails closed as
`registry_load_failed`; it is never interpreted as an empty registry or
partially rewritten. Later representation changes require a new version plus an
explicit, tested, atomic migration. Additive unknown-field compatibility is
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
- an optional proxy matches exactly one structured adapter variant and satisfies
  its path, token, placeholder, host-key, and credential-content restrictions;
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
  `ssh.extraOptions`, `ssh.proxy`, its exact nested adapter field, or
  `ssh.remoteCcusagePath`.

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
  "id": "remote-a",
  "displayName": "Remote A",
  "kind": "ssh",
  "enabled": true,
  "ssh": {
    "host": "127.0.0.1",
    "port": 2222,
    "user": "ccusage",
    "identityFile": "<home>/.ssh/ccusage-remote",
    "extraOptions": ["-o ConnectTimeout=10"],
    "proxy": {
      "kind": "jump",
      "host": "relay.example.internal",
      "port": 22,
      "user": "relay",
      "knownHostsFile": "<home>/.ssh/known_hosts"
    },
    "remoteCcusagePath": "/usr/local/bin/ccusage"
  }
}
```

`MachineCreateRequest` has exactly the fields shown above and requires
`id`, `displayName`, `kind: "ssh"`, `enabled`, and `ssh`.
`MachineReplaceRequest` omits `id` but otherwise has the same required fields.
`SSHConnectionRequest` requires `host`, `port`, and `user`; `identityFile` and
`remoteCcusagePath` may be omitted, `extraOptions` may be omitted and defaults
to `[]`, and `proxy` may be omitted for direct semantics. In responses,
`extraOptions` is always present and `remoteCcusagePath` is the effective value
(default `ccusage`); absent `identityFile` and direct-by-omission `proxy` are
omitted. The local response is always
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
A runtime reconciliation failure returns `500
registry_reconciliation_failed`; a later mutation attempted while recovery is
required returns `503 registry_reconciliation_required`. Their exact bodies
are:

```json
{
  "error": {
    "code": "registry_reconciliation_failed",
    "message": "Machine registry runtime reconciliation failed"
  },
  "reconciliationRequired": false
}
```

```json
{
  "error": {
    "code": "registry_reconciliation_required",
    "message": "Machine registry reconciliation is required"
  },
  "reconciliationRequired": true
}
```

The failed mutation uses the first body with `reconciliationRequired: false`
when rollback restores the prior disk and runtime state, or `true` when either
rollback fails. While the owner is latched, every subsequent registry mutation
uses the second body and performs no validation, persistence, publication, or
runtime change. Neither response includes `Retry-After`, because recovery
requires a controlled process restart rather than a timed retry. No error
includes identity contents, raw command arguments, stderr, or an unredacted
filesystem failure. A successful mutation is not published until the atomic
registry save succeeds; its response reflects the persisted value.

#### Serialized registry mutation ownership

One process-wide registry mutation owner serializes every POST, PUT, PATCH, and
DELETE from request validation through persistence, runtime reconciliation,
revision advancement, and publication. Each queued mutation observes the latest
committed registry revision and, without allowing another mutation to
interleave, performs this exact transaction:

1. construct the complete candidate registry from that revision and validate
   request fields, cross-entry uniqueness, persistence safety, and the complete
   resulting descriptors; stage every throwing runner, store, and poller
   dependency before changing durable or published state;
2. write a same-directory temporary file, enforce mode `0600`, synchronize the
   file, retain the prior validated bytes for rollback, and atomically replace
   `machines.json` as the durable staging point;
3. increment the affected machine's staged poller generation, cancel and await
   the old generation, reconcile snapshot/status retention or removal, and
   install the enabled replacement generation without exposing the candidate
   registry to readers;
4. atomically advance the committed revision and publish the candidate registry
   plus reconciled runtime as one reader-visible state; and
5. discard the rollback bytes and return the HTTP response only after the
   runtime observes that committed revision.

Validation or any failure before the atomic replacement leaves the prior file,
published revision, snapshot/status state, and pollers unchanged. A failure
after durable staging but before publication restores the prior registry bytes
with the same synchronized atomic-replacement protocol and restores the prior
runtime generation before releasing the owner; the mutation returns sanitized
`500 registry_reconciliation_failed`. If either rollback cannot restore the
prior coherent state, the owner retains the last published revision, stops the
affected poller, marks reconciliation required in sanitized health state, and
rejects later registry mutations with `503 registry_reconciliation_required`
until restart recovery reloads and reconciles one complete persisted revision.
No response may report success while disk, the published revision, and runtime
reconciliation disagree.

Startup recovery has one deterministic boundary: decode and validate the
complete atomically persisted registry, stage every runtime dependency,
reconcile all pollers and retained status, and only then publish initial
revision `1` and begin accepting HTTP requests. Success clears the in-memory
reconciliation-required latch. Any load, staging, or reconciliation failure
fails startup with sanitized `registry_reconciliation_failed`; the process
publishes no registry revision, starts no poller, and does not open the HTTP
listener. Atomic replacement guarantees startup observes either the prior or
candidate complete file, never partial bytes.

Runner construction and every other throwing prerequisite are validated before
persistence; installing an already staged poller generation and publishing the
revision are non-throwing owner operations. Later command or cache failures are
ordinary collection health. Every collection publication carries both registry
revision and poller generation and is discarded unless both still match, so a
cancelled task cannot republish after an update or deletion. Reads may use the
previous published immutable revision concurrently until the transaction's
single publication point, but no second registry mutation or poller replacement
bypasses this owner. Cache-clear reconciliation coordinates with the same owner
and its currently published revision before changing a machine's store or
poller.

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

`machine=all` selects enabled machines only. The router derives an effective
half-open query interval before snapshot selection. A response has
`dataDisposition: "current"` when that interval contains the request evaluation
instant or ends after the start of its host-calendar day; otherwise it has
`dataDisposition: "historical"`. `/api/recent` and `/api/budget` are always
current. This interval rule makes today, recent12h, the current week, the
current month, all-time, and any custom range ending on the current host day
current without maintaining a route-name allowlist. Yesterday and custom
ranges ending before the current host day are historical.

Historical selection merges every retained snapshot that covers the requested
range. Current selection excludes any machine whose derived collection state
is `stale`, `error`, `neverCollected`, or `disabled` before rows or totals are
computed. Consequently stale retained history can support an explicitly
historical view but can never contribute to a current/latest summary card,
budget value, recent series total, or all-machine current aggregate.

Merge stamps every block/timeline, daily, and session source record with its
source id, concatenates records without discarding provenance, and recomputes
every route row and total from those records; it never adds already-computed
snapshot totals. A concrete stale-machine historical response still emits that
concrete id on every row and declares `scope.dataDisposition: "historical"`,
with the id in `scope.staleMachineIds`. A concrete current query for a stale
machine returns `503 current_data_unavailable` rather than presenting its
retained history as current. Unknown ids return
`404`; malformed or repeated conflicting machine parameters return `400`.

Every successful query response includes a `scope` object without removing its
existing fields:

```json
{
  "requested": "all",
  "dataDisposition": "current",
  "includedMachineIds": ["local"],
  "staleMachineIds": ["remote-a"],
  "unavailableMachineIds": ["remote-b"],
  "excludedFromCurrentTotalsMachineIds": ["remote-a", "remote-b"],
  "machineAvailability": [
    {
      "machine": "remote-a",
      "available": false,
      "unavailableSince": "2026-07-16T11:59:41.000Z",
      "reasonCode": "tunnel_unreachable"
    },
    {
      "machine": "remote-b",
      "available": false,
      "unavailableSince": "2026-07-16T11:00:00.000Z",
      "reasonCode": "never_collected"
    }
  ],
  "lastHourDataGaps": [
    {
      "machine": "remote-a",
      "startAt": "2026-07-16T11:59:41.000Z",
      "endAt": "2026-07-16T12:00:00.000Z",
      "reasonCode": "tunnel_unreachable"
    },
    {
      "machine": "remote-b",
      "startAt": "2026-07-16T11:00:00.000Z",
      "endAt": "2026-07-16T12:00:00.000Z",
      "reasonCode": "never_collected"
    }
  ],
  "evaluatedAt": "2026-07-16T12:00:00.000Z",
  "generatedAt": "<oldest included snapshot timestamp>"
}
```

The additive `DashboardScope` fields are exact:

- `dataDisposition: "current" | "historical"` is non-null;
- `excludedFromCurrentTotalsMachineIds: [String]` is empty for historical
  ranges and contains enabled stale or unavailable machines for current ranges;
- `machineAvailability: [MachineAvailability]`;
- `lastHourDataGaps: [MachineDataGap]`; and
- `evaluatedAt: Date`.

`MachineAvailability` contains non-null `machine: String`, `available: Bool`,
`unavailableSince: Date`, and `reasonCode: MachineAvailabilityReason`.
`MachineDataGap` contains non-null `machine: String`, `startAt: Date`,
`endAt: Date`, and `reasonCode: MachineAvailabilityReason`. The reason enum is
closed to `collection_stale`, `never_collected`, `tunnel_unreachable`,
`auth_failed`, `host_key_verification_failed`, `timeout`, `transport_failed`,
`remote_command_failed`, `invalid_response`, `cache_failed`, and
`internal_error`.

`machineAvailability` has one item for each machine excluded from current
totals. Its concrete `unavailableSince` is `staleSince` for a retained stale
snapshot, the first consecutive failure for `error`, or the descriptor's
status-tracking start for `neverCollected`. An age-only stale machine uses
`collection_stale`; an error-driven state uses its sanitized diagnostic code.
`evaluatedAt` is the request evaluation instant and is distinct from the
oldest-snapshot freshness timestamp already carried by `generatedAt`.
`lastHourDataGaps` is the intersection of each unavailability interval with
`[evaluatedAt - 1 hour, evaluatedAt]`; it is empty when there is no overlap.
Items use registry order and never infer availability from zero reported usage.

For a known enabled machine with no successful snapshot, query routes return
`503` with `error: "snapshot_unavailable"`, its machine id, the exact
`collectionState` derived by the machine-status state machine, and
`refreshIntervalSeconds`; the response also carries a `Retry-After` header with
that interval. Therefore the state is `neverCollected` before any failed
attempt and `error` when an uncleared latest collection error exists. A known
disabled machine returns `409` with `error: "machine_disabled"` and
`collectionState: "disabled"`; an unknown id remains `404`. A stale machine
with a retained successful snapshot returns `200` for a historical range and
lists the id in `scope.staleMachineIds`; a current range returns
`503 current_data_unavailable` with the same status and availability metadata.

The new current-data error uses the router's structured envelope and always
includes the exact selection metadata:

```json
{
  "error": {
    "code": "current_data_unavailable",
    "message": "Current usage data is unavailable"
  },
  "machine": "remote-a",
  "collectionState": "stale",
  "refreshIntervalSeconds": 20,
  "machineLatestEvents": [{
    "machine": "remote-a",
    "latestEventAt": "2026-07-16T10:42:00.000Z",
    "markerState": "stale",
    "inLastHour": false,
    "dataQuality": "sessionEstimated"
  }],
  "scope": {
    "requested": "remote-a",
    "dataDisposition": "current",
    "includedMachineIds": [],
    "staleMachineIds": ["remote-a"],
    "unavailableMachineIds": [],
    "excludedFromCurrentTotalsMachineIds": ["remote-a"],
    "machineAvailability": [{
      "machine": "remote-a",
      "available": false,
      "unavailableSince": "2026-07-16T11:59:41.000Z",
      "reasonCode": "tunnel_unreachable"
    }],
    "lastHourDataGaps": [{
      "machine": "remote-a",
      "startAt": "2026-07-16T11:59:41.000Z",
      "endAt": "2026-07-16T12:00:00.000Z",
      "reasonCode": "tunnel_unreachable"
    }],
    "evaluatedAt": "2026-07-16T12:00:00.000Z",
    "generatedAt": null
  }
}
```

For `machine=all`, the envelope omits `machine` and `collectionState`, retains
every scope field, and uses the same status and error object. No new route
returns a bare string in `error`.

The `machineLatestEvents` member above is specific to
`/api/cost-series`. That route adds the same member to a recognized
`409 machine_disabled`, `503 snapshot_unavailable`, `503
current_data_unavailable`, or `503 range_unavailable` response after machine
selection has resolved. Every such cost-series response also preserves its full
selection `scope`, including `machineAvailability` and `lastHourDataGaps`, plus
the applicable refresh interval and requested-coverage metadata. It contains
one latest-event item for every selected known machine, including when no
machine is eligible for current rows. A never-collected machine has
`latestEventAt: null`, `markerState: "unavailable"`, `inLastHour: false`, and
`dataQuality: null`; a stale machine may retain its last event timestamp but
uses `markerState: "stale"`. Malformed and unknown selections have no resolved
machine set and omit the member. Other query routes retain their existing error
shapes.

The error bodies are stable JSON contracts:

```json
{
  "error": "snapshot_unavailable",
  "machine": "remote-b",
  "collectionState": "error",
  "refreshIntervalSeconds": 20,
  "scope": {
    "requested": "remote-b",
    "includedMachineIds": [],
    "staleMachineIds": [],
    "unavailableMachineIds": ["remote-b"],
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
included only for historical ranges; current ranges exclude them alongside
enabled machines without snapshots. Excluded machines remain visible through
`scope.staleMachineIds`, `scope.unavailableMachineIds`,
`scope.excludedFromCurrentTotalsMachineIds`, and `scope.machineAvailability`.
If at least one eligible snapshot exists, the API returns `200` even when the
result is partial. If none exists, it returns `503` with the applicable
`snapshot_unavailable` or `current_data_unavailable` error, the same scope
metadata, and `refreshIntervalSeconds`. An all-machine response omits singular
`machine` and `collectionState` fields because unavailable machines may have
different states; `/api/machine-status?machine=all` is the authoritative
per-machine detail. Query serialization calls the same state-derivation
function as that route, so a concrete machine cannot report a different state
in the two contracts at the same store revision.

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
  `/api/machines/{id}`;
- `POST /api/machines/{id}/test-connection`; and
- `POST /api/machines/{id}/refresh`.

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

#### No-restart connection test and targeted refresh

The two machine action routes are additive; the existing guarded
`GET /api/refresh` contract remains for compatibility. They accept no query
items and either an empty body or `{}`. They use the same loopback/same-origin
gate and `X-CCUsage-Gauge-Mutation: 1` header as every other control.

Before either action, the serialized registry owner reloads `machines.json`
from disk, validates the complete closed schema and all SSH safety rules, and
computes a revision diff. A valid changed document is published atomically to
the in-memory registry; affected poller generations are replaced before the
action continues. An invalid or unsafe document returns
`409 registry_reload_failed`, keeps the last committed in-memory registry and
pollers unchanged, and runs neither the connection test nor collection. This
reload boundary makes an operator edit or API/UI configuration change usable
without restarting the process.

A valid version-1 document encountered here first runs the schema migration
transaction above. Migration failure is reported as
`409 registry_reload_failed`, preserves the version-1 file and current runtime
revision, and runs no action.

`POST /api/machines/{id}/test-connection` resolves the current descriptor and
runs a bounded, fixed probe through the same validated runner used by
collection. For SSH it executes the configured `ccusage` executable with the
fixed `--version` token; it does not run a shell fragment, create a tunnel,
write a cache, publish collection status, or replace a snapshot. Synthetic
`local` uses its resolved local executable. A successful response is:

```json
{
  "machine": "remote-a",
  "status": "reachable",
  "testedAt": "2026-07-16T12:00:00.000Z",
  "diagnostic": null
}
```

A completed unsuccessful probe returns `200` with `status: "failed"` and the
same structured sanitized diagnostic used by collection. A malformed id is
`400`, an unknown id is `404`, a disabled id is `409 machine_disabled`, and an
internal inability to run the probe is a sanitized
`503 connection_test_unavailable`. Transport or authentication failure is a
test result, not an HTTP transport failure, so UI and CLI clients never parse
error text.

`MachineConnectionTestResponse` is exact: non-null `machine: String`,
`status: "reachable" | "failed"`, `testedAt: Date`, and nullable
`diagnostic: SanitizedCollectionError`. `diagnostic` is null only when status
is `reachable` and non-null only when status is `failed`.

`POST /api/machines/{id}/refresh` reloads the registry as above, requires an
enabled descriptor, coalesces with any in-flight collection for the resulting
revision, and immediately recollects using retained coverage. It returns the
existing `RefreshResponse` shape with the concrete id. A collection failure
returns `200` with `status: "failed"`, `failedMachineIds: [id]`, and an
additive `diagnostic` field; selection, registry-reload, or
service-unavailable failures retain their structured `4xx` or `503` envelopes.
It never enables a machine, discards the last successful snapshot, or weakens
host-key checking.

The concrete action response uses `RefreshResponse` with non-null
`status: "ok" | "failed"`, `requested: String`,
`refreshedMachineIds: [String]`, `failedMachineIds: [String]`,
`generatedAt: Date`, and nullable `diagnostic: SanitizedCollectionError`.
`ok` requires `[id]`, `[]`, and null diagnostic; `failed` requires `[]`,
`[id]`, and a non-null diagnostic. The compatible all-machine
`GET /api/refresh` may also use `status: "partial"` and returns a null top-level
diagnostic because per-machine status remains authoritative.

`DashboardAPIClient` exposes typed methods for both actions. CLI support is
`ccusage-gauge client machines test-connection <id>` and
`ccusage-gauge client machines refresh <id>` with existing `--api-port` and
`--json` behavior. Text output renders only the sanitized code, detail, and
remediation. The frontend places Test connection and Refresh controls beside
each machine, disables duplicate in-flight actions per machine, and refreshes
registry, status, current metrics, cost series, and budget after a successful
targeted refresh.

For CLI actions, `reachable` or `ok` writes the normal response to stdout and
exits `0`. A decoded HTTP-200 action result with `status: "failed"` writes the
sanitized text response, or the exact JSON response under `--json`, to stderr
and exits `4`, matching other actionable client-side API failures. HTTP and
transport failures retain the existing client exit mapping.

The frontend treats `status: "failed"` as an action failure even though fetch
succeeded: it shows the diagnostic panel, never shows a success toast, and
keeps the result until the next edit/action. A failed connection test refetches
nothing because it does not mutate collection status. A failed refresh
refetches machine status plus current metrics, cost series, and budget so the
new stale/exclusion state is reflected while preserving the retained snapshot.
A successful refresh performs the same refetch set and clears the prior
diagnostic.

One per-machine action state owns both the refresh request and its post-refresh
refetches. Duplicate controls remain disabled while that state is active, and a
single unconditional completion boundary clears it after every outcome:
refresh rejection, decoded `status: "failed"`, successful refetch, or any
failed/aborted post-refresh refetch. Refetch failures use the ordinary
dashboard-load error surface without erasing the retained action diagnostic.
They never leave Test connection, Refresh, Edit, Enable/Disable, or Remove
permanently disabled. A later action may start without reloading the page.

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

A failed range expansion retains the previous snapshot and coverage. Selection
then applies coverage before data disposition. If no retained snapshot covers
the requested interval, a concrete-machine query returns
`503 range_unavailable` with `machine`, `requestedCoverageStart`,
`availableCoverageStart`, and the normal scope. An all-machine query omits
machines lacking coverage and lists them in `scope.unavailableMachineIds`; it
returns `503 range_unavailable` when no selected retained snapshot covers the
interval.

When retained coverage does satisfy the interval, stale data remains eligible
only for a historical disposition and may produce a historical `200`. A current
query still applies the normal stale-state gate after the failed expansion: a
concrete stale machine returns `503 current_data_unavailable`, while
`machine=all` excludes stale machines before aggregation and returns partial
`200` only when at least one current-eligible snapshot remains. If covering
snapshots exist but all are stale, the all-machine response is
`503 current_data_unavailable`. Thus range expansion failure cannot reintroduce
retained stale rows into current series, totals, budgets, or summaries.

`GET /api/refresh?machine=<id|all>` preserves the existing GET contract.
`machine` defaults to `all`. A concrete id force-refreshes that enabled machine;
`all` concurrently force-refreshes every enabled machine. Each refresh uses its
retained coverage start, or current-week start when none exists, and coalesces
with in-flight work. A successful concrete refresh returns `200`:

```json
{
  "status": "ok",
  "requested": "remote-a",
  "refreshedMachineIds": ["remote-a"],
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
      "id": "remote-a",
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
  "registryReconciliationRequired": false,
  "machines": [
    {
      "id": "remote-a",
      "displayName": "Remote A",
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
      "consecutiveFailureCount": 1,
      "unavailableSince": "2026-07-16T11:59:41.000Z",
      "staleSince": "2026-07-16T11:59:41.000Z",
      "lastErrorAt": "2026-07-16T11:59:41.000Z",
      "lastError": {
        "code": "tunnel_unreachable",
        "message": "SSH tunnel is unreachable",
        "detail": "The configured SSH endpoint did not accept a connection.",
        "remediation": "Verify that the configured proxy or tunnel is running and that its host and port match the active endpoint."
      },
      "lastHourDataGap": {
        "startAt": "2026-07-16T11:59:41.000Z",
        "endAt": "2026-07-16T12:00:00.000Z"
      },
      "refreshIntervalSeconds": 20
    }
  ]
}
```

Every item always emits every field shown.
`registryReconciliationRequired` is a non-null top-level Boolean. It is false
during normal operation and after successful startup recovery. It becomes true
only when a registry mutation cannot restore a coherent prior disk/runtime
state; while true, the affected poller remains stopped, the last published
registry revision and retained snapshot/status remain reader-visible, and all
registry mutations are rejected as specified above. `coverageStart` is an
inclusive host-calendar `YYYY-MM-DD` or `null`. All `*At` fields and top-level
`generatedAt` use UTC RFC 3339 with exactly millisecond precision; item
timestamps are `null` until their corresponding event exists.
`snapshotGeneratedAt` comes from the retained snapshot; `lastAttemptAt` is when
the latest scheduled/manual collection began; `lastSuccessAt` is when a
snapshot was last published atomically; and `lastErrorAt` is when the latest
uncleared collection error completed. A success clears `lastErrorAt` and
`lastError`, resets `consecutiveFailureCount` to zero, and clears the tracked
failure interval. A failure increments `consecutiveFailureCount` and sets
`unavailableSince` only when the count changes from zero to one; later
consecutive failures preserve that first concrete instant. Before a first
successful collection, `unavailableSince` is the earlier of the first failure
or the time the enabled descriptor began status tracking, ensuring
never-collected summary states also identify a concrete time.

`staleSince` is null outside `collectionState: "stale"`. For an error-driven
stale snapshot it is `unavailableSince`; for age-only staleness it is
`snapshotGeneratedAt + (2 * refreshIntervalSeconds)`; when both apply it is the
earlier instant. `lastHourDataGap` is null when staleness does not overlap the
hour ending at top-level `generatedAt`; otherwise its start is the later of
`staleSince` and `generatedAt - 1 hour`, and its end is `generatedAt`.
`collectionInProgress` reports an active collection independently of the
retained health state. `refreshIntervalSeconds` is always the positive
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
permitted `lastError.code` values are `tunnel_unreachable`, `auth_failed`,
`host_key_verification_failed`, `timeout`, `transport_failed`,
`remote_command_failed`, `invalid_response`, `cache_failed`, and
`internal_error`, using the normative typed-failure table in the transport
section. `detail` and `remediation` are additive nullable fields on
`SanitizedCollectionError`; clients must continue accepting a response that
contains only the legacy `code` and `message`. Raw stderr, exit status,
termination reason, command arguments, host/user/identity values, exception
text, and filesystem paths are never exposed. An age-only stale item has null
error fields but still has `staleSince` and an applicable `lastHourDataGap`.

Malformed, empty, repeated, conflicting, non-canonical, or extra query values
return `400` with
`{"error":{"code":"invalid_machine_selection","message":"Invalid machine selection","fieldErrors":{"machine":"must use one canonical machine id or all"}}}`.
A canonical unknown id returns `404` with
`{"error":{"code":"machine_not_found","message":"Machine not found","fieldErrors":{"machine":"was not found"}}}`.
The route never returns `409` or `503`: disabled, failed, and never-collected
machines are successful health representations. Other methods return `405`
with `Allow: GET`; internal status-read failures return sanitized
`500 machine_status_unavailable` in the same error envelope.

#### Latest-event and last-hour marker contract

`/api/cost-series` adds `machineLatestEvents`, ordered by registry order, to
every successful response and to the recognized data-availability errors
defined above:

```json
{
  "machineLatestEvents": [
    {
      "machine": "local",
      "latestEventAt": "2026-07-16T11:54:00.000Z",
      "markerState": "observed",
      "inLastHour": true,
      "dataQuality": "timestamped"
    },
    {
      "machine": "remote-a",
      "latestEventAt": "2026-07-16T10:42:00.000Z",
      "markerState": "stale",
      "inLastHour": false,
      "dataQuality": "sessionEstimated"
    }
  ]
}
```

`latestEventAt` is the maximum unbucketed source timestamp for the machine
within retained coverage, before model/agent presentation filters. It is null
when no event-like timestamp is available. `markerState` is exactly
`observed`, `noEvent`, `stale`, or `unavailable`; collection availability takes
precedence over event presence. `inLastHour` compares the timestamp with the
one-hour window ending at request evaluation time. `dataQuality` is nullable
and identifies `timestamped` local reconciliation or `sessionEstimated` remote
session timing. Daily-only records do not invent event times.

`MachineLatestEvent` has non-null `machine: String`,
`markerState: "observed" | "noEvent" | "stale" | "unavailable"`, and
`inLastHour: Bool`, plus nullable `latestEventAt: Date` and
`dataQuality: "timestamped" | "sessionEstimated"`. The array contains every
machine in the resolved selection even when the cost-series request has zero
eligible snapshots. Marker derivation reads retained per-machine source
timestamps directly; it is metadata-only and cannot make excluded source rows
eligible for current aggregation.

The cost-series client decodes recognized `snapshot_unavailable`,
`current_data_unavailable`, and `range_unavailable` response bodies as
observable data states rather than reducing them to a generic fetch error. It
preserves their sanitized error, scope, availability, refresh interval,
`machineLatestEvents`, and data-gap metadata for the dashboard while continuing
to reject malformed or unrelated errors through the ordinary error boundary.

The sub-daily dashboard graph consumes marker metadata from either a successful
response or a recognized data-availability response and renders it in a
dedicated overlay layer above the cost series: one marker per selected machine
at `latestEventAt` when it falls inside the visible domain, plus clipped
last-hour data-gap spans from scope/status metadata. Markers and gap spans do
not create series points, affect axes, alter totals, or intercept chart
interaction. Their visual state and accessible labels distinguish observed,
no-event, stale, and unavailable machines. Beside the graph it always renders
the latest time or a concrete No event, Stale since, or Unavailable since label,
so an off-domain or missing marker is not silent. Stale markers are visually
distinct and never imply that retained stale usage contributed to current
totals.

### 5. Dashboard UI

- Machine selector in the sidebar: "All machines" + one entry per registered
  machine; drives the `machine` query param and a visible label of the current
  scope on the stats/charts/table.
- Row-level machine attribution: metric table + chart legend/tooltip show the
  machine id when scope = all.
- A "Machines" registration screen (add/edit/remove ssh connection info, toggle
  enabled). It edits the closed direct/jump/command adapter fields without
  exposing a raw SSH-option or shell-command field, plus the per-machine
  collection state, freshness, last successful collection, stale-since instant,
  last-hour data gap, and sanitized current diagnostic defined by the health
  DTO.
- Stale and unavailable states use a persistent high-contrast status panel,
  not only transient text or color. Each panel states whether the machine was
  excluded from current totals and the concrete unavailable-since time.
- Current summary cards calculate only from server-selected eligible rows and
  list every machine in `excludedFromCurrentTotalsMachineIds`; client-side
  filtering must not reintroduce stale rows.
- Each SSH machine row provides Edit, Test connection, Refresh, Enable/Disable,
  and Remove controls. Test and refresh results remain visible until the next
  action or edit and render remediation as plain text without executable links.
- Edit initializes a draft from the selected persisted descriptor, including
  display name, enabled state, host, port, user, identity-file reference,
  allowlisted SSH option entries, remote executable path, and the complete
  direct/jump/command proxy discriminator and fields. Switching proxy kind
  clears fields owned only by the previous variant. Machine id remains
  immutable.
- The edit form applies the same field-level validation and closed proxy union
  as create. It exposes allowlisted option entries as structured values, never
  a shell command, raw `ssh` argv, environment field, or unbounded proxy
  string. Validation failures preserve the draft and identify the exact field.
  Save sends one full `PUT /api/machines/{id}` replacement, closes and updates
  the row only after the persisted response succeeds, and otherwise preserves
  both the prior row and draft. Cancel performs no request or mutation.
- The last-hour portion of a sub-daily graph overlays the latest-event markers
  and visible data-gap spans from the additive cost-series and scope metadata.

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
- The observability API is additive: existing machine/status fields and
  `GET /api/refresh` remain decodable and operational. New clients prefer the
  per-machine POST actions; older clients continue using the existing routes.
- `Sources/AppCore/HTTPService.swift`, already at 1001 lines,
  is an immediate refactoring target, and `MachineCollection.swift`,
  `MachineDashboardRouter.swift`, and `frontend/src/App.tsx` are split by
  diagnostics, machine actions, HTTP routing, and observability presentation
  responsibilities before additions would cross the repository's
  maintainability limits. Every non-generated Swift file finishes below 1000
  lines.
- Required verification is `task test`, `task lint`, `task frontend:check`,
  `task frontend:build`, `nix flake check`, `task smoke:isolated-runtime`,
  `task smoke:dashboard`, and `task smoke:remote-machines`, plus focused Swift
  tests for log rotation/retention, SSH diagnostic fixtures, current-total
  exclusion, staleness/data-gap derivation, and action routes and focused
  frontend tests for stale panels, exclusions, actions, and event markers.
  `task test:coverage` remains the repository-supported coverage
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
