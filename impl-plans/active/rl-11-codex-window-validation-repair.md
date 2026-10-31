# rl-11: Repair - Codex Live Window Validation Must Report invalid_response

**Status**: Planned
**Wave**: 1 of the continuation run (runs in parallel with rl-09)
**Depends on**: none in this run (repairs rl-06 baseline code)
**Design Reference**: `design-docs/specs/design-subscription-rate-limits.md`,
section "Derived Model" (`usedPercent` must be finite and non-negative,
otherwise the result is `invalid_response`)

## Intent and Context

Review of the rl-06 baseline against the accepted design found one concrete
defect. In `Sources/AppCore/RateLimitUsageCodex.swift`, `CodexWindow.window(now:)`
builds the window with `try? RateLimitWindow(...)`. A live Codex window that has
both `used_percent` and `limit_window_seconds` but invalid values, such as a
negative `used_percent` or a non-positive `limit_window_seconds`, is therefore
silently dropped. The design says such a response is `invalid_response`. The
Claude fetcher already does this correctly: `RateLimitUsageClaude.swift:42`
uses `try`, and the error is mapped to `invalidResponse` at line 37.

The concrete failure: `{"rate_limit":{"primary_window":{"used_percent":-5,"limit_window_seconds":18000}}}`
returns an observation with no windows and status `ok`, instead of throwing
`RateLimitErrorCode.invalidResponse`. That lets the service fall back to
last-good or JSONL data.

## Non-Goals

- **No change to the session fallback.**
  `RateLimitUsageCodexSessionFallback.swift` must keep dropping bad events,
  because the rl-06 contract says the fallback never throws.
- **Missing fields keep today's behavior.** A window missing `used_percent`
  or `limit_window_seconds` still yields no window and no throw. The existing
  test `{"rate_limit":{"primary_window":{"used_percent":1}}}` must still return
  empty windows.
- **No other changes.** Do not touch credential handling, headers, URLs,
  status mapping, classification, or any other file.
- **No git operations, and no `mise run build`.**

## writePaths

- `Sources/AppCore/RateLimitUsageCodex.swift`
- `Tests/AppCoreTests/RateLimitUsageCodexTests.swift`
- `impl-plans/active/rl-11-codex-window-validation-repair.md` (Progress Log only)

`swift build` and `swift test` write to the git-ignored `.build/`. The operator
authorized this as a command side effect, so it is not a writePaths violation.

## File-Level Changes

### `Sources/AppCore/RateLimitUsageCodex.swift`

1. Make `CodexWindow.window(now:)` throwing:
   `func window(now: Date) throws -> RateLimitWindow?`
   - Keep the guard `guard let used, let seconds else { return nil }`.
   - Replace `try?` with `try`. `RateLimitWindow.init` already throws
     `RateLimitErrorCode.invalidResponse` on bad input.
2. In `CodexRateLimitFetcher.fetchLive(now:)`, build the windows with `try`.
   For example, map the two optional windows with a throwing call, or use a
   small loop.
   - The error must surface as `RateLimitErrorCode.invalidResponse`.
   - It must not surface as `networkError`, which is what the service maps
     non-`RateLimitErrorCode` errors to.
3. Keep the file's existing compact style, as in
   `Sources/AppCore/RateLimitUsageClaude.swift:29-37`. Do not add helpers
   beyond what this needs.

### `Tests/AppCoreTests/RateLimitUsageCodexTests.swift`

Add these cases inside the existing `failures()` test, or as a new `@Test`
in the same suite, using the existing private `fetch(_:status:now:)` helper.
Each is input -> expected result:

- `{"rate_limit":{"primary_window":{"used_percent":-5,"limit_window_seconds":18000}}}`
  -> throws `RateLimitErrorCode.invalidResponse`.
- `{"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":0}}}`
  -> throws `RateLimitErrorCode.invalidResponse`.
- `{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000},"secondary_window":{"used_percent":-1,"limit_window_seconds":604800}}}`
  -> throws `RateLimitErrorCode.invalidResponse`. The whole response is
  invalid; it does not keep only the valid window.

The existing assertions (`sampleAndHeaders`, `classificationsAndReset`
including the line-37 missing-field case, `failures`, `credentialFiles`) must
still pass unchanged.

## Invariants

- The exact Codex sample still yields one weekly window with `usedPercent`
  82, `remainingPercent` 18, and `resetsAt` 1793774131, with `fiveHour` nil.
- No thrown error contains `testCodexToken` or `testCodexAccountID`.
- `! grep -n 'refresh_token\|id_token\|OPENAI_API_KEY' Sources/AppCore/RateLimitUsageCodex.swift`
  still exits 0.

## Verification

Run every command in the foreground. Create the directory first with
`mkdir -p tmp/subscription-rate-limits-20261031/rl-11`. Record each command's
exit code and log path in the Progress Log.

1. `swift build > tmp/subscription-rate-limits-20261031/rl-11/build.log 2>&1`:
   exits 0.
2. `swift test --filter RateLimitUsageCodexTests > tmp/subscription-rate-limits-20261031/rl-11/codex-tests.log 2>&1`:
   exits 0, and the log shows the new cases passing with 0 failures.
3. `swift test --filter RateLimitUsageCodexFallbackTests > tmp/subscription-rate-limits-20261031/rl-11/codex-fallback-tests.log 2>&1`:
   exits 0 (regression check).
4. `swiftlint lint Sources/AppCore/RateLimitUsageCodex.swift Tests/AppCoreTests/RateLimitUsageCodexTests.swift > tmp/subscription-rate-limits-20261031/rl-11/swiftlint.log 2>&1`:
   exits 0.
5. `! grep -n 'try? RateLimitWindow' Sources/AppCore/RateLimitUsageCodex.swift`:
   exits 0.
6. `git diff --quiet -- Sources/AppCore/RateLimitUsageCodexSessionFallback.swift`
   exits 0. The file is untracked at baseline, so also record
   `shasum -a 256 Sources/AppCore/RateLimitUsageCodexSessionFallback.swift`
   before and after the work and confirm the hash is unchanged.

If step 1 fails only because of a file outside this plan's `writePaths` (for
example, sibling rl-09 is mid-edit), record the failure, wait, and re-run.

## Done Criteria

- [ ] A live Codex window with present but invalid values throws
  `invalidResponse`, and a window with missing fields is still dropped.
- [ ] The three new test cases pass, and the existing Codex and fallback tests
  still pass.
- [ ] The session fallback file is unchanged (same hash before and after).
- [ ] Steps 1 to 6 are recorded with exit codes and log paths.

## Progress Log

- 2026-10-31: Plan created after the continuation-run review of rl-06 against
  the design.
