#!/usr/bin/env bash
# agent-tree DEVELOPMENT install / uninstall from this checkout, for your REAL Herdr server.
#
# This is a development install from a checkout, not the normal user install path. A normal
# user installs a published release artifact with scripts/install.sh; see README.md.
#
#   ./install.sh              install and apply
#   ./install.sh --uninstall  remove and restore config
#   ./install.sh --status     show what is currently in place
#
# Changes it makes, all reversible:
#   1. builds . as an optimized release binary
#   2. stages a self-contained plugin root in the user data directory
#      (default ~/.local/share/herdr-agent-tree/stage) with the release binary at
#      ./src/agent-tree, so the installed plugin depends on neither this checkout
#      nor target/ surviving
#   3. adds or updates the agent-tree [ui.sidebar.agents] rows block in
#      ~/.config/herdr/config.toml (backed up first; a foreign block is left alone)
#   4. registers the staged root in your user-global Herdr registry
#   5. invokes agent-tree.apply so the projection appears without a restart
#
# A previous install that registered this source checkout (local:<repo>) is relinked
# to the staged root; no server restart is needed for the move.
set -euo pipefail

PLUGIN=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO="$PLUGIN"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml"
SOCKET="${HERDR_SOCKET_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/herdr.sock}"
MARK_BEGIN="# >>> agent-tree sidebar rows >>>"
MARK_END="# <<< agent-tree sidebar rows <<<"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
step() { printf '  -> %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

MODE=install
PREFIX=""
HERDR_BIN=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --uninstall) MODE=uninstall ;;
    --status)    MODE=status ;;
    --prefix)    [ "$#" -ge 2 ] || fail "--prefix needs a directory"; PREFIX=$2; shift ;;
    --herdr)     [ "$#" -ge 2 ] || fail "--herdr needs a path"; HERDR_BIN=$2; shift ;;
    -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
  shift
done

if [ -z "$PREFIX" ]; then
  if [ -n "${XDG_DATA_HOME:-}" ]; then
    PREFIX="$XDG_DATA_HOME/herdr-agent-tree"
  else
    PREFIX="$HOME/.local/share/herdr-agent-tree"
  fi
fi
case "$PREFIX" in
  /*) ;;
  *) fail "--prefix must be an absolute path" ;;
esac
STAGE="$PREFIX/stage"
RELEASE_BINARY="$PLUGIN/target/release/agent-tree"

if [ -z "$HERDR_BIN" ]; then
  if [ -n "${HERDR_BIN_PATH:-}" ]; then
    HERDR_BIN=$HERDR_BIN_PATH
  else
    HERDR_BIN=$(command -v herdr || true)
  fi
fi
[ -n "$HERDR_BIN" ] && [ -x "$HERDR_BIN" ] || fail "herdr not found; put it on PATH or pass --herdr PATH."
herdr() { "$HERDR_BIN" "$@"; }
herdr status >/dev/null 2>&1 || fail "no running Herdr server found."

registered_path() {
  herdr plugin list 2>/dev/null | grep -F 'agent-tree (' \
    | sed -n 's/.*\[local:\(.*\)\].*/\1/p' | head -1 || true
}

build_release() {
  say "Building the release binary"
  cargo build --locked --release --manifest-path "$PLUGIN/Cargo.toml" 2>&1 | sed 's/^/  /'
  [ -x "$RELEASE_BINARY" ] || fail "release build did not produce $RELEASE_BINARY"
}

stage_root() {
  say "Staging a self-contained plugin root"
  [ ! -L "$STAGE" ] || fail "refusing to replace a symlinked stage path: $STAGE"
  mkdir -p "$PREFIX"
  local work old id
  work=$(mktemp -d "$PREFIX/.stage.XXXXXX") || fail "cannot create a staging directory under $PREFIX"
  mkdir -p "$work/src"
  cp -- "$PLUGIN/herdr-plugin.toml" "$work/herdr-plugin.toml"
  cp -- "$PLUGIN/README.md" "$work/README.md"
  cp -- "$RELEASE_BINARY" "$work/src/agent-tree"
  chmod 644 "$work/herdr-plugin.toml" "$work/README.md"
  chmod 755 "$work/src/agent-tree"

  # The staged root is a complete plugin root: manifest identity and every command the
  # manifest runs must resolve inside it, with the real release binary in place of the
  # source launcher.
  id=$(awk -F '"' '$1 ~ /^[[:space:]]*id[[:space:]]*=[[:space:]]*$/ { print $2; exit }' "$work/herdr-plugin.toml")
  [ "$id" = agent-tree ] || { rm -rf "$work"; fail "staged manifest has the wrong plugin id: ${id:-<none>}"; }
  for action in start apply clear toggle; do
    grep -Fqx "command = [\"./src/agent-tree\", \"$action\"]" "$work/herdr-plugin.toml" \
      || { rm -rf "$work"; fail "staged manifest is missing the '$action' command"; }
  done
  [ -x "$work/src/agent-tree" ] || { rm -rf "$work"; fail "staged binary is not executable"; }

  old="$PREFIX/.stage-old.$$"
  rm -rf "$old"
  if [ -e "$STAGE" ]; then
    mv -T "$STAGE" "$old" || { rm -rf "$work"; fail "cannot move the previous stage aside"; }
  fi
  if ! mv -T "$work" "$STAGE"; then
    if [ -e "$old" ]; then mv -T "$old" "$STAGE"; fi
    rm -rf "$work"
    fail "cannot commit the staged plugin root: $STAGE"
  fi
  rm -rf "$old"
  step "staged $STAGE ($(stat -c '%s' "$STAGE/src/agent-tree") bytes)"
}

