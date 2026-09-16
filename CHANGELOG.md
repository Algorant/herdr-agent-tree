# Changelog

All notable changes will be documented in this file. This project uses
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) structure and intends to use
semantic versioning after its first public release.

## [Unreleased]

### Added

- Release packaging for `x86_64-unknown-linux-musl` and `aarch64-unknown-linux-musl`:
  deterministic per-target archives, per-archive `.sha256` sidecars and an aggregate
  `agent-tree-v<version>-SHA256SUMS` file.
- A checksum-pinned, HTTPS-only release installer with a strict archive allowlist, atomic
  versioned installation and disabled registration.
- CI running `cargo fmt --check`, `cargo clippy`, `cargo build --locked`,
  `cargo test --locked` and the hermetic packaging/installer suites, plus candidate musl
  builds for both targets.
- An owner- and evidence-gated tag workflow that fails closed while
  `release-targets.txt` has no promoted target. No tag or release has been published.

### Changed

- `README.md` now documents the release install as the supported path for a normal user and
  labels the root `./install.sh` a development install from a checkout.

## [0.1.0] - planned

### Added

- Pi delegation tree projection into Herdr's native Agents sidebar: `agent_tree_row` and
  `agent_tree_rank` pane tokens and one `agent.view.set` projection.
- Recomputed identity validation, unique parent resolution, preorder rank ordering and the
  20-character decoration grammar.
- Lifecycle actions `start`, `apply`, `clear` and `toggle`, with a socket-scoped paused flag
  and a single-instance subscriber lock.
- Isolated demo, identity/projection/decoration/pause contract tests, and measured sidebar
  width evidence.

[Unreleased]: https://github.com/Algorant/herdr-agent-tree/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Algorant/herdr-agent-tree/releases/tag/v0.1.0
