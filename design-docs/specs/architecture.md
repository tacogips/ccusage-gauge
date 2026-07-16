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
- `pollIntervalSeconds`: `60`; polling cadence in whole seconds.

Accordingly, a newly created file is equivalent to:

```json
{
  "ccusagePath": null,
  "defaultResetTerm": "daily",
  "dashboardPort": 18081,
  "dashboardAutostart": true,
  "pollIntervalSeconds": 60
}
```

Validation requires an executable `ccusage`, a port in `1...65535`, a positive
poll interval, and a supported default reset term. Decode and validation errors
are reported with the config path and do not mutate the file.

### Mutable state

Path: `~/.local/ccusage-gauge/state.json`

The state store owns:

- optional nonnegative `budgetUSD`;
- selected reset cycle: `daily`, `weekly`, `monthly`, or `customHours` with a
  positive hour count;
- optional `lastManualResetAt` timestamp;
- reset baseline metadata, as defined below, which makes the selected effective
  boundary explicit and stable across restarts.

State changes use an atomic replacement in the same directory. Timestamps are
encoded as ISO 8601 instants. Corrupt state is reported and must not be silently
overwritten; the UI may continue with safe in-memory defaults until the user
chooses a recovery action in a later design.

Both stores accept injected base URLs in tests. Production path resolution must
not be captured in static globals so CLI and tests can safely isolate files.

## Usage Integration and Aggregation

The process boundary accepts an executable URL, argument list, environment, and
timeout and returns stdout, stderr, and exit status. Only fixed argument arrays
are passed to `Process`; no shell command interpolation is used. A nonzero exit,
timeout, invalid JSON, or unsupported payload is a typed error suitable for UI
guidance and HTTP error mapping.

Decoders follow the observed v20.0.17 `blocks --json`, `daily --json`, and
`daily --json --by-agent` shapes. Blocks retain exact reset-boundary behavior
for the menu gauge. Detailed daily agent/model breakdowns are the dashboard's
source of truth for cost and token metrics across supported agents, including
Claude Code and Codex. `session --json --by-agent` supplies model cost and
session last-activity timestamps for the dashboard's hourly cost graph.
They ignore unknown fields and tolerate additive schema evolution, while
requiring the time and cost fields necessary for a query. Cost is aggregated by
summing model-level cost values exactly once per record; a provided aggregate
must not be added again when model details are present. Fixtures document the
accepted schema and protect against double counting.

All internal monetary calculations use `Decimal`. JSON APIs emit numeric USD
values at a documented precision; UI rounding is presentation-only.

## Reset Window and Budget Rules

### Persisted reset baseline contract

The baseline is a persisted cache of the boundary decision used to include or
exclude `ccusage` records. It is not a monetary balance, does not copy usage
cost, and must never be added to or subtracted from `ccusage` totals. Version one
stores this object in `state.json`:

- `scheduledBoundaryAt`: scheduled boundary calculated for the selected cycle;
- `manualResetAtConsidered`: the `lastManualResetAt` value considered, or
  `null`;
- `activeBoundaryAt`: the later of the scheduled boundary and
  `manualResetAtConsidered`;
- `boundaryKind`: `scheduled` or `manual`, identifying which value won;
- `cycle`: a copy of the cycle used for the calculation, including the positive
  hour value for `customHours`;
- `calendarIdentifier` and `timeZoneIdentifier`: environment used for calendar
  boundaries;
- `computedAt`: evaluation instant, used for diagnostics and expiry checks.

All baseline timestamps are ISO 8601 instants. The baseline is valid only when
its cycle, manual-reset value, calendar, time zone, and scheduled boundary match
the current evaluation context. `computedAt` never changes the cost result.

Startup loads state, chooses the persisted cycle or the configured
`defaultResetTerm`, and validates the baseline. A missing or stale baseline is
recomputed before presenting cost and atomically persisted with the state.
Advancing into a new scheduled window similarly recomputes and persists it.
Corrupt state remains an error under the state-store policy and is not repaired
silently.

`Reset now` captures one clock instant, writes it to `lastManualResetAt`, derives
the baseline from that same instant and current cycle, and atomically persists
both. A failed write leaves both prior values effective. Changing the cycle
preserves `lastManualResetAt`, recomputes all baseline fields for the new cycle,
and atomically persists the cycle and baseline. Thus a manual reset later than
the new scheduled boundary continues to win; an older manual reset does not.

