# EDF-09: Distinct Model Colors with Vendor Families and Effort Shades

**Status**: Completed
**Plan ID**: EDF-09
**Wave**: 2
**Depends on**: EDF-04 (`src/effort.ts`: `EFFORT_ORDER`, `effortRank`)
**Design Reference**: `design-docs/specs/design-dashboard-dark-flat-effort-grouping.md` section 7
**Protocol**: `impl-plans/completed/dashboard-dark-flat-effort-overview.md` section 3

## Purpose

Today, `frontend/src/seriesColors.ts` picks
`palette[scheme][kind][stableHash(kind:key) % 8]`. Hash collisions and
neighboring hues give near-identical colors, as reported for the sol and luna
models. This plan replaces model coloring with three things:

- vendor hue families;
- collision-free allocation over the model catalog;
- effort shades.

The file becomes dark-only.

## Write paths

- `frontend/src/seriesColors.ts`
- `frontend/tests/seriesColors.test.ts`

## Non-goals

- Do not edit `App.tsx`, `UsageChart.tsx`, or `DashboardComponents.tsx`.
  EDF-11 rewires the callers. Type errors in `src/App.tsx` are expected until
  then (overview protocol 7).
- No server or config change. The `/api/chart-colors` `dark.models` and
  `dark.machines` overrides are still honored by the callers.

## Exported contract (exact names)

- `export type ModelVendor = "anthropic" | "openai" | "other";`
- `export function vendorForModel(model: string): ModelVendor`. Lowercase the
  name first:
  - it contains `claude`: `anthropic`;
  - it starts with `gpt-` or `codex`, or matches `^o\d`: `openai`;
  - otherwise: `other`.
- `export const MODEL_COLOR_FAMILIES: Readonly<Record<ModelVendor, readonly string[]>>`
  - `anthropic`: warm reds, oranges, and ambers, hue about 0-50 degrees.
  - `openai`: greens, teals, cyans, and blues, hue about 140-225 degrees.
  - `other`: violets and magentas, hue about 260-330 degrees.
  - At least 5 lowercase `#rrggbb` colors per family.
  - Every color has HSL lightness in [48, 66], so the effort shades fit.
- `export function allocateModelColors(catalog: readonly string[], overrides?: Readonly<Record<string, string>>): (model: string) => string`
  1. De-duplicate and sort the catalog.
  2. For each vendor, iterate that vendor's non-overridden models in sorted
     order. Each takes `preferred = stableHash("model:" + name) % size`, or the
     next free slot by linear probing (`(i + 1) % size`).
  3. When every slot of a family is used, start a new round with an empty used
     set, so assignment reuses slots in the same probe order.
  4. The returned function:
     - returns an override when present;
     - otherwise returns the allocated color;
     - for a model not in the catalog, returns `family[preferred]` with no
       probing.
- `export function effortShade(baseColor: string, effort?: string): string`
  - Convert `#rrggbb` to HSL and keep the hue.
  - Ranked efforts use lightness offsets in percentage points:
    `minimal -24, low -12, medium 0, high +12, xhigh +24`, clamped to [20, 90].
  - Any other non-empty effort uses one of `-18, -6, +6, +18`, chosen by
    `stableHash("effort:" + effort) % 4`.
  - `undefined` or an empty string (unknown) keeps the lightness and multiplies
    saturation by 0.35.
  - The result is a lowercase `#rrggbb`.
  - Use `effortRank` or `EFFORT_ORDER` from `./effort` for ranking. Do not
    re-declare the order.
- `export type SeriesKind = "machine" | "subdirectory";`
- `export function seriesColor(kind: SeriesKind, key: string, overrides?: Readonly<Record<string, string>>): string`
  - This keeps the **existing dark** machine and subdirectory palettes and the
    existing hash, so the current dark machine and subdirectory colors do not
    change.
- Remove the `light` palettes, the `ColorScheme` export, and the `model` hash
  palette.
- `export const CHART_BACKGROUND = "#15171c";`. This matches EDF-03's
  `--color-surface` and is used only by tests.
- Keep `stableHash` (FNV-1a) unchanged. It may be exported for tests.
- Add a short code comment documenting that model colors depend on the catalog
  and are stable for a fixed catalog.

## Pitfalls

- Overrides must not consume a slot. Otherwise adding a config override would
  shift other models' colors.
- Sorting happens inside `allocateModelColors`. Callers may pass unsorted or
  duplicate lists.
