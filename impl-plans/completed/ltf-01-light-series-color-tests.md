# LTF-01: Light Series Color Tests

**Status**: Complete
**Plan ID**: LTF-01
**Wave**: 1
**Depends on**: none
**Design Reference**: `design-docs/specs/design-dashboard-light-theme-and-flat-icons.md` section 4
**Protocol**: `impl-plans/active/light-theme-flat-icons-overview.md` sections 4 and 5

## Purpose

`frontend/src/seriesColors.ts` already has light palettes: fixed hex values in
`LIGHT_MODEL_COLOR_FAMILIES` and `lightSeriesColors`, plus a light effort
ladder. These are uncommitted and have no tests. This plan adds the test rules
from design section 4 to `frontend/tests/seriesColors.test.ts`. It changes
light palette values only if a new test fails.

## Write paths

- `frontend/tests/seriesColors.test.ts`
- `frontend/src/seriesColors.ts`: light palette literals and
  `effortLadders.light` only, and only when a new test proves a value
  defective.
- `impl-plans/active/ltf-01-light-series-color-tests.md` (Status and Progress
  Log)

Evidence logs go to `tmp/light-theme-flat-icons-20260930/LTF-01`, created by
`mkdir -p` in the verification commands. `tmp/` is git-ignored, so it is not a
write path (overview protocol 7).

## Read-only context

- `frontend/src/colorScheme.ts:ColorScheme`
- `frontend/src/effort.ts:EFFORT_ORDER`
- The existing helpers at the top of `frontend/tests/seriesColors.test.ts`:
  `rgb`, `lab`, `deltaE`, `contrast`, `hsl`, `everyPair`. Reuse them and do not
  duplicate them.

## Non-goals

- Do not change any dark value: `MODEL_COLOR_FAMILIES`, `darkSeriesColors`,
  `effortLadders.dark`, or `CHART_BACKGROUND`.
- Do not change any existing dark test.
- Do not change function signatures or add exports to `seriesColors.ts`. The
  tests must use the current exports only:
  - `LIGHT_MODEL_COLOR_FAMILIES`, `LIGHT_CHART_BACKGROUND`, and
    `modelColorFamilies`;
  - `allocateModelColors`, `effortShade`, and `seriesColor` with their
    `scheme` argument.
- Do not touch `App.tsx`, `styles.css`, or any other test file.

## Changes

Add one `describe("light series colors", ...)` block after the existing one,
and extend the import list. Tests to add, written as situation -> expected
outcome:

1. Palette selection:
   - `LIGHT_CHART_BACKGROUND` -> `"#ffffff"`.
   - `modelColorFamilies("light")` -> `LIGHT_MODEL_COLOR_FAMILIES`.
   - `modelColorFamilies()` -> `MODEL_COLOR_FAMILIES`.
2. Each vendor's light family:
   - length equals the dark family length;
   - every value matches `/^#[0-9a-f]{6}$/`;
   - every value has `contrast(color, LIGHT_CHART_BACKGROUND) >= 3`;
   - all pairs have `deltaE >= 20`.
3. Hue parity. For each slot `i`, the light slot hue is within 5 degrees of the
   dark slot hue. Compare hues circularly: `min(d, 360 - d)`.
4. Light machine and subdirectory colors:
   - Call `seriesColor(kind, "key-" + n, undefined, "light")` for n = 0..299
     and collect the distinct results.
   - Each kind yields exactly 8 distinct colors.
   - Each color is at least 3:1 on `#ffffff`.
   - This checks the unexported `lightSeriesColors` without exporting it.
5. Light effort ladder. For every light family color `c`:
   - HSL lightness of `effortShade(c, e, "light")` for `e` in `minimal`,
     `low`, `medium`, `high`, `xhigh` is strictly increasing;
   - those 5 shades are pairwise `deltaE >= 11`;
   - `hsl(effortShade(c, undefined, "light"))[1] < hsl(c)[1]` (a missing
     effort desaturates);
   - `effortShade(c, "turbo", "light")` is a 6-digit hex value and is
     identical across two calls.
6. The dark default is unchanged. For a sample of dark family colors:
   - `effortShade(c, "high")` equals `effortShade(c, "high", "dark")`;
   - `allocateModelColors(catalog)(m)` equals
     `allocateModelColors(catalog, undefined, "dark")(m)` for every model `m`
     in `catalog = ["gpt-5.6-sol", "gpt-6-luna", "claude-opus-4-8", "gemini-2"]`
     (the catalog already used at `frontend/tests/seriesColors.test.ts:118`).
7. Slot parity. For that catalog, the index of each model's light color in
   `LIGHT_MODEL_COLOR_FAMILIES[vendor]` equals the index of its dark color in
   `MODEL_COLOR_FAMILIES[vendor]`.
