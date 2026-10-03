---
id: task-2
uid: e7ea48d9-d592-4a33-b9c5-bc25fc5aabeb
type: task
title: "Disposable live fixture for nested Agent Tree Worker and Subagent"
priority: "low"
effort: "small"
relatedFiles: ["src/forest.rs", "src/decoration.rs", "tests/e2e/sidebar.sh"]
tags: ["spike", "demo"]
accord:
  status: "accepted"
  acceptance: ["While live, a real Worker row is nested below its delegating Pi agent and a read-only Subagent row is nested below that Worker, with both identities observable in Herdr.", "The Worker makes no source edits and reports the exact pane/workspace identities and visual evidence so the owner can verify the fixture before disposal."]
  claimedAt: "2026-09-27T02:41:00Z"
  deliveredAt: "2026-09-27T02:41:09Z"
  summary: "Genuine live UI fixture verified and inspected by Algorant: host Pi w4:p3 in herdr-agent-tree, Worker task-2 w5:p1, Worker-owned Subagent w5:p2; the sidebar displayed Pi → └─W task-2 → │  └─S. Worker made no source edits. After approval, exact Worker attempt was discarded, its pane/worktree/branch removed, and repo remains clean."
  evidence: ["During inspection `herdr pane get w5:p2` showed `role=subagent`, `agency_parent` matching Worker `agency_self`, `agent_tree_row=│  └─S`, rank 000003; Worker w5:p1 had `role=worker`, `agent_tree_row=└─W task-2`, rank 000002.", "The live tmux-backed Herdr sidebar displayed `π - herdr-agent-tree`, `└─W task-2 ▸ · π - worker-task-…`, and `│  └─S · π - plugin-forest-scou…` in consecutive rows; doctor reported 2 valid relationships and 3 ranked panes.", "Algorant replied `ok looks good` with screenshot of the nested chain. `worker_discard` disposed the exact attempt; Herdr has no task-2 pane, `wt list` shows only main, and `git status --short --branch` is clean."]
  updatedAt: "2026-09-27T02:41:13Z"
createdAt: "2026-09-27T02:37:36Z"
updatedAt: "2026-09-27T02:41:13Z"
assignee: "pi"
archivedAt: "2026-09-27T02:41:13Z"
resolution:
  outcome: "completed"
---

## Description

Operator-authorized visual fixture, not a source implementation. Spawn a real Worker in a Worktrunk checkout of herdr-agent-tree, and have that Worker spawn a read-only Subagent so Algorant can inspect the one-line tree. Keep both alive long enough for inspection; do not edit source or commit. The owning orchestrator will discard the Worker and remove the exact checkout after Algorant confirms the view, then restore the pre-test Herdr sidebar config.
