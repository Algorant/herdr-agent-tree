#!/bin/sh
# Clean-source build smoke test for the Herdr-managed install contract.
#
# Herdr installs this plugin from a source revision and runs the manifest's own [[build]]
# argv before registering it. This test reproduces that from a checkout that has only
# tracked files and no target/ directory: it runs every exact build argv from the parsed
# manifest, requires the executable every runtime manifest command names, and proves the
# entrypoint reaches the freshly built binary.
set -eu

PROGRAM=${0##*/}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/agent-tree-source-install.XXXXXX")
trap 'rm -rf -- "$SANDBOX"' EXIT HUP INT TERM
TREE=$SANDBOX/tree
mkdir -p "$TREE"

# Export only tracked working-tree files, preserving modes. The developer's target/ is
# deliberately absent, exactly as in a fresh Herdr-managed checkout.
(cd "$ROOT" && git ls-files -z | tar --null -T - -cf -) | tar -xf - -C "$TREE"
[ ! -e "$TREE/target" ] || { printf '%s: the clean checkout unexpectedly contains target/\n' "$PROGRAM" >&2; exit 1; }

# Execute the parsed manifest argv exactly as Herdr would: one argv array per build command,
# no shell reconstruction. Then require the binary and every runtime command.
python3 - "$TREE" <<'PY'
import os
import subprocess
import sys
import tomllib

tree = sys.argv[1]
with open(os.path.join(tree, "herdr-plugin.toml"), "rb") as handle:
    manifest = tomllib.load(handle)

builds = manifest.get("build") or []
if not builds:
    raise SystemExit("manifest declares no [[build]] command")
for index, entry in enumerate(builds):
    command = entry.get("command")
    if not command:
        raise SystemExit(f"manifest build {index} has no command")
    print(f"running manifest build {index}: {command}", file=sys.stderr)
    subprocess.run(command, cwd=tree, check=True)

binary = os.path.join(tree, "target", "release", "agent-tree")
if not os.access(binary, os.X_OK):
    raise SystemExit("the manifest build did not produce target/release/agent-tree")

runtimes = []
for section in ("startup", "actions"):
    for entry in manifest.get(section) or []:
        command = entry.get("command")
        if not command:
            raise SystemExit(f"a {section} manifest entry has no command")
        runtimes.append(command)
if not runtimes:
    raise SystemExit("manifest declares no runtime command")
for command in runtimes:
    first = command[0]
    if not first.startswith("./"):
        raise SystemExit(f"runtime manifest command is not a plugin-relative path: {first}")
    if not os.access(os.path.join(tree, first[2:]), os.X_OK):
        raise SystemExit(f"runtime manifest command is not executable: {first}")

# The entrypoint must reach the binary the build just produced. An unknown subcommand is a
# clean usage error; a missing build instead prints the launcher's unavailable diagnostic.
env = dict(os.environ)
env.pop("AGENT_TREE_NATIVE_BIN", None)
result = subprocess.run(
    [os.path.join(tree, "src", "agent-tree"), "__source_install_probe__"],
    cwd=tree,
    env=env,
    capture_output=True,
    text=True,
)
if result.returncode == 0:
    raise SystemExit("the manifest entrypoint unexpectedly accepted an unknown subcommand")
combined = result.stdout + result.stderr
if "unknown command" not in combined:
    raise SystemExit(f"the manifest entrypoint did not reach the built binary: {combined.strip()}")
print("ok - clean source build produced the executable every manifest command runs")
PY
