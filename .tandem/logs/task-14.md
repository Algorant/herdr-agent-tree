---
id: task-14
type: task
title: "Make Agent Tree deployment and diagnostics endpoint-complete"
priority: "high"
effort: "medium"
relatedFiles: ["scripts/deploy.sh", "scripts/release/install.sh", "scripts/stage-local.sh", "scripts/check.sh", "README.md", "herdr-plugin.toml"]
tags: ["deployment", "diagnostics", "multi-machine"]
accord:
  status: "accepted"
  acceptance: ["A supported command deploys the current Agent Tree build to an explicitly named Herdr endpoint such as `archbox`, stages a self-contained plugin root there, registers/enables it, and returns only after the endpoint runs the staged binary.", "Remote deployment verifies target architecture, Herdr protocol/version compatibility, plugin action registration, one stable subscriber, and matching build/staged/running SHA-256; failure identifies the exact phase and preserves the prior valid installation/configuration.", "A read-only doctor accepts explicit local and remote endpoints and reports for each: Herdr reachability/version, plugin registration and source, staged/running hashes, subscriber count, toggle action availability, shortcut presence, sidebar `$agent_tree_row` presence, relationship-bearing pane count, ranked pane count, and delegated-looking panes missing relationship metadata.", "Doctor output clearly identifies the observed split state where The-Desktop is healthy while `archbox` has a shortcut but no plugin, and never implies that a TUI-selected machine retargets local CLI commands.", "The existing local `just deploy`, rollback behavior, foreign sidebar-block protection, and no-server-restart guarantee remain intact.", "Direct live evidence shows local and `archbox` endpoints each toggle independently and a newly created delegated child on either endpoint can be ranked by that endpoint's plugin."]
  claimedAt: "2026-09-20T14:48:53Z"
  deliveredAt: "2026-09-20T15:20:03Z"
  validation: ["$ git diff --check", "$ just test", "$ just build"]
  constraints: ["Do not restart either Herdr server or disturb unrelated panes.", "Do not infer endpoint ownership or parent relationships from titles, names, cwd, or TUI focus.", "Do not overwrite a foreign `[ui.sidebar.agents]` block or an occupied shortcut.", "Do not assume local and remote architectures match; detect and fail clearly when no compatible build is available.", "Do not copy credentials or Pi session files between machines.", "Keep deployment reversible and safe to rerun; preserve the previous valid staged plugin/config on failure."]
  summary: "Implemented explicit endpoint deployment and read-only endpoint doctor, preserving the existing local deploy path. The deployment performs compatibility/architecture/loader checks, transactional staging and registration, terminal reload verification, and exact build/staged/running subscriber hash checks. Doctor reports endpoint-specific plugin, config, subscriber, pane-relationship and ranking state with explicit routing. Final uninstall corrections now refuse concurrent config edits byte-for-byte and treat stage cleanup failures as rollback-triggering failures. Hermetic endpoint deploy/doctor suites and all isolated E2E validations pass; retained prior live evidence covers independent local/archbox deployment, toggling and child ranking without server restart."
  evidence: ["AC1: scripts/deploy-endpoint.sh requires an explicit endpoint, stages a self-contained root, links/enables it, waits for terminal reload status, and verifies one running staged subscriber; endpoint deploy scenarios 1, 12 and 17/18 pass. Retained prior live evidence: `deploy-endpoint archbox --yes` completed only after archbox ran the staged binary.", "AC2: preflight checks Herdr compatibility/version, target architecture and loader execution; verify_subscriber enforces one subscriber and matching build/staged/running SHA. Failure/rollback scenarios 3, 4, 6-9 pass. Retained prior live evidence recorded SHA 0a7e7a77... on archbox with server PID 217697 unchanged.", "AC3: tests/shell/doctor.sh passes 7/7 and covers explicit local/remote endpoints, Herdr/version/protocol, registration/source, hashes, subscriber count, toggle, shortcut, sidebar token, relationship/rank and incomplete-delegation counts; the doctor remains read-only.", "AC4: doctor scenarios 2-4 identify the local-healthy/archbox-degraded split and prove label, SSH target and profile ID explicit resolution while ignoring TUI selection. Retained prior live observation showed archbox shortcut/sidebar present but plugin absent before deployment.", "AC5: scripts/deploy.sh and the local deploy recipe remain unchanged; foreign sidebar/shortcut refusal and rollback suites pass; no server restart path is used. New scenarios 23-24 prove uninstall preserves concurrent user config bytes exactly and hard stage-deletion failures restore registration, config, stage and subscriber without false success.", "AC6: Retained prior live evidence showed local and archbox toggled independently and were restored; a new credential-empty real Pi child on each endpoint received rank 000002 and row `└─S`, then fixtures were closed. Current isolated sidebar/toggle E2E suites also pass.", "Native validations independently rerun in the Worker checkout: `git diff --check` exit 0; `just test` exit 0 with doctor 1..7, endpoint deploy 1..25, deploy/reload, sidebar and toggle E2E all passing; `just build` exit 0."]
  filesChanged: [".gitignore", "CHANGELOG.md", "README.md", "justfile", "scripts/check.sh", "scripts/deploy-endpoint.sh", "scripts/doctor.sh", "scripts/lib/config.py", "scripts/lib/endpoint.sh", "scripts/lib/probe.py", "scripts/lib/report.py", "scripts/lib/stop.py", "tests/shell/deploy-endpoint.sh", "tests/shell/dev-reload.sh", "tests/shell/doctor.sh"]
  reviewer: "orchestrator"
  updatedAt: "2026-09-20T15:20:07Z"
createdAt: "2026-09-19T14:22:48Z"
updatedAt: "2026-09-20T15:20:07Z"
assignee: "worker-task-14-b2ce38bf"
archivedAt: "2026-09-20T15:20:07Z"
resolution:
  outcome: "completed"
  reviewer: "orchestrator"
---

## Description

Agent Tree is working on The-Desktop, but the saved `cart-lab`/`archbox` Herdr endpoint has the shortcut config and no Agent Tree plugin installed. The current development deploy path is local-only and gives no endpoint-wide diagnosis, so a multi-machine TUI can show a working tree for one endpoint and permanently flat rows for another without explaining why.

Add one supported, repeatable path for deploying the current reviewed build to a named Herdr endpoint and one read-only doctor that reports endpoint-specific readiness. The implementation must preserve the existing local `just deploy` path and must not treat a TUI-selected machine as CLI routing; every target must be explicit. Prove the path on The-Desktop and `archbox` without restarting either Herdr server.
