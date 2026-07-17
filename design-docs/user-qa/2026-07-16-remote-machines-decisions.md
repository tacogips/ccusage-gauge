# Remote Machine Collection - User Decisions (2026-07-16)

Source: `/goal` request to collect ccusage usage from multiple private GCP
machines, emulated locally with compose + colima.

The user asked for the "recommended" option on every open fork. Recorded here so
the implementation and any later reviewer share the same premises.

## Decisions

1. Transport: SSH-exec over a forwarded port.
   - Host opens a port-forward / IAP tunnel to the machine's `sshd` and runs
     `ssh <machine> ccusage <cmd> --json`, tagging the output with the machine id.
   - Remote setup is only `ccusage` + `sshd` (already present on a GCP box).
   - No daemon to deploy, no remote push, nothing persisted on the remote.
   - Matches the user's "direct ccusage via port-forward" and "lightest remote".
   - Prometheus exporter was rejected: heavier remote setup and its counter/gauge
     model loses the per-agent / per-model / token breakdown the dashboard needs.

2. Collector location: background per-machine poller inside `ccusage-gauge serve`.
   - Reuses the existing `PollingService` pattern; one process serves + collects.

3. Secrets and topology (local emulation): Docker Compose under Colima.
   - The accepted issue-resolution constraint is standalone `docker compose`
     only. Docker Swarm and other deployment topologies are forbidden.
   - A `keygen` container creates one ephemeral ed25519 pair in tmpfs. The
     private key is piped directly into a collector-container tmpfs and only the
     public key is piped into the SSH-machine tmpfs directories. Standalone
     Compose file-backed secrets are not used for credentials because they are
     bind mounts.
   - No key is written to the host, image, bind mount, named volume, writable
     layer, runtime cache/config, environment, argument, log, or Git candidate;
     the host's real `~/.ssh` is never read or mounted.
   - The collector API remains unpublished and is exercised through
     `docker compose exec` on its loopback interface. SSH uses the machines'
     published host ports, not direct service DNS, to retain the forwarded-port
     boundary.

4. Cache: one SQLite file per machine, on the host only, keyed by machine id.
   - `aggregates-<machineId>.sqlite3`. Remotes stay stateless.
   - Local machine keeps its own per-machine cache under the same scheme.

5. SSH execution safety contract.
   - Ignore ambient SSH config with `-F /dev/null`, use a fixed canonical option
     order, quote every remote token for the remote POSIX shell, accept only the
     closed operational option allowlist in the design, and reject config,
     proxy, command-hook, environment, remote-command, forwarding, and
     destination override forms.
   - `remoteCcusagePath` is one safe bare executable name or absolute POSIX path,
     never a command string.

6. Provenance compatibility contract.
   - Metric and session records expose a non-optional machine string.
     Constructors and legacy decode default to `local`; new encoding and all API
     rows always include the field.

7. Missing, stale, and aggregate snapshot behavior.
   - A selected enabled machine with no snapshot returns `503`; disabled returns
     `409`; unknown returns `404`. Retained stale snapshots remain readable.
   - The all-machine view returns partial `200` results when at least one enabled
     snapshot exists and exposes included, stale, and unavailable ids in response
     scope metadata; no usable snapshots returns `503`.
   - Aggregation uses the host calendar/reset boundary, the oldest component as
     `generatedAt`, the minimum positive refresh interval, and one host budget.
     Spending and derived budget values are recomputed from included rows.

8. Machine registry HTTP contract.
   - The collection route is exactly `/api/machines`; item updates and deletion
     target `/api/machines/{id}`. POST creates, PUT fully replaces mutable
     fields, PATCH replaces supplied top-level fields, and DELETE retains the
     host cache while removing registry/runtime state.
   - Shared request/response DTOs, mutation status codes, validation field
     errors, reserved-local conflicts, and persistence failures are fixed in the
     authoritative design. The frontend does not invent a second contract.

