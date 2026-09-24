---
id: task-8-2
type: task
title: "Dogfood the exact v0.1.0 Herdr-managed source install"
state: "in-progress"
priority: "high"
effort: "medium"
parentId: "task-8"
blockers: ["task-21"]
references: ["decision-3", "task-7"]
relatedFiles: ["herdr-plugin.toml", "README.md", "docs/release.md"]
tags: ["dogfood", "release", "validation", "herdr-plugin-install"]
accord:
  status: "blocked"
  acceptance: ["A clean Herdr-managed install from the exact reviewed candidate ref runs the manifest `[[build]]` command successfully, registers `agent-tree`, and executes the built binary from the managed plugin checkout without relying on a pre-existing `target/` directory.", "The managed install exposes the declared apply/reload/clear/toggle actions, can be enabled and activated using the documented steps, and the doctor reports a healthy subscriber and canonical `prefix+t` shortcut/config state.", "Real top-level, Worker, Subagent and Worker-owned Subagent relationships are observed during normal use, including ordering, exit cleanup and tree/native toggle behavior, with no critical identity, recovery, lifecycle or sidebar regression.", "The installed plugin source ref/commit, Herdr version, Rust version, build result, registration source, running executable/hash and observed lifecycle/sidebar results are captured as Task evidence.", "Algorant explicitly reviews and approves the exact managed-install dogfood result before task-8 may make the repository public or create the v0.1.0 tag."]
  claimedAt: "2026-09-21T02:45:15Z"
  validation: ["$ git diff --check", "$ just test", "$ just build"]
  constraints: ["Do not make the repository public, create or push a tag, or publish a release during dogfood.", "Do not claim owner approval on Algorant's behalf; record explicit approval only after presenting the exact managed-install evidence.", "Use the Herdr-managed source install from decision-3; do not use the removed archive installer, a development stage, or a checkout link as release evidence.", "Do not restart or disturb unrelated Herdr panes while transitioning the live plugin."]
  note: "Managed install of exact candidate 40f810a succeeded on laptop, but Herdr moved the former checkout to .tmp-install-*/previous-checkout and reload correctly refused its still-running (deleted) executable; doctor reports degraded despite matching bytes. Task-21 must fix and validate a narrow replacement trust path before dogfood can finish. No force signal/restart performed."
  updatedAt: "2026-09-24T14:28:16Z"
createdAt: "2026-09-21T01:36:26Z"
updatedAt: "2026-09-24T14:28:16Z"
assignee: "orchestrator"
---
After task-8-1 establishes the standard source-build contract, install the exact reviewed v0.1.0 candidate through `herdr plugin install Algorant/herdr-agent-tree --ref <exact-candidate-ref>` in an isolated environment or controlled live transition. Prove Herdr runs the manifest build, registers the resulting plugin, and exposes working actions from the managed checkout. Then use that exact install in normal Herdr work, record objective tree/toggle/lifecycle observations, and ask Algorant for explicit release approval. This replaces the cancelled archive-evidence task-7; decision-3 removed custom archives, target allowlists and native-evidence files from the release model. Task-18's focus/publication spike is accepted; task-20's managed-install doctor false negative is the remaining concrete blocker.