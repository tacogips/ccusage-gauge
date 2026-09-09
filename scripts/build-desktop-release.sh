#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-}" in
  darwin-arm64) rust_target=aarch64-apple-darwin ;;
  darwin-x64) rust_target=x86_64-apple-darwin ;;
  *) echo 'usage: build-desktop-release.sh darwin-arm64|darwin-x64' >&2; exit 2 ;;
esac
mise exec -- cargo build --locked --release --manifest-path "$project_root/src-tauri/Cargo.toml" --target "$rust_target" >&2
printf '%s\n' "$project_root/src-tauri/target/$rust_target/release/ccusage-gauge-dashboard"
