# Task 10 spike — grouped → priority → tree agent-mode cycle

Status: **finding only, no implementation.** This is a tagged spike; the worktree is
discarded after the finding. Every claim below was observed in an **isolated Herdr 0.9.0
instance** (own `HOME`, XDG dirs and socket, verified with `herdr status`); the live server
and `~/.config/herdr` were never written or signaled. Herdr binary:
`/home/ivan/.local/share/mise/installs/herdr/0.9.0/herdr` (protocol 22).

## 1. Finding

There is **no socket/CLI method to select the native agent-panel ordering at runtime**. The
native mode is selected only by the `ui.agent_panel_sort` config key, and a running server
picks up a change live through `server.reload_config` (`herdr server reload-config`) without
a server restart:

| config `ui.agent_panel_sort` | plugin view | sidebar header | row order |
| --- | --- | --- | --- |
| `"spaces"` (alias `"workspaces"`) | none | `grouped` | workspace order |
| `"priority"` | none | `priority` | attention queue: blocked, working, idle, unknown |
| any | ours, label `tree` | `tree` | our rank token, then native order |

The recommended mechanism delegates grouped/priority to the **native** modes (config value +
reload) and keeps `tree` as the existing source-owned view. An alternative — expressing all
three modes as plugin views — was rejected: native grouped/priority are equivalent by
construction, while a view can only approximate them (native priority happened to match a
view sort by `attention` `desc` for the exercised fixture, and native grouped passed the same
order as a view sort by `workspace_order`; done/seen semantics, machine grouping and tie
breaks were **not** reproducible in isolation).

### 1.1 Native mode selection (observed, isolated)

```
# config.toml
[ui]
agent_panel_sort = "priority"      # or "spaces"; "workspaces" is accepted as an alias
```

```
$ herdr server reload-config
{"result":{"diagnostics":[],"status":"applied","type":"config_reload"}}
```

* The server PID did not change; no restart, no client disruption.
* Header labels are rendered by Herdr: `grouped` for spaces, `priority` for priority.
* Fixture (four reported agents, one per workspace, in creation order
  `idle-one, blocked-two, working-three, unknown-four`):
  * `spaces` → `idle-one blocked-two working-three unknown-four`
  * `priority` → `blocked-two working-three idle-one unknown-four`
* View active at the same time as a config change: `server.reload_config` leaves the view
  **and** the plugin's pane tokens untouched. The view owner was re-probed after reload with
  a foreign-source `agent.view.clear` and still returned
  `{"active":true,"source":"plugin:agent-tree","label":"tree"}`.
* `server.reload_config` does **not** re-run `[[startup]]` hooks (the plugin startup log
  stayed at exactly one entry across repeated reloads), so a reload can never start a second
  subscriber.

### 1.2 View semantics (confirmed against task-3 M1 evidence)

* `agent.view.set` / `agent.view.clear` are the only agent-panel view methods.
* A source-mismatched `agent.view.clear` is a read-only owner probe: it returns the active
  owner and changes nothing. This is how the cycle action detects the tree owner.
* A plugin-owned view is tied to an **enabled** plugin: with the plugin disabled,
  `agent.view.set` with its source fails `plugin_disabled`. The cycle action must therefore
  run as an action of `agent-tree` itself (source `plugin:agent-tree`).

### 1.3 Plugin-action environment (observed)

An action launched by Herdr receives the server environment plus the plugin context. It has
everything needed to implement the mechanism:

```
HOME=/tmp/<isolated>/home
XDG_CONFIG_HOME=/tmp/<isolated>/config
HERDR_SOCKET_PATH=/tmp/<isolated>/config/herdr/herdr.sock
HERDR_BIN_PATH=/home/ivan/.local/share/mise/installs/herdr/0.9.0/herdr
HERDR_PLUGIN_STATE_DIR=/tmp/<isolated>/state/herdr/plugins/<id>
HERDR_PLUGIN_ACTION_ID=...
```

So the action can read `$XDG_CONFIG_HOME/herdr/config.toml` (fallback
`$HOME/.config/herdr/config.toml`) and call either
`HERDR_BIN_PATH server reload-config` or the raw `server.reload_config` method.

## 2. Recommended mechanism

A new `cycle` action on `agent-tree` that advances `grouped → priority → tree → grouped`.

**Durable state needed: none beyond what already exists**, plus one restore record:

| state | meaning | owner |
| --- | --- | --- |
| `paused-<tag>.flag` (existing) | set = native panel; clear = tree projection | plugin state dir |
| `ui.agent_panel_sort` | `spaces` = grouped, `priority` = priority | `config.toml` (`[ui]`) |
| `original-sort-<tag>` (new) | user's pre-existing `ui.agent_panel_sort` value (or "absent") captured before the first write | plugin state dir |

No separate mode file is required: the existing pause flag already distinguishes tree from
native across a restart, and the config value distinguishes grouped from priority.

### 2.1 Mode detection

```
owner, own  = view owner probe (foreign-source agent.view.clear)
if owner is some other source:  refuse to cycle (never evict a foreign owner)
if pause flag is set:           grouped  if config value is "spaces"/"workspaces"/absent/invalid
                                priority if config value is "priority"
else:                           tree
```

If the pause flag is set **and** our view is active, that is a desync; clear the view
(source-checked) and treat the mode as native. The subscriber already implements exactly this
branch in its reconcile pass.

### 2.2 Transitions

| from → to | actions |
| --- | --- |
| grouped → priority | write `agent_panel_sort = "priority"` if different; `server.reload_config` |
| priority → tree | clear the pause flag; ensure the subscriber (the existing `apply` path); the subscriber sets the `tree` view and republishes tokens |
| tree → grouped | clear the `tree` view (source-checked); clear `agent_tree_row`/`agent_tree_rank`; set the pause flag; write `agent_panel_sort = "spaces"` if different; `server.reload_config` |

