---
id: task-8
type: task
title: "Publish v0.1.0 as a public Herdr plugin"
state: todo
priority: "medium"
effort: "medium"
blockers: ["task-8-1", "task-8-2"]
relatedFiles: ["herdr-plugin.toml", "Cargo.toml", "CHANGELOG.md", "README.md", "docs/release.md", ".github/workflows/ci.yml", ".github/workflows/release.yml", ".tandem", ".gitignore"]
tags: ["release", "public", "marketplace", "source-build"]
accord:
  status: "ready"
  acceptance: ["Task-8-1 and task-8-2 are complete, Algorant explicitly approves the exact managed-install dogfood result and public release, and all required hosted CI jobs pass on the reviewed release commit.", "Internal `.tandem` coordination metadata is removed from the public release tree and excluded from future public commits only at the final boundary, without losing the accepted dogfood/release decision record needed before that boundary.", "Algorant/herdr-agent-tree is public with the `herdr-plugin` topic and a parseable root `herdr-plugin.toml` whose standard source-build install contract matches decision-3.", "The immutable `v0.1.0` tag points at the reviewed release commit; the GitHub release workflow completes successfully and publishes the source release without custom binary installer assets.", "A clean anonymous `herdr plugin install Algorant/herdr-agent-tree --ref v0.1.0` runs the manifest build, registers a runnable plugin, and the documented activation/doctor flow succeeds without any pre-existing checkout or target directory.", "README.md, CHANGELOG.md and docs/release.md describe the published source-build release, standard Herdr install/update commands and actual support status, with no stale private/no-release/planned-install claims."]
  validation: ["$ git diff --check", "$ just test", "$ just build", "$ scripts/release/check-release.sh --ref refs/tags/v0.1.0"]
  constraints: ["Do not perform the final visibility change, tag or release until Algorant explicitly approves the exact task-8-2 managed-install result and authorizes publication.", "Use the single Herdr-managed source-build path from decision-3; do not restore custom installers, binary archives, target promotion allowlists or plugin-link release paths.", "Keep `.tandem` tracked until every prerequisite coordination record is accepted; remove it only in the final reviewed release commit.", "Do not replace, move or recreate an existing tag or GitHub release; fail rather than overwrite.", "Keep the repository private until the owner-authorized final publication sequence."]
  updatedAt: "2026-09-21T01:36:45Z"
createdAt: "2026-09-16T12:39:34Z"
updatedAt: "2026-09-21T01:36:45Z"
references: ["decision-3"]
---
Publish v0.1.0 through Herdr's native plugin lifecycle after the source-build install contract and its exact managed-install dogfood are complete and Algorant explicitly approves release. The sole normal-user path is `herdr plugin install Algorant/herdr-agent-tree --ref v0.1.0`; the tag workflow publishes the immutable reviewed source release rather than custom binary archives. At the final public boundary, remove internal `.tandem` coordination metadata, make the repository public, create the exact tag, verify hosted CI/release completion, confirm marketplace discovery prerequisites, and perform a clean anonymous Herdr-managed installation.