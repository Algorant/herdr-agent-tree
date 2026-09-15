//! Projection: the two plugin-owned pane tokens and the single Agents view.

use crate::forest::Placement;
use crate::transport::Model;
use crate::wire::{request, R};
use serde_json::{json, Map, Value};
use std::collections::HashMap;

/// The only two pane keys this plugin ever writes.
pub const ROW_TOKEN: &str = "agent_tree_row";
pub const RANK_TOKEN: &str = "agent_tree_rank";
/// Metadata report source.
pub const SOURCE: &str = "agent-tree";
/// View ownership source; the `plugin:` form is required by Herdr.
pub const VIEW_SOURCE: &str = "plugin:agent-tree";
pub const VIEW_LABEL: &str = "tree";

/// Widest rank the fixed-width encoding supports.
pub const MAX_RANKS: usize = 999_999;

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
    pub row: Option<String>,
    pub rank: Option<String>,
}

pub fn desired(placements: &[Placement]) -> HashMap<String, Desired> {
    let mut map = HashMap::new();
    for placement in placements {
        let row = crate::decoration::decoration(
            placement.depth,
            placement.is_last_sibling,
            &placement.role,
            placement.task_id.as_deref(),
            placement.attention,
        );
        map.insert(
            placement.pane_id.clone(),
            Desired {
                row,
                rank: Some(format!("{:06}", placement.rank)),
            },
        );
    }
    map
}

/// Writes only the differences, one report per pane, both keys together when both change.
/// Rows that should carry nothing have their plugin-owned keys cleared.
pub fn reconcile_tokens(
    socket: &str,
    model: &mut Model,
    desired: &HashMap<String, Desired>,
) -> R<usize> {
    let mut writes = 0usize;
    let snapshot: Vec<(String, Option<String>, Option<String>)> = model
        .ordered_rows()
        .into_iter()
        .map(|row| (row.pane_id.clone(), row.token(ROW_TOKEN), row.token(RANK_TOKEN)))
        .collect();
    for (pane_id, current_row, current_rank) in snapshot {
        let want = desired.get(&pane_id).cloned().unwrap_or_default();
        if current_row == want.row && current_rank == want.rank {
            continue;
        }
        let mut tokens = Map::new();
        if current_row != want.row {
            tokens.insert(ROW_TOKEN.to_string(), optional(&want.row));
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
                model.set_token(&pane_id, ROW_TOKEN, want.row.clone());
                model.set_token(&pane_id, RANK_TOKEN, want.rank.clone());
                writes += 1;
            }
            Err(e) => eprintln!("agent-tree: {e}"),
        }
    }
    Ok(writes)
}

/// Clears exactly the two plugin-owned keys on every pane that carries them.
pub fn clear_own_tokens(socket: &str, model: &mut Model) -> usize {
    let snapshot: Vec<(String, Option<String>, Option<String>)> = model
        .ordered_rows()
        .into_iter()
        .map(|row| (row.pane_id.clone(), row.token(ROW_TOKEN), row.token(RANK_TOKEN)))
        .collect();
    let mut cleared = 0usize;
    for (pane_id, current_row, current_rank) in snapshot {
        if current_row.is_none() && current_rank.is_none() {
            continue;
        }
        let mut tokens = Map::new();
        tokens.insert(ROW_TOKEN.to_string(), Value::Null);
        tokens.insert(RANK_TOKEN.to_string(), Value::Null);
        let params = json!({
            "pane_id": pane_id,
            "source": SOURCE,
            "tokens": Value::Object(tokens),
        });
        match request(socket, "pane.report_metadata", params) {
            Ok(_) => {
                model.set_token(&pane_id, ROW_TOKEN, None);
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
    let active = result.get("active").and_then(Value::as_bool).unwrap_or(false);
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
