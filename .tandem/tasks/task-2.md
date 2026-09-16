---
id: task-2
type: task
title: "Release packaging, CI and a first published release"
state: "in-progress"
effort: "medium"
relatedFiles: ["herdr-plugin.toml", "Cargo.toml", "install.sh", "README.md"]
tags: ["release-readiness", "packaging", "ci"]
accord:
  status: "claimed"
  acceptance: ["herdr-plugin.toml and Cargo.toml versions agree, and a CHANGELOG entry exists for the release version.", "A release build produces packaged artifacts with checksums for the supported target(s).", "CI runs build, test, clippy and fmt checks on push.", "A normal user can install and update the plugin from a published release artifact, documented in README.md.", "The local staging directory is no longer the documented default install path for a normal user; any remaining staged install is clearly labelled as a development install.", "Deliberate deviations from the herdr-notifs-plus release machinery are stated rather than left implicit."]
  claimedAt: "2026-09-16T02:34:29Z"
  validation: ["$ git diff --check", "$ cargo build --locked --release"]
  constraints: ["Follow the herdr-notifs-plus release machinery rather than inventing a new scheme.", "Do not publish a tagged release without Algorant's explicit approval.", "Do not make the repository public without Algorant's explicit approval.", "Do not change plugin behaviour; this is packaging, CI and install path only.", "Do not leave hidden local state as the supported install path."]
  updatedAt: "2026-09-16T02:34:29Z"
createdAt: "2026-09-16T01:23:50Z"
updatedAt: "2026-09-16T02:34:29Z"
assignee: "worker-task-2-295abba6"
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

