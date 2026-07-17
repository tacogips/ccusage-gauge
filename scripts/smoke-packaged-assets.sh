#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
layout=all
missing=false
while (($#)); do
  case "$1" in
    --layout) layout="$2"; shift 2 ;;
    --expect-missing-diagnostics) missing=true; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
case "$layout" in swiftpm|formula|cask|all) ;; *) echo "invalid layout: $layout" >&2; exit 2 ;; esac

source_assets="$project_root/frontend/dist"
test -f "$source_assets/index.html"
build_dir="$(swift build --show-bin-path)"
source_binary="$build_dir/ccusage-gauge"
root="$(mktemp -d)"
pid=""
cleanup() { if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" || true; wait "$pid" || true; fi; rm -rf "$root"; }
trap cleanup EXIT INT TERM

fake="$root/ccusage"
printf '%s\n' '#!/usr/bin/env bash' "printf '%s' '{\"blocks\":[]}'" >"$fake"
chmod +x "$fake"
mkdir -p "$root/config/ccusage-gauge"
chmod 0700 "$root" "$root/config" "$root/config/ccusage-gauge"
cat >"$root/config/ccusage-gauge/ccusage-config.json" <<JSON
{"ccusagePath":"$fake","defaultResetTerm":"daily","dashboardPort":18082,"dashboardAutostart":false,"pollIntervalSeconds":60}
JSON
chmod 0600 "$root/config/ccusage-gauge/ccusage-config.json"
export CCUSAGE_GAUGE_CONFIG_HOME="$root/config" CCUSAGE_GAUGE_STATE_HOME="$root/state"

probe() {
  local name="$1" binary="$2" asset_root="$3"
  if ! $missing; then mkdir -p "$asset_root"; cp -R "$source_assets"/. "$asset_root"/; else rm -rf "$asset_root"; fi
  "$binary" serve --port 18082 >"$root/$name.log" 2>&1 & pid=$!
  for _ in {1..80}; do curl -fsS http://127.0.0.1:18082/api/health >/dev/null 2>&1 && break; sleep .1; done
  if $missing; then
    code="$(curl -sS -o "$root/body" -w '%{http_code}' http://127.0.0.1:18082/)"
    test "$code" = 503; grep -q assets_missing "$root/body"
  else
    curl -fsS http://127.0.0.1:18082/ | grep -q ccusage-gauge
  fi
  kill -TERM "$pid"; wait "$pid"; pid=""
  ! curl -fsS http://127.0.0.1:18082/api/health >/dev/null 2>&1
}

run_layout() {
  local name="$1" stage="$root/$1"
  case "$name" in
    swiftpm)
      mkdir -p "$stage/bin"; cp "$source_binary" "$stage/bin/ccusage-gauge"
      probe "$name" "$stage/bin/ccusage-gauge" "$stage/bin/ccusage-gauge_ccusage-gauge.bundle/Web" ;;
    formula)
      mkdir -p "$stage/bin"; cp "$source_binary" "$stage/bin/ccusage-gauge"
      probe "$name" "$stage/bin/ccusage-gauge" "$stage/share/ccusage-gauge/web" ;;
    cask)
      mkdir -p "$stage/CCUsageGauge.app/Contents/MacOS"; cp "$source_binary" "$stage/CCUsageGauge.app/Contents/MacOS/ccusage-gauge"
      probe "$name" "$stage/CCUsageGauge.app/Contents/MacOS/ccusage-gauge" "$stage/CCUsageGauge.app/Contents/Resources/Web" ;;
  esac
}

if [[ "$layout" = all ]]; then for value in swiftpm formula cask; do run_layout "$value"; done; else run_layout "$layout"; fi
echo "packaged asset smoke passed: layout=$layout missing=$missing"
