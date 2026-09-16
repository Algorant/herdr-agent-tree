---
id: task-4
type: task
title: "Show which agent a row belongs to without clipping"
priority: "low"
effort: "small"
relatedFiles: ["install.sh", "demo.sh", "README.md", "src/decoration.rs"]
tags: ["ux", "papercut"]
accord:
  status: "accepted"
  acceptance: ["A Worker row identifies its agent legibly at the sidebar widths actually in use, or the current behaviour is retained with measured evidence that alternatives are worse.", "Nesting glyphs and parent-child structure remain readable at those widths.", "The decoration token stays within its documented cap and grammar.", "The empty identity cell for an agent with no terminal title is either fixed or explicitly documented.", "Whatever is chosen is measured at real sidebar widths, not reasoned about abstractly."]
  claimedAt: "2026-09-16T02:18:45Z"
  deliveredAt: "2026-09-16T02:33:58Z"
  validation: ["$ git diff --check", "$ cargo build --locked --release"]
  constraints: ["Do not expand the decoration token beyond its documented cap or add a name slot that evicts the task id or attention indicator.", "Do not degrade nesting legibility to fit more identity text.", "Do not require a Pi-side change: Subagents and Workers already publish usable names."]
  summary: "Resolved task-4 by measuring the current row configuration in the isolated demo at Herdr's 18/26/32/36 sidebar widths and retaining it, because every measured alternative is worse. No plugin, script or config behaviour changed: only README.md and a new evidence document were added. At 26 (default) and 32 the Worker row clips both cells but the clipped task id (`task-…`, `task-dem…`) still identifies it; at 36 the full 15-character decoration including `▸` fits; at 18 identity is weak (`└─W t… · π - …`) though the branch glyphs survive. Nesting glyphs stay readable from 26 up; at 18 the depth-2 role letter clips to `│  └─…`. Measured alternatives rejected: a second row doubles the agent row count (16 vs 8), title-first only relocates the clip onto the decoration (18: `└─W …`, `│  └…`), the `agent`+title four-cell row clips the Worker decoration to `└─W t…` and the Subagent to `│  └─…` and evicts the task id, and `rows_by_agent` keys on canonical agent IDs, so all Pi roles share `pi` and a `worker` key is rejected by `herdr config check` (`unknown canonical agent id`). The empty identity cell for an agent with no terminal title is now explicitly documented under README Known limitations. Remaining gap/caveat stated in the doc: the demo Worker title (`π - worker-alpha`, 16 chars) is shorter than a live worktree title; the live row recorded in the task matches the 26-column measurement, and a longer title can only clip further within the measured row budget, but no separate long-title launch was run (the orchestrator judged the evidence sufficient)."
  evidence: ["A Worker row identifies its agent legibly at the sidebar widths actually in use, or the current behaviour is retained with measured evidence that alternatives are worse.: Retained. Measured raw renders: 26 -> '└─W task-… · π - work…', 32 -> '└─W task-dem… · π - worker-…' (clipped task id still identifies the Worker), 36 -> '└─W task-demo ▸ · π - worker-al…' (full decoration). Alternatives measured worse: two-row doubles 8 agent rows to 16; title-first at 26 gives '└─W task…' and at 18 '└─W …'; agent+title at 26 gives '└─W t… · work… · π - …' (task id gone); rows_by_agent cannot target a role.", "Nesting glyphs and parent-child structure remain readable at those widths.: At 26, 32 and 36 the branch/role glyphs survive: '└─W', '│  └─S ?', '└─S'. At 18 the depth-2 Subagent clamps to '│  └─…' (role letter and '?' clip) while the branch glyphs '│' and '└─' remain, so structure is readable and role is not.", "The decoration token stays within its documented cap and grammar.: The fixture Worker token is '└─W task-demo ▸' = 15 chars, inside the 20-char cap and the C4 grammar (indent branch role task attention). src/decoration.rs was not changed; the existing cap/grammar/drop-order tests pass (40 unit tests, exit 0). Clipping observed in renders is Herdr's row-cell allocation, not a token overrun.", "The empty identity cell for an agent with no terminal title is either fixed or explicitly documented.: Documented in README.md Known limitations item 7, naming the demo's synthetic 'codex' row and explaining why the measured fix (adding the 'agent' cell) was rejected: it clips the Worker decoration to '└─W t…' and the Subagent to '│  └─…' and evicts the task id.", "Whatever is chosen is measured at real sidebar widths, not reasoned about abstractly.: docs/agent-tree/task-4-measurements.md records the raw cropped sidebar at 18, 26, 32 and 36 columns for the current configuration, the two-row, title-first and agent+title alternatives, and the published token/title table, plus the exact 'herdr config check' diagnostic that rejects a 'worker' rows_by_agent key."]
  filesChanged: ["README.md", "docs/agent-tree/task-4-measurements.md"]
  updatedAt: "2026-09-16T02:33:58Z"
createdAt: "2026-09-16T01:24:37Z"
updatedAt: "2026-09-16T02:33:58Z"
assignee: "worker-task-4-1a46539a"
archivedAt: "2026-09-16T02:33:58Z"
resolution:
  outcome: "completed"
---

## Description

## Problem

Rows identify the agent using `terminal_title_stripped`, chosen because Subagents and Workers already carry their own name there and no Pi-side change was needed. It works well for roots and Subagents:

    π - ffsync
    │  └─S · π - sub-alpha

It works badly for Workers, whose title is the full worktree name:

    └─W task-… · π - work…

Both cells clip at real sidebar widths, and the `task-…` id ends up doing the identifying. Observed live by Algorant on 2026-09-15.

A non-Pi agent with no terminal title renders an empty identity cell, visible in the demo's synthetic `codex` row.

## Constraints that shaped the current choice

Putting the name inside `agent_tree_row` was rejected during the original work and the reasoning still holds: that token is capped at 20 characters and already carries depth glyphs, branch, role, Worker `task_id` and attention. A measured alternative clipped the decoration to `└─W tas…` at 32 columns, which destroys the nesting that is the point of the plugin.

Note that the 20-character cap is a cap on the token value, not a reservation of sidebar width.

## Directions worth exploring

- Shortening the Worker identity specifically, since the useful part is the task id which the decoration already carries.
- `rows_by_agent` in Herdr's sidebar config, which allows different row layouts per agent kind.
- A second row for deeper context, accepting the vertical cost.
- Leaving it alone and documenting it, if no option improves on the current trade.

An honest "the current trade is the best available" is an acceptable outcome if the alternatives are measured and shown to be worse.

