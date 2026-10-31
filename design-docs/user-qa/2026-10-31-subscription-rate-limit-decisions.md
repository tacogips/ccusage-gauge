# Subscription Rate Limits and Pie Selection - Decisions and Open Questions (2026-10-31)

Source: the workflow request "Add Claude Code and Codex 5h/weekly subscription
rate-limit module with selectable multi-pie charts (dashboard + menu bar)".
Design: `design-docs/specs/design-subscription-rate-limits.md`.

The request did not settle the points below. The design adopts the defaults
listed here so implementation can proceed. Each one can be reversed without
changing the rest of the design.

## Default decisions (confirm or override)

1. The dashboard and the menu bar keep separate pie selections.
   - The dashboard stores `DashboardUIState.pieCharts`, which persists through
     the existing `/api/dashboard-state` and SQLite store.
   - The menu bar stores `AppState.menuBarPieCharts` in `state.json`.
   - Both default to `[budget]`.
   - Reason: a shared selection would need either a new HTTP mutation path into
     `state.json`, which today is changed only by the menu bar, or the menu bar
     reading the dashboard's SQLite store. The glyph also has far less room
     than the dashboard.
2. The Claude Keychain item is read with `/usr/bin/security
   find-generic-password -s "Claude Code-credentials" -w`, using a fixed
   argument array and a 10-second timeout. It is not read with
   `SecItemCopyMatching`.
   - Reason: the item's existing access-control entry trusts that tool. A
     direct Security-framework read would prompt for each unsigned or updated
     ccusage-gauge binary.
   - The fallback is `.credentials.json`.
3. Codex windows that are neither 5h nor weekly appear in the API's
   `otherWindows`. The panel and the pies do not show them.
4. Credentials and the Codex JSONL fallback use only the default agent homes:
   `CLAUDE_CONFIG_DIR` or `~/.claude`, and `CODEX_HOME` or `~/.codex`.
   - Extra session directories configured per machine are not credential
     sources.
   - Reason: they may belong to other accounts.
5. The menu bar fetches rate limits only while at least one rate-limit pie is
   selected. The dashboard fetches them whenever it is open, because the
   rate-limit panel is always shown.
6. After a failed fetch, the last successful result is kept in memory and
   reported as `stale`. Claude `unauthorized` and `token_expired` are the
   exception and are always reported as `unauthorized`. Stale windows whose
   reset time has passed are dropped.
7. A rate-limit pie fills its used share, the same way the budget pie does.
   The menu-bar status title text does not change.

## Open questions

None block implementation.
