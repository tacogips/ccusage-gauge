# LTF-04: Finalize, Bundled Assets, Visual Check, and Gate

**Status**: Ready
**Plan ID**: LTF-04
**Wave**: 2 (serial)
**Depends on**: LTF-01, LTF-02, LTF-03
**Design Reference**: `design-docs/specs/design-dashboard-light-theme-and-flat-icons.md` sections 2, 3, 6, 7
**Protocol**: `impl-plans/active/light-theme-flat-icons-overview.md` sections 4 and 5

## Purpose

This plan runs serially after wave 1. It does six things:

- reconciles wave-1 drift and failures;
- confirms that the adopted, pre-existing theme work satisfies the design;
- regenerates the bundled web assets;
- checks the toggle and persistence behavior and both themes in a real
  browser;
- runs the full gate;
- marks the design as implemented.

## Write paths

- `Sources/AppCore/Resources/Web` (directory; regenerated only by
  `mise run frontend:build`)
- `design-docs/specs/design-dashboard-light-theme-and-flat-icons.md` (the
  Status line, and the lines listed in step 8)
- `impl-plans/active/light-theme-flat-icons-overview.md` (Status and Progress
  Log)
- `impl-plans/active/ltf-04-finalize-assets-gate.md` (Status and Progress Log)

Not write paths. These are git-ignored and are produced only as side effects
of commands (overview protocol 6 and 7):

- `frontend/dist` (written by `bun run build` inside `mise run frontend:build`);
- `tmp/light-theme-flat-icons-20260930/LTF-04` (logs, the isolated server root,
  and the screenshots, created by `mkdir -p`);
- the Playwright harness, which lives outside the repository (step 7).

Repair-only paths. Edit these only to fix a concrete failure found in steps 1
to 7, and record each repair with its cause:

- `frontend/src/styles.css`
- `frontend/src/DashboardLayout.tsx`
- `frontend/tests/seriesColors.test.ts`
- `frontend/src/seriesColors.ts`
- `scripts/render-app-icon.swift`
- `Resources/AppIcon.png` (regenerated only by rerunning
  `swift scripts/render-app-icon.swift` after a serial repair of the script;
  never hand-edited)
- `Resources/AppIcon.icns` (same rule as `Resources/AppIcon.png`)
- `Resources/DashboardIcon.png` (same rule as `Resources/AppIcon.png`)
- `Sources/CCUsageGaugeMenuBar/MenuBarPieIcon.swift`

After any such regeneration, re-run the full LTF-02 verification block
(determinism hash diff, `sips` sizes, `iconutil` round-trip to 10 entries, and
the visual check) and write its logs under `tmp/light-theme-flat-icons-20260930/LTF-04/`.

## Non-goals

- Do not commit, push, or archive plans. Plans stay in `impl-plans/active/`.
- Do not grow `frontend/src/App.tsx`. It must stay at 1330 lines or fewer, and
  it is edited only if a defect cannot be fixed elsewhere.
- Do not overwrite `design-docs/screenshots/*.png`.
- Do not add Playwright or any other dependency to `frontend/package.json` or
  `frontend/bun.lock`.

## Steps