link_staged() {
  say "Registering the staged plugin"
  local current
  current=$(registered_path)
  if [ -n "$current" ]; then
    if [ "$current" = "$STAGE" ]; then
      step "refreshing the registration at $STAGE"
    else
      step "replacing the previous install at $current"
    fi
    herdr plugin unlink agent-tree >/dev/null 2>&1 \
      || fail "could not unregister the existing agent-tree plugin at $current"
  fi
  herdr plugin link "$STAGE" --enabled >/dev/null 2>&1 \
    || fail "herdr plugin link $STAGE --enabled failed"
  step "linked $STAGE"
}

case "$MODE" in

status)
  say "agent-tree status"
  if herdr plugin list 2>/dev/null | grep -q agent-tree; then
    herdr plugin list 2>/dev/null | grep agent-tree | sed 's/^/  /'
    current=$(registered_path)
    if [ "$current" = "$STAGE" ]; then
      step "running from the staged release root"
    elif [ -n "$current" ]; then
      step "running from $current (a source checkout: run install.sh to move to the stage)"
    fi
  else
    step "plugin not registered"
  fi
  if [ -x "$STAGE/src/agent-tree" ]; then
    step "staged root present: $STAGE"
  else
    step "no staged root at $STAGE"
  fi
  if grep -qF "$MARK_BEGIN" "$CONFIG" 2>/dev/null; then
    step "sidebar rows block present in $CONFIG"
  else
    step "no agent-tree sidebar block in $CONFIG"
  fi
  ls -1t "$CONFIG".agent-tree-backup.* 2>/dev/null | head -3 | sed 's/^/  backup: /' || true
  ;;

uninstall)
  say "Removing agent-tree from your live Herdr"
  herdr plugin action invoke agent-tree.clear >/dev/null 2>&1 && step "cleared plugin tokens and view" || step "clear action unavailable (already gone?)"
  herdr plugin disable agent-tree >/dev/null 2>&1 && step "disabled" || true
  herdr plugin unlink agent-tree >/dev/null 2>&1 && step "unregistered" || step "was not registered"
  # Leave no paused flag behind for a future reinstall to trip over.
  STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr/."
  if compgen -G "$STATE_DIR/paused-*.flag" >/dev/null 2>&1; then
    rm -f "$STATE_DIR"/paused-*.flag && step "removed paused flag(s)"
  fi
  RELOAD_AFTER=1

  if grep -qF "$MARK_BEGIN" "$CONFIG" 2>/dev/null; then
    cp -p "$CONFIG" "$CONFIG.agent-tree-backup.$(date +%Y%m%d-%H%M%S)"
    python3 - "$CONFIG" "$MARK_BEGIN" "$MARK_END" <<'PY'
import sys
path, begin, end = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines(keepends=True)
starts = [i for i, line in enumerate(lines) if line.strip() == begin]
ends = [i for i, line in enumerate(lines) if line.strip() == end]
if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
    sys.exit("agent-tree: %s has a damaged managed block; config left unchanged" % path)
first, last = starts[0], ends[0]
open(path, "w").write("".join(lines[:first] + lines[last + 1:]).rstrip() + "\n")
PY
    step "removed the sidebar block from $CONFIG"
  else
    step "no sidebar block to remove"
  fi
  if [ "${RELOAD_AFTER:-0}" = 1 ]; then
    herdr server reload-config >/dev/null 2>&1 && step "config reloaded; rows reverted" \
      || step "run '$HERDR_BIN server reload-config' to revert the rows"
  fi
  if [ -e "$STAGE" ]; then
    step "staged files left in place; remove with: rm -rf $STAGE"
  fi
  say "Done."
  ;;

