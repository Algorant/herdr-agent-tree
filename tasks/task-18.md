---
id: task-18
uid: dc073b68-247d-49c7-bc45-095d9dd71dd1
type: task
kind: "papercut"
title: "deploy.sh --uninstall leaves the staged subscriber running"
state: todo
priority: "low"
relatedFiles: ["scripts/deploy.sh"]
accord:
  status: "ready"
  acceptance: ["After `scripts/deploy.sh --uninstall`, no `agent-tree subscriber` process from the staged root is left running, or the script fails clearly naming the surviving pid."]
  updatedAt: "2026-10-20T17:07:55Z"
createdAt: "2026-10-20T17:07:55Z"
updatedAt: "2026-10-20T17:07:55Z"
---

## Description

Observed on worktop on 2026-10-20 while switching from the staged dev build to the managed v0.5.0. `scripts/deploy.sh --uninstall` printed cleared/disabled/unregistered/Done, but the staged subscriber (pid 3520778, ~/.local/share/herdr-agent-tree/stage/src/agent-tree) kept running. A managed `reload` would then refuse it as a foreign holder, so it had to be killed by hand before installing the managed release. The script reports success while leaving a live subscriber.
