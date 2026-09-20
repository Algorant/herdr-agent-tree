#!/usr/bin/env bash
#
# Noninteractive isolated Herdr end-to-end test for the owner-safe Agent Tree toggle.
#
# It builds the plugin, starts an isolated Herdr instance (own HOME, all XDG dirs and an
# explicit socket, verified at runtime), installs the Pi publisher and launches credential-
# free idle Pi agents to obtain genuine agent_session values, publishes the pi-agency-shaped
# relationship tokens derived from those real session paths, and then drives the documented
# `[[keys.command]]` binding `prefix+t` through native -> tree -> native. It asserts the
# `tree` view label and projected order through a real tmux PTY, that agent_tree_row and
# agent_tree_rank stay published with tree ordering off, that config.toml is never written,
# that the native Agents header mouse toggle works again when tree is off, and that a foreign
# view owner is never displaced.
#
# Everything it creates lives in one temp directory and is removed on exit, including on
# failure or interrupt; the isolated server is stopped with it. It never reads or writes the
# active Herdr server, its socket or ~/.config/herdr.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PLUGIN_DIR="$ROOT"

fail() { printf '\ntoggle-e2e: ERROR: %s\n' "$*" >&2; exit 1; }
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
need sha256sum "coreutils, used for the agency_self hash"
need setsid "util-linux, used to detach the isolated server"
need tmux "the shortcut, sidebar and mouse assertions need a real PTY"
need python3 "socket calls for the view probe and the throwaway foreign-view plugin"

pi_real=""
if command -v mise >/dev/null 2>&1; then
    pi_real=$(mise which pi 2>/dev/null || true)
fi
if [ -z "$pi_real" ] || [ ! -x "$pi_real" ]; then
    pi_real=$(command -v pi 2>/dev/null || true)
fi
[ -x "$pi_real" ] || fail "missing prerequisite: pi (needed for genuine agent_session values)"
PI_DIR=$(CDPATH= cd -- "$(dirname -- "$pi_real")" && pwd)

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
TMP=$(mktemp -d "${TMPDIR:-/tmp}/agent-tree-toggle-e2e.XXXXXX")
export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/config"
export XDG_STATE_HOME="$TMP/state"
export XDG_DATA_HOME="$TMP/data"
export XDG_RUNTIME_DIR="$TMP/run"
export HERDR_SOCKET_PATH="$TMP/config/herdr/herdr.sock"
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SESSION HERDR_ENV \
      HERDR_PLUGIN_ID HERDR_PLUGIN_ROOT HERDR_PLUGIN_CONFIG_DIR \
      HERDR_PLUGIN_STATE_DIR HERDR_PLUGIN_EVENT HERDR_INTEGRATION_ID

mkdir -p "$HOME/.pi/agent/extensions" "$XDG_CONFIG_HOME/herdr" "$XDG_STATE_HOME" \
         "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR" "$TMP/work" "$TMP/logs"
chmod 700 "$XDG_RUNTIME_DIR"

CREDENTIAL_VARS="AI_GATEWAY_API_KEY ANTHROPIC_API_KEY ANTHROPIC_KEY ANTHROPIC_OAUTH_TOKEN
ANTHROPIC_PROXY_KEY AWS_ACCESS_KEY_ID AWS_BEARER_TOKEN AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN AZURE_API_KEY AZURE_OPENAI_API_KEY BASETEN_API_KEY CEREBRAS_API_KEY
CLOUDFLARE_API_KEY DEEPSEEK_API_KEY FIREWORKS_API_KEY GEMINI_API_KEY
GOOGLE_APPLICATION_CREDENTIALS GOOGLE_API_KEY GROQ_API_KEY HF_TOKEN KIMI_API_KEY
LLAMA_API_KEY LOCAL_OPENAI_API_KEY MINIMAX_API_KEY MINIMAX_CN_API_KEY MISTRAL_API_KEY
NVIDIA_API_KEY OPENAI_API_KEY OPENAI_API_VERSION OPENAI_BASE_URL
OPENAI_DEPLOYMENT_NAME_MAP OPENAI_RESOURCE_NAME OPENCODE_API_KEY OPENROUTER_API_KEY
PI_MODEL PORTKEY_API_KEY PROXY_API_KEY QWEN_TOKEN_PLAN_API_KEY QWEN_TOKEN_PLAN_CN_API_KEY
XAI_API_KEY"
for var in $CREDENTIAL_VARS; do
    unset "$var" 2>/dev/null || true
