---
id: task-21
type: task
title: "Allow verified subscriber replacement after Herdr-managed source reinstall"
priority: "high"
effort: "medium"
references: ["task-8-2"]
relatedFiles: ["src/lifecycle.rs", "tests/shell/dev-reload.sh"]
tags: ["bug", "release-blocker", "source-install", "lifecycle"]
accord:
  status: "accepted"
  acceptance: ["A managed Herdr source reinstall from an exact ref followed by `agent-tree.reload` replaces the verified old subscriber from the Herdr previous-checkout path with the new target/release binary without restarting Herdr or touching unrelated panes.", "A foreign lock holder with spoofed plugin environment, wrong socket/state/uid, arbitrary executable or lookalike previous-checkout path is refused without a signal; tests cover managed replacement and refusal.", "Read-only doctor reports healthy with one subscriber whose executable path and hash match the registered managed checkout after reload."]
  claimedAt: "2026-09-24T14:28:19Z"
  deliveredAt: "2026-09-24T14:37:02Z"
  validation: ["$ just test", "$ git diff --check"]
  summary: "Managed source reinstall now accepts only the exact Herdr previous-checkout executable location under the same plugin registry as the current managed binary, while preserving UID/ID/socket/state-dir/argv verification and rejecting other locations. The live laptop reinstall of cb630ad replaced the previously stranded subscriber safely."
  evidence: ["just test passed full gate including 46 Rust tests, clean source build, hermetic dev reload, endpoint doctor, deploy suites and isolated sidebar/toggle E2E. tests/shell/dev-reload.sh: managed previous-checkout live subscriber replaced; foreign spoofed environment and lookalike previous-checkout refused without signal.", "git diff --check passed. Changes committed as ef71d26 and GitHub ref cb630ad5b58815618ab4479da6ba8aff94ad6e14.", "Laptop Herdr 0.9.1 managed GitHub install resolved cb630ad5b58815618ab4479da6ba8aff94ad6e14 with manifest locked release build. agent-tree.reload log plugin-log-263 succeeded and replaced old pid 908799 with pid 1391846; old exited. No Herdr server restart or unrelated panes changed.", "Read-only laptop doctor: source_kind=github, prefix+t and sidebar row present, registered target/release/agent-tree SHA 7fa5f2af13e6441255a6bde02bcaf99fd9f16b675629bf34d5665d6f9d79faf0 equals sole pid 1391846 /proc executable hash and exact path, verdict healthy."]
  filesChanged: ["src/lifecycle.rs", "tests/shell/dev-reload.sh", "CHANGELOG.md"]
  reviewer: "orchestrator"
  updatedAt: "2026-09-24T14:37:07Z"
createdAt: "2026-09-24T14:28:09Z"
updatedAt: "2026-09-24T14:37:07Z"
assignee: "orchestrator"
archivedAt: "2026-09-24T14:37:07Z"
resolution:
  outcome: "completed"
  reviewer: "orchestrator"
---

## Description

Herdr 0.9.1 `plugin install ... --ref <new SHA>` atomically moves the previous managed checkout under `plugins/.tmp-install-<pid>-<timestamp>/previous-checkout`, deletes it, and leaves the old subscriber running from `.../target/release/agent-tree (deleted)`. The current `agent-tree.reload` refuses that holder even when its plugin id, socket, state dir and managed root match, so routine source updates leave the plugin degraded. Fix the narrow trust boundary for the Herdr-owned previous-checkout location and prove a reload safely replaces exactly that holder; no blanket acceptance of spoofed process environment or arbitrary binaries.
