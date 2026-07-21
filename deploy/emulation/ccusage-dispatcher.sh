#!/bin/sh
set -eu

# The dispatcher owns the execution context for both the collector and SSH
# machines. The pinned binary is never shadowed by a pricing shim.
export TZ=UTC
: "${HOME:?HOME must be explicit for ccusage emulation}"
export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mode="${CCUSAGE_EMULATION_MODE:-}"
if [ -z "$mode" ] && [ -r /etc/ccusage-emulation-mode ]; then
  mode="$(cat /etc/ccusage-emulation-mode)"
fi
if [ "${mode:-real}" = stub ]; then
  exec /usr/local/libexec/ccusage-stub "$@"
fi
exec /usr/local/bin/ccusage.real "$@"
