---
id: decision-1
type: decision
title: "Allow runtime writes of ui.agent_panel_sort for the agent-mode cycle"
status: "proposed"
deciders: ["Algorant"]
createdAt: "2026-09-17T22:01:51Z"
updatedAt: "2026-09-17T22:01:51Z"
---

Algorant approved a one-key runtime write of `[ui] agent_panel_sort` so the plugin can cycle grouped → priority → tree → grouped. There is no Herdr socket/CLI method to set native agent-panel sort.

The writer may change only that key (spaces or priority), must capture and restore the user's original value on clear/uninstall, must not touch `[ui.sidebar.agents]` rows, and must not invent a plugin-view approximation of native grouped/priority.
