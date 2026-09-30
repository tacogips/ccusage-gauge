# Optional Light Theme and Flat Icons

**Status**: Implemented (2026-09-30). The riela opus-luna workflow (session
220) accepted LTF-01. Its gate refused script-based evidence for LTF-02 and
LTF-03 (`implementation-materially-unverified`), so verifying them and running
LTF-04 were done directly. Section 4 was also revised after a CIEDE2000 audit
of the model palettes.
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

### Model palette revision (2026-09-30)

- **Why.** A CIEDE2000 audit of the five-per-vendor families from `d34c4fc`
  found near-duplicates, such as the dark violets `#8d07fb`/`#7a47df` at 6.8
  and the dark oranges `#d78c57`/`#fb7b09` at 9.7. The Playwright check also
  showed that `gpt-6-sol` and `gpt-6.1-sol` rendered as two similar blues.
  - CIE76, used by the earlier tests, overstates differences between blues.
  - This contradicted the original requirement that model colors be clearly
    different.
- **Search results.** A search under the existing constraints (dark contrast
  at least 3 on `#15171c`, dark HSL lightness 48 to 66, light contrast at least
  3 on `#ffffff`, and effort-ladder separation in both themes) showed:
  - five colors per vendor top out near 13 CIEDE2000;
  - three per vendor reach 24.6 within a family and 19.7 across all nine.
- **Palette.** The model palette is now nine colors, three per vendor family,
  chosen jointly for both themes:

  | Vendor | Dark | Light |
  |---|---|---|
  | Anthropic (red, orange, yellow) | `#ff4754 #ffae51 #fff129` | `#b8000c #e07800 #857c00` |
  | OpenAI (cyan, blue, green) | `#2fc3da #2f7fda #63dc38` | `#20a2b6 #1f61ad #3a931a` |
  | Other (magenta, rose, violet) | `#f651ff #be3774 #6949df` | `#e900f5 #8e2957 #4723c7` |

  - Each light slot keeps the hue and saturation of its dark slot, so a model
    keeps its identity across themes.
- **Allocation.** `allocateModelColors(catalog, overrides, scheme)`:
  - each vendor fills its own family first, by stable-hash preferred slot with
    linear probing;
  - models beyond a family's three borrow unused colors from the other
    families in sorted order, again by hash-preferred index;
  - no two models share a color until all nine are in use, and only after
    that do colors repeat;
  - vendor hue families are a preference, and distinctness wins. The user
    allowed vendor families but did not require them.
  - Overrides still win without using a slot.

### Other series colors

- The dark machine and subdirectory palettes, the dark effort ladder, and
  `CHART_BACKGROUND` (`#15171c`) do not change.
- The light machine and subdirectory palettes are `lightSeriesColors`.
  `seriesColor(kind, key, overrides, scheme)` selects between the two.
- `effortShade(base, effort, scheme)` uses a ladder for each scheme.
  - The light ladder is `minimal -18, low -9, medium 0, high +17, xhigh +32`,
    clamped to lightness 8 to 94.
  - Unknown efforts use the four-step unranked offsets of the scheme, and
    missing effort desaturates.
- User `chartColors` overrides come from `chartColors[scheme]` and are used
  verbatim for models and machines.

### Validation rules (`seriesColors.test.ts`)

- All nine model colors are pairwise CIEDE2000 at least 19 in each theme.
  Within a vendor family the floor is 24.
- Dark model colors keep contrast at least 3 on `#15171c` and HSL lightness 48
  to 66. Light model, machine, and subdirectory colors are at least 3:1 on
  `#ffffff`.
- Effort shades: ranked lightness strictly increases, and variants are
  pairwise CIE76 dE of at least 11, in both themes.
- Allocation: three models of one vendor stay in that family. A mixed catalog
  of seven models gets seven distinct colors, all pairwise at least 19. Nine
  models get nine distinct colors, and only beyond nine do colors repeat.
- Slot indexes in the combined palette match between themes.

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
- **Geometry** (revised 2026-09-30 at the user's request for a white usage
  pie chart on a dark flat base). Units are fractions of the canvas side S, with
  the origin at bottom-left.

| Element | Specification |
|---|---|
| Base | A full-bleed square filled with `#0f1115` (the dashboard `--color-bg`). There is no drawn rounded tile, bevel, shadow, gradient, or border. macOS applies its own mask. |
| Remaining share (rail) | A pie sector of radius 0.34 S filled with white at alpha 0.24. It covers the 32% not used. |
| Used share | A solid white pie sector of radius 0.34 S covering 68%. It runs clockwise from 12 o'clock and is pulled out 0.03 S along its bisector, which leaves a clean dark gap with no outline stroke. |
| Centering | The whole pie is shifted back by half the pull-out offset, so the composition stays optically centered. |

- The script repeats `--color-bg` as a literal, because it cannot read CSS. If
  that token changes, regenerate the icon.
- The earlier gauge-and-bars geometry was replaced before release.

### 5.2 Menu-bar glyph (`Sources/CCUsageGaugeMenuBar/MenuBarPieIcon.swift`)

- It stays an 18 by 18 pt `NSImage` with `isTemplate = true`, drawn in black
  with alpha. macOS renders it white on a dark menu bar and black on a light
  one.
- The public API `image(fraction:hasBudget:warning:)` is unchanged, so
  `MenuBarApp.swift` needs no changes.
- It is a flat pie, matching the app icon. The pie is the circle inset 2 pt
  from the bounds, and wedges run clockwise from 12 o'clock.

| State | Drawing |
|---|---|
| Fraction known | A full disc at alpha 0.35 (the rail), plus a solid (alpha 1) wedge for the clamped fraction in [0, 1]. A fraction of 0 draws the disc only. |
| Budget but unknown fraction | The disc at alpha 0.35, plus a solid quarter wedge from 12 to 3 o'clock. |
| No budget | The disc at alpha 0.35, plus the vertical marker, a 1.5 pt butt-capped line through the center. |
| Warning | The outlined triangle and exclamation mark. The mark has a butt cap and a square dot. |

- The accessibility description stays "Budget usage pie chart" for
  non-warning states. This matches the E2E window labels in `MenuBarApp.swift`.
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
  - `seriesColors.test.ts` implements the section 4 validation rules
    (CIEDE2000 distinctness, contrast, effort ladders, and allocation).
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
