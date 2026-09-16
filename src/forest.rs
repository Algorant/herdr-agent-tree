//! Placement: which validated nodes form the forest, in what order, and at what depth.
//!
//! Every rule here is a direct implementation of contract C2/C3/C5. Nothing is guessed from
//! names, titles, tabs, worktrees or proximity; a node that cannot be validated stays visible
//! and unlinked.

use crate::identity::{self, Relationship};
use crate::transport::AgentRow;
use std::collections::{HashMap, HashSet};

#[derive(Clone, Debug, PartialEq)]
pub struct Placement {
    pub pane_id: String,
    pub depth: usize,
    pub is_last_sibling: bool,
    pub role: String,
    pub task_id: Option<String>,
    pub attention: Option<char>,
    pub rank: u32,
}

pub fn build(order: &[String], rows: &HashMap<String, AgentRow>) -> Vec<Placement> {
    let pi_rows: Vec<&AgentRow> = order
        .iter()
        .filter_map(|id| rows.get(id))
        .filter(|row| row.is_pi_session())
        .collect();
    let native_index: HashMap<&str, usize> = order
        .iter()
        .enumerate()
        .map(|(index, id)| (id.as_str(), index))
        .collect();

    // Relationship tokens, then the duplicate rule: any panes publishing the same
    // agency_self are ambiguous, so every pane carrying that value stays unlinked.
    let mut relationships: HashMap<String, Relationship> = HashMap::new();
    let mut published_counts: HashMap<String, usize> = HashMap::new();
    for row in &pi_rows {
        if let Some(published) = row.token("agency_self") {
            if !published.is_empty() {
                *published_counts.entry(published).or_insert(0) += 1;
            }
        }
        if let Some(relationship) = identity::relationship(row) {
            relationships.insert(row.pane_id.clone(), relationship);
        }
    }
    let self_valid: HashSet<String> = pi_rows
        .iter()
        .filter(|row| {
            relationships.get(&row.pane_id).is_some_and(|relationship| {
                identity::is_self_valid(row, relationship)
                    && published_counts
                        .get(&relationship.agency_self)
                        .copied()
                        .unwrap_or(0)
                        == 1
            })
        })
        .map(|row| row.pane_id.clone())
        .collect();

    // Recomputed hash of each Pi pane's own native session reference. This is the only
    // input used to resolve a parent edge; a published value is never trusted for the parent.
    let mut by_hash: HashMap<String, Vec<String>> = HashMap::new();
    for row in &pi_rows {
        if let Some(path) = row.session_path.as_deref() {
            by_hash
                .entry(identity::self_hash(path))
                .or_default()
                .push(row.pane_id.clone());
        }
    }

    // Parent edges: unique resolution only. Dangling, ambiguous and self matches produce none.
    let mut parent: HashMap<String, String> = HashMap::new();
    for pane_id in &self_valid {
        let relationship = &relationships[pane_id];
        let matches: Vec<&String> = by_hash
            .get(&relationship.agency_parent)
            .map(|ids| ids.iter().filter(|id| *id != pane_id).collect())
            .unwrap_or_default();
        if matches.len() == 1 {
            parent.insert(pane_id.clone(), matches[0].clone());
        }
    }

    let mut children: HashMap<String, Vec<String>> = HashMap::new();
    for (child, parent_id) in &parent {
        children
            .entry(parent_id.clone())
            .or_default()
            .push(child.clone());
    }
    for list in children.values_mut() {
        list.sort_by_key(|id| native_index.get(id.as_str()).copied().unwrap_or(usize::MAX));
    }

    // Parent-valid roots are the only entry points; a node whose parent chain never reaches
    // one (a cycle, or a chain into an unplaceable node) is never emitted.
    let roots: Vec<String> = pi_rows
        .iter()
        .map(|row| row.pane_id.clone())
        .filter(|id| children.contains_key(id) && !parent.contains_key(id))
        .collect();

    let mut placements = Vec::new();
    let mut visited: HashSet<String> = HashSet::new();
    let mut rank = 1u32;
    for root in roots {
        emit(
            &root,
            0,
            true,
            &children,
            &relationships,
            &mut visited,
            &mut placements,
            &mut rank,
        );
    }
    placements
}

