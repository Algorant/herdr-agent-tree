#!/usr/bin/env bash
#
# Noninteractive isolated Herdr end-to-end test for the agent-tree sidebar.
#
# It builds the plugin, starts an isolated Herdr instance (own HOME, all XDG dirs and an
# explicit socket, verified at runtime), installs the Pi publisher and launches 7
# credential-free idle Pi agents to obtain genuine agent_session values. It publishes the
# pi-agency-shaped relationship tokens derived from those real session paths (never
# agent_tree_* tokens), applies the projection, asserts rank ordering, rejects a forged
# agency_self, and asserts the rendered sidebar through a real tmux PTY.
#
# Everything it creates lives in one temp directory and is removed on exit, including on
# failure or interrupt; the isolated server is stopped with it. It never reads or writes the
# active Herdr server, its socket or ~/.config/herdr.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PLUGIN_DIR="$ROOT"

fail() { printf '\nsidebar-e2e: ERROR: %s\n' "$*" >&2; exit 1; }
step() { printf '  -> %s\n' "$*" >&2; }
log() { printf '\n== %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 1. Preflight: every external command this test needs, checked up front.
# ---------------------------------------------------------------------------
need() {
    command -v "$1" >/dev/null 2>&1 || fail "missing prerequisite: $1 ($2)"
}
need cargo "Rust toolchain, used to build the plugin"
need jq "JSON parsing for Herdr CLI output"
need sha256sum "coreutils, used for the agency_self hash"
need setsid "util-linux, used to detach the isolated server"
need tmux "the rendered-sidebar assertion needs a real PTY"

# Resolve the real Pi executable. Under mise, `command -v pi` may be a shim that cannot run
# with an isolated HOME, so ask mise for the real path.
pi_real=""
if command -v mise >/dev/null 2>&1; then
    pi_real=$(mise which pi 2>/dev/null || true)
fi
if [ -z "$pi_real" ] || [ ! -x "$pi_real" ]; then
    pi_real=$(command -v pi 2>/dev/null || true)
fi
[ -x "$pi_real" ] || fail "missing prerequisite: pi (needed for genuine agent_session values)"
PI_DIR=$(CDPATH= cd -- "$(dirname -- "$pi_real")" && pwd)

# Resolve the real Herdr binary before HOME changes; a mise shim fails with an isolated HOME.
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
# 3. Isolation environment. Set before any command that talks to Herdr, and clear the
#    provider credentials the throwaway agents must not be able to spend.
# ---------------------------------------------------------------------------
TMP=$(mktemp -d "${TMPDIR:-/tmp}/agent-tree-sidebar-e2e.XXXXXX")
export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/config"
export XDG_STATE_HOME="$TMP/state"
export XDG_DATA_HOME="$TMP/data"
export XDG_RUNTIME_DIR="$TMP/run"
export HERDR_SOCKET_PATH="$TMP/config/herdr/herdr.sock"
# Do not inherit the outer Herdr identity; the test talks only to the isolated socket.
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SESSION HERDR_ENV \
      HERDR_PLUGIN_ID HERDR_PLUGIN_ROOT HERDR_PLUGIN_CONFIG_DIR \
      HERDR_PLUGIN_STATE_DIR HERDR_PLUGIN_EVENT HERDR_INTEGRATION_ID

mkdir -p "$HOME/.pi/agent/extensions" "$XDG_CONFIG_HOME/herdr" "$XDG_STATE_HOME" \
         "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR" "$TMP/work" "$TMP/logs"
chmod 700 "$XDG_RUNTIME_DIR"

# Provider credentials that would let a Pi agent reach a paid model. Cleared explicitly
# rather than assumed absent, and verified again in the launched process below.
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

# The isolated TUI reads this config; a fixed sidebar width keeps the render stable.
cat > "$XDG_CONFIG_HOME/herdr/config.toml" <<'CFG'
[server]
headless_cols = 200
headless_rows = 50

[experimental]
allow_nested = true

[ui]
sidebar_width = 32
sidebar_min_width = 32
sidebar_max_width = 32

# One line per agent: status, tree decoration, then the agent's terminal title.
[ui.sidebar.agents]
rows = [["state_icon", "$agent_tree_row", "terminal_title_stripped"]]
CFG

SERVER_PID=""
TMUX_SOCKET=""

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

# ---------------------------------------------------------------------------
# 3b. Start the isolated server and prove the resolved socket is ours.
# ---------------------------------------------------------------------------
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

log "Installing the Pi publisher into the isolated HOME"
herdr integration install pi >/dev/null

log "Linking the agent-tree plugin into the isolated registry"
herdr plugin link "$PLUGIN_DIR" --enabled >/dev/null

# ---------------------------------------------------------------------------
# 4. Fixture. Real Pi agents give genuine agent_session values; the test derives the
#    relationship tokens from those real session paths and lets the plugin validate them.
# ---------------------------------------------------------------------------
self_hash() {
    jq -cnj --arg p "$1" '["pi","path",$p]' | sha256sum | awk '{print $1}'
}

mkws() {
    # Give every agent its own cwd so Pi titles itself `π - <name>`, as live sessions do.
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

# Fail closed on the no-cost property: two independent signals on the first agent, before
# any further agent is started. Missing evidence aborts; it is never treated as a pass.
verify_credentials_free() { # <pane>
    local pane="$1" info pid environ bad banner
    info=$(herdr pane process-info --pane "$pane")
    pid=$(printf '%s' "$info" \
        | jq -r '[.result.process_info.foreground_processes[] | select(.name=="pi")][0].pid // empty')
    [ -n "$pid" ] || fail "could not find the launched Pi process for $pane; NO further agents started"
    [ -r "/proc/$pid/environ" ] || fail "cannot read /proc/$pid/environ; NO further agents started"
    environ=$(tr '\0' '\n' < "/proc/$pid/environ")

    # Signal 1: no provider credential is present and non-empty in the launched process.
    for var in $CREDENTIAL_VARS; do
        if printf '%s\n' "$environ" | grep -q "^${var}=.\+"; then
            fail "provider credential $var is set in the launched Pi process; NO further agents started"
        fi
    done
    bad=$(printf '%s\n' "$environ" | awk -F= '/^[A-Za-z0-9_]+(_API_KEY|_OAUTH[A-Z0-9_]*)$/ && length($2)>0 {print $1}' | sort -u | paste -sd, -)
    [ -z "$bad" ] || fail "provider credentials in the launched Pi process ($bad); NO further agents started"

    # Signal 2: Pi reports no usable model. A missing banner is an abort, not a pass.
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

log "Creating the delegation fixture (7 credential-free idle Pi agents)"
t0=$SECONDS

# make_pi runs in the current shell and sets GP_PANE/GP_SESSION, so the one-time credential
# check below really happens once, on the first agent.
GP_PANE=""
GP_SESSION=""
make_pi() { # <name>
    GP_PANE=$(mkws "$1")
    GP_SESSION=$(start_pi "$1" "$GP_PANE")
}

# Undelegating sessions and the non-Pi row are created FIRST so native order puts them
# above the family; the projection must move the ranked tree to the top of the sidebar.
make_pi lone-1; P_L1=$GP_PANE; S_L1=$GP_SESSION
verify_credentials_free "$P_L1"
step "lone-1  (${SECONDS-t0}s)"

make_pi lone-2; P_L2=$GP_PANE; S_L2=$GP_SESSION
step "lone-2  (${SECONDS-t0}s)"

P_X1=$(mkws codex-1)
herdr pane report-agent "$P_X1" --source pi-fixture --agent codex --state idle >/dev/null
step "codex-1 (reported non-Pi agent, ${SECONDS-t0}s)"

make_pi root-alpha;   P_R1=$GP_PANE; S_R1=$GP_SESSION; step "root-alpha   (${SECONDS-t0}s)"
make_pi worker-alpha; P_W1=$GP_PANE; S_W1=$GP_SESSION; step "worker-alpha (${SECONDS-t0}s)"
H_R1=$(self_hash "$S_R1"); H_W1=$(self_hash "$S_W1")
report_rel "$P_W1" worker "$H_W1" "$H_R1" "task_id=task-e2e" "handoff=reported"

make_pi sub-alpha; P_S1=$GP_PANE; S_S1=$GP_SESSION; step "sub-alpha    (${SECONDS-t0}s)"
H_S1=$(self_hash "$S_S1")
report_rel "$P_S1" subagent "$H_S1" "$H_W1" "question=1"

make_pi root-beta; P_R2=$GP_PANE; S_R2=$GP_SESSION; step "root-beta    (${SECONDS-t0}s)"
make_pi sub-beta;  P_S2=$GP_PANE; S_S2=$GP_SESSION; step "sub-beta     (${SECONDS-t0}s)"
H_R2=$(self_hash "$S_R2"); H_S2=$(self_hash "$S_S2")
report_rel "$P_S2" subagent "$H_S2" "$H_R2"

# ---------------------------------------------------------------------------
# 5. Apply the plugin and verify the tree came from real identity validation.
# ---------------------------------------------------------------------------
log "Applying the tree projection"
herdr plugin action invoke agent-tree.apply >/dev/null

rank_of() { # <pane> -> rank or "-"
    herdr agent list | jq -r --arg p "$1" '.result.agents[] | select(.pane_id==$p) | .tokens.agent_tree_rank // "-"'
}

wait_ranked() { # <count> -> 0 if reached within ~20s
    local want="$1" got=""
    for _ in $(seq 1 40); do
        got=$(herdr agent list | jq '[.result.agents[] | select(.tokens.agent_tree_rank != null)] | length')
        [ "$got" = "$want" ] && return 0
        sleep 0.5
    done
    return 1
}

wait_ranked 5 || fail "expected 5 ranked rows; the plugin did not finish the projection"

log "Verifying real identity validation"
expect_rank() { # <pane> <expected> <label>
    local got; got=$(rank_of "$1")
    [ "$got" = "$2" ] || fail "$3: expected rank $2, got $got"
    step "$3 rank $2"
}
expect_rank "$P_R1" 000001 "root-alpha"
expect_rank "$P_W1" 000002 "worker-alpha"
expect_rank "$P_S1" 000003 "sub-alpha (Worker-owned Subagent)"
expect_rank "$P_R2" 000004 "root-beta"
expect_rank "$P_S2" 000005 "sub-beta"
for pair in "$P_L1=lone-1" "$P_L2=lone-2" "$P_X1=codex-1"; do
    [ "$(rank_of "${pair%%=*}")" = "-" ] || fail "${pair##*=} must stay unranked"
done
step "Undelegating Pi rows and the non-Pi row stayed unranked"

# Tamper proof: forge a ranked leaf Subagent's agency_self and watch the plugin recompute
# and drop it, then restore the true value and watch the rank return.
log "Tamper check: a forged agency_self must be rejected by recomputation"
herdr pane report-metadata "$P_S1" --source pi-fixture \
    --token "agency_self=$(printf '0%.0s' {1..64})" >/dev/null
dropped=0
for _ in $(seq 1 30); do
    [ "$(rank_of "$P_S1")" = "-" ] && { dropped=1; break; }
    sleep 0.5
done
[ "$dropped" = 1 ] || fail "a forged agency_self was not rejected"
step "Forged agency_self dropped the Subagent"
report_rel "$P_S1" subagent "$H_S1" "$H_W1" "question=1"
wait_ranked 5 || fail "restoring the true agency_self did not restore the tree"
[ "$(rank_of "$P_S1")" = "000003" ] || fail "Subagent rank did not return after restore"
step "True agency_self restored the Subagent rank"

# ---------------------------------------------------------------------------
# 6. Render the sidebar through a real tmux PTY and assert the tree.
# ---------------------------------------------------------------------------
log "Rendering the sidebar and asserting the tree"
TMUX_SOCKET="$TMP/tmux.sock"
rm -f "$TMUX_SOCKET"
tmux -S "$TMUX_SOCKET" new-session -d -x 150 -y 50 -s agent-tree-e2e "$HERDR_BIN"
sleep 6
# Dismiss the isolated client's first-run modal; harmless if it is not shown.
tmux -S "$TMUX_SOCKET" send-keys -t agent-tree-e2e Escape
sleep 1
tmux -S "$TMUX_SOCKET" send-keys -t agent-tree-e2e Escape
sleep 1
text=$(tmux -S "$TMUX_SOCKET" capture-pane -p -t agent-tree-e2e)
tmux -S "$TMUX_SOCKET" kill-server >/dev/null 2>&1 || true
printf '%s\n' "$text" | grep -qE 'agents +tree' || fail "the rendered sidebar did not show the 'tree' view label"
printf '%s\n' "$text" | grep -q '└─W' || fail "the rendered sidebar did not show the Worker row"
step "Sidebar rendered with the 'tree' view label and a Worker row"

log "End-to-end sidebar test passed"
