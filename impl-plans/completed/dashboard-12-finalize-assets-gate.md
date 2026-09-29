# EDF-12: Serial Reconciliation, Asset Regeneration, and Final Gate

**Status**: Completed
**Plan ID**: EDF-12
**Wave**: 4 (serial, runs alone)
**Depends on**: EDF-01, EDF-02, EDF-03, EDF-04, EDF-05, EDF-06, EDF-07, EDF-08, EDF-09, EDF-10, EDF-11
**Design Reference**: `design-docs/specs/design-dashboard-dark-flat-effort-grouping.md` sections 9 and 10
**Protocol**: `impl-plans/completed/dashboard-dark-flat-effort-overview.md` section 3

## Purpose

This plan runs after all parallel work has joined. It:

- repairs every recorded cross-plan breakage;
- verifies the pinned contracts;
- runs the full gate;
- regenerates the bundled web assets, as the last step;
- marks the design and plan set implemented.

## Write paths

- `Sources/AppCore/Resources/Web` (directory; regenerated only by `mise run frontend:build`)
- `impl-plans/completed/dashboard-dark-flat-effort-overview.md`
- `design-docs/specs/design-dashboard-dark-flat-effort-grouping.md` (Status line only)

## Shared paths (serial repair only)

Repair is allowed in the paths below only for a `BLOCKED-BY-FOREIGN` or
`DRIFT` entry recorded in some plan's Progress Log, or for a failure in this
plan's gate. Each repair must be the minimal change that restores that plan's
stated contract.

- every `writePaths` entry of EDF-01 through EDF-11

## Non-goals

- No new features, refactors, or formatting sweeps.
- No git commit or push. Committing is the workflow's later step.
- Do not archive plans to `impl-plans/completed/`. Archiving happens after
  review acceptance.

## Steps

1. **Collect.** Read the Progress Log of every EDF plan. List every `DRIFT`,
   `BLOCKED-BY-FOREIGN`, and failed check. Fix each one, then re-run the
   owning plan's verification commands. Record the log paths in this plan's
   Progress Log.
2. **Check contracts.**
   - `grep -n "effort" Sources/AppCore/CCUsage.swift Sources/AppCore/CodexUsageEvents.swift Sources/AppCore/DashboardQuery.swift Sources/AppCore/AggregationCache.swift`
     shows the field, parsing, row, and column.
   - `grep -n "effortBreakdown" Sources/AppCore/HTTPService.swift Sources/AppCore/MachineDashboardRouter.swift "Sources/AppCore/MachineDashboardRouter+DirectoryQueries.swift"`
     is non-empty.
   - `grep -n "\-\-color-surface: #15171c" frontend/src/styles.css`, together
     with `CHART_BACKGROUND = "#15171c"` in `frontend/src/seriesColors.ts`.
   - `grep -rn "data-color-scheme\|colorScheme" frontend/src` returns no
     matches.
3. **Check line limits.**
   `wc -l Sources/AppCore/*.swift | sort -n | tail -5` must show every file
   under 1000 lines. Ignore the final `total` line. `wc -l frontend/src/App.tsx` must be below 1580.
4. **Run the full gate, in order.** Write each command's output to
   `/tmp/ccusage-gauge-effort/EDF-12-<name>.log`, and every command must exit 0.
   ```text
   swift build
   swift test
   swiftlint lint --quiet <every Swift file changed per `git status --porcelain Sources Tests`>
   mise run lint
   mise run test
   mise run frontend:test
   mise run frontend:check
   mise run frontend:build
   ```
   `mise run frontend:build` runs **last**, after all source edits. It
   replaces `Sources/AppCore/Resources/Web` through
   `scripts/sync-frontend-assets.sh`. If any source file changes after it
   runs, run it again.
5. **Check the assets.**
   - `git status --porcelain Sources/AppCore/Resources/Web` shows the old
     hashed bundle removed and a new one added.
   - `grep -c "data-color-scheme" Sources/AppCore/Resources/Web/assets/*.css`
     is 0.
   - `grep -c "aria-pressed" Sources/AppCore/Resources/Web/assets/*.js` is at
     least 1.
