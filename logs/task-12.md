---
id: task-12
uid: e6acdda8-05cd-42cb-8293-8cde6975d8ae
type: task
title: "Prepare v0.4.0 Agent Tree source release for family recency ordering"
priority: "high"
effort: "small"
relatedFiles: ["Cargo.toml", "Cargo.lock", "herdr-plugin.toml", "CHANGELOG.md", "README.md", "src/lifecycle.rs"]
tags: ["release"]
accord:
  status: "accepted"
  acceptance: ["Cargo.toml, Cargo.lock and herdr-plugin.toml declare 0.4.0; `scripts/release/check-release.sh --ref refs/tags/v0.4.0` passes and v0.3.0 ref is rejected.", "CHANGELOG has an empty [Unreleased], a dated [0.4.0] section accurately documenting family recency and its limitations, and a compare link from v0.3.0 to v0.4.0; no private task IDs or exaggerated live verification.", "README status and managed install/update commands use v0.4.0, while historical release examples remain clearly labeled. No Rust behavior or release machinery changes.", "`scripts/check.sh`, `cargo build --locked --release`, and `git diff --check` pass; source changes committed and Worker checkout clean. No push, tag, release or live deploy."]
  claimedAt: "2026-09-30T03:34:09Z"
  deliveredAt: "2026-09-30T03:48:50Z"
  validation: ["$ scripts/release/check-release.sh --ref refs/tags/v0.4.0", "$ scripts/check.sh", "$ cargo build --locked --release"]
  summary: "Addressed the permitted unit-test flake in a separate test-only commit, retaining final-state assertions. Repeated the filtered test 30/30, reran the full project gate and requested release checks, and committed the clean branch. Release prep is 705d0cd; retry assertion fix is 4335a42."
  evidence: ["Permit valid retry publication write counts of 1 or 2 without changing production behavior or adding tests.: Only the existing test's comment/assertion changed in src/lifecycle.rs. It asserts `ranked == 3` and accepts writes 1 or 2; the comment explains same-millisecond root timestamp reuse.", "Retain final-state correctness checks proving parent/child ranks are contiguous and the singleton remains behind the promoted family.: Existing assertions remain unchanged: root and child share the timestamp prefix; the prefix is promoted relative to the neutral rank; root/child end in preorder ranks 000001/000002; both rank ahead of the singleton `other`; and a subsequent display-only pass writes zero ranks.", "Release and project validations pass with a committed clean Worker branch.: Filtered test passed 30/30, `scripts/check.sh`, locked release build, v0.4.0 release checker, and diff check passed. Both commits are present; working tree is clean. No push, tag, or release was performed."]
  filesChanged: ["src/lifecycle.rs"]
  updatedAt: "2026-09-30T03:48:50Z"
createdAt: "2026-09-30T03:33:59Z"
updatedAt: "2026-09-30T03:48:50Z"
assignee: "worker-task-12-215a435d"
archivedAt: "2026-09-30T03:48:50Z"
resolution:
  outcome: "completed"
---
Algorant approved v0.4.0 for task-10 family recency after v0.3.0. Local main has one clean unpushed task-10 commit db38aef. Prepare release metadata/docs: bump Cargo.toml, Cargo.lock and herdr-plugin.toml; date the [0.4.0] CHANGELOG section; update README status and managed install/update commands. Notes must accurately describe practical family recency and limitations (clock skew, neutral restart/stop baseline, unit-tested child promotion not witnessed live). Live normal-client validation covered singleton ordering on x1nano and desktop-wsl with Herdr 0.9.3; cartlab remains older/outside two-machine dogfood. No new recency E2E suite, no live config/plugin changes, no push/tag/release by Worker.

Owner validation on 2026-09-29 found an existing flaky unit assertion in src/lifecycle.rs::a_failed_publication_retries_the_same_transition_until_ranks_are_contiguous: 27/30 isolated reruns returned 1 retry write and 3/30 returned 2. Both are valid because the root's successful first write can already have the final timestamp if both passes occur in the same millisecond; the child remains the only changed pane. The final parent/child contiguous rank assertions already test correctness. Worker may change ONLY that test assertion/comment to accept 1 or 2 writes while keeping final-state checks, without modifying production Rust. This is a release validation blocker fix, not a new feature.

Orchestrator owns Git push/tag/GitHub Release and later live deployment.