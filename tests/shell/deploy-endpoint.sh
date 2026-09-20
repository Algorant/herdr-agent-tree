#!/usr/bin/env bash
# Hermetic acceptance tests for scripts/deploy-endpoint.sh.
#
# Nothing here touches the live Herdr socket, config or installed plugin. A fake `cargo`
# supplies a prebuilt binary into a private CARGO_TARGET_DIR, a fake `herdr` models the
# forwarded API by profile id, a fake `ssh` runs the argv-safe runner against a second
# sandbox, the plugin root is streamed as a tar archive over the argv-safe SSH runner,
# and a tiny socket server keeps real `agent-tree subscriber` processes alive. The scenarios cover the transactional deploy,
# per-substep stage rollback, registration/enabled restoration, prior-root verification,
# automatic lock serialization, argv-safe weird paths, config refusals, identity-verified
# uninstall and rollback-failure reporting.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
PROGRAM=${0##*/}
fail() { printf '\n%s: ERROR: %s\n' "$PROGRAM" "$*" >&2; exit 1; }
step() { printf '  -> %s\n' "$*" >&2; }

for tool in cargo python3 sha256sum stat awk sed grep mktemp readlink; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing prerequisite: $tool"
done
REAL_UNAME=$(command -v uname)
REAL_MV=$(command -v mv)
REAL_CAT=$(command -v cat)
REAL_RM=$(command -v rm)

unset HERDR_SOCKET_PATH HERDR_PLUGIN_STATE_DIR HERDR_PLUGIN_ID HERDR_PLUGIN_ROOT \
      HERDR_PLUGIN_CONFIG_DIR HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID \
      HERDR_BIN_PATH HERDR_ENV HERDR_SESSION 2>/dev/null || true

SB=$(mktemp -d "${TMPDIR:-/tmp}/agent-tree-endpoint-test.XXXXXX")
BIN=$SB/bin
REMOTE=$SB/remote
FAKE=$SB/fake
mkdir -p "$BIN" "$FAKE"

PASS=0
pass() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$1"; }

kill_tree_pids() {
    for proc in /proc/[0-9]*; do
        pid=${proc#/proc/}
        exe=$(readlink "$proc/exe" 2>/dev/null || true)
        exe=${exe% (deleted)}
        case "$exe" in "$SB"/*) kill -9 "$pid" 2>/dev/null || true ;; esac
    done
    sleep 0.2
}

cleanup() {
    kill_tree_pids
    [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
    rm -rf -- "$SB"
}
trap cleanup EXIT HUP INT TERM

cargo build --locked --bins --manifest-path "$ROOT/Cargo.toml" >/dev/null 2>&1 || fail 'debug build failed'
BINARY=$ROOT/target/debug/agent-tree
[ -x "$BINARY" ] || fail "debug build did not produce $BINARY"
BINARY_B=$SB/agent-tree-b
cp -- "$BINARY" "$BINARY_B"
printf 'EXTRA' >>"$BINARY_B"
chmod 755 "$BINARY_B"

REMOTE_HOME=$REMOTE/home
REMOTE_XDG_CONFIG=$REMOTE/config
REMOTE_CONFIG=$REMOTE_XDG_CONFIG/herdr
REMOTE_DATA=$REMOTE/data
REMOTE_STATE=$REMOTE/state
REMOTE_PREFIX=$REMOTE_DATA/herdr-agent-tree
REMOTE_STAGE=$REMOTE_PREFIX/stage
REMOTE_RELEASE=$REMOTE_PREFIX/release
REMOTE_SOCKET=$REMOTE/sock/herdr.sock
REMOTE_PLUGIN_STATE=$REMOTE_STATE/herdr/plugins/agent-tree
TAG=$(printf '%s' "$REMOTE_SOCKET" | sha256sum | awk '{print substr($1,1,16)}')
LOCK_FILE=$REMOTE_PLUGIN_STATE/subscriber-$TAG.lock
DEPLOY_LOCK=$REMOTE_PREFIX/.agent-tree-deploy.lock
REG_FILE=$SB/registered-root
ENABLED_FILE=$SB/registered-enabled
LINK_FAILED=$SB/link-failed
STAGE_NEW_FAILED=$SB/stage-new-failed
CONFIG_MV_FAILED=$SB/config-mv-failed
RELOAD_MARKER=$SB/reload-config-called
STAGE_CLEANUP_FAILED=$SB/stage-cleanup-failed
STAGE_RM_FAILED=$SB/stage-rm-failed
CONFIG_READ_COUNT=$SB/config-read-count

reset_remote() {
    kill_tree_pids
    rm -rf -- "$REMOTE_HOME" "$REMOTE_XDG_CONFIG" "$REMOTE_DATA" "$REMOTE_STATE" \
        "$REG_FILE" "$ENABLED_FILE" "$LINK_FAILED" "$STAGE_NEW_FAILED" "$CONFIG_MV_FAILED" \
        "$RELOAD_MARKER" "$STAGE_CLEANUP_FAILED" "$STAGE_RM_FAILED" "$CONFIG_READ_COUNT" \
        "$SB/seq" "$SB/logs" "$SB/reload-done" "$SB/config-edited" "$SB/profiles.log"
    mkdir -p "$REMOTE_HOME" "$REMOTE_CONFIG" "$REMOTE_DATA" "$REMOTE_STATE"
    cat >"$REMOTE_CONFIG/config.toml" <<'TOML'
[ui]
sidebar_width = 32
TOML
}

cat >"$BIN/cargo" <<'SH'
#!/bin/sh
set -eu
dest=${CARGO_TARGET_DIR:-$FAKE_PLUGIN/target}/release
mkdir -p "$dest"
cp "$FAKE_PREBUILT" "$dest/agent-tree.new"
mv -f "$dest/agent-tree.new" "$dest/agent-tree"
chmod 755 "$dest/agent-tree"
SH
chmod 755 "$BIN/cargo"


cat >"$BIN/uname" <<SH
#!/bin/sh
if [ "\${FAKE_REMOTE_MARKER:-0}" = 1 ] && [ -n "\${FAKE_REMOTE_UNAME:-}" ] && [ "\$1 \$2" = "-s -m" ]; then
    printf '%s\n' "\$FAKE_REMOTE_UNAME"
    exit 0
fi
exec "$REAL_UNAME" "\$@"
SH
chmod 755 "$BIN/uname"

cat >"$BIN/mv" <<SH
#!/bin/sh
last=; prev=
for a in "\$@"; do prev=\$last; last=\$a; done
if [ "\${FAKE_FAIL_STAGE_NEW:-0}" = 1 ] && [ ! -f "$STAGE_NEW_FAILED" ]; then
    case "\$last" in */stage) case "\$prev" in *.stage-new.*) : >"$STAGE_NEW_FAILED"; exit 1 ;; esac ;; esac
fi
if [ "\${FAKE_FAIL_CONFIG_MV:-0}" = 1 ] && [ ! -f "$CONFIG_MV_FAILED" ] && [ "\$last" = "\${FAKE_REMOTE_CONFIG_PATH:-}" ]; then
    : >"$CONFIG_MV_FAILED"; exit 1
fi
exec "$REAL_MV" "\$@"
SH
chmod 755 "$BIN/mv"

cat >"$BIN/rm" <<SH
#!/bin/sh
last=
for a in "\$@"; do last=\$a; done
if [ "\${FAKE_FAIL_UNINSTALL_STAGE_RM:-0}" = 1 ] && [ ! -f "$STAGE_RM_FAILED" ]; then
    case "\$last" in *.stage-uninstall.*) : >"$STAGE_RM_FAILED"; exit 1 ;; esac
fi
if [ "\${FAKE_FAIL_STAGE_CLEANUP:-0}" = 1 ] && [ ! -f "$STAGE_CLEANUP_FAILED" ]; then
    case "\$last" in *.stage-old.*|*.stage-new.*|*.stage-failed.*) : >"$STAGE_CLEANUP_FAILED"; exit 1 ;; esac
fi
exec "$REAL_RM" "\$@"
SH
chmod 755 "$BIN/rm"

cat >"$BIN/cat" <<SH
#!/bin/sh
last=
for a in "\$@"; do last=\$a; done
if [ "\${FAKE_STEAL_LOCK:-0}" = 1 ]; then
    case "\$last" in */owner) printf 'intruder'; exit 0 ;; esac
