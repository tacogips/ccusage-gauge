# rt-02: Dashboard Per-Pie Ratio-Text Visibility

**Status**: Completed
**Wave**: 1 (no dependencies; runs in parallel with rt-01)
**Design Reference**: `design-docs/specs/design-subscription-rate-limits.md`,
section "Configurable Ratio Text", subsections "Dashboard" and "Verification"
(frontend bullets). Decisions R7 and R8 are in
`design-docs/user-qa/2026-10-31-ratio-text-decisions.md`.

## Intent and Context

In the dashboard pie panel (`frontend/src/PieChartPanel.tsx`), the user wants
to show or hide each selected pie's ratio text (the `n% used` or status
detail). The choice is persisted with the dashboard UI state. By default every
selected pie shows its ratio text, which is today's behavior.

Persistence uses a hidden-set, `hiddenPieRatios: PieChartID[]`, which defaults
to `[]`. It travels through the existing `GET`/`PUT /api/dashboard-state`
save path next to `pieCharts`. rt-01 adds the Swift side of this field
(`DashboardUIState.hiddenPieRatios`, decoded with `decodeIfPresent` and a
default of `[]`). The frontend field is optional, so this plan does not depend
on rt-01 to compile or test.

## Non-Goals

- No CSS changes.
- No change to the pie selection toggles (`.pie-toggles`), the
  `RateLimitPanel`, or the "Menu budget" summary line (`App.tsx` around line
  1337).
- No new logic in `App.tsx` beyond threading: one signal, one apply line, one
  save field, two props, and an import.
- Do not run `mise run build`, `mise run frontend:build`, `bun install`, or
  `mise run frontend:check` / `frontend:test`. Those `mise` tasks run
  `bun install` first. Do not touch `Sources/AppCore/Resources/Web`, which
  rt-04 regenerates.
- No Swift changes.

## writePaths

- `frontend/src/api.ts`
- `frontend/src/rateLimits.ts`
- `frontend/src/PieChartPanel.tsx`
- `frontend/src/App.tsx`
- `frontend/tests/rateLimits.test.ts`
- `frontend/tests/appMarkupGuards.test.ts`
- `tmp/ratio-text-20261031/rt-02` (git-ignored evidence logs; artifact root)
- `impl-plans/active/rt-02-frontend-ratio-visibility.md` (Progress Log only)

## File-Level Changes

- **`frontend/src/api.ts`.** In `interface DashboardUIState`, add the optional
  field `hiddenPieRatios?: PieChartID[];` directly after `pieCharts?`.
- **`frontend/src/rateLimits.ts`.** Add two exported pure helpers next to
  `normalizePieCharts` and `togglePieChart`:
  - `normalizeHiddenPieRatios(value: unknown): PieChartID[]`
    - It keeps only known ids, in `pieChartIds` order, with no duplicates.
    - It returns `[]` for non-arrays and for an empty result. It does not
      fall back to `["budget"]`.
  - `toggleHiddenPieRatio(id: PieChartID, hidden: PieChartID[]): PieChartID[]`
    - It removes `id` if present, otherwise adds it, then normalizes.
    - There is no lock.
- **`frontend/src/PieChartPanel.tsx`.**
  - Add two props: `hiddenRatios: Accessor<PieChartID[]>` and
    `onToggleRatio: (id: PieChartID) => void`.
  - Inside each `pie-item`, define a local
    `ratioVisible = () => !props.hiddenRatios().includes(id)`.
  - Render the existing `<span>{detail()}</span>` only when `ratioVisible()`
    is true. Use `Show` from `solid-js`.
  - Add a button with:
    - `type="button"`;
    - `aria-pressed={ratioVisible()}`, the boolean form already used by the
      pie toggles in this file;
    - `aria-label={`Show ratio text for ${labels[id]}`}`;
    - `onClick={() => props.onToggleRatio(id)}`;
    - the visible text `Ratio`.
  - Keep the SVG `aria-label` as `${labels[id]}: ${detail()}`, always,
    including when the ratio is hidden.
