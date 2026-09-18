//! CLI boundary test for the tree-off marker. No Herdr server is involved: the socket path
//! is deliberately absent and lives inside the temporary state directory, and a live holder
//! entry for that same socket stops `apply` from spawning any subscriber at all.

use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};

const BIN: &str = env!("CARGO_BIN_EXE_agent-tree");

struct TempDir {
    path: PathBuf,
}

impl TempDir {
    fn new(tag: &str) -> TempDir {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "agent-tree-cli-{tag}-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst)
        ));
        std::fs::create_dir_all(&path).expect("create temp dir");
        TempDir { path }
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

/// Same derivation as `transport::server_tag`: sha256 of the socket, first 16 hex chars.
fn server_tag(socket: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(socket.as_bytes());
    format!("{:x}", hasher.finalize())[..16].to_string()
}

fn tree_off_marker(dir: &Path, socket: &str) -> PathBuf {
    dir.join(format!("tree-off-{}.flag", server_tag(socket)))
}

fn subscriber_lock(dir: &Path, socket: &str) -> PathBuf {
    dir.join(format!("subscriber-{}.lock", server_tag(socket)))
}

fn run(args: &[&str], dir: &Path, socket: &str) -> Output {
    Command::new(BIN)
        .args(args)
        .env("HERDR_PLUGIN_STATE_DIR", dir)
        .env("HERDR_SOCKET_PATH", socket)
        .output()
        .expect("run agent-tree")
}

#[test]
fn apply_clears_the_tree_off_marker_but_clear_and_toggle_do_not() {
    let dir = TempDir::new("marker");
    let socket = dir.path().join("absent.sock");
    let socket = socket.to_str().unwrap();

    // A live holder for this exact socket makes ensure_subscriber a no-op, so `apply` never
    // detaches a process. Nothing can outlive this test or leave the temp state directory.
    std::fs::write(
        subscriber_lock(dir.path(), socket),
        format!(
            "{{\"pid\":{},\"socket_path\":\"{}\",\"started_unix_ms\":0}}",
            std::process::id(),
            socket
        ),
    )
    .unwrap();

    let marker = tree_off_marker(dir.path(), socket);
    std::fs::write(&marker, b"tree-off\n").unwrap();

    let apply = run(&["apply"], dir.path(), socket);
    assert_eq!(
        apply.status.code(),
        Some(1),
        "apply cannot succeed without a server: {}",
        String::from_utf8_lossy(&apply.stderr)
    );
    assert!(
        !marker.exists(),
        "apply must clear the tree-off marker first"
    );
    assert!(
        !dir.path().join("subscriber.log").exists(),
        "the live holder must have prevented any subscriber spawn"
    );

    std::fs::write(&marker, b"tree-off\n").unwrap();
    let clear = run(&["clear"], dir.path(), socket);
    assert_eq!(
        clear.status.code(),
        Some(1),
        "clear cannot succeed without a server: {}",
        String::from_utf8_lossy(&clear.stderr)
    );
    assert!(
        marker.exists(),
        "clear must never touch the tree-off marker"
    );

    let toggle = run(&["toggle"], dir.path(), socket);
    assert_eq!(
        toggle.status.code(),
        Some(1),
        "toggle cannot decide an owner without a server: {}",
        String::from_utf8_lossy(&toggle.stderr)
    );
    assert!(
        marker.exists(),
        "toggle must fail closed before touching the tree-off marker"
    );

    for entry in std::fs::read_dir(dir.path()).unwrap() {
        let name = entry.unwrap().file_name().to_string_lossy().into_owned();
        assert!(
            name.starts_with("tree-off-") || name.starts_with("subscriber-"),
            "unexpected file in the temp state dir: {name}"
        );
    }
}
