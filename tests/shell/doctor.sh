#!/usr/bin/env bash
# Hermetic acceptance tests for scripts/doctor.sh.
#
# Nothing here touches the live Herdr socket, config or installed plugin. A fake `herdr`
# serves canned local and `--machine` JSON, a fake `ssh` runs the remote probes against a
# second sandbox, and one real `agent-tree subscriber` is kept alive by a tiny socket server
# so the subscriber count, hash match and lock/tree-off state are exercised for real.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
PROGRAM=${0##*/}
fail() { printf '\n%s: ERROR: %s\n' "$PROGRAM" "$*" >&2; exit 1; }

for tool in cargo python3 sha256sum stat awk sed grep mktemp readlink; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing prerequisite: $tool"
done

# Never inherit a live Herdr identity.
unset HERDR_SOCKET_PATH HERDR_PLUGIN_STATE_DIR HERDR_PLUGIN_ID HERDR_PLUGIN_ROOT \
      HERDR_PLUGIN_CONFIG_DIR HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID \
      HERDR_BIN_PATH HERDR_ENV HERDR_SESSION 2>/dev/null || true

SB=$(mktemp -d "${TMPDIR:-/tmp}/agent-tree-doctor-test.XXXXXX")
BIN=$SB/bin
LOCAL=$SB/local
REMOTE=$SB/remote
FAKE=$SB/fake
mkdir -p "$BIN" "$LOCAL" "$REMOTE" "$FAKE/local" "$FAKE/remote"

PASS=0
pass() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$1"; }

cleanup() {
    [ -n "${SUB_PID:-}" ] && kill "$SUB_PID" 2>/dev/null || true
    [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
    rm -rf -- "$SB"
}
trap cleanup EXIT HUP INT TERM

cargo build --locked --bins --manifest-path "$ROOT/Cargo.toml" >/dev/null 2>&1 || fail 'debug build failed'
BINARY=$ROOT/target/debug/agent-tree
[ -x "$BINARY" ] || fail "debug build did not produce $BINARY"

json() { python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])))' "$1"; }

# ---------------------------------------------------------------------------
# Local fixture: registered plugin, staged binary, live subscriber, complete config.
# ---------------------------------------------------------------------------
LOCAL_HOME=$LOCAL/home
LOCAL_CONFIG=$LOCAL/config/herdr
LOCAL_DATA=$LOCAL/data
LOCAL_STATE=$LOCAL/state
LOCAL_STAGE=$LOCAL_DATA/herdr-agent-tree/stage
LOCAL_SOCKET=$LOCAL_CONFIG/herdr.sock
LOCAL_PLUGIN_STATE=$LOCAL_STATE/herdr/plugins/agent-tree
mkdir -p "$LOCAL_HOME" "$LOCAL_CONFIG" "$LOCAL_STAGE/src" "$LOCAL_PLUGIN_STATE"
cp -- "$BINARY" "$LOCAL_STAGE/src/agent-tree"
chmod 755 "$LOCAL_STAGE/src/agent-tree"
LOCAL_SHA=$(sha256sum "$LOCAL_STAGE/src/agent-tree" | awk '{print $1}')

cat >"$LOCAL_CONFIG/config.toml" <<'TOML'
[ui]
sidebar_width = 32

[ui.sidebar.agents]
rows = [["state_icon", "$agent_tree_row", "terminal_title_stripped"]]

[[keys.command]]
key = "prefix+alt+t"
type = "shell"
command = "herdr plugin action invoke agent-tree.toggle"
TOML

python3 - "$LOCAL_SOCKET" >"$FAKE/local/status.json" <<'PY'
import json, sys
print(json.dumps({"status": "running", "running": True, "version": "0.9.1", "protocol": 22,
                  "compatible": True, "endpoint_compatible": True, "socket": sys.argv[1]}))
PY

