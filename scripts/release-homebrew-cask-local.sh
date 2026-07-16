#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
artifact_name="ccusage-gauge"
source_repository="tacogips/ccusage-gauge"
release_repository="tacogips/homebrew-tap"

usage() {
  cat <<EOF
Usage:
  scripts/release-homebrew-cask-local.sh v<version> [tap-cask-file]

Builds signed and notarized app archives, publishes them to the shared tap
release named ccusage-gauge-v<version>, and renders the tap Cask.

Required environment variables:
  APPLE_SIGNING_IDENTITY  Developer ID Application identity.
  APPLE_ID                Apple ID email for notarization.
  APPLE_PASSWORD          Apple app-specific password for notarization.
  APPLE_TEAM_ID           Apple Developer Team ID for notarization.
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'missing required command: %s\n' "$1" >&2
    return 1
  fi
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

release_tag="${1:-}"
tap_cask_file="${2:-$repo_root/../homebrew-tap/Casks/$artifact_name.rb}"
if [[ -z "$release_tag" || "$release_tag" != v* ]]; then
  usage >&2
  exit 1
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'error: Homebrew Cask release signing must run on macOS\n' >&2
  exit 1
fi

require_command gh
require_command git
require_command shasum

version="${release_tag#v}"
host_release_tag="$artifact_name-$release_tag"
if [[ "$(tr -d '[:space:]' < "$repo_root/VERSION")" != "$version" ]]; then
  printf 'error: VERSION does not match release tag %s\n' "$release_tag" >&2
  exit 1
fi

cd "$repo_root"
git rev-parse -q --verify "refs/tags/$release_tag" >/dev/null || {
  printf 'error: local git tag does not exist: %s\n' "$release_tag" >&2
  exit 1
}
git ls-remote --exit-code --tags origin "refs/tags/$release_tag" >/dev/null || {
  printf 'error: git tag has not been pushed to origin: %s\n' "$release_tag" >&2
  exit 1
}

scripts/build-homebrew-cask-release.sh darwin-arm64 darwin-x64

release_dir="${CASK_RELEASE_DIR:-$repo_root/dist/homebrew-cask}"
arm_zip="$release_dir/${artifact_name}_${version}_aarch64.app.zip"
intel_zip="$release_dir/${artifact_name}_${version}_x86_64.app.zip"
test -f "$arm_zip"
test -f "$intel_zip"

release_notes="Signed, notarized, and stapled CCUsage Gauge macOS app archives for Homebrew Cask. Source release: https://github.com/$source_repository/releases/tag/$release_tag"
if ! gh release view "$host_release_tag" --repo "$release_repository" >/dev/null 2>&1; then
  gh release create "$host_release_tag" \
    --repo "$release_repository" \
    --target main \
    --title "CCUsage Gauge $release_tag" \
    --notes "$release_notes"
fi

gh release upload "$host_release_tag" "$arm_zip" "$intel_zip" --repo "$release_repository" --clobber
scripts/render-homebrew-cask.sh "$version" "$tap_cask_file"

printf '\nRendered tap Cask: %s\n' "$tap_cask_file"
printf 'Install after pushing the tap update with:\n'
printf '  brew install --cask tacogips/tap/ccusage-gauge\n'
