# rl-04: README Section for Subscription Rate Limits and Pie Selection

**Status**: Planned
**Wave**: 1 (no dependencies)
**Design Reference**: `design-docs/specs/design-subscription-rate-limits.md`,
sections Data Sources and Security and Privacy, plus QA decisions 1-7

## Intent and Context

The acceptance criteria require the README to document four things: the
feature, its data sources, its privacy behavior, and the pie selection
setting. The design is accepted, so the documentation can be written now.

## Non-Goals

- No other README sections are edited, except one link line in an existing
  overview list if such a list exists.
- No screenshots.
- No design-doc edits.

## writePaths

- `README.md`
- `impl-plans/active/rl-04-readme.md` (Progress Log only)

## File-Level Changes

Add a `## Subscription rate limits and pie charts` section immediately before
`## Remote machines`, which is currently at around README line 320. It
contains the following.

1. **What it shows.**
   - Claude Code and Codex 5h and weekly windows: used percent, remaining
     percent, and time to reset.
   - These appear in the dashboard panel and as optional pies.
   - The data covers this Mac's CLI accounts only; remote machines are not
     included.
2. **Data sources.** List the endpoint and credential source for each
   provider, without exposing any values:
   - Claude: `https://api.anthropic.com/api/oauth/usage`. The credential
     comes from the Keychain item `Claude Code-credentials`, read through
     `/usr/bin/security`, or from `$CLAUDE_CONFIG_DIR/.credentials.json`
     (default `~/.claude`).
   - Codex: `https://chatgpt.com/backend-api/wham/usage`. The credential
     comes from `$CODEX_HOME/auth.json` (default `~/.codex`). The offline
     fallback is the newest `rate_limits` event in
     `$CODEX_HOME/sessions/**/*.jsonl`, shown as stale.
3. **Privacy.**
   - Credentials are read-only and held in memory for a single request only.
   - Tokens are never refreshed, logged, stored, or returned.
   - `GET /api/rate-limits` returns only derived numbers, status, plan type,
     and timestamps.
   - Requests go out at most once per provider every 60 seconds.
   - Opening the dashboard triggers these requests.
   - The menu bar requests only while a rate-limit pie is selected.
   - An expired token or 401 shows "unauthorized": run the CLI to refresh
     its login.
4. **Statuses.** Describe `ok`, `stale` (with the "as of" time),
   `unauthorized`, and `unavailable`.
5. **Pie chart selection.**
   - Dashboard: toggle buttons in the pie chart section, saved in the
     dashboard state.
   - Menu bar: Settings > Pie charts, saved in
     `~/.local/ccusage-gauge/state.json` as `menuBarPieCharts`.
   - Both default to the budget pie only. The two selections are
     independent.
6. **API example.** A `curl http://127.0.0.1:18081/api/rate-limits` example
   with a sample response that contains no secrets, using the shape from the
   overview.

## Key Pitfalls

- Do not paste real tokens, account IDs, or real user paths beyond `~`.
- Do not use emojis.
- Do not claim support for remote machines.

## Verification

1. `grep -n "## Subscription rate limits and pie charts" README.md`: exactly
   one match.
2. `grep -n "/api/rate-limits\|menuBarPieCharts\|Claude Code-credentials\|CODEX_HOME" README.md`:
   all four terms present.
3. `git diff --stat README.md`: only README changed by this plan.

## Done Criteria

- [ ] Section items 1-6 present.
- [ ] Verification 1-3 recorded in the Progress Log.

## Progress Log

- 2026-10-31: Plan created.
- 2026-10-31: Implemented section items 1-6 in README, including a synthetic
  API response. Both done criteria are satisfied. Verified the unique heading,
  required terms, and README diff stat with exit status 0; complete logs are
  `tmp/subscription-rate-limits-20261031/rl-04/check-01.log` through
  `check-03.log`. Also checked diff whitespace and parsed the sample JSON and
  section placement successfully (logs `check-04.log` and `check-05.log`).
  Formal review and integration remain downstream.
