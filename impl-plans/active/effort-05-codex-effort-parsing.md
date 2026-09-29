# EDF-05: Codex Effort Parsing

**Status**: Not Started
**Plan ID**: EDF-05
**Wave**: 2
**Depends on**: EDF-01 (`TimestampedUsageEvent.effort`, `UsageEffort.normalized`)
**Design Reference**: `design-docs/specs/design-dashboard-dark-flat-effort-grouping.md` section 5 (Source facts; Parsing)
**Protocol**: `impl-plans/active/dashboard-dark-flat-effort-overview.md` section 3

## Purpose

Read the reasoning effort from each Codex rollout `turn_context` line
(`payload.effort`) and attach it to every token-count event that the
`turn_context` governs. Effort changes per turn, exactly like `model`.
The forward, reverse, and resumed scans must agree.

## Write paths

- `Sources/AppCore/CodexUsageEvents.swift`
- `Tests/AppCoreTests/CodexEffortParsingTests.swift` (new)

## Non-goals

- No Claude parsing change. Claude effort stays `nil`.
- No change to event identity or the watermark.
- No change to `UsageEventFileScanCache.swift`. It is in memory and stores the
  whole event and context generically.

## Step 0: confirm source keys (read-only, record only)

- Before coding, try to confirm the key against one current local rollout.
- Print only JSON key names and the effort value, never other values.
  For example:
  - locate the newest file under `~/.codex/sessions` (or `$CODEX_HOME/sessions`);
  - take its first `"type":"turn_context"` line;
  - print `sorted(payload.keys())` and `payload.get("effort")` with a one-line
    `python3 -c` JSON parse.
- Also count effort-like key names in one current Claude transcript under
  `~/.claude/projects` with
  `grep -o '"[A-Za-z_]*[Ee]ffort[A-Za-z_]*"' <file> | sort | uniq -c`.
- Record both results in the Progress Log.
- If the files are not readable, record "not accessible" and proceed with the
  design key `effort`.
- If the Codex key differs (for example `reasoning_effort`), decode that key
  instead and note it. Everything else is unchanged.
- A Claude finding is recorded only. Do not add Claude parsing.

## Changes (`Sources/AppCore/CodexUsageEvents.swift`)

1. `CodexScanContext`: add `var effort: String?`. `initialContext(for:)` sets
   it to `nil`.
2. `CodexPayload`: add `effort: String?`. Decoding must be **tolerant**. A
   non-string effort, such as a number, object, or array, must yield `nil`
   without failing the whole line. Otherwise the `turn_context` would be
   dropped and its model lost, which is a data-loss regression.
   - Implement this with a custom `init(from:)` that uses
     `try? container.decodeIfPresent(String.self, forKey: .effort)` for effort
     only.
   - Keep strict or optional decoding for the existing fields exactly as it is
     today.
3. `CodexForwardParser.consume`: in the `turn_context` branch with a
   non-empty model, also set
   `context.effort = UsageEffort.normalized(envelope.payload.effort)`. It is
   `nil` when absent, so a later turn without effort resets it and does not
   inherit the previous value.
   `CodexUsageEventLoader.event(...)` gains an `effort: String?` parameter,
   passed to `TimestampedUsageEvent(..., effort:)`.
4. Reverse `rescan`:
   - `ResolvedTokenCount` gains `let effort: String?`.
   - When a `turn_context` resolves `pending`, attach that line's normalized
     effort to each resolved item.
   - Capture the end-of-file effort together with `contextModel`, in the same
     `if contextModel == nil` branch, for example as `contextEffort`.
   - After the scan, set `context.effort = contextEffort` next to
     `context.model = contextModel ?? ""`.
   - `flush()` passes `item.effort`.
5. `resume`: this needs no new logic. It already continues from
   `entry.context`, which now carries effort. Verify it with a test.

## Pitfalls

- Effort must come from the **same** `turn_context` line as the model. Never
  carry an effort across a `turn_context` that lacks one.
- In the reverse scan, the first `turn_context` encountered is the **last** one
  in the file. Only that one sets `contextEffort`, and only when
  `contextModel` is being set for the first time. A later (earlier-in-file)
  `turn_context` must not overwrite it.
- Do not change the early-stop conditions (`stopRequested`, `scanFloor`).
- `session_meta` handling does not touch effort.
- Keep the file under 1000 lines. It is 413 today.

## Tests (`@Suite("CodexEffortParsingTests")`)

Imitate
`Tests/AppCoreTests/DirectoryFeatureTests.swift:codexForwardAndReverseScansPreserveMultipleModelContexts`
and the Codex cases and helpers in
`Tests/AppCoreTests/UsageEventIncrementalScanTests.swift`. Use temp roots and
fixed UTC days. Define local fixture helpers in the new file; do not edit the
shared helpers in other test files.

- `turn_context{model:"gpt-x", effort:"high"}` followed by 2 token counts gives
  both events `effort == "high"` in the forward scan (`events(since: nil, ...)`).
- A mid-session change: turn A (`effort "high"`, 1 token count), then turn B
  (`effort "low"`, 1 token count). The events carry `high` and `low` in order.
  The forward scan (`since: nil`) and reverse scan (`since: day`) return equal
  `[(identity, model, effort)]`.
- Turn A (`effort "high"`), then turn B with no effort key. The event after B
  has `effort == nil`, in both scan directions.
- `effort: " Medium "` gives `"medium"`. `effort: 7` and `effort: {}` give
  `nil`, and the event still has the turn's model, so it is not dropped.
- Resume: scan, then append a token count to the same turn. The appended event
  carries the last turn's effort. Also append a new `turn_context` with
  `effort "xhigh"` plus a token count, and that event carries `xhigh`. The
  result equals a fresh loader's scan.
- A Claude loader event from an existing Claude fixture shape has
  `effort == nil`.

## Verification

```text
mkdir -p /tmp/ccusage-gauge-effort
swift build > /tmp/ccusage-gauge-effort/EDF-05-build.log 2>&1; echo "exit=$?"
swift test --filter CodexEffortParsingTests > /tmp/ccusage-gauge-effort/EDF-05-test.log 2>&1; echo "exit=$?"
swift test --filter IncrementalScanTests > /tmp/ccusage-gauge-effort/EDF-05-incremental.log 2>&1; echo "exit=$?"
swift test --filter Directory > /tmp/ccusage-gauge-effort/EDF-05-directory.log 2>&1; echo "exit=$?"
swiftlint lint --quiet Sources/AppCore/CodexUsageEvents.swift Tests/AppCoreTests/CodexEffortParsingTests.swift > /tmp/ccusage-gauge-effort/EDF-05-lint.log 2>&1; echo "exit=$?"
wc -l Sources/AppCore/CodexUsageEvents.swift
```

Expected evidence: all commands exit 0, the existing incremental-scan and
directory suites are unchanged green, and the file is under 1000 lines.

## Completion criteria

- [ ] Step 0 result recorded (key names, or "not accessible").
- [ ] Forward, reverse, and resume parity tests pass.
- [ ] Tolerant decoding test passes.
- [ ] All logs recorded.

## Progress Log

- 2026-09-29: Plan created.
