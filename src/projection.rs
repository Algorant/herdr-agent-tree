//! Projection: one composed display token, the rank token, and the single Agents view.

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
    pub row: Option<String>,
    pub rank: Option<String>,
}

pub fn desired(model: &Model, placements: &[Placement]) -> HashMap<String, Desired> {
    let placements: HashMap<&str, &Placement> = placements
        .iter()
        .map(|placement| (placement.pane_id.as_str(), placement))
        .collect();
    let mut map = HashMap::new();
    for row in model.ordered_rows() {
        let placement = placements.get(row.pane_id.as_str()).copied();
        if row.cleanup_only {
            map.insert(row.pane_id.clone(), Desired::default());
            continue;
        }
        let display = match placement.filter(|placement| placement.depth > 0) {
            Some(placement) => crate::decoration::descendant(
                placement.depth,
                placement.is_last_sibling,
                &placement.role,
                child_name(row),
                placement.task_id.as_deref(),
                placement.attention,
            ),
            _ => ordinary_display(row, placement.and_then(|placement| placement.attention)),
        };
        map.insert(
            row.pane_id.clone(),
            Desired {
                row: Some(display),
                rank: placement.map(|placement| format!("{:06}", placement.rank)),
            },
        );
    }
    map
}

fn child_name(row: &crate::transport::AgentRow) -> &str {
    row.name
        .as_deref()
        .or_else(|| {
            row.terminal_title_stripped
                .as_deref()
                .map(strip_pi_title_prefix)
        })
        .filter(|name| !name.trim().is_empty())
        .unwrap_or("(unnamed)")
}

fn strip_pi_title_prefix(title: &str) -> &str {
    title.strip_prefix("π - ").unwrap_or(title)
}

fn ordinary_display(row: &crate::transport::AgentRow, attention: Option<char>) -> String {
    let workspace = row
        .workspace_label
        .as_deref()
        .map(clean_display)
        .filter(|label| !label.is_empty());
    let tab = row
        .tab_label
        .as_deref()
        .map(clean_display)
        .filter(|label| !label.is_empty());
    let location = match (workspace, tab) {
        (Some(workspace), Some(tab)) => Some(format!("{workspace} · {tab}")),
        (Some(workspace), None) => Some(workspace),
        (None, Some(tab)) => Some(tab),
        (None, None) => None,
    };
    let display = if row.agent == "pi" {
        location
            .or_else(|| {
                row.name
                    .as_deref()
                    .map(clean_display)
                    .filter(|name| !name.is_empty())
            })
            .or_else(|| {
                row.terminal_title_stripped
                    .as_deref()
                    .map(strip_pi_title_prefix)
                    .map(clean_display)
                    .filter(|title| !title.is_empty())
            })
            .unwrap_or_else(|| clean_display(&row.agent))
    } else {
        let identity = row
            .name
            .as_deref()
            .map(clean_display)
            .filter(|name| !name.is_empty())
            .or_else(|| (!row.agent.is_empty()).then(|| clean_display(&row.agent)));
        match (identity, location) {
            (Some(identity), Some(location)) => format!("{identity} · {location}"),
            (Some(identity), None) => identity,
            (None, Some(location)) => location,
            (None, None) => "agent".to_string(),
        }
    };
    let display = match attention {
        Some(glyph) if display.chars().count() + 2 <= 64 => format!("{display} {glyph}"),
        Some(glyph) => format!("{} {glyph}", truncate_display(&display, 62)),
        None => display,
    };
    truncate_display(&display, 64)
}

