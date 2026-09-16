#!/bin/sh
# Prove the release executable is a static ELF file for the named Rust target.
set -eu
PROGRAM=${0##*/}
target=
binary_dir=
READELF=${READELF:-readelf}
fail() { printf '%s: %s\n' "$PROGRAM" "$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
    case $1 in
        --target) [ "$#" -ge 2 ] || exit 2; target=$2; shift 2 ;;
        --binary-dir) [ "$#" -ge 2 ] || exit 2; binary_dir=$2; shift 2 ;;
        *) fail "unknown argument: $1" ;;
    esac
done
case $target in
    x86_64-unknown-linux-musl) expected='Advanced Micro Devices X86-64'; expected_elf=EM_X86_64 ;;
    aarch64-unknown-linux-musl) expected='AArch64'; expected_elf=EM_AARCH64 ;;
    *) fail 'unsupported or missing target' ;;
esac
[ -n "$binary_dir" ] || fail '--binary-dir is required'
command -v "$READELF" >/dev/null 2>&1 || fail "readelf is unavailable: $READELF"
for name in agent-tree; do
    binary=$binary_dir/$name
    [ -f "$binary" ] && [ ! -L "$binary" ] && [ -x "$binary" ] || fail "binary is missing, unsafe, or not executable: $binary"
    machine=$(LC_ALL=C "$READELF" -h "$binary" 2>/dev/null | awk -F: '$1 ~ /^[[:space:]]*Machine[[:space:]]*$/ { sub(/^[[:space:]]*/, "", $2); print $2; exit }')
    [ "$machine" = "$expected" ] || fail "$name target mismatch: expected $expected_elf ($expected), got ${machine:-no ELF machine}"
    if LC_ALL=C "$READELF" -d "$binary" 2>/dev/null | grep -q '(NEEDED)'; then
        fail "$name is dynamically linked for $target"
    fi
done
printf '%s\n' "$target: $expected_elf; the binary has no NEEDED entries"
