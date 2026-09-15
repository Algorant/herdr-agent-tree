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