fi
if [ "\${FAKE_CONCURRENT_CONFIG_EDIT:-0}" = 1 ] && [ -f "\${FAKE_RELOAD_DONE:-/nonexistent}" ] && [ ! -f "\${FAKE_CONFIG_EDITED:-/nonexistent}" ] && [ "\$last" = "\${FAKE_REMOTE_CONFIG_PATH:-}" ]; then
    printf '\n# concurrent edit\n' >> "\$last"
    : > "\$FAKE_CONFIG_EDITED"
fi
if [ "\${FAKE_UNINSTALL_CONCURRENT_CONFIG_EDIT:-0}" = 1 ] && [ "\$last" = "\${FAKE_REMOTE_CONFIG_PATH:-}" ]; then
    n=0
    if [ -f "\${FAKE_CONFIG_READ_COUNT:-/nonexistent}" ]; then read -r n < "\$FAKE_CONFIG_READ_COUNT"; fi
    n=\$((n + 1))
    printf '%s\n' "\$n" > "\$FAKE_CONFIG_READ_COUNT"
    if [ "\$n" = 2 ]; then printf '\n# concurrent uninstall edit\n' >> "\$last"; fi
fi
exec "$REAL_CAT" "\$@"
SH
chmod 755 "$BIN/cat"

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
shift || true
exec env HOME="$FAKE_REMOTE_HOME" \
    XDG_CONFIG_HOME="$FAKE_REMOTE_XDG_CONFIG" \
    XDG_DATA_HOME="$FAKE_REMOTE_DATA" \
    XDG_STATE_HOME="$FAKE_REMOTE_STATE" \
    FAKE_REMOTE_MARKER=1 \
    PATH="$FAKE_BIN:$PATH" \
    sh -c "$*"
SH
chmod 755 "$BIN/ssh"

cat >"$BIN/herdr" <<'SH'
#!/bin/sh
set -eu
if [ "${1:-}" = "--machine" ]; then
    [ -n "${FAKE_PROFILE_LOG:-}" ] && printf '%s\n' "$2" >>"$FAKE_PROFILE_LOG"
    shift 2
fi
first=${1:-}
second=${2:-}
case "$first $second" in
    "machine list") cat "$FAKE_MACHINES" ;;
    "status server") cat "$FAKE_REMOTE_STATUS" ;;
    "agent list") printf '{"result":{"agents":[]}}\n' ;;
    "server reload-config")
        if [ "${FAKE_FAIL_UNINSTALL_RELOAD_CONFIG:-0}" = 1 ]; then printf 'injected reload-config failure\n' >&2; exit 1; fi
        touch "$FAKE_RELOAD_MARKER"; printf '{"result":{"status":"applied"}}\n' ;;
    "plugin list")
        if [ -f "$FAKE_REG_FILE" ]; then
            root=$(cat "$FAKE_REG_FILE")
            enabled=false
            [ -f "$FAKE_ENABLED_FILE" ] && enabled=true
            printf '{"result":{"plugins":[{"plugin_id":"agent-tree","name":"Agent Tree","version":"0.1.0",'
            printf '"manifest_path":"%s/herdr-plugin.toml","plugin_root":"%s","enabled":%s,"source":{"kind":"local"},' "$root" "$root" "$enabled"
            printf '"actions":[{"id":"apply","command":["./src/agent-tree","apply"]},{"id":"clear","command":["./src/agent-tree","clear"]},{"id":"reload","command":["./src/agent-tree","reload"]},{"id":"toggle","command":["./src/agent-tree","toggle"]}]}],"type":"plugin_list"}}\n'
        else
            printf '{"result":{"plugins":[],"type":"plugin_list"}}\n'
        fi
        ;;
    "plugin unlink") rm -f "$FAKE_REG_FILE" "$FAKE_ENABLED_FILE"; printf '{"result":{"plugin_id":"agent-tree"}}\n' ;;
    "plugin disable")
        if [ "${FAKE_FAIL_UNLINK:-0}" = 1 ] && [ "${3:-}" = "--definitely-not" ]; then printf 'nope\n' >&2; exit 1; fi
        rm -f "$FAKE_ENABLED_FILE"; printf '{"result":{"plugin_id":"agent-tree"}}\n' ;;
    "plugin link")
        path=$3
        enabled=true
        for arg in "$@"; do [ "$arg" = "--disabled" ] && enabled=false; done
        if [ "${FAKE_FAIL_LINK_ALWAYS:-0}" = 1 ]; then
            printf 'injected link failure\n' >&2; exit 1
        fi
        if [ "${FAKE_FAIL_LINK_ONCE:-0}" = 1 ] && [ ! -f "$FAKE_LINK_FAILED" ]; then
            : >"$FAKE_LINK_FAILED"
            printf 'injected one-shot link failure\n' >&2; exit 1
        fi
        printf '%s' "$path" >"$FAKE_REG_FILE"
        if [ "$enabled" = true ]; then : >"$FAKE_ENABLED_FILE"; else rm -f "$FAKE_ENABLED_FILE"; fi
        printf '{"result":{"plugin_id":"agent-tree"}}\n'
        ;;
    "plugin action")
        action=${4#agent-tree.}
        seq=0
        [ -f "$FAKE_SEQ" ] && seq=$(cat "$FAKE_SEQ")
        seq=$((seq + 1))
        printf '%s' "$seq" >"$FAKE_SEQ"
        log_id="plugin-log-$seq"
        mkdir -p "$FAKE_LOGS"
        record="$FAKE_LOGS/$log_id.json"
        printf '{"log_id":"%s","plugin_id":"agent-tree","action_id":"%s","status":"running"}\n' "$log_id" "$action" >"$record"
        (
            root=$(cat "$FAKE_REG_FILE" 2>/dev/null || true)
            out=$FAKE_LOGS/$log_id.out
            err=$FAKE_LOGS/$log_id.err
            rc=0
            if [ "${FAKE_FAIL_UNINSTALL_CLEAR:-0}" = 1 ] && [ "$action" = clear ]; then
                rc=1
                printf 'injected clear failure\n' >"$err"
            elif [ "${FAKE_FAIL_RELOAD:-0}" = 1 ] && [ "$action" = reload ]; then
                rc=1
                printf 'injected reload failure\n' >"$err"
            elif [ -z "$root" ]; then
                rc=1
                printf 'no registered plugin root\n' >"$err"
            else
                env HERDR_PLUGIN_ID=agent-tree \
                    HERDR_PLUGIN_ROOT="$root" \
                    HERDR_PLUGIN_STATE_DIR="$FAKE_REMOTE_PLUGIN_STATE" \
                    HERDR_SOCKET_PATH="$FAKE_REMOTE_SOCKET" \
                    "$root/src/agent-tree" "$action" >"$out" 2>"$err" || rc=$?
            fi
            if [ "$action" = reload ] && [ "$rc" = 0 ] && [ -n "${FAKE_RELOAD_DONE:-}" ]; then : >"$FAKE_RELOAD_DONE"; fi
            python3 - "$record" "$rc" "$out" "$err" <<'PY'
import json, os, sys
record, rc, out, err = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
data = json.load(open(record))
data["status"] = "succeeded" if rc == 0 else "failed"
data["exit_code"] = rc
data["stdout"] = open(out).read() if os.path.exists(out) else ""
data["stderr"] = open(err).read() if os.path.exists(err) else ""
tmp = record + ".tmp"
json.dump(data, open(tmp, "w"))
os.replace(tmp, record)
PY
        ) >/dev/null 2>&1 </dev/null &
        printf '{"id":"cli:plugin","result":{"log":{"log_id":"%s","plugin_id":"agent-tree","status":"running"},"type":"plugin_action_invoked"}}\n' "$log_id"
        ;;
    "plugin log")
        python3 - "$FAKE_LOGS" <<'PY'
import glob, json, os, sys
records = []
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.json"))):
    try:
        records.append(json.load(open(path)))
    except Exception:
        pass
print(json.dumps({"id": "cli:plugin", "result": {"logs": records, "type": "plugin_log_list"}}))
PY
        ;;
    *) printf 'fake herdr: unsupported %s %s\n' "$first" "$second" >&2; exit 1 ;;
esac
SH
chmod 755 "$BIN/herdr"

