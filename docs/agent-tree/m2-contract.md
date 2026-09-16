# M2 implementation contract — Pi-aware delegation tree in Herdr Agents sidebar

> **Historical record.** This contract was agreed while the plugin lived in the
> repository now named `Algorant/herdr-notifs-plus`. Its paths
> (`plugins/agent-tree/...`), crate layout, build commands, status lines and live-enable
> prerequisites describe the state at the time of agreement, not this repository today. It
> is retained as the historical record of what was agreed; only markings that identify it as
> historical have been added. The plugin was later extracted to this repository root and
> implemented: current paths and commands are in `README.md`.

Status at the time of agreement: submitted for orchestrator and Algorant agreement, and no
plugin code existed then.
Basis: M1 evidence (`docs/agent-tree/m1-evidence.md`, commits fea6468 and ab20bea) plus the
orchestrator rulings (option C; rank validated Pi nodes only; never write to non-Pi panes;
`.pi` task-189 a prerequisite for live enable) and Algorant's scope clarification that for the
MVP every relevant pane is treated as Pi.

Every choice below cites an M1 observation or is listed as an unknown in C10.

---

## C1 Identity, tokens, sources

- Plugin id `agent-tree`; crate `plugins/agent-tree/` (the monorepo path at the time; the
  crate now sits at this repository root) with its own `Cargo.toml`,
  `Cargo.lock`, `herdr-plugin.toml`, `src/`. `min_herdr_version = "0.9.0"`.
  `platforms = ["linux"]` (add `macos` only if the portable path is actually validated in M4).
- Exactly two pane keys, ever: **`agent_tree_row`** (decoration) and **`agent_tree_rank`**
  (preorder rank). Namespace rule: the plugin id with every character outside `[A-Za-z0-9_]`
  replaced by `_`, then `_row` / `_rank`. Names are 14 and 15 characters, inside the
  verified 1–32 charset.
- Metadata report source: `agent-tree`. View source: `plugin:agent-tree` (mandatory
  `plugin:` form).
- The plugin never writes, clears or replaces `role`, `agency_self`, `agency_parent`,
  `task_id`, `handoff`, `worker_context`, `started_at`, `delivery_id`,
  `orchestrator_workspace_id`, `question`, or any key it did not itself publish. No wholesale
  token reset. No writes on panes that have no agent row.

## C2 Validation — recomputation only, no inference

- `self(pane) =` lowercase hex `sha256` over the exact UTF-8 bytes of compact JSON
  `["pi","path",<agent_session.value>]`, computed only for agent rows with `agent == "pi"`,
  `agent_session.kind == "path"`, and an absolute `value`.
- **self-valid node**: publishes `role ∈ {worker, subagent}` and a 64-char lowercase hex
  `agency_self` exactly equal to `self(pane)` — byte-for-byte, no case folding, no trimming.
- **parent edge valid**: the child's `agency_parent` equals `self(parent pane)` for exactly
  one other pane in the same snapshot.
- **parent-valid pane**: a pane with at least one self-valid child whose edge points at it.
  This is the approved refinement: a root is validated by recomputing the hash of its own
  native `agent_session` path, with no token on the root and no inference from names, tabs,
  worktrees or proximity.
- **placeable node**: a parent-valid root with no parent edge, or a node whose parent chain
  terminates at a parent-valid root without revisiting a node. Everything else is unplaceable.

## C3 Ordering and rank format

- Input is the native agent order from `session.snapshot` / `agent.list`
  (workspace, then tab, then pane).
- Emission: parent-valid roots in native order; for each root, the root then its validated
  descendants recursively, children in native order. Then every remaining agent row in
  native order.
- `agent_tree_rank` = 6-digit zero-padded decimal (`000001` upward) assigned in emission
  order. Sort-only; the recommended row fragment does not render it. If N > 999999 the
  plugin publishes no ranks and logs a clear error — no wrap, no partial publication.
- View: `source = plugin:agent-tree`, `label = "tree"`, **no filter** (all agents stay
  visible), sort exactly:
  ```json
  [{"field":{"token":"agent_tree_rank"},"order":"asc"},
   {"field":"workspace_order","order":"asc"},
   {"field":"tab_order","order":"asc"},
   {"field":"pane_order","order":"asc"}]
  ```
  `pane_order` is the M1-verified tie-break; `workspace_order` and `tab_order` are
  documented but unverified in M1, so they are carried in the chain (to keep the unranked
  block in native relative order) and listed as an M4 verification item. Unique ranks make
  the token decisive; the native chain is the safety net for the unranked block and for a
  duplicated or stale rank.
- **Deviation from product-scope wording**, stated plainly: under option C the unranked
  block is displaced below every ranked row *as a block*, in native order. Brief note:
  non-Pi rows are not designed for, are never written to, and land unranked in native order;
  the practical case is not expected to occur.