9. Historical coverage and manual loading behavior.
   - Every machine retains an inclusive host-calendar `coverageStart`; scheduled
     and manual refresh preserve that coverage, while an older custom/day/range
     query expands only the selected machine or enabled all-machine set.
   - `/api/refresh` and `/api/load-status` accept the same `machine=<id|all>`
     selection as query routes and default to `all`. Load status preserves its
     existing summary fields while exposing per-machine phase and coverage.
   - All-machine range and refresh operations use partial-success responses;
     a concrete machine whose requested history cannot be loaded returns a
     stable `503` without discarding its last usable snapshot.

10. Canonical machine identity and display labels.
    - Persisted SSH ids are case-sensitive 1...63-byte lowercase ASCII slugs
      using only letters, digits, and interior hyphens; `local` and `all` are
      reserved. Ids are never normalized or aliased.
    - Route and query ids are decoded exactly once as UTF-8 and must use their
      literal canonical spelling; percent-encoded, double-encoded, separated,
      malformed, and mixed-case aliases are rejected with the design's stable
      `id` or `machine` field mapping.
    - Display names are trimmed, normalized to NFC, limited to 1...80 permitted
      Unicode scalars and 256 UTF-8 bytes, and reject control/line-separator
      scalars. The normalized value is the persisted and returned value.

11. Machine collection-health API.
    - `GET /api/machine-status?machine=<id|all>` defaults to `all`; all includes
      disabled entries, orders synthetic `local` first then ids, and a concrete
      disabled/failed/never-collected machine remains a successful status item.
    - The response always uses the exact design DTO and nullable field rules.
      Health is one of `disabled`, `neverCollected`, `healthy`, `stale`, or
      `error` with fixed precedence; collection-in-progress is an independent
      Boolean. Timestamps are UTC RFC 3339 milliseconds and coverage is a
      host-calendar date.
    - Errors use only closed sanitized codes/messages and never expose raw
      stderr, arguments, connection values, identity data, exception text, or
      paths. Invalid selection is `400`, a canonical unknown id is `404`, and
      health states themselves never produce `409` or `503`.

12. Query-state consistency and typed collection failures.
    - A concrete query error derives `collectionState` from the exact same
      machine-status state machine and store revision: `neverCollected` before
      a failed first attempt, `error` afterward when no snapshot exists, and
      `disabled` for a disabled selection. Aggregate errors omit a singular
      state because component states can differ.
    - Command runners retain typed launch, timeout, signal, SSH transport-exit,
      and ccusage command-exit failures through `CCUsageClient`; they are not
      collapsed into an unqualified nonzero-exit error.
    - Public health sanitization is deterministic: launch/timeout/signal/SSH
      status 255 is `transport_failed`; local or remote ccusage nonzero exit is
      `remote_command_failed`; response decode/shape is `invalid_response`;
      cache operations are `cache_failed`; other non-cancellation collection
      failures are `internal_error`. Raw typed details remain internal.

13. Existing local-cache upgrade behavior.
    - Preserve a sole valid `aggregates.sqlite3` by checkpointing and atomically
      renaming it in the same cache directory to `aggregates-local.sqlite3`
      before the local poller opens. Enforce directory mode `0700` and file mode
      `0600`; do not use a non-atomic copy fallback.
    - If source and destination both exist, the destination wins without merge
      or overwrite; retain and ignore the legacy source with a sanitized warning.
      Invalid or unsafe legacy input is also retained and ignored while history
      is rebuilt. Permission, checkpoint, race, or rename failures surface as
      `cache_failed`, publish no partial destination, and retry later.
    - Clearing local cache includes both old and new filenames and their SQLite
      sidecars, serialized with collectors and atomically staged before the
      empty store is published, so legacy data cannot reappear after restart.

14. Fail-closed registry startup and recovery.
    - A missing `machines.json` means an empty SSH registry only after its
      current-user-owned mode-`0700` directory is proven safely writable.
      Existing registry files must be regular, single-link, current-user-owned,
      mode `0600`, completely decodable, and fully valid.
    - Unsafe permissions/type/ownership, malformed JSON, invalid entries, or an
      unusable persistence path fail startup before listeners and pollers. There
      is no quarantine, automatic repair, backup promotion, or local-only
      fallback for a present invalid file.
    - Recovery is offline repair or intentional file removal followed by
      restart. File removal preserves per-machine caches and chooses the empty
      registry behavior.

