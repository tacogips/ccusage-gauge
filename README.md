# ccusage-gauge

A cross-platform local dashboard and CLI, plus a macOS menu-bar cost gauge,
backed exclusively by `ccusage --json`.

ccusage-gauge supports ccusage 20.0.17 and later. It automatically uses the
20.0.17 `--by-agent` daily report and the flag-free daily report introduced by
ccusage 20.1.0.

The status item shows a budget-progress pie followed by cost in the selected
aggregation period. Its menu supports budget editing, hourly/daily/weekly/
monthly/custom-hour aggregation periods, Launch at Login, dashboard start/stop/open,
refresh, and quit. Missing or invalid `ccusage` configuration changes the
status icon to a warning and exposes diagnostics plus retry in an Error Details
submenu.

## Screenshots

### Menu bar

The compact status item shows current spend and budget usage at a glance.

<p align="center">
  <img src="design-docs/screenshots/menu-bar-status.png" alt="ccusage-gauge menu-bar status showing spend and budget usage" width="384">
</p>

The expanded menu provides budget, aggregation-period, refresh-interval, settings,
and dashboard controls.

<p align="center">
  <img src="design-docs/screenshots/menu-bar-menu.png" alt="ccusage-gauge expanded menu" width="608">
</p>

### Dashboard

![ccusage-gauge dashboard showing model filters, cost metrics, and hourly usage](design-docs/screenshots/dashboard.png)

## Install with Homebrew

Install the `ccusage` data source and the CCUsage Gauge Cask:

```bash
brew install ccusage
brew install --cask tacogips/tap/ccusage-gauge
```

The Cask installs the macOS menu-bar app and the `ccusage-gauge` command-line
tool. Open **CCUsage Gauge** from Applications after installation, or run
`ccusage-gauge serve` to start the local dashboard.

The SolidJS dashboard provides:

- exact per-agent and per-model rows from `ccusage daily --json --by-agent` on
  ccusage 20.0.17 and `ccusage daily --json` on ccusage 20.1.0 and later;
- left-side model and agent filters;
- top-right Last 12 hours, Today, Yesterday, This week, This month, and Custom date controls;
- cost-over-time graph with a rolling 12-hour Hourly default, 15-minute,
  6-hour, and Daily aggregation, and hover details for each bar;
- selected-period cost/token totals and detailed agent/model rows;
- budget and aggregation-period summaries from the same AppCore snapshot.
- automatic data refresh using the menu bar's effective refresh interval.
- an All machines aggregate, per-machine filtering and row attribution, SSH
  machine registration, enable/disable/remove controls, and sanitized collection
  health without exposing command, connection, or credential details.

Automatic refreshes retain the current dashboard while data loads in the
background, then replace it with the completed response without flashing the
full-page loading state. A compact `Updating…` indicator remains visible while
the background request is active.

Changing the selected data range intentionally clears the previous graph and
uses the initial loading state until the new range's metrics and graph rows are
both ready. This prevents values from the previous range appearing under the
new range label.

Changing between 15 min, Hourly, 6 hour, and Daily uses the same blocking
transition, so bars from the previous granularity are never displayed under the
new label.

The 15-minute graph reads timestamped response usage from local Claude Code and
Codex JSONL logs. Claude streaming snapshots are deduplicated by session,
request, and message ID; Codex token events are deduplicated by session and
cumulative token watermark while retaining the active turn model. Each
agent/model/day is reconciled to the authoritative
ccusage detailed daily cost using weighted input, output, cache-read,
and cache-creation usage, so its 15-minute buckets preserve the reported daily
total. The timestamp and token counts are taken from the raw event; the
sub-daily cost is a reconciled allocation rather than an amount reported
directly by the agent. Hourly and 6-hour graphs aggregate those same cached
buckets. This enables granular Fable and Opus graphs when their local response
events are present, even when the unified `ccusage session` report omits
Claude, and avoids assigning an entire Codex session total to its last activity.

Models for which neither raw timestamped events nor session rows exist remain
visible in the Models filter but are disabled and struck through for the
affected granularity. Hover a disabled model for the source-data explanation,
or select Daily to view its aggregate usage. The dashboard does not invent a
timestamp when only a daily total is available.

