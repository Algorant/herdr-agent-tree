---
id: task-7
type: task
title: "Dogfood the latest x86-64 build and capture native sidebar evidence"
priority: "high"
effort: "medium"
relatedFiles: ["docs/release-evidence", "release/targets.txt", "README.md", "justfile"]
tags: ["dogfood", "release-evidence", "validation"]
accord:
  status: "ready"
  acceptance: ["The local staged binary and sole running subscriber are proven to come from the intended latest source commit, and the plugin is unpaused with the chosen sidebar row rendering `$agent_tree_row`.", "Real top-level, Worker, Subagent and Worker-owned Subagent relationships are observed during normal use, including appearance, reordering, exit cleanup and toggle/apply behavior.", "No critical identity, recovery, lifecycle or sidebar regression is observed over the dogfood period; any issue found is captured as a blocker rather than waived.", "An exact x86_64-unknown-linux-musl candidate is built, packaged, checksum-verified and installed through the release installer path in an isolated or versioned prefix.", "A version-bound draft under docs/release-evidence records host, source commit, candidate archive/digest, SOURCE_DATE_EPOCH, install path, lifecycle results, sidebar observations and review date.", "Algorant explicitly reviews the dogfood result before native_sidebar_evidence changes to passed or x86-64 is added to release-targets.txt."]
  validation: ["$ git diff --check", "$ just test", "$ just build"]
  constraints: ["Do not make the repository public, create or push a tag, publish a release, or promote a target in release-targets.txt during the observation period.", "Do not claim owner approval on Algorant's behalf; keep native_sidebar_evidence and owner_approved_by pending until explicit review.", "Use the exact packaged x86_64 candidate digest and source commit in the evidence; a checkout binary alone is insufficient release evidence.", "Do not use cross-built or emulated evidence for aarch64."]
  updatedAt: "2026-09-16T13:28:01Z"
createdAt: "2026-09-16T12:39:18Z"
updatedAt: "2026-09-21T01:36:17Z"
archivedAt: "2026-09-21T01:36:17Z"
resolution:
  outcome: "canceled"
  note: "Superseded before work began by Algorant's decision-3 to use Herdr-managed source builds as the sole public install path. The original archive/digest/native-target evidence contract no longer applies; replacement dogfood work will validate the exact managed source install under task-8."
---
After the simplified layout and safe `just deploy` workflow land, switch Algorant's local agent-tree installation from the old paused staged binary to the latest checkout and use it in normal Herdr work before any public release. Keep this Task open through the dogfood period. Record objective lifecycle and sidebar observations against an exact x86_64-unknown-linux-musl candidate archive and digest, but keep owner approval pending until Algorant explicitly accepts the dogfood result. This Task establishes the evidence needed to promote x86-64; it does not make the repository public, add a release target, tag or publish.