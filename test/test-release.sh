#!/bin/sh
# Hermetic deterministic packaging and release-gate tests. Nothing is published.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PACKAGE=$ROOT/scripts/package-release.sh
CHECK=$ROOT/scripts/check-release.sh
SUMS=$ROOT/scripts/write-checksums.sh
TARGET_CHECK=$ROOT/scripts/check-target-binaries.sh
PROMOTION_CHECK=$ROOT/scripts/check-release-targets.sh
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/agent-tree-release-tests.XXXXXX")
trap 'rm -rf -- "$SANDBOX"' EXIT HUP INT TERM
PASS=0
pass() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
expect_failure() { name=$1; shift; if "$@" >"$SANDBOX/fail.out" 2>"$SANDBOX/fail.err"; then fail "$name unexpectedly succeeded"; fi; pass "$name"; }

mkdir -p "$SANDBOX/bin" "$SANDBOX/one" "$SANDBOX/two"
cp /bin/true "$SANDBOX/bin/agent-tree"
chmod 755 "$SANDBOX/bin/agent-tree"
cat >"$SANDBOX/readelf" <<'SH'
#!/bin/sh
set -eu
case $1 in
    -h) printf '  Machine:                           %s\n' "$FAKE_MACHINE" ;;
    -d) [ "${FAKE_NEEDED:-0}" = 0 ] && printf 'There is no dynamic section in this file.\n' || printf ' 0x1 (NEEDED) Shared library: [bad.so]\n' ;;
    *) exit 2 ;;
esac
SH
chmod 755 "$SANDBOX/readelf"
READELF=$SANDBOX/readelf FAKE_MACHINE='Advanced Micro Devices X86-64' "$TARGET_CHECK" --target x86_64-unknown-linux-musl --binary-dir "$SANDBOX/bin" >/dev/null
READELF=$SANDBOX/readelf FAKE_MACHINE=AArch64 "$TARGET_CHECK" --target aarch64-unknown-linux-musl --binary-dir "$SANDBOX/bin" >/dev/null
expect_failure 'target checker rejects an aarch64 machine in x86_64 assets' env READELF="$SANDBOX/readelf" FAKE_MACHINE=AArch64 "$TARGET_CHECK" --target x86_64-unknown-linux-musl --binary-dir "$SANDBOX/bin"
expect_failure 'target checker rejects dynamic NEEDED entries' env READELF="$SANDBOX/readelf" FAKE_MACHINE=AArch64 FAKE_NEEDED=1 "$TARGET_CHECK" --target aarch64-unknown-linux-musl --binary-dir "$SANDBOX/bin"
pass 'target checker maps EM_X86_64 and EM_AARCH64 to exact release targets'
EPOCH=1700000000
for output in one two; do
    for target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl; do
        machine=AArch64; [ "$target" = x86_64-unknown-linux-musl ] && machine='Advanced Micro Devices X86-64'
        READELF=$SANDBOX/readelf FAKE_MACHINE="$machine" SOURCE_DATE_EPOCH=$EPOCH "$PACKAGE" --target "$target" --binary-dir "$SANDBOX/bin" --output "$SANDBOX/$output" >/dev/null
    done
    "$SUMS" "$SANDBOX/$output" >/dev/null
    "$CHECK" --assets "$SANDBOX/$output"
done
cmp -s "$SANDBOX/one/agent-tree-v0.1.0-x86_64-unknown-linux-musl.tar.gz" "$SANDBOX/two/agent-tree-v0.1.0-x86_64-unknown-linux-musl.tar.gz" || fail 'x86-64 archives differ'
cmp -s "$SANDBOX/one/agent-tree-v0.1.0-aarch64-unknown-linux-musl.tar.gz" "$SANDBOX/two/agent-tree-v0.1.0-aarch64-unknown-linux-musl.tar.gz" || fail 'aarch64 archives differ'
pass 'two clean candidate packages are byte-identical for both targets'

