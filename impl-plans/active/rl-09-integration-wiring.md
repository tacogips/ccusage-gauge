# rl-09: Production Factory, Runtime Wiring, and Integration Non-Disclosure Test

**Status**: Planned
**Wave**: 1 of the continuation run (rl-01 to rl-08 are the implemented,
uncommitted baseline)
**Depends on**: none in this run
**Design Reference**: `design-docs/specs/design-subscription-rate-limits.md`,
sections "Integration Wiring and Rollout" (Production factory, One instance
per process), "HTTP API", and "Verification" item 9

## Intent and Context

The rate-limit feature is implemented for rl-01 to rl-08, but nothing creates
a production `RateLimitUsageService`, so `GET /api/rate-limits` returns 503 in
`serve` and in the desktop window. This plan adds the production factory, wires
one instance into `Sources/AppCLI/Runtime.swift`, and adds the end-to-end
non-disclosure test.

The menu-bar hook-in moved to rl-10, and the asset rebuild and full gate moved
to rl-12. The earlier version of this plan, which combined all three, stopped
because its `artifactRoots` were empty.

Existing contracts this plan uses (do not change them):

- `RateLimitUsageService.init(claude:codex:codexFallback:minimumInterval:now:)`
  at `Sources/AppCore/RateLimitUsageService.swift:25`
- `ClaudeRateLimitFetcher(credentials:transport:)` at
  `Sources/AppCore/RateLimitUsageClaude.swift:8`
- `ClaudeCredentialProvider(environment:)` at
  `Sources/AppCore/RateLimitUsageClaudeCredentials.swift:8` (the other
  parameters keep their defaults)
- `CodexRateLimitFetcher(credentials:transport:)` and
  `CodexCredentialProvider(environment:)` in
  `Sources/AppCore/RateLimitUsageCodex.swift`
- `CodexHome.url(environment:)` at `Sources/AppCore/RateLimitUsageCodex.swift:4`
- `CodexRateLimitSessionFallback(sessionsRoot:)` at
  `Sources/AppCore/RateLimitUsageCodexSessionFallback.swift:6`
- `URLSessionRateLimitTransport()` at
  `Sources/AppCore/RateLimitUsageTransport.swift:13`
- `MachineDashboardRouter(..., rateLimitService:)`, the last defaulted
  parameter, at `Sources/AppCore/MachineDashboardRouter.swift:25`
- `DashboardRouter(snapshotProvider:assetResolver:rateLimitService:)` and
  `DashboardRouter(machineRouter:assetResolver:)` in
  `Sources/AppCore/HTTPService.swift`

## Non-Goals

- Do not edit any rl-01 to rl-08 file. If one has a defect, record the file,
  the symptom, and the failing command in the Progress Log and stop. Do not
  fix it here.
- No menu-bar changes. `Sources/CCUsageGaugeMenuBar/` belongs to rl-10.
- Do not run `mise run build`, `mise run frontend:build`, or `bun run build`.
  They rewrite `Sources/AppCore/Resources/Web`, which only rl-12 owns.
- No new configuration keys, CLI flags, or log records.
- No git commit, branch, stash, reset, or worktree.

## writePaths

- `Sources/AppCore/RateLimitUsageProduction.swift` (new)
- `Sources/AppCLI/Runtime.swift`
- `Tests/AppCoreTests/RateLimitUsageIntegrationTests.swift` (new)
- `impl-plans/active/rl-09-integration-wiring.md` (Progress Log only)

