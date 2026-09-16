#!/bin/sh
# Validate the tracked owner approval and version-specific native-evidence allowlist.
set -efu
PROGRAM=${0##*/}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
root=$ROOT
manifest=$ROOT/release/targets.txt
requested=
fail() { printf '%s: %s\n' "$PROGRAM" "$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
    case $1 in
        --manifest) [ "$#" -ge 2 ] || exit 2; manifest=$2; shift 2 ;;
        --root) [ "$#" -ge 2 ] || exit 2; root=$2; shift 2 ;;
        --target) [ "$#" -ge 2 ] || exit 2; requested=$2; shift 2 ;;
        *) fail "unknown argument: $1" ;;
    esac
done
[ -d "$root" ] || fail 'evidence root does not exist'
root=$(CDPATH= cd -- "$root" && pwd -P)
[ -f "$manifest" ] && [ ! -L "$manifest" ] || fail 'promotion manifest is missing or unsafe'
case $manifest in
    /*) ;;
    */*) manifest=$(CDPATH= cd -- "${manifest%/*}" && pwd -P)/${manifest##*/} ;;
    *) manifest=$PWD/$manifest ;;
esac
version=$(awk -F '"' '$1 ~ /^[[:space:]]*version[[:space:]]*=[[:space:]]*$/ { print $2; exit }' "$root/herdr-plugin.toml")
[ -n "$version" ] || fail 'plugin manifest version is missing'

git_root=
if git_root=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null); then
    git_root=$(CDPATH= cd -- "$git_root" && pwd -P)
    [ "$git_root" = "$root" ] || fail 'evidence root must be the Git checkout root'
    case $manifest in "$root"/*) manifest_relative=${manifest#"$root"/} ;; *) fail 'promotion manifest must be inside the Git checkout' ;; esac
    git -C "$root" ls-files --error-unmatch "$manifest_relative" >/dev/null 2>&1 || fail 'promotion manifest is not tracked'
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/agent-tree-targets.XXXXXX")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
approved=$work/approved
: >"$approved"
while IFS= read -r line || [ -n "$line" ]; do
    case $line in ''|'#'*) continue ;; esac
    old_ifs=$IFS; IFS='|'; set -- $line; IFS=$old_ifs
    [ "$#" -eq 3 ] || fail 'malformed promotion entry; expected TARGET|EVIDENCE_PATH|OWNER_APPROVER'
    target=$1; evidence=$2; approver=$3
    case $target in x86_64-unknown-linux-musl|aarch64-unknown-linux-musl) ;; *) fail "unsupported promoted target: $target" ;; esac
    case $evidence in
        docs/release-evidence/*.md) evidence_name=${evidence#docs/release-evidence/} ;;
        *) fail "unsafe or non-versioned evidence path for $target" ;;
    esac
    case $evidence_name in ''|*/*|.*|*..*|*[!A-Za-z0-9._-]*) fail "evidence must be one safe Markdown basename for $target" ;; esac
    case $approver in ''|*[!A-Za-z0-9_.@-]*) fail "invalid owner approver for $target" ;; esac
    grep -Fqx "$target" "$approved" && fail "duplicate promoted target: $target"
    evidence_file=$root/$evidence
    [ -f "$evidence_file" ] && [ ! -L "$evidence_file" ] || fail "tracked native evidence is missing or unsafe for $target: $evidence"
    if [ -n "$git_root" ]; then
        git -C "$root" ls-files --error-unmatch "$evidence" >/dev/null 2>&1 || fail "native evidence is not tracked for $target: $evidence"
    fi
    [ "$(grep -Fxc "target: $target" "$evidence_file" || true)" -eq 1 ] || fail "native evidence target mismatch for $target"
    [ "$(grep -Fxc "version: $version" "$evidence_file" || true)" -eq 1 ] || fail "native evidence version mismatch for $target; expected $version"
    [ "$(grep -Fxc 'native_sidebar_evidence: passed' "$evidence_file" || true)" -eq 1 ] || fail "native sidebar evidence has not passed for $target"
    [ "$(grep -Fxc "owner_approved_by: $approver" "$evidence_file" || true)" -eq 1 ] || fail "owner approval mismatch for $target"
    [ "$(grep -c '^candidate_sha256: ' "$evidence_file" || true)" -eq 1 ] || fail "candidate SHA-256 is missing or duplicated for $target"
    digest=$(awk '/^candidate_sha256: / { print substr($0, 19); exit }' "$evidence_file")
    [ "${#digest}" -eq 64 ] || fail "candidate SHA-256 is malformed for $target"
    case $digest in *[!0-9a-f]*) fail "candidate SHA-256 is malformed for $target" ;; esac
    printf '%s\n' "$target" >>"$approved"
done <"$manifest"
[ -s "$approved" ] || fail 'no targets are approved for final publication'
if [ -n "$requested" ]; then
    case $requested in x86_64-unknown-linux-musl|aarch64-unknown-linux-musl) ;; *) fail "unsupported requested target: $requested" ;; esac
    grep -Fqx "$requested" "$approved" || fail "target is not approved for final publication: $requested"
else
    cat "$approved"
fi
