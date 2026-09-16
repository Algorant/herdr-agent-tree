---
id: task-10
type: task
title: "Determine the safe mechanism for cycling grouped, priority and tree agent modes"
state: todo
priority: "high"
effort: "small"
relatedFiles: ["herdr-plugin.toml", "src/projection.rs", "src/lifecycle.rs", "src/wire.rs", "README.md", "docs"]
tags: ["spike", "ux", "configuration", "toggle"]
accord:
  status: "ready"
  acceptance: ["The native grouped and priority mode semantics and the public mechanism for selecting each are established with reproducible isolated evidence.", "A three-step grouped → priority → tree → grouped cycle is demonstrated or the exact missing platform capability is identified.", "The recommendation defines mode detection, projection/view ownership, header labels, token cleanup and behavior after config reload/server restart.", "The spike either establishes an implementable mechanism that preserves unrelated sidebar configuration or escalates the unresolved Herdr limitation instead of guessing."]
  validation: ["$ git diff --check"]
  constraints: ["Use only an isolated Herdr HOME/XDG/socket; do not modify Algorant's live config or active server.", "Do not approximate grouped or priority sorting; demonstrate equivalence to the native modes.", "Do not infer undocumented active-view behavior; establish how current mode is detected and how source ownership interacts with native modes.", "Do not overwrite unrelated user configuration or require restarting the whole Herdr server for each mode change."]
  updatedAt: "2026-09-16T18:00:04Z"
createdAt: "2026-09-16T17:58:01Z"
updatedAt: "2026-09-16T18:00:04Z"
---
Algorant requires one agent-mode action that cycles `grouped → priority → tree → grouped`. Grouped and priority must behave like Herdr's native agent panel modes; tree is the plugin's validated delegation projection. Investigate Herdr 0.9.0 public APIs and configuration behavior in an isolated instance to establish how a plugin action can detect the current mode, select the next mode, produce the correct header/order, and survive reload/restart without overwriting unrelated user configuration. Produce a reproducible mechanism and state contract before implementation.