cat >"$FAKE/machines.json" <<'JSON'
[{"id": "a5bbdad2c6a2ed308515f090ec24947a", "label": "cart-lab", "target": "archbox",
  "session": "default", "enabled": true, "selected": true}]
JSON

mkdir -p "$REMOTE_CONFIG" "$REMOTE/sock"
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
python3 "$SB/server.py" "$REMOTE_SOCKET" &
SERVER_PID=$!
for _ in $(seq 1 100); do [ -S "$REMOTE_SOCKET" ] && break; sleep 0.1; done
[ -S "$REMOTE_SOCKET" ] || fail "the fake socket server did not start"

python3 - "$REMOTE_SOCKET" >"$FAKE/remote-status.json" <<'PY'
import json, sys
print(json.dumps({"status": "running", "running": True, "version": "0.9.0", "protocol": 22,
                  "compatible": True, "endpoint_compatible": True, "socket": sys.argv[1]}))
PY

export_fixture_env() {
    export FAKE_PLUGIN="$ROOT"
    export CARGO_TARGET_DIR="$SB/target"
    export FAKE_PREBUILT="${DEPLOY_PREBUILT:-$BINARY}"
    export FAKE_FAIL_LINK_ONCE="${DEPLOY_FAIL_LINK_ONCE:-0}"
    export FAKE_FAIL_LINK_ALWAYS="${DEPLOY_FAIL_LINK_ALWAYS:-0}"
    export FAKE_FAIL_STAGE_NEW="${DEPLOY_FAIL_STAGE_NEW:-0}"
    export FAKE_FAIL_CONFIG_MV="${DEPLOY_FAIL_CONFIG_MV:-0}"
    export FAKE_FAIL_RELOAD="${DEPLOY_FAIL_RELOAD:-0}"
    export FAKE_CONCURRENT_CONFIG_EDIT="${DEPLOY_CONCURRENT_CONFIG_EDIT:-0}"
    export FAKE_RELOAD_DONE="$SB/reload-done"
    export FAKE_CONFIG_EDITED="$SB/config-edited"
    export FAKE_PROFILE_LOG="$SB/profiles.log"
    export FAKE_FAIL_UNINSTALL_CLEAR="${DEPLOY_FAIL_UNINSTALL_CLEAR:-0}"
    export FAKE_FAIL_UNINSTALL_RELOAD_CONFIG="${DEPLOY_FAIL_UNINSTALL_RELOAD_CONFIG:-0}"
    export FAKE_FAIL_UNINSTALL_STAGE_RM="${DEPLOY_FAIL_UNINSTALL_STAGE_RM:-0}"
    export FAKE_FAIL_STAGE_CLEANUP="${DEPLOY_FAIL_STAGE_CLEANUP:-0}"
    export FAKE_UNINSTALL_CONCURRENT_CONFIG_EDIT="${DEPLOY_UNINSTALL_CONCURRENT_CONFIG_EDIT:-0}"
    export FAKE_CONFIG_READ_COUNT="$CONFIG_READ_COUNT"
    export FAKE_STEAL_LOCK="${DEPLOY_STEAL_LOCK:-0}"
    export FAKE_MACHINES="$FAKE/machines.json"
    export FAKE_REMOTE_STATUS="$FAKE/remote-status.json"
    export FAKE_REG_FILE="$REG_FILE"
    export FAKE_ENABLED_FILE="$ENABLED_FILE"
    export FAKE_LINK_FAILED="$LINK_FAILED"
    export FAKE_RELOAD_MARKER="$RELOAD_MARKER"
    export FAKE_SEQ="$SB/seq"
    export FAKE_LOGS="$SB/logs"
    export FAKE_REMOTE_HOME="$REMOTE_HOME"
    export FAKE_REMOTE_XDG_CONFIG="$REMOTE_XDG_CONFIG"
    export FAKE_REMOTE_DATA="$REMOTE_DATA"
    export FAKE_REMOTE_STATE="$REMOTE_STATE"
    export FAKE_REMOTE_PLUGIN_STATE="$REMOTE_PLUGIN_STATE"
    export FAKE_REMOTE_SOCKET="$REMOTE_SOCKET"
    export FAKE_REMOTE_CONFIG_PATH="$REMOTE_CONFIG/config.toml"
    export HOME="$SB/home"
    export XDG_CONFIG_HOME="$SB/home/config"
    export XDG_DATA_HOME="$SB/home/data"
    export XDG_STATE_HOME="$SB/home/state"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$SB/logs"
    export HERDR_BIN_PATH=
    export FAKE_BIN="${DEPLOY_FAKE_BIN:-$BIN}"
    export PATH="$BIN:$PATH"
}

run_deploy() {
    export_fixture_env
    (
        cd "$ROOT"
        ./scripts/deploy-endpoint.sh --endpoint archbox --yes "$@"
    )
}

run_uninstall() {
    export_fixture_env
    (
        cd "$ROOT"
        ./scripts/deploy-endpoint.sh --endpoint archbox --uninstall
    )
}

probe_path() {
    python3 "$ROOT/scripts/lib/probe.py" --socket "$REMOTE_SOCKET" --stage "$1" --state-dir "$REMOTE_PLUGIN_STATE"
}

start_subscriber() {
    local root=$1
    export_fixture_env
    mkdir -p "$REMOTE_PLUGIN_STATE"
    env HERDR_PLUGIN_ID=agent-tree HERDR_SOCKET_PATH="$REMOTE_SOCKET" \
        HERDR_PLUGIN_STATE_DIR="$REMOTE_PLUGIN_STATE" HERDR_PLUGIN_ROOT="$root" \
        "$root/src/agent-tree" subscriber >"$SB/subscriber-$RANDOM.log" 2>&1 &
    for _ in $(seq 1 100); do [ -f "$LOCK_FILE" ] && break; sleep 0.1; done
    [ -f "$LOCK_FILE" ] || fail "the subscriber for $root did not acquire its lock"
}

# ---------------------------------------------------------------------------
# 1. Successful transactional deploy: absolute herdr shortcut, verified subscriber, lock free.
# ---------------------------------------------------------------------------
step "scenario 1: success"
reset_remote
run_deploy >"$SB/deploy1.out" 2>"$SB/deploy1.err" || { cat "$SB/deploy1.err" >&2; fail 'first endpoint deploy failed'; }
[ -x "$REMOTE_STAGE/src/agent-tree" ] || fail 'the endpoint stage was not committed'
BUILD_SHA=$(sha256sum "$CARGO_TARGET_DIR/release/agent-tree" | awk '{print $1}')
[ "$(sha256sum "$REMOTE_STAGE/src/agent-tree" | awk '{print $1}')" = "$BUILD_SHA" ] || fail 'the staged binary does not match the build'
[ "$(cat "$REG_FILE")" = "$REMOTE_STAGE" ] || fail 'the plugin was not registered at the stage'
[ -f "$ENABLED_FILE" ] || fail 'the plugin was not enabled'
[ -f "$RELOAD_MARKER" ] || fail 'the endpoint config was not reloaded after installing fragments'
[ ! -e "$DEPLOY_LOCK" ] || fail 'the deploy lock was not released'
grep -qF '$agent_tree_row' "$REMOTE_CONFIG/config.toml" || fail 'the managed sidebar fragment was not installed'
grep -qF "$BIN/herdr plugin action invoke agent-tree.toggle" "$REMOTE_CONFIG/config.toml" \
    || fail 'the managed shortcut did not use the resolved absolute herdr path'
python3 - "$(probe_path "$REMOTE_STAGE/src/agent-tree")" <<'PY' || fail 'the endpoint subscriber was not verified'
import json, sys
probe = json.loads(sys.argv[1])
assert probe["subscriber_count"] == 1, probe
assert not probe["replaced_stage_subscribers"], probe
assert probe["stage"]["sha256"] == probe["subscribers"][0]["sha256"], probe
PY
pass 'a named endpoint deploys transactionally, locks serialization, and installs an absolute-herdr shortcut'

