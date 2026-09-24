#!/usr/bin/env bash
# Read-only Agent Tree doctor for explicit local and remote Herdr endpoints.
#
#   scripts/doctor.sh --endpoint local
#   scripts/doctor.sh --endpoint local --endpoint archbox
#   scripts/doctor.sh --endpoint archbox --json
#
# Each --endpoint is `local`, or the unique label, profile id, or SSH target of an enabled
# saved Herdr machine. The endpoint is always the one named here; a machine selected in the
# TUI never retargets it. The doctor only reads: forwarded Herdr API JSON, the endpoint
# config, and a read-only /proc probe. It never writes, signals a process, or restarts a
# server. Remote values cross SSH only as argv (base64 payload), never interpolated.
set -euo pipefail

PLUGIN=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB="$PLUGIN/scripts/lib"
. "$LIB/endpoint.sh"

HERDR_BIN="${HERDR_BIN_PATH:-}"
SSH_BIN=${SSH_BIN:-ssh}
JSON=0
ENDPOINTS=()

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --endpoint) [ "$#" -ge 2 ] || fail "--endpoint needs a name"; ENDPOINTS+=("$2"); shift ;;
    --json)     JSON=1 ;;
    --herdr)    [ "$#" -ge 2 ] || fail "--herdr needs a path"; HERDR_BIN=$2; shift ;;
    --ssh)      [ "$#" -ge 2 ] || fail "--ssh needs a path"; SSH_BIN=$2; shift ;;
    -h|--help)  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
  shift
done

[ "${#ENDPOINTS[@]}" -gt 0 ] || fail "at least one --endpoint is required; it is never inferred from the TUI selection"
if [ -z "$HERDR_BIN" ]; then
  HERDR_BIN=$(command -v herdr || true)
fi
[ -n "$HERDR_BIN" ] && [ -x "$HERDR_BIN" ] || fail "herdr not found; put it on PATH or pass --herdr PATH."
[ -x "$SSH_BIN" ] || SSH_BIN=$(command -v "$SSH_BIN" || true)
[ -n "$SSH_BIN" ] && [ -x "$SSH_BIN" ] || fail "ssh not found; pass --ssh PATH."

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/agent-tree-doctor.XXXXXX")
RAW="$TMPD/raw.jsonl"
: > "$RAW"
cleanup() { rm -rf -- "$TMPD"; }
trap cleanup EXIT

json_extract() {
  # $1 file, $2 python expression over `data` (the parsed document)
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    sys.exit(1)
value = eval(sys.argv[2], {"json": json}, {"data": data})
if value is None:
    sys.exit(1)
if isinstance(value, str):
    sys.stdout.write(value)
else:
    sys.stdout.write(json.dumps(value))
PY
}

plugin_entry() {
  # $1 file with {"result":{"plugins":[...]}}, $2 field
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    plugins = json.load(open(sys.argv[1], "r", encoding="utf-8"))["result"]["plugins"]
except Exception:
    sys.exit(1)
for plugin in plugins:
    if plugin.get("plugin_id") == "agent-tree":
        value = plugin.get(sys.argv[2])
        if value is None:
            sys.exit(1)
        sys.stdout.write(value if isinstance(value, str) else json.dumps(value))
        break
else:
    sys.exit(1)
PY
}

registered_binary() {
  local dir=$1 fallback=$2 root kind
  root=$(plugin_entry "$dir/plugins.json" plugin_root 2>/dev/null || true)
  [ -n "$root" ] || { printf '%s' "$fallback"; return; }
  kind=$(plugin_entry "$dir/plugins.json" source 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("kind", ""))
except (ValueError, AttributeError): print("")' || true)
  case "$kind" in
    github) printf '%s/target/release/agent-tree' "$root" ;;
    local) printf '%s/src/agent-tree' "$root" ;;
    *) printf '%s/unknown-install-kind/agent-tree' "$root" ;;
  esac
}

collect_local() {
  local dir=$1
  local config_path="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml"
  local prefix="${XDG_DATA_HOME:-$HOME/.local/share}/herdr-agent-tree"
  local state="${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/agent-tree"

  if "$HERDR_BIN" status server --json > "$dir/status.json" 2>"$dir/status.err"; then :; else
    printf '{"error":"local status unavailable"}' > "$dir/status_error.json"
  fi
  "$HERDR_BIN" plugin list --json > "$dir/plugins.json" 2>/dev/null || echo '{}' > "$dir/plugins.json"
  plugin_entry "$dir/plugins.json" plugin_root > "$dir/plugin_root" 2>/dev/null || : > "$dir/plugin_root"
  if [ -f "$config_path" ]; then cp -- "$config_path" "$dir/config.toml"; else : > "$dir/config.toml"; fi
  if "$HERDR_BIN" agent list > "$dir/agents.raw.json" 2>/dev/null; then :; else echo '{}' > "$dir/agents.raw.json"; fi
  json_extract "$dir/agents.raw.json" 'data["result"]["agents"]' > "$dir/agents.json" 2>/dev/null || echo '[]' > "$dir/agents.json"

  local socket="" stage_binary
  if [ -s "$dir/status.json" ]; then
    socket=$(json_extract "$dir/status.json" 'data.get("socket")' 2>/dev/null || true)
  fi
  stage_binary=$(registered_binary "$dir" "$prefix/stage/src/agent-tree")
  python3 "$LIB/probe.py" --socket "$socket" --stage "$stage_binary" --state-dir "$state" > "$dir/probe.json" 2>/dev/null \
    || echo '{"subscribers":[],"subscriber_count":0,"replaced_stage_subscribers":[],"stage":{},"tree_off":null}' > "$dir/probe.json"
  JSON_SOCKET=$socket
}

