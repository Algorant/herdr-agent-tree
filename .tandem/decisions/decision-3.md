---
id: decision-3
type: decision
title: "Use Herdr-managed source builds as the sole public install path"
status: "proposed"
deciders: ["Algorant"]
references: ["task-8", "task-7"]
tags: ["release", "installation", "architecture"]
createdAt: "2026-09-21T01:35:42Z"
updatedAt: "2026-09-21T01:35:42Z"
---

Algorant chose the ecosystem-native source-build model for v0.1.0. The authoritative user path is `herdr plugin install Algorant/herdr-agent-tree --ref v0.1.0`, backed by a manifest `[[build]]` command that runs locked Cargo release compilation. Remove the bespoke checksum installer, binary archive promotion/evidence gates, and plugin-link release path rather than retaining them as alternatives. Keep `scripts/deploy.sh` and explicit-endpoint deployment only as development/admin tooling. GitHub publication may still create an immutable source release/tag, but Herdr owns installation, registration and rebuild/update behavior.