# ---------------------------------------------------------------------------
# 2. Re-running is idempotent.
# ---------------------------------------------------------------------------
step "scenario 2: idempotent redeploy"
BEFORE_CONFIG=$(sha256sum "$REMOTE_CONFIG/config.toml" | awk '{print $1}')
run_deploy >"$SB/deploy2.out" 2>"$SB/deploy2.err" || { cat "$SB/deploy2.err" >&2; fail 'second endpoint deploy failed'; }
[ "$BEFORE_CONFIG" = "$(sha256sum "$REMOTE_CONFIG/config.toml" | awk '{print $1}')" ] || fail 'redeploy rewrote an already-correct config'
grep -q 'left byte-for-byte untouched' "$SB/deploy2.err" || fail 'redeploy did not report the preserved config'
[ ! -e "$DEPLOY_LOCK" ] || fail 'redeploy left the deploy lock'
pass 'redeploy preserves the installed config and leaves exactly one subscriber'

# ---------------------------------------------------------------------------
# 2b. A managed prefix+alt+t shortcut migrates to prefix+t; a foreign prefix+t
#     colliding with the managed block is refused with the config byte-for-byte unchanged.
# ---------------------------------------------------------------------------
step "scenario 2b: managed shortcut migration and collision"
reset_remote
run_deploy >"$SB/migrate1.out" 2>"$SB/migrate1.err" || { cat "$SB/migrate1.err" >&2; fail 'migration setup deploy failed'; }
grep -q 'key = "prefix+t"' "$REMOTE_CONFIG/config.toml" || fail 'the initial deploy did not install prefix+t'
python3 - "$REMOTE_CONFIG/config.toml" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
assert 'key = "prefix+t"' in text, text
open(path, "w").write(text.replace('key = "prefix+t"', 'key = "prefix+alt+t"'))
PY
grep -q 'prefix+alt+t' "$REMOTE_CONFIG/config.toml" || fail 'the legacy managed key was not staged'
run_deploy >"$SB/migrate2.out" 2>"$SB/migrate2.err" || { cat "$SB/migrate2.err" >&2; fail 'migration redeploy failed'; }
grep -q 'key = "prefix+t"' "$REMOTE_CONFIG/config.toml" || fail 'the managed block was not migrated to prefix+t'
grep -q 'prefix+alt+t' "$REMOTE_CONFIG/config.toml" && fail 'the legacy managed key survived migration' || true
MIGRATED_SHA=$(sha256sum "$REMOTE_CONFIG/config.toml" | awk '{print $1}')
run_deploy >"$SB/migrate3.out" 2>"$SB/migrate3.err" || { cat "$SB/migrate3.err" >&2; fail 'post-migration redeploy failed'; }
[ "$MIGRATED_SHA" = "$(sha256sum "$REMOTE_CONFIG/config.toml" | awk '{print $1}')" ] || fail 'migration was not idempotent'
grep -q 'left byte-for-byte untouched' "$SB/migrate3.err" || fail 'the idempotent redeploy did not preserve the config'

# Critical collision: the managed block is back on the legacy key while a separate foreign
# binding already owns prefix+t. Refuse, and leave the complete config byte-for-byte unchanged.
python3 - "$REMOTE_CONFIG/config.toml" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
text = text.replace('key = "prefix+t"', 'key = "prefix+alt+t"')
text += '\n[[keys.command]]\nkey = "prefix+t"\ntype = "shell"\ncommand = "echo foreign"\n'
open(path, "w").write(text)
PY
COLLIDE_SHA=$(sha256sum "$REMOTE_CONFIG/config.toml" | awk '{print $1}')
run_deploy >"$SB/collide.out" 2>"$SB/collide.err" && fail 'deploy migrated a managed block onto a foreign prefix+t' || true
grep -q 'bound to another command' "$SB/collide.err" || { cat "$SB/collide.err" >&2; fail 'the collision refusal did not explain the occupied key'; }
[ "$COLLIDE_SHA" = "$(sha256sum "$REMOTE_CONFIG/config.toml" | awk '{print $1}')" ] || fail 'the collision refusal changed the config byte-for-byte'
[ ! -e "$DEPLOY_LOCK" ] || fail 'the collision refusal left a deploy lock'
python3 - "$ROOT/scripts/lib/config.py" "$REMOTE_CONFIG/config.toml" <<'PY' || fail 'config.py ensure did not refuse the managed/foreign prefix+t collision'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("config", sys.argv[1])
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)
lines = open(sys.argv[2]).read().splitlines(keepends=True)
try:
    config.ensure(lines, config.DEFAULT_ROWS, config.DEFAULT_KEY, config.DEFAULT_COMMAND)
except config.Refused:
    raise SystemExit(0)
raise SystemExit("ensure accepted a foreign prefix+t beside a managed legacy block")
PY
pass 'a managed legacy shortcut migrates to prefix+t idempotently, and a foreign prefix+t bound to another command is refused with the config unchanged'

# ---------------------------------------------------------------------------
# 3. Architecture gate.
# ---------------------------------------------------------------------------
step "scenario 3: architecture gate"
reset_remote
export FAKE_REMOTE_UNAME="Linux aarch64"
if run_deploy >"$SB/arch.out" 2>"$SB/arch.err"; then fail 'deploy accepted an architecture mismatch'; fi
unset FAKE_REMOTE_UNAME
grep -q 'phase: build' "$SB/arch.err" || fail 'the architecture gate did not name the build phase'
[ ! -e "$REMOTE_STAGE" ] || fail 'the architecture gate mutated the endpoint stage'
[ ! -f "$REG_FILE" ] || fail 'the architecture gate registered the plugin'
[ ! -e "$DEPLOY_LOCK" ] || fail 'the architecture gate left a deploy lock'
pass 'an architecture mismatch fails at the build phase with no endpoint mutation'

# ---------------------------------------------------------------------------
# 4. Loader gate.
# ---------------------------------------------------------------------------
step "scenario 4: loader gate"
reset_remote
printf 'this is not an executable\n' >"$SB/garbage"
chmod 755 "$SB/garbage"
DEPLOY_PREBUILT="$SB/garbage" run_deploy >"$SB/loader.out" 2>"$SB/loader.err" && fail 'deploy accepted an unexecutable candidate' || true
grep -q 'phase: loader' "$SB/loader.err" || fail 'the loader gate did not name the loader phase'
[ ! -e "$REMOTE_STAGE" ] || fail 'the loader gate committed the stage'
[ ! -f "$REG_FILE" ] || fail 'the loader gate registered the plugin'
[ ! -e "$DEPLOY_LOCK" ] || fail 'the loader gate left a deploy lock'
pass 'an unexecutable candidate fails the loader gate before the commit'

# ---------------------------------------------------------------------------
# 5. Foreign config refusals happen before mutation.
# ---------------------------------------------------------------------------
step "scenario 5: foreign config refusal"
reset_remote
cat >"$REMOTE_CONFIG/config.toml" <<'TOML'
[ui.sidebar.agents]
rows = [["state_icon", "terminal_title_stripped"]]
TOML
BEFORE=$(sha256sum "$REMOTE_CONFIG/config.toml" | awk '{print $1}')
run_deploy >"$SB/foreign.out" 2>"$SB/foreign.err" && fail 'deploy overwrote a foreign sidebar block' || true
grep -q 'foreign \[ui.sidebar.agents\]' "$SB/foreign.err" || fail 'deploy did not explain the foreign sidebar refusal'
[ "$BEFORE" = "$(sha256sum "$REMOTE_CONFIG/config.toml" | awk '{print $1}')" ] || fail 'the foreign refusal modified the config'
[ ! -e "$DEPLOY_LOCK" ] || fail 'the foreign refusal left a deploy lock'

reset_remote
cat >"$REMOTE_CONFIG/config.toml" <<'TOML'
[[keys.command]]
key = "prefix+t"
type = "shell"
command = "echo occupied"
TOML
run_deploy >"$SB/occupied.out" 2>"$SB/occupied.err" && fail 'deploy overwrote an occupied shortcut' || true
grep -q 'bound to another command' "$SB/occupied.err" || fail 'deploy did not explain the occupied shortcut'
pass 'foreign sidebar blocks and a foreign prefix+t shortcut are refused before mutation'

# ---------------------------------------------------------------------------
# 6. Substep commit failure restores `.stage-old` to `stage`.
# ---------------------------------------------------------------------------
step "scenario 6: commit substep failure"
reset_remote
run_deploy >"$SB/substep1.out" 2>"$SB/substep1.err" || { cat "$SB/substep1.err" >&2; fail 'substep setup deploy failed'; }
PRIOR_SHA=$(sha256sum "$REMOTE_STAGE/src/agent-tree" | awk '{print $1}')
PRIOR_SUB=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$LOCK_FILE")
kill -9 "$PRIOR_SUB" 2>/dev/null || true
wait "$PRIOR_SUB" 2>/dev/null || true
rm -f "$LOCK_FILE"
start_subscriber "$REMOTE_STAGE"

