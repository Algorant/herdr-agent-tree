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

    let branch = if is_last_sibling {
        "\u{2514}\u{2500}"
    } else {
        "\u{251c}\u{2500}"
    }; // └─ / ├─
    let task = task_id
        .filter(|_| role == "worker")
        .map(|value| truncate(value, MAX_TASK))
        .filter(|value| !value.is_empty());
    let hint = attention.map(|glyph| glyph.to_string());

    let full = compose(
        &indent(depth),
        branch,
        role_label,
        task.as_deref(),
        hint.as_deref(),
    );
    if full.chars().count() <= MAX_WIDTH {
        return Some(full);
    }
    // Drop order: task, then attention, then collapse the indent. Branch and role remain.
    let without_task = compose(&collapsed(depth), branch, role_label, None, hint.as_deref());
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

#[cfg(test)]
mod tests {
    use super::*;

    fn rendered(
        depth: usize,
        is_last_sibling: bool,
        role: &str,
        task: Option<&str>,
        attention: Option<char>,
    ) -> String {
        decoration(depth, is_last_sibling, role, task, attention)
            .expect("non-root placements with a known role always render")
    }

    #[test]
    fn root_carries_attention_only() {
        assert_eq!(decoration(0, true, "worker", Some("task-1"), None), None);
        assert_eq!(
            decoration(0, false, "subagent", Some("task-1"), Some('?')),
            Some("?".to_string())
        );
        assert_eq!(
            decoration(0, true, "worker", None, Some('▸')),
            Some("▸".to_string())
        );
    }

    #[test]
    fn depth_indent_branch_and_role_grammar() {
        assert_eq!(rendered(1, true, "worker", None, None), "└─W");
        assert_eq!(rendered(1, false, "worker", None, None), "├─W");
        assert_eq!(rendered(2, true, "subagent", None, None), "│  └─S");
        assert_eq!(rendered(3, false, "worker", None, None), "│  │  ├─W");
        assert_eq!(rendered(4, true, "worker", None, None), "…  │  │  └─W");
        assert_eq!(rendered(9, true, "worker", None, None), "…  │  │  └─W");
    }

    #[test]
    fn unknown_roles_never_render() {
        assert_eq!(decoration(1, true, "reviewer", None, None), None);
        assert_eq!(decoration(2, false, "", None, None), None);
    }

    #[test]
    fn worker_task_is_truncated_to_twelve_and_subagents_ignore_it() {
        assert_eq!(
            rendered(1, true, "worker", Some("task-1234567890"), None),
            "└─W task-1234567"
        );
        assert_eq!(
            rendered(1, true, "worker", Some("task-1234567890123"), None),
            "└─W task-1234567"
        );
        assert_eq!(
            rendered(1, true, "subagent", Some("task-1234567890123"), None),
            "└─S"
        );
        assert_eq!(rendered(1, true, "worker", Some(""), None), "└─W");
    }

    #[test]
    fn attention_is_appended_when_it_fits() {
        assert_eq!(
            rendered(1, true, "worker", Some("task-1"), Some('?')),
            "└─W task-1 ?"
        );
        assert_eq!(rendered(1, false, "subagent", None, Some('!')), "├─S !");
    }

    #[test]
    fn over_cap_drops_the_task_first_and_keeps_branch_and_role() {
        // 9 (collapsed indent) + 3 (branch/role) + 1 + 12 (task) + 2 (hint) = 27.
        let value = rendered(4, true, "worker", Some("task-1234567890123"), Some('?'));
        assert_eq!(value, "…  │  │  └─W ?");
        assert!(
            !value.contains("task"),
            "the task is the first thing dropped"
        );

        let value = rendered(7, false, "subagent", Some("task-1234567890"), None);
        assert_eq!(value, "…  │  │  ├─S");
    }

    #[test]
    fn every_rendered_value_respects_the_cap_and_never_leads_with_whitespace() {
        let long = "x".repeat(64);
        let tasks: [Option<&str>; 4] = [
            None,
            Some("t"),
            Some("task-1234567890123"),
            Some(long.as_str()),
        ];
        for depth in 0..12 {
            for is_last_sibling in [true, false] {
                for role in ["worker", "subagent", "reviewer"] {
                    for task in tasks {
                        for attention in [None, Some('?')] {
                            if let Some(value) =
                                decoration(depth, is_last_sibling, role, task, attention)
                            {
                                assert!(
                                    value.chars().count() <= MAX_WIDTH,
                                    "over cap at depth {depth}: {value:?}"
                                );
                                assert!(
                                    !value.starts_with(char::is_whitespace),
                                    "leading whitespace at depth {depth}: {value:?}"
                                );
                            }
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn decoration_never_emits_a_full_hash_or_untruncated_task() {
        let hash = "a".repeat(64);
        let value = rendered(1, true, "worker", Some(&hash), Some('?'));
        assert_eq!(value, "└─W aaaaaaaaaaaa ?");
        assert!(!value.contains(&hash));
        assert!(value.chars().count() <= MAX_WIDTH);
    }

    #[test]
    fn decoration_never_emits_a_path_routing_id_delivery_id_or_report_content() {
        let adversarial = [
            "/sessions/secret.jsonl",
            "route-0123456789abcdef0123456789abcdef",
            "delivery-0123456789abcdef0123456789abcdef",
            "report: the child failed because of a secret",
        ];
        for value in adversarial {
            let rendered = rendered(1, true, "worker", Some(value), Some('?'));
            assert!(
                !rendered.contains(value),
                "full metadata value leaked: {rendered:?}"
            );
            assert!(rendered.chars().count() <= MAX_WIDTH, "{rendered:?}");
        }
    }
}
