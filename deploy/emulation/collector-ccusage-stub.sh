#!/bin/sh
set -eu
case "${1:-}" in
  blocks) printf '{"blocks":[]}' ;;
  daily) printf '{"daily":[]}' ;;
  session) printf '{"session":[]}' ;;
  *) exit 2 ;;
esac