DEPLOY_PREBUILT="$BINARY_B" DEPLOY_FAIL_STAGE_NEW=1 run_deploy >"$SB/substep2.out" 2>"$SB/substep2.err" \
    && fail 'the injected stage-new failure did not fail the deploy' || true
grep -q 'phase: commit' "$SB/substep2.err" || fail 'the substep failure did not name the commit phase'
grep -q 'Rollback complete' "$SB/substep2.err" || { cat "$SB/substep2.err" >&2; fail 'the substep failure did not roll back'; }
[ "$(sha256sum "$REMOTE_STAGE/src/agent-tree" | awk '{print $1}')" = "$PRIOR_SHA" ] || fail 'the substep rollback did not restore the previous stage'
[ -z "$(ls -A "$REMOTE_PREFIX" 2>/dev/null | grep -E '^\.stage-(new|old|failed)')" ] || fail 'the substep rollback left a transaction directory'
[ ! -e "$DEPLOY_LOCK" ] || fail 'the substep rollback left the deploy lock'
python3 - "$(probe_path "$REMOTE_STAGE/src/agent-tree")" "$PRIOR_SHA" <<'PY' || fail 'the substep rollback did not preserve the prior subscriber'
import json, sys
probe, sha = json.loads(sys.argv[1]), sys.argv[2]
assert probe["subscriber_count"] == 1, probe
assert probe["subscribers"][0]["sha256"] == sha, probe
PY
pass 'a failure between the two stage moves restores the previous stage and subscriber'

# ---------------------------------------------------------------------------
# 7. Post-commit link failure rolls back stage, registration, config, subscriber.
# ---------------------------------------------------------------------------
step "scenario 7: rollback"
PRIOR_CONFIG=$(sha256sum "$REMOTE_CONFIG/config.toml" | awk '{print $1}')
kill_tree_pids
rm -f "$LOCK_FILE"
PRIOR_SHA=$(sha256sum "$REMOTE_STAGE/src/agent-tree" | awk '{print $1}')
start_subscriber "$REMOTE_STAGE"
DEPLOY_PREBUILT="$BINARY_B" DEPLOY_FAIL_LINK_ONCE=1 run_deploy >"$SB/rollback2.out" 2>"$SB/rollback2.err" \
    && fail 'the injected link failure did not fail the deploy' || true
grep -q 'phase: register' "$SB/rollback2.err" || fail 'the failure did not name the register phase'
grep -q 'Rollback complete' "$SB/rollback2.err" || { cat "$SB/rollback2.err" >&2; fail 'the deploy did not report a completed rollback'; }
[ "$(sha256sum "$REMOTE_STAGE/src/agent-tree" | awk '{print $1}')" = "$PRIOR_SHA" ] || fail 'rollback did not restore the previous staged binary'
[ "$PRIOR_CONFIG" = "$(sha256sum "$REMOTE_CONFIG/config.toml" | awk '{print $1}')" ] || fail 'rollback changed the config'
[ "$(cat "$REG_FILE")" = "$REMOTE_STAGE" ] || fail 'rollback did not restore the registration'
python3 - "$(probe_path "$REMOTE_STAGE/src/agent-tree")" "$PRIOR_SHA" <<'PY' || fail 'rollback did not restore the previous subscriber'
import json, sys
probe, sha = json.loads(sys.argv[1]), sys.argv[2]
assert probe["subscriber_count"] == 1, probe
assert probe["subscribers"][0]["sha256"] == sha, probe
PY
[ ! -e "$DEPLOY_LOCK" ] || fail 'rollback left the deploy lock'
pass 'a post-commit failure rolls back the stage, registration, config and subscriber'

# ---------------------------------------------------------------------------
# 8. Prior registration at the same root but disabled returns disabled after failure.
# ---------------------------------------------------------------------------
step "scenario 8: prior disabled state"
kill_tree_pids
rm -f "$LOCK_FILE" "$ENABLED_FILE"
[ -f "$REG_FILE" ] || fail 'scenario 8 lost the registration'
DEPLOY_FAIL_RELOAD=1 run_deploy >"$SB/disabled.out" 2>"$SB/disabled.err" && fail 'the injected reload failure did not fail the deploy' || true
grep -q 'phase: reload' "$SB/disabled.err" || fail 'the reload failure did not name the reload phase'
grep -q 'Rollback complete' "$SB/disabled.err" || { cat "$SB/disabled.err" >&2; fail 'the disabled-state rollback did not complete'; }
[ ! -f "$ENABLED_FILE" ] || fail 'rollback did not restore the prior disabled state'
[ "$(cat "$REG_FILE")" = "$REMOTE_STAGE" ] || fail 'rollback did not restore the registration root'
[ ! -f "$LOCK_FILE" ] || fail 'rollback left a subscriber lock for a prior disabled install'
[ ! -e "$DEPLOY_LOCK" ] || fail 'rollback left the deploy lock'
pass 'a prior registration at the same root returns disabled after a failed deploy'

# ---------------------------------------------------------------------------
# 9. Prior owned registration at $PREFIX/release rolls back with exact verification.
# ---------------------------------------------------------------------------
step "scenario 9: prior release rollback"
reset_remote
mkdir -p "$REMOTE_RELEASE/src"
cp -- "$BINARY" "$REMOTE_RELEASE/src/agent-tree"
chmod 755 "$REMOTE_RELEASE/src/agent-tree"
RELEASE_SHA=$(sha256sum "$REMOTE_RELEASE/src/agent-tree" | awk '{print $1}')
printf '%s' "$REMOTE_RELEASE" >"$REG_FILE"
: >"$ENABLED_FILE"
rm -f "$LOCK_FILE"
start_subscriber "$REMOTE_RELEASE"
DEPLOY_PREBUILT="$BINARY_B" DEPLOY_FAIL_CONFIG_MV=1 run_deploy >"$SB/release.out" 2>"$SB/release.err" \
    && fail 'the injected config failure did not fail the deploy' || true
grep -q 'phase: config' "$SB/release.err" || { cat "$SB/release.err" >&2; fail 'the config failure did not name the config phase'; }
grep -q 'Rollback complete' "$SB/release.err" || { cat "$SB/release.err" >&2; fail 'the release rollback did not complete'; }
[ "$(cat "$REG_FILE")" = "$REMOTE_RELEASE" ] || fail 'rollback did not restore the release registration'
[ -f "$ENABLED_FILE" ] || fail 'rollback did not restore the release enabled state'
[ ! -e "$REMOTE_STAGE" ] || fail 'rollback left the candidate stage'
[ -z "$(ls -A "$REMOTE_PREFIX" 2>/dev/null | grep -E '^\.stage-(new|old|failed)')" ] || fail 'rollback left a transaction directory'
python3 - "$(probe_path "$REMOTE_RELEASE/src/agent-tree")" "$RELEASE_SHA" <<'PY' || fail 'rollback did not verify the release subscriber'
import json, sys
probe, sha = json.loads(sys.argv[1]), sys.argv[2]
assert probe["subscriber_count"] == 1, probe
assert probe["subscribers"][0]["exe"] == probe["stage"]["path"], probe
assert probe["subscribers"][0]["sha256"] == sha, probe
PY
pass 'a prior owned release registration rolls back and verifies that exact subscriber'
run_deploy >"$SB/release2.out" 2>"$SB/release2.err" || { cat "$SB/release2.err" >&2; fail 'a subsequent deploy after the release rollback failed'; }
[ "$(cat "$REG_FILE")" = "$REMOTE_STAGE" ] || fail 'the subsequent deploy did not register the stage'
python3 - "$(probe_path "$REMOTE_STAGE/src/agent-tree")" <<'PYEOF' || fail 'the subsequent deploy did not run a verified subscriber'
import json, sys
probe = json.loads(sys.argv[1])
assert probe["subscriber_count"] == 1, probe
PYEOF
pass 'a subsequent deploy succeeds after the config-phase rollback'

