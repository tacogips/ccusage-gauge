# rl-02: Pie Chart Selection Model and Persisted State Fields

**Status**: Planned
**Wave**: 1 (no dependencies)
**Design Reference**: `design-docs/specs/design-subscription-rate-limits.md`,
section Pie Chart Selection. QA decision 1 in
`design-docs/user-qa/2026-10-31-subscription-rate-limit-decisions.md`.

## Intent and Context

The dashboard and the menu bar each persist their own pie selection:

- `DashboardUIState.pieCharts`, stored in SQLite through
  `/api/dashboard-state`;
- `AppState.menuBarPieCharts`, stored in `state.json`.

Both must decode older files that lack the field to `[budget]`, so current
behavior is preserved and no existing budget, cycle, or baseline value is lost.

## Non-Goals

- No UI.
- No HTTP route changes.
- `/api/dashboard-state` handling stays as is; it already decodes and
  validates `DashboardUIState`.
- No new mutation route.
- No change to existing `StateStore.save` validation rules.

## writePaths

- `Sources/AppCore/PieChartSelection.swift` (new)
- `Sources/AppCore/State.swift`
- `Sources/AppCore/DashboardStateStore.swift`
- `Tests/AppCoreTests/PieChartSelectionTests.swift` (new)
- `impl-plans/active/rl-02-pie-selection-state.md` (Progress Log only)

## Contract

- `public enum PieChartID: String, Codable, CaseIterable, Sendable { case budget, claude5h, claudeWeekly, codex5h, codexWeekly }`
  The declaration order is the canonical order.
- `public enum PieChartSelection`
  - `public static let defaultSelection: [PieChartID] = [.budget]`
  - `public static func normalized(rawValues: [String]) -> [PieChartID]`
    drops unknown values, removes duplicates, and sorts into canonical order.
    An empty result returns `defaultSelection`.
  - `public static func normalized(_ ids: [PieChartID]) -> [PieChartID]`
    applies the same rules.
  - `public static func toggled(_ id: PieChartID, in selection: [PieChartID]) -> [PieChartID]`
    removes `id` if present, otherwise inserts it. It returns the normalized
    result. Toggling the only selected id returns the selection unchanged.
- `AppState`
  - New property `public var menuBarPieCharts: [PieChartID]`.
  - New init parameter `menuBarPieCharts: [PieChartID] = PieChartSelection.defaultSelection`,
    added last so existing call sites still compile.
  - Add `menuBarPieCharts` to `CodingKeys`.
  - In `init(from:)`, decode `decodeIfPresent([String].self, forKey: .menuBarPieCharts)`
    and pass the result through `normalized(rawValues:)`. A missing key gives
    the default.
- `DashboardUIState`
  - New property `public let pieCharts: [PieChartID]`.
  - New init parameter `pieCharts: [PieChartID] = PieChartSelection.defaultSelection`,
    added last.
  - Add `pieCharts` to `CodingKeys`.
  - Decode it the same way as `menuBarPieCharts`.
  - `validate()` additionally requires `!pieCharts.isEmpty && pieCharts.count <= PieChartID.allCases.count`.

## Patterns to Imitate

- `Sources/AppCore/DashboardStateStore.swift:DashboardUIState.init(from:)`
  shows the `stackBy` coercion and the `decodeIfPresent ?? default` pattern.
- `Sources/AppCore/State.swift:AppState.init(from:)` shows the
  `budgetMachineIDs` handling.
- Tests: `Tests/AppCoreTests/DashboardUIStateFoldEffortTests.swift`, which
  decodes legacy JSON.

## Key Pitfalls

- Decode `[String]`, not `[PieChartID]`. Decoding the enum array would throw
  on an unknown value and could reset the user's whole state file.
- Do not reorder or rename existing `CodingKeys`.
- Do not change `resetCycle` decoding, which is still required.
- The synthesized `encode(to:)` must now include the new key. Check this in a
  round-trip test.
- Do not touch `HTTPService.swift`, `MachineDashboardRouter.swift`, or any
  menu-bar file.

## Test Cases (situation -> expected outcome)

- Legacy `state.json` JSON with `budgetUSD` 50, `resetCycle` weekly, and no
  `menuBarPieCharts` -> decodes to `[.budget]`, with budget 50 and cycle
  weekly preserved.
- `menuBarPieCharts: ["codexWeekly","bogus","claude5h","claude5h"]` ->
  `[.claude5h, .codexWeekly]`.
- `menuBarPieCharts: []` -> `[.budget]`.
- `StateStore.save` followed by `load` (temp directory) with
  `[.budget, .codex5h]` -> the same value round-trips, and the saved JSON
  contains `"menuBarPieCharts"`.
- Legacy `DashboardUIState` JSON (the fold-test fixture) -> `pieCharts == [.budget]`,
  and `validate()` passes.
- `DashboardUIState` with `pieCharts: ["claudeWeekly","budget"]` ->
  `[.budget, .claudeWeekly]`.
- `DashboardStateStore.save` then `load` (temp SQLite file) -> `pieCharts`
  persists.
- `toggled(.budget, in: [.budget])` -> `[.budget]`.
- `toggled(.codex5h, in: [.budget])` -> `[.budget, .codex5h]`.
- `toggled(.budget, in: [.budget, .codex5h])` -> `[.codex5h]`.

## Verification

1. `swift build`: exit 0.
2. `swift test --filter PieChartSelectionTests`: all pass.
3. `swift test --filter DashboardUIStateFoldEffortTests`: still passes
   (regression).
4. `swift test --filter StoreTests`: still passes (regression).
5. `swiftlint lint Sources/AppCore/PieChartSelection.swift Sources/AppCore/State.swift Sources/AppCore/DashboardStateStore.swift Tests/AppCoreTests/PieChartSelectionTests.swift`:
   no errors.

## Done Criteria

- [ ] The contract symbols exist exactly as named.
- [ ] Legacy JSON decodes to `[budget]` in both stores, as shown by the tests.
- [ ] Verification 1-5 recorded in the Progress Log with exit codes.

## Progress Log

- 2026-10-31: Plan created.