## C4 Decoration encoding (`agent_tree_row`)

```
row       = indent branch role [" " task] [" " attention]
indent    = ""                              depth 0
          | ("│  " × (depth-1))             1 ≤ depth ≤ 3        (U+2502)
          | "…  " + ("│  " × 2)            depth > 3           (bounded at any depth)
branch    = "├─" if a following sibling exists in the same family, else "└─"
role      = "W" (worker) | "S" (subagent)
task      = Worker task_id value, truncated to 12 characters, worker only
attention = "?" pending question | "!" handoff=failed | "▸" handoff=reported | ""
```

- Attention comes from existing metadata only: Worker `handoff ∈ {question, failed,
  reported}`; Subagent `question` token present ⇒ `?` (a Subagent has no `handoff`).
  `missing` / absent / unknown `handoff` ⇒ no glyph, never rendered as failure. No glyph
  ever implies task success or Tandem acceptance.
- Hard cap 20 characters. Over-cap drop order: **task, then attention, then collapse the
  indent**; branch and role are never dropped.
- **Known limitation (depth fidelity):** the ellipsis collapse renders depth 4, 5, 6 and
  deeper identically (`…  │  │  └─`). Bounded width is the deliberate trade, so a tree deeper
  than three levels loses depth fidelity beyond level 3. Carried into the M4 documentation so
  a reader of a deep tree is not surprised.
- The grammar never emits leading whitespace (M1 proved leading spaces, NBSP and U+2007 are
  stripped) and never emits a hash, session path, routing id, delivery id, question text or
  report contents.
- A parent-valid root carries the attention glyph only; with no attention it carries no
  decoration token at all (an empty token value clears the key, so there is nothing to
  publish). Its structure is conveyed by its decorated descendants.

## C5 Degenerate cases → visibly unlinked (no decoration, no rank; the row stays visible but is displaced into the unranked block per C3)

| case | treatment |
| ---- | --------- |
| missing relation tokens (legacy tokenless Worker, lone Pi session, plain Pi pane) | unlinked |
| malformed: `role` outside {worker, subagent}; `agency_self`/`agency_parent` not 64-char lowercase hex; any of the three keys absent; a role such as reviewer | unlinked |
| recomputed self-hash mismatch | unlinked |
| duplicate `agency_self` across two panes | both unlinked |
| self-link (`agency_parent == agency_self`) | unlinked |
| dangling parent (`agency_parent` matches no pane) or ambiguous parent (matches ≥ 2 panes) | child unlinked |
| cycle: a node whose parent chain revisits a node, or whose chain passes through such a node | unlinked; cycle members never rank and never validate a parent |
| stale/replaced identity | unlinked |

Stale/replaced is handled structurally: every projection is recomputed from the current
snapshot, and no graph, hash or parent assignment is carried across snapshots, so a restart
or a replaced pane cannot leave a stale parent assignment.

No inference fallback from name, terminal title, cwd, worktree, tab, workspace,
`orchestrator_workspace_id`, `started_at`, `delivery_id` or filesystem proximity.
`delivery_id`, `worker_context`, `started_at` and `orchestrator_workspace_id` are never read
as ownership inputs.

## C6 Transport, timing, lifecycle

- Manifest: `[[startup]]` runs the binary with `start`; `[[actions]]` **apply** (same start
  routine, because M1 showed enable does not run startup hooks) and **clear** (clears only
  our two names with source `agent-tree`).
- `start`: acquire a single-instance lock at `$HERDR_PLUGIN_STATE_DIR/subscriber.lock`
  holding `{pid, socket_path, started_unix_ms}`. A live holder for the same socket ⇒ wait up
  to 3 s then exit 0 with a log line. A recorded dead pid ⇒ replace the lock (stale-lock
  recovery). Then spawn the subscriber detached (`setsid`, logs under the state dir) and
  exit 0. The lock is the only persistent file; it holds no graph, no identity, no
  relationship data.
- Subscriber: **one process per server**. Connect to `HERDR_SOCKET_PATH`, send
  `events.subscribe` **first** and wait for `subscription_started`, then call
  `session.snapshot`, buffer and apply events received in between, then stream. On
  connection loss or server restart it exits rather than reconnecting (a fresh server starts
  a fresh subscriber). No reconnect loop, no supervisor, no renewal protocol, no polling.
- Subscribed events: `pane.created`, `pane.closed`, `pane.moved`, `pane.exited`,
  `pane.updated`, `pane.agent_detected`, `layout.updated`, `tab.created`, `tab.closed`,
  `tab.moved`, `workspace.created`, `workspace.closed`, `workspace.moved`,
  `workspace.reordered`. No status/scroll/title subscriptions.
