#!/usr/bin/env bash
# Agent Tree deployment to an explicitly named Herdr endpoint.
#
#   scripts/deploy-endpoint.sh --endpoint <name>            deploy (transactional)
#   scripts/deploy-endpoint.sh --endpoint <name> --status   read-only doctor for that endpoint
#   scripts/deploy-endpoint.sh --endpoint <name> --uninstall reverse this deployment
#
# <name> is `local`, or the unique label, profile id, or SSH target of an enabled saved
# Herdr machine (`herdr machine list`). The endpoint is always the one named here; a machine
# selected in the TUI never retargets this command. `--endpoint local` is the existing
# scripts/deploy.sh path, unchanged.
#
# The remote path is transactional: every prerequisite is checked before the first write,
# one per-endpoint lock serializes concurrent deploy/uninstall attempts, and any failure
# after the transaction opens restores the previous stage, registration/enabled state and
# configuration and then verifies the previous installation is usable. Remote values cross
# the SSH boundary only as argv (base64 payload), never interpolated into a shell string.
set -euo pipefail

PLUGIN=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB="$PLUGIN/scripts/lib"
. "$LIB/endpoint.sh"

MODE=install
ENDPOINT=""
HERDR_BIN="${HERDR_BIN_PATH:-}"
SSH_BIN=${SSH_BIN:-ssh}
PREFIX_OVERRIDE=""
ASSUME_YES=0
PASSTHRU=()

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
step() { printf '  -> %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*" >&2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --endpoint)  [ "$#" -ge 2 ] || fail "--endpoint needs a name"; ENDPOINT=$2; shift ;;
    --uninstall) MODE=uninstall; PASSTHRU+=(--uninstall) ;;
    --status)    MODE=status; PASSTHRU+=(--status) ;;
    --herdr)     [ "$#" -ge 2 ] || fail "--herdr needs a path"; HERDR_BIN=$2; PASSTHRU+=(--herdr "$2"); shift ;;
    --ssh)       [ "$#" -ge 2 ] || fail "--ssh needs a path"; SSH_BIN=$2; shift ;;
    --prefix)    [ "$#" -ge 2 ] || fail "--prefix needs a directory"; PREFIX_OVERRIDE=$2; PASSTHRU+=(--prefix "$2"); shift ;;
    -y|--yes)    ASSUME_YES=1 ;;
    -h|--help)   sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
  shift
done

[ -n "$ENDPOINT" ] || fail "--endpoint is required; it is never inferred from the TUI selection"
if [ -z "$HERDR_BIN" ]; then
  HERDR_BIN=$(command -v herdr || true)
fi
[ -n "$HERDR_BIN" ] && [ -x "$HERDR_BIN" ] || fail "herdr not found; put it on PATH or pass --herdr PATH."

endpoint_read "$HERDR_BIN" "$ENDPOINT" || fail "could not resolve endpoint '$ENDPOINT'"

if [ "$EP_KIND" = local ]; then
  if [ "$MODE" = status ]; then
    exec "$PLUGIN/scripts/doctor.sh" --endpoint local
  fi
  exec "$PLUGIN/scripts/deploy.sh" ${PASSTHRU[@]+"${PASSTHRU[@]}"}
fi

[ -x "$SSH_BIN" ] || SSH_BIN=$(command -v "$SSH_BIN" || true)
[ -n "$SSH_BIN" ] && [ -x "$SSH_BIN" ] || fail "ssh not found; pass --ssh PATH."
SSH_OPTIONS="-o BatchMode=yes -o ConnectTimeout=10"

if [ "$MODE" = status ]; then
  exec "$PLUGIN/scripts/doctor.sh" --endpoint "$ENDPOINT"
fi

MANIFEST="$PLUGIN/herdr-plugin.toml"
MIN_VERSION=$(awk -F '"' '$1 ~ /^[[:space:]]*min_herdr_version[[:space:]]*=[[:space:]]*$/ { print $2; exit }' "$MANIFEST")
[ -n "$MIN_VERSION" ] || fail "the manifest has no min_herdr_version"

REMOTE_PREFIX=""
REMOTE_CONFIG=""
REMOTE_STATE=""
REMOTE_SOCKET=""
REMOTE_HERDR=""
REMOTE_HERDR_Q=""
STAGE=""
NEW_STAGE=""
OLD_STAGE=""
FAILED_STAGE=""
LOCK_DIR=""
CONFIG_PENDING=""
CONFIG_BACKUP_REMOTE=""
ORIGINAL_CONFIG=""
ORIGINAL_CONFIG_SHA=""
NEW_CONFIG=""
LOCAL_TMP=""
LOCAL_SHA=""
PRIOR_REGISTERED=0
PRIOR_ROOT=""
PRIOR_ENABLED=false
PRIOR_STAGE_BINARY=""
PRIOR_STAGE_PRESENT=0
PHASE=init
SUCCESS=0
TXN_STARTED=0
LOCK_ACQUIRED=0
STAGE_COMMITTED=0
PRIOR_STAGE_MOVED_ASIDE=0
REGISTRATION_CHANGED=0
CONFIG_WRITTEN=0
RELOAD_ATTEMPTED=0
PRIOR_SUBSCRIBER_STOPPED=0
LOCK_TOKEN=""

# Only argv crosses the SSH boundary; no endpoint value is ever interpolated into a command.
remote_exec() { endpoint_ssh_exec "$SSH_BIN" "$EP_TARGET" "$@"; }

# Every forwarded call uses the unique saved profile id, never the label (labels can repeat).
herdr_machine() { "$HERDR_BIN" --machine "$EP_ID" "$@"; }

cleanup_tmp() {
  [ -n "$LOCAL_TMP" ] && [ -d "$LOCAL_TMP" ] && rm -rf -- "$LOCAL_TMP"
  return 0
}

remote_probe() {
  local stage=$1
  remote_exec python3 -c "$(cat "$LIB/probe.py")" --socket "$REMOTE_SOCKET" --stage "$stage" --state-dir "$REMOTE_STATE"
}

