# Agent Tree

Shows Pi Subagents and Workers beneath the immediate agent that spawned them in Herdr's
native Agents sidebar. One session-wide forest: a top-level Pi session first, then its
validated Subagents and Workers, with a Worker-launched Subagent nested under that Worker —
including across tabs and workspaces.

It is an external Herdr plugin. It never changes Pi, never writes Pi-owned metadata, and
never touches panes it cannot validate.

Status: MVP. Rendering, ordering, identity validation and lifecycle were observed in an
isolated Herdr 0.9.0 server (see "What is verified" below). It has not been installed or
enabled on a live server.

## How it works

- Exactly two pane tokens are published, both namespaced to this plugin:
  - `agent_tree_row` — the row decoration: depth glyphs, branch, role, Worker `task_id`,
    and an attention hint (`?` pending question, `!` handoff publication failure,
    `▸` report available). Capped at 20 characters.
  - `agent_tree_rank` — a fixed-width 6-digit preorder rank, used only for sorting.
- One `agent.view.set` projection (`source = plugin:agent-tree`, label `tree`) sorts by rank
  and then by native order, so unranked rows stay in native relative order after the ranked
  block.
- Identity is recomputed, never inferred: `agency_self` must equal
  `sha256(["pi","path",<agent_session.value>])`, a parent edge must resolve to exactly one
  pane, and a pane that is only a parent is validated through a validated child's
  `agency_parent`. Anything missing, malformed, mismatched, duplicated, self-linked,
  dangling, ambiguous, cyclic or stale stays visible and unlinked.

## Requirements

- Herdr 0.9.0 (protocol 22). `min_herdr_version = "0.9.0"`.
- Rust toolchain (built with 1.81+).

## Build

```sh
cargo build --locked --manifest-path plugins/agent-tree/Cargo.toml
```

The manifest runs `./src/agent-tree`, a launcher that execs
`plugins/agent-tree/target/debug/agent-tree` (override with `AGENT_TREE_NATIVE_BIN`).

## Install (link a local checkout)

```sh
herdr plugin link /path/to/herdr/plugins/agent-tree --enabled
herdr plugin list          # expect: agent-tree (Agent Tree) enabled
```

`plugin link` registers the plugin. The startup hook runs on the next **server start**, not
on link or enable.

To apply the projection to a running server without restarting it:

```sh
herdr plugin action invoke agent-tree.apply
```

## Agents row configuration (verified fragment)

Herdr renders rows from `ui.sidebar.agents.rows`. This plugin's decoration only appears if
the row template references `$agent_tree_row`. The fragment below is exactly what was
rendered and verified in the isolated session (default cells keep the existing theme; no
theme colours are redefined):

```toml
[ui.sidebar.agents]
rows = [["state_icon", "machine", "workspace", "tab"], ["$agent_tree_row", "agent"]]
```

Rendered example (`tree` is the projection label shown in the sidebar header):

```
 agents              tree
 ○ m4
   R1
 ○ m4
   └─W task-3 ▸ · W1
 ○ m4
   │  └─S ? · S1
 ○ m4
   R2
 ○ m4
   └─S · S2
 ○ m4
   X1          <- non-Pi agent: never written to
 ○ m4
   L1          <- Pi session with no relationship tokens: unlinked
 ○ m4
   U1
```

The rank token is deliberately **not** rendered; it exists only for ordering.

Optional styling with existing palette values (not verified in this session):

```toml
# [ui.sidebar.agents]
# rows = [["state_icon", "machine", "workspace", "tab"],
#         [{ token = "agent_tree_row", fg = "#8ec07c", dim = true }, "agent"]]
```

Rollback of the fragment: delete the `[ui.sidebar.agents]` block (or restore the rows value
you had before). Herdr's defaults apply underneath; the plugin writes no configuration.

## Rollback

```sh
herdr plugin action invoke agent-tree.clear   # clears only agent_tree_row/agent_tree_rank and our view
herdr plugin disable agent-tree              # Herdr clears the view; tokens remain (see limitations)
herdr plugin unlink agent-tree               # unregisters; leaves files alone
```

`clear` removes exactly the two plugin tokens (source `agent-tree`) and only clears the view
when this plugin owns it. Run it with the subscriber stopped if you want the clear to stick;
a running subscriber will restore its projection on the next relevant event.

## Verified behavior (isolated Herdr 0.9.0)

Observed in an isolated server (own `HOME`/XDG/socket), never the active one:

- Rendered order for a two-root fixture: rank order `R1, W1, S1, R2, S2`, then the unranked
  rows in native order (`X1, L1, U1`); the sidebar header showed the `tree` label.
- Worker-owned Subagent rendered at depth 2 (`│  └─S ?`), Worker row `└─W task-3 ▸`.
- Cross-workspace: after moving the Worker's pane to another workspace the nesting and rank
  were preserved.
- Parent exit: closing the root cleared the child's rank and decoration (no stale parent).
  Child exit: closing the Child left the root unranked, because a root is ranked only while
  it has a validated child.
- Degenerate identities stayed unlinked: missing tokens, mismatched `agency_self`,
  self-link.
- Duplicate, cyclic, ambiguous-parent and stale/replaced identity are covered by the
  focused contract checks that were run during development (a temporary harness, since
  removed); they were not re-run live.
- Lifecycle: three `apply` invocations produced exactly one subscriber (single-instance
  lock); `kill -9` left the view and ranks in place with a stale lock that the next `apply`
  recovered; `disable` cleared the view but left tokens; `enable` restored nothing (hence
  `apply`); server restart dropped all pane metadata and the startup hook re-installed the
  projection from the fresh snapshot.
- No self-authored loop: with the projection installed and the tokens present, a 20-second
  idle window produced no further writes.
- Nothing was written to the non-Pi agent pane or to Pi panes without validated identity.

## Known limitations

1. **Depth fidelity beyond level 3.** Depths 4, 5, 6 … render identically as
   `…  │  │  └─`; bounded width was the deliberate trade.
2. **Mid-session socket loss.** The subscriber exits when its socket closes and startup
   hooks only run at server start, so a loss without a restart leaves the plugin stopped with
   its tokens and view in place. Run `agent-tree.apply` to restore it. (The trigger itself
   was never observed in the isolated session.)
3. **Restored panes need a live pane.** After a headless server restart, restored panes are
   listed but reject input verbs until a client attaches; build new panes if you need
   fixtures. This is a Herdr observation from the isolated session, not a plugin behaviour.
4. **Unranked rows are displaced.** Pi sessions with no validated delegation (and non-Pi
   agents) appear after the ranked block, in native order, because a missing token sorts
   last. A Pi session therefore moves to the top while it delegates and drops back when its
   last delegation ends.
5. **Dependency: `.pi` task-189 before live enable.** A Worker whose own durable tokens are
   gone but whose Worker-owned Subagent still carries a validated edge is parent-valid, so it
   receives a rank; Pi's recovery guard then refuses that Worker with
   `has incomplete or conflicting Herdr metadata rather than a tokenless restart identity;
   recovery made no changes.` Retry `worker_recover` once Pi republishes the Worker's durable
   tokens, or stop/clear this plugin first. Transient, non-destructive, self-healing — but
   task-189 should land before this plugin is enabled live.

## Unverified (needs a live TUI)

Mouse targets, indexed `focus_agent` bindings, the visual focus ring, `workspace_order` /
`tab_order` as secondary sort fields, and styled token rendering in a real theme.
