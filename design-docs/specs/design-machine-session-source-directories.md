# Design: Per-machine Session-source Directories

## Status

Accepted for implementation on `feature/machine-session-dirs`.

This design extends the machine registry and collection contracts in
`design-remote-machine-collection.md`. It is authoritative for session-source
configuration, registry schema version 3, source-plan construction, and the
related runner, HTTP, CLI, and dashboard behavior. For sourced collection
commands, its fixed positional adapter supersedes the earlier direct
`remoteCcusagePath <arguments>` command shape; unsourced diagnostics retain the
earlier shape.

## Issue and reference mapping

The workflow-input issue is “Per-machine configurable Codex/Claude
session-source directories with default-dir opt-out.” No GitHub URL,
repository/number pair, Codex-agent reference, or Cursor CLI behavior was
provided. This design therefore derives behavior from the intake acceptance
signals and the current repository contracts only.

## Goal and scope

Every local or SSH machine has an independent source configuration:

- `codexSessionDirs: [String]`: additional Codex home directories;
- `claudeConfigDirs: [String]`: additional Claude configuration directories;
- `includeDefaultCodexDir: Bool`: include the effective default Codex home;
- `includeDefaultClaudeDir: Bool`: include the effective default Claude
  configuration directory.

The include-default values default to `true`; the directory arrays default to
empty. Therefore existing machines continue to use the same sources when the
fields are absent. One physical host can be represented by multiple logical
machines with defaults disabled and disjoint explicit directories.

Configured values name agent roots, not their scan subdirectories.
`codexSessionDirs` entries contain a `sessions/` directory and
`claudeConfigDirs` entries contain a `projects/` directory.

This feature does not add providers, credentials, arbitrary commands, remote
software installation, or a new usage-data format. Machine id remains the
provenance and cache-ownership boundary.

## Source configuration and defaults

For a local machine, the effective default roots are:

- Codex: `CODEX_HOME` when present, otherwise `$HOME/.codex`;
- Claude: `CLAUDE_CONFIG_DIR` when present, otherwise `$HOME/.claude`.

For an SSH machine, the same rules are evaluated in the remote execution
environment. Local environment values are never forwarded to SSH. An explicit
`~/path` is expanded against the home directory of the local process user or
the configured remote SSH user, respectively; `~other-user` is not supported.

Environment-derived defaults are not machine-configured paths and are not
subject to `MachineValidation`. To preserve pre-feature behavior, the presence
of `CODEX_HOME` or `CLAUDE_CONFIG_DIR` wins without trimming or rejecting an
empty or relative value. Local collection resolves that value with the same
process working-directory and filesystem semantics used before this feature;
SSH collection leaves resolution to the remote environment and fixed adapter,
matching the pre-feature remote `ccusage` invocation. These values are never
returned by the API or UI, included in public diagnostics, or forwarded between
hosts.

The source planner operates separately for Codex and Claude:

1. add the effective default root only when its include-default flag is true;
2. append explicit roots in stored order;
3. expand explicit `~`, standardize lexical path forms, and resolve existing
   filesystem aliases, while environment-derived entries retain their
   pre-feature host resolution semantics;
4. convert roots to scan scopes by appending `sessions/` for Codex or
   `projects/` for Claude;
5. remove duplicate scopes and any scope contained by an already selected
   broader scope; and
6. skip missing or non-directory scopes without failing collection.

Scopes are considered for containment from shallowest to deepest, with stored
order breaking ties. Local resolution uses standardized, symlink-resolved
filesystem URLs. The SSH adapter resolves home and existing paths in one fixed
remote path-probe operation before running `ccusage`; it does not interpolate
paths into executable shell text. Lexically normalized paths are retained when
a missing path cannot be canonicalized, then skipped by step 6.

Event identities remain a second deduplication boundary after file discovery.
The Codex identity is its session/token watermark identity and the Claude
identity is its session/request/message identity. This protects exact and
nested aliases from double counting even if the same event is encountered
through more than one retained filesystem path.

Disabling a default with no corresponding explicit roots is valid and produces
zero usage for that agent. A machine with no effective Codex or Claude roots is
also valid: collection performs no usage commands, publishes an empty healthy
snapshot, and does not reuse prior cached totals.

## Validation and normalization

`MachineValidation` validates every entry independently and reports errors
under indexed keys such as `codexSessionDirs[0]` and
`claudeConfigDirs[2]`.

A session-source path is valid when all of the following hold:

- its UTF-8 representation is between 1 and 4096 bytes;
- it starts with `/`, is exactly `~`, or starts with `~/`;
- it contains no NUL, carriage return, line feed, or other ASCII control
  character;
- it does not use `~user` or another relative form.

Dot and dot-dot components, repeated separators, trailing separators, spaces,
and other ordinary path characters are accepted. They remain path data rather
than command syntax and are standardized before containment and identity
deduplication. The server validates again after HTTP or CLI validation.
Duplicate or overlapping valid values are accepted and normalized by the source
planner rather than rejected. Boolean combinations and empty arrays are valid.

