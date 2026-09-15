//! Identity validation. Everything here is recomputed from public surfaces; nothing is
//! inferred from names, titles, tabs, worktrees or filesystem proximity.

use crate::transport::{hex, AgentRow};
use serde_json::json;
use sha2::{Digest, Sha256};

/// Lowercase hex SHA-256 over the exact bytes of compact JSON `["pi","path",<session>]`.
pub fn self_hash(session_path: &str) -> String {
    let tuple = json!(["pi", "path", session_path]).to_string();
    let mut hasher = Sha256::new();
    hasher.update(tuple.as_bytes());
    hex(&hasher.finalize())
}

pub fn is_lower_hex64(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// The three relationship tokens plus the display inputs this plugin is allowed to read.
#[derive(Clone, Debug, PartialEq)]
pub struct Relationship {
    pub role: String,
    pub agency_self: String,
    pub agency_parent: String,
    pub task_id: Option<String>,
    pub handoff: Option<String>,
    pub question: Option<String>,
}

/// Reads the relationship tokens. Returns `None` when any of the three is absent, so a
/// partially published identity is treated as unlinked rather than as a candidate.
pub fn relationship(row: &AgentRow) -> Option<Relationship> {
    Some(Relationship {
        role: row.token("role")?,
        agency_self: row.token("agency_self")?,
        agency_parent: row.token("agency_parent")?,
        task_id: row.token("task_id"),
        handoff: row.token("handoff"),
        question: row.token("question"),
    })
}

/// True only when the published `agency_self` matches the recomputation byte-for-byte and
/// the role is one this plugin understands.
pub fn is_self_valid(row: &AgentRow, relationship: &Relationship) -> bool {
    if !matches!(relationship.role.as_str(), "worker" | "subagent") {
        return false;
    }
    if !is_lower_hex64(&relationship.agency_self) || !is_lower_hex64(&relationship.agency_parent) {
        return false;
    }
    match row.session_path.as_deref() {
        Some(path) => self_hash(path) == relationship.agency_self,
        None => false,
    }
}

/// Small attention hint derived from existing Worker handoff / Subagent question metadata.
/// `missing`, absent and unknown produce nothing, and no glyph implies success or acceptance.
pub fn attention(relationship: &Relationship) -> Option<char> {
    match relationship.role.as_str() {
        "worker" => match relationship.handoff.as_deref() {
            Some("question") => Some('?'),
            Some("failed") => Some('!'),
            Some("reported") => Some('▸'),
            _ => None,
        },
        "subagent" => match relationship.question.as_deref() {
            Some(value) if !value.is_empty() => Some('?'),
            _ => None,
        },
        _ => None,
    }
}
