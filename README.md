# Agent Tree

Shows Pi Subagents and Workers beneath the immediate agent that spawned them in Herdr's
native Agents sidebar. One session-wide forest: a top-level Pi session first, then its
validated Subagents and Workers, with a Worker-launched Subagent nested under that Worker —
including across tabs and workspaces.

It is an external Herdr plugin. It never changes Pi, never writes Pi-owned metadata, and
never touches panes it cannot validate.

Status: v0.1.0 source release for Linux and Herdr 0.9.0+. The Herdr-managed GitHub install
was dogfooded on Herdr 0.9.1 with a real Pi root, Worker and Subagents, including managed
reinstall, tree/native toggle and cleanup. The isolated `tests/e2e/sidebar.sh` and
`tests/e2e/toggle.sh` also exercise the tree and shortcut (see "End-to-end test").

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
- Rust 1.81+ with `cargo`, and `git`: Herdr runs the manifest build and manages the source
  checkout during `herdr plugin install`.
- `just` for the developer recipes (`just test`, `just build`, `just deploy`).

## Build

```sh
just build
# equivalent to: cargo build --locked --release --manifest-path Cargo.toml
```

The manifest declares `[[build]] command = ["cargo", "build", "--locked", "--release"]`.
Herdr runs that locked build and then the tracked `./src/agent-tree` launcher, which execs the
optimized release binary `target/release/agent-tree` (override with `AGENT_TREE_NATIVE_BIN`).
Linking this source checkout directly, or running `scripts/deploy.sh`, is a development install
from a checkout. The supported path for a normal user is Herdr's managed source install (see
"Install" below).

## Test

```sh
just test
```

`scripts/check.sh` is the single authoritative gate: formatting, Clippy, Rust tests, the locked
build, shell syntax checks, the clean-source install and local-stage suites, and the noninteractive isolated
Herdr end-to-end test below. The Rust suite runs against the plugin's own logic with Rust's
standard test harness and needs no running Herdr server, no socket and no network. It covers
identity recomputation and self-validation, unique parent resolution and the tokenless-parent
refinement, every contract C5 degenerate case, preorder emission with family contiguity and
native ordering, the rank format and its ceiling, the decoration grammar and 20-character cap,
the tree-off marker, the verified reload holder checks (including the `(deleted)` staged
binary), the view-owner classification and toggle decision table, and the CLI boundary where
`apply` clears the tree-off marker while `clear` and a fail-closed `toggle` leave it.
`tests/shell/dev-reload.sh` drives the real `scripts/deploy.sh` against a fake `herdr`, a fake
`cargo` and a local socket server to cover first install, repeated reload, stale-lock recovery
and foreign-holder refusal without a live Herdr server. Hosted CI runs
`scripts/check.sh --no-e2e` because its runner has no Herdr or Pi.

## End-to-end test

```sh
tests/e2e/sidebar.sh      # identity/tree rendering; also run by `just test`
tests/e2e/toggle.sh       # owner-safe shortcut toggle; also run by `just test`
```

The test builds the plugin, creates a fully isolated Herdr instance under a temp directory, and
drives the plugin on a real delegation family: a root, a Worker beneath it, a Worker-owned
Subagent beneath that Worker, a second root with its Subagent, two undelegating Pi sessions and
a non-Pi row. It is noninteractive, has no options, never touches the active Herdr server, its
socket or `~/.config/herdr`, and removes the temp directory and isolated server on exit,
including on failure or interrupt.

What it does, in order:

- Preflights `herdr`, `cargo`, `jq`, `sha256sum`, `setsid` and `tmux`.
- Starts an isolated Herdr with its own `HOME`, XDG dirs and explicit socket, and verifies the
  resolved socket at runtime, aborting if it is not the isolated one.
- Installs the Pi publisher into the isolated HOME and launches **7 credential-free, idle Pi
  agents**. Provider credential variables are cleared explicitly, then two independent signals
  fail the test closed before any further agent starts: the launched process environment
  contains no provider key, and Pi reports `No models available`. It never prompts an agent and
  cannot spend credits. Expect about 25 s and 1 GB RAM.
