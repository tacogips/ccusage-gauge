# rt-04: Dashboard Asset Rebuild and Full Verification Gate

**Status**: Completed
**Wave**: 3 (depends on rt-01, rt-02, rt-03)
**Design Reference**: `design-docs/specs/design-subscription-rate-limits.md`,
section "Configurable Ratio Text", subsections "Dashboard" (bundled assets),
"Verification", and "Rollout constraints". Decisions R10 and R11 are in
`design-docs/user-qa/2026-10-31-ratio-text-decisions.md`.

## Intent and Context

The Swift package serves the dashboard from the tracked bundle in
`Sources/AppCore/Resources/Web`. rt-02 changed the frontend, so that bundle
must be regenerated with `mise run build`. That task runs `frontend:install`
(`bun install --frozen-lockfile`), then `vite build`, then
`scripts/sync-frontend-assets.sh`, which deletes stale hashed files, then
`swift build`. If the bundle were stale, the frontend tests would pass but
the old UI would ship.

This plan also runs the full acceptance gate once, after every
implementation plan has joined.

Operator constraint: `artifactRoots` must never be the bare `tmp` directory,
because Riela fanout evidence lives in `tmp/opus-terra-waves`. This plan
declares only these artifact roots:

- `.build`;
- `frontend/dist`;
- `frontend/node_modules`;
- `tmp/ratio-text-20261031/rt-04`.

All of them are git-ignored, authorized side effects.

## Non-Goals

- Do not edit any source, test, frontend source, design, or README file. If a
  gate step fails because of a defect, record the failure, the log path, and
  the owning plan (rt-01, rt-02, or rt-03) in the Progress Log, then stop. Do
  not fix other plans' files here.
- Do not hand-edit anything under `Sources/AppCore/Resources/Web`.
- Do not commit, push, merge, or rebase. The workflow's finalization commits
  locally on `main`.

## writePaths

- `Sources/AppCore/Resources/Web` (tracked generated bundle; source snapshot, about 140 KB)
- `.build` (artifact root)
- `frontend/dist` (artifact root)
- `frontend/node_modules` (artifact root)
- `tmp/ratio-text-20261031/rt-04` (evidence logs; artifact root)
- `impl-plans/active/rt-04-asset-rebuild-full-gate.md` (Progress Log only)

## Key Pitfalls

- Never declare or `rm -rf` the bare `tmp` directory, and never touch
  `tmp/opus-terra-waves`.
- Every gate command runs in the foreground with `set -o pipefail` and a `tee`
  log. A truncated log, or a command that is still running, is not a pass.
- `.riela/retention/*` was untracked before this run. It must stay unstaged
  and untouched.
- `mise run build` must be the command that regenerates the bundle. Do not
  copy files from `frontend/dist` by hand.

## Verification Steps

Run from the repository root, in this order. Each command must exit 0 unless
the step says it is optional.

1. `mkdir -p tmp/ratio-text-20261031/rt-04`
2. `set -o pipefail; mise run build 2>&1 | tee tmp/ratio-text-20261031/rt-04/build.log`.
   This regenerates the bundle and runs `swift build`.
3. `grep -l "Show ratio text for" Sources/AppCore/Resources/Web/assets/*.js | tee tmp/ratio-text-20261031/rt-04/bundle-check.log`.
   There must be at least one match, which proves the new UI is bundled.
4. `git status --short -- Sources/AppCore/Resources/Web | tee tmp/ratio-text-20261031/rt-04/web-status.log`.
   Record the changed or renamed hashed assets. `index.html` must reference
   only files that exist.
5. `set -o pipefail; mise run test 2>&1 | tee tmp/ratio-text-20261031/rt-04/test.log`.
   All Swift tests must pass. The log must show `RatioTextTests`,
   `PieChartSelectionTests`, and `RateLimitDisplayFormattingTests` passing.
6. `set -o pipefail; mise run lint 2>&1 | tee tmp/ratio-text-20261031/rt-04/lint.log`.
   SwiftLint must report 0 serious violations.
7. `set -o pipefail; mise run frontend:check 2>&1 | tee tmp/ratio-text-20261031/rt-04/frontend-check.log`
8. `set -o pipefail; mise run frontend:test 2>&1 | tee tmp/ratio-text-20261031/rt-04/frontend-test.log`.
   All bun tests must pass, including the two new rt-02 tests.
9. `wc -l Sources/CCUsageGaugeMenuBar/*.swift Sources/AppCore/*.swift | tee tmp/ratio-text-20261031/rt-04/wc.log`.
   Then run
   `! awk '$2 != "total" && $1 >= 1000' tmp/ratio-text-20261031/rt-04/wc.log | grep .`.
   This proves every Swift file is under 1000 lines.
10. `! grep -rn "refresh_token\|refreshToken\|oauth/token" Sources/AppCore Sources/CCUsageGaugeMenuBar Sources/AppCLI --include="*.swift"`.
    This confirms no token-refresh code was introduced.
11. `git status --short | tee tmp/ratio-text-20261031/rt-04/git-status.log`.
    Only these paths may appear:
    - the files owned by rt-01, rt-02, and rt-03;
    - `Sources/AppCore/Resources/Web`;
    - the design and plan documents for this feature;
    - the still-untracked `.riela/retention/`.
12. Optional manual GUI check, recorded as skipped (with the reason) when no
    interactive GUI session exists:
    1. Launch the menu-bar app.
    2. Set "Pie charts" to Claude Code weekly and Codex weekly, and set "Ratio
       text" to the same two.
    3. Expect two pies and the title `Claude W n% · Codex W n%`, with no
       budget pie and no budget text.
    4. Unchecking every "Ratio text" item should leave the glyph only.

## Done Criteria

- [x] Steps 2 to 11 exit 0, and each has a complete log under
  `tmp/ratio-text-20261031/rt-04/`.
- [x] The regenerated `Sources/AppCore/Resources/Web` contains the ratio
  toggle text (step 3).
- [x] Step 12 is recorded as done or skipped, with a reason.
- [x] The Progress Log records each command's exit code and log path.

## Progress Log

- 2026-10-31: Plan created.

- 2026-10-31: rt-04 integration gate completed on the joined tree. `mise run build` exited 0 and generated the Web bundle; `build.log`, `bundle-check.log`, `web-status.log`, and `index-check.log` record the build, ratio-toggle text, changed assets, and valid index references.
- `mise run test` exited 0 (357 tests, 0 failures; `test.log`); `mise run lint` exited 0 (27 warnings, 0 serious; `lint.log`); `mise run frontend:check` exited 0 (`frontend-check.log`); `mise run frontend:test` exited 0 (138 tests, 0 failures; `frontend-test.log`). All logs are under `tmp/ratio-text-20261031/rt-04/`.
- Line-count checks, refresh-token search, and git status exited 0; see `wc.log`, `line-check.log`, `all-swift-lines.log`, `token-check.log`, and `git-status.log`. No Swift files were edited by rt-04; `selected-lint.log` records the empty selected-file gate.
- Manual GUI check skipped: this automated workflow has no established interactive GUI session; menu-bar behavior remains subject to downstream integration review. No source files were edited by rt-04. Formal reviews and final commit remain downstream.
- 2026-10-31: Completed. Test-integrity review, adversarial review (needs_revision=false), branch evidence and the integration review accepted rt-04. Browser E2E was skipped because the repository has no browser E2E harness. Archived to `impl-plans/completed/rt-04-asset-rebuild-full-gate.md`. The local commit on `main` happens in the commit step. It must stage the deleted `index-C6kVNlJa.js` together with the new `index-CePPN1y5.js`.
