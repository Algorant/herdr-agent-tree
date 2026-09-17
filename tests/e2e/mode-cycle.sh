#!/usr/bin/env bash
#
# Noninteractive isolated Herdr end-to-end test for the grouped -> priority -> tree mode cycle.
#
# It builds the plugin, starts an isolated Herdr instance (own HOME, all XDG dirs and an
# explicit socket, verified at runtime), links the plugin, and drives the `agent-tree.cycle`
# action on a synthetic four-agent fixture. It observes Herdr's own `grouped` and `priority`
# mode labels and row order through a real tmux PTY, checks the plugin writes only
# `ui.agent_panel_sort`, that tree tokens are cleared when leaving tree, that a corrupt
# restore record and a foreign view owner both fail closed, and that the mode survives a
# config reload and a server restart. The original sort value and the sidebar rows block are
# restored byte for byte by `clear`.
#
# Everything it creates lives in one temp directory and is removed on exit, including on
# failure or interrupt; the isolated server is stopped with it. It never reads or writes the
# active Herdr server, its socket or ~/.config/herdr.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PLUGIN_DIR="$ROOT"

fail() { printf '\nmode-cycle-e2e: ERROR: %s\n' "$*" >&2; exit 1; }
step() { printf '  -> %s\n' "$*" >&2; }
log() { printf '\n== %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 1. Preflight.
# ---------------------------------------------------------------------------
need() {
    command -v "$1" >/dev/null 2>&1 || fail "missing prerequisite: $1 ($2)"
}
need cargo "Rust toolchain, used to build the plugin"
need jq "JSON parsing for Herdr CLI output"
need sha256sum "coreutils, used for the per-server state-file tag"
need setsid "util-linux, used to detach the isolated server"
need tmux "the native mode header/order assertion needs a real PTY"
need python3 "socket calls for the view probe and the throwaway foreign-view plugin"

herdr_real=""
if command -v mise >/dev/null 2>&1; then
    herdr_real=$(mise which herdr 2>/dev/null || true)
fi
if [ -z "$herdr_real" ] || [ ! -x "$herdr_real" ]; then
    herdr_real=$(command -v herdr 2>/dev/null || true)
fi
[ -x "$herdr_real" ] || fail "missing prerequisite: herdr (Herdr 0.9.0; https://herdr.dev)"
HERDR_BIN=$(CDPATH= cd -- "$(dirname -- "$herdr_real")" && pwd)/$(basename -- "$herdr_real")
herdr() { "$HERDR_BIN" "$@"; }

herdr_version=$("$HERDR_BIN" --version 2>/dev/null | awk '{print $2}')
[ -n "$herdr_version" ] || fail "could not read the Herdr version"
if [ "$(printf '%s\n0.9.0\n' "$herdr_version" | sort -V | head -1)" != "0.9.0" ]; then
    fail "Herdr $herdr_version is older than the plugin's minimum 0.9.0"
fi

# ---------------------------------------------------------------------------
# 2. Build the plugin.
# ---------------------------------------------------------------------------
log "Building the plugin"
cargo build --locked --release --manifest-path "$PLUGIN_DIR/Cargo.toml"
[ -x "$PLUGIN_DIR/target/release/agent-tree" ] || fail "build did not produce target/release/agent-tree"

# ---------------------------------------------------------------------------
# 3. Isolation environment.
# ---------------------------------------------------------------------------
TMP=$(mktemp -d "${TMPDIR:-/tmp}/agent-tree-mode-cycle-e2e.XXXXXX")
export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/config"
export XDG_STATE_HOME="$TMP/state"
export XDG_DATA_HOME="$TMP/data"
export XDG_RUNTIME_DIR="$TMP/run"
export HERDR_SOCKET_PATH="$TMP/config/herdr/herdr.sock"
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SESSION HERDR_ENV \
      HERDR_PLUGIN_ID HERDR_PLUGIN_ROOT HERDR_PLUGIN_CONFIG_DIR \
      HERDR_PLUGIN_STATE_DIR HERDR_PLUGIN_EVENT HERDR_INTEGRATION_ID

CONFIG="$XDG_CONFIG_HOME/herdr/config.toml"
ORIGINAL_CONFIG="$TMP/original-config.toml"
PLUGIN_STATE="$XDG_STATE_HOME/herdr/plugins/agent-tree"
ROWS='rows = [["state_icon", "agent", "terminal_title_stripped"]]'

mkdir -p "$HOME" "$XDG_CONFIG_HOME/herdr" "$XDG_STATE_HOME" "$XDG_DATA_HOME" \
         "$XDG_RUNTIME_DIR" "$TMP/work" "$TMP/logs"
chmod 700 "$XDG_RUNTIME_DIR"

# The pre-existing value is deliberately non-default so the restore check is meaningful.
cat > "$CONFIG" <<CFG
[server]
headless_cols = 200
headless_rows = 50

[experimental]
allow_nested = true

[ui]
sidebar_width = 32
sidebar_min_width = 32
sidebar_max_width = 32
agent_panel_sort = "workspaces"

[ui.sidebar.agents]
$ROWS
CFG
cp -p "$CONFIG" "$ORIGINAL_CONFIG"

SERVER_PID=""
TMUX_SOCKET=""
SESSION="mode-cycle"

cleanup() {
    if [ -n "$TMUX_SOCKET" ]; then
        tmux -S "$TMUX_SOCKET" kill-server >/dev/null 2>&1 || true
    fi
    if [ -n "$TMP" ] && [ -d "$TMP" ]; then
        herdr server stop >/dev/null 2>&1 || true
        if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
            kill "$SERVER_PID" 2>/dev/null || true
        fi
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

start_server() {
    local phase="$1"
    setsid "$HERDR_BIN" server > "$TMP/logs/server-$phase.out" 2>&1 < /dev/null &
    SERVER_PID=$!
    for _ in $(seq 1 100); do
        [ -S "$HERDR_SOCKET_PATH" ] && break
        sleep 0.2
    done
    [ -S "$HERDR_SOCKET_PATH" ] || fail "the isolated server did not create $HERDR_SOCKET_PATH; see $TMP/logs/server-$phase.out"
    sleep 0.5
    local resolved
    resolved=$(herdr status 2>/dev/null | awk '/socket:/{print $2; exit}')
    [ "$resolved" = "$HERDR_SOCKET_PATH" ] || \
        fail "refusing to continue: Herdr resolved socket $resolved but the isolated socket is $HERDR_SOCKET_PATH"
}

stop_server() {
    herdr server stop >/dev/null 2>&1 || true
    if [ -n "$SERVER_PID" ]; then
        for _ in $(seq 1 50); do
            kill -0 "$SERVER_PID" 2>/dev/null || break
            sleep 0.2
        done
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    SERVER_PID=""
}

start_client() {
    TMUX_SOCKET="$TMP/tmux.sock"
    rm -f "$TMUX_SOCKET"
    tmux -S "$TMUX_SOCKET" new-session -d -x 150 -y 50 -s "$SESSION" "$HERDR_BIN"
    sleep 6
    # Dismiss the isolated client's first-run modal; harmless if it is not shown.
    tmux -S "$TMUX_SOCKET" send-keys -t "$SESSION" Escape
    sleep 1
    tmux -S "$TMUX_SOCKET" send-keys -t "$SESSION" Escape
    sleep 1
}

kill_client() {
    if [ -n "$TMUX_SOCKET" ]; then
        tmux -S "$TMUX_SOCKET" kill-server >/dev/null 2>&1 || true
        TMUX_SOCKET=""
    fi
}

log "Starting the isolated Herdr server"
start_server first
step "Socket verified isolated: $HERDR_SOCKET_PATH"

log "Installing the plugin and the four-agent fixture"
herdr plugin link "$PLUGIN_DIR" --enabled >/dev/null
mkdir -p "$TMP/work"
mkagent() { # <name> <state> -> prints pane id
    local name="$1" state="$2" pane
    mkdir -p "$TMP/work/$name"
    pane=$(herdr workspace create --cwd "$TMP/work/$name" --label "$name" --no-focus \
        | jq -r '.result.root_pane.pane_id')
    herdr pane report-agent "$pane" --source mode-cycle --agent "$name" --state "$state" >/dev/null
    printf '%s' "$pane"
}
P_IDLE=$(mkagent idle-one idle)
P_BLOCKED=$(mkagent blocked-two blocked)
P_WORKING=$(mkagent working-three working)
P_UNKNOWN=$(mkagent unknown-four unknown)
P_STALE=$P_IDLE

TAG=$(printf '%s' "$HERDR_SOCKET_PATH" | sha256sum | cut -c1-16)
FLAG="$PLUGIN_STATE/paused-$TAG.flag"
RECORD="$PLUGIN_STATE/original-sort-$TAG"
LOCK="$PLUGIN_STATE/subscriber-$TAG.lock"

start_client

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------
config_sort() {
    local value
    value=$(grep -oE 'agent_panel_sort[[:space:]]*=[[:space:]]*"[^"]*"' "$CONFIG" 2>/dev/null \
        | tail -1 | sed -E 's/.*"([^"]*)"$/\1/') || true
    if [ -z "$value" ]; then printf 'absent'; else printf '%s' "$value"; fi
}

current_mode() {
    if [ ! -f "$FLAG" ]; then
        printf 'tree'
        return 0
    fi
    if [ "$(config_sort)" = priority ]; then
        printf 'priority'
    else
        printf 'grouped'
    fi
}

capture() { tmux -S "$TMUX_SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null || true; }

header_current() {
    capture | grep -oE 'agents +[a-z]+' | tail -1 | awk '{print $2}' || true
}

order_after_header() {
    local text line labels
    text=$(capture)
    line=$(printf '%s\n' "$text" | grep -nE 'agents +[a-z]+' | tail -1 | cut -d: -f1) || true
    if [ -z "$line" ]; then
        return 0
    fi
    labels=$(printf '%s\n' "$text" | tail -n +"$((line + 1))" \
        | grep -oE 'idle-one|blocked-two|working-three|unknown-four' | head -4 | paste -sd, -) || true
    printf '%s' "$labels"
}

view_probe() {
    python3 - "$HERDR_SOCKET_PATH" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(10)
s.connect(sys.argv[1])
f = s.makefile("rwb")
f.write((json.dumps({
    "id": "probe",
    "method": "agent.view.clear",
    "params": {"source": "plugin:agent-tree-probe"},
}) + "\n").encode())
f.flush()
result = json.loads(f.readline())["result"]
s.close()
print(("%s %s" % (str(result.get("active")).lower(), result.get("source") or "-")).strip())
PY
}

set_config_sort() { # <value>
    python3 - "$CONFIG" "$1" <<'PY'
import re, sys
path, value = sys.argv[1], sys.argv[2]
text = open(path).read()
pattern = r'agent_panel_sort\s*=\s*"[^"]*"'
if not re.search(pattern, text):
    raise SystemExit("no agent_panel_sort line to replace")
open(path, "w").write(re.sub(pattern, 'agent_panel_sort = "%s"' % value, text))
PY
}

invoke_action() { # <action-id> -> prints log_id
    herdr plugin action invoke "agent-tree.$1" | jq -r '.result.log.log_id // empty'
}

log_status() { # <log_id> -> prints terminal status, or empty while running/unknown
    local log_id="$1" status
    status=$(herdr plugin log list --plugin agent-tree --limit 100 2>/dev/null \
        | jq -r --arg id "$log_id" '.result.logs[] | select(.log_id==$id) | .status' | head -1) || true
    if [ "$status" = running ]; then
        return 0
    fi
    printf '%s' "$status"
}

wait_log() { # <log_id> -> prints terminal status
    local log_id="$1" status
    for _ in $(seq 1 80); do
        status=$(log_status "$log_id")
        if [ -n "$status" ]; then
            printf '%s' "$status"
            return 0
        fi
        sleep 0.25
    done
    return 1
}

log_stderr() { # <log_id>
    herdr plugin log list --plugin agent-tree --limit 100 2>/dev/null \
        | jq -r --arg id "$1" '.result.logs[] | select(.log_id==$id) | (.stderr // "")' | head -1 || true
}

wait_mode() { # <mode>
    local want="$1" got=""
    for _ in $(seq 1 80); do
        got=$(current_mode)
        [ "$got" = "$want" ] && return 0
        sleep 0.25
    done
    fail "expected internal mode $want, got $got (pause flag $([ -f "$FLAG" ] && echo present || echo absent), sort $(config_sort))"
}

wait_header() { # <mode>
    local want="$1" got=""
    for _ in $(seq 1 80); do
        got=$(header_current)
        [ "$got" = "$want" ] && return 0
        sleep 0.25
    done
    fail "expected sidebar header '$want', got '${got:-none}' (internal mode $(current_mode))"
}

wait_order() { # <comma list>
    local want="$1" got=""
    for _ in $(seq 1 40); do
        got=$(order_after_header)
        [ "$got" = "$want" ] && return 0
        sleep 0.25
    done
    return 1
}

cycle_to() { # <mode>
    local want="$1" log_id status
    log_id=$(invoke_action cycle) || fail "could not start agent-tree.cycle"
    status=$(wait_log "$log_id") || fail "cycle log $log_id never reached a terminal status"
    [ "$status" = succeeded ] || fail "cycle to $want reported $status (log $log_id): $(log_stderr "$log_id")"
    wait_mode "$want"
    wait_header "$want"
}

cycle_failure() { # <reason>
    local reason="$1" log_id status
    log_id=$(invoke_action cycle) || fail "could not start agent-tree.cycle for the $reason check"
    status=$(wait_log "$log_id") || fail "$reason: cycle log $log_id never reached a terminal status"
    [ "$status" = failed ] || fail "$reason: expected cycle to fail, got status=$status"
    step "$reason refused as expected: $(log_stderr "$log_id")"
}

assert_sort() { # <value> <label>
    local got; got=$(config_sort)
    [ "$got" = "$1" ] || fail "$2: expected agent_panel_sort '$1', got '$got'"
}

assert_flag() { # present|absent <label>
    if [ "$1" = present ]; then
        [ -f "$FLAG" ] || fail "$2: the pause flag is missing"
    else
        [ ! -f "$FLAG" ] || fail "$2: the pause flag is present"
    fi
}

assert_rows() { # <label>
    grep -Fq "$ROWS" "$CONFIG" || fail "$1: the [ui.sidebar.agents] rows block changed"
}

assert_view() { # <expected probe output> <label>
    local got; got=$(view_probe)
    [ "$got" = "$1" ] || fail "$2: expected view '$1', got '$got'"
}

tokens_state() {
    herdr agent list 2>/dev/null \
        | jq -r --arg p "$P_STALE" '.result.agents[] | select(.pane_id==$p) | ((.tokens.agent_tree_row // "-") + "|" + (.tokens.agent_tree_rank // "-"))' || true
}

# ---------------------------------------------------------------------------
# 4. The cycle.
# ---------------------------------------------------------------------------
log "Verifying the documented initial state"
assert_flag absent "initial state"
[ ! -f "$RECORD" ] || fail "an original-sort record exists before the first write"
step "No pause flag: the plugin reads tree; a fresh install's startup hook installs the tree view"

log "Reaching the grouped start state (tree -> grouped)"
cycle_to grouped
assert_flag present "grouped"
assert_sort spaces "grouped writes the grouped value"
[ -f "$RECORD" ] || fail "the original sort was not captured before the first write"
assert_rows "grouped"
if ! grep -Fq '"sort_line":"agent_panel_sort = \"workspaces\""' "$RECORD"; then
    fail "the capture record does not hold the original workspaces value: $(cat "$RECORD")"
fi
step "captured original sort: $(cat "$RECORD")"

run_cycle_sequence() { # <label>
    local label="$1"
    cycle_to priority
    assert_flag present "$label priority"
    assert_sort priority "$label priority writes the priority value"
    assert_rows "$label priority"
    local order
    order=$(wait_order 'blocked-two,working-three,idle-one,unknown-four') \
        || fail "$label priority: native attention order was '$(order_after_header)'"
    step "$label priority header and attention order confirmed"

    cycle_to tree
    assert_flag absent "$label tree"
    assert_view 'true plugin:agent-tree' "$label tree owns the view"
    assert_rows "$label tree"
    step "$label tree header and view ownership confirmed"

    cycle_to grouped
    assert_flag present "$label grouped again"
    assert_sort spaces "$label grouped again writes the grouped value"
    order=$(wait_order 'idle-one,blocked-two,working-three,unknown-four') \
        || fail "$label grouped: native workspace order was '$(order_after_header)'"
    step "$label grouped header and workspace order confirmed"
}

log "Cycle pass 1: grouped -> priority -> tree -> grouped"
run_cycle_sequence "pass 1"
log "Cycle pass 2 (determinism): grouped -> priority -> tree -> grouped"
run_cycle_sequence "pass 2"

# ---------------------------------------------------------------------------
# 5. Unknown sort value is grouped, never a refusal.
# ---------------------------------------------------------------------------
log "Unknown agent_panel_sort is treated as grouped"
assert_flag present "unknown-value precondition"
set_config_sort bogus
[ "$(config_sort)" = bogus ] || fail "could not seed the unknown sort value"
cycle_to priority
assert_sort priority "unknown sort advanced to priority"
step "unknown value behaved as grouped and the cycle advanced to priority"

# ---------------------------------------------------------------------------
# 6. Corrupt restore record fails closed.
# ---------------------------------------------------------------------------
log "A corrupt original-sort record fails closed"
herdr plugin action invoke agent-tree.clear >/dev/null
for _ in $(seq 1 40); do
    [ ! -f "$RECORD" ] && [ "$(config_sort)" = workspaces ] && break
    sleep 0.25
done
[ ! -f "$RECORD" ] || fail "clear did not remove the record"
assert_sort workspaces "clear restores the original before the corrupt-record check"
printf 'not json\n' > "$RECORD"
cycle_failure "corrupt original-sort record"
assert_sort workspaces "corrupt record must leave the config unchanged"
assert_rows "corrupt record"
rm -f "$RECORD"

# ---------------------------------------------------------------------------
# 7. A foreign view owner is never evicted.
# ---------------------------------------------------------------------------
log "A foreign view owner makes the cycle refuse and change nothing"
FOREIGN_DIR="$TMP/view-owner"
mkdir -p "$FOREIGN_DIR/bin"
cat > "$FOREIGN_DIR/herdr-plugin.toml" <<'TOML'
id = "view-owner"
name = "View Owner"
version = "0.1.0"
min_herdr_version = "0.9.0"
platforms = ["linux"]

[[actions]]
id = "own"
title = "Own the agent view"
command = ["./bin/own.sh"]
TOML
cat > "$FOREIGN_DIR/bin/own.sh" <<'SH'
#!/bin/sh
set -eu
python3 - "$HERDR_SOCKET_PATH" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(10)
s.connect(sys.argv[1])
f = s.makefile("rwb")
f.write((json.dumps({
    "id": "own",
    "method": "agent.view.set",
    "params": {"source": "plugin:view-owner", "label": "foreign", "sort": []},
}) + "\n").encode())
f.flush()
f.readline()
s.close()
PY
SH
chmod +x "$FOREIGN_DIR/bin/own.sh"
herdr plugin link "$FOREIGN_DIR" --enabled >/dev/null
herdr plugin action invoke view-owner.own >/dev/null
for _ in $(seq 1 40); do
    [ "$(view_probe)" = 'true plugin:view-owner' ] && break
    sleep 0.25
done
assert_view 'true plugin:view-owner' "foreign view installed"
cycle_failure "foreign view owner"
assert_view 'true plugin:view-owner' "foreign view must survive the refused cycle"
assert_rows "foreign owner"
herdr plugin disable view-owner >/dev/null 2>&1 || true
herdr plugin unlink view-owner >/dev/null 2>&1 || true
for _ in $(seq 1 40); do
    [ "$(view_probe)" = 'false -' ] && break
    sleep 0.25
done
assert_view 'false -' "foreign view cleared after disable"

# Re-enter the cycle from grouped and end in tree for the stale-token check.
cycle_to priority
cycle_to tree
assert_view 'true plugin:agent-tree' "tree view before the stale-token check"

# ---------------------------------------------------------------------------
# 8. Leaving tree clears plugin-owned tokens and projection state.
# ---------------------------------------------------------------------------
log "Leaving tree clears stale plugin-owned tokens"
if [ -f "$LOCK" ]; then
    pid=$(jq -r '.pid' "$LOCK")
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    rm -f "$LOCK"
fi
herdr pane report-metadata "$P_STALE" --source agent-tree \
    --token "agent_tree_row=stale" --token "agent_tree_rank=000001" >/dev/null
[ "$(tokens_state)" = "stale|000001" ] || fail "could not seed stale tree tokens: $(tokens_state)"
cycle_to grouped
for _ in $(seq 1 40); do
    [ "$(tokens_state)" = "-|-" ] && break
    sleep 0.25
done
[ "$(tokens_state)" = "-|-" ] || fail "stale tree tokens survived leaving tree: $(tokens_state)"
assert_flag present "after stale-token cleanup"
assert_rows "after stale-token cleanup"
step "agent_tree_row/agent_tree_rank cleared when tree mode was left"

# ---------------------------------------------------------------------------
# 9. Config reload and server restart.
# ---------------------------------------------------------------------------
log "Cycling used config reload, not a server restart"
kill -0 "$SERVER_PID" 2>/dev/null || fail "the isolated server restarted during mode cycling"

log "The native mode survives a server restart"
stop_server
kill_client
start_server restart
assert_flag present "paused restart"
assert_sort spaces "paused restart keeps the grouped value"
start_client
wait_header grouped
assert_rows "restart"
step "startup hook left the paused native panel alone; header grouped after restart"
cycle_to priority
assert_rows "restart priority"
cycle_to tree
assert_view 'true plugin:agent-tree' "restart tree"

# ---------------------------------------------------------------------------
# 10. Clear restores the original configuration byte for byte.
# ---------------------------------------------------------------------------
log "clear restores the pre-existing configuration"
herdr plugin action invoke agent-tree.clear >/dev/null
for _ in $(seq 1 60); do
    [ ! -f "$RECORD" ] && [ "$(config_sort)" = workspaces ] && break
    sleep 0.25
done
[ ! -f "$RECORD" ] || fail "clear did not remove the original-sort record"
cmp -s "$CONFIG" "$ORIGINAL_CONFIG" \
    || fail "clear did not restore config.toml byte for byte:\n$(diff -u "$ORIGINAL_CONFIG" "$CONFIG" || true)"
step "config.toml is byte-identical to the pre-plugin original"

log "Mode-cycle end-to-end test passed"
