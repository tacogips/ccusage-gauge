# Subscription Rate Limits and Selectable Pie Charts

## Status

Proposed (2026-10-31). Source: workflow request "Add Claude Code and Codex
5h/weekly subscription rate-limit module with selectable multi-pie charts
(dashboard + menu bar)". There is no GitHub issue number. Default decisions and
open questions are recorded in
`design-docs/user-qa/2026-10-31-subscription-rate-limit-decisions.md`.

## Scope

In scope:

- An `AppCore` module that reads the current 5-hour and weekly subscription
  windows for Claude Code and Codex on the local machine, derives remaining
  percentage and reset time, and caches them in memory.
- `GET /api/rate-limits` on both dashboard routing surfaces.
- A dashboard rate-limit panel and a persisted multi-select of pie charts.
- A persisted multi-select of pie charts in the menu-bar app, rendered in the
  status glyph and the dropdown menu.

Out of scope:

- Remote machines. Rate limits are account-level data read with the host's own
  CLI credentials.
- Token refresh, any write to credential stores, new configuration keys, CLI
  `client` subcommands, and per-model Claude sub-limits such as
  `seven_day_opus` and `seven_day_sonnet`.

`ccusage` remains the only cost source. Rate-limit data never enters cost,
budget, aggregation, or cache code paths.

## Data Sources

### Claude Code

- Request: `GET https://api.anthropic.com/api/oauth/usage` with headers
  `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`,
  and `Content-Type: application/json`.
- Claude home: `CLAUDE_CONFIG_DIR` when it is set, otherwise `$HOME/.claude`.
  Extra Claude directories configured for session scanning are not credential
  sources (see QA decision 4).
- Credential lookup order:
  1. On macOS only, the Keychain generic password with service
     `Claude Code-credentials`. It is read by running `/usr/bin/security` with
     the fixed argument array
     `["find-generic-password", "-s", "Claude Code-credentials", "-w"]`. The
     process boundary is the existing one: no shell, a 10-second timeout,
     stdout kept only in memory, and stderr discarded unread.
  2. If the item is absent, the platform is not macOS, or the read fails,
     `<claude home>/.credentials.json`.
- Both sources contain the same JSON:
  `{"claudeAiOauth":{"accessToken","refreshToken","expiresAt"(ms),"subscriptionType"?,...}}`.
  Only `accessToken`, `expiresAt`, and `subscriptionType` are decoded. The
  refresh token is never decoded into a model.
- Response fields used: `five_hour` and `seven_day`, each either `null` or
  `{utilization: number (percent 0-100), resets_at: ISO 8601 string | null}`.
  Unknown keys are ignored, and either window may be `null` or absent.
  `resets_at` carries microsecond fractions and a `+00:00` offset, for example
  `2026-10-31T13:00:00.013669+00:00`. Parsing must accept that exact form.
- Window lengths are fixed by key: `five_hour` is 18000 seconds and
  `seven_day` is 604800 seconds.
- `planType` is `claudeAiOauth.subscriptionType` when present, otherwise
  `null`.

### Codex

- Request: `GET https://chatgpt.com/backend-api/wham/usage` with headers
  `Authorization: Bearer <tokens.access_token>` and
  `ChatGPT-Account-Id: <tokens.account_id>`.
- Codex home: `CODEX_HOME` when it is set, otherwise `$HOME/.codex`.
  Credentials come from `<codex home>/auth.json`. Only `tokens.access_token`
  and `tokens.account_id` are decoded. If either is missing (for example in
  API-key mode), the result is `credentials_missing`.
- Response fields used: `plan_type`, plus `rate_limit.primary_window` and
  `rate_limit.secondary_window`. Each window is `null` or
  `{used_percent, limit_window_seconds, reset_at?(epoch s), reset_after_seconds?}`.
  `resetsAt` is `reset_at`; otherwise it is fetch time plus
  `reset_after_seconds`; otherwise it is `null`. Unknown keys are ignored.
- Offline fallback: the newest `token_count` event that has a non-null
  `rate_limits` object, read from
  `<codex home>/sessions/**/*.jsonl`.
  - The event shape is `{"timestamp":..., "type":"event_msg",
    "payload":{"type":"token_count","rate_limits":{"primary":{used_percent,
    window_minutes, resets_at?},"secondary":...,"plan_type"?}}}`.
  - Window length is `window_minutes * 60`.
  - `resetsAt` is `resets_at` (epoch seconds), otherwise the event timestamp
    plus `resets_in_seconds`, otherwise `null`.
  - File discovery reuses `UsageEventLogReader.jsonlFiles` on that single
    root. Files are visited newest modification time first, at most 10 files.
    Each file is read from the end with
    `UsageEventLogReader.forEachLineFromEnd`, filtered on
    `"type":"token_count"`. The first match wins.
  - The observation time is the event `timestamp`.

