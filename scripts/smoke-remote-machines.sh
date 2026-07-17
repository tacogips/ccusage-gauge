#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose_file="$repository_root/deploy/emulation/compose.yaml"
project_name="ccusage-gauge-remote-smoke"

# Stub mode remains a fast deterministic check. Real mode is explicit and can
# never silently fall back when Docker, fixtures, or parity checks are missing.
case "${1:---stub}" in
  --real) exec "$repository_root/scripts/smoke-remote-machines-real.sh" ;;
  --stub) ;;
  *) printf 'usage: %s [--stub|--real]\n' "$0" >&2; exit 2 ;;
esac

limitation() {
  printf 'LIMITATION: remote-machine emulation not executed: %s\n' "$1" >&2
  exit 0
}

command -v colima >/dev/null 2>&1 || limitation "Colima is unavailable"
command -v docker >/dev/null 2>&1 || limitation "Docker CLI is unavailable"
command -v python3 >/dev/null 2>&1 || limitation "Python 3 is unavailable for response assertions"
docker compose version >/dev/null 2>&1 || limitation "Docker Compose is unavailable"
if ! docker info >/dev/null 2>&1; then
  colima start >/dev/null 2>&1 || limitation "Colima could not start a Docker Engine"
fi
docker info >/dev/null 2>&1 || limitation "Docker Engine is unavailable"

read -r MACHINE_A_SSH_PORT MACHINE_B_SSH_PORT < <(python3 - <<'PY'
import socket
sockets = [socket.socket() for _ in range(2)]
for sock in sockets:
    sock.bind(("127.0.0.1", 0))
print(*(sock.getsockname()[1] for sock in sockets))
for sock in sockets:
    sock.close()
PY
)
export MACHINE_A_SSH_PORT MACHINE_B_SSH_PORT

compose=(docker compose --project-name "$project_name" -f "$compose_file")
cleanup() {
  cleanup_status=$?
  "${compose[@]}" down --volumes --remove-orphans --rmi local >/dev/null 2>&1 || cleanup_status=1
  if docker ps -a --format '{{.Names}}' | grep -q "^${project_name}-"; then
    printf 'remote-machine cleanup left project containers behind\n' >&2
    cleanup_status=1
  fi
  if docker volume ls --format '{{.Name}}' | grep -q "^${project_name}_"; then
    printf 'remote-machine cleanup left project volumes behind\n' >&2
    cleanup_status=1
  fi
  if docker images --format '{{.Repository}}' | grep -q "^${project_name}-"; then
    printf 'remote-machine cleanup left project images behind\n' >&2
    cleanup_status=1
  fi
  trap - EXIT INT TERM
  exit "$cleanup_status"
}
trap cleanup EXIT INT TERM

export CCUSAGE_EMULATION_MODE=stub

"${compose[@]}" config >/dev/null
"${compose[@]}" build
"${compose[@]}" up -d

for _ in $(seq 1 100); do
  if "${compose[@]}" exec -T keygen test -s /run/ccusage-keygen/id_ed25519.pub; then break; fi
  sleep 0.1
done
"${compose[@]}" exec -T keygen test -s /run/ccusage-keygen/id_ed25519

"${compose[@]}" exec -T keygen cat /run/ccusage-keygen/id_ed25519 \
  | "${compose[@]}" exec -T collector sh -c 'umask 077; cat > /run/ccusage-secrets/id_ed25519; chmod 0400 /run/ccusage-secrets/id_ed25519'
for machine in machine-a machine-b; do
  "${compose[@]}" exec -T keygen cat /run/ccusage-keygen/id_ed25519.pub \
    | "${compose[@]}" exec -T "$machine" sh -c 'umask 077; cat > /run/ccusage-auth/authorized_keys; chmod 0600 /run/ccusage-auth/authorized_keys'
done

for service_path in \
  'keygen:/run/ccusage-keygen' \
  'collector:/run/ccusage-secrets' \
  'machine-a:/run/ccusage-auth' \
  'machine-a:/run/ccusage-hostkeys' \
  'machine-b:/run/ccusage-auth' \
  'machine-b:/run/ccusage-hostkeys'; do
  service="${service_path%%:*}"
  path="${service_path#*:}"
  "${compose[@]}" exec -T "$service" awk -v path="$path" '$2 == path && $3 == "tmpfs" { found=1 } END { exit !found }' /proc/mounts
done
"${compose[@]}" exec -T collector test "$("${compose[@]}" exec -T collector stat -c %a /run/ccusage-secrets/id_ed25519 | tr -d '\r')" = 400

fingerprint_a="$("${compose[@]}" exec -T machine-a ssh-keygen -lf /run/ccusage-hostkeys/ssh_host_ed25519_key.pub | awk '{print $2}')"
fingerprint_b="$("${compose[@]}" exec -T machine-b ssh-keygen -lf /run/ccusage-hostkeys/ssh_host_ed25519_key.pub | awk '{print $2}')"
test -n "$fingerprint_a"
test -n "$fingerprint_b"
test "$fingerprint_a" != "$fingerprint_b"

for _ in $(seq 1 120); do
  if "${compose[@]}" exec -T collector curl --fail --silent http://127.0.0.1:18081/api/health >/dev/null 2>&1; then break; fi
  sleep 0.25
done
"${compose[@]}" exec -T collector curl --fail --silent http://127.0.0.1:18081/api/health >/dev/null

