#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
artifact_name="ccusage-gauge"

usage() {
  cat <<EOF
Usage:
  scripts/render-homebrew-cask.sh <version> [output-file]

Reads archive checksums from:
  dist/homebrew-cask/${artifact_name}_<version>_<arch>.app.zip.sha256

Environment:
  CASK_RELEASE_DIR       Directory containing archives and .sha256 files.
  CASK_RELEASE_BASE_URL  Release URL base. Defaults to the shared tap release.

This renderer expects Developer ID signed, notarized, and stapled app archives.
EOF
}

sha_for_arch() {
  local version arch release_dir sha_file
  version="$1"
  arch="$2"
  release_dir="$3"
  sha_file="$release_dir/${artifact_name}_${version}_${arch}.app.zip.sha256"
  if [[ ! -f "$sha_file" ]]; then
    printf 'missing checksum file: %s\n' "$sha_file" >&2
    return 1
  fi
  awk '{print $1}' "$sha_file"
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    return
  fi
  if [[ -z "${1:-}" ]]; then
    usage
    return 2
  fi

  local version output release_dir release_base_url arm_sha intel_sha
  version="$1"
  output="${2:-$repo_root/Casks/$artifact_name.rb}"
  release_dir="${CASK_RELEASE_DIR:-$repo_root/dist/homebrew-cask}"
  release_base_url="${CASK_RELEASE_BASE_URL:-https://github.com/tacogips/homebrew-tap/releases/download/${artifact_name}-v$version}"
  arm_sha="$(sha_for_arch "$version" aarch64 "$release_dir")"
  intel_sha="$(sha_for_arch "$version" x86_64 "$release_dir")"

  mkdir -p "$(dirname "$output")"
  cat > "$output" <<EOF
cask "ccusage-gauge" do
  arch arm: "aarch64", intel: "x86_64"

  version "$version"
  sha256 arm:   "$arm_sha",
         intel: "$intel_sha"

  url "$release_base_url/${artifact_name}_#{version}_#{arch}.app.zip"
  name "CCUsage Gauge"
  desc "Menu bar gauge and local dashboard for AI coding-agent usage costs"
  homepage "https://github.com/tacogips/ccusage-gauge"

  livecheck do
    skip "Release assets are hosted in the shared tap repository"
  end

  depends_on macos: :sonoma

  app "CCUsageGauge.app"
  binary "#{appdir}/CCUsageGauge.app/Contents/MacOS/ccusage-gauge", target: "ccusage-gauge"

  caveats do
    <<~EOS
      CCUsage Gauge reads usage data from the ccusage command. Install ccusage
      separately and configure an absolute path when it is not discoverable on PATH:

        ~/.config/ccusage-gauge/ccusage-config.json

      The app is signed and notarized with Apple Developer ID.
    EOS
  end
end
EOF
  printf 'rendered %s\n' "$output"
}

main "$@"
