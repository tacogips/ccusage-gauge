# Subscription Rate Limits and Selectable Pie Charts

## Status

Accepted (2026-10-31). Source: workflow request "Add Claude Code and Codex
5h/weekly subscription rate-limit module with selectable multi-pie charts
(dashboard + menu bar)". There is no GitHub issue number. Default decisions and
open questions are recorded in
`design-docs/user-qa/2026-10-31-subscription-rate-limit-decisions.md`.

Implementation state (2026-10-31): plans rl-01 to rl-08 are implemented in the
working tree but not committed. rl-09 (production factory, process wiring,
menu-bar hook-in, integration test, asset rebuild, full gate) is not started.
The section "Integration Wiring and Rollout" below is the contract for the
remaining work.

Update (2026-10-31, later): the feature above is committed as `f5092bf`. The
section "Configurable Ratio Text" adds a menu-bar ratio-text selection and a
dashboard per-pie ratio visibility. Its decisions are recorded in
`design-docs/user-qa/2026-10-31-ratio-text-decisions.md`.

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

| Provider | Live result | Fallback available | Status | errorCode |
| --- | --- | --- | --- | --- |
| both | HTTP 200, decodable | - | `ok` | `null` |
| Claude | `expiresAt <= now` (no request sent) | ignored | `unauthorized` | `token_expired` |
| Claude | HTTP 401 or 403 | ignored, even with last-good | `unauthorized` | `unauthorized` |
| Codex | HTTP 401 or 403 | Codex JSONL or last-good | `stale` | `unauthorized` |
| Codex | HTTP 401 or 403 | none | `unauthorized` | `unauthorized` |
| both | Any other failure | Last-good or Codex JSONL (Codex only) | `stale` | the failure code |
| both | Any other failure | none | `unavailable` | the failure code |

The per-provider rows above match the Status Algorithm in
`impl-plans/active/rl-01-core-contracts-service.md`, which is authoritative
for edge cases.

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
  - The status title text is governed by the ratio-text selection described
    in "Configurable Ratio Text". With the default selection it is today's
    cost and budget percentage text, unchanged.
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
    `MenuBarPieIcon` drawing;
  - `MenuBarApp+PieCharts.swift` for the hook-in methods (polling helper,
    toggle action, glyph entries, dropdown rows).

  `MenuBarApp.swift` (945 lines) gets only the minimal hook-in calls and must
  stay below 1000 lines.

## Integration Wiring and Rollout

This section pins the rl-09 boundary against the code present on 2026-10-31.

- **Production factory.** `RateLimitUsageService.production(environment:)`
  in `Sources/AppCore/RateLimitUsageProduction.swift` composes the existing
  types and adds nothing else:
  - `ClaudeRateLimitFetcher(credentials: ClaudeCredentialProvider(environment:), transport:)`;
  - `CodexRateLimitFetcher(credentials: CodexCredentialProvider(environment:), transport:)`;
  - one `URLSessionRateLimitTransport()` shared by both fetchers;
  - `CodexRateLimitSessionFallback(sessionsRoot: CodexHome.url(environment:)/sessions)`;
  - the default 60-second interval and the system clock.

  Construction performs no file, Keychain, process, or network I/O. All of
  that happens only inside `current()`.
- **One instance per process.**
  - `Sources/AppCLI/Runtime.swift`: create the service once and pass it as
    `rateLimitService:` to the single `MachineDashboardRouter` (currently at
    line 129). That router serves both the desktop window and
    `DashboardRouter(machineRouter:)` (line 156), so `serve` and the desktop
    window share one throttle.
  - `Sources/CCUsageGaugeMenuBar/MenuBarApp.swift`: a stored service created
    with the app, passed to the `MachineDashboardRouter` built in bootstrap
    (currently at line 256) and used by the menu-bar pies.
