---
id: task-7
uid: 6a5d46e1-6678-4abd-8e91-3bc9d7fa3c45
type: task
title: "Agent Tree ranks collide across endpoints in a multi-machine sidebar"
priority: "high"
effort: "medium"
relatedFiles: ["src/projection.rs", "src/forest.rs", "src/decoration.rs", "tests/e2e/sidebar.sh"]
tags: ["bug", "multi-machine", "plan-first"]
accord:
  status: "accepted"
  acceptance: ["In an isolated two-endpoint Herdr setup (or a documented equivalent), each endpoint's delegation families stay contiguous and descendants appear only under their own root in the merged Agents panel.", "Herdr 0.9.1's actual ordering rule for the rank token is recorded with evidence, and the rank format is chosen from it.", "Single-endpoint ordering and toggle behavior are unchanged; stale old-format ranks are cleaned up on upgrade."]
  claimedAt: "2026-09-28T20:02:51Z"
  deliveredAt: "2026-09-28T20:55:10Z"
  validation: ["$ scripts/check.sh", "$ cargo build --locked --release"]
  summary: "Implemented endpoint-qualified preorder ranks using a domain-separated digest of validated /etc/machine-id and canonical HERDR_SOCKET_PATH. Added migration/failure handling, updated isolated assertions and rollout documentation, preserved task-5 branch rendering and package version 0.2.0, and committed as 580bbed."
  evidence: ["Herdr ordering and rank-format compatibility: Ranks now have `h<16 lowercase hex>-<six-digit preorder>` form, ordered lexically by endpoint then preorder. Unit tests cover same machine/different socket, different machine/same socket, stable recomputation, missing/invalid identity, family contiguity, six-digit order, and length under Herdr's 80-character cap.", "Migration and existing isolated endpoint behavior: The real-plugin isolated sidebar test injected a stale `000001` rank and observed it rewritten to the endpoint-qualified format. Sidebar and toggle E2Es passed with existing branch labels and order intact.", "Failure safety and foreign ownership: When endpoint identity cannot be derived, reconcile clears plugin-owned metadata and sends a source-checked view clear; foreign view owners are not cleared by that request. There is no hostname or numeric fallback.", "Scope and remaining acceptance gate: No live deployment/config changes were made. The requested live merged-sidebar capture remains intentionally pending explicit Algorant approval and parent-owned acceptance."]
  filesChanged: ["src/identity.rs", "src/lifecycle.rs", "src/projection.rs", "tests/e2e/sidebar.sh", "tests/e2e/toggle.sh", "docs/agent-tree/endpoint-rank-rollout.md", "CHANGELOG.md"]
  updatedAt: "2026-09-28T20:55:10Z"
createdAt: "2026-09-28T18:48:47Z"
updatedAt: "2026-09-28T20:55:10Z"
blockers: ["task-8"]
assignee: "worker-task-7-a71cc36e"
archivedAt: "2026-09-28T20:55:10Z"
resolution:
  outcome: "completed"
---
Observed 2026-09-28 in the desktop-wsl Herdr client: x1nano rank `000001` herdr-agent-tree root and `000002` task-5 Worker interleave with desktop rank `000001` mediafetch root and `000002` audio-games-audit Subagent. The x1nano Worker appears under mediafetch. The plugin assigns local preorder ranks; equal values across endpoints collide in the merged client.

Herdr 0.9.1 API schema has no machine builtin sort field, only token plus workspace_order, tab_order, pane_order, attention, status, agent, seen, state_change_seq. Tagged v0.9.1 `src/agent_view_eval.rs` compares token values lexicographically as strings and puts missing values after present ones. Earlier real Herdr 0.9.0 isolated TUI observed this at docs/agent-tree/m1-evidence.md §3.3. However, a 0.9.1 single-server disposable fixture showed an active `tree` label yet did not apply an explicit exists(rank) filter or sort; traced requests found no second view.set. Do not claim that fixture proves client ordering.

Task-8 spike (archived) established that the supported Herdr 0.9.1 merged-client route is a saved SSH machine profile whose add operation prepares a remote server; no safe two-local-Unix-socket aggregate test was available. It made no source/live changes. Implementation can proceed after task-5 integrates, using the source comparator contract plus real-plugin isolated single-endpoint checks, but multi-machine correctness remains a separate live validation gate with Algorant's explicit approval before any deploy or live config edit.

Candidate minimal fix: namespace the existing fixed-width preorder rank with a stable viewer-independent endpoint identifier, not numeric ranges. Choose and validate the identity (hostname can collide/rename; `/etc/machine-id` is readable but clones can duplicate it, and raw machine-id must not be exposed). Preserve task-5 branch/display behavior. During version skew, old numeric ranks will still interleave among old endpoints; document the rollout and test stale old-format rank cleanup on each upgraded endpoint. Merge only after task-5; run scripts/check.sh and cargo build --locked --release, then request explicit live deployment approval to capture the merged before/after sidebar before accepting this Task.