- **`frontend/src/App.tsx`.** Threading only:
  - extend the import on line 66 with `normalizeHiddenPieRatios` and
    `toggleHiddenPieRatio`;
  - after the `pieCharts` signal (line 91), add
    `const [hiddenPieRatios, setHiddenPieRatios] = createSignal<PieChartID[]>([]);`;
  - in the dashboard-state `apply` (after `setPieCharts(...)`, line 805), add
    `setHiddenPieRatios(normalizeHiddenPieRatios(state.hiddenPieRatios));`;
  - in the save-state object (after `pieCharts: pieCharts(),`, line 841), add
    `hiddenPieRatios: hiddenPieRatios(),`;
  - on `<PieChartPanel ...>` (line 1334), add
    `hiddenRatios={hiddenPieRatios}` and
    `onToggleRatio={(id) => setHiddenPieRatios(toggleHiddenPieRatio(id, hiddenPieRatios()))}`.

## Patterns to Imitate

- `frontend/src/rateLimits.ts:normalizePieCharts` and `togglePieChart` show
  the normalize and toggle style. Do not copy the `["budget"]` fallback or the
  last-item lock.
- `frontend/src/PieChartPanel.tsx` shows the existing `For`/`button
  aria-pressed` markup and the `labels` map.
- `frontend/src/App.tsx` threads `pieCharts` through `createSignal`, `apply`,
  the save effect, and the `PieChartPanel` props. Mirror that exactly.
- `frontend/tests/appMarkupGuards.test.ts` uses `readFileSync`-based
  `toContain` source guards.

## Key Pitfalls

- The default must render exactly as today. With `hiddenPieRatios` equal to
  `[]`, every selected pie shows its detail span.
- Loaded state may lack `hiddenPieRatios`, because the server or SQLite state
  predates this change. Always run the value through
  `normalizeHiddenPieRatios`, which turns `undefined` into `[]`.
- Do not prune `hiddenPieRatios` when a pie is deselected. Design R7 keeps
  the two lists independent.
- Do not hide the SVG accessible label. Hide only the visible detail span.
- Do not change the existing `pie-toggles` button semantics or the
  `disabled` lock on the last pie.
- Do not add the new field to any other request payload.
- Keep `App.tsx` edits to the threading lines listed above. It is already
  1344 lines.

## Test Cases (situation -> expected outcome)

These go in `frontend/tests/rateLimits.test.ts`, in a new
`test("normalizes and toggles hidden pie ratios", ...)`:

- `normalizeHiddenPieRatios(undefined)` -> `[]`.
- `normalizeHiddenPieRatios([])` -> `[]`.
- `normalizeHiddenPieRatios(["codexWeekly", "x", "budget", "budget"])` ->
  `["budget", "codexWeekly"]`.
- `normalizeHiddenPieRatios("budget")` (not an array) -> `[]`.
- `toggleHiddenPieRatio("budget", [])` -> `["budget"]`.
- `toggleHiddenPieRatio("budget", ["budget"])` -> `[]`.
- `toggleHiddenPieRatio("claude5h", ["codexWeekly"])` ->
  `["claude5h", "codexWeekly"]`.

These go in `frontend/tests/appMarkupGuards.test.ts`, in a new
`test("wires per-pie ratio text visibility", ...)`. Read
`../src/PieChartPanel.tsx` with `readFileSync`, as the file already does for
the other sources.

- `PieChartPanel.tsx` contains `Show ratio text for `, `props.onToggleRatio(id)`,
  `props.hiddenRatios()`, and `<span>{detail()}</span>`. It also still
  contains `` aria-label={`${labels[id]}: ${detail()}`} ``.
- `App.tsx` contains
  `setHiddenPieRatios(normalizeHiddenPieRatios(state.hiddenPieRatios))` and
  `hiddenPieRatios: hiddenPieRatios(),`.
- `App.tsx` still contains `Menu budget: ` (regression guard).

## Verification

Run in the foreground from the repository root. Each command must exit 0.
`frontend/node_modules` already exists. Do not reinstall.

