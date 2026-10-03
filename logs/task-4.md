---
id: task-4
uid: a19933a1-5370-45e3-b2ec-4bf0178cc3ed
type: task
title: "Make managed-to-staged Agent Tree dogfood transition fail safely before relinking"
priority: "low"
effort: "small"
relatedFiles: ["scripts/deploy.sh", "src/lifecycle.rs", "tests/shell/dev-reload.sh"]
tags: ["papercut"]
accord:
  status: "accepted"
  acceptance: ["A managed GitHub install transitioning to a local staged dogfood build either completes with one verified staged subscriber or refuses before changing registration, leaving the previous subscriber and config coherent; isolated tests cover the refused and successful boundaries."]
  claimedAt: "2026-09-28T16:26:18Z"
  deliveredAt: "2026-09-28T16:49:31Z"
  summary: "Updated the refusal remedy based on an isolated Herdr 0.9.1 experiment: both `herdr plugin disable agent-tree` and `herdr plugin unlink agent-tree` leave the detached subscriber running. The refusal now gives the workable sequence: disable, re-verify the reported PID's UID/argv/executable/socket identity, send that PID SIGTERM, wait for exit, then retry the printed deploy command. The detector now fails closed on same-UID inspection errors, skipping only processes that disappear during the scan. Committed as `4489505` (`Clarify managed subscriber stop procedure`)."
  evidence: ["Provide an operator remedy that actually permits the managed-to-staged transition, with exact commands and an isolated full-sequence test.: In Herdr 0.9.1, disable and unlink alone both leave the subscriber running. The refusal prints `herdr plugin disable agent-tree`, instructs verification of its reported PID/executable/socket followed by `kill -TERM <pid>`, waiting for exit, then the deploy retry command. The real isolated integration test performs refusal → disable → identity re-check → SIGTERM → successful deploy and verifies registration plus one hash-matched staged process.", "Unreadable same-UID process inspection fails closed, while exited processes may be skipped.: The preflight skips only `FileNotFoundError` while reading a PID's `/proc` entries; other ownership or same-UID identity inspection errors terminate the preflight with an error instead of continuing.", "Preserve the point-in-time scan as a residual risk.: No deploy lock was added; the possibility of a concurrent registration/subscriber change after preflight remains documented in this report."]
  filesChanged: ["scripts/deploy.sh", "tests/e2e/deploy-reload.sh", "CHANGELOG.md"]
  updatedAt: "2026-09-28T16:49:31Z"
createdAt: "2026-09-27T12:51:20Z"
updatedAt: "2026-09-28T16:49:31Z"
assignee: "worker-task-4-67acca14"
archivedAt: "2026-09-28T16:49:31Z"
resolution:
  outcome: "completed"
---

## Description

A local `scripts/deploy.sh` from a GitHub-managed Agent Tree install staged and relinked to the local build, then reload refused the still-running managed-checkout subscriber because its executable fell outside the new stage's trusted paths. The old subscriber remained active while registration pointed at the new stage (doctor: degraded). Investigate a verified, owner-safe transition or a preflight refusal before staging/relinking; do not bypass executable/UID/socket identity checks or signal foreign processes.
