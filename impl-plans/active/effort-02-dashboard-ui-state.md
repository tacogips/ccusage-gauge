# EDF-02: Dashboard UI State - modelEffort Stack and Fold Flags

**Status**: Not Started
**Plan ID**: EDF-02
**Wave**: 1
**Depends on**: none
**Design Reference**: `design-docs/specs/design-dashboard-dark-flat-effort-grouping.md` section 5 (Dashboard UI state) and section 3
**Protocol**: `impl-plans/active/dashboard-dark-flat-effort-overview.md` section 3

## Purpose

The SPA persists its view state through `GET` and `PUT /api/dashboard-state`,
stored by `DashboardStateStore`. This plan makes the server accept and persist:

- the new stack mode `modelEffort`;
- two fold flags, `sidebarCollapsed` and `headerCollapsed`.

Model stays the default.

## Write paths

- `Sources/AppCore/DashboardStateStore.swift`
- `Tests/AppCoreTests/DashboardUIStateFoldEffortTests.swift` (new)

## Non-goals

- No change to the SQLite schema. The state is one JSON blob in row id 1.
- No change to routes. They already decode and encode `DashboardUIState`.
- No frontend change (EDF-04 and EDF-11 handle it).

## Changes (`DashboardUIState` in `Sources/AppCore/DashboardStateStore.swift`)

- Add `public let sidebarCollapsed: Bool` and `public let headerCollapsed: Bool`.
- In the public init, add the trailing parameters
  `sidebarCollapsed: Bool = false, headerCollapsed: Bool = false`, after
  `stackBy`.
- Add both names to `CodingKeys`.
- In `init(from:)`, decode each with `decodeIfPresent(Bool.self, ...) ?? false`.
- Encoding is synthesized from `CodingKeys` and always writes both booleans.
- Add `"modelEffort"` to the allowed `stackBy` set in both places: the decode
  coercion (currently `["model", "machine", "subdirectory"].contains(decodedStackBy)`)
  and `validate()`. Unknown values still coerce to `"model"`.
- Put the allowed stack values in one private static constant so the two sites
  cannot drift apart.

## Pitfalls

- Keep the new init parameters defaulted and last. Existing tests in
  `MachineTests.swift`, `DashboardTests.swift`, `StoreTests.swift`,
  `DirectoryFeatureTests.swift`, and `DirectoryDisplayNameTests.swift`
  construct `DashboardUIState`, and they must compile unchanged.
- A JSON blob persisted before this change has no fold keys. It must load as
  `false`, `false` and must not throw.
- Do not use `decode` (non-optional) for the new keys.

## Tests (`@Suite("DashboardUIStateFoldEffortTests")`)

Imitate the existing `DashboardUIState` tests in
`Tests/AppCoreTests/StoreTests.swift` (grep `DashboardUIState`).

- Legacy JSON without `stackBy`, `sidebarCollapsed`, or `headerCollapsed` gives
  `stackBy == "model"` and both flags `false`, and passes `validate()`.
- JSON with `stackBy: "modelEffort"` decodes as `modelEffort` and passes
  `validate()`.
- JSON with `stackBy: "bogus"` decodes as `model`.
- A state built with `stackBy: "modelEffort", sidebarCollapsed: true, headerCollapsed: true`
  survives `DashboardStateStore` save then load against a temp file URL and is
  equal to the original.
- Encoded JSON contains `"sidebarCollapsed":false` when the value is false,
  proving the flag is always encoded.

## Verification

```text
mkdir -p /tmp/ccusage-gauge-effort
swift build > /tmp/ccusage-gauge-effort/EDF-02-build.log 2>&1; echo "exit=$?"
swift test --filter DashboardUIStateFoldEffortTests > /tmp/ccusage-gauge-effort/EDF-02-test.log 2>&1; echo "exit=$?"
swift test --filter DashboardStateStoreTests > /tmp/ccusage-gauge-effort/EDF-02-store.log 2>&1; echo "exit=$?"
swiftlint lint --quiet Sources/AppCore/DashboardStateStore.swift Tests/AppCoreTests/DashboardUIStateFoldEffortTests.swift > /tmp/ccusage-gauge-effort/EDF-02-lint.log 2>&1; echo "exit=$?"
```

Expected evidence: every command exits 0, and the existing
`DashboardStateStoreTests` suite remains green.

## Completion criteria

- [ ] `grep -c "modelEffort" Sources/AppCore/DashboardStateStore.swift` is at
      least 1, and the allowed set is defined once.
- [ ] The new tests pass, and all logs are recorded.

## Progress Log

- 2026-09-29: Plan created.