8. Overrides in light:
   - `allocateModelColors(catalog, { "gpt-6-luna": "#123456" }, "light")("gpt-6-luna")`
     -> `"#123456"`;
   - `seriesColor("machine", "custom", { custom: "#123ABC" }, "light")` ->
     `"#123ABC"`.

## Pitfalls

- Pass `"light"` explicitly. Every helper defaults to dark, so a forgotten
  argument silently tests dark.
- Iterate over `Object.entries(LIGHT_MODEL_COLOR_FAMILIES)` together with the
  matching `MODEL_COLOR_FAMILIES[vendor]` for slot and hue comparisons. Do not
  rely on `Object.values` order.
- If a rule fails, first confirm the test follows design section 4 exactly.
  Only then adjust the offending light value in `seriesColors.ts`:
  - keep hue and saturation and change lightness only;
  - or adjust one `effortLadders.light` offset.

  Record the old and new values in the Progress Log. LTF-04 carries any ladder
  change into design section 4.
- Do not weaken a threshold to make a test pass.

## Verification

```text
mkdir -p tmp/light-theme-flat-icons-20260930/LTF-01
(cd frontend && bun test tests/seriesColors.test.ts) > tmp/light-theme-flat-icons-20260930/LTF-01/series.log 2>&1; echo "exit=$?"
(cd frontend && bun test) > tmp/light-theme-flat-icons-20260930/LTF-01/all.log 2>&1; echo "exit=$?"
(cd frontend && bun run check) > tmp/light-theme-flat-icons-20260930/LTF-01/check.log 2>&1; echo "exit=$?"
```

Expected evidence:

- `series.log`: exit 0, and the log lists the new `light series colors` tests
  as passing.
- `all.log`: exit 0.
- `check.log`: exit 0.

## Completion criteria

- [x] `grep -c 'describe("light series colors"' frontend/tests/seriesColors.test.ts`
      is 1.
- [x] `grep -c '"light"' frontend/tests/seriesColors.test.ts` is at least 8.
- [x] `git diff -- frontend/src/seriesColors.ts` shows no change to
      `MODEL_COLOR_FAMILIES`, `darkSeriesColors`, or `effortLadders.dark`.
- [x] All three verification commands exit 0, and their log paths are
      recorded.
- [x] The Progress Log has the intent snapshot, the post-hashes, and any
      palette changes with old and new values.

## Progress Log

- 2026-09-30: Plan created.
- 2026-09-30: Implemented the light series color assertions from design section 4. Added palette selection and dark default checks; vendor family length/hex/contrast/CIE76 checks; circular hue parity; machine/subdirectory palette count and contrast; light effort ordering, pairwise separation, missing-effort desaturation, and deterministic unknown effort; explicit dark equivalence; cross-theme slot parity; and light overrides. Existing dark test suite matches the pre-edit snapshot exactly. No palette values changed because all assertions passed.
- Intent snapshot: `tmp/light-theme-flat-icons-20260930/LTF-01/intent-snapshot.sha256` (pre-edit SHA-256: `frontend/tests/seriesColors.test.ts` `a321f2cc332fc42ad71c613eb8bdcc2e46878db7e279bf83e69063eb5d60da5c`; `frontend/src/seriesColors.ts` `57272a3b095770df478e5a13bbd4da326454e1eb6ea3f1339d305f8910744e52`; this plan `30a80c9f0c25811fa2cb29dfe7a06ddc874f4d210bed0e8e02a5bb8e67ddb325`). Per-edit intentions are in `tmp/light-theme-flat-icons-20260930/LTF-01/edit-intent.md`.
- Verification: `(cd frontend && bun test tests/seriesColors.test.ts)` exit 0, 16 passed / 0 failed; complete log `tmp/light-theme-flat-icons-20260930/LTF-01/series.log`. `(cd frontend && bun test)` exit 0, 130 passed / 0 failed across 21 files; complete log `tmp/light-theme-flat-icons-20260930/LTF-01/all.log`. `(cd frontend && bun run check)` exit 0; complete log `tmp/light-theme-flat-icons-20260930/LTF-01/check.log`. Mechanical criteria: exactly one light describe block and at least 8 explicit light arguments.
- Post-edit SHA-256: `frontend/tests/seriesColors.test.ts` `6ac58c1e6279942c74b441ed920206e81c7e2d83af3bffe809d129435a5e5046`; `frontend/src/seriesColors.ts` `57272a3b095770df478e5a13bbd4da326454e1eb6ea3f1339d305f8910744e52` (unchanged from intent snapshot). `git diff --check -- frontend/tests/seriesColors.test.ts` passed.
