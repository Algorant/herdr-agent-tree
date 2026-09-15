# M1 evidence record — isolated Herdr spike (Tandem task-3-1)

Evidence only. No plugin implementation exists in this repository as a result of M1.
Every statement below is labeled **live-observed** (a real process/server produced it),
**synthetic** (I published fixture values into an isolated server), **source-read**
(read from a file without executing it), or **unknown** (not established).

Environment: herdr 0.9.0, protocol 22, binary
`/home/ivan/.local/share/mise/installs/herdr/0.9.0/herdr`.
Public surfaces read at the commit pinned by the task:
`socket-api.mdx` and `plugins.mdx` at `b99002ac99b09e00b4ca692436cb15a6b0d676f1`.

The **active** server (`/home/ivan/.config/herdr/herdr.sock`) was used for read verbs only.
Section 2 lists every command that touched it.

---

## 1. Isolation recipe (exact commands)

Plugin registration is user-global, so a named session is not isolation. The isolated
instance gets its own `HOME`, XDG config/state/data/runtime dirs and an explicit socket.
Nothing under `/home/ivan/.config/herdr` is read or written by the isolated instance.

```sh
# throwaway isolation environment (lives in /tmp, removed in section 8)
M1=/tmp/agent-tree-m1
mkdir -p "$M1/home" "$M1/config" "$M1/state" "$M1/data" "$M1/run" "$M1/work" "$M1/logs"
chmod 700 "$M1/run"
cat > "$M1/env.sh" <<'EOF'
export M1=/tmp/agent-tree-m1
export HOME="$M1/home"
export XDG_CONFIG_HOME="$M1/config"
export XDG_STATE_HOME="$M1/state"
export XDG_DATA_HOME="$M1/data"
export XDG_RUNTIME_DIR="$M1/run"
export HERDR_SOCKET_PATH="$M1/config/herdr/herdr.sock"
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SESSION HERDR_ENV \
      HERDR_PLUGIN_ID HERDR_PLUGIN_ROOT HERDR_PLUGIN_CONFIG_DIR \
      HERDR_PLUGIN_STATE_DIR HERDR_PLUGIN_EVENT
EOF
. "$M1/env.sh"

# headless server on the isolated socket (never the active one)
setsid herdr server > "$M1/logs/server.out" 2>&1 < /dev/null &
sleep 3
herdr status                 # must print socket: /tmp/agent-tree-m1/config/herdr/herdr.sock
herdr workspace create --cwd "$M1/work" --label m1
```

Isolation was verified rather than assumed: `herdr status` reported
`/tmp/agent-tree-m1/config/herdr/herdr.sock` (**live-observed**), and `plugin link` wrote
`/tmp/agent-tree-m1/config/herdr/plugins.json` (**live-observed**, section 5).
The isolated `config.toml` was also used to set
`[server] headless_cols = 200`, `headless_rows = 50`,
`[experimental] allow_nested = true`, and `next_agent`/`previous_agent` keybindings.

Socket requests were sent with a throwaway helper that writes one newline-delimited JSON
request and prints the response line:

```python
# $M1/m1req.py  (reads JSON request lines on stdin, prints response lines)
import json, os, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(10)
s.connect(os.environ["HERDR_SOCKET_PATH"]); f = s.makefile("rwb")
for line in sys.stdin:
    if not line.strip(): continue
    f.write(line.encode()); f.flush(); print(f.readline().decode().rstrip())
```

The throwaway probe plugin (`$M1/probe-plugin/herdr-plugin.toml`, never in the repository)
declared one `[[startup]]` hook and one `[[events]]` hook on `pane.agent_status_changed`;
its scripts only appended to `$M1/logs/` and optionally published a view or a token when
driven by `M1_VIEW`/`M1_TOKENS`/`M1_EXIT` environment variables.

---

## 2. Active-socket read-only audit

