# Command-Line Contract

## Status

Proposed alongside the ccusage-gauge architecture.

## Public Commands

```text
ccusage-gauge --help
ccusage-gauge --version
ccusage-gauge config-check
ccusage-gauge usage-snapshot [--json]
ccusage-gauge dashboard [--port <port>] [--assets <directory>]
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

`dashboard` is a foreground diagnostic host for the same loopback service used
by the menu-bar app. It binds only to `127.0.0.1`. `--port` must be in
`1...65535`; `--assets` must name a readable compiled frontend directory and is
intended for development and verification. SIGINT or SIGTERM stops the service
cleanly.

## Exit and Error Behavior

- `0`: requested operation completed successfully.
- `2`: invalid command, option, or user-supplied value.
- `1`: configuration, state, `ccusage`, asset, bind, decoding, or other runtime
  failure.

Human-readable errors go to standard error and identify the failed boundary
without printing raw usage output or environment contents. JSON output includes a
machine-readable error code when JSON mode was requested. There is no fallback
from an explicitly configured invalid `ccusagePath` to a different executable.

The CLI reuses `AppCore` configuration, persistence, validation, aggregation, and
HTTP behavior. It must not become a second implementation of product rules.
