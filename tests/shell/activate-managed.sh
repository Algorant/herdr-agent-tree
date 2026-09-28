#!/usr/bin/env bash
# An isolated, credential-free activation contract test; never contacts the live server.
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/agent-tree-activate.XXXXXX")
trap 'rm -rf -- "$TEMP"' EXIT
mkdir -p "$TEMP/config/herdr" "$TEMP/bin"
CONFIG=$TEMP/config/herdr/config.toml
printf '[ui]\naccent = "blue"\n' > "$CONFIG"

# Mock just the Herdr commands this activation contract needs. Config checking parses
# the actual on-disk TOML; the action log models the async invocation/success boundary.
cat > "$TEMP/bin/herdr" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'plugin list --json') printf '{"result":{"plugins":[{"plugin_id":"agent-tree","enabled":true,"source":{"kind":"github"}}]}}\n' ;;
  'status') printf 'running\n' ;;
  'config check') python3 -c 'import os,tomllib; tomllib.load(open(os.environ["XDG_CONFIG_HOME"]+"/herdr/config.toml","rb"))' ;;
  'server reload-config') printf 'reloaded\n' ;;
  'plugin action invoke agent-tree.apply') printf '{"result":{"log":{"log_id":"plugin-log-1","status":"running"}}}\n' ;;
  'plugin log list --plugin agent-tree --limit 20') printf '{"result":{"logs":[{"log_id":"plugin-log-1","status":"%s"}]}}\n' "${MOCK_ACTION_STATUS:-succeeded}" ;;
  *) printf 'unexpected mock herdr command: %s\n' "$*" >&2; exit 1 ;;
esac
SH
chmod +x "$TEMP/bin/herdr"
export XDG_CONFIG_HOME=$TEMP/config HERDR_BIN_PATH=$TEMP/bin/herdr
"$ROOT/scripts/activate-managed.sh" > "$TEMP/first.out"
grep -q 'apply completed' "$TEMP/first.out"
python3 - "$CONFIG" <<'PY'
import sys, tomllib
with open(sys.argv[1], 'rb') as f:
    data = tomllib.load(f)
assert data['ui']['sidebar']['agents']['rows'] == [['state_icon', '$agent_tree_branch', 'workspace', 'tab']]
PY
[ -f "${CONFIG}.agent-tree.bak" ]
grep -q 'accent = "blue"' "${CONFIG}.agent-tree.bak"
cp "$CONFIG" "$TEMP/first-config"
"$ROOT/scripts/activate-managed.sh" > "$TEMP/second.out"
cmp -s "$CONFIG" "$TEMP/first-config"

# A started action is not a completed action: reject a terminal failure.
if MOCK_ACTION_STATUS=failed "$ROOT/scripts/activate-managed.sh" > "$TEMP/failed.out" 2>&1; then
  printf 'a failed apply action was incorrectly accepted\n' >&2; exit 1
fi
grep -q 'apply failed' "$TEMP/failed.out"

# Never displace custom rows, and never invoke the action in that case.
printf '\n[ui.sidebar.agents]\nrows = [["agent"]]\n' > "$CONFIG"
if "$ROOT/scripts/activate-managed.sh" > "$TEMP/foreign.out" 2>&1; then
  printf 'foreign Agents rows were incorrectly accepted\n' >&2; exit 1
fi
grep -q 'rows differ' "$TEMP/foreign.out"
grep -q 'rows = \[\["agent"\]\]' "$CONFIG"

# Both previously managed rows are user-owned on upgrade and require an explicit migration.
legacy_rows=(
  '[["state_icon", "$agent_tree_row", "terminal_title_stripped"]]'
  '[["state_icon", "$agent_tree_row"]]'
  '[["state_icon", "workspace", "tab", "$agent_tree_row"]]'
)
for rows in "${legacy_rows[@]}"; do
  printf '\n[ui.sidebar.agents]\nrows = %s\n' "$rows" > "$CONFIG"
  cp "$CONFIG" "$TEMP/legacy-config"
  if "$ROOT/scripts/activate-managed.sh" > "$TEMP/legacy.out" 2>&1; then
    printf 'a legacy sidebar row was silently migrated\n' >&2; exit 1
  fi
  grep -q 'manually replace with rows' "$TEMP/legacy.out"
  grep -qF "rows = [['state_icon', '\$agent_tree_branch', 'workspace', 'tab']]" "$TEMP/legacy.out"
  cmp -s "$CONFIG" "$TEMP/legacy-config" || { printf 'legacy user config was changed\n' >&2; exit 1; }
done
printf 'ok - managed activation, idempotence, and manual foreign-row migration boundary\n'