`swift build` and `swift test` write to the git-ignored `.build/`. The operator
authorized this as a command side effect (design section "Integration Wiring
and Rollout", Build side effects). It is not a writePaths violation, so do not
refuse to build because `artifactRoots` is empty.

## File-Level Changes

### `Sources/AppCore/RateLimitUsageProduction.swift` (new, about 25 lines)

Pinned signature:

```swift
extension RateLimitUsageService {
  public static func production(environment: [String: String] = ProcessInfo.processInfo.environment) -> RateLimitUsageService
}
```

It composes the following:

- one `let transport = URLSessionRateLimitTransport()`, shared by both
  fetchers;
- `claude: ClaudeRateLimitFetcher(credentials: ClaudeCredentialProvider(environment: environment), transport: transport)`;
- `codex: CodexRateLimitFetcher(credentials: CodexCredentialProvider(environment: environment), transport: transport)`;
- `codexFallback: CodexRateLimitSessionFallback(sessionsRoot: CodexHome.url(environment: environment).appendingPathComponent("sessions", isDirectory: true))`;
- the default `minimumInterval` (60) and the default `now`.

Pitfalls:

- Do no I/O in the factory. That means no `FileManager` calls, no credential
  read, no `/usr/bin/security` call, no network, and no directory creation.
  `CodexHome.url` is pure path math, so it is safe.
- Pass `environment` to every provider and to `CodexHome.url`. Mixing in
  `ProcessInfo` would break the test that uses a temporary `HOME`.
- Do not add parameters such as an injectable interval or transport. The
  initializer already serves tests.

### `Sources/AppCLI/Runtime.swift`

- In the `MachineDashboardRouter(...)` call at line 129, add one trailing
  argument: `rateLimitService: RateLimitUsageService.production()`.
  Alternatively, bind it first as `let rateLimitService = RateLimitUsageService.production()`
  and pass that.
- That single router already serves the desktop window (`window.start(router: machineRouter)`)
  and `DashboardRouter(machineRouter:assetResolver:)` at line 156. Do not
  create a second service, and do not add `rateLimitService:` to the
  delegating `DashboardRouter(machineRouter:)`. It forwards every `/api/*`
  request to the machine router.
- Change nothing else in the file.

### `Tests/AppCoreTests/RateLimitUsageIntegrationTests.swift` (new)

Imitate `Tests/AppCoreTests/RateLimitRoutesTests.swift`: the
`@Suite`/`@Test` style, the `makeMachine(root:service:)` helper (copy it as a
private helper), the temporary root with `defer` removal, and the ISO 8601
decoder. Reuse these from `Tests/AppCoreTests/RateLimitUsageTestSupport.swift`
without editing that file: `testClaudeToken`, `testCodexToken`,
`testCodexAccountID`, and `RecordingRateLimitTransport`.

Fixtures, all private to this file:

- A fake `ClaudeCredentialProviding` that returns
  `ClaudeOAuthCredential(accessToken: RedactedSecret(testClaudeToken), expiresAt: <now + 1h>, subscriptionType: "pro")`.
- A fake `CodexCredentialProviding` that returns `testCodexToken` and
  `testCodexAccountID`.
- Two `RecordingRateLimitTransport` instances, one per fetcher:
  - the Claude one returns status 200 with the exact Claude sample body from
    `RateLimitUsageClaudeTests.sampleAndHeaders`
    (`five_hour.utilization` 0.0, `seven_day.utilization` 53.0, microsecond
    `+00:00` `resets_at`, null `seven_day_opus` and `seven_day_sonnet`, plus
    `extra_usage`);
  - the Codex one returns status 200 with the exact Codex sample body from
    `RateLimitUsageCodexTests.sampleAndHeaders` (plan `pro`, a weekly-only
    `primary_window` with `used_percent` 82, `reset_at` 1793774131,
    `secondary_window` null).
- A fixed clock `now = Date(timeIntervalSince1970: 1_793_448_000)`
  (2026-10-31T12:00:00Z). It must fall before both reset times and before the
  Claude `expiresAt`.
- `RateLimitUsageService(claude: ClaudeRateLimitFetcher(...), codex: CodexRateLimitFetcher(...), codexFallback: nil, now: { now })`.

Test cases, as input -> expected result:

- `GET /api/rate-limits` through `DashboardRouter(snapshotProvider: { throw CancellationError() }, assetResolver:, rateLimitService: service)`
  and through `MachineDashboardRouter(..., rateLimitService: service)`:
  - status 200 on both;
  - each body, as a UTF-8 string, contains none of `testClaudeToken`,
    `testCodexToken`, or `testCodexAccountID`;
  - the decoded `RateLimitsResponse` has providers `[claude, codex]`;
  - Claude `fiveHour?.remainingPercent == 100` and
    `weekly?.remainingPercent == 47`;
  - Codex `weekly?.usedPercent == 82` and `fiveHour == nil`;
  - the two decoded responses are equal.
- Across both transports, the recorded requests total exactly 2: one URL
  with path `/api/oauth/usage` and one with `/backend-api/wham/usage`. No
  recorded `absoluteString` contains `token` or `refresh`, compared
  case-insensitively. The second route call hits the 60 s throttle cache, so
  no third request is made.
- `RateLimitUsageService.production(environment: ["HOME": tempDir.path])`
  returns without crashing. Never call `current()` on it.

Pitfalls:

- Never call `current()` on a production service, because that reaches the
  real network and Keychain.
- Route the plain router first, then the machine router, and then assert the
  request count of 2. Both calls share one service.
- Do not print response bodies or tokens in test output.

## Invariants

- No source file in rl-01 to rl-08 changes.
- `grep -rn "refresh_token\|refreshToken\|oauth/token" Sources/AppCore Sources/AppCLI`
  finds no match.
- Default runtime behavior apart from `/api/rate-limits` is unchanged.

## Verification

Run every command in the foreground from the repository root. Create the
directory first with
`mkdir -p tmp/subscription-rate-limits-20261031/rl-09`, and send each
command's output to the named log. Record each command's exit code and log
path in the Progress Log.

1. `swift build > tmp/subscription-rate-limits-20261031/rl-09/build.log 2>&1`:
   exit 0.
2. `swift test --filter RateLimitUsageIntegrationTests > tmp/subscription-rate-limits-20261031/rl-09/integration-tests.log 2>&1`:
   exit 0, with at least 1 test passing and 0 failures.
3. `swift test --filter RateLimitRoutesTests > tmp/subscription-rate-limits-20261031/rl-09/routes-tests.log 2>&1`:
   exit 0 (regression).
4. `swiftlint lint Sources/AppCore/RateLimitUsageProduction.swift Sources/AppCLI/Runtime.swift Tests/AppCoreTests/RateLimitUsageIntegrationTests.swift > tmp/subscription-rate-limits-20261031/rl-09/swiftlint.log 2>&1`:
   exit 0 with no violations in these files.
5. `! grep -rn 'refresh_token\|refreshToken\|oauth/token' Sources/AppCore Sources/AppCLI --include='*.swift'`:
   exit 0.
6. `wc -l Sources/AppCore/RateLimitUsageProduction.swift Sources/AppCLI/Runtime.swift Tests/AppCoreTests/RateLimitUsageIntegrationTests.swift > tmp/subscription-rate-limits-20261031/rl-09/wc.log 2>&1`:
   every file is under 1000 lines.
7. `grep -c 'RateLimitUsageService.production' Sources/AppCLI/Runtime.swift`:
   prints `1`.

If step 1 fails only because of a file outside this plan's writePaths, for
example while sibling rl-11 is mid-edit, record it, wait, and re-run. Do not
edit that file.

## Done Criteria

- [ ] `RateLimitUsageProduction.swift` exists with the pinned signature and
  performs no I/O.
- [ ] `Runtime.swift` creates exactly one service and passes it to the single
  `MachineDashboardRouter`.
- [ ] The integration test passes: no sentinel in either body, the exact
  values above, and exactly 2 recorded URLs.
- [ ] Verification steps 1 to 7 are recorded with exit codes and log paths.

## Progress Log

- 2026-10-31: Plan created (the original combined rl-09).
- 2026-10-31: Narrowed in the continuation run. The menu-bar hook-in moved to
  rl-10, and the asset rebuild and full gate moved to rl-12.
- 2026-10-31: Implemented the production factory, one runtime router injection,
  and the two-router integration test. On the shared working tree, verification
  steps 1–7 exited 0 respectively; logs: `tmp/subscription-rate-limits-20261031/rl-09/`
  `build.log`, `integration-tests.log` (1 test), `routes-tests.log` (2 tests),
  `swiftlint.log`, `refresh-grep.log`, `wc.log`, and `factory-count.log`.
  Files have 14, 255, and 75 lines respectively. The additional required strict
  changed-file lint exited 1 (`strict-lint.log`): the pre-existing
  `Runtime.swift:84` multiple-closures warning becomes an error under strict
  lint. `baseline-strict-lint.log` confirms the same violation on HEAD (exit 2).
  The plan restricts Runtime changes to the router injection, so this unrelated
  existing hunk was not changed. Formal review and downstream plans remain pending.
- 2026-10-31: Scope amendment authorized by integration review session-572
  wave-001 (IR-RL09-STRICT-LINT-RUNTIME-84): baseline
  multiple_closures_with_trailing_closure at Runtime.swift:84 fixed by labeling
  serviceFactory; behavior unchanged. Runtime SHA-256 before:
  `19bb2ed7bada960dcf80fbd419483b8e99b6bd35b38ea91d3401e3670efb5f6c`;
  after: `559ce9e99f99cf32785e91603a846af373e770a6a724b0abcc00eb781b955930`.
  The scope and unchanged closure bodies check exited 0 (`amendment-scope.log`);
  the pre-edit strict lint reproduction exited 2 (`amendment-reproduction.log`).
  On the final shared-tree source, verification steps 1–7 each exited 0:
  `build.log`, `integration-tests.log` (1 passed), `routes-tests.log` (2 passed),
  `swiftlint.log`, `refresh-grep.log`, `wc.log`, and `factory-count.log`.
  Strict selected-file lint also exited 0 (`strict-lint.log`). All logs are in
  `tmp/subscription-rate-limits-20261031/rl-09/`; prior logs are retained with
  the `prior-` prefix. All four Done Criteria are met; independent review and
  downstream work remain pending.
