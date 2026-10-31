# rl-01: Rate-Limit Core Contracts, Transport, and Service

**Status**: Planned
**Wave**: 1 (no dependencies)
**Design Reference**: `design-docs/specs/design-subscription-rate-limits.md`,
sections Derived Model, Status rules, and Fetch, Cache, and Isolation
**Overview**: `impl-plans/active/subscription-rate-limits-overview.md`

## Intent and Context

This plan pins every Swift type that the other rate-limit plans compile
against, and implements the provider-independent parts:

- window derivation and classification;
- the status rules;
- the 60s throttle and single-flight fetching;
- the in-memory last-good fallback;
- the URLSession transport.

Provider-specific HTTP and credential code is out of scope; it belongs to
rl-05 (Claude) and rl-06 (Codex).

## Non-Goals

- No Claude or Codex request or decoding logic.
- No credential file or Keychain access.
- No JSONL scanning.
- No HTTP routes and no UI.
- No production factory; rl-09 owns that.
- No logging (do not use `BootstrapLogger`).
- No token refresh code of any kind.

## writePaths

- `Sources/AppCore/RateLimitUsageModels.swift` (new)
- `Sources/AppCore/RateLimitUsageProtocols.swift` (new)
- `Sources/AppCore/RateLimitUsageTransport.swift` (new)
- `Sources/AppCore/RateLimitUsageService.swift` (new)
- `Tests/AppCoreTests/RateLimitUsageTestSupport.swift` (new; shared fakes that
  rl-05, rl-06, rl-07 and rl-09 may use read-only)
- `Tests/AppCoreTests/RateLimitUsageModelsTests.swift` (new)
- `Tests/AppCoreTests/RateLimitUsageServiceTests.swift` (new)
- `impl-plans/active/rl-01-core-contracts-service.md` (Progress Log only)

## Contract (exact public symbols; other plans depend on these names)

### RateLimitUsageModels.swift

- `public enum RateLimitProvider: String, Codable, Sendable { case claude, codex }`
- `public enum RateLimitStatus: String, Codable, Sendable { case ok, stale, unauthorized, unavailable }`
- `public enum RateLimitErrorCode: String, Codable, Sendable, Error`
  - Cases and raw values: `credentialsMissing = "credentials_missing"`,
    `credentialsUnreadable = "credentials_unreadable"`,
    `tokenExpired = "token_expired"`, `unauthorized = "unauthorized"`,
    `rateLimited = "rate_limited"`, `httpError = "http_error"`,
    `networkError = "network_error"`, `timeout = "timeout"`,
    `invalidResponse = "invalid_response"`.
  - `public var message: String` returns fixed English text. Examples:
    unauthorized gives "Sign in again with the CLI to refresh credentials";
    `credentials_missing` gives "CLI credentials were not found". The text
    contains no interpolation.
- `public enum RateLimitWindowKind: String, Codable, Sendable { case fiveHour, weekly, other }`
  - `static func classify(windowSeconds: Int) -> RateLimitWindowKind` maps
    18000 to `fiveHour`, 604800 to `weekly`, and everything else to `other`.
- `public struct RateLimitWindow: Codable, Equatable, Sendable`
  - Fields: `kind`, `windowSeconds: Int`, `usedPercent: Double`,
    `remainingPercent: Double`, `resetsAt: Date?`.
  - `public init(windowSeconds: Int, usedPercent: Double, resetsAt: Date?) throws`
    throws `RateLimitErrorCode.invalidResponse` when `usedPercent` is not
    finite, when `usedPercent < 0`, or when `windowSeconds <= 0`. It derives
    `kind` through `classify`, and sets
    `remainingPercent = min(max(100 - usedPercent, 0), 100)`.
  - `public var pieFraction: Double` is `min(usedPercent, 100) / 100`.
  - Encode `resetsAt` as an explicit `null` when nil (custom
    `encode(to:)`). Decoding must accept a missing key or `null`.
- `public struct RateLimitObservation: Equatable, Sendable { planType: String?; observedAt: Date; windows: [RateLimitWindow] }`
  with a public memberwise init.
- `public struct ProviderRateLimits: Codable, Equatable, Sendable`
  - Fields: `provider`, `status`, `errorCode: RateLimitErrorCode?`,
    `message: String?`, `planType: String?`, `fetchedAt: Date?`,
    `stale: Bool`, `fiveHour: RateLimitWindow?`, `weekly: RateLimitWindow?`,
    `otherWindows: [RateLimitWindow]`.
  - Every optional is encoded as an explicit `null` (custom `encode(to:)`).
  - Slot-assignment helper:
    `static func slots(_ windows: [RateLimitWindow]) -> (fiveHour: RateLimitWindow?, weekly: RateLimitWindow?, other: [RateLimitWindow])`.
    It walks the windows in input order and the first window of each kind
    wins. A later duplicate goes to `other` and keeps its `kind`.
- `public struct RateLimitsResponse: Codable, Equatable, Sendable { generatedAt: Date; scope: String; providers: [ProviderRateLimits] }`
  - `scope` is always `"local"`.
  - `providers` is always `[claude, codex]`, in that order.