6. **Optional E2E evidence.** Record whichever of these apply.
   - If a local environment allows it, run
     `swift run ccusage-gauge serve` in the foreground for the check, then stop
     it.
   - Capture screenshots at about 1440px and about 800px widths:
     - sidebar and header expanded and collapsed;
     - a pressed preset after reload;
     - "Model + effort" stacking.
   - Store them under `/tmp/ccusage-gauge-effort/screenshots/` and record the
     paths.
   - If this cannot run, record "E2E not run" and the reason. It is not a
     blocker.
7. **Finish.**
   - Set the `**Status**` line of
     `design-docs/specs/design-dashboard-dark-flat-effort-grouping.md` to
     `Implemented`.
   - Set this plan's Status and the overview Status to `Completed`.
   - Append a summary to the overview Progress Log: plans done, repairs made,
     gate results with log paths, and any residual items.

## Invariants to re-confirm

- With `effortBreakdown` omitted, the cost-series JSON has no `effort` key.
  This is covered by the EDF-08 tests, which pass in `swift test`.
- The model-only default comes from `defaultStackBy === "model"` and the
  server `stackBy` fallback.
- No emojis in changed files. Check with
  `LC_ALL=C grep -rln $'\xF0\x9F' frontend/src frontend/tests Sources/AppCore/*.swift Tests/AppCoreTests design-docs/specs/design-dashboard-dark-flat-effort-grouping.md`.
  BSD grep has no `-P`, so this matches the 4-byte UTF-8 emoji prefix instead.
  It must list no file.

## Completion criteria

- [x] Every gate command exits 0, with log paths recorded.
- [x] Assets are regenerated after the final source edit.
- [x] Every repair is documented.
- [x] The design Status is `Implemented`.

## Progress Log

- 2026-09-29: Plan created.
- 2026-09-30: Completed outside the workflow. The riela dispatch-plans step
  crashed while dispatching this plan: a regression in riela-packages
  d1d526d gave every fanout item the last plan's dependsOn, which made
  EDF-01 depend on itself. The session could not be resumed. EDF-01 through
  EDF-11 were already accepted by integration review.
  - Collect: no open DRIFT or BLOCKED-BY-FOREIGN entries. Earlier transient
    failures were fixed and rerun in the owning plans.
  - Contracts: effort appears in CCUsage, CodexUsageEvents, DashboardQuery
    and AggregationCache. effortBreakdown appears in HTTPService and in
    MachineDashboardRouter+DirectoryQueries. `--color-surface: #15171c`
    matches CHART_BACKGROUND. There are no colorScheme or data-color-scheme
    references.
  - Line limits: the largest Swift file is MachineDashboardRouter.swift at
    995 lines. App.tsx is 1320 lines, down from 1580.
  - Gate, all exit 0, logs in `/tmp/ccusage-gauge-effort/EDF-12-*.log`:
    - swift build;
    - swift test: 316 swift-testing tests in 67 suites;
    - swiftlint on the changed Swift files;
    - mise run lint and mise run test;
    - frontend test: 115 tests;
    - frontend check;
    - frontend build.
  - Assets: regenerated. The CSS has no data-color-scheme and the JS
    contains aria-pressed.
  - E2E: Playwright was run against an isolated `serve` with Codex effort
    fixtures and a Claude fixture. Everything passed on function:
    - square corners everywhere;
    - dark background;
    - wide fold (sidebar 245 to 44 px);
    - narrow vertical folds for the sidebar and header, persisted across
      reload;
    - preset aria-pressed, surviving reload, and custom ranges clear the
      presets;
    - Model + effort with an explicit "(unknown)" bucket for Claude.
  - Visual repairs made after E2E:
    - The collapsed-rail toggle now shows a chevron only, because the
      "Expand" text was clipped in the 44px rail.
    - Toggle-group buttons are nowrap; "Model + effort" had wrapped onto
      three lines.
    - The usage panel title and controls stack and wrap at 1180px and
      below, removing a 1000px scroll width on an 800px viewport.
    - The stacked title keeps flex 0 0 auto.
    - Effort shade offsets widened to -30/-16/0/+16/+28. Luna medium vs high
      went from dE 10.2 to 13.9, and the test minimum rose from 10 to 11.
  - Screenshots: `/tmp/ccusage-gauge-effort/screenshots/`, including the
    v2- and v3- sets.
