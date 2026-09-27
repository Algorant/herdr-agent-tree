//! Snapshot and event handling: the ordered agent rows this plugin reasons about.

use crate::wire::R;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;

/// Events that can change pane identity/display inputs or pane/workspace/tab placement.
pub const SUBSCRIBED_EVENTS: &[&str] = &[
    "pane.created",
    "pane.closed",
    "pane.moved",
    "pane.exited",
    "pane.updated",
    "pane.agent_detected",
    "layout.updated",
    "tab.created",
    "tab.closed",
    "tab.moved",
    "tab.renamed",
    "workspace.created",
    "workspace.closed",
    "workspace.renamed",
    "workspace.updated",
    "workspace.moved",
    "workspace.reordered",
];

#[derive(Clone, Debug, Default, PartialEq)]
pub struct AgentRow {
    pub pane_id: String,
    pub workspace_id: String,
    pub tab_id: String,
    pub agent: String,
    pub agent_status: String,
    pub name: Option<String>,
    pub terminal_title_stripped: Option<String>,
    pub workspace_label: Option<String>,
    pub tab_label: Option<String>,
    /// A pane-only snapshot row used solely to clear stale plugin-owned tokens after agent release.
    pub cleanup_only: bool,
    /// Present only when Herdr exposes a native session reference of kind `path`.
    pub session_path: Option<String>,
    pub tokens: HashMap<String, String>,
}

impl AgentRow {
    pub fn token(&self, name: &str) -> Option<String> {
        self.tokens.get(name).cloned()
    }

    pub fn is_pi_session(&self) -> bool {
        !self.cleanup_only && self.agent == "pi" && self.session_path.is_some()
    }

    fn from_value(value: &Value) -> Option<AgentRow> {
        let pane_id = value.get("pane_id")?.as_str()?.to_string();
        Some(AgentRow {
            pane_id,
            workspace_id: text(value, "workspace_id"),
            tab_id: text(value, "tab_id"),
            agent: text(value, "agent"),
            agent_status: text(value, "agent_status"),
            name: optional_text(value, "name"),
            terminal_title_stripped: optional_text(value, "terminal_title_stripped"),
            workspace_label: optional_text(value, "workspace_label"),
            tab_label: optional_text(value, "tab_label"),
            cleanup_only: false,
            session_path: session_path(value),
            tokens: tokens(value),
        })
    }
}

fn optional_text(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|text| !text.is_empty())
        .map(str::to_string)
}

