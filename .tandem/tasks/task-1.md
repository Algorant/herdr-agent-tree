---
id: task-1
type: task
title: "Add a real test suite for agent-tree"
state: "in-progress"
effort: "medium"
relatedFiles: ["src/identity.rs", "src/forest.rs", "src/decoration.rs", "src/pause.rs", "README.md", "docs/agent-tree/m2-contract.md"]
tags: ["release-readiness", "testing"]
accord:
  status: "claimed"
  acceptance: ["The identity rules are covered: hash recomputation, agency_self self-validation, unique parent resolution, and the tokenless-parent refinement.", "Every degenerate case in the contract C5 table has a test asserting the agent is left unlinked.", "Preorder emission, family contiguity, deterministic sibling order and unranked native ordering are covered.", "Rank format and decoration grammar are covered, including the 20-character cap and its drop order.", "Paused behaviour is covered: paused publishes nothing, apply clears the flag, clear does not.", "The suite runs with a single documented command and needs no running Herdr server.", "The suite passes and the command is recorded in README.md."]
  claimedAt: "2026-09-16T02:07:00Z"
  validation: ["$ git diff --check", "$ cargo test --locked"]
  constraints: ["No Herdr server harness and no dependency on a live or isolated server; demo.sh remains the end-to-end path.", "Do not change plugin behaviour to make it testable without saying so explicitly and justifying it.", "Keep test dependencies minimal; prefer the standard test harness over adding crates."]
  updatedAt: "2026-09-16T02:07:00Z"
createdAt: "2026-09-16T01:23:25Z"
updatedAt: "2026-09-16T02:07:00Z"
assignee: "worker-task-1-0ec8d999"
---

## Description

## Problem

This plugin has no tests. The focused harness written during the original implementation was explicitly temporary and deleted before delivery, under a constraint against permanent harness expansion for the MVP. That was right for an MVP and is wrong for a release.

Everything currently rests on observation in an isolated Herdr instance. That caught real defects, but it is not repeatable in CI and does not protect the identity rules against future edits.

## What matters most

The identity and placement rules are where a silent regression would be worst, because a wrong parent edge produces a confident, wrong tree rather than an obvious failure. Cover at least:

- Hash recomputation: byte-exact compact JSON tuple, lowercase hex, no path trimming or canonicalization, no hash truncation.
- Self-validation: `agency_self` must match the recomputed identity before any relationship metadata is trusted.
- Parent-edge validation, including the refinement where a parent carrying no tokens is validated through a validated child's `agency_parent`.
- Every degenerate case from the contract C5 table, each resolving to unlinked: missing, malformed, mismatched, duplicate, self-link, dangling, ambiguous, cycle, stale. Duplicate detection was already caught as a real defect by the temporary harness, so the risk is demonstrated rather than hypothetical.
- Preorder emission: parent before descendants, family contiguity, deterministic sibling order, unranked rows keeping native relative order.
- Rank format: 6-digit zero padding, lexicographic order equal to numeric order, no publication above the documented ceiling.
- Decoration grammar: 20-character cap, drop order task then attention then indent collapse, branch and role never dropped, never emits leading whitespace, never emits a hash, path, routing id, delivery id or report content.
- Paused behaviour: paused publishes nothing and sets no view; `apply` clears the flag; `clear` does not.

## Scope boundary

Unit and integration tests against the plugin's own logic. Do not build a Herdr server harness and do not require a live or isolated server to run the suite: `demo.sh` already covers end-to-end observation and stays the place for that. If a rule genuinely cannot be tested without a server, say so rather than faking it.

Reference: `docs/agent-tree/m2-contract.md` holds the authoritative rules.

