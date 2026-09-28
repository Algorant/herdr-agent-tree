//! Projection: the descendant branch token, rank token, and the single Agents view.

use crate::forest::Placement;
use crate::transport::Model;
use crate::wire::{request, R};
use serde_json::{json, Map, Value};
use std::collections::HashMap;

/// The current decoration token: branch/role marker and, for Subagents, a short own name.
pub const BRANCH_TOKEN: &str = "agent_tree_branch";
/// Previous composed token, cleared on upgrade but never written again.
pub const LEGACY_ROW_TOKEN: &str = "agent_tree_row";
/// Rank is published for ordering only.
pub const RANK_TOKEN: &str = "agent_tree_rank";
/// Metadata report source.
pub const SOURCE: &str = "agent-tree";
/// View ownership source; the `plugin:` form is required by Herdr.
pub const VIEW_SOURCE: &str = "plugin:agent-tree";
pub const VIEW_LABEL: &str = "tree";
/// A source that never owns the view, so `agent.view.clear` with it is a pure ownership
/// probe: a source mismatch leaves the active view unchanged (task-10 §1.2).
pub const VIEW_PROBE_SOURCE: &str = "plugin:agent-tree-probe";

/// Widest rank the fixed-width encoding supports.
pub const MAX_RANKS: usize = 999_999;

/// True while `count` rankable rows fit the fixed-width rank space. Above it the plugin
/// publishes nothing: no wrap, no partial publication.
pub const fn within_rank_ceiling(count: usize) -> bool {
    count <= MAX_RANKS
}

