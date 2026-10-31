# rl-12: Dashboard Asset Rebuild and Full Verification Gate

**Status**: Planned
**Wave**: 3 of the continuation run
**Depends on**: rl-09, rl-10, rl-11
**Design Reference**: `design-docs/specs/design-subscription-rate-limits.md`,
sections "Integration Wiring and Rollout" (Dashboard assets, Build side
effects) and "Verification"; `design-docs/user-qa/2026-10-31-subscription-rate-limit-decisions.md`
decision 8

## Intent and Context

The dashboard frontend changes from rl-03 (`RateLimitPanel.tsx`,
`PieChartPanel.tsx`, `rateLimits.ts`, and the `App.tsx` and `api.ts` edits)
reach the shipped app only after `Sources/AppCore/Resources/Web` is
regenerated. `mise run build` regenerates it: it runs `frontend:build`, which
runs `bun run build` and then `scripts/sync-frontend-assets.sh`. That script
deletes the destination and copies `frontend/dist`, so stale hashed files
disappear. After that, the full gate must pass on the combined tree (rl-01 to
rl-11).

The previous combined rl-09 stopped because its `artifactRoots` were empty.
The operator explicitly authorized this plan to own the git-ignored build
caches and evidence directories as artifact roots (QA decision 8). That
authorization overrides the old manifest's `evidenceLayout` text. Running the
commands below is therefore in scope, and you must not refuse them.

## Non-Goals

- Do not hand-edit anything under `Sources/AppCore/Resources/Web`. Keep the
  generated result exactly as produced, including deleted old hashes.
- Do not edit any source, test, frontend, or README file. If a gate command
  fails because of one, record the failing command, its exit code, the log
  path, the file, and the first error lines (never secrets) in the Progress
  Log. Report it as a finding for serial repair by the owning plan or a
  checkpoint amendment, then stop.
- Do not commit, stage, push, stash, or reset. The workflow finalization step
  makes the single local commit.
- Do not start a long-lived server unless the runner provides an explicitly
  owned service lifecycle. Do not use `&`, `nohup`, or `setsid`.

## writePaths

- `Sources/AppCore/Resources/Web` (tracked, regenerated; this is a source
  snapshot path)
- `.build` (artifact root)
- `frontend/dist` (artifact root)
- `frontend/node_modules` (artifact root)
- `tmp` (artifact root; holds the evidence logs)
- `impl-plans/active/rl-12-asset-rebuild-full-gate.md` (Progress Log only)

`artifactRoots`: `.build`, `frontend/dist`, `frontend/node_modules`, `tmp`.

## Steps and Evidence

Run every step in the foreground from the repository root. Start with
`mkdir -p tmp/subscription-rate-limits-20261031/rl-12`. For each piped step,
run `set -o pipefail` first so the recorded exit code is the command's, not
`tee`'s. Record each step's exit code and complete log path in the Progress
Log. A truncated or missing log does not count as a pass.

1. `mise run build 2>&1 | tee tmp/subscription-rate-limits-20261031/rl-12/build.log`:
   exits 0. This regenerates `Sources/AppCore/Resources/Web`.
2. `git status --short -- Sources/AppCore/Resources/Web > tmp/subscription-rate-limits-20261031/rl-12/web-status.log 2>&1`:
   record the added and deleted hashed files.
   - `index.html` must reference only asset files that exist. Check with
     `grep -o 'assets/[^"]*' Sources/AppCore/Resources/Web/index.html` and an
     `ls` of each match.
   - Also check that the new bundle contains the panel: `grep -l 'Subscription rate limits' Sources/AppCore/Resources/Web/assets/*.js`
     finds one file.
