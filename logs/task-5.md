---
id: task-5
uid: b7b2e53e-5739-44b7-b3f0-c1d686767cf7
type: task
title: "Render readable Agent rows when an endpoint lacks a compatible Agent Tree plugin"
priority: "high"
effort: "medium"
relatedFiles: ["README.md", "scripts/lib/config.py", "scripts/deploy.sh", "scripts/activate-managed.sh", "src/projection.rs", "tests/e2e/sidebar.sh", "tests/shell/doctor.sh"]
tags: ["ux", "plan-first", "multi-machine"]
accord:
  status: "accepted"
  acceptance: ["In an isolated Herdr client, an agent whose pane has no `agent_tree_row` (no plugin, old plugin, stopped subscriber) renders readable native identity (e.g. workspace · tab or agent name) instead of an icon-only row, at 26/32/36 widths.", "Where the current plugin row IS present, the row still shows only the composed value once: no duplicated workspace/tab or `π -` title.", "Behavior for unreachable or incompatible saved machines is observed and documented; the doctor flags endpoints that will render degraded rows.", "Managed config fragments, deploy/activation defaults and README describe the fallback; foreign user config is still never rewritten silently."]
  claimedAt: "2026-09-28T16:26:18Z"
  deliveredAt: "2026-09-28T20:02:34Z"
  validation: ["$ scripts/check.sh", "$ cargo build --locked --release"]
  summary: "Applied both requested rework fixes and committed them without changing the 0.2.0 package/plugin versions. Managed old rows now migrate through deploy; doctor capability is affirmative only from observed `agent_tree_branch` tokens or a future 0.3.0+ version. Full project checks, release build, and Rust 1.81 tests pass. Commits: `b232c79` and `7d7da62`; checkout is clean."
  evidence: ["Verbatim isolated renderer capture at 26 columns.:      | agents              tree│\n     | ○ root-alpha · main     │\n     | ○ ├─S s… · root-… · main│\n     | ○ ├─S l… · root-… · main│\n     | ○ └─W · task-5 · herdr-…│\n     | ○ lone-1                │\n     | ○ lone-2                │\n     | ○ codex-1               │", "Verbatim isolated renderer capture at 32 columns.:      | agents                    tree│\n     | ○ root-alpha · main           │\n     | ○ ├─S scou… · root-alp… · main│\n     | ○ ├─S live… · root-alp… · main│\n     | ○ └─W · task-5 · herdr-agent-…│\n     | ○ lone-1                      │\n     | ○ lone-2                      │\n     | ○ codex-1                     │", "Verbatim isolated renderer capture at 36 columns.:      | agents                        tree│\n     | ○ root-alpha · main               │\n     | ○ ├─S scout-r… · root-alpha · main│\n     | ○ ├─S live-si… · root-alpha · main│\n     | ○ └─W · task-5 · herdr-agent-tree │\n     | ○ lone-1                          │\n     | ○ lone-2                          │\n     | ○ codex-1                         │", "A pane carrying only a stale 0.2.0 composed value does not duplicate it under the new row.: The isolated PTY showed `legacy-only pane:  ○ lone-1                │` while that pane had only `agent_tree_row=obsolete-composed-location`; the obsolete value was absent. The real plugin was restarted after the check and cleared the stale token.", "Herdr managed-vs-foreign classification and doctor capability evidence are correct.: Marked old managed rows no longer trigger either foreign flag and deploy upgrades their block. Doctor now treats a 0.2.0 endpoint as branch-capable only when a pane actually reports `agent_tree_branch`; with zero agents/tokens it reports capability unproven and `rows fall back to native workspace · tab without tree markers`. Version 0.3.0+ can prove support by version."]
  filesChanged: ["CHANGELOG.md", "Cargo.lock", "Cargo.toml", "README.md", "scripts/activate-managed.sh", "scripts/deploy-endpoint.sh", "scripts/deploy.sh", "scripts/lib/config.py", "scripts/lib/report.py", "src/decoration.rs", "src/forest.rs", "src/identity.rs", "src/lifecycle.rs", "src/mode.rs", "src/projection.rs", "src/testutil.rs", "src/transport.rs", "tests/e2e/sidebar.sh", "tests/e2e/toggle.sh", "tests/shell/activate-managed.sh", "tests/shell/deploy-endpoint.sh", "tests/shell/dev-reload.sh", "tests/shell/doctor.sh"]
  updatedAt: "2026-09-28T20:02:34Z"
createdAt: "2026-09-27T13:06:54Z"
updatedAt: "2026-09-28T20:02:34Z"
assignee: "worker-task-5-3edcc573"
archivedAt: "2026-09-28T20:02:34Z"
resolution:
  outcome: "completed"
---

## Description

After task-3, the managed sidebar row is `[["state_icon", "$agent_tree_row"]]`, so the plugin composes the entire visible text. A Herdr client viewing agents from a saved machine that has no plugin, an older plugin (v0.1.0 publishes no row for ordinary agents), a stopped/crashed subscriber, or an unreachable/incompatible endpoint renders those agents as a bare state icon with no text. This was observed live: with desktop and cartlab enabled, their agents appeared as blank rows in the local Agents panel. Mixed-version and partially reachable fleets are normal, so the display must degrade to readable native identity rather than blank rows. Investigate Herdr 0.9.x row-config capabilities (token fallback, hide/equals rules, rows_by_agent, multi-cell composition) and plugin-side options before choosing; do not guess at renderer behavior. Keep one-line-per-agent and no duplicated location/title when the plugin row IS present.
