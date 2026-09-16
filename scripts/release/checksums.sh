#!/bin/sh
set -eu
PROGRAM=${0##*/}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
directory=$ROOT/target/release-assets
targets_file=
targets_root=$ROOT
if [ "$#" -gt 0 ] && [ "${1#--}" = "$1" ]; then directory=$1; shift; fi
while [ "$#" -gt 0 ]; do
    case $1 in
        --targets-file) [ "$#" -ge 2 ] || exit 2; targets_file=$2; shift 2 ;;
        --targets-root) [ "$#" -ge 2 ] || exit 2; targets_root=$2; shift 2 ;;
        *) printf '%s: unknown argument: %s\n' "$PROGRAM" "$1" >&2; exit 2 ;; esac
done
[ -d "$directory" ] || { printf '%s: asset directory does not exist\n' "$PROGRAM" >&2; exit 1; }
version=$(awk -F '"' '$1 ~ /^[[:space:]]*version[[:space:]]*=[[:space:]]*$/ { print $2; exit }' "$ROOT/herdr-plugin.toml")
output=$directory/agent-tree-v$version-SHA256SUMS
work=$(mktemp -d "${TMPDIR:-/tmp}/agent-tree-sums.XXXXXX")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
if [ -n "$targets_file" ]; then
    "$ROOT/scripts/release/check-targets.sh" --root "$targets_root" --manifest "$targets_file" >"$work/targets"
else
    printf '%s\n' aarch64-unknown-linux-musl x86_64-unknown-linux-musl >"$work/targets"
fi
: >"$work/sums"
while IFS= read -r target; do
    archive=agent-tree-v$version-$target.tar.gz
    [ -f "$directory/$archive" ] && [ ! -L "$directory/$archive" ] || { printf '%s: missing or unsafe archive: %s\n' "$PROGRAM" "$archive" >&2; exit 1; }
    sha256sum "$directory/$archive" | awk -v name="$archive" '{ print $1 "  " name }' >>"$work/sums"
done <"$work/targets"
LC_ALL=C sort -k2,2 "$work/sums" >"$output"
printf '%s\n' "$output"
