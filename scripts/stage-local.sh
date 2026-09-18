#!/bin/sh
# Create a complete native plugin root for local development. This script never links it.
set -eu

PROGRAM=${0##*/}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TARGET_DIR=${CARGO_TARGET_DIR:-$ROOT/target}
output=$TARGET_DIR/stage-local
profile=debug
force=false

usage() {
    printf '%s\n' 'usage: scripts/stage-local.sh [--output DIR] [--profile debug|release] [--force]' >&2
    exit 2
}
while [ "$#" -gt 0 ]; do
    case $1 in
        --output)
            [ "$#" -ge 2 ] || usage
            output=$2; shift 2 ;;
        --profile)
            [ "$#" -ge 2 ] || usage
            profile=$2; shift 2 ;;
        --force) force=true; shift ;;
        --help|-h) usage ;;
        *) usage ;;
    esac
done
case $profile in debug|release) ;; *) usage ;; esac
case $TARGET_DIR in /*) ;; *) TARGET_DIR=$ROOT/$TARGET_DIR ;; esac
mkdir -p -- "$TARGET_DIR"
TARGET_DIR=$(CDPATH= cd -- "$TARGET_DIR" && pwd -P)
case $TARGET_DIR in
    "$ROOT"/*) [ "$TARGET_DIR" = "$ROOT/target" ] || { printf '%s: Cargo target directory must not overlap tracked source\n' "$PROGRAM" >&2; exit 1; } ;;
esac
case $output in /*) ;; *) output=$ROOT/$output ;; esac
output_parent=${output%/*}
output_name=${output##*/}
[ -n "$output_name" ] && [ "$output_name" != . ] && [ "$output_name" != .. ] || usage
[ -d "$output_parent" ] || { printf '%s: output parent must be the Cargo target directory\n' "$PROGRAM" >&2; exit 1; }
output_parent=$(CDPATH= cd -- "$output_parent" && pwd -P)
[ "$output_parent" = "$TARGET_DIR" ] || { printf '%s: output must be a direct child of the Cargo target directory\n' "$PROGRAM" >&2; exit 1; }
output=$output_parent/$output_name
[ ! -L "$output" ] || { printf '%s: refusing symlink stage path: %s\n' "$PROGRAM" "$output" >&2; exit 1; }

hook=$TARGET_DIR/$profile/agent-tree
[ -x "$hook" ] || {
    printf '%s: native binary is unavailable: %s; run cargo build --locked --bins%s\n' \
        "$PROGRAM" "$hook" "$( [ "$profile" = release ] && printf ' --release' || : )" >&2
    exit 1
}

if [ -e "$output" ]; then
    [ "$force" = true ] || { printf '%s: stage already exists: %s (use --force)\n' "$PROGRAM" "$output" >&2; exit 1; }
    rm -rf -- "$output"
fi
mkdir -p -- "$output/src"
for file in herdr-plugin.toml README.md CHANGELOG.md LICENSE; do
    cp -- "$ROOT/$file" "$output/$file"
done
cp -- "$hook" "$output/src/agent-tree"
chmod 755 "$output/src/agent-tree"
chmod 644 "$output/herdr-plugin.toml" "$output/README.md" "$output/CHANGELOG.md" "$output/LICENSE"

id=$(awk -F '"' '$1 ~ /^[[:space:]]*id[[:space:]]*=[[:space:]]*$/ { print $2; exit }' "$output/herdr-plugin.toml")
[ "$id" = agent-tree ] || {
    printf '%s: staged manifest validation failed: wrong plugin id: %s\n' "$PROGRAM" "${id:-<none>}" >&2
    exit 1
}
for action in start apply reload clear toggle; do
    grep -Fqx "command = [\"./src/agent-tree\", \"$action\"]" "$output/herdr-plugin.toml" || {
        printf '%s: staged manifest validation failed: missing the %s command\n' "$PROGRAM" "$action" >&2
        exit 1
    }
done
printf '%s\n' "$output"
