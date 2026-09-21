#!/bin/sh
# Hermetic local staging and source-launcher acceptance tests. No user state is touched.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
STAGE=$ROOT/scripts/stage-local.sh
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/agent-tree-stage-local.XXXXXX")
trap 'rm -rf -- "$SANDBOX"' EXIT HUP INT TERM
PASS=0

pass() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
assert_file() { [ -f "$1" ] || fail "missing file: $1"; }
assert_contains() { grep -F "$2" "$1" >/dev/null || fail "missing '$2' in $1"; }
expect_failure() { name=$1; shift; if "$@" >"$SANDBOX/fail.out" 2>"$SANDBOX/fail.err"; then fail "$name unexpectedly succeeded"; fi; pass "$name"; }

# The tracked source launcher is the manifest entrypoint. Without a build it must fail with
# actionable guidance instead of pretending to run.
diagnostic=$SANDBOX/agent-tree.err
if env AGENT_TREE_NATIVE_BIN=/definitely/missing "$ROOT/src/agent-tree" 2>"$diagnostic"; then
    fail 'missing native launcher succeeded'
fi
assert_contains "$diagnostic" 'run cargo build --locked --release'
pass 'source launcher fails with actionable native build guidance'

# stage-local.sh writes a complete plugin root under the Cargo target directory without
# touching the source checkout or any user path.
S=$SANDBOX/stage
mkdir -p "$S/target/debug"
cp /bin/true "$S/target/debug/agent-tree"
before=$(sha256sum "$ROOT/src/agent-tree")
CARGO_TARGET_DIR=$S/target "$STAGE" --output "$S/target/plugin" >/dev/null
assert_file "$S/target/plugin/src/agent-tree"
assert_file "$S/target/plugin/LICENSE"
[ "$(find "$S/target/plugin" -type f | wc -l)" -eq 5 ] || fail 'local stage file allowlist changed'
[ "$(sha256sum "$ROOT/src/agent-tree")" = "$before" ] || fail 'tracked launcher changed'
CARGO_TARGET_DIR=$S/target "$STAGE" --output "$S/target/plugin" --force >/dev/null
mkdir -p "$S/victim"
printf 'safe\n' >"$S/victim/marker"
expect_failure 'local stage rejects output traversal outside the target root' \
    env CARGO_TARGET_DIR="$S/target" "$STAGE" --output "$S/target/../victim" --force
assert_contains "$S/victim/marker" safe
pass 'local stage is complete, repeatable, and does not mutate source or user state'

printf '1..%d\n' "$PASS"
