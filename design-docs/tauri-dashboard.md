# Tauri desktop dashboard

The native dashboard uses the Tauri 2 builder and embedded frontend pattern from
the sibling `chilla` project. The existing SolidJS UI remains shared with the
optional browser dashboard.

Swift launches `ccusage-gauge-dashboard --swift-host` with two anonymous pipes.
Frontend `invoke("dashboard_request")` calls enter Rust, which assigns a request
ID and sends a newline-delimited JSON request to Swift. Swift routes directly
through `MachineDashboardRouter` and returns status, content type, and body with
the same ID. No socket is opened and no Swift business logic is reimplemented in Rust.

The menu-bar host shares its existing router and collector with the window. The
CLI `dashboard` host initializes the same runtime as `serve` but launches the
window instead of starting `DashboardHTTPServer`. `serve` and HTTP client commands
remain available explicitly. Do not run multiple data owners against the same
state directory when testing; use the existing isolated path overrides.

Only API paths and supported methods cross the bridge. Mutation headers are
constructed by the Swift pipe adapter; the existing HTTP origin checks remain
unchanged. Tauri's CSP permits local assets and IPC, with no remote origins or
general shell/filesystem plugins. Requests are correlated so long-running queries
do not block progress/status requests. Rust removes pending requests after 120
seconds; frontend timeout/cancellation ends waiting but does not roll back a
mutation already dispatched to Swift, matching HTTP semantics.

Closing a window ends its process; the menu-bar app can reopen it. Quitting the
Swift host closes the input pipe and Tauri exits on EOF. The CLI also shuts down
collection on window exit or a termination signal. A protocol decoding failure
closes the bridge rather than leaving an unusable window.

`mise run desktop:build` compiles embedded assets and Rust, builds the Swift CLI,
and places the window executable beside it. `app:build` and `e2e:build` include
and ad-hoc sign a nested helper app in Contents/Helpers, giving the window its own
macOS identity instead of inheriting the menu-bar host's LSUIElement setting.
Version 0.2.0 release archives include the desktop executable for both macOS
architectures. Cask DMGs contain the signed app, nested Tauri helper, and CLI;
Formula tarballs contain the CLI, Tauri executable, and browser assets.

## Verification

Verified on macOS with the packaged native window at `tauri://localhost`:
actual local usage totals, model rows, token counts, and the hourly chart load
through Swift. Isolated fixtures additionally exercised refresh, Daily/Hourly
switching, window close/reopen, and persisted selection restoration. Neither
the Swift host nor Tauri process had a TCP listener. Nested app signature
verification passed.

Validation: `mise run desktop:build`, `mise run app:build`, `swift test`
(273 tests), `bun run check`, `bun test` (91 tests), `cargo test --manifest-path
src-tauri/Cargo.toml`, `cargo clippy --manifest-path src-tauri/Cargo.toml -- -D
warnings`, and `mise exec -- swiftlint --quiet`. SwiftLint reports existing
warnings in other code, with no warnings in the new desktop integration files.
