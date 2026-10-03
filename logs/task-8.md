---
id: task-8
uid: 35e8f2a4-9825-40fd-aa7c-29afdddf960a
type: task
title: "Spike: establish an isolated Herdr 0.9.1 merged-client rank-ordering witness"
priority: "high"
effort: "medium"
relatedFiles: ["tests/e2e/sidebar.sh", "docs/agent-tree/m1-evidence.md", "src/projection.rs"]
tags: ["spike", "multi-machine", "herdr"]
accord:
  status: "ready"
  acceptance: ["A disposable Herdr 0.9.1 fixture proves, with captured TUI rows and verified per-pane token values, whether ascending agent_tree_rank uses lexical string order and missing values sort last, or establishes a minimal reproducible failure with the filter and sort both present.", "If feasible within an isolated test boundary, a merged two-endpoint client capture demonstrates equal ranks interleaving and namespaced ranks grouping families; otherwise the precise missing capability and next valid validation route are recorded.", "No live Herdr sockets/config/machine profiles, project source changes, or user-facing deploys are made; report a concise finding and reproducible check for task-7 before disposal."]
  claimedAt: "2026-09-28T19:32:46Z"
  validation: ["$ herdr --version"]
  note: "discarded: Disposable spike completed as a bounded capability finding: Herdr 0.9.1 merged clients require saved SSH endpoint setup; no safe isolated two-local-socket client path was found. No source edits or live changes. Finding and next validation path recorded on task-8; discard its clean worktree."
  updatedAt: "2026-09-28T19:35:29Z"
createdAt: "2026-09-28T19:32:32Z"
updatedAt: "2026-09-28T19:35:29Z"
archivedAt: "2026-09-28T19:35:29Z"
resolution:
  outcome: "completed"
---
Disposable investigation finding (2026-09-28): No supported Herdr 0.9.1 merged-client test route exists for two arbitrary local Unix sockets. `herdr machine add --help` accepts an SSH target and label, with optional remote session; v0.9.1 `src/cli/machine.rs` calls `prepare_saved_ssh` (which prepares/starts a remote server) before saving a profile, and `src/client/endpoint/catalog.rs` offers Local or saved SSH endpoints. The Worker verified a disposable client HOME/XDG/socket had no machine profiles and stopped BEFORE invoking machine add, starting servers, or contacting real SSH hosts. Project checkout was untouched. This is a capability gap in the test harness, not evidence that the proposed rank fix is wrong.

Prior discarded task-7 investigation: isolated 0.9.1 single-server fixture had `tree` header but did not apply even an explicit exists(agent_tree_rank) filter; a request trace ruled out a second agent.view.set replacement, yet proxy-routed TUI yielded no capture. Herdr v0.9.1 `src/agent_view_eval.rs` compares string rank tokens lexically with missing values last (source-level contract); earlier 0.9.0 isolated TUI evidence is at docs/agent-tree/m1-evidence.md §3.3. The live multi-machine screenshot and per-endpoint rank values show interleaving but not a controlled before/after fix.

Next validation path: use source-level comparator tests and the existing isolated real-plugin single-endpoint E2E for development; with Algorant's separate permission, stage the tested build across live endpoints and capture the merged sidebar before accepting task-7. Do not silently treat a single-server or source-only check as proof of multi-machine behavior.