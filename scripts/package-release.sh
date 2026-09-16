#!/bin/sh
# Build one deterministic candidate or owner-gated final release archive.
set -eu

PROGRAM=${0##*/}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
source=$ROOT
mode=candidate
target=
binary_dir=
output=$ROOT/target/release-assets
promotion=
epoch=${SOURCE_DATE_EPOCH:-}

fail() { printf '%s: %s\n' "$PROGRAM" "$*" >&2; exit 1; }
usage() {
    printf '%s\n' 'usage: scripts/package-release.sh --target T --binary-dir DIR [--output DIR] [--source DIR] [--mode candidate|final] [--promotion FILE]' >&2
    exit 2
}
while [ "$#" -gt 0 ]; do
    case $1 in
        --target|--binary-dir|--output|--source|--mode|--promotion)
            [ "$#" -ge 2 ] || usage
            case $1 in
                --target) target=$2 ;;
                --binary-dir) binary_dir=$2 ;;
                --output) output=$2 ;;
                --source) source=$2 ;;
                --mode) mode=$2 ;;
                --promotion) promotion=$2 ;;
            esac
            shift 2 ;;
        --help|-h) usage ;;
        *) usage ;;
    esac
done
case $target in x86_64-unknown-linux-musl|aarch64-unknown-linux-musl) ;; *) fail 'unsupported or missing release target' ;; esac
case $mode in candidate|final) ;; *) fail 'mode must be candidate or final' ;; esac
[ -n "$binary_dir" ] || fail '--binary-dir is required'
[ -d "$source" ] || fail 'source directory does not exist'
for tool in awk date gzip mktemp sha256sum tar; do command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"; done
tar --version 2>/dev/null | grep -F 'GNU tar' >/dev/null || fail 'GNU tar is required'

version=$(awk -F '"' '$1 ~ /^[[:space:]]*version[[:space:]]*=[[:space:]]*$/ { print $2; exit }' "$source/herdr-plugin.toml")
cargo_version=$(awk -F '"' '/^version[[:space:]]*=/ { print $2; exit }' "$source/Cargo.toml")
[ -n "$version" ] && [ "$version" = "$cargo_version" ] || fail 'manifest and Cargo versions differ'
grep -Fqx "## [$version] - planned" "$source/CHANGELOG.md" || fail 'changelog has no exact planned version heading'
case $version in *[!0-9.]*|.*|*.|*..*) fail 'manifest version is not numeric SemVer' ;; esac
[ "$(printf '%s' "$version" | awk -F. '{print NF}')" -eq 3 ] || fail 'manifest version must have three components'

# agent-tree commits an MIT LICENSE from the start, so candidate and final archives both
# include it. This is a deliberate deviation from herdr-notifs-plus, whose candidate mode
# rejected the project LICENSE until the owner selected one.
for path in herdr-plugin.toml Cargo.toml README.md CHANGELOG.md LICENSE; do
    [ -f "$source/$path" ] && [ ! -L "$source/$path" ] || fail "required source file is missing or not regular: $path"
done

if [ "$mode" = final ]; then
    [ -n "$promotion" ] || promotion=$source/release-targets.txt
    "$ROOT/scripts/check-release-targets.sh" --root "$source" --manifest "$promotion" --target "$target" >/dev/null
    [ "${GITHUB_EVENT_NAME:-}" = push ] || fail 'final mode requires an owner-triggered GitHub push event'
    [ "${GITHUB_REF:-}" = "refs/tags/v$version" ] || fail "final mode requires exact tag refs/tags/v$version"
fi

if [ -z "$epoch" ]; then
    epoch=$(git -C "$source" show -s --format=%ct HEAD 2>/dev/null) || fail 'SOURCE_DATE_EPOCH is required outside a Git checkout'
fi
case $epoch in ''|*[!0-9]*) fail 'SOURCE_DATE_EPOCH must be a non-negative integer' ;; esac
# GNU tar rejects values beyond its date parser range. Check it before staging.
date -u -d "@$epoch" +%s >/dev/null 2>&1 || fail 'SOURCE_DATE_EPOCH is outside the supported range'

"$ROOT/scripts/check-target-binaries.sh" --target "$target" --binary-dir "$binary_dir" >/dev/null

mkdir -p "$output"
output=$(CDPATH= cd -- "$output" && pwd -P)
top=agent-tree-v$version-$target
archive=$top.tar.gz
work=$(mktemp -d "${TMPDIR:-/tmp}/agent-tree-package.XXXXXX")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
stage=$work/$top
mkdir -p "$stage/src"
for file in herdr-plugin.toml README.md CHANGELOG.md LICENSE; do cp -- "$source/$file" "$stage/$file"; done
cp -- "$binary_dir/agent-tree" "$stage/src/agent-tree"
chmod 755 "$stage" "$stage/src" "$stage/src/agent-tree"
find "$stage" -type f ! -path "$stage/src/agent-tree" -exec chmod 644 {} +

rm -f -- "$output/$archive" "$output/$archive.sha256"
(
    cd "$work"
    LC_ALL=C tar --format=gnu --sort=name --owner=0 --group=0 --numeric-owner \
        --mtime="@$epoch" -cf "$work/archive.tar" "$top"
)
gzip -n -9 <"$work/archive.tar" >"$output/$archive"
digest=$(sha256sum "$output/$archive" | awk '{print $1}')
printf '%s  %s\n' "$digest" "$archive" >"$output/$archive.sha256"
printf '%s\n' "$output/$archive"
