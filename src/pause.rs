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
    state_dir.join(format!("paused-{}.flag", crate::transport::server_tag(socket)))
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
