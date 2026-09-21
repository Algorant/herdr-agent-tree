---
id: task-18
type: task
title: "Spike Agent focus view loss and missing live Worker relationships"
priority: "high"
effort: "medium"
relatedFiles: ["tests/e2e/toggle.sh", "docs/agent-tree/m1-evidence.md", "src/lifecycle.rs", "src/projection.rs", "src/transport.rs"]
tags: ["spike", "bug", "focus", "view", "relationship-publication"]
accord:
  status: "accepted"
  acceptance: ["An isolated real-Herdr multi-workspace fixture installs the tree view, focuses/clicks different live Agent rows, and captures the view active/source/label plus sidebar header before and after each transition; any tree→grouped transition is reproduced and located at plugin, server, client, or selected-endpoint scope.", "A genuine pi-agency Worker/Subagent publication is inspected while live and compared with a flat live row: exact role, agency_self, agency_parent, agent_session, rank and row tokens establish whether publication is missing, rejected or cleared.", "The finding separates same-endpoint focus from saved-machine endpoint selection and states the smallest production or upstream fix, with a reproducible check and no production change integrated."]
  claimedAt: "2026-09-21T16:09:37Z"
  deliveredAt: "2026-09-21T16:09:51Z"
  validation: ["$ tests/e2e/toggle.sh"]
  constraints: ["Do not restart Herdr, alter user config, or disturb unrelated panes.", "Use isolated Herdr for mouse/focus reproduction; any live pi-agency witness must be a scoped throwaway child owned by the spike Worker and cleaned up.", "Do not infer relationships from names, titles, cwd or visual indentation; inspect exact live tokens and agent sessions.", "Discard the spike worktree after preserving the finding."]
  summary: "Disposable spike found no same-endpoint Agent Tree focus defect. Programmatic focus, real Agent-row mouse clicks, Space-row clicks, keyboard workspace switching, second-client focus and detach/reattach all preserved active=true/source=plugin:agent-tree/label=tree. The screenshot's tree/grouped transition is consistent with Herdr's documented selected-server view scope. Genuine pi-agency Worker and Worker-owned Subagent publications ranked correctly; the flat live herdr-notifs-plus rows had zero metadata tokens, so their relationships were never published upstream rather than rejected or cleared by Agent Tree."
  evidence: ["Isolated Herdr 0.9.1 multi-workspace TUI: every same-endpoint focus/click/client transition preserved header tree and the plugin-owned view; focus IDs changed, proving clicks landed.", "Tree→grouped occurred only on explicit agent-tree.toggle, subscriber shutdown cleanup, or plugin disable; agent-tree.apply restored tree.", "Live task-18 Worker had valid role/agency_self/agency_parent and rank 000002; its real Worker-owned Subagent had valid recomputed identity, parent edge, rank 000003 and row `│  └─S`. Subscriber log changed 2→3→2 as it lived and closed.", "Five inspected flat live rows, including the herdr-notifs-plus root at capture time, had genuine Pi sessions but zero tokens. Agent Tree had no role/agency_self/agency_parent input to validate; this is publication absent, not plugin rejection/clear.", "Herdr 0.9.1 documents that the selected server's view governs the combined agent list, explaining view-label changes when selection crosses endpoints whose view states differ. The unreachable saved endpoint prevented a second-server fixture and no machine profile was changed.", "Native `tests/e2e/toggle.sh` and disposable `spikes/task-18/focus-view-probe.sh` both exited 0. No production source was integrated; the worktree was discarded."]
  reviewer: "orchestrator"
  updatedAt: "2026-09-21T16:09:56Z"
createdAt: "2026-09-21T15:51:00Z"
updatedAt: "2026-09-21T16:09:56Z"
assignee: "orchestrator"
archivedAt: "2026-09-21T16:09:56Z"
resolution:
  outcome: "completed"
  reviewer: "orchestrator"
---

## Description

Algorant observed two concurrent live failures in the combined Agents sidebar: clicking a different Agent row changed the header from the plugin-owned `tree` view to native `grouped`, and live herdr-notifs-plus Worker/Subagent rows remained flat with no Agent Tree decoration. Herdr 0.9.1 documents that an agent view lasts until explicit clear/replacement, plugin disable/unlink/uninstall, or server exit, so focus alone must not deactivate it. Determine whether mouse/agent focus clears or switches the selected server view, whether the failure is per-client/per-endpoint context, and whether the flat live children lack pi-agency relationship publication or are rejected by validation. This is a disposable spike; do not integrate a production fix until the boundary is proven.
