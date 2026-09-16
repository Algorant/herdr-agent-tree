#!/bin/sh
# Install one caller-pinned agent-tree release without elevated privileges.
#
# Downloads over HTTPS only, verifies the SHA-256 the caller pins, enforces a strict
# archive allowlist, installs atomically into a versioned directory, and registers the
# plugin disabled. It never edits Herdr configuration and never publishes anything.
set -eu

PROGRAM=${0##*/}
REPOSITORY_URL=https://github.com/Algorant/herdr-agent-tree
PLUGIN_ID=agent-tree

fail() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

usage() {
    cat >&2 <<'USAGE'
usage: scripts/install.sh --version V --checksum SHA256 [--target T]
                          [--prefix DIR] [--herdr PATH] [--no-link]
USAGE
    exit 2
}

version=
checksum=
target=
prefix=
herdr_path=
herdr_was_set=false
link=true
while [ "$#" -gt 0 ]; do
    case $1 in
        --version|--checksum|--target|--prefix|--herdr)
            [ "$#" -ge 2 ] || usage
            case $1 in
                --version) version=$2 ;;
                --checksum) checksum=$2 ;;
                --target) target=$2 ;;
                --prefix) prefix=$2 ;;
                --herdr) herdr_path=$2; herdr_was_set=true ;;
            esac
            shift 2
            ;;
        --no-link) link=false; shift ;;
        --help|-h) usage ;;
        *) usage ;;
    esac
done

[ -n "$version" ] || fail '--version is required'
[ "$version" != latest ] || fail 'latest is not a version; pin an exact release version'
case $version in
    *[!0-9A-Za-z.+-]*|.*|-*|+*) fail 'version has an unsafe format' ;;
esac
release_core=${version%%[-+]*}
major=${release_core%%.*}
release_tail=${release_core#*.}
minor=${release_tail%%.*}
patch=${release_tail#*.}
[ "$release_core" != "$release_tail" ] && [ "$release_tail" != "$patch" ] || fail 'version must contain three numeric release components'
for component in "$major" "$minor" "$patch"; do
    case $component in ''|*[!0-9]*|*.*) fail 'version must contain three numeric release components' ;; esac
done
[ "${#checksum}" -eq 64 ] || fail '--checksum must be 64 lowercase hexadecimal characters'
case $checksum in
    *[!0-9a-f]*) fail '--checksum must be 64 lowercase hexadecimal characters' ;;
esac

for tool in curl sha256sum tar mktemp mkdir mv rm awk grep chmod stat; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done
tar --version 2>/dev/null | grep -F 'GNU tar' >/dev/null || fail 'GNU tar is required for strict archive validation'

if [ -z "$target" ]; then
    command -v uname >/dev/null 2>&1 || fail 'required tool is unavailable: uname'
    [ "$(uname -s)" = Linux ] || fail 'automatic target detection supports Linux only'
    case $(uname -m) in
        x86_64) target=x86_64-unknown-linux-musl ;;
        aarch64|arm64) target=aarch64-unknown-linux-musl ;;
        *) fail "unsupported Linux architecture: $(uname -m)" ;;
    esac
fi
case $target in
    x86_64-unknown-linux-musl|aarch64-unknown-linux-musl) ;;
    *) fail "unsupported target: $target" ;;
esac

if [ -z "$prefix" ]; then
    if [ -n "${XDG_DATA_HOME:-}" ]; then
        prefix=$XDG_DATA_HOME/herdr-agent-tree
    else
        [ -n "${HOME:-}" ] || fail 'HOME is required when --prefix and XDG_DATA_HOME are unset'
        prefix=$HOME/.local/share/herdr-agent-tree
    fi
