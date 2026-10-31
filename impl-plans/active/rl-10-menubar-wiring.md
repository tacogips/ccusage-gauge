# rl-10: Menu-Bar Hook-In for Rate Limits and Selectable Pies

**Status**: Planned
**Wave**: 2 of the continuation run
**Depends on**: rl-09, for `RateLimitUsageService.production(environment:)`
**Design Reference**: `design-docs/specs/design-subscription-rate-limits.md`,
sections "Menu-Bar App" and "Integration Wiring and Rollout" (One instance per
process, Menu-bar refresh ordering)

## Intent and Context

The menu-bar views exist from rl-08 but are not connected to anything:

- `Sources/CCUsageGaugeMenuBar/MenuBarPieStrip.swift` provides
  `MenuBarPieEntry` and `MenuBarPieStrip.image(entries:accessibilityDescription:)`;
- `PieChartMenu.swift` provides `PieChartMenu.item(selection:target:action:)`;
- `RateLimitMenuView.swift` provides `RateLimitMenuView.items(selection:response:now:)`;
- `Sources/AppCore/RateLimitDisplayFormatting.swift` provides `entry(for:in:)`,
  `title(for:)`, and `pieFraction(_:)`.

The persisted selection already exists as `AppState.menuBarPieCharts:
[PieChartID]` (`Sources/AppCore/State.swift:34`), and it decodes to
`[budget]` when absent.

This plan connects those pieces to `MenuBarDelegate`:

- one shared service;
- polling only while a rate-limit pie is selected;
- the Settings > Pie charts submenu;
- the multi-pie glyph;
- the dropdown rows.

`Sources/CCUsageGaugeMenuBar/MenuBarApp.swift` is 945 lines and must stay
under 1000. New methods therefore go in
`Sources/CCUsageGaugeMenuBar/MenuBarApp+PieCharts.swift`.

## Non-Goals

- No change to the status title text (`statusTitle`, `updateStatusTitle`),
  budget math, the snapshot logic, the generation guard, the polling interval,
  or `BudgetMenuView`.
- No edits to rl-08 files (`MenuBarPieStrip.swift`, `PieChartMenu.swift`,
  `RateLimitMenuView.swift`, `MenuBarPieIcon.swift`,
  `RateLimitDisplayFormatting.swift`) or to any `Sources/AppCore` file. If one
  needs a fix, record it in the Progress Log and stop. Do not fix it here.
- No new configuration keys, logging, or HTTP routes.
- Do not run `mise run build` or `frontend:build`.
- No git operations.

## writePaths

- `Sources/CCUsageGaugeMenuBar/MenuBarApp.swift`
- `Sources/CCUsageGaugeMenuBar/MenuBarApp+PieCharts.swift` (new)
- `impl-plans/active/rl-10-menubar-wiring.md` (Progress Log only)

`swift build` writes to the git-ignored `.build/`. The operator authorized
this as a command side effect; it is not a writePaths violation.

## File-Level Changes

### `MenuBarApp.swift`: minimal hook-in, about 25 net lines

1. **Stored properties** in `MenuBarDelegate`, near line 71. Extensions
   cannot hold stored properties, and the extension file must reach these, so
   they are internal rather than `private`:
   - `let rateLimitService = RateLimitUsageService.production()`
   - `var latestRateLimits: RateLimitsResponse?`
2. **Router.** In the `MachineDashboardRouter(...)` call at line 256, add the
   trailing argument `rateLimitService: rateLimitService`. The dashboard
   server started by the menu bar then shares the menu bar's throttle.
3. **`refresh()` ordering (PR-M2).**
   - Rename the existing body of `private func refresh() async` (lines
     329-357) unchanged to `private func refreshSnapshot() async`.
   - Add a new `private func refresh() async` that does exactly
     `await refreshSnapshot()` and then `await refreshRateLimitsIfNeeded()`.
   - This puts the rate-limit refresh after the state reload, but makes it
     independent of the early returns at the old lines 331-334 and 341-342.
   - Every existing caller of `refresh()` (polling loop, bootstrap,
     `mutateState`, `reloadSelectedMachines`) keeps calling `refresh()`.
4. **`StatusIconState`** (line 52) becomes
   `struct StatusIconState: Equatable { let entries: [MenuBarPieEntry]; let accessibility: String }`.
   - Relax `private` to internal only where the extension needs it, for
     example on `StatusIconState` and `appliedIconState`.
