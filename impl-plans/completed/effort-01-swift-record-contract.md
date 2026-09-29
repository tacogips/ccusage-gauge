# EDF-01: Swift Effort Record Contract

**Status**: Completed
**Plan ID**: EDF-01
**Wave**: 1
**Depends on**: none
**Design Reference**: `design-docs/specs/design-dashboard-dark-flat-effort-grouping.md` section 5 (Normalization; Records, reconciliation, and merge keys)
**Protocol**: `impl-plans/completed/dashboard-dark-flat-effort-overview.md` section 3

## Purpose

Add the optional `effort` field that every later Swift plan relies on. The
change is purely additive: every existing call site must keep compiling with no
edits, because all new init parameters default to `nil`.

## Write paths

- `Sources/AppCore/UsageEffort.swift` (new)
- `Sources/AppCore/ClaudeUsageEvents.swift`
- `Sources/AppCore/CCUsage.swift`
- `Tests/AppCoreTests/UsageEffortContractTests.swift` (new)

## Non-goals

- Do not parse effort from any log. EDF-05 does that.
- Do not change reconciliation, merge keys, cache, or queries. Those are
  EDF-06, EDF-07, and EDF-08.
- Claude events always keep `effort == nil`. Do not decode any Claude field
  for it.
- Do not change `TimestampedUsageEvent.identity` or `relativeCostWeight`.

## Changes

1. `Sources/AppCore/UsageEffort.swift`: add
   `enum UsageEffort { static func normalized(_ raw: String?) -> String? }`.
   - The input is trimmed of whitespace and newlines, then lowercased.
   - The result is returned only if it matches `^[a-z0-9_-]{1,32}$`.
     Otherwise the function returns `nil`.
   - `internal` visibility is enough.
2. `Sources/AppCore/ClaudeUsageEvents.swift`: in `TimestampedUsageEvent`:
   - add `public let effort: String?`;
   - add the last init parameter `effort: String? = nil`, after `directory`;
   - assign `self.effort = UsageEffort.normalized(effort)`.
   - Imitate the handling of `directory` (the `normalizedDirectory` call in
     `init`). Do not touch the Claude loader code.
3. `Sources/AppCore/CCUsage.swift`:
   - `CCUsageMetricRecord` and `CCUsageSessionMetricRecord`: for each, add
     `public let effort: String?` and the last init parameter
     `effort: String? = nil`. Add `effort` to `CodingKeys` and decode it with
     `decodeIfPresent`.
   - The synthesized `encode(to:)` then omits `nil` automatically. Confirm this
     with a test. Do not write a custom encoder unless the test proves it is
     needed.
   - Imitate `directory` in the same structs (`CCUsage.swift` lines 62, 74,
     106, 130, 143, 177).
   - `CCUsageClient` re-stamps records with `machine:`. At every site that
     passes `directory: row.directory` or `directory: $0.directory` (currently
     around lines 661, 690, 712, 732, 747), also pass
     `effort: row.effort` or `effort: $0.effort`. Re-grep `directory: ` in the
     file to find every site. A missed site silently drops effort.
   - `CCUsageCostRecord` does not get effort.

## Pitfalls

- Placing `effort` anywhere other than the last init parameter breaks
  positional or trailing-closure callers. Keep it last.
- Do not add effort to `identity`, `Equatable` exclusions, or any `Hashable`
  key here.

## Tests (`Tests/AppCoreTests/UsageEffortContractTests.swift`, `@Suite("UsageEffortContractTests")`)

Imitate
`Tests/AppCoreTests/DirectoryFeatureTests.swift:legacyRecordsDecodeWithoutDirectoryAndNilIsOmitted`.
Cases:

- `normalized(" High ")` returns `"high"`.
- `normalized("xhigh")` returns `"xhigh"`.
- `normalized(nil)`, `normalized("")`, and `normalized("   ")` each return `nil`.
- `normalized("a b")`, `normalized("high!")`, and a 33-character string each
  return `nil`.
- Constructing `TimestampedUsageEvent(..., effort: " Medium ")` stores
  `"medium"`. Omitting `effort` stores `nil`.
- Two events that differ only in effort have equal `identity`.
- A session record JSON without an `effort` key decodes to `effort == nil`.
  Encoding a record with `nil` effort produces JSON with no `effort` key.
- A session record with `effort: "high"` round-trips through encode and decode.
- The same two checks for `CCUsageMetricRecord`.
- `CCUsageClient` re-stamp keeps effort. Use the smallest existing test seam
  from `CCUsageTests.swift` that exercises machine re-stamping, or construct
  records through the internal path those tests use. If no seam exists without
  touching other files, assert the behavior through a record copy helper test
  and note it in the Progress Log.

## Verification

