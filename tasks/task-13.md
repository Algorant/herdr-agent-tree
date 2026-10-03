---
id: task-13
uid: aed22243-17a2-4634-869c-c6a9f42d94b7
type: task
title: "[throwaway] Live agent-tree nesting smoke test Worker"
state: todo
priority: "low"
tags: ["smoke-test"]
accord:
  status: "ready"
  acceptance: ["Worker launches one read-only Subagent and reports needs-input without changing any files"]
  updatedAt: "2026-10-03T03:03:10Z"
createdAt: "2026-10-03T03:03:10Z"
updatedAt: "2026-10-03T03:03:27Z"
effort: "trivial"
---

## Description

Disposable task used only to exercise live Agent Tree nesting (root → Worker → Subagent). The Worker will be discarded and this task canceled afterward. No code changes.