fn clean_display(value: &str) -> String {
    value
        .chars()
        .filter_map(|ch| {
            if ch.is_control() {
                ch.is_whitespace().then_some(' ')
            } else {
                Some(ch)
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn truncate_display(value: &str, limit: usize) -> String {
    value.chars().take(limit).collect()
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
        .map(|row| {
            (
                row.pane_id.clone(),
                row.token(ROW_TOKEN),
                row.token(RANK_TOKEN),
            )
        })
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
        .map(|row| {
            (
                row.pane_id.clone(),
                row.token(ROW_TOKEN),
                row.token(RANK_TOKEN),
            )
        })
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
    use crate::decoration::MAX_WIDTH;
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
            task_id: None,
            attention: None,
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
        assert_eq!(map["unlinked"].rank, None);
        assert_eq!(map["unlinked"].row.as_deref(), Some("Workspace · Tab"));
    }

    #[test]
    fn root_rows_show_location_and_retain_their_rank() {
        let model = model(vec![crate::testutil::pi_row("root", "/s/root")]);
        let mut map = desired(&model, &[placement("root", 0, 1)]);
        let root = map.remove("root").unwrap();
        assert_eq!(root.row.as_deref(), Some("Workspace · Tab"));
        assert_eq!(root.rank.as_deref(), Some("000001"));
    }

    #[test]
    fn validated_depth_zero_root_attention_is_preserved_after_location() {
        let model = model(vec![crate::testutil::pi_row("root", "/s/root")]);
        let mut root = placement("root", 0, 1);
        root.attention = Some('!');
        let map = desired(&model, &[root]);
        assert_eq!(map["root"].row.as_deref(), Some("Workspace · Tab !"));
    }

    #[test]
    fn desired_applies_the_decoration_cap() {
        let placement = Placement {
            task_id: Some("task-123456789012345".to_string()),
            ..placement("worker", 2, 4)
        };
        let mut worker = crate::testutil::linked("worker", "/s/worker", "worker", "parent");
        worker.name = Some("worker-task-3-78712afb".to_string());
        let model = model(vec![worker]);
        let mut map = desired(&model, &[placement]);
        let row = map.remove("worker").unwrap().row.unwrap();
        assert!(row.chars().count() <= MAX_WIDTH, "{row:?}");
        assert!(row.starts_with("│  └─W worker-task-3"), "{row:?}");
    }

    #[test]
    fn cleanup_only_rows_clear_owned_row_and_rank_instead_of_getting_a_display() {
        let mut orphan = crate::testutil::with_token(
            crate::testutil::other_row("released"),
            ROW_TOKEN,
            "stale display",
        );
        orphan = crate::testutil::with_token(orphan, RANK_TOKEN, "000007");
        orphan.cleanup_only = true;
        let model = model(vec![orphan]);
        let desired = desired(&model, &[]);
        assert_eq!(desired["released"].row, None);
        assert_eq!(desired["released"].rank, None);
    }

    #[test]
    fn descendants_use_name_then_exact_title_prefix_fallback_and_keep_non_pi_visible() {
        let mut worker = crate::testutil::linked("worker", "/s/worker", "worker", "parent");
        worker.name = None;
        worker.terminal_title_stripped = Some("π - worker-task-3-78712afb".to_string());
        let codex = crate::testutil::other_row("codex");
        let model = model(vec![worker, codex]);
        let map = desired(&model, &[placement("worker", 1, 1)]);
        assert!(map["worker"]
            .row
            .as_deref()
            .unwrap()
            .starts_with("└─W worker-task-3"));
        assert_eq!(map["codex"].row.as_deref(), Some("codex · Workspace · Tab"));
        assert_eq!(map["codex"].rank, None);
    }

    #[test]
    fn ordinary_display_collapses_controls_and_caps_long_labels_and_names() {
        let mut pi = crate::testutil::pi_row("p", "/s/p");
        pi.workspace_label = Some("unsafe\nworkspace\u{1b}[31m".to_string());
        pi.tab_label = Some("main\tthread".to_string());
        let mut codex = crate::testutil::other_row("c");
        codex.name = Some("worker-".to_string() + &"x".repeat(100));
        let model = model(vec![pi, codex]);
        let map = desired(&model, &[]);
        let pi_row = map["p"].row.as_deref().unwrap();
        assert_eq!(pi_row, "unsafe workspace[31m · main thread");
        assert!(!pi_row.chars().any(char::is_control));
        let codex_row = map["c"].row.as_deref().unwrap();
        assert_eq!(codex_row.chars().count(), 64);
        assert!(!codex_row.chars().any(char::is_control));
    }
}
