# Dashboard Client Commands

**Status**: Complete
**Design Reference**: `design-docs/specs/client-commands.md`

## Purpose

Provide a Swift Argument Parser command client for the running loopback
dashboard API, including SSH machine retrieval/addition and dashboard data
queries, without duplicating server persistence or query rules.

## Deliverables

- [x] ArgumentParser-based root command preserving current commands
- [x] Typed loopback `DashboardAPIClient`
- [x] Machine list/show/add commands
- [x] Dashboard read commands
- [x] Parsing, transport, integration, and rendering tests
- [x] README client documentation

## Tasks

### TASK-001: Add ArgumentParser and migrate existing commands

**Parallelizable**: No

**Completion Criteria**:

- [x] `--help`, `--version`, `config-check`, `usage-snapshot`, and `serve` retain their contracts.
- [x] Invalid arguments exit through the documented usage path.
- [x] The handwritten parser is removed after parity tests pass.

### TASK-002: Implement the typed dashboard API client

**Depends On**: TASK-001
**Parallelizable**: No

**Completion Criteria**:

- [x] Requests are fixed to loopback and use the configured/default port.
- [x] Mutation headers appear only on machine creation.
- [x] Raw JSON, typed response decoding, scope, and structured errors are tested.

### TASK-003: Implement machine and dashboard commands

**Depends On**: TASK-002
**Parallelizable**: No

**Completion Criteria**:

- [x] Machine list/show/add map to existing endpoints and validators.
- [x] All dashboard-visible read resources are exposed.
- [x] Human and JSON output honor the design contract.

### TASK-004: Document and verify

**Depends On**: TASK-003
**Parallelizable**: No

**Completion Criteria**:

- [x] README contains examples and the connection-metadata warning.
- [x] SwiftLint, full tests, build, and CLI smoke commands pass.

## Progress Log

- 2026-07-21: Fable 5 design completed and accepted with the dependency updated to swift-argument-parser 1.8.2.
- 2026-07-21: Implemented the full client command tree. Added
  swift-argument-parser 1.8.2 to `AppCLI` only; migrated `config-check`,
  `usage-snapshot`, and `serve` to `AsyncParsableCommand` with a custom entry
  point that maps parse/validation failures to exit status 2 and preserves
  help/version. Removed the hand-written `AppCommand` parser. Added an
  injectable, loopback-only `DashboardAPIClient` in `AppCore` with raw-body
  preservation, `ScopedResponse` envelopes reusing existing DTOs, typed
  range/granularity/machine domains, structured `DashboardClientError`, and
  `FoundationNetworking` compatibility. Machine creation sends the exact closed
  shape with the mutation header; reads never do; identity-file contents are
  never read. Added parsing, transport, renderer, exit-status, and live
  server/client round-trip tests. Independent review added direct generated-help
  coverage and rejected unsafe/reserved machine path ids before requests.
  Verified `swift build`, `swift test` (117 tests), executable help/exit-status
  smoke checks, and `swiftlint` (no new violations).
- 2026-07-21: Review-and-improve pass. Fixed the entry point mapping every
  non-clean failure to exit status 2: runtime failures (config-check, serve,
  usage-snapshot errors) now exit 1 as documented, via a testable
  `RootCommand.terminationStatus(for:)`. Made the default client transport an
  ephemeral `URLSession` so dashboard reads never touch the shared cookie/cache
  store. Documented the `--ssh-option=<value>` quoting requirement in generated
  help and corrected the README example (`'--ssh-option=-o ConnectTimeout=10'`
  must be shell-quoted). Added port-bind retries to the live server test
  fixture. Re-verified `swift build`, `swift test` (118 tests), exit-status
  smoke checks (0/1/2/3), and `swiftlint` (no violations in feature files).
