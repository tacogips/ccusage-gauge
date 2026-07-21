#!/bin/sh
set -eu
awk '$2 == "/run/ccusage-keygen" && $3 == "tmpfs" { found=1 } END { exit !found }' /proc/mounts
umask 077
ssh-keygen -q -t ed25519 -N '' -f /run/ccusage-keygen/id_ed25519
exec tail -f /dev/null