- **Menu-bar refresh ordering.**
  - `refreshRateLimitsIfNeeded()` runs on every `refresh()`. It must not sit
    behind the early returns at `MenuBarApp.swift:331-334` (no snapshot store)
    or :341-342 (nil snapshot, generation changed).
  - It reads the selection from `currentState` (set at bootstrap line 129, by
    `refresh()`, and by `mutateState`), defaulting to `[budget]`. It calls
    `current()` only when a non-budget chart is selected, stores the result,
    and then calls `updateStatusIcon()`.
  - `togglePieChart` persists through `mutateState` and calls
    `updateStatusIcon()`. It schedules no extra refresh, because `mutateState`
    already does (`MenuBarApp.swift:576`).
  - If bootstrap fails, there is no poll loop and no snapshot service. The
    rate-limit pies then show the no-data ring. This is accepted; it is the
    same state as a ccusage failure today.
- **Dashboard assets.** `Sources/AppCore/Resources/Web` is regenerated only by
  `mise run build` (through `scripts/sync-frontend-assets.sh`, which deletes
  stale hashed files). The result is committed exactly as generated.
- **Build side effects.** `.build/`, `frontend/dist/`,
  `frontend/node_modules/`, and `tmp/` are git-ignored side effects of the
  gate commands. The plan that runs the full gate declares them in its
  dispatch-manifest `artifactRoots` and `writePaths`. This explicit operator
  authorization overrides the manifest's `evidenceLayout` text that forbids
  listing build caches.
- **Repairs.** rl-01 to rl-08 are the baseline. Defects found in review are
  fixed by targeted repair plans whose `writePaths` name the exact files they
  touch, with no overlap between plans that run in parallel.
- **Commit.** One focused local commit on `main` covers rl-01 to rl-09, the
  repairs, plan progress logs, and the README. Files are staged by explicit
  path. `.riela/` (including `.riela/retention/`, which `.gitignore` does not
  cover) and `tmp/` are never staged. Nothing is pushed, merged, or rebased.

## Configurable Ratio Text

Source: workflow request "Configurable usage-ratio text for menu bar status
item and dashboard pie panel" (no GitHub issue). Decisions:
`design-docs/user-qa/2026-10-31-ratio-text-decisions.md`.

The goal is to let the user show, for example, only the Claude Code weekly and
Codex weekly pies with their ratios, and hide the budget pie and budget text.
Ratio text is a separate selection from the pie selection. Selecting a pie
does not select its text, and the reverse is also true.

### Selection model (`AppCore`)

- **`RatioTextSelection`** is a new enum in `PieChartSelection.swift`, next to
  `PieChartSelection`. It does not reuse `PieChartSelection.normalized`, because
  that function turns an empty result into `[budget]`.
  - `defaultSelection` is `[budget]`.
  - `normalized(rawValues:)` and `normalized(_:)`:
    - drop unknown values;
    - remove duplicates;
    - sort into canonical `PieChartID.allCases` order.

    An empty result stays empty.
  - `toggled(_:in:)` adds or removes the id and then normalizes. There is no
    last-item lock, so removing the only id gives `[]`.
- **`AppState.menuBarRatioLabels: [PieChartID]`** is a new field in
  `state.json`. The memberwise init defaults it to `[budget]`. Decoding works
  as follows:
  - Missing key: `[budget]`.
  - Key present: `RatioTextSelection.normalized(rawValues:)` of the decoded
    array. So `[]` stays `[]`, and an array of only unknown values becomes
    `[]`.
  - The field is added to `CodingKeys`, so it is also encoded. `StateStore.save`
    adds no validation for it, because decoding already normalizes it.

### Status title composition (`AppCore`)

- **Budget segment.** The budget segment is the exact string that
  `MenuBarApp` passes to `updateStatusTitle(_:)` today. That covers each of
  these forms:
  - `statusTitle(snapshot)`, which is `<cost> · <pct>`, or just `<cost>` when
    no budget is set;
  - `"$—"`;
  - `"$!"`;
  - `<statusTitle> !`.

  It is not reformatted.
