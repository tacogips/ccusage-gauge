# rl-06: Codex Credential Provider, Usage Fetcher, and Session JSONL Fallback

**Status**: Planned
**Wave**: 2 (depends on rl-01)
**Design Reference**: `design-docs/specs/design-subscription-rate-limits.md`,
sections Data Sources/Codex, Window classification, and Status rules. QA
decisions 3 and 4.

## Intent and Context

This plan implements the Codex side as three pieces:

- `CodexCredentialProvider` reads `<codex home>/auth.json`.
- `CodexRateLimitFetcher` calls
  `GET https://chatgpt.com/backend-api/wham/usage` and classifies each
  window by length.
- `CodexRateLimitSessionFallback` returns the newest `token_count`
  `rate_limits` observation found in `<codex home>/sessions/**/*.jsonl`.

The service from rl-01 decides when the fallback result is used and marks it
stale.

## Non-Goals

- No token refresh.
- No writes under the Codex home.
- No changes to `CodexUsageEvents.swift` or `UsageEventLogReader.swift`.
  Reuse their internal helpers as they are.
- Extra configured Codex session directories are not scanned (QA
  decision 4).
- No caching or throttling.

## writePaths

- `Sources/AppCore/RateLimitUsageCodex.swift` (new; credential provider,
  fetcher, response decoding)
- `Sources/AppCore/RateLimitUsageCodexSessionFallback.swift` (new)
- `Tests/AppCoreTests/RateLimitUsageCodexTests.swift` (new)
- `Tests/AppCoreTests/RateLimitUsageCodexFallbackTests.swift` (new)
- `impl-plans/active/rl-06-codex-fetcher.md` (Progress Log only)

Read-only use: the rl-01 files and `Sources/AppCore/UsageEventLogReader.swift`
(`jsonlFiles(roots:modifiedSince:)` and
`forEachLineFromEnd(in:endingAt:matchingAny:body:)`).

## Contract

- `public enum CodexHome { public static func url(environment: [String: String]) -> URL }`
  returns `CODEX_HOME`, otherwise
  `(HOME ?? NSHomeDirectory()) + "/.codex"`. This is shared with rl-09's
  factory.
- `public struct CodexCredentialProvider: CodexCredentialProviding`
  - Init: `public init(environment: [String: String] = ProcessInfo.processInfo.environment)`.
  - Reads `<home>/auth.json`.
    - Missing file: throw `.credentialsMissing`.
    - Unreadable file or invalid JSON: throw `.credentialsUnreadable`.
    - `tokens`, `tokens.access_token`, or `tokens.account_id` missing or
      empty (for example in API-key mode): throw `.credentialsMissing`.
  - The private `Decodable` decodes only `tokens.access_token` and
    `tokens.account_id`. Never declare `refresh_token`, `id_token`, or
    `OPENAI_API_KEY`.
- `public struct CodexRateLimitFetcher: RateLimitLiveFetching`
  - Init: `public init(credentials: any CodexCredentialProviding, transport: any RateLimitHTTPTransport, timeoutSeconds: TimeInterval = 15)`.
  - Sends the headers `Authorization: Bearer <access>` and
    `ChatGPT-Account-Id: <account>`.
  - Status mapping is the same as for Claude: 200 decodes, 401 and 403
    throw `.unauthorized`, 429 throws `.rateLimited`, and anything else
    throws `.httpError`.
  - Decoding:
    - The top level must be an object; otherwise throw `.invalidResponse`.
    - `plan_type` is an optional String.
    - `rate_limit` is optional. When it is absent, the result has zero
      windows.
    - `primary_window` and `secondary_window` are each optional or null.
    - A window needs both `used_percent` (Double) and
      `limit_window_seconds` (Int); without either, skip that window.
    - `resetsAt` is `reset_at` (epoch seconds), otherwise
      `now + reset_after_seconds`, otherwise nil.
  - The windows are `[primary, secondary]`, in that order and compacted.
    Classification and slot assignment happen through rl-01's
    `RateLimitWindow` and `ProviderRateLimits.slots`; never by position.
  - Returns `RateLimitObservation(planType:, observedAt: now, windows:)`.
- `public struct CodexRateLimitSessionFallback: CodexRateLimitFallbackReading`
  - Init: `public init(sessionsRoot: URL, maxFiles: Int = 10)`.
  - `latestObservation()` runs its file I/O off the caller's executor
    (`Task.detached(priority: .utility)`, as in
    `CodexUsageEventLoader.events`).
  - File selection: `UsageEventLogReader.jsonlFiles(roots: [sessionsRoot], modifiedSince: nil)`,
    sorted by `modified` descending (a nil date sorts last), keeping the
    first `maxFiles` files.
  - For each file, call `forEachLineFromEnd` with the needle
    `Data(#""type":"token_count""#.utf8)`.
    - Decode `{timestamp: String, type: "event_msg", payload: {type: "token_count", rate_limits: {primary?, secondary?, plan_type?}?}}`.
    - Skip lines whose `rate_limits` is null or missing, and keep scanning
      backwards.
    - The first line with a usable `rate_limits` ends the whole search.
  - Window fields: `used_percent` (Double) and `window_minutes` (Int,
    required; `windowSeconds = window_minutes * 60`). `resetsAt` is
    `resets_at` (epoch seconds), otherwise the event timestamp plus
    `resets_in_seconds`, otherwise nil.
  - `observedAt` is the event `timestamp`, parsed as ISO 8601 with or
    without fractional seconds. If the timestamp cannot be parsed, skip the
    line.
  - Any I/O or decoding error in a file skips that file. The function never
    throws. If nothing is found, it returns nil.

