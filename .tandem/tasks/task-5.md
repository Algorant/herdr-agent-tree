---
id: task-5
type: task
title: "Fix hosted CI failures in the release pipeline"
state: "in-progress"
priority: "high"
effort: "small"
relatedFiles: ["scripts/check-release.sh", "test/install-candidate.sh", ".github/workflows/ci.yml", "test/test-release.sh"]
tags: ["ci", "release-readiness"]
accord:
  status: "claimed"
  acceptance: ["Normal branch and pull-request CI does not interpret GITHUB_REF as a release tag unless a release ref is explicitly supplied to the checker.", "Both musl candidate jobs install their packaged archive through the real installer using an absolute isolated prefix.", "A fresh hosted CI run for the fix commit completes successfully for the quality job and both candidate matrix jobs.", "Local release and installer suites still cover mismatched tags, relative/system-prefix rejection and fail-closed final publication."]
  claimedAt: "2026-09-16T13:29:03Z"
  validation: ["$ git diff --check", "$ make check"]
  constraints: ["Do not weaken the exact refs/tags/v<version> gate when an explicit release ref is checked.", "Do not allow relative installer prefixes; canonicalize the hermetic test destination or pass an absolute path.", "Do not skip, condition away or mark failing CI steps continue-on-error.", "Do not tag, publish a release or change repository visibility."]
  updatedAt: "2026-09-16T13:29:03Z"
createdAt: "2026-09-16T12:38:35Z"
updatedAt: "2026-09-16T13:29:03Z"
assignee: "pi-orchestrator"
---

## Description

The first hosted CI run for commit e742c72 failed despite local checks passing. The quality job inherits GITHUB_REF=refs/heads/main, and scripts/check-release.sh currently treats any inherited GITHUB_REF as a requested release-tag check; test/test-release.sh therefore fails with `tag must be refs/tags/v0.1.0`. Both candidate jobs build and package successfully, then fail because test/install-candidate.sh forwards the workflow's relative `target/install-<target>` path to scripts/install.sh, whose absolute-prefix requirement correctly rejects it. Fix these CI integration errors without weakening either release-tag validation or installer path safety. Failed run: https://github.com/Algorant/herdr-agent-tree/actions/runs/35096118026
