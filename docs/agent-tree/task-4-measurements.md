# task-4 measurements — agent identity at real sidebar widths

Evidence record for Tandem task-4 ("Show which agent a row belongs to without clipping").
Outcome: **the current single-row configuration is retained.** This document is the measured
trade that justifies that decision and the raw renders behind it.

## Scope and isolation

- Measured in the demo's isolated Herdr instance (own `HOME`, XDG dirs and explicit socket;
  the active server at `/home/ivan/.config/herdr/herdr.sock` was never contacted),
  Herdr 0.9.0, protocol 22.
- Fixture: the `demo.sh` delegation family — 7 credential-free idle Pi agents plus the
  synthetic `codex` row — with relationship tokens published as `pi-agency` publishes them,
  and the plugin's `tree` projection applied.
- Method: the kept isolated instance from `./demo.sh --print --keep`; the isolated
  `config.toml` was rewritten (all three sidebar widths pinned to the measured column count)
  and applied with `herdr server reload-config`; the sidebar was rendered through the demo's
  tmux PTY helper and cropped to the configured width. Every rewritten config passed
  `herdr config check` (the one invalid variant is called out below).
- Widths: 18 (Herdr's `sidebar_min_width`), 26 (default `sidebar_width`), 32 (the demo's
  pinned width), 36 (`sidebar_max_width`).
- In the transcripts below a leading `|` marks the first column and a trailing `|` marks the
  configured width, so clipping is visible.

## Published values behind the render

`herdr agent list` on the isolated instance at the time of measurement:

| agent | `terminal_title` | `agent_tree_row` | role | task_id | handoff | rank |
| ----- | ---------------- | ---------------- | ---- | ------- | ------- | ---- |
| root-alpha | `π - root-alpha` | (none) | – | – | – | 000001 |
| worker-alpha | `π - worker-alpha` | `└─W task-demo ▸` (15 chars) | worker | task-demo | reported | 000002 |
| sub-alpha | `π - sub-alpha` | `│  └─S ?` (8 chars) | subagent | – | – | 000003 |
| root-beta | `π - root-beta` | (none) | – | – | – | 000004 |
| sub-beta | `π - sub-beta` | `└─S` | subagent | – | – | 000005 |
| lone-1, lone-2 | `π - lone-1`, `π - lone-2` | (none) | – | – | – | – |
| codex (synthetic) | (none) | (none) | – | – | – | – |

The Worker decoration is 15 characters — inside the documented 20-character cap and the C4
grammar (`indent branch role [task] [attention]`). The clipping below is Herdr's row-cell
allocation, not a token overrun.

## Current configuration at each width

`rows = [["state_icon", "$agent_tree_row", "terminal_title_stripped"]]`

### 18 columns

```
 agents      tree
 ○ π - root-alpha
 ○ └─W t… · π - …
 ○ │  └─… · π - …
 ○ π - root-beta
 ○ └─S · π - sub…
 ○ π - lone-1
 ○ π - lone-2
 ○
```

### 26 columns

```
 agents              tree
 ○ π - root-alpha
 ○ └─W task-… · π - work…
 ○ │  └─S ? · π - sub-al…
 ○ π - root-beta
 ○ └─S · π - sub-beta
 ○ π - lone-1
 ○ π - lone-2
 ○
```

### 32 columns

```
 agents                    tree
 ○ π - root-alpha
 ○ └─W task-dem… · π - worker-…
 ○ │  └─S ? · π - sub-alpha
 ○ π - root-beta
 ○ └─S · π - sub-beta
 ○ π - lone-1
 ○ π - lone-2
 ○
```

### 36 columns

```
 agents                        tree
 ○ π - root-alpha
 ○ └─W task-demo ▸ · π - worker-al…
 ○ │  └─S ? · π - sub-alpha
 ○ π - root-beta
 ○ └─S · π - sub-beta
 ○ π - lone-1
 ○ π - lone-2
 ○
```

### Observations

- A root row has no decoration and its title fits (`π - root-alpha`, 14 chars) at every
  measured width, including 18.
- The Worker row overflows in both cells. The decoration loses the attention glyph and part
  of the task id first: `└─W task-demo ▸` → `└─W task-dem…` (32) → `└─W task-…` (26) →
  `└─W t…` (18). The title clips to `π - worker-…` (32), `π - work…` (26), `π - …` (18).
- The `task-…` fragment identifies the Worker at 26 and 32 (`task-…`, `task-dem…`), matching
  the live row (`└─W task-… · π - work…`) recorded in the task; at 18 only `t…` remains. At 36
  the full 15-character decoration, attention glyph included, is visible and only the title
  clips.