15. Serialized registry mutation ownership.
    - One mutation owner queues all CRUD and covers complete-candidate
      validation, synchronized atomic persistence, immutable revision publish,
      affected-generation cancellation, snapshot/status reconciliation, and
      replacement poller registration before the HTTP response.
    - A pre-publish failure changes neither disk nor runtime state. Poll results
      carry registry revision and generation fences so removed or replaced
      pollers cannot publish late results.

16. Explicit state-changing HTTP origin policy.
    - The control-mutation inventory is registry POST/PUT/PATCH/DELETE,
      `GET /api/refresh`, and `DELETE /api/cache`. Historical read-through cache
      fills are not configuration/deletion controls.
    - Every control mutation requires a recognized loopback authority, exact
      same-origin browser/fetch metadata, and
      `X-CCUsage-Gauge-Mutation: 1`. Non-browser automation may omit browser
      headers but must send the mutation header.
    - Null, cross-origin, same-site-but-not-same-origin, mismatched-authority,
      preflight, or missing-header requests receive sanitized `403`, no CORS
      authorization, and make no state change.

17. Complete row provenance.
    - Block/timeline, daily metric, and session source records carry a
      non-optional machine id, defaulting to `local` only for legacy decoding
      and source-compatible initialization.
    - Every usage/cost response row emits `machine`: `RecentPoint` for
      `/api/recent`, `/api/day`, and `/api/period`; metric rows for
      `/api/metrics`; and `DashboardCostRow` for every `/api/cost-series`
      granularity. Aggregation keys include machine, and concrete selection does
      not omit the field.
    - Merge and serialization tests cover block/timeline, daily, and session
      paths and prove equal rows from different machines remain attributable.

18. Versioned registry representation.
    - `machines.json` is exactly a closed `{"schemaVersion":1,"machines":[]}`
      envelope. Both top-level keys are required, only persisted SSH descriptors
      are allowed, and all object levels reject duplicate and unknown keys.
    - The canonical persisted SSH shape explicitly writes `extraOptions` and
      `remoteCcusagePath`; API omission defaults these to `[]` and `ccusage`
      before persistence. `identityFile` is the sole optional persisted SSH key
      and is omitted rather than `null`.
    - Version 1 is the only accepted version. Missing, lower, higher, malformed,
      and unversioned representations fail closed without rewrite or fallback.
      Future formats require an explicit version and tested atomic migration.

19. Cache-clear behavioral contract.
    - A clear is atomic for one machine and intentionally partial across an
      `all` selection. Machines are processed in stable order; prior successful
      commits are not rolled back when a later machine fails.
    - Responses are `200` for complete success, `207` for mixed success, and
      `500` with per-item `cache_failed` when none commits. They always report a
      stable `complete|partial|failed` outcome, ordered `clearedMachineIds`, and
      `failedMachines`, including whether offline recovery is required.
      `all` includes disabled descriptors, and a disabled concrete machine can
      be cleared because deletion is an administrative operation.
    - A clean rollback preserves the prior store and resumes that poller. A
      committed clear publishes an empty store and repopulates current-week
      coverage. An incomplete rollback preserves the stale snapshot, stops that
      poller, and fails closed as `cache_failed` until deterministic recovery
      succeeds. The implementation plan owns the concrete durability mechanism.

## Open questions

None. The prior Compose-versus-Swarm question is resolved by decision 3: use
Docker Compose under Colima with pipe-only transfer between container tmpfs
mounts. Missing runtime prerequisites must be recorded as verification
limitations and must not trigger a topology or credential-storage fallback.

## Dashboard requirements (from the goal)

- Show which machine the displayed data belongs to.
- A cross-machine (all machines) aggregate view.
- Filter by machine.
- A screen to register per-host connection info.
