# Native release evidence

One reviewed file per target and release version belongs in this directory. Evidence paths must
be one safe Markdown basename directly in this directory. Nested paths, whitespace, symlinks
and traversal are rejected by `scripts/release/check-targets.sh`.

Copy this template to a versioned name such as `v0.1.0-x86_64-unknown-linux-musl.md` only
after all native human checks pass:

```text
target: x86_64-unknown-linux-musl
version: 0.1.0
candidate_sha256: <64 lowercase hexadecimal SHA-256 of the installed candidate archive>
native_sidebar_evidence: passed
owner_approved_by: <owner identity>
```

Before human review, a version-specific draft can record objective results with
`native_sidebar_evidence: pending` and `owner_approved_by: pending`. The promotion gate rejects
that draft. Do not use `passed` or an owner identity until the matching installed candidate has
received human TUI/sidebar and release-readiness validation.

The evidence body must additionally record the native host, the exact candidate archive name,
the candidate source commit, `SOURCE_DATE_EPOCH`, the installation command, the installed
plugin root, the lifecycle result, the TUI/sidebar observations and the review date. The exact
fields above are the machine gate and each must occur once.

After review, the owner adds the corresponding line to `release/targets.txt` in the same
reviewed release commit. The target, current `herdr-plugin.toml` version, candidate digest,
passed status and approver must all match. Evidence for one version cannot authorize a later
version. Aarch64 requires native aarch64 TUI/sidebar evidence; cross-built or emulated evidence
is insufficient.

`release/targets.txt` currently has no entries, so no target is approved and no release may be
published.
