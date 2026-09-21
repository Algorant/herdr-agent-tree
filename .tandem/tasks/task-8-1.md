---
id: task-8-1
type: task
title: "Converge v0.1.0 on Herdr-managed source installation"
state: todo
priority: "high"
effort: "medium"
parentId: "task-8"
references: ["decision-3"]
relatedFiles: ["herdr-plugin.toml", "Cargo.toml", "README.md", "docs/release.md", ".github/workflows/ci.yml", ".github/workflows/release.yml", "scripts/release", "tests/shell", "release/targets.txt", "docs/release-evidence"]
tags: ["release", "installation", "rust", "herdr-plugin"]
accord:
  status: "ready"
  acceptance: ["`herdr-plugin.toml` declares an idiomatic `[[build]]` command using `cargo build --locked --release`, and a clean source checkout produces the executable expected by every manifest command.", "README.md documents `herdr plugin install Algorant/herdr-agent-tree --ref v0.1.0` as the sole normal-user install path, with reinstall/update and activation steps using Herdr's plugin lifecycle.", "The bespoke release installer, binary archive packaging, target-promotion/native-evidence gate and their exclusive tests/docs are removed rather than retained as a fallback; development deploy and endpoint doctor tooling remain explicitly non-user install paths.", "Cargo.toml carries standard package metadata (`description`, `license`, `repository`, `readme`) while preserving the current supported Rust version and non-crates.io status.", "CI and the tag workflow validate the source release contract without expecting custom binary assets, and a clean-install smoke check fails if the manifest build or command path is broken."]
  validation: ["$ git diff --check", "$ just test", "$ just build"]
  constraints: ["Use one authoritative installation path; do not retain the custom installer or binary-asset path as an alternative.", "Do not change plugin runtime behavior, identity rules, tree rendering or toggle semantics.", "Do not make the repository public or create/push a release tag in this subtask."]
  updatedAt: "2026-09-21T01:35:55Z"
createdAt: "2026-09-21T01:35:55Z"
updatedAt: "2026-09-21T01:35:55Z"
---

## Description

Replace the copied bespoke release installer/asset promotion system with the standard Herdr plugin lifecycle chosen in decision-3. `herdr plugin install Algorant/herdr-agent-tree --ref v0.1.0` must clone the plugin, run its manifest-declared locked Cargo release build, and register a runnable plugin. The repository should have one public install path; remove the checksum installer, musl archive/target promotion/evidence machinery and associated tests/docs rather than retaining a second path. Keep checkout deployment tooling clearly labeled as development/admin-only.