fi
case $prefix in
    /*) ;;
    *) fail '--prefix must be an absolute path' ;;
esac
case /$prefix/ in
    */../*|*/./*) fail '--prefix must not contain dot path components' ;;
esac
case $prefix in
    /usr|/usr/*) fail '--prefix must not write under /usr' ;;
esac

archive=$PLUGIN_ID-v$version-$target.tar.gz
top=$PLUGIN_ID-v$version-$target
url=$REPOSITORY_URL/releases/download/v$version/$archive
parent=$prefix/$version
final=$parent/$target
work=
stage=
cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    [ -z "$stage" ] || rm -rf -- "$stage"
    [ -z "$work" ] || rm -rf -- "$work"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

work=$(mktemp -d "${TMPDIR:-/tmp}/agent-tree-install.XXXXXX") || fail 'cannot create download workspace'
printf '%s\n' "Downloading $url" >&2
curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --output "$work/$archive" -- "$url" \
    || fail 'release archive download failed'
actual=$(sha256sum "$work/$archive") || fail 'cannot hash downloaded archive'
actual=${actual%% *}
[ "$actual" = "$checksum" ] || fail 'downloaded archive SHA-256 does not match the caller-pinned checksum'

listing=$work/archive.list
LC_ALL=C tar --list --verbose --numeric-owner --quoting-style=escape --file "$work/$archive" >"$listing" \
    || fail 'release archive is malformed or unreadable'
awk -v top="$top" '
BEGIN {
  expected[top "/"] = "drwxr-xr-x";
  expected[top "/src/"] = "drwxr-xr-x";
  expected[top "/herdr-plugin.toml"] = "-rw-r--r--";
  expected[top "/README.md"] = "-rw-r--r--";
  expected[top "/CHANGELOG.md"] = "-rw-r--r--";
  expected[top "/LICENSE"] = "-rw-r--r--";
  expected[top "/src/agent-tree"] = "-rwxr-xr-x";
}
{
  mode=$1; name=$6;
  if (NF < 6 || !(name in expected) || mode != expected[name] || seen[name]++) exit 1;
}
END {
  if (NR != 7) exit 1;
  for (name in expected) {
    if (!seen[name]) exit 1;
  }
}
' "$listing" || fail 'release archive members, types, modes, or paths violate the allowlist'

[ ! -e "$final" ] || fail "version is already installed: $final"
mkdir -p -- "$parent" || fail 'cannot create installation parent directory'
stage=$(mktemp -d "$parent/.install-$version-$target.XXXXXX") || fail 'cannot create sibling staging directory'
tar --extract --gzip --file "$work/$archive" --directory "$stage" --strip-components=1 --no-same-owner \
    || fail 'release archive extraction failed'

# GNU tar can apply the caller's umask while extracting. Normalize and verify the
# complete frozen tree so the committed plugin has deterministic modes.
directories='. src'
executables='src/agent-tree'
ordinary_files='herdr-plugin.toml README.md CHANGELOG.md LICENSE'
for directory in $directories; do
    [ -d "$stage/$directory" ] && [ ! -L "$stage/$directory" ] || fail "staged directory is invalid: $directory"
done
for executable in $executables; do
    [ -f "$stage/$executable" ] && [ ! -L "$stage/$executable" ] || fail "staged executable is invalid: $executable"
done
for ordinary_file in $ordinary_files; do
    [ -f "$stage/$ordinary_file" ] && [ ! -L "$stage/$ordinary_file" ] || fail "staged ordinary file is invalid: $ordinary_file"
done
chmod 755 "$stage" "$stage/src" "$stage/src/agent-tree" \
    || fail 'cannot normalize staged executable and directory modes'
for ordinary_file in $ordinary_files; do
    chmod 644 "$stage/$ordinary_file" || fail "cannot normalize staged ordinary file mode: $ordinary_file"
done
for directory in $directories; do
    [ "$(stat -c '%a' "$stage/$directory")" = 755 ] || fail "staged directory mode is invalid: $directory"
done
for executable in $executables; do
    [ -x "$stage/$executable" ] && [ "$(stat -c '%a' "$stage/$executable")" = 755 ] \
        || fail "staged executable mode is invalid: $executable"
done
for ordinary_file in $ordinary_files; do
    [ "$(stat -c '%a' "$stage/$ordinary_file")" = 644 ] || fail "staged ordinary file mode is invalid: $ordinary_file"
done
[ "$(awk -F '"' '$1 ~ /^[[:space:]]*id[[:space:]]*=[[:space:]]*$/ { print $2; exit }' "$stage/herdr-plugin.toml")" = "$PLUGIN_ID" ] \
    || fail 'staged manifest plugin identity is invalid'
[ "$(awk -F '"' '$1 ~ /^[[:space:]]*version[[:space:]]*=[[:space:]]*$/ { print $2; exit }' "$stage/herdr-plugin.toml")" = "$version" ] \
    || fail 'staged manifest version does not match --version'
for action in start apply clear toggle; do
    grep -Fqx "command = [\"./src/agent-tree\", \"$action\"]" "$stage/herdr-plugin.toml" \
        || fail "staged manifest is missing the '$action' command"
done

mv -T -n -- "$stage" "$final" || fail 'atomic installation commit failed'
if [ -e "$stage" ]; then
    fail "version appeared during installation and was not overwritten: $final"
fi
stage=
printf '%s\n' "Installed verified plugin at $final" >&2

if [ "$link" = true ]; then
    if [ "$herdr_was_set" = true ]; then
        [ -x "$herdr_path" ] || fail "--herdr is not executable: $herdr_path"
    elif [ -n "${HERDR_BIN_PATH:-}" ]; then
        herdr_path=$HERDR_BIN_PATH
        [ -x "$herdr_path" ] || fail "HERDR_BIN_PATH is not executable: $herdr_path"
    elif command -v herdr >/dev/null 2>&1; then
        herdr_path=$(command -v herdr)
    fi
    if [ -n "$herdr_path" ]; then
        "$herdr_path" plugin link "$final" --disabled || fail 'plugin was installed but disabled registration failed'
    else
        printf '%s\n' "Herdr was not found; link later with: herdr plugin link $final --disabled" >&2
    fi
fi

printf '%s\n' 'Activate manually; this installer never edits Herdr configuration:' >&2
printf '%s\n' '  1. Add to your Herdr config and reload with `herdr server reload-config`:' >&2
printf '%s\n' '       [ui.sidebar.agents]' >&2
printf '%s\n' '       rows = [["state_icon", "$agent_tree_row", "terminal_title_stripped"]]' >&2
printf '%s\n' "  2. herdr plugin enable $PLUGIN_ID" >&2
printf '%s\n' "  3. herdr plugin action invoke $PLUGIN_ID.apply" >&2
