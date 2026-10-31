# rt-01: AppCore Ratio-Text Selection, Persisted Fields, and Title Composition

**Status**: Planned
**Wave**: 1 (no dependencies)
**Design Reference**: `design-docs/specs/design-subscription-rate-limits.md`,
section "Configurable Ratio Text", subsections "Selection model (AppCore)",
"Status title composition (AppCore)", "Dashboard" (the `DashboardUIState`
bullet only), and "Verification". Decisions R1, R5, R6 and R7 are in
`design-docs/user-qa/2026-10-31-ratio-text-decisions.md`.

## Intent and Context

The user wants to choose which usage ratios appear as text in the macOS
menu-bar status item, independently of which pies are drawn. The user's
target setup is "Claude W n% · Codex W n%" with no budget text. The dashboard
also needs a persisted per-pie "hide ratio text" set.

This plan delivers only the `AppCore` contracts that rt-03 (menu bar) consumes
and that the dashboard state API persists:

- a selection model that allows an empty selection;
- two persisted fields with backward-compatible decoding;
- pure formatting functions for the status title.

Baseline: commit `f5092bf`. It already has:

- `PieChartID` and `PieChartSelection` (`Sources/AppCore/PieChartSelection.swift`);
- `AppState.menuBarPieCharts` (`Sources/AppCore/State.swift`);
- `DashboardUIState.pieCharts` (`Sources/AppCore/DashboardStateStore.swift`);
- `RateLimitDisplayFormatting` (`Sources/AppCore/RateLimitDisplayFormatting.swift`).

## Non-Goals

- No menu-bar code. Sources/CCUsageGaugeMenuBar belongs to rt-03.
- No frontend code. That belongs to rt-02.
- No HTTP route changes. `/api/dashboard-state` already decodes, validates,
  and encodes `DashboardUIState` as a whole.
- No change to `PieChartSelection`'s behavior, which still forces a non-empty
  selection.
- No change to rate-limit fetching, credentials, `/api/rate-limits`, or
  `StateStore.save` validation.
- No edits to existing test files. New tests go in one new file.

## writePaths

- `Sources/AppCore/PieChartSelection.swift`
- `Sources/AppCore/State.swift`
- `Sources/AppCore/DashboardStateStore.swift`
- `Sources/AppCore/RateLimitDisplayFormatting.swift`
- `Tests/AppCoreTests/RatioTextTests.swift` (new)
- `tmp/ratio-text-20261031/rt-01` (git-ignored evidence logs; artifact root)
- `impl-plans/active/rt-01-appcore-ratio-text.md` (Progress Log only)

## Contract

rt-03 depends on these exact signatures.

- In `PieChartSelection.swift`, add after `PieChartSelection`:
  `public enum RatioTextSelection`
  - `public static let defaultSelection: [PieChartID] = [.budget]`
  - `public static func normalized(rawValues: [String]) -> [PieChartID]`
  - `public static func normalized(_ ids: [PieChartID]) -> [PieChartID]`
    - It drops unknown values, removes duplicates, and sorts into
      `PieChartID.allCases` order.
    - An empty result stays empty. Do not fall back to `[budget]`.
  - `public static func toggled(_ id: PieChartID, in selection: [PieChartID]) -> [PieChartID]`
    - It removes `id` if present, otherwise inserts it, then normalizes.
    - There is no last-item lock: `toggled(.budget, in: [.budget]) == []`.
- `AppState`:
  - New property `public var menuBarRatioLabels: [PieChartID]`.
  - New init parameter, added last:
    `menuBarRatioLabels: [PieChartID] = RatioTextSelection.defaultSelection`.
  - Add `menuBarRatioLabels` to `CodingKeys`, as a new `case` line after
    `menuBarPieCharts`.
  - In `init(from:)`, a missing key gives `RatioTextSelection.defaultSelection`.
    A present key gives `RatioTextSelection.normalized(rawValues:)` of the
    decoded `[String]`. The idiom is
    `decodeIfPresent(...).map(RatioTextSelection.normalized(rawValues:)) ?? RatioTextSelection.defaultSelection`.
- `DashboardUIState`:
  - New property `public let hiddenPieRatios: [PieChartID]`.
  - New init parameter, added last: `hiddenPieRatios: [PieChartID] = []`.
  - Add `hiddenPieRatios` to `CodingKeys`.
  - In `init(from:)`, decode
    `RatioTextSelection.normalized(rawValues: decodeIfPresent([String].self, ...) ?? [])`.
  - `validate()` adds `hiddenPieRatios.count <= PieChartID.allCases.count`
    inside the existing `guard`.