1. `mkdir -p tmp/ratio-text-20261031/rt-02`
2. `set -o pipefail; (cd frontend && bun run check) 2>&1 | tee tmp/ratio-text-20261031/rt-02/check.log`.
   The `tsc --noEmit` typecheck must pass.
3. `set -o pipefail; (cd frontend && bun test) 2>&1 | tee tmp/ratio-text-20261031/rt-02/test.log`.
   All tests must pass, and the log must include both new test names.
4. `grep -n "hiddenPieRatios" frontend/src/App.tsx | tee tmp/ratio-text-20261031/rt-02/app-threading.log`.
   Expect exactly the signal, apply, save, and two prop lines (5 or 6
   matches). No other logic may use it.

## Done Criteria

- [x] `grep -c "export function normalizeHiddenPieRatios\|export function toggleHiddenPieRatio" frontend/src/rateLimits.ts` returns 2.
- [x] `grep -n "hiddenPieRatios?: PieChartID\[\]" frontend/src/api.ts` matches.
- [x] Verification steps 2 and 3 exit 0, and their logs are complete.
- [x] `git status --short` shows changes only in this plan's writePaths, plus
  any pre-existing changes made by other plans.

## Progress Log

- 2026-10-31: Plan created.

- 2026-10-31: Implemented rt-02 dashboard ratio visibility and its helper and markup tests. The implementation criteria are satisfied: both helpers and optional API field are present; typecheck and all 138 tests pass; the threading and status checks are recorded. Bun's aggregate reporter suppresses test names, so the two named tests were also individually selected and each passed. Logs and per-edit intentions are under `tmp/ratio-text-20261031/rt-02/`. Status includes concurrent rt-01 files and pre-existing `.riela/retention/`; they were not edited by this plan. Formal review and rt-04 asset regeneration/full gate remain downstream.
- Verification (moving shared tree): `bun run check` exit 0; `bun test` exit 0 (138 passed, 0 failed); each new named test exit 0 (1 passed each); threading grep exit 0; scoped diff check exit 0.
- Source pre-edit -> post-edit SHA-256:
  - `api.ts`: eec237e3b3c84d2daa670219cf18b464eca332bd714fdfc2a6a2f04b2f52a553 -> bd50581f9ee15aa007430243e2ef01a05f767aa16b517e4740c5445661d0b9dc.
  - `rateLimits.ts`: b07515d95575e58c61e4f0ed1eaa4806754e6fef231c0f2056a07fc4882b53e2 -> c7a6716a8b6bc72f6b9d482a9b15861535f6a24844c6267be8461882ffd2d533.
  - `PieChartPanel.tsx`: 39bc3c76242f48d203cb2928294cee5b38d710d88867d7ebbe573f188b6fb888 -> 0607a9cee4201ac58b371f79c4ae04ae1d99820ec30550eb1887bcbd79749635.
  - `App.tsx`: 120322ce76dcb041c7a7c3604ca723155407f208df69ec05a0a3e9519685c957 -> c491fb76cf27631fb7a0556f37f0d16554d9965854a07fc1b889fa32439f547a.
  - `rateLimits.test.ts`: 8d0418a21e327dc203ef05a64afa279eef2f0f07065bc01c9e1ad022ac705edf -> 00015b17b666d1d661620e5edb72454e3f97a03c9267a63eeeff2ab769fdc850.
  - `appMarkupGuards.test.ts`: 754da9fd84f8c5922b6ed645ecb62e50793b79c46d61ad68005b7ab40739d1f8 -> d29527854452160af0317d83677f39315afb88fdd978b6ccdb33334128aa994f.
- 2026-10-31: Completed. Test-integrity review, adversarial review (needs_revision=false) and the integration review accepted rt-02. The rt-04 full gate exited 0 on the joined tree (`frontend-check.log`; `frontend-test.log`: 138 tests passed). The regenerated bundle contains the ratio toggle. The done-criteria greps were re-run at documentation refresh and matched (2, 1). Browser E2E was skipped because the repository has no browser E2E harness. Archived to `impl-plans/completed/rt-02-frontend-ratio-visibility.md`.
