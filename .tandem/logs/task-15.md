---
id: task-15
type: task
title: "Make toggle E2E sidebar-order parsing UTF-8-safe"
priority: "high"
effort: "small"
relatedFiles: ["tests/e2e/toggle.sh"]
tags: ["test", "papercut"]
accord:
  status: "accepted"
  acceptance: ["`tests/e2e/toggle.sh` recognizes the decorated `sub-alpha` row and asserts the actual sidebar order without matching content from the main pane.", "The isolated toggle end-to-end test passes without weakening its ordering assertions."]
  claimedAt: "2026-09-20T14:44:15Z"
  deliveredAt: "2026-09-20T14:48:18Z"
  validation: ["$ tests/e2e/toggle.sh"]
  constraints: ["Keep the change limited to the test parser; do not change plugin behavior or production code."]
  summary: "Made the toggle E2E sidebar-order parser UTF-8-safe in tests/e2e/toggle.sh only. Added a `sidebar_region` helper that slices the first 31 characters of each captured line (the sidebar border is the 32nd character), replacing the byte-oriented `cut -c1-31` inside `order_after_header`. The decorated row `○ └─S ? · π - sub-alpha` now survives to grep, so the three-row ordering assertions run against the real sidebar and the isolated test passes. No production code or assertions were changed."
  evidence: ["tests/e2e/toggle.sh recognizes the decorated sub-alpha row and asserts the actual sidebar order without matching content from the main pane.: With the fix, order_after_header on the real capture returns root-alpha,sub-alpha,lone-1. The sidebar region is the first 31 characters (border `│` at character index 31 / column 32), so the main pane's `/tmp/.../work/lone-1` text is excluded; the legacy byte cut on the same bytes returned root-alpha,lone-1 because it truncated `sub-alpha` to `sub-alph`.", "The isolated toggle end-to-end test passes without weakening its ordering assertions.: `tests/e2e/toggle.sh` exited 0 with the ordering assertions unchanged: tree `root-alpha,sub-alpha,lone-1`, native `lone-1,root-alpha,sub-alpha`, and tree again `root-alpha,sub-alpha,lone-1`; all later shortcut, decoration, mouse, foreign-owner, clear and config checks also passed.", "Change limited to the test parser; plugin/production behavior unchanged.: git diff touches only tests/e2e/toggle.sh (+12/-1, replacing cut -c1-31 in order_after_header with the sidebar_region helper); no src/ or production files changed."]
  filesChanged: ["tests/e2e/toggle.sh"]
  updatedAt: "2026-09-20T14:48:18Z"
createdAt: "2026-09-20T14:44:07Z"
updatedAt: "2026-09-20T14:48:18Z"
assignee: "worker-task-15-dc86afdf"
archivedAt: "2026-09-20T14:48:18Z"
resolution:
  outcome: "completed"
---

## Description

The native `tests/e2e/toggle.sh` validation now fails on both main and the task-14 branch even though the captured sidebar visibly contains `root-alpha`, decorated `sub-alpha`, and `lone-1` in the correct order. `order_after_header` truncates with `cut -c1-31`; GNU cut counts UTF-8 bytes, so the multibyte `○ └─S · π` decoration truncates `sub-alpha` to `sub-alph` before grep. Fix the parser narrowly so it inspects the sidebar region without losing valid decorated names or matching the main pane.