# Pane fixtures: ordinary Pi pane, a valid worker, a role-only pane, a malformed pane.
python3 - "$LOCAL_SOCKET" >"$FAKE/local/agents.json" <<'PY'
import hashlib, json, sys

def self_hash(path):
    return hashlib.sha256(json.dumps(["pi", "path", path], separators=(",", ":")).encode()).hexdigest()

root_session = "/home/example/.pi/sessions/root.jsonl"
worker_session = "/home/example/.pi/sessions/worker.jsonl"
agents = [
    {"pane_id": "w1:p1", "agent": "pi", "agent_status": "idle",
     "agent_session": {"agent": "pi", "kind": "path", "source": "herdr:pi", "value": root_session},
     "tokens": {}},
    {"pane_id": "w1:p2", "agent": "pi", "agent_status": "working",
     "agent_session": {"agent": "pi", "kind": "path", "source": "herdr:pi", "value": worker_session},
     "tokens": {"role": "worker", "agency_self": self_hash(worker_session),
                "agency_parent": self_hash(root_session), "task_id": "task-1",
                "agent_tree_rank": "000001", "agent_tree_row": "\u2514\u2500W task-1"}},
    {"pane_id": "w1:p3", "agent": "pi", "agent_status": "idle",
     "agent_session": {"agent": "pi", "kind": "path", "source": "herdr:pi", "value": "/home/example/.pi/sessions/role-only.jsonl"},
     "tokens": {"role": "worker", "task_id": "task-2"}},
    {"pane_id": "w1:p4", "agent": "pi", "agent_status": "idle",
     "agent_session": {"agent": "pi", "kind": "path", "source": "herdr:pi", "value": "/home/example/.pi/sessions/malformed.jsonl"},
     "tokens": {"role": "subagent", "agency_self": "abc", "agency_parent": "def"}},
]
print(json.dumps({"result": {"agents": agents}}))
PY

python3 - "$LOCAL_STAGE" "$LOCAL_SHA" >"$FAKE/local/plugins.json" <<'PY'
import json, sys
root, sha = sys.argv[1], sys.argv[2]
plugin = {
    "plugin_id": "agent-tree", "name": "Agent Tree", "version": "0.1.0",
    "manifest_path": root + "/herdr-plugin.toml", "plugin_root": root,
    "enabled": True, "platforms": ["linux"], "source": {"kind": "local"},
    "actions": [{"id": action, "title": action, "command": ["./src/agent-tree", action]}
                for action in ("apply", "clear", "reload", "toggle")],
    "startup": [{"command": ["./src/agent-tree", "start"]}],
}
print(json.dumps({"result": {"plugins": [plugin], "type": "plugin_list"}}))
PY

# ---------------------------------------------------------------------------
# Remote fixture (archbox): identical config, no plugin, no stage, no subscriber.
# ---------------------------------------------------------------------------
REMOTE_HOME=$REMOTE/home
REMOTE_XDG_CONFIG=$REMOTE/config
REMOTE_CONFIG=$REMOTE_XDG_CONFIG/herdr
REMOTE_DATA=$REMOTE/data
REMOTE_STATE=$REMOTE/state
mkdir -p "$REMOTE_HOME" "$REMOTE_CONFIG" "$REMOTE_DATA" "$REMOTE_STATE"
mkdir -p "$REMOTE_HOME" "$REMOTE_CONFIG" "$REMOTE_DATA" "$REMOTE_STATE"
cp -- "$LOCAL_CONFIG/config.toml" "$REMOTE_CONFIG/config.toml"
# Patch nothing: the socket is written directly below.
python3 - "$REMOTE_CONFIG/herdr.sock" >"$FAKE/remote/status.json" <<'PY'
import json, sys
print(json.dumps({"status": "running", "running": True, "version": "0.9.0", "protocol": 22,
                  "compatible": True, "endpoint_compatible": True, "socket": sys.argv[1]}))
