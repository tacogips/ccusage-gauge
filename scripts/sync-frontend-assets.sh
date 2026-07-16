#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_root="$project_root/frontend/dist"
destination="$project_root/Sources/AppCore/Resources/Web"

test -f "$source_root/index.html"
rm -rf "$destination"
mkdir -p "$destination"
cp -R "$source_root"/. "$destination"/
