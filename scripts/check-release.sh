#!/bin/sh
# Check source/tag consistency and inspect release assets without publishing.
set -eu
PROGRAM=${0##*/}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
assets=
targets_file=
targets_root=$ROOT
# A release ref is checked only when the caller explicitly supplies --ref. Normal push and
# pull-request jobs also export GITHUB_REF, but those branch refs are not release intent.
ref=
while [ "$#" -gt 0 ]; do
    case $1 in
        --assets) [ "$#" -ge 2 ] || exit 2; assets=$2; shift 2 ;;
        --ref) [ "$#" -ge 2 ] || exit 2; ref=$2; shift 2 ;;
        --targets-file) [ "$#" -ge 2 ] || exit 2; targets_file=$2; shift 2 ;;
        --targets-root) [ "$#" -ge 2 ] || exit 2; targets_root=$2; shift 2 ;;
        *) printf '%s: unknown argument: %s\n' "$PROGRAM" "$1" >&2; exit 2 ;;
    esac
done
fail() { printf '%s: %s\n' "$PROGRAM" "$*" >&2; exit 1; }
version=$(awk -F '"' '$1 ~ /^[[:space:]]*version[[:space:]]*=[[:space:]]*$/ { print $2; exit }' "$ROOT/herdr-plugin.toml")
cargo_version=$(awk -F '"' '/^version[[:space:]]*=/ { print $2; exit }' "$ROOT/Cargo.toml")
[ -n "$version" ] && [ "$version" = "$cargo_version" ] || fail 'manifest and Cargo versions differ'
grep -Fqx "## [$version] - planned" "$ROOT/CHANGELOG.md" || fail "CHANGELOG.md lacks exact heading: ## [$version] - planned"
if [ -n "$ref" ]; then [ "$ref" = "refs/tags/v$version" ] || fail "tag must be refs/tags/v$version"; fi
[ -z "$assets" ] || [ -d "$assets" ] || fail 'asset directory does not exist'
if [ -n "$assets" ]; then
    work=$(mktemp -d "${TMPDIR:-/tmp}/agent-tree-release-check.XXXXXX")
    trap 'rm -rf -- "$work"' EXIT HUP INT TERM
    if [ -n "$targets_file" ]; then
        "$ROOT/scripts/check-release-targets.sh" --root "$targets_root" --manifest "$targets_file" >"$work/targets"
    else
        printf '%s\n' aarch64-unknown-linux-musl x86_64-unknown-linux-musl >"$work/targets"
    fi
    expected_count=$(wc -l <"$work/targets")
    if [ -n "$targets_file" ]; then
        [ "$(find "$assets" -maxdepth 1 -type f -name '*.tar.gz' | wc -l)" -eq "$expected_count" ] || fail 'asset archive set does not match promoted targets'
        [ "$(find "$assets" -maxdepth 1 -type f -name '*.tar.gz.sha256' | wc -l)" -eq "$expected_count" ] || fail 'asset sidecar set does not match promoted targets'
    fi
    sums=$assets/agent-tree-v$version-SHA256SUMS
    [ -f "$sums" ] && [ ! -L "$sums" ] || fail 'aggregate checksum file is missing or unsafe'
    LC_ALL=C sort -c -k2,2 "$sums" || fail 'aggregate checksum names are not sorted'
    [ "$(wc -l <"$sums")" -eq "$expected_count" ] || fail "aggregate checksum file must contain $expected_count lines"
    while IFS= read -r target; do
        archive=agent-tree-v$version-$target.tar.gz
        sidecar=$assets/$archive.sha256
        [ -f "$assets/$archive" ] && [ ! -L "$assets/$archive" ] && [ -f "$sidecar" ] && [ ! -L "$sidecar" ] || fail "missing or unsafe target assets for $target"
        digest=$(sha256sum "$assets/$archive" | awk '{print $1}')
        [ "$(wc -l <"$sidecar")" -eq 1 ] && grep -Fqx "$digest  $archive" "$sidecar" || fail "invalid sidecar for $target"
        (cd "$assets" && sha256sum -c "$archive.sha256") || fail "sidecar verification failed for $target"
        grep -Fqx "$digest  $archive" "$sums" || fail "aggregate checksum differs for $target"
        top=$archive; top=${top%.tar.gz}
        first=$(tar -tzf "$assets/$archive" | head -1)
        [ "$first" = "$top/" ] || fail "archive has wrong top directory: $target"
        tar -tzf "$assets/$archive" | awk -v top="$top/" 'index($0, top) != 1 || $0 ~ /(^|\/)\.\.\// { exit 1 }' || fail "archive has unsafe members: $target"
    done <"$work/targets"
fi
