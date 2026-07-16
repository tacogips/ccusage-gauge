# Computer Use E2E Result — 2026-07-16

## Tested build

- Product: `ccusage-gauge-menubar` debug build
- Bundle: isolated `.build/e2e/CCUsageGauge.app`
- UI driver: Computer Use through Finder, CCUsageGauge E2E, and Brave Browser
- Production configuration/state: fingerprints unchanged during the recorded run

## Results

| Scenario | Result | Evidence |
| --- | --- | --- |
| E2E-001 initial usage | Pass | Finder launch produced an E2E window with the shared pie image, `$3.75`, `Spent $3.75`, `Budget not set`, and `daily`; `/api/budget` returned `spentUSD: 3.75`. |
| E2E-002 set budget | Pass | Computer Use opened the AppKit alert, entered `10.00`, saved it, and observed `Budget $10.00`; isolated state persisted `budgetUSD: 10`. The shared pie image changed to the 37.5% progress rendering. |
| E2E-003 reset controls | Pass | Computer Use selected `Monthly`, then `Reset now`; UI changed to `$0.00` and isolated state recorded a monthly cycle, manual boundary, and manual-reset timestamp. |
| E2E-004 dashboard | Pass | `Open dashboard` loaded packaged assets in Brave. The page showed the expected heading, `$0.00` since the just-performed reset, `$10.00` remaining, and `$3.75` recent total. Yesterday returned `$0.00`; week/month returned `$3.75`. Stop produced `ERR_CONNECTION_REFUSED`; start restored the page. |
| E2E-005 missing ccusage | Pass | Missing explicit executable showed `$!` and a visible validation error. Computer Use still entered and saved `12.00`; isolated state persisted `budgetUSD: 12` and UI showed `Spent unavailable · Budget $12.00`. |
| E2E-006 reset custom hours | Pass | Computer Use opened `Custom reset cycle`, entered `6`, saved it, and observed `customHours(6)` in the shared menu state. |
| E2E-007 detailed metrics | Pass | The redesigned left sidebar exposed exact `claude-opus-4-8`/`claude` and `gpt-5.6-sol`/`codex` rows. Computer Use verified the combined `$3.75`, then selected `gpt-5.6-sol` and observed `$2.50`, 860 total tokens, 300 input, 60 output, 500 cache-read, and 0 cache-creation tokens. The cost chart defaulted to Hourly and retained `$2.50` when switched to Daily. |
| E2E-008 top-right periods | Pass | Today returned `$3.75`, Yesterday `$0.00`, and This week/This month `$3.75`. Custom exposed From/To date controls; setting both bounds to 2026-07-16 returned `$3.75`. |
| E2E-009 Launch at Login | Pass | The isolated controller initially showed `Launch at Login: Off`. Computer Use toggled it to `On`, then back to `Off`. The production controller uses `SMAppService.mainApp`; the E2E run did not modify the operator's login items. |
| E2E-010 ccusage warning | Pass | In missing mode, Computer Use observed `$!`, an icon labeled `Warning: ccusage unavailable`, and the full configured-path error with install/correction guidance. |

## Verification commands

```text
swift build --product ccusage-gauge-menubar
swift test
scripts/build-e2e-app.sh fixture
scripts/build-e2e-app.sh missing
```

Final verification passed 23 Swift tests in 10 suites, frontend typechecking and
production bundling, dashboard/isolated-runtime/packaged-assets smoke checks,
and SwiftLint 0.57.0 with zero violations. Direct `swiftlint` was unavailable on
the host PATH, so the lint gate ran through `nix develop`.

## Accessibility limitation and coverage

The Computer Use runtime does not expose macOS status-item menus as addressable
windows. E2E mode therefore opens a regular inspection window that renders the
same `MenuBarPieIcon` image and status value and invokes the same AppKit action
selectors as the production menu. Finder still launches the real app bundle and
the production status item is created. This covers the actual persistence,
process, reset, dashboard, and rendering code paths, but coordinate-level
clicking of the physical menu-bar item remains outside the runtime's accessible
surface.