### Window classification

Each window is classified by length, never by position:

| Length (seconds) | Kind |
| --- | --- |
| 18000 | `fiveHour` |
| 604800 | `weekly` |
| any other length | `other` |

For Codex, `primary` is classified first, then `secondary`. If two windows
resolve to the same kind, the first one keeps the slot and the second goes to
`otherWindows`. A weekly-only `primary` with a `null` `secondary` therefore
produces `weekly` set and `fiveHour = null`.

## Derived Model

`ProviderRateLimits` has one entry per provider, `claude` then `codex`:

- `provider`: `claude` | `codex`.
- `status`: `ok` | `stale` | `unauthorized` | `unavailable`.
- `errorCode`: `null`, or one of the closed codes `credentials_missing`,
  `credentials_unreadable`, `token_expired`, `unauthorized`, `rate_limited`,
  `http_error`, `network_error`, `timeout`, `invalid_response`.
- `message`: `null`, or fixed application-owned text chosen by `errorCode`.
  It never contains remote text, error descriptions, paths, or headers.
- `planType`: a string or `null`.
- `fetchedAt`: the instant the windows were observed. For JSONL fallback it is
  the event timestamp. It is `null` when there are no windows.
- `stale`: a boolean. It is `true` exactly when `status == stale`.
- `fiveHour` and `weekly`: a `RateLimitWindow` or `null`.
- `otherWindows`: `[RateLimitWindow]`, possibly empty.

`RateLimitWindow` has these fields:

- `kind`;
- `windowSeconds`;
- `usedPercent`: the decoded percent, which must be finite and non-negative,
  otherwise the result is `invalid_response`;
- `remainingPercent`: `min(max(100 - usedPercent, 0), 100)`;
- `resetsAt`: ISO 8601 or `null`.

The pie fraction is `min(usedPercent, 100) / 100`. The filled wedge means
"used", the same meaning as the budget pie.

### Status rules

| Live result | Fallback available | Status | errorCode |
| --- | --- | --- | --- |
| HTTP 200, decodable | - | `ok` | `null` |
| Claude `expiresAt <= now` (no request sent) | Claude: none | `unauthorized` | `token_expired` |
| HTTP 401 or 403 | Codex JSONL or last-good | `stale` | `unauthorized` |
| HTTP 401 or 403 | none | `unauthorized` | `unauthorized` |
| Any other failure | Last-good or Codex JSONL | `stale` | the failure code |
| Any other failure | none | `unavailable` | the failure code |

Fallback rules:

- **Last-good fallback.** This is the most recent `ok` result for the provider,
  held in memory only. It is used before the Codex JSONL fallback when its
  `fetchedAt` is newer than the JSONL event. Claude gets a last-good fallback
  for every failure except `token_expired` and `unauthorized`. Those two always
  report `unauthorized`, so the user sees that the Claude CLI must refresh.
- **Window expiry.** A window in a stale result whose `resetsAt` is at or
  before `now` is replaced with `null`, because it no longer describes the
  current window. If every window is dropped, the status becomes
  `unavailable`, and `errorCode` keeps the live failure code.
- **No token refresh.** No code path performs token refresh. Status
  `unauthorized` is the only signal; the CLIs refresh their own tokens.

## Fetch, Cache, and Isolation

`RateLimitUsageService` is an actor. One instance is shared per process.

- **Injected dependencies:** a `RateLimitCredentialProvider` for each
  provider, a `RateLimitHTTPTransport`, a Codex session-fallback reader, a
  clock `@Sendable () -> Date`, and a minimum interval (default 60 seconds).
- **`current()`** returns both providers and never throws. Each provider's
  fetch runs concurrently and is isolated. An error, timeout, or decoding
  failure in one provider is captured only in that provider's entry.
- **Throttle.** For each provider, if `now - lastAttemptAt < minimumInterval`,
  the cached `ProviderRateLimits` is returned, whatever its status. Otherwise
  one fetch runs. Concurrent callers share the in-flight task. `lastAttemptAt`
  is set when the attempt starts, so failures are throttled too. Both dashboard
  polling and menu-bar polling are bounded by this throttle.
- **Credential lifetime.** Credentials are read fresh on every attempt and
  dropped when the attempt ends. Tokens are never cached, so a token the CLI has
  refreshed is picked up on the next attempt.
- **Transport.**
  - The production transport uses an ephemeral `URLSession` with no URL cache
    and no cookie storage.
  - The request timeout is 15 seconds.
  - Redirects are refused and reported as `http_error`, so a redirect can never
    forward the bearer token.
  - Status 429 maps to `rate_limited`.
  - Any other non-2xx status except 401 and 403 maps to `http_error`.
