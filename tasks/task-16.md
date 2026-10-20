---
id: task-16
uid: c27d2467-6b13-4ffb-ac1a-d45cc9da0d8d
type: task
title: "Nest a workspace's agents under its explicit lead (agency_lead) with Variant A ordering"
state: "in-progress"
priority: "medium"
references: ["task-15"]
relatedFiles: ["src/transport.rs", "src/identity.rs", "src/forest.rs", "src/decoration.rs", "src/projection.rs", "src/testutil.rs", "scripts/lib/report.py", "tests/e2e/sidebar.sh", "docs/agent-tree/m2-contract.md", "README.md", "CHANGELOG.md", "herdr-plugin.toml"]
tags: ["identity", "nesting"]
accord:
  status: "delivered"
  acceptance: ["With exactly one valid agency_lead anchor in a workspace, its other undelegated agent rows (Pi and non-Pi) render as depth-1 `├─M`/`└─M` children after the anchor's delegated children, sharing the anchor's family rank prefix and a contiguous preorder.", "A Worker started by a manus and that Worker's Subagent nest beneath the manus (Ceph -> M -> W -> S, `│  │  └─S name` at depth 3).", "A forged or stale agency_lead, two anchors in one workspace, or an anchor with a delegation parent produces no grouping, and the rows return to today's roots; the tab label is never read.", "docs/agent-tree/m2-contract.md (C2/C4/C5), README and CHANGELOG describe workspace membership under a validated anchor as a second edge kind, while delegation edges stay never-inferred.", "scripts/doctor.sh reports lead-declared/lead-valid panes, anchored and ambiguous workspaces, and member counts, in both text and --json output.", "`just test` (scripts/check.sh, including the extended isolated tests/e2e/sidebar.sh) passes."]
  claimedAt: "2026-10-20T13:51:05Z"
  deliveredAt: "2026-10-20T14:42:29Z"
  validation: ["$ just test"]
  summary: "Workspace membership under a validated agency_lead anchor, with Variant A ordering and an M marker. Deployed as a staged dev build on worktop; live st family nests its manus. The branch is not yet merged; acceptance waits for Algorant's sidebar review and a real-tmux `just test`."
  evidence: ["Worker commit 9abfbe1 on the worker-task-16 branch; orchestrator-run scripts/check.sh --no-e2e: All checks passed", "Deployed on worktop with scripts/deploy.sh from the worker checkout: staged subscriber pid 3520778, sha256 matches the build. The old managed v0.4.0 subscriber (pid 2346) was stopped as the README documents.", "Live: st (w8) family root with st-prod/st-captis/st-dhc/st-moa ├─M and st-duckdb └─M; no M rows in other workspaces", "doctor --endpoint local: healthy; leads declared 6 (valid 6), anchored workspaces 6, ambiguous 0, members 5", "GAP: sidebar.sh/toggle.sh PTY assertions passed only under the Worker's pyte tmux emulator; worktop has no tmux and no active just, so a real `just test` is still outstanding"]
  filesChanged: ["src/transport.rs", "src/identity.rs", "src/forest.rs", "src/decoration.rs", "src/testutil.rs", "scripts/lib/report.py", "tests/e2e/sidebar.sh", "tests/shell/doctor.sh", "docs/agent-tree/m2-contract.md", "README.md", "CHANGELOG.md", "herdr-plugin.toml"]
  updatedAt: "2026-10-20T14:42:29Z"
createdAt: "2026-10-20T13:49:55Z"
updatedAt: "2026-10-20T14:42:29Z"
effort: "medium"
assignee: "worker-task-16-53e4635e"
---

## Description

Implements the option (b2) that Algorant approved in task-15 (via Herdra, m6ef2dd4d), with Variant A ordering. Non-Pi agents in member tabs nest too.

Anchor: a Pi agent row whose `agency_lead` token equals sha256(["pi","path",<its own agent_session.value>]) and which has no validated delegation parent. A workspace with exactly one anchor groups. Members are agent rows in that workspace_id (Pi or not) with no delegation parent, other than the anchor. Members are placed at depth 1 after the anchor's delegated children, in native order, and get the branch marker `M` (no name). A manus's own Workers and Subagents keep delegation nesting beneath it. Zero or several anchors, a mismatched or stale lead token, or an anchor with a delegation parent means no grouping. The tab label is never read.

The publisher is the pi-agency side (Algorant/.pi, owned by the .pi Ceph). It is not part of this Task; the e2e fixture publishes `agency_lead` itself.

No new Rust unit tests (global testing rule): new coverage goes into tests/e2e/sidebar.sh. Existing Rust tests are touched only where struct changes require.
