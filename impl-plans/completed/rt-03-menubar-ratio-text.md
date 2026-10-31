# rt-03: Menu-Bar Ratio-Text Submenu and Status-Title Wiring

**Status**: Completed
**Wave**: 2 (depends on rt-01)
**Design Reference**: `design-docs/specs/design-subscription-rate-limits.md`,
section "Configurable Ratio Text", subsections "Menu-bar wiring" and "Behavior
notes". Decisions R1 to R4 and R9 are in
`design-docs/user-qa/2026-10-31-ratio-text-decisions.md`.

## Intent and Context

Today the macOS status item always shows the budget text `<cost> · <pct>`.
`MenuBarApp.statusTitle(_:)` (`MenuBarApp.swift:737`) builds that text, and
`updateStatusTitle(_:)` (`MenuBarApp.swift:752`) applies it. The user wants a
"Ratio text" multi-select in Settings, next to "Pie charts", that chooses
which ratios appear as text. The user's target is pies
`[claudeWeekly, codexWeekly]` with ratio text `[claudeWeekly, codexWeekly]`,
giving the title `Claude W n% · Codex W n%` with no budget text.

rt-01 provides these symbols (do not modify them):

- `AppState.menuBarRatioLabels`;
- `RatioTextSelection.normalized(_:)` and `toggled(_:in:)`;
- `RateLimitDisplayFormatting.statusTitle(selection:budgetText:response:)`.

## Non-Goals

- Do not edit anything under `Sources/AppCore`, the tests, or the frontend.
- Do not change rate-limit fetching beyond widening the gate. That means no
  change to the service, the throttle, credentials, or `/api/rate-limits`.
- Do not change the pie strip, `pieEntries()`, `pieAccessibilityDescription()`,
  `RateLimitMenuView`, the budget dropdown view, `togglePieChart`, or
  `Self.statusTitle(_:)`.
- Do not change any existing `updateStatusTitle(...)` call site. They keep
  passing today's budget strings.
- Do not change tooltip or accessibility-label logic in `updateStatusIcon()`.

## writePaths

- `Sources/CCUsageGaugeMenuBar/MenuBarApp.swift`
- `Sources/CCUsageGaugeMenuBar/MenuBarApp+PieCharts.swift`
- `Sources/CCUsageGaugeMenuBar/PieChartMenu.swift`
- `tmp/ratio-text-20261031/rt-03` (git-ignored evidence logs; artifact root)
- `impl-plans/active/rt-03-menubar-ratio-text.md` (Progress Log only)

## File-Level Changes

### `MenuBarApp.swift`

This file is 951 lines. Add at most about 6 net lines, and keep it under 1000.

1. Next to `latestRateLimits` (around line 74), add a stored property
   `var budgetStatusText = "$—"`. Use the same em-dash string as line 100. It
   is internal so the extension file can read it.
2. Make `updateStatusTitle(_:)` internal by removing `private`, and give the
   parameter a budget-text meaning:
   - first store the argument in `budgetStatusText`;
   - then compose
     `RateLimitDisplayFormatting.statusTitle(selection: menuBarRatioSelection(), budgetText: <argument>, response: latestRateLimits)`;
   - then run the existing `appliedTitle` dedup, `button.title`,
     `setAccessibilityValue`, and `updateStatusIcon()` logic on the composed
     string.
3. In the Settings submenu builder, directly after the existing line 443
   (`submenu.addItem(PieChartMenu.item(...togglePieChart...))`), add one line:
   `submenu.addItem(PieChartMenu.ratioTextItem(selection: menuBarRatioSelection(), target: self, action: #selector(toggleRatioLabel(_:))))`.

### `MenuBarApp+PieCharts.swift`

- Add `func menuBarRatioSelection() -> [PieChartID]`, which returns
  `RatioTextSelection.normalized(currentState?.menuBarRatioLabels ?? RatioTextSelection.defaultSelection)`.
