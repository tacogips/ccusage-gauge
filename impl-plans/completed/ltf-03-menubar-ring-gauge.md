# LTF-03: Menu-Bar Ring Gauge Glyph

**Status**: Complete (2026-09-30). The riela gate rejected the six-state render evidence as materially unverified. Verification was redone directly: contract greps, a visual review of the rendered states, swift build, strict swiftlint, and swift test.
**Plan ID**: LTF-03
**Wave**: 1
**Depends on**: none
**Design Reference**: `design-docs/specs/design-dashboard-light-theme-and-flat-icons.md` section 5.2
**Protocol**: `impl-plans/active/light-theme-flat-icons-overview.md` sections 4 and 5

## Purpose

The menu-bar status glyph is currently a filled pie wedge inside an outline
circle. This plan changes it to a flat ring gauge: a reduced-alpha full rail
plus a solid arc for the used fraction, with butt caps. The glyph stays a
template image, and the unknown, no-budget, and warning states are kept.

## Write paths

- `Sources/CCUsageGaugeMenuBar/MenuBarPieIcon.swift`
- `impl-plans/active/ltf-03-menubar-ring-gauge.md` (Status and Progress Log)

Logs, the throwaway render script, and the rendered PNGs go to
`tmp/light-theme-flat-icons-20260930/LTF-03`, created by `mkdir -p` in the
verification commands. `tmp/` is git-ignored, so it is not a write path
(overview protocol 7).

## Non-goals

- Do not rename the enum or the file. `MenuBarPieIcon` stays.
- Do not change the signature
  `static func image(fraction: Decimal?, hasBudget: Bool, warning: Bool = false) -> NSImage`.
- Do not edit `Sources/CCUsageGaugeMenuBar/MenuBarApp.swift`; the caller is at
  line 762 and does not change.
- Do not change `drawWarning(in:)`. The warning state is unchanged, including
  its accessibility text `"Warning: ccusage unavailable"`.
- Do not add color. The glyph is drawn in black with alpha only.
- Do not add a test target.

## Changes

- Keep `size = 18 by 18` and `image.isTemplate = true`.
- The ring geometry is `circle = bounds.insetBy(dx: 2, dy: 2)`. Draw ring
  paths as arcs on that circle's center with radius `circle.width / 2`, line
  width `2.5`, and `lineCapStyle = .butt`.
- Replace the current 1.5 pt outline with a full-circle rail stroked in
  `NSColor.black.withAlphaComponent(0.35)`. The rail is drawn first in every
  non-warning state.
- States:

| State | Drawing |
|---|---|
| Fraction known | Clamp to [0, 1]. At 0, draw the rail only. Otherwise stroke a solid (alpha 1) arc from 90 degrees to `90 - f * 360`, `clockwise: true`, the same angle convention as the current `drawSlice`. At `f >= 1`, stroke the full solid circle. |
| Budget, no fraction | Rail, plus a solid arc from 90 degrees to 0 degrees, `clockwise: true` (12 to 3 o'clock). |
| No budget | Rail, plus the existing vertical marker from `circle.minY + 2` to `circle.maxY - 2`, width 1.5, solid, with an explicit `.butt` cap. |
| Warning | `drawWarning(in:)`, unchanged. |

- Rename the private helpers to describe arcs, for example `drawUsedArc` and
  `drawUnknownArc`, and keep `drawBudgetMarker`.
- Set the accessibility description to `"Budget usage gauge"` for non-warning
  states.
- Follow the existing style in this file: 2-space indent, `private static func`
  helpers, and `NSBezierPath` rather than CG calls.

## Pitfalls

- The old wedge code calls `slice.move(to: center)` and then `fill()`. The arc
  must not start at the center and must be stroked, not filled. Otherwise it
  becomes a pie again.
- Use a fresh `NSBezierPath` for each arc, and set `lineWidth` and
  `lineCapStyle` on every path.
- Set the stroke color before each `stroke()`. The rail uses the 0.35 alpha
  color, and the used arc and marker use opaque black. Template images use
  only the alpha channel, so the used arc must stay fully opaque to contrast
  with the rail.
- The outer edge of the ring is at 7 + 1.25 = 8.25 pt from the center, inside
  the 9 pt half-size. Do not increase the inset or the width without checking
  for clipping.
- `CGFloat(truncating: fraction as NSDecimalNumber)` is the existing Decimal
  conversion. Reuse it.

## Verification

Throwaway render. Nothing outside `tmp/` is committed.

- Write `tmp/light-theme-flat-icons-20260930/LTF-03/render-main.swift`. It calls `MenuBarPieIcon.image`
  for these states:
  - `(0, true)`
  - `(0.4, true)`
  - `(1, true)`
  - `(nil, true)`
  - `(nil, false)`
  - `(nil, true, warning: true)`
- For each state it:
  - prints `isTemplate` and `accessibilityDescription`;
  - draws the image at 8x into an `NSBitmapImageRep` over a white background;
  - writes `tmp/light-theme-flat-icons-20260930/LTF-03/<state>.png`.
- Concatenate the source with the harness so the executable target is not
  imported:

```text
mkdir -p tmp/light-theme-flat-icons-20260930/LTF-03
swift build --product ccusage-gauge-menubar > tmp/light-theme-flat-icons-20260930/LTF-03/build.log 2>&1; echo "exit=$?"
if [ -s tmp/light-theme-flat-icons-20260930/LTF-03/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/light-theme-flat-icons-20260930/LTF-03/changed-swift-files.nul > tmp/light-theme-flat-icons-20260930/LTF-03/swiftlint.log 2>&1; echo "exit=$?"; fi
cat Sources/CCUsageGaugeMenuBar/MenuBarPieIcon.swift tmp/light-theme-flat-icons-20260930/LTF-03/render-main.swift > tmp/light-theme-flat-icons-20260930/LTF-03/render.swift
swift tmp/light-theme-flat-icons-20260930/LTF-03/render.swift > tmp/light-theme-flat-icons-20260930/LTF-03/render.log 2>&1; echo "exit=$?"
wc -l Sources/CCUsageGaugeMenuBar/MenuBarPieIcon.swift
```

Expected evidence:

- The build exits 0.
- `swiftlint.log` is empty, with exit 0.
- `render.log` exits 0 and prints `isTemplate true` for all six states,
  `Budget usage gauge` for five of them, and
  `Warning: ccusage unavailable` for the warning state.
- Visual check. Open each PNG with the image viewer tool and record:
  - `(0, true)` shows a faint ring only;
  - `(0.4, true)` shows a faint ring and a solid arc from 12 o'clock
    clockwise to about 5 o'clock;
  - `(1, true)` shows a solid ring;
  - the unknown state shows a solid quarter from 12 to 3;
  - the no-budget state shows a faint ring and a vertical line;
  - the warning state shows the unchanged triangle;
  - no state shows a filled wedge.

## Completion criteria

- [x] `grep -c "move(to: center)" Sources/CCUsageGaugeMenuBar/MenuBarPieIcon.swift`
      is 0.
- [x] `grep -c "\.butt" Sources/CCUsageGaugeMenuBar/MenuBarPieIcon.swift` is
      at least 1.
- [x] `grep -c "isTemplate = true" Sources/CCUsageGaugeMenuBar/MenuBarPieIcon.swift`
      is 1.
- [x] `grep -c "Budget usage gauge" Sources/CCUsageGaugeMenuBar/MenuBarPieIcon.swift`
      is 1.
- [x] `git diff --stat -- Sources/CCUsageGaugeMenuBar/MenuBarApp.swift` is
      empty.
- [x] All verification items pass, and their log and PNG paths are recorded.

## Progress Log

- 2026-09-30: Plan created.
- 2026-09-30 (session 220): Implemented the menu-bar rail and arc gauge in
  `Sources/CCUsageGaugeMenuBar/MenuBarPieIcon.swift`; preserved the image API,
  template flag, warning drawing/text, and `MenuBarApp.swift`.
  Source SHA-256: `2779ee0462db5216a29b042e8e9f493daf37a0a0eded67d4a3ecfd5457b4978d`.
  - `swift build --product ccusage-gauge-menubar`: exit 0;
    full log `tmp/light-theme-flat-icons-20260930/LTF-03/build.log`.
  - Selected-file `swiftlint lint --strict --quiet --no-cache` using
    `changed-swift-files.nul`: exit 0, empty diagnostics;
    full log `tmp/light-theme-flat-icons-20260930/LTF-03/swiftlint.log`.
  - `swift tmp/light-theme-flat-icons-20260930/LTF-03/render.swift`: exit 0;
    `render.log` reports all six template images, five
    `Budget usage gauge` descriptions, and the unchanged warning description.
    PNGs: `zero.png`, `partial.png`, `full.png`, `unknown.png`,
    `no-budget.png`, and `warning.png` in the same evidence directory.
    Visual review confirms rail-only zero, clockwise 0.4 arc, solid full ring,
    12-to-3 unknown quarter, vertical no-budget marker, and the warning
    triangle; no state has a filled wedge.
  - Invariant checks all exit 0; full log
    `tmp/light-theme-flat-icons-20260930/LTF-03/invariants.log`. Source remains
    under 1000 lines, no `move(to: center)` remains, butt caps are present,
    the template/accessibility strings occur once, and `MenuBarApp.swift` has
    no diff.
  - Awaiting independent implementation review and downstream integration.
- 2026-09-30 (Step 6 verification rerun): Re-ran the assigned behavioral and
  static gates against source SHA-256
  `2779ee0462db5216a29b042e8e9f493daf37a0a0eded67d4a3ecfd5457b4978d`.
  `swift build --product ccusage-gauge-menubar` exited 0;
  `tmp/light-theme-flat-icons-20260930/LTF-03/rerun-01/build.log` is complete.
  Selected-file strict SwiftLint exited 0 with an empty log at
  `tmp/light-theme-flat-icons-20260930/LTF-03/rerun-01/swiftlint.log`.
  The throwaway renderer exited 0 and rendered six states, each with
  `isTemplate=true`; five report `Budget usage gauge`, while warning retains
  `Warning: ccusage unavailable`. Complete output:
  `tmp/light-theme-flat-icons-20260930/LTF-03/rerun-01/render.log`; PNGs are
  `zero.png`, `partial.png`, `full.png`, `unknown.png`, `no-budget.png`, and
  `warning.png` under `tmp/light-theme-flat-icons-20260930/LTF-03/`.
  Visual inspection confirmed the expected six shapes and no filled wedge.
  Structural checks passed, and `MenuBarApp.swift` remains untouched. The plan
  remains awaiting independent review and downstream integration.