Concurrent dashboard API requests share one in-flight AppCore snapshot. This
avoids launching duplicate `ccusage` process groups for metrics, graph, and
budget requests during initial load and automatic refresh.

The HTTP server prewarms its snapshot at startup. Range changes reuse the last
completed snapshot immediately, while automatic and manual refreshes explicitly
replace it through `/api/refresh` before the visible resources are refetched.

Only the active period's metric and graph rows are requested by the frontend.
The Models menu omits models with no data in that period. If period data exists
but the selected graph granularity has no usable timestamped source, the model
remains visible but is disabled and struck through.

## Dashboard server (macOS and Linux)

The `ccusage-gauge` CLI runs the dashboard on both macOS and Linux. Only the
menu-bar application is macOS-specific.

Start the loopback server with:

```bash
ccusage-gauge serve
```

It binds to `127.0.0.1` and uses the configured `dashboardPort`, which defaults
to `18081`. Override the port or use a development frontend build with:

```bash
ccusage-gauge serve --port 19090 --assets frontend/dist
```

The installed Linux layout places the executable at `bin/ccusage-gauge` and
the dashboard files under `share/ccusage-gauge/web`.

## Installation with Nix (nix-darwin)

CCUsage Gauge can be installed declaratively through nix-darwin's Homebrew
integration. Homebrew must already be installed, either separately or through
a Nix Homebrew integration such as `nix-homebrew`.

Add the tap, the `ccusage` CLI used as the data source, and the CCUsage Gauge
Cask to a nix-darwin module:

```nix
{ ... }:
{
  homebrew = {
    enable = true;
    taps = [ "tacogips/tap" ];
    brews = [ "ccusage" ];
    casks = [ "tacogips/tap/ccusage-gauge" ];
  };
}
```

Apply the configuration using the configuration name defined by your flake:

```bash
darwin-rebuild switch --flake .#<configuration>
```

If the local Homebrew policy requires explicit trust for third-party taps,
trust the tap once before rebuilding:

```bash
brew trust --tap tacogips/tap
```

The repository's own `flake.nix` provides the development shell described
below; it is not the application installation package.

## Development

```bash
nix develop
task build
task test
task app:build
task app:run
swift run ccusage-gauge --help
swift run ccusage-gauge-menubar
```

`task app:build` creates an ad-hoc signed `.build/CCUsageGauge.app` bundle with
`Resources/AppIcon.icns`. `task app:run` builds and launches that menu-bar app.
Because it is an `LSUIElement` utility, it uses the icon in Finder and launch
surfaces but intentionally does not remain in the Dock.

The package uses Swift Package Manager with:

- Library target: `AppCore`
- Executable target: `AppCLI`
- Installed executable: `ccusage-gauge`
- Menu-bar executable target/product: `CCUsageGaugeMenuBar` / `ccusage-gauge-menubar`

Swift target names and type names must be valid Swift identifiers. If the project
name contains hyphens, keep `PROJECT_NAME` and `EXECUTABLE_NAME` hyphenated as
needed, but use identifier-safe values such as `AppCore`, `AppCLI`, and
`AppCommand` for Swift module/type variables.

## Configuration and state

Static configuration is created once at
`~/.config/ccusage-gauge/ccusage-config.json`. It is safe to manage this file
read-only with Nix after creation. The application does not rewrite an existing
configuration file, including one managed by Nix.

The generated defaults are:

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

| Field | Type and default | Behavior and validation |
| --- | --- | --- |
| `ccusagePath` | string or `null`; default `null` | An explicit value must be an absolute executable path. `null` searches `PATH`, `/opt/homebrew/bin`, and `/usr/local/bin`. An invalid explicit path is an error and does not fall back. |
| `defaultResetTerm` | string; default `"daily"` | Initial aggregation period when mutable state has no selection. Supported values are `"hourly"`, `"daily"`, `"weekly"`, and `"monthly"`. |
| `dashboardPort` | integer; default `18081` | Loopback port in the range `1` through `65535`. The dashboard binds to `127.0.0.1`, and **Open dashboard** opens `http://127.0.0.1:<dashboardPort>/`. |
| `dashboardAutostart` | boolean; default `true` | Starts the local dashboard server when the menu-bar application starts. |
| `pollIntervalSeconds` | integer; default `20` | Usage refresh interval in seconds. It must be positive. |
| `cacheRetentionDays` | integer; default `365` | Retains the aggregate cache for this many days from its creation time. It must be positive. Expired cache data is purged during regular snapshot refreshes and rebuilt once. |

