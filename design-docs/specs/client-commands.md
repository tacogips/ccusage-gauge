# Dashboard Client Command Design

## Status

Accepted for implementation. The initial design was produced by Claude Fable 5
after a read-only review of the repository and refined against the current
server contract and swift-argument-parser 1.8.2 documentation.

## Purpose

Add a typed command-line client to `ccusage-gauge` for operators and scripts
that need to inspect or add SSH machines and read the same data exposed by the
loopback dashboard API. The running dashboard server remains the only owner of
machine registry mutation, collection state, historical expansion, and query
semantics.

## Command Tree

Existing commands retain their spelling and behavior:

```text
ccusage-gauge --help
ccusage-gauge --version
ccusage-gauge config-check
ccusage-gauge usage-snapshot [--json]
ccusage-gauge serve [--port <port>] [--assets <directory>]
```

The new client surface is grouped by resource:

```text
ccusage-gauge client machines list [client options]
ccusage-gauge client machines show <id> [client options]
ccusage-gauge client machines add <id> --host <host> --user <user>
  [--display-name <name>] [--ssh-port <port>] [--identity-file <path>]
  [--ssh-option <option>]... [--remote-ccusage-path <path>] [--disabled]
  [client options]

ccusage-gauge client dashboard budget [--machine <id|all>] [client options]
ccusage-gauge client dashboard recent [--machine <id|all>] [--limit <count>] [client options]
ccusage-gauge client dashboard day --date <YYYY-MM-DD> [--machine <id|all>] [client options]
ccusage-gauge client dashboard period [--range <range>] [--start <date>] [--end <date>]
  [--machine <id|all>] [client options]
ccusage-gauge client dashboard metrics [--range <range>] [--start <date>] [--end <date>]
  [--machine <id|all>] [client options]
ccusage-gauge client dashboard cost-series [--range <range>] [--start <date>] [--end <date>]
  [--granularity <granularity>] [--machine <id|all>] [client options]
ccusage-gauge client dashboard machine-status [--machine <id|all>] [client options]
ccusage-gauge client dashboard load-status [--machine <id|all>] [client options]
```

Client options are:

- `--api-port <port>`: loopback dashboard port. If omitted, load the configured
  `dashboardPort`; the default configuration value is `18081`.
- `--json`: emit the server JSON response without transforming its fields.

The hostname is intentionally fixed to `127.0.0.1`. This command does not add a
remote unauthenticated HTTP control plane. Operators may use an explicitly
configured SSH local forward when they understand the server's exact Host/port
mutation gate.

Closed option values use typed enums:

- machine: `all`, `local`, or a canonical machine identifier;
- period range: `today`, `yesterday`, `week`, `month`, or `custom`;
- metrics/cost range: `all`, `recent12h`, `today`, `yesterday`, `week`,
  `month`, or `custom`;
- granularity: `15min`, `hourly`, `6hour`, or `daily`.

`custom` requires both `--start` and `--end`. Other ranges reject those two
options. Dates use strict `YYYY-MM-DD`. `--limit` is `1...500`. SSH port is
`1...65535`. `--display-name` defaults to the id, SSH port to `22`, and remote
ccusage path to `ccusage`.

## HTTP Mapping

| Command | Request |
| --- | --- |
| `machines list` | `GET /api/machines` |
| `machines show` | `GET /api/machines/{id}` |
| `machines add` | `POST /api/machines` |
| `dashboard budget` | `GET /api/budget?machine=...` |
| `dashboard recent` | `GET /api/recent?machine=...&limit=...` |
| `dashboard day` | `GET /api/day?machine=...&date=...` |
| `dashboard period` | `GET /api/period?...` |
| `dashboard metrics` | `GET /api/metrics?...` |
| `dashboard cost-series` | `GET /api/cost-series?...` |
| `dashboard machine-status` | `GET /api/machine-status?machine=...` |
| `dashboard load-status` | `GET /api/load-status?machine=...` |

Machine creation sends the exact closed request shape already accepted by the
server, plus `Content-Type: application/json` and
`X-CCUsage-Gauge-Mutation: 1`. Reads do not send the mutation header.

No new server endpoint is required. Machine replace, patch, delete, manual
refresh, and cache clearing are deferred from the initial client surface.

## Boundaries and Types

`AppCore` owns a new `DashboardAPIClient` and injectable HTTP transport. It
constructs loopback URLs, performs requests, preserves raw response bytes for
JSON output, decodes known response DTOs for text output, and converts non-2xx
responses into a typed error containing HTTP status, server error code,
message, field errors, and retry information when supplied.

The client reuses existing DTOs where their wire representation is complete.
Scope-bearing query envelopes require explicit DTOs because the router injects
`scope` after encoding the query response. Controlled wire domains such as
range, granularity, machine kind, load phase, collection state, and data quality
remain enums rather than open strings.

`AppCLI` owns all ArgumentParser command structs, option groups, validation,
and human-readable rendering. The ArgumentParser package is a dependency of
`AppCLI` only. Command types are split by responsibility rather than growing
the entry-point file.

The hand-written `AppCommand` parser is removed after parity coverage moves to
ArgumentParser parsing tests. `usage-snapshot` remains local-only.

## Output Contract

`--json` writes the successful server body to standard output. It does not
decode and re-encode query responses, so `scope` and future additive response
fields remain available to scripts.

Text output provides compact summaries:

- machine list/show: id, display name, kind, enabled state, and SSH connection
  fields;
- add: the created descriptor;
- budget: spent, configured budget, remaining/overage, reset cycle, and active
  boundary;
- recent/day/period: total cost, point count, and scope;
- metrics: totals and per-date/agent/model/machine rows;
- cost series: range, granularity, total, row count, timeline, and scope;
- machine/load status: one row per machine.

Partial aggregate scope is never silent. Text output identifies stale and
unavailable machines.

## Connection Metadata and Security

Machine list/show returns exactly the existing `MachineDescriptor` contract:
SSH host, port, user, identity-file path, extra SSH options, and remote ccusage
path. These are operationally sensitive topology metadata but are not secret
key contents. The client must never open, copy, print, or transmit the contents
of an identity file.

The API is unauthenticated loopback. Any local process able to connect to the
dashboard port can already retrieve this metadata. Documentation warns users
that JSON output may contain hostnames, usernames, and local identity-file
paths and should not be pasted into public reports without review.

## Errors and Exit Status

- `0`: success or help/version output;
- `2`: ArgumentParser usage or validation error;
- `3`: dashboard API is unreachable;
- `4`: non-5xx API rejection, including validation, conflict, and not found;
- `5`: dashboard API 5xx or snapshot/range unavailable;
- `1`: other runtime or decoding failure.

In JSON mode, a server error body is written unchanged to standard error and
standard output stays empty. Text mode renders the error code/message and sorted
field errors without raw command stderr, environment values, or credentials.

## Compatibility

The root command uses `AsyncParsableCommand`, generated help, and the existing
`Version.current`. Existing command names and options remain valid. A small
custom entry point maps parse/validation failures to the established exit code
2 instead of changing scripts to ArgumentParser's default usage status.

## Verification

- parsing and validation tests for every existing and new command;
- transport tests for URL/query construction, exact machine-create JSON,
  mutation headers, raw-body preservation, date decoding, and API errors;
- server/client round trip for add, list, and representative dashboard reads;
- renderer tests for machine and dashboard text output;
- `swiftlint`, `swift test`, `swift build`, and executable help/smoke commands.

