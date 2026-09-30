# Optional Light Theme and Flat Icons

**Status**: Accepted. The frontend theme work (sections 2 and 3, and the light
palettes of section 4) is implemented in the working tree and not yet
committed. The light assertions in `seriesColors.test.ts`, the icons, the
bundled assets, and the browser check are not implemented yet.
**Amends**: `design-docs/specs/design-dashboard-dark-flat-effort-grouping.md`
section 2 (Dark Flat Theme). That spec removed the light theme. This addendum
brings light back as an explicit option. Dark stays the default, and every
flat-geometry rule still applies.
**Source request**: user request of 2026-09-30, with no GitHub issue. It asks
for dark as the default with an optional light theme, and for the icons to be
reconsidered as dark icons with a white rail. It follows commit `d34c4fc`.
**User decisions**: `design-docs/user-qa/2026-09-29-dashboard-theme-effort-decisions.md`
(decision 1 revised, open question 2 answered)

## 1. Requirements

| # | Requirement |
|---|---|
| 1 | Dark is the default theme on first load, whatever the OS appearance is |
| 2 | A light theme is available through a square icon button in the dashboard header, and the choice persists across reloads |
| 3 | Both themes keep the flat contract: no border-radius, shadows, or gradients |
| 4 | Chart series colors stay legible and distinct on both backgrounds |
| 5 | The app icon, the dashboard (Tauri) icon, and the menu-bar glyph are redesigned to match the flat style: a dark base with a white gauge rail |

Out of scope:
- following the OS appearance automatically;
- server-side persistence of the theme;
- theming the native menu-bar popover;
- a light variant of the app icon.

## 2. Theme Selection

- `frontend/src/colorScheme.ts` owns the theme state. It is implemented.
  - The type is `ColorScheme = "dark" | "light"`, and the default is `dark`.
  - The storage key is `ccusage-gauge-theme`.
  - `parseColorScheme` maps any value other than `"light"` to `dark`.
  - `readStoredColorScheme` and `storeColorScheme` wrap storage access in
    try/catch. If storage is missing or throws, the read returns dark and the
    write is dropped.
  - `applyColorScheme` sets `data-theme` on the root element.
  - `oppositeColorScheme` returns the other scheme.
- The key is new on purpose. Before the dark-only change, the old
  `ccusage-gauge-color-scheme` key was written automatically from
  `prefers-color-scheme`. Reading it again would open light-OS users in light
  mode, which breaks requirement 1.
  - The old key is never read, written, or deleted.
  - Only an explicit toggle writes the new key.
- `index.tsx` applies the stored theme to `document.documentElement`
  (`data-theme`) before the first render. This avoids a dark-to-light flash for
  users who chose light.
- `frontend/index.html` keeps `<meta name="color-scheme" content="dark">`. It
  matches the default and keeps the pre-CSS canvas dark.
- The theme is a per-browser preference, so it stays in localStorage. It is not
  added to the server-side dashboard UI state, because a desktop webview and a
  browser tab may reasonably differ.
- The toggle lives in `DashboardLayout.tsx` as `ThemeToggle`. `App.tsx` gets
  only:
  - the `colorScheme` signal and a `toggleColorScheme` handler;
  - the `ThemeToggle` element;
  - the scheme passed into the color helpers.

  This is about 10 lines, so `App.tsx` does not grow meaningfully.
- The toggle handler does three things in order: it updates the signal, it
  calls `applyColorScheme` on the root, and it calls `storeColorScheme`.
- `ThemeToggle` is a `theme-toggle` icon button placed under refresh in the
  header `stats-actions` column.
  - It is 32 by 32 px, like refresh.
  - Its `aria-label` and `title` read "Switch to light theme" or "Switch to
    dark theme".
  - It shows a square sun glyph (a square core with rays) in dark mode and a
    crescent in light mode.
  - The SVG strokes use `stroke-linecap: square` and `stroke-linejoin: miter`.

## 3. Stylesheet Tokens

- `styles.css` keeps the dark token block as the initial `:root { ... }`.
- It adds one `:root[data-theme="light"] { ... }` block. The block sets
  `color-scheme: light` and redefines every color token of the dark block,
  and nothing else.
- Color literals appear only in these two token blocks. Every other rule uses
  `var(--color-*)`.
- The hard-coded `input[type="date"] { color-scheme: dark; }` rule is removed.
  Date inputs inherit the root `color-scheme`.
- Both token blocks must meet these contrast floors (WCAG relative-luminance
  ratio):

| Pair | Floor |
|---|---|
| `--color-text` on `--color-bg` and on `--color-surface` | 4.5 |
| `--color-text-muted` on `--color-surface` | 3 |
| `--color-accent-text` on `--color-accent` | 4.5 |
| `--color-control-border` on `--color-surface` and on `--color-bg` | 3 |
| `--color-chart-axis` on `--color-surface` | 3 |
| `--color-border` on `--color-surface` | 1.5 |