fn text(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn tokens(value: &Value) -> HashMap<String, String> {
    value
        .get("tokens")
        .and_then(Value::as_object)
        .map(|map| {
            map.iter()
                .filter_map(|(name, raw)| raw.as_str().map(|text| (name.clone(), text.to_string())))
                .collect()
        })
        .unwrap_or_default()
}

fn session_path(value: &Value) -> Option<String> {
    let session = value.get("agent_session")?;
    if session.get("kind").and_then(Value::as_str) != Some("path") {
        return None;
    }
    let path = session.get("value").and_then(Value::as_str)?;
    if !path.starts_with('/') {
        return None;
    }
    Some(path.to_string())
}

/// Native agent order plus the rows, exactly as the server reports them.
#[derive(Clone, Debug, Default)]
pub struct Model {
    pub order: Vec<String>,
    pub rows: HashMap<String, AgentRow>,
}

impl Model {
    pub fn install(&mut self, rows: Vec<AgentRow>) {
        self.order = rows.iter().map(|row| row.pane_id.clone()).collect();
        self.rows = rows
            .into_iter()
            .map(|row| (row.pane_id.clone(), row))
            .collect();
    }

    pub fn ordered_rows(&self) -> Vec<&AgentRow> {
        self.order
            .iter()
            .filter_map(|id| self.rows.get(id))
            .collect()
    }

    pub fn set_token(&mut self, pane_id: &str, name: &str, value: Option<String>) {
        if let Some(row) = self.rows.get_mut(pane_id) {
            match value {
                Some(value) => {
                    row.tokens.insert(name.to_string(), value);
                }
                None => {
                    row.tokens.remove(name);
                }
            }
        }
    }

    /// Normalized digest of everything this plugin's output depends on, in native order.
    /// An event that leaves the digest unchanged must cause no writes at all.
    pub fn digest(&self) -> String {
        let mut hasher = Sha256::new();
        for row in self.ordered_rows() {
            hasher.update(row.pane_id.as_bytes());
            hasher.update(b"\x1f");
            hasher.update(row.agent.as_bytes());
            hasher.update(b"\x1f");
            for value in [
                row.name.as_deref(),
                row.terminal_title_stripped.as_deref(),
                row.workspace_label.as_deref(),
                row.tab_label.as_deref(),
            ] {
                hasher.update(value.unwrap_or_default().as_bytes());
                hasher.update(b"\x1f");
            }
            hasher.update([u8::from(row.cleanup_only)]);
            hasher.update(b"\x1f");
            hasher.update(row.session_path.as_deref().unwrap_or("").as_bytes());
            hasher.update(b"\x1f");
            for name in [
                crate::projection::ROW_TOKEN,
                crate::projection::RANK_TOKEN,
                "role",
                "agency_self",
                "agency_parent",
                "handoff",
                "question",
            ] {
                hasher.update(row.token(name).unwrap_or_default().as_bytes());
                hasher.update(b"\x1f");
            }
            hasher.update(b"\x1e");
        }
        hex(&hasher.finalize())
    }
}

pub fn hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

/// Stable, short tag derived from a server socket path. Used to scope per-server files in
/// the shared plugin state dir (the subscriber lock and the tree-off marker).
pub fn server_tag(socket: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(socket.as_bytes());
    let digest = hex(&hasher.finalize());
    digest[..16].to_string()
}

/// Authoritative rows and location labels from one coherent Herdr session snapshot.
pub fn fetch_rows(socket: &str) -> R<Vec<AgentRow>> {
    let result = crate::wire::request(socket, "session.snapshot", json!({}))?;
    let snapshot = result
        .get("snapshot")
        .ok_or_else(|| "session.snapshot returned no snapshot object".to_string())?;
    rows_from_snapshot(snapshot)
}

fn rows_from_snapshot(snapshot: &Value) -> R<Vec<AgentRow>> {
    let workspaces = labels_by_id(
        snapshot,
        "workspaces",
        "workspace_id",
        "session.snapshot workspaces",
    )?;
    let tabs = labels_by_id(snapshot, "tabs", "tab_id", "session.snapshot tabs")?;
    let mut rows = rows_from(snapshot, "agents", "session.snapshot")?;
    let agent_panes: std::collections::HashSet<String> =
        rows.iter().map(|row| row.pane_id.clone()).collect();
    for row in &mut rows {
        row.workspace_label = workspaces.get(&row.workspace_id).cloned();
        row.tab_label = tabs.get(&row.tab_id).cloned();
    }
    let panes = rows_from(snapshot, "panes", "session.snapshot")?;
    rows.extend(panes.into_iter().filter_map(|mut pane| {
        if agent_panes.contains(&pane.pane_id)
            || (pane.token(crate::projection::ROW_TOKEN).is_none()
                && pane.token(crate::projection::RANK_TOKEN).is_none())
        {
            return None;
        }
        pane.cleanup_only = true;
        Some(pane)
    }));
    Ok(rows)
}

fn labels_by_id(
    container: &Value,
    key: &str,
    id_key: &str,
    source: &str,
) -> R<HashMap<String, String>> {
    let array = container
        .get(key)
        .and_then(Value::as_array)
        .ok_or_else(|| format!("{source} returned no {key} array"))?;
    Ok(array
        .iter()
        .filter_map(|value| {
            Some((
                value.get(id_key)?.as_str()?.to_string(),
                value.get("label")?.as_str()?.to_string(),
            ))
        })
        .collect())
}

fn rows_from(container: &Value, key: &str, source: &str) -> R<Vec<AgentRow>> {
    let array = container
        .get(key)
        .and_then(Value::as_array)
        .ok_or_else(|| format!("{source} returned no {key} array"))?;
    Ok(array.iter().filter_map(AgentRow::from_value).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::{self, with_token};

    #[test]
    fn hex_and_server_tag_are_stable_and_distinct() {
        assert_eq!(hex(&[0x00, 0x0f, 0xff]), "000fff");
        assert_eq!(server_tag("/tmp/x.sock"), server_tag("/tmp/x.sock"));
        assert_ne!(server_tag("/tmp/x.sock"), server_tag("/tmp/y.sock"));
        assert_eq!(server_tag("/tmp/x.sock").len(), 16);
    }

    #[test]
    fn from_value_reads_identity_fields_and_string_tokens() {
        let value = json!({
            "pane_id": "p1",
            "workspace_id": "w",
            "tab_id": "t",
            "agent": "pi",
            "agent_status": "idle",
            "name": "helper",
            "terminal_title_stripped": "π - helper - root",
            "agent_session": {"kind": "path", "value": "/s/p1.jsonl"},
            "tokens": {"role": "worker", "agency_self": "abc", "count": 7}
        });
        let row = AgentRow::from_value(&value).unwrap();
        assert_eq!(row.pane_id, "p1");
        assert_eq!(row.workspace_id, "w");
        assert_eq!(row.tab_id, "t");
        assert_eq!(row.agent, "pi");
        assert_eq!(row.agent_status, "idle");
        assert_eq!(row.name.as_deref(), Some("helper"));
        assert_eq!(
            row.terminal_title_stripped.as_deref(),
            Some("π - helper - root")
        );
        assert_eq!(row.session_path.as_deref(), Some("/s/p1.jsonl"));
        assert_eq!(row.token("role").as_deref(), Some("worker"));
        assert_eq!(row.token("agency_self").as_deref(), Some("abc"));
        assert_eq!(row.token("count"), None, "non-string tokens are ignored");
        assert!(row.is_pi_session());
    }

    #[test]
    fn session_path_requires_path_kind_and_absolute_value() {
        let cases = [
            (json!({"kind": "path", "value": "/abs"}), Some("/abs")),
            (json!({"kind": "path", "value": "rel"}), None),
            (json!({"kind": "id", "value": "/abs"}), None),
            (json!({"value": "/abs"}), None),
            (json!({"kind": "path"}), None),
        ];
        for (session, expected) in cases {
            let value = json!({"pane_id": "p", "agent_session": session});
            assert_eq!(
                AgentRow::from_value(&value)
                    .unwrap()
                    .session_path
                    .as_deref(),
                expected,
                "{session}"
            );
        }
    }

    #[test]
    fn only_pi_rows_with_a_path_are_candidates() {
        let codex = json!({"pane_id": "c", "agent": "codex"});
        assert!(!AgentRow::from_value(&codex).unwrap().is_pi_session());
        let pi_without_path = json!({"pane_id": "p", "agent": "pi"});
        assert!(!AgentRow::from_value(&pi_without_path)
            .unwrap()
            .is_pi_session());
    }

    #[test]
    fn rows_without_a_pane_id_are_skipped_and_a_missing_array_is_an_error() {
        assert!(AgentRow::from_value(&json!({"agent": "pi"})).is_none());
        assert!(rows_from(&json!({}), "agents", "agent.list").is_err());
        let rows = rows_from(
            &json!({"agents": [{"pane_id": "p"}, {"agent": "pi"}]}),
            "agents",
            "agent.list",
        )
        .unwrap();
        assert_eq!(rows.len(), 1);
    }

    #[test]
    fn digest_is_stable_and_reacts_to_order_display_values_and_tokens() {
        fn rows() -> Vec<AgentRow> {
            vec![
                testutil::pi_row("a", "/s/a"),
                with_token(testutil::pi_row("b", "/s/b"), "role", "worker"),
            ]
        }
        fn digest(rows: Vec<AgentRow>) -> String {
            let mut model = Model::default();
            model.install(rows);
            model.digest()
        }
        assert_eq!(digest(rows()), digest(rows()));

        let mut reversed = rows();
        reversed.reverse();
        assert_ne!(digest(rows()), digest(reversed), "native order is an input");

        let mut changed = rows();
        changed[0] = with_token(testutil::pi_row("a", "/s/a"), "agency_parent", "x");
        assert_ne!(digest(rows()), digest(changed), "token values are an input");

        let mut renamed = rows();
        renamed[0].name = Some("renamed".to_string());
        assert_ne!(
            digest(rows()),
            digest(renamed),
            "agent name is a display input"
        );
        let mut relabeled = rows();
        relabeled[0].workspace_label = Some("new workspace".to_string());
        assert_ne!(
            digest(rows()),
            digest(relabeled),
            "workspace label is a display input"
        );
        let mut retabbed = rows();
        retabbed[0].tab_label = Some("new tab".to_string());
        assert_ne!(
            digest(rows()),
            digest(retabbed),
            "tab label is a display input"
        );
        let mut retitled = rows();
        retitled[0].terminal_title_stripped = Some("π - changed".to_string());
        assert_ne!(digest(rows()), digest(retitled), "title is a display input");
    }

    #[test]
    fn snapshot_joins_agent_location_ids_to_authoritative_workspace_and_tab_labels() {
        let snapshot = json!({
            "agents": [{
                "pane_id": "p1", "workspace_id": "w1", "tab_id": "t1", "agent": "pi",
                "agent_status": "idle", "name": null,
                "agent_session": {"kind": "path", "value": "/s/p1.jsonl"}
            }],
            "workspaces": [{"workspace_id": "w1", "label": "project"}],
            "tabs": [{"tab_id": "t1", "label": "main"}],
            "panes": [{"pane_id": "p1", "workspace_id": "w1", "tab_id": "t1"}]
        });
        let rows = rows_from_snapshot(&snapshot).unwrap();
        assert_eq!(rows[0].workspace_label.as_deref(), Some("project"));
        assert_eq!(rows[0].tab_label.as_deref(), Some("main"));
        assert_eq!(
            rows.len(),
            1,
            "an ordinary pane does not duplicate its agent row"
        );
    }

    #[test]
    fn released_pane_with_plugin_tokens_is_retained_only_for_owned_token_cleanup() {
        let snapshot = json!({
            "agents": [],
            "workspaces": [{"workspace_id": "w1", "label": "project"}],
            "tabs": [{"tab_id": "t1", "label": "main"}],
            "panes": [{
                "pane_id": "released", "workspace_id": "w1", "tab_id": "t1",
                "tokens": {"agent_tree_row": "old row", "agent_tree_rank": "000007", "other": "keep"}
            }]
        });
        let rows = rows_from_snapshot(&snapshot).unwrap();
        assert_eq!(rows.len(), 1);
        assert!(rows[0].cleanup_only);
        assert_eq!(
            rows[0].token(crate::projection::ROW_TOKEN).as_deref(),
            Some("old row")
        );
        assert_eq!(rows[0].token("other").as_deref(), Some("keep"));
    }

    #[test]
    fn subscription_covers_agent_and_location_display_refresh_events() {
        for event in [
            "pane.updated",
            "workspace.renamed",
            "workspace.updated",
            "tab.renamed",
        ] {
            assert!(SUBSCRIBED_EVENTS.contains(&event), "missing {event}");
        }
    }
}
