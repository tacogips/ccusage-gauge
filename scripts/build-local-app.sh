#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${CCUSAGE_GAUGE_LOCAL_APP:-$project_root/.build/CCUsageGauge.app}"
version="${CCUSAGE_GAUGE_VERSION:-$(tr -d '[:space:]' < "$project_root/VERSION")}"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Web"

swift build --package-path "$project_root" --product ccusage-gauge-menubar >/dev/null
bin_dir="$(swift build --package-path "$project_root" --show-bin-path)"
cp "$bin_dir/ccusage-gauge-menubar" "$app/Contents/MacOS/ccusage-gauge-menubar"
chmod 0755 "$app/Contents/MacOS/ccusage-gauge-menubar"
cp "$project_root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp -R "$project_root/Sources/AppCore/Resources/Web"/. "$app/Contents/Resources/Web"/

cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>CCUsage Gauge</string>
  <key>CFBundleExecutable</key><string>ccusage-gauge-menubar</string>
  <key>CFBundleIdentifier</key><string>com.tacogips.ccusage-gauge.debug</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>CCUsageGauge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>LSUIElement</key><true/>
  <key>LSEnvironment</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

plutil -lint "$app/Contents/Info.plist" >/dev/null
codesign --force --sign - "$app" >/dev/null
printf 'built local app at %s\n' "$app"