PY
echo '{"result": {"plugins": [], "type": "plugin_list"}}' >"$FAKE/remote/plugins.json"
python3 - >"$FAKE/remote/agents.json" <<'PY'
import json
agents = [{"pane_id": "w9:p1", "agent": "pi", "agent_status": "idle",
           "agent_session": {"agent": "pi", "kind": "path", "source": "herdr:pi", "value": "/home/remote/.pi/sessions/cart.jsonl"},
           "tokens": {}}]
print(json.dumps({"result": {"agents": agents}}))
PY

# ---------------------------------------------------------------------------
# Fake herdr, fake ssh and the socket server.
# ---------------------------------------------------------------------------
cat >"$BIN/herdr" <<'SH'
#!/bin/sh
set -eu
dir=$FAKE_LOCAL_DIR
if [ "${1:-}" = "--machine" ]; then dir=$FAKE_REMOTE_DIR; shift 2; fi
first=${1:-}
second=${2:-}
case "$first $second" in
    "machine list") cat "$FAKE_MACHINES" ;;
    "status server") cat "$dir/status.json" ;;
    "plugin list") cat "$dir/plugins.json" ;;
    "agent list") cat "$dir/agents.json" ;;
    *) echo '{"error":{"code":"unsupported","message":"fake herdr"}}' >&2; exit 1 ;;
esac
SH
chmod 755 "$BIN/herdr"

cat >"$BIN/ssh" <<'SH'
#!/bin/sh
set -eu
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) shift 2 ;;
        -*) shift ;;
        *) break ;;
    esac
done
shift || true # target
exec env HOME="$FAKE_REMOTE_HOME" \
    XDG_CONFIG_HOME="$FAKE_REMOTE_CONFIG" \
    XDG_DATA_HOME="$FAKE_REMOTE_DATA" \
    XDG_STATE_HOME="$FAKE_REMOTE_STATE" \
    PATH="$FAKE_BIN:$PATH" \
    sh -c "$*"
SH
chmod 755 "$BIN/ssh"

cat >"$FAKE/machines.json" <<'JSON'
[{"id": "a5bbdad2c6a2ed308515f090ec24947a", "label": "cart-lab", "target": "archbox",
  "session": "default", "enabled": true, "selected": true}]
JSON

cat >"$SB/server.py" <<'PY'
import json, os, socketserver, sys

path = sys.argv[1]


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        for line in self.rfile:
            try:
                request = json.loads(line.decode())
            except ValueError:
                continue
            method = request.get("method")
            if method == "events.subscribe":
                result = {"type": "subscription_started"}
            elif method == "agent.list":
                result = {"agents": []}
            elif method in ("agent.view.clear", "agent.view.set"):
                result = {"active": False, "source": "", "label": ""}
            else:
                result = {}
            self.wfile.write((json.dumps({"id": request.get("id"), "result": result}) + "\n").encode())
            self.wfile.flush()


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


try:
    os.unlink(path)
except FileNotFoundError:
    pass
server = Server(path, Handler)
os.chmod(path, 0o600)
server.serve_forever()
PY
python3 "$SB/server.py" "$LOCAL_SOCKET" &
SERVER_PID=$!
for _ in $(seq 1 100); do [ -S "$LOCAL_SOCKET" ] && break; sleep 0.1; done
[ -S "$LOCAL_SOCKET" ] || fail "the fake socket server did not start"

env HERDR_PLUGIN_ID=agent-tree \
    HERDR_SOCKET_PATH="$LOCAL_SOCKET" \
    HERDR_PLUGIN_STATE_DIR="$LOCAL_PLUGIN_STATE" \
    HERDR_PLUGIN_ROOT="$LOCAL_STAGE" \
    "$LOCAL_STAGE/src/agent-tree" subscriber >"$SB/subscriber.log" 2>&1 &
SUB_PID=$!
TAG=$(printf '%s' "$LOCAL_SOCKET" | sha256sum | awk '{print substr($1,1,16)}')
for _ in $(seq 1 100); do
    [ -f "$LOCAL_PLUGIN_STATE/subscriber-$TAG.lock" ] && kill -0 "$SUB_PID" 2>/dev/null && break
    sleep 0.1
