//! Runtime configuration: the single `ui.agent_panel_sort` key and its restore record.
//!
//! Task-10 §2 settles that Herdr has no socket method for selecting the native agent-panel
//! order, so the cycle action writes exactly one user-configuration key at runtime:
//! `agent_panel_sort` inside the existing `[ui]` table. Editing is line-based and preserves
//! every other byte: the key's own line is replaced in place (indentation and a trailing
//! comment survive), or one line is inserted directly after the `[ui]` header. Nothing else
//! is written, and the `[ui.sidebar.agents]` rows block is never touched.
//!
//! Before the first write the pre-existing value is captured once in
//! `original-sort-<tag>`; `clear` restores it (removing the key when it was absent) and drops
//! the record. A corrupt record fails closed rather than guessing the user's original.

use crate::wire::R;
use serde_json::{json, Value};
use std::io::Write;
use std::path::{Path, PathBuf};

pub const SORT_KEY: &str = "agent_panel_sort";
pub const GROUPED_VALUE: &str = "spaces";
pub const PRIORITY_VALUE: &str = "priority";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SortMode {
    Grouped,
    Priority,
}

/// The `[ui] agent_panel_sort` value Herdr treats as priority. Every other value, including
/// absent, `spaces`, the `workspaces` alias and unknown strings, is grouped.
pub fn classify(value: Option<&str>) -> SortMode {
    match value {
        Some(PRIORITY_VALUE) => SortMode::Priority,
        _ => SortMode::Grouped,
    }
}

/// `$XDG_CONFIG_HOME/herdr/config.toml`, falling back to `$HOME/.config/herdr/config.toml`.
pub fn config_path() -> R<PathBuf> {
    if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME") {
        if !xdg.is_empty() {
            return Ok(PathBuf::from(xdg).join("herdr").join("config.toml"));
        }
    }
    let home = std::env::var("HOME").map_err(|_| {
        "neither XDG_CONFIG_HOME nor HOME is set; cannot locate Herdr config.toml".to_string()
    })?;
    Ok(PathBuf::from(home)
        .join(".config")
        .join("herdr")
        .join("config.toml"))
}

/// Socket-scoped restore record, named like the paused flag so distinct servers that share
/// one plugin state dir do not overwrite each other's original value.
pub fn original_path(state_dir: &Path, socket: &str) -> PathBuf {
    state_dir.join(format!(
        "original-sort-{}",
        crate::transport::server_tag(socket)
    ))
}

/// The current `agent_panel_sort` classification for `config`.
pub fn read_sort(config: &Path) -> R<SortMode> {
    let text = read_text(config)?;
    Ok(classify(current_sort_value(&text).as_deref()))
}

/// The managed key's quoted value inside the existing `[ui]` table, if any.
fn current_sort_value(text: &str) -> Option<String> {
    let lines = Lines::split(text);
    let table = find_ui_table(&lines.items)?;
    lines.items[table.body_start..table.body_end]
        .iter()
        .find_map(|line| match key_value(line) {
            Some(Some(value)) => Some(value),
            _ => None,
        })
}

/// Writes `value` (`"spaces"` or `"priority"`) to the one managed line.
pub fn set_sort(config: &Path, value: &str) -> R<()> {
    let text = read_text(config)?;
    let mut lines = Lines::split(&text);
    if let Some(table) = find_ui_table(&lines.items) {
        match key_index(&lines.items, &table) {
            Some(index) => lines.items[index] = set_value_on_line(&lines.items[index], value),
            None => lines
                .items
                .insert(table.header + 1, format!("{SORT_KEY} = \"{value}\"")),
        }
    } else {
        // No [ui] table: append one. The record captures the original trailing-newline state
        // so a restore reproduces the file byte for byte.
        if text.is_empty() {
            lines.items.clear();
        }
        lines.items.push("[ui]".to_string());
        lines.items.push(format!("{SORT_KEY} = \"{value}\""));
        lines.trailing = true;
    }
    write_text(config, &lines.join())
}