- `flatThemeStyles.test.ts` parses both blocks and asserts every row for each
  theme through one `test.each` over dark and light. This is implemented.

## 4. Series Colors per Theme

This section describes what is implemented in `frontend/src/seriesColors.ts`.
Light uses fixed palettes. It does not adapt dark colors at runtime.

- Dark palettes do not change:
  - `MODEL_COLOR_FAMILIES`;
  - the dark machine and subdirectory palettes;
  - the dark effort ladder;
  - `CHART_BACKGROUND` (`#15171c`).
- The light model palette is `LIGHT_MODEL_COLOR_FAMILIES`.
  - Each slot keeps the hue and saturation of the matching dark slot.
  - Lightness is lowered so that each color reaches at least 3:1 on
    `LIGHT_CHART_BACKGROUND` (`#ffffff`, which equals the light
    `--color-surface`).
  - `modelColorFamilies(scheme)` selects the palette, and
    `allocateModelColors(catalog, overrides, scheme)` uses it. Slot allocation
    by stable hash is the same in both themes, so a model keeps the same slot
    index in both.
- The light machine and subdirectory palettes are `lightSeriesColors`.
  `seriesColor(kind, key, overrides, scheme)` selects between the two.
- `effortShade(base, effort, scheme)` uses a ladder for each scheme.
  - The light ladder is `minimal -18, low -9, medium 0, high +17, xhigh +32`.
    It is clamped to lightness 8 to 94.
  - The light ladder reaches further up than down, because light bases already
    sit at lower lightness.
  - Unknown efforts use the four-step unranked offsets of the scheme, and
    missing effort desaturates. Both work as in dark.
- User `chartColors` overrides come from `chartColors[scheme]` and are used
  verbatim for models and machines. This means the `light` configuration is
  used again.
  - Subdirectory series had no override path before this change and still have
    none.
- Validation rules, enforced in `seriesColors.test.ts`:
  - every `LIGHT_MODEL_COLOR_FAMILIES` color is at least 3:1 on `#ffffff`;
  - every light machine and subdirectory color is at least 3:1 on `#ffffff`;
  - within each vendor, light family colors are pairwise CIE76 dE of at least
    20 (the current palette is designed for at least 35);
  - for each light family color, the ranked effort shades `minimal` to `xhigh`
    have strictly increasing HSL lightness and are pairwise dE of at least 11;
  - the existing dark assertions stay unchanged and must pass.

## 5. Flat Icons

### 5.1 App icon and dashboard icon

- **Assets**:
  - `Resources/AppIcon.png` is 1024 by 1024.
  - `Resources/AppIcon.icns` is used by the build and staging scripts through
    `CFBundleIconFile`.
  - `Resources/DashboardIcon.png` is 128 by 128. It is the Tauri
    `bundle.icon` in `src-tauri/tauri.conf.json`.
- **Generator**: the new file `scripts/render-app-icon.swift`, run as
  `swift scripts/render-app-icon.swift` from the repository root.
  - It draws with CoreGraphics into bitmap contexts. It uses only AppKit,
    CoreGraphics, and ImageIO, with no third-party dependencies.
  - It writes the two PNGs above.
  - It writes a temporary `AppIcon.iconset` with the standard ten entries:
    `icon_{16,32,128,256,512}x{same}` plus `@2x`.
  - It runs `/usr/bin/iconutil -c icns` to produce `Resources/AppIcon.icns`,
    then removes the temporary iconset.
  - Each size is rendered from vector geometry at that size, not downscaled
    from the 1024 master.
  - Output is deterministic for a given macOS toolchain.
- **Geometry**. Units are fractions of the canvas side S. The origin is at
  bottom-left, and the center is at (0.5 S, 0.5 S).

| Element | Specification |
|---|---|
| Base | Full-bleed square filled with `#0f1115` (the dashboard `--color-bg`). No drawn rounded tile, bevel, shadow, gradient, or border. macOS applies its own mask. |
| Rail | Arc of radius 0.32 S and stroke width 0.085 S in `#ffffff`, with butt caps. It spans 270 degrees and leaves a 90-degree opening centered at the bottom, running clockwise from 225 degrees to -45 degrees (standard math angles). |
| Progress | The same radius and width in accent green `#277b5a` (the dark `--color-accent`), with butt caps. It is drawn over the rail from the 225-degree start and covers 62% of the rail sweep. |
| Bars | Three squared-off bars with no rounding, standing on a shared baseline at y = 0.30 S inside the ring, clear of the rail's inner edge. Each is 0.075 S wide, with a 0.035 S gap, and the group is centered horizontally. Heights are 0.14 S, 0.22 S, and 0.18 S. Colors, left to right, are vendor families Anthropic `#d78c57`, OpenAI `#55bdcf`, and other `#cd67d7` (the first dark slot of each family). |

