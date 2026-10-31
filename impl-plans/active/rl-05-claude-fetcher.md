# rl-05: Claude Code Credential Provider and Usage Fetcher

**Status**: Planned
**Wave**: 2 (depends on rl-01)
**Design Reference**: `design-docs/specs/design-subscription-rate-limits.md`,
sections Data Sources/Claude Code and Status rules. QA decisions 2 and 4.

## Intent and Context

This plan implements the Claude side as two pieces:

- `ClaudeCredentialProvider` (`ClaudeCredentialProviding`) reads the OAuth
  credential, read-only. On macOS it tries the Keychain first, through the
  `/usr/bin/security` CLI; otherwise, or when the Keychain read fails, it
  reads `<claude home>/.credentials.json`.
- `ClaudeRateLimitFetcher` (`RateLimitLiveFetching`) calls
  `GET https://api.anthropic.com/api/oauth/usage` through the injected
  transport and returns a `RateLimitObservation`.

## Non-Goals

- No token refresh. Never call any OAuth token endpoint.
- No writes to the Keychain or the filesystem.
- No caching or throttling; rl-01's service owns those.
- No `seven_day_opus` or `seven_day_sonnet`.
- No production factory; rl-09 owns that.

## writePaths

- `Sources/AppCore/RateLimitUsageClaude.swift` (new; fetcher and response
  decoding)
- `Sources/AppCore/RateLimitUsageClaudeCredentials.swift` (new)
- `Tests/AppCoreTests/RateLimitUsageClaudeTests.swift` (new)
- `impl-plans/active/rl-05-claude-fetcher.md` (Progress Log only)

Read-only use: the rl-01 files, including
`Tests/AppCoreTests/RateLimitUsageTestSupport.swift`, and
`Sources/AppCore/CCUsageCommandRunner.swift`.

## Contract

- `public struct ClaudeCredentialProvider: ClaudeCredentialProviding`
  - Init: `public init(environment: [String: String] = ProcessInfo.processInfo.environment, processRunner: any CCUsageProcessRunning = CCUsageProcessRunner(), useKeychain: Bool = <true on macOS, false otherwise>)`.
  - Claude home is `environment["CLAUDE_CONFIG_DIR"]`, otherwise
    `(environment["HOME"] ?? NSHomeDirectory()) + "/.claude"`. This mirrors
    `MachineSessionSourcePlan.localSources`.
  - Keychain step, only when `useKeychain` is true:
    - Run `processRunner.run(executable: URL(fileURLWithPath: "/usr/bin/security"), arguments: ["find-generic-password", "-s", "Claude Code-credentials", "-w"], timeoutSeconds: 10)`.
    - Exit 0 with decodable JSON means use it.
    - Any other outcome (exit 44 not-found, other exit codes, timeout,
      spawn failure, undecodable stdout) moves on to the file step.
    - Never read or keep stderr.
  - File step: read `<home>/.credentials.json`.
    - Missing file: throw `.credentialsMissing`.
    - Present but unreadable or undecodable, or `accessToken` missing or
      empty: throw `.credentialsUnreadable`.
  - Decoding:
    - Use private `Decodable` structs that decode only
      `claudeAiOauth.accessToken` (String), `claudeAiOauth.expiresAt`
      (number of milliseconds since the epoch, optional), and
      `claudeAiOauth.subscriptionType` (String, optional).
    - The structs must NOT declare `refreshToken`.
    - `expiresAt` becomes `Date(timeIntervalSince1970: ms / 1000)`.