Configuration is loaded when the application starts. After changing any field,
quit and relaunch `ccusage-gauge`; the menu's **Refresh** action refreshes usage
data but does not reload configuration. For example, to use port `19090`, set
`"dashboardPort": 19090`, relaunch the application, and choose **Open
dashboard** to open `http://127.0.0.1:19090/`.

Historical daily and timestamped event aggregates are cached at
`~/.cache/ccusage-gauge/aggregates-<machine-id>.sqlite3`. The first multi-machine
startup atomically migrates a valid legacy `aggregates.sqlite3` to
`aggregates-local.sqlite3` when no destination exists. After the initial cache build,
refreshes run the block, daily, and session queries concurrently while limiting
daily/session and raw Claude event reads to uncached and current dates. Set
`CCUSAGE_GAUGE_CACHE_HOME` to override the `.cache` root.

The cache uses the system SQLite library. Metadata, daily aggregates, and
session aggregates are stored in normalized tables and updated transactionally.

Validate the production configuration and resolved `ccusage` executable with:

```bash
ccusage-gauge config-check
```

During source development, the equivalent command is:

```bash
swift run ccusage-gauge config-check
```

Mutable budget/aggregation-period state is stored separately at
`~/.local/ccusage-gauge/state.json` with user-only permissions. Menu actions do
not rewrite the static configuration. The **Refresh interval** submenu can set
a persistent positive whole-number override in seconds or return to the
`pollIntervalSeconds` configuration default. The dashboard automatically uses
the same effective interval and adopts menu-bar interval changes after its next
refresh.

## Remote machines

`serve` always exposes the synthetic `local` machine and loads SSH descriptors
from the closed, versioned `~/.config/ccusage-gauge/machines.json` registry.
Registry creation and edits are available from the dashboard. SSH collection
executes the remote `ccusage` binary through an operator-provided forwarded port;
it does not deploy an agent, push data, or persist a cache remotely. Identity
files remain operator-managed references and are never copied into the registry.

The registry directory must be owned by the current user with mode `0700`; an
existing registry must be a regular, single-link, current-user-owned mode-`0600`
file. Unsafe metadata, malformed JSON, or invalid descriptors fail startup before
the loopback listener binds. Recovery is offline: stop the service, repair or
intentionally remove `machines.json`, then restart.

Local emulation uses standalone Docker Compose under Colima only. It creates two
SSH machines, an unprivileged collector, and one key-generation service. Client
and host private keys live only in service-scoped tmpfs mounts and are transferred
through non-logging pipes; the collector HTTP port is not published.

```bash
task emulation:config
task smoke:remote-machines
task test:coverage
```

If Colima, Docker, Compose, host-gateway, or tmpfs support is unavailable, the
smoke script reports an explicit limitation and does not claim runtime or
credential-isolation verification. Docker Swarm, file-backed Compose secrets,
host SSH mounts, credential bind mounts, and named volumes are not supported
fallbacks.

## Dashboard client commands

The `ccusage-gauge client` command tree talks to a running dashboard server over
loopback for operators and scripts that want to inspect or add SSH machines and
read the same data the dashboard shows. The server remains the only owner of the
machine registry, collection state, historical expansion, and query semantics;
the client issues plain HTTP requests to it.

Every client subcommand accepts:

- `--api-port <port>`: loopback dashboard port. When omitted, the configured
  `dashboardPort` is used (default `18081`).
- `--json`: emit the server's JSON response verbatim, preserving `scope` and any
  additive fields for scripting. Without `--json`, a compact text summary is
  printed.

The host is fixed to `127.0.0.1`; the client never targets a remote host and
does not add a remote unauthenticated control plane.

### Machines

```bash
# List registered machines (local plus SSH descriptors).
ccusage-gauge client machines list

# Show one machine.
ccusage-gauge client machines show remote-box

# Register a new SSH machine.
ccusage-gauge client machines add remote-box \
  --host box.example.internal --user ccusage \
  --display-name "Remote box" --ssh-port 22 \
  --identity-file ~/.ssh/id_ed25519 \
  --remote-ccusage-path /usr/local/bin/ccusage
```

