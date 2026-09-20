#!/bin/sh
# Hermetic latest-checkout deploy/reload acceptance tests for task-6.
#
# Nothing here touches the live Herdr socket, config or installed plugin. A fake `herdr`
# resolves `plugin action invoke agent-tree.reload` to the real staged binary, a fake
# `cargo` supplies a prebuilt binary quickly, and a tiny Python server speaks just enough
# of the socket protocol for real subscriber processes to connect, hold the lock and be
# replaced. The scenarios cover first install, repeated reload, stale-lock recovery,
# foreign-holder refusal, user-owned config preservation and cleanup.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
REAL_CARGO=$(command -v cargo 2>/dev/null || true)
[ -n "$REAL_CARGO" ] || { echo 'dev-reload: cargo is required' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo 'dev-reload: python3 is required' >&2; exit 1; }
for tool in sha256sum stat awk sed grep mktemp readlink; do
    command -v "$tool" >/dev/null 2>&1 || { echo "dev-reload: $tool is required" >&2; exit 1; }
done

# Never inherit a live Herdr identity; this test only talks to its own fake server.
unset HERDR_SOCKET_PATH HERDR_PLUGIN_STATE_DIR HERDR_PLUGIN_ID HERDR_PLUGIN_ROOT \
      HERDR_PLUGIN_CONFIG_DIR HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID \
      HERDR_BIN_PATH HERDR_ENV HERDR_INTEGRATION_ID 2>/dev/null || true

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/agent-tree-dev-reload.XXXXXX")
STATE=$SANDBOX/state
CONFIG=$SANDBOX/config
HOME_DIR=$SANDBOX/home
BIN_DIR=$SANDBOX/bin
HERDR_DIR=$SANDBOX/herdr
DATA=$SANDBOX/data
STAGE=$DATA/herdr-agent-tree/stage
SOCKET=$CONFIG/herdr/herdr.sock
mkdir -p "$STATE" "$CONFIG/herdr" "$HOME_DIR" "$BIN_DIR" "$HERDR_DIR" "$DATA" "$HERDR_DIR/logs"

PASS=0
pass() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

