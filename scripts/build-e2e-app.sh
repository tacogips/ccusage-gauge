#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(tr -d '[:space:]' < "$project_root/VERSION")"
mode="${1:-fixture}"
case "$mode" in
  fixture | missing | unreachable) ;;
  *)
    printf 'usage: %s [fixture|missing|unreachable]\n' "$0" >&2
    exit 2
    ;;
esac

output_root="${CCUSAGE_GAUGE_E2E_DIR:-$project_root/.build/e2e}"
app="$output_root/CCUsageGauge.app"
home="$output_root/home"
mock_bin="$output_root/bin/ccusage"
config="$home/config/ccusage-gauge/ccusage-config.json"
state="$home/state/ccusage-gauge/state.json"
cache="$home/cache"
claude_home="$home/claude"
codex_home="$home/codex"
machines="$(dirname "$config")/machines.json"

rm -rf "$output_root"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Web" "$output_root/bin" \
  "$(dirname "$config")" "$(dirname "$state")" "$cache" "$claude_home" "$codex_home"
chmod 0700 "$output_root" "$home" "$home/config" "$(dirname "$config")" \
  "$home/state" "$(dirname "$state")" "$cache" "$claude_home" "$codex_home"

swift build --package-path "$project_root" --product ccusage-gauge-menubar >/dev/null
bin_dir="$(swift build --package-path "$project_root" --show-bin-path)"
cp "$bin_dir/ccusage-gauge-menubar" "$app/Contents/MacOS/ccusage-gauge-menubar"
chmod 0755 "$app/Contents/MacOS/ccusage-gauge-menubar"
cp "$project_root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp -R "$project_root/Sources/AppCore/Resources/Web"/. "$app/Contents/Resources/Web"/

cat >"$mock_bin" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
first_timestamp="$(/bin/date -u -v-10M '+%Y-%m-%dT%H:%M:%SZ')"
second_timestamp="$(/bin/date -u -v-5M '+%Y-%m-%dT%H:%M:%SZ')"
case "${1:-}" in
  blocks)
    printf '{"blocks":[{"startTime":"%s","costUSD":1.25,"models":["claude-opus-4-8"]},{"startTime":"%s","costUSD":2.5,"models":["gpt-5.6-sol"]}]}' "$first_timestamp" "$second_timestamp"
    ;;
  daily)
    period="$(/bin/date '+%Y-%m-%d')"
    printf '{"daily":[{"period":"%s","agent":"all","agents":[{"agent":"claude","modelBreakdowns":[{"modelName":"claude-opus-4-8","cost":1.25,"inputTokens":100,"outputTokens":20,"cacheCreationTokens":40,"cacheReadTokens":200}]},{"agent":"codex","modelBreakdowns":[{"modelName":"gpt-5.6-sol","cost":2.5,"inputTokens":300,"outputTokens":60,"cacheCreationTokens":0,"cacheReadTokens":500}]}]}]}' "$period"
    ;;
  session)
    printf '{"session":[{"agent":"claude","metadata":{"lastActivity":"%s"},"modelBreakdowns":[{"modelName":"claude-opus-4-8","cost":1.25,"inputTokens":100,"outputTokens":20,"cacheCreationTokens":40,"cacheReadTokens":200}]},{"agent":"codex","metadata":{"lastActivity":"%s"},"modelBreakdowns":[{"modelName":"gpt-5.6-sol","cost":2.5,"inputTokens":300,"outputTokens":60,"cacheCreationTokens":0,"cacheReadTokens":500}]}]}' "$first_timestamp" "$second_timestamp"
    ;;
  *)
    printf 'unsupported fixture command\n' >&2
    exit 2
    ;;
esac
MOCK
chmod 0755 "$mock_bin"

configured_ccusage="$mock_bin"
if [[ "$mode" == missing ]]; then
  configured_ccusage="$output_root/bin/ccusage-missing"
fi
remote_settings=""
if [[ "$mode" == unreachable ]]; then
  remote_settings=$',\n  "remoteRetryCount": 0,\n  "remoteTimeoutSeconds": 1'
fi

cat >"$config" <<JSON
{
  "ccusagePath": "$configured_ccusage",
  "defaultResetTerm": "daily",
  "dashboardPort": 18081,
  "dashboardAutostart": true,
  "pollIntervalSeconds": 20$remote_settings
}
JSON
chmod 0600 "$config"

if [[ "$mode" == unreachable ]]; then
  cat >"$machines" <<'JSON'
{
  "schemaVersion": 2,
  "machines": [
    {
      "id": "unreachable",
      "displayName": "Unreachable test machine",
      "kind": "ssh",
      "enabled": true,
      "ssh": {
        "host": "192.0.2.1",
        "port": 22,
        "user": "missing",
        "extraOptions": [],
        "remoteCcusagePath": "ccusage"
      }
    }
  ]
}
JSON
  chmod 0600 "$machines"
fi

cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>CCUsageGauge E2E</string>
  <key>CFBundleExecutable</key>
  <string>ccusage-gauge-menubar</string>
  <key>CFBundleIdentifier</key>
  <string>com.tacogips.ccusage-gauge.e2e</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>CCUsageGauge</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$version</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <false/>
  <key>LSEnvironment</key>
  <dict>
    <key>CCUSAGE_GAUGE_CONFIG_HOME</key>
    <string>$home/config</string>
    <key>CCUSAGE_GAUGE_STATE_HOME</key>
    <string>$home/state</string>
    <key>CCUSAGE_GAUGE_CACHE_HOME</key>
    <string>$cache</string>
    <key>CLAUDE_CONFIG_DIR</key>
    <string>$claude_home</string>
    <key>CODEX_HOME</key>
    <string>$codex_home</string>
    <key>CCUSAGE_GAUGE_E2E_OPEN_MENU</key>
    <string>1</string>
  </dict>
</dict>
</plist>
PLIST

plutil -lint "$app/Contents/Info.plist" >/dev/null
codesign --force --sign - "$app" >/dev/null

cat >"$output_root/paths.env" <<PATHS
CCUSAGE_GAUGE_E2E_APP=$app
CCUSAGE_GAUGE_E2E_CONFIG=$config
CCUSAGE_GAUGE_E2E_STATE=$state
CCUSAGE_GAUGE_E2E_CACHE=$cache
CCUSAGE_GAUGE_E2E_MODE=$mode
PATHS

printf 'built %s mode at %s\n' "$mode" "$app"
printf 'state path: %s\n' "$state"
