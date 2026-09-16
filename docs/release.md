# Release machinery

This documents how agent-tree is built, packaged, installed and gated for release. It ports
the `Algorant/herdr-notifs-plus` release machinery; the deliberate deviations are listed at
the end. No tagged release has been published, the repository stays private for now, and the
owner target allowlist is empty.

## Version gate

`herdr-plugin.toml` and `Cargo.toml` must carry the same three-component version, and
`CHANGELOG.md` must have the exact heading `## [<version>] - planned`. `scripts/check-release.sh`
enforces all three and, when run for a tag, requires the exact `refs/tags/v<version>` ref.

```sh
./scripts/check-release.sh
```

## Supported targets

Release archives are built for:

- `x86_64-unknown-linux-musl`
- `aarch64-unknown-linux-musl`

Both use `rust-lld` with Rust's bundled musl startup objects (`.cargo/config.toml`), so no
unpinned cross compiler is downloaded. The plugin manifest is `platforms = ["linux"]`.

## Packaging

`scripts/package-release.sh` builds one deterministic archive and its `.sha256` sidecar for a
target from an already-built binary directory:

```sh
SOURCE_DATE_EPOCH=$(git show -s --format=%ct HEAD) \
  ./scripts/package-release.sh --target x86_64-unknown-linux-musl \
  --binary-dir target/x86_64-unknown-linux-musl/release
```

The archive is `agent-tree-v<version>-<target>.tar.gz` and always contains exactly:

```
agent-tree-v<version>-<target>/
├── CHANGELOG.md        (0644)
├── LICENSE             (0644)
├── README.md           (0644)
├── herdr-plugin.toml   (0644)
└── src/
    └── agent-tree      (0755)
```

Ownership is `0/0`, member names are sorted, modes are exact, and the mtime is pinned to
`SOURCE_DATE_EPOCH`, so two clean builds are byte-identical. `scripts/check-target-binaries.sh`
rejects a binary whose ELF machine is not the target's or which has any `NEEDED` entry.
`scripts/write-checksums.sh` writes the aggregate `agent-tree-v<version>-SHA256SUMS` file.

## Installer

`scripts/install.sh` installs one caller-pinned release without elevated privileges:

1. Downloads `https://github.com/Algorant/herdr-agent-tree/releases/download/v<version>/agent-tree-v<version>-<target>.tar.gz`
   with `curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2`.
2. Verifies the caller-supplied 64-character lowercase SHA-256.
3. Enforces a strict GNU-tar allowlist: exactly the seven entries above, with their modes, and
   no traversal or unexpected members.
4. Extracts into a sibling staging directory, normalizes and re-verifies every mode, checks the
   manifest identity, version and the four `start`/`apply`/`clear`/`toggle` commands.
5. Commits atomically to `${XDG_DATA_HOME:-$HOME/.local/share}/herdr-agent-tree/<version>/<target>`
   and never overwrites an existing `<version>/<target>`.
6. Registers the committed directory with `herdr plugin link <dir> --disabled` when Herdr is
   available. It never edits `config.toml` and never enables the plugin.

See "Install" in `README.md` for the user-facing commands and the manual activation steps.

## Local development stage

`scripts/stage-local.sh` writes a complete plugin root under the Cargo target directory
(`target/stage-local` by default) from a debug or release binary. It never links the result or
touches user state. The root `./install.sh` is the development install from a checkout; it is
not the normal user path.

## CI

`.github/workflows/ci.yml` runs on pushes and pull requests with a pinned Rust 1.81.0
toolchain:

- `cargo build --locked` as an explicit build step, then `make ci`:
  `cargo fmt --check`, `cargo clippy --locked --all-targets --all-features -- -D warnings`,
  `cargo test --locked --all-targets`, `cargo build --locked`, `sh -n` over the shell scripts,
  and the hermetic installer and release suites.
- A step that runs `make release-check` and fails the job unless the owner gate stays closed.
- A candidate matrix that builds both musl targets twice, compares the archives byte for byte,
  runs them through the real installer with a caller-pinned digest, and asserts ELF machine
  and static linkage.

## Owner-gated final promotion

`release-targets.txt` is the owner-controlled allowlist. Each line is
`RUST_TARGET|TRACKED_NATIVE_EVIDENCE_PATH|OWNER_APPROVER`. It is intentionally empty.

`scripts/check-release-targets.sh` refuses to approve anything until a target has a tracked
`docs/release-evidence/*.md` file with a matching `target`, the current manifest `version`, a
64-character lowercase `candidate_sha256`, `native_sidebar_evidence: passed` and the matching
`owner_approved_by`. Aarch64 requires native aarch64 TUI/sidebar evidence; cross-built or
emulated evidence is insufficient. The promotion manifest must be tracked by Git, and it and every
evidence file must be in the same reviewed release commit.

`make release-check` fails closed while the allowlist is empty. The tag workflow in
`.github/workflows/release.yml` runs only on a `v*` tag push and would stop at that same gate
before building or publishing. Nothing in this repository creates a tag, publishes a release,
or changes repository visibility.

## Deliberate deviations from herdr-notifs-plus

- **License state.** agent-tree committed an MIT `LICENSE` from the start, so candidate and
  final archives both include it; there is no pre-license gate and no candidate mode that
  rejects a project LICENSE. Final promotion is still owner-gated on target evidence.
- **Single binary.** agent-tree has one executable (`agent-tree`); the notifs-plus doctor
  binary, `assets/`, `LICENSES/`, `config.toml.example` and `THIRD_PARTY_NOTICES.md` do not
  exist here and are not packaged.
- **Activation and configuration.** The installer registers the plugin disabled and never
  edits Herdr configuration. Activation is manual: add the sidebar rows block, run
  `herdr plugin enable agent-tree`, reload the config and invoke `agent-tree.apply`. The
  sidebar fragment is `rows = [["state_icon", "$agent_tree_row", "terminal_title_stripped"]]`.
- **Supply-chain reporting.** The notifs-plus CI job that generated dependency-license,
  RustSec and CycloneDX reports is not ported; agent-tree has a small dependency set and the
  job was not required for release readiness.
- **Publication state.** The repository remains private, no tag exists and no release has been
  published. Publication is out of scope and requires explicit owner approval.
