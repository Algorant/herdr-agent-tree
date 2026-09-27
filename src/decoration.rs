//! Composes a validated descendant's complete one-cell sidebar value.
//!
//! The branch and role lead, followed immediately by the child identity. Task and attention
//! are optional suffixes and are dropped before branch/role/name when width is constrained.

/// Maximum composed descendant value. This leaves room for the status cell at narrow widths.
pub const MAX_WIDTH: usize = 20;
const MAX_INDENT: usize = 3;
const CELL: &str = "\u{2502}  "; // "│  "
const COLLAPSED: &str = "\u{2026}  "; // "…  "

pub fn descendant(
    depth: usize,
    is_last_sibling: bool,
    role: &str,
    name: &str,
    task_id: Option<&str>,
    attention: Option<char>,
) -> String {
    let role_label = match role {
        "worker" => "W",
        "subagent" => "S",
        _ => return clean(name),
    };
    let branch = if is_last_sibling { "└─" } else { "├─" };
    let indent = indent(depth);
    let prefix = format!("{indent}{branch}{role_label} ");
    let name = clean(name);
    let name = truncate(&name, MAX_WIDTH.saturating_sub(prefix.chars().count()));
    let mut value = format!("{prefix}{name}");

    if let Some(task) = task_id.filter(|_| role == "worker") {
        let task = clean(task);
        if !task.is_empty() {
            let suffix = format!(" {task}");
            if value.chars().count() + suffix.chars().count() <= MAX_WIDTH {
                value.push_str(&suffix);
            }
        }
    }
    if let Some(glyph) = attention {
        let suffix = format!(" {glyph}");
        if value.chars().count() + suffix.chars().count() <= MAX_WIDTH {
            value.push_str(&suffix);
        }
    }
    value
}

fn clean(value: &str) -> String {
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

fn indent(depth: usize) -> String {
    if depth > MAX_INDENT {
        return COLLAPSED.to_string();
    }
    CELL.repeat(depth.saturating_sub(1))
}

fn truncate(value: &str, limit: usize) -> String {
    value.chars().take(limit).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn branch_role_then_child_identity_is_the_leading_display() {
        assert_eq!(
            descendant(1, true, "worker", "worker-alpha", None, None),
            "└─W worker-alpha"
        );
        assert_eq!(
            descendant(1, false, "subagent", "lint-helper", None, None),
            "├─S lint-helper"
        );
        assert_eq!(
            descendant(2, true, "subagent", "lint-helper", None, None),
            "│  └─S lint-helper"
        );
        assert_eq!(
            descendant(3, false, "worker", "worker", None, None),
            "│  │  ├─W worker"
        );
        assert_eq!(
            descendant(4, true, "worker", "worker", None, None),
            "…  └─W worker"
        );
    }

    #[test]
    fn identity_precedes_optional_task_and_attention() {
        assert_eq!(
            descendant(1, true, "worker", "a", Some("task-7"), Some('▸')),
            "└─W a task-7 ▸"
        );
        let value = descendant(
            1,
            true,
            "worker",
            "a-child-with-long-name",
            Some("task-123456"),
            Some('?'),
        );
        assert!(value.starts_with("└─W a-child-with-lon"), "{value:?}");
        assert!(
            !value.contains("task-"),
            "task must be dropped before identity: {value:?}"
        );
        assert!(
            !value.contains('?'),
            "attention must be dropped before identity: {value:?}"
        );
    }

    #[test]
    fn values_are_single_line_bounded_and_do_not_emit_untrusted_controls() {
        for depth in 0..12 {
            let value = descendant(
                depth,
                true,
                "worker",
                "child\nname\u{1b}[31m",
                Some("task\nsecret"),
                Some('?'),
            );
            assert!(value.chars().count() <= MAX_WIDTH, "{value:?}");
            assert!(!value.chars().any(char::is_control), "{value:?}");
            assert!(value.contains("child name"), "{value:?}");
        }
    }

    #[test]
    fn unknown_role_does_not_fabricate_a_branch() {
        assert_eq!(
            descendant(1, true, "reviewer", "reviewer-name", None, None),
            "reviewer-name"
        );
    }
}