for target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl; do
    archive=$SANDBOX/one/agent-tree-v0.1.0-$target.tar.gz
    listing=$SANDBOX/$target.list
    TZ=UTC tar --numeric-owner --full-time -tvzf "$archive" >"$listing"
    expected_time=$(TZ=UTC date -d "@$EPOCH" '+%Y-%m-%d %H:%M:%S')
    awk -v expected_time="$expected_time" '
      $2 != "0/0" { exit 1 }
      $4 " " $5 != expected_time { exit 1 }
      $1 ~ /^d/ && $1 != "drwxr-xr-x" { exit 1 }
      $1 ~ /^-/ && $6 ~ /\/src\/agent-tree$/ && $1 != "-rwxr-xr-x" { exit 1 }
      $1 ~ /^-/ && $6 !~ /\/src\/agent-tree$/ && $1 != "-rw-r--r--" { exit 1 }
      { count++ }
      END { exit !(count == 7) }
    ' "$listing" || fail "metadata differs for $target"
    [ "$(tar -tzf "$archive" | LC_ALL=C sort | sha256sum | awk '{print $1}')" = "$(tar -tzf "$archive" | sha256sum | awk '{print $1}')" ] || fail 'member order is not byte-sorted'
done
pass 'candidate archives have exact allowlist, sorted names, numeric ownership, and deterministic modes'

# Candidate and final archives both carry the committed MIT LICENSE.
for target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl; do
    [ "$(tar -tzf "$SANDBOX/one/agent-tree-v0.1.0-$target.tar.gz" | grep -Fxc "agent-tree-v0.1.0-$target/LICENSE")" -eq 1 ] || fail "candidate archive lacks exactly one LICENSE for $target"
done
pass 'candidate archives include exactly one project LICENSE'

# Drive the real installer with local archives and caller-pinned digests.
for target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl; do
    archive=$SANDBOX/one/agent-tree-v0.1.0-$target.tar.gz
    "$ROOT/test/install-candidate.sh" "$archive" "$target" "$SANDBOX/install-$target"
done
pass 'both packaged targets install with independent caller-pinned digests'

