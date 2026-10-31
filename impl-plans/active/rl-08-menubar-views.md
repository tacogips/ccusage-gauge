# rl-08: Menu-Bar Pie Strip, Pie Chart Submenu, and Rate-Limit Menu Rows

**Status**: Planned
**Wave**: 2 (depends on rl-01 and rl-02)
**Design Reference**: `design-docs/specs/design-subscription-rate-limits.md`,
section Menu-Bar App. QA decision 7.

## Intent and Context

This plan builds the self-contained menu-bar pieces that rl-09 wires into
`MenuBarApp.swift`, which is 945 lines and must stay under 1000:

- the multi-pie status glyph;
- the "Pie charts" settings submenu;
- the dropdown rows for rate limits;
- testable text formatting in AppCore. The menu-bar executable target has no
  test target.

## Non-Goals

- Do NOT edit `Sources/CCUsageGaugeMenuBar/MenuBarApp.swift`; rl-09 owns
  it.
- No fetching. These views receive a `RateLimitsResponse?` and a selection.
- No change to the budget pie's look or to `BudgetMenuView`.

## writePaths

- `Sources/CCUsageGaugeMenuBar/MenuBarPieStrip.swift` (new)
- `Sources/CCUsageGaugeMenuBar/PieChartMenu.swift` (new)
- `Sources/CCUsageGaugeMenuBar/RateLimitMenuView.swift` (new)
- `Sources/CCUsageGaugeMenuBar/MenuBarPieIcon.swift`: only to change the
  drawing helpers from `private static` to internal `static`. Drawing output
  stays unchanged.
- `Sources/AppCore/RateLimitDisplayFormatting.swift` (new)
- `Tests/AppCoreTests/RateLimitDisplayFormattingTests.swift` (new)
- `impl-plans/active/rl-08-menubar-views.md` (Progress Log only)

## Contract

### AppCore: RateLimitDisplayFormatting.swift

`public enum RateLimitDisplayFormatting`:

- `static func entry(for chart: PieChartID, in response: RateLimitsResponse?) -> (provider: ProviderRateLimits?, window: RateLimitWindow?)`
  - `claude5h` maps to the Claude `fiveHour` window, `claudeWeekly` to the
    Claude `weekly` window, and likewise for Codex.
  - `budget` returns `(nil, nil)`.
- `static func title(for chart: PieChartID) -> String` returns "Budget",
  "Claude Code 5h", "Claude Code weekly", "Codex 5h", or "Codex weekly".
- `static func resetText(resetsAt: Date?, now: Date) -> String` returns:
  - "resets in 2h 13m" (hours and minutes) when the reset is less than one
    day away;
  - "resets in 3d 4h" when it is one day or more away;
  - "resets in <1m" when it is under one minute away;
  - "reset due" when the time is at or before `now`;
  - "reset time unknown" when it is nil.
- `static func menuLine(for chart: PieChartID, response: RateLimitsResponse?, now: Date) -> String`
  - With a window, the line is
    `"<title>: <remaining rounded>% left, <resetText>"`. If the provider is
    stale, append `" (stale)"`.
  - Without a window, the line is `"<title>: <status text>"`, where status
    text is "unauthorized - sign in again with the CLI", the provider
    `message` for unavailable, or "loading" when the response is nil.
- `static func pieFraction(_ window: RateLimitWindow?) -> Double?` returns
  `window?.pieFraction`.

### Menu bar: MenuBarPieStrip.swift

- Pin this exact type, because rl-09 depends on it:
  `enum MenuBarPieEntry: Equatable { case budget(fraction: Decimal?, hasBudget: Bool, warning: Bool); case rateLimit(fraction: Double?) }`.
- `enum MenuBarPieStrip { static func image(entries: [MenuBarPieEntry], accessibilityDescription: String) -> NSImage }`
  - Exactly one `.budget` entry: return
    `MenuBarPieIcon.image(fraction:hasBudget:warning:)` unchanged. This keeps
    today's default glyph byte-for-byte.
  - Otherwise: lay the entries out side by side, 18 pt each with 2 pt gaps.
    The image is a template (`isTemplate = true`).
    - A `.budget` entry uses the existing budget drawing, including the
      warning triangle.
    - `.rateLimit` with a fraction: rail plus a used wedge (reuse
      `drawRail` and `drawUsedWedge`).
    - `.rateLimit(nil)`: rail plus the existing center marker
      (`drawBudgetMarker`).

### Menu bar: PieChartMenu.swift

