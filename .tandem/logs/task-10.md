---
id: task-10
type: task
title: "Determine the safe mechanism for cycling grouped, priority and tree agent modes"
priority: "high"
effort: "small"
relatedFiles: ["docs/agent-tree/task-10-mode-cycle.md", "herdr-plugin.toml", "src/projection.rs", "src/lifecycle.rs", "src/wire.rs", "README.md", "docs"]
tags: ["spike", "ux", "configuration", "toggle"]
accord:
  status: "ready"
  acceptance: ["The native grouped and priority mode semantics and the public mechanism for selecting each are established with reproducible isolated evidence.", "A three-step grouped → priority → tree → grouped cycle is demonstrated or the exact missing platform capability is identified.", "The recommendation defines mode detection, projection/view ownership, header labels, token cleanup and behavior after config reload/server restart.", "The spike either establishes an implementable mechanism that preserves unrelated sidebar configuration or escalates the unresolved Herdr limitation instead of guessing."]
  claimedAt: "2026-09-17T21:36:50Z"
  validation: ["$ git diff --check"]
  constraints: ["Use only an isolated Herdr HOME/XDG/socket; do not modify Algorant's live config or active server.", "Do not approximate grouped or priority sorting; demonstrate equivalence to the native modes.", "Do not infer undocumented active-view behavior; establish how current mode is detected and how source ownership interacts with native modes.", "Do not overwrite unrelated user configuration or require restarting the whole Herdr server for each mode change."]
  note: "discarded: Successful spike: mechanism is native ui.agent_panel_sort plus server.reload_config for grouped/priority, existing pause flag for tree. Discarding the worktree without merging plugin source or the throwaway reference harness. Finding preserved in docs/agent-tree/task-10-mode-cycle.md. Runtime config writes still need Algorant's decision before task-11."
  updatedAt: "2026-09-17T22:01:43Z"
createdAt: "2026-09-16T17:58:01Z"
updatedAt: "2026-09-17T22:01:43Z"
archivedAt: "2026-09-17T22:01:43Z"
resolution:
  outcome: "completed"
---
Algorant requires one agent-mode action that cycles `grouped → priority → tree → grouped`. Grouped and priority must behave like Herdr's native agent panel modes; tree is the plugin's validated delegation projection. Investigate Herdr 0.9.0 public APIs and configuration behavior in an isolated instance to establish how a plugin action can detect the current mode, select the next mode, produce the correct header/order, and survive reload/restart without overwriting unrelated user configuration. Produce a reproducible mechanism and state contract before implementation.

## Spike finding (unmerged)

Isolated Herdr 0.9.0: there is no socket/CLI method to set native agent-panel sort. The only public mechanism is writing `[ui] agent_panel_sort` (`spaces` = grouped, `priority` = priority, `workspaces` is an alias for spaces) and calling `server.reload_config` (same PID, no restart). Tree remains the existing source-owned view plus the socket-scoped pause flag. Full contract: `docs/agent-tree/task-10-mode-cycle.md`.

task-11 must follow that contract (existing pause flag, restore original sort on clear/uninstall). Do not copy the spike's throwaway `MODE_FILE` reference harness. Runtime config writes need an explicit owner decision before implementation: the README currently says the plugin runtime writes no configuration.