server_tag() { printf '%s' "$1" | sha256sum | awk '{ print substr($1, 1, 16) }'; }
lock_path() { printf '%s/subscriber-%s.lock\n' "$STATE" "$(server_tag "$1")"; }
lock_pid() { sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1" | head -1; }
count_locks() { set -- "$STATE"/subscriber-*.lock; if [ -e "$1" ]; then printf '%s\n' "$#"; else printf '0\n'; fi; }
wait_dead() { pid=$1; i=0; while kill -0 "$pid" 2>/dev/null; do i=$((i + 1)); [ "$i" -lt 200 ] || return 1; sleep 0.1; done; }
staged_subscribers() {
    count=0
    for proc in /proc/[0-9]*; do
        pid=${proc#/proc/}
        exe=$(readlink "$proc/exe" 2>/dev/null || true)
        exe=${exe% (deleted)}
        [ "$exe" = "$STAGE/src/agent-tree" ] && count=$((count + 1))
    done
    printf '%s\n' "$count"
}

cleanup() {
    if [ -n "${STATE:-}" ] && [ -d "$STATE" ]; then
        for lock in "$STATE"/subscriber-*.lock; do
            [ -f "$lock" ] || continue
            pid=$(lock_pid "$lock" 2>/dev/null || true)
            [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
        done
    fi
    [ -f "$SANDBOX/server.pid" ] && kill "$(cat "$SANDBOX/server.pid")" 2>/dev/null || true
    [ -n "${FOREIGN:-}" ] && kill "$FOREIGN" 2>/dev/null || true
    # Leave no fake release artifact behind: the next real cargo build restores the cached
    # optimized binary instead of treating the debug copy as fresh.
    rm -f -- "$ROOT/target/release/agent-tree"
    rm -rf -- "$SANDBOX"
}
trap cleanup EXIT HUP INT TERM

# ---------------------------------------------------------------------------
# Fixtures: prebuilt binary, fake cargo, fake herdr and the minimal socket server.
# ---------------------------------------------------------------------------
PREBUILT=$ROOT/target/debug/agent-tree
"$REAL_CARGO" build --locked --bins --manifest-path "$ROOT/Cargo.toml" >/dev/null 2>&1 \
    || fail 'debug build failed'
[ -x "$PREBUILT" ] || fail "debug build did not produce $PREBUILT"

cat >"$BIN_DIR/cargo" <<'SH'
#!/bin/sh
set -eu
dest=$FAKE_PLUGIN/target/release
mkdir -p "$dest"
# Replace via rename so this never writes through the hardlink cargo keeps between
# target/release/agent-tree and its deps artifact (which would corrupt the cached real
# release binary and let `just deploy` ship the debug build).
cp "$FAKE_PREBUILT" "$dest/agent-tree.new"
mv -f "$dest/agent-tree.new" "$dest/agent-tree"
chmod 755 "$dest/agent-tree"
SH
chmod 755 "$BIN_DIR/cargo"

cat >"$BIN_DIR/herdr" <<'SH'
#!/bin/sh
set -eu
# A fake Herdr that models the one behaviour this suite depends on: `plugin action invoke`
# starts the manifest command and returns immediately with a running log record, and its real
# outcome only appears later in `plugin log list`. A deploy that treats the invoke exit as
# completion is therefore caught instead of passing by timing luck.
dir=$FAKE_HERDR_DIR
stage_file=$dir/stage
logs=$dir/logs
seq_file=$dir/logseq
command=${1:-}
shift || true
case $command in
    status) exit 0 ;;
    server) exit 0 ;;
    plugin)
        sub=${1:-}
        shift || true
        case $sub in
            list)
                if [ -f "$stage_file" ]; then
                    root=$(cat "$stage_file")
                    printf 'agent-tree (local:%s) [local:%s]\n' "$root" "$root"
                fi
                ;;
            link) printf '%s\n' "$1" >"$stage_file" ;;
            unlink) rm -f "$stage_file" ;;
            disable) ;;
            action)
                action=${2#agent-tree.}
                root=$(cat "$stage_file")
                n=0
                if [ -f "$seq_file" ]; then n=$(cat "$seq_file"); fi
                n=$((n + 1))
                printf '%s\n' "$n" >"$seq_file"
                log_id=plugin-log-$n
                mkdir -p "$logs"
                record=$logs/$log_id.json
                printf '{"log_id":"%s","plugin_id":"agent-tree","action_id":"%s","status":"running"}\n' \
                    "$log_id" "$action" >"$record"
                (
                    delay=${FAKE_HERDR_ACTION_DELAY:-0}
                    [ "$delay" = 0 ] || sleep "$delay"
                    out=$dir/$log_id.out
                    err=$dir/$log_id.err
                    rc=0
                    env HERDR_PLUGIN_ID=agent-tree \
                        HERDR_PLUGIN_ROOT="$root" \
                        HERDR_PLUGIN_STATE_DIR="$FAKE_HERDR_STATE_DIR" \
                        HERDR_SOCKET_PATH="$FAKE_HERDR_SOCKET" \
                        "$root/src/agent-tree" "$action" >"$out" 2>"$err" || rc=$?
                    python3 - "$record" "$rc" "$out" "$err" <<'PY'
import json, os, sys
record, rc, out, err = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
with open(record) as handle:
    data = json.load(handle)
data["status"] = "succeeded" if rc == 0 else "failed"
data["exit_code"] = rc
data["stdout"] = open(out).read()
data["stderr"] = open(err).read()
tmp = record + ".tmp"
with open(tmp, "w") as handle:
    json.dump(data, handle)
os.replace(tmp, record)
PY
                ) >/dev/null 2>&1 </dev/null &
                printf '{"id":"cli:plugin","result":{"log":{"log_id":"%s","plugin_id":"agent-tree","status":"running"},"type":"plugin_action_invoked"}}\n' "$log_id"
                ;;
            log)
                sub2=${1:-}
                shift || true
                case $sub2 in
                    list)
                        python3 - "$logs" <<'PY'
import glob, json, os, sys
records = []
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.json"))):
    try:
        with open(path) as handle:
            records.append(json.load(handle))
    except Exception:
        pass