register_machine() {
  local id="$1" port
  port="$("${compose[@]}" port "$id" 22 | awk -F: 'NR == 1 { print $NF }')"
  test -n "$port"
  "${compose[@]}" exec -T collector curl --fail --silent \
    -H 'Content-Type: application/json' \
    -H 'X-CCUsage-Gauge-Mutation: 1' \
    -X POST http://127.0.0.1:18081/api/machines \
    --data "{\"id\":\"$id\",\"displayName\":\"$id\",\"kind\":\"ssh\",\"enabled\":true,\"ssh\":{\"host\":\"host.docker.internal\",\"port\":$port,\"user\":\"ccusage\",\"identityFile\":\"/run/ccusage-secrets/id_ed25519\",\"extraOptions\":[\"-o ConnectTimeout=5\",\"-o StrictHostKeyChecking=accept-new\",\"-o UserKnownHostsFile=/run/ccusage-secrets/known_hosts\"],\"remoteCcusagePath\":\"ccusage\"}}" >/dev/null
}
register_machine machine-a
register_machine machine-b

# Wait until both remote machines have completed their first collection. The
# `local` machine reports healthy almost immediately, so gate on machine-a and
# machine-b specifically; querying their metrics before a snapshot exists
# correctly returns 503.
for _ in $(seq 1 120); do
  status_json="$("${compose[@]}" exec -T collector curl --fail --silent 'http://127.0.0.1:18081/api/machine-status?machine=all')"
  if printf '%s' "$status_json" | python3 -c 'import json,sys
data = json.load(sys.stdin)
healthy = {m["id"] for m in data["machines"] if m["collectionState"] == "healthy"}
sys.exit(0 if {"machine-a", "machine-b"} <= healthy else 1)'; then break; fi
  sleep 0.25
done

machine_a_json="$("${compose[@]}" exec -T collector curl --fail --silent 'http://127.0.0.1:18081/api/metrics?range=all&machine=machine-a')"
all_json="$("${compose[@]}" exec -T collector curl --fail --silent 'http://127.0.0.1:18081/api/metrics?range=all&machine=all')"
python3 - "$machine_a_json" "$all_json" <<'PY'
import json, sys
one = json.loads(sys.argv[1])
all_data = json.loads(sys.argv[2])
assert one["rows"] and all(row["machine"] == "machine-a" for row in one["rows"])
assert {row["machine"] for row in all_data["rows"]} >= {"machine-a", "machine-b"}
assert set(all_data["scope"]["includedMachineIds"]) >= {"local", "machine-a", "machine-b"}
remote_total = sum(row["costUSD"] for row in all_data["rows"] if row["machine"] != "local")
assert remote_total == 3
assert sum(row["costUSD"] for row in all_data["rows"] if row["machine"] == "local") == 0
PY

"${compose[@]}" stop machine-b >/dev/null
# Force machine-b to re-poll now so it fails fast (connection refused) and is
# marked stale, instead of waiting for the full poll interval. The single-machine
# refresh returns 503 when the only target fails, so do not use --fail here.
degraded_json=""
for _ in $(seq 1 60); do
  "${compose[@]}" exec -T collector curl --silent -o /dev/null \
    -H 'X-CCUsage-Gauge-Mutation: 1' \
    'http://127.0.0.1:18081/api/refresh?machine=machine-b' || true
  degraded_json="$("${compose[@]}" exec -T collector curl --fail --silent 'http://127.0.0.1:18081/api/metrics?range=all&machine=all')"
  if printf '%s' "$degraded_json" | python3 -c 'import json,sys
s = json.load(sys.stdin)["scope"]
sys.exit(0 if "machine-b" in s["staleMachineIds"] or "machine-b" in s["unavailableMachineIds"] else 1)'; then break; fi
  sleep 0.5
done
python3 - "$degraded_json" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
scope = data["scope"]
assert "machine-b" in scope["staleMachineIds"] or "machine-b" in scope["unavailableMachineIds"]
assert data["rows"]
assert all("machine" in row for row in data["rows"])
assert "host.docker.internal" not in json.dumps(data)
assert "id_ed25519" not in json.dumps(data)
PY

if "${compose[@]}" port collector 18081 2>/dev/null | grep -q .; then
  printf 'collector HTTP port was published\n' >&2
  exit 1
fi
if "${compose[@]}" logs 2>&1 | grep -q 'OPENSSH PRIVATE KEY'; then
  printf 'private key material entered service logs\n' >&2
  exit 1
fi
for service in keygen machine-a machine-b collector; do
  container_id="$("${compose[@]}" ps --all -q "$service")"
  if docker diff "$container_id" | grep -E 'id_ed25519|ssh_host_ed25519_key|authorized_keys' >/dev/null; then
    printf 'credential path entered the writable layer for %s\n' "$service" >&2
    exit 1
  fi
  if docker inspect --format '{{json .Config.Env}} {{json .Config.Cmd}} {{json .Config.Entrypoint}}' "$container_id" \
    | grep -q 'OPENSSH PRIVATE KEY'; then
    printf 'credential material entered environment or arguments for %s\n' "$service" >&2
    exit 1
  fi
done
if "${compose[@]}" config | grep -E '^[[:space:]]*secrets:|/\.ssh' >/dev/null; then
  printf 'compose configuration contains a forbidden secret or host SSH mount\n' >&2
  exit 1
fi
printf 'remote-machine emulation passed: local/two-remote aggregate, degraded partial state, provenance, and tmpfs credential isolation verified\n'
