#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
real_config="${HOME}/.config/ccusage-gauge/ccusage-config.json"
real_state="${HOME}/.local/ccusage-gauge/state.json"
fingerprint() {
  if [[ ! -e "$1" ]]; then
    echo absent
    return
  fi
  if stat -f '%p:%z:%m' "$1" >/dev/null 2>&1; then
    stat -f '%p:%z:%m' "$1"
  else
    stat -c '%a:%s:%Y' "$1"
  fi
  shasum -a 256 "$1"
}
before_config="$(fingerprint "$real_config")"
before_state="$(fingerprint "$real_state")"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT INT TERM

mkdir -p "$root/bin"
cat >"$root/bin/ccusage" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  blocks) printf '%s' '{"blocks":[{"startTime":"2026-07-15T01:00:00Z","costUSD":3.5,"models":["fixture"]}]}' ;;
  daily) printf '%s' '{"daily":[{"period":"2026-07-15","agents":[{"agent":"codex","modelBreakdowns":[{"modelName":"gpt-5.6-sol","cost":3.5,"inputTokens":10,"outputTokens":2,"cacheCreationTokens":0,"cacheReadTokens":20}]}]}]}' ;;
  session) printf '%s' '{"session":[{"agent":"codex","metadata":{"lastActivity":"2026-07-15T01:00:00Z"},"modelBreakdowns":[{"modelName":"gpt-5.6-sol","cost":3.5,"inputTokens":10,"outputTokens":2,"cacheCreationTokens":0,"cacheReadTokens":20}]}]}' ;;
  *) exit 2 ;;
esac
FAKE
chmod +x "$root/bin/ccusage"
export PATH="$root/bin:$PATH"
export CCUSAGE_GAUGE_CONFIG_HOME="$root/config"
export CCUSAGE_GAUGE_STATE_HOME="$root/state"
binary="$(swift build --show-bin-path)/ccusage-gauge"

"$binary" config-check >/dev/null
test -f "$root/config/ccusage-gauge/ccusage-config.json"
"$binary" usage-snapshot --json | grep -q 'costSinceResetUSD'
test -f "$root/state/ccusage-gauge/state.json"

marker="$root/path-fallback-invoked"
cat >"$root/bin/ccusage" <<FAKE
#!/usr/bin/env bash
touch "$marker"
exit 0
FAKE
chmod +x "$root/bin/ccusage"
cat >"$root/config/ccusage-gauge/ccusage-config.json" <<'JSON'
{"ccusagePath":"/definitely/missing/ccusage","defaultResetTerm":"daily","dashboardPort":18081,"dashboardAutostart":false,"pollIntervalSeconds":60}
JSON
set +e
output="$("$binary" config-check 2>&1)"; config_status=$?
snapshot_output="$("$binary" usage-snapshot --json 2>&1)"; snapshot_status=$?
set -e
test "$config_status" -eq 1
test "$snapshot_status" -eq 1
grep -q 'ccusage executable is unavailable' <<<"$output"
grep -q 'ccusage executable is unavailable' <<<"$snapshot_output"
test ! -e "$marker"
test "$(fingerprint "$real_config")" = "$before_config"
test "$(fingerprint "$real_state")" = "$before_state"

if [[ "${CCUSAGE_GAUGE_LIVE_SMOKE:-0}" = 1 ]]; then
  if command -v ccusage >/dev/null 2>&1; then ccusage blocks --json >/dev/null && echo "live ccusage smoke passed"; else echo "live ccusage smoke skipped: tool unavailable"; fi
else
  echo "live ccusage smoke skipped: opt-in disabled"
fi
echo "isolated runtime smoke passed"
