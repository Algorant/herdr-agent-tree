---
id: task-6
uid: 6aeac51d-f726-413c-8109-ad93cb333cea
type: task
title: "Prepare the v0.2.0 source release (version, changelog, install docs)"
priority: "high"
effort: "small"
relatedFiles: ["Cargo.toml", "Cargo.lock", "herdr-plugin.toml", "CHANGELOG.md", "README.md"]
tags: ["release"]
accord:
  status: "accepted"
  acceptance: ["Cargo.toml, Cargo.lock (agent-tree package entry) and herdr-plugin.toml all declare 0.2.0; `scripts/release/check-release.sh --ref refs/tags/v0.2.0` passes and `--ref refs/tags/v0.1.0` fails.", "CHANGELOG.md has `## [0.2.0] - 2026-09-27` accurately describing the changes since v0.1.0 (Added/Changed/Fixed as applicable), an empty `[Unreleased]`, the user-owned sidebar row upgrade step, and the task-5 known limitation.", "README status line and normal-user install/activation commands reference v0.2.0; historical v0.1.0 references are only kept where explicitly historical.", "`scripts/check.sh` and `cargo build --locked --release` pass; changes are committed on the Worker branch and the checkout is clean."]
  claimedAt: "2026-09-27T13:07:26Z"
  deliveredAt: "2026-09-27T13:22:32Z"
  validation: ["$ scripts/release/check-release.sh --ref refs/tags/v0.2.0", "$ scripts/check.sh", "$ cargo build --locked --release"]
  summary: "Revised the v0.2.0 public changelog for accuracy and amended the Worker commit to d9b6b36. Checkout is clean; no push, tag, or release was performed."
  evidence: ["Public release notes state the endpoint/plugin limitation without private task references and cover legacy, stopped, and unreachable endpoints with upgrade guidance.: Removed the local task reference; limitation now includes Agent Tree 0.1.0, stopped subscribers, unreachable saved machines, and upgrade-every-machine guidance with deployment/reinstall examples.", "Changed notes explicitly describe the default row change, complete row-value semantics, and snapshot/event refresh sources.: Documented old/new row templates, row values for all agents, ordinary/root and validated descendant content with task/attention dropped first, plus `session.snapshot` and the three subscribed events.", "Fixed notes describe released-pane stale-token cleanup and preservation of other sources.: Added a Fixed bullet stating cleanup removes only `agent_tree_row` and `agent_tree_rank` from released-agent panes while preserving other-source tokens.", "Revised notes validated and committed with clean checkout.: Both requested validation commands passed; CHANGELOG.md was included in amended commit d9b6b36; checkout is clean."]
  filesChanged: ["CHANGELOG.md"]
  updatedAt: "2026-09-27T13:22:32Z"
createdAt: "2026-09-27T13:07:19Z"
updatedAt: "2026-09-27T13:22:32Z"
assignee: "worker-task-6-b1149fe2"
archivedAt: "2026-09-27T13:22:32Z"
resolution:
  outcome: "completed"
---

## Description

Prepare, but do not publish, the v0.2.0 source release covering everything since v0.1.0 (24efc31): managed activation (`scripts/activate-managed.sh`, b06c43b), sidebar identity docs (29dede2), and task-3's role-aware one-cell composed Agent row (6986d47: `session.snapshot` labels, rename-event refresh, owned stale-token cleanup, managed row `[["state_icon", "$agent_tree_row"]]`). The release workflow requires manifest/Cargo/CHANGELOG/tag agreement (`scripts/release/check-release.sh --ref refs/tags/v0.2.0`) and a clean source build on Rust 1.81.0; keep code 1.81-compatible and do not change release machinery. Release notes must be honest: include the upgrade step for an existing user-owned `[ui.sidebar.agents]` block (deploy/activation never rewrite it) and the known limitation tracked as task-5 (agents on endpoints without a compatible plugin render icon-only rows). Orchestrator owns commit integration, push, tag, and GitHub release.