1. **Collect.**
   - Read the Progress Logs of LTF-01, LTF-02, and LTF-03.
   - **Survival check.** Run it before any repair. Write logs under
     `tmp/light-theme-flat-icons-20260930/LTF-04/` and record every exit
     status in the Progress Log.
     - For every file written by LTF-01, LTF-02, and LTF-03, compare the
       current `shasum -a 256 <file>` with the post-hash recorded in that
       plan's Progress Log. On a mismatch not caused by LTF-04, record
       `DRIFT <path> <recorded-hash> <current-hash>` and re-run the owning
       plan's full verification.
     - `shasum -a 256 -c tmp/light-theme-flat-icons-20260930/LTF-02/hash-2.txt`
       (the PNG hashes from LTF-02's second render) must exit 0.
     - Re-run the LTF-03 contract checks:
       - `grep -c 'move(to: center)' Sources/CCUsageGaugeMenuBar/MenuBarPieIcon.swift`
         is 0;
       - `grep -c '\.butt' Sources/CCUsageGaugeMenuBar/MenuBarPieIcon.swift`
         is at least 1;
       - `grep -c 'isTemplate = true' Sources/CCUsageGaugeMenuBar/MenuBarPieIcon.swift`
         is 1;
       - `grep -c 'Budget usage gauge' Sources/CCUsageGaugeMenuBar/MenuBarPieIcon.swift`
         is 1;
       - `git diff --quiet -- Sources/CCUsageGaugeMenuBar/MenuBarApp.swift`
         exits 0.
   - Fix every `DRIFT`, `BLOCKED-BY-FOREIGN`, and failed check.
   - Re-run the owning plan's verification commands and record the log paths.
   - If LTF-01 changed `effortLadders.light`, note the new offsets for step 8.
2. **Check the adopted theme contracts.**
   - `grep -n 'ccusage-gauge-theme' frontend/src/colorScheme.ts` returns 1
     line.
   - `grep -rn 'ccusage-gauge-color-scheme' frontend/src` returns no match.
   - `grep -n 'applyColorScheme(document.documentElement, readStoredColorScheme())' frontend/src/index.tsx`
     returns 1 line.
   - `grep -n '<meta name="color-scheme" content="dark" />' frontend/index.html`
     returns 1 line.
   - `grep -c ':root\[data-theme="light"\]' frontend/src/styles.css` is 1.
   - `grep -n 'color-scheme: dark; }' frontend/src/styles.css` returns no
     match.
3. **Check line limits.**
   - `wc -l frontend/src/App.tsx` is 1330 or less.
   - `wc -l Sources/CCUsageGaugeMenuBar/*.swift scripts/render-app-icon.swift`
     shows every file under 1000 lines.
4. **Run the frontend gate.** Write each log to `tmp/light-theme-flat-icons-20260930/LTF-04/<name>.log`
   and print `exit=$?`. Every command must exit 0.

   ```text
   (cd frontend && bun test)
   (cd frontend && bun run check)
   mise run frontend:build
   ```

   - `mise run frontend:build` runs `bun install --frozen-lockfile`,
     `bun run build`, and `scripts/sync-frontend-assets.sh`.
   - It must run after the last frontend source edit. If a repair changes a
     frontend source file later, run it again.
5. **Check the assets.**
   - `diff -r frontend/dist Sources/AppCore/Resources/Web` prints nothing and
     exits 0.
   - `grep -l 'data-theme' Sources/AppCore/Resources/Web/assets/*.css` lists
     1 file.
   - `grep -l 'ccusage-gauge-theme' Sources/AppCore/Resources/Web/assets/*.js`
     lists 1 file.
6. **Run the Swift gate**, after step 4 so the embedded resources are fresh.
   Write each log to `tmp/light-theme-flat-icons-20260930/LTF-04/<name>.log`. Every command must exit 0.

   ```text
   swift build
   swift test
   swiftlint lint --quiet Sources/CCUsageGaugeMenuBar/MenuBarPieIcon.swift scripts/render-app-icon.swift
   mise run lint
   mise run test
   ```

7. **Browser check (Playwright). This step is required.**
   - **Server.** Use an isolated root, modeled on
     `scripts/smoke-dashboard.sh:87-97`:
     - Export `CCUSAGE_GAUGE_CONFIG_HOME`, `CCUSAGE_GAUGE_STATE_HOME`, and
       `CCUSAGE_GAUGE_CACHE_HOME` under `tmp/light-theme-flat-icons-20260930/LTF-04/serve/`.
     - Leave `CLAUDE_CONFIG_DIR` and `CODEX_HOME` at the user's defaults, so
       charts show real series colors. They are only read.
     - Start
       `"$(swift build --show-bin-path)/ccusage-gauge" serve --port 18182 --assets Sources/AppCore/Resources/Web`
       in a tool session you keep. Do not use `&`.
     - Wait until `curl -fsS http://127.0.0.1:18182/api/health` succeeds.
     - If port 18182 is busy, pick another free port and record it.
   - **Harness.**
     - Create the harness outside the repository, at
       `"${TMPDIR:-/tmp}/ccusage-gauge-ltf04-pw/"`, and run `bun init -y` and
       `bun add playwright` there. Its `node_modules` contains symlinks, so it
       must never sit inside the repository.
     - Run `bunx playwright install chromium` inside that directory. Never
       inside `frontend/`.
     - Write `theme-check.ts` in that directory, and copy it to
       `tmp/light-theme-flat-icons-20260930/LTF-04/theme-check.ts` as evidence
       after the run. Using a fresh browser context
       with empty storage, it checks:
       - on first load, `document.documentElement.dataset.theme === "dark"`;
       - clicking `button[aria-label="Switch to light theme"]` sets the theme
         to `"light"`, and `localStorage.getItem("ccusage-gauge-theme") === "light"`;
       - after `page.reload()`, the theme is still `"light"`;
       - clicking `button[aria-label="Switch to dark theme"]` sets the theme
         to `"dark"`, and the storage value is `"dark"`;
       - with only `localStorage["ccusage-gauge-color-scheme"] = "light"` set
         before load (use `addInitScript` in a new context), the theme is
         `"dark"`.
     - Print one PASS or FAIL line per assertion, and exit non-zero on any
       FAIL.
   - **Screenshots.** Take full-page PNGs of dark and light at viewports
     1440x900 and 390x844, into `tmp/light-theme-flat-icons-20260930/LTF-04/screenshots/`:
     - `dark-1440.png`
     - `light-1440.png`
     - `dark-390.png`
     - `light-390.png`
   - **Visual review.** Open every screenshot with the image viewer tool, and
     record one line per file about:
     - clipping;
     - horizontal overflow;
     - invisible borders or text;
     - the toggle visible under refresh;
     - chart series legible on the background.

     A defect is fixed by a repair edit under the repair-only rules. After a
     repair, repeat steps 4 to 7.
   - **Stop the server** with Ctrl-C in its session and record its exit
     status.
   - **If the browser check cannot run** (for example, there is no network for
     the Chromium download), record `BLOCKED <reason>` with the log. Leave this
     plan's Status at `In Progress`. Do not mark the acceptance criterion as
     met.
8. **Update the design document**
   (`design-docs/specs/design-dashboard-light-theme-and-flat-icons.md`).
   - Set the `**Status**` line to `Implemented`.
   - Section 6: mark the `seriesColors.test.ts` item as implemented. (The
     section 3 and section 6 `flatThemeStyles.test.ts` lines were already
     corrected in the design step of session 220.)
   - If LTF-01 changed `effortLadders.light`, update the ladder numbers in
     section 4.
   - Make no other design edits.
9. **Finish.**
   - Run the emoji check:
     `LC_ALL=C grep -rln $'\xF0\x9F' frontend/src frontend/tests scripts/render-app-icon.swift Sources/CCUsageGaugeMenuBar design-docs/specs/design-dashboard-light-theme-and-flat-icons.md impl-plans/active/ltf-0*.md impl-plans/active/light-theme-flat-icons-overview.md`.
     It must list no file.
   - Check `git status --porcelain`. Every changed path must fall under the
     union of the plans' Write paths, the pre-existing uncommitted theme files
     (overview section 2), and the two user-qa and parent-spec edits already
     present. List any other path and revert only what this plan set wrote.
   - Set this plan's Status and the overview Status to `Completed`. Append a
     summary to the overview Progress Log:
     - repairs made;
     - gate results with log paths;
     - the Playwright results and screenshot paths;
     - residual items.

## Completion criteria

- [ ] The step 1 survival check passes: wave-1 post-hashes match or DRIFT is
      reconciled, `shasum -c` of LTF-02 `hash-2.txt` exits 0, and the LTF-03
      contract greps hold.
- [ ] Every gate command in steps 4 and 6 exits 0, and its log paths are
      recorded.
- [ ] Every item in steps 2, 3, and 5 holds.
- [ ] `theme-check.ts` prints only PASS lines and exits 0.
- [ ] Four screenshots are reviewed, each with a recorded line.
- [ ] The design Status is `Implemented`, and the stale lines are corrected.
- [ ] Nothing is committed or pushed.

## Progress Log

- 2026-09-30: Plan created.