Every contact with `/home/ivan/.config/herdr/herdr.sock` is listed here. No write verb,
`agent.view.*`, `report_metadata`, focus change, plugin operation, reload, restart or stop
was ever sent to that socket.

| # | command | kind |
| - | ------- | ---- |
| 1 | `herdr status` (default socket), run at the start of M1 and again after cleanup | read-only status report |
| 2 | raw `{"id":"m1-read-only","method":"agent.list","params":{}}` over that socket | read-only |
| 3 | amendment reads, all raw and read-only: `agent.list` (`m1-read-only-2`, `m1-read-only-5`, and three poll invocations), `pane.list` (`m1-read-only-3`), `workspace.list` (`m1-read-only-4`), `pane.get w7H:p2` (three poll invocations) | read-only |

Raw response (saved verbatim as `$M1/logs/active-agent-list.json`, 4431 bytes) contained
7 agents. Only one carried relationship tokens — this retained Worker:

```json
{"name":"worker-task-3-6bfac99d","agent":"pi","agent_status":"working",
 "workspace_id":"w7J","pane_id":"w7J:p1",
 "tokens":{"task_id":"task-3",
   "agency_self":"42199c1a2bd5c678b38ff4eccc372ea2a98eb788040190fbbae32a38600e25da",
   "role":"worker",
   "worker_context":"v1:7524a405956486af10582dfb302e6770cb343e5bc8242d171a3c797bd350063f",
   "started_at":"1789442758620",
   "agency_parent":"c527db1f988c0b2b71da916fdc1a19da908d217bca0249c755dfd087660b09c1",
   "orchestrator_workspace_id":"w7H",
   "handoff":"missing"},
 "agent_session":{"source":"herdr:pi","agent":"pi","kind":"path","value":"…jsonl"}}
```

The other six agents were `agent=pi` with **no tokens at all** (`keys=0`), i.e. plain Pi
sessions with no pi-agency relationship metadata (**live-observed**).

**Unknown:** the live subagent token set. No Subagent existed in the active session at read
time, so the subagent count below is source-read plus synthetic only.

> Amended in section 2.1: a live Subagent was subsequently observed, and this paragraph is
> kept to preserve the record of the first snapshot's scope.

### 2.1 Amendment — live Subagent observation and identity recomputation

The orchestrator created a live Subagent (`token-witness-2`) in its own workspace. Captured
with the same read-only rules, one raw `agent.list` request, raw output kept verbatim in
`active-agent-list-3.json` (8 agents). The relationship-bearing rows were:

```json
{"pane_id":"w7H:p4","name":"token-witness-2","agent":"pi","agent_status":"working",
 "workspace_id":"w7H","tokens":{
   "role":"subagent",
   "agency_self":"bd9cd5732a0e821dc7275766bbc0b23923b471f72d99acc75cbc553cec84830f",
   "agency_parent":"c527db1f988c0b2b71da916fdc1a19da908d217bca0249c755dfd087660b09c1"},
 "agent_session":{"source":"herdr:pi","agent":"pi","kind":"path",
   "value":"/home/ivan/.pi/sessions/subagent-7c1b66b8-8362-4ff1-a0fd-28cef8f2499a.jsonl"}}
```

The orchestrator's own pane (`w7H:p1`, the parent) carried **no tokens** (0 keys), and its
native session reference was
`/home/ivan/.pi/sessions/2026-09-15T03-04-02-851Z_01a0a305-8422-7258-93f9-859433517ce1.jsonl`.

Recomputing `sha256(JSON.stringify(["pi","path",<absolute session file>]))` with compact
separators against the native `agent_session.value` gave, for **two independent real
sessions**:

| row | session file | recomputed | published | result |
| --- | ------------ | ---------- | --------- | ------ |
| subagent `w7H:p4` | `…/subagent-7c1b66b8-….jsonl` | `bd9cd573…830f` | `bd9cd573…830f` | **match** |
| worker `w7J:p1` | `…/2026-09-15T03-25-56-022Z_01a0a319-….jsonl` | `42199c1a…e25da` | `42199c1a…e25da` | **match** |