### RateLimitUsageProtocols.swift

- `public struct RedactedSecret: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable`
  - `init(_ value: String)` and an internal `let rawValue: String`.
  - `description`, `debugDescription`, and the mirror all yield `<redacted>`.
  - It must NOT conform to `Codable`, `Encodable`, or `Hashable`.
- `public struct ClaudeOAuthCredential: Sendable { accessToken: RedactedSecret; expiresAt: Date?; subscriptionType: String? }`
- `public struct CodexOAuthCredential: Sendable { accessToken: RedactedSecret; accountID: RedactedSecret }`
- `public protocol ClaudeCredentialProviding: Sendable { func claudeCredential() async throws -> ClaudeOAuthCredential }`
  It throws only `RateLimitErrorCode`.
- `public protocol CodexCredentialProviding: Sendable { func codexCredential() async throws -> CodexOAuthCredential }`
- `public struct RateLimitHTTPResponse: Sendable { status: Int; body: Data }`
- `public protocol RateLimitHTTPTransport: Sendable { func get(url: URL, headers: [String: String], timeoutSeconds: TimeInterval) async throws -> RateLimitHTTPResponse }`
  It throws only `.timeout` or `.networkError`, and returns every HTTP status,
  including 3xx.
- `public protocol RateLimitLiveFetching: Sendable { func fetchLive(now: Date) async throws -> RateLimitObservation }`
  It throws `RateLimitErrorCode`.
- `public protocol CodexRateLimitFallbackReading: Sendable { func latestObservation() async -> RateLimitObservation? }`

### RateLimitUsageTransport.swift

- `public struct URLSessionRateLimitTransport: RateLimitHTTPTransport`
  - Uses `URLSessionConfiguration.ephemeral` with `urlCache = nil`,
    `httpCookieStorage = nil`, and `httpShouldSetCookies = false`.
  - A delegate refuses redirects by calling the completion handler with
    `nil`, so the 3xx response is returned as-is.
  - Uses a per-request `timeoutInterval`.
  - `URLError.timedOut` maps to `.timeout`. Any other error maps to
    `.networkError`.
  - Never interpolate an `Error`, the request, or the headers into anything.

### RateLimitUsageService.swift

- `public actor RateLimitUsageService`
  - Init: `public init(claude: any RateLimitLiveFetching, codex: any RateLimitLiveFetching, codexFallback: (any CodexRateLimitFallbackReading)?, minimumInterval: TimeInterval = 60, now: @escaping @Sendable () -> Date = { Date() })`
  - `public func current() async -> RateLimitsResponse`
    - It never throws.
    - It fetches the two providers concurrently (`async let`) and always
      returns both entries.

## Status Algorithm (implement exactly; this resolves design-review finding DR-L1)

For each provider, on `current()`:

1. **Throttle.** If an entry is cached and `now() - lastAttemptAt < minimumInterval`,
   return the cached entry unchanged. This applies to every status, so
   failures are throttled too.
2. **Single flight.** If a fetch task for this provider is in flight, await
   that task. Store the `Task` in actor state before the first `await`,
   because actor reentrancy otherwise lets two callers both start a fetch.
3. **Fetch.** Otherwise set `lastAttemptAt = now()` and run `fetchLive(now:)`.
4. **Success.** Status `ok`, `stale = false`, `errorCode` and `message` are
   nil, `fetchedAt = observation.observedAt`, and the slots come from
   `slots(windows)`. Save this entry as the provider's last-good observation.
5. **Failure.** Let `code` be the thrown error. Any non-`RateLimitErrorCode`
   error maps to `.networkError`.
   - **Claude auth failure.** If the provider is Claude and `code` is
     `.tokenExpired` or `.unauthorized`, the status is `unauthorized`, with
     no windows and `fetchedAt = nil`. This holds even when a last-good
     observation exists.
   - **Candidates.** The candidates are the last-good observation, plus the
     Codex fallback `latestObservation()` when the provider is Codex. The
     newest `observedAt` wins.
   - **Window expiry.** From the chosen candidate, drop windows whose
     `resetsAt` is non-nil and `<= now()`.
   - **Stale result.** If at least one window remains, the status is
     `stale`, with `stale = true`, `errorCode = code`,
     `message = code.message`, `fetchedAt = candidate.observedAt`, and
     `planType = candidate.planType`.
   - **No usable candidate.** If no candidate exists or every window was
     dropped, the status is `unauthorized` when `code` is `.unauthorized` or
     `.tokenExpired`, and `unavailable` otherwise. In both cases `errorCode`
     is `code`, `message` is `code.message`, and there are no windows.

`generatedAt` is `now()` at return.

## Patterns to Imitate

- Actor plus injected clock: `Sources/AppCore/DashboardRangeLoading.swift`
  and the `DashboardSnapshotCache` usage in `Sources/AppCore/HTTPService.swift`.
