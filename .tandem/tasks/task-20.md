---
id: task-20
type: task
title: "Make doctor verify Herdr-managed source-install executables correctly"
state: todo
priority: "high"
effort: "medium"
references: ["task-8", "task-8-2"]
relatedFiles: ["scripts/doctor.sh", "scripts/lib/probe.py", "tests/shell/doctor.sh"]
tags: ["bug", "doctor", "source-install", "release-blocker"]
accord:
  status: "ready"
  acceptance: ["For a Herdr-managed GitHub source install, doctor verifies the built `target/release/agent-tree` executable and reports healthy when the sole subscriber runs that exact binary.", "The staged development install continues to require the staged `src/agent-tree` binary and rejects a foreign or mismatched subscriber.", "Shell tests cover a healthy managed source install, a healthy staged development install, and a genuine executable mismatch."]
  validation: ["$ tests/shell/doctor.sh", "$ git diff --check"]
  updatedAt: "2026-09-22T01:05:03Z"
createdAt: "2026-09-22T01:05:03Z"
updatedAt: "2026-09-22T01:05:03Z"
---

## Description

A standard GitHub source install keeps `src/agent-tree` as the launcher but runs `target/release/agent-tree`. The current endpoint doctor hashes the launcher and compares it with `/proc/<pid>/exe`, so a correct managed install is falsely reported as degraded. Teach doctor to resolve and verify the executable appropriate to the registered install type while preserving the strict staged-development identity check.