Both rows' `agency_parent` was `c527db1f…09c1`, which is exactly the recomputed hash of
the **orchestrator's** session file — not mine — so parent identity was checked against a
second real identity rather than self-confirmed.

Live Subagent key set: `{role, agency_self, agency_parent}` (**3 keys**; the `question` token
is absent while no question is outstanding, so the source-read maximum of 4 in section 7 is
an upper bound, not the resting state). The first witness described by the orchestrator lived
only about 18 seconds; a poll in that window already showed a subagent row on `w7H:p4` with
those three keys, but that poll did not print the agent name, so it is not claimed which
witness it was. The named capture above is `token-witness-2`.

---

## 3. `agent.view.set` — ownership, ordering, tie-breakers, navigation

### 3.1 Ownership and clear semantics (synthetic, isolated server)

* `agent.view.set` with `source: "plugin:probe.m1"` **before** the plugin was registered
  returned `error code plugin_not_found`; after `herdr plugin link` it returned
  `{"type":"agent_view","active":true,"source":"plugin:probe.m1","label":"…"}`.
  A plugin-owned view requires a linked, enabled plugin (**live-observed**).
* With a view owned by `plugin:probe.m1`, sending `agent.view.clear` with
  `source: "plugin:other.tool"` returned
  `{"active":true,"source":"plugin:probe.m1","label":"m1-owner"}` and left the view intact.
  This makes a **source-mismatched clear a read-only owner probe**, which is how view
  ownership was checked throughout M1.
* Clearing with the owning source returned `{"active":false}`.
* A non-plugin source (`user:someone-else`) replaced a plugin-owned view atomically; the
  plugin's later source-checked clear returned the foreign owner and changed nothing
  (**live-observed**). A plugin cannot evict a competing owner through `agent.view.clear`.
* Sort entries must be shaped `{"field": <builtin|{"token":"name"}>,"order":"asc|desc"}`.
  The documentation's shorthand `{"token":"m1rank"}` as a whole sort entry is rejected:
  `error invalid_request: missing field 'field'` (**live-observed**).

### 3.2 Ordering is only observable in the TUI

`agent.list` and `session.snapshot.agents` did **not** change order after
`agent.view.set`; both stayed in native pane order while the TUI sidebar reordered
(**live-observed**). The socket schema exposes only `agent.view.set` / `agent.view.clear`,
with no query returning the resolved projection. Ordering evidence was therefore taken from
a real TUI client driven through a PTY:

```sh
( sleep 6; printf '\002q' ) | timeout 25 script -qec "stty cols 200 rows 50; herdr" "$raw"
python3 m1screen.py "$raw" 174 49     # replays ANSI into the final screen grid
```

Navigation was read from server state instead of pixels: after each keypress
`agent.list` shows which pane is `focused`.

### 3.3 Observed ordering rules (synthetic fixtures, rendered order)

Ranks were published as the token `m1rank` on three panes; native order is p1, p2, p4.

| case | token values (p1/p2/p4) | rendered sidebar order | conclusion |
| ---- | ----------------------- | ---------------------- | ---------- |
| no view | – (header `grouped`) | beta(p1), gamma(p2) | native order when no view is set |
| rank asc | `9`,`10`,`2` | gamma(`10`), delta(`2`), beta(`9`) | **lexicographic string compare**, not numeric |
| rank asc | `009`,`010`,`002` | delta(`002`), beta(`009`), gamma(`010`) | fixed-width zero-padded rank sorts numerically |
| equal ranks | `050`,`050`,`050` | beta(p1), gamma(p2), delta(p4) | stable tie-break falls back to native order |
| equal + secondary `pane_order desc` | `050`,`050`,`050` | delta(p4), gamma(p2), beta(p1) | an explicit second sort key controls the tie-break |
| one missing | *(none)*,`020`,`010` | delta(`010`), gamma(`020`), beta(missing) | missing values sort **after** present values |