- Recompute trigger: a normalized digest of (`agent key`, `agent_session.value`, our two
  token values, `role`, `agency_self`, `agency_parent`, `handoff`, `question`). A digest-equal
  event causes no writes and no view set; title/scroll/revision-only `pane.updated` events
  (M1 showed `pane.updated` fires on our own token writes) are ignored. Suppression is by
  **value comparison, not by timing** — this is the deliberate answer to M1's self-authored
  change loop risk.
- Publish order: tokens first, then the view.
- **Failed fetch is not an empty snapshot**: a snapshot error or unreadable stream causes no
  publish and no clear; the connect/subscribe/snapshot sequence is retried at most 3 times
  1 s apart, then the process exits non-zero with a log line.
- Resnapshot triggers: re-subscription, an event naming an unknown pane, or a digest change
  with missing local state.
- Shutdown: on SIGTERM/SIGINT clear our two tokens on the panes that carry them (source
  `agent-tree`, values `null`), then `agent.view.clear` with source `plugin:agent-tree`, then
  remove the lock. On socket EOF (server stop/restart) Herdr has already dropped metadata and
  the view (M1 verified), so the process only removes the lock and exits. Never an
  unconditional clear.
- View ownership: before the first set of a process, determine the owner with
  `agent.view.clear {source: "plugin:agent-tree"}`, whose documented and M1-verified
  behaviour is that a source mismatch leaves the active view unchanged and reports
  `active`/`source`/`label`. If the owner is another source, or the response is an error or
  does not report an owner, the plugin **does not set**, logs the conflict and stays passive
  until the next process start. It never falls back to an unconditional clear and never
  guesses. While it owns the view it re-sets on recompute without re-probing, because
  probing would clear its own view. **Stated limitation**: a foreign owner appearing mid-run
  is not detected until the next process start; no probing protocol is invented to work
  around that.
- Duplicate start: the lock plus exit-on-socket-loss. Documented consequence of M1: disable
  clears the view automatically but runs no plugin code, so tokens remain until the next
  start, the `clear` action, or the startup self-heal (the plugin always clears its own
  unwanted tokens from panes it no longer decorates).
- **Known limitation (mid-session socket loss):** because the subscriber exits on connection
  loss and startup hooks run only at server start, a socket loss *without* a server restart
  leaves the plugin stopped with its tokens and view still in place until the next server
  start or a manual `apply`. No reconnect loop or supervisor is built; `apply` is the remedy.
  M1 never observed such a loss without a server restart, so the trigger itself is unverified
  and the limitation is stated as a consequence of the chosen mechanism, not as an observed
  failure. Carried into the M4 documentation.
- No durable registry, graph, database, metrics file, Tandem access, transcript access,
  delivery-record access, self-update, or Pi-side change.

## C7 Recovery-conflict publication rule

- Publication scope is option C: tokens only on validated Pi nodes (validated children and
  parent-valid panes). Consequence for the record: an unvalidated Pi pane, including a
  lost-identity Worker, never receives a plugin token, so the M1-reproduced guard cannot be
  tripped by those panes.
- **Residual case, documented rather than hidden**: a Worker whose own durable tokens are
  gone while its Worker-owned Subagent still carries a validated child edge is parent-valid,
  so it receives a rank, and per M1 one extra key makes `worker_recover` refuse.
  - Exact symptom: `worker_recover` fails with “has incomplete or conflicting Herdr metadata
    rather than a tokenless restart identity; recovery made no changes.”
  - Exact retry that clears it: once Pi republishes the Worker's durable tokens (`role`,
    `agency_self`, `agency_parent`, `task_id`, `orchestrator_workspace_id`), recovery takes
    the durable-candidate branch and succeeds; stopping the plugin or running the `clear`
    action also removes the token. Transient, non-destructive, self-healing.
- Dependency: **`.pi` task-189 is a prerequisite for live enable**, and that dependency plus
  the symptom and retry are documented in the M4 setup and rollback documentation rather than
  left for the reader to discover.

## C8 Lone-Pi-session ordering position

Under option C the sidebar splits into ranked validated family members and an unranked block
of Pi sessions that have not delegated. This is the main ordering consequence of the design,
not a side effect.

**Position: accept it**, for four reasons.

1. **Inert by default.** With no delegations there are no ranks at all, every row is missing
   the token, and the projection leaves native order untouched. A user who never delegates
   sees literally no reordering.
2. **The movement is the feature.** A session rises exactly when it has a live validated
   delegation, and showing that tree is what the plugin exists to do.
3. **The blocks are distinguishable by construction, not by convention.** A root is
   rankable only while it has at least one validated child, so every row in the ranked block
   has at least one decorated descendant directly beneath it, and no row in the unranked block
   ever does. There is therefore no ambiguous promoted root in the rendered result, and no
   extra root glyph is needed; the glyph vocabulary stays branch/role/task/attention exactly
   as scoped.
