---
id: task-16
type: task
title: "Replace the unreliable Alt-based tree toggle shortcut"
priority: "high"
effort: "medium"
relatedFiles: ["scripts/lib/config.py", "scripts/deploy-endpoint.sh", "scripts/lib/report.py", "tests/e2e/toggle.sh", "tests/shell/deploy-endpoint.sh", "tests/shell/doctor.sh", "README.md", "CHANGELOG.md"]
tags: ["keybinding", "deployment", "ux"]
accord:
  status: "accepted"
  acceptance: ["The canonical Agent Tree toggle shortcut is `prefix+t`, with no Alt/Meta dependency, and documentation explains the exact `Ctrl+B`, release, `t` sequence.", "Endpoint config inspection and deployment report/check/install `prefix+t`; an existing managed Agent Tree shortcut is migrated idempotently, while a foreign `prefix+t` binding is refused without mutation.", "The real-PTY toggle E2E drives `prefix+t` and proves tree-to-native and native-to-tree behavior; doctor and deployment suites expect the new key.", "The local live config can be updated to one effective `prefix+t` Agent Tree binding and reloaded without restarting Herdr."]
  claimedAt: "2026-09-20T19:54:26Z"
  deliveredAt: "2026-09-20T20:52:31Z"
  validation: ["$ git diff --check", "$ just test", "$ just build"]
  constraints: ["Do not change the owner-safe toggle semantics or plugin executable behavior.", "Do not occupy or overwrite any foreign shortcut.", "Do not restart Herdr."]
  summary: "Replaced the unreliable Alt-dependent Agent Tree shortcut with canonical `prefix+t` across endpoint config management, doctor reporting, documentation and real-PTY tests. Managed legacy bindings migrate idempotently, foreign `prefix+t` collisions fail without mutation, and the live local config now has exactly one `prefix+t` toggle binding reloaded without a Herdr restart."
  evidence: ["scripts/lib/config.py now defines `prefix+t`; managed legacy `prefix+alt+t` fragments migrate idempotently, while a foreign `prefix+t` binding is refused before output or endpoint mutation.", "The real-PTY E2E sends Ctrl+B followed by literal t and passes tree-to-native, native-to-tree, retained-decoration, native-header and foreign-owner assertions.", "Doctor and deploy suites pass 8/8 and 26/26, including legacy-key reporting, managed migration, idempotency, and byte-for-byte collision refusal.", "Native validations passed independently: `git diff --check`, `just test` ending All checks passed, and `just build`, all exit 0.", "Live verification: `herdr config check` reports config ok; parsed config contains exactly one Agent Tree binding at `prefix+t` and no legacy toggle binding; local doctor reports shortcut present prefix+t and verdict healthy. Config was reloaded without restarting Herdr."]
  filesChanged: ["CHANGELOG.md", "README.md", "scripts/lib/config.py", "tests/e2e/toggle.sh", "tests/shell/deploy-endpoint.sh", "tests/shell/doctor.sh"]
  reviewer: "orchestrator"
  updatedAt: "2026-09-20T20:52:34Z"
createdAt: "2026-09-20T19:54:18Z"
updatedAt: "2026-09-20T20:52:34Z"
assignee: "worker-task-16-4e5b7deb"
archivedAt: "2026-09-20T20:52:34Z"
resolution:
  outcome: "completed"
  reviewer: "orchestrator"
---

## Description

The documented and endpoint-managed `prefix+alt+t` shortcut does not fire in Algorant's live terminal, although invoking `agent-tree.toggle` directly works. Replace the canonical shortcut with `prefix+t`: Herdr 0.9.1 documents `prefix+t` as valid custom-command syntax, it avoids terminal-dependent Alt/Meta delivery, it is distinct from the built-in `prefix+shift+t` rename-tab binding, and it is unoccupied in the current config. Update deployment management, doctor reporting, documentation and tests so future endpoint deploys install or migrate to the reliable key.
