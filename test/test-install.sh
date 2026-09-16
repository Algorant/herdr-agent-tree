#!/bin/sh
# Hermetic installer and local-stage acceptance tests. No real Herdr or user path is used.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
INSTALL=$ROOT/scripts/install.sh
STAGE=$ROOT/scripts/stage-local.sh
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/agent-tree-tests.XXXXXX")
trap 'rm -rf -- "$SANDBOX"' EXIT HUP INT TERM
PASS=0

pass() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
assert_file() { [ -f "$1" ] || fail "missing file: $1"; }
assert_absent() { [ ! -e "$1" ] || fail "unexpected path: $1"; }
assert_contains() { grep -F "$2" "$1" >/dev/null || fail "missing '$2' in $1"; }
assert_mode() { [ "$(stat -c '%a' "$2")" = "$1" ] || fail "wrong mode for $2"; }

make_curl() {
    bindir=$1
    mkdir -p "$bindir"
    cat >"$bindir/curl" <<'SH'
#!/bin/sh
set -eu
[ "${FAKE_CURL_FAIL:-0}" = 0 ] || exit 22
if [ -n "${FAKE_CURL_ARGS_LOG:-}" ]; then
    printf '%s\n' "$@" >"$FAKE_CURL_ARGS_LOG"
fi
output=
url=
while [ "$#" -gt 0 ]; do
    case $1 in
        --output) output=$2; shift 2 ;;
        --) shift; url=$1; shift ;;
        *) shift ;;
    esac
done
[ -n "$output" ] && [ -n "$url" ]
printf '%s\n' "$url" >"$FAKE_URL_LOG"
cp "$FAKE_ARCHIVE" "$output"
SH
    chmod 755 "$bindir/curl"
}

make_herdr() {
    path=$1
    cat >"$path" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$FAKE_HERDR_LOG"
SH
    chmod 755 "$path"
}

make_archive() {
    destination=$1
    version=$2
    target=$3
    variant=${4:-good}
    tree=$SANDBOX/tree-$version-$target-$$
    top=agent-tree-v$version-$target
    rm -rf "$tree"
    mkdir -p "$tree/$top/src"
    cp "$ROOT/herdr-plugin.toml" "$tree/$top/herdr-plugin.toml"
    awk -v version="$version" 'BEGIN { changed=0 } /^version = / { print "version = \"" version "\""; changed=1; next } { print } END { if (!changed) exit 1 }' \
        "$tree/$top/herdr-plugin.toml" >"$tree/manifest" && mv "$tree/manifest" "$tree/$top/herdr-plugin.toml"
    cp /bin/true "$tree/$top/src/agent-tree"
    for file in README.md CHANGELOG.md LICENSE; do cp "$ROOT/$file" "$tree/$top/$file"; done
    chmod 755 "$tree/$top" "$tree/$top/src" "$tree/$top/src/agent-tree"
    find "$tree/$top" -type f ! -path '*/src/agent-tree' -exec chmod 644 {} +
    case $variant in
        good) ;;
        link) rm "$tree/$top/README.md"; ln -s CHANGELOG.md "$tree/$top/README.md" ;;
        mode) chmod 0666 "$tree/$top/README.md" ;;
        unexpected) printf 'bad\n' >"$tree/$top/UNEXPECTED"; chmod 644 "$tree/$top/UNEXPECTED" ;;
    esac
    case $variant in
        absolute)
            (cd "$tree" && tar --sort=name --owner=0 --group=0 --numeric-owner --transform='s,^,/,S' -czf "$destination" "$top") 2>/dev/null ;;
        traversal)
            (cd "$tree" && tar --sort=name --owner=0 --group=0 --numeric-owner --transform='s,^,../,S' -czf "$destination" "$top") ;;
        device)
            tar --owner=0 --group=0 --numeric-owner -czf "$destination" /dev/null 2>/dev/null ;;
        duplicate)
            raw=$SANDBOX/duplicate.tar
            (cd "$tree" && tar --sort=name --owner=0 --group=0 --numeric-owner -cf "$raw" "$top" && tar --owner=0 --group=0 --numeric-owner -rf "$raw" "$top/README.md")
            gzip -c "$raw" >"$destination" ;;
        *) (cd "$tree" && tar --sort=name --owner=0 --group=0 --numeric-owner -czf "$destination" "$top") ;;
    esac
    rm -rf "$tree"
}

