#!/usr/bin/env bash
# Required, host-data-backed remote proof. Logs aggregates only.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose_file="$root/deploy/emulation/compose.yaml"
project="ccusage-gauge-real-$$"
run="$(mktemp -d "${TMPDIR:-/tmp}/ccusage-gauge-real.XXXXXX")"
manifest="$(mktemp "${TMPDIR:-/tmp}/ccusage-gauge-manifest.XXXXXX")"
day="${CCUSAGE_SMOKE_UTC_DAY:-2026-07-16}"
source="${CLAUDE_CONFIG_DIR:-${HOME:?HOME is required}/.claude}"
fail() { printf 'real smoke failed: %s\n' "$1" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || fail "missing prerequisite: $1"; }
snapshot() {
  # Keep stdin attached to porcelain data: a heredoc would replace it.
  git -C "$root" status --porcelain=v1 -z --untracked-files=all | python3 -c '
import hashlib, os, sys
r, o = sys.argv[1:]
records = sys.stdin.buffer.read().split(b"\0")
out = []; i = 0
while i < len(records) and records[i]:
    record = records[i]; status = record[:2]; paths = [record[3:]]
    if status[:1] in b"RC" and i + 1 < len(records):
        i += 1; paths.append(records[i])
    for path in paths:
        name = path.decode("utf-8", "surrogateescape"); full = os.path.join(r, name)
        if os.path.islink(full): value = b"L" + os.readlink(full).encode("utf-8", "surrogateescape")
        elif os.path.isfile(full):
            with open(full, "rb") as f: value = b"F" + f.read()
        elif os.path.exists(full): value = b"D"
        else: value = b"M"
        out.append((status.decode("ascii"), name, hashlib.sha256(value).hexdigest()))
    i += 1
open(o, "w", encoding="utf-8").write(repr(out))
' "$root" "$1"
}
cleanup() {
  status=$?
  if test "$status" -ne 0; then
    docker compose --project-name "$project" -f "$compose_file" logs --no-color --tail 80 collector >&2 || true
    docker compose --project-name "$project" -f "$compose_file" logs --no-color --tail 80 machine-b >&2 || true
  fi
  docker compose --project-name "$project" -f "$compose_file" down --volumes --remove-orphans --rmi local >/dev/null 2>&1 || status=1
  docker ps -a --format '{{.Names}}' | awk -v prefix="${project}-" 'index($0, prefix) == 1 { found=1 } END { exit !found }' && status=1 || true
  docker volume ls --format '{{.Name}}' | awk -v prefix="${project}_" 'index($0, prefix) == 1 { found=1 } END { exit !found }' && status=1 || true
  docker images --format '{{.Repository}}' | awk -v prefix="${project}-" 'index($0, prefix) == 1 { found=1 } END { exit !found }' && status=1 || true
  current="$(mktemp "${TMPDIR:-/tmp}/ccusage-gauge-current.XXXXXX")"; snapshot "$current" || status=1
  cmp -s "$manifest" "$current" || status=1
  chmod -R u+w "$run" 2>/dev/null || status=1
  rm -f "$current" "$manifest"
  rm -rf "$run"
  git -C "$root" diff --cached --quiet || status=1
  trap - EXIT; exit "$status"
}
trap cleanup EXIT
require docker; require python3; test -x /usr/bin/ssh || fail '/usr/bin/ssh is unavailable'
docker compose version >/dev/null 2>&1 || fail 'Docker Compose is unavailable'; docker info >/dev/null 2>&1 || fail 'Docker Engine is unavailable'
[[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail 'invalid fixed UTC day'
snapshot "$manifest"; mkdir -p "$run/fixtures"
chmod 0711 "$run"
chmod 0700 "$run/fixtures"
python3 - "$source" "$day" "$run/fixtures" <<'PY'
import json, os, pathlib, sys
src,day,dst=map(pathlib.Path,sys.argv[1:]); chosen=[]
if not src.is_dir(): raise SystemExit('Claude fixture root is unavailable')
for f in src.rglob('*.jsonl'):
 kept=[]
 try:
  for line in f.read_text(encoding='utf-8').splitlines():
   o=json.loads(line); m=o.get('message',{}); u=m.get('usage',{}) if isinstance(m,dict) else {}
   timestamp = str(o.get('timestamp', ''))
   if timestamp.endswith('Z'): timestamp = timestamp[:-1] + '+00:00'
   is_fixed_utc_day = __import__('datetime').datetime.fromisoformat(timestamp).astimezone(__import__('datetime').timezone.utc).date().isoformat() == str(day)
   if is_fixed_utc_day and m.get('role')=='assistant' and isinstance(m.get('model'),str) and m['model'] and all(isinstance(u.get(k),int) and u[k]>=0 for k in ('input_tokens','output_tokens','cache_creation_input_tokens','cache_read_input_tokens')):
    kept.append(json.dumps(o,separators=(',',':')))
    if len(kept)>500: break
 except (OSError, UnicodeError, ValueError, json.JSONDecodeError): continue
 if kept and len(kept)<=500: chosen.append((f,kept))
 if len(chosen)==2: break
if len(chosen)!=2: raise SystemExit('need two disjoint nonempty validated fixed-day files')
for name,(f,lines) in zip(('local','machine-a'),chosen):
 d=dst/name/'projects'/'fixed'; d.mkdir(parents=True); target=d/(f.stem+'.jsonl'); target.write_text('\n'.join(lines)+'\n'); os.chmod(target,0o644); print(f'{name}: assistant_events={len(lines)}')
(dst/'machine-b'/'projects').mkdir(parents=True)
PY
chmod -R a-w "$run/fixtures"
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
export CCUSAGE_REAL_DAY="$day" CCUSAGE_EMULATION_MODE=real
docker compose --project-name "$project" -f "$compose_file" --profile real build --pull
compose=(docker compose --project-name "$project" -f "$compose_file")
"${compose[@]}" --profile real create
"${compose[@]}" cp "$run/fixtures/local/." collector:/home/collector/.claude
"${compose[@]}" cp "$run/fixtures/machine-a/." machine-a:/home/ccusage/.claude
"${compose[@]}" cp "$run/fixtures/machine-b/." machine-b:/home/ccusage/.claude
"${compose[@]}" --profile real start
for _ in $(seq 1 100); do
  "${compose[@]}" exec -T keygen test -s /run/ccusage-keygen/id_ed25519.pub && break
  sleep 0.1
done
"${compose[@]}" exec -T keygen test -s /run/ccusage-keygen/id_ed25519
"${compose[@]}" exec -T keygen cat /run/ccusage-keygen/id_ed25519 \
  | "${compose[@]}" exec -T collector sh -c 'umask 077; cat > /run/ccusage-secrets/id_ed25519; chmod 0400 /run/ccusage-secrets/id_ed25519'
for machine in machine-a machine-b; do
  "${compose[@]}" exec -T keygen cat /run/ccusage-keygen/id_ed25519.pub \
    | "${compose[@]}" exec -T "$machine" sh -c 'umask 077; cat > /run/ccusage-auth/authorized_keys; chmod 0600 /run/ccusage-auth/authorized_keys'
done
for _ in $(seq 1 120); do
  "${compose[@]}" exec -T collector curl --fail-with-body --silent http://127.0.0.1:18081/api/health >/dev/null 2>&1 && break
  sleep 0.25
done
"${compose[@]}" exec -T collector curl --fail-with-body --silent --show-error http://127.0.0.1:18081/api/health >/dev/null
register_machine() {
  local id="$1" port
  port="$("${compose[@]}" port "$id" 22 | awk -F: 'NR == 1 { print $NF }')"
  test -n "$port"
  "${compose[@]}" exec -T collector curl --fail-with-body --silent --show-error -H 'Content-Type: application/json' -H 'X-CCUsage-Gauge-Mutation: 1' \
    -X POST http://127.0.0.1:18081/api/machines \
    --data "{\"id\":\"$id\",\"displayName\":\"$id\",\"kind\":\"ssh\",\"enabled\":true,\"ssh\":{\"host\":\"host.docker.internal\",\"port\":$port,\"user\":\"ccusage\",\"identityFile\":\"/run/ccusage-secrets/id_ed25519\",\"extraOptions\":[\"-o ConnectTimeout=5\",\"-o StrictHostKeyChecking=accept-new\",\"-o UserKnownHostsFile=/run/ccusage-secrets/known_hosts\"],\"remoteCcusagePath\":\"ccusage\"}}" >/dev/null
}
register_machine machine-a
register_machine machine-b
"${compose[@]}" exec -T collector curl --fail-with-body --silent --show-error \
  -H 'X-CCUsage-Gauge-Mutation: 1' \
  'http://127.0.0.1:18081/api/refresh?machine=all' >/dev/null
python3 "$root/deploy/emulation/assert-real-parity.py" "$project" "$compose_file" "$day"
scripts/smoke-packaged-assets.sh --layout all --expect-missing-diagnostics
printf 'real smoke passed: fixed-day parity and lifecycle verified\n'