Machine creation sends the exact closed request shape accepted by the server,
with `Content-Type: application/json` and the `X-CCUsage-Gauge-Mutation: 1`
header. Read commands never send the mutation header. Replace, patch, delete,
manual refresh, and cache clearing remain dashboard-server responsibilities and
are intentionally not exposed by the client.

SSH options that begin with a dash must use the `--ssh-option=<value>` form so
they are not mistaken for flags, for example `--ssh-option=-4` or, quoted so the
shell keeps the embedded space, `'--ssh-option=-o ConnectTimeout=10'`. The
option is repeatable.

### Dashboard reads

```bash
ccusage-gauge client dashboard budget [--machine <id|all>]
ccusage-gauge client dashboard recent [--machine <id|all>] [--limit <1...500>]
ccusage-gauge client dashboard day --date YYYY-MM-DD [--machine <id|all>]
ccusage-gauge client dashboard period [--range today|yesterday|week|month|custom]
  [--start YYYY-MM-DD --end YYYY-MM-DD] [--machine <id|all>]
ccusage-gauge client dashboard metrics [--range all|recent12h|today|yesterday|week|month|custom]
  [--start YYYY-MM-DD --end YYYY-MM-DD] [--machine <id|all>]
ccusage-gauge client dashboard cost-series [--range ...] [--granularity 15min|hourly|6hour|daily]
  [--start YYYY-MM-DD --end YYYY-MM-DD] [--machine <id|all>]
ccusage-gauge client dashboard machine-status [--machine <id|all>]
ccusage-gauge client dashboard load-status [--machine <id|all>]
```

The `--machine` value is `all` (the default aggregate), `local`, or a canonical
machine id. A `custom` range requires both `--start` and `--end`; every other
range rejects them. Dates use strict `YYYY-MM-DD`. Partial aggregate reads are
never silent: text output lists stale and unavailable machines from the response
`scope`.

Exit statuses are stable for scripting: `0` success, `2` usage/validation error,
`3` dashboard unreachable, `4` API rejection (validation, conflict, not found),
`5` API 5xx or snapshot/range unavailable, and `1` other runtime failures. In
`--json` mode a server error body is written unchanged to standard error while
standard output stays empty.

### Connection metadata and security

Machine list and show return the existing `MachineDescriptor` contract: SSH host,
port, user, identity-file path, extra SSH options, and remote ccusage path. These
are operationally sensitive topology fields but are not secret key material. The
client never opens, copies, prints, or transmits the contents of an identity
file; it only reports the path already stored in the registry.

The dashboard API is unauthenticated loopback: any local process able to reach
the dashboard port can already retrieve this metadata. JSON output may contain
hostnames, usernames, and local identity-file paths, so review it before pasting
into public reports.

## E2E testing

Build an isolated app bundle with a deterministic `ccusage` fixture:

```bash
task e2e:build -- fixture
```

The Computer Use scenarios and recorded evidence are under
`design-docs/e2e/`. E2E config and state stay below `.build/e2e` and do not touch
the operator's production files.

## Homebrew Formula

Build local formula archives:

```bash
task build:homebrew -- darwin-arm64 darwin-x64
```

Render a formula after both platform archives exist:

```bash
task homebrew:formula -- 0.1.8
```

Render directly into the default sibling tap checkout:

```bash
task homebrew:tap-formula -- 0.1.8
```

Install from the tap after the formula is published:

```bash
brew tap tacogips/tap
brew install ccusage-gauge
```

## Homebrew Cask

The Cask workflow builds signed, notarized, and stapled macOS app archives with
the project icon for Apple Silicon and Intel Macs. Release assets are hosted in
the shared `tacogips/homebrew-tap` repository, following `bifrost-gauge`.
Apple signing credentials must stay local and must not be committed.

Check the build plan:

```bash
task build:homebrew-cask -- --dry-run darwin-arm64 darwin-x64
```

Build with local signing credentials:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  task build:homebrew-cask -- darwin-arm64 darwin-x64
```

Render a Cask:

```bash
task homebrew:cask -- 0.1.8
```

For a tagged release, build, upload, and render the tap Cask:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  task release:homebrew-cask-local -- v0.1.8
```

See `packaging/homebrew/README.md` and `.agents/skills/` for release workflows.

## License

This project is available under the [MIT License](LICENSE).
