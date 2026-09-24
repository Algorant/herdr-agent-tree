# Source release and publication

Agent Tree is installed from source by Herdr itself. The sole normal-user path is:

```sh
herdr plugin install Algorant/herdr-agent-tree --ref v0.1.0
```

Herdr clones that source revision, runs the manifest `[[build]]` command, registers the
plugin and manages the checkout. There are no downloadable binary archives, checksum files,
target allowlists or native-evidence files, and this repository publishes none.

v0.1.0 is the first public source release. The release tag identifies the reviewed source
revision; Herdr builds the optimized native executable on the installing machine. Git history
contains earlier internal `.tandem` coordination records; the release tree removes and ignores
`.tandem/` for subsequent commits.

## Version gate

`herdr-plugin.toml` and `Cargo.toml` must carry the same three-component version, and
`CHANGELOG.md` must have an exact dated `## [<version>] - YYYY-MM-DD` heading (the
pre-release gate also accepts `planned`). `scripts/release/check-release.sh` enforces both and,
when run for a tag, requires the exact `refs/tags/v<version>` ref:

```sh
./scripts/release/check-release.sh --ref refs/tags/v0.1.0
```

The same script requires exactly one manifest `[[build]]` command and that it is
`["cargo", "build", "--locked", "--release"]`, so the published revision cannot point Herdr at
a different build.

## Install contract

`herdr-plugin.toml` declares:

- `[[build]] command = ["cargo", "build", "--locked", "--release"]`, run by Herdr in the
  plugin root before it registers the plugin; and
- runtime `[[startup]]`/`[[actions]]` commands of the form
  `["./src/agent-tree", "<start|apply|reload|clear|toggle>"]`.

`src/agent-tree` is the tracked launcher (a repository convention shared with
`herdr-notifs-plus`). It execs the freshly built `target/release/agent-tree`, so a clean
checkout with no pre-existing `target/` works after Herdr runs the build, and the manifest
never invokes Cargo at runtime. `tests/shell/source-install.sh` proves this contract
hermetically: it exports only tracked files to a target-less tree, runs the manifest build
argv verbatim, and checks that every runtime manifest command is executable and reaches the
built binary.

Herdr owns installation, registration and rebuild/update behavior. Updating means reinstalling
from a newer ref (`herdr plugin install Algorant/herdr-agent-tree --ref <newer-tag>`); Herdr
replaces the managed checkout. Removing the plugin is `herdr plugin uninstall agent-tree`.

## Local development tooling

These are development and administration paths, not the normal user install:

- `scripts/deploy.sh` (`just deploy`) builds, stages a self-contained plugin root under the
  user data directory and registers that staged root against the live server.
- `scripts/stage-local.sh` writes an inert complete plugin root under the Cargo target
  directory and never links it or touches user state.
- `scripts/deploy-endpoint.sh` (`just deploy-endpoint <name>`) and `scripts/doctor.sh`
  (`just doctor <name>`) deploy to or diagnose an explicitly named local or saved remote
  endpoint.

## CI

`.github/workflows/ci.yml` runs on pushes and pull requests with a pinned Rust 1.81.0
toolchain. It builds the locked source and runs `scripts/check.sh --no-e2e`: `cargo fmt
--check`, `cargo clippy --locked --all-targets --all-features -- -D warnings`, `cargo test
--locked --all-targets`, `cargo build --locked`, shell syntax checks, the clean-source install
smoke test, the local stage tests, the release version gate and the hermetic endpoint suites.
Hosted CI skips only the Herdr/Pi end-to-end test, which `just test` runs locally.

## Tag workflow

`.github/workflows/release.yml` runs only on a `v*` tag push. Its validate job reruns
`scripts/release/check-release.sh --ref "$GITHUB_REF"` and the clean-source install smoke test.
Its publish job then creates the tag release with `gh release create --verify-tag` and no
uploaded assets, so GitHub's own source archive is the immutable release. It refuses to replace
an existing release.

## Marketplace discovery prerequisites

The Herdr marketplace indexes public GitHub repositories tagged with the `herdr-plugin` topic
whose default branch contains a parseable `herdr-plugin.toml`. This repository already has a
root manifest with the required `id`, `name`, `version`, `min_herdr_version` and `platforms`;
publication must add the topic and make the repository public.

## Release verification

The v0.1.0 candidate was installed from its exact Git commit through Herdr's managed source
lifecycle on Linux/Herdr 0.9.1, built with the locked Cargo manifest command, and exercised
with live Pi root, Worker, root-owned Subagent and Worker-owned Subagent relationships. A
managed reinstall replaced its verified previous subscriber, and the doctor reported one
matching executable, working `prefix+t` toggle and configured sidebar row. The full local
quality gate and hosted CI passed on the reviewed candidate. The final tag workflow validates
the release ref and clean-source build before publishing the source release.

For a new machine, install from the tag above, add the rows configuration from the README,
then activate it with `herdr plugin enable agent-tree`, `herdr server reload-config` and
`herdr plugin action invoke agent-tree.apply`. Reinstall from a newer tag to update; this
release does not provide binary archives or a separate `plugin update` command.
