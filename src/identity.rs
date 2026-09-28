//! Identity validation. Everything here is recomputed from public surfaces; nothing is
//! inferred from names, titles, tabs, worktrees or filesystem proximity.

use crate::transport::{hex, AgentRow};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::path::Path;

/// Lowercase hex SHA-256 over the exact bytes of compact JSON `["pi","path",<session>]`.
pub fn self_hash(session_path: &str) -> String {
    let tuple = json!(["pi", "path", session_path]).to_string();
    let mut hasher = Sha256::new();
    hasher.update(tuple.as_bytes());
    hex(&hasher.finalize())
}

/// Stable, endpoint-scoped rank namespace. Machine ID and socket path are inputs only;
/// neither is returned or published. The canonical socket path distinguishes sessions on
/// one host while remaining stable across subscriber restarts.
pub fn endpoint_rank_prefix(machine_id: &str, socket_path: &Path) -> Result<String, String> {
    let machine_id = machine_id.strip_suffix('\n').unwrap_or(machine_id);
    let machine_id = machine_id.strip_suffix('\r').unwrap_or(machine_id);
    if machine_id.len() != 32
        || !machine_id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b) || (b'A'..=b'F').contains(&b))
        || machine_id.bytes().all(|b| b == b'0')
    {
        return Err(
            "/etc/machine-id is missing or invalid; endpoint rank identity unavailable".into(),
        );
    }
    let canonical_socket = socket_path.canonicalize().map_err(|_| {
        "HERDR_SOCKET_PATH cannot be canonicalized; endpoint rank identity unavailable".to_string()
    })?;
    let tuple = json!([
        "herdr-agent-tree-endpoint-v1",
        machine_id.to_ascii_lowercase(),
        canonical_socket.to_string_lossy()
    ])
    .to_string();
    let mut hasher = Sha256::new();
    hasher.update(tuple.as_bytes());
    let digest = hex(&hasher.finalize());
    Ok(format!("h{}", &digest[..16]))
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
}