Every menu-bar, CLI, and dashboard cost query uses `baseline.activeBoundaryAt`
as the lower bound after baseline validation. There is no parallel boundary
calculation at presentation or API layers. This persisted derivation ensures a
restart, cycle change, and subsequent poll all apply the same boundary contract
while `ccusage --json` remains the sole monetary source.

### Boundary calculation and aggregation

The active reset boundary is the later of the scheduled-cycle boundary and the
last manual reset instant. Calendar boundaries use the user's current calendar
and time zone:

- `daily`: start of the current local day;
- `weekly`: start of the current local week according to the active calendar;
- `monthly`: start of the current local month;
- `customHours(n)`: `n` hours before the evaluation instant.

A manual reset and cycle change follow the atomic baseline lifecycle above.
Usage before `baseline.activeBoundaryAt` is excluded. Tests use fixed clocks,
calendars, and time zones and cover exact boundaries, daylight-saving-relevant
calendar transitions, startup with valid and stale baselines, atomic manual
reset, cycle changes with older and later manual resets, and restart persistence.

Cost since reset is the sum of records in the closed interval
`[baseline.activeBoundaryAt, now]`, using each decoded record's documented
accounting timestamp. Records exactly at either bound are included; records
after `now` are excluded. Baseline metadata contributes no cost. With a positive
budget, spent is the nonnegative cost, remaining is
`max(budget - spent, 0)`, and the visual fraction is capped at 100% while the raw
over-budget amount remains available. Without a budget, the UI shows an unset
state rather than inventing a denominator.

## Menu-Bar Behavior

The status item renders a dynamic pie whose filled sector is the capped budget
fraction, followed by formatted USD cost since reset. Its menu exposes:

- budget usage as spent versus remaining, including a pie-chart presentation;
- a budget editor persisted to the mutable state file;
- `Reset now`;
- reset-cycle choices, including a positive custom-hour value;
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
- `GET /api/cost-series?granularity=hourly|daily&range=...`: filtered graph
  source rows; hourly uses session last-activity timestamps and daily uses
  exact daily agent/model breakdowns;
- `GET /api/budget`: budget, cost since reset, remaining amount, reset cycle,
  and active boundary.

Successful responses use JSON and stable field names. Bad parameters return
`400`; missing routes return `404`; `ccusage` or internal query failures return
`503` or `500` with a machine-readable error code and non-sensitive message.
No route accepts filesystem paths or executes arbitrary commands. State-changing
HTTP endpoints are out of scope for version one; budget and reset mutations
remain menu-bar actions.

Static assets are resolved in this order: an explicit development override,
SwiftPM resources in development, then resources adjacent to the packaged
executable/application bundle. Resolution is read-only and failure produces a
diagnostic response rather than exposing a directory listing. Formula and Cask
build validation must exercise their respective layouts.

## Frontend Contract

The SolidJS SPA is built by bun and produces static assets. A left sidebar
filters exact `ccusage` daily breakdown rows by model and agent. The top-right
aggregation control provides Today, Yesterday, This week, This month, and a
Custom choice that reveals From/To date calendar controls. The graph always
shows cost and provides Hourly and Daily aggregation controls, defaulting to
Hourly. The selected period and filters drive all totals, the green-bar cost
series, and daily detail;
mixed-model block costs are never used for dashboard model filtering. The SPA
reads only the same-origin JSON API, treats API failures and empty series as
first-class UI states, and does not invoke `ccusage` or access local files.

## Security and Privacy Boundaries

- The server is loopback-only and provides read-only version-one APIs.
- `ccusage` arguments are fixed and never composed through a shell.
- API errors, logs, and UI guidance exclude environment values, raw usage
  payloads, and unrelated local paths.
- Configuration and state files use user-only permissions when created where the
  platform permits it.
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

## Risks Requiring Implementation Evidence

- The exact v20.0.17 payload variants must be captured as sanitized fixtures
  before finalizing Codable contracts.
- Swift 6 actor isolation must be verified around `Process`, polling, AppKit, and
  listener lifecycle rather than bypassed with unchecked concurrency.
- Calendar and manual-reset boundary tests must establish behavior across local
  time-zone changes and daylight-saving transitions.
- Asset discovery must be tested from SwiftPM, Homebrew formula, and app-bundle
  layouts.
- The selected HTTP implementation must preserve loopback-only binding without
  regressing package and release portability.
