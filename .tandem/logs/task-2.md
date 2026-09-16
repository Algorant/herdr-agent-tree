---
id: task-2
type: task
title: "Release packaging, CI and a first published release"
effort: "medium"
relatedFiles: ["herdr-plugin.toml", "Cargo.toml", "install.sh", "README.md"]
tags: ["release-readiness", "packaging", "ci"]
accord:
  status: "accepted"
  acceptance: ["herdr-plugin.toml and Cargo.toml versions agree, and a CHANGELOG entry exists for the release version.", "A release build produces packaged artifacts with checksums for the supported target(s).", "CI runs build, test, clippy and fmt checks on push.", "A normal user can install and update the plugin from a published release artifact, documented in README.md.", "The local staging directory is no longer the documented default install path for a normal user; any remaining staged install is clearly labelled as a development install.", "Deliberate deviations from the herdr-notifs-plus release machinery are stated rather than left implicit."]
  claimedAt: "2026-09-16T02:34:29Z"
  deliveredAt: "2026-09-16T02:47:08Z"
  validation: ["$ git diff --check", "$ cargo build --locked --release"]
  constraints: ["Follow the herdr-notifs-plus release machinery rather than inventing a new scheme.", "Do not publish a tagged release without Algorant's explicit approval.", "Do not make the repository public without Algorant's explicit approval.", "Do not change plugin behaviour; this is packaging, CI and install path only.", "Do not leave hidden local state as the supported install path."]
  summary: "Ported the herdr-notifs-plus release machinery to agent-tree for release readiness, with no tag, release, visibility change or live-install change. Added CHANGELOG.md with the exact `## [0.1.0] - planned` heading, an empty owner allowlist release-targets.txt, a Makefile with an explicit `cargo build --locked` target plus `check`/`ci`/`release-check`/`stage-local`, and .cargo rust-lld musl config. Added deterministic per-target packaging and checksums (agent-tree-v0.1.0-{x86_64,aarch64}-unknown-linux-musl.tar.gz), a checksum-pinned HTTPS installer with strict seven-entry allowlist and atomic install to ${XDG_DATA_HOME:-$HOME/.local/share}/herdr-agent-tree/<version>/<target> (disabled registration), hermetic suites (23 installer + 30 release checks), CI (fmt/clippy/test/explicit build + both musl candidate matrix) and a tag-only workflow that fails closed while release-targets.txt is empty. README now documents the release install as the normal-user path (download and review the tagged installer, reject `curl | sh`, pinned version/checksum, manual sidebar rows + enable + reload + apply) and labels root ./install.sh a development install. docs/release.md and docs/release-evidence/README.md state the machinery and deliberate deviations (MIT LICENSE included in candidate and final, single binary, manual activation, omitted supply-chain job, private/unpublished). The target-evidence gate field is `native_sidebar_evidence: passed` everywhere; no desktop/audio terminology remains. cargo fmt was applied across src/ (formatting only; 40 unit + 1 integration tests still pass)."
  evidence: ["herdr-plugin.toml and Cargo.toml versions agree, and a CHANGELOG entry exists for the release version.: Both manifests are 0.1.0 and CHANGELOG.md has the exact `## [0.1.0] - planned` heading required by scripts/check-release.sh; `make check` runs check-version and exited 0. docs/release.md documents the bracketed heading form.", "A release build produces packaged artifacts with checksums for the supported target(s).: With Rust 1.81.0 and .cargo rust-lld config, both x86_64 and aarch64 musl binaries built statically; package-release.sh produced agent-tree-v0.1.0-<target>.tar.gz plus .sha256, write-checksums.sh produced agent-tree-v0.1.0-SHA256SUMS, and check-release.sh --assets verified both archives OK. The real x86_64 archive installed through scripts/install.sh and its src/agent-tree ran.", "CI runs build, test, clippy and fmt checks on push.: .github/workflows/ci.yml triggers on push and pull_request, has an explicit `cargo +1.81.0 build --locked` step, runs `make ci` (fmt, clippy --all-targets -D warnings, test --locked --all-targets, build --locked, shell-check, hermetic installer and release suites), adds a step asserting the owner gate stays closed, and a candidate matrix for both musl targets. All those commands were reproduced locally on 1.81.0 and passed.", "A normal user can install and update the plugin from a published release artifact, documented in README.md.: README 'Install' now shows a non-checkout user downloading the exact tagged scripts/install.sh, reviewing it, explicitly rejecting `curl | sh`, and running it from a file with a pinned version, target and independently trusted lowercase SHA-256; it documents the install path, disabled registration, manual activation and the update re-run. No tagged release is published, and README states that.", "The local staging directory is no longer the documented default install path for a normal user; any remaining staged install is clearly labelled as a development install.: README installs releases to ${XDG_DATA_HOME:-$HOME/.local/share}/herdr-agent-tree/<version>/<target> under 'Release install (the normal user path)', and root ./install.sh is retitled and documented as a development install from a checkout that stages ~/.local/share/herdr-agent-tree/stage.", "Deliberate deviations from the herdr-notifs-plus release machinery are stated rather than left implicit.: docs/release.md 'Deliberate deviations' records: candidate and final archives both include the committed MIT LICENSE (no pre-license gate), single agent-tree binary with no doctor/assets/LICENSES files, installer never edits config and activation is manual, the supply-chain reporting job is omitted, and the repository stays private with no tag or release.", "Final target promotion stays owner/evidence-gated and publication remains unperformed.: release-targets.txt has no entries; check-release-targets.sh requires tracked docs/release-evidence/*.md with matching target/version/candidate_sha256/native_sidebar_evidence: passed/owner_approved_by; `make release-check` exited 2 with 'no targets are approved for final publication'; the tag-only release workflow would stop at the same gate. No tag, release, visibility change or live-install change was made.", "Preserve task-1 tests, task-3 docs and task-4 measurements; do not change plugin behaviour.: 40 unit tests and the 1 cli_flags integration test pass unchanged; docs/agent-tree/m1-evidence.md, m2-contract.md and task-4-measurements.md were not modified; the src/ diff is cargo fmt formatting only."]
  filesChanged: [".cargo/config.toml", ".github/workflows/ci.yml", ".github/workflows/release.yml", "CHANGELOG.md", "Makefile", "README.md", "docs/release-evidence/README.md", "docs/release.md", "install.sh", "release-targets.txt", "scripts/check-release-targets.sh", "scripts/check-release.sh", "scripts/check-target-binaries.sh", "scripts/install.sh", "scripts/package-release.sh", "scripts/stage-local.sh", "scripts/write-checksums.sh", "src/decoration.rs", "src/forest.rs", "src/identity.rs", "src/lifecycle.rs", "src/pause.rs", "src/projection.rs", "src/transport.rs", "src/wire.rs", "test/install-candidate.sh", "test/test-install.sh", "test/test-release.sh"]
  updatedAt: "2026-09-16T02:47:08Z"