pub fn sort_spec() -> Value {
    json!([
        {"field": {"token": RANK_TOKEN}, "order": "asc"},
        {"field": "workspace_order", "order": "asc"},
        {"field": "tab_order", "order": "asc"},
        {"field": "pane_order", "order": "asc"}
    ])
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Desired {
    pub branch: Option<String>,
    pub rank: Option<String>,
}

struct TokenSnapshot {
    pane_id: String,
    branch: Option<String>,
    legacy_row: Option<String>,
    rank: Option<String>,
}

fn token_snapshot(model: &Model) -> Vec<TokenSnapshot> {
    model
        .ordered_rows()
        .into_iter()
        .map(|row| TokenSnapshot {
            pane_id: row.pane_id.clone(),
            branch: row.token(BRANCH_TOKEN),
            legacy_row: row.token(LEGACY_ROW_TOKEN),
            rank: row.token(RANK_TOKEN),
        })
        .collect()
}

pub fn desired(model: &Model, placements: &[Placement]) -> HashMap<String, Desired> {
    let placements: HashMap<&str, &Placement> = placements
        .iter()
        .map(|placement| (placement.pane_id.as_str(), placement))
        .collect();
    let mut map = HashMap::new();
    for row in model.ordered_rows() {
        let placement = placements.get(row.pane_id.as_str()).copied();
        let branch = if row.cleanup_only {
            None
        } else {
            placement
                .filter(|placement| placement.depth > 0)
                .and_then(|placement| {
                    crate::decoration::descendant(
                        placement.depth,
                        placement.is_last_sibling,
                        &placement.role,
                        (placement.role == "subagent")
                            .then(|| child_name(row))
                            .flatten(),
                    )
                })
        };
        map.insert(
            row.pane_id.clone(),
            Desired {
                branch,
                rank: placement
                    .filter(|_| !row.cleanup_only)
                    .map(|placement| format!("{:06}", placement.rank)),
            },
        );
    }
    map
}

fn child_name(row: &crate::transport::AgentRow) -> Option<&str> {
    row.name
        .as_deref()
        .or_else(|| {
            row.terminal_title_stripped
                .as_deref()
                .map(strip_pi_title_prefix)
        })
        .filter(|name| !name.trim().is_empty())
}

fn strip_pi_title_prefix(title: &str) -> &str {
    title.strip_prefix("π - ").unwrap_or(title)
}

/// Writes only the differences, clearing the 0.2.0 composed token during migration.
/// Ranks are unchanged; only validated descendants receive the current branch token.
pub fn reconcile_tokens(
    socket: &str,
    model: &mut Model,
    desired: &HashMap<String, Desired>,
) -> R<usize> {
    let mut writes = 0usize;
    for TokenSnapshot {
        pane_id,
        branch: current_branch,
        legacy_row: current_legacy,
        rank: current_rank,
    } in token_snapshot(model)
    {
        let want = desired.get(&pane_id).cloned().unwrap_or_default();
        if current_branch == want.branch && current_legacy.is_none() && current_rank == want.rank {
            continue;
        }
        let mut tokens = Map::new();
        if current_branch != want.branch {
            tokens.insert(BRANCH_TOKEN.to_string(), optional(&want.branch));
        }
        if current_legacy.is_some() {
            tokens.insert(LEGACY_ROW_TOKEN.to_string(), Value::Null);
        }
        if current_rank != want.rank {
            tokens.insert(RANK_TOKEN.to_string(), optional(&want.rank));
        }
        let params = json!({
            "pane_id": pane_id,
            "source": SOURCE,
            "tokens": Value::Object(tokens),
        });
        match request(socket, "pane.report_metadata", params) {
            Ok(_) => {
                model.set_token(&pane_id, BRANCH_TOKEN, want.branch.clone());
                model.set_token(&pane_id, LEGACY_ROW_TOKEN, None);
                model.set_token(&pane_id, RANK_TOKEN, want.rank.clone());
                writes += 1;
            }
            Err(e) => eprintln!("agent-tree: {e}"),
        }
    }
    Ok(writes)
}

/// Clears the current branch, legacy composed row and rank, preserving all other sources.
pub fn clear_own_tokens(socket: &str, model: &mut Model) -> usize {
    let mut cleared = 0usize;
    for TokenSnapshot {
        pane_id,
        branch: current_branch,
        legacy_row: current_legacy,
        rank: current_rank,
    } in token_snapshot(model)
    {
        if current_branch.is_none() && current_legacy.is_none() && current_rank.is_none() {
            continue;
        }
        let mut tokens = Map::new();
        tokens.insert(BRANCH_TOKEN.to_string(), Value::Null);
        tokens.insert(LEGACY_ROW_TOKEN.to_string(), Value::Null);
        tokens.insert(RANK_TOKEN.to_string(), Value::Null);
        let params = json!({
            "pane_id": pane_id,
            "source": SOURCE,
            "tokens": Value::Object(tokens),
        });
        match request(socket, "pane.report_metadata", params) {
            Ok(_) => {
                model.set_token(&pane_id, BRANCH_TOKEN, None);
                model.set_token(&pane_id, LEGACY_ROW_TOKEN, None);
                model.set_token(&pane_id, RANK_TOKEN, None);
                cleared += 1;
            }
            Err(e) => eprintln!("agent-tree: {e}"),
        }
    }
    cleared
}

fn optional(value: &Option<String>) -> Value {
    match value {
        Some(value) => Value::String(value.clone()),
        None => Value::Null,
    }
}

/// Ownership state for the lifetime of one subscriber process.
#[derive(Debug, Default)]
pub struct ViewState {
    attempted: bool,
    owned: bool,
    passive: bool,
    /// True once this process has confirmed the plugin's own view is not active. Reset
    /// whenever the view is (re)installed, so an off -> on -> off cycle clears again.
    cleared: bool,
}

impl ViewState {
    pub fn owned(&self) -> bool {
        self.owned
    }

    pub fn passive(&self) -> bool {
        self.passive
    }
}

/// Installs the projection once per process, refusing to displace another owner.
///
/// The owner is read with a source-checked clear, whose documented behaviour is that a
/// source mismatch leaves the active view unchanged. If the owner cannot be determined the
/// plugin stays passive rather than guessing or clearing unconditionally.
pub fn ensure_view(socket: &str, state: &mut ViewState) -> R<()> {
    if state.passive {
        return Ok(());
    }
    state.cleared = false;
    if !state.attempted {
        state.attempted = true;
        match request(socket, "agent.view.clear", json!({"source": VIEW_SOURCE})) {
            Ok(result) => {
                let active = result.get("active").and_then(Value::as_bool);
                let owner = result
                    .get("source")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                match active {
                    Some(false) => {}
                    Some(true) if owner == VIEW_SOURCE => {}
                    Some(true) => {
                        eprintln!(
                            "agent-tree: view is owned by {owner}; staying passive for this process"
                        );
                        state.passive = true;
                        return Ok(());
                    }
                    None => {
                        eprintln!(
                            "agent-tree: could not determine the current view owner; staying passive"
                        );
                        state.passive = true;
                        return Ok(());
                    }
                }
            }
            Err(e) => {
                eprintln!("agent-tree: view owner probe failed ({e}); staying passive");
                state.passive = true;
                return Ok(());
            }
        }
    }

    let result = request(
        socket,
        "agent.view.set",
        json!({"source": VIEW_SOURCE, "label": VIEW_LABEL, "sort": sort_spec()}),
    )?;
    let active = result
        .get("active")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let owner = result
        .get("source")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if active && owner == VIEW_SOURCE {
        state.owned = true;
        Ok(())
    } else {
        eprintln!("agent-tree: view set was not accepted as ours ({result}); staying passive");
        state.owned = false;
        state.passive = true;
        Ok(())
    }
}

/// Source-checked view clear. Never unconditional; a foreign owner is left untouched.
pub fn clear_view(socket: &str) -> R<Value> {
    request(socket, "agent.view.clear", json!({"source": VIEW_SOURCE}))
}

/// Ensures the plugin's own view is not active, leaving an absent or foreign view alone.
///
/// The clear is source-checked, so it is safe to call whether the view is ours, absent or
/// foreign, and it is a no-op after the first successful confirmation within one process.
/// Tokens are never touched here: Agent Tree decorations stay published with the view off.
pub fn ensure_view_cleared(socket: &str, state: &mut ViewState) -> R<()> {
    if state.cleared {
        return Ok(());
    }
    clear_view(socket)?;
    state.cleared = true;
    state.owned = false;
    Ok(())
}

/// Read-only ownership probe. Uses a source that can never own the view, so the call reports
/// the active owner (`active`, `source`, `label`) without clearing anything.
pub fn probe_view(socket: &str) -> R<Value> {
    request(
        socket,
        "agent.view.clear",
        json!({"source": VIEW_PROBE_SOURCE}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transport::Model;

    fn model(rows: Vec<crate::transport::AgentRow>) -> Model {
        let mut model = Model::default();
        model.install(rows);
        model
    }

    fn placement(pane_id: &str, depth: usize, rank: u32) -> Placement {
        Placement {
            pane_id: pane_id.to_string(),
            depth,
            is_last_sibling: true,
            role: "worker".to_string(),
            rank,
        }
    }

    #[test]
    fn view_sort_spec_is_exact_and_puts_rank_before_native_order() {
        assert_eq!(
            sort_spec(),
            json!([
                {"field": {"token": RANK_TOKEN}, "order": "asc"},
                {"field": "workspace_order", "order": "asc"},
                {"field": "tab_order", "order": "asc"},
                {"field": "pane_order", "order": "asc"}
            ])
        );
    }

    #[test]
    fn ranks_are_six_digit_and_lexicographic_order_matches_numeric_order() {
        assert_eq!(MAX_RANKS, 999_999);
        let mut previous: Option<String> = None;
        for rank in 1..=1_000u32 {
            let model = model(vec![crate::testutil::pi_row("p", "/s/p")]);
            let mut map = desired(&model, &[placement("p", 0, rank)]);
            let want = map.remove("p").unwrap().rank.unwrap();
            assert_eq!(want, format!("{rank:06}"));
            assert_eq!(want.len(), 6);
            if let Some(previous) = previous {
                assert!(previous < want, "{previous} must sort before {want}");
            }
            previous = Some(want);
        }
        assert_eq!(format!("{:06}", MAX_RANKS), "999999");
        assert_eq!(format!("{:06}", MAX_RANKS + 1).len(), 7);
    }

    #[test]
    fn rank_ceiling_is_exact_at_the_documented_maximum() {
        assert!(within_rank_ceiling(0));
        assert!(within_rank_ceiling(MAX_RANKS));
        assert!(!within_rank_ceiling(MAX_RANKS + 1));
    }

    #[test]
    fn unlinked_rows_receive_no_rank_and_are_left_out_of_the_projection() {
        let model = model(vec![
            crate::testutil::pi_row("linked", "/s/linked"),
            crate::testutil::pi_row("unlinked", "/s/unlinked"),
        ]);
        let map = desired(&model, &[placement("linked", 0, 1)]);
        assert_eq!(map["linked"].rank.as_deref(), Some("000001"));
        assert_eq!(map["linked"].branch, None, "roots carry no marker");
        assert_eq!(map["unlinked"].rank, None);
        assert_eq!(
            map["unlinked"].branch, None,
            "ordinary agents carry no marker"
        );
    }

    #[test]
    fn roots_publish_only_the_rank_and_leave_native_workspace_tab_cells_to_herdr() {
        let model = model(vec![crate::testutil::pi_row("root", "/s/root")]);
        let mut map = desired(&model, &[placement("root", 0, 1)]);
        let root = map.remove("root").unwrap();
        assert_eq!(root.branch, None);
        assert_eq!(root.rank.as_deref(), Some("000001"));
    }

    #[test]
    fn worker_decoration_contains_only_the_marker() {
        let worker = crate::testutil::linked("worker", "/s/worker", "worker", "parent");
        let mut map = desired(&model(vec![worker]), &[placement("worker", 1, 2)]);
        assert_eq!(map.remove("worker").unwrap().branch.as_deref(), Some("└─W"));
    }

    #[test]
    fn subagent_decoration_contains_its_short_own_name() {
        let mut subagent = crate::testutil::linked("sub", "/s/sub", "subagent", "parent");
        subagent.name = Some("live-sidebar-verification".to_string());
        let mut map = desired(
            &model(vec![subagent]),
            &[Placement {
                role: "subagent".to_string(),
                ..placement("sub", 1, 2)
            }],
        );
        assert_eq!(
            map.remove("sub").unwrap().branch.as_deref(),
            Some("└─S live-sideba…")
        );
    }

    #[test]
    fn cleanup_only_rows_clear_all_plugin_tokens_instead_of_getting_a_display() {
        let orphan = crate::testutil::with_token(
            crate::testutil::with_token(
                crate::testutil::with_token(
                    crate::testutil::other_row("released"),
                    LEGACY_ROW_TOKEN,
                    "stale display",
                ),
                BRANCH_TOKEN,
                "└─S stale",
            ),
            RANK_TOKEN,
            "000007",
        );
        let mut orphan = orphan;
        orphan.cleanup_only = true;
        let desired = desired(&model(vec![orphan]), &[]);
        assert_eq!(desired["released"].branch, None);
        assert_eq!(desired["released"].rank, None);
    }

    #[test]
    fn subagent_name_falls_back_to_title_and_ordinary_agents_get_no_token() {
        let mut subagent = crate::testutil::linked("sub", "/s/sub", "subagent", "parent");
        subagent.name = None;
        subagent.terminal_title_stripped = Some("π - live-sidebar-verify".to_string());
        let codex = crate::testutil::other_row("codex");
        let map = desired(
            &model(vec![subagent, codex]),
            &[Placement {
                role: "subagent".to_string(),
                ..placement("sub", 1, 1)
            }],
        );
        assert_eq!(map["sub"].branch.as_deref(), Some("└─S live-sideba…"));
        assert_eq!(map["codex"].branch, None);
        assert_eq!(map["codex"].rank, None);
    }
}