- `enum PieChartMenu { @MainActor static func item(selection: [PieChartID], target: AnyObject, action: Selector) -> NSMenuItem }`
  - Returns a "Pie charts" item whose submenu has 5 items in
    `PieChartID.allCases` order, titled with
    `RateLimitDisplayFormatting.title`.
  - Each item has `representedObject = id.rawValue` and
    `state = .on/.off`.
  - When the selection has exactly one element, that item has
    `isEnabled = false`.
  - The submenu must have `autoenablesItems = false`, so the disabled state
    sticks.

### Menu bar: RateLimitMenuView.swift

- `enum RateLimitMenuView { @MainActor static func items(selection: [PieChartID], response: RateLimitsResponse?, now: Date) -> [NSMenuItem] }`
  - Returns one disabled title item per selected non-budget chart, in
    canonical order, with the title from `menuLine`.

## Key Pitfalls

- The default `[budget]` glyph must be identical to today's. Return
  `MenuBarPieIcon.image` directly; never re-draw the single-budget case.
- The menu-bar target is AppKit, macOS-only, and `@MainActor`. Keep the
  AppCore formatting free of AppKit so it can be tested on any platform.
- Round remaining percent with `Int(value.rounded())`. Do not use
  locale-dependent percent formatters in AppCore tests.
- `MenuBarPieIcon.swift`: change only access modifiers. Do not change any
  geometry or colors.

## Test Cases (Tests/AppCoreTests/RateLimitDisplayFormattingTests.swift)

- `resetText` with now `12:00Z` and resetsAt `14:13Z` -> "resets in 2h 13m".
- `resetText` with a reset 3 days 4 hours away -> "resets in 3d 4h".
- `resetText` with a reset 30 seconds away -> "resets in <1m".
- `resetText` with a past time -> "reset due".
- `resetText` with nil -> "reset time unknown".
- `entry(for: .codexWeekly)` against a response where Codex has only weekly
  -> the weekly window. `entry(for: .codex5h)` -> window nil.
- `menuLine(.claude5h)` with fiveHour used 47 and resetsAt +2h13m ->
  "Claude Code 5h: 53% left, resets in 2h 13m".
- `menuLine` with a stale provider -> ends with " (stale)".
- `menuLine` with Claude unauthorized -> "Claude Code 5h: unauthorized -
  sign in again with the CLI".
- `menuLine` with a nil response -> "Claude Code 5h: loading".
- `pieFraction` with used 120 -> 1.0.

## Verification

1. `swift build`: exit 0. This compiles the `CCUsageGaugeMenuBar` target on
   macOS.
2. `swift test --filter RateLimitDisplayFormattingTests`: all pass.
3. `swiftlint lint Sources/CCUsageGaugeMenuBar/MenuBarPieStrip.swift Sources/CCUsageGaugeMenuBar/PieChartMenu.swift Sources/CCUsageGaugeMenuBar/RateLimitMenuView.swift Sources/CCUsageGaugeMenuBar/MenuBarPieIcon.swift Sources/AppCore/RateLimitDisplayFormatting.swift Tests/AppCoreTests/RateLimitDisplayFormattingTests.swift`:
   no errors.
4. `git diff Sources/CCUsageGaugeMenuBar/MenuBarPieIcon.swift`: only
   `private` removals.
5. `git diff --quiet Sources/CCUsageGaugeMenuBar/MenuBarApp.swift`: exit 0
   (untouched).

## Done Criteria

- [ ] The contract symbols exist exactly as named.
- [ ] The tests pass.
- [ ] Verification 1-5 recorded in the Progress Log with exit codes.

## Progress Log

- 2026-10-31: Plan created.
- 2026-10-31: Implemented all named formatting and menu-bar view contracts;
  single-budget rendering delegates directly to the existing icon. Verification
  on the shared tree: `swift build` exit 0 (`rl-08/build.log`);
  `swift test --filter RateLimitDisplayFormattingTests` exit 0, 2 tests, 0
  failures (`rl-08/formatting-tests.log`); specified SwiftLint command exit 0
  (`rl-08/swiftlint.log`); strict changed-file SwiftLint exit 0
  (`rl-08/swiftlint-strict.log`, manifest `rl-08/changed-swift.nul`);
  icon diff exit 0 and contains only access changes (`rl-08/menubar-pie-icon.diff`);
  `git diff --quiet -- Sources/CCUsageGaugeMenuBar/MenuBarApp.swift` exit 0
  (`rl-08/menubar-app-diff.log`). Paths are under
  `tmp/subscription-rate-limits-20261031/`. rl-09 owns integration and the
  stable combined-tree gate; formal review remains downstream.
