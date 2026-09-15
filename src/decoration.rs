//! Decoration encoding (contract C4).
//!
//! The value always starts with a non-whitespace glyph, because Herdr trims surrounding
//! whitespace and leading plain spaces therefore cannot encode depth. Width is capped at 20
//! characters; the rank token is never rendered.

/// Hard cap on the decoration value.
pub const MAX_WIDTH: usize = 20;
/// Worker task labels longer than this are truncated.
const MAX_TASK: usize = 12;
/// Depth beyond this collapses to an ellipsis marker so width stays bounded at any depth.
const MAX_INDENT: usize = 3;

const CELL: &str = "\u{2502}  "; // "│  "
const COLLAPSED: &str = "\u{2026}  "; // "…  "

/// Renders the decoration for one placement.
///
/// A root (depth 0) carries the attention glyph only; with no attention there is nothing to
/// publish, which is why the return value is an `Option`.
pub fn decoration(
    depth: usize,
    is_last_sibling: bool,
    role: &str,
    task_id: Option<&str>,
    attention: Option<char>,
) -> Option<String> {
    if depth == 0 {
        return attention.map(|glyph| glyph.to_string());
    }

    let role_label = match role {
        "worker" => "W",
        "subagent" => "S",
        _ => return None,
    };

    let branch = if is_last_sibling { "\u{2514}\u{2500}" } else { "\u{251c}\u{2500}" }; // └─ / ├─
    let task = task_id
        .filter(|_| role == "worker")
        .map(|value| truncate(value, MAX_TASK))
        .filter(|value| !value.is_empty());
    let hint = attention.map(|glyph| glyph.to_string());

    let full = compose(&indent(depth), branch, role_label, task.as_deref(), hint.as_deref());
    if full.chars().count() <= MAX_WIDTH {
        return Some(full);
    }
    // Drop order: task, then attention, then collapse the indent. Branch and role remain.
    let without_task = compose(
        &collapsed(depth),
        branch,
        role_label,
        None,
        hint.as_deref(),
    );
    if without_task.chars().count() <= MAX_WIDTH {
        return Some(without_task);
    }
    let without_hint = compose(&collapsed(depth), branch, role_label, None, None);
    if without_hint.chars().count() <= MAX_WIDTH {
        return Some(without_hint);
    }
    Some(truncate(&without_hint, MAX_WIDTH))
}

fn compose(
    indent: &str,
    branch: &str,
    role_label: &str,
    task: Option<&str>,
    attention: Option<&str>,
) -> String {
    let mut value = String::new();
    value.push_str(indent);
    value.push_str(branch);
    value.push_str(role_label);
    if let Some(task) = task {
        value.push(' ');
        value.push_str(task);
    }
    if let Some(attention) = attention {
        value.push(' ');
        value.push_str(attention);
    }
    value
}

fn indent(depth: usize) -> String {
    if depth > MAX_INDENT {
        return collapsed(depth);
    }
    CELL.repeat(depth.saturating_sub(1))
}

fn collapsed(depth: usize) -> String {
    if depth > MAX_INDENT {
        format!("{COLLAPSED}{CELL}{CELL}")
    } else {
        indent(depth)
    }
}

fn truncate(value: &str, limit: usize) -> String {
    value.chars().take(limit).collect()
}
