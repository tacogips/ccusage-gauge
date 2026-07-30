#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
port=18081
assets="$project_root/frontend/dist"
binary=""
while (($#)); do
  case "$1" in
    --port) port="$2"; shift 2 ;;
    --assets) assets="$2"; shift 2 ;;
    --binary) binary="$2"; shift 2 ;;
    --installed-assets) assets=""; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
if [[ -n "$assets" && "$assets" != /* ]]; then assets="$project_root/$assets"; fi
if [[ -n "$binary" && "$binary" != /* ]]; then binary="$project_root/$binary"; fi

root="$(mktemp -d)"
pid=""
cleanup() {
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  rm -rf "$root"
}
trap cleanup EXIT INT TERM

> "$root/fixture-timestamp"
fake="$root/ccusage"
cat >"$fake" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
# One shared timestamp for every invocation. Recomputing it per call lets two
# source-scoped runs straddle a second boundary, which splits the cost points
# and makes the assertions below depend on timing.
timestamp="$(cat "$SMOKE_TIMESTAMP_FILE" 2>/dev/null || true)"
if [[ -z "$timestamp" ]]; then
  if date -u -d '5 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
    timestamp="$(date -u -d '5 minutes ago' '+%Y-%m-%dT%H:%M:%SZ')"
  else
    timestamp="$(date -u -v-5M '+%Y-%m-%dT%H:%M:%SZ')"
  fi
  printf '%s' "$timestamp" >"$SMOKE_TIMESTAMP_FILE"
fi
period="$(date '+%Y-%m-%d')"
# The dashboard runs one command per session source, pointing the agent that a
# source does not cover at an empty "disabled" root (see
# CCUsageCommandRunner.run(arguments:source:timeoutSeconds:)). Real ccusage
# therefore reports only the scoped agent; emitting both from every invocation
# would multiply the merged totals.
claude_enabled=1
codex_enabled=1
case "${CLAUDE_CONFIG_DIR-}" in *ccusage-gauge-disabled-claude*) claude_enabled=0 ;; esac
case "${CODEX_HOME-}" in *ccusage-gauge-disabled-codex*) codex_enabled=0 ;; esac

claude_breakdown='{"modelName":"claude-opus-4-8","cost":1.25,"inputTokens":100,"outputTokens":20,"cacheCreationTokens":40,"cacheReadTokens":200}'
codex_breakdown='{"modelName":"gpt-5.6-sol","cost":2.25,"inputTokens":300,"outputTokens":60,"cacheCreationTokens":0,"cacheReadTokens":500}'

join() { local IFS=,; printf '%s' "$*"; }

blocks=()
agents=()
sessions=()
if ((claude_enabled)); then
  blocks+=("{\"startTime\":\"$timestamp\",\"costUSD\":1.25,\"models\":[\"claude-opus-4-8\"]}")
  agents+=("{\"agent\":\"claude\",\"modelBreakdowns\":[$claude_breakdown]}")
  sessions+=("{\"agent\":\"claude\",\"metadata\":{\"lastActivity\":\"$timestamp\"},\"modelBreakdowns\":[$claude_breakdown]}")
fi
if ((codex_enabled)); then
  blocks+=("{\"startTime\":\"$timestamp\",\"costUSD\":2.25,\"models\":[\"gpt-5.6-sol\"]}")
  agents+=("{\"agent\":\"codex\",\"modelBreakdowns\":[$codex_breakdown]}")
  sessions+=("{\"agent\":\"codex\",\"metadata\":{\"lastActivity\":\"$timestamp\"},\"modelBreakdowns\":[$codex_breakdown]}")
fi

daily_rows=""
if ((${#agents[@]})); then
  daily_rows="{\"period\":\"$period\",\"agent\":\"all\",\"agents\":[$(join "${agents[@]}")]}"
fi
case "${1:-}" in
  blocks) printf '{"blocks":[%s]}' "$(join ${blocks[@]+"${blocks[@]}"})" ;;
  daily) printf '{"daily":[%s],"session":[%s]}' "$daily_rows" "$(join ${sessions[@]+"${sessions[@]}"})" ;;
  session) printf '{"session":[%s]}' "$(join ${sessions[@]+"${sessions[@]}"})" ;;
  *) exit 2 ;;
esac
FAKE
chmod +x "$fake"
mkdir -p "$root/config/ccusage-gauge" "$root/state/ccusage-gauge" "$root/cache/ccusage-gauge" "$root/claude/projects" "$root/codex/sessions"
chmod 0700 "$root/config/ccusage-gauge" "$root/state/ccusage-gauge" "$root/cache/ccusage-gauge"
cat >"$root/config/ccusage-gauge/ccusage-config.json" <<JSON
{"ccusagePath":"$fake","defaultResetTerm":"daily","dashboardPort":$port,"dashboardAutostart":false,"pollIntervalSeconds":60}
JSON

export CCUSAGE_GAUGE_CONFIG_HOME="$root/config"
export CCUSAGE_GAUGE_STATE_HOME="$root/state"
export CCUSAGE_GAUGE_CACHE_HOME="$root/cache"
export CLAUDE_CONFIG_DIR="$root/claude"
export CODEX_HOME="$root/codex"
export SMOKE_TIMESTAMP_FILE="$root/fixture-timestamp"
binary="${binary:-$(swift build --show-bin-path)/ccusage-gauge}"
today="$(date '+%Y-%m-%d')"

# A dashboard already bound to this port answers every request below with its
# own real usage data, so the assertions would describe that instance instead
# of the fixture. The default port is also the product default, which a
# developer very plausibly has running.
require_free_port() {
  # The probe runs in a subshell so its descriptor closes with the subshell;
  # closing it here with `exec` would also rewire this shell's own stderr.
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    echo "port $port is already serving; stop it or pass --port <free port>" >&2
    return 1
  fi
  return 0
}

wait_ready() {
  for _ in {1..80}; do
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
      echo "dashboard exited before becoming ready" >&2
      cat "$root/server.log" >&2
      return 1
    fi
    curl -fsS "http://127.0.0.1:$port/api/health" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  echo "dashboard readiness timed out" >&2
  cat "$root/server.log" >&2
  return 1
}

wait_for_local_snapshot() {
  for _ in {1..80}; do curl -fsS "http://127.0.0.1:$port/api/recent" >/dev/null 2>&1 && return 0; sleep 0.1; done
  echo "local snapshot readiness timed out" >&2
  cat "$root/server.log" >&2
  return 1
}

expect_total() {
  local route="$1" expected="${2:-3.5}" payload
  payload="$(curl -fsS "http://127.0.0.1:$port$route")"
  if ! grep -q "\"totalUSD\":$expected\([,}]\)" <<<"$payload"; then
    printf '%s did not report totalUSD %s: %s\n' "$route" "$expected" "$payload" >&2
    return 1
  fi
}

run_once() {
  local arguments=(serve --port "$port")
  if [[ -n "$assets" ]]; then arguments+=(--assets "$assets"); fi
  "$binary" "${arguments[@]}" >"$root/server.log" 2>&1 &
  pid=$!
  wait_ready
  wait_for_local_snapshot
  curl -fsS "http://127.0.0.1:$port/" | grep -q 'ccusage-gauge'
  # Assert the aggregate itself, not a substring that a split series can also
  # satisfy: the fixture's two sources contribute 1.25 and 2.25.
  expect_total "/api/recent"
  expect_total "/api/day?date=$today"
  expect_total "/api/period?range=today"
  expect_total "/api/period?range=custom&start=$today&end=$today"
  curl -fsS "http://127.0.0.1:$port/api/metrics?range=today" | grep -q 'gpt-5.6-sol'
  curl -fsS "http://127.0.0.1:$port/api/metrics?range=today" | grep -q 'claude-opus-4-8'
  hourly_cost_series="$(curl -fsS "http://127.0.0.1:$port/api/cost-series?range=today&granularity=hourly")"
  if ! grep -q 'gpt-5.6-sol' <<<"$hourly_cost_series"; then
    printf 'hourly cost series did not contain the expected model: %s\n' "$hourly_cost_series" >&2
    return 1
  fi
  curl -fsS "http://127.0.0.1:$port/api/cost-series?range=today&granularity=daily" | grep -q 'claude-opus-4-8'
  curl -fsS "http://127.0.0.1:$port/api/budget" | grep -q 'spentUSD'
  cache_clear_response="$(curl -fsS \
    -H 'X-CCUsage-Gauge-Mutation: 1' \
    -H "Origin: http://127.0.0.1:$port" \
    -H 'Sec-Fetch-Site: same-origin' \
    -X DELETE "http://127.0.0.1:$port/api/cache")"
  grep -q '"outcome":"complete"' <<<"$cache_clear_response"
  grep -q '"local"' <<<"$cache_clear_response"
  wait_for_local_snapshot
  curl -fsS "http://127.0.0.1:$port/api/metrics?range=today" | grep -q 'gpt-5.6-sol'
  kill -TERM "$pid"
  wait "$pid"
  pid=""
  ! curl -fsS "http://127.0.0.1:$port/api/health" >/dev/null 2>&1
}

require_free_port
run_once
run_once
echo "dashboard smoke passed on 127.0.0.1:$port"