- Publishes the pi-agency-shaped relationship tokens (`role`, `agency_self`, `agency_parent`,
  `task_id`, `handoff`, `question`) derived from those real session paths. It never writes
  `agent_tree_row` or `agent_tree_rank`; the plugin computes those itself.
- Applies the plugin, asserts the rank order, then forges a Subagent's `agency_self` and asserts
  the plugin recomputes and drops it before restoring the true value and the rank.
- Renders the sidebar through a real tmux PTY and asserts the `tree` view label and a Worker row.

`tests/e2e/toggle.sh` is the second isolated test. It launches three credential-free Pi
sessions (one undelegating session plus a validated root/subagent family), installs the
documented `prefix+t` binding in the isolated config, and presses it through a real tmux
PTY: tree -> native -> tree -> native. It asserts the `tree` view label and projected order,
that `agent_tree_row`/`agent_tree_rank` stay published when tree is off, that the native
Agents header mouse toggle works again when tree is off, that a foreign view owner is never
displaced by either the action or the shortcut, that `clear` still removes the plugin tokens
and view, and that `config.toml` is byte-identical after the run (the plugin writes no
configuration).

What the fixture proves and does not prove:

- Genuine: every `agent_session` comes from a real Pi process (`source: herdr:pi`,
  `kind: path`).
- Genuine: the tree is produced by the plugin's own identity validation. The forged-hash step
  shows it recomputes rather than trusting published labels.
- Fixture: the relationship tokens are published by the test, not by pi-agency, because the
  throwaway HOME has no pi-agency and no Tandem. They use the same names and values pi-agency
  publishes, derived from the real session paths.
- Fixture: the non-Pi row is a reported agent row (`codex`), not a launched Codex process.

### Why real agents

External `pane.report_agent_session` / `pane.report_agent` cannot populate `agent_session`:
tested from an external connection with plain and `herdr:` sources, with and without
`agent_session_path`, before and after an agent row existed, and `agent_session` stays absent.
The only route is a real agent launch. See `docs/agent-tree/m1-evidence.md` section 11.

## Install

### Herdr-managed source install (the normal user path)

The supported install path for a normal user is Herdr's own plugin lifecycle. Install the
published v0.1.0 source release from GitHub:

Herdr clones the tagged source revision, runs the manifest `[[build]]` command
(`cargo build --locked --release`) in the managed checkout, and registers the plugin:

```sh
herdr plugin install Algorant/herdr-agent-tree --ref v0.1.0
```

A normal user does not need this checkout or a prebuilt binary: Herdr runs the locked Cargo
release build itself, so the managed machine needs the Rust toolchain (1.81+), `cargo`, `git`
and `rustc`. Herdr stores the managed checkout under its own plugin data directory.

### Activate the managed install (manual)

Herdr registers the plugin; activation is still explicit. Add the sidebar rows block from
"Agents row configuration" below, then enable, reload and apply:

```sh
herdr plugin enable agent-tree
herdr server reload-config
herdr plugin action invoke agent-tree.apply
```

Without the rows block, the plugin's decoration has no cell to render into. The startup hook
runs on the next **server start**, not on install or enable, which is why the explicit `apply`
is part of activation.

### Update

Reinstall from the new tag; Herdr replaces the managed source checkout and reruns the build:

```sh
herdr plugin install Algorant/herdr-agent-tree --ref v0.2.0
```

There is no separate `herdr plugin update` in plugin v1, no `latest`, and no side-by-side
version directory: the tag you name is the version you run. Remove the plugin with
`herdr plugin uninstall agent-tree`.

### Development install from a checkout

`just deploy` (which runs `scripts/deploy.sh`) is the **development install** from this
checkout and the sole rapid checkout dogfood loop. It builds the release binary, stages a
self-contained plugin root at `${XDG_DATA_HOME:-$HOME/.local/share}/herdr-agent-tree/stage`,
registers **that staged root** (not this checkout), adds or updates the sidebar rows block in
`config.toml`, and then replaces the running subscriber with the just-staged build and
re-applies the projection, without restarting the server or disturbing panes:

```sh
just deploy               # build, stage, register, configure and reload the live subscriber
scripts/deploy.sh --status     # show what is in place
scripts/deploy.sh --uninstall  # reverse registration and the config block
```

