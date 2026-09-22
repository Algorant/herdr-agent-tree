---
id: task-19
type: task
title: "Polish the Herdr plugin install preview"
state: todo
priority: "low"
effort: "small"
references: ["task-8"]
tags: ["papercut", "upstream-herdr", "cli", "ux", "install"]
accord:
  status: "ready"
  acceptance: ["A representative Agent Tree install preview presents plugin identity, source/ref, capabilities, build/startup commands and confirmation in a compact, clearly grouped layout without losing safety-relevant information.", "The successful-install message and config path are visually distinct and easy to scan.", "Automated snapshot or equivalent output tests cover the redesigned preview and completion output for a plugin with build, startup and multiple actions."]
  updatedAt: "2026-09-22T01:01:56Z"
createdAt: "2026-09-22T01:01:56Z"
updatedAt: "2026-09-22T01:01:56Z"
---

## Description

The standard `herdr plugin install` confirmation currently prints a dense, repetitive plaintext inventory of counts and every build/startup/action command. For Agent Tree this is difficult to scan and visually unbalanced despite containing useful safety information. Redesign the upstream Herdr CLI presentation so the identity/source/commit and confirmation are prominent, command capabilities are grouped compactly, and successful installation has a clean completion summary. This is an upstream Herdr CLI UX task tracked here because it is part of Agent Tree's public installation experience.
