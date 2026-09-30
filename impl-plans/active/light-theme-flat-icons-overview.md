# Optional Light Theme and Flat Icons - Plan Overview

**Status**: In Progress
**Design Reference**: `design-docs/specs/design-dashboard-light-theme-and-flat-icons.md`
(accepted by the Step 3 design review with no findings)
**User decisions**: `design-docs/user-qa/2026-09-29-dashboard-theme-effort-decisions.md`
(decision 1 revised, open question 2 answered, both on 2026-09-30)
**Issue**: none. The source is the user request of 2026-09-30, a follow-up to
commit `d34c4fc`.

Only the finalization plan (LTF-04) edits this file. Every other worker edits
only its own plan file's `**Status**` line and `## Progress Log`.

## 1. User intent

The user asked for this in Japanese:

- "default はdark theme だがlight themeもあっていい。icon も考え直して"
  ("dark is the default, but a light theme would be fine too; rethink the
  icons")
- "icon などはdarkなものに白のrailが出るように" ("the icons and so on should be
  dark, with a white rail")

In other words:

- The dashboard keeps dark as the first-load default and gains an explicit,
  opt-in light theme.
- The app icon, the dashboard (Tauri) icon, and the menu-bar glyph are
  redesigned as flat dark icons with a white gauge rail.

## 2. Starting state (already in the working tree, uncommitted)

The frontend theme work is already implemented and has to be adopted, not
rewritten:

- `frontend/src/colorScheme.ts`: dark default, storage key
  `ccusage-gauge-theme`; the legacy key is never read.
- `frontend/src/index.tsx`: sets `data-theme` before render.
- `frontend/src/App.tsx`: the signal, the toggle handler, and the scheme passed
  into the color helpers. The file is 1330 lines.
- `frontend/src/DashboardLayout.tsx`: `ThemeToggle`.
- `frontend/src/styles.css`: the `:root[data-theme="light"]` token block and
  the `.theme-toggle` styles.
- `frontend/src/seriesColors.ts`: `LIGHT_MODEL_COLOR_FAMILIES`,
  `lightSeriesColors`, and the light effort ladder.
- Tests: `frontend/tests/colorScheme.test.ts`,
  `frontend/tests/flatThemeStyles.test.ts` (dark and light contrast floors are
  already asserted there), and `frontend/tests/appMarkupGuards.test.ts`.

Remaining work:

- the light assertions in `frontend/tests/seriesColors.test.ts`;
- the icon renderer script and the regenerated icon assets;
- the menu-bar ring gauge;
- the bundled web assets, the Playwright check, and the full gate.

## 3. Plans and dependency DAG

| Wave | Plan ID | File | Depends on |
|---|---|---|---|
| 1 | LTF-01 | `impl-plans/active/ltf-01-light-series-color-tests.md` | - |
| 1 | LTF-02 | `impl-plans/active/ltf-02-app-icon-renderer.md` | - |
| 1 | LTF-03 | `impl-plans/active/ltf-03-menubar-ring-gauge.md` | - |
| 2 | LTF-04 | `impl-plans/active/ltf-04-finalize-assets-gate.md` | LTF-01, LTF-02, LTF-03 |

Within wave 1, the `writePaths` of different plans are disjoint. There are no
cross-plan code contracts in wave 1, because each plan touches a separate
module. LTF-04 is the only serial reconciliation point.

## 4. Shared execution protocol (every plan)

1. **One working tree, no git mutations.** All plans run on branch `main` in
   `/Users/taco/gits/tacogips/ccusage-gauge`.
   - Do not run `git commit`, `git stash`, `git checkout`, `git reset`,
     `git restore`, `git clean`, or `git push`.
   - Do not create branches or worktrees.
   - Read-only `git status` and `git diff -- <own paths>` are allowed.
2. **Write only your own paths.** Edit only the files in your plan's Write
   paths, plus your own plan file's `**Status**` line and `## Progress Log`.
   - Never reformat, lint-fix, or "repair" any other file.
   - Never touch the pre-existing theme files listed in section 2 unless your
     plan names them.
3. **Record an intent snapshot first.** Before the first edit, append to your
   Progress Log:
   - the files you will change;
   - `shasum -a 256 <file>` for each file that already exists;
   - one line of intent per file.
4. **Read fresh before every edit.** Re-read a file just before each edit.
   - If its hash differs from your last recorded hash and you did not cause
     the change, record `DRIFT <path> <old-hash> <new-hash>`.
   - Then re-read the file and reapply only your own intent on top of the
     current content.
   - Never revert content you did not write.
5. **Record post-hashes.** When you finish, record `shasum -a 256` for every
   file you wrote.
6. **Foreign breakage.** Wave-1 commands implicitly share the git-ignored
   build caches `.build` and `frontend/node_modules` (and LTF-04 writes
   `frontend/dist`).
   - These caches contain symlinks. They are never listed as write, shared,
     or tracked paths in any plan or in the dispatch manifest; commands create
     and use them as side effects only. Do not edit them by hand.
   - If a command fails only because of files outside your Write paths, rerun
     it up to 3 times, about 2 minutes apart.
   - If it still fails, record
     `BLOCKED-BY-FOREIGN <file:line> <error> <log path>`, finish your remaining
     checks, and leave the repair to LTF-04.
7. **Logs.** Every verification command writes its complete output to
   `tmp/light-theme-flat-icons-20260930/<PLAN-ID>/<step>.log` and then prints `exit=$?`. `tmp/` is
   git-ignored. Commands create it with `mkdir -p`; it is not a write,
   shared, or tracked path, and nothing that creates symlinks (such as a
   `bun add` or `npm install`) runs inside it.
   - The Progress Log records the command, the exit status, and the log path.
   - A truncated log is not a pass.
8. **Foreground only.** Do not use `&`, `nohup`, `disown`, or `setsid`.
   - A long-running process, such as the LTF-04 dashboard server, runs in a
     tool session that you keep and poll.
   - Stop it yourself (Ctrl-C), and record its exit status.
9. **Content rules.**
   - English only, no emojis, no AI attribution.
   - Swift files stay under 1000 lines (`wc -l`).
   - After a Swift edit, run `swiftlint lint --quiet <changed Swift files>`.
   - Follow `.codex/skills/swift-coding-agent/SKILL.md` for Swift.
10. **Serial-only work.** Only LTF-04 does these:
    - `mise run frontend:build` and `scripts/sync-frontend-assets.sh`, which
      regenerate `Sources/AppCore/Resources/Web`;
    - edits to the design document or to this overview.

    No plan does these at all:
    - archive plans;
    - commit or push.

## 5. Pinned invariants (all plans)

- Dark is the default on first load, and the dark palettes, dark tokens, and
  dark tests do not change.
- The flat contract holds in both themes: no border-radius, box-shadow,
  text-shadow, gradients, or drop-shadow. Color literals appear only inside
  the two token blocks of `styles.css`.
- The public API of `MenuBarPieIcon.image(fraction:hasBudget:warning:)` is
  unchanged, and `Sources/CCUsageGaugeMenuBar/MenuBarApp.swift` is not edited.
- The consumers of `Resources/AppIcon.icns` (`scripts/build-local-app.sh`,
  `scripts/stage-desktop-app.sh`, `scripts/build-e2e-app.sh`,
  `scripts/build-homebrew-cask-release.sh`, the `CFBundleIconFile` entries in
  `Resources/*.plist`) and `src-tauri/tauri.conf.json` are not edited. Only
  the asset bytes change.
- `frontend/src/App.tsx` stays at 1330 lines or fewer.

## 6. Progress Log

- 2026-09-30: Plan set created from the accepted design. Main still has the
  unpushed commit `d34c4fc`; this work must land as a separate change (design
  section 7).
- 2026-09-30 (session 220, resume of session 218): session 218 stopped at
  step6-implement with policyBlocked "fanout change tracking refuses symlink
  ancestry", because the dispatch manifest listed git-ignored caches
  (`frontend/node_modules`, `.build`, `frontend/dist`, and the `tmp/` evidence
  directories) as write or shared paths. The manifest and the plan Write paths
  now list only tracked source and asset paths, the LTF-04 Playwright harness
  moved outside the repository, and `originalHead` is `9716395`. The design is
  unchanged apart from correcting its stale status and test-coverage lines.
