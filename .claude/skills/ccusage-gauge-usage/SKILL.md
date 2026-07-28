---
name: ccusage-gauge-usage
description: Use when operating ccusage-gauge as an end user — starting the dashboard or menu-bar app, registering local/remote machines, configuring per-machine Codex/Claude session-source directories, querying usage via the client CLI or HTTP API, or diagnosing collection problems.
---

# Using ccusage-gauge

ccusage-gauge shows AI coding-agent usage costs from `ccusage --json` as a
macOS menu-bar gauge and a local web dashboard, aggregated per machine.

## Start and stop

```bash
ccusage-gauge serve                 # dashboard at http://127.0.0.1:18081
ccusage-gauge serve --port 18090    # explicit port
ccusage-gauge usage-snapshot --json # one-shot local snapshot (exit 1 + JSON error on failure)
open /Applications/CCUsage\ Gauge.app   # menu-bar app (Homebrew Cask install)
```

The menu-bar app can also start/stop the dashboard from its menu. Config lives
in `~/.config/ccusage-gauge/ccusage-config.json`, machine registry in
`~/.config/ccusage-gauge/machines.json`, caches under
`~/.cache/ccusage-gauge/`, logs under `~/.local/ccusage-gauge/logs/`.

## Machines

Every install has the synthetic `local` machine; SSH machines are registered
by id. All mutations need header `X-CCUsage-Gauge-Mutation: 1` on the API, or
use the CLI which sends it automatically.

```bash
ccusage-gauge client machines list
ccusage-gauge client machines show <id>
ccusage-gauge client machines add <id> --host <host> --user <user> \
  [--identity-file <path>] [--remote-ccusage-path <path>]
ccusage-gauge client machines test-connection <id>
ccusage-gauge client machines refresh <id>
```

API equivalents: `GET/POST /api/machines`, `GET/PATCH/DELETE
/api/machines/<id>`, `POST /api/machines/<id>/test-connection`,
`POST /api/machines/<id>/refresh`.

## Session source directories

Each machine independently declares which Codex/Claude directories feed its
usage: `codexSessionDirs` and `claudeConfigDirs` (lists, absolute or
`~`-prefixed paths), plus `includeDefaultCodexDir` / `includeDefaultClaudeDir`
for the default `~/.codex` / `~/.claude` (or `CODEX_HOME` /
`CLAUDE_CONFIG_DIR`) locations. Usage from all configured directories of a
machine is summed into that machine's row. SSH machines resolve paths on the
remote host; a not-yet-existing directory contributes no usage rather than
erroring.

```bash
# Aggregate several Docker-bound codex dirs into one machine row.
ccusage-gauge client machines update <id> \
  --codex-session-dir /srv/codex-a --codex-session-dir /srv/codex-b \
  --exclude-default-codex-dir

# Same over HTTP (tri-state PATCH: omitted fields stay unchanged).
curl -X PATCH http://127.0.0.1:18081/api/machines/<id> \
  -H 'Content-Type: application/json' -H 'X-CCUsage-Gauge-Mutation: 1' \
  -d '{"codexSessionDirs":["/srv/codex-a","/srv/codex-b"],"includeDefaultCodexDir":false}'
```

- `--clear-codex-session-dirs` / `--clear-claude-config-dirs` empty a list.
- Changes apply WITHOUT restarting: the collector rebuilds the machine's
  source plan, drops caches from the old configuration, and recollects. The
  dashboard briefly shows a loading state for that machine while it does.
- To track directories on one host separately, register the host as multiple
  logical machines with disjoint dirs and defaults disabled where needed.
- Validation errors use indexed field names, e.g. `codexSessionDirs[0]`.

## Reading usage

```bash
ccusage-gauge client dashboard budget  [--machine <id|all>]
ccusage-gauge client dashboard recent  [--machine <id|all>] [--limit 1..500]
ccusage-gauge client dashboard day     --date YYYY-MM-DD [--machine <id|all>]
ccusage-gauge client dashboard period  [--range today|yesterday|week|month|custom ...]
```

Key API reads (all accept `machine=<id>|all`):
`/api/metrics?range=today|...` or `?range=custom&start=...&end=...` (totals +
per-agent/model rows), `/api/day?date=...` (cost points), `/api/recent`,
`/api/budget`, `/api/cost-series?granularity=15min|hourly|6hour|daily`.

## Diagnosing problems

- Menu bar shows `!` or dashboard empty → `GET /api/machine-status`: check
  `collectionState`, `consecutiveFailureCount`, and the sanitized `lastError`.
- `GET /api/load-status` reports collection progress phases.
- Sanitized JSONL logs: `~/.local/ccusage-gauge/logs/` (no command lines or
  credentials are ever logged).
- `client machines test-connection <id>` runs only a fixed `--version` probe.
- ccusage itself must be ≥ 20.0.17 (`brew install ccusage`); the configured
  path is `ccusagePath` in the config file.

## Isolated experimentation

To try things without touching real config/state, set
`CCUSAGE_GAUGE_CONFIG_HOME`, `CCUSAGE_GAUGE_STATE_HOME`, and
`CCUSAGE_GAUGE_CACHE_HOME` to scratch directories before launching (see
`.claude/skills/verify/SKILL.md` for a full recipe including a fake ccusage).