The view label appears in the sidebar header (`agents   m1-glyph`), so an active view is
visible without reading the socket.

### 3.4 Navigation targets (live-observed, view order ≠ native order)

View order was beta(p1,`010`) → delta(p4,`020`) → gamma(p2,`030`); native order is p1, p2, p4.

| action | focused pane after | matches |
| ------ | ------------------ | ------- |
| start (`agent focus w1:p1`) | beta(p1) | – |
| `next_agent` | delta(p4) | view order (native would be gamma/p2) |
| `next_agent` | gamma(p2) | view order (native would be delta/p4) |
| `previous_agent` | delta(p4) | view order |

Next/previous agent navigation follows the projection order and focuses the correct pane.
`pane.focused` events fire for these changes (**live-observed**).

**Unknown / not verified:** mouse targets and indexed `focus_agent` bindings (not exercised);
the visual focus ring; behavior with a view whose filter uses `current_workspace_id`.

### 3.5 Nested-client hazard (live-observed)

Running a herdr TUI *inside a pane of the same server* collapsed the server's virtual
layout area to `width:4, height:1` (`pane.layout` reported degenerate pane rects) while the
nested client was attached, and the area returned to `200x50` on detach. Nested rendering is
therefore **not** a usable evidence path for a headless isolated server in 0.9.0; the PTY
client in 3.2 is. This is an observation about nesting, not about the plugin.

---

## 4. Token normalization, glyph prefixes and budgets

All values below were published with `pane.report_metadata` into the isolated server and
read back from `pane.get` (**synthetic**, exact post-normalization values):

| published value | stored value |
| --------------- | ------------ |
| `"  └─ child"` | `"└─ child"` |
| `"    └─ grandchild"` | `"└─ grandchild"` |
| `"│  └─ x"` | `"│  └─ x"` |
| `U+00A0 + "└─ x"` | `"└─ x"` |
| `U+2007 + "└─ x"` | `"└─ x"` |
| 100 × `x` | 80 × `x` |
| `""` | key cleared (absent) |
| `"a\tb"` | `"atb"` (control char removed, not replaced) |
| `"ab  "` | `"ab"` |

**Conclusion:** leading **plain spaces do not survive**; neither do NBSP or U+2007. A
multi-level prefix is only possible when the first character is a non-whitespace glyph
(`│`, `└`, `├`, `·`, …), with interior spaces preserved. Interior spaces after a glyph do
survive, so `│  └─` renders at a deeper indent than `└─`.

Budgets (synthetic, exact errors):

* 17 keys in one report → `error invalid_metadata_token: "a metadata report may update at most 16 tokens"`.
* 16 keys in one report → accepted; 32 retained keys accepted; the 33rd →
  `error metadata_token_limit: "pane metadata may contain at most 32 tokens"`.
* Consequence observed: a pane already at 32 keys silently rejects further NEW keys
  (the report fails), so a plugin publishing into a full pane would lose its tokens.

### 4.1 Sidebar row rendering of a custom token (live-observed)

With the isolated client config

```toml
[ui.sidebar.agents]
rows = [["state_icon", "machine", "workspace", "tab"], ["$m1rank", "agent"]]
```

the rendered rows were (`$`-token then ` · ` then the agent name):

```
agents          m1-glyph
○ m1
  002 └─ child · beta
● m1
  010 │  └─ gra… · gamma
● m1
  020 · delta
```

So: custom tokens do render in agent rows; glyph prefixes render at two depths; the sidebar
clips the row (`gra…`) at its width. A long decoration therefore pushes the identity part out
of view — relevant to the M2 decoration-length decision. Row rendering order followed the
rank sort, not native order.

---

## 5. Lifecycle observations (isolated instance)