- Nesting stays readable from 26 up: `└─W`, `│  └─S`, `└─S` all survive. At 18 the depth-2
  Subagent decoration clamps to `│  └─…`, losing the `S` role and `?` attention; the branch
  glyphs (`│`, `└─`) remain, so parent-child structure is still legible but role is not.

## Rejected alternatives (measured)

### A second row

`rows = [["state_icon", "$agent_tree_row", "terminal_title_stripped"], ["terminal_title_stripped"]]`

26 columns:

```
 ○ π - root-alpha
   π - root-alpha
 ○ └─W task-… · π - work…
   π - worker-alpha
 ○ │  └─S ? · π - sub-al…
   π - sub-alpha
 ...
```

The second line shows the full title, but it applies to every agent, not only Workers, and
doubles the row count (16 agent rows for 8 agents versus 8). At 18 even the second line clips
(`π - worker-al…`). It buys legibility for one cell at the cost of roughly twice the
vertical space in the panel.

### Title first

`rows = [["state_icon", "terminal_title_stripped", "$agent_tree_row"]]`

26 columns:

```
 ○ π - root-alpha
 ○ π - worke… · └─W task…
 ○ π - sub-al… · │  └─S ?
 ○ π - root-beta
 ○ π - sub-beta · └─S
```

18 columns:

```
 ○ π - w… · └─W …
 ○ π - s… · │  └…
```

This only moves the clipping onto the decoration: at 26 the Worker decoration is
`└─W task…`, and at 18 it is `└─W …` with the task id gone and the Subagent reduced to
`│  └…` with the role gone. The Worker title improves only from `π - work…` to
`π - worke…` at 26. No nesting gain.

### `agent` plus title (four cells)

`rows = [["state_icon", "$agent_tree_row", "agent", "terminal_title_stripped"]]`

26 columns:

```
 ○ root-alpha · π - root…
 ○ └─W t… · work… · π - …
 ○ │  └─… · sub-… · π - …
 ○ root-beta · π - root-…
 ○ └─S · sub-be… · π - s…
 ○ lone-1 · π - lone-1
 ○ lone-2 · π - lone-2
 ○ codex
```

The synthetic `codex` row now renders a name, so this is the only measured variant that
fills the untitled-agent cell. The price is exactly the M2 constraint: the Worker decoration
clips to `└─W t…` (task id lost) and the Subagent decoration to `│  └─…` (role lost). This
reproduces the alternative rejected in task-5 and is worse than the empty cell.

### `rows_by_agent`

`herdr --default-config` documents the table as "Optional canonical agent IDs replace the
default rows for matching agents" with a `claude = ...` example.

- All Pi agents in the fixture report `agent: "pi"` in `herdr agent list`, regardless of
  role: roots, the Worker, Subagents and lone sessions.
- Measured with `[ui.sidebar.agents.rows_by_agent] pi = [["state_icon", "agent"]]`, every Pi
  row — root, Worker, Subagent and lone session — switched to the same override:

  ```
   ○ root-alpha
   ○ worker-alpha
   ○ sub-alpha
   ○ root-beta
   ○ sub-beta
   ○ lone-1
   ○ lone-2
   ○
  ```

  The `codex` row kept the default rows and stayed empty. The override is keyed by agent
  kind, so it cannot shorten a Worker's identity specifically.
- A role-scoped key is rejected by the config parser. `herdr config check` with
  `[ui.sidebar.agents.rows_by_agent] worker = [["state_icon", "agent"]]`:

  ```
  config: issues found
  config parse error: TOML parse error at line 16, column 1
     |
  16 | [ui.sidebar.agents.rows_by_agent]
     | ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  unknown canonical agent id `worker` in sidebar rows_by_agent
  ; using defaults
  exit=1
  ```

## Conclusion

Retain `rows = [["state_icon", "$agent_tree_row", "terminal_title_stripped"]]`.

No measured alternative improves Worker identity without clipping the nesting or evicting the
task id: the second row doubles vertical cost for every agent, title-first only relocates the
clip, the `agent` cell damages the decoration, and the only role-specific mechanism is
unavailable (`rows_by_agent` keys on agent kind; a `worker` key is invalid). The empty
identity cell for an untitled agent is documented in the README's Known limitations rather
than fixed, because the only measured fix degrades nesting legibility.

Caveat: this fixture's Worker title (`π - worker-alpha`, 16 columns) is shorter than a live
Worker's worktree-name title. The live observation recorded in task-4 (`└─W task-… ·
π - work…`) matches the 26-column measurement here, so the measured trade is representative;
a longer title clips further inside the same measured row budget and does not widen the
decoration.

Raw captures (temporary, not committed): the width/layout transcripts and the
`herdr config check` output were produced by a throwaway harness under `/tmp/task4/`.
