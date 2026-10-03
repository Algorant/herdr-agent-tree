---
id: task-3
uid: 051c3193-16c4-4acb-a873-1e45b76263b2
type: task
title: "Render a role-aware one-line Agent Tree row without repeated Pi titles"
priority: "medium"
effort: "medium"
relatedFiles: ["src/transport.rs", "src/projection.rs", "src/lifecycle.rs", "src/decoration.rs", "scripts/activate-managed.sh", "scripts/lib/config.py", "tests/e2e/sidebar.sh", "README.md"]
tags: ["ux", "plan-first"]
accord:
  status: "accepted"
  acceptance: ["A single Agent row per pane shows root workspace/tab and, for validated Worker/Subagent descendants, a left-readable branch with that child's identity; there is no repeated `π -` title or indistinguishable `workspace · tab · └─S` child. Root, Worker, and Worker-owned Subagent stay in correct preorder.", "Ordinary Pi and non-Pi agents remain visible; ambiguous, invalid, missing or stale relationship metadata never invents a parent; changes to agent name, workspace/tab label, role or pane lifecycle refresh the composed display without stale plugin-owned tokens.", "The one-time Herdr sidebar configuration and install/deploy defaults document the new row; the old two-token rank/decoration behavior and owner-safe toggle/clear are preserved or deliberately migrated with tested cleanup.", "Real isolated Herdr sidebar evidence at practical widths (26, 32, 36, and local actual width) demonstrates branch/role and child identity surviving truncation; an isolated nested Worker/Subagent fixture passes. No live install or config edit occurs before Algorant approves dogfood."]
  claimedAt: "2026-09-27T04:48:50Z"
  deliveredAt: "2026-09-27T12:25:01Z"
  validation: ["$ scripts/check.sh", "$ cargo build --locked --release"]
  constraints: ["Use a plan-first Worker and obtain explicit orchestrator agreement on the implementation before edits.", "Keep scope in herdr-agent-tree; no upstream Herdr or Pi modifications unless a demonstrated API block is reported to the owner first.", "Do not mutate the live Herdr plugin registration, running subscriber, or ~/.config/herdr/config.toml during implementation; source build and isolated tests are allowed.", "Do not push, merge, finish or remove the Worker checkout; the owning orchestrator controls those steps and asks Algorant before a live install/dogfood trial."]
  summary: "Addressed both evidence defects and the released-pane stale-token case. Sidebar tests now find the actual rendered pane seam immediately after the Agents header's tree label, assert exact 26/32/36 widths, and print captured rows. Session snapshots retain pane-only records carrying stale Agent Tree tokens; reconciliation clears only the plugin-owned row/rank. Committed as `6986d47` (`Render role-aware composed Agent Tree rows`); Worker checkout is clean."
  evidence: ["Measure and slice the actual sidebar boundary; assert pinned widths and show captured evidence: The isolated tmux capture locates the vertical `│` seam immediately following the rendered `tree` header label and crops through that seam (not by the 150-column terminal width). Pinned assertions measured 26, 32, and 36 columns exactly. Output includes the actual captured header and rows; at 26: `agents              tree│`, `○ └─W worker-task-3-78  │`, `○ │  └─S worker-owned-  │`, `○ lone-1 · 1            │`, `○ lone-2 · 1            │`, `○ codex · codex-1 · 1   │`. Default local width settings reproduced in isolation measured 26 columns.", "Release/removal cannot leave stale plugin-owned row/rank metadata; preserve other owners: After isolated `pane.release_agent` removed codex from `agent.list`, `session.snapshot.panes` still exposed its plugin metadata. Cleanup-only rows route through the normal `pane.report_metadata` path using source `agent-tree`, clearing only `agent_tree_row`/`agent_tree_rank`. `herdr pane get` after cleanup returned `{\"keep\":\"kept\"}`: both plugin-owned keys absent, unrelated `release-owner-fixture` token preserved.", "Composed display, identity refresh, visibility, toggle/clear ownership and ordering: Isolated sidebar fixture passed with named Worker and Worker-owned Subagent, readable lone Pi/non-Pi rows, validated preorder, and no repeated `π -` title. Watchers observed `pane_updated`, `workspace_renamed`, and `tab_renamed`, followed by changed composed tokens. Toggle-off retained composed rows; clear removed plugin-owned row/rank while preserving a token owned by another source."]
  filesChanged: ["README.md", "docs/agent-tree/sidebar-identity-followup.md", "docs/agent-tree/task-4-measurements.md", "scripts/activate-managed.sh", "scripts/deploy.sh", "scripts/lib/config.py", "src/decoration.rs", "src/lifecycle.rs", "src/projection.rs", "src/testutil.rs", "src/transport.rs", "tests/e2e/sidebar.sh", "tests/e2e/toggle.sh", "tests/shell/activate-managed.sh", "tests/shell/deploy-endpoint.sh", "tests/shell/dev-reload.sh", "tests/shell/doctor.sh"]
  updatedAt: "2026-09-27T12:25:01Z"
createdAt: "2026-09-27T04:46:58Z"
updatedAt: "2026-09-27T12:25:01Z"
assignee: "worker-task-3-78712afb"
archivedAt: "2026-09-27T12:25:01Z"
resolution:
  outcome: "completed"
---

## Description

Implement the user-approved one-line Agent sidebar in herdr-agent-tree. Today the live config shows workspace/tab on every Pi row and appends only `└─S`/`└─W` at the end, losing child identity and readable hierarchy. Replace this with one plugin-composed, role-aware display value: roots/ordinary Pi rows retain useful workspace + tab location, while validated Workers/Subagents display an indented branch/role plus their own useful identity (and relevant task/attention), rather than repeating the root's location or `π -` terminal title. Herdr may need a one-time config reference to the new plugin display token; keep non-Pi rows visible. Follow existing identity safety, sorting, ownership and cleanup contracts. Inspect the actual Herdr API for names/location labels and update triggers before locking in the design. Do not install, relink, reload or modify the currently running plugin/config as Worker work. The owning orchestrator must request Algorant's approval for live install/dogfood after reviewing tests and build.
