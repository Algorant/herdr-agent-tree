---
id: task-9
type: task
title: "Simplify the repository around test, build and deploy"
state: todo
priority: "high"
effort: "medium"
blockers: ["task-5"]
relatedFiles: ["Makefile", "justfile", "demo.sh", "install.sh", "release-targets.txt", "release", "scripts", "test", "tests", "docs", "README.md", "CHANGELOG.md", ".github/workflows", "src/agent-tree"]
tags: ["repository-hygiene", "developer-experience", "just"]
accord:
  status: "ready"
  acceptance: ["The tracked repository root contains no .sh files, no .txt files and no Makefile; it contains a justfile with exactly test, build and deploy recipes.", "`just test` runs formatting, Clippy, Rust tests, shell installer/release tests and a noninteractive isolated Herdr E2E test that always cleans up.", "`just build` produces the optimized current-checkout agent-tree binary.", "`just deploy` delegates to scripts/deploy.sh as the sole checkout dogfood entry point; task-6 may subsequently strengthen its subscriber replacement behavior.", "The former demo is replaced by tests/e2e/sidebar.sh with no interactive attach, --keep or demo-specific output branches while retaining real identity and sidebar assertions.", "release/targets.txt is the sole owner promotion manifest, tests/shell/ is the sole shell-test location, and all release internals use the organized scripts/release paths.", "README, release documentation, CHANGELOG, workflows, package scripts and source-launcher guidance contain no stale references to Makefile, demo.sh, root install.sh, root release-targets.txt or test/.", "Hosted CI and local commands use the new authoritative paths and preserve the fail-closed publication gate."]
  validation: ["$ git diff --check", "$ just test", "$ just build"]
  constraints: ["The justfile exposes exactly the three product operations test, build and deploy; do not add aliases, release publishing recipes or a miscellaneous command collection.", "Just recipes remain thin entry points; keep complex and security-sensitive logic in separately testable scripts.", "Do not weaken release target approval, archive allowlists, checksum verification, tag gating or disabled-by-default release installation while moving paths.", "Keep herdr-plugin.toml and its required launcher path at the repository root/src contract expected by Herdr.", "Keep .tandem intact and tracked through dogfooding; public-release removal remains task-8.", "Do not retain a root demo.sh/install.sh compatibility shim after references are migrated; one authoritative path only."]
  updatedAt: "2026-09-16T13:27:45Z"
createdAt: "2026-09-16T13:27:45Z"
updatedAt: "2026-09-16T13:27:45Z"
---

## Description

Restructure the repository for the product it is now rather than preserving MVP-era paths. The root should contain no shell scripts, no .txt control file and no Makefile. Replace Make with one small justfile exposing exactly three developer recipes: `just test`, `just build`, and `just deploy`. Keep security-sensitive installer/release/process logic in tested scripts beneath scripts/. Replace demo.sh with a noninteractive isolated Herdr E2E test under tests/e2e/; it must preserve the genuine delegation, ordering, forged-identity rejection and rendered-sidebar assertions but remove attach, --keep and demo presentation modes. `just test` runs the complete gate, including that E2E test. Move the owner target allowlist to release/targets.txt, merge test/ into tests/shell/, organize release scripts under scripts/release/, and move the checkout installer behind scripts/deploy.sh. Update every workflow, test, documentation and package reference atomically.
