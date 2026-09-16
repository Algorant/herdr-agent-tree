---
id: task-6
type: task
title: "Add a safe latest-checkout dogfood reload workflow"
state: "in-progress"
priority: "high"
effort: "medium"
relatedFiles: ["justfile", "scripts/deploy.sh", "src/lifecycle.rs", "src/main.rs", "herdr-plugin.toml", "README.md", "tests/shell"]
tags: ["development", "dogfood", "lifecycle"]
accord:
  status: "claimed"
  acceptance: ["`just deploy` rebuilds and stages the latest code, registers that stage, and leaves exactly one subscriber running from the new staged build.", "Repeating `just deploy` replaces an older live subscriber safely; a dead/stale lock is recovered, while an unverifiable or foreign lock holder fails clearly without signaling it.", "The workflow clears the paused state when applying the new build and confirms that the projection pass succeeded.", "A user-owned sidebar configuration is preserved byte-for-byte; when it lacks `$agent_tree_row`, the workflow prints the exact fragment or edit required for the tree to render.", "Automated isolated coverage exercises first install, repeated reload, stale-lock handling, foreign-holder refusal and cleanup without a running live Herdr server.", "README.md documents `just deploy` as the sole rapid checkout dogfood loop and distinguishes it from release installation and inert local staging."]
  claimedAt: "2026-09-16T17:46:11Z"
  validation: ["$ git diff --check", "$ just test", "$ ./tests/shell/dev-reload.sh"]
  constraints: ["Never kill a PID based only on an unverified integer from a lock file; verify plugin ownership, socket scope and process identity before signaling it.", "Do not restart or stop the whole Herdr server as the normal iteration path.", "Do not overwrite a user-owned [ui.sidebar.agents] block or silently substitute a row layout.", "Do not weaken the single-subscriber lock or create a second supervisor/reconnect path.", "Tests must use isolated state/processes and must not touch the live Herdr socket, config or installed plugin."]
  updatedAt: "2026-09-16T17:46:11Z"
createdAt: "2026-09-16T12:39:00Z"
updatedAt: "2026-09-16T17:46:11Z"
blockers: ["task-9"]
assignee: "worker-task-6-06e2f08c"
---
After task-9 establishes `just deploy` and `scripts/deploy.sh`, strengthen that workflow so it reliably replaces the long-lived subscriber. Restaging alone does not replace an already-running subscriber: the old in-memory binary can continue holding subscriber-<socket>.lock, the new apply action performs only one pass, and later events return to old code. `just deploy` must build, stage, register, and guarantee that the sole subscriber is the newly staged build without restarting the whole Herdr server or disturbing panes. A user-owned [ui.sidebar.agents] block must remain untouched; the workflow reports the exact row fragment needed when `$agent_tree_row` is absent.