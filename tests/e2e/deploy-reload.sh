#!/usr/bin/env bash
#
# Noninteractive isolated real-Herdr deploy/reload ordering test.
#
# `scripts/deploy.sh` must not return until the reload action it started has actually
# finished and exactly one stable subscriber runs the just-staged binary. Herdr's
# `plugin action invoke` only starts the manifest command and returns a log record whose
# status is still `running`, so this test drives a real isolated server through two deploys
# and independently verifies, outside deploy's own helpers:
#   - a direct invoke response is `running`, not `succeeded` (the async contract that made
#     the pre-fix deploy return while the old `.stage-old.*` subscriber still held the lock),
#   - deploy returns with one live `agent-tree subscriber` on the staged path,
#   - sha256(target/release/agent-tree) == sha256($STAGE/src/agent-tree) == sha256(/proc/<pid>/exe),
#   - no `.stage-old.*` subscriber lingers and the pid is unchanged after `server reload-config`.
#
# Everything it creates lives in one temp directory and is removed on exit. It never reads or
# writes the active Herdr server, its socket or ~/.config/herdr.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PROGRAM=${0##*/}
fail() { printf '\n%s: ERROR: %s\n' "$PROGRAM" "$*" >&2; exit 1; }
step() { printf '  -> %s\n' "$*" >&2; }
log() { printf '\n== %s\n' "$*" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || fail "missing prerequisite: $1 ($2)"; }
need cargo "Rust toolchain, used to build the plugin"
need python3 "JSON parsing and /proc verification"
need sha256sum "coreutils, one of the three-way hashes"
need setsid "util-linux, used to detach the isolated server"
need awk "reading the resolved socket from herdr status"
need find "locating the subscriber lock"
need sort "the Herdr version check"

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

# Resolve the real cargo before HOME changes: deploy.sh builds through $PATH with the
# isolated HOME, where a mise shim cannot read its trusted configuration.
cargo_real=""
if command -v mise >/dev/null 2>&1; then
    cargo_real=$(mise which cargo 2>/dev/null || true)
fi
if [ -z "$cargo_real" ] || [ ! -x "$cargo_real" ]; then
    cargo_real=$(command -v cargo 2>/dev/null || true)
fi
[ -x "$cargo_real" ] || fail "missing prerequisite: cargo (Rust toolchain, used to build the plugin)"
export PATH="$(dirname -- "$cargo_real"):$PATH"

log "Building the release binary"
cargo build --locked --release --manifest-path "$ROOT/Cargo.toml"
RELEASE="$ROOT/target/release/agent-tree"
[ -x "$RELEASE" ] || fail "build did not produce $RELEASE"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/agent-tree-deploy-reload.XXXXXX")
export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/config"
export XDG_STATE_HOME="$TMP/state"
export XDG_DATA_HOME="$TMP/data"
export XDG_RUNTIME_DIR="$TMP/run"
export HERDR_SOCKET_PATH="$TMP/config/herdr/herdr.sock"
# Do not inherit the outer Herdr identity; this test talks only to the isolated socket.
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SESSION HERDR_ENV \
      HERDR_PLUGIN_ID HERDR_PLUGIN_ROOT HERDR_PLUGIN_CONFIG_DIR \
      HERDR_PLUGIN_STATE_DIR HERDR_PLUGIN_EVENT HERDR_INTEGRATION_ID 2>/dev/null || true

PREFIX="$TMP/data/herdr-agent-tree"
STAGE="$PREFIX/stage"
STATE_PLUGIN="$XDG_STATE_HOME/herdr/plugins/agent-tree"
SERVER_PID=""

