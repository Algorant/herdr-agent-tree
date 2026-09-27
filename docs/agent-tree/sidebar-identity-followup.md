# Sidebar identity follow-up (historical local investigation; superseded)

This note records an earlier local configuration choice and predates the approved one-cell
Agent Tree implementation. It is historical context, not current guidance: the plugin now
composes location or validated descendant identity into `$agent_tree_row`, and the managed
sidebar row is `[["state_icon", "$agent_tree_row"]]`. See the current contract in `README.md`.

## Current local choice and reproduction

Algorant prefers a compact one-line Agent panel on this machine:

```toml
[ui.sidebar.agents]
rows = [["state_icon", "workspace", "tab"]]
```

This is **local Herdr config, not the plugin's shipped/default layout**. The plugin still owns the `tree` sort view and publishes `agent_tree_rank` and `agent_tree_row`, but the row template does not render the latter.

On Herdr 0.9.1 with a live parent and read-only Subagent in the same workspace and tab (`w1:tZ`), `herdr agent list` identified separate panes `w1:p1T` and `w1:p2H` (titles `π - Algomarchy` and `π - identity-fixture - Algomarchy`). `herdr pane list --workspace w1` showed the child's `role=subagent` and `agent_tree_row=└─S`, while the parent had neither. A second, temporary tmux-backed client at 150×48 rendered both entries identically in the selected one-line layout:

```text
agents                        tree
◐ Algomarchy · herdr-agent-tree
◐ Algomarchy · herdr-agent-tree
```

The live child remains ordered beside its parent but is not visually distinguishable; two same-tab roots would also be indistinguishable. This is a real information loss accepted for the compact local view, not a repaired version of task-4's identity criterion. No historical Tandem record was edited.

## Tested config-only alternatives

| Temporary-client row config | Observation at the local sidebar width | Cost |
| --- | --- | --- |
| `[["state_icon", "workspace", "tab", "$agent_tree_row", "machine"]]` | The child branch appears, but the tab is clipped earlier than on a root, and the machine does not right-align. | One line, uneven/clipped. |
| `[["state_icon", "workspace", "tab", "machine"], ["$agent_tree_row"]]` | Root has one line; a child gets an additional branch line. | Mixed one/two-line heights, child lacks its name. |
| `[["state_icon", "workspace", "tab"], ["$agent_tree_row", "machine"]]` | Complete tab on line one; root's `Local` and child's `└─S · Local` on line two. | Uniform two-line height; fewer visible agents. |
| One-line five-cell layout with `sidebar_width = sidebar_min_width = sidebar_max_width = 40` | Child tab still clips (`herdr-ag…`) when its branch is present. | Wider sidebar without preserving all fields. |

Each preview used a temporary `HERDR_CONFIG_PATH` client and `herdr config check`; it did not replace the live config. The live layout was restored after testing, then explicitly set to the one-line choice above by Algorant.

[Herdr 0.9.1's sidebar documentation](https://herdr.dev/docs/configuration/#sidebar-row-layouts) permits token ordering, `fg`/`bold`/`dim` styling, and value-based hide rules. Empty rows disappear. It does not describe column widths, per-token right alignment, or row-wide conditional styles based on another token. Public configs such as [herdr-agent-index](https://github.com/kadaliao/herdr-agent-index), [herdr-pane-issue](https://github.com/ilazaridis/herdr-pane-issue), and [herdr-agent-context](https://github.com/ryonakae/herdr-agent-context) use multiple lines rather than a fixed grid.

## Recommendation

Do not change Agent Tree's identity validation or decoration grammar to compensate for the chosen local layout. If visible delegation in a single line becomes required again, first specify which fields must survive at actual sidebar widths and investigate a small **Herdr sidebar renderer/config enhancement** (for example, field-priority truncation or fixed/anchored cells). A plugin-only composite string would need to guess the client width and machine label and would repeat a layout responsibility that belongs to the client.

A follow-up implementation task should have a runnable visual check: in an isolated Herdr client, render a same-workspace/same-tab root and child at widths 26, 32, 36 and 40, assert the child role/branch remains visible, and assert that the selected location fields survive the chosen truncation policy. Keep the local one-line view unchanged until Algorant selects that policy.
