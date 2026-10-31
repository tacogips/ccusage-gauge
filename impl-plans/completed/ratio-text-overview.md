# Configurable Ratio Text - Plan Overview

**Status**: Completed
**Design Reference**: `design-docs/specs/design-subscription-rate-limits.md`,
section "Configurable Ratio Text". The design review accepted it. Decisions
are in `design-docs/user-qa/2026-10-31-ratio-text-decisions.md`.

## Purpose

Two changes, both with defaults that keep today's output byte for byte:

- The menu-bar status title gets a persisted "Ratio text" multi-select,
  `AppState.menuBarRatioLabels`. The default is `[budget]`, and an empty
  selection is allowed. It is independent of the "Pie charts" selection.
- The dashboard pie panel gets per-pie ratio-text visibility,
  `DashboardUIState.hiddenPieRatios`. The default is `[]`.

There is no GitHub issue. The request is inline:
`inline-request:configurable-ratio-text`. The baseline commit is `f5092bf`.

## Plans and Waves

| Wave | Plan ID | File | Depends on |
| --- | --- | --- | --- |
| 1 | rt-01 | `rt-01-appcore-ratio-text.md` | - |
| 1 | rt-02 | `rt-02-frontend-ratio-visibility.md` | - |
| 2 | rt-03 | `rt-03-menubar-ratio-text.md` | rt-01 |
| 3 | rt-04 | `rt-04-asset-rebuild-full-gate.md` | rt-01, rt-02, rt-03 |

- rt-01 pins every `AppCore` signature that rt-03 consumes:
  - `RatioTextSelection`;
  - `AppState.menuBarRatioLabels`;
  - `DashboardUIState.hiddenPieRatios`;
  - `RateLimitDisplayFormatting.ratioLabel(for:in:)` and
    `statusTitle(selection:budgetText:response:)`.
- rt-02 depends only on the JSON field name `hiddenPieRatios`, which is
  pinned here and in rt-01. It is optional on the frontend, so rt-02 runs in
  parallel with rt-01.
- No two plans share a write path.

## Execution Protocol (all plans)

1. **Fresh read before each edit.** Read the target file immediately before
   each edit. Record `shasum -a 256 <file>` before and after the edit in the
   plan's Progress Log.
2. **Write ownership.** Edit only your plan's `writePaths`. You may read
   files in other plans' `writePaths`, but never edit them.
3. **Drift.** If the pre-edit hash of an owned file differs from the hash you
   last recorded, re-read the file and re-apply only your intent. Never revert
   content you do not own.
4. **Sibling build breaks.** If `swift build` fails only because of a file
   outside your `writePaths`, do not fix it. Record the failure in your
   Progress Log, wait, and re-run. rt-04 runs the final gate, and repairs are
   serial after the join.
5. **Commands to avoid before rt-04.** Do not run `mise run build`,
   `mise run frontend:build`, `bun run build`, `bun install`,
   `mise run frontend:check`, or `mise run frontend:test`:
   - the build commands rewrite `Sources/AppCore/Resources/Web`, which only
     rt-04 owns;
   - the `mise` frontend tasks run `bun install`.

   rt-02 runs `bun run check` and `bun test` directly inside `frontend/`.
6. **Evidence and artifacts.**
   - Each plan writes its logs only under `tmp/ratio-text-20261031/<planId>/`,
     which is declared as that plan's artifact root.
   - The bare `tmp` directory is never an artifact root and is never deleted,
     and `tmp/opus-terra-waves` is never touched.
   - Writes to the git-ignored `.build/` by `swift build` and `swift test` are
     authorized side effects. rt-04 declares `.build`, `frontend/dist`, and
     `frontend/node_modules` as artifact roots.
7. **Git.** Workers make no git commits, branches, worktrees, stashes,
   resets, pushes, merges, or rebases. Finalization makes one local commit on
   `main`. It stages files by explicit path, never stages `.riela/` (including
   the pre-existing `.riela/retention/*`) or `tmp/`, and adds no AI
   attribution.
8. **Progress Log.** Update only your own plan file's Progress Log section.
9. **No secrets.** Never print, log, or commit tokens or account IDs.

## Completion

The work is complete when all of these hold:

- rt-01 to rt-04 are each marked Completed;
- rt-04's gate passes, which means all five commands exit 0 with complete
  logs: `mise run build`, `mise run test`, `mise run lint`,
  `mise run frontend:check`, and `mise run frontend:test`;
- the regenerated `Sources/AppCore/Resources/Web` contains the ratio toggle;
- every Swift file is under 1000 lines.

## Progress Log

- 2026-10-31: Overview and plans rt-01 to rt-04 created.
- 2026-10-31: Completed. rt-01 to rt-04 are marked Completed and were accepted by the test-integrity, adversarial and integration reviews. The rt-04 gate exited 0 for `mise run build`, `mise run test` (357 passed), `mise run lint` (0 serious), `mise run frontend:check` and `mise run frontend:test` (138 passed). The regenerated Web bundle contains the ratio toggle, and every Swift file is under 1000 lines. README.md documents the shipped behavior. The overview and the four plans were archived to `impl-plans/completed/`. The dispatch manifest `impl-plans/active/ratio-text-20261031-dispatch.json` stays in place as checkpoint provenance for the commit step.
