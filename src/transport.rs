//! Snapshot and event handling: the ordered agent rows this plugin reasons about.

use crate::wire::R;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;

/// Exactly the events this plugin needs. No status, scroll or title subscriptions.
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
    "workspace.created",
    "workspace.closed",
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
    /// Present only when Herdr exposes a native session reference of kind `path`.
    pub session_path: Option<String>,
    pub tokens: HashMap<String, String>,
}

impl AgentRow {
    pub fn token(&self, name: &str) -> Option<String> {
        self.tokens.get(name).cloned()
    }

    pub fn is_pi_session(&self) -> bool {
        self.agent == "pi" && self.session_path.is_some()
    }

    fn from_value(value: &Value) -> Option<AgentRow> {
        let pane_id = value.get("pane_id")?.as_str()?.to_string();
        Some(AgentRow {
            pane_id,
            workspace_id: text(value, "workspace_id"),
            tab_id: text(value, "tab_id"),
            agent: text(value, "agent"),
            agent_status: text(value, "agent_status"),
            session_path: session_path(value),
            tokens: tokens(value),
        })
    }

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
                .filter_map(|(name, raw)| {
                    raw.as_str().map(|text| (name.clone(), text.to_string()))
                })
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
        self.order.iter().filter_map(|id| self.rows.get(id)).collect()
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
/// the shared plugin state dir (the subscriber lock and the paused flag).
pub fn server_tag(socket: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(socket.as_bytes());
    let digest = hex(&hasher.finalize());
    digest[..16].to_string()
}

/// Authoritative ordered rows for the current server state.
pub fn fetch_rows(socket: &str) -> R<Vec<AgentRow>> {
    let result = crate::wire::request(socket, "agent.list", json!({}))?;
    rows_from(&result, "agents", "agent.list")
}

fn rows_from(container: &Value, key: &str, source: &str) -> R<Vec<AgentRow>> {
    let array = container
        .get(key)
        .and_then(Value::as_array)
        .ok_or_else(|| format!("{source} returned no {key} array"))?;
    Ok(array.iter().filter_map(AgentRow::from_value).collect())
}
