# LTF-02: Flat App Icon Renderer and Regenerated Icons

**Status**: Ready
**Plan ID**: LTF-02
**Wave**: 1
**Depends on**: none
**Design Reference**: `design-docs/specs/design-dashboard-light-theme-and-flat-icons.md` section 5.1
**Protocol**: `impl-plans/active/light-theme-flat-icons-overview.md` sections 4 and 5

## Purpose

The app icon and the Tauri dashboard icon are currently binary files with no
generator. This plan adds a checked-in CoreGraphics Swift script that renders
the flat icon: a dark base, a white 270-degree rail, an accent progress arc,
and three vendor bars. The script regenerates:

- `Resources/AppIcon.png` (1024 px);
- `Resources/AppIcon.icns`;
- `Resources/DashboardIcon.png` (128 px).

## Write paths

- `scripts/render-app-icon.swift` (new)
- `Resources/AppIcon.png`
- `Resources/AppIcon.icns`
- `Resources/DashboardIcon.png`
- `impl-plans/active/ltf-02-app-icon-renderer.md` (Status and Progress Log)

Logs and the round-trip output go to `tmp/light-theme-flat-icons-20260930/LTF-02`,
created by `mkdir -p` in the verification commands. `tmp/` is git-ignored, so
it is not a write path (overview protocol 7).

## Non-goals

- Do not edit the icon consumers:
  - `scripts/build-local-app.sh`, `scripts/stage-desktop-app.sh`,
    `scripts/build-e2e-app.sh`, `scripts/build-homebrew-cask-release.sh`;
  - `Resources/MenuBarInfo.plist`, `Resources/DashboardInfo.plist`;
  - `src-tauri/tauri.conf.json`;
  - `Package.swift`, `mise.toml`.
- Do not add a mise task.
- Do not add a light icon variant.
- Do not draw a rounded tile, bevel, shadow, gradient, or border. macOS masks
  the icon itself.

## Script contract (`scripts/render-app-icon.swift`)

- **Invocation**: `swift scripts/render-app-icon.swift`, with no arguments,
  run from the repository root.
  - If `./Package.swift` or `./Resources` is missing from the current
    directory, print `run from the repository root` to stderr and exit 1.
- **Imports**: `Foundation`, `CoreGraphics`, `ImageIO`, and
  `UniformTypeIdentifiers` if needed for the PNG type. No AppKit is needed and
  there are no third-party dependencies.
- **Rendering**: one function renders a square PNG of pixel size `S` directly
  from vector geometry.
  - Use a `CGContext` bitmap with the sRGB color space
    (`CGColorSpace(name: CGColorSpace.sRGB)`), 8 bits per component, and
    `premultipliedLast`.
  - Keep the default orientation: origin at the bottom-left, y up.
  - Turn antialiasing on.
  - Write the file with `CGImageDestination` as PNG, with no extra metadata.
- **Outputs, in order**:
  1. `Resources/AppIcon.png` at 1024.
  2. `Resources/DashboardIcon.png` at 128.
  3. A temporary directory
     `FileManager.default.temporaryDirectory/<UUID>/AppIcon.iconset` with
     exactly these ten files. Each is rendered at its own pixel size, not
     downscaled:

     | File | Pixels |
     |---|---|
     | `icon_16x16.png` | 16 |
     | `icon_16x16@2x.png` | 32 |
     | `icon_32x32.png` | 32 |
     | `icon_32x32@2x.png` | 64 |
     | `icon_128x128.png` | 128 |
     | `icon_128x128@2x.png` | 256 |
     | `icon_256x256.png` | 256 |
     | `icon_256x256@2x.png` | 512 |
     | `icon_512x512.png` | 512 |
     | `icon_512x512@2x.png` | 1024 |

  4. Run `/usr/bin/iconutil -c icns <iconset> -o Resources/AppIcon.icns`
     through `Process`. If the termination status is non-zero, print the
     status and exit 1.
  5. Remove the temporary directory, even after an iconutil failure (use
     `defer`).
- **Geometry**, copied from design section 5.1. Units are fractions of `S`;
  the center is `(0.5 S, 0.5 S)`.
  - **Base**: fill the full canvas with `#0f1115`.
  - **Rail**: `#ffffff`, radius `0.32 S`, line width `0.085 S`, butt caps.
    - It is a CG arc from 225 degrees to -45 degrees, `clockwise: true` in
      y-up coordinates.
    - It passes through the left, top, and right, and leaves the 90-degree
      opening at the bottom.
  - **Progress**: `#277b5a`, same radius, width, and cap.
    - It starts at 225 degrees, `clockwise: true`, and sweeps
      `0.62 * 270 = 167.4` degrees, ending at 57.6 degrees.
    - Draw it after the rail.
  - **Bars**: three filled rectangles with square corners, width `0.075 S`,
    gap `0.035 S`, and the group centered horizontally.
    - The shared bottom edge is at `y = 0.30 S`.
    - Left to right, heights are `0.14 S`, `0.22 S`, `0.18 S`, and colors are
      `#d78c57`, `#55bdcf`, `#cd67d7`.
