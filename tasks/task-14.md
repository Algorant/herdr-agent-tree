---
id: task-14
uid: 119c0e18-5d5b-440e-8607-06c4d9dcbe19
type: task
title: "Managed upgrade leaves the old subscriber running and the install docs omit --yes"
state: todo
priority: "low"
effort: "small"
relatedFiles: ["README.md", "scripts/activate-managed.sh"]
tags: ["papercut"]
accord:
  status: "ready"
  acceptance: ["README Install/Update document that non-interactive `herdr plugin install` needs `--yes`", "Upgrading a managed install with an older live subscriber via the documented steps ends with the doctor reporting a SHA-matching subscriber, without needing a separate undocumented reload"]
  updatedAt: "2026-10-03T03:04:32Z"
createdAt: "2026-10-03T03:04:32Z"
updatedAt: "2026-10-03T03:04:32Z"
---

## Description

Observed upgrading the live dellmini install from v0.2.0 to v0.4.0 per README 'Install'/'Update': (1) `herdr plugin install Algorant/herdr-agent-tree --ref v0.4.0` fails non-interactively with 'remote plugin install requires --yes when stdin is not interactive'. (2) After a successful reinstall, `scripts/activate-managed.sh` (apply) reported success, but the old v0.2.0 subscriber pid kept running; the doctor reported 'degraded: running subscriber path or SHA-256 does not match'. Legacy rows were only cleared after a manual `herdr plugin action invoke agent-tree.reload`.