- `RateLimitDisplayFormatting`:
  - `public static func ratioLabel(for chart: PieChartID, in response: RateLimitsResponse?) -> String`
    - The short names are `claude5h` -> `Claude 5h`, `claudeWeekly` ->
      `Claude W`, `codex5h` -> `Codex 5h`, and `codexWeekly` -> `Codex W`.
    - When `entry(for:in:).window` is non-nil, the result is
      `"<short> <n>%"`, where `n` is `Int((window.pieFraction * 100).rounded())`.
    - Otherwise the result is `"<short> --"`.
    - `.budget` returns `""`. It is never called for budget.
  - `public static func statusTitle(selection: [PieChartID], budgetText: String, response: RateLimitsResponse?) -> String`
    - It applies `RatioTextSelection.normalized(selection)`.
    - It maps `.budget` to `budgetText`, unchanged, and every other id to
      `ratioLabel(for:in:)`.
    - It joins the results with `" · "`. That is space, U+00B7 MIDDLE DOT,
      space: the same character as `MenuBarApp.swift:740`.

## Patterns to Imitate

- `Sources/AppCore/PieChartSelection.swift:PieChartSelection` is the shape to
  copy for `RatioTextSelection`.
- `Sources/AppCore/State.swift:AppState.init(from:)` shows how
  `menuBarPieCharts` decodes `[String]`, not `[PieChartID]`.
- `Sources/AppCore/DashboardStateStore.swift:DashboardUIState.init(from:)`
  shows the `pieCharts` decode and the `validate()` guard list.
- `Sources/AppCore/RateLimitDisplayFormatting.swift:menuLine(for:response:now:)`
  uses `entry(for:in:)` and switch-based naming.
- `Tests/AppCoreTests/PieChartSelectionTests.swift` and
  `Tests/AppCoreTests/RateLimitDisplayFormattingTests.swift` show the Swift
  Testing style and how to construct fixtures:
  - `RateLimitWindow(windowSeconds:usedPercent:resetsAt:)`;
  - `ProviderRateLimits(...)`;
  - `RateLimitsResponse(generatedAt:providers:)`.

  Use the global `temporaryDirectory()` helper from
  `Tests/AppCoreTests/StoreTests.swift`.

## Key Pitfalls

- Never pass the ratio selection through `PieChartSelection.normalized`,
  because that function turns `[]` into `[budget]`.
- In `AppState.init(from:)`, do not write
  `normalized(rawValues: decodeIfPresent ?? [])`. That makes a missing key
  decode as `[]` instead of `[budget]`, which changes the default title.
- Decode `[String]`, never `[PieChartID]`. An unknown value must not make the
  whole `state.json` or the dashboard state fail to decode.
- Add the new parameters last and with defaults. Existing call sites, such as
  `dashboardState(pieCharts:)` in `PieChartSelectionTests.swift` and
  `AppState(...)` call sites in the CLI and menu bar, must compile unchanged.
- Do not reorder or rename existing `CodingKeys`.
- `statusTitle` must return `budgetText` byte for byte when the selection is
  `[budget]`. Do not trim it and do not re-parse it. `budgetText` may itself
  contain `" · "`, `"$—"`, `"$!"`, or a trailing `" !"`.
- Use the existing `RateLimitWindow.pieFraction`
  (`RateLimitUsageModels.swift:47`), which clamps to 100. Do not recompute the
  percentage from `remainingPercent`.
- Keep every file under 1000 lines. All four source files are currently under
  200 lines.

## Test Cases (situation -> expected outcome)

Add these to `Tests/AppCoreTests/RatioTextTests.swift`, in a
`@Suite("RatioTextTests")`.

- `RatioTextSelection.normalized(rawValues: ["codexWeekly","bogus","claudeWeekly","claudeWeekly"])`
  -> `[.claudeWeekly, .codexWeekly]`.
- `RatioTextSelection.normalized(rawValues: [])` -> `[]`.
- `toggled(.budget, in: [.budget])` -> `[]`.
- `toggled(.codexWeekly, in: [])` -> `[.codexWeekly]`.
- `toggled(.budget, in: [.codexWeekly])` -> `[.budget, .codexWeekly]`.
- `AppState` JSON `{"resetCycle":{"type":"weekly"}}` -> `menuBarRatioLabels == [.budget]`.
- `AppState` JSON with `"menuBarRatioLabels":[]` -> `[]`.
- `AppState` JSON with `"menuBarRatioLabels":["bogus"]` -> `[]`.
- `AppState` JSON with `["codexWeekly","claudeWeekly","codexWeekly"]` ->
  `[.claudeWeekly, .codexWeekly]`.
- `StateStore` save then load, in a temporary directory, with
  `menuBarRatioLabels: []` -> loads `[]`. The saved JSON object has the key
  `menuBarRatioLabels` with value `[]`.