- **Adjustments**: values may be adjusted by up to `0.02 S` for legibility at
  16 px. Record any adjustment in the Progress Log. The 270-degree opening,
  butt caps, and no-effects rule are fixed.
- **Colors**: keep all literals in one small constants section at the top,
  with a comment. The comment says the base and accent mirror the dark
  `--color-bg` and `--color-accent` in `frontend/src/styles.css`, and the bars
  mirror the first slot of `MODEL_COLOR_FAMILIES` in
  `frontend/src/seriesColors.ts`.

## Pitfalls

- CG angles are in radians. Convert degrees explicitly.
- CG `clockwise` is relative to the context's y-up coordinates. A flipped
  context reverses the visual direction. Do not flip the context.
- Do not use `NSImage` or TIFF round-trips. They add DPI and color-profile
  variation, and determinism depends on drawing straight to a CG bitmap.
- Do not set `lineCap` to `.round`, and do not add a shadow.
- The script is not a SwiftPM target and must not be put under `Sources`.
  SwiftPM must not pick it up.
- The script runs in Swift script mode with the mise toolchain (swift 6.3.3).
  Keep the top-level code simple and do not use async.

## Verification

```text
mkdir -p tmp/light-theme-flat-icons-20260930/LTF-02
swift scripts/render-app-icon.swift > tmp/light-theme-flat-icons-20260930/LTF-02/render-1.log 2>&1; echo "exit=$?"
shasum -a 256 Resources/AppIcon.png Resources/DashboardIcon.png > tmp/light-theme-flat-icons-20260930/LTF-02/hash-1.txt
swift scripts/render-app-icon.swift > tmp/light-theme-flat-icons-20260930/LTF-02/render-2.log 2>&1; echo "exit=$?"
shasum -a 256 Resources/AppIcon.png Resources/DashboardIcon.png > tmp/light-theme-flat-icons-20260930/LTF-02/hash-2.txt
diff tmp/light-theme-flat-icons-20260930/LTF-02/hash-1.txt tmp/light-theme-flat-icons-20260930/LTF-02/hash-2.txt; echo "determinism-exit=$?"
sips -g pixelWidth -g pixelHeight Resources/AppIcon.png Resources/DashboardIcon.png > tmp/light-theme-flat-icons-20260930/LTF-02/sips.log 2>&1; echo "exit=$?"
rm -rf tmp/light-theme-flat-icons-20260930/LTF-02/roundtrip.iconset
iconutil -c iconset Resources/AppIcon.icns -o tmp/light-theme-flat-icons-20260930/LTF-02/roundtrip.iconset > tmp/light-theme-flat-icons-20260930/LTF-02/iconutil.log 2>&1; echo "exit=$?"
ls tmp/light-theme-flat-icons-20260930/LTF-02/roundtrip.iconset | wc -l
swiftlint lint --quiet scripts/render-app-icon.swift > tmp/light-theme-flat-icons-20260930/LTF-02/swiftlint.log 2>&1; echo "exit=$?"
wc -l scripts/render-app-icon.swift
```

Expected evidence:

- Both renders exit 0, and `determinism-exit=0`.
- `sips.log` shows 1024 by 1024 for `AppIcon.png` and 128 by 128 for
  `DashboardIcon.png`.
- The iconutil round-trip exits 0 and lists 10 files.
- `swiftlint` exits 0 with no warnings. If it prints "No lintable files
  found", record that verbatim; it is not a failure.
- The script is under 1000 lines.
- Visual check. Open `Resources/AppIcon.png`, `Resources/DashboardIcon.png`,
  and `tmp/light-theme-flat-icons-20260930/LTF-02/roundtrip.iconset/icon_16x16.png` with the image viewer
  tool and record what you see:
  - a dark full-bleed square;
  - a white rail open at the bottom, with square ends;
  - a green segment running from the lower-left end over the top;
  - three square bars in orange, teal, and violet;
  - no rounded tile, shadow, or gradient;
  - the rail still readable at 16 px.

## Completion criteria

- [ ] `test -f scripts/render-app-icon.swift`
- [ ] `grep -c "iconutil" scripts/render-app-icon.swift` is at least 1.
- [ ] `grep -Ec '\.round\)|= \.round|[Ss]hadow|[Gg]radient|RoundedRect|cornerRadius' scripts/render-app-icon.swift`
      is 0. The pattern deliberately does not match `background`.
- [ ] Every verification item above passes, and its log paths are recorded.
- [ ] `git status --porcelain Resources` shows only the three icon files as
      modified.

## Progress Log

- 2026-09-30: Plan created.
