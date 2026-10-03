---
id: task-11
uid: 22e2d4e3-f59c-48bb-8c51-b1ca457b1a0a
type: task
title: "Spike: find a cross-machine agent state-transition time for recency ordering"
priority: "high"
effort: "small"
relatedFiles: ["src/transport.rs", "src/lifecycle.rs", "src/projection.rs", "tests/e2e/sidebar.sh"]
tags: ["spike", "herdr", "ordering", "multi-machine"]
accord:
  status: "ready"
  acceptance: ["Report an exact Herdr 0.9.1/protocol-22 state-transition field and evidence that it is comparable across endpoints (with a bounded isolated check), or demonstrate the absence of such a field with the precise remaining API/product gap.", "Distinguish initial state, status transitions, output/focus/metadata changes, restart/reconnect, and cross-machine clock/tie implications; do not claim endpoint-local sequence values are global.", "No live Herdr socket/config/machines or repository source files are modified; deliver a reproducible finding for task-10 and discard this Worker's checkout."]
  claimedAt: "2026-09-29T12:35:44Z"
  validation: ["$ herdr --version"]
  note: "discarded: Disposable Sonnet 5.5 research spike complete: Herdr 0.9.1 exposes no authoritative cross-machine agent transition timestamp; per-server state_change_seq is not globally comparable. Reproducible finding recorded on task-11. No source edits; discard only this spike checkout. Task-10 awaits Algorant's product/API decision."
  updatedAt: "2026-09-29T12:42:17Z"
createdAt: "2026-09-29T12:35:32Z"
updatedAt: "2026-09-29T12:42:17Z"
references: ["https://github.com/herdrdev/herdr/blob/v0.9.1/src/app/actions.rs", "https://github.com/herdrdev/herdr/blob/v0.9.1/src/client/shell/endpoints.rs"]
archivedAt: "2026-09-29T12:42:17Z"
resolution:
  outcome: "completed"
---
Finding (Herdr 0.9.1/protocol 22, Sonnet 5.5 isolated spike): NO authoritative cross-endpoint-comparable agent state-transition time is exposed to plugins. `herdr api schema --json` AgentInfo has `state_change_seq` but no state-changed timestamp; pane.agent_status_changed event has status/presentation fields only (no seq or timestamp). v0.9.1 src/app/actions.rs increments the app-local `next_agent_state_change_seq` only on underlying state change; it resets on server restart. Repro script `/tmp/task11-recency-check.sh` started two disposable HOME/XDG/socket servers: A made five transitions, B made one 0.5s later. A reported seq=5 and B seq=1 despite B being later. Both used pane id w1:p1, demonstrating IDs and counters are endpoint-local. Presentation-only metadata can emit status-changed events without a seq bump, while output/focus/token writes do not bump seq. First observation may emit an initial event without a transition; late subscribers cannot replay missed transition time. Subscriber event receipt lag measured ~95–98 ms over 20 samples, and cross-machine clock skew is unknown.

Herdr v0.9.1 client internally assigns global observed recency to agents as endpoint snapshots arrive (`src/client/shell/endpoints.rs`), but that value is client-local and only drives built-in Priority order; it is not exposed as an AgentViewBuiltinSortField or to endpoint-scoped plugins. Exposing an individual agent's client recency alone would NOT keep a parent family contiguous: a family-aware grouped max-recency sort keyed by a plugin family token (with parent-first preorder within each group) or equivalent merged-client capability would also be needed. Other option: Algorant explicitly accepts approximate subscriber-stamped wall-clock tokens, with ~100 ms receipt jitter, unenforced inter-machine skew, undatable gaps/restarts and per-pane subscriptions; this cannot promise strict global chronology. No fallback was implemented. Must ask Algorant to choose the product contract before task-10 implementation.

No project source or live Herdr state changed. All test servers used disposable HOME/XDG/socket and were stopped. Worker checkout will be discarded. Version/source check: `herdr --version` 0.9.1; `herdr api schema --json` protocol 22; upstream source tag v0.9.1 at herdrdev/herdr. Reproduce basic comparator gap with `herdr pane report-agent` on two isolated servers and compare `.result.agents[].state_change_seq` from `herdr agent list`, as in `/tmp/task11-recency-check.sh`.