```text
mkdir -p /tmp/ccusage-gauge-effort
swift build > /tmp/ccusage-gauge-effort/EDF-01-build.log 2>&1; echo "exit=$?"
swift test --filter UsageEffortContractTests > /tmp/ccusage-gauge-effort/EDF-01-test.log 2>&1; echo "exit=$?"
swift test --filter Directory > /tmp/ccusage-gauge-effort/EDF-01-directory.log 2>&1; echo "exit=$?"
swiftlint lint --quiet Sources/AppCore/UsageEffort.swift Sources/AppCore/ClaudeUsageEvents.swift Sources/AppCore/CCUsage.swift Tests/AppCoreTests/UsageEffortContractTests.swift > /tmp/ccusage-gauge-effort/EDF-01-lint.log 2>&1; echo "exit=$?"
wc -l Sources/AppCore/CCUsage.swift Sources/AppCore/ClaudeUsageEvents.swift
```

Expected evidence:

- the build exits 0;
- the new suite passes;
- the existing directory suites still pass (filter `Directory` matches
  `UsageDirectoryEventTests`, `DashboardDirectoryQueryTests`,
  `MachineDirectoryAPITests`, `DirectoryCacheMigrationTests`, and the
  `Directory*RegressionTests`), which proves existing call sites are
  unaffected;
- swiftlint reports no violations;
- both files stay under 1000 lines.

## Completion criteria

- [x] All four files are in the state described above.
- [x] All verification commands are recorded with exit status 0 and log paths.
- [x] `grep -c "effort" Sources/AppCore/CCUsage.swift` is at least 12: 2 fields,
      2 params, 2 CodingKeys, 2 decodes, and the four metric/session client copies.
      The blocks re-stamp is excluded because `CCUsageCostRecord` does not carry effort.

## Progress Log

- 2026-09-29: Plan created.
- 2026-09-29: Implemented EDF-01. Added `UsageEffort.normalized`, optional effort
  on `TimestampedUsageEvent`, `CCUsageMetricRecord`, and
  `CCUsageSessionMetricRecord`, optional decoding and nil-omitting synthesized
  encoding, plus effort propagation at all four metric/session machine
  re-stamps. `CCUsageCostRecord` and block re-stamping remain unchanged by
  design. Added five contract tests. The current CCUsage JSON loader has no
  seam to inject an effort-bearing row into `CCUsageClient`, so a focused
  record-copy test covers the re-stamp contract while the four client hunks
  explicitly copy effort.
  - Post-edit SHA-256: `Sources/AppCore/UsageEffort.swift`
    `d697a9b19e8728d69f0edd1300527811d9bc00d858680a0decf52fd7fc46e578`;
    `Sources/AppCore/ClaudeUsageEvents.swift`
    `0d77754e25104dfebce057b67981ace1fc09e7febf2099ea8a9bf6dccff4d163`;
    `Sources/AppCore/CCUsage.swift`
    `b326f9d9edc9616553aeabfbcba10e15312747aadf6bd5dd8004238de788ac35`;
    `Tests/AppCoreTests/UsageEffortContractTests.swift`
    `de81779c02b103fd0c76dd774056df74a5942028b12e51d3dd1b9262134baf57`.
  - `swift build`: exit 0, complete log `/tmp/ccusage-gauge-effort/EDF-01-build.log`.
  - `swift test --filter UsageEffortContractTests`: exit 0, 5 tests passed,
    complete log `/tmp/ccusage-gauge-effort/EDF-01-test.log`.
  - `swift test --filter Directory`: exit 0, 44 tests passed,
    complete log `/tmp/ccusage-gauge-effort/EDF-01-directory.log`.
  - Strict changed-file SwiftLint via the NUL-delimited manifest:
    exit 0, complete log `/tmp/ccusage-gauge-effort/EDF-01-lint.log`.
  - `wc -l Sources/AppCore/CCUsage.swift Sources/AppCore/ClaudeUsageEvents.swift`:
    exit 0; 799 and 400 lines. `grep -c "effort" Sources/AppCore/CCUsage.swift`:
    exit 0; 14 occurrences.
  - Self-check strengthened normalization tests for all accepted character
    classes and the 32-character boundary, and changed the identity test to
    compare distinct normalized efforts. Final-tree reruns: `swift test
    --filter UsageEffortContractTests` exited 0 with 5 tests passed
    (`/tmp/ccusage-gauge-effort/EDF-01-test-rerun.log`); `swift test --filter
    Directory` exited 0 with 44 tests passed
    (`/tmp/ccusage-gauge-effort/EDF-01-directory-rerun.log`); strict changed-file
    SwiftLint exited 0 (`/tmp/ccusage-gauge-effort/EDF-01-lint-rerun.log`).
  - The first build wrapper attempt exited 1 because zsh reserves the variable
    name `status`; the shell error is preserved at
    `tmp/dashboard-dark-flat-effort-20260929/EDF-01/attempt-1/first-build-wrapper-error.txt`.
    The corrected `swift build` rerun above exited 0.
  - Final source-tree `swift build` rerun exited 0; complete log
    `/tmp/ccusage-gauge-effort/EDF-01-build-rerun.log`. Final size check exited
    0 (`/tmp/ccusage-gauge-effort/EDF-01-line-count.log`); final grep count
    exited 0 with 14 (`/tmp/ccusage-gauge-effort/EDF-01-effort-count.log`).