## Key Pitfalls

- Primary and secondary are not fixed to 5h and weekly. A weekly primary with
  a null secondary must yield `weekly` set and `fiveHour` nil (asserted
  through `ProviderRateLimits.slots`).
- `used_percent` may be an int (82) or a double (77.0). Decode it as
  `Double`.
- `jsonlFiles` already sorts by path. Re-sort by modification time;
  otherwise the "newest" event is wrong.
- Never put the account ID or token into errors or strings.
- Fallback tests must write fixture JSONL files to a temp directory and set
  explicit modification dates with
  `FileManager.setAttributes([.modificationDate: ...])`.

## Test Cases

`RateLimitUsageCodexTests.swift`:

- Exact sample `{"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":82,"limit_window_seconds":604800,"reset_after_seconds":339165,"reset_at":1793774131},"secondary_window":null},"credits":{"has_credits":false}}`
  -> `planType` "pro", one window of kind `weekly`, used 82, remaining 18,
  and `resetsAt` equal to epoch 1793774131. `slots` gives fiveHour nil and
  the weekly window.
- Primary 18000s and secondary 604800s -> `fiveHour` and `weekly`.
- Primary 604800s and secondary 18000s -> also `fiveHour` and `weekly`
  (position-independent).
- Primary 3600s -> kind `other`, which lands in `slots().other`.
- No `reset_at` but `reset_after_seconds: 60` -> `resetsAt == now + 60`.
- No `rate_limit` -> zero windows.
- `[]` -> `.invalidResponse`.
- Status 401, 403, 429, 500 -> `.unauthorized`, `.unauthorized`,
  `.rateLimited`, `.httpError`.
- Recorded headers -> exactly `Authorization: Bearer test-codex-access-token`
  and `ChatGPT-Account-Id: test-codex-account-id`. The URL is
  `/backend-api/wham/usage`.
- `auth.json` missing -> `.credentialsMissing`.
- `{"OPENAI_API_KEY":"x"}` with no tokens -> `.credentialsMissing`.
- `not json` -> `.credentialsUnreadable`.
- `CODEX_HOME` from the environment is respected (temp directory).
- `String(describing:)` of the errors contains no sentinel.

`RateLimitUsageCodexFallbackTests.swift`:

- Two files, where the newer file (by modification time) has events at
  t1 < t2 with `rate_limits` -> returns the t2 event, with weekly from
  `window_minutes` 10080 and `observedAt` t2.
- The newest file's last `token_count` has `"rate_limits":null`, and an
  earlier line has data -> the earlier line is returned.
- The newest file has no `rate_limits` at all, and an older file does -> the
  older file's event is returned.
- `resets_in_seconds` only -> `resetsAt` is the event timestamp plus that
  value.
- An empty or missing `sessionsRoot` -> nil.
- A malformed line -> skipped, no throw.
- `maxFiles: 1` where only the second-newest file has data -> nil.

## Verification

1. `swift build`: exit 0.
2. `swift test --filter RateLimitUsageCodexTests`: all pass.
3. `swift test --filter RateLimitUsageCodexFallbackTests`: all pass.
4. `swiftlint lint Sources/AppCore/RateLimitUsageCodex.swift Sources/AppCore/RateLimitUsageCodexSessionFallback.swift Tests/AppCoreTests/RateLimitUsageCodexTests.swift Tests/AppCoreTests/RateLimitUsageCodexFallbackTests.swift`:
   no errors.
5. `grep -n "refresh_token\|id_token\|OPENAI_API_KEY" Sources/AppCore/RateLimitUsageCodex*.swift`:
   no matches.

## Done Criteria

- [ ] The contract types exist exactly as named.
- [ ] All the listed tests pass.
- [ ] Verification 1-5 recorded in the Progress Log with exit codes.

## Progress Log

- 2026-10-31: Plan created.
- 2026-10-31: Implemented Codex home, read-only credentials, live fetcher, and bounded session fallback; contract types and listed behavior covered by focused fixtures. On the shared tree, `swift build` exit 0 (`tmp/subscription-rate-limits-20261031/rl-06/build-final.log`); `swift test --filter RateLimitUsageCodexTests` exit 0, 4 tests (`codex-tests-final.log`); `swift test --filter RateLimitUsageCodexFallbackTests` exit 0, 1 test (`codex-fallback-tests-final.log`). Selected-file SwiftLint exit 0 (`swiftlint.log`); strict selected-file SwiftLint exit 0 (`swiftlint-strict-final.log`, manifest `changed-swift.nul`). Forbidden credential-key check and unchanged-reader diff both exit 0 (`privacy.log`, `unchanged.log`). All abbreviated log paths are under `tmp/subscription-rate-limits-20261031/rl-06/`. Review and full integration gates remain downstream.
- 2026-10-31: Addressed RL06-TI-M1 by naming the older fixture `a-old.jsonl` and newer fixture `b-new.jsonl`, making path order oppose modification-time order while retaining all assertions. On the shared tree, `swift test --filter RateLimitUsageCodexFallbackTests` exit 0 (1 test, `tmp/subscription-rate-limits-20261031/rl-06/codex-fallback-tests-ti1.log`), `swift test --filter RateLimitUsageCodexTests` exit 0 (4 tests, `tmp/subscription-rate-limits-20261031/rl-06/codex-tests-ti1.log`), and strict selected-file SwiftLint exit 0 (`tmp/subscription-rate-limits-20261031/rl-06/swiftlint-strict-ti1.log`, non-empty `changed-swift.nul`). Logs postdate the test edit. Independent review remains pending.