digest() { sha256sum "$1" | awk '{print $1}'; }
run_install() {
    case_dir=$1; archive=$2; version=$3; shift 3
    mkdir -p "$case_dir/bin" "$case_dir/home" "$case_dir/tmp"
    make_curl "$case_dir/bin"
    FAKE_ARCHIVE=$archive FAKE_URL_LOG=$case_dir/url FAKE_CURL_ARGS_LOG=$case_dir/curl-args HOME=$case_dir/home XDG_DATA_HOME=$case_dir/data TMPDIR=$case_dir/tmp \
        PATH=$case_dir/bin:/usr/bin:/bin "$INSTALL" --version "$version" --checksum "$(digest "$archive")" "$@"
}
expect_failure() {
    name=$1; shift
    if "$@" >"$SANDBOX/failure.out" 2>"$SANDBOX/failure.err"; then fail "$name unexpectedly succeeded"; fi
    pass "$name"
}

TARGET=x86_64-unknown-linux-musl
A=$SANDBOX/good.tar.gz
make_archive "$A" 0.1.0 "$TARGET" good
C=$SANDBOX/success
(umask 077; run_install "$C" "$A" 0.1.0 --target "$TARGET" --prefix "$C/prefix" --no-link >/dev/null)
FINAL=$C/prefix/0.1.0/$TARGET
assert_file "$FINAL/herdr-plugin.toml"
for directory in "$FINAL" "$FINAL/src"; do assert_mode 755 "$directory"; done
assert_mode 755 "$FINAL/src/agent-tree"
for ordinary_file in "$FINAL/herdr-plugin.toml" "$FINAL/README.md" "$FINAL/CHANGELOG.md" "$FINAL/LICENSE"; do
    assert_mode 644 "$ordinary_file"