/// Captures the pre-existing value once, before the first config write.
///
/// An existing record is validated and kept; a corrupt record is a hard error so the plugin
/// never overwrites a capture it cannot understand.
pub fn capture_original(state_dir: &Path, socket: &str, config: &Path) -> R<()> {
    let path = original_path(state_dir, socket);
    if path.exists() {
        let text = std::fs::read_to_string(&path)
            .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
        parse_record(&text)?;
        return Ok(());
    }
    let text = read_text(config)?;
    let lines = Lines::split(&text);
    let table = find_ui_table(&lines.items);
    let record = OriginalRecord {
        ui_present: table.is_some(),
        sort_line: table
            .as_ref()
            .and_then(|table| key_index(&lines.items, table))
            .map(|index| lines.items[index].clone()),
        file_ended_with_newline: text.ends_with('\n'),
    };
    let body = record_json(&record);
    let mut file = match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
    {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            // A concurrent capture won the race; validate what is there instead.
            let text = std::fs::read_to_string(&path)
                .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
            parse_record(&text)?;
            return Ok(());
        }
        Err(e) => return Err(format!("cannot create {}: {e}", path.display())),
    };
    file.write_all(body.as_bytes())
        .map_err(|e| format!("cannot write {}: {e}", path.display()))
}

/// Restores the captured original value and removes the record. Returns whether a record
/// existed, so the caller can reload the configuration only when something changed.
pub fn restore_original(state_dir: &Path, socket: &str, config: &Path) -> R<bool> {
    let path = original_path(state_dir, socket);
    if !path.exists() {
        return Ok(false);
    }
    let record_text = std::fs::read_to_string(&path)
        .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    let record = parse_record(&record_text)?;
    let text = read_text(config)?;
    let restored = restore_text(&text, &record);
    if restored != text {
        write_text(config, &restored)?;
    }
    std::fs::remove_file(&path).map_err(|e| format!("cannot remove {}: {e}", path.display()))?;
    Ok(true)
}

fn read_text(path: &Path) -> R<String> {
    match std::fs::read_to_string(path) {
        Ok(text) => Ok(text),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(e) => Err(format!("cannot read {}: {e}", path.display())),
    }
}

fn write_text(path: &Path, text: &str) -> R<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
    }
    std::fs::write(path, text).map_err(|e| format!("cannot write {}: {e}", path.display()))
}

#[derive(Debug, Clone, PartialEq)]
struct OriginalRecord {
    ui_present: bool,
    sort_line: Option<String>,
    file_ended_with_newline: bool,
}

fn record_json(record: &OriginalRecord) -> String {
    json!({
        "version": 1,
        "ui_present": record.ui_present,
        "sort_line": record.sort_line,
        "file_ended_with_newline": record.file_ended_with_newline,
    })
    .to_string()
}

fn parse_record(text: &str) -> R<OriginalRecord> {
    let value: Value = serde_json::from_str(text)
        .map_err(|e| format!("the original-sort record is corrupt and cannot be trusted: {e}"))?;
    let version = value
        .get("version")
        .and_then(Value::as_u64)
        .ok_or_else(|| "the original-sort record is corrupt: missing version".to_string())?;
    if version != 1 {
        return Err(format!(
            "the original-sort record has unsupported version {version}; refusing to guess the original value"
        ));
    }
    let ui_present = value
        .get("ui_present")
        .and_then(Value::as_bool)
        .ok_or_else(|| "the original-sort record is corrupt: missing ui_present".to_string())?;
    let sort_line = match value.get("sort_line") {
        None | Some(Value::Null) => None,
        Some(Value::String(line)) => Some(line.clone()),
        Some(_) => {
            return Err(
                "the original-sort record is corrupt: sort_line must be a string or null"
                    .to_string(),
            )
        }
    };
    let file_ended_with_newline = value
        .get("file_ended_with_newline")
        .and_then(Value::as_bool)
        .ok_or_else(|| {
            "the original-sort record is corrupt: missing file_ended_with_newline".to_string()
        })?;
    Ok(OriginalRecord {
        ui_present,
        sort_line,
        file_ended_with_newline,
    })
}