print(json.dumps({"id": "cli:plugin", "result": {"logs": records, "type": "plugin_log_list"}}))
PY
                        ;;
                esac
                ;;
        esac
        ;;
esac
exit 0
SH
chmod 755 "$BIN_DIR/herdr"

cat >"$SANDBOX/server.py" <<'PY'
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
            self.wfile.write(
                (json.dumps({"id": request.get("id"), "result": result}) + "\n").encode()
            )
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
python3 "$SANDBOX/server.py" "$SOCKET" &
echo $! >"$SANDBOX/server.pid"
i=0
while [ ! -S "$SOCKET" ]; do
    i=$((i + 1))
    [ "$i" -lt 100 ] || fail "the fake socket server did not create $SOCKET"
    sleep 0.1
done

# A minimal config; deploy appends its own managed rows block.
printf '[ui]\nsidebar_width = 32\n' >"$CONFIG/herdr/config.toml"

run_deploy() {
    config=$1
    shift
    (
        cd "$ROOT"
        printf 'y\n' | env \
            HOME="$HOME_DIR" \
            XDG_CONFIG_HOME="$config" \
            XDG_DATA_HOME="$DATA" \
            XDG_STATE_HOME="$SANDBOX/xdg-state" \
            HERDR_SOCKET_PATH="$SOCKET" \
            HERDR_BIN_PATH= \
            PATH="$BIN_DIR:$PATH" \
            FAKE_PLUGIN="$ROOT" \
            FAKE_PREBUILT="$PREBUILT" \
            FAKE_HERDR_DIR="$HERDR_DIR" \
            FAKE_HERDR_STATE_DIR="$STATE" \
            FAKE_HERDR_SOCKET="$SOCKET" \
            FAKE_HERDR_ACTION_DELAY="${FAKE_HERDR_ACTION_DELAY:-1}" \
            ./scripts/deploy.sh "$@"
    )
}

assert_staged_exe() {
    pid=$1
    got=$(readlink "/proc/$pid/exe")
    got=${got% (deleted)}
    [ "$got" = "$STAGE/src/agent-tree" ] \
        || fail "subscriber pid $pid runs $got, expected $STAGE/src/agent-tree"
}

# ---------------------------------------------------------------------------
# 1. First install: one subscriber owning the lock from the staged build.
#    The fake herdr starts the action asynchronously (1s default delay), so every
#    assertion below holds only because deploy waits for the action's terminal log record
#    and verifies the running image before it returns.
# ---------------------------------------------------------------------------
printf '== first install\n'
run_deploy "$CONFIG" >"$SANDBOX/out1" 2>"$SANDBOX/err1" \
    || { cat "$SANDBOX/err1" >&2; fail 'first deploy failed'; }
LOCK=$(lock_path "$SOCKET")
[ -f "$LOCK" ] || fail 'first deploy left no subscriber lock'
PID1=$(lock_pid "$LOCK")
[ -n "$PID1" ] || fail 'first deploy wrote an unreadable lock'
kill -0 "$PID1" 2>/dev/null || fail "subscriber pid $PID1 is not alive"
assert_staged_exe "$PID1"
[ "$(count_locks)" = 1 ] || fail "expected exactly one lock, found $(count_locks)"
[ "$(staged_subscribers)" = 1 ] || fail "expected exactly one staged subscriber, found $(staged_subscribers)"
grep -q 'subscriber replaced' "$SANDBOX/out1" || fail 'deploy did not report the subscriber replacement'
grep -q 'verified (pid' "$SANDBOX/out1" || fail 'deploy did not verify the staged subscriber hash before returning'
pass 'first deploy starts exactly one subscriber from the staged build'

# ---------------------------------------------------------------------------
# 2. Repeated deploy: the live subscriber is replaced safely. The action is delayed, so a
#    deploy that returned on the async invoke instead of its terminal log would still show
#    the old pid here and fail.
# ---------------------------------------------------------------------------
printf '== repeated deploy\n'
run_deploy "$CONFIG" >"$SANDBOX/out2" 2>"$SANDBOX/err2" \
    || { cat "$SANDBOX/err2" >&2; fail 'repeated deploy failed'; }
