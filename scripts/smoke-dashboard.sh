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

fake="$root/ccusage"
cat >"$fake" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if date -u -d '5 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
  timestamp="$(date -u -d '5 minutes ago' '+%Y-%m-%dT%H:%M:%SZ')"
else
  timestamp="$(date -u -v-5M '+%Y-%m-%dT%H:%M:%SZ')"
fi
period="$(date '+%Y-%m-%d')"
case "${1:-}" in
  blocks) printf '{"blocks":[{"startTime":"%s","costUSD":1.25,"models":["claude-opus-4-8"]},{"startTime":"%s","costUSD":2.25,"models":["gpt-5.6-sol"]}]}' "$timestamp" "$timestamp" ;;
  daily) printf '{"daily":[{"period":"%s","agent":"all","agents":[{"agent":"claude","modelBreakdowns":[{"modelName":"claude-opus-4-8","cost":1.25,"inputTokens":100,"outputTokens":20,"cacheCreationTokens":40,"cacheReadTokens":200}]},{"agent":"codex","modelBreakdowns":[{"modelName":"gpt-5.6-sol","cost":2.25,"inputTokens":300,"outputTokens":60,"cacheCreationTokens":0,"cacheReadTokens":500}]}]}]}' "$period" ;;
  session) printf '{"session":[{"agent":"claude","metadata":{"lastActivity":"%s"},"modelBreakdowns":[{"modelName":"claude-opus-4-8","cost":1.25,"inputTokens":100,"outputTokens":20,"cacheCreationTokens":40,"cacheReadTokens":200}]},{"agent":"codex","metadata":{"lastActivity":"%s"},"modelBreakdowns":[{"modelName":"gpt-5.6-sol","cost":2.25,"inputTokens":300,"outputTokens":60,"cacheCreationTokens":0,"cacheReadTokens":500}]}]}' "$timestamp" "$timestamp" ;;
  *) exit 2 ;;
esac
FAKE
chmod +x "$fake"
mkdir -p "$root/config/ccusage-gauge" "$root/state/ccusage-gauge" "$root/cache/ccusage-gauge" "$root/claude/projects" "$root/codex/sessions"
cat >"$root/config/ccusage-gauge/ccusage-config.json" <<JSON
{"ccusagePath":"$fake","defaultResetTerm":"daily","dashboardPort":$port,"dashboardAutostart":false,"pollIntervalSeconds":60}
JSON

export CCUSAGE_GAUGE_CONFIG_HOME="$root/config"
export CCUSAGE_GAUGE_STATE_HOME="$root/state"
export CCUSAGE_GAUGE_CACHE_HOME="$root/cache"
export CLAUDE_CONFIG_DIR="$root/claude"
export CODEX_HOME="$root/codex"
binary="${binary:-$(swift build --show-bin-path)/ccusage-gauge}"
today="$(date '+%Y-%m-%d')"

wait_ready() {
  for _ in {1..80}; do curl -fsS "http://127.0.0.1:$port/api/health" >/dev/null 2>&1 && return 0; sleep 0.1; done
  echo "dashboard readiness timed out" >&2
  cat "$root/server.log" >&2
  return 1
}

run_once() {
  local arguments=(serve --port "$port")
  if [[ -n "$assets" ]]; then arguments+=(--assets "$assets"); fi
  "$binary" "${arguments[@]}" >"$root/server.log" 2>&1 &
  pid=$!
  wait_ready
  curl -fsS "http://127.0.0.1:$port/" | grep -q 'ccusage-gauge'
  curl -fsS "http://127.0.0.1:$port/api/recent" | grep -q '3.5'
  curl -fsS "http://127.0.0.1:$port/api/day?date=$today" | grep -q '3.5'
  curl -fsS "http://127.0.0.1:$port/api/period?range=today" | grep -q '3.5'
  curl -fsS "http://127.0.0.1:$port/api/period?range=custom&start=$today&end=$today" | grep -q '3.5'
  curl -fsS "http://127.0.0.1:$port/api/metrics?range=today" | grep -q 'gpt-5.6-sol'
  curl -fsS "http://127.0.0.1:$port/api/metrics?range=today" | grep -q 'claude-opus-4-8'
  curl -fsS "http://127.0.0.1:$port/api/cost-series?range=today&granularity=hourly" | grep -q 'gpt-5.6-sol'
  curl -fsS "http://127.0.0.1:$port/api/cost-series?range=today&granularity=daily" | grep -q 'claude-opus-4-8'
  curl -fsS "http://127.0.0.1:$port/api/budget" | grep -q 'spentUSD'
  curl -fsS -X DELETE "http://127.0.0.1:$port/api/cache" | grep -q '"status":"ok"'
  curl -fsS "http://127.0.0.1:$port/api/metrics?range=today" | grep -q 'gpt-5.6-sol'
  kill -TERM "$pid"
  wait "$pid"
  pid=""
  ! curl -fsS "http://127.0.0.1:$port/api/health" >/dev/null 2>&1
}

run_once
run_once
echo "dashboard smoke passed on 127.0.0.1:$port"