fn restore_text(text: &str, record: &OriginalRecord) -> String {
    let mut lines = Lines::split(text);
    if record.ui_present {
        match &record.sort_line {
            Some(original) => set_key_line(&mut lines, original),
            None => remove_key_line(&mut lines),
        }
        return lines.join();
    }
    remove_key_line(&mut lines);
    remove_ui_table_if_empty(&mut lines);
    let mut restored = lines.join();
    if !record.file_ended_with_newline {
        if let Some(stripped) = restored.strip_suffix('\n') {
            restored = stripped.to_string();
        }
    }
    restored
}

/// Owned lines plus whether the source ended with a newline, so `join` reproduces the text.
struct Lines {
    items: Vec<String>,
    trailing: bool,
}

impl Lines {
    fn split(text: &str) -> Lines {
        match text.strip_suffix('\n') {
            Some(head) => Lines {
                items: head.split('\n').map(str::to_string).collect(),
                trailing: true,
            },
            None => Lines {
                items: text.split('\n').map(str::to_string).collect(),
                trailing: false,
            },
        }
    }

    fn join(&self) -> String {
        if self.items.is_empty() {
            return String::new();
        }
        let mut joined = self.items.join("\n");
        if self.trailing {
            joined.push('\n');
        }
        joined
    }
}

struct Table {
    header: usize,
    body_start: usize,
    body_end: usize,
}

fn find_ui_table(items: &[String]) -> Option<Table> {
    for (index, line) in items.iter().enumerate() {
        if table_header(line) == Some("ui") {
            let body_start = index + 1;
            let body_end = items
                .iter()
                .enumerate()
                .skip(body_start)
                .find(|(_, later)| table_header(later).is_some())
                .map(|(later, _)| later)
                .unwrap_or(items.len());
            return Some(Table {
                header: index,
                body_start,
                body_end,
            });
        }
    }
    None
}

/// Returns the table name only for an exact `[name]` header, never `[[array]]` or a
/// `[ui.other]` subtable.
fn table_header(line: &str) -> Option<&str> {
    let trimmed = line.trim_start();
    if !trimmed.starts_with('[') || trimmed.starts_with("[[") {
        return None;
    }
    let close = trimmed.find(']')?;
    let name = trimmed[1..close].trim();
    if name.is_empty() || name.contains(']') {
        return None;
    }
    let rest = trimmed[close + 1..].trim_start();
    if rest.is_empty() || rest.starts_with('#') {
        Some(name)
    } else {
        None
    }
}

fn key_index(items: &[String], table: &Table) -> Option<usize> {
    (table.body_start..table.body_end).find(|&index| key_value(&items[index]).is_some())
}

/// `None` when the line is not the managed key; otherwise the key's quoted value, or `None`
/// for a present key without a parseable quoted string.
fn key_value(line: &str) -> Option<Option<String>> {
    let trimmed = line.trim_start();
    if trimmed.starts_with('#') {
        return None;
    }
    let rest = trimmed.strip_prefix(SORT_KEY)?;
    if !rest.starts_with(|c: char| c.is_whitespace() || c == '=') {
        return None;
    }
    let equals = trimmed.find('=')?;
    Some(quoted_value(&trimmed[equals + 1..]))
}

fn quoted_value(text: &str) -> Option<String> {
    let start = text.find('"')?;
    let mut value = String::new();
    let mut escaped = false;
    for c in text[start + 1..].chars() {
        if escaped {
            value.push(c);
            escaped = false;
            continue;
        }
        match c {
            '\\' => escaped = true,
            '"' => return Some(value),
            _ => value.push(c),
        }
    }
    None
}

fn quoted_span(text: &str) -> Option<(usize, usize)> {
    let start = text.find('"')?;
    let mut escaped = false;
    for (offset, c) in text[start + 1..].char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        match c {
            '\\' => escaped = true,
            '"' => return Some((start, start + 1 + offset + 1)),
            _ => {}
        }
    }
    None
}

/// Replaces only the value inside the managed key's existing line, keeping indentation and a
/// trailing comment.
fn set_value_on_line(line: &str, value: &str) -> String {
    let Some(equals) = line.find('=') else {
        return format!("{SORT_KEY} = \"{value}\"");
    };
    let (head, tail) = line.split_at(equals + 1);
    if let Some((start, end)) = quoted_span(tail) {
        format!("{head}{}\"{value}\"{}", &tail[..start], &tail[end..])
    } else if let Some(comment) = tail.find('#') {
        format!("{head} \"{value}\"  {}", &tail[comment..])
    } else {
        format!("{head} \"{value}\"")
    }
}