"Replaces the subscriber" is literal and verified. Restaging alone would not be enough: an
older subscriber process can keep holding `subscriber-<tag>.lock` and answer later events
with its in-memory binary. `agent-tree.reload` guarantees the sole subscriber is started from
the running (newly staged) binary. Before signaling a live holder it requires every identity
signal to agree: the same UID, `HERDR_PLUGIN_ID=agent-tree`, the exact injected
`HERDR_SOCKET_PATH` and `HERDR_PLUGIN_STATE_DIR`, an `agent-tree subscriber` argv, and an
executable inside this deploy's own staged install path (the `stage/` root or its exact
`.stage-old.*` sibling). No holder-reported environment value can widen that executable set.
A dead or stale lock is recovered. Anything unverifiable or foreign fails clearly, is never
signaled, and no replacement is started.

`just deploy` does not trust the action invocation's own exit status. Herdr starts an action
asynchronously and returns a log record that is still `running`, so deploy waits for that
exact record to reach a terminal status and surfaces the action's stderr if it failed. It
then verifies the running image directly: exactly one `agent-tree subscriber` on the staged
path, no `.stage-old.*` subscriber, and the same SHA-256 for the checkout build, the staged
file and `/proc/<pid>/exe`. It repeats that check after `herdr server reload-config` and
fails if the pid changed, so deploy returns only with one stable subscriber and no later
handoff.

`apply` is unchanged and narrower: it only ensures some subscriber is present and re-installs
the projection once. Use it to restore the projection after a mid-session socket loss, or
invoke the `reload` action directly:

```sh
herdr plugin action invoke agent-tree.apply
herdr plugin action invoke agent-tree.reload
```

A bare `herdr plugin action invoke agent-tree.reload` only *starts* the action; use
`just deploy` (or wait for the returned log id to reach a terminal status) when the
replacement must be complete before you continue.

The staged layout follows the `herdr-notifs-plus` development staging approach: a complete
plugin root whose `src/<name>` is the real binary rather than a launcher.

```
~/.local/share/herdr-agent-tree/stage/   # or $XDG_DATA_HOME/herdr-agent-tree/stage
├── herdr-plugin.toml
├── README.md
└── src/agent-tree                       # the release binary
```

Because the staged `src/agent-tree` is the release binary, the staged plugin depends on neither
the repository checkout nor `target/`: `cargo clean`, a `target/` wipe, or moving the checkout
does not affect it. Re-run `just deploy` to rebuild, restage and replace the live subscriber.
The staging directory is local hidden state, so this is not the documented path for a normal
user.

These local loops are not the normal install path. A normal user installs from source with
`herdr plugin install Algorant/herdr-agent-tree --ref <tag>`, which lets Herdr clone, build and
register the plugin. `scripts/stage-local.sh` is inert local staging: it writes a complete
plugin root under the Cargo target directory and never links it or touches user state.

An install made earlier with `herdr plugin link <repo>/. --enabled` registered the source
checkout; running `just deploy` relinks it to the staged root. If a subscriber started from
that checkout is still running, `reload` refuses it as outside the staged install path and
does not signal it; stop that process manually (or let it exit with the server) and run
`just deploy` again.
Registering the checkout by hand also remains available for development:

```sh
cargo build --locked --release --manifest-path Cargo.toml
herdr plugin link /path/to/herdr-agent-tree --enabled
```

To apply the projection to a running server without restarting it:

```sh
herdr plugin action invoke agent-tree.apply
```

### Deploy and diagnose a named Herdr endpoint

`just deploy` above is local-only. When Agent Tree must run on another machine that is saved
as a Herdr SSH machine, use the explicit-endpoint path:

```sh
just deploy-endpoint archbox      # deploy the current checkout to that endpoint
just doctor archbox               # read-only readiness report for that endpoint
just doctor local                 # read-only readiness report for this machine
```

The endpoint is always the one named on the command line: `local`, or the unique label,
profile id, or SSH target of an enabled saved machine (`herdr machine list --json`). A
machine selected in the TUI never retargets these commands. `--endpoint local` is exactly
the existing `scripts/deploy.sh` path, so the local loop is unchanged.

