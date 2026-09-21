---
id: task-8-1
type: task
title: "Converge v0.1.0 on Herdr-managed source installation"
priority: "high"
effort: "medium"
parentId: "task-8"
references: ["decision-3"]
relatedFiles: ["herdr-plugin.toml", "Cargo.toml", "README.md", "docs/release.md", ".github/workflows/ci.yml", ".github/workflows/release.yml", "scripts/release", "tests/shell", "release/targets.txt", "docs/release-evidence"]
tags: ["release", "installation", "rust", "herdr-plugin"]
accord:
  status: "accepted"
  acceptance: ["`herdr-plugin.toml` declares an idiomatic `[[build]]` command using `cargo build --locked --release`, and a clean source checkout produces the executable expected by every manifest command.", "README.md documents `herdr plugin install Algorant/herdr-agent-tree --ref v0.1.0` as the sole normal-user install path, with reinstall/update and activation steps using Herdr's plugin lifecycle.", "The bespoke release installer, binary archive packaging, target-promotion/native-evidence gate and their exclusive tests/docs are removed rather than retained as a fallback; development deploy and endpoint doctor tooling remain explicitly non-user install paths.", "Cargo.toml carries standard package metadata (`description`, `license`, `repository`) and uses Cargo's conventional inferred `README.md`, while preserving the current supported Rust version and non-crates.io status.", "CI and the tag workflow validate the source release contract without expecting custom binary assets, and a clean-install smoke check fails if the manifest build or command path is broken."]
  claimedAt: "2026-09-21T02:44:02Z"
  deliveredAt: "2026-09-21T02:44:15Z"
  validation: ["$ git diff --check", "$ just test", "$ just build"]
  constraints: ["Use one authoritative installation path; do not retain the custom installer or binary-asset path as an alternative.", "Do not change plugin runtime behavior, identity rules, tree rendering or toggle semantics.", "Do not make the repository public or create/push a release tag in this subtask."]
  summary: "Converged Agent Tree on Herdr-managed source installation. The manifest now runs one locked Cargo release build and keeps the tracked launcher as the runtime boundary; README/release docs use `herdr plugin install ... --ref`; standard Cargo metadata is present; the bespoke installer, binary archives, musl targets, promotion/evidence gates and exclusive tests are removed; CI and the tag workflow validate/publish the source contract only. Clean-source smoke coverage parses exact TOML argv and proves the launcher reaches a fresh build."
  evidence: ["Manifest declares exactly one `[[build]]` command `cargo build --locked --release`; a tracked-files-only target-less export executed that exact TOML argv and proved every runtime command path is executable and reaches the produced binary.", "README.md and docs/release.md document `herdr plugin install Algorant/herdr-agent-tree --ref v0.1.0` as the sole normal-user path, with Herdr-managed reinstall/update, uninstall and manual activation.", "Custom installer/package/checksum/binary-target/native-evidence scripts, manifests and exclusive tests were deleted; the release gate checks the full obsolete path set cannot reappear. Development deploy, endpoint deployment and doctor remain explicitly non-user tooling.", "Cargo.toml now has description, MIT license and repository metadata, preserves Rust 1.81 and publish=false, and uses Cargo's inferred README convention with warning-free builds.", "CI now runs the pinned Rust 1.81 quality/source-install gate; the tag workflow validates the exact source contract and creates a source-only release without custom assets.", "Independent validations at the integrated source: `git diff --check`, `just test`, `just build`, and `scripts/release/check-release.sh --ref refs/tags/v0.1.0` all exited 0; all isolated Herdr E2E tests passed."]
  filesChanged: [".cargo/config.toml", ".github/workflows/ci.yml", ".github/workflows/release.yml", "CHANGELOG.md", "Cargo.toml", "README.md", "docs/release-evidence/README.md", "docs/release.md", "herdr-plugin.toml", "release/targets.txt", "scripts/check.sh", "scripts/deploy.sh", "scripts/release/check-binaries.sh", "scripts/release/check-release.sh", "scripts/release/check-targets.sh", "scripts/release/checksums.sh", "scripts/release/install.sh", "scripts/release/package.sh", "tests/shell/install-candidate.sh", "tests/shell/source-install.sh", "tests/shell/stage-local.sh", "tests/shell/test-install.sh", "tests/shell/test-release.sh"]
  reviewer: "orchestrator"
  updatedAt: "2026-09-21T02:44:20Z"
createdAt: "2026-09-21T01:35:55Z"
updatedAt: "2026-09-21T02:44:20Z"
assignee: "orchestrator"
archivedAt: "2026-09-21T02:44:20Z"
resolution:
  outcome: "completed"
  reviewer: "orchestrator"
---

## Description

Replace the copied bespoke release installer/asset promotion system with the standard Herdr plugin lifecycle chosen in decision-3. `herdr plugin install Algorant/herdr-agent-tree --ref v0.1.0` must clone the plugin, run its manifest-declared locked Cargo release build, and register a runnable plugin. The repository should have one public install path; remove the checksum installer, musl archive/target promotion/evidence machinery and associated tests/docs rather than retaining a second path. Keep checkout deployment tooling clearly labeled as development/admin-only.
