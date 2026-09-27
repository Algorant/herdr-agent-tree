#!/usr/bin/env bash
# Activate an already installed Herdr-managed GitHub copy without replacing its registration.
# The plugin runtime never edits config.toml; this explicit operator command owns that step.
set -euo pipefail

HERDR=${HERDR_BIN_PATH:-herdr}
CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml
ROW='rows = [["state_icon", "$agent_tree_row"]]'

fail() { printf 'agent-tree: %s\n' "$*" >&2; exit 1; }
command -v "$HERDR" >/dev/null || fail "herdr not found"
command -v python3 >/dev/null || fail "python3 not found"
[ -f "$CONFIG" ] && [ ! -L "$CONFIG" ] || fail "expected a regular config at $CONFIG"

# Refuse to replace a local/foreign plugin or silently edit a custom Agents row layout.
plugin_list=$("$HERDR" plugin list --json) || fail "could not inspect plugin registration"
python3 -c 'import json,sys
try:
    matches = [p for p in json.load(sys.stdin)["result"]["plugins"] if p["plugin_id"] == "agent-tree"]
    assert len(matches) == 1 and matches[0]["enabled"] and matches[0]["source"]["kind"] == "github"
except (KeyError, ValueError, AssertionError, TypeError):
    sys.exit("agent-tree: enable and install the GitHub-managed agent-tree plugin first")' <<< "$plugin_list"
"$HERDR" status >/dev/null || fail "Herdr server is not running"

# Compute the whole config before changing it. Existing exact rows are left untouched;
# a different [ui.sidebar.agents] block is owned by the user and must be handled manually.
new_config=$(mktemp "${CONFIG}.agent-tree.XXXXXX")
trap 'rm -f -- "$new_config"' EXIT
python3 - "$CONFIG" "$new_config" "$ROW" <<'PY'
import pathlib, sys, tomllib
source, destination = map(pathlib.Path, sys.argv[1:3])
row = sys.argv[3]
text = source.read_text()
try:
    config = tomllib.loads(text)
except tomllib.TOMLDecodeError as exc:
    sys.exit(f"agent-tree: invalid Herdr config: {exc}")
sidebar = config.get("ui", {}).get("sidebar", {}).get("agents")
expected = [["state_icon", "$agent_tree_row"]]
if sidebar is not None and sidebar.get("rows") != expected:
    sys.exit("agent-tree: existing [ui.sidebar.agents] rows differ; manually migrate to [['state_icon', '$agent_tree_row']] after review")
if sidebar is None:
    text += "\n[ui.sidebar.agents]\n" + str(row) + "\n"
destination.write_text(text)
PY

"$HERDR" config check >/dev/null || fail "current Herdr config is invalid"
if ! cmp -s -- "$CONFIG" "$new_config"; then
  backup="${CONFIG}.agent-tree.bak"
  [ ! -e "$backup" ] || fail "backup already exists: $backup"
  cp -p -- "$CONFIG" "$backup"
  chmod --reference="$CONFIG" "$new_config"
  mv -- "$new_config" "$CONFIG"
  if ! "$HERDR" config check || ! "$HERDR" server reload-config; then
    cp -p -- "$backup" "$CONFIG"
    "$HERDR" server reload-config >/dev/null || true
    fail "config activation failed; restored $backup"
  fi
  printf 'agent-tree: sidebar rows enabled (backup: %s)\n' "$backup"
else
  "$HERDR" server reload-config >/dev/null || fail "could not reload existing sidebar rows"
fi

# Invoke only after configuration is loaded. Invoking returns a RUNNING log, not success.
response=$("$HERDR" plugin action invoke agent-tree.apply) || fail "apply invocation failed"
log_id=$(python3 -c 'import json,sys
try: print(json.load(sys.stdin)["result"]["log"]["log_id"])
except (KeyError, ValueError, TypeError): sys.exit("agent-tree: apply returned no log id")' <<< "$response")
for ((attempt=0; attempt<40; attempt++)); do
  logs=$("$HERDR" plugin log list --plugin agent-tree --limit 20) || fail "could not inspect action log $log_id"
  status=$(python3 -c 'import json,sys
logs=json.load(sys.stdin)["result"]["logs"]
print(next((entry.get("status", "unknown") for entry in logs if entry.get("log_id") == sys.argv[1]), "missing"))' "$log_id" <<< "$logs")
  case "$status" in
    succeeded) printf 'agent-tree: apply completed; tree is active (log %s)\n' "$log_id"; exit 0 ;;
    failed|cancelled|error) printf '%s\n' "$logs" >&2; fail "apply $status (log $log_id)" ;;
    running|missing) sleep 0.25 ;;
    *) fail "unknown action status $status (log $log_id)" ;;
  esac
done
fail "apply did not finish within 10 seconds (log $log_id); inspect herdr plugin log list --plugin agent-tree"
