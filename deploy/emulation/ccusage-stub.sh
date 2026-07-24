#!/bin/sh
set -eu

# Emulated ccusage. Emits a single fixed-day record whose cost/model is derived
# from the machine seed. It honors --since/--until so that the collector's
# month-partitioned historical range queries do not each return the same record
# (which would duplicate usage in the aggregate). Real ccusage filters by range.

seed="${MACHINE_SEED:-$(cat /etc/ccusage-machine-seed 2>/dev/null || printf 0)}"
day="2026-07-17"
command="${1:-}"
shift || true

since=""
until_=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --since) since="${2:-}"; shift 2 || shift ;;
    --until) until_="${2:-}"; shift 2 || shift ;;
    *) shift ;;
  esac
done

d=$(printf '%s' "$day" | tr -d -)
in_range=1
if [ -n "$since" ]; then
  s=$(printf '%s' "$since" | tr -d -)
  [ "$d" -lt "$s" ] && in_range=0
fi
if [ -n "$until_" ]; then
  u=$(printf '%s' "$until_" | tr -d -)
  [ "$d" -gt "$u" ] && in_range=0
fi

case "$command" in
  --version)
    printf 'ccusage 20.0.17\n'
    ;;
  blocks)
    if [ "$in_range" -eq 1 ]; then
      printf '{"blocks":[{"startTime":"2026-07-17T00:00:00.000Z","costUSD":%s,"models":["emulated-model-%s"]}]}' "$seed" "$seed"
    else
      printf '{"blocks":[]}'
    fi
    ;;
  daily)
    if [ "$in_range" -eq 1 ]; then
      printf '{"daily":[{"period":"2026-07-17","totalCost":%s,"modelsUsed":["emulated-model-%s"],"agents":[{"agent":"codex","modelBreakdowns":[{"modelName":"emulated-model-%s","cost":%s,"inputTokens":%s,"outputTokens":1,"cacheCreationTokens":0,"cacheReadTokens":0}]}]}]}' "$seed" "$seed" "$seed" "$seed" "$seed"
    else
      printf '{"daily":[]}'
    fi
    ;;
  session)
    if [ "$in_range" -eq 1 ]; then
      printf '{"session":[{"agent":"codex","metadata":{"lastActivity":"2026-07-17T00:00:00.000Z"},"modelBreakdowns":[{"modelName":"emulated-model-%s","cost":%s,"inputTokens":%s,"outputTokens":1,"cacheCreationTokens":0,"cacheReadTokens":0}]}]}' "$seed" "$seed" "$seed"
    else
      printf '{"session":[]}'
    fi
    ;;
  *)
    printf 'unsupported command\n' >&2
    exit 2
    ;;
esac
