//! Test-only helpers. Compiled only under `#[cfg(test)]`; it is never part of the binary.

use crate::identity::self_hash;
use crate::transport::AgentRow;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

/// A Pi agent row with a native session path and no relationship tokens.
pub fn pi_row(pane_id: &str, path: &str) -> AgentRow {
    AgentRow {
        pane_id: pane_id.to_string(),
        workspace_id: "ws".to_string(),
        tab_id: "tab".to_string(),
        agent: "pi".to_string(),
        agent_status: String::new(),
        session_path: Some(path.to_string()),
        tokens: HashMap::new(),
    }
}

/// A non-Pi agent row: no session path, so it is never a placement candidate.
pub fn other_row(pane_id: &str) -> AgentRow {
    AgentRow {
        pane_id: pane_id.to_string(),
        workspace_id: "ws".to_string(),
        tab_id: "tab".to_string(),
        agent: "codex".to_string(),
        agent_status: String::new(),
        session_path: None,
        tokens: HashMap::new(),
    }
}

/// Inserts or replaces a relationship token, mirroring how the snapshot reports strings.
pub fn with_token(mut row: AgentRow, name: &str, value: &str) -> AgentRow {
    row.tokens.insert(name.to_string(), value.to_string());
    row
}

/// A self-valid Pi row: `role`, a recomputed `agency_self`, and the given `agency_parent`.
pub fn linked(pane_id: &str, path: &str, role: &str, agency_parent: &str) -> AgentRow {
    with_token(
        with_token(
            with_token(pi_row(pane_id, path), "role", role),
            "agency_self",
            &self_hash(path),
        ),
        "agency_parent",
        agency_parent,
    )
}

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// Unique temporary directory that removes itself on drop.
pub struct TempDir {
    path: PathBuf,
}

impl TempDir {
    pub fn new(tag: &str) -> TempDir {
        let unique = format!(
            "agent-tree-test-{tag}-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst)
        );
        let path = std::env::temp_dir().join(unique);
        std::fs::create_dir_all(&path).expect("create temp dir");
        TempDir { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}
