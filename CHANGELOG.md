# Changelog

All notable changes will be documented in this file. This project uses
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) structure and intends to use
semantic versioning after its first public release.

## [Unreleased]

### Added

- An explicit-endpoint deploy and doctor: `scripts/deploy-endpoint.sh` (`just deploy-endpoint
  <name>`) transactionally deploys the current checkout to a named saved Herdr machine
  (`local` or a unique label, profile id, or SSH target) with a host-architecture gate, a
  remote loader proof, atomic staging, registration, a verified subscriber replacement,
  idempotent managed config fragments, automatic rollback, and an ownership-checked
  `--uninstall`; `scripts/doctor.sh` (`just doctor <name>`) is a read-only per-endpoint
  readiness report that names the split state where one endpoint is healthy and another has
  the shortcut and row token but no plugin. Neither ever restarts a Herdr server. Hermetic
  coverage lives in `tests/shell/deploy-endpoint.sh` and `tests/shell/doctor.sh`.
- A verified latest-checkout reload: `agent-tree.reload` (and the deploy workflow's use of
  it) replaces the running subscriber with the just-staged build, recovers a dead lock, and
  refuses an unverifiable or foreign holder without signaling it, so `just deploy` is safe to
  repeat against a live server. Hermetic coverage lives in `tests/shell/dev-reload.sh`.
- Release packaging for `x86_64-unknown-linux-musl` and `aarch64-unknown-linux-musl`:
  deterministic per-target archives, per-archive `.sha256` sidecars and an aggregate
  `agent-tree-v<version>-SHA256SUMS` file.
- A checksum-pinned, HTTPS-only release installer with a strict archive allowlist, atomic
  versioned installation and disabled registration.
- CI running the shared `scripts/check.sh` quality gate (formatting, Clippy, `cargo
  build --locked`, `cargo test --locked` and the hermetic packaging/installer suites), plus
  candidate musl builds for both targets.
- An owner- and evidence-gated tag workflow that fails closed while
  `release/targets.txt` has no promoted target. No tag or release has been published.

### Changed

- The three-state `agent-tree.cycle` is replaced by the owner-safe `agent-tree.toggle`
  (documented `prefix+alt+t`): with no plugin view it installs the validated `tree`
  projection, when this plugin owns the view it clears only that view to reveal Herdr's own
  grouped/priority list, and a foreign or unknown owner fails closed and is never displaced.
  `agent_tree_row`/`agent_tree_rank` stay published in both states, so decorations remain
  visible with tree ordering on or off. The plugin no longer writes `ui.agent_panel_sort` and
  has no sort capture/restore path; `clear` removes only the plugin's tokens and view.
  Isolated coverage lives in `tests/e2e/toggle.sh`.
- The repository is organized around five `just` recipes: `just test` (the complete gate,
  including the noninteractive `tests/e2e/sidebar.sh` isolated Herdr test and the hermetic
  `tests/shell/dev-reload.sh` deploy/reload suite), `just build`, `just deploy` (the local
  checkout development install now at `scripts/deploy.sh`, which stages and replaces the live
  subscriber), `just deploy-endpoint <name>` (an explicit remote or local endpoint), and
  `just doctor <name>` (a read-only endpoint report). Release internals live under
  `scripts/release/`, shell tests under
  `tests/shell/`, and the owner allowlist at `release/targets.txt`.
- `README.md` documents the release install as the supported path for a normal user and
  labels `scripts/deploy.sh` a development install from a checkout.

### Fixed

- `just deploy` no longer returns on the async `agent-tree.reload` invocation. Herdr's
  `plugin action invoke` starts the action and returns a still-running log record, so deploy
  now waits for that exact record to reach a terminal status and reports the failed phase with
  the action's stderr. It then verifies the running image three ways (checkout build, staged
  file, `/proc/<pid>/exe`), and repeats the check after `herdr server reload-config` so no
  second subscriber handoff can happen after it returns. A real isolated-Herdr ordering test
  (`tests/e2e/deploy-reload.sh`) and an async-modeling fake-Herdr case in
  `tests/shell/dev-reload.sh` prevent regression.
- The hermetic deploy tests no longer corrupt the cached release artifact. Their fake `cargo`
  replaced `target/release/agent-tree` in place, which wrote through the hardlink cargo keeps
  to its deps artifact and could make a later `just build`/`just deploy` treat the debug copy
  as fresh. They now replace via rename, and the endpoint deploy honors `CARGO_TARGET_DIR` so
  a test can build into a private target directory.
- The endpoint deploy now serializes concurrent deploy/uninstall attempts with a per-endpoint
  lock, restores stage substeps independently, restores the prior registration's enabled state
  as well as its root, verifies rollback against the actual prior registered binary, refuses a
  symlinked config and a concurrent config edit without overwriting either, stops a replaced
  subscriber by identity before moving its stage, and identity-verifies and stops the
  subscriber before uninstall deletes anything. Remote values cross SSH only as argv and the
  managed shortcut stores the endpoint's absolute `herdr` path.
- The endpoint stop path captures a Linux process start time before signaling and re-checks
  it before every later signal, so a reused PID is never signaled; the plugin root is streamed
  as a tar archive over the argv-safe runner (removing the rsync remote-path boundary); the
  managed shortcut is shell-quoted and then TOML-encoded so a Herdr path with spaces or quotes
  still parses; uninstall is transactional with a full preflight and automatic restore; and
  the deployment lock is removed only when its owner token still matches.

## [0.1.0] - planned

### Added

- Pi delegation tree projection into Herdr's native Agents sidebar: `agent_tree_row` and
  `agent_tree_rank` pane tokens and one `agent.view.set` projection.
- Recomputed identity validation, unique parent resolution, preorder rank ordering and the
  20-character decoration grammar.
- Lifecycle actions `start`, `apply`, `clear` and `toggle`, with a socket-scoped tree-off
  marker and a single-instance subscriber lock. The plugin writes no configuration.
- Isolated Herdr end-to-end sidebar test, identity/projection/decoration/tree-off and toggle
  contract tests, and measured sidebar width evidence.

[Unreleased]: https://github.com/Algorant/herdr-agent-tree/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Algorant/herdr-agent-tree/releases/tag/v0.1.0