done

CONFIG="$XDG_CONFIG_HOME/herdr/config.toml"
# mouse_capture stays on (the default) so the native Agents header is a real hit region.
# The documented binding is installed exactly as a user would install it; the plugin itself
# never writes config.toml.
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
mouse_capture = true

[ui.sidebar.agents]
rows = [["state_icon", "\$agent_tree_row", "terminal_title_stripped"]]

[keys]
prefix = "ctrl+b"

[[keys.command]]
key = "prefix+t"
type = "shell"
description = "Toggle Agent Tree ordering on or off"
command = "$HERDR_BIN plugin action invoke agent-tree.toggle"
CFG
cp -p "$CONFIG" "$TMP/original-config.toml"

SERVER_PID=""
TMUX_SOCKET=""
SESSION=toggle-e2e

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

log "Starting the isolated Herdr server"
setsid "$HERDR_BIN" server > "$TMP/logs/server.out" 2>&1 < /dev/null &
SERVER_PID=$!
for _ in $(seq 1 50); do
    [ -S "$HERDR_SOCKET_PATH" ] && break
    sleep 0.2
done
[ -S "$HERDR_SOCKET_PATH" ] || fail "the isolated server did not create $HERDR_SOCKET_PATH; see $TMP/logs/server.out"
resolved_socket=$(herdr status 2>/dev/null | awk '/socket:/{print $2; exit}')
[ "$resolved_socket" = "$HERDR_SOCKET_PATH" ] || \
    fail "refusing to continue: Herdr resolved socket $resolved_socket but the isolated socket is $HERDR_SOCKET_PATH"
step "Socket verified isolated: $HERDR_SOCKET_PATH"

log "Installing the Pi publisher and linking the plugin"
herdr integration install pi >/dev/null
herdr plugin link "$PLUGIN_DIR" --enabled >/dev/null

# ---------------------------------------------------------------------------
# 4. Fixture: one undelegating Pi session plus a validated root/child family.
#    The lone session is created first so native order and tree order differ.
# ---------------------------------------------------------------------------
self_hash() {
    jq -cnj --arg p "$1" '["pi","path",$p]' | sha256sum | awk '{print $1}'
}

mkws() {
    mkdir -p "$TMP/work/$1"
    herdr workspace create --cwd "$TMP/work/$1" --label "$1" --no-focus \
        --env "PATH=$PI_DIR:$PATH" | jq -r '.result.root_pane.pane_id'
}

start_pi() { # <name> <pane> -> prints the genuine agent_session path
    local name="$1" pane="$2" path
    path=$(herdr agent start "$name" --kind pi --pane "$pane" \
        | jq -r '.result.agent.agent_session.value // empty')
    if [ -z "$path" ]; then
        for _ in $(seq 1 20); do
            sleep 0.5
            path=$(herdr agent list \
                | jq -r --arg p "$pane" '.result.agents[] | select(.pane_id==$p) | .agent_session.value // empty')
            [ -n "$path" ] && break
        done
    fi
    [ -n "$path" ] || fail "agent $name did not publish an agent_session"
    printf '%s' "$path"
}

verify_credentials_free() { # <pane>
    local pane="$1" info pid environ bad banner
    info=$(herdr pane process-info --pane "$pane")
    pid=$(printf '%s' "$info" \
        | jq -r '[.result.process_info.foreground_processes[] | select(.name=="pi")][0].pid // empty')
    [ -n "$pid" ] || fail "could not find the launched Pi process for $pane; NO further agents started"
    [ -r "/proc/$pid/environ" ] || fail "cannot read /proc/$pid/environ; NO further agents started"
    environ=$(tr '\0' '\n' < "/proc/$pid/environ")
    for var in $CREDENTIAL_VARS; do
        if printf '%s\n' "$environ" | grep -q "^${var}=.\+"; then
            fail "provider credential $var is set in the launched Pi process; NO further agents started"
        fi
    done
    bad=$(printf '%s\n' "$environ" | awk -F= '/^[A-Za-z0-9_]+(_API_KEY|_OAUTH[A-Z0-9_]*)$/ && length($2)>0 {print $1}' | sort -u | paste -sd, -)
    [ -z "$bad" ] || fail "provider credentials in the launched Pi process ($bad); NO further agents started"
    banner=""
    for _ in $(seq 1 20); do
        banner=$(herdr pane read "$pane" --lines 200 2>/dev/null || true)
        case "$banner" in *"No models available"*) break ;; esac
        sleep 0.5
    done
    case "$banner" in
        *"No models available"*) ;;
        *) fail "Pi did not report 'No models available' for $pane; NO further agents started" ;;
    esac
    step "Credential-free confirmed: no provider keys in the Pi process and no usable model"
}

