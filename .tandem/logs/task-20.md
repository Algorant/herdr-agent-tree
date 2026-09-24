---
id: task-20
type: task
title: "Make doctor verify Herdr-managed source-install executables correctly"
priority: "high"
effort: "medium"
references: ["task-8", "task-8-2"]
relatedFiles: ["scripts/doctor.sh", "scripts/lib/probe.py", "tests/shell/doctor.sh"]
tags: ["bug", "doctor", "source-install", "release-blocker"]
accord:
  status: "accepted"
  acceptance: ["For a Herdr-managed GitHub source install, doctor verifies the built `target/release/agent-tree` executable and reports healthy when the sole subscriber runs that exact binary.", "The staged development install continues to require the staged `src/agent-tree` binary and rejects a foreign or mismatched subscriber.", "Shell tests cover a healthy managed source install, a healthy staged development install, and a genuine executable mismatch."]
  claimedAt: "2026-09-24T14:25:03Z"
  deliveredAt: "2026-09-24T14:25:10Z"
  validation: ["$ tests/shell/doctor.sh", "$ git diff --check"]
  summary: "Doctor now resolves Herdr-managed GitHub installs to target/release/agent-tree and development local installs to src/agent-tree; it verifies both live executable path and SHA-256, reports unsupported source kinds as issues, and labels the report as registered executable rather than staged binary."
  evidence: ["tests/shell/doctor.sh: 11 hermetic checks passed, including healthy managed source, healthy staged development, changed registered binary mismatch, same-hash foreign executable mismatch, remote split state and read-only config.", "just test: all project gates passed including Rust tests, source-install smoke, endpoint/deploy suites, and isolated Herdr sidebar/toggle end-to-end.", "Read-only live doctor against saved laptop endpoint after fix: source_kind=github; registered target/release/agent-tree SHA 6419632067ff2ac003a0ebe5fbff4b593a524f6b3367191dc982bc034e7503a5 equals sole subscriber pid 908799 /proc exe hash and path; verdict healthy; prefix+t and sidebar token present.", "git diff --check passed; source commit 921988a."]
  filesChanged: ["scripts/doctor.sh", "scripts/lib/report.py", "tests/shell/doctor.sh", "README.md"]
  reviewer: "orchestrator"
  updatedAt: "2026-09-24T14:25:13Z"
createdAt: "2026-09-22T01:05:03Z"
updatedAt: "2026-09-24T14:25:13Z"
assignee: "orchestrator"
archivedAt: "2026-09-24T14:25:13Z"
resolution:
  outcome: "completed"
  reviewer: "orchestrator"
---

## Description

A standard GitHub source install keeps `src/agent-tree` as the launcher but runs `target/release/agent-tree`. The current endpoint doctor hashes the launcher and compares it with `/proc/<pid>/exe`, so a correct managed install is falsely reported as degraded. Teach doctor to resolve and verify the executable appropriate to the registered install type while preserving the strict staged-development identity check.