- Do not edit `frontend/tests/dashboardDirectoryState.test.ts`. EDF-10 owns
  migrating its two old-signature `seriesColor("light", ...)` calls to the new
  contract.
- Do not choose family colors by eye alone. The tests below compute deltaE and
  contrast, and they must pass with the chosen constants.

## Tests (`frontend/tests/seriesColors.test.ts`, rewritten)

Put small helpers inside the test file: hex to sRGB to linear to XYZ (D65) to
CIELAB, CIE76 deltaE, and WCAG contrast.

- `vendorForModel`:
  - `"claude-opus-4-8"` gives `anthropic`;
  - `"gpt-5.6-sol"` and `"gpt-6-luna"` give `openai`;
  - `"o3-mini"` gives `openai`;
  - `"codex-mini"` gives `openai`;
  - `"gemini-2"` gives `other`.
- Family constants:
  - each family has at least 5 colors;
  - every pair inside a family has deltaE of at least 20;
  - every color has contrast of at least 3:1 against `CHART_BACKGROUND`;
  - HSL lightness is in [48, 66].
- The catalog `["gpt-5.6-sol", "gpt-6-luna", "gpt-5.5", "claude-opus-4-8", "claude-sonnet-4-6"]`
  produces all-distinct colors, and sol and luna differ by deltaE of at least 20.
- Stability:
  - the same catalog in a different order, with a duplicate, gives an identical
    mapping;
  - adding an `other` vendor model does not change any `openai` or
    `anthropic` color.
- Capacity: 5 or fewer openai models give unique colors. With 7 openai models
  every color comes from the family, and the function does not throw.
- With the override `{ "gpt-6-luna": "#123456" }`, `gpt-6-luna` returns
  `#123456`. Every other catalog model gets exactly the color it would get from
  `allocateModelColors(catalogWithoutLuna)`. This shows the override consumes
  no slot.
- `effortShade`:
  - `effortShade(c, "medium") === c`, up to hex rounding;
  - for each family color, the 6 variants (5 ranked plus unknown) are pairwise
    deltaE of at least 10;
  - lightness is monotonic from minimal to xhigh;
  - the unknown variant has lower HSL saturation than the base;
  - an unranked value such as `"turbo"` is deterministic across calls.
- `seriesColor("machine", "local")` returns the current dark palette value
  `#8fa6b5`, as the existing test expects. Namespace separation between
  machine and subdirectory still holds.

## Verification

```text
mkdir -p /tmp/ccusage-gauge-effort
cd frontend && bun test tests/seriesColors.test.ts > /tmp/ccusage-gauge-effort/EDF-09-test.log 2>&1; echo "exit=$?"
cd frontend && bun run check > /tmp/ccusage-gauge-effort/EDF-09-check.log 2>&1; echo "exit=$?"; grep -E "src/seriesColors\.ts" /tmp/ccusage-gauge-effort/EDF-09-check.log; echo "own-errors-grep-exit=$?"
```

Expected evidence: the test exits 0 and `own-errors-grep-exit=1`. `App.tsx`
errors are allowed at this wave.

## Completion criteria

- [x] The contract exports exist with the exact names above.
- [x] `grep -cw "light" frontend/src/seriesColors.ts` is 0 (whole word, so
      `lightness` is allowed) and `grep -c "ColorScheme" frontend/src/seriesColors.ts`
      is 0.
- [x] The deltaE and contrast tests pass, and all logs are recorded.

## Progress Log

- 2026-09-29: Plan created.
- 2026-09-29: Implemented dark vendor-family model colors, sorted catalog
  allocation with override slot skipping, and HSL effort shades in
  `frontend/src/seriesColors.ts`. Rewrote `frontend/tests/seriesColors.test.ts`
  with computed CIE76, WCAG contrast, and HSL assertions plus allocation and
  dark palette regression coverage.
- 2026-09-29: `bun test tests/seriesColors.test.ts` passed 8 tests / 428
  assertions after a first palette candidate failed the shade-distance check;
  the repaired palette was verified in
  `tmp/dashboard-dark-flat-effort-20260929/EDF-09/attempt-1/test-rerun.log`.
  `bun run check` still reports five expected `App.tsx` errors from old color
  API callers, owned by EDF-11; grep found no `seriesColors.ts` errors. The
  complete logs are under `tmp/dashboard-dark-flat-effort-20260929/EDF-09/attempt-1/`.
- 2026-09-29: Combined-tree integration review remains downstream with EDF-12.