plugin_json() {
  local json
  json=$(herdr_machine plugin list --json) || return 1
  python3 -c '
import json, sys
try:
    plugins = json.loads(sys.argv[1])["result"]["plugins"]
except Exception:
    sys.exit(1)
for plugin in plugins:
    if plugin.get("plugin_id") == "agent-tree":
        print(json.dumps(plugin))
        break
' "$json"
}

plugin_root() {
  local json
  json=$(herdr_machine plugin list --json) || return 1
  python3 -c '
import json, sys
try:
    plugins = json.loads(sys.argv[1])["result"]["plugins"]
except Exception:
    sys.exit(1)
for plugin in plugins:
    if plugin.get("plugin_id") == "agent-tree":
        sys.stdout.write(plugin.get("plugin_root") or "")
        break
' "$json"
}

plugin_enabled() {
  local json
  json=$(herdr_machine plugin list --json) || return 1
  python3 -c '
import json, sys
try:
    plugins = json.loads(sys.argv[1])["result"]["plugins"]
except Exception:
    sys.exit(1)
for plugin in plugins:
    if plugin.get("plugin_id") == "agent-tree":
        print("true" if plugin.get("enabled") else "false")
        break
' "$json"
}

acquire_lock() {
  local owner
  owner="$(hostname 2>/dev/null || echo host):$$:$(date +%s):$RANDOM"
  if ! remote_exec sh -c 'mkdir -p -- "$1" && mkdir -- "$2" && printf "%s" "$3" > "$2/owner"' \
       sh "$REMOTE_PREFIX" "$LOCK_DIR" "$owner" >/dev/null 2>&1; then
    holder=$(remote_exec cat -- "$LOCK_DIR/owner" 2>/dev/null || true)
    fail "another deploy or uninstall holds the endpoint lock $LOCK_DIR (holder: ${holder:-unknown}); retry after it finishes, or remove that directory if the holder is gone (phase: lock)"
  fi
  LOCK_TOKEN=$owner
  LOCK_ACQUIRED=1
}

release_lock() {
  [ "$LOCK_ACQUIRED" = 1 ] || return 0
  if [ -n "$LOCK_TOKEN" ]; then
    local current
    current=$(remote_exec cat -- "$LOCK_DIR/owner" 2>/dev/null || true)
    if [ "$current" = "$LOCK_TOKEN" ]; then
      remote_exec rm -rf -- "$LOCK_DIR" >/dev/null 2>&1 || true
    fi
  fi
  LOCK_ACQUIRED=0
}

verify_subscriber() {
  local phase=$1 json
  json=$(remote_probe "$STAGE_BINARY") || { printf 'the endpoint subscriber probe failed during %s\n' "$phase" >&2; return 1; }
  python3 - "$json" "$STAGE_BINARY" "$LOCAL_SHA" <<'PY'
import json, sys

probe = json.loads(sys.argv[1])
stage_binary, expected = sys.argv[2], sys.argv[3]

if probe["replaced_stage_subscribers"]:
    raise SystemExit("subscriber(s) still running from a replaced stage: %s" % (
        ", ".join(str(entry["pid"]) for entry in probe["replaced_stage_subscribers"])))
subscribers = probe["subscribers"]
if len(subscribers) != 1:
    raise SystemExit("expected exactly one live subscriber on %s, found %d: %s" % (
        stage_binary, len(subscribers), ", ".join(str(e["pid"]) for e in subscribers) or "none"))
entry = subscribers[0]
if entry["exe"] != stage_binary:
    raise SystemExit("the live subscriber runs %s, not the staged %s" % (entry["exe"], stage_binary))
staged = probe["stage"]["sha256"]
if not (staged == expected == entry["sha256"]):
    raise SystemExit("hash mismatch (build=%s staged=%s running=%s)" % (
        expected, staged, entry["sha256"]))
print(entry["pid"])
PY
}

# Rollback verification: the restored binary is whatever the prior root now holds, so this
# checks exactly one subscriber running that root with a self-consistent hash.
verify_single_subscriber() {
  local phase=$1 binary=$2 json
  json=$(remote_probe "$binary") || { printf 'the endpoint subscriber probe failed during %s\n' "$phase" >&2; return 1; }
  python3 - "$json" "$binary" <<'PY'
import json, sys

probe = json.loads(sys.argv[1])
binary = sys.argv[2]
if probe["replaced_stage_subscribers"]:
    raise SystemExit("subscriber(s) still running from a replaced stage")
subscribers = probe["subscribers"]
if len(subscribers) != 1:
    raise SystemExit("expected exactly one live subscriber on %s, found %d" % (binary, len(subscribers)))
entry = subscribers[0]
if entry["exe"] != binary:
    raise SystemExit("the subscriber runs %s, not %s" % (entry["exe"], binary))
staged = probe["stage"]["sha256"]
if not (staged and staged == entry["sha256"]):
    raise SystemExit("the subscriber hash does not match the restored binary")
PY
}