- **Rate-limit label.** `RateLimitDisplayFormatting.ratioLabel(for:in:)`
  returns `<short name> <n>%` or `<short name> --`.

  | `PieChartID` | Short name |
  | --- | --- |
  | `claude5h` | `Claude 5h` |
  | `claudeWeekly` | `Claude W` |
  | `codex5h` | `Codex 5h` |
  | `codexWeekly` | `Codex W` |

  - `n` is `Int((pieFraction * 100).rounded())`, using the existing
    `RateLimitWindow.pieFraction`. This is the same used-percent value as the
    pie and its accessibility text, clamped to 0-100.
  - The label is `--` when `entry(for:in:).window` is `nil`. That covers
    these cases:
    - no response yet;
    - the provider is missing;
    - the window is `null`;
    - the provider is `unauthorized` or `unavailable`;
    - a stale window whose reset time has passed and was dropped.

    A stale window that is still valid shows its value without a marker. The
    dropdown row already shows "(stale)".
- **Composition.** `RateLimitDisplayFormatting.statusTitle(selection:budgetText:response:)`
  is a pure function. It maps the normalized ratio selection, in canonical
  order, to segments:
  - `budget` maps to the budget segment;
  - any other id maps to its rate-limit label.

  The segments are joined with `" · "`.
  - `[budget]` returns `budgetText` unchanged, byte for byte.
  - `[]` returns `""`.
  - `[claudeWeekly, codexWeekly]` returns, for example,
    `Claude W 59% · Codex W 83%`.

### Menu-bar wiring

`MenuBarApp.swift` has 951 lines and must stay under 1000. It gets only these
edits:

1. **New stored property.** `budgetStatusText: String`, initialized to `"$—"`,
   is internal so that extensions can read it.
2. **`updateStatusTitle(_:)` changes.** It becomes internal and treats its
   argument as the budget segment. It stores that segment in
   `budgetStatusText`, then composes the title with `statusTitle(selection:
   menuBarRatioSelection(), ...)` against `latestRateLimits`. The existing
   `appliedTitle` deduplication, the `button.title` assignment, the
   `setAccessibilityValue` call, and the `updateStatusIcon()` call then apply
   to the composed string. No call site changes.
3. **New Settings item.** One line adds the "Ratio text" item directly after
   the existing "Pie charts" item in the Settings submenu.

The remaining code goes in existing satellite files:

- **`MenuBarApp+PieCharts.swift`.**
  - `menuBarRatioSelection()` returns `RatioTextSelection.normalized` of
    `currentState?.menuBarRatioLabels`, or `[budget]` when there is no state.
  - `refreshRateLimitsIfNeeded()` now fetches when
    `menuBarPieSelection() + menuBarRatioSelection()` contains a non-budget id.
    After storing `latestRateLimits`, it calls
    `updateStatusTitle(budgetStatusText)` instead of `updateStatusIcon()`. That
    one call recomposes the title and refreshes the glyph, so a rate-limit
    label never goes stale.
  - `@objc toggleRatioLabel(_:)` persists
    `RatioTextSelection.toggled(id, in: $0.menuBarRatioLabels)` through
    `mutateState`. On success it calls `updateStatusTitle(budgetStatusText)`.
    `mutateState` already schedules `refresh()`, so a newly needed fetch runs
    there and is bounded by the service throttle. Until data arrives, the new
    label shows `--`.
- **`PieChartMenu.swift`.** It adds
  `ratioTextItem(selection:target:action:)`, titled "Ratio text". The item has
  five checkable children in canonical order, using the same titles as "Pie
  charts" (`RateLimitDisplayFormatting.title(for:)`). All children are always
  enabled.

Behavior notes:

- **Glyph-only title.** With `[]`, the title is `""`. The status item is
  `variableLength` with `.imageLeading`, so it shrinks to the glyph. The
  accessibility value becomes `""`. The pie image's accessibility description,
  from `pieAccessibilityDescription()`, still lists every selected chart with
  its value.