`scripts/deploy-endpoint.sh` is transactional and never restarts either server:

1. preflight (read-only): endpoint Herdr running and protocol-compatible, server version at
   or above the manifest `min_herdr_version`, remote tools present, and the endpoint config
   free of a foreign `[ui.sidebar.agents]` block or an occupied `prefix+t` shortcut;
2. host-architecture gate: `uname -s -m` must equal the endpoint's, otherwise the deploy
   fails at the build phase with no endpoint change;
3. build the release binary on the host and stream the self-contained plugin root as a tar
   archive into a temporary endpoint path over the argv-safe SSH runner (no remote shell
   path is built from a path), verify the transferred SHA-256, and prove the endpoint loader
   can execute that exact binary (an expected CLI exit is enough; failure prints
   `file`/`ldd`/glibc diagnostics);
4. commit the stage atomically, register and enable it, run `agent-tree.reload`, and require
   exactly one live subscriber whose executable is the staged binary with matching
   build/staged/running SHA-256;
5. install the managed sidebar rows fragment and the `prefix+t` shortcut if they are
   missing, migrate an existing managed shortcut fragment to `prefix+t`, and refuse a foreign
   `prefix+t` binding, preserving an existing matching fragment byte-for-byte. The shortcut uses the
   endpoint's resolved absolute `herdr` path (mise first, then `PATH`), so it does not depend
   on the key-command shell's `PATH`; the same absolute binary is used for the remote status
   probe. Remote paths and session values cross the SSH boundary only as argv (a base64
   payload executed without a shell), so spaces and single quotes in an override path work.
   The shortcut is composed by shell-quoting that absolute argv for execution and then
   TOML-encoding the complete command string, so a Herdr path with spaces or quotes still
   yields parseable `config.toml`.

A per-endpoint lock (`.agent-tree-deploy.lock` under the endpoint prefix) serializes deploy
and uninstall attempts; a concurrent attempt refuses before touching any stage. Concurrent
edits to the endpoint config are detected by a hash re-check immediately before the commit —
by both the deploy and the uninstall path — and are never overwritten, a symlinked config path
is refused, and the commit keeps a
recoverable pending marker plus a `cp -p` backup so an interrupted SSH commit is still
restored.

Any failure after the transaction opens automatically restores the previous stage (tracking each
commit substep, so a failure between the two stage moves still restores `.stage-old`),
registration/enabled state, and configuration, then re-establishes and verifies the previous
subscriber using that prior registered root's own binary. Every signal is guarded by a
captured Linux process start time, so a reused PID is never signaled: a subscriber that was
actually replaced is identity-verified and stopped before its stage is moved, and no
`.stage-failed.*` (deleted) holder is ever stranded. If the rollback itself fails, both the
previous and candidate stage directories are kept and the original phase plus the rollback
failure are reported; the lock is released on every exit, and only when its owner token still
matches this invocation. `--uninstall` is explicit-endpoint and transactional: it preflights
the registry, ownership, config marker validity and the prospective config bytes and the
subscriber identity before stopping anything, refuses a registration outside that endpoint's
own prefix, then identity-verifies and stops the subscriber (same UID, plugin id, socket,
state dir, `agent-tree subscriber` argv and an owned executable) before unlinking. Registry
fetch/parse and unlink failures are hard errors, and a later config, registry or stage failure
— including a failure to delete the staged root or a leftover `.stage-*` transaction
directory — automatically restores the prior config, registration/enabled state, stage and
subscriber or reports the exact rollback failure. It is reversible by re-running the deploy.

`scripts/doctor.sh` is read-only and reports, per endpoint: Herdr reachability/version/
protocol, plugin registration and source, staged/running SHA-256 and subscriber count, toggle
action availability and tree-off state, shortcut presence, `$agent_tree_row` presence, and
pane counts. Pane classification uses only pane-published tokens: a pane that declares
`role` worker/subagent but lacks a complete relationship is counted separately from an
ordinary tokenless Pi pane whose role is unknown. Nothing is inferred from a title, name, or
cwd. A representative report where the local endpoint is healthy and a saved endpoint has the
shortcut and row token but no plugin:

```
endpoint: local (kind: local)
  herdr:       running 0.9.0 (protocol 22, compatible=True, min 0.9.0)
  plugin:      Agent Tree 0.1.0 enabled at ~/.local/share/herdr-agent-tree/stage (source local)
  executable:  0a7e7a77...  ~/.local/share/herdr-agent-tree/stage/src/agent-tree
  subscriber:  1 running pids 961729 (sha256 matches registered executable)
  toggle:      action available, tree-off False
  shortcut:    present prefix+t
  sidebar:     $agent_tree_row present
  panes:       relationship-bearing 3 (valid 3), ranked 6, delegated-without-relationship 0, ordinary Pi 8
  verdict:     healthy
endpoint: archbox (kind: remote, machine cart-lab, ssh archbox, session default)
  herdr:       running 0.9.0 (protocol 22, compatible=True, min 0.9.0)
  plugin:      NOT registered
  ...
  verdict:     degraded
    issue: the agent-tree plugin is not registered

split state: one endpoint is healthy while another is degraded or unusable
routing: every line above targets the endpoint named on the command line; a machine selected in the TUI never retargets these commands.
```

`--json` emits a stable document (`{"endpoints": [...], "split_state": bool}`) for scripting.
The doctor never writes, signals a process, or reloads a server.

## Toggle Agent Tree ordering

Agent Tree exposes one owner-safe toggle. `agent-tree.toggle` turns the plugin's ordering on
when no plugin view is active, and off when this plugin owns the view:

```sh
herdr plugin action invoke agent-tree.toggle
```

- **No active plugin view -> tree.** The subscriber is ensured, the validated delegation
  projection is installed with label `tree`, and the sidebar shows the nested forest.
- **This plugin owns the view -> native.** Only this plugin's view is cleared; Herdr's
  existing native Agents list returns in whichever grouped/priority order the client already
  uses. The plugin never writes `ui.agent_panel_sort` and never creates or consumes
  sort-restore state.
- **Another source owns the view -> refused, unchanged.** Herdr has no restorable view stack,
  so the toggle fails clearly and leaves the foreign view exactly as it found it. An owner
  that cannot be determined also fails closed.

`agent_tree_row` and `agent_tree_rank` stay published in both states, so decorations remain
visible with tree ordering on or off; only the plugin-owned view changes. The tree-off state
is durable in a socket-scoped `tree-off-<tag>.flag` beside the subscriber lock, so a server
restart resumes the same ordering.

`apply` always means "show the tree": it clears the tree-off flag first. `clear` removes only
the plugin's own tokens and view and never touches the flag, so a clear while the native list
is showing stays native. The plugin runtime writes no configuration at all.

### Toggle with one keystroke

`herdr plugin action invoke` works from a `[[keys.command]]` shell entry. This is the
documented binding for the toggle. It uses Herdr's `prefix+t` form, valid custom command
syntax with no Alt/Meta chord:

```toml
[[keys.command]]
key = "prefix+t"
type = "shell"
description = "Toggle Agent Tree ordering on or off"
command = "herdr plugin action invoke agent-tree.toggle"
```

Press the prefix (`Ctrl+B` by default), release it, then press `t`: Herdr routes the next
keypress to itself instead of the pane. `prefix+t` is distinct from Herdr's built-in
`prefix+shift+t` "Rename tab" binding.

The earlier documented key was `prefix+alt+t`, which is unreliable: Alt/Meta chords only
reach Herdr when the terminal is configured to report Alt/Meta, and otherwise the chord is
silently swallowed. `prefix+t` has no such terminal dependency.

Reload it with `herdr server reload-config`; no server restart is needed. The plugin runtime
never writes `config.toml`. `scripts/deploy-endpoint.sh` installs the managed binding for a
named endpoint, migrates an existing managed binding to `prefix+t` idempotently, and refuses
a foreign `prefix+t` binding rather than overwriting it. An unmanaged binding (for example
one you added by hand) is left untouched: change its `key` to `prefix+t` yourself, then run
`herdr server reload-config`.

The native Agents header mouse press remains Herdr's own grouped/priority toggle. It works
whenever tree is off and is inert while tree is active, because Herdr disables the header's
sort hit region for any active agent view; that is a Herdr client behaviour, not something
this plugin overrides.