expect_failure 'final publication packaging fails closed without promoted targets' env SOURCE_DATE_EPOCH=$EPOCH GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/v0.1.0 "$PACKAGE" --mode final --target x86_64-unknown-linux-musl --binary-dir "$SANDBOX/bin" --output "$SANDBOX/final"
mkdir -p "$SANDBOX/source/docs/release-evidence"
for file in Cargo.toml herdr-plugin.toml README.md CHANGELOG.md LICENSE; do cp "$ROOT/$file" "$SANDBOX/source/$file"; done
cat >"$SANDBOX/source/docs/release-evidence/x86.md" <<'EOF'
target: x86_64-unknown-linux-musl
version: 0.1.0
candidate_sha256: 0000000000000000000000000000000000000000000000000000000000000000
native_sidebar_evidence: passed
owner_approved_by: test-owner
EOF
printf '%s\n' 'x86_64-unknown-linux-musl|docs/release-evidence/x86.md|test-owner' >"$SANDBOX/source/release-targets.txt"
expect_failure 'final packaging rejects a non-tag trigger' env READELF="$SANDBOX/readelf" FAKE_MACHINE='Advanced Micro Devices X86-64' SOURCE_DATE_EPOCH=$EPOCH GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/tags/v0.1.0 "$PACKAGE" --source "$SANDBOX/source" --mode final --target x86_64-unknown-linux-musl --binary-dir "$SANDBOX/bin" --output "$SANDBOX/final-event"
expect_failure 'final packaging rejects a mismatched tag' env READELF="$SANDBOX/readelf" FAKE_MACHINE='Advanced Micro Devices X86-64' SOURCE_DATE_EPOCH=$EPOCH GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/v9.9.9 "$PACKAGE" --source "$SANDBOX/source" --mode final --target x86_64-unknown-linux-musl --binary-dir "$SANDBOX/bin" --output "$SANDBOX/final-tag"
GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/v0.1.0 READELF="$SANDBOX/readelf" FAKE_MACHINE='Advanced Micro Devices X86-64' SOURCE_DATE_EPOCH=$EPOCH "$PACKAGE" --source "$SANDBOX/source" --mode final --target x86_64-unknown-linux-musl --binary-dir "$SANDBOX/bin" --output "$SANDBOX/final-ok" >/dev/null
[ "$(tar -tzf "$SANDBOX/final-ok/agent-tree-v0.1.0-x86_64-unknown-linux-musl.tar.gz" | grep -Fxc 'agent-tree-v0.1.0-x86_64-unknown-linux-musl/LICENSE')" -eq 1 ] || fail 'final package does not contain exactly one project LICENSE'
pass 'owner-gated final mode includes exactly one project LICENSE'
"$SUMS" "$SANDBOX/final-ok" --targets-file "$SANDBOX/source/release-targets.txt" --targets-root "$SANDBOX/source" >/dev/null
"$CHECK" --assets "$SANDBOX/final-ok" --targets-file "$SANDBOX/source/release-targets.txt" --targets-root "$SANDBOX/source"
cp "$SANDBOX/one/agent-tree-v0.1.0-aarch64-unknown-linux-musl.tar.gz"* "$SANDBOX/final-ok/"
expect_failure 'mixed final asset sets reject unpromoted aarch64' "$CHECK" --assets "$SANDBOX/final-ok" --targets-file "$SANDBOX/source/release-targets.txt" --targets-root "$SANDBOX/source"
expect_failure 'unpromoted aarch64 cannot enter final assets' env READELF="$SANDBOX/readelf" FAKE_MACHINE=AArch64 SOURCE_DATE_EPOCH=$EPOCH GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/v0.1.0 "$PACKAGE" --source "$SANDBOX/source" --mode final --target aarch64-unknown-linux-musl --binary-dir "$SANDBOX/bin" --output "$SANDBOX/final-arm"
: >"$SANDBOX/empty-targets.txt"
expect_failure 'empty promotion data fails closed' "$PROMOTION_CHECK" --root "$SANDBOX/source" --manifest "$SANDBOX/empty-targets.txt"
printf '%s\n' 'aarch64-unknown-linux-musl|bad/path.md|owner' >"$SANDBOX/malformed-targets.txt"
expect_failure 'malformed promotion data fails closed' "$PROMOTION_CHECK" --root "$SANDBOX/source" --manifest "$SANDBOX/malformed-targets.txt"
printf '%s\n' 'aarch64-unknown-linux-musl|docs/release-evidence/x86.md|test-owner' >"$SANDBOX/mismatch-targets.txt"
expect_failure 'mismatched native evidence fails closed' "$PROMOTION_CHECK" --root "$SANDBOX/source" --manifest "$SANDBOX/mismatch-targets.txt"
sed 's/^native_sidebar_evidence: passed$/native_sidebar_evidence: pending/; s/^owner_approved_by: test-owner$/owner_approved_by: pending/' \
    "$SANDBOX/source/docs/release-evidence/x86.md" >"$SANDBOX/source/docs/release-evidence/pending.md"