Malformed HTTP fields return `422 invalid_machine` with the existing error
envelope. JSON type errors, unknown fields, and malformed request structure
remain `400`.

## Registry persistence and compatibility

The persisted machine registry advances from schema version 2 to version 3.
Version 3 remains a closed document:

```json
{
  "schemaVersion": 3,
  "localSessionSources": {
    "codexSessionDirs": [],
    "claudeConfigDirs": [],
    "includeDefaultCodexDir": true,
    "includeDefaultClaudeDir": true
  },
  "machines": [
    {
      "id": "remote-a",
      "displayName": "Remote A",
      "kind": "ssh",
      "enabled": true,
      "codexSessionDirs": ["/srv/codex-a"],
      "claudeConfigDirs": ["~/claude-a"],
      "includeDefaultCodexDir": false,
      "includeDefaultClaudeDir": false,
      "ssh": {
        "host": "127.0.0.1",
        "port": 2222,
        "user": "ccusage",
        "extraOptions": [],
        "remoteCcusagePath": "ccusage"
      }
    }
  ]
}
```

The top level requires exactly `schemaVersion`, `localSessionSources`, and
`machines`. The local object requires exactly the four source fields. Every SSH
descriptor requires the four source fields in addition to the version-2
descriptor fields. Arrays preserve order and booleans must be JSON booleans.
Only SSH descriptors remain in `machines`; `local` is still synthesized with
its fixed id, name, kind, and enabled state plus `localSessionSources`.

Loading a valid version-2 registry atomically migrates it to version 3 by adding
the default local source object and adding `[]`, `[]`, `true`, and `true` to
every SSH descriptor. A valid version-1 registry follows the already specified
version-1-to-version-2 transformation and this transformation in one
synchronized atomic replacement before runtime publication. Migration failure
leaves the original bytes and runtime unchanged.

`MachineDescriptor` decoding outside the strict persisted-registry loader uses
`decodeIfPresent`, with `[]` and `true` defaults, so legacy API fixtures and
payloads remain decodable. The persisted loader still performs closed
version-specific key validation before decoding; backward compatibility does
not weaken fail-closed registry handling.

## HTTP contract

All machine responses include the four normalized fields, including `local`.
Create and replace requests may omit them; omission means `[]`, `[]`, `true`,
and `true`. Patch requests preserve omitted values and replace an array in full
when that array is present.

The existing routes retain their meanings with these additions:

- `POST /api/machines` creates an SSH descriptor with optional source fields;
- `PUT /api/machines/{id}` replaces an SSH descriptor, with omitted source
  fields taking backward-compatible defaults;
- `PATCH /api/machines/{id}` updates any non-empty subset of the four source
  fields in addition to the existing mutable fields; and
- `GET /api/machines` and `GET /api/machines/{id}` return effective normalized
  values.

`PATCH /api/machines/local` accepts only the four source fields. The local id,
display name, kind, enabled state, and absent SSH connection remain immutable.
`PUT` and `DELETE` for `local` continue to return `409 machine_conflict`.

Changing source configuration is a registry mutation. It uses the existing
serialized persistence/reconciliation transaction, replaces the affected
poller generation, fences older publications, and returns only after disk,
runtime, and the published registry revision agree.

Responses expose configured path strings because they are required for
editing, but never expose expanded home paths, canonical remote paths,
environment values, command arguments, stderr, or credentials. Existing SSH
sanitization rules remain unchanged.

## Collection data flow

Each machine service receives an immutable source configuration. It rebuilds
the resolved source plan at the start of every polling or on-demand collection
attempt, before consulting reusable aggregate data. One attempt retains its
plan unchanged through loading and publication.

Plan construction captures the configured roots, current environment-derived
defaults, canonical targets of existing paths, and missing/non-directory state.
Consequently, a configured directory that appears after startup, a symlink
whose target changes, or a changed remote default environment is observed by
the next attempt without requiring a registry edit or process restart.

Local collection supplies all selected Codex scan scopes to
`CodexUsageEventLoader` and all selected Claude scan scopes to
`ClaudeUsageEventLoader`. Their existing identity maps merge recent timestamped
events across roots before snapshot reconciliation.

Historical and fallback aggregates use a multi-source command coordinator for
both local and SSH machines. It executes `ccusage` once per agent source for
each requested fixed subcommand and range, then decodes and merges the results
under the one machine id. The command runner accepts a typed internal source
context; HTTP, CLI, and registry input cannot provide an executable, argument
list, environment name, or shell fragment through that context.

For an explicit Codex source, the local runner sets `CODEX_HOME` to the resolved
root and sets `CLAUDE_CONFIG_DIR` to a non-directory sentinel below
`/dev/null`; an explicit Claude source applies the inverse. A default source
whose environment variable was present reuses the captured value unchanged,
including an empty or relative value. A default source whose variable was
absent uses the resolved `$HOME` fallback. The runner derives a fresh process
environment from the service environment and changes only those two
application-owned keys.

