# EDF-02: Dashboard UI State - modelEffort Stack and Fold Flags

**Status**: Completed
**Plan ID**: EDF-02
**Wave**: 1
**Depends on**: none
**Design Reference**: `design-docs/specs/design-dashboard-dark-flat-effort-grouping.md` section 5 (Dashboard UI state) and section 3
**Protocol**: `impl-plans/completed/dashboard-dark-flat-effort-overview.md` section 3

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

- `swift build`: initial attempt exited 1 while concurrent `CCUsage.swift`
  edits produced a transient compile mismatch; complete log:
  `/tmp/ccusage-gauge-effort/EDF-02-build.log`. Retry exited 0 against the
  shared tree:
  `/tmp/ccusage-gauge-effort/EDF-02-build-rerun1.log`.
- `swift test --filter DashboardUIStateFoldEffortTests`: exit 0; 5 passed,
  0 failed; `/tmp/ccusage-gauge-effort/EDF-02-test.log`.
- `swift test --filter DashboardStateStoreTests`: exit 0; 3 passed, 0 failed;
  `/tmp/ccusage-gauge-effort/EDF-02-store.log`.
- Changed-file strict SwiftLint via the NUL-delimited manifest in
  `tmp/dashboard-dark-flat-effort-20260929/EDF-02/changed-swift-files.nul`:
  exit 0; `/tmp/ccusage-gauge-effort/EDF-02-lint-final.log`.

## Completion criteria

- [x] `grep -c "modelEffort" Sources/AppCore/DashboardStateStore.swift` is at
      least 1, and the allowed set is defined once.
- [x] The new tests pass, and all logs are recorded.

## Progress Log

- 2026-09-29: Plan created.
- 2026-09-29: Step 6 started after confirming EDF-02 has no dependencies. Initial
  write-path snapshot: `Sources/AppCore/DashboardStateStore.swift`
  `06c5d69014f27ffdac99c2ab41bd19e8c27bbae0467f7f2c4fb528b7fcdfe218`;
  `impl-plans/completed/effort-02-dashboard-ui-state.md`
  `0c759ca588b0be58fdf9880ba815ec1db8d2a0eafb73b7102f0e8a5d835fd67c`;
  `Tests/AppCoreTests/DashboardUIStateFoldEffortTests.swift` did not exist.
  Intent: add one shared allowed-stack set, accept `modelEffort` in decoding and
  validation, default missing fold flags to false while always encoding them,
  and add legacy/coercion/round-trip tests. No schema, route, or frontend change.
- 2026-09-29: Implemented EDF-02 in the two assigned Swift paths. Post-edit
  SHA-256: `Sources/AppCore/DashboardStateStore.swift`
  `b0159a6f46fa181f3da54eb62425132242fe3e87a2897abbc99d7f648474a720`;
  `Tests/AppCoreTests/DashboardUIStateFoldEffortTests.swift`
  `4a231424a6fb163a6f1a14f89f2d968d443002e805e5103899f5bb960c14e2af`.
  Verification: `swift build` retry exit 0;
  `swift test --filter DashboardUIStateFoldEffortTests` exit 0 (5 passed, 0
  failed); `swift test --filter DashboardStateStoreTests` exit 0 (3 passed, 0
  failed); selected-file `swiftlint lint --strict --quiet --no-cache` exit 0.
  The first build attempt's shared-tree `CCUsage.swift` compile mismatch is
  retained above with its separate failed log and passing retry. Plan-local
  edit intentions and changed Swift manifest are under
  `tmp/dashboard-dark-flat-effort-20260929/EDF-02/`.