printf '%s\n' 'x86_64-unknown-linux-musl|docs/release-evidence/pending.md|test-owner' >"$SANDBOX/pending-targets.txt"
expect_failure 'pending native evidence cannot promote a target' "$PROMOTION_CHECK" --root "$SANDBOX/source" --manifest "$SANDBOX/pending-targets.txt"
sed '/^version:/d' "$SANDBOX/source/docs/release-evidence/x86.md" >"$SANDBOX/source/docs/release-evidence/missing-version.md"
printf '%s\n' 'x86_64-unknown-linux-musl|docs/release-evidence/missing-version.md|test-owner' >"$SANDBOX/missing-version-targets.txt"
expect_failure 'missing evidence version fails closed' "$PROMOTION_CHECK" --root "$SANDBOX/source" --manifest "$SANDBOX/missing-version-targets.txt"
sed 's/^version: 0.1.0$/version: 9.9.9/' "$SANDBOX/source/docs/release-evidence/x86.md" >"$SANDBOX/source/docs/release-evidence/wrong-version.md"
printf '%s\n' 'x86_64-unknown-linux-musl|docs/release-evidence/wrong-version.md|test-owner' >"$SANDBOX/wrong-version-targets.txt"
expect_failure 'mismatched evidence version fails closed' "$PROMOTION_CHECK" --root "$SANDBOX/source" --manifest "$SANDBOX/wrong-version-targets.txt"
printf '%s\n' 'x86_64-unknown-linux-musl|docs/release-evidence/nested/x86.md|test-owner' >"$SANDBOX/nested-targets.txt"
expect_failure 'nested evidence paths fail closed' "$PROMOTION_CHECK" --root "$SANDBOX/source" --manifest "$SANDBOX/nested-targets.txt"
printf '%s\n' 'x86_64-unknown-linux-musl|docs/release-evidence/../x86.md|test-owner' >"$SANDBOX/traversal-targets.txt"
expect_failure 'traversal evidence paths fail closed' "$PROMOTION_CHECK" --root "$SANDBOX/source" --manifest "$SANDBOX/traversal-targets.txt"
printf '%s\n' 'x86_64-unknown-linux-musl|docs/release-evidence/x86 evidence.md|test-owner' >"$SANDBOX/whitespace-targets.txt"
expect_failure 'whitespace evidence paths fail closed' "$PROMOTION_CHECK" --root "$SANDBOX/source" --manifest "$SANDBOX/whitespace-targets.txt"
pass 'promotion manifest permits only version-bound owner-approved native evidence'
cp -a "$SANDBOX/source" "$SANDBOX/git-source"
git -C "$SANDBOX/git-source" init -q
git -C "$SANDBOX/git-source" add herdr-plugin.toml release-targets.txt
expect_failure 'Git checkout rejects untracked native evidence' "$PROMOTION_CHECK" --root "$SANDBOX/git-source" --manifest "$SANDBOX/git-source/release-targets.txt"
git -C "$SANDBOX/git-source" add docs/release-evidence/x86.md
"$PROMOTION_CHECK" --root "$SANDBOX/git-source" --manifest "$SANDBOX/git-source/release-targets.txt" --target x86_64-unknown-linux-musl
git -C "$SANDBOX/git-source" rm --cached -q release-targets.txt
expect_failure 'Git checkout rejects an untracked promotion manifest' "$PROMOTION_CHECK" --root "$SANDBOX/git-source" --manifest "$SANDBOX/git-source/release-targets.txt"
pass 'Git checkouts require tracked promotion manifests and evidence files'
expect_failure 'source release check rejects a mismatched tag' "$CHECK" --ref refs/tags/v9.9.9
sed 's/version = "0.1.0"/version = "bad"/' "$SANDBOX/source/herdr-plugin.toml" >"$SANDBOX/source/herdr-plugin.bad"
mv "$SANDBOX/source/herdr-plugin.bad" "$SANDBOX/source/herdr-plugin.toml"
expect_failure 'packaging rejects malformed or inconsistent manifest versions' env READELF="$SANDBOX/readelf" FAKE_MACHINE='Advanced Micro Devices X86-64' SOURCE_DATE_EPOCH=$EPOCH GITHUB_EVENT_NAME=push GITHUB_REF=refs/tags/v0.1.0 "$PACKAGE" --mode final --source "$SANDBOX/source" --target x86_64-unknown-linux-musl --binary-dir "$SANDBOX/bin" --output "$SANDBOX/bad-version"

cp -a "$SANDBOX/one" "$SANDBOX/malformed"
printf 'unexpected\n' >>"$SANDBOX/malformed/agent-tree-v0.1.0-SHA256SUMS"
expect_failure 'release inspection rejects malformed aggregate checksums' "$CHECK" --assets "$SANDBOX/malformed"
pass 'R07-R08 remain covered by the atomic disabled-link installer suite'
printf '1..%d\n' "$PASS"
