---
id: task-1
uid: 0e6727c3-f5fe-4b2f-ae80-f6f10b552e68
type: task
title: "Investigate readable Agent Tree identity within Herdr sidebar constraints"
priority: "medium"
effort: "small"
references: ["https://herdr.dev/docs/configuration/#sidebar-row-layouts"]
relatedFiles: ["README.md", "docs/agent-tree/task-4-measurements.md", "src/decoration.rs", "tests/e2e/sidebar.sh"]
tags: ["spike", "ux"]
accord:
  status: "accepted"
  acceptance: ["Record a reproducible same-workspace/same-tab parent-and-live-child sidebar case at actual local width, including what information is lost by the current one-line layout.", "Compare at least one plugin/config-only alternative with the Herdr 0.9.1 documented row capabilities; state concrete limitations, vertical/width tradeoffs, and whether a Herdr change is required.", "Write an evidence-backed recommendation for the smallest next implementation task, with a runnable visual or test check; do not change the archived task-4 record."]
  claimedAt: "2026-09-27T02:05:10Z"
  deliveredAt: "2026-09-27T02:10:01Z"
  summary: "Recorded a same-tab live root/Subagent reproduction and measured config-only alternatives. The compact local row renders two identical Algomarchy · herdr-agent-tree entries despite a published └─S child token; Herdr 0.9.1 offers ordered/styled/hidden tokens but no documented width/alignment, so a polished single-line view preserving identity plus full location needs an explicit Herdr sidebar layout contract rather than changing Agent Tree's identity logic. Wrote docs/agent-tree/sidebar-identity-followup.md with recommendation and visual validation target."
  evidence: ["`herdr agent list` showed root w1:p1T and Subagent w1:p2H in tab w1:tZ; `herdr pane list --workspace w1` showed child role=subagent and agent_tree_row=└─S, root no role/row.", "Temporary 150x48 tmux client with live local rows [[state_icon, workspace, tab]] rendered two identical `◐ Algomarchy · herdr-agent-tree` rows under the `tree` header.", "Temporary client comparisons: five-cell one-line clipped child tab; conditional branch row used mixed heights; two-line workspace/tab then branch/machine preserved full tab; width 40 still clipped child tab.", "Herdr 0.9.1 sidebar docs enumerate token ordering, fg/bold/dim and hide rules; community configs use multiple rows, no documented fixed or right-aligned sidebar cells.", "`git diff --check` and `scripts/check.sh --no-e2e` passed in /home/algorant/Projects/herdr-agent-tree; committed research note as 29dede2. Live config unchanged."]
  filesChanged: ["docs/agent-tree/sidebar-identity-followup.md"]
  updatedAt: "2026-09-27T02:10:08Z"
createdAt: "2026-09-27T02:04:53Z"
updatedAt: "2026-09-27T02:10:08Z"
assignee: "pi"
archivedAt: "2026-09-27T02:10:08Z"
resolution:
  outcome: "completed"
---

## Description

Fresh follow-up to archived historical task-4 (not a reopening). Algorant chose a compact one-line local layout, `rows = [["state_icon", "workspace", "tab"]]`, after the documented plugin row clipped names and tree decoration at actual widths. This layout hides the branch and cannot distinguish two agents sharing a workspace/tab; the underlying row-cell allocation is Herdr behavior. Determine which requirement can be met by plugin/config alone versus requiring an upstream Herdr sidebar feature. Keep the current live config intact while investigating; do not claim that the historical clipping compromise solved this new goal.