done
[ -f "$LOCAL_PLUGIN_STATE/subscriber-$TAG.lock" ] || { cat "$SB/subscriber.log" >&2; fail "the subscriber did not acquire its lock"; }

run_doctor() {
    env HOME="$SB/home" \
        XDG_CONFIG_HOME="$LOCAL/config" \
        XDG_DATA_HOME="$LOCAL/data" \
        XDG_STATE_HOME="$LOCAL/state" \
        HERDR_BIN_PATH= \
        PATH="$BIN:$PATH" \
        FAKE_LOCAL_DIR="$FAKE/local" \
        FAKE_REMOTE_DIR="$FAKE/remote" \
        FAKE_MACHINES="$FAKE/machines.json" \
        FAKE_REMOTE_HOME="$REMOTE_HOME" \
        FAKE_REMOTE_CONFIG="$REMOTE_XDG_CONFIG" \
        FAKE_REMOTE_DATA="$REMOTE_DATA" \
        FAKE_REMOTE_STATE="$REMOTE_STATE" \
        FAKE_BIN="$BIN" \
        "$ROOT/scripts/doctor.sh" "$@"
}

# ---------------------------------------------------------------------------
# 1. Local endpoint is healthy with the exact pane classification.
# ---------------------------------------------------------------------------
printf '== local endpoint\n'
run_doctor --endpoint local --json >"$SB/local.json" || { cat "$SB/local.json" >&2; fail 'doctor failed for local'; }
python3 - "$SB/local.json" <<'PY' || fail 'local report is not healthy or classified panes incorrectly'
import json, sys
doc = json.load(open(sys.argv[1]))
endpoint = doc["endpoints"][0]
assert endpoint["verdict"] == "healthy", endpoint
assert endpoint["subscriber"]["count"] == 1, endpoint["subscriber"]
assert endpoint["subscriber"]["matches_staged"] is True, endpoint["subscriber"]
assert endpoint["sidebar"]["agent_tree_row_present"] is True, endpoint["sidebar"]
assert endpoint["shortcut"]["present"] is True, endpoint["shortcut"]
panes = endpoint["panes"]
assert panes["relationship_bearing"] == 1, panes
assert panes["relationship_valid"] == 1, panes
assert panes["ranked"] == 1, panes
assert panes["delegated_missing_relationship"] == 2, panes
assert panes["ordinary_pi"] == 1, panes
assert doc["split_state"] is False
PY
pass 'local endpoint reports healthy and separates role-declared from ordinary panes'

# ---------------------------------------------------------------------------
# 2. Remote endpoint: shortcut + $agent_tree_row present, no plugin -> degraded split state.
# ---------------------------------------------------------------------------
printf '== remote endpoint\n'
run_doctor --endpoint archbox --json >"$SB/remote.json" || { cat "$SB/remote.json" >&2; fail 'doctor failed for archbox'; }
python3 - "$SB/remote.json" <<'PY' || fail 'remote report did not identify the split state'
import json, sys
endpoint = json.load(open(sys.argv[1]))["endpoints"][0]
assert endpoint["kind"] == "remote" and endpoint["label"] == "cart-lab" and endpoint["target"] == "archbox", endpoint
assert endpoint["verdict"] == "degraded", endpoint
assert endpoint["plugin"]["registered"] is False, endpoint["plugin"]
assert endpoint["shortcut"]["present"] is True, endpoint["shortcut"]
assert endpoint["sidebar"]["agent_tree_row_present"] is True, endpoint["sidebar"]
assert any("not registered" in issue for issue in endpoint["issues"]), endpoint["issues"]
assert endpoint["panes"]["delegated_missing_relationship"] == 0, endpoint["panes"]
assert endpoint["panes"]["ordinary_pi"] == 1, endpoint["panes"]
PY
pass 'archbox is reported as shortcut+sidebar without a plugin (degraded)'

