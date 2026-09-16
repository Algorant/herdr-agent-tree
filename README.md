# Agent Tree

Shows Pi Subagents and Workers beneath the immediate agent that spawned them in Herdr's
native Agents sidebar. One session-wide forest: a top-level Pi session first, then its
validated Subagents and Workers, with a Worker-launched Subagent nested under that Worker —
including across tabs and workspaces.

It is an external Herdr plugin. It never changes Pi, never writes Pi-owned metadata, and
never touches panes it cannot validate.

Status: MVP. Rendering, ordering, identity validation and lifecycle were observed in an
isolated Herdr 0.9.0 server (see "Verified behavior" below). The plugin has also been
installed and enabled on Algorant's live Herdr server since 2026-09-15, from the staged
release root that `scripts/deploy.sh` produces; the toggle and the tree were verified there.
`tests/e2e/sidebar.sh` exercises it on a real fixture in a throwaway instance (see
"End-to-end test").

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
- `just` for the developer recipes (`just test`, `just build`, `just deploy`).

## Build

```sh
just build
# equivalent to: cargo build --locked --release --manifest-path Cargo.toml
```

The manifest runs `./src/agent-tree`, a launcher that execs the optimized release binary
`target/release/agent-tree` (override with `AGENT_TREE_NATIVE_BIN`).
Linking this source checkout directly, or running `scripts/deploy.sh`, is a development install
from a checkout. The supported path for a normal user is a release install (see "Install" below).

## Test

```sh
just test
```

`scripts/check.sh` is the single authoritative gate: formatting, Clippy, Rust tests, the locked
build, shell syntax checks, the installer and release suites, and the noninteractive isolated
Herdr end-to-end test below. The Rust suite runs against the plugin's own logic with Rust's
standard test harness and needs no running Herdr server, no socket and no network. It covers
identity recomputation and self-validation, unique parent resolution and the tokenless-parent
refinement, every contract C5 degenerate case, preorder emission with family contiguity and
native ordering, the rank format and its ceiling, the decoration grammar and 20-character cap,
the paused flag, the verified reload holder checks (including the `(deleted)` staged binary),
and the CLI boundary where `apply` clears the paused flag while `clear` leaves it.
`tests/shell/dev-reload.sh` drives the real `scripts/deploy.sh` against a fake `herdr`, a fake
`cargo` and a local socket server to cover first install, repeated reload, stale-lock recovery
and foreign-holder refusal without a live Herdr server. Hosted CI runs
`scripts/check.sh --no-e2e` because its runner has no Herdr or Pi.

## End-to-end test

```sh
tests/e2e/sidebar.sh   # also run by `just test`
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

### Release install (the normal user path)

The supported install path for a normal user is a published release artifact. **No tagged
release has been published yet**, so there is nothing to download today; this documents the
path a user takes once the owner approves publication. The release machinery and installer are
ready and owner-gated (see `docs/release.md`).

The release installer downloads one archive over HTTPS only, verifies a SHA-256 you pin,
enforces a strict archive allowlist and commits an atomic versioned install. It registers the
plugin **disabled** and never edits your Herdr configuration.

A normal user does not have this checkout. Obtain the installer from the exact tagged
repository revision and run it from a file:

```sh
version=0.1.0
target=x86_64-unknown-linux-musl   # or aarch64-unknown-linux-musl
curl --fail --location --proto '=https' --proto-redir '=https' \
  --output install-agent-tree.sh \
  "https://raw.githubusercontent.com/Algorant/herdr-agent-tree/v$version/scripts/release/install.sh"
less install-agent-tree.sh
```

Do not pipe a download into a shell (`curl ... | sh`). Review the saved script, then run it with
the pinned version, target and checksum:

```sh
checksum=<sha256 from the release's agent-tree-v$version-SHA256SUMS>
chmod 755 install-agent-tree.sh
./install-agent-tree.sh --version "$version" --checksum "$checksum" --target "$target"
```

Obtain the version and lowercase SHA-256 digest through a separately trusted channel. A checksum
copied only from the same GitHub release detects corruption but does not authenticate the
publisher.

It installs to `${XDG_DATA_HOME:-$HOME/.local/share}/herdr-agent-tree/<version>/<target>`
(`--prefix DIR` overrides it). This path is separate from the development stage below. The
archive is `agent-tree-v<version>-<target>.tar.gz` under
`https://github.com/Algorant/herdr-agent-tree/releases/download/v<version>/`. `--target` is
optional on Linux and detects `x86_64` or `aarch64`; `--herdr PATH` / `HERDR_BIN_PATH` selects
Herdr and `--no-link` skips registration.

