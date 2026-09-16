---
id: task-8
type: task
title: "Publish v0.1.0 as a public Herdr plugin"
state: todo
priority: "medium"
effort: "medium"
blockers: ["task-5", "task-7"]
relatedFiles: ["herdr-plugin.toml", "Cargo.toml", "CHANGELOG.md", "release/targets.txt", "docs/release-evidence", ".github/workflows/release.yml", "scripts/release/install.sh", "README.md", "justfile", ".tandem", ".gitignore"]
tags: ["release", "public", "marketplace"]
accord:
  status: "ready"
  acceptance: ["All required hosted CI jobs pass on the exact release commit.", "release/targets.txt contains only owner-approved targets with matching tracked evidence for version 0.1.0, and the final release checks pass.", "Internal `.tandem` coordination metadata is removed from the public release tree and excluded from future public commits without disrupting the completed dogfood record.", "Algorant/herdr-agent-tree is public with the `herdr-plugin` topic and root `herdr-plugin.toml`.", "The immutable `v0.1.0` tag points at the reviewed release commit and the GitHub release workflow completes successfully.", "The GitHub release contains exactly the approved target archives, per-archive SHA-256 sidecars and the aggregate SHA256SUMS file, all of which verify.", "A clean anonymous installation using the documented tagged `scripts/release/install.sh`, pinned version and checksum succeeds and registers the plugin disabled.", "README.md and CHANGELOG.md describe the published release and no longer say that no tagged release exists."]
  validation: ["$ git diff --check", "$ just test", "$ just build", "$ scripts/release/check-targets.sh", "$ scripts/release/check-release.sh --ref refs/tags/v0.1.0"]
  constraints: ["Do not begin until Algorant explicitly approves the dogfood result and public release.", "Keep .tandem available and tracked through the dogfood period; remove it from the public release tree only at the final release boundary after active coordination records are no longer needed.", "Promote only targets with matching version-bound native evidence and explicit owner approval; do not include aarch64 without native aarch64 evidence.", "Do not replace, move or recreate an existing tag or GitHub release; fail rather than overwrite.", "Use the tracked gated release workflow and exact source commit; do not upload hand-built substitute assets.", "Keep release checksums, archive allowlists and disabled-by-default installer behavior intact."]
  updatedAt: "2026-09-16T13:28:14Z"
createdAt: "2026-09-16T12:39:34Z"
updatedAt: "2026-09-16T13:28:14Z"
---

## Description

Perform the owner-authorized public release only after hosted CI is green and Algorant has completed and approved the x86-64 dogfood evidence. Make Algorant/herdr-agent-tree public, promote only targets with matching tracked native evidence, create the exact immutable v0.1.0 tag, and let the gated GitHub release workflow build and publish the artifacts. Verify the public install path anonymously and confirm the repository satisfies Herdr marketplace discovery requirements: root herdr-plugin.toml, public visibility and the herdr-plugin topic.