## Agents row configuration (verified fragment)

Herdr renders rows from `ui.sidebar.agents.rows`. This plugin's decoration only appears if
the row template references `$agent_tree_row`. `scripts/deploy.sh` appends this exact fragment, and
updates it on re-install if the managed block already exists (default cells keep the existing
theme; no theme colours are redefined):

```toml
[ui.sidebar.agents]
rows = [["state_icon", "$agent_tree_row", "terminal_title_stripped"]]
```

Rendered example from `tests/e2e/sidebar.sh` at its fixed 32-column sidebar (`tree` is the
projection label shown in the sidebar header):

```
 agents                    tree

 ○ π - root-alpha
 ○ └─W task-e2e… · π - worker-…
 ○ │  └─S ? · π - sub-alpha
 ○ π - root-beta
 ○ └─S · π - sub-beta
 ○ π - lone-1
 ○ π - lone-2
 ○
```

The last row is the test's synthetic non-Pi agent, which has no terminal title; the plugin
never decorates non-Pi rows, and this configuration does not identify them.

The rank token is deliberately **not** rendered; it exists only for ordering.

### Measured at real sidebar widths (task-4)

The same fixture was measured in the isolated instance at Herdr's `sidebar_min_width` (18),
default `sidebar_width` (26), the test's pinned 32, and `sidebar_max_width` (36). A root title
fits at every width. A Worker clips in both cells: at 26 and 32 the clipped task id
(`task-…`, `task-e2e…`) still identifies the Worker, while at 18 only `└─W t…` remains and the
title is `π - …`. Nesting glyphs stay readable from 26 up, and at 18 the depth-2 role letter
clips while the branch glyphs remain:

```
 18  ○ └─W t… · π - …
 26  ○ └─W task-… · π - work…
 32  ○ └─W task-e2e… · π - worker-…
 36  ○ └─W task-e2e ▸ · π - worker-al…
```

At 36 the full 14-character decoration, including the `▸` attention glyph, is visible and only
the title clips. `rows_by_agent` cannot shorten a Worker specifically: it keys on canonical
agent IDs, so every Pi root, Worker and Subagent matches `pi`, and a `worker` key is rejected
by `herdr config check` (`unknown canonical agent id`). The measured alternatives and raw
renders are in `docs/agent-tree/task-4-measurements.md`.

### Which agent is which (task-5)

A Subagent row previously read `└─S · herdr · main`: it repeated the parent's workspace and
tab and never named the Subagent. The fix is **option 3, row configuration**: render
`terminal_title_stripped` instead of `workspace`/`tab`. No plugin token, contract or `.pi`
change was needed.

Pi already publishes the name, so option 1 (Pi-side naming) is satisfied as-is:
`herdr agent list` gives Workers and Subagents durable names (`worker-task-108-459649c8`,
`decoration-tracer`), and Pi titles every session itself — `π - ffsync` for a top-level
session, `π - decoration-tracer - worker-task-5-…` for a Subagent (name first, parent context
after), and `π - worker-task-108-…` for a Worker (the worktree name). Because the name is
already on the wire, no `.pi` Task was filed; the gap was rendering only.

The rejected alternatives and why:

- **Option 2, name inside `agent_tree_row`.** The decoration is one 20-character token that
also carries depth glyphs, branch, role, the Worker `task_id` and the attention glyph. The M2
drop order is exactly the data a name would evict, and the C4 grammar
(`indent branch role [task] [attention]`) has no name slot; it would also need `AgentRow`
and digest changes for no gain over a built-in cell.
- **The `agent` cell as the sole identity cell.** Isolated renders show `agent` is a real
name cell (`worker-alpha`, not `pi`), but an unnamed agent renders its kind, and a top-level
Pi session has `name = null`. It would show `pi` for every root — the uninformative row this
Task set out to remove.
- **`agent` plus `terminal_title_stripped`.** The sidebar divides the row across its cells;
at 32 columns the fourth cell squeezed the name to `worker…` and the decoration to
`└─W tas…`, losing the `task_id` and degrading nesting legibility.