/// Reads the relationship tokens. Returns `None` when any of the three is absent, so a
/// partially published identity is treated as unlinked rather than as a candidate.
pub fn relationship(row: &AgentRow) -> Option<Relationship> {
    Some(Relationship {
        role: row.token("role")?,
        agency_self: row.token("agency_self")?,
        agency_parent: row.token("agency_parent")?,
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil;

    const SESSION: &str = "/tmp/session.jsonl";
    /// Independently computed: `sha256('["pi","path","/tmp/session.jsonl"]')`.
    const SESSION_HASH: &str = "82985f7d63b627e59d1c5e6386576a0a39a378bfa8ab86bc4e59ef720d8970e3";

    fn partial(names: &[&str]) -> AgentRow {
        let mut row = testutil::pi_row("p", SESSION);
        for name in names {
            row = testutil::with_token(row, name, "value");
        }
        row
    }

    #[test]
    fn self_hash_is_byte_exact_lowercase_hex_over_the_raw_tuple() {
        let value = self_hash(SESSION);
        assert_eq!(value, SESSION_HASH);
        assert_eq!(value.len(), 64, "no truncation");
        assert!(value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)));
    }

    #[test]
    fn self_hash_does_not_trim_case_fold_or_canonicalize_the_path() {
        assert_ne!(self_hash("/tmp/x"), self_hash(" /tmp/x"));
        assert_ne!(self_hash("/tmp/x"), self_hash("/tmp/x "));
        assert_ne!(self_hash("/a/../b"), self_hash("/b"));
        assert_ne!(self_hash("/a//b"), self_hash("/a/b"));
        assert_ne!(self_hash("/a/b/"), self_hash("/a/b"));
        assert_ne!(self_hash("/Tmp/x"), self_hash("/tmp/x"));
        for path in ["/", "", "x", "/a/b/c/d/e/f/g/h/i/j"] {
            assert_eq!(self_hash(path).len(), 64, "{path:?}");
        }
    }

    #[test]
    fn endpoint_rank_prefix_is_stable_and_names_machine_and_socket_pair() {
        let test_dir =
            std::env::temp_dir().join(format!("agent-tree-identity-{}", std::process::id()));
        std::fs::create_dir_all(&test_dir).unwrap();
        let socket_a = test_dir.join("a.sock");
        let socket_b = test_dir.join("b.sock");
        std::fs::write(&socket_a, []).unwrap();
        std::fs::write(&socket_b, []).unwrap();
        let machine_a = "0123456789abcdef0123456789abcdef";
        let machine_b = "abcdef0123456789abcdef0123456789";
        let a = endpoint_rank_prefix(machine_a, &socket_a).unwrap();
        assert_eq!(
            a,
            endpoint_rank_prefix(machine_a, &socket_a).unwrap(),
            "subscriber restart stability"
        );
        assert_ne!(
            a,
            endpoint_rank_prefix(machine_a, &socket_b).unwrap(),
            "same host, distinct endpoints"
        );
        assert_ne!(
            a,
            endpoint_rank_prefix(machine_b, &socket_a).unwrap(),
            "distinct hosts, same socket path"
        );
        assert_eq!(a.len(), 17);
        assert!(!a.contains(machine_a));
        assert!(!a.contains(&socket_a.to_string_lossy().to_string()));
        std::fs::remove_dir_all(test_dir).unwrap();
    }

    #[test]
    fn endpoint_rank_prefix_rejects_missing_or_invalid_identity_inputs() {
        let socket = Path::new("/tmp/agent-tree-test.sock");
        for machine_id in [
            "",
            "unknown",
            &format!(" {} ", "a".repeat(32)),
            &format!("{}\n\n", "a".repeat(32)),
            &"0".repeat(32),
            &"g".repeat(32),
            &"a".repeat(31),
        ] {
            assert!(
                endpoint_rank_prefix(machine_id, socket).is_err(),
                "{machine_id:?}"
            );
        }
        assert!(endpoint_rank_prefix(
            "0123456789abcdef0123456789abcdef",
            Path::new("/nonexistent/socket")
        )
        .is_err());
    }

    #[test]
    fn lower_hex64_accepts_only_exactly_64_lowercase_hex() {
        assert!(is_lower_hex64(&"a".repeat(64)));
        assert!(is_lower_hex64(&"0".repeat(64)));
        assert!(!is_lower_hex64(&"a".repeat(63)));
        assert!(!is_lower_hex64(&"a".repeat(65)));
        assert!(!is_lower_hex64(&"A".repeat(64)));
        assert!(!is_lower_hex64(&format!("g{}", "a".repeat(63))));
        assert!(!is_lower_hex64(""));
    }

    #[test]
    fn relationship_requires_all_three_tokens() {
        assert!(relationship(&partial(&["role", "agency_self", "agency_parent"])).is_some());
        for missing in ["role", "agency_self", "agency_parent"] {
            let names: Vec<&str> = ["role", "agency_self", "agency_parent"]
                .into_iter()
                .filter(|name| *name != missing)
                .collect();
            assert!(
                relationship(&partial(&names)).is_none(),
                "missing {missing} must be unlinked rather than a candidate"
            );
        }
    }

    fn self_row() -> AgentRow {
        testutil::linked("p", SESSION, "worker", &"0".repeat(64))
    }

    fn mutate(row: &AgentRow, name: &str, value: &str) -> AgentRow {
        testutil::with_token(row.clone(), name, value)
    }

    #[test]
    fn self_validation_accepts_only_a_recomputed_lowercase_hex_identity() {
        for role in ["worker", "subagent"] {
            let row = mutate(&self_row(), "role", role);
            let relation = relationship(&row).unwrap();
            assert!(
                is_self_valid(&row, &relation),
                "{role} with a matching hash"
            );
        }

        let cases: Vec<(&str, AgentRow)> = vec![
            ("role reviewer", mutate(&self_row(), "role", "reviewer")),
            ("role empty", mutate(&self_row(), "role", "")),
            (
                "agency_self uppercase",
                mutate(&self_row(), "agency_self", &SESSION_HASH.to_uppercase()),
            ),
            (
                "agency_self short",
                mutate(&self_row(), "agency_self", &SESSION_HASH[..63]),
            ),
            (
                "agency_self non-hex",
                mutate(
                    &self_row(),
                    "agency_self",
                    &format!("g{}", &SESSION_HASH[1..]),
                ),
            ),
            (
                "agency_parent uppercase",
                mutate(&self_row(), "agency_parent", &"a".repeat(64).to_uppercase()),
            ),
            (
                "recomputed mismatch",
                mutate(&self_row(), "agency_self", &self_hash("/somewhere/else")),
            ),
            ("no session path", {
                let mut row = self_row();
                row.session_path = None;
                row
            }),
        ];
        for (label, row) in cases {
            let relation = relationship(&row).expect("all tokens are present");
            assert!(!is_self_valid(&row, &relation), "{label} must be unlinked");
        }
    }
}
