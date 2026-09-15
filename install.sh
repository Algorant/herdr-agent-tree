#!/usr/bin/env bash
# agent-tree live install / uninstall for your REAL Herdr server.
#
#   plugins/agent-tree/install.sh              install and apply
#   plugins/agent-tree/install.sh --uninstall  remove and restore config
#   plugins/agent-tree/install.sh --status     show what is currently in place
#
# Changes it makes, all reversible:
#   1. builds plugins/agent-tree
#   2. appends a [ui.sidebar.agents] block to ~/.config/herdr/config.toml
#      (backed up first; skipped if you already have one)
#   3. registers the plugin in your user-global Herdr registry
#   4. invokes agent-tree.apply so the projection appears without a restart
set -euo pipefail

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PLUGIN="$REPO/plugins/agent-tree"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml"
MARK_BEGIN="# >>> agent-tree sidebar rows >>>"
MARK_END="# <<< agent-tree sidebar rows <<<"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
step() { printf '  -> %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

MODE=install
for a in "$@"; do
  case "$a" in
    --uninstall) MODE=uninstall ;;
    --status)    MODE=status ;;
    -h|--help)   sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown option: $a" ;;
  esac
done

command -v herdr >/dev/null || fail "herdr not found on PATH."
herdr status >/dev/null 2>&1 || fail "no running Herdr server found."

case "$MODE" in

status)
  say "agent-tree status"
  if herdr plugin list 2>/dev/null | grep -q agent-tree; then
    herdr plugin list 2>/dev/null | grep agent-tree | sed 's/^/  /'
  else
    step "plugin not registered"
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
  RELOAD_AFTER=1

  if grep -qF "$MARK_BEGIN" "$CONFIG" 2>/dev/null; then
    cp -p "$CONFIG" "$CONFIG.agent-tree-backup.$(date +%Y%m%d-%H%M%S)"
    python3 - "$CONFIG" "$MARK_BEGIN" "$MARK_END" <<'PY'
import sys
path, begin, end = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines(keepends=True)
out, skip = [], False
for ln in lines:
    if ln.strip() == begin: skip = True; continue
    if ln.strip() == end:   skip = False; continue
    if not skip: out.append(ln)
open(path, "w").write("".join(out).rstrip() + "\n")
PY
    step "removed the sidebar block from $CONFIG"
  else
    step "no sidebar block to remove"
  fi
  if [ "${RELOAD_AFTER:-0}" = 1 ]; then
    herdr server reload-config >/dev/null 2>&1 && step "config reloaded; rows reverted" \
      || step "run 'herdr server reload-config' to revert the rows"
  fi
  say "Done."
  ;;

install)
  say "Installing agent-tree into your live Herdr"
  echo "  This will register the plugin globally and append a sidebar block to:"
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

  say "Building"
  cargo build --locked --manifest-path "$PLUGIN/Cargo.toml" 2>&1 | sed 's/^/  /'

  say "Configuring the Agents sidebar"
  if grep -q "ui.sidebar.agents" "$CONFIG" 2>/dev/null; then
    step "you already have a [ui.sidebar.agents] block; leaving it alone"
    step "to show the tree, add \"\$agent_tree_row\" to one of its rows yourself"
  else
    cp -p "$CONFIG" "$CONFIG.agent-tree-backup.$(date +%Y%m%d-%H%M%S)"
    step "backed up $CONFIG"
    cat >> "$CONFIG" <<EOF

$MARK_BEGIN
[ui.sidebar.agents]
rows = [["state_icon", "\$agent_tree_row", "workspace", "tab"]]
$MARK_END
EOF
    step "appended the sidebar rows block"
  fi

  say "Registering and applying the plugin"
  if herdr plugin list 2>/dev/null | grep -q agent-tree; then
    step "already registered"
  else
    herdr plugin link "$PLUGIN" --enabled 2>&1 | grep -o '"plugin_id":"[^"]*"' | sed 's/^/  -> linked /' || step "linked"
  fi
  herdr plugin action invoke agent-tree.apply >/dev/null 2>&1 && step "projection applied" || fail "apply failed; run '$0 --uninstall' to back out"

  # The sidebar rows come from config.toml, so the running server has to re-read it.
  # This reloads configuration only; it does not restart the server or disturb panes.
  herdr server reload-config >/dev/null 2>&1 && step "config reloaded (no restart, panes untouched)" \
    || step "could not reload config automatically; run: herdr server reload-config"

  say "What the plugin sees right now"
  python3 - <<'PY'
import json, os, socket

def call(obj):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(10)
    s.connect(os.path.expanduser("~/.config/herdr/herdr.sock"))
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

  say "Done"
  echo "  Back out at any time:  $0 --uninstall"
  ;;
esac
