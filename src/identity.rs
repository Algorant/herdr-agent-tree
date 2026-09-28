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
