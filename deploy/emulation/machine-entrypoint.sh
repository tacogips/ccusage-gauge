#!/bin/sh
set -eu

is_tmpfs() {
  awk -v path="$1" '$2 == path && $3 == "tmpfs" { found=1 } END { exit !found }' /proc/mounts
}

is_tmpfs /run/ccusage-auth
is_tmpfs /run/ccusage-hostkeys
test ! -e /run/ccusage-hostkeys/ssh_host_ed25519_key
ssh-keygen -q -t ed25519 -N '' -f /run/ccusage-hostkeys/ssh_host_ed25519_key
chown root:root /run/ccusage-hostkeys/ssh_host_ed25519_key*
chmod 0600 /run/ccusage-hostkeys/ssh_host_ed25519_key
chmod 0644 /run/ccusage-hostkeys/ssh_host_ed25519_key.pub

# sshd does not export the container ENV to a non-login `ssh <host> ccusage`
# exec session, and the SSH transport allowlist forbids SendEnv/SetEnv, so
# persist the seed to a file the ccusage stub can read during SSH collection.
printf '%s' "${MACHINE_SEED:-0}" > /etc/ccusage-machine-seed
chmod 0644 /etc/ccusage-machine-seed

while test ! -s /run/ccusage-auth/authorized_keys; do sleep 0.1; done
chown -R ccusage:ccusage /run/ccusage-auth
chmod 0700 /run/ccusage-auth
chmod 0600 /run/ccusage-auth/authorized_keys

exec /usr/sbin/sshd -D -e \
  -h /run/ccusage-hostkeys/ssh_host_ed25519_key \
  -o AuthorizedKeysFile=/run/ccusage-auth/authorized_keys \
  -o PasswordAuthentication=no \
  -o KbdInteractiveAuthentication=no \
  -o PermitRootLogin=no \
  -o AllowUsers=ccusage \
  -o UsePAM=no
