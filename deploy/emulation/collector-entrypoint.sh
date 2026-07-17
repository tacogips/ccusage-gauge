#!/bin/sh
set -eu

is_tmpfs() {
  awk -v path="$1" '$2 == path && $3 == "tmpfs" { found=1 } END { exit !found }' /proc/mounts
}

is_tmpfs /run/ccusage-secrets
while test ! -s /run/ccusage-secrets/id_ed25519; do sleep 0.1; done
test "$(stat -c %a /run/ccusage-secrets/id_ed25519)" = 400

mkdir -p /runtime/config/ccusage-gauge /runtime/state/ccusage-gauge /runtime/cache/ccusage-gauge
chmod 0700 /runtime/config/ccusage-gauge /runtime/state/ccusage-gauge /runtime/cache/ccusage-gauge
if test ! -e /runtime/config/ccusage-gauge/ccusage-config.json; then
  umask 077
  printf '%s\n' '{"ccusagePath":"/usr/local/bin/ccusage","defaultResetTerm":"daily","dashboardPort":18081,"dashboardAutostart":true,"pollIntervalSeconds":1,"cacheRetentionDays":365}' > /runtime/config/ccusage-gauge/ccusage-config.json
fi

export CCUSAGE_GAUGE_CONFIG_HOME=/runtime/config
export CCUSAGE_GAUGE_STATE_HOME=/runtime/state
export CCUSAGE_GAUGE_CACHE_HOME=/runtime/cache
exec /usr/local/bin/ccusage-gauge serve --port 18081