#[allow(clippy::too_many_arguments)]
fn emit(
    pane_id: &str,
    depth: usize,
    is_last_sibling: bool,
    children: &HashMap<String, Vec<String>>,
    relationships: &HashMap<String, Relationship>,
    visited: &mut HashSet<String>,
    placements: &mut Vec<Placement>,
    rank: &mut u32,
) {
    if !visited.insert(pane_id.to_string()) {
        return;
    }
    let relationship = relationships.get(pane_id);
    placements.push(Placement {
        pane_id: pane_id.to_string(),
        depth,
        is_last_sibling,
        role: relationship.map(|r| r.role.clone()).unwrap_or_default(),
        task_id: relationship.and_then(|r| r.task_id.clone()),
        attention: relationship.and_then(identity::attention),
        rank: *rank,
    });
    *rank += 1;
    if let Some(kids) = children.get(pane_id) {
        let last = kids.len();
        for (index, kid) in kids.iter().enumerate() {
            emit(
                kid,
                depth + 1,
                index + 1 == last,
                children,
                relationships,
                visited,
                placements,
                rank,
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::{self, with_token};
    use crate::transport::Model;

    fn placements(rows: Vec<AgentRow>) -> Vec<Placement> {
        let mut model = Model::default();
        model.install(rows);
        build(&model.order, &model.rows)
    }

    fn ids(placements: &[Placement]) -> Vec<&str> {
        placements
            .iter()
            .map(|placement| placement.pane_id.as_str())
            .collect()
    }

    fn linked_ids(placements: &[Placement]) -> Vec<String> {
        placements
            .iter()
            .map(|placement| placement.pane_id.clone())
            .collect()
    }

    fn is_linked(placements: &[Placement], pane_id: &str) -> bool {
        placements
            .iter()
            .any(|placement| placement.pane_id == pane_id)
    }

    fn path(name: &str) -> String {
        format!("/sessions/{name}.jsonl")
    }

    #[test]
    fn emission_is_preorder_family_contiguous_and_native_ordered() {
        let rows = vec![
            testutil::pi_row("root-a", &path("root-a")),
            testutil::pi_row("root-b", &path("root-b")),
            testutil::linked(
                "sub-b",
                &path("sub-b"),
                "subagent",
                &identity::self_hash(&path("root-b")),
            ),
            testutil::linked(
                "worker-2",
                &path("worker-2"),
                "worker",
                &identity::self_hash(&path("root-a")),
            ),
            testutil::linked(
                "worker-1",
                &path("worker-1"),
                "worker",
                &identity::self_hash(&path("root-a")),
            ),
            testutil::linked(
                "sub-a",
                &path("sub-a"),
                "subagent",
                &identity::self_hash(&path("worker-1")),
            ),
            testutil::pi_row("lone", &path("lone")),
        ];
        let placements = placements(rows);

        assert_eq!(
            ids(&placements),
            ["root-a", "worker-2", "worker-1", "sub-a", "root-b", "sub-b"]
        );
        assert_eq!(
            placements.iter().map(|p| p.depth).collect::<Vec<_>>(),
            [0, 1, 1, 2, 0, 1]
        );
        assert_eq!(
            placements.iter().map(|p| p.rank).collect::<Vec<_>>(),
            [1, 2, 3, 4, 5, 6]
        );
        assert_eq!(
            placements
                .iter()
                .map(|p| p.is_last_sibling)
                .collect::<Vec<_>>(),
            [true, false, true, true, true, true]
        );
        assert!(!is_linked(&placements, "lone"));
    }

    #[test]
    fn sibling_order_follows_native_order_and_is_deterministic() {
        let family = |first: &str, second: &str| {
            vec![
                testutil::pi_row("root", &path("root")),
                testutil::linked(
                    first,
                    &path(first),
                    "worker",
                    &identity::self_hash(&path("root")),
                ),
                testutil::linked(
                    second,
                    &path(second),
                    "worker",
                    &identity::self_hash(&path("root")),
                ),
            ]
        };
        assert_eq!(
            linked_ids(&placements(family("w1", "w2"))),
            ["root", "w1", "w2"]
        );
        assert_eq!(
            linked_ids(&placements(family("w2", "w1"))),
            ["root", "w2", "w1"]
        );
        assert_eq!(
            linked_ids(&placements(family("w1", "w2"))),
            linked_ids(&placements(family("w1", "w2")))
        );
    }

    #[test]
    fn tokenless_parent_is_validated_through_a_validated_child() {
        let rows = vec![
            testutil::pi_row("root", &path("root")),
            testutil::linked(
                "child",
                &path("child"),
                "worker",
                &identity::self_hash(&path("root")),
            ),
        ];
        let placements = placements(rows);
        assert_eq!(ids(&placements), ["root", "child"]);
        assert_eq!(placements[0].depth, 0);
        assert_eq!(
            placements[0].role, "",
            "the root carries no relationship tokens"
        );
        assert_eq!(placements[0].attention, None);
        assert_eq!(placements[1].depth, 1);
    }

    #[test]
    fn duplicate_agency_self_unlinks_every_carrier() {
        let root = path("root");
        let shared_child = path("child");
        let control = placements(vec![
            testutil::pi_row("root", &root),
            testutil::linked(
                "child",
                &shared_child,
                "worker",
                &identity::self_hash(&root),
            ),
        ]);
        assert_eq!(control.len(), 2, "control: a unique child is linked");

        let duplicates = placements(vec![
            testutil::pi_row("root", &root),
            testutil::linked(
                "child-a",
                &shared_child,
                "worker",
                &identity::self_hash(&root),
            ),
            testutil::linked(
                "child-b",
                &shared_child,
                "worker",
                &identity::self_hash(&root),
            ),
        ]);
        assert!(
            duplicates.is_empty(),
            "duplicate agency_self must unlink every carrier, got {:?}",
            ids(&duplicates)
        );
    }

    #[test]
    fn malformed_and_missing_identities_are_unlinked() {
        let root = testutil::pi_row("root", &path("root"));
        let base = testutil::linked(
            "child",
            &path("child"),
            "worker",
            &identity::self_hash(&path("root")),
        );
        let mutations: Vec<(&str, AgentRow)> = vec![
            (
                "role reviewer",
                with_token(base.clone(), "role", "reviewer"),
            ),
            ("role empty", with_token(base.clone(), "role", "")),
            (
                "agency_self uppercase",
                with_token(
                    base.clone(),
                    "agency_self",
                    &identity::self_hash(&path("child")).to_uppercase(),
                ),
            ),
            (
                "agency_self short",
                with_token(
                    base.clone(),
                    "agency_self",
                    &identity::self_hash(&path("child"))[..63],
                ),
            ),
            (
                "agency_parent non-hex",
                with_token(
                    base.clone(),
                    "agency_parent",
                    &identity::self_hash(&path("root")).replace('a', "z"),
                ),
            ),
            (
                "recomputed self mismatch",
                with_token(
                    base.clone(),
                    "agency_self",
                    &identity::self_hash(&path("elsewhere")),
                ),
            ),
            (
                "dangling parent",
                with_token(
                    base.clone(),
                    "agency_parent",
                    &identity::self_hash(&path("nobody")),
                ),
            ),
        ];
        for (label, child) in mutations {
            let placements = placements(vec![root.clone(), child]);
            assert!(!is_linked(&placements, "child"), "{label} must be unlinked");
        }

        for missing in ["role", "agency_self", "agency_parent"] {
            let mut child = base.clone();
            child.tokens.remove(missing);
            let placements = placements(vec![root.clone(), child]);
            assert!(
                !is_linked(&placements, "child"),
                "missing {missing} must be unlinked"
            );
        }
    }

    #[test]
    fn self_link_produces_no_parent_edge() {
        let self_linked = with_token(
            testutil::linked("a", &path("a"), "worker", &identity::self_hash(&path("a"))),
            "agency_parent",
            &identity::self_hash(&path("a")),
        );
        assert!(
            placements(vec![self_linked.clone()]).is_empty(),
            "a self-linked node with no children is unlinked"
        );
        let with_child = placements(vec![
            self_linked,
            testutil::linked("c", &path("c"), "worker", &identity::self_hash(&path("a"))),
        ]);
        assert_eq!(ids(&with_child), ["a", "c"]);
        assert_eq!(
            with_child[0].depth, 0,
            "the self-link never becomes its own parent"
        );
    }

    #[test]
    fn ambiguous_parent_matches_are_unlinked() {
        let placements = placements(vec![
            testutil::pi_row("root-a", &path("root")),
            testutil::pi_row("root-b", &path("root")),
            testutil::linked(
                "child",
                &path("child"),
                "worker",
                &identity::self_hash(&path("root")),
            ),
        ]);
        assert!(
            !is_linked(&placements, "child"),
            "two panes sharing the parent hash must resolve to no edge"
        );
    }

    #[test]
    fn cycles_never_rank_and_never_validate_a_parent() {
        let placements = placements(vec![
            testutil::linked("a", &path("a"), "worker", &identity::self_hash(&path("b"))),
            testutil::linked("b", &path("b"), "worker", &identity::self_hash(&path("a"))),
        ]);
        assert!(
            placements.is_empty(),
            "cycle members must not be emitted, got {:?}",
            ids(&placements)
        );
    }

    #[test]
    fn stale_identity_is_recomputed_from_each_snapshot() {
        let before = placements(vec![
            testutil::pi_row("root", &path("root")),
            testutil::linked(
                "child",
                &path("child"),
                "worker",
                &identity::self_hash(&path("root")),
            ),
        ]);
        assert_eq!(ids(&before), ["root", "child"]);

        let after = placements(vec![
            testutil::pi_row("root", &path("replaced-root")),
            testutil::linked(
                "child",
                &path("child"),
                "worker",
                &identity::self_hash(&path("root")),
            ),
        ]);
        assert!(
            !is_linked(&after, "child"),
            "a replaced parent must not leave a stale edge"
        );
    }

    #[test]
    fn non_pi_rows_are_never_placement_candidates() {
        let placements = placements(vec![
            testutil::other_row("codex"),
            testutil::pi_row("plain", &path("plain")),
        ]);
        assert!(placements.is_empty());
    }
}
