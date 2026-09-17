---
id: task-11
type: task
title: "Implement the grouped, priority and tree agent-mode cycle"
state: "in-progress"
priority: "high"
effort: "medium"
relatedFiles: ["docs/agent-tree/task-10-mode-cycle.md", "herdr-plugin.toml", "src/lifecycle.rs", "src/projection.rs", "src/wire.rs", "README.md", "tests"]
tags: ["ux", "configuration", "toggle"]
accord:
  status: "claimed"
  acceptance: ["Starting from grouped, successive action invocations produce priority, then tree, then grouped again with the correct sidebar header each time.", "Grouped and priority ordering match Herdr's native modes; tree ordering and identity validation remain unchanged.", "Leaving tree mode clears plugin-owned tree tokens and projection state so grouped/priority do not retain stale decoration or rank data.", "The cycle remains deterministic across repeated invocations, config reload and server restart, with documented initial-state behavior.", "The user's sidebar row configuration is preserved while modes change.", "Automated isolated tests cover the complete cycle, view ownership conflicts, restart/reload, stale tree-token cleanup and unknown/corrupt mode state."]
  claimedAt: "2026-09-17T22:02:17Z"
  validation: ["$ git diff --check", "$ just test", "$ just build"]
  constraints: ["Follow the task-10 mechanism and state contract; do not invent a fallback implementation.", "Do not approximate or rename the grouped and priority native modes.", "Do not overwrite the user's [ui.sidebar.agents] row configuration as part of cycling modes.", "Do not restart or stop the whole Herdr server as the mode-change path.", "Keep mode state, active view ownership and displayed header consistent across repeated actions and server restarts."]
  updatedAt: "2026-09-17T22:02:17Z"
createdAt: "2026-09-16T17:58:11Z"
updatedAt: "2026-09-17T22:02:17Z"
references: ["task-10", "decision-1"]
assignee: "worker-task-11-18e21e3e"
---
Implement the mechanism selected by task-10 so the plugin action cycles exactly `grouped → priority → tree → grouped`. Grouped and priority use Herdr-native-equivalent ordering and labels; tree uses the validated delegation projection. The sidebar row configuration remains independent and must not be overwritten as part of changing modes. Replace the current binary tree/native toggle before public release.