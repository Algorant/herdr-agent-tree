---
id: task-13
type: task
title: "Replace the three-mode cycle with an owner-safe Agent Tree toggle"
priority: "high"
effort: "medium"
references: ["task-11", "task-10", "decision-2"]
relatedFiles: ["src/main.rs", "src/lifecycle.rs", "src/pause.rs", "src/projection.rs", "src/config.rs", "herdr-plugin.toml", "tests/e2e/mode-cycle.sh", "scripts/check.sh", "README.md", "CHANGELOG.md"]
tags: ["ux", "configuration", "toggle"]
accord:
  status: "accepted"
  acceptance: ["A registered `agent-tree.toggle` action and documented `[[keys.command]]` binding (`prefix+alt+t`) switch no active plugin view → Agent Tree view → native Agents list without restarting Herdr.", "Turning Agent Tree off preserves the Herdr client's existing native grouped/priority choice and neither writes `ui.agent_panel_sort` nor creates or consumes sort-restore state.", "The subscriber continues publishing `agent_tree_row` and `agent_tree_rank` with Agent Tree ordering both on and off; only the plugin-owned view changes.", "If another source owns the Agents view, toggle fails clearly and leaves that view unchanged; an unknown or ambiguous owner also fails closed.", "The obsolete `agent-tree.cycle` action, three-mode state machine, configuration writer/restore path, and corresponding documentation are removed rather than retained as a compatibility path.", "Isolated real-Herdr coverage drives the configured shortcut through native → tree → native, verifies tree ordering and retained decorations, verifies the native mouse grouped/priority toggle works again when tree is off, and verifies a foreign view is never displaced."]
  claimedAt: "2026-09-18T15:19:48Z"
  deliveredAt: "2026-09-18T15:32:56Z"
  validation: ["$ git diff --check", "$ just test", "$ just build"]
  constraints: ["Do not overwrite, clear, or approximate a view owned by another source.", "Do not write `ui.agent_panel_sort` or attempt to synchronize Herdr's client-local header preference.", "Do not retain `agent-tree.cycle` as an alias, fallback, or compatibility path.", "Do not restart the whole Herdr server as the toggle path.", "Do not overwrite `[ui.sidebar.agents]` rows.", "Keep view operations source-checked and preserve the existing one-subscriber and full-clear guarantees."]
  summary: "Verified the ancestry-only replay in this checkout; no files modified and implementation not redone. HEAD = 3faf9618ad1efa1d5cb7a3323d6d7ecef15c3d98, HEAD^ = 67bafa088411ab21e839598f0f9f2fe093ae68fd (the stated replay target), `git diff --check` exits 0, and `git status --porcelain` is empty. The commit's binary diff hashes to ab6d0f17a84161d21a866badf20cf16c888b92334f8ff05738fb2d170c729867 under `git diff HEAD^ HEAD`, `git show --format= --binary HEAD` and `git diff-tree -p HEAD^ HEAD`. The source tree is byte-identical to the previously validated b654038 (`git diff b654038 3faf961 -- . ':(exclude).tandem'` is empty; the only differences are .tandem events/task-13.md), so the native validation results below were run on the identical source before this replay. Task 13 content is unchanged: manifest still exposes start/apply/reload/clear/toggle with no cycle path."
  evidence: ["HEAD, parent and cleanliness: git rev-parse HEAD = 3faf9618ad1efa1d5cb7a3323d6d7ecef15c3d98; git rev-parse HEAD^ = 67bafa088411ab21e839598f0f9f2fe093ae68fd; git status --porcelain empty; git diff --check exit 0.", "Binary diff SHA-256 unchanged: Three equivalent generators (git diff HEAD^ HEAD, git show --format= --binary HEAD, git diff-tree -p HEAD^ HEAD) each hash to ab6d0f17a84161d21a866badf20cf16c888b92334f8ff05738fb2d170c729867, matching the reviewed patch hash.", "Ancestry-only replay, no content change: git diff b654038 3faf961 -- . ':(exclude).tandem' is empty; the only tree differences between the validated b654038 and the replayed 3faf961 are .tandem/tasks/task-13.md and one .tandem event file.", "HEAD^ is the authoritative base, source-identical to current main: git diff --stat 67bafa0 70a8996 (local main) lists only .tandem/events/ce2d8b18-....jsonl and .tandem/tasks/task-13.md; main:herdr-plugin.toml still has id = \"cycle\" (Task 13 not integrated yet).", "Task 13 toggle surface intact after replay: 3faf961's manifest (from the unchanged tree) exposes actions apply/reload/clear/toggle and no cycle alias, with src/mode.rs and tests/e2e/toggle.sh present and src/config.rs/pause.rs/mode-cycle.sh deleted.", "Native validations recorded on the identical source: git diff --check exit 0 (re-run); just test exit 0 and just build exit 0 from the pre-replay tree whose source diff to 3faf961 is empty."]
  filesChanged: ["CHANGELOG.md", "README.md", "docs/agent-tree/task-10-mode-cycle.md", "docs/release.md", "herdr-plugin.toml", "scripts/check.sh", "scripts/deploy.sh", "scripts/release/install.sh", "scripts/stage-local.sh", "src/config.rs", "src/lifecycle.rs", "src/main.rs", "src/mode.rs", "src/pause.rs", "src/projection.rs", "src/transport.rs", "tests/cli_flags.rs", "tests/e2e/mode-cycle.sh", "tests/e2e/toggle.sh"]
  updatedAt: "2026-09-18T15:32:56Z"
createdAt: "2026-09-17T22:44:03Z"
updatedAt: "2026-09-18T15:32:56Z"
assignee: "worker-task-13-51edea24"
archivedAt: "2026-09-18T15:32:56Z"
resolution:
  outcome: "completed"
---
## Description

The grouped/priority/tree cycle shipped by task-11 is the wrong product. Isolated Herdr 0.9.1 evidence established that the native Agents header is a client-local grouped↔priority toggle, any active plugin view disables its hit target, and no plugin API can observe or join that toggle.

Replace the cycle with one supported Herdr keyboard shortcut for turning Agent Tree ordering on and off. The plugin exposes `agent-tree.toggle`, documented through a `[[keys.command]]` binding using `prefix+alt+t`:

- With no active plugin view, toggle installs this plugin's `tree` view.
- When this plugin owns the active view, toggle clears only that view and reveals Herdr's existing native Agents list in whichever grouped/priority order the client already uses.
- When another source owns the active view, toggle refuses clearly and leaves it unchanged; Herdr exposes no view stack that could restore a displaced foreign view.

The subscriber keeps publishing `agent_tree_row` and `agent_tree_rank` while the plugin is enabled, so decorations remain visible with tree ordering on or off. Remove the obsolete three-state cycle and its `ui.agent_panel_sort` write/capture/restore machinery rather than retaining an alias or fallback. `apply` continues to mean show Agent Tree, while `clear` remains the full plugin cleanup path.