fn set_key_line(lines: &mut Lines, original: &str) {
    if let Some(table) = find_ui_table(&lines.items) {
        if let Some(index) = key_index(&lines.items, &table) {
            lines.items[index] = original.to_string();
            return;
        }
        lines.items.insert(table.header + 1, original.to_string());
        return;
    }
    if lines.items.len() == 1 && lines.items[0].is_empty() {
        lines.items.clear();
    }
    lines.items.push("[ui]".to_string());
    lines.items.push(original.to_string());
    lines.trailing = true;
}

fn remove_key_line(lines: &mut Lines) {
    if let Some(table) = find_ui_table(&lines.items) {
        if let Some(index) = key_index(&lines.items, &table) {
            lines.items.remove(index);
        }
    }
}

/// Removes a `[ui]` table only when every remaining body line is blank or a comment, i.e.
/// the table this plugin appended for one key is now empty. A table holding user keys stays.
fn remove_ui_table_if_empty(lines: &mut Lines) {
    let Some(table) = find_ui_table(&lines.items) else {
        return;
    };
    let empty = lines.items[table.body_start..table.body_end]
        .iter()
        .all(|line| {
            let trimmed = line.trim();
            trimmed.is_empty() || trimmed.starts_with('#')
        });
    if empty {
        lines.items.drain(table.header..table.body_end);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::TempDir;

    fn write(config: &Path, text: &str) {
        std::fs::create_dir_all(config.parent().unwrap()).unwrap();
        std::fs::write(config, text).unwrap();
    }

    fn read(config: &Path) -> String {
        std::fs::read_to_string(config).unwrap()
    }

    #[test]
    fn classification_maps_only_priority_to_priority() {
        assert_eq!(classify(Some("priority")), SortMode::Priority);
        assert_eq!(classify(Some("spaces")), SortMode::Grouped);
        assert_eq!(classify(Some("workspaces")), SortMode::Grouped);
        assert_eq!(classify(Some("bogus")), SortMode::Grouped);
        assert_eq!(classify(None), SortMode::Grouped);
    }

    #[test]
    fn existing_key_is_replaced_in_place_and_restored_byte_for_byte() {
        let dir = TempDir::new("config-replace");
        let config = dir.path().join("config.toml");
        let original = "[server]\nheadless_cols = 200\n\n[ui]\nsidebar_width = 26\nagent_panel_sort = \"workspaces\"  # user choice\n\n[ui.sidebar.agents]\nrows = [[\"state_icon\", \"$agent_tree_row\"]]\n";
        write(&config, original);
        assert_eq!(read_sort(&config).unwrap(), SortMode::Grouped);

        let socket = "/tmp/config-replace.sock";
        capture_original(dir.path(), socket, &config).unwrap();
        set_sort(&config, PRIORITY_VALUE).unwrap();
        assert_eq!(read_sort(&config).unwrap(), SortMode::Priority);
        let replaced = read(&config);
        assert!(replaced.contains("agent_panel_sort = \"priority\"  # user choice"));
        assert!(replaced.contains("sidebar_width = 26"));
        assert!(replaced.contains("rows = [[\"state_icon\", \"$agent_tree_row\"]]"));
        assert_eq!(replaced.matches("[ui]").count(), 1);

        assert!(restore_original(dir.path(), socket, &config).unwrap());
        assert_eq!(read(&config), original, "restore must be byte-identical");
        assert!(!original_path(dir.path(), socket).exists());
    }

    #[test]
    fn absent_key_is_inserted_after_the_ui_header_and_removed_on_restore() {
        let dir = TempDir::new("config-insert");
        let config = dir.path().join("config.toml");
        let original =
            "[ui]\nsidebar_width = 26\n\n[ui.sidebar.agents]\nrows = [[\"state_icon\"]]\n";
        write(&config, original);
        let socket = "/tmp/config-insert.sock";
        capture_original(dir.path(), socket, &config).unwrap();
        set_sort(&config, GROUPED_VALUE).unwrap();
        let inserted = read(&config);
        assert!(inserted.starts_with("[ui]\nagent_panel_sort = \"spaces\"\nsidebar_width = 26\n"));
        assert_eq!(inserted.matches("[ui]").count(), 1);

        assert!(restore_original(dir.path(), socket, &config).unwrap());
        assert_eq!(read(&config), original, "restore must be byte-identical");
    }

    #[test]
    fn a_missing_ui_table_is_appended_once_and_removed_again() {
        let dir = TempDir::new("config-append");
        let config = dir.path().join("config.toml");
        let original = "[server]\nheadless_cols = 200\n";
        write(&config, original);
        let socket = "/tmp/config-append.sock";
        capture_original(dir.path(), socket, &config).unwrap();
        set_sort(&config, PRIORITY_VALUE).unwrap();
        let appended = read(&config);
        assert!(appended
            .starts_with("[server]\nheadless_cols = 200\n[ui]\nagent_panel_sort = \"priority\"\n"));
        assert_eq!(appended.matches("[ui]").count(), 1);

        assert!(restore_original(dir.path(), socket, &config).unwrap());
        assert_eq!(read(&config), original, "restore must be byte-identical");
    }

    #[test]
    fn appending_to_a_file_without_a_trailing_newline_restores_exactly() {
        let dir = TempDir::new("config-no-newline");
        let config = dir.path().join("config.toml");
        let original = "[server]\nheadless_cols = 200";
        write(&config, original);
        let socket = "/tmp/config-no-newline.sock";
        capture_original(dir.path(), socket, &config).unwrap();
        set_sort(&config, GROUPED_VALUE).unwrap();
        assert!(read(&config).contains("\n[ui]\nagent_panel_sort = \"spaces\"\n"));
        assert!(restore_original(dir.path(), socket, &config).unwrap());
        assert_eq!(read(&config), original);
    }

    #[test]
    fn insertion_never_touches_the_agents_rows_block() {
        let dir = TempDir::new("config-rows");
        let config = dir.path().join("config.toml");
        let rows = "[ui.sidebar.agents]\nrows = [[\"state_icon\", \"$agent_tree_row\", \"terminal_title_stripped\"]]\n";
        write(
            &config,
            &format!("[ui]\nagent_panel_sort = \"priority\"\n{rows}"),
        );
        let socket = "/tmp/config-rows.sock";
        capture_original(dir.path(), socket, &config).unwrap();
        set_sort(&config, GROUPED_VALUE).unwrap();
        assert!(
            read(&config).contains(rows),
            "the rows block must be untouched"
        );
        assert_eq!(read(&config).matches("[ui]").count(), 1);
        assert_eq!(read(&config).matches("[ui.sidebar.agents]").count(), 1);
        restore_original(dir.path(), socket, &config).unwrap();
    }

    #[test]
    fn capture_is_idempotent_and_a_corrupt_record_fails_closed() {
        let dir = TempDir::new("config-corrupt");
        let config = dir.path().join("config.toml");
        write(&config, "[ui]\nagent_panel_sort = \"priority\"\n");
        let socket = "/tmp/config-corrupt.sock";
        capture_original(dir.path(), socket, &config).unwrap();
        // A second capture keeps the first record.
        set_sort(&config, GROUPED_VALUE).unwrap();
        capture_original(dir.path(), socket, &config).unwrap();
        std::fs::write(original_path(dir.path(), socket), b"not json").unwrap();
        let error = capture_original(dir.path(), socket, &config).unwrap_err();
        assert!(error.contains("corrupt"), "{error}");
        let error = restore_original(dir.path(), socket, &config).unwrap_err();
        assert!(error.contains("corrupt"), "{error}");
    }

    #[test]
    fn no_record_means_no_restore() {
        let dir = TempDir::new("config-none");
        let config = dir.path().join("config.toml");
        write(&config, "[ui]\nsidebar_width = 26\n");
        assert!(!restore_original(dir.path(), "/tmp/config-none.sock", &config).unwrap());
        assert_eq!(read(&config), "[ui]\nsidebar_width = 26\n");
    }
}