remote_exec() { endpoint_ssh_exec "$SSH_BIN" "$EP_TARGET" "$@"; }

collect_remote() {
  local dir=$1
  local paths
  paths=$(remote_exec sh -c 'printf "%s\n%s\n%s\n" "${XDG_DATA_HOME:-$HOME/.local/share}/herdr-agent-tree" "${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml" "${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/agent-tree"') \
    || fail "ssh to '$EP_TARGET' failed"
  local prefix config_path state remote_herdr
  prefix=$(printf '%s\n' "$paths" | sed -n 1p)
  config_path=$(printf '%s\n' "$paths" | sed -n 2p)
  state=$(printf '%s\n' "$paths" | sed -n 3p)
  remote_herdr=$(remote_exec sh -c 'p=; if command -v mise >/dev/null 2>&1; then p=$(mise which herdr 2>/dev/null || true); fi; if [ -z "$p" ] || [ ! -x "$p" ]; then p=$(command -v herdr 2>/dev/null || true); fi; printf "%s" "$p"' 2>/dev/null || true)

  if "$HERDR_BIN" --machine "$EP_ID" status server --json > "$dir/status.json" 2>"$dir/status.err"; then :; else
    printf '{"error":"remote status unavailable"}' > "$dir/status_error.json"
  fi
  "$HERDR_BIN" --machine "$EP_ID" plugin list --json > "$dir/plugins.json" 2>/dev/null || echo '{}' > "$dir/plugins.json"
  plugin_entry "$dir/plugins.json" plugin_root > "$dir/plugin_root" 2>/dev/null || : > "$dir/plugin_root"
  remote_exec cat -- "$config_path" > "$dir/config.toml" 2>/dev/null || : > "$dir/config.toml"
  "$HERDR_BIN" --machine "$EP_ID" agent list > "$dir/agents.raw.json" 2>/dev/null || echo '{}' > "$dir/agents.raw.json"
  json_extract "$dir/agents.raw.json" 'data["result"]["agents"]' > "$dir/agents.json" 2>/dev/null || echo '[]' > "$dir/agents.json"

  local socket="" stage_binary
  if [ -n "$remote_herdr" ]; then
    socket=$(remote_exec env HERDR_SESSION="$EP_SESSION" "$remote_herdr" status server --json 2>/dev/null \
      | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("socket") or "")
except Exception: print("")' || true)
  fi
  stage_binary=$(registered_binary "$dir" "$prefix/stage/src/agent-tree")
  remote_exec python3 -c "$(cat "$LIB/probe.py")" --socket "$socket" --stage "$stage_binary" --state-dir "$state" > "$dir/probe.json" 2>/dev/null \
    || echo '{"subscribers":[],"subscriber_count":0,"replaced_stage_subscribers":[],"stage":{},"tree_off":null}' > "$dir/probe.json"
  JSON_SOCKET=$socket
}

index=0
for name in "${ENDPOINTS[@]}"; do
  endpoint_read "$HERDR_BIN" "$name" || fail "could not resolve endpoint '$name'"
  index=$((index + 1))
  dir="$TMPD/$index"
  mkdir -p "$dir"
  if [ "$EP_KIND" = local ]; then
    collect_local "$dir"
  else
    collect_remote "$dir"
  fi
  python3 - "$dir" "$name" "$JSON_SOCKET" "${EP_LABEL:-}" "${EP_ID:-}" "${EP_TARGET:-}" "${EP_SESSION:-}" "$PLUGIN/herdr-plugin.toml" <<'PY' >> "$RAW"
import json, os, sys
directory, name, socket, label, profile, target, session, manifest = sys.argv[1:9]

def load(filename, default):
    path = os.path.join(directory, filename)
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return default
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return default

config_text = ""
config_path = os.path.join(directory, "config.toml")
if os.path.exists(config_path):
    with open(config_path, "r", encoding="utf-8", errors="replace") as handle:
        config_text = handle.read()

min_version = "0.9.0"
try:
    with open(manifest, "r", encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if stripped.startswith("min_herdr_version") and "=" in stripped:
                min_version = stripped.split("=", 1)[1].strip().strip('"')
                break
except OSError:
    pass

status = load("status.json", None)
status_error = load("status_error.json", None)
if isinstance(status_error, dict):
    status_error = status_error.get("error")
plugin_json = load("plugins.json", {})
plugin = None
for entry in (plugin_json.get("result", {}) or {}).get("plugins", []) or []:
    if entry.get("plugin_id") == "agent-tree":
        plugin = entry
        break
raw = {
    "name": name,
    "kind": "remote" if label else "local",
    "label": label or None,
    "id": profile or None,
    "target": target or None,
    "session": session or None,
    "socket": socket or None,
    "status": status,
    "status_error": status_error,
    "plugin": plugin,
    "config": config_text,
    "probe": load("probe.json", {}),
    "agents": load("agents.json", []),
    "min_version": min_version,
}
print(json.dumps(raw))
PY
done

report_args=(--raw "$RAW")
if [ "$JSON" = 1 ]; then report_args+=(--json); fi
python3 "$LIB/report.py" "${report_args[@]}"
