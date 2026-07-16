# ccusage-gauge

A macOS menu-bar cost gauge and local dashboard backed exclusively by
`ccusage --json`.

The status item shows a budget-progress pie followed by cost since the active
reset boundary. Its menu supports budget editing, manual reset, daily/weekly/
monthly/custom-hour reset cycles, Launch at Login, dashboard start/stop/open,
refresh, and quit. Missing or invalid `ccusage` configuration changes the
status icon to a warning and exposes diagnostics plus retry in an Error Details
submenu.

The SolidJS dashboard provides:

- exact per-agent and per-model rows from `ccusage daily --json --by-agent`;
- left-side model and agent filters;
- top-right Today, Yesterday, This week, This month, and Custom date controls;
- cost-over-time graph with Hourly (default) and Daily aggregation;
- selected-period cost/token totals and detailed agent/model rows;
- budget and reset-window summaries from the same AppCore snapshot.

## Development

```bash
nix develop
task build
task test
swift run ccusage-gauge --help
swift run ccusage-gauge-menubar
```

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
read-only with Nix after creation. Supported fields are `ccusagePath`,
`defaultResetTerm`, `dashboardPort`, `dashboardAutostart`, and
`pollIntervalSeconds`.

Mutable budget/reset state is stored separately at
`~/.local/ccusage-gauge/state.json` with user-only permissions. Menu actions do
not rewrite the static configuration.

The menu app searches the configured absolute `ccusagePath`, then PATH plus the
standard Apple Silicon and Intel Homebrew bin directories. An invalid explicit
path remains an error and never falls back.

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
task homebrew:formula -- 0.1.0
```

Render directly into the default sibling tap checkout:

```bash
task homebrew:tap-formula -- 0.1.0
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
task homebrew:cask -- 0.1.0
```

For a tagged release, build, upload, and render the tap Cask:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  task release:homebrew-cask-local -- v0.1.0
```

See `packaging/homebrew/README.md` and `.agents/skills/` for release workflows.