done
assert_contains "$C/url" "https://github.com/Algorant/herdr-agent-tree/releases/download/v0.1.0/agent-tree-v0.1.0-$TARGET.tar.gz"
awk '
NR == 1 { ok = ($0 == "--fail") }
NR == 2 { ok = ok && ($0 == "--location") }
NR == 3 { ok = ok && ($0 == "--proto") }
NR == 4 { ok = ok && ($0 == "=https") }
NR == 5 { ok = ok && ($0 == "--proto-redir") }
NR == 6 { ok = ok && ($0 == "=https") }
NR == 7 { ok = ok && ($0 == "--tlsv1.2") }
NR == 8 { ok = ok && ($0 == "--output") }
NR == 10 { ok = ok && ($0 == "--") }
NR == 11 { ok = ok && ($0 ~ /^https:\/\/github\.com\/Algorant\/herdr-agent-tree\/releases\/download\/v0\.1\.0\//) }
END { exit !(ok && NR == 11) }
' "$C/curl-args" || fail 'curl security argv differs'
pass 'HTTPS-only curl argv and deterministic modes survive umask 077'

for pair in 'x86_64 x86_64-unknown-linux-musl' 'aarch64 aarch64-unknown-linux-musl'; do
    set -- $pair; arch=$1; mapped=$2
    archive=$SANDBOX/$arch.tar.gz; make_archive "$archive" 0.1.0 "$mapped" good
    case_dir=$SANDBOX/detect-$arch; mkdir -p "$case_dir/bin"
    make_curl "$case_dir/bin"
    cat >"$case_dir/bin/uname" <<SH
#!/bin/sh
[ "\$1" = -s ] && printf '%s\n' Linux || printf '%s\n' $arch
SH
    chmod 755 "$case_dir/bin/uname"
    FAKE_ARCHIVE=$archive FAKE_URL_LOG=$case_dir/url HOME=$case_dir PATH=$case_dir/bin:/usr/bin:/bin \
        "$INSTALL" --version 0.1.0 --checksum "$(digest "$archive")" --prefix "$case_dir/prefix" --no-link >/dev/null
    assert_file "$case_dir/prefix/0.1.0/$mapped/herdr-plugin.toml"
done
pass 'automatic architecture mapping covers x86_64 and aarch64'

expect_failure 'unsupported explicit target is rejected before download' \
    env HOME="$SANDBOX" PATH=/usr/bin:/bin "$INSTALL" --version 0.1.0 --checksum "$(digest "$A")" --target riscv64-unknown-linux-musl --prefix "$SANDBOX/nope" --no-link
expect_failure 'system prefix and path traversal are rejected' \
    env HOME="$SANDBOX" PATH=/usr/bin:/bin "$INSTALL" --version 0.1.0 --checksum "$(digest "$A")" --target "$TARGET" --prefix /tmp/../usr/local --no-link

MISSING=$SANDBOX/missing; mkdir -p "$MISSING"
for tool in sha256sum tar mktemp mkdir mv rm awk grep chmod stat; do ln -s "$(command -v "$tool")" "$MISSING/$tool"; done
expect_failure 'missing download tool fails actionably' env PATH="$MISSING" /bin/sh "$INSTALL" --version 0.1.0 --checksum "$(digest "$A")" --target "$TARGET" --prefix "$SANDBOX/missing-prefix" --no-link

N=$SANDBOX/network; mkdir -p "$N/bin"; make_curl "$N/bin"
expect_failure 'network and HTTP download errors preserve user state' env FAKE_CURL_FAIL=1 FAKE_ARCHIVE="$A" FAKE_URL_LOG="$N/url" HOME="$N" PATH="$N/bin:/usr/bin:/bin" "$INSTALL" --version 0.1.0 --checksum "$(digest "$A")" --target "$TARGET" --prefix "$N/prefix" --no-link
assert_absent "$N/prefix/0.1.0/$TARGET"

expect_failure 'malformed uppercase digest is rejected' env HOME="$SANDBOX" PATH=/usr/bin:/bin "$INSTALL" --version 0.1.0 --checksum ABCDEF --target "$TARGET" --prefix "$SANDBOX/bad-digest" --no-link
MM=$SANDBOX/mismatch; mkdir -p "$MM/bin"; make_curl "$MM/bin"
expect_failure 'caller-pinned checksum mismatch is rejected' env FAKE_ARCHIVE="$A" FAKE_URL_LOG="$MM/url" HOME="$MM" PATH="$MM/bin:/usr/bin:/bin" "$INSTALL" --version 0.1.0 --checksum 0000000000000000000000000000000000000000000000000000000000000000 --target "$TARGET" --prefix "$MM/prefix" --no-link

for variant in absolute traversal link device duplicate mode unexpected; do
    archive=$SANDBOX/$variant.tar.gz
    make_archive "$archive" 0.1.0 "$TARGET" "$variant"
    case_dir=$SANDBOX/malicious-$variant
    expect_failure "malicious archive is rejected: $variant" run_install "$case_dir" "$archive" 0.1.0 --target "$TARGET" --prefix "$case_dir/prefix" --no-link
    assert_absent "$case_dir/prefix/0.1.0/$TARGET"
    if [ -d "$case_dir/prefix/0.1.0" ]; then
        count=$(find "$case_dir/prefix/0.1.0" -name '.install-*' | wc -l)
        [ "$count" -eq 0 ] || fail "partial staging remains for $variant"
    fi
done

P=$SANDBOX/partial; mkdir -p "$P/bin"; make_curl "$P/bin"
REAL_TAR=$(command -v tar)
cat >"$P/bin/tar" <<'SH'
#!/bin/sh
set -eu
extract=false
directory=
previous=
for argument in "$@"; do
    [ "$previous" = --directory ] && directory=$argument
    [ "$argument" = --extract ] && extract=true
    previous=$argument
done
if [ "$extract" = true ]; then
    printf 'partial\n' >"$directory/partial"
    exit 2
fi
exec "$REAL_TAR" "$@"
SH
chmod 755 "$P/bin/tar"
expect_failure 'failed extraction cleans the sibling partial stage' env REAL_TAR="$REAL_TAR" FAKE_ARCHIVE="$A" FAKE_URL_LOG="$P/url" HOME="$P" PATH="$P/bin:/usr/bin:/bin" "$INSTALL" --version 0.1.0 --checksum "$(digest "$A")" --target "$TARGET" --prefix "$P/prefix" --no-link
assert_absent "$P/prefix/0.1.0/$TARGET"
[ "$(find "$P/prefix/0.1.0" -name '.install-*' 2>/dev/null | wc -l)" -eq 0 ] || fail 'partial extraction stage remains'

ID=$SANDBOX/idempotent
run_install "$ID" "$A" 0.1.0 --target "$TARGET" --prefix "$ID/prefix" --no-link >/dev/null
marker=$(sha256sum "$ID/prefix/0.1.0/$TARGET/herdr-plugin.toml")
expect_failure 'existing version is never overwritten' run_install "$ID" "$A" 0.1.0 --target "$TARGET" --prefix "$ID/prefix" --no-link
[ "$(sha256sum "$ID/prefix/0.1.0/$TARGET/herdr-plugin.toml")" = "$marker" ] || fail 'existing install changed'

UP=$SANDBOX/upgrade; B=$SANDBOX/good-0.2.0.tar.gz
make_archive "$B" 0.2.0 "$TARGET" good
run_install "$UP" "$A" 0.1.0 --target "$TARGET" --prefix "$UP/prefix" --no-link >/dev/null
run_install "$UP" "$B" 0.2.0 --target "$TARGET" --prefix "$UP/prefix" --no-link >/dev/null
assert_file "$UP/prefix/0.1.0/$TARGET/herdr-plugin.toml"
assert_file "$UP/prefix/0.2.0/$TARGET/herdr-plugin.toml"
pass 'upgrade and rollback versions coexist without deletion or current symlink'

L=$SANDBOX/link; mkdir -p "$L"; make_herdr "$L/herdr"
mkdir -p "$L/direct/bin"; make_curl "$L/direct/bin"
FAKE_ARCHIVE=$A FAKE_URL_LOG=$L/direct/url FAKE_HERDR_LOG=$L/herdr-log HOME=$L/direct PATH=$L/direct/bin:/usr/bin:/bin \
    "$INSTALL" --version 0.1.0 --checksum "$(digest "$A")" --target "$TARGET" --prefix "$L/direct-prefix" --herdr "$L/herdr" >/dev/null
printf '%s\n' plugin link "$L/direct-prefix/0.1.0/$TARGET" --disabled >"$L/expected"
cmp -s "$L/expected" "$L/herdr-log" || fail 'disabled link argv differs'
pass 'registration occurs only after commit with exact disabled argv'

NL=$SANDBOX/no-link; make_herdr "$NL-herdr"
mkdir -p "$NL/bin"; make_curl "$NL/bin"
FAKE_ARCHIVE=$A FAKE_URL_LOG=$NL/url FAKE_HERDR_LOG=$NL/herdr-log HERDR_BIN_PATH=$NL-herdr HOME=$NL PATH=$NL/bin:/usr/bin:/bin \
    "$INSTALL" --version 0.1.0 --checksum "$(digest "$A")" --target "$TARGET" --prefix "$NL/prefix" --no-link >/dev/null
assert_absent "$NL/herdr-log"
pass '--no-link never invokes Herdr'

diagnostic=$SANDBOX/agent-tree.err
if env AGENT_TREE_NATIVE_BIN=/definitely/missing "$ROOT/src/agent-tree" 2>"$diagnostic"; then fail 'missing native launcher succeeded'; fi
assert_contains "$diagnostic" 'run cargo build --locked --release'
pass 'source launcher fails with actionable native build guidance'

S=$SANDBOX/stage; mkdir -p "$S/target/debug"
cp /bin/true "$S/target/debug/agent-tree"
before=$(sha256sum "$ROOT/src/agent-tree")
CARGO_TARGET_DIR=$S/target "$STAGE" --output "$S/target/plugin" >/dev/null
assert_file "$S/target/plugin/src/agent-tree"
assert_file "$S/target/plugin/LICENSE"
[ "$(find "$S/target/plugin" -type f | wc -l)" -eq 5 ] || fail 'local stage file allowlist changed'
[ "$(sha256sum "$ROOT/src/agent-tree")" = "$before" ] || fail 'tracked launcher changed'
CARGO_TARGET_DIR=$S/target "$STAGE" --output "$S/target/plugin" --force >/dev/null
mkdir -p "$S/victim"; printf 'safe\n' >"$S/victim/marker"
expect_failure 'local stage rejects output traversal outside the target root' env CARGO_TARGET_DIR="$S/target" "$STAGE" --output "$S/target/../victim" --force
assert_contains "$S/victim/marker" safe
pass 'local stage is complete, repeatable, and does not mutate source or user state'

printf '1..%d\n' "$PASS"
