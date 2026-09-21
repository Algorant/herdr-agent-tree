#!/bin/sh
# Check the source release contract without publishing anything.
#
# Herdr installs this plugin from a tagged source revision and runs the manifest's [[build]]
# command itself, so there are no binary release assets to inspect. This gate keeps the
# manifest, Cargo.toml, CHANGELOG and tag ref in agreement, requires the exact locked Cargo
# release build that the manifest declares, and fails if any removed custom release path
# reappears.
set -eu
PROGRAM=${0##*/}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
# A release ref is checked only when the caller explicitly supplies --ref. Normal push and
# pull-request jobs also export GITHUB_REF, but those branch refs are not release intent.
ref=
while [ "$#" -gt 0 ]; do
    case $1 in
        --ref) [ "$#" -ge 2 ] || exit 2; ref=$2; shift 2 ;;
        *) printf '%s: unknown argument: %s\n' "$PROGRAM" "$1" >&2; exit 2 ;;
    esac
done
python3 - "$ROOT" "$ref" <<'PY'
import os
import re
import sys
import tomllib

root, ref = sys.argv[1], sys.argv[2]


def fail(message):
    print(f"check-release.sh: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_toml(relative):
    with open(os.path.join(root, relative), "rb") as handle:
        return tomllib.load(handle)


manifest = load_toml("herdr-plugin.toml")
cargo = load_toml("Cargo.toml")
version = manifest.get("version")
cargo_version = cargo.get("package", {}).get("version")
if not version or version != cargo_version:
    fail("manifest and Cargo versions differ")

with open(os.path.join(root, "CHANGELOG.md"), encoding="utf-8") as handle:
    changelog = handle.read()
heading = rf"^## \[{re.escape(version)}\] - (planned|[0-9]{{4}}-[0-9]{{2}}-[0-9]{{2}})$"
if not re.search(heading, changelog, re.MULTILINE):
    fail(f"CHANGELOG.md lacks an exact '{version}' heading (planned or dated)")

if ref and ref != f"refs/tags/v{version}":
    fail(f"tag must be refs/tags/v{version}")

# The sole install path is Herdr running this locked release build from the source checkout.
# Require exactly that one build command and nothing that fakes a binary asset.
commands = [entry.get("command") for entry in manifest.get("build") or []]
if commands != [["cargo", "build", "--locked", "--release"]]:
    fail('manifest must declare exactly one build command: ["cargo", "build", "--locked", "--release"]')

obsolete = [
    ".cargo/config.toml",
    "docs/release-evidence",
    "release/targets.txt",
    "scripts/release/check-binaries.sh",
    "scripts/release/check-targets.sh",
    "scripts/release/checksums.sh",
    "scripts/release/install.sh",
    "scripts/release/package.sh",
    "tests/shell/install-candidate.sh",
    "tests/shell/test-install.sh",
    "tests/shell/test-release.sh",
]
present = [path for path in obsolete if os.path.lexists(os.path.join(root, path))]
if present:
    fail("removed release machinery is still present: " + ", ".join(present))
PY
