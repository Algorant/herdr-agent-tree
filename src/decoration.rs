//! Builds the plugin-owned branch cell for validated descendants.
//!
//! Workers carry only their tree marker; their task workspace is already shown by Herdr.
//! Subagents also carry a bounded own name so siblings in the parent's location remain
//! distinguishable.

use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

/// Maximum display columns occupied by a Subagent's own name, including an ellipsis.
pub const MAX_NAME_WIDTH: usize = 12;

const MAX_INDENT: usize = 3;
const CELL: &str = "\u{2502}  "; // "│  "
const COLLAPSED: &str = "\u{2026}  "; // "…  "

pub fn descendant(
    depth: usize,
    is_last_sibling: bool,
    role: &str,
    name: Option<&str>,
) -> Option<String> {
    let role_label = match role {
        "worker" => "W",
        "subagent" => "S",
        _ => return None,
    };
    let branch = if is_last_sibling { "└─" } else { "├─" };
    let indent = indent(depth);
    let mut value = format!("{indent}{branch}{role_label}");

    if role == "subagent" {
        if let Some(name) = name.and_then(short_name) {
            value.push(' ');
            value.push_str(&name);
        }
    }
    Some(value)
}

fn short_name(value: &str) -> Option<String> {
    let clean = clean(value);
    if clean.is_empty() {
        return None;
    }
    if UnicodeWidthStr::width(clean.as_str()) <= MAX_NAME_WIDTH {
        return Some(clean);
    }

    let name_width = MAX_NAME_WIDTH - UnicodeWidthStr::width("…");
    let mut width = 0;
    let mut prefix = String::new();
    for ch in clean.chars() {
        let char_width = UnicodeWidthChar::width(ch).unwrap_or(0);
        if width + char_width > name_width {
            break;
        }
        prefix.push(ch);
        width += char_width;
    }
    prefix.push('…');
    Some(prefix)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workers_show_only_the_branch_and_role_marker() {
        assert_eq!(
            descendant(1, true, "worker", Some("worker-task-3")),
            Some("└─W".to_string())
        );
    }

    #[test]
    fn subagents_show_branch_role_and_bounded_own_name() {
        assert_eq!(
            descendant(1, true, "subagent", Some("live-sidebar")),
            Some("└─S live-sidebar".to_string())
        );
        assert_eq!(
            descendant(1, false, "subagent", Some("scout-release-notes")),
            Some("├─S scout-relea…".to_string())
        );
        assert_eq!(
            descendant(2, true, "subagent", Some("scout-release-notes")),
            Some("│  └─S scout-relea…".to_string())
        );
    }

    #[test]
    fn name_limit_counts_display_columns_and_includes_ellipsis() {
        for name in ["scout-release-notes", "界界界界界界界"] {
            let value = short_name(name).unwrap();
            assert!(
                UnicodeWidthStr::width(value.as_str()) <= MAX_NAME_WIDTH,
                "{value:?}"
            );
            assert!(value.ends_with('…'), "{value:?}");
        }
        assert_eq!(
            UnicodeWidthStr::width(short_name("界界界界界界界").unwrap().as_str()),
            11
        );
    }

    #[test]
    fn no_or_empty_name_leaves_only_the_marker_and_controls_are_cleaned() {
        assert_eq!(
            descendant(1, true, "subagent", None),
            Some("└─S".to_string())
        );
        assert_eq!(
            descendant(1, true, "subagent", Some("\n\u{1b}")),
            Some("└─S".to_string())
        );
        assert_eq!(descendant(1, true, "reviewer", Some("name")), None);
    }

    #[test]
    fn branch_depth_and_sibling_glyphs_are_preserved() {
        assert_eq!(
            descendant(3, false, "subagent", None),
            Some("│  │  ├─S".to_string())
        );
        assert_eq!(
            descendant(4, true, "worker", None),
            Some("…  └─W".to_string())
        );
    }
}