- The script repeats the icon colors as literals, because it cannot read CSS.
  If `--color-bg` or `--color-accent` changes later, the icon must be
  regenerated.
- The geometry values are starting points. The implementer may adjust them by
  up to 0.02 S so the icon reads at 16 px. Any adjustment must keep the
  270-degree opening, the butt caps, and the no-effects rule.

### 5.2 Menu-bar glyph (`Sources/CCUsageGaugeMenuBar/MenuBarPieIcon.swift`)

- It stays an 18 by 18 pt `NSImage` with `isTemplate = true`, drawn in black
  with alpha. macOS renders it white on a dark menu bar and black on a light
  one.
- The public API `image(fraction:hasBudget:warning:)` is unchanged, so
  `MenuBarApp.swift` needs no changes.
- The ring is the circle inset 2 pt from the bounds, stroked 2.5 pt with butt
  caps, going clockwise from 12 o'clock.

| State | Drawing |
|---|---|
| Fraction known | Full 360-degree rail at alpha 0.35, plus a solid (alpha 1) arc for the clamped fraction in [0, 1]. A fraction of 0 draws the rail only. |
| Budget but unknown fraction | Rail at alpha 0.35, plus a solid quarter arc from 12 to 3 o'clock. |
| No budget | Rail at alpha 0.35, plus the existing vertical marker, a 1.5 pt butt-capped line through the center that stays inside the ring. |
| Warning | The existing outlined triangle and exclamation mark, unchanged. |

- The accessibility description is "Budget usage gauge" for non-warning states.
  The warning text is unchanged.

## 6. Verification

- Frontend unit tests:
  - `colorScheme.test.ts` is implemented. It covers the dark default, the
    ignored legacy key, the round trip, the storage fallbacks, and apply and
    toggle.
  - `flatThemeStyles.test.ts`:
    - flat geometry and literal confinement are implemented;
    - every dark token is redefined for light, which is implemented;
    - the section 3 contrast floors for both blocks, which is implemented.
  - `seriesColors.test.ts`: the section 4 light rules must be added, and the
    dark rules stay as they are.
  - `appMarkupGuards.test.ts` covers the toggle markup and the stats-actions
    placement. It is implemented.
- Icons:
  - run `swift scripts/render-app-icon.swift`;
  - `sips -g pixelWidth -g pixelHeight` reports 1024 for `AppIcon.png` and 128
    for `DashboardIcon.png`;
  - `iconutil -c iconset Resources/AppIcon.icns` round-trips to ten entries;
  - view the PNGs visually, because binary assets cannot be reviewed in a diff;
  - for the menu-bar glyph, render the four states to PNG with a throwaway
    script in the git-ignored `tmp/` evidence directory (never committed),
    view them, and report the result as evidence. The menu-bar target has no test target.
- Bundled assets: run `scripts/sync-frontend-assets.sh` after
  `cd frontend && bun run build`. `Sources/AppCore/Resources/Web` must then have
  no diff against a fresh build.
- Visual check: take Playwright screenshots of the dashboard in dark and light,
  at 1440 px and 390 px widths, and look for clipping, overflow, and invisible
  borders or text. The Playwright harness and its dependencies live outside the
  repository. Screenshots are uncommitted review evidence under the git-ignored
  `tmp/` evidence directory. Do not overwrite the existing
  `design-docs/screenshots/*.png`.
- Gate:
  - `cd frontend && bun test && bun run check && bun run build`
  - `swift build`
  - `swift test`
  - `swiftlint` on the changed Swift files (`MenuBarPieIcon.swift` and
    `scripts/render-app-icon.swift`)
  - `mise run lint`
  - `mise run test`

## 7. Rollout Constraints

- Land this as a change separate from `d34c4fc`. It must not be squashed into
  that commit.
- `frontend/src/App.tsx` stays under its current size plus about 10 lines. Any
  further theme wiring goes into `DashboardLayout.tsx` or `colorScheme.ts`.
- Keep Swift files under 1000 lines.
- Implementation path lists (plan Write paths and the dispatch manifest
  `writePaths`, `sharedPaths`, and `trackedPaths`) name only tracked source
  and asset paths, with `Sources/AppCore/Resources/Web` as a write path. The
  git-ignored caches and outputs `.build`, `frontend/node_modules`,
  `frontend/dist`, and `tmp/` contain or may contain symlinks. They are
  produced only as side effects of the gate commands and are never listed.
  Session 218 stopped at implementation because they were listed.