install)
  say "Installing agent-tree as a development install from this checkout"
  echo "  This is not the normal user path; see scripts/install.sh and README.md for a release install."
  echo "  This will build a release binary, stage a self-contained plugin root at:"
  echo "    $STAGE"
  echo "  and register that staged root (not this source checkout), then add or update"
  echo "  the sidebar rows block in:"
  echo "    $CONFIG"
  echo "  Both are reversible with: $0 --uninstall"
  echo
  echo "  Known caveat: if a Worker's own Herdr tokens are ever dropped (server"
  echo "  restart) while one of its Subagents still points at it, worker_recover"
  echo "  can refuse once with 'incomplete or conflicting Herdr metadata'."
  echo "  It is transient: retry after Pi republishes, or run --uninstall."
  echo
  read -rp "  Continue? [y/N] " reply
  [[ "$reply" == [yY] ]] || { echo "Aborted. Nothing changed."; exit 1; }

  build_release
  stage_root

  say "Configuring the Agents sidebar"
  # One line per agent: status, tree decoration, then the agent's terminal title.
  # Pi titles every session itself and puts the agent's own name first, so the row
  # says *which* Worker or Subagent it is without a new plugin token or a .pi change.
  ROWS='[["state_icon", "$agent_tree_row", "terminal_title_stripped"]]'
  if grep -qF "$MARK_BEGIN" "$CONFIG" 2>/dev/null; then
    cp -p "$CONFIG" "$CONFIG.agent-tree-backup.$(date +%Y%m%d-%H%M%S)"
    step "backed up $CONFIG"
    python3 - "$CONFIG" "$MARK_BEGIN" "$MARK_END" "$ROWS" <<'PY'
import sys
path, begin, end, rows = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
lines = open(path).read().splitlines(keepends=True)
starts = [i for i, line in enumerate(lines) if line.strip() == begin]
ends = [i for i, line in enumerate(lines) if line.strip() == end]
if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
    sys.exit("agent-tree: %s has a damaged managed block (need exactly one begin and one end marker, in order); config left unchanged" % path)
first, last = starts[0], ends[0]
if any(line.strip() == "[ui.sidebar.agents]" for i, line in enumerate(lines) if not (first < i < last)):
    sys.exit("agent-tree: %s already declares [ui.sidebar.agents] outside the managed block; config left unchanged" % path)
body = ["[ui.sidebar.agents]\n", "rows = %s\n" % rows]
open(path, "w").write("".join(lines[:first + 1] + body + lines[last:]))
PY
    step "updated the agent-tree sidebar rows block"
  elif grep -q "ui.sidebar.agents" "$CONFIG" 2>/dev/null; then
    step "you already have a [ui.sidebar.agents] block this plugin does not manage; leaving it alone"
    step "to show the tree, add \"\$agent_tree_row\" to one of its rows yourself"
  else
    cp -p "$CONFIG" "$CONFIG.agent-tree-backup.$(date +%Y%m%d-%H%M%S)"
    step "backed up $CONFIG"
    cat >> "$CONFIG" <<EOF

$MARK_BEGIN
[ui.sidebar.agents]
rows = $ROWS
$MARK_END
EOF
    step "appended the sidebar rows block"
  fi

  link_staged
  herdr plugin action invoke agent-tree.apply >/dev/null 2>&1 && step "projection applied" || fail "apply failed; run '$0 --uninstall' to back out"

  # The sidebar rows come from config.toml, so the running server has to re-read it.
  # This reloads configuration only; it does not restart the server or disturb panes.
  herdr server reload-config >/dev/null 2>&1 && step "config reloaded (no restart, panes untouched)" \
    || step "could not reload config automatically; run: $HERDR_BIN server reload-config"

  say "What the plugin sees right now"
  python3 - "$SOCKET" <<'PY'
import json, os, socket, sys

def call(obj):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(10)
    s.connect(os.path.expanduser(sys.argv[1]))
    f = s.makefile("rwb"); f.write((json.dumps(obj) + "\n").encode()); f.flush()
    r = json.loads(f.readline()); s.close(); return r

agents = call({"id": "i", "method": "agent.list", "params": {}})["result"]["agents"]
ranked = []
for a in agents:
    t = a.get("tokens") or {}
    if t.get("agent_tree_rank"):
        ranked.append((t["agent_tree_rank"], a.get("workspace_id", ""), t.get("agent_tree_row", "")))
ranked.sort()

if ranked:
    print("  %d agent(s) are in a validated delegation tree:\n" % len(ranked))
    for rank, ws, row in ranked:
        print("    %s  %-6s %s" % (rank, ws, row or "(root)"))
    print("\n  Those rows are nested in your Agents sidebar now.")
else:
    print("  No delegation exists at the moment, so nothing is nested yet.")
    print("  Every Pi session you have open is a plain top-level session:")
    print("  there are no Workers or Subagents for the plugin to place.")
    print()
    print("  This is the plugin working correctly, not a failure. To see a tree,")
    print("  have one of your Pi sessions spawn a Subagent or start a Worker;")
    print("  the child appears beneath its parent within a few seconds, and the")
    print("  parent drops back to the flat list when its last child exits.")
PY

  say "Done (development install)"
  echo "  Running from:            $STAGE"
  echo "  Toggle the tree off/on:  $HERDR_BIN plugin action invoke agent-tree.toggle"
  echo "  Back out at any time:    $0 --uninstall"
  ;;
esac
