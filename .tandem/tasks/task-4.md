---
id: task-4
type: task
title: "Show which agent a row belongs to without clipping"
state: todo
priority: "low"
effort: "small"
relatedFiles: ["install.sh", "demo.sh", "README.md", "src/decoration.rs"]
tags: ["ux", "papercut"]
accord:
  status: "ready"
  acceptance: ["A Worker row identifies its agent legibly at the sidebar widths actually in use, or the current behaviour is retained with measured evidence that alternatives are worse.", "Nesting glyphs and parent-child structure remain readable at those widths.", "The decoration token stays within its documented cap and grammar.", "The empty identity cell for an agent with no terminal title is either fixed or explicitly documented.", "Whatever is chosen is measured at real sidebar widths, not reasoned about abstractly."]
  validation: ["$ git diff --check", "$ cargo build --locked --release"]
  constraints: ["Do not expand the decoration token beyond its documented cap or add a name slot that evicts the task id or attention indicator.", "Do not degrade nesting legibility to fit more identity text.", "Do not require a Pi-side change: Subagents and Workers already publish usable names."]
  updatedAt: "2026-09-16T01:24:37Z"
createdAt: "2026-09-16T01:24:37Z"
updatedAt: "2026-09-16T01:24:37Z"
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