invoke_action() {
  local action=$1 response log_id detail
  response=$(herdr_machine plugin action invoke "agent-tree.$action") \
    || { printf 'could not start agent-tree.%s\n' "$action" >&2; return 1; }
  log_id=$(printf '%s' "$response" | python3 -c 'import json, sys
try:
    print(json.load(sys.stdin)["result"]["log"]["log_id"])
except Exception:
    sys.exit(1)') \
    || { printf 'could not read the %s action log id from Herdr\n' "$action" >&2; return 1; }
  detail=$(python3 - "$HERDR_BIN" "$EP_ID" "$log_id" "$action" 2>&1 <<'PY'
import json, subprocess, sys, time

herdr, profile, log_id, action = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
deadline = time.monotonic() + 30.0
record = None
while True:
    try:
        out = subprocess.run(
            [herdr, "--machine", profile, "plugin", "log", "list", "--plugin", "agent-tree", "--limit", "200"],
            capture_output=True, text=True, timeout=15,
        )
        logs = json.loads(out.stdout)["result"]["logs"]
    except Exception:
        logs = []
    record = next((entry for entry in logs if entry.get("log_id") == log_id), None)
    if record is not None and record.get("status") != "running":
        break
    if time.monotonic() >= deadline:
        break
    time.sleep(0.2)
if record is None:
    raise SystemExit("Herdr reported no terminal status for %s log %s within 30s" % (action, log_id))
if record.get("status") != "succeeded" or record.get("exit_code") != 0:
    stderr = (record.get("stderr") or "").strip()
    raise SystemExit("%s log %s reported %s (exit %s)%s" % (
        action, log_id, record.get("status"), record.get("exit_code"), ": " + stderr if stderr else ""))
PY
) || { printf '%s action failed: %s\n' "$action" "${detail:-no detail reported}" >&2; return 1; }
}

invoke_reload() {
  RELOAD_ATTEMPTED=1
  invoke_action reload
}

stop_endpoint_subscriber() {
  remote_exec python3 -c "$(cat "$LIB/stop.py")" \
    --socket "$REMOTE_SOCKET" --state-dir "$REMOTE_STATE" --root "$1" --prefix "$REMOTE_PREFIX"
}

restore_config() {
  local pending=0 backup=0
  if [ -n "$CONFIG_BACKUP_REMOTE" ] && remote_exec test -e "$CONFIG_BACKUP_REMOTE" >/dev/null 2>&1; then backup=1; fi
  if remote_exec test -e "$CONFIG_PENDING" >/dev/null 2>&1; then pending=1; fi
  # Only restore what this deploy committed. A concurrent edit made before the commit
  # leaves no backup and no pending marker, so it is never overwritten.
  if [ "$CONFIG_WRITTEN" != 1 ] && [ "$pending" != 1 ] && [ "$backup" != 1 ]; then
    return 0
  fi
  note "restoring the endpoint configuration"
  if remote_exec test -e "$CONFIG_BACKUP_REMOTE" >/dev/null 2>&1; then
    remote_exec cp -p -- "$CONFIG_BACKUP_REMOTE" "$REMOTE_CONFIG" || return 1
  else
    remote_exec sh -c 'cp -p -- "$1" "$2" && cat > "$2" && mv -T -- "$2" "$1"' \
      sh "$REMOTE_CONFIG" "$REMOTE_CONFIG.restore.$$" < "$ORIGINAL_CONFIG" || return 1
  fi
  remote_exec rm -f -- "$CONFIG_PENDING" >/dev/null 2>&1 || true
  herdr_machine server reload-config >/dev/null 2>&1 || true
  return 0
}

rollback() {
  local ok=0 current current_enabled moved=0
  if [ "$RELOAD_ATTEMPTED" = 1 ]; then
    note "identity-verifying and stopping the candidate subscriber before touching its stage"
    if ! stop_endpoint_subscriber "$STAGE" >/dev/null 2>&1; then
      note "could not verify or stop the current subscriber; leaving every stage in place"
      return 1
    fi
  fi

  restore_config || ok=1

  if [ "$REGISTRATION_CHANGED" = 1 ]; then
    note "restoring plugin registration and enabled state"
    current=$(plugin_root || true)
    current_enabled=$(plugin_enabled || true)
    if [ "$PRIOR_REGISTERED" = 1 ]; then
      if [ "$current" != "$PRIOR_ROOT" ] || [ "$current_enabled" != "$PRIOR_ENABLED" ]; then
        herdr_machine plugin unlink agent-tree >/dev/null 2>&1 || true
        if [ "$PRIOR_ENABLED" = true ]; then
          herdr_machine plugin link "$PRIOR_ROOT" --enabled >/dev/null 2>&1 || ok=1
        else
          herdr_machine plugin link "$PRIOR_ROOT" --disabled >/dev/null 2>&1 || ok=1
        fi
      fi
    elif [ -n "$current" ]; then
      herdr_machine plugin unlink agent-tree >/dev/null 2>&1 || ok=1
    fi
  fi

  note "restoring the previous staged plugin root"
  if [ "$STAGE_COMMITTED" = 1 ]; then
    if [ "$PRIOR_STAGE_PRESENT" = 1 ]; then
      if remote_exec sh -c 'mv -T -- "$1" "$2" && mv -T -- "$3" "$1"' sh "$STAGE" "$FAILED_STAGE" "$OLD_STAGE"; then
        moved=1
      else
        remote_exec sh -c 'if [ ! -e "$1" ] && [ -e "$2" ]; then mv -T -- "$2" "$1"; fi' sh "$STAGE" "$FAILED_STAGE" >/dev/null 2>&1 || true
        ok=1
      fi
    else
      remote_exec mv -T -- "$STAGE" "$FAILED_STAGE" || ok=1
      moved=1
    fi
  elif [ "$PRIOR_STAGE_MOVED_ASIDE" = 1 ]; then
    if remote_exec mv -T -- "$OLD_STAGE" "$STAGE"; then
      moved=1
    else
      ok=1
    fi
  fi

  if [ "$ok" = 0 ] && [ "$PRIOR_REGISTERED" = 1 ] && [ "$PRIOR_ENABLED" = true ]; then
    note "re-establishing the previous subscriber"
    if [ "$RELOAD_ATTEMPTED" = 1 ] || [ "$PRIOR_SUBSCRIBER_STOPPED" = 1 ]; then
      invoke_reload >/dev/null 2>&1 || ok=1
    fi
    verify_single_subscriber "rollback" "$PRIOR_STAGE_BINARY" >/dev/null 2>&1 || ok=1
  fi

  if [ "$ok" = 0 ]; then
    remote_exec rm -rf -- "$NEW_STAGE" >/dev/null 2>&1 || true
    remote_exec rm -rf -- "$FAILED_STAGE" >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

on_exit() {
  local rc=$?
  trap - EXIT
  if [ "$SUCCESS" = 1 ]; then
    exit "$rc"
  fi
  if [ "$TXN_STARTED" != 1 ]; then
    printf '\nERROR (phase: %s): the endpoint was not mutated.\n' "$PHASE" >&2
    cleanup_tmp
    exit "$rc"
  fi
  set +e
  printf '\nERROR (phase: %s): starting automatic rollback.\n' "$PHASE" >&2
  if rollback; then
    printf 'Rollback complete: the previous installation, registration and configuration are restored.\n' >&2
  else
    printf 'ROLLBACK FAILED (original phase: %s). The previous and candidate stages were kept for manual recovery under %s\n' \
      "$PHASE" "$REMOTE_PREFIX" >&2
  fi
  release_lock
  cleanup_tmp
  exit "$rc"
}

# ---------------------------------------------------------------------------
# Shared read-only preflight.
# ---------------------------------------------------------------------------
say "Preflight for endpoint $ENDPOINT ($EP_LABEL -> $EP_TARGET, session $EP_SESSION)"

status_json=$(herdr_machine status server --json) \
  || fail "Herdr forwarding to profile '$EP_ID' failed (phase: preflight)"
python3 - "$status_json" "$MIN_VERSION" <<'PY' || fail "the endpoint Herdr is not usable for this plugin (phase: preflight)"
import json, sys
status = json.loads(sys.argv[1])
minimum = sys.argv[2]
if not status.get("running"):
    raise SystemExit("the endpoint Herdr server is not running")
if not status.get("compatible"):
    raise SystemExit("the endpoint Herdr endpoint protocol is not compatible with this client")
version = str(status.get("version", ""))
if not version:
    raise SystemExit("the endpoint Herdr did not report a version")

def triple(value):
    core = value.split("-")[0].split("+")[0]
    parts = core.split(".")
    while len(parts) < 3:
        parts.append("0")
    return tuple(int(part) for part in parts[:3])

if triple(version) < triple(minimum):
    raise SystemExit("the endpoint Herdr %s is older than the plugin minimum %s" % (version, minimum))
print("  endpoint Herdr %s (protocol %s, compatible)" % (version, status.get("protocol")))
PY

remote_uname=$(remote_exec uname -s -m) || fail "ssh to '$EP_TARGET' failed (phase: preflight)"
host_uname=$(uname -s -m)
step "endpoint platform: $remote_uname (host: $host_uname)"
if [ "$remote_uname" != "$host_uname" ]; then
  fail "no compatible build: the host is $host_uname but the endpoint is $remote_uname, and only the host target is installed (phase: build). No endpoint state was changed."
fi

paths=$(remote_exec sh -c 'printf "%s\n%s\n%s\n" "${XDG_DATA_HOME:-$HOME/.local/share}/herdr-agent-tree" "${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml" "${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/agent-tree"') \
  || fail "could not read the endpoint data/config paths (phase: preflight)"
REMOTE_PREFIX=$(printf '%s\n' "$paths" | sed -n 1p)
REMOTE_CONFIG=$(printf '%s\n' "$paths" | sed -n 2p)
REMOTE_STATE=$(printf '%s\n' "$paths" | sed -n 3p)
case "$PREFIX_OVERRIDE" in
  "") ;;
  /*) REMOTE_PREFIX=$PREFIX_OVERRIDE ;;
  *) fail "--prefix must be an absolute path" ;;
esac
STAGE="$REMOTE_PREFIX/stage"
NEW_STAGE="$REMOTE_PREFIX/.stage-new.$$"
OLD_STAGE="$REMOTE_PREFIX/.stage-old.$$"
FAILED_STAGE="$REMOTE_PREFIX/.stage-failed.$$"
LOCK_DIR="$REMOTE_PREFIX/.agent-tree-deploy.lock"
CONFIG_PENDING="$REMOTE_CONFIG.agent-tree-pending"
STAGE_BINARY="$STAGE/src/agent-tree"
step "endpoint prefix: $REMOTE_PREFIX"

for value in "$REMOTE_PREFIX" "$REMOTE_CONFIG" "$REMOTE_STATE"; do
  case "$value" in
    *$'\n'*|*$'\r'*) fail "unsupported newline in an endpoint path: $value (phase: preflight)" ;;
  esac
done

missing=$(remote_exec sh -c 'for t in python3 sha256sum tar mv rm cp mkdir chmod stat uname; do command -v "$t" >/dev/null 2>&1 || printf "%s " "$t"; done')
[ -z "$missing" ] || fail "the endpoint is missing required tools: $missing (phase: preflight)"

REMOTE_HERDR=$(remote_exec sh -c 'p=; if command -v mise >/dev/null 2>&1; then p=$(mise which herdr 2>/dev/null || true); fi; if [ -z "$p" ] || [ ! -x "$p" ]; then p=$(command -v herdr 2>/dev/null || true); fi; printf "%s" "$p"') \
  || fail "could not resolve the endpoint herdr binary (phase: preflight)"
[ -n "$REMOTE_HERDR" ] || fail "the endpoint has no herdr on PATH or via mise (phase: preflight)"
remote_exec test -x "$REMOTE_HERDR" || fail "the endpoint herdr is not executable: $REMOTE_HERDR (phase: preflight)"
case "$REMOTE_HERDR" in
  *'"'*|*$'\n'*|*$'\r'*) fail "unsupported character in the endpoint herdr path: $REMOTE_HERDR (phase: preflight)" ;;
esac
REMOTE_HERDR_Q=$(python3 -c 'import shlex, sys; sys.stdout.write(shlex.quote(sys.argv[1]))' "$REMOTE_HERDR")
step "endpoint herdr: $REMOTE_HERDR"

REMOTE_SOCKET=$(remote_exec env HERDR_SESSION="$EP_SESSION" "$REMOTE_HERDR" status server --json | python3 -c 'import json, sys
try:
    print(json.load(sys.stdin)["socket"])
except Exception:
    sys.exit(1)') \
  || fail "could not read the endpoint's session socket (phase: preflight)"
step "endpoint socket: $REMOTE_SOCKET"

if remote_exec test -L "$REMOTE_CONFIG"; then
  fail "refusing: the endpoint config $REMOTE_CONFIG is a symlink; this deploy will not replace a symlink (phase: preflight)"
fi

# ---------------------------------------------------------------------------
# Uninstall: explicit, lock-serialized, identity-verified stop, hard errors.
# ---------------------------------------------------------------------------
if [ "$MODE" = uninstall ]; then
  say "Uninstalling agent-tree from endpoint $ENDPOINT"

  # Read-only preflight: registry fetch/parse, ownership, config prospective bytes and the
  # subscriber identity. Nothing is stopped or changed until all of these pass.
  plugins_json=$(herdr_machine plugin list --json) \
    || fail "could not read the endpoint plugin registry (phase: uninstall); nothing was changed"
  registered_root=$(printf '%s' "$plugins_json" | python3 -c '
import json, sys
try:
    plugins = json.load(sys.stdin)["result"]["plugins"]
except Exception:
    sys.exit(1)
for plugin in plugins:
    if plugin.get("plugin_id") == "agent-tree":
        sys.stdout.write(plugin.get("plugin_root") or "")
        break
') || fail "the endpoint plugin registry could not be parsed (phase: uninstall); nothing was changed"
  registered_enabled=false
  if [ -n "$registered_root" ]; then
    case "$registered_root" in
      "$REMOTE_PREFIX"/*) ;;
      *) fail "refusing: agent-tree is registered at $registered_root, outside $REMOTE_PREFIX; refusing to uninstall an installation this endpoint does not own" ;;
    esac
    registered_enabled=$(printf '%s' "$plugins_json" | python3 -c '
import json, sys
for plugin in json.load(sys.stdin)["result"]["plugins"]:
    if plugin.get("plugin_id") == "agent-tree":
        print("true" if plugin.get("enabled") else "false")
        break
')
  fi
  stop_root=${registered_root:-$STAGE}

  UN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/agent-tree-uninstall.XXXXXX")
  UN_CONFIG_PENDING="$REMOTE_CONFIG.agent-tree-uninstall-pending"
  UN_CONFIG_WRITTEN=0
  UN_CONFIG_BACKUP=""
  UN_CONFIG_CHANGED=0
  UN_STAGE_TXN=""
  UN_STAGE_MOVED=0
  UN_REGISTRATION_CHANGED=0
  UN_PRIOR_REGISTERED=0
  UN_PRIOR_ROOT=""
  UN_PRIOR_ENABLED=false
  UN_TXN_STARTED=0
  UN_SUCCESS=0
  if [ -n "$registered_root" ]; then
    UN_PRIOR_REGISTERED=1
    UN_PRIOR_ROOT=$registered_root
    UN_PRIOR_ENABLED=$registered_enabled
  fi

  if remote_exec cat -- "$REMOTE_CONFIG" > "$UN_TMP/orig.toml" 2>/dev/null && [ -s "$UN_TMP/orig.toml" ]; then
    if ! python3 "$LIB/config.py" remove --file "$UN_TMP/orig.toml" --out "$UN_TMP/new.toml" >/dev/null 2>"$UN_TMP/config.err"; then
      rm -rf -- "$UN_TMP"
      fail "refusing: the endpoint config has damaged agent-tree markers; the subscriber, registration, config and stage are unchanged (phase: uninstall)"
    fi
    if cmp -s "$UN_TMP/orig.toml" "$UN_TMP/new.toml"; then UN_CONFIG_CHANGED=0; else UN_CONFIG_CHANGED=1; fi
  fi

  if ! remote_exec python3 -c "$(cat "$LIB/stop.py")" --dry-run \
      --socket "$REMOTE_SOCKET" --state-dir "$REMOTE_STATE" --root "$stop_root" --prefix "$REMOTE_PREFIX" >/dev/null 2>&1; then
    rm -rf -- "$UN_TMP"
    fail "refusing: the endpoint subscriber could not be identity-verified; the subscriber, registration, config and stage are unchanged (phase: uninstall)"
  fi

  uninstall_restore_config() {
    local pending=0 backup=0
    if remote_exec test -e "$UN_CONFIG_PENDING" >/dev/null 2>&1; then pending=1; fi
    if [ -n "$UN_CONFIG_BACKUP" ] && remote_exec test -e "$UN_CONFIG_BACKUP" >/dev/null 2>&1; then backup=1; fi
    if [ "$UN_CONFIG_WRITTEN" != 1 ] && [ "$pending" != 1 ] && [ "$backup" != 1 ]; then
      return 0
    fi
    if [ "$backup" = 1 ]; then
      remote_exec cp -p -- "$UN_CONFIG_BACKUP" "$REMOTE_CONFIG" || return 1
    else
      remote_exec sh -c 'cp -p -- "$1" "$2" && cat > "$2" && mv -T -- "$2" "$1"' \
        sh "$REMOTE_CONFIG" "$REMOTE_CONFIG.uninstall-restore.$$" < "$UN_TMP/orig.toml" || return 1
    fi
    remote_exec rm -f -- "$UN_CONFIG_PENDING" >/dev/null 2>&1 || true
    herdr_machine server reload-config >/dev/null 2>&1 || true
    return 0
  }

  uninstall_rollback() {
    local ok=0 current current_enabled
    uninstall_restore_config || ok=1
    if [ "$UN_REGISTRATION_CHANGED" = 1 ]; then
      current=$(plugin_root || true)
      current_enabled=$(plugin_enabled || true)
      if [ "$UN_PRIOR_REGISTERED" = 1 ]; then
        if [ "$current" != "$UN_PRIOR_ROOT" ] || [ "$current_enabled" != "$UN_PRIOR_ENABLED" ]; then
          herdr_machine plugin unlink agent-tree >/dev/null 2>&1 || true
          if [ "$UN_PRIOR_ENABLED" = true ]; then
            herdr_machine plugin link "$UN_PRIOR_ROOT" --enabled >/dev/null 2>&1 || ok=1
          else
            herdr_machine plugin link "$UN_PRIOR_ROOT" --disabled >/dev/null 2>&1 || ok=1
          fi
        fi
      elif [ -n "$current" ]; then
        herdr_machine plugin unlink agent-tree >/dev/null 2>&1 || ok=1
      fi
    fi
    if [ "$UN_STAGE_MOVED" = 1 ]; then
      remote_exec sh -c 'if [ ! -e "$2" ] && [ -e "$1" ]; then mv -T -- "$1" "$2"; fi; exit 0' sh "$UN_STAGE_TXN" "$STAGE" || ok=1
    fi
    if [ "$UN_PRIOR_REGISTERED" = 1 ] && [ "$UN_PRIOR_ENABLED" = true ]; then
      invoke_reload >/dev/null 2>&1 || ok=1
      verify_single_subscriber "uninstall rollback" "$UN_PRIOR_ROOT/src/agent-tree" >/dev/null 2>&1 || ok=1
    fi
    [ "$ok" = 0 ]
  }

  uninstall_on_exit() {
    local rc=$?
    trap - EXIT
    if [ "$UN_SUCCESS" = 1 ]; then
      release_lock
      rm -rf -- "$UN_TMP"
      exit "$rc"
    fi
    if [ "$UN_TXN_STARTED" = 1 ]; then
      set +e
      printf '\nERROR (phase: uninstall): starting automatic rollback.\n' >&2
      if uninstall_rollback; then
        printf 'Rollback complete: the previous registration, config, stage and subscriber are restored.\n' >&2
      else
        printf 'ROLLBACK FAILED (phase: uninstall); recovery artifacts were kept under %s\n' "$REMOTE_PREFIX" >&2
      fi
    fi
    release_lock
    rm -rf -- "$UN_TMP"
    exit "$rc"
  }
  trap 'uninstall_on_exit' EXIT

  acquire_lock
  UN_TXN_STARTED=1

  stop_endpoint_subscriber "$stop_root" >/dev/null \
    || fail "refusing: the endpoint subscriber could not be identity-verified and stopped (phase: uninstall)"
  step "verified and stopped the endpoint subscriber"

  invoke_action clear >/dev/null \
    || fail "could not clear the agent-tree tokens and view (phase: uninstall)"
  step "cleared plugin tokens and view"
  herdr_machine plugin disable agent-tree >/dev/null 2>&1 || true

  if [ "$UN_PRIOR_REGISTERED" = 1 ]; then
    herdr_machine plugin unlink agent-tree >/dev/null \
      || fail "could not unregister agent-tree (phase: uninstall)"
    UN_REGISTRATION_CHANGED=1
    step "unregistered"
  fi

  if [ "$UN_CONFIG_CHANGED" = 1 ]; then
    UN_CONFIG_BACKUP="$REMOTE_CONFIG.agent-tree-uninstall-backup.$(date +%Y%m%d-%H%M%S)"
    remote_exec cp -p -- "$REMOTE_CONFIG" "$UN_CONFIG_BACKUP" \
      || fail "could not back up the endpoint config (phase: uninstall)"
    remote_exec sh -c 'cp -p -- "$1" "$2" && cat > "$2" && cp -p -- "$1" "$3" && : > "$4" && mv -T -- "$2" "$1" && rm -f -- "$4"' \
      sh "$REMOTE_CONFIG" "$REMOTE_CONFIG.uninstall.$$" "$UN_CONFIG_BACKUP" "$UN_CONFIG_PENDING" < "$UN_TMP/new.toml" \
      || fail "could not commit the endpoint config (phase: uninstall)"
    UN_CONFIG_WRITTEN=1
    herdr_machine server reload-config >/dev/null \
      || fail "could not reload the endpoint config (phase: uninstall)"
    step "removed the agent-tree managed config fragments"
  else
    step "no agent-tree managed config fragments to remove"
  fi

  if remote_exec test -e "$STAGE"; then
    UN_STAGE_TXN="$REMOTE_PREFIX/.stage-uninstall.$$"
    remote_exec mv -T -- "$STAGE" "$UN_STAGE_TXN" \
      || fail "could not move the staged plugin root aside (phase: uninstall)"
    UN_STAGE_MOVED=1
  fi
  remote_exec sh -c 'for d in "$1"/.stage-old.* "$1"/.stage-new.* "$1"/.stage-failed.*; do if [ -e "$d" ]; then rm -rf -- "$d"; fi; done; exit 0' sh "$REMOTE_PREFIX"
  remote_exec rm -rf -- "$UN_STAGE_TXN" >/dev/null 2>&1 || true
  UN_STAGE_MOVED=0
  step "removed the staged plugin root"
  remote_exec sh -c 'rm -f -- "$1"/tree-off-*.flag "$1"/paused-*.flag "$1"/original-sort-*; exit 0' sh "$REMOTE_STATE" >/dev/null 2>&1 || true

  UN_SUCCESS=1
  say "Done. Re-deploy with: $0 --endpoint $ENDPOINT"
  exit 0
fi
trap on_exit EXIT

# ---------------------------------------------------------------------------
# Install preflight (still read-only on the endpoint).
# ---------------------------------------------------------------------------
LOCAL_TMP=$(mktemp -d "${TMPDIR:-/tmp}/agent-tree-endpoint.XXXXXX") || fail "cannot create a local workspace"
ORIGINAL_CONFIG="$LOCAL_TMP/config.orig.toml"
NEW_CONFIG="$LOCAL_TMP/config.new.toml"
remote_exec cat -- "$REMOTE_CONFIG" > "$ORIGINAL_CONFIG" \
  || fail "could not read the endpoint config $REMOTE_CONFIG (phase: preflight)"
ORIGINAL_CONFIG_SHA=$(sha256sum -- "$ORIGINAL_CONFIG" | awk '{print $1}')

inspect=$(python3 "$LIB/config.py" inspect --file "$ORIGINAL_CONFIG") \
  || fail "could not inspect the endpoint config (phase: preflight)"
python3 - "$inspect" <<'PY' || fail "the endpoint configuration cannot be completed safely (phase: preflight)"
import json, sys
data = json.loads(sys.argv[1])
if data["foreign_sidebar_block_without_token"]:
    raise SystemExit("refusing: a foreign [ui.sidebar.agents] block does not reference $agent_tree_row; it will not be overwritten")
if data["shortcut_key_occupied"]:
    raise SystemExit("refusing: shortcut %r is bound to another command" % data["shortcut_key"])
if data["sidebar_managed_block_damaged"] or data["shortcut_managed_block_damaged"]:
    raise SystemExit("refusing: an agent-tree managed fragment is damaged")
PY
SHORTCUT_COMMAND="$REMOTE_HERDR_Q plugin action invoke agent-tree.toggle"
ensure_result=$(python3 "$LIB/config.py" ensure --file "$ORIGINAL_CONFIG" --out "$NEW_CONFIG" --command "$SHORTCUT_COMMAND") \
  || fail "the endpoint config fragments could not be prepared (phase: preflight)"
CONFIG_CHANGED=$(printf '%s' "$ensure_result" | python3 -c 'import json, sys; print("1" if json.load(sys.stdin)["changed"] else "0")')
if [ "$CONFIG_CHANGED" = 1 ]; then
  step "config fragments: will install the missing managed fragment(s)"
else
  step "config fragments: already complete (left byte-for-byte untouched)"
fi

prior_json=$(plugin_json || true)
if [ -n "$prior_json" ]; then
  PRIOR_REGISTERED=1
  PRIOR_ROOT=$(printf '%s' "$prior_json" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("plugin_root") or "")')
  PRIOR_ENABLED=$(printf '%s' "$prior_json" | python3 -c 'import json, sys; print("true" if json.load(sys.stdin).get("enabled") else "false")')
  case "$PRIOR_ROOT" in
    "$REMOTE_PREFIX"/*) ;;
    *) fail "refusing: agent-tree is registered at $PRIOR_ROOT, outside $REMOTE_PREFIX; this deploy will not take ownership of it" ;;
  esac
  remote_exec test -e "$PRIOR_ROOT" \
    || fail "refusing: the registered plugin root $PRIOR_ROOT does not exist on the endpoint"
  PRIOR_STAGE_BINARY="$PRIOR_ROOT/src/agent-tree"
  step "previous registration: $PRIOR_ROOT (enabled=$PRIOR_ENABLED)"
else
  PRIOR_STAGE_BINARY="$STAGE_BINARY"
  step "no previous agent-tree registration"
fi
if remote_exec test -e "$STAGE"; then PRIOR_STAGE_PRESENT=1; fi

if [ "$ASSUME_YES" != 1 ]; then
  printf '\nDeploy the current checkout to endpoint %s and replace its plugin subscriber?\n' "$EP_LABEL" >&2
  read -r -p "  Continue? [y/N] " reply
  [[ "$reply" == [yY] ]] || { echo "Aborted. Nothing changed."; exit 1; }
fi

# ---------------------------------------------------------------------------
# Build and transfer. The lock opens the transaction with the first remote write.
# ---------------------------------------------------------------------------
PHASE=build
say "Building the release binary"
case "${CARGO_TARGET_DIR:-}" in
  "") TARGET_DIR="$PLUGIN/target" ;;
  /*) TARGET_DIR="$CARGO_TARGET_DIR" ;;
  *) TARGET_DIR="$PWD/$CARGO_TARGET_DIR" ;;
esac
RELEASE_BINARY="$TARGET_DIR/release/agent-tree"
cargo build --locked --release --manifest-path "$PLUGIN/Cargo.toml" 2>&1 | sed 's/^/  /'
[ -x "$RELEASE_BINARY" ] || fail "release build did not produce $RELEASE_BINARY (phase: build)"
LOCAL_SHA=$(sha256sum -- "$RELEASE_BINARY" | awk '{print $1}')

LOCAL_ROOT="$LOCAL_TMP/root"
mkdir -p "$LOCAL_ROOT/src"
for file in herdr-plugin.toml README.md CHANGELOG.md LICENSE; do
  cp -p -- "$PLUGIN/$file" "$LOCAL_ROOT/$file"
done
cp -p -- "$RELEASE_BINARY" "$LOCAL_ROOT/src/agent-tree"
chmod 755 "$LOCAL_ROOT/src/agent-tree"
[ -x "$LOCAL_ROOT/src/agent-tree" ] || fail "the local stage is not executable (phase: build)"

PHASE=lock
acquire_lock
TXN_STARTED=1
step "acquired the endpoint deploy lock"

PHASE=transfer
say "Transferring the candidate"
remote_exec sh -c 'mkdir -p -- "$1" && rm -rf -- "$2" && mkdir -p -- "$2"' sh "$REMOTE_PREFIX" "$NEW_STAGE" \
  || fail "could not create the endpoint staging path (phase: transfer)"
tar -C "$LOCAL_ROOT" -cf - . | remote_exec sh -c 'tar -xf - -C "$1"' sh "$NEW_STAGE" \
  || fail "could not stream the plugin root to the endpoint (phase: transfer)"
remote_sha=$(remote_exec sha256sum -- "$NEW_STAGE/src/agent-tree" | awk '{print $1}') \
  || fail "could not hash the endpoint candidate (phase: transfer)"
[ "$remote_sha" = "$LOCAL_SHA" ] \
  || fail "the transferred binary does not match the build (build=$LOCAL_SHA staged=$remote_sha, phase: transfer)"

PHASE=loader
say "Proving the endpoint loader can execute the candidate"
set +e
loader_out=$(remote_exec "$NEW_STAGE/src/agent-tree" __agent_tree_endpoint_probe__ 2>&1)
loader_rc=$?
set -e
if [ "$loader_rc" != 2 ] || ! printf '%s' "$loader_out" | grep -q 'unknown command'; then
  printf '  candidate exit=%s output=%s\n' "$loader_rc" "$loader_out" >&2
  printf '  endpoint loader diagnostics:\n' >&2
  remote_exec sh -c 'file "$1" 2>&1; ldd "$1" 2>&1; ldd --version 2>&1 | head -1; uname -a' sh "$NEW_STAGE/src/agent-tree" >&2 || true
  fail "the endpoint loader could not execute the candidate binary (phase: loader); the previous installation is untouched"
fi
note "candidate executed on the endpoint (exit $loader_rc)"

# ---------------------------------------------------------------------------
# Commit, register, reload, verify, config. Any failure from here is rolled back.
# ---------------------------------------------------------------------------
PHASE=commit
say "Committing the staged root"
if [ "$PRIOR_STAGE_PRESENT" = 1 ]; then
  remote_exec mv -T -- "$STAGE" "$OLD_STAGE" \
    || fail "could not move the previous stage aside (phase: commit)"
  PRIOR_STAGE_MOVED_ASIDE=1
fi
remote_exec mv -T -- "$NEW_STAGE" "$STAGE" \
  || fail "could not commit the staged root (phase: commit)"
STAGE_COMMITTED=1
step "staged $STAGE"

PHASE=register
say "Registering the staged plugin"
if [ "$PRIOR_REGISTERED" = 1 ] && [ "$PRIOR_ROOT" != "$STAGE" ]; then
  # The reload action only trusts its own registered root and `.stage-old.*` siblings, so a
  # subscriber running from a different owned root (for example `<prefix>/release`) must be
  # identity-verified and stopped before the reload can start the new subscriber.
  if ! stop_endpoint_subscriber "$PRIOR_ROOT" >/dev/null 2>&1; then
    fail "could not identity-verify and stop the previous subscriber at $PRIOR_ROOT (phase: register)"
  fi
  PRIOR_SUBSCRIBER_STOPPED=1
  step "stopped the previous subscriber at $PRIOR_ROOT"
fi
current_root=$(plugin_root || true)
if [ -n "$current_root" ] && [ "$current_root" != "$STAGE" ]; then
  herdr_machine plugin unlink agent-tree >/dev/null \
    || fail "could not unregister the previous plugin at $current_root (phase: register)"
  REGISTRATION_CHANGED=1
fi
herdr_machine plugin link "$STAGE" --enabled >/dev/null \
  || fail "herdr plugin link $STAGE --enabled failed (phase: register)"
REGISTRATION_CHANGED=1
step "linked and enabled $STAGE"

PHASE=reload
say "Replacing the running subscriber"
invoke_reload || fail "the reload action failed (phase: reload)"
PHASE=verify
pid_before=$(verify_subscriber "after the reload action") \
  || fail "subscriber verification failed after the reload action (phase: verify)"
step "subscriber verified (pid $pid_before, sha256 matches the build)"

if [ "$CONFIG_CHANGED" = 1 ]; then
  PHASE=config
  say "Updating the endpoint configuration"
  recheck="$LOCAL_TMP/config.recheck.toml"
  remote_exec cat -- "$REMOTE_CONFIG" > "$recheck" \
    || fail "could not re-read the endpoint config (phase: config)"
  recheck_sha=$(sha256sum -- "$recheck" | awk '{print $1}')
  [ "$recheck_sha" = "$ORIGINAL_CONFIG_SHA" ] \
    || fail "the endpoint config changed after preflight; refusing to overwrite a concurrent edit (phase: config)"
  CONFIG_BACKUP_REMOTE="$REMOTE_CONFIG.agent-tree-backup.$(date +%Y%m%d-%H%M%S)"
  remote_exec sh -c 'cp -p -- "$1" "$2" && cat > "$2" && cp -p -- "$1" "$3" && : > "$4" && mv -T -- "$2" "$1" && rm -f -- "$4"' \
    sh "$REMOTE_CONFIG" "$REMOTE_CONFIG.new.$$" "$CONFIG_BACKUP_REMOTE" "$CONFIG_PENDING" < "$NEW_CONFIG" \
    || fail "could not commit the endpoint config (phase: config)"
  CONFIG_WRITTEN=1
  herdr_machine server reload-config >/dev/null \
    || fail "reloading the endpoint config failed (phase: config)"
  step "config updated (backup: $CONFIG_BACKUP_REMOTE)"
  PHASE=verify
  pid_after=$(verify_subscriber "after the config reload") \
    || fail "subscriber verification failed after the config reload (phase: verify)"
  [ "$pid_after" = "$pid_before" ] \
    || fail "the subscriber pid changed from $pid_before to $pid_after after the config reload (phase: verify)"
  step "subscriber stable at pid $pid_after"
else
  note "the endpoint config already references \$agent_tree_row and the toggle shortcut; left byte-for-byte untouched"
fi

if [ "$PRIOR_STAGE_PRESENT" = 1 ]; then
  remote_exec rm -rf -- "$OLD_STAGE" >/dev/null 2>&1 || true
fi

SUCCESS=1
release_lock
cleanup_tmp
say "Done: endpoint $EP_LABEL now runs the staged build"
printf '  Running from:   %s\n' "$STAGE"
printf '  Toggle:         %s --machine %s plugin action invoke agent-tree.toggle\n' "$HERDR_BIN" "$EP_ID"
printf '  Diagnose:       %s/scripts/doctor.sh --endpoint %s\n' "$PLUGIN" "$ENDPOINT"
printf '  Back out:       %s --endpoint %s --uninstall\n' "$0" "$ENDPOINT"