PID2=$(lock_pid "$LOCK")
[ -n "$PID2" ] || fail 'repeated deploy lost the lock'
[ "$PID2" != "$PID1" ] || fail 'repeated deploy did not replace the subscriber'
wait_dead "$PID1" || fail "old subscriber $PID1 is still alive"
kill -0 "$PID2" 2>/dev/null || fail "replacement subscriber $PID2 is not alive"
assert_staged_exe "$PID2"
[ "$(count_locks)" = 1 ] || fail "repeated deploy left $(count_locks) locks"
[ "$(staged_subscribers)" = 1 ] || fail 'repeated deploy did not leave exactly one staged subscriber'
pass 'repeated deploy replaces the live subscriber with the new staged build'

# ---------------------------------------------------------------------------
# 3. Stale lock: SIGKILL leaves the lock behind and the next deploy recovers it.
# ---------------------------------------------------------------------------
printf '== stale lock\n'
kill -9 "$PID2" 2>/dev/null || true
wait_dead "$PID2" || fail "could not stop subscriber $PID2 for the stale-lock test"
[ -f "$LOCK" ] || fail 'SIGKILL did not leave the stale lock to recover'
run_deploy "$CONFIG" >"$SANDBOX/out3" 2>"$SANDBOX/err3" \
    || { cat "$SANDBOX/err3" >&2; fail 'stale-lock deploy failed'; }
PID3=$(lock_pid "$LOCK")
[ -n "$PID3" ] || fail 'stale-lock recovery wrote no lock'
[ "$PID3" != "$PID2" ] || fail 'stale-lock recovery reused the dead pid'
kill -0 "$PID3" 2>/dev/null || fail "recovered subscriber $PID3 is not alive"
assert_staged_exe "$PID3"
[ "$(count_locks)" = 1 ] || fail 'stale-lock recovery left multiple locks'
pass 'a dead subscriber lock is recovered by the next deploy'

# ---------------------------------------------------------------------------
# 4. Cleanup: only the freshly recovered staged subscriber remains.
# ---------------------------------------------------------------------------
printf '== cleanup\n'
[ "$(staged_subscribers)" = 1 ] || fail "expected exactly one staged subscriber, found $(staged_subscribers)"
[ "$(count_locks)" = 1 ] || fail "expected exactly one lock after recovery, found $(count_locks)"
pass 'replaced subscribers exit and release their locks'

# ---------------------------------------------------------------------------
# 5. User-owned sidebar config: preserved byte-for-byte, exact fragment printed.
# ---------------------------------------------------------------------------
printf '== user-owned sidebar config\n'
USER_CONFIG_DIR=$SANDBOX/user-config
mkdir -p "$USER_CONFIG_DIR/herdr"
USER_CONFIG=$USER_CONFIG_DIR/herdr/config.toml
cat >"$USER_CONFIG" <<'TOML'
[ui]
sidebar_width = 28

[ui.sidebar.agents]
rows = [["state_icon", "terminal_title_stripped"]]
TOML
BEFORE=$(sha256sum "$USER_CONFIG" | awk '{ print $1 }')
run_deploy "$USER_CONFIG_DIR" >"$SANDBOX/out5" 2>"$SANDBOX/err5" \
    || { cat "$SANDBOX/err5" >&2; fail 'deploy with a user-owned config failed'; }
AFTER=$(sha256sum "$USER_CONFIG" | awk '{ print $1 }')
[ "$BEFORE" = "$AFTER" ] || fail 'deploy modified a user-owned [ui.sidebar.agents] block'
grep -qF 'rows = [["state_icon", "$agent_tree_row", "terminal_title_stripped"]]' "$SANDBOX/out5" \
    || fail 'deploy did not print the exact rows fragment for a block missing $agent_tree_row'
if grep -qF '$agent_tree_row' "$USER_CONFIG"; then
    fail 'deploy wrote into the user-owned block'
fi
pass 'a user-owned sidebar block is preserved and the missing fragment is printed'

