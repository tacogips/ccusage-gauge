#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

swift test --enable-code-coverage
coverage_output_path="$(swift test --show-codecov-path)"
profile_path="$coverage_output_path"
if [[ "$coverage_output_path" == *.json ]]; then
  profile_path="$(dirname "$coverage_output_path")/default.profdata"
fi
build_path="$(swift build --show-bin-path)"
test_binary="$(find "$build_path" -type f -perm -111 -name '*PackageTests' -print -quit)"
if [[ -z "$test_binary" ]]; then
  test_binary="$(find "$build_path" -type f -path '*.xctest/Contents/MacOS/*' -perm -111 -print -quit)"
fi
[[ -f "$profile_path" ]] || { printf 'coverage profile is unavailable\n' >&2; exit 1; }
[[ -n "$test_binary" && -x "$test_binary" ]] || { printf 'coverage test binary is unavailable\n' >&2; exit 1; }

if command -v xcrun >/dev/null 2>&1 && xcrun --find llvm-cov >/dev/null 2>&1; then
  llvm_cov=(xcrun llvm-cov)
elif command -v llvm-cov >/dev/null 2>&1; then
  llvm_cov=(llvm-cov)
else
  printf 'llvm-cov is unavailable\n' >&2
  exit 1
fi

source_files=()
while IFS= read -r source_file; do source_files+=("$source_file"); done < <(find Sources/AppCore Sources/AppCLI -type f -name '*.swift' | sort)
summary="$("${llvm_cov[@]}" export -summary-only "$test_binary" -instr-profile="$profile_path" -- "${source_files[@]}")"
python3 - "$summary" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
totals = payload["data"][0]["totals"]["lines"]
percent = float(totals["percent"])
covered = totals.get("covered", totals["count"] - totals.get("notcovered", totals["count"]))
print(f"AppCore+AppCLI executable line coverage: {percent:.2f}% ({covered}/{totals['count']})")
if percent < 80.0:
    raise SystemExit("line coverage is below the required 80.0%")
PY