4. **It reverses deterministically.** When the last delegation ends, the family leaves the
   ranked block together and the session reappears in the flat block in its native slot, so
   the change reads as “the delegation ended”, not as noise.

The one genuine instability to name: a session's position changes when its first delegation
appears and again when its last one ends. That is acceptable for the MVP because both edges
are the moments the tree itself changes.

**Cheap way to keep non-delegating sessions in native position: none found.** A token-sorted
view puts rows without the token last; keeping them in place would require publishing the
rank on panes we cannot validate, which is exactly the write that was ruled out because a
lost-identity Worker is indistinguishable from a lone root on public surfaces. Recommendation:
accept, with an M4 note that Algorant should judge the movement in a live sidebar. If he
judges it as instability that undermines the feature, the only compliant alternative is a
different mechanism altogether (option A after task-189) — a scope change, not a tweak.

## C9 Budgets (observed, not assumed)

- Two keys per pane; one metadata report per pane per recompute (both keys together, at most
  16 keys mentioned). Observed Pi coexistence: Worker 9 keys + 2 = 11 of the verified 32 cap;
  Subagent 3–4 + 2 = 5–6.
- Value widths: rank exactly 6 characters, decoration at most 20 — both far inside the
  verified 80-character cap.
- No writes to panes without an agent row; agentless retained panes are never promoted to
  rows; the plugin reads agent rows only.

## C10 Unknowns carried forward, with design impact

| # | unknown | impact |
| - | ------- | ------ |
| 1 | mouse targets, indexed `focus_agent`, focus ring under a projection | no design change; if indexed focus does not honour the projection, M4 records it as native behaviour, not a plugin defect |
| 2 | event coalescing/ordering; whether a dedicated metadata event exists | the digest plus resnapshot triggers absorb ordering uncertainty; if events can be dropped outright, stale tokens could persist until the next relevant event, and the response would be to resnapshot on digest mismatch |
| 3 | view filter referencing `current_workspace_id`/`current_tab_id` from a headless server | moot for the MVP because the projection sets no filter; matters only if a filter is added later |
| 4 | nested-TUI layout collapse (M1 §3.5) with a real attached client | affects only the evidence harness; M4 must use the PTY-client method from M1 §3.2 |
| 5 | `workspace_order` and `tab_order` as sort fields (only `pane_order` verified) | changes the unranked block's cross-workspace order; M4 checks it |
| 6 | how a row template renders an absent `$token` | affects the M4 config fragment only, not plugin logic |

## C11 Not in the MVP

No Radar fork or adoption; no new dashboard; no Pi extension or Pi-side change; no new Pi
publisher; no transcript, delivery-record, metrics or Tandem reads; no agent messaging or
control; no Reviewer parent inference (`role = reviewer` stays unlinked); no cross-machine
discovery; no expand/collapse or any new navigation UI; no mouse-target work; no animations;
no notifications; no theme, font or configuration writing; no installer or release changes;
no global install or enable; no persistent graph or registry; no fallback or speculative
transport; no parent inference of any kind.

## C12 M3 deliverables and validations

Proposed files at the time (none existed yet; monorepo layout):

```
plugins/agent-tree/Cargo.toml
plugins/agent-tree/Cargo.lock
plugins/agent-tree/herdr-plugin.toml
plugins/agent-tree/src/agent-tree          launcher script (repo convention)
plugins/agent-tree/src/main.rs          entry: start | apply | clear | subscriber
plugins/agent-tree/src/wire.rs          socket request/response/event shapes
plugins/agent-tree/src/transport.rs     connect, subscribe-first, snapshot, digest, failures
plugins/agent-tree/src/identity.rs      sha256 tuple recomputation, edge validation
plugins/agent-tree/src/forest.rs        placeability, preorder, rank assignment
plugins/agent-tree/src/decoration.rs    token grammar, caps, attention
plugins/agent-tree/src/projection.rs    view ownership, set/clear, token reconciliation
plugins/agent-tree/src/lifecycle.rs     lock, duplicate start, shutdown, self-heal
```

The crate is standalone (the repository root is not a workspace), keeps the root
notification plugin, package identity, installer and release behaviour untouched, and adds no
shared SDK or multi-plugin release machinery. The launcher script `src/agent-tree` follows the
root plugin's existing `src/<name>` convention and execs `target/debug/agent-tree` (with an
env override), so the manifest never invokes cargo at runtime. M4 then adds the reviewed
row-configuration fragment and the setup/rollback documentation, including the two named
limitations (depth collapse beyond level 3; mid-session socket loss with `apply` as the
remedy) and the `.pi` task-189 dependency with its symptom and retry.

M3 declared validations at the time: `git diff --check` and
`cargo build --locked --manifest-path plugins/agent-tree/Cargo.toml` (the monorepo manifest
path; the manifest is now `Cargo.toml` at this repository root).
