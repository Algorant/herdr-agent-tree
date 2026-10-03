---
id: task-9
uid: 3ef88ab4-8a03-4f6c-83ca-3e78a27670f3
type: task
title: "Prepare v0.3.0 source release after fallback and cross-endpoint rank fixes"
priority: "high"
effort: "small"
relatedFiles: ["Cargo.toml", "Cargo.lock", "herdr-plugin.toml", "CHANGELOG.md", "README.md", "docs/agent-tree/endpoint-rank-rollout.md"]
tags: ["release"]
accord:
  status: "accepted"
  acceptance: ["Cargo.toml, Cargo.lock and herdr-plugin.toml declare 0.3.0; `scripts/release/check-release.sh --ref refs/tags/v0.3.0` passes and the v0.2.0 ref is rejected.", "CHANGELOG.md has a dated 0.3.0 section accurately covering task-4, task-5 and task-7, including manual row migration and partial-rollout limitation, and an empty [Unreleased]. No private Tandem IDs appear in public notes.", "README status/install commands use v0.3.0; historical v0.1.0/v0.2.0 examples remain clearly labeled. Endpoint-rank-rollout.md records the specific live merged-client evidence without overstating cartlab verification.", "`scripts/check.sh` and `cargo build --locked --release` pass; commit changes and leave Worker checkout clean. No push, tag, release or live deploy."]
  claimedAt: "2026-09-28T20:56:15Z"
  deliveredAt: "2026-09-28T21:04:56Z"
  validation: ["$ scripts/release/check-release.sh --ref refs/tags/v0.3.0", "$ scripts/check.sh", "$ cargo build --locked --release"]
  summary: "Prepared and committed the v0.3.0 source release metadata and documentation as 0b4ec5f; no Rust behavior, release machinery, live configuration, tag, push, or release changes. Worker checkout is clean."
  evidence: ["All release version metadata is 0.3.0; release checker accepts v0.3.0 and rejects v0.2.0.: Cargo.toml, Cargo.lock and herdr-plugin.toml were changed to 0.3.0. The v0.3.0 release check passed; v0.2.0 exited 1 with the expected tag mismatch.", "Changelog includes dated release notes, exact manual migration and empty Unreleased section.: CHANGELOG.md has an empty [Unreleased] heading and [0.3.0] - 2026-09-28 notes covering managed-to-staged preflight, branch/native fallback, Subagent names, endpoint ranks, the exact replacement row, and mixed rollout limitation. No private Tandem IDs were added.", "README and endpoint rollout notes state the current install/status and accurately describe approved live evidence.: README install/status use v0.3.0. The rollout notes record the desktop-wsl merged-client observation: x1nano herdr-agent-tree root then Worker with ha99dee8df1923c08-000001/000002, desktop ffsync root then Worker with he4cfca619976c0cb-000001/000002; isolated tests are distinguished, and cartlab's unupgraded 0.1.0/no-current-agents status is explicit.", "Required project validations pass; changes committed and Worker checkout clean.: scripts/check.sh and cargo build --locked --release passed. Commit 0b4ec5f contains six requested metadata/doc files; git status --short returned no changes."]
  filesChanged: ["Cargo.toml", "Cargo.lock", "herdr-plugin.toml", "CHANGELOG.md", "README.md", "docs/agent-tree/endpoint-rank-rollout.md"]
  updatedAt: "2026-09-28T21:04:56Z"
createdAt: "2026-09-28T20:56:07Z"
updatedAt: "2026-09-28T21:04:56Z"
assignee: "worker-task-9-0c64676a"
archivedAt: "2026-09-28T21:04:56Z"
resolution:
  outcome: "completed"
---

## Description

Prepare (do not publish) the v0.3.0 source release from current main, including task-4 safe managed-to-staged preflight, task-5 native workspace/tab fallback and Subagent short names with agent_tree_branch token, and task-7 endpoint-qualified rank. Local main is 3 commits ahead of origin after these integrations. Update Cargo.toml, Cargo.lock and herdr-plugin.toml to 0.3.0; date the [0.3.0] CHANGELOG entry using actual current date, keep [Unreleased] empty, update README normal-user install ref and status to v0.3.0. Explain the exact manual user-owned Agents row migration and mixed endpoint rollout. Record task-7 live multi-machine validation evidence (2026-09-28: desktop-wsl merged TUI showed x1nano herdr-agent-tree root immediately followed by task-7 Worker, then desktop ffsync root immediately followed by task-156 Worker; x1nano ranks ha99dee8df1923c08-000001/000002 and desktop he4cfca619976c0cb-000001/000002), clearly distinguishing this from isolated tests and noting cartlab was not upgraded. Amend endpoint-rank-rollout.md to mark that validation completed for those two endpoints, while preserving partial-rollout caveat. Orchestrator owns push, tag, release and later cartlab deploy; no live edits in this task.
