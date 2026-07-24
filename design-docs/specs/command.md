# Command-Line Contract

## Status

Proposed alongside the ccusage-gauge architecture.

## Public Commands

```text
ccusage-gauge --help
ccusage-gauge --version
ccusage-gauge config-check
ccusage-gauge usage-snapshot [--json]
ccusage-gauge serve [--port <port>] [--assets <directory>]
```

`--help` documents commands without creating configuration or state. `--version`
prints the package version without side effects.

`config-check` resolves the production paths by default, creates the static
configuration only when missing, loads both stores, validates values, resolves
`ccusage`, and reports actionable status. Test and development builds may expose
environment- or argument-injected base paths, but production defaults remain
`~/.config/ccusage-gauge/ccusage-config.json` and
`~/.local/ccusage-gauge/state.json`.

The generated configuration defaults are `ccusagePath: null`,
`defaultResetTerm: daily`, `dashboardPort: 18081`,
`dashboardAutostart: true`, and `pollIntervalSeconds: 20`. `config-check` reports
these effective values but does not rewrite an existing configuration file.

`usage-snapshot` performs one asynchronous `ccusage --json` collection through
`AppCore`, then reports the active reset boundary, cost since reset, and budget
summary. It validates or refreshes the persisted reset baseline first and uses
`baseline.activeBoundaryAt` as the inclusive lower bound; baseline metadata is
never treated as monetary usage. `--json` emits a stable machine-readable
object. The command never parses raw usage JSONL.

`usage-snapshot` remains a local-only compatibility command. Multi-machine
collection is owned by `serve`; this avoids turning a one-shot diagnostic into a
second collector lifecycle.

`serve` is a foreground host for the same loopback service used
by the menu-bar app. It binds only to `127.0.0.1`. `--port` must be in
`1...65535`; `--assets` must name a readable compiled frontend directory and is
intended for development and verification. SIGINT or SIGTERM stops the service
cleanly.

The emulation does not relax this listener contract. Docker Compose under
Colima runs an emulation-only collector whose API is not published; smoke calls
execute with `docker compose exec` inside that container against
`http://127.0.0.1:18081`. Its SSH private key arrives by a pipe into container
tmpfs and never through a host file, Compose file-backed secret, bind mount, or
named volume. No proxy, relay, wildcard bind, origin-policy exception, Swarm
deployment, or credential-storage fallback is permitted.

At startup, `serve` loads the machine registry, synthesizes `local`, starts one
background snapshot poller per enabled machine, and exposes machine-aware query,
registry, and health endpoints. Local collection uses the configured local
ccusage path and local reconciliation; SSH collection invokes the remote binary
through a direct endpoint or the remote-machine design's validated
direct/jump/command adapter. An operator-opened local forward is a direct
endpoint. `serve` does not create a provider-specific tunnel, deploy remote
software, push data, or persist anything remotely.

Only an absent registry file selects an empty SSH registry. Unsafe directory or
file ownership/type/permissions, malformed JSON, invalid descriptors, or an
unusable persistence path fail startup before the listener or pollers start;
there is no entry quarantine or synthetic-local fallback for a present invalid
file. Recovery is to stop the service, repair or intentionally remove the file,
and restart.
The persisted document is the closed version-2 `schemaVersion`/`machines`
envelope from the remote-machine design. An exact valid version-1 document is
atomically migrated before listener or poller startup; migration failure keeps
the original bytes and fails startup. Missing or unsupported versions and
duplicate or unknown fields fail closed; API defaults are normalized before the
canonical SSH-only version-2 document is written.

One serialized registry owner validates and stages the complete candidate,
synchronizes an atomic mode-`0600` save, reconciles the affected poller
generation and snapshot/status state, then publishes the advanced revision
before responding. A reconciliation failure compensates disk and runtime back
to the prior revision; failed compensation latches
`registry_reconciliation_required` until controlled restart recovery. Invalid
descriptors, attempts to mutate `local`, unsafe machine ids or SSH options, and
inline secret material leave both persisted and running state unchanged.
Registry mutations, `GET /api/refresh`, and `DELETE /api/cache` require the
remote-machine design's loopback/same-origin gate and
`X-CCUsage-Gauge-Mutation: 1`; rejected requests perform no work.

### Remote-machine observability actions

The existing `client` command group adds:

```text
ccusage-gauge client machines test-connection <id> [--api-port <port>] [--json]
ccusage-gauge client machines refresh <id> [--api-port <port>] [--json]
```

Both commands call the guarded additive routes defined in
`design-docs/specs/design-remote-machine-collection.md` and set
`X-CCUsage-Gauge-Mutation: 1`. Test connection reports `reachable` or `failed`
plus the sanitized diagnostic and safe remediation. Refresh reloads the
registry, recollects the selected enabled machine immediately, and reports
refreshed/failed ids. Neither command accepts raw SSH arguments or a command to
execute. A decoded action result with `status: "failed"` is written to stderr
and exits `4`; successful `reachable` or `ok` results are written to stdout and
exit `0`. `--json` preserves the exact action response on the corresponding
stream.

`config-check`, `usage-snapshot`, `serve`, and client runtime failures use the
persistent bootstrap logger defined in `design-docs/specs/architecture.md`.
Runtime commands activate it before configuration parsing; help and version do
not activate it and remain side-effect free. The active file is still created
lazily on the first record. CLI stderr and JSON error behavior remain
authoritative for the caller even when persistent logging is unavailable.

## Exit and Error Behavior

- `0`: requested operation completed successfully.
- `2`: invalid command, option, or user-supplied value.
- `3`: a `client` command could not reach the dashboard API.
- `4`: a `client` command received an actionable non-5xx rejection or a
  completed machine action with `status: "failed"`.
- `5`: a `client` command received an API 5xx or unavailable snapshot/range.
- `1`: configuration, state, `ccusage`, asset, bind, decoding, or other runtime
  failure.

Human-readable errors go to standard error and identify the failed boundary
without printing raw usage output or environment contents. JSON output includes a
machine-readable error code when JSON mode was requested. There is no fallback
from an explicitly configured invalid `ccusagePath` to a different executable.
`design-docs/specs/client-commands.md` remains authoritative for the complete
client-command error-stream and exit-status mapping.

The CLI reuses `AppCore` configuration, persistence, validation, aggregation, and
HTTP behavior. It must not become a second implementation of product rules.