report_rel() { # <pane> <role> <self-hash> <parent-hash> [extra token ...]
    local pane="$1" role="$2" self="$3" parent="$4"; shift 4
    local args=()
    for extra in "$@"; do args+=(--token "$extra"); done
    herdr pane report-metadata "$pane" --source pi-fixture \
        --token "role=$role" --token "agency_self=$self" --token "agency_parent=$parent" \
        "${args[@]}" >/dev/null
}

GP_PANE=""
GP_SESSION=""
make_pi() { # <name>
    GP_PANE=$(mkws "$1")
    GP_SESSION=$(start_pi "$1" "$GP_PANE")
}

log "Creating the fixture (3 credential-free idle Pi agents)"
make_pi lone-1;  P_L1=$GP_PANE
verify_credentials_free "$P_L1"
step "lone-1 created"
make_pi root-alpha; P_R1=$GP_PANE; S_R1=$GP_SESSION; step "root-alpha created"
make_pi sub-alpha;  P_S1=$GP_PANE; S_S1=$GP_SESSION; step "sub-alpha created"
H_R1=$(self_hash "$S_R1"); H_S1=$(self_hash "$S_S1")
report_rel "$P_S1" subagent "$H_S1" "$H_R1" "question=1"
step "Published the validated root-alpha -> sub-alpha edge"

