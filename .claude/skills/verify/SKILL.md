# Verify ccusage-gauge changes end-to-end

Runtime verification recipe for the dashboard server and CLI. The whole app can
run fully isolated with a fake `ccusage` — no real usage data or user config is
touched.

## Isolated runtime

These env vars redirect all persistence (see `scripts/smoke-*.sh` for prior art):

```bash
CCUSAGE_GAUGE_CONFIG_HOME=$ROOT/config   # ccusage-config.json, machines.json
CCUSAGE_GAUGE_STATE_HOME=$ROOT/state
CCUSAGE_GAUGE_CACHE_HOME=$ROOT/cache     # aggregates-<machine>.sqlite3
CODEX_HOME=$ROOT/codex-default           # "default" codex dir for the process
CLAUDE_CONFIG_DIR=$ROOT/claude-default   # "default" claude dir
```

Write `$ROOT/config/ccusage-gauge/ccusage-config.json` pointing `ccusagePath`
at a fake executable, then:

```bash
"$(swift build --show-bin-path)/ccusage-gauge" serve --port 18090 --assets frontend/dist
curl -fsS http://127.0.0.1:18090/api/health   # readiness
```

## Fake ccusage that reveals which dirs were read

Make the stub's output depend on `CODEX_HOME` / `CLAUDE_CONFIG_DIR` (the app
overrides these per source invocation, poisoning the other agent's var with
`/dev/null/ccusage-gauge-disabled-*`). Put a `cost.txt` marker in each fixture
dir and have the stub emit that cost — totals then prove exactly which dirs
were aggregated. Log every call (`echo "$CODEX_HOME $*" >> calls.log`) to see
the per-source fan-out. Handle `--version`, `blocks`, `daily --json --sections
daily,session`, `session`. Copy the JSON shapes from
`scripts/smoke-dashboard.sh`.

Gotcha: use FIXED block `startTime`s (e.g. today T03:00:00Z). Relative
"minutes ago" timestamps mint new cost points every collection cycle and fake
an inflation bug that isn't there.

Gotcha: real ccusage (20.0.x) HARD-ERRORS (exit 1, `CliError: No valid Claude
data directories found`) when `CODEX_HOME`/`CLAUDE_CONFIG_DIR` points at a
nonexistent path; a directory that exists but has an empty `sessions/` /
`projects/` substructure yields empty data with exit 0. Make the stub exit 1
on nonexistent dirs too — a lenient stub hid exactly this integration break
once. After API-level checks pass, also launch the real menu-bar app
(`task app:run`) against the real ccusage at least once.

## Useful endpoints

- `GET /api/machines`, `GET /api/machines/<id>` — machine round-trip
- `PATCH /api/machines/<id>` — needs headers `Content-Type: application/json`
  and `X-CCUsage-Gauge-Mutation: 1` (403 without). A source-config PATCH
  triggers re-collection by itself; no refresh call needed.
- `GET "/api/metrics?machine=local&since=YYYY-MM-DD&until=YYYY-MM-DD"` —
  authoritative cost/token totals and per-agent rows
- `GET "/api/day?machine=local&date=YYYY-MM-DD"` — blocks-based cost points

CLI against the running server: `client machines show|add|update <id>
--api-port 18090` (not `--port`).

## Flows worth driving

- Configure multiple `codexSessionDirs` + `includeDefaultCodexDir=false`,
  check `/api/metrics` totals equal the sum of exactly those dirs' fixtures.
- Flip back to defaults; totals should return to the default dirs' values.
- Probes: relative path → 422 with `codexSessionDirs[0]` field error; explicit
  JSON `null` field → 200 (treated as omitted); unknown key → 400; missing
  mutation header → 403.
