---
id: task-14
uid: 119c0e18-5d5b-440e-8607-06c4d9dcbe19
type: task
title: "Managed upgrade leaves the old subscriber running and the install docs omit --yes"
priority: "low"
effort: "small"
relatedFiles: ["README.md", "scripts/activate-managed.sh"]
tags: ["papercut", "plan-first"]
accord:
  status: "accepted"
  acceptance: ["README Install/Update document that non-interactive `herdr plugin install` needs `--yes`", "Upgrading a managed install with an older live subscriber via the documented steps ends with the doctor reporting a SHA-matching subscriber, without needing a separate undocumented reload"]
  claimedAt: "2026-10-20T16:48:54Z"
  deliveredAt: "2026-10-20T17:04:13Z"
  summary: "activate-managed.sh now reloads (replacing the verified old subscriber); reload trusts Herdr 0.9.5 sibling install ids; the install docs include --yes. A live double reinstall follows the v0.5.0 release."
  evidence: ["Worker commit d3210c9; the orchestrator read the diff (activate-managed.sh reload, lifecycle.rs is_other_install for the 0.9.5 github-installations/agent-tree-<hash>/<id>/checkout layout, --yes in README/docs/release.md)", "Orchestrator-run `just test` with real tmux in the Worker checkout: All checks passed (sidebar, toggle and deploy-reload e2e passed)"]
  filesChanged: ["src/lifecycle.rs", "scripts/activate-managed.sh", "README.md", "docs/release.md", "tests/shell/activate-managed.sh", "CHANGELOG.md"]
  updatedAt: "2026-10-20T17:04:17Z"
createdAt: "2026-10-03T03:04:32Z"
updatedAt: "2026-10-20T17:04:17Z"
assignee: "worker-task-14-b791b18c"
archivedAt: "2026-10-20T17:04:17Z"
resolution:
  outcome: "completed"
---

## Description

Observed upgrading the live dellmini install from v0.2.0 to v0.4.0 per README 'Install'/'Update': (1) `herdr plugin install Algorant/herdr-agent-tree --ref v0.4.0` fails non-interactively with 'remote plugin install requires --yes when stdin is not interactive'. (2) After a successful reinstall, `scripts/activate-managed.sh` (apply) reported success, but the old v0.2.0 subscriber pid kept running; the doctor reported 'degraded: running subscriber path or SHA-256 does not match'. Legacy rows were only cleared after a manual `herdr plugin action invoke agent-tree.reload`.
