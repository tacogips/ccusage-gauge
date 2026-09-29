# EDF-01: Swift Effort Record Contract

**Status**: Not Started
**Plan ID**: EDF-01
**Wave**: 1
**Depends on**: none
**Design Reference**: `design-docs/specs/design-dashboard-dark-flat-effort-grouping.md` section 5 (Normalization; Records, reconciliation, and merge keys)
**Protocol**: `impl-plans/active/dashboard-dark-flat-effort-overview.md` section 3

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

- [ ] All four files are in the state described above.
- [ ] All verification commands are recorded with exit status 0 and log paths.
- [ ] `grep -c "effort" Sources/AppCore/CCUsage.swift` is at least 11: 2 fields,
      2 params, 2 CodingKeys, 2 decodes, and 5 or more client copies.

## Progress Log

- 2026-09-29: Plan created.