### Activate a release install (manual)

The installer deliberately leaves activation to you; it never writes `config.toml` or enables
the plugin. After it installs and links the plugin:

1. Add the sidebar rows block from "Agents row configuration" below.
2. Enable, reload and apply:

```sh
herdr plugin enable agent-tree
herdr server reload-config
herdr plugin action invoke agent-tree.apply
```

Without the rows block, the plugin's decoration has no cell to render into. `plugin link`
registers the plugin; the startup hook runs on the next **server start**, not on link or
enable, which is why the explicit `apply` is part of activation.

### Update

Download and review the new tag's installer (as above), then re-run it with the new version and
checksum:

```sh
./install-agent-tree.sh --version 0.2.0 --checksum <sha256> --target x86_64-unknown-linux-musl
```

Versions install side by side under the same prefix, and the installer never overwrites an
existing `<version>/<target>`. Point `herdr plugin link` at the new directory (the installer
does this when Herdr is found) and remove the old one when you are satisfied. There is no
`latest` and no current-version symlink: every install is an explicit version.

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

`apply` is unchanged and narrower: it only ensures some subscriber is present and re-installs
the projection once. Use it to restore the projection after a mid-session socket loss, or
invoke the `reload` action directly:

```sh
herdr plugin action invoke agent-tree.apply
herdr plugin action invoke agent-tree.reload
```

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

This loop is not the same as the other two paths. A normal user installs a published release
with `scripts/release/install.sh`, which verifies a caller-pinned checksum, never edits
`config.toml`, and registers the plugin **disabled** by default. `scripts/stage-local.sh` is
inert local staging: it writes a complete plugin root under the Cargo target directory and
never links it or touches user state.

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

## Toggle the projection off and on

The plugin sets its projection on top of Herdr's native Agents panel; it never replaces that
logic. `toggle` flips a paused flag in the plugin state directory and makes the change
visible immediately:

```sh
herdr plugin action invoke agent-tree.toggle
```

- Pausing clears `agent_tree_row`/`agent_tree_rank` and the plugin's `tree` view, so Herdr's
  native panel returns: whatever `agent_panel_sort` and your `ui.sidebar.agents.rows` give
  you with the plugin uninstalled.
- Toggling again restores the tree projection.
- While paused the subscriber publishes nothing and sets no view. It does not recompute
  quietly and then skip the write.
- `apply` always means "show the tree": it clears the paused flag first, so it can never be a
  silent no-op. `clear` never touches the paused flag, so a clear while paused stays clear.
- The flag is a socket-scoped file, `paused-<tag>.flag`, beside the subscriber lock in
  `HERDR_PLUGIN_STATE_DIR`. It holds nothing but its own existence.

Restart behaviour: the paused flag lives in the plugin state directory, the same place as the
subscriber lock, and the startup hook does not reset it. A deliberate off state therefore
survives a Herdr server restart: the startup hook starts no subscriber and the native panel
stays in place until you `apply` or `toggle` again. (If you want the tree back on restart,
run `apply` once, or delete `paused-*.flag` from the plugin state directory.)

### Toggle with one keystroke

`herdr plugin action invoke` works from a `[[keys.command]]` shell entry:

```toml
[[keys.command]]
key = "prefix+alt+t"
type = "shell"
description = "toggle the Pi delegation tree / native Agents panel"
command = "herdr plugin action invoke agent-tree.toggle"
```

Reload it with `herdr server reload-config`; no server restart is needed. The plugin never
installs this binding for you.

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
you had before). Herdr's defaults apply underneath; the plugin runtime writes no
configuration, and `scripts/deploy.sh` only manages the marked block above.

## Rollback

```sh
herdr plugin action invoke agent-tree.clear   # clears only agent_tree_row/agent_tree_rank and our view
herdr plugin disable agent-tree              # Herdr clears the view; tokens remain (see limitations)
herdr plugin unlink agent-tree               # unregisters; leaves files alone
```

`clear` removes exactly the two plugin tokens (source `agent-tree`) and only clears the view
when this plugin owns it. A running subscriber restores its projection on the next relevant
event, so `clear` is a one-shot reset. To keep the native panel for more than a moment, use
`herdr plugin action invoke agent-tree.toggle` (see "Toggle the projection off and on").

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

The live install (2026-09-15) verified installation, enablement, the toggle and the rendered
tree. Still unverified: mouse targets, indexed `focus_agent` bindings, the visual focus ring,
`workspace_order` / `tab_order` as secondary sort fields, and styled token rendering in a
real theme.