# ---------------------------------------------------------------------------
# 10. Uninstall identity-verifies and stops the subscriber; foreign holders refuse.
# ---------------------------------------------------------------------------
step "scenario 10: uninstall stop"
reset_remote
run_deploy >"$SB/unin1.out" 2>"$SB/unin1.err" || { cat "$SB/unin1.err" >&2; fail 'uninstall setup deploy failed'; }
SUB_PID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$LOCK_FILE")
if ! run_uninstall >"$SB/unin2.out" 2>"$SB/unin2.err"; then cat "$SB/unin2.out" >&2; cat "$SB/unin2.err" >&2; fail 'uninstall failed'; fi
[ ! -e "/proc/$SUB_PID" ] || fail 'uninstall did not stop the verified subscriber before deleting its stage'
[ ! -e "$LOCK_FILE" ] || fail 'uninstall left the subscriber lock'
[ ! -e "$REMOTE_STAGE" ] || fail 'uninstall left the staged plugin root'
[ ! -f "$REG_FILE" ] || fail 'uninstall left the plugin registered'
[ ! -e "$DEPLOY_LOCK" ] || fail 'uninstall left the deploy lock'
grep -qF '$agent_tree_row' "$REMOTE_CONFIG/config.toml" && fail 'uninstall left the managed sidebar fragment' || true
pass 'uninstall stops the verified subscriber and its lock before deleting the stage'

step "scenario 10b: uninstall foreign subscriber"
reset_remote
run_deploy >"$SB/unin3.out" 2>"$SB/unin3.err" || { cat "$SB/unin3.err" >&2; fail 'foreign setup deploy failed'; }
FOREIGN_DIR=$SB/foreign
mkdir -p "$FOREIGN_DIR/src"
cp -- "$BINARY" "$FOREIGN_DIR/src/agent-tree"
chmod 755 "$FOREIGN_DIR/src/agent-tree"
FOREIGN_STATE=$SB/foreign-state
mkdir -p "$FOREIGN_STATE"
export_fixture_env
env HERDR_PLUGIN_ID=agent-tree HERDR_SOCKET_PATH="$REMOTE_SOCKET" \
    HERDR_PLUGIN_STATE_DIR="$FOREIGN_STATE" "$FOREIGN_DIR/src/agent-tree" subscriber >"$SB/foreign.log" 2>&1 &
FOREIGN_PID=$!
for _ in $(seq 1 100); do [ -f "$FOREIGN_STATE/subscriber-$TAG.lock" ] && break; sleep 0.1; done
if run_uninstall >"$SB/unin4.out" 2>"$SB/unin4.err"; then fail 'uninstall proceeded with a foreign subscriber present'; fi
grep -q 'refusing' "$SB/unin4.err" || fail 'uninstall did not explain the foreign-subscriber refusal'
[ -e "$REMOTE_STAGE" ] || fail 'the foreign refusal deleted the stage'
[ -f "$REG_FILE" ] || fail 'the foreign refusal unregistered the plugin'
kill -9 "$FOREIGN_PID" 2>/dev/null || true
kill_tree_pids
pass 'uninstall refuses without mutation when a foreign subscriber shares the socket'

# ---------------------------------------------------------------------------
# 11. Deployment lock: concurrent attempt refuses; rollback failure releases the lock.
# ---------------------------------------------------------------------------
step "scenario 11: deployment lock"
reset_remote
mkdir -p "$REMOTE_PREFIX" "$DEPLOY_LOCK"
printf 'other:1:0' >"$DEPLOY_LOCK/owner"
run_deploy >"$SB/lock.out" 2>"$SB/lock.err" && fail 'deploy proceeded while the endpoint lock was held' || true
grep -q 'holds the endpoint lock' "$SB/lock.err" || fail 'deploy did not explain the held lock'
[ ! -e "$REMOTE_STAGE" ] || fail 'the held-lock refusal mutated the stage'
[ ! -f "$REG_FILE" ] || fail 'the held-lock refusal registered the plugin'
rm -rf "$DEPLOY_LOCK"

reset_remote
run_deploy >"$SB/rollback3a.out" 2>"$SB/rollback3a.err" || { cat "$SB/rollback3a.err" >&2; fail 'rollback-failure setup deploy failed'; }
kill_tree_pids
rm -f "$LOCK_FILE"
DEPLOY_PREBUILT="$BINARY_B" DEPLOY_FAIL_LINK_ALWAYS=1 run_deploy >"$SB/rollback3.out" 2>"$SB/rollback3.err" \
    && fail 'the always-failing link did not fail the deploy' || true
grep -q 'ROLLBACK FAILED' "$SB/rollback3.err" || { cat "$SB/rollback3.err" >&2; fail 'a failed rollback was not reported'; }
grep -q 'phase: register' "$SB/rollback3.err" || fail 'the failed rollback did not preserve the original phase'
[ ! -e "$DEPLOY_LOCK" ] || fail 'a failed rollback left the deploy lock'
pass 'the endpoint lock refuses concurrent attempts and is released even when rollback fails'

# ---------------------------------------------------------------------------
# 12. argv-safe override path with a space and a single quote.
# ---------------------------------------------------------------------------
step "scenario 12: weird override path"
reset_remote
WEIRD="$REMOTE/data/weird path/o'brien"
run_deploy --prefix "$WEIRD" >"$SB/weird.out" 2>"$SB/weird.err" || { cat "$SB/weird.err" >&2; fail 'deploy with a space and quote prefix failed'; }
[ -x "$WEIRD/stage/src/agent-tree" ] || fail 'the weird prefix stage was not committed'
[ "$(cat "$REG_FILE")" = "$WEIRD/stage" ] || fail 'the weird prefix was not registered exactly'
python3 - "$(python3 "$ROOT/scripts/lib/probe.py" --socket "$REMOTE_SOCKET" --stage "$WEIRD/stage/src/agent-tree" --state-dir "$REMOTE_PLUGIN_STATE")" <<'PY' || fail 'the weird-prefix subscriber was not verified'
import json, sys
probe = json.loads(sys.argv[1])
assert probe["subscriber_count"] == 1, probe
assert probe["stage"]["present"], probe
PY
pass 'an override path with a space and a single quote deploys argv-safely'

# ---------------------------------------------------------------------------
# 13. config.py remove refuses damaged markers.
# ---------------------------------------------------------------------------
step "scenario 13: damaged markers"
DAMAGED=$SB/damaged.toml
cat >"$DAMAGED" <<'TOML'
# >>> agent-tree sidebar rows >>>
[ui.sidebar.agents]
rows = [["state_icon", "$agent_tree_row"]]
TOML
if python3 "$ROOT/scripts/lib/config.py" remove --file "$DAMAGED" --out "$SB/damaged.out" >"$SB/damaged.json" 2>"$SB/damaged.err"; then
    fail 'config.py remove accepted damaged markers'
fi
grep -q 'damaged agent-tree managed fragment' "$SB/damaged.err" || fail 'config.py remove did not explain the damaged markers'
[ ! -e "$SB/damaged.out" ] || fail 'config.py remove wrote an output around damaged markers'
pass 'config.py remove refuses damaged managed markers instead of uninstalling around them'

# ---------------------------------------------------------------------------
# 14. A concurrent config edit is detected and never overwritten.
# ---------------------------------------------------------------------------
step "scenario 14: concurrent config edit"
reset_remote
DEPLOY_CONCURRENT_CONFIG_EDIT=1 run_deploy >"$SB/concurrent.out" 2>"$SB/concurrent.err" \
    && fail 'deploy overwrote a concurrent config edit' || true
grep -q 'changed after preflight' "$SB/concurrent.err" || { cat "$SB/concurrent.err" >&2; fail 'the concurrent edit was not detected'; }
grep -qF 'concurrent edit' "$REMOTE_CONFIG/config.toml" || fail 'rollback overwrote the concurrent edit'
grep -q 'Rollback complete' "$SB/concurrent.err" || fail 'the concurrent-edit failure did not roll back'
[ ! -e "$REMOTE_STAGE" ] || fail 'the concurrent-edit rollback left the candidate stage'
[ ! -e "$DEPLOY_LOCK" ] || fail 'the concurrent-edit rollback left the deploy lock'
pass 'a concurrent config edit is detected and rolled back without being overwritten'

