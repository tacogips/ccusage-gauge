# Dashboard Dark Flat Theme and Effort Grouping - Plan Overview

**Status**: In Progress
**Design Reference**: `design-docs/specs/design-dashboard-dark-flat-effort-grouping.md`
**User decisions**: `design-docs/user-qa/2026-09-29-dashboard-theme-effort-decisions.md`
**Issue**: workflow-input inline issue "Dashboard: dark flat theme, foldable panes, active range buttons, effort grouping, distinct model colors" (no GitHub issue number)

This file indexes the plan set. Only the finalization plan (EDF-12) edits this
file. Every other worker edits only its own plan file's `## Progress Log`.

## 1. User intent

The dashboard needs the following changes:

- Switch to a dark-only, flat, square-cornered design with clear button states.
- Make the left filter pane foldable: horizontally on wide screens and
  vertically on narrow screens. The stacked header must also fold vertically.
- Fix range preset buttons (Today, Yesterday, ...) that never show as active.
- Add an opt-in "Model + effort" stack mode. Reasoning effort comes from Codex
  `turn_context`, and rows without effort go to an explicit `unknown` bucket.
- Give models clearly distinct colors: vendor hue families, with effort
  variants as shades of the model color.

Model-only stacking remains the default.

## 2. Plans and dependency DAG

| Wave | Plan ID | File | Depends on |
|---|---|---|---|
| 1 | EDF-01 | `impl-plans/active/effort-01-swift-record-contract.md` | - |
| 1 | EDF-02 | `impl-plans/active/effort-02-dashboard-ui-state.md` | - |
| 1 | EDF-03 | `impl-plans/active/dashboard-03-dark-flat-theme.md` | - |
| 1 | EDF-04 | `impl-plans/active/effort-04-frontend-contract.md` | - |
| 2 | EDF-05 | `impl-plans/active/effort-05-codex-effort-parsing.md` | EDF-01 |
| 2 | EDF-06 | `impl-plans/active/effort-06-reconciliation-merge-keys.md` | EDF-01 |
| 2 | EDF-07 | `impl-plans/active/effort-07-aggregation-cache.md` | EDF-01 |
| 2 | EDF-08 | `impl-plans/active/effort-08-cost-series-api.md` | EDF-01 |
| 2 | EDF-09 | `impl-plans/active/dashboard-09-model-colors.md` | EDF-04 |
| 2 | EDF-10 | `impl-plans/active/effort-10-frontend-effort-series.md` | EDF-04 |
| 3 | EDF-11 | `impl-plans/active/dashboard-11-app-split-wiring.md` | EDF-02, EDF-03, EDF-04, EDF-08, EDF-09, EDF-10 |
| 4 | EDF-12 | `impl-plans/active/dashboard-12-finalize-assets-gate.md` | EDF-01 .. EDF-11 |

Within a wave, the `writePaths` of different plans are disjoint. No file is
written by two plans in the same wave.

## 3. Shared execution protocol (applies to every plan)

1. **Same working tree, no git mutations.** All plans run on branch `main` in
   `/Users/taco/gits/tacogips/ccusage-gauge`. Workers must not run
   `git commit`, `git stash`, `git checkout`, `git reset`, `git restore`,
   `git clean`, or create branches or worktrees. Read-only
   `git status` and `git diff -- <own paths>` are allowed.
2. **Write only your own paths.** Edit only files in your plan's `writePaths`,
   plus your own plan file's `**Status**` line and `## Progress Log`. Never
   reformat, lint-fix, or "repair" any other file, even if it fails to compile.
3. **Record the intent snapshot first.** Before the first edit, append to your
   Progress Log:
   - the list of files you will change;
   - `shasum -a 256 <file>` for each existing file;
   - one line of intent per file.
4. **Read fresh before every edit.** Re-read the file just before each edit.
   If its hash differs from your last recorded hash, and you did not cause the
   difference, another worker drifted into your path. Stop editing that file,
   record `DRIFT <path> <old-hash> <new-hash>` in your Progress Log, re-read the
   file, and reapply only your intent on top of the current content. Never
   revert the other content.
5. **Record post-hashes.** After finishing, record `shasum -a 256` for every
   file you wrote.
6. **Foreign build breakage.** Wave-parallel workers share one build directory.
   If `swift build`, `swift test`, `bun run check`, or `bun test` fails only because of
   errors in files outside your `writePaths`, rerun the command up to 3 times,
   about 2 minutes apart. If it still fails, record
   `BLOCKED-BY-FOREIGN <file:line> <error>` with the log path, and complete your
   remaining checks. Do not edit the foreign file. The finalization plan
   (EDF-12) reconciles.
7. **Frontend typecheck carve-out for waves 1-2.** `src/App.tsx` is rewired
   only in EDF-11. Until EDF-11 lands, `bun run check` may report errors in
   `src/App.tsx` caused by the new contracts. Wave 1-2 frontend plans require
   that `bun run check` report **no error located in any file of their own
   `writePaths`**. EDF-11 and EDF-12 require `bun run check` to exit 0.
8. **Non-vacuous filters.** `swift test --filter <regex>` matches
   `AppCoreTests.<SuiteStruct>/<test>` identifiers, not file names. A filtered
   run passes only if its log shows at least one executed test. For
   swift-testing, look for a line like `Test run with N tests passed` with
   N > 0. A zero-test run is a failure of the command, not a pass.