| observation | result |
| ----------- | ------ |
| `herdr plugin link <dir> --enabled` | registers; writes `plugins.json`; **startup hook did not run** |
| server start / restart | `plugins.json` reloaded; **startup hook runs once per server start**, after session restore, with the API socket ready (it successfully published a view on the first try) |
| `herdr plugin enable` on an already-registered plugin | does **not** re-run the startup hook (log line count unchanged) |
| `herdr server stop` | socket disappears; the view and all pane token metadata are gone; panes are restored on the next start |
| restart after stop | panes `w1:p1,w1:p2,w1:p4,w1:p5` restored; `agent.list` empty (no agent rows); every pane `tokens` absent; source-checked view clear returned `active:false` |
| `herdr plugin disable` | the plugin-owned view is **cleared automatically** (`active:false`); pane tokens the plugin published **remain** |
| `herdr plugin unlink` | `plugins.json` becomes `[]`; view inactive; tokens remain; `agent.view.set` for that source now returns `plugin_not_found`; while disabled it returned `plugin_disabled` |
| crash-while-enabled (hook exits, process gone) | the view and tokens the hook published **persist** with no owning process alive; there is no automatic cleanup |
| failing hook (`exit 3`) | server keeps running; `plugin.log.list` reports `event=startup status=failed exit_code=3`; a view published before the failure still persisted |
| plugin stop hook | **does not exist** in the 0.9.0 manifest schema (only build/startup/actions/events/panes/link_handlers). "Stop" is disable, unlink or server stop |
| event hook | `pane.agent_status_changed` delivered to the hook as `HERDR_PLUGIN_EVENT_JSON` with pane_id/agent/agent_status (**live-observed**) |
| agentless panes | panes with no agent report never appear as agent rows (5 panes present, `agent.list` empty) |

Exactly one startup invocation per server start was observed across 4 applicable starts
(the earliest boot predates the plugin link).

### 5.1 Events usable for recomputation (live-observed)

Subscribing with `events.subscribe` acknowledges first
(`{"type":"subscription_started"}`) and then streams. Observed emissions:

* token write via `pane.report_metadata` → **`pane.updated`** carrying the full pane record
  including `tokens` and `revision`. Our own publication therefore emits an event, so a
  naive recompute-on-event loop self-triggers.
* agent state report → `pane.updated`; a `pane.agent_status_changed` subscription scoped to
  that pane also fired with `{pane_id, workspace_id, agent, agent_status}`.
* `pane.split` → `pane.created` + `layout.updated`.
* `agent focus` → `pane.focused` (`{pane_id, workspace_id}`).
* `workspace.report_metadata` → `workspace.metadata_updated` (available to subscribers, does
  not invoke plugin event hooks).

**Unknown:** whether token writes ever emit a dedicated metadata event (none observed);
event coalescing/batching behaviour under rapid updates (revisions advanced between
observations, but ordering guarantees were not established).

---

## 6. pi-agency tokenless-recovery conflict

**Source-read** (`/home/ivan/.pi/agent/extensions/pi-agency/workers/index.ts`):

* `worker_recover` first selects candidates with
  `candidate.tokens.role === "worker" && candidate.tokens.orchestrator_workspace_id === ownerWorkspaceId && candidate.tokens.task_id === params.taskId`.
* Only when that set is empty does it take the tokenless-restart branch, matching exactly one
  raw agent by name, and then evaluates (line 1843):

```js
if (agent.tokens && Object.keys(agent.tokens).some((key) => key !== "worker_context")) {
  throw new Error(`Worker ${params.agent} has incomplete or conflicting Herdr metadata rather than a tokenless restart identity; recovery made no changes.`);
}
```

**Premise (live-observed earlier in this run):** a server restart restores panes but drops
all pane token metadata, so a restored Worker pane initially has no tokens; pi-agency may
republish `worker_context` on reload.

**Reproduction (synthetic fixture pane `w1:p5`, guard expression copied verbatim from the
source line and evaluated with node against the token map read back from the isolated
server):**

