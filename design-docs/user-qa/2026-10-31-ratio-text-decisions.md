# Configurable Ratio Text - Decisions (2026-10-31)

Source: the workflow request "Make the usage-ratio text configurable alongside
the pie charts". There is no GitHub issue. Design:
`design-docs/specs/design-subscription-rate-limits.md`, section "Configurable
Ratio Text".

This record supersedes decision 7 in
`2026-10-31-subscription-rate-limit-decisions.md`, which said the status title
text does not change. The title now follows the ratio-text selection, and its
default reproduces today's text exactly.

## Decisions from the request

R1. The menu bar has its own ratio-text selection,
    `AppState.menuBarRatioLabels`. It is separate from `menuBarPieCharts` but
    uses the same `PieChartID` set.
    - The default is `[budget]`.
    - An empty selection is allowed, and the status item then shows only the
      glyph.
    - A missing key decodes as `[budget]`. An explicit `[]` stays `[]`.
R2. In the Settings menu, a "Ratio text" submenu sits next to "Pie charts".
    Its items toggle independently, and there is no last-item lock.
R3. The menu bar fetches rate limits when any non-budget pie or any non-budget
    ratio label is selected.

## Default decisions (confirm or override)

R4. The warning markers `$!` and ` !` are part of the budget text segment.
    When budget text is hidden, they are hidden too. The warning is still
    shown in these places:
    - the status button tooltip;
    - the accessibility label;
    - the budget pie's triangle, when the budget pie is selected.

    Reason: this keeps the default title exactly as it is today, and it adds
    no new title syntax.
R5. Rate-limit labels use these compact names:
    - `Claude 5h`;
    - `Claude W`;
    - `Codex 5h`;
    - `Codex W`.

    Each label is followed by the rounded used percent, using the same clamped
    fraction as the pie. It is `--` when no window is available for any
    reason (loading, unauthorized, unavailable, or an expired stale window). A
    stale window that is still valid shows its value without a marker.
R6. Labels appear in canonical `PieChartID` order with budget first. They are
    joined with `" · "`. The budget segment is today's string, unchanged.
R7. The dashboard stores a hidden-set, `DashboardUIState.hiddenPieRatios`,
    whose default is `[]`, rather than a visible-set.
    - The default renders exactly as today.
    - Old saved state still validates.
    - Entries persist independently of `pieCharts`.
R8. The dashboard control is a per-pie toggle inside each selected pie item.
    Hiding a ratio removes the visible detail text, meaning the `n% used` text
    or the status text. The SVG accessible label keeps the full detail. The
    "Menu budget" summary line does not change.
R9. With an empty ratio selection, the status item's accessibility value is
    `""`. The pie image's accessibility description still lists the values.

## Operator constraints for this run

R10. Dispatch-manifest `artifactRoots` and `writePaths` must never contain
     the bare `tmp` directory, because Riela fanout evidence lives under
     `tmp/opus-terra-waves`. The allowed roots are:
     - `.build`;
     - `frontend/dist`;
     - `frontend/node_modules`;
     - a plan-specific `tmp/ratio-text-20261031`.

     For this feature, this replaces the `tmp/` allowance in decision 8 of
     the earlier record.
R11. The run is local-only. The work goes into one commit on `main`, which
     excludes `.riela/` and `tmp/`. Nothing is pushed.

## Open questions

None block implementation. R4, R5, and R7 can each be reversed without
changing the rest of the design.
