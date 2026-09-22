---
id: task-8-2
type: task
title: "Dogfood the exact v0.1.0 Herdr-managed source install"
state: "in-progress"
priority: "high"
effort: "medium"
parentId: "task-8"
blockers: ["task-18"]
references: ["decision-3", "task-7"]
relatedFiles: ["herdr-plugin.toml", "README.md", "docs/release.md"]
tags: ["dogfood", "release", "validation", "herdr-plugin-install"]
accord:
  status: "blocked"
  acceptance: ["A clean Herdr-managed install from the exact reviewed candidate ref runs the manifest `[[build]]` command successfully, registers `agent-tree`, and executes the built binary from the managed plugin checkout without relying on a pre-existing `target/` directory.", "The managed install exposes the declared apply/reload/clear/toggle actions, can be enabled and activated using the documented steps, and the doctor reports a healthy subscriber and canonical `prefix+t` shortcut/config state.", "Real top-level, Worker, Subagent and Worker-owned Subagent relationships are observed during normal use, including ordering, exit cleanup and tree/native toggle behavior, with no critical identity, recovery, lifecycle or sidebar regression.", "The installed plugin source ref/commit, Herdr version, Rust version, build result, registration source, running executable/hash and observed lifecycle/sidebar results are captured as Task evidence.", "Algorant explicitly reviews and approves the exact managed-install dogfood result before task-8 may make the repository public or create the v0.1.0 tag."]
  claimedAt: "2026-09-21T02:45:15Z"
  validation: ["$ git diff --check", "$ just test", "$ just build"]
  constraints: ["Do not make the repository public, create or push a tag, or publish a release during dogfood.", "Do not claim owner approval on Algorant's behalf; record explicit approval only after presenting the exact managed-install evidence.", "Use the Herdr-managed source install from decision-3; do not use the removed archive installer, a development stage, or a checkout link as release evidence.", "Do not restart or disturb unrelated Herdr panes while transitioning the live plugin."]
  note: "Live cross-endpoint capture resolved the current herdr-notifs-plus symptom. Desktop endpoint is healthy with Agent Tree 0.1.0 and one subscriber; laptop endpoint has no Agent Tree registration, no staged binary, and zero subscribers, so its rows cannot receive Agent Tree rank/row metadata and endpoint selection can expose a different native view. The current laptop child herdr-plugin-ecosystem also has no role/agency_self/agency_parent tokens because its managed Subagent startup failed on a stale extension path in the already-running root session and it was manually restarted with `herdr agent start`, bypassing pi-agency publication. Next evidence must install/activate Agent Tree on laptop through an approved path, start fresh managed Subagent and Worker children from a current Pi session, and compare both endpoints before release approval."
  updatedAt: "2026-09-22T00:31:46Z"
createdAt: "2026-09-21T01:36:26Z"
updatedAt: "2026-09-22T00:31:46Z"
assignee: "orchestrator"
---

## Description

After task-8-1 establishes the standard source-build contract, install the exact reviewed v0.1.0 candidate through `herdr plugin install Algorant/herdr-agent-tree --ref <exact-candidate-ref>` in an isolated environment or controlled live transition. Prove Herdr runs the manifest build, registers the resulting plugin, and exposes working actions from the managed checkout. Then use that exact install in normal Herdr work, record objective tree/toggle/lifecycle observations, and ask Algorant for explicit release approval. This replaces the cancelled archive-evidence task-7; decision-3 removed custom archives, target allowlists and native-evidence files from the release model.
