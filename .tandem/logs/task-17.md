---
id: task-17
type: task
title: "Spike dynamic tree re-latch after relationships appear in native mode"
priority: "high"
effort: "medium"
relatedFiles: ["tests/e2e/toggle.sh", "src/lifecycle.rs", "src/projection.rs", "src/transport.rs"]
tags: ["spike", "bug", "toggle", "dynamic-relationship"]
accord:
  status: "accepted"
  acceptance: ["An isolated real-Herdr reproduction starts in native/tree-off state, introduces a genuine root and Subagent relationship afterward, verifies the relationship and rank tokens are live, then toggles Tree on and captures the resulting view label and sidebar order.", "The finding states whether the reported failure is reproduced and locates the responsible boundary (relationship publication, subscriber reconciliation, view sorting/reinstallation, or pane closure), with exact logs and a reproducible command.", "No production fix is integrated from the spike; its worktree is disposable and the release dogfood remains blocked until the finding is resolved or shown not to be a plugin defect."]
  claimedAt: "2026-09-21T04:22:17Z"
  deliveredAt: "2026-09-21T04:22:24Z"
  validation: ["$ tests/e2e/toggle.sh"]
  constraints: ["Do not touch the active Herdr server, live plugin state, user config or unrelated panes.", "Use credential-free isolated Pi fixtures and do not invoke a model.", "Do not infer relationships from titles, names, cwd or the Subagent status footer; inspect exact relationship tokens and live panes.", "Discard the spike worktree after preserving the finding and reproducible check."]
  summary: "Disposable isolated spike did not reproduce a dynamic Tree re-latch defect for live validated Pi relationships. Relationships introduced while Tree was off ranked immediately; prefix+t installed the tree view and reformed the family. Already-ranked families also reformed after off/on, and a new child re-sorted while Tree stayed on. Only closed Subagent panes or retained panes whose Pi agent/session had exited could not appear, because Herdr exposes no live agent row to rank."
  evidence: ["Phase A: while view probe reported active=false, a live root→Subagent relationship received rank 000002; prefix+t changed the view to source plugin:agent-tree label tree and sidebar order root-alpha,sub-alpha,lone-1.", "Phase B: an already-ranked family was turned off, a second live child received rank 000003 while off, and turning Tree on produced root-alpha,sub-alpha,sub-beta,lone-1.", "Live view re-evaluation also passed: a new live child appeared in tree order without another toggle.", "Closed pane case: completed Subagent pane disappeared from agent.list and therefore had no row to rank. Retained no-agent case: pane remained but agent/session/rank/row were absent; stale relationship tokens alone were correctly rejected.", "Native validation `tests/e2e/toggle.sh` exited 0. Disposable reproduction `SPIKE_KEEP=1 tests/e2e/toggle-dynamic.sh` exited 0 with RESULT: NOT REPRODUCED. No production source was integrated and the spike worktree was discarded."]
  reviewer: "orchestrator"
  updatedAt: "2026-09-21T04:22:28Z"
createdAt: "2026-09-21T04:12:45Z"
updatedAt: "2026-09-21T04:22:28Z"
assignee: "orchestrator"
archivedAt: "2026-09-21T04:22:28Z"
resolution:
  outcome: "completed"
  reviewer: "orchestrator"
---

## Description

Algorant observed that turning Tree back on while Subagents were present did not reform the delegation family. Existing toggle E2E creates and ranks the relationship before its first tree/native transition, so it does not cover the dynamic sequence: start with Tree off/native ordering, create or publish a valid root→Subagent relationship while native remains active, then toggle Tree on and require the family to latch into tree order. Reproduce this against an isolated real Herdr server and identify whether the failure is relationship-token publication, rank reconciliation, view reinstallation/re-evaluation, or closed-pane timing. This is a disposable spike; do not ship a production fix from it.
