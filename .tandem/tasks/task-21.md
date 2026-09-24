---
id: task-21
type: task
title: "Allow verified subscriber replacement after Herdr-managed source reinstall"
state: "in-progress"
priority: "high"
effort: "medium"
references: ["task-8-2"]
relatedFiles: ["src/lifecycle.rs", "tests/shell/dev-reload.sh"]
tags: ["bug", "release-blocker", "source-install", "lifecycle"]
accord:
  status: "claimed"
  acceptance: ["A managed Herdr source reinstall from an exact ref followed by `agent-tree.reload` replaces the verified old subscriber from the Herdr previous-checkout path with the new target/release binary without restarting Herdr or touching unrelated panes.", "A foreign lock holder with spoofed plugin environment, wrong socket/state/uid, arbitrary executable or lookalike previous-checkout path is refused without a signal; tests cover managed replacement and refusal.", "Read-only doctor reports healthy with one subscriber whose executable path and hash match the registered managed checkout after reload."]
  claimedAt: "2026-09-24T14:28:19Z"
  validation: ["$ just test", "$ git diff --check"]
  updatedAt: "2026-09-24T14:28:19Z"
createdAt: "2026-09-24T14:28:09Z"
updatedAt: "2026-09-24T14:28:19Z"
assignee: "orchestrator"
---

## Description

Herdr 0.9.1 `plugin install ... --ref <new SHA>` atomically moves the previous managed checkout under `plugins/.tmp-install-<pid>-<timestamp>/previous-checkout`, deletes it, and leaves the old subscriber running from `.../target/release/agent-tree (deleted)`. The current `agent-tree.reload` refuses that holder even when its plugin id, socket, state dir and managed root match, so routine source updates leave the plugin degraded. Fix the narrow trust boundary for the Herdr-owned previous-checkout location and prove a reload safely replaces exactly that holder; no blanket acceptance of spoofed process environment or arbitrary binaries.