# ---------------------------------------------------------------------------
# 15. A symlinked config path is refused before any mutation.
# ---------------------------------------------------------------------------
step "scenario 15: symlinked config"
reset_remote
rm -f "$REMOTE_CONFIG/config.toml"
: >"$SB/target-config.toml"
ln -s "$SB/target-config.toml" "$REMOTE_CONFIG/config.toml"
if run_deploy >"$SB/symlink.out" 2>"$SB/symlink.err"; then fail 'deploy proceeded with a symlinked config'; fi
grep -q 'symlink' "$SB/symlink.err" || fail 'deploy did not explain the symlink refusal'
[ -L "$REMOTE_CONFIG/config.toml" ] || fail 'the refusal replaced the symlink'
[ ! -e "$REMOTE_STAGE" ] || fail 'the symlink refusal mutated the stage'
[ ! -e "$DEPLOY_LOCK" ] || fail 'the symlink refusal left a deploy lock'
pass 'a symlinked config path is refused before any mutation'

step "scenario 17: profile id routing"
grep -qx 'a5bbdad2c6a2ed308515f090ec24947a' "$SB/profiles.log" || fail 'no forwarded call used the saved profile id'
if grep -qx 'cart-lab' "$SB/profiles.log"; then fail 'a forwarded call used the mutable label'; fi
pass 'every forwarded Herdr call used the unique saved profile id'


# ---------------------------------------------------------------------------
# 18. stop.py identity helper: a matching starttime holds, a stale one does not.
# ---------------------------------------------------------------------------
step "scenario 18: stop identity recheck"
reset_remote
run_deploy >"$SB/ident1.out" 2>"$SB/ident1.err" || { cat "$SB/ident1.err" >&2; fail 'identity setup deploy failed'; }
IDENT_PID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$LOCK_FILE")
IDENT_START=$(python3 -c 'import sys
raw = open("/proc/%s/stat" % sys.argv[1]).read(); i = raw.rfind(")"); print(raw[i + 2:].split()[19])' "$IDENT_PID")
if ! python3 "$ROOT/scripts/lib/stop.py" --check-identity "$IDENT_PID" "$IDENT_START" \
        --socket "$REMOTE_SOCKET" --state-dir "$REMOTE_PLUGIN_STATE" --root "$REMOTE_STAGE" --prefix "$REMOTE_PREFIX" >/dev/null; then
    fail 'the identity helper rejected a live subscriber with its own starttime'
fi
if python3 "$ROOT/scripts/lib/stop.py" --check-identity "$IDENT_PID" "$((IDENT_START + 1))" \
        --socket "$REMOTE_SOCKET" --state-dir "$REMOTE_PLUGIN_STATE" --root "$REMOTE_STAGE" --prefix "$REMOTE_PREFIX" >/dev/null; then
    fail 'the identity helper accepted a reused-pid starttime'
fi
kill -0 "$IDENT_PID" 2>/dev/null || fail 'the identity check signaled the live subscriber'
pass 'the stop identity helper holds only for the exact live process starttime'

# ---------------------------------------------------------------------------
# 19. Uninstall failure injections roll the whole uninstall back.
# ---------------------------------------------------------------------------
step "scenario 19: uninstall rollback injections"
for injection in after-stop after-unlink config-commit; do
    reset_remote
    run_deploy >"$SB/unroll1.out" 2>"$SB/unroll1.err" || { cat "$SB/unroll1.err" >&2; fail "uninstall $injection setup deploy failed"; }
    UN_SHA=$(sha256sum "$REMOTE_STAGE/src/agent-tree" | awk '{print $1}')
    UN_CONFIG=$(sha256sum "$REMOTE_CONFIG/config.toml" | awk '{print $1}')
    UN_PID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$LOCK_FILE")
    case "$injection" in
        after-stop)   failed=0; DEPLOY_FAIL_UNINSTALL_CLEAR=1 run_uninstall >"$SB/unroll.out" 2>"$SB/unroll.err" || failed=1 ;;
        after-unlink) failed=0; DEPLOY_FAIL_UNINSTALL_RELOAD_CONFIG=1 run_uninstall >"$SB/unroll.out" 2>"$SB/unroll.err" || failed=1 ;;
        config-commit) failed=0; DEPLOY_FAIL_CONFIG_MV=1 run_uninstall >"$SB/unroll.out" 2>"$SB/unroll.err" || failed=1 ;;
    esac
    [ "$failed" = 1 ] || fail "the $injection injection did not fail the uninstall"
    grep -q 'Rollback complete' "$SB/unroll.err" || { cat "$SB/unroll.err" >&2; fail "the $injection uninstall did not roll back"; }
    [ "$(cat "$REG_FILE")" = "$REMOTE_STAGE" ] || fail "$injection rollback did not restore the registration"
    [ -f "$ENABLED_FILE" ] || fail "$injection rollback did not restore the enabled state"
    [ "$UN_CONFIG" = "$(sha256sum "$REMOTE_CONFIG/config.toml" | awk '{print $1}')" ] || fail "$injection rollback did not restore the config"
    [ "$UN_SHA" = "$(sha256sum "$REMOTE_STAGE/src/agent-tree" | awk '{print $1}')" ] || fail "$injection rollback did not restore the stage"
    [ -z "$(ls -A "$REMOTE_PREFIX" 2>/dev/null | grep '^.stage-uninstall')" ] || fail "$injection rollback left a stage transaction directory"
    [ ! -e "$DEPLOY_LOCK" ] || fail "$injection rollback left the deploy lock"
    python3 - "$(probe_path "$REMOTE_STAGE/src/agent-tree")" "$UN_SHA" <<'PY' || fail "$injection rollback did not restore the subscriber"
import json, sys
probe, sha = json.loads(sys.argv[1]), sys.argv[2]
assert probe["subscriber_count"] == 1, probe
assert probe["subscribers"][0]["sha256"] == sha, probe
PY
done
pass 'uninstall failures after stop, after unlink and during the config commit all roll back'

# ---------------------------------------------------------------------------
# 20. A damaged config marker refuses uninstall with everything still live.
# ---------------------------------------------------------------------------
step "scenario 20: damaged marker uninstall refusal"
reset_remote
run_deploy >"$SB/dmg1.out" 2>"$SB/dmg1.err" || { cat "$SB/dmg1.err" >&2; fail 'damaged setup deploy failed'; }
DMG_PID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$LOCK_FILE")
DMG_CONFIG=$(sha256sum "$REMOTE_CONFIG/config.toml" | awk '{print $1}')
grep -v -F '# <<< agent-tree sidebar rows <<<' "$REMOTE_CONFIG/config.toml" > "$SB/damaged-remote.toml"
mv "$SB/damaged-remote.toml" "$REMOTE_CONFIG/config.toml"
DMG_BROKEN=$(sha256sum "$REMOTE_CONFIG/config.toml" | awk '{print $1}')
if run_uninstall >"$SB/dmg2.out" 2>"$SB/dmg2.err"; then fail 'uninstall accepted a damaged config marker'; fi
grep -q 'damaged agent-tree markers' "$SB/dmg2.err" || { cat "$SB/dmg2.err" >&2; fail 'uninstall did not explain the damaged marker refusal'; }
kill -0 "$DMG_PID" 2>/dev/null || fail 'the damaged-marker refusal stopped the live subscriber'
[ -f "$REG_FILE" ] || fail 'the damaged-marker refusal unregistered the plugin'
[ -e "$REMOTE_STAGE" ] || fail 'the damaged-marker refusal removed the stage'
[ "$DMG_BROKEN" = "$(sha256sum "$REMOTE_CONFIG/config.toml" | awk '{print $1}')" ] || fail 'the damaged-marker refusal changed the config'
[ ! -e "$DEPLOY_LOCK" ] || fail 'the damaged-marker refusal left the deploy lock'
pass 'a damaged config marker refuses uninstall and leaves the subscriber, registration, config and stage live'

# ---------------------------------------------------------------------------
# 21. release_lock never removes a lock recreated by another owner.
# ---------------------------------------------------------------------------
step "scenario 21: lock owner token"
reset_remote
run_deploy >"$SB/steal0.out" 2>"$SB/steal0.err" || { cat "$SB/steal0.err" >&2; fail 'lock-steal setup deploy failed'; }
kill_tree_pids
rm -f "$LOCK_FILE"
DEPLOY_STEAL_LOCK=1 DEPLOY_FAIL_LINK_ALWAYS=1 run_deploy >"$SB/steal.out" 2>"$SB/steal.err" \
    && fail 'the always-failing link did not fail the lock-steal deploy' || true