- Change `refreshRateLimitsIfNeeded()`:
  - the guard becomes "`menuBarPieSelection()` or `menuBarRatioSelection()`
    contains a non-budget id". It still returns before any `await` when
    neither does;
  - after `latestRateLimits = await rateLimitService.current()`, call
    `updateStatusTitle(budgetStatusText)` instead of `updateStatusIcon()`.
    `updateStatusTitle` recomposes the title and then calls
    `updateStatusIcon()`.
- Add `@objc func toggleRatioLabel(_ sender: NSMenuItem)`. Mirror
  `togglePieChart`:
  - parse `representedObject` as a `PieChartID` raw value;
  - in a `Task`, call
    `await mutateState { $0.menuBarRatioLabels = RatioTextSelection.toggled(id, in: $0.menuBarRatioLabels) }`;
  - on success, call `updateStatusTitle(budgetStatusText)`.
  - Do not schedule another refresh. `mutateState` already schedules one
    (`MenuBarApp.swift:588`).

### `PieChartMenu.swift`

- Add
  `@MainActor static func ratioTextItem(selection: [PieChartID], target: AnyObject, action: Selector) -> NSMenuItem`.
  - The item title is `"Ratio text"`, and the submenu has
    `autoenablesItems = false`.
  - It has one child per `PieChartID.allCases`, in canonical order. Each
    child's title is `RateLimitDisplayFormatting.title(for:)`, its
    `representedObject` is `id.rawValue`, and its `state` is `.on` when
    selected.
  - Every child stays enabled (`isEnabled = true`). There is no last-item
    lock.

## Patterns to Imitate

- `Sources/CCUsageGaugeMenuBar/PieChartMenu.swift:item(selection:target:action:)`.
- `Sources/CCUsageGaugeMenuBar/MenuBarApp+PieCharts.swift:togglePieChart(_:)`
  and `menuBarPieSelection()`.
- The existing `appliedTitle` dedup in `MenuBarApp.swift:updateStatusTitle(_:)`.

## Key Pitfalls

- Default behavior must be byte-identical:
  - with no `menuBarRatioLabels` in `state.json`, or with
    `currentState == nil` at launch, the selection is `[budget]`;
  - so the title equals the argument exactly, including `"$—"`, `"$!"`,
    `"<cost> · <pct>"`, and `"<...> !"`.
- Use `RatioTextSelection`, never `PieChartSelection.normalized`, on the ratio
  selection. The latter turns `[]` into `[budget]`, which would make a
  glyph-only title impossible.
- `budgetStatusText` must be updated on every `updateStatusTitle` call,
  including calls that dedup to the same composed title. Otherwise a later
  recompose would use a stale budget string.
- `refreshRateLimitsIfNeeded()` must not `await` anything when both
  selections are `[budget]`. That keeps the default free of network and
  Keychain access.
- Do not call `updateStatusTitle(Self.statusTitle(...))` from the extension.
  Always pass `budgetStatusText`, the last budget string, so error markers
  are preserved.
- Selector names must match the `@objc` methods exactly. A mismatch compiles
  but crashes at click time, so check them by grep.
- Swift 6 strict concurrency: `MenuBarDelegate` is `@MainActor`. Keep new
  members on it. Do not add `nonisolated` or `@unchecked Sendable`.
- Do not grow `MenuBarApp.swift` with composition logic. Put logic in the
  extension or in `AppCore` (rt-01 already did the latter).

## Test Cases

The menu-bar target has no unit-test target. Its behavior is covered by:

- the `AppCore` composition tests in rt-01 (`RatioTextTests`);
- a compile check;
- grep-based structural checks;
- one optional manual check, which rt-04 records.

Structural expectations:

- `toggleRatioLabel` is reachable from `PieChartMenu.ratioTextItem`.
- `refreshRateLimitsIfNeeded` references both `menuBarPieSelection()` and
  `menuBarRatioSelection()`.