# ---------------------------------------------------------------------------
# 5. Helpers.
# ---------------------------------------------------------------------------
cap() { tmux -S "$TMUX_SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null || true; }
header() { cap | grep -oE 'agents +[a-z]+' | tail -1 | awk '{print $2}'; }
# The sidebar is the first 31 columns of the capture; the 32nd is its border. `cut -c`
# counts bytes in this test's POSIX locale, so a decorated row such as
# `○ └─S ? · π - sub-alpha` loses the tail of the name before grep. Slice by character
# instead, which keeps valid multibyte decorations and still excludes the main pane.
sidebar_region() {
    python3 -c '
import sys
text = sys.stdin.buffer.read().decode("utf-8", "replace")
sys.stdout.write("\n".join(line[:31] for line in text.split("\n")))
'
}
order_after_header() {
    local line
    line=$(cap | grep -nE 'agents +[a-z]+' | tail -1 | cut -d: -f1) || true
    [ -n "$line" ] || return 0
    cap | tail -n +"$((line + 1))" | sidebar_region \
        | grep -oE 'lone-1|root-alpha|sub-alpha' | head -3 | paste -sd, -
}
wait_header() { # <expected> [attempts]
    local want="$1" tries="${2:-40}" got=""
    for _ in $(seq 1 "$tries"); do
        got=$(header)
        [ "$got" = "$want" ] && return 0
        sleep 0.25
    done
    fail "expected sidebar header '$want', got '${got:-none}'"
}
press_toggle() {
    # The documented `prefix+t` binding, driven through the real TTY: press the prefix
    # (Ctrl+B), release it, then press `t`.
    tmux -S "$TMUX_SOCKET" send-keys -t "$SESSION" C-b
    sleep 0.4
    tmux -S "$TMUX_SOCKET" send-keys -t "$SESSION" -l "t"
}
click_header() {
    local hit row full sb label before start col
    hit=$(cap | grep -nE 'agents +[a-z]+' | tail -1)
    row=${hit%%:*}; full=${hit#*:}
    sb=$(printf '%s' "$full" | cut -c1-31)
    label=$(printf '%s' "$sb" | grep -oE 'agents +[a-z]+' | tail -1 | awk '{print $NF}')
    before=${sb%%"$label"*}; start=$(( ${#before} + 1 )); col=$(( start + ${#label} / 2 ))
    tmux -S "$TMUX_SOCKET" send-keys -t "$SESSION" -l "$(printf '\033[<0;%d;%dM' "$col" "$row")"
    tmux -S "$TMUX_SOCKET" send-keys -t "$SESSION" -l "$(printf '\033[<0;%d;%dm' "$col" "$row")"
    sleep 1.5
}
dismiss_overlays() {
    local i
    tmux -S "$TMUX_SOCKET" send-keys -t "$SESSION" Escape; sleep 0.7
    for i in $(seq 1 8); do
        if cap | grep -qE 'mouse-first|terminal workspace manager|continue'; then
            tmux -S "$TMUX_SOCKET" send-keys -t "$SESSION" Enter; sleep 0.8
            tmux -S "$TMUX_SOCKET" send-keys -t "$SESSION" Escape; sleep 0.4
        else
            break
        fi
    done
    cap | grep -qE 'mouse-first|terminal workspace manager' && fail "onboarding overlay survived dismissal"
    return 0
}

token_of() { # <pane> <token> -> value or "-"
    herdr agent list | jq -r --arg p "$1" --arg t "$2" \
        '.result.agents[] | select(.pane_id==$p) | .tokens[$t] // "-"' | head -1
}
wait_ranked() { # <count>
    local want="$1" got=""
    for _ in $(seq 1 40); do
        got=$(herdr agent list | jq '[.result.agents[] | select(.tokens.agent_tree_rank != null)] | length')
        [ "$got" = "$want" ] && return 0
        sleep 0.5
    done
    return 1
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

config_has_sort() {
    grep -qE 'agent_panel_sort' "$CONFIG" && printf yes || printf no
}

assert_decorations_retained() { # <label>
    [ "$(token_of "$P_R1" agent_tree_rank)" = "000001" ] || fail "$1: root-alpha rank lost while tree was off"
    [ "$(token_of "$P_S1" agent_tree_rank)" = "000002" ] || fail "$1: sub-alpha rank lost while tree was off"
    [ "$(token_of "$P_S1" agent_tree_row)" != "-" ] || fail "$1: sub-alpha decoration lost while tree was off"
    step "$1: agent_tree_rank/agent_tree_row still published"
}

# ---------------------------------------------------------------------------
# 6. Apply the tree, then drive the shortcut native -> tree -> native.
# ---------------------------------------------------------------------------
log "Applying the tree projection and waiting for the validated ranks"
herdr plugin action invoke agent-tree.apply >/dev/null
wait_ranked 2 || fail "the plugin did not rank the validated family"

log "Rendering the sidebar through a real tmux PTY"
TMUX_SOCKET="$TMP/tmux.sock"
rm -f "$TMUX_SOCKET"
tmux -S "$TMUX_SOCKET" new-session -d -x 150 -y 50 -s "$SESSION" "$HERDR_BIN"
sleep 6
dismiss_overlays
wait_header tree
[ "$(order_after_header)" = "root-alpha,sub-alpha,lone-1" ] \
    || fail "tree order was '$(order_after_header)', expected root-alpha,sub-alpha,lone-1 (ranked tree first, unranked lone last)"
step "tree view: header tree, order $(order_after_header)"

log "Shortcut: tree -> native"
press_toggle
wait_header grouped
# Turning tree off preserves the Herdr client's own grouped/priority choice and writes no
# config; the plugin only removes its view.
[ "$(config_has_sort)" = no ] || fail "toggle wrote ui.agent_panel_sort into config.toml"
assert_decorations_retained "tree off"
[ "$(order_after_header)" = "lone-1,root-alpha,sub-alpha" ] \
    || fail "native order was '$(order_after_header)', expected lone-1,root-alpha,sub-alpha"

log "Shortcut: native -> tree"
press_toggle
wait_header tree
[ "$(order_after_header)" = "root-alpha,sub-alpha,lone-1" ] || fail "tree did not return after the second shortcut press"
assert_decorations_retained "tree on again"

log "Shortcut: tree -> native again"
press_toggle
wait_header grouped
assert_decorations_retained "tree off again"

log "The native Agents header mouse toggle works again when tree is off"
before=$(header)
click_header
wait_header "$([ "$before" = grouped ] && echo priority || echo grouped)"
step "native header press toggled $before -> $(header)"
# Return to grouped so the later foreign-view label check is unambiguous.
if [ "$(header)" = priority ]; then click_header; wait_header grouped; fi

log "A foreign view owner is never displaced"
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
[ "$(view_probe)" = 'true plugin:view-owner' ] || fail "the foreign view was not installed"

log_id=$(herdr plugin action invoke agent-tree.toggle | jq -r '.result.log.log_id // empty')
[ -n "$log_id" ] || fail "could not start agent-tree.toggle for the foreign-owner check"
status=""
for _ in $(seq 1 80); do
    status=$(herdr plugin log list --plugin agent-tree --limit 100 2>/dev/null \
        | jq -r --arg id "$log_id" '.result.logs[] | select(.log_id==$id) | .status' | head -1) || true
    [ -n "$status" ] && [ "$status" != running ] && break
    sleep 0.25
done
[ "$status" = failed ] || fail "toggle with a foreign owner reported status=$status, expected failed"
stderr=$(herdr plugin log list --plugin agent-tree --limit 100 2>/dev/null \
    | jq -r --arg id "$log_id" '.result.logs[] | select(.log_id==$id) | (.stderr // "")' | head -1) || true
case "$stderr" in *view-owner*) ;; *) fail "toggle refusal did not name the foreign owner: $stderr" ;; esac
[ "$(view_probe)" = 'true plugin:view-owner' ] || fail "the foreign view changed during the refused toggle"
step "foreign view refused and unchanged: $stderr"

# The shortcut is the same action and must also leave the foreign view alone.
press_toggle
sleep 1.5
[ "$(view_probe)" = 'true plugin:view-owner' ] || fail "the shortcut displaced the foreign view"
step "shortcut press also left the foreign view unchanged"
herdr plugin disable view-owner >/dev/null 2>&1 || true
herdr plugin unlink view-owner >/dev/null 2>&1 || true

log "clear remains the full cleanup path when no subscriber is running"
# A running subscriber deliberately republishes decorations in both states, so stop it (the
# documented one-shot-reset behaviour) to observe clear's full removal.
PLUGIN_STATE="$XDG_STATE_HOME/herdr/plugins/agent-tree"
TAG=$(printf '%s' "$HERDR_SOCKET_PATH" | sha256sum | cut -c1-16)
LOCK="$PLUGIN_STATE/subscriber-$TAG.lock"
if [ -f "$LOCK" ]; then
    pid=$(jq -r '.pid' "$LOCK")
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    rm -f "$LOCK"
fi
herdr plugin action invoke agent-tree.clear >/dev/null
for _ in $(seq 1 40); do
    [ "$(token_of "$P_R1" agent_tree_rank)" = "-" ] && [ "$(view_probe)" = 'false -' ] && break
    sleep 0.25
done
[ "$(token_of "$P_R1" agent_tree_rank)" = "-" ] || fail "clear did not remove the plugin tokens"
[ "$(view_probe)" = 'false -' ] || fail "clear did not remove the plugin view"
step "clear removed the plugin tokens and view"

log "The plugin wrote no configuration"
[ "$(config_has_sort)" = no ] || fail "config.toml gained ui.agent_panel_sort"
# Herdr itself records the dismissed first-run onboarding in config.toml, so compare the
# two files with that one Herdr-owned line removed; no other difference is allowed.
grep -v '^onboarding = ' "$CONFIG" > "$TMP/config.plugin-view.toml"
grep -v '^onboarding = ' "$TMP/original-config.toml" > "$TMP/config.original-view.toml"
cmp -s "$TMP/config.plugin-view.toml" "$TMP/config.original-view.toml" \
    || fail "the plugin changed config.toml: $(diff -u "$TMP/config.original-view.toml" "$TMP/config.plugin-view.toml" || true)"
step "config.toml unchanged apart from Herdr's own onboarding line; no sort key written"

log "Toggle end-to-end test passed"
