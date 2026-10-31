# rl-07: GET /api/rate-limits on Both Routing Surfaces

**Status**: Planned
**Wave**: 2 (depends on rl-01)
**Design Reference**: `design-docs/specs/design-subscription-rate-limits.md`,
section HTTP API. Decision D5.

## Intent and Context

There are two routing surfaces:

- `DashboardRouter`, the plain `HTTPService.swift` path;
- `MachineDashboardRouter`, which handles every `/api/*` request when a
  machine router is present (`HTTPService.swift:461`). This is the router
  every production runtime uses.

Both must serve `GET /api/rate-limits` with the same body. The route is
handled before snapshot loading and before machine or directory parameter
parsing, so ccusage failures cannot affect it.

## Non-Goals

- No production construction-site changes. `Sources/AppCLI/Runtime.swift`
  and `MenuBarApp.swift` belong to rl-09.
- No machine selection for rate limits.
- No CORS or mutation-gate changes.
- No change to any other route's behavior.

## writePaths

- `Sources/AppCore/HTTPService+RateLimits.swift` (new; shared response
  helper)
- `Sources/AppCore/HTTPService.swift`
- `Sources/AppCore/MachineDashboardRouter.swift`
- `Tests/AppCoreTests/RateLimitRoutesTests.swift` (new)
- `impl-plans/active/rl-07-http-routes.md` (Progress Log only)

## Contract and File-Level Changes

### HTTPService+RateLimits.swift

`func rateLimitsHTTPResponse(service: RateLimitUsageService?, method: String) async -> HTTPResponse`
is an internal free function.

- `method != "GET"`: return 405 with the body
  `{"error":{"code":"method_not_allowed","message":"Method is not supported for this route"}}`,
  built the same way as `DashboardRouter.errorResponse` (`JSONSerialization`
  with sorted keys).
- `service == nil`: return 503 with `rate_limits_unavailable` and the
  message "Rate limit data is not available".
- Otherwise call `await service.current()`.
  - Encode with a local `JSONEncoder` using `dateEncodingStrategy = .iso8601`
    and `outputFormatting = [.sortedKeys]`.
  - Return 200 with `application/json`.
  - If encoding fails, return 500 with `encoding_failed`.

### HTTPService.swift (DashboardRouter)

- Add the stored property `let rateLimitService: RateLimitUsageService?`.
- Add the parameter `rateLimitService: RateLimitUsageService? = nil` as the
  last parameter of each of the three non-machine inits.
- In `init(machineRouter:assetResolver:)`, set it to `nil`; that path
  delegates every `/api/*` request.
- In `route(...)`, immediately after the `if let machineRouter, path.hasPrefix("/api/")`
  block and before `directoryNameMutationResponse`, add:
  `if path == "/api/rate-limits" { return await rateLimitsHTTPResponse(service: rateLimitService, method: method) }`.

### MachineDashboardRouter.swift

- Add the stored property `private let rateLimitService: RateLimitUsageService?`.
- Add the init parameter `rateLimitService: RateLimitUsageService? = nil` as
  the last parameter.
- In `route(...)`, right after the `/api/chart-colors` block, add the same
  one-line delegation. It must come before `queryRoute` and before the
  generic `guard method == "GET"`.

## Key Pitfalls

- Placement matters.
  - In `DashboardRouter`, a placement after the method guard or inside the
    snapshot `do` block would couple the route to snapshot failures.
  - In `MachineDashboardRouter`, a placement after `queryRoute` would apply
    machine-selection parsing to the route.
- Ignore query parameters. `/api/rate-limits?machine=remote1` returns the
  same 200 body.
- Keep the new init parameters defaulted and last, so every existing call
  site and test compiles unchanged.
- `MachineDashboardRouter.swift` is 753 lines and `HTTPService.swift` is
  693. Each may grow by no more than about 10 lines.

## Patterns to Imitate

- `/api/chart-colors` handling at
  `Sources/AppCore/MachineDashboardRouter.swift:route`.
- Router construction in tests:
  `Tests/AppCoreTests/DesktopDashboardTests.swift:77`
  (`MachineDashboardRouter(store:collector:mutationOwner:paths:)`) and
  `Tests/AppCoreTests/DashboardTests.swift:279` (`DashboardRouter(...)`).
- Fakes: `FakeRateLimitFetcher` and `RateLimitTestClock` from
  `Tests/AppCoreTests/RateLimitUsageTestSupport.swift` (rl-01), used
  read-only.

## Test Cases (Tests/AppCoreTests/RateLimitRoutesTests.swift)

- `DashboardRouter` with a service built on fake fetchers (Claude ok with
  fiveHour 47%, Codex unavailable) -> GET `/api/rate-limits` returns 200,
  `scope == "local"`, `providers[0].provider == "claude"`,
  `fiveHour.remainingPercent == 53`, and Codex `status == "unavailable"`.
- The same request through `MachineDashboardRouter` -> 200 with a
  structurally identical body: decode both into `RateLimitsResponse` and
  compare everything except `generatedAt`. Also through
  `DashboardRouter(machineRouter:assetResolver:)`, which delegates.
- Key allowlist: recursively walk the JSON body. Every key must be in
  {generatedAt, scope, providers, provider, status, errorCode, message,
  planType, fetchedAt, stale, fiveHour, weekly, otherWindows, kind,
  windowSeconds, usedPercent, remainingPercent, resetsAt}.
- `/api/rate-limits?machine=remote1` -> 200.
- POST and PUT -> 405 `method_not_allowed` on both routers.
- A router constructed without a service -> 503 `rate_limits_unavailable` on
  both routers.
- A `DashboardRouter` whose snapshot provider throws -> `/api/rate-limits`
  still returns 200 (independence from the snapshot).

## Verification

1. `swift build`: exit 0.
2. `swift test --filter RateLimitRoutesTests`: all pass.
3. `swift test --filter DashboardTests`: still passes (regression).
4. `swift test --filter DesktopDashboardTests`: still passes (regression).
5. `swiftlint lint Sources/AppCore/HTTPService+RateLimits.swift Sources/AppCore/HTTPService.swift Sources/AppCore/MachineDashboardRouter.swift Tests/AppCoreTests/RateLimitRoutesTests.swift`:
   no errors.
6. `wc -l Sources/AppCore/HTTPService.swift Sources/AppCore/MachineDashboardRouter.swift`:
   both under 1000.

## Done Criteria

- [ ] Both routers serve the route at the specified positions.
- [ ] All the tests pass.
- [ ] Verification 1-6 recorded in the Progress Log with exit codes.

## Progress Log

- 2026-10-31: Plan created.