grep -q 'ROLLBACK FAILED\|Rollback complete' "$SB/steal.err" || fail 'the lock-steal deploy did not finish its rollback path'
[ -e "$DEPLOY_LOCK" ] || fail 'release_lock removed a lock whose owner token no longer matched'
rm -rf "$DEPLOY_LOCK"
pass 'release_lock leaves a lock that another owner recreated'

# ---------------------------------------------------------------------------
# 22. Absolute herdr shortcut with spaces and a single quote, parsed with tomllib.
# ---------------------------------------------------------------------------
step "scenario 22: weird herdr path shortcut"
reset_remote
WEIRD_BIN="$SB/herdr bin/o'brien"
mkdir -p "$WEIRD_BIN"
cp -- "$BIN/herdr" "$WEIRD_BIN/herdr"
DEPLOY_FAKE_BIN="$WEIRD_BIN:$BIN" run_deploy >"$SB/weirdherdr.out" 2>"$SB/weirdherdr.err" \
    || { cat "$SB/weirdherdr.err" >&2; fail 'deploy with a weird herdr path failed'; }
python3 - "$REMOTE_CONFIG/config.toml" "$WEIRD_BIN/herdr" <<'PY' || fail 'the weird-herdr shortcut is not valid TOML or wrong'
import shlex, sys, tomllib
with open(sys.argv[1], "rb") as handle:
    data = tomllib.load(handle)
commands = data["keys"]["command"]
assert len(commands) == 1, commands
command = commands[0]["command"]
argv = shlex.split(command)
assert argv == [sys.argv[2], "plugin", "action", "invoke", "agent-tree.toggle"], argv
PY
grep -qF 'agent-tree.toggle' "$REMOTE_CONFIG/config.toml" || fail 'the weird-herdr shortcut lost the toggle command'
pass 'a herdr path with a space and a single quote yields a valid TOML shortcut'

# ---------------------------------------------------------------------------
# 23. Uninstall re-reads the config before its commit and never overwrites a
#     concurrent edit; the injected user bytes survive rollback byte-for-byte.
# ---------------------------------------------------------------------------
step "scenario 23: uninstall concurrent config edit"
reset_remote
run_deploy >"$SB/uncon1.out" 2>"$SB/uncon1.err" || { cat "$SB/uncon1.err" >&2; fail 'concurrent-edit uninstall setup deploy failed'; }
UN_CON_SHA=$(sha256sum "$REMOTE_STAGE/src/agent-tree" | awk '{print $1}')
cp -- "$REMOTE_CONFIG/config.toml" "$SB/uncon-before.toml"
printf '\n# concurrent uninstall edit\n' >"$SB/uncon-suffix.toml"
cat "$SB/uncon-before.toml" "$SB/uncon-suffix.toml" >"$SB/uncon-expected.toml"
DEPLOY_UNINSTALL_CONCURRENT_CONFIG_EDIT=1 run_uninstall >"$SB/uncon2.out" 2>"$SB/uncon2.err" \
    && fail 'uninstall overwrote a concurrent config edit' || true
grep -q 'Done\. Re-deploy' "$SB/uncon2.out" && fail 'uninstall reported success despite the concurrent edit' || true
grep -q 'changed after preflight' "$SB/uncon2.err" || { cat "$SB/uncon2.err" >&2; fail 'uninstall did not detect the concurrent edit'; }
grep -q 'Rollback complete' "$SB/uncon2.err" || { cat "$SB/uncon2.err" >&2; fail 'uninstall did not roll back after the concurrent edit'; }
cmp -s "$SB/uncon-expected.toml" "$REMOTE_CONFIG/config.toml" \
    || { diff -u "$SB/uncon-expected.toml" "$REMOTE_CONFIG/config.toml" >&2 || true; fail 'rollback did not preserve the concurrent edit byte-for-byte'; }
[ "$(cat "$REG_FILE")" = "$REMOTE_STAGE" ] || fail 'the concurrent-edit rollback did not restore the registration'
[ -f "$ENABLED_FILE" ] || fail 'the concurrent-edit rollback did not restore the enabled state'
[ "$UN_CON_SHA" = "$(sha256sum "$REMOTE_STAGE/src/agent-tree" | awk '{print $1}')" ] || fail 'the concurrent-edit rollback did not restore the stage'
[ -z "$(ls -A "$REMOTE_PREFIX" 2>/dev/null | grep '^.stage-uninstall')" ] || fail 'the concurrent-edit rollback left a stage transaction directory'
[ ! -e "$DEPLOY_LOCK" ] || fail 'the concurrent-edit rollback left the deploy lock'
python3 - "$(probe_path "$REMOTE_STAGE/src/agent-tree")" "$UN_CON_SHA" <<'PY' || fail 'the concurrent-edit rollback did not restore the subscriber'
import json, sys
probe, sha = json.loads(sys.argv[1]), sys.argv[2]
assert probe["subscriber_count"] == 1, probe
assert probe["subscribers"][0]["sha256"] == sha, probe
PY
pass 'uninstall refuses a concurrent config edit, preserves the user bytes exactly and restores the prior install'

# ---------------------------------------------------------------------------
# 24. Stage deletion failures are hard transactional failures: no false
#     success, and the moved stage/registration/config/subscriber are restored.
# ---------------------------------------------------------------------------
step "scenario 24: uninstall stage deletion failures"
for injection in cleanup txn-remove; do
    reset_remote
    run_deploy >"$SB/stagedel1.out" 2>"$SB/stagedel1.err" || { cat "$SB/stagedel1.err" >&2; fail "stage-deletion $injection setup deploy failed"; }
    SD_SHA=$(sha256sum "$REMOTE_STAGE/src/agent-tree" | awk '{print $1}')
    SD_CONFIG=$(sha256sum "$REMOTE_CONFIG/config.toml" | awk '{print $1}')
    case "$injection" in
        cleanup)
            mkdir -p "$REMOTE_PREFIX/.stage-old.12345"
            failed=0; DEPLOY_FAIL_STAGE_CLEANUP=1 run_uninstall >"$SB/stagedel.out" 2>"$SB/stagedel.err" || failed=1
            ;;
        txn-remove)
            failed=0; DEPLOY_FAIL_UNINSTALL_STAGE_RM=1 run_uninstall >"$SB/stagedel.out" 2>"$SB/stagedel.err" || failed=1
            ;;
    esac
    [ "$failed" = 1 ] || fail "the $injection stage-deletion failure did not fail the uninstall"
    grep -q 'phase: uninstall' "$SB/stagedel.err" || { cat "$SB/stagedel.err" >&2; fail "the $injection failure did not name the uninstall phase"; }
    grep -q 'Done\. Re-deploy' "$SB/stagedel.out" && fail "the $injection failure falsely reported success" || true
    grep -q 'Rollback complete' "$SB/stagedel.err" || { cat "$SB/stagedel.err" >&2; fail "the $injection failure did not roll back"; }
    [ "$(cat "$REG_FILE")" = "$REMOTE_STAGE" ] || fail "$injection rollback did not restore the registration"
    [ -f "$ENABLED_FILE" ] || fail "$injection rollback did not restore the enabled state"
    [ "$SD_CONFIG" = "$(sha256sum "$REMOTE_CONFIG/config.toml" | awk '{print $1}')" ] || fail "$injection rollback did not restore the config"
    [ "$SD_SHA" = "$(sha256sum "$REMOTE_STAGE/src/agent-tree" | awk '{print $1}')" ] || fail "$injection rollback did not restore the stage"
    [ -z "$(ls -A "$REMOTE_PREFIX" 2>/dev/null | grep '^.stage-uninstall')" ] || fail "$injection rollback left a stage transaction directory"
    [ ! -e "$DEPLOY_LOCK" ] || fail "$injection rollback left the deploy lock"
    python3 - "$(probe_path "$REMOTE_STAGE/src/agent-tree")" "$SD_SHA" <<'PY' || fail "$injection rollback did not restore the subscriber"
import json, sys
probe, sha = json.loads(sys.argv[1]), sys.argv[2]
assert probe["subscriber_count"] == 1, probe
assert probe["subscribers"][0]["sha256"] == sha, probe
PY
done
pass 'uninstall stage deletion failures are hard failures that restore the prior stage/subscriber/config/registration'

printf '1..%d\n' "$PASS"