- `refreshRateLimitsIfNeeded` calls `updateStatusTitle(budgetStatusText)`.

## Verification

Run in the foreground from the repository root. Each command must exit 0.

1. `mkdir -p tmp/ratio-text-20261031/rt-03`
2. `set -o pipefail; swift build 2>&1 | tee tmp/ratio-text-20261031/rt-03/build.log`.
   This proves the menu-bar product compiles under Swift 6.
3. `set -o pipefail; swiftlint lint Sources/CCUsageGaugeMenuBar/MenuBarApp.swift Sources/CCUsageGaugeMenuBar/MenuBarApp+PieCharts.swift Sources/CCUsageGaugeMenuBar/PieChartMenu.swift 2>&1 | tee tmp/ratio-text-20261031/rt-03/swiftlint.log`.
   There must be no errors.
4. `test "$(wc -l < Sources/CCUsageGaugeMenuBar/MenuBarApp.swift)" -lt 1000`
5. `grep -n "toggleRatioLabel" Sources/CCUsageGaugeMenuBar/MenuBarApp.swift Sources/CCUsageGaugeMenuBar/MenuBarApp+PieCharts.swift | tee tmp/ratio-text-20261031/rt-03/selector.log`.
   Expect the `#selector` in `MenuBarApp.swift` and the `@objc func` in the
   extension.
6. `grep -c "menuBarRatioSelection()" Sources/CCUsageGaugeMenuBar/MenuBarApp+PieCharts.swift`.
   The count must be 2 or more: the gate plus any other uses.
7. `grep -n "updateStatusTitle(budgetStatusText)" Sources/CCUsageGaugeMenuBar/MenuBarApp+PieCharts.swift`.
   There must be 2 matches: the rate-limit refresh and the toggle.
8. `! grep -n "PieChartSelection.normalized(currentState?.menuBarRatioLabels" Sources/CCUsageGaugeMenuBar/*.swift`.
   This guards against the wrong normalizer.
9. `git diff --stat -- Sources/CCUsageGaugeMenuBar | tee tmp/ratio-text-20261031/rt-03/diffstat.log`.
   Only the three owned files may change.

## Done Criteria

- [x] "Ratio text" submenu is added right after "Pie charts", and all items
  are always enabled.
- [x] `updateStatusTitle` composes through
  `RateLimitDisplayFormatting.statusTitle` and stores `budgetStatusText`.
- [x] The rate-limit gate covers both selections, and the title is
  recomposed after each fetch.
- [x] Verification steps 2 to 9 pass, and their logs are complete.
- [x] `MenuBarApp.swift` is under 1000 lines (step 4).

## Progress Log

- 2026-10-31: Plan created.

- 2026-10-31: Implemented menu-bar ratio text; moved title update into the existing extension to satisfy strict type-body lint. Final `swift build`, selected-file SwiftLint including strict, structural checks, and diff check passed; MenuBarApp.swift is 942 lines. Evidence: `tmp/ratio-text-20261031/rt-03/`. Earlier strict lint and intermediate build failures were resolved. Formal review and rt-04 integration remain downstream.
- Source SHA-256 pre-edit: MenuBarApp.swift 8d5187f421c80d214901000ca77451172f3b0d58b3e984904898c479b3ce1ade; MenuBarApp+PieCharts.swift 70b8063143d4c9b71c4626a32aec492a3cc8c6242ee77763a148a30cfd9afb22; PieChartMenu.swift df3da3ccb6880579c867614cf2381d46011a6f8442bc3b5b861bf99be679dc15. Final hashes are recorded in `source-identity.log`.
- 2026-10-31: Completed. Test-integrity review, adversarial review (needs_revision=false) and the integration review accepted rt-03. The rt-04 full gate exited 0 on the joined tree (build, test, lint; logs under `tmp/ratio-text-20261031/rt-04/`). The manual GUI check was skipped, which is an accepted tradeoff. Archived to `impl-plans/completed/rt-03-menubar-ratio-text.md`.
