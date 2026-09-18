//! Tree-ordering marker: one file in the plugin state dir, beside the subscriber lock.
//!
//! The marker's presence means Agent Tree ordering is **off**: the subscriber keeps
//! publishing `agent_tree_row`/`agent_tree_rank`, but no plugin view is active, so Herdr's
//! native Agents list (grouped or priority, whichever the client already uses) is shown.
//! The file holds no state beyond its existence — it is not a cache and is never read as
//! tree or relationship data.

use crate::wire::R;
use std::path::{Path, PathBuf};

/// Socket-scoped marker, named like the subscriber lock so distinct servers that share one
/// plugin state dir never change each other's ordering.
pub fn off_path(state_dir: &Path, socket: &str) -> PathBuf {
    state_dir.join(format!(
        "tree-off-{}.flag",
        crate::transport::server_tag(socket)
    ))
}

pub fn is_off(path: &Path) -> bool {
    path.exists()
}

pub fn set_off(path: &Path, off: bool) -> R<()> {
    if off {
        std::fs::write(path, b"tree-off\n").map_err(|e| {
            format!(
                "cannot write the tree-off marker at {}: {e}",
                path.display()
            )
        })
    } else {
        match std::fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(format!(
                "cannot clear the tree-off marker at {}: {e}",
                path.display()
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::TempDir;

    #[test]
    fn path_is_socket_scoped_and_documented() {
        let dir = TempDir::new("mode-path");
        let a = off_path(dir.path(), "/tmp/a.sock");
        assert_eq!(a, off_path(dir.path(), "/tmp/a.sock"));
        assert_ne!(
            a,
            off_path(dir.path(), "/tmp/b.sock"),
            "servers never share an ordering state"
        );
        let name = a.file_name().unwrap().to_string_lossy();
        assert!(
            name.starts_with("tree-off-") && name.ends_with(".flag"),
            "{name}"
        );
        assert_eq!(a.parent().unwrap(), dir.path());
    }

    #[test]
    fn set_creates_and_removes_the_marker_idempotently() {
        let dir = TempDir::new("mode-marker");
        let marker = off_path(dir.path(), "/tmp/a.sock");
        assert!(!is_off(&marker));

        set_off(&marker, true).unwrap();
        assert!(is_off(&marker));
        set_off(&marker, true).unwrap();
        assert!(is_off(&marker), "setting an existing marker is idempotent");

        set_off(&marker, false).unwrap();
        assert!(!is_off(&marker));
        set_off(&marker, false).unwrap();
        assert!(!is_off(&marker), "clearing an absent marker is a no-op");
    }
}