createdAt: "2026-09-16T01:23:50Z"
updatedAt: "2026-09-16T02:47:08Z"
assignee: "worker-task-2-295abba6"
archivedAt: "2026-09-16T02:47:08Z"
resolution:
  outcome: "completed"
---

## Description

## Outcome

Make this repository able to build, package and publish a release, so the plugin is installed and updated from release artifacts like any other Herdr plugin.

Algorant's explicit requirement: the current install path stages a self-contained plugin root at `${XDG_DATA_HOME:-$HOME/.local/share}/herdr-agent-tree/stage` and registers that with Herdr. That is interim scaffolding, not the end state. A local staging directory is hidden state a user will not remember exists. Replace it as the default install path for a normal user with an install from a published release. If a staged install survives for development from a checkout, keep it clearly distinguished.

## Reference implementation

`Algorant/herdr-notifs-plus` already solved all of this and should be followed rather than reinvented. Its `scripts/` directory contains `check-release.sh`, `check-release-targets.sh`, `check-target-binaries.sh`, `install.sh`, `package-release.sh`, `stage-local.sh` and `write-checksums.sh`, driven by a `Makefile` with `check`, `ci`, `release-check` and staging targets. It enforces manifest/Cargo version agreement, an exact `v<version>` tag, a CHANGELOG heading, per-target binaries and checksums.

Read that repository, port the pattern, and note any deliberate deviation rather than differing quietly.

## Scope

- Version consistency between `herdr-plugin.toml` and `Cargo.toml`, plus a CHANGELOG.
- Release build for the supported target(s), packaged with checksums.
- CI running at minimum: `cargo build --locked`, `cargo test --locked`, `cargo clippy` and `cargo fmt --check`.
- A documented install-from-release path, and an update path.
- The Herdr marketplace requires a public repository carrying the `herdr-plugin` topic with `herdr-plugin.toml` at the root. The topic is set and the manifest is at the root; the repository is currently private. Making it public is Algorant's decision.

## Not in scope

Publishing an actual tagged release without Algorant's explicit approval.

