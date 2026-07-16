# Menu-bar Computer Use E2E Scenarios

These scenarios exercise the packaged AppKit UI and local dashboard with an
isolated configuration, state directory, and deterministic `ccusage` fixture.
They must not read or modify the user's production files under
`~/.config/ccusage-gauge` or `~/.local/ccusage-gauge`.

## Preparation

1. Run `scripts/build-e2e-app.sh fixture`.
2. Confirm port `18081` is free.
3. Launch `.build/e2e/CCUsageGauge.app` from Finder through Computer Use.
4. The E2E environment opens an inspection window that renders the exact
   status-item pie image and value and invokes the same action selectors as the
   production status menu. Production remains a menu-bar-only accessory app.
   All subsequent UI actions must be performed through Computer Use.

## E2E-001: Initial usage and menu-bar presentation

1. Launch the fixture app.
2. Verify the status item has the accessibility label
   `ccusage-gauge cost since reset`.
3. Verify the status item shows a pie-chart icon followed by `$3.75`.
4. Verify the menu shows the spent value, `Budget not set`, reset controls,
   dashboard controls, refresh, and quit.

Expected result: usage is aggregated from the fixture and no production state
file is touched.

## E2E-002: Set and persist a budget

1. Choose `Set budget…`.
2. Enter `10.00` and choose `Save`.
3. Reopen the menu and verify `Spent $3.75` and `Budget $10`.
4. Verify the menu-bar pie is approximately 37.5% filled.
5. Verify the isolated state JSON contains `"budgetUSD" : 10`.
6. Quit and relaunch, then verify the budget and pie remain present.

Expected result: the budget persists in `.build/e2e/home/state/ccusage-gauge/state.json`.

## E2E-003: Reset-cycle and manual-reset persistence

1. Choose `Reset cycle` and then `Monthly`.
2. Reopen the menu and verify the budget summary says `monthly`.
3. Choose `Reset now`.
4. Verify the isolated state contains a monthly reset cycle and a manual-reset
   timestamp.

Expected result: both changes persist and the cost-since-reset presentation
refreshes without modifying the read-only configuration.

## E2E-004: Dashboard lifecycle and content

1. Choose `Open dashboard`.
2. In Brave, verify the page heading is `ccusage-gauge`.
3. Verify the left model menu lists `claude-opus-4-8` and `gpt-5.6-sol`, and
   that the agent controls list `claude` and `codex`.
4. Select only `claude-opus-4-8` and verify the selected-period total is
   `$1.25`; select only `gpt-5.6-sol` and verify `$2.50`; restore `All models` and verify
   `$3.75`.
5. Verify the graph is labeled `Cost over time`, defaults to Hourly, and can be
   switched to Daily while preserving the filtered cost total.
6. Exercise the top-right `Today`, `Yesterday`, `This week`, and `This month`
   buttons.
7. Choose `Custom`, verify From/To calendar inputs appear, set both to today,
   and verify the total remains `$3.75`.
8. From the status menu choose `Stop dashboard` and verify the browser endpoint
   becomes unavailable.
9. Choose `Start dashboard`, reload, and verify the page returns.

Expected result: the Swift loopback service binds only to `127.0.0.1:18081`,
serves packaged assets, and starts and stops from the menu.

## E2E-009: Launch at Login setting

1. In the isolated inspection window, verify `Launch at Login: Off`.
2. Toggle it and verify the state becomes `On`.
3. Toggle it again and verify the state becomes `Off`.

Expected result: the production menu uses `SMAppService.mainApp`; E2E uses an
in-memory controller and never changes the operator's login items.

## E2E-010: ccusage warning and details

1. Build and launch the `missing` fixture mode.
2. Verify the status icon accessibility label is `Warning: ccusage unavailable`
   and the status value is `$!`.
3. Verify the visible error detail identifies the unavailable configured path
   and tells the operator to install ccusage or correct the config.

Expected result: invalid configuration is visible from the menu surface without
opening logs, while state-only actions remain available when state storage is valid.

## E2E-005: Missing ccusage validation with writable state

1. Quit the fixture app and run `scripts/build-e2e-app.sh missing`.
2. Launch the rebuilt app from Finder through Computer Use.
3. Verify `$!` and a non-sensitive `ccusage unavailable` message are shown.
4. Choose `Set budget…`, enter `12.00`, and save.
5. Verify the isolated state JSON contains `"budgetUSD" : 12` even though
   usage collection is unavailable.

Expected result: process validation fails visibly, but independent budget and
reset settings remain usable.

## Evidence to record

- Computer Use accessibility text or screenshots for every visible assertion.
- Isolated state/config fingerprints before and after each scenario.
- HTTP health and bind-address checks for dashboard lifecycle assertions.
- Exact build, test, and lint command results for the tested source revision.