- **Token wrapper.** Token values are held in a redacting wrapper whose
  `description` and `debugDescription` print `<redacted>`.

Credential reads and HTTP use only the protocols, so tests inject fixtures and
never touch the network, Keychain, or real home directories.

## HTTP API

`GET /api/rate-limits` returns 200 with
`{"generatedAt": ISO8601, "scope": "local", "providers": [ProviderRateLimits, ProviderRateLimits]}`.

- The route is read-only. Methods other than GET return 405, and query
  parameters are ignored. `scope: "local"` states that the data belongs to the
  host's own CLI accounts, whatever machine is selected in the dashboard.
- The route is handled before snapshot loading and before machine or directory
  parameter parsing, on both surfaces:
  - plain `DashboardRouter` (`HTTPService.swift`), inside its `/api/` branch;
  - `MachineDashboardRouter`, before `queryRoute`. When a machine router is
    present, `HTTPService.swift:461` hands every `/api/*` request to it, so it
    must answer here.

  A ccusage, snapshot, or collection failure therefore cannot affect this
  route, and this route cannot affect them.
- Both routers take an optional `RateLimitUsageService` (default `nil`). With
  `nil`, the route returns 503 `rate_limits_unavailable`.
  - Production construction sites pass one shared production instance:
    `Sources/AppCLI/Runtime.swift` for both `serve` and the desktop window,
    and `Sources/CCUsageGaugeMenuBar/MenuBarApp.swift`.
  - The menu-bar process passes the same instance to its router and to its
    own pie rendering.
  - Response encoding lives in a shared helper in
    `HTTPService+RateLimits.swift`.
- The payload contains only derived numbers, status values, plan type, and
  timestamps. It never contains access or refresh tokens, account IDs,
  credential paths, raw upstream bodies, or upstream error text. Tests assert
  this by encoding a response built from fixtures that hold sentinel token and
  account values, then checking that the sentinels are absent.

## Pie Chart Selection

`PieChartID` is a closed set, in canonical order: `budget`, `claude5h`,
`claudeWeekly`, `codex5h`, `codexWeekly`.

Normalization is shared by both stores:

- unknown values are dropped;
- duplicates are removed;
- values are sorted into canonical order;
- an empty result becomes `[budget]`.

Both stores decode the field with `decodeIfPresent`, so a file without it
decodes to `[budget]`. This keeps the current behavior and the user's existing
budget, cycle, and baseline values.

The dashboard and the menu bar keep separate selections (QA decision 1):

- **Dashboard:** `DashboardUIState.pieCharts`. It persists through the
  existing `GET`/`PUT /api/dashboard-state` and the SQLite
  `DashboardStateStore`, so there is no new mutation route. `validate()`
  rejects more than 5 entries.
- **Menu bar:** `AppState.menuBarPieCharts` in `state.json`. It persists
  through `StateStore` and the existing `mutateState`. Budget and aggregation
  mutations already go through that path, and it remains menu-bar only.

## Dashboard Frontend

- **`frontend/src/api.ts`.** Adds `RateLimitsResponse`, the
  `PieChartID` type, and the optional `pieCharts` field on `DashboardUIState`.
  If the field is absent, the dashboard uses `["budget"]`.
- **Rate-limit state module (new).** It fetches `/api/rate-limits` at page
  load and on the existing refresh timer, at the effective menu-bar interval
  from `/api/budget`. The server throttle bounds upstream calls. A failure of
  this request affects only the rate-limit panel and the rate-limit pies.
- **`RateLimitPanel.tsx` (new).** For Claude Code and Codex, it shows the 5h
  and weekly rows with:
  - remaining percent;
  - time to reset, computed from `resetsAt` and client time, for example
    "resets in 2h 13m", or "reset time unknown" when it is `null`;
  - a status label: unauthorized shows "Sign in again with the CLI", stale
    shows "as of <time>", and unavailable shows the fixed message.

  It is labeled as this Mac's account data. `otherWindows` is not rendered.
- **`PieChartPanel.tsx` (new).**
  - It renders the selected pies side by side as flat SVG, following the theme
    rules in `design-dashboard-dark-flat-effort-grouping.md`.
  - The budget pie uses `budget.visualFraction` from the existing
    `/api/budget`, so it follows the selected machine scope. When no budget is
    set, it shows the existing "No budget set" state.
  - A rate-limit pie with no window shows an empty ring and the provider
    status.
- **Settings control.** Five toggle buttons with `aria-pressed`. The last
  pressed button is disabled, so the selection cannot become empty. A change
  persists through the existing dashboard-state save path.
- **`App.tsx`.** Changes are limited to mounting the two components and
  threading the selection through the existing state apply and save code.
  `App.tsx` is already 1330 lines, so it gets no new logic.

## Menu-Bar App

