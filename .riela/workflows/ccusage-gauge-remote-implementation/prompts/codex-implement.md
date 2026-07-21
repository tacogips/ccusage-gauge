You are the Codex implementation agent. The preceding Riela session already
completed Codex findings, repeated Fable proposals, and repeated Codex proposal
reviews. Do not restart design review. Implement the consolidated requirements
below and address concrete final-review findings if this is a loop iteration.

```json
{{workflowInput}}
```

Latest direct input, if any:

```json
{{_rielaInput.latest.payload}}
```

Core requirements:

- Preserve unrelated dirty work, including the existing stack-by CSS and
  generated Web assets. Do not stage, commit, or push.
- Keep stub mode working, but add a required real mode. Required mode must fail
  nonzero for missing Docker, ccusage, fixture, version, or parity prerequisites.
- Pin ccusage 20.0.17 in collector and SSH machine images. A dispatcher owns
  `--version`, selects real/stub mode, sets `TZ=UTC`, and derives
  `CLAUDE_CONFIG_DIR` from an explicit `HOME`. Collector HOME is
  `/home/collector`; machine HOME is `/home/ccusage`.
- Stage a bounded subset of real Claude host data: exactly one fixed historical
  UTC day, two nonempty disjoint files/scopes, no more than 500 retained
  assistant events per file, and counts-only logs. Validate timestamp, model,
  and integer token fields; cost is computed by ccusage. Never copy auth.json
  unless strictly necessary, and never print raw events or credentials.
- Mount local, machine-a, and empty machine-b fixtures read-only. Use safe
  permissions beneath a host-only 0700 parent.
- Match the app's actual ccusage command: `daily --json --sections daily,session`
  with `--by-agent` retry only for incompatible JSON. Do not add pricing flags or
  pricing environment overrides.
- Use `/usr/bin/ssh` plus an argument array exactly matching
  `SSHCCUsageCommandRunner.sshArguments` for the registered host, published port,
  identity, extra options, destination, and quoted remote tokens. Assert the
  executable separately in a focused Swift test if Swift is edited.
- Verify exact Decimal costs and integer input/output/cache-creation/cache-read
  tokens for local, machine-a, and their all-scope sum. Daily series comes from
  daily rows. `15min`, `hourly`, and `6hour` must match the same unbucketed
  session-row multiset including timestamp, agent, model, machine, cost, and all
  token categories.
- Machine-b must first collect healthy-empty, then after stopping be included
  and exactly stale (not unavailable), then after restart be healthy-empty with
  empty stale/unavailable sets and no usage rows.
- Add a frontend build-and-recursive-byte-compare gate using a temporary copy,
  proving packaged resources match source and retaining the stack-by layout fix.
- Cleanup must be targeted to run-owned containers, volumes, images, fixtures,
  oracles, keys, temporary homes, and processes. An EXIT trap must retain primary
  failure status, run cleanup/absence checks, and run final integrity checks.
- Integrity protection must enumerate all dirty/untracked files with
  `git status --porcelain=v1 -z --untracked-files=all`, have no real-worktree path
  exclusions, handle NUL-delimited records, symlinks and missing paths, store its
  manifest outside the worktree, and prove the real index stays empty. Test
  rename/copy parsing synthetically or only inside a scratch repository whose
  index is restored before snapshot verification.
- Follow AGENTS.md and the Swift coding skill. Avoid editing HTTPService.swift;
  if it must be edited, split its current 1001 lines by responsibility.

Implement rather than merely describe. Return JSON with `changedFiles`,
`implementationSummary`, `testsAdded`, `preliminaryVerification`,
`unresolvedItems`, and `residualRisks`.
