---
id: task-3
type: task
title: "Correct stale documentation after the repository split"
state: todo
priority: "low"
effort: "small"
relatedFiles: ["README.md", "docs/agent-tree/m1-evidence.md", "docs/agent-tree/m2-contract.md"]
tags: ["documentation", "papercut"]
accord:
  status: "ready"
  acceptance: ["README.md no longer claims the plugin has never been installed on a live server, and describes its actual status accurately.", "Paths in current instructions resolve correctly in this repository.", "Historical evidence and contract documents remain historical, with any retained monorepo-era wording explicitly marked as describing the layout at that time.", "Any documentation directory restructuring preserves the meaning of historical references."]
  validation: ["$ git diff --check"]
  constraints: ["Do not rewrite the evidence or contract records to match the present layout; mark them as historical instead.", "Do not change plugin behaviour or any script logic in this Task.", "Do not remove documented limitations or caveats while tidying."]
  updatedAt: "2026-09-16T01:24:12Z"
createdAt: "2026-09-16T01:24:12Z"
updatedAt: "2026-09-16T01:24:12Z"
---

## Description

## Problem

Documentation carried over from the original monorepo now contains statements that are false or path-inaccurate.

Known items, verify and look for others:

1. `README.md` still says the plugin "has not been installed or enabled on a live server." It has been installed and enabled on Algorant's live Herdr server since 2026-09-15, and the toggle and tree were verified there. A previous Worker correctly left this alone as out of scope for a build-path Task.
2. `docs/agent-tree/m2-contract.md` still refers to `plugins/agent-tree/...` paths from the monorepo layout. Where that text records the historical layout at the time the contract was agreed, leave it factual and say so; where it would mislead someone working in this repository today, correct it.
3. `docs/agent-tree/m1-evidence.md` and the contract describe the evidence and decisions behind the MVP. They are a historical record and should stay one; do not rewrite history to match the present.
4. The docs live under `docs/agent-tree/` in a repository that is entirely about agent-tree. Consider flattening to `docs/`, but only if it does not damage the historical references.

## Judgment required

The distinction that matters: a historical record should read as historical, and current instructions should be correct. Do not blur the two by silently editing evidence documents to match today's layout.