5. **`updateStatusIcon()`** (line 751):
   - Build the state as `StatusIconState(entries: pieEntries(), accessibility: pieAccessibilityDescription())`.
   - Keep the `appliedIconState != iconState` dedup.
   - Set the image with `MenuBarPieStrip.image(entries:accessibilityDescription:)`.
   - Keep `e2eIconView?.image = ...`.
   - Keep the accessibility label and tooltip lines (769-771) unchanged.
   - Relax `private` to internal on `updateStatusIcon` so the extension can
     call it.
6. **`populateMenu(_:)`** (line 359):
   - Wrap the existing budget block (the `latestSnapshot`, `budgetUSD`, and
     unavailable branches) in `if selection.contains(.budget) { ... }`, where
     `selection` comes from the extension helper `menuBarPieSelection()`.
   - The `if let errorMessage { ... errorDetailsItem ... }` block stays
     outside that condition, so it is always shown when present.
   - Right after the error item, before the separator, append
     `RateLimitMenuView.items(selection: selection, response: latestRateLimits, now: Date())`.
7. **`settingsItem()`** (line 414): before `root.submenu = submenu`, add
   `submenu.addItem(PieChartMenu.item(selection: menuBarPieSelection(), target: self, action: #selector(togglePieChart(_:))))`.

### `MenuBarApp+PieCharts.swift` (new)

`extension MenuBarDelegate` containing:

- `func menuBarPieSelection() -> [PieChartID]`: returns
  `PieChartSelection.normalized(currentState?.menuBarPieCharts ?? PieChartSelection.defaultSelection)`.
- `func refreshRateLimitsIfNeeded() async`:
  - If the selection has no chart other than `.budget`, return immediately,
    before any `await`. This means no `current()`, no Keychain, and no
    network access.
  - Otherwise, `latestRateLimits = await rateLimitService.current()`, then
    `updateStatusIcon()`.
- `@objc func togglePieChart(_ sender: NSMenuItem)`:
  - Read `sender.representedObject as? String`, then
    `PieChartID(rawValue:)`. Return when either is nil.
  - Then run:
    `Task { if await mutateState({ $0.menuBarPieCharts = PieChartSelection.toggled(id, in: $0.menuBarPieCharts) }) { updateStatusIcon() } }`.
  - Relax `mutateState` from `private` to internal.
  - Do not add `Task { await refresh() }`. `mutateState` already schedules
    one at `MenuBarApp.swift:576`.
- `func pieEntries() -> [MenuBarPieEntry]`: one entry per selected chart, in
  canonical order:
  - `.budget` -> `.budget(fraction: latestSnapshot?.budget.visualFraction, hasBudget: currentState?.budgetUSD != nil, warning: isUsageUnavailable || !collectionWarnings.isEmpty)`.
    These are exactly today's `StatusIconState` inputs.
  - any other chart ->
    `.rateLimit(fraction: RateLimitDisplayFormatting.pieFraction(RateLimitDisplayFormatting.entry(for: id, in: latestRateLimits).window))`.
- `func pieAccessibilityDescription() -> String`: joins with `", "` one item
  per selected chart:
  - for `.budget`: `"Budget"`;
  - for a rate-limit chart: `"<title> <n>% used"` when a window exists
    (`n = Int((fraction * 100).rounded())`), otherwise
    `"<title> unavailable"`, where `<title>` comes from
    `RateLimitDisplayFormatting.title(for:)`.
  - Do not include reset times. They change every minute and would defeat
    the icon dedup and cause a redraw every tick.

Relax `private` to internal on each member the extension reads:
`latestSnapshot`, `currentState`, `isUsageUnavailable`, `collectionWarnings`,
`mutateState`, `updateStatusIcon`, `StatusIconState`, and `appliedIconState`,
if used. Change only what the compiler requires. Do not reorder or
restructure anything else.

## Key Pitfalls

- **Default `[budget]` behavior must be unchanged.**
  - `MenuBarPieStrip.image` returns `MenuBarPieIcon.image(fraction:hasBudget:warning:)`
    unchanged for a single budget entry, so the glyph is byte-identical.
  - The dropdown is identical, because `RateLimitMenuView.items` returns
    `[]` for `[budget]`.
  - `refreshRateLimitsIfNeeded` never calls `current()`.
- **Bootstrap failure.** When bootstrap fails there is no polling and
  `snapshotService` is nil. The rate-limit pies show the no-data ring. This is
  accepted; do not add a polling path for it.
