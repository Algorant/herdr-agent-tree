---
id: task-15
uid: 8cf828a1-d374-4f37-ab39-b20f5c1f6f5e
type: task
kind: "research"
title: "Research: nest a workspace's non-main tab agents (manus) under its main-tab agent (Ceph)"
state: todo
priority: "medium"
relatedFiles: ["README.md", "docs/agent-tree/m2-contract.md", "src/forest.rs", "src/identity.rs", "src/decoration.rs"]
tags: ["research", "identity", "nesting"]
accord:
  status: "ready"
  acceptance: ["A written comparison of options (a), (b) and (c) covers identity validation, the \"never infer\" rule, recency ranking, Workers and Subagents already nested, and cross-workspace/cross-machine cases.", "An html Sideshow post shows st's current sidebar next to the proposed nesting, including a Worker under main and a Subagent under a Worker, with 1-2 variants where the design has real choices.", "Herdra receives one request with this Task ID, the Sideshow session URL, the key findings and a recommended option, stating how it respects or changes the never-infer rule.", "No plugin or publisher code changes are made under this Task."]
  updatedAt: "2026-10-19T19:59:46Z"
createdAt: "2026-10-19T19:59:46Z"
updatedAt: "2026-10-19T19:59:46Z"
---

## Description

Requested by Algorant via Herdra (agent message m70e00934, worktop). Research and Sideshow mockups first; no code.

Today a project's manus (long-running Pi agents Herdra starts with `herdr agent start` in other tabs of the project's workspace, e.g. st's w8: st-prod/prod-publish, st-captis/captis, st-dhc/dhc, st-moa/moa) render as separate roots, while Workers already nest under the Ceph (the `main` tab agent, `st`) through pi-agency's `role`/`agency_self`/`agency_parent` tokens. Manus carry no relationship tokens.

Investigate read-only the options and trade-offs: (a) plugin-side rule that the `main` tab agent roots its workspace; (b) an explicit relationship published by the manus' launcher or by the Ceph; (c) anything Herdr offers natively for grouping by workspace/tab. Cover the README/contract C2/C5 "never infer" rule, identity validation, recency ranking, Workers already nested under main, Subagents under Workers, and cross-workspace / cross-machine cases. Publish html Sideshow mockups (current vs proposed, 1-2 variants) before any code, and recommend one option to Herdra.
