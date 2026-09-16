//! Paused flag: one file in the plugin state dir, beside the subscriber lock.
//!
//! The flag's own presence means "paused": the subscriber publishes nothing and sets no
//! view, so Herdr's native Agents panel shows through. The file holds no state beyond its
//! existence — it is not a cache and is never read as tree or relationship data.

use crate::wire::R;
use std::path::{Path, PathBuf};

/// Socket-scoped paused flag, named like the subscriber lock so distinct servers that share
/// one plugin state dir never pause each other.
pub fn path(state_dir: &Path, socket: &str) -> PathBuf {
    state_dir.join(format!(
        "paused-{}.flag",
        crate::transport::server_tag(socket)
    ))
}

pub fn is_paused(path: &Path) -> bool {
    path.exists()
}

pub fn set(path: &Path, paused: bool) -> R<()> {
    if paused {
        std::fs::write(path, b"paused\n")
            .map_err(|e| format!("cannot write the paused flag at {}: {e}", path.display()))
    } else {
        match std::fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(format!(
                "cannot clear the paused flag at {}: {e}",
                path.display()
            )),
        }
    }
}

/// Flips the flag and returns the new paused state.
pub fn flip(path: &Path) -> R<bool> {
    let now = !is_paused(path);
    set(path, now)?;
    Ok(now)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::TempDir;

    #[test]
    fn path_is_socket_scoped_and_documented() {
        let dir = TempDir::new("pause-path");
        let a = path(dir.path(), "/tmp/a.sock");
        assert_eq!(a, path(dir.path(), "/tmp/a.sock"));
        assert_ne!(
            a,
            path(dir.path(), "/tmp/b.sock"),
            "servers never share a pause"
        );
        let name = a.file_name().unwrap().to_string_lossy();
        assert!(
            name.starts_with("paused-") && name.ends_with(".flag"),
            "{name}"
        );
        assert_eq!(a.parent().unwrap(), dir.path());
    }

    #[test]
    fn set_creates_and_removes_the_flag_and_flip_toggles() {
        let dir = TempDir::new("pause-flag");
        let flag = path(dir.path(), "/tmp/a.sock");
        assert!(!is_paused(&flag));

        set(&flag, true).unwrap();
        assert!(is_paused(&flag));
        set(&flag, true).unwrap();
        assert!(is_paused(&flag), "setting an existing flag is idempotent");

        set(&flag, false).unwrap();
        assert!(!is_paused(&flag));
        set(&flag, false).unwrap();
        assert!(!is_paused(&flag), "clearing an absent flag is a no-op");

        assert!(flip(&flag).unwrap());
        assert!(is_paused(&flag));
        assert!(!flip(&flag).unwrap());
        assert!(!is_paused(&flag));
    }
}