- **Settings submenu.** A "Pie charts" submenu has five checkable items in
  canonical order. Toggling an item persists `menuBarPieCharts` through
  `mutateState`. The only checked item is disabled.
- **Status glyph.**
  - The selected pies render side by side in one template image: 18 pt each
    with 2 pt gaps.
  - The budget pie keeps today's exact rendering, including the warning
    triangle on ccusage failure.
  - A rate-limit pie fills its used fraction. When it has no window, it shows
    the rail with the existing center marker.
  - The status title text, cost and budget percentage, is unchanged.
  - The accessibility description lists the selected charts and their values.
- **Dropdown.** The existing budget view stays first whenever `budget` is
  selected. Each selected rate-limit pie adds one non-interactive row, for
  example "Claude Code 5h: 53% left, resets in 2h 13m", or a status text such
  as "unauthorized".
- **Data flow.**
  - Data comes in-process from the shared `RateLimitUsageService`, in the same
    way the menu bar already uses in-process `AppCore` services for budget
    data.
  - Each poll tick calls `current()` only when the selection contains a
    rate-limit chart. The default selection, `[budget]`, therefore makes no
    new network requests and no Keychain reads.
  - Rendering stays on the main actor, and fetching runs off it.
  - The existing `appliedIconState` dedup is extended to cover the multi-pie
    inputs, so the icon does not flicker.
- **Code placement.** New code goes in new files:
  - `PieChartMenu.swift` for the submenu;
  - `RateLimitMenuView.swift` for the dropdown rows;
  - `MenuBarPieStrip.swift` for composing the glyph, which reuses the
    `MenuBarPieIcon` drawing.

  `MenuBarApp.swift` (945 lines) gets only the hook-in and must stay below
  1000 lines.

## Security and Privacy

- **Read-only credentials.** Credential access is read-only: no Keychain
  writes and no writes under the Claude or Codex homes. There is no token
  refresh code.
- **Where tokens may appear.** Tokens and account IDs exist only in memory for
  the length of one attempt and are sent only to the two fixed HTTPS hosts.
- **Where tokens must not appear.** They are never logged, persisted, placed
  in error values, or added to API, UI, or test fixtures. Fixtures use obvious
  sentinels such as `test-access-token`.
- **Logging.** No new log records are added. The bootstrap logger is not used
  for rate-limit failures.
- **Keychain prompts.** Reading through `/usr/bin/security` relies on the
  item's existing access-control entry for that tool, so normally no prompt
  appears. If one does appear and is denied, or it times out, the result is
  `credentials_unreadable` and the provider degrades to `unavailable`.
- **README.** Documents the two endpoints, the credential sources, the
  in-memory-only handling, the 60-second throttle, the fact that opening the
  dashboard triggers rate-limit fetches, and the default menu-bar behavior of
  no fetches.

## Verification

Unit tests live in `Tests/AppCoreTests/RateLimitUsage*Tests.swift`, plus
state decoding tests:

1. Decoding the exact Claude sample. Unknown keys are ignored. Null or absent
   `seven_day_opus`, `seven_day_sonnet`, and windows are allowed. The
   microsecond `+00:00` `resets_at` value parses.
2. Decoding the exact Codex sample. Windows are classified by
   `limit_window_seconds`, including weekly-only `primary` with `null`
   `secondary`, an 18000-second `secondary`, and a generic length placed in
   `otherWindows`.
3. JSONL fallback picks the newest `token_count` `rate_limits` event, uses
   `window_minutes`, sets `stale` and `fetchedAt` to the event timestamp, and
   drops windows whose reset time has passed.
4. A Claude token with `expiresAt` in milliseconds that is in the past maps to
   `unauthorized`/`token_expired` with zero transport calls. HTTP 401 maps to
   `unauthorized`. No refresh request is ever issued: the transport fixture
   records every URL.
5. Per-provider isolation: one provider fails or throws while the other stays
   `ok`.
6. Throttle: with an injected clock, a second call before 60 seconds performs
   no transport call, and a call at or after 60 seconds performs one.
   Concurrent calls share one in-flight fetch.
7. `/api/rate-limits` through plain `DashboardRouter` and through
   `MachineDashboardRouter`. The sentinel token and account ID are absent from
   the body. A `nil` service returns 503, and a non-GET method returns 405.
8. `AppState` and `DashboardUIState` decode without the new field to
   `[budget]`, and normalization drops unknown and duplicate values.

Frontend tests in `frontend/tests/` cover response parsing, reset-time
formatting, pie selection normalization and persistence, and panel status
labels.

The gate is `mise run build`, `mise run test`, `mise run lint`,
`mise run frontend:check`, and `mise run frontend:test`. An optional manual
smoke test runs `swift run ccusage-gauge serve` and curls
`/api/rate-limits`, then confirms that no token or account ID appears.