3. `mise run test 2>&1 | tee tmp/subscription-rate-limits-20261031/rl-12/test.log`:
   exits 0. The log must show these suites passing with 0 failures:
   `RateLimitUsageModelsTests`, `RateLimitUsageServiceTests`,
   `RateLimitUsageClaudeTests`, `RateLimitUsageCodexTests`,
   `RateLimitUsageCodexFallbackTests`, `RateLimitRoutesTests`,
   `RateLimitDisplayFormattingTests`, `PieChartSelectionTests`, and
   `RateLimitUsageIntegrationTests`.
4. `mise run lint 2>&1 | tee tmp/subscription-rate-limits-20261031/rl-12/lint.log`:
   exits 0 with no errors.
5. `mise run frontend:check 2>&1 | tee tmp/subscription-rate-limits-20261031/rl-12/frontend-check.log`:
   exits 0.
6. `mise run frontend:test 2>&1 | tee tmp/subscription-rate-limits-20261031/rl-12/frontend-test.log`:
   exits 0 with 0 failures.
7. `wc -l Sources/CCUsageGaugeMenuBar/*.swift Sources/AppCore/*.swift Sources/AppCLI/*.swift Tests/AppCoreTests/RateLimit*.swift > tmp/subscription-rate-limits-20261031/rl-12/wc.log 2>&1`:
   every file is under 1000 lines. `MenuBarApp.swift`, `HTTPService.swift`,
   and `MachineDashboardRouter.swift` must each be explicitly confirmed.
8. `grep -rn "refresh_token\|refreshToken\|oauth/token" Sources/AppCore Sources/CCUsageGaugeMenuBar Sources/AppCLI --include='*.swift' > tmp/subscription-rate-limits-20261031/rl-12/no-refresh.log 2>&1`:
   no match (exit 1 is the passing result).
9. `git status --short > tmp/subscription-rate-limits-20261031/rl-12/git-status.log 2>&1`:
   - Every changed path must be in the union of the rl-01 to rl-12
     `writePaths`, the design and plan documents, `README.md`, or
     `Sources/AppCore/Resources/Web`.
   - `.riela/retention/` is listed but must stay unstaged.
   - Nothing under `tmp/` appears, because it is git-ignored.
10. Optional live smoke test. Run it only under an explicitly owned service
    lifecycle provided by the runner:
    - Command: `curl -s http://127.0.0.1:<port>/api/rate-limits | grep -c -E "Bearer|access_token|account_id|refresh|test-"`
      must print `0`.
    - Record only the count and the provider status values, never the body.
    - Without an owned lifecycle, record "smoke skipped: no owned service
      lifecycle". Non-disclosure is still proven by
      `RateLimitUsageIntegrationTests` in step 3.
11. README accuracy check (read-only).
    - Confirm that `README.md`, section "Subscription rate limits and pie
      charts", still matches the final wiring: menu-bar fetches happen only
      while a rate-limit pie is selected, there is a 60 s throttle, and the
      selection persists as `menuBarPieCharts`.
    - Record "README consistent" or list the mismatches as findings. Do not
      edit the file.

## Key Pitfalls

- `mise run build` depends on `frontend:install` (`bun install --frozen-lockfile`).
  If it fails because the network is unavailable, record that as a blocker
  with the log. Do not edit `frontend/bun.lock`.
- Re-running `mise run build` after a repair produces new hashes again, and
  that is expected. The final committed state must come from the last
  successful build, run after the last frontend source change.
- Do not print response bodies, credential files, or environment variables
  into the logs.

## Done Criteria

- [ ] `Sources/AppCore/Resources/Web` was regenerated by `mise run build`
  (exit 0) and not hand-edited, `index.html` references only existing assets,
  and the bundle contains the rate-limit panel.
- [ ] Steps 3 to 6 exit 0, with complete logs under
  `tmp/subscription-rate-limits-20261031/rl-12/`.
- [ ] Steps 7 to 9 pass as specified.
- [ ] Step 10 is recorded or explicitly skipped with a reason, and step 11 is
  recorded.

## Progress Log

- 2026-10-31: Plan created. It is split out of the original rl-09 and owns the
  build caches and evidence as artifact roots under the operator's
  authorization.