printf '== split state\n'
run_doctor --endpoint local --endpoint archbox --json >"$SB/both.json"
python3 - "$SB/both.json" <<'PY' || fail 'combined report did not flag the split state'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["split_state"] is True, doc
kinds = [endpoint["kind"] for endpoint in doc["endpoints"]]
assert kinds == ["local", "remote"], kinds
PY
pass 'combined local+remote report flags the split state'

# ---------------------------------------------------------------------------
# 3. Resolution accepts label, SSH target and profile id, ignoring the TUI selection.
# ---------------------------------------------------------------------------
printf '== explicit endpoint resolution\n'
for spec in cart-lab archbox a5bbdad2c6a2ed308515f090ec24947a; do
    run_doctor --endpoint "$spec" --json >"$SB/resolve-$spec.json" || fail "resolution failed for $spec"
    python3 - "$SB/resolve-$spec.json" <<'PY' || fail "resolution for $spec did not reach archbox"
import json, sys
endpoint = json.load(open(sys.argv[1]))["endpoints"][0]
assert endpoint["kind"] == "remote" and endpoint["label"] == "cart-lab", endpoint
PY
done
pass 'label, SSH target and profile id all resolve to the same explicit endpoint'

printf '== unknown endpoint is refused\n'
if run_doctor --endpoint does-not-exist >"$SB/unknown.out" 2>&1; then
    fail 'doctor accepted an unknown endpoint'
fi
grep -q 'unknown endpoint' "$SB/unknown.out" || fail 'doctor did not explain the unknown endpoint'
pass 'an unknown endpoint fails clearly instead of guessing'

# ---------------------------------------------------------------------------
# 4. A foreign [ui.sidebar.agents] block without the token is reported, not overwritten.
# ---------------------------------------------------------------------------
printf '== foreign sidebar block\n'
cp -- "$REMOTE_CONFIG/config.toml" "$SB/remote-config.bak"
cat >"$REMOTE_CONFIG/config.toml" <<'TOML'
[ui.sidebar.agents]
rows = [["state_icon", "terminal_title_stripped"]]
TOML
FOREIGN_SHA=$(sha256sum "$REMOTE_CONFIG/config.toml" | awk '{print $1}')
run_doctor --endpoint archbox --json >"$SB/foreign.json"
python3 - "$SB/foreign.json" <<'PY' || fail 'foreign block was not classified as lacking the token'
import json, sys
endpoint = json.load(open(sys.argv[1]))["endpoints"][0]
assert endpoint["sidebar"]["foreign_without_token"] is True, endpoint["sidebar"]
assert endpoint["sidebar"]["agent_tree_row_present"] is False, endpoint["sidebar"]
PY
[ "$FOREIGN_SHA" = "$(sha256sum "$REMOTE_CONFIG/config.toml" | awk '{print $1}')" ] \
    || fail 'the doctor modified the endpoint config'
pass 'a foreign sidebar block without the token is reported and left untouched'

# ---------------------------------------------------------------------------
# 5. The doctor never writes to either endpoint config.
# ---------------------------------------------------------------------------
printf '== read-only\n'
BEFORE_LOCAL=$(sha256sum "$LOCAL_CONFIG/config.toml" | awk '{print $1}')
BEFORE_REMOTE=$(sha256sum "$REMOTE_CONFIG/config.toml" | awk '{print $1}')
run_doctor --endpoint local --endpoint archbox >/dev/null
[ "$BEFORE_LOCAL" = "$(sha256sum "$LOCAL_CONFIG/config.toml" | awk '{print $1}')" ] || fail 'local config changed'
[ "$BEFORE_REMOTE" = "$(sha256sum "$REMOTE_CONFIG/config.toml" | awk '{print $1}')" ] || fail 'remote config changed'
pass 'the doctor is read-only for local and remote config'

printf '1..%d\n' "$PASS"