The SSH runner applies the same isolation through a fixed POSIX adapter with
quoted positional values. The adapter then executes the validated
`remoteCcusagePath` with only the existing fixed ccusage arguments. Its probe
captures both the raw environment-derived default and the resolved identity
used for planning; execution reuses the raw value while fingerprinting and
deduplication use the resolved identity. Per-agent isolation prevents an
enabled default for the other agent from being counted repeatedly.

Decoded block, daily metric, and session rows are merged deterministically:
cost/token fields sum by their existing aggregation keys, model sets are
unioned, and session/event identities are retained once. Rows are stamped with
the machine id only after source-local merging. A selected existing source that
fails causes the machine collection to fail rather than silently publish
partial totals; missing sources were already skipped during planning.

Range loading and refresh progress counts source/range work units, while the
public result remains one snapshot and one health state per machine. Retries
apply to the failing source invocation, not to already successful sources.

## Cache coherence

Each machine cache stores a `sourceConfigurationFingerprint` metadata value
derived from:

- the source-semantics version;
- agent kind;
- include-default flags;
- normalized configured roots; and
- the freshly resolved source plan for the collection attempt, including
  missing/non-directory state.

The fingerprint is internal and never returned by an API. A missing or
mismatched fingerprint makes the cache stale: the affected machine cache is
replaced with an empty store before any cached aggregate is reused or new
results are published. The changed plan advances the affected machine's runtime
source generation. Publications carry the registry revision, collector
generation, and source-plan fingerprint; an older in-flight attempt that
finishes after the advance is fenced from publication. Registry edits use the
same fence and additionally replace the machine service. This applies to
configured-source changes, missing-to-present transitions, symlink retargeting,
remote default-environment changes, and upgrades from caches created before
this feature.

Unchanged source configuration keeps the existing per-machine incremental
cache behavior. Source changes never clear another machine's cache.

## CLI contract

Machine add accepts repeatable `--codex-session-dir <path>` and
`--claude-config-dir <path>` options plus
`--exclude-default-codex-dir` and `--exclude-default-claude-dir`.

A new `client machines update <id>` command updates session sources for local
or SSH machines. Repeatable directory options replace the corresponding list;
`--clear-codex-session-dirs` and `--clear-claude-config-dirs` explicitly send
empty lists. Include/exclude flag pairs are mutually exclusive and map to
tri-state patch values so omission preserves the server value. An update with
no requested field is a usage error.

Machine list/show JSON returns the server body. Human-readable list/show/add/
update output displays both include-default values and every configured
directory. It prints configured strings only, never resolved remote paths or
environment values.

## Dashboard contract

`frontend/src/api.ts` carries the four fields on `Machine`. Form state and
payload construction live in `frontend/src/machineForm.ts` and mutation
lifecycle behavior remains in `frontend/src/machineActions.ts`.

`frontend/src/MachineAdminPanel.tsx` shows source editing for local and SSH
machines. Each agent section has:

- a checkbox for its include-default flag;
- ordered repeatable directory rows;
- an Add control; and
- a Remove control for each row.

The local row exposes edit and refresh actions but not SSH test, enable/disable,
or delete actions. SSH connection fields remain visible only for SSH machines.
Saving local sources uses `PATCH`; saving an SSH edit may continue using the
complete `PUT` request.

Client-side validation mirrors path rules for immediate feedback, but server
validation is authoritative. Indexed server keys map to the corresponding row;
an unmapped error remains visible in the form-level alert. Removing every row
while disabling a default is allowed.

## Verification and rollout

Required automated coverage includes:

- descriptor decoding with omitted fields;
- version-1/version-2 registry migration and version-3 round-trip;
- accepted absolute and `~/` paths plus indexed rejection cases;
- local and SSH HTTP create/update/read round-trips;
- local-only source updates and local immutability;
- multi-root aggregation for both agents;
- default opt-out and valid empty-source behavior;
- exact, nested, and symlink-alias deduplication where the filesystem supports
  symlinks;
- missing-to-present source discovery and symlink retargeting between
  collection attempts;
- remote default-environment changes before cache reuse and fencing of the
  older in-flight plan;
- isolated SSH argument serialization without raw shell interpolation;
- cache-fingerprint invalidation after a source change;
- CLI parsing/rendering and dashboard form/error mapping.

Verification commands:

```text
task lint
swift build
swift test
task frontend:check
task frontend:test
task frontend:build
git status --short
```

No application version bump is part of this change. The registry schema
migration is automatic, atomic, and covered by rollback tests. Changes remain
limited to machine modeling, registry persistence, collection, API/CLI
surfaces, dashboard administration, tests, generated dashboard assets, and
these design specifications.