Width is why the decoration comes first and the title last: the title is clipped, not the
nesting. The 20-character cap limits the token value, not the row, so the short decoration
leaves most of the sidebar to the name. A Worker's title is long enough to clip at real
sidebar widths; the decoration's `task-N` still identifies it and the
`π - worker-task-N-…` prefix reinforces it. A real non-Pi agent with no terminal title
renders an empty identity cell under this configuration; non-Pi rows are unranked, never
decorated, and out of scope for task-5.

Optional styling with existing palette values (not verified in this session):

```toml
# [ui.sidebar.agents]
# rows = [["state_icon", { token = "agent_tree_row", fg = "#8ec07c", dim = true },
#          "terminal_title_stripped"]]
```

Rollback of the fragment: delete the `[ui.sidebar.agents]` block (or restore the rows value
you had before). Herdr's defaults apply underneath. The plugin runtime writes no
configuration; `scripts/deploy.sh` only manages the marked rows block above.

## Rollback

```sh
herdr plugin action invoke agent-tree.clear   # clears only agent_tree_row/agent_tree_rank and our view
herdr plugin disable agent-tree              # Herdr clears the view; tokens remain (see limitations)
herdr plugin unlink agent-tree               # unregisters; leaves files alone
```

`clear` removes exactly the two plugin tokens (source `agent-tree`) and only clears the view
when this plugin owns it; it writes no configuration. A running subscriber restores its
projection on the next relevant event, so `clear` is a one-shot reset. To leave the tree for
Herdr's native Agents list for more than a moment, use
`herdr plugin action invoke agent-tree.toggle` (see "Toggle Agent Tree ordering").

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
5. **Worker recovery conflict after a tokenless restart (`.pi` task-189).** A Worker whose
   own durable tokens are gone but whose Worker-owned Subagent still carries a validated edge
   is parent-valid, so it receives a rank; Pi's recovery guard then refuses that Worker with
   `has incomplete or conflicting Herdr metadata rather than a tokenless restart identity;
   recovery made no changes.` Retry `worker_recover` once Pi republishes the Worker's durable
   tokens, or stop/clear this plugin first. Transient, non-destructive, self-healing. The
   conflict was a stated prerequisite for the live enable; the plugin has since been enabled
   live (2026-09-15), so it remains a caveat to watch rather than an open gate.
6. **Identity clips at real sidebar widths (task-4).** The single-row configuration is
   retained after measuring it at 18, 26, 32 and 36 columns. A Worker carries a 14-character
   decoration and a long title, so at 26 and 32 both cells clip (`└─W task-… · π - work…` and
   `└─W task-e2e… · π - worker-…`) and the clipped task id still identifies the Worker; at 18
   only `└─W t… · π - …` remains, so identity is weak there though the nesting glyphs are
   intact. Nesting glyphs stay readable from 26 up, and at 18 the depth-2 role letter clips
   (`│  └─…`).
   Measured alternatives were rejected: a second row doubles the vertical cost of every
   agent, title-first only moves the clipping onto the decoration, adding the `agent` cell
   clips the decoration to `└─W t…` and loses the task id, and `rows_by_agent` keys on
   canonical agent IDs, so all Pi agents share `pi` and a `worker` key is rejected by
   `herdr config check`. Raw renders: `docs/agent-tree/task-4-measurements.md`.
7. **An agent with no terminal title renders an empty identity cell (task-4).** The identity
   cell is `terminal_title_stripped`, so a non-Pi agent (the test's synthetic `codex` row)
   and any agent that never sets a title leave it blank; the plugin never decorates non-Pi
   rows, so it cannot fill that cell. The measured fix — adding the `agent` cell — shows
   `codex`, but it splits the row further, clipping the Worker decoration to `└─W t…` and the
   Subagent decoration to `│  └─…` and evicting the task id. The empty cell is therefore
   documented rather than fixed.

## Unverified

The live install (2026-09-15) verified installation, enablement and the rendered tree; the
owner-safe toggle and Herdr's native header behaviour were verified in isolation. Still
unverified: mouse targets on other surfaces, indexed `focus_agent` bindings, the visual focus
ring, `workspace_order` / `tab_order` as secondary sort fields, and styled token rendering in
a real theme.
