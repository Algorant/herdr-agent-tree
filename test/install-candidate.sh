#!/bin/sh
# Install one local candidate through the real download interface with its caller-pinned digest.
set -eu
PROGRAM=${0##*/}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
[ "$#" -eq 3 ] || { printf '%s\n' "usage: $PROGRAM ARCHIVE TARGET PREFIX" >&2; exit 2; }
archive=$1
target=$2
prefix=$3
[ -f "$archive" ] || { printf '%s: archive is missing: %s\n' "$PROGRAM" "$archive" >&2; exit 1; }
case $prefix in
    /*) ;;
    *) prefix=$PWD/$prefix ;;
esac
case $archive in
    /*) ;;
    */*) archive=$(CDPATH= cd -- "${archive%/*}" && pwd -P)/${archive##*/} ;;
    *) archive=$PWD/$archive ;;
esac
case $target in x86_64-unknown-linux-musl|aarch64-unknown-linux-musl) ;; *) printf '%s: unsupported target\n' "$PROGRAM" >&2; exit 1 ;; esac
work=$(mktemp -d "${TMPDIR:-/tmp}/agent-tree-candidate-install.XXXXXX")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
mkdir -p "$work/bin" "$work/home"
cat >"$work/bin/curl" <<'SH'
#!/bin/sh
set -eu
output=
while [ "$#" -gt 0 ]; do
    case $1 in --output) output=$2; shift 2 ;; --) shift 2 ;; *) shift ;; esac
done
[ -n "$output" ]
cp "$FAKE_ARCHIVE" "$output"
SH
chmod 755 "$work/bin/curl"
version=$(awk -F '"' '$1 ~ /^[[:space:]]*version[[:space:]]*=[[:space:]]*$/ { print $2; exit }' "$ROOT/herdr-plugin.toml")
digest=$(sha256sum "$archive" | awk '{print $1}')
FAKE_ARCHIVE=$archive HOME=$work/home PATH=$work/bin:/usr/bin:/bin \
    "$ROOT/scripts/install.sh" --version "$version" --target "$target" --checksum "$digest" \
    --prefix "$prefix" --no-link >/dev/null
[ -x "$prefix/$version/$target/src/agent-tree" ]