- `public struct ClaudeRateLimitFetcher: RateLimitLiveFetching`
  - Init: `public init(credentials: any ClaudeCredentialProviding, transport: any RateLimitHTTPTransport, timeoutSeconds: TimeInterval = 15)`.
  - `fetchLive(now:)` steps:
    1. Load the credential (rethrow its code).
    2. If `expiresAt != nil && expiresAt <= now`, throw `.tokenExpired`
       without calling the transport.
    3. Call `transport.get` with the URL
       `https://api.anthropic.com/api/oauth/usage` and the headers
       `Authorization: Bearer <rawValue>`,
       `anthropic-beta: oauth-2025-04-20`, and
       `Content-Type: application/json`.
    4. Map the status:
       - 200 means decode;
       - 401 and 403 throw `.unauthorized`;
       - 429 throws `.rateLimited`;
       - any other status, including 3xx, throws `.httpError`.
    5. Decode:
       - The top level must be a JSON object; otherwise throw
         `.invalidResponse`.
       - `five_hour` and `seven_day` are each optional or null.
       - A window object whose `utilization` is null or missing counts as
         absent.
       - `resets_at` is optional. If it cannot be parsed, `resetsAt` is nil;
         do not fail.
       - Unknown keys are ignored.
    6. Build the windows with
       `RateLimitWindow(windowSeconds: 18000 | 604800, usedPercent: utilization, resetsAt:)`.
       Its throw (a negative or non-finite value) becomes `.invalidResponse`.
    7. Return `RateLimitObservation(planType: credential.subscriptionType, observedAt: now, windows: [fiveHour?, weekly?])`.
  - `resets_at` parsing must accept the exact value
    `2026-10-31T13:00:00.013669+00:00`, which has 6 fractional digits and a
    `+00:00` offset.
    - First try `ISO8601DateFormatter` with
      `[.withInternetDateTime, .withFractionalSeconds]`.
    - If that returns nil, retry after truncating the fraction to 3 digits,
      then try once more without fractional seconds.
    - Pattern to follow: `Sources/AppCore/DashboardAPIClient.swift:309`.

## Key Pitfalls

- Do not include the token in any thrown error, string, or log. Use
  `credential.accessToken.rawValue` only when building the header value.
- Do not keep the credential beyond the `fetchLive` call. No stored
  properties may hold it.
- Do not use `SecItemCopyMatching` (QA decision 2).
- Do not route the Keychain call through `/bin/sh`.
- On Linux the code must compile: no `Security` import is needed, because
  the CLI is reached through `Process`.
- `utilization` may be an int or a double in the JSON. Decode it as
  `Double`, which accepts both.

## Test Cases (Tests/AppCoreTests/RateLimitUsageClaudeTests.swift)

All tests use fakes only: `RecordingRateLimitTransport`, a fake
`CCUsageProcessRunning`, and a temp directory for `CLAUDE_CONFIG_DIR`.

- Exact sample body `{"five_hour":{"utilization":0.0,"resets_at":"2026-10-31T13:00:00.013669+00:00"},"seven_day":{"utilization":53.0,"resets_at":"2026-11-01T17:00:00.013690+00:00"},"seven_day_opus":null,"seven_day_sonnet":null,"extra_usage":{"x":1}}`
  -> two windows: `fiveHour` with used 0 and remaining 100, and `weekly`
  with used 53 and remaining 47. Both `resetsAt` values parse to the
  expected instants, to second precision.
- `{"five_hour":null}` -> zero windows, no throw.
- `[]` (top level is not an object) -> `.invalidResponse`.
- `utilization: -5` -> `.invalidResponse`.
- The transport records the URL and headers -> exactly the three headers,
  and the bearer value is the sentinel `test-claude-access-token`.
- The credential has `expiresAt` in milliseconds in the past -> throws
  `.tokenExpired`, and the transport call count is 0.
- Status 401 -> `.unauthorized`. 403 -> `.unauthorized`.
  429 -> `.rateLimited`. 302 and 500 -> `.httpError`.
- Across all tests, the recorded URLs contain only `/api/oauth/usage`, never
  a token or refresh endpoint.
- Keychain fake returns exit 0 with JSON -> its `accessToken` and
  `subscriptionType` are used, and the file is not required.
- Keychain fake returns exit 44 and the file exists -> the file is used.
- Keychain fake returns exit 44 and there is no file ->
  `.credentialsMissing`.
- `useKeychain: false` and the file contains `{}` ->
  `.credentialsUnreadable`.
- The fake runner records the arguments -> exactly
  `["find-generic-password","-s","Claude Code-credentials","-w"]`, the
  executable is `/usr/bin/security`, and the timeout is 10.
- `String(describing:)` of every thrown error does not contain the sentinel.

## Verification

1. `swift build`: exit 0.
2. `swift test --filter RateLimitUsageClaudeTests`: all pass.
3. `swiftlint lint Sources/AppCore/RateLimitUsageClaude.swift Sources/AppCore/RateLimitUsageClaudeCredentials.swift Tests/AppCoreTests/RateLimitUsageClaudeTests.swift`:
   no errors.
4. `grep -n "refreshToken\|refresh_token\|SecItem" Sources/AppCore/RateLimitUsageClaude*.swift`:
   no matches.

## Done Criteria

- [ ] The contract types exist exactly as named.
- [ ] Every test case passes.
- [ ] Verification 1-4 recorded in the Progress Log with exit codes.

## Progress Log

- 2026-10-31: Plan created.