- Legacy `DashboardUIState` JSON (the `prefix + "}"` fixture from
  `PieChartSelectionTests.legacyAndNormalizedDashboardState`) ->
  `hiddenPieRatios == []`, and `validate()` does not throw.
- `DashboardUIState` JSON with
  `"hiddenPieRatios":["codexWeekly","x","budget","budget"]` ->
  `[.budget, .codexWeekly]`, and it validates.
- A memberwise `DashboardUIState` with `hiddenPieRatios` holding 6 entries ->
  `validate()` throws `DashboardStateError`.
- `DashboardStateStore` save then load (temporary SQLite file) with
  `hiddenPieRatios: [.claudeWeekly]` -> loads an equal state.
- `statusTitle(selection: [.budget], budgetText: X, response: nil) == X` for
  each X in `"$12.34 · 45%"`, `"$12.34"`, `"$—"`, `"$!"`, and
  `"$12.34 · 45% !"`.
- `statusTitle(selection: [], budgetText: "$12.34 · 45%", response: r) == ""`.
- With a response where Claude weekly `usedPercent` is 59 and Codex weekly is
  83: `statusTitle(selection: [.codexWeekly, .claudeWeekly], budgetText: "$1", response: r)`
  -> `"Claude W 59% · Codex W 83%"`. The input order is reversed to prove
  canonical ordering.
- `statusTitle(selection: [.claude5h], budgetText: "$1", response: nil)` ->
  `"Claude 5h --"`.
- A Claude provider with `status: .unauthorized` and no windows, selection
  `[.claude5h]` -> `"Claude 5h --"`.
- `statusTitle(selection: [.budget, .codex5h], budgetText: "$12.34 · 45%", response: r)`,
  where Codex 5h `usedPercent` is 12 -> `"$12.34 · 45% · Codex 5h 12%"`.
- Short names are pinned:
  `ratioLabel(for:)` with windows present gives the prefixes `Claude 5h `,
  `Claude W `, `Codex 5h `, and `Codex W `.
- Rounding and clamping: `usedPercent` 58.6 gives `59%`, and `usedPercent`
  120 gives `100%`.

## Verification

Run from the repository root, in the foreground. Each command must exit 0.

1. `mkdir -p tmp/ratio-text-20261031/rt-01`
2. `set -o pipefail; swift build 2>&1 | tee tmp/ratio-text-20261031/rt-01/build.log`.
   This proves `AppCore`, `AppCLI`, and the menu bar compile, so the new
   defaulted parameters break no existing call site.
3. `set -o pipefail; swift test --filter RatioTextTests 2>&1 | tee tmp/ratio-text-20261031/rt-01/ratio-tests.log`.
   All new tests must pass, and the log must show the suite ran.
4. `set -o pipefail; swift test --filter 'PieChartSelectionTests|RateLimitDisplayFormattingTests|DashboardUIStateFoldEffortTests|StoreTests' 2>&1 | tee tmp/ratio-text-20261031/rt-01/regression.log`.
   These existing suites must still pass.
5. `set -o pipefail; swiftlint lint Sources/AppCore/PieChartSelection.swift Sources/AppCore/State.swift Sources/AppCore/DashboardStateStore.swift Sources/AppCore/RateLimitDisplayFormatting.swift Tests/AppCoreTests/RatioTextTests.swift 2>&1 | tee tmp/ratio-text-20261031/rt-01/swiftlint.log`.
   There must be no errors.
6. `wc -l Sources/AppCore/PieChartSelection.swift Sources/AppCore/State.swift Sources/AppCore/DashboardStateStore.swift Sources/AppCore/RateLimitDisplayFormatting.swift Tests/AppCoreTests/RatioTextTests.swift | tee tmp/ratio-text-20261031/rt-01/wc.log`.
   Every file must be under 1000 lines.

## Done Criteria

- [ ] `grep -n "public enum RatioTextSelection" Sources/AppCore/PieChartSelection.swift` matches.
- [ ] `grep -n "menuBarRatioLabels" Sources/AppCore/State.swift` shows the property, the init parameter, the coding key, and the decode.
- [ ] `grep -n "hiddenPieRatios" Sources/AppCore/DashboardStateStore.swift` shows the property, the init, the key, the decode, and the validate line.
- [ ] `grep -n "func ratioLabel\|func statusTitle" Sources/AppCore/RateLimitDisplayFormatting.swift` gives 2 matches.
- [ ] Verification steps 2 to 6 exit 0, and their logs are complete.
- [ ] No file outside writePaths is modified (`git status --short`).

## Progress Log

- 2026-10-31: Plan created.
