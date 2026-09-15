# Agent Tree

Shows Pi Subagents and Workers beneath the immediate agent that spawned them in Herdr's
native Agents sidebar. One session-wide forest: a top-level Pi session first, then its
validated Subagents and Workers, with a Worker-launched Subagent nested under that Worker —
including across tabs and workspaces.

It is an external Herdr plugin. It never changes Pi, never writes Pi-owned metadata, and
never touches panes it cannot validate.

Status: MVP. Rendering, ordering, identity validation and lifecycle were observed in an
isolated Herdr 0.9.0 server (see "What is verified" below). It has not been installed or
enabled on a live server. `plugins/agent-tree/demo.sh` runs it on a real fixture in a
throwaway instance with one command (see "Demo").

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

## Demo (one command)

```sh
plugins/agent-tree/demo.sh            # attach an isolated TUI and look at the sidebar
plugins/agent-tree/demo.sh --print    # print the rendered sidebar as text (needs tmux)
plugins/agent-tree/demo.sh --keep     # leave the isolated instance running on exit
```

The demo builds the plugin, creates a fully isolated Herdr instance under a temp directory,
and shows the plugin working on a real delegation family: a root, a Worker beneath it, a
Worker-owned Subagent beneath that Worker, a second root with its Subagent, two undelegating
Pi sessions and a non-Pi row. It never touches the active Herdr server, its socket or
`~/.config/herdr`, and never registers the plugin in a user-global registry.

What it does, in order:

- Preflights `herdr`, `cargo`, `jq`, `sha256sum` and `setsid` (plus `tmux` for `--print`), and
  announces the resource cost before doing any of it.
- Starts an isolated Herdr with its own `HOME`, XDG dirs and explicit socket, and verifies
  the resolved socket at runtime, aborting if it is not the isolated one.
- Installs the Pi publisher into the isolated HOME and launches **7 credential-free, idle Pi
  agents**. Provider credential variables are cleared explicitly, then two independent
  signals fail the demo closed before any further agent starts: the launched process
  environment contains no provider key, and Pi reports `No models available`. It never
  prompts an agent and cannot spend credits. Expect about 25 s and 1 GB RAM.
- Publishes the pi-agency-shaped relationship tokens (`role`, `agency_self`, `agency_parent`,
  `task_id`, `handoff`, `question`) derived from those real session paths. It never writes
  `agent_tree_row` or `agent_tree_rank`; the plugin computes those itself.
- Applies the plugin, verifies the ranks, then forges a Subagent's `agency_self` and shows the
  plugin recompute and drop it before restoring the true value and the rank.
- Stops the isolated server and removes the temp directory on exit, including on failure or
  interrupt. `--keep` leaves the instance running and prints the attach and stop commands.

What the fixture proves and does not prove:

- Genuine: every `agent_session` comes from a real Pi process (`source: herdr:pi`,
  `kind: path`).
- Genuine: the tree is produced by the plugin's own identity validation. The forged-hash step
  shows it recomputes rather than trusting published labels.
- Fixture: the relationship tokens are published by the demo, not by pi-agency, because the
  throwaway HOME has no pi-agency and no Tandem. They use the same names and values pi-agency
  publishes, derived from the real session paths.
- Fixture: the non-Pi row is a reported agent row (`codex`), not a launched Codex process.

### Why real agents

External `pane.report_agent_session` / `pane.report_agent` cannot populate `agent_session`:
tested from an external connection with plain and `herdr:` sources, with and without
`agent_session_path`, before and after an agent row existed, and `agent_session` stays absent.
The only route is a real agent launch. See `docs/agent-tree/m1-evidence.md` section 11.

### Running from inside Herdr

The default (attach) mode starts the isolated TUI in your current terminal. If you run the
demo from inside an existing Herdr pane, the nested client can hit the layout quirk from M1
section 3.5 and the sidebar may render at an odd size. `--print` runs the client through a
real tmux PTY instead and is the reliable path from inside Herdr (or in CI and pipes).

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