- **Warning markers.** The `$!` and ` !` markers belong to the budget segment.
  When `budget` is not in the ratio selection, they are hidden with it. The
  warning is still shown by these existing channels, which this change leaves
  alone:
  - the status button tooltip;
  - the accessibility label;
  - the budget pie's warning triangle, when that pie is selected.

  See QA decision R4.
- **Unchanged behavior.**
  - The pie strip, the dropdown rows, and the budget view all follow the pie
    selection, as they do today.
  - The fetch semantics, the throttle, credential handling, and the
    `/api/rate-limits` payload are the same, apart from the wider gate. With
    the default selections, `[budget]` pies and `[budget]` ratio text, there
    are still no rate-limit fetches and no Keychain reads.

### Dashboard

- **`DashboardUIState.hiddenPieRatios: [PieChartID]`.** This is a hidden-set,
  and its default is `[]`, which means every selected pie shows its ratio text.
  That matches today's rendering.
  - Decoding uses `decodeIfPresent`, then `RatioTextSelection.normalized(rawValues:)`.
    A missing key or `[]` gives `[]`.
  - `validate()` adds `hiddenPieRatios.count <= PieChartID.allCases.count`.
    Old persisted state, which lacks the key, still loads and validates.
  - The field persists through the existing `GET`/`PUT /api/dashboard-state`
    and SQLite store. There is no new route.
- **Hidden-set lifecycle.** The hidden-set is independent of
  `DashboardUIState.pieCharts`. Deselecting a pie keeps its hidden entry, and
  the entry takes effect again if the pie is reselected. Ids that are not
  selected have no visible effect.
- **`frontend/src/api.ts`.** Adds the optional field
  `hiddenPieRatios?: PieChartID[]`.
- **`frontend/src/rateLimits.ts`.** Adds two pure helpers:
  - `normalizeHiddenPieRatios(value: unknown)` uses canonical order, drops
    unknown values and duplicates, and allows an empty result;
  - `toggleHiddenPieRatio(id, hidden)` has no lock.
- **`frontend/src/App.tsx`.** Changes are limited to threading:
  - a `hiddenPieRatios` signal, default `[]`;
  - one line in the dashboard-state `apply` that normalizes the loaded value;
  - one field in the save-state object;
  - two props on `<PieChartPanel>`.

  There is no new logic.
- **`frontend/src/PieChartPanel.tsx`.** Each `pie-item` gets a toggle button.
  - Its `aria-pressed` is `true` when the ratio is visible.
  - Its accessible name is `Show ratio text for <label>`.
  - When the ratio is hidden, the item omits its detail `<span>`. That span
    holds the `n% used` text or the status text, such as "No budget set".

  The SVG `aria-label` keeps the full detail, so screen-reader output does not
  change. The pie toggles and the "Menu budget" summary line do not change.
- **Bundled assets.** `Sources/AppCore/Resources/Web` is regenerated with
  `mise run build` and committed exactly as generated.

### Verification

- **Swift tests (`Tests/AppCoreTests`).**
  - `RatioTextSelection` normalizes and toggles, including toggling off the
    last id to get `[]`.
  - `AppState` decoding:
    - missing key gives `[budget]`;
    - explicit `[]` gives `[]`, and it round-trips through `StateStore` as
      `[]`;
    - unknown and duplicate values are dropped.
  - `DashboardUIState` decoding:
    - missing key gives `[]`, and the state validates;
    - unknown and duplicate values are dropped;
    - the field round-trips.
  - `statusTitle(selection:budgetText:response:)` covers these cases:
    - `[budget]` returns `budgetText` unchanged for `"$12.34 · 45%"`, `"$!"`,
      and `"$12.34 · 45% !"`;
    - `[]` returns `""`;
    - `[claudeWeekly, codexWeekly]` returns `Claude W 59% · Codex W 83%`;
    - `[claude5h]` with a `nil` window returns `Claude 5h --`, and the same
      applies with a `nil` response;
    - `[budget, codex5h]` returns `<budget> · Codex 5h <n>%`.
  - The four short names are each pinned.
