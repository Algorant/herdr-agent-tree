---
id: decision-2
type: decision
title: "Replace the three-mode cycle with an owner-safe Agent Tree toggle"
status: "accepted"
deciders: ["Algorant"]
supersedes: ["decision-1"]
createdAt: "2026-09-18T14:52:50Z"
updatedAt: "2026-09-18T14:52:58Z"
decidedAt: "2026-09-18T14:52:58Z"
---

Algorant chose a simpler supported Herdr shortcut after isolated Herdr 0.9.1 evidence proved that the native Agents header cannot participate in a three-state grouped/priority/tree cycle. Agent Tree will expose one toggle action intended for a `[[keys.command]]` binding (documented as `prefix+alt+t`): with no active plugin view it installs the Agent Tree view; when Agent Tree owns the view it clears that view and reveals Herdr's existing native grouped/priority list. It must not write `ui.agent_panel_sort` or attempt to synchronize the client-local header preference. If another source owns the Agents view, the toggle refuses clearly and leaves that view unchanged because Herdr exposes no restorable view stack. Tree decorations remain published while the plugin is enabled, whether its view is on or off. The native mouse header remains Herdr's grouped/priority toggle whenever tree is off and is inert while tree is active, as established by the isolated evidence.
