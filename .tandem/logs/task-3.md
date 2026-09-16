---
id: task-3
type: task
title: "Correct stale documentation after the repository split"
priority: "low"
effort: "small"
relatedFiles: ["README.md", "docs/agent-tree/m1-evidence.md", "docs/agent-tree/m2-contract.md"]
tags: ["documentation", "papercut"]
accord:
  status: "accepted"
  acceptance: ["README.md no longer claims the plugin has never been installed on a live server, and describes its actual status accurately.", "Paths in current instructions resolve correctly in this repository.", "Historical evidence and contract documents remain historical, with any retained monorepo-era wording explicitly marked as describing the layout at that time.", "Any documentation directory restructuring preserves the meaning of historical references."]
  claimedAt: "2026-09-16T02:15:07Z"
  deliveredAt: "2026-09-16T02:18:26Z"
  validation: ["$ git diff --check"]
  constraints: ["Do not rewrite the evidence or contract records to match the present layout; mark them as historical instead.", "Do not change plugin behaviour or any script logic in this Task.", "Do not remove documented limitations or caveats while tidying."]
  summary: "Documentation-only correction of stale post-split statements. README.md now states the actual live status (installed and enabled on Algorant's live Herdr server since 2026-09-15 from the staged release root produced by install.sh; toggle and tree verified there), drops the stale `\"What is verified\"` cross-reference, removes the misleading \"root `herdr-notifs-plus`\" wording, reframes limitation 5 as a Worker-recovery caveat that has since been through the live enable rather than an open gate, and retitles the unverified list around the live install. docs/agent-tree/m1-evidence.md and m2-contract.md each gained a \"Historical record\" banner stating they come from the repository now named Algorant/herdr-notifs-plus, with inline markers on the monorepo crate path (C1) and the M3 validation command (C12); agreed/evidence content is otherwise unchanged. docs/agent-tree/ was deliberately not flattened. No scripts, runtime code, manifests or config were touched."
  evidence: ["README.md no longer claims the plugin has never been installed on a live server, and describes its actual status accurately.: README status paragraph now reads: observed in an isolated Herdr 0.9.0 server (see \"Verified behavior\"), and \"The plugin has also been installed and enabled on Algorant's live Herdr server since 2026-09-15, from the staged release root that `install.sh` produces; the toggle and the tree were verified there.\" No paused/transient state is encoded. grep for the old claim returns nothing.", "Paths in current instructions resolve correctly in this repository.: All README-relative paths (`./demo.sh`, `./install.sh`, `./src/agent-tree`, `target/release/agent-tree`, `docs/agent-tree/m1-evidence.md`) exist or are build-output/install-target paths; the stale `\"What is verified\"` ref was corrected to the existing `Verified behavior` section; the monorepo-era \"root `herdr-notifs-plus` plugin\" wording was fixed to \"the `herdr-notifs-plus` plugin\". `git diff --check` exit 0.", "Historical evidence and contract documents remain historical, with any retained monorepo-era wording explicitly marked as describing the layout at that time.: m1-evidence.md and m2-contract.md each open with a `> **Historical record.**` banner that says they were gathered/agreed while the plugin lived in the repository now named Algorant/herdr-notifs-plus and that paths, commits, commands and prerequisites describe that time. C1 now marks `plugins/agent-tree/` as the monorepo path; C12 marks the proposed file list and the `--manifest-path plugins/agent-tree/Cargo.toml` validation as those of the time. No agreed rule, evidence statement, or limitation was rewritten or removed.", "Any documentation directory restructuring preserves the meaning of historical references.: No restructuring was performed: `docs/agent-tree/` and both files remain in place (`ls docs docs/agent-tree`), so every existing historical reference (README and M2 both point at `docs/agent-tree/m1-evidence.md`) still resolves. Flattening was judged unnecessary because the repository-wide path is referenced from several documents."]
  filesChanged: ["README.md", "docs/agent-tree/m1-evidence.md", "docs/agent-tree/m2-contract.md"]
  updatedAt: "2026-09-16T02:18:26Z"
createdAt: "2026-09-16T01:24:12Z"
updatedAt: "2026-09-16T02:18:26Z"
assignee: "worker-task-3-2fefc59d"
archivedAt: "2026-09-16T02:18:26Z"
resolution:
  outcome: "completed"
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

