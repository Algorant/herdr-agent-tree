---
id: task-17
uid: 02170388-fad8-47b5-ba5c-6f5f8256fd18
type: task
kind: "papercut"
title: "worktop cannot run `just test`: just inactive, tmux missing"
priority: "low"
accord:
  status: "ready"
  acceptance: ["On worktop, `just test` runs the full gate with real tmux, or the README states which machines can run the PTY e2e and how to provision one."]
  updatedAt: "2026-10-20T15:49:49Z"
createdAt: "2026-10-20T14:42:40Z"
updatedAt: "2026-10-20T15:49:49Z"
archivedAt: "2026-10-20T15:49:49Z"
resolution:
  outcome: "completed"
  reviewer: "Algorant"
---

## Description

Found during task-16. On worktop, `just` is a mise shim that is not activated for this checkout, and tmux is not installed. tests/e2e/sidebar.sh and toggle.sh hard-require tmux, so the Task validation `$ just test` cannot run here. A Worker fell back to a temporary pyte tmux emulator, which is not real evidence. Provisioning belongs to the dotfiles Ceph's mise/paru profile (worktop), or to a `mise.toml` in this repo for `just`.