- **Frontend tests (`frontend/tests/rateLimits.test.ts`).** They cover
  `normalizeHiddenPieRatios` and `toggleHiddenPieRatio`. A source guard in
  `appMarkupGuards.test.ts` checks two things:
  - `PieChartPanel.tsx` renders the detail span conditionally and exposes the
    per-pie ratio toggle;
  - `App.tsx` includes `hiddenPieRatios` in the saved state.
- **Gate.** `mise run build`, `mise run test`, `mise run lint`,
  `mise run frontend:check`, and `mise run frontend:test` each exit 0. Every
  Swift file is under 1000 lines (`wc -l`).
- **Manual menu-bar check.** This check is optional and is recorded as
  skipped when there is no GUI session. Set pies to
  `[claudeWeekly, codexWeekly]` and ratio text to
  `[claudeWeekly, codexWeekly]`. The status item should show two pies and
  `Claude W n% · Codex W n%`, with no budget pie and no budget text.

### Rollout constraints

- Dispatch-manifest `artifactRoots` must never be the bare `tmp` directory.
  Riela fanout evidence lives under `tmp/opus-terra-waves`. For this feature
  only, this rule replaces the `tmp/` allowance in "Integration Wiring and
  Rollout" and in QA decision 8. Declare only these roots, and list the same
  paths in `writePaths`:
  - `.build`;
  - `frontend/dist`;
  - `frontend/node_modules`;
  - a plan-specific directory such as `tmp/ratio-text-20261031`.
- The work is one local commit on `main`. Stage files by explicit path, and
  never stage `.riela/` (including the pre-existing `.riela/retention/*`) or
  `tmp/`. Nothing is pushed, merged, or rebased.

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
9. `Tests/AppCoreTests/RateLimitUsageIntegrationTests.swift` composes the
   real Claude and Codex fetchers with fake credential providers holding the
   sentinels `test-claude-access-token`, `test-codex-access-token`, and
   `test-codex-account-id`, and a recording transport returning the exact
   samples. Through both `DashboardRouter` and `MachineDashboardRouter`:
   - no sentinel appears in the body;
   - Claude `fiveHour.remainingPercent == 100` and
     `weekly.remainingPercent == 47`;
   - Codex `weekly.usedPercent == 82` and `fiveHour == null`;
   - the transport saw exactly two URLs, none containing `token` or
     `refresh`.

   `production(environment: ["HOME": <temp dir>])` is constructed without
   calling `current()`, because that would reach the network.

Frontend tests in `frontend/tests/` cover response parsing, reset-time
formatting, pie selection normalization and persistence, and panel status
labels.

The gate is `mise run build`, `mise run test`, `mise run lint`,
`mise run frontend:check`, and `mise run frontend:test`. Each runs in the
foreground with `set -o pipefail` and its output teed to a `tmp/` log, and its
exit code and log path are recorded. The gate also checks:

- every Swift file is under 1000 lines (`wc -l`);
- `grep -rn "refresh_token\|refreshToken\|oauth/token" Sources/AppCore Sources/CCUsageGaugeMenuBar Sources/AppCLI`
  finds no match;
- `git status --short` shows only feature files plus `.riela/retention/`,
  which stays unstaged.

Two checks are optional and are recorded as skipped, with the reason, when
the runner cannot do them:

- a live smoke test, only under an explicitly owned service lifecycle: run
  `swift run ccusage-gauge serve`, curl `/api/rate-limits`, filter the body
  through `grep -c`, and record only the count and the status values;
- a manual menu-bar check that the glyph updates right after a rate-limit pie
  is toggled, which needs an interactive GUI session.