- **Main actor.** `MenuBarDelegate` is `@MainActor`.
  `await rateLimitService.current()` hops to the actor and does not block the
  main thread. Never use a semaphore or `Task.detached` with a blocking wait.
- **Line limit.** `MenuBarApp.swift` must stay below 1000 lines. Check with
  `wc -l`.
- **Secrets.** Never print or log `latestRateLimits`. It holds no secrets, but
  no new logging is allowed.

## Test Strategy

`CCUsageGaugeMenuBar` is an executable target with no unit-test target. The
formatting logic is already covered by `RateLimitDisplayFormattingTests` from
rl-08. This plan is verified by compilation, lint, line count, mechanical
source checks, and recorded code inspection:

- selection `[budget]` -> `refreshRateLimitsIfNeeded` returns before any
  `await`. Inspect the guard;
- selection `[budget, claude5h]` -> one `current()` call, then
  `updateStatusIcon()`. Inspect the ordering;
- `refresh()` with a nil `machineSnapshotStore` -> still reaches
  `refreshRateLimitsIfNeeded()`. Inspect the new `refresh()` body;
- toggle -> `mutateState`, then `updateStatusIcon()`, and no extra
  `refresh()`. Inspect.

## Verification

Run every command in the foreground. Create the directory first with
`mkdir -p tmp/subscription-rate-limits-20261031/rl-10`. Record each command's
exit code and log path in the Progress Log.

1. `swift build > tmp/subscription-rate-limits-20261031/rl-10/build.log 2>&1`:
   exit 0.
2. `swiftlint lint Sources/CCUsageGaugeMenuBar/MenuBarApp.swift Sources/CCUsageGaugeMenuBar/MenuBarApp+PieCharts.swift > tmp/subscription-rate-limits-20261031/rl-10/swiftlint.log 2>&1`:
   exit 0 with no violations in these files.
3. `wc -l Sources/CCUsageGaugeMenuBar/MenuBarApp.swift Sources/CCUsageGaugeMenuBar/MenuBarApp+PieCharts.swift > tmp/subscription-rate-limits-20261031/rl-10/wc.log 2>&1`:
   both files are under 1000 lines.
4. `grep -c 'RateLimitUsageService.production' Sources/CCUsageGaugeMenuBar/MenuBarApp.swift`:
   prints `1`.
5. `grep -n 'rateLimitService: rateLimitService' Sources/CCUsageGaugeMenuBar/MenuBarApp.swift`:
   exactly one match, inside the `MachineDashboardRouter(` call.
6. `grep -n 'await refresh()' Sources/CCUsageGaugeMenuBar/MenuBarApp+PieCharts.swift`:
   no match (exit 1), which shows the toggle schedules no extra refresh.
7. `grep -n 'refreshRateLimitsIfNeeded\|refreshSnapshot' Sources/CCUsageGaugeMenuBar/MenuBarApp.swift > tmp/subscription-rate-limits-20261031/rl-10/refresh-order.log 2>&1`:
   shows the new `refresh()` calling `refreshSnapshot()` and then
   `refreshRateLimitsIfNeeded()`. Paste the matched lines into the Progress
   Log.
8. `! grep -rn 'refresh_token\|refreshToken\|oauth/token' Sources/CCUsageGaugeMenuBar --include='*.swift'`:
   exit 0.
9. Manual glyph check: after toggling a rate-limit pie, the glyph updates
   without waiting for the next poll. This needs an interactive GUI session.
   Without one, record "skipped: no interactive GUI session in the runner".

## Done Criteria

- [ ] There is one service per menu-bar process, shared with its
  `MachineDashboardRouter`.
- [ ] `refresh()` always runs `refreshRateLimitsIfNeeded()` after
  `refreshSnapshot()`. The helper makes no `current()` call for `[budget]`
  and calls `updateStatusIcon()` after storing a result.
- [ ] The Pie charts submenu is present. `togglePieChart` persists through
  `mutateState` with no extra refresh.
- [ ] The glyph is built from `[MenuBarPieEntry]` with dedup. The dropdown
  keeps the budget block only when `budget` is selected and always keeps the
  error item.
- [ ] `MenuBarApp.swift` is under 1000 lines, and steps 1 to 8 are recorded.
  Step 9 is recorded or skipped with a reason.

## Progress Log

- 2026-10-31: Plan created. It is split out of the original rl-09.