| fixture token map | `matchesDurableCandidate` | guard rejects |
| ----------------- | ------------------------- | ------------- |
| `{worker_context: "cap-abc"}` | false | **false** → recovery proceeds |
| `{worker_context, agent_tree_row: "├─01"}` | false | **true** → recovery refuses |
| `{role, agency_self, agency_parent, task_id, orchestrator_workspace_id, delivery_id, started_at, worker_context, agent_tree_row}` | true | true (branch not reached — durable candidate path is used) |

So the conflict is **real and reproducible at the predicate level**: one plugin-published
token on a tokenless-restart Worker pane is enough to make exact recovery refuse, and it
refuses *before* any Pi-side identity is examined.

**Ruled out by construction?** The task's own non-negotiables already forbid publishing
tokens onto panes whose identity cannot be validated (missing/malformed/mismatched
relationships stay visibly unlinked). A tokenless-restart Worker pane has no `agency_self`
and is therefore unlinked, so a plugin that publishes only on validated, linked panes never
places a key there. That avoidance is deterministic; **publication timing alone is not**,
because the plugin's own snapshot can legitimately show a Pi agent row before Pi's durable
tokens exist, and no event marks the end of Pi's recovery. This is an M2 contract decision,
not something M1 implements.

**End-to-end reproduction would require** a real Worker with a durable delivery record in an
isolated server, a server restart that drops its metadata, pi-agency's `advertise` path
republishing `worker_context`, our plugin publishing a token in that window, and an
orchestrator-invoked `worker_recover`. That needs Tandem mutations and (for the active
Worker) restarting the live server, so it was not performed.

---

## 7. Token key counts — live, source and spec

| source | Worker keys | Subagent keys |
| ------ | ----------- | ------------- |
| spec (`pi unions Worker<=9 / Subagent<=4 plus two plugin keys give 11/6`) | ≤ 9 | ≤ 4 |
| source-read producer enumeration (corrected) | **9** | **4** (maximum, including `question`) |
| live-observed (`agent.list` on the active socket) | **9** | **3** (`role, agency_self, agency_parent`; no outstanding question) |
| synthetic reproduction in isolation | 9 accepted | 4 accepted |

Exact Worker key set, identical in the live and corrected source-read sets:
`role, agency_self, agency_parent, task_id, orchestrator_workspace_id, delivery_id,
handoff, started_at, worker_context`.

Producers (source-read): `relationshipTokens()` gives `role/agency_self/agency_parent`;
`workers/index.ts:1660` adds `task_id`, `orchestrator_workspace_id`, `delivery_id`,
`handoff`, `started_at`; `workers/index.ts:1077` publishes `worker_context`.
Subagent: `subagents/core.ts:350` publishes the three relationship tokens and
`subagents/ask-question-contract.ts` adds `question`.

**Correction to the M2-boundary plan:** my first enumeration reported 8 and missed
`started_at` (published at `workers/index.ts:1666` as `started_at: String(now)`). The live
count caught it. All three Worker figures now agree at 9, so the two-plugin-token union is
11 for a Worker, leaving 21 keys of headroom against the verified 32-key pane cap. For a
Subagent the union is 6 at most and 5 at rest (3 live keys + 2 plugin keys), so the plugin's
two keys never approach the cap in observed coexistence.

**Unknown:** whether other producers (Reviewer metadata, future Pi extensions, third-party
tools) add keys to the same pane in coexistence; the live snapshot showed only pi-agency
tokens.

---

## 8. Cleanup (performed)

```sh
. /tmp/agent-tree-m1/env.sh
herdr server stop            # isolated server only; reported the isolated socket
herdr plugin unlink probe.m1 # refused: server_not_running (stop ran first)
rm -rf /tmp/agent-tree-m1    # removes the isolated plugins.json with it
```

Cleanup result, recorded verbatim rather than idealized: the isolated `plugin unlink`
**failed** with `server_not_running` because the server was stopped first, so the isolated
registration was removed by deleting the scratch root instead. `find` over `/tmp` and the
active config dir confirmed no `plugins.json` remained anywhere afterwards.