9. **Logs.** Every verification command writes its complete output to
   `/tmp/ccusage-gauge-effort/<PLAN-ID>-<step>.log` and prints `exit=$?`. The
   Progress Log records the command, exit status, and log path. A truncated
   log is not a pass.
10. **Content rules.** No emojis in code, docs, or comments. No AI attribution.
   Swift files must stay under 1000 lines (`wc -l`).
11. **Swift changes.** Follow `.codex/skills/swift-coding-agent/SKILL.md`. Run
    `swiftlint lint --quiet <changed Swift files>` on your changed files only.
12. **Serial finalization only.** Do not run `mise run frontend:build`. It
    regenerates `Sources/AppCore/Resources/Web`, which only EDF-12 writes.
    Do not archive plans or edit design docs; that is also EDF-12.

## 4. Cross-plan contracts (pinned)

### Swift (EDF-01)

- `enum UsageEffort` in the new file `Sources/AppCore/UsageEffort.swift`, with
  `static func normalized(_ raw: String?) -> String?`. It trims whitespace,
  lowercases, and accepts only `^[a-z0-9_-]{1,32}$`; anything else becomes
  `nil`.
- `TimestampedUsageEvent` gains `public let effort: String?` and a new last
  init parameter `effort: String? = nil`, normalized through `UsageEffort`.
- `CCUsageMetricRecord` and `CCUsageSessionMetricRecord` each gain
  `public let effort: String?` and a new last init parameter
  `effort: String? = nil`. The field is decoded with `decodeIfPresent` and is
  omitted from encoding when `nil`.
- `DashboardCostRow` gains `public let effort: String?`. This belongs to
  EDF-08 and is encoded only when non-nil.
- `DashboardQueryService.costSeries(..., effortBreakdown: Bool = false)` (EDF-08).

### Frontend (EDF-04)

- `src/effort.ts` exports:
  - `EFFORT_ORDER = ["minimal","low","medium","high","xhigh"] as const`;
  - `UNKNOWN_EFFORT = "unknown"`;
  - `effortRank(effort?: string): number`: the index in `EFFORT_ORDER`,
    `EFFORT_ORDER.length` for an unranked value, and `EFFORT_ORDER.length + 1`
    for `undefined`;
  - `effortLabel(effort?: string): string`: `effort ?? "unknown"`.
- In `src/api.ts`:
  - `CostRow.effort?: string`;
  - `DashboardUIState.stackBy` is
    `"model" | "machine" | "subdirectory" | "modelEffort"`;
  - `DashboardUIState.sidebarCollapsed?: boolean` and
    `headerCollapsed?: boolean`.

### Frontend (EDF-09 and EDF-10, consumed by EDF-11)

- `seriesColors.ts` (EDF-09):
  - `ModelVendor` and `vendorForModel`;
  - `MODEL_COLOR_FAMILIES`;
  - `allocateModelColors(catalog, overrides?) => (model) => string`;
  - `effortShade(base, effort?) => string`;
  - `seriesColor(kind: "machine" | "subdirectory", key, overrides?)`.
- `usageChartSeries.ts` (EDF-10):
  - `StackBy` includes `"modelEffort"`;
  - identity `` `${model}\u001f${effort ?? ""}` ``;
  - `modelEffortParts(identity) => { model: string; effort?: string }`;
  - `compareSeriesIdentities(stackBy, a, b)`.

### CSS class and markup contract (EDF-03 styles, EDF-11 renders)

- Toggle groups: every container of mutually exclusive buttons has the class
  `toggle-group`, and every such button carries `aria-pressed="true"` or
  `aria-pressed="false"`. The containers are range presets plus Custom, agents,
  granularity, chart metric, and stack mode. The existing classes
  `range-buttons`, `agent-buttons`, `granularity-control`, and `stack-toggle`
  are kept alongside it. The only pressed selector is
  `.toggle-group button[aria-pressed="true"]`.
- Shell: `div.app-shell`, plus the class `sidebar-collapsed` when collapsed.
- Sidebar: `aside.model-sidebar` contains, first, a
  `div.pane-fold-bar > button.fold-toggle[aria-expanded][aria-controls="usage-filters-content"]`
  and a `span.pane-fold-summary`. After that comes
  `div#usage-filters-content.model-sidebar-content`, which wraps all existing
  sidebar content.
- Header: `header`, plus the class `header-collapsed` when collapsed. It
  contains `div.header-fold-bar`, holding the existing title element,
  `span.header-range-summary`, and
  `button.fold-toggle.header-fold-toggle[aria-expanded][aria-controls="dashboard-header-content"]`.
  After that comes `div#dashboard-header-content.header-content`, holding the
  config menu and `.period-control`.
- CSS alone decides the fold effect per breakpoint. JavaScript only toggles
  the classes.

## 5. Final gate (EDF-12)

```text
swift build
swift test
swiftlint lint --quiet <all changed Swift files>
mise run frontend:test
mise run frontend:check
mise run lint
mise run test
mise run frontend:build        (last; regenerates Sources/AppCore/Resources/Web)
```

## Progress Log

- 2026-09-29: Plan set created by the Step 4 author from the accepted design.