Set the pause flag **before** writing config so a concurrent subscriber pass cannot reinstall
the view; the subscriber's paused pass is already a no-op that sets no view.

### 2.3 Header labels and tokens

* grouped: native header `grouped`; both plugin tokens cleared.
* priority: native header `priority`; both plugin tokens cleared.
* tree: view label `tree`; `agent_tree_row`/`agent_tree_rank` published as today.

### 2.4 Config reload and server restart

* **Config reload** (`server.reload_config`) applies `agent_panel_sort` live and preserves the
  view, tokens and subscriber. No restart is needed for any transition.
* **Server restart** drops views and pane tokens; the pause flag and `config.toml` survive.
  The startup hook (`agent-tree start`) already checks the pause flag and, when set, leaves
  the native panel alone and starts no subscriber; when clear, it starts the subscriber and
  the tree view returns. Verified: paused restart → header `grouped`/`priority`, view
  inactive, zero isolated subscribers, startup stderr
  `agent-tree: paused; leaving Herdr's native Agents panel alone and not starting a subscriber`;
  unpaused restart → header `tree`.
* `reload_config` must **not** be used to re-run startup work; it does not, and should not be
  relied on for that.

### 2.5 Preserving unrelated configuration

* Edit only the `agent_panel_sort` line inside the existing `[ui]` table; never append a
  second `[ui]` table and never reformat other keys.
* Capture the pre-existing value once, before the first write, in `original-sort-<tag>`, and
  restore it (removing the key if it was absent) on `clear`/uninstall.
* Observed with an explicit user original (`agent_panel_sort = "workspaces"`): after
  grouped → priority → tree → grouped the only file diff was that one line; `clear` restored
  the file **byte-identical** to the original; `herdr config check` stayed `ok`.
* `herdr config check` and `server.reload_config` accept an unknown enum value without
  diagnostics and Herdr silently falls back to `grouped` — so the plugin must write only
  `"spaces"`/`"priority"` and must treat an unrecognised existing value as grouped rather
  than inferring acceptance from diagnostics.

## 3. Reproducible isolated check

The harness is kept beside this document at `docs/agent-tree/task-10-reference/` (id
`t10.cycle`, source `plugin:t10.cycle`): a `herdr-plugin.toml` and a `bin/cycle.py` whose
`cycle` action implements §2.1–§2.3. It is a spike artifact, not plugin source, and is not
linked by the build, `just deploy` or CI. Core steps, all against an isolated socket:

```sh
TMP=/tmp/task10/inst
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/config" XDG_STATE_HOME="$TMP/state" \
       XDG_DATA_HOME="$TMP/data" XDG_RUNTIME_DIR="$TMP/run" \
       HERDR_SOCKET_PATH="$TMP/config/herdr/herdr.sock"
HERDR=/home/ivan/.local/share/mise/installs/herdr/0.9.0/herdr
setsid "$HERDR" server >"$TMP/logs/server.out" 2>&1 </dev/null &
# fixtures: one workspace + reported agent per state (idle, blocked, working, unknown)
REPO=$(git rev-parse --show-toplevel)
herdr plugin link "$REPO/docs/agent-tree/task-10-reference" --enabled
herdr plugin disable agent-tree            # keep this spike's own view out of the way
herdr plugin action invoke t10.cycle.cycle   # -> {"from":"grouped","to":"priority",...}
herdr plugin action invoke t10.cycle.cycle   # -> {"from":"priority","to":"tree",...}
herdr plugin action invoke t10.cycle.cycle   # -> {"from":"tree","to":"grouped",...}
```

Observed sequence with a real tmux PTY capture after each action:

```
priority | blocked-two working-three idle-one unknown-four
tree     | (rank order)   header tree
grouped  | idle-one blocked-two working-three unknown-four
priority | blocked-two working-three idle-one unknown-four
tree     | (rank order)   header tree
```

Restart check:

```sh
herdr server stop; setsid "$HERDR" server ...      # restart, isolated socket only
# paused restart:  header grouped|priority, view inactive, no isolated subscriber
# unpaused restart: header tree (startup hook re-projects)
```

Live-owner control (view persistence): a view owned by a second plugin with no startup hook
was gone after `herdr server stop` + start, proving views do not survive a restart on their
own and that the restart result comes from the pause flag + startup hook.

## 4. Risks and limits of this finding

1. **The plugin must edit user `config.toml` at runtime.** No API exists to set the native
   sort. The edit is one key inside `[ui]`, but it is the first runtime config write in this
   project (the README currently states the plugin runtime writes no configuration). If the
   parent rejects runtime config writes, the only alternative is approximating native modes
   with plugin views, which the task constraints forbid without demonstrated equivalence.
2. **A concurrent config writer** (Herdr TUI Settings, another plugin, or
   `scripts/deploy.sh`'s managed block) could race the key. The writer must re-read and
   replace only the exact `agent_panel_sort` line.
3. **`agent_panel_sort` is user-global while the pause flag is socket-scoped.** Two Herdr
   sessions sharing one `HOME` will share the config value but load it at different times;
   a cycle in one session does not reload the other.
4. **Foreign view owner**: if another plugin/source owns the agent view, the cycle refuses
   rather than evicting it (consistent with the plugin's existing ownership rule).
5. **Invalid config values** are silently treated as grouped; detection must be explicit, not
   inferred from `config check`.
6. The `original-sort` restore record is only as good as the `clear`/uninstall path that runs
   it; `plugin unlink` runs no plugin code, so restoration must be attached to `clear` (and to
   `scripts/deploy.sh --uninstall`, which already manages the rows block).
