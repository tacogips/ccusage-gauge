# Dashboard Theme and Effort Grouping - Decisions and Open Questions (2026-09-29)

Source: the workflow-input issue "Dashboard: dark flat theme, foldable panes,
active range buttons, effort grouping, distinct model colors".
Design: `design-docs/specs/design-dashboard-dark-flat-effort-grouping.md`.

The request did not settle the points below. The design adopts the defaults
listed here so implementation can proceed. Each one can be reversed without
changing the rest of the design.

## Default decisions (confirm or override)

1. Dark is the default theme. (Revised 2026-09-30: the user asked for an
   optional light theme. See
   `design-docs/specs/design-dashboard-light-theme-and-flat-icons.md`.) The
   original default was dark-only, recorded below. The stored
   `ccusage-gauge-color-scheme` browser value stays ignored, and the new
   explicit-choice key is `ccusage-gauge-theme`.
   - Original default: the light theme and the light/dark toggle were removed.
   - Reason: the request says "dark base", and restyling two flat themes would
     double the work with no accepted requirement for it.
   - The `chartColors.light` configuration stays valid, but the SPA no longer
     uses it.
2. Fold state is persisted server-side in the existing dashboard UI state as
   `sidebarCollapsed` and `headerCollapsed`, both defaulting to expanded.
   - One `sidebarCollapsed` flag covers both the wide (horizontal) and narrow
     (vertical) layouts.
   - Header folding applies only in the stacked header layout (1180px and
     below).
3. The effort grouping is a fourth stack mode, `modelEffort`, labeled
   "Model + effort". `model` stays the default.
4. Vendor hue families are assigned from the model name:
   - `claude` maps to Anthropic (warm hues);
   - `gpt-`, `codex`, and `o<digit>` map to OpenAI (green, teal, and blue
     hues);
   - everything else maps to other (violet and magenta hues).
5. Rows without a recorded effort are shown as `<model> (unknown)`. These are
   Claude rows, SSH-machine rows, ccusage aggregate fallback rows, and history
   whose event logs are gone.

## Open questions

1. Claude Code transcripts: does any current transcript line record a
   reasoning-effort or thinking level?
   - This change treats Claude effort as unknown.
   - If the implementation's check of a current transcript finds a recorded
     field, parsing it is a follow-up requiring confirmation. It is not added
     speculatively.
2. Should the light theme come back as an option later?
   - Answered 2026-09-30: yes. Dark stays the default, and light is an
     explicit option.
   - The icons are reconsidered too: the app icon and the menu-bar glyph become
     flat, with a dark base and a white gauge rail.

## Follow-up decisions (2026-09-30)

1. Model colors: distinctness takes priority over vendor hue families.
   - The palette is nine colors, three per vendor family. Extra models borrow
     unused colors from other families before any color repeats.
   - Reason: five similar hues per vendor could not be made clearly different
     (about 13 CIEDE2000 at most). The request allows vendor families but
     requires clearly different model colors.
   - See `design-docs/specs/design-dashboard-light-theme-and-flat-icons.md`
     section 4.