Verified afterwards in a fresh shell with the real environment: `herdr status` reported
`server: running`, socket `/home/ivan/.config/herdr/herdr.sock` (the active server was never
stopped, reloaded or reconfigured). The active config directory still contains only
`config.toml` (mtime 2026-09-12, unchanged), state and session files; it has no
`plugins.json` at all, so this work could not have written one. The repository worktree
contains only this document as a change.

---

## 9. Unknowns and unverified items carried into M2

1. Live Subagent token set — **resolved in section 2.1**: 3 keys at rest, 4 possible with
   `question`; two real `agency_self` hashes and one real `agency_parent` hash verified.
2. Mouse targets, indexed `focus_agent` bindings, and the visual focus ring under a view.
3. Event coalescing/ordering guarantees for rapid token updates; whether any dedicated
   metadata event exists.
4. Behaviour of the view when its filter references `current_workspace_id`/`current_tab_id`
   from a headless server (no attached client at set time).
5. Whether nested-TUI layout collapse (3.5) also occurs when the outer server has a real
   attached client.
6. End-to-end Worker recovery conflict (section 6) — predicate-level only; the proposed
   correction is now `.pi` task-189.
7. Live multi-root / cross-workspace / Worker-owned-Subagent layouts (M4 matrix).

## 10. Tandem Task text for the `.pi` workspace (filed by the orchestrator as task-189)

Per the task constraint "Mutate only this repository's Worker checkout", this text is
delivered for the orchestrator to file in the `.pi` Tandem workspace. It is the narrowest
correction that does not weaken an ownership guard.

**Title:** Worker tokenless-restart recovery refuses a pane carrying unrelated plugin tokens

**Body:**
`worker_recover` takes its tokenless-restart branch when no agent claims
`role=worker + orchestrator_workspace_id + task_id`, and then rejects the candidate if
`agent.tokens` contains any key other than `worker_context`
(`workers/index.ts:1843`). After a server restart, Herdr drops pane token metadata while
restoring the pane, so a retained Worker pane reappears with no tokens; pi-agency's
`advertise` path may republish `worker_context` before recovery runs. Any other producer
that publishes a single display token onto that pane in that window — an external Herdr
plugin, for example a sidebar decoration — makes recovery refuse with
"incomplete or conflicting Herdr metadata rather than a tokenless restart identity;
recovery made no changes." Reproduced at predicate level in an isolated Herdr 0.9.0
instance: `{worker_context}` → guard false; `{worker_context, agent_tree_row}` → guard true.
The guard cannot distinguish an unrelated display token from a conflicting pi-agency
routing token, because `agent.list` tokens carry no source attribution.

**Acceptance criteria:**
1. The recovery decision is documented for the case "pane carries `worker_context` plus
   tokens owned by another producer", with the chosen rule stated explicitly.
2. Any narrowed guard still refuses a pane that carries pi-agency routing identity that
   does not match the durable delivery record (role/agency_self/agency_parent/task_id/
   orchestrator_workspace_id/delivery_id).
3. A regression test covers: `{worker_context}` accepted, `{worker_context, foreign}` per
   the chosen rule, and `{role,task_id,…}` mismatching the record still refused.
4. Ownership guards are not weakened and no arbitrary token whitelist is introduced; if the
   chosen rule cannot satisfy both 2 and 3, the decision is escalated rather than guessed.

**Constraints:**
- Do not change Herdr or the plugin repository from the `.pi` side; the plugin-side
  alternative (never publishing on unlinked panes) is decided in Tandem task-3's M2 contract.
- No behaviour change without a test that fails before and passes after.

**Validations:**
- `$ (the .pi project's own test command for pi-agency)` — to be filled by the `.pi`
  project's rules; this checkout cannot run it.

**Note for the orchestrator:** if M2 adopts the plugin-side rule "publish tokens only on
panes whose identity validates", this Task may reduce to documentation of the latent
fragility rather than a code change.
