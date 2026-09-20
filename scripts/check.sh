#!/bin/sh
# The single authoritative quality gate. `just test` runs the complete gate, including the
# noninteractive isolated Herdr end-to-end test. Hosted CI passes --no-e2e because its runner
# has no Herdr or Pi; every hermetic check still runs there.
set -eu

PROGRAM=${0##*/}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
CARGO=${CARGO:-cargo}
run_e2e=true

usage() {
    printf '%s\n' 'usage: scripts/check.sh [--no-e2e]' >&2
    exit 2
}
while [ "$#" -gt 0 ]; do
    case $1 in
        --no-e2e) run_e2e=false ;;
        --help|-h) usage ;;
        *) printf '%s: unknown argument: %s\n' "$PROGRAM" "$1" >&2; usage ;;
    esac
    shift
done

say() { printf '\n== %s\n' "$*"; }
# CARGO may carry extra arguments (for example "cargo +1.81.0"), so expand it unquoted.
# shellcheck disable=SC2086
cargo_run() { $CARGO "$@"; }

cd "$ROOT"

say 'Formatting'
cargo_run fmt --all -- --check

say 'Clippy'
cargo_run clippy --locked --all-targets --all-features -- -D warnings

say 'Rust tests'
cargo_run test --locked --all-targets

say 'Locked build'
cargo_run build --locked

say 'Shell syntax'
sh -n scripts/check.sh scripts/stage-local.sh scripts/lib/endpoint.sh scripts/release/*.sh \
    tests/shell/install-candidate.sh tests/shell/test-install.sh tests/shell/test-release.sh \
    tests/shell/dev-reload.sh src/agent-tree
bash -n scripts/deploy.sh scripts/deploy-endpoint.sh scripts/doctor.sh \
    tests/shell/deploy-endpoint.sh tests/shell/doctor.sh \
    tests/e2e/sidebar.sh tests/e2e/deploy-reload.sh tests/e2e/toggle.sh

say 'Python syntax'
python3 -c 'import ast, sys
for path in sys.argv[1:]:
    ast.parse(open(path, "rb").read(), path)' \
    scripts/lib/config.py scripts/lib/probe.py scripts/lib/report.py scripts/lib/stop.py

say 'Release version check'
scripts/release/check-release.sh

say 'Installer tests'
tests/shell/test-install.sh

say 'Release tests'
tests/shell/test-release.sh

say 'Dev reload tests'
tests/shell/dev-reload.sh

say 'Endpoint doctor tests'
tests/shell/doctor.sh

say 'Endpoint deploy tests'
tests/shell/deploy-endpoint.sh

if [ "$run_e2e" = true ]; then
    say 'Isolated Herdr deploy/reload ordering test'
    tests/e2e/deploy-reload.sh
    say 'Isolated Herdr end-to-end sidebar test'
    tests/e2e/sidebar.sh
    say 'Isolated Herdr Agent Tree toggle end-to-end test'
    tests/e2e/toggle.sh
fi

say 'All checks passed'
