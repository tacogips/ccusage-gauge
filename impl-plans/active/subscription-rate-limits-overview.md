# Subscription Rate Limits and Selectable Pie Charts - Plan Overview

**Status**: In Progress
**Design Reference**: `design-docs/specs/design-subscription-rate-limits.md`
(accepted by design review, decision `accept`), plus
`design-docs/user-qa/2026-10-31-subscription-rate-limit-decisions.md` and the
cross-references in `design-docs/specs/architecture.md`.

## Purpose

ccusage-gauge currently shows one pie chart, the cost budget. This work adds
three things:

- Claude Code and Codex 5h and weekly subscription rate limits, served by
  `GET /api/rate-limits`;
- a dashboard rate-limit panel;
- a persisted multi-select of pie charts on the dashboard and in the menu bar.
  Both default to the budget pie only.

There is no GitHub issue. The source is workflow execution
`opus-terra-design-and-implement-review-loop-session-567`.

## Plans and Waves

| Wave | Plan ID | File | Depends on |
| --- | --- | --- | --- |
| 1 | rl-01 | `rl-01-core-contracts-service.md` | - |
| 1 | rl-02 | `rl-02-pie-selection-state.md` | - |
| 1 | rl-03 | `rl-03-frontend-dashboard.md` | - |
| 1 | rl-04 | `rl-04-readme.md` | - |
| 2 | rl-05 | `rl-05-claude-fetcher.md` | rl-01 |
| 2 | rl-06 | `rl-06-codex-fetcher.md` | rl-01 |
| 2 | rl-07 | `rl-07-http-routes.md` | rl-01 |
| 2 | rl-08 | `rl-08-menubar-views.md` | rl-01, rl-02 |
| 3 | rl-09 | `rl-09-integration-wiring.md` | rl-02, rl-03, rl-05, rl-06, rl-07, rl-08 |

Wave 1 pins every shared Swift contract (rl-01) and the selection model
(rl-02). The frontend (rl-03) depends only on the JSON contract, which is
pinned in this overview and in rl-01. Wave 3 is the only plan that touches
production construction sites (`Sources/AppCLI/Runtime.swift`,
`Sources/CCUsageGaugeMenuBar/MenuBarApp.swift`) or regenerates the tracked
dashboard assets (`Sources/AppCore/Resources/Web`).

## Pinned JSON Contract (`GET /api/rate-limits`)

Dates are ISO 8601 without fractional seconds. Optional fields are encoded as
explicit `null`, and consumers must treat a missing key the same as `null`.
Keys are sorted.

```json
{"generatedAt":"2026-10-31T12:00:00Z","scope":"local","providers":[
  {"provider":"claude","status":"ok","errorCode":null,"message":null,"planType":"max",
   "fetchedAt":"2026-10-31T12:00:00Z","stale":false,
   "fiveHour":{"kind":"fiveHour","windowSeconds":18000,"usedPercent":47,"remainingPercent":53,"resetsAt":"2026-10-31T13:00:00Z"},
   "weekly":null,"otherWindows":[]},
  {"provider":"codex", "...": "same shape"}]}
```

- `status`: `ok` | `stale` | `unauthorized` | `unavailable`.
- `errorCode`: `credentials_missing` | `credentials_unreadable` |
  `token_expired` | `unauthorized` | `rate_limited` | `http_error` |
  `network_error` | `timeout` | `invalid_response`.
- Pie IDs, in canonical order: `budget`, `claude5h`, `claudeWeekly`,
  `codex5h`, `codexWeekly`.

## Execution Protocol (all plans)

1. **Fresh read before each edit.** Read the target file immediately before
   each edit. Record `shasum -a 256 <file>` before and after the edit in the
   plan's Progress Log.
2. **Write ownership.** Edit only the plan's `writePaths`. A file in another
   plan's `writePaths` may be read but never edited.
3. **Drift.** If the pre-edit hash of an owned file differs from the hash you
   last recorded, re-read the file and re-apply only your intent. Never revert
   content you do not own.
4. **Sibling build breaks.** If `swift build` fails only because of a file
   outside your `writePaths` (a sibling still in progress), do not fix it.
   Record the failure in your Progress Log, wait, and re-run. Final gates are
   run by rl-09.
5. **Commands to avoid before rl-09.** Do not run `mise run build`,
   `mise run frontend:build`, or `bun run build` before rl-09. They rewrite
   the tracked `Sources/AppCore/Resources/Web` assets, which only rl-09 owns.
6. **Git.** No git commits, branches, worktrees, stashes, or resets from
   workers.
7. **Progress Log.** Update only your own plan file's Progress Log section.
8. **No secrets.** Never print, log, or commit real tokens or account IDs.
   Tests use the sentinels `test-claude-access-token`,
   `test-codex-access-token`, and `test-codex-account-id`.

## Completion

All nine plans are marked Completed, and rl-09's full gate passes:
`mise run build`, `mise run test`, `mise run lint`, `mise run frontend:check`,
and `mise run frontend:test`.