cleanup() {
    [ -d "$TMP" ] || return 0
    "$HERDR_BIN" server stop >/dev/null 2>&1 || true
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
    fi
    if [ -d "$STATE_PLUGIN" ]; then
        find "$STATE_PLUGIN" -name 'subscriber-*.lock' -print0 2>/dev/null \
            | while IFS= read -r -d '' lock; do
                pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$lock" 2>/dev/null || true)
                [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
            done
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$HOME" "$XDG_CONFIG_HOME/herdr" "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
printf '[ui]\nsidebar_width = 32\n' >"$XDG_CONFIG_HOME/herdr/config.toml"

log "Starting the isolated Herdr server"
setsid "$HERDR_BIN" server >"$TMP/server.log" 2>&1 </dev/null &
SERVER_PID=$!
for _ in $(seq 1 100); do
    [ -S "$HERDR_SOCKET_PATH" ] && break
    sleep 0.1
done
[ -S "$HERDR_SOCKET_PATH" ] || fail "the isolated server did not create $HERDR_SOCKET_PATH; see $TMP/server.log"
resolved_socket=$(herdr status 2>/dev/null | awk '/socket:/{print $2; exit}')
[ "$resolved_socket" = "$HERDR_SOCKET_PATH" ] \
    || fail "refusing to continue: Herdr resolved socket ${resolved_socket:-none} but the isolated socket is $HERDR_SOCKET_PATH"
step "Socket verified isolated: $HERDR_SOCKET_PATH"

deploy() {
    ( cd "$ROOT" && printf 'y\n' | ./scripts/deploy.sh --herdr "$HERDR_BIN" --prefix "$PREFIX" )
}

# Independently verify the deploy contract: exactly one live `agent-tree subscriber` on the
# staged path, no `.stage-old.*` subscriber under the prefix, and the same SHA-256 for the
# checkout build, the staged file and the running image. Prints the subscriber pid.
verify_subscriber() {
    python3 - "$STAGE/src/agent-tree" "$RELEASE" "$PREFIX" "$1" <<'PY'
import hashlib, os, sys

stage, release, prefix = (os.path.realpath(arg) for arg in sys.argv[1:4])
phase = sys.argv[4]


def normalize(path):
    suffix = " (deleted)"
    return path[: -len(suffix)] if path.endswith(suffix) else path


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def argv(pid):
    try:
        raw = open("/proc/%d/cmdline" % pid, "rb").read()
    except OSError:
        return []
    return [part.decode("utf-8", "replace") for part in raw.split(b"\0") if part]


def die(message):
    sys.stderr.write("%s: %s\n" % (phase, message))
    sys.exit(1)


if not os.path.exists(stage):
    die("staged binary is absent: %s" % stage)
subscribers, replaced = [], []
for name in os.listdir("/proc"):
    if not name.isdigit():
        continue
    pid = int(name)
    try:
        exe = normalize(os.readlink("/proc/%d/exe" % pid))
    except OSError:
        continue
    if not exe.endswith("/agent-tree"):
        continue
    args = argv(pid)
    if len(args) < 2 or args[1] != "subscriber":
        continue
    if exe == stage:
        subscribers.append(pid)
    elif exe.startswith(prefix.rstrip("/") + "/.stage-old."):
        replaced.append((pid, exe))
if replaced:
    die("subscriber(s) still on a replaced stage: " + ", ".join("%d %s" % item for item in replaced))
if len(subscribers) != 1:
    die("expected exactly one staged subscriber, found %d: %s"
        % (len(subscribers), ", ".join(str(pid) for pid in subscribers) or "none"))
pid = subscribers[0]
try:
    stage_hash = sha256(stage)
    release_hash = sha256(release)
    image_hash = sha256("/proc/%d/exe" % pid)
except OSError as exc:
    die("cannot hash staged/release/running image: %s" % exc)
if not (stage_hash == release_hash == image_hash):
    die("hash mismatch: staged=%s release=%s running=%s" % (stage_hash, release_hash, image_hash))
print(pid)
PY
}

holder_pid() {
    local lock
    lock=$(find "$STATE_PLUGIN" -maxdepth 1 -name 'subscriber-*.lock' 2>/dev/null | head -1)
    [ -n "$lock" ] || return 1
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$lock"
}

# ---------------------------------------------------------------------------
# 1. First deploy: install, stage, register, reload. It must return already verified.
# ---------------------------------------------------------------------------
log "First deploy"
if ! deploy >"$TMP/deploy1.out" 2>"$TMP/deploy1.err"; then
    cat "$TMP/deploy1.err" >&2
    fail "the first deploy failed"
fi
grep -q 'verified (pid' "$TMP/deploy1.out" || fail "deploy did not print its staged-subscriber verification"
grep -q 'subscriber stable at pid' "$TMP/deploy1.out" || fail "deploy did not confirm subscriber stability after config reload"
pid1=$(verify_subscriber "after deploy 1") || fail "deploy 1 left no single verified staged subscriber"
step "deploy 1 returned with one verified subscriber pid $pid1"

# ---------------------------------------------------------------------------
# 2. The async contract, against real Herdr. The invoke returns a running record; the
#    replacement only happens later. A deploy that returned on the invoke would be wrong.
# ---------------------------------------------------------------------------
log "Establishing Herdr's async action ordering"
before=$(holder_pid) || fail "no subscriber lock exists before the direct reload"
invoke_json=$(herdr plugin action invoke agent-tree.reload) || fail "the direct reload invoke failed to start"
log_id=$(printf '%s' "$invoke_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["log"]["log_id"])') \
    || fail "could not read the direct reload log id"
status=$(printf '%s' "$invoke_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["log"]["status"])') \
    || fail "could not read the direct reload log status"
[ "$status" = running ] || fail "expected a running record from the async invoke, got '$status'"
step "invoke agent-tree.reload returned $log_id with status=running while the action was still working"
python3 - "$HERDR_BIN" "$log_id" <<'PY' || fail "the direct reload action did not finish successfully"
import json, subprocess, sys, time

herdr, log_id = sys.argv[1], sys.argv[2]
deadline = time.monotonic() + 30.0
while True:
    try:
        out = subprocess.run([herdr, "plugin", "log", "list", "--plugin", "agent-tree", "--limit", "200"],
                             capture_output=True, text=True, timeout=10)
        logs = json.loads(out.stdout)["result"]["logs"]
    except Exception:
        logs = []
    record = next((entry for entry in logs if entry.get("log_id") == log_id), None)
    if record is not None and record.get("status") != "running":
        if record.get("status") != "succeeded" or record.get("exit_code") != 0:
            raise SystemExit("reload log %s reported %s (exit %s): %s"
                             % (log_id, record.get("status"), record.get("exit_code"), record.get("stderr")))
        break
    if time.monotonic() >= deadline:
        raise SystemExit("reload log %s never reached a terminal status" % log_id)
    time.sleep(0.2)
PY
after=$(verify_subscriber "after the direct reload") || fail "the direct reload left no single verified staged subscriber"
[ "$after" != "$before" ] || fail "the direct reload did not replace subscriber $before"
step "direct reload finished with a new verified subscriber pid $after"

# ---------------------------------------------------------------------------
# 3. Repeated deploy: restage and replace again. Deploy must return only after the
#    replacement, and no pid may change after it returns and config reload completes.
# ---------------------------------------------------------------------------
log "Repeated deploy"
if ! deploy >"$TMP/deploy2.out" 2>"$TMP/deploy2.err"; then
    cat "$TMP/deploy2.err" >&2
    fail "the repeated deploy failed"
fi
pid3=$(verify_subscriber "after deploy 2") || fail "deploy 2 left no single verified staged subscriber"
[ "$pid3" != "$after" ] || fail "the repeated deploy did not replace the subscriber"
grep -q 'subscriber stable at pid' "$TMP/deploy2.out" || fail "deploy 2 did not confirm subscriber stability after config reload"
step "deploy 2 returned with one verified subscriber pid $pid3"

stable=$(holder_pid) || fail "the subscriber lock disappeared after deploy 2 returned"
for _ in $(seq 1 8); do
    sleep 0.25
    current=$(holder_pid) || fail "the subscriber lock disappeared while observing post-return stability"
    [ "$current" = "$stable" ] || fail "subscriber pid changed from $stable to $current after deploy returned"
    verify_subscriber "post-return stability" >/dev/null \
        || fail "subscriber identity was not stable after deploy returned"
done
step "no later replacement or pid change across the post-return observation window"

log "Deploy/reload ordering test passed"