- Swift Testing style:
  `Tests/AppCoreTests/DashboardUIStateFoldEffortTests.swift`
  (`@Suite`, `@Test`, `#expect`).
- Lock-protected test fakes:
  `Tests/AppCoreTests/DashboardAPIClientTests.swift:RequestRecorder`
  (`final class ... @unchecked Sendable` with `NSLock`). Use this only in
  `Tests/`.

## Test Support (RateLimitUsageTestSupport.swift)

- `RateLimitTestClock`: a settable `Date`, lock-protected, with a `now`
  closure.
- `FakeRateLimitFetcher: RateLimitLiveFetching`: scripted results, call
  counter, and an optional delay for single-flight tests.
- `FakeRateLimitFallback: CodexRateLimitFallbackReading`.
- `RecordingRateLimitTransport: RateLimitHTTPTransport`: scripted
  `(status, body)` or a thrown code; records every URL and header dictionary.
- Sentinel constants: `test-claude-access-token`, `test-codex-access-token`,
  `test-codex-account-id`.

## Test Cases (situation -> expected outcome)

Models:

- `usedPercent` 47 -> `remainingPercent` 53, `pieFraction` 0.47.
- `usedPercent` 120 -> remaining 0, fraction 1.0.
- `usedPercent` -1 or NaN -> throws `.invalidResponse`.
- `windowSeconds` 18000, 604800, and 3600 -> `fiveHour`, `weekly`, `other`.
- `slots([weekly A, fiveHour B, weekly C])` -> weekly A, fiveHour B,
  `other == [C]`.
- Encoding a `ProviderRateLimits` with nil fields -> the JSON contains
  `"errorCode":null` and `"resetsAt":null`.
- Encoding a response -> the top-level keys are exactly `generatedAt`,
  `scope`, `providers`.
- `String(describing: RedactedSecret("test-claude-access-token"))` and
  `dump` output do not contain the sentinel.

Service (all with an injected clock):

- Both fetchers succeed -> both entries `ok`, `fetchedAt == observedAt`.
- Claude throws `.networkError` while Codex succeeds -> Claude
  `unavailable`/`network_error`, Codex `ok` (isolation).
- A fetcher throws a non-code error -> `network_error`.
- Call at t0, then at t0 + 59s -> the fetcher is called once. At t0 + 60s ->
  called twice.
- A failure at t0 is cached until t0 + 60s, with no retry before then.
- Two concurrent `current()` calls while a slow fetch is in flight -> the
  fetcher is called once and both results are equal.
- Claude ok at t0, then `.networkError` at t0 + 60s -> `stale`,
  `errorCode network_error`, `fetchedAt` t0.
- Claude ok at t0, then `.unauthorized` at t0 + 60s -> `unauthorized`, no
  windows.
- Claude `.tokenExpired` -> `unauthorized`/`token_expired`.
- Codex `.unauthorized` with fallback observed at t0 - 10m -> `stale`,
  `errorCode unauthorized`, `fetchedAt` equals the fallback time.
- Codex `.unauthorized` with no fallback -> `unauthorized`.
- Codex failure where last-good is newer than the fallback -> last-good is
  used. Where the fallback is newer -> the fallback is used.
- A stale candidate whose only window has `resetsAt <= now` -> `unavailable`
  with the failure code.
- A stale candidate with one past window and one future window -> `stale`,
  and only the future window remains.

## Key Pitfalls

- Optional encoding must emit an explicit `null`. Synthesized `Codable`
  omits nil keys.
- Do not store `ClaudeOAuthCredential`, `CodexOAuthCredential`, or
  `RedactedSecret` in the actor. Credentials live only inside a single fetch,
  in rl-05 and rl-06.
- Do not use `Date()` directly inside the service; use the injected `now`.
- The transport has no unit test that touches the network. If a test is
  added, call the redirect delegate method directly with an un-resumed task.

## Verification

1. `swift build`: exit 0, no errors in owned files.
2. `swift test --filter RateLimitUsageModelsTests`: all pass.
3. `swift test --filter RateLimitUsageServiceTests`: all pass.
4. `swiftlint lint Sources/AppCore/RateLimitUsageModels.swift Sources/AppCore/RateLimitUsageProtocols.swift Sources/AppCore/RateLimitUsageTransport.swift Sources/AppCore/RateLimitUsageService.swift Tests/AppCoreTests/RateLimitUsageTestSupport.swift Tests/AppCoreTests/RateLimitUsageModelsTests.swift Tests/AppCoreTests/RateLimitUsageServiceTests.swift`:
   no errors.
5. `wc -l` on each owned Swift file: every file is under 1000 lines.
6. `grep -rn "refresh_token\|refreshToken\|oauth/token" Sources/AppCore/RateLimitUsage*.swift`:
   no matches (exit 1).

## Done Criteria

- [ ] All contract symbols above exist with the exact names and signatures.
- [ ] Every listed test case exists and passes.
- [ ] Verification steps 1-6 recorded in the Progress Log with exit codes.

## Progress Log

- 2026-10-31: Plan created.