# 5b. A user-owned block that already references $agent_tree_row needs no fragment.
USER_CONFIG_DIR2=$SANDBOX/user-config-ok
mkdir -p "$USER_CONFIG_DIR2/herdr"
USER_CONFIG2=$USER_CONFIG_DIR2/herdr/config.toml
cat >"$USER_CONFIG2" <<'TOML'
[ui.sidebar.agents]
rows = [["state_icon", "$agent_tree_row"]]
TOML
BEFORE2=$(sha256sum "$USER_CONFIG2" | awk '{ print $1 }')
run_deploy "$USER_CONFIG_DIR2" >"$SANDBOX/out5b" 2>"$SANDBOX/err5b" \
    || { cat "$SANDBOX/err5b" >&2; fail 'deploy with a complete user config failed'; }
AFTER2=$(sha256sum "$USER_CONFIG2" | awk '{ print $1 }')
[ "$BEFORE2" = "$AFTER2" ] || fail 'deploy modified a complete user-owned block'
grep -qF 'already references $agent_tree_row' "$SANDBOX/out5b" \
    || fail 'deploy did not recognize the user block as already complete'
pass 'a user-owned block with $agent_tree_row is left alone'

# ---------------------------------------------------------------------------
# 6. A same-user holder that spoofs the plugin environment is still foreign: the values
#    it reports can never widen the executable trust set, so it is refused and not signaled.
# ---------------------------------------------------------------------------
printf '== spoofed-environment holder\n'
kill -9 "$PID3" 2>/dev/null || true
wait_dead "$PID3" || fail "could not stop subscriber $PID3 before the spoofed test"
rm -f "$LOCK"
env HERDR_PLUGIN_ID=agent-tree \
    HERDR_SOCKET_PATH="$SOCKET" \
    HERDR_PLUGIN_STATE_DIR="$STATE" \
    HERDR_PLUGIN_ROOT=/tmp/attacker-root \
    sleep 300 &
FOREIGN=$!
printf '{"pid":%s,"socket_path":"%s","started_unix_ms":0}\n' "$FOREIGN" "$SOCKET" >"$LOCK"
if run_deploy "$CONFIG" >"$SANDBOX/out6" 2>"$SANDBOX/err6"; then
    fail 'deploy accepted a spoofed-environment foreign holder'
fi
kill -0 "$FOREIGN" 2>/dev/null || fail 'deploy signaled a spoofed-environment holder'
[ -f "$LOCK" ] || fail 'deploy removed the spoofed holder lock'
grep -q 'refusing' "$SANDBOX/err6" || fail 'deploy did not explain the spoofed-env refusal'
grep -q 'phase: reload action' "$SANDBOX/err6" || fail 'deploy did not name the failed phase (reload action)'
pass 'a same-user holder with spoofed plugin env is refused and never signaled'
kill "$FOREIGN" 2>/dev/null || true
wait_dead "$FOREIGN" 2>/dev/null || true
FOREIGN=

# ---------------------------------------------------------------------------
# 6b. A holder with no plugin environment at all is refused the same way.
# ---------------------------------------------------------------------------
printf '== foreign holder refusal\n'
rm -f "$LOCK"
sleep 300 &
FOREIGN=$!
printf '{"pid":%s,"socket_path":"%s","started_unix_ms":0}\n' "$FOREIGN" "$SOCKET" >"$LOCK"
if run_deploy "$CONFIG" >"$SANDBOX/out7" 2>"$SANDBOX/err7"; then
    fail 'deploy succeeded against a foreign lock holder'
fi
kill -0 "$FOREIGN" 2>/dev/null || fail 'deploy signaled the foreign holder'
[ -f "$LOCK" ] || fail 'deploy removed the foreign holder lock'
grep -q 'refusing' "$SANDBOX/err7" || fail 'deploy did not explain the refusal'
grep -qF "$FOREIGN" "$SANDBOX/err7" || fail 'deploy did not name the refused pid'
grep -q 'phase: reload action' "$SANDBOX/err7" || fail 'deploy did not name the failed phase (reload action)'
pass 'a foreign lock holder fails clearly and is never signaled'

printf '1..%d\n' "$PASS"
