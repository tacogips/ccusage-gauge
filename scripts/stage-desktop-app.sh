#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="${1:?usage: stage-desktop-app.sh <host-app-Contents-directory>}"
dashboard_app="$destination/Helpers/CCUsageGaugeDashboard.app"
version="${CCUSAGE_GAUGE_VERSION:-$(tr -d '[:space:]' < "$project_root/VERSION")}"

mkdir -p "$dashboard_app/Contents/MacOS" "$dashboard_app/Contents/Resources"
cp "${CCUSAGE_GAUGE_DESKTOP_BINARY:-$project_root/src-tauri/target/release/ccusage-gauge-dashboard}" "$dashboard_app/Contents/MacOS/ccusage-gauge-dashboard"
cp "$project_root/Resources/AppIcon.icns" "$dashboard_app/Contents/Resources/AppIcon.icns"
cp "$project_root/Resources/DashboardInfo.plist" "$dashboard_app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$dashboard_app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$dashboard_app/Contents/Info.plist"
plutil -lint "$dashboard_app/Contents/Info.plist" >/dev/null
if [[ "${CCUSAGE_GAUGE_SKIP_ADHOC_SIGN:-0}" != 1 ]]; then
  codesign --force --sign - "$dashboard_app" >/dev/null
fi
