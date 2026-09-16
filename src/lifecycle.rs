//! Lifecycle: single-instance lock, detached subscriber, shutdown and explicit clear.
//!
//! Herdr startup hooks are one-shot commands, so `start`/`apply` acquire a lock and detach
//! exactly one subscriber per server socket. No supervisor, no reconnect loop, no polling.

use crate::forest;
use crate::pause;
use crate::projection::{self, ViewState};
use crate::transport::{self, Model};
use crate::wire::{Client, Incoming, R};
use serde_json::{json, Value};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

static TERMINATE: AtomicBool = AtomicBool::new(false);

extern "C" fn on_signal(_: libc::c_int) {
    TERMINATE.store(true, Ordering::SeqCst);
}

fn install_signal_handlers() {
    unsafe {
        libc::signal(
            libc::SIGTERM,
            on_signal as extern "C" fn(libc::c_int) as usize as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGINT,
            on_signal as extern "C" fn(libc::c_int) as usize as libc::sighandler_t,
        );
    }
}

fn state_dir() -> R<PathBuf> {
    std::env::var("HERDR_PLUGIN_STATE_DIR")
        .map(PathBuf::from)
        .map_err(|_| {
            "HERDR_PLUGIN_STATE_DIR is not set; run agent-tree as a Herdr plugin command"
                .to_string()
        })
}

fn socket_path() -> R<String> {
    std::env::var("HERDR_SOCKET_PATH").map_err(|_| {
        "HERDR_SOCKET_PATH is not set; the plugin is scoped to the injected socket".to_string()
    })
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn lock_path(dir: &Path, socket: &str) -> PathBuf {
    dir.join(format!("subscriber-{}.lock", transport::server_tag(socket)))
}

struct LockInfo {
    pid: i32,
    socket: String,
}

struct LockGuard {
    path: PathBuf,
}

impl Drop for LockGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

fn read_lock(path: &Path) -> Option<LockInfo> {
    let text = std::fs::read_to_string(path).ok()?;
    let value: Value = serde_json::from_str(&text).ok()?;
    Some(LockInfo {
        pid: value.get("pid")?.as_i64()? as i32,
        socket: value.get("socket_path")?.as_str()?.to_string(),
    })
}

fn pid_alive(pid: i32) -> bool {
    pid > 0 && unsafe { libc::kill(pid, 0) == 0 }
}

fn live_holder(dir: &Path, socket: &str) -> Option<i32> {
    let path = lock_path(dir, socket);
    let info = read_lock(&path)?;
    if info.socket == socket && pid_alive(info.pid) {
        Some(info.pid)
    } else {
        None
    }
}

fn acquire_lock(dir: &Path, socket: &str) -> Option<LockGuard> {
    let path = lock_path(dir, socket);
    if let Some(info) = read_lock(&path) {
        if !pid_alive(info.pid) {
            let _ = std::fs::remove_file(&path);
        }
    }
    let body = json!({
        "pid": std::process::id(),
        "socket_path": socket,
        "started_unix_ms": now_ms(),
    })
    .to_string();
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .ok()?;
    if file.write_all(body.as_bytes()).is_err() {
        let _ = std::fs::remove_file(&path);
        return None;
    }
    Some(LockGuard { path })
}

/// Startup entrypoint: ensures exactly one subscriber per server socket.
///
/// Paused means no subscriber is started at all, so nothing can publish and the native
/// panel is left alone. The paused flag lives in the state dir and is not reset here, so a
/// deliberate off state survives a server restart until `apply` or `toggle` clears it.
pub fn start() -> R<()> {
    let dir = state_dir()?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("cannot create plugin state dir: {e}"))?;
    let socket = socket_path()?;
    ensure_subscriber(&dir, &socket, true)
}

fn ensure_subscriber(dir: &Path, socket: &str, wait_for_handoff: bool) -> R<()> {
    if pause::is_paused(&pause::path(dir, socket)) {
        eprintln!("agent-tree: paused; leaving Herdr's native Agents panel alone and not starting a subscriber");
        return Ok(());
    }

    if live_holder(dir, socket).is_some() {
        if !wait_for_handoff {
            // An explicit action only needs a subscriber present, not a fresh one. Waiting
            // for the live holder to exit would delay the visible change by seconds.
            return Ok(());
        }
        // A live handoff or a duplicate startup hook can race here. Wait briefly for the
        // previous holder to notice its dead socket, then give up rather than fight it.
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            if live_holder(dir, socket).is_none() {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        if let Some(pid) = live_holder(dir, socket) {
            eprintln!(
                "agent-tree: subscriber {pid} already holds {socket}; not starting a second one"
            );
            return Ok(());
        }
    }

    spawn_subscriber(dir)
}

fn spawn_subscriber(dir: &Path) -> R<()> {
    let exe = std::env::current_exe().map_err(|e| format!("cannot resolve own executable: {e}"))?;
    let log_path = dir.join("subscriber.log");
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .map_err(|e| format!("cannot open {}: {e}", log_path.display()))?;
    let log_err = log
        .try_clone()
        .map_err(|e| format!("cannot duplicate the subscriber log handle: {e}"))?;

    let mut command = std::process::Command::new(exe);
    command
        .arg("subscriber")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::from(log))
        .stderr(std::process::Stdio::from(log_err));
    unsafe {
        use std::os::unix::process::CommandExt;
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let child = command
        .spawn()
        .map_err(|e| format!("cannot start the agent-tree subscriber: {e}"))?;
    eprintln!("agent-tree: started subscriber pid {}", child.id());
    Ok(())
}

/// The single long-lived process: subscribe first, then reconcile on every relevant event.
///
/// Herdr closes an idle request connection, so each reconcile pass opens its own short-lived
/// request connection; the subscription connection stays open and drives the loop.
pub fn run_subscriber() -> R<()> {
    let dir = state_dir()?;
    let socket = socket_path()?;
    let _guard = match acquire_lock(&dir, &socket) {
        Some(guard) => guard,
        None => {
            eprintln!(
                "agent-tree: another subscriber already holds the lock for {socket}; exiting"
            );
            return Ok(());
        }
    };
    install_signal_handlers();

    // The subscription lives on its own connection: Herdr closes a connection that carries
    // further requests once it is streaming events.
    let mut events = Client::connect(&socket)?;
    events.subscribe(transport::SUBSCRIBED_EVENTS)?;

    let mut model = Model::default();
    let mut view = ViewState::default();
    let mut last_digest = String::new();
    let paused = pause::path(&dir, &socket);
    pass(&socket, &paused, &mut model, &mut view, &mut last_digest)?;
    events.set_stream_timeout(Duration::from_millis(500))?;

    loop {
        if TERMINATE.load(Ordering::SeqCst) {
            eprintln!("agent-tree: terminating on signal");
            break;
        }
        match events.read() {
            Ok(Incoming::Timeout) => continue,
            Ok(Incoming::Closed) => {
                eprintln!(
                    "agent-tree: Herdr closed the subscription; exiting without reconnecting"
                );
                break;
            }
            Ok(Incoming::Message(message)) => {
                if message.get("event").is_none() {
                    continue;
                }
                if let Err(e) = pass(&socket, &paused, &mut model, &mut view, &mut last_digest) {
                    eprintln!("agent-tree: reconcile pass failed: {e}");
                }
            }
            Err(e) => {
                eprintln!("agent-tree: {e}; exiting");
                break;
            }
        }
    }

    cleanup(&socket, &mut model);
    Ok(())
}

/// Removes only the plugin's own tokens and its own view, then reports what it did.
fn cleanup(socket: &str, model: &mut Model) {
    let cleared = projection::clear_own_tokens(socket, model);
    match projection::clear_view(socket) {
        Ok(result) => eprintln!("agent-tree: shutdown cleared {cleared} panes; view -> {result}"),
        Err(e) => eprintln!("agent-tree: shutdown cleared {cleared} panes; view clear failed: {e}"),
    }
}

/// One authoritative reconcile pass: fetch, decide, publish only real differences.
///
/// While paused the pass does nothing at all: no fetch, no recompute, no write. If a pause
/// lands after this pass has already published, the flag is re-checked and the projection is
/// removed, so the flag always wins the race and the native panel is left in charge.
fn pass(
    socket: &str,
    paused: &Path,
    model: &mut Model,
    view: &mut ViewState,
    last_digest: &mut String,
) -> R<()> {
    if pause::is_paused(paused) {
        return Ok(());
    }
    let rows = transport::fetch_rows(socket)?;
    model.install(rows);

    let digest = model.digest();
    if digest == *last_digest {
        return Ok(());
    }
    let placements = forest::build(&model.order, &model.rows);
    if !projection::within_rank_ceiling(placements.len()) {
        eprintln!(
            "agent-tree: {} rankable rows exceeds the fixed-width rank space; publishing nothing",
            placements.len()
        );
        *last_digest = digest;
        return Ok(());
    }
    let desired = projection::desired(&placements);
    let writes = projection::reconcile_tokens(socket, model, &desired)?;
    projection::ensure_view(socket, view)?;
    eprintln!(
        "agent-tree: {} ranked rows, {} panes written, view owned={} passive={}",
        placements.len(),
        writes,
        view.owned(),
        view.passive()
    );
    *last_digest = model.digest();
    if pause::is_paused(paused) {
        let cleared = projection::clear_own_tokens(socket, model);
        match projection::clear_view(socket) {
            Ok(result) => eprintln!(
                "agent-tree: paused during a reconcile pass; cleared {cleared} panes; view -> {result}"
            ),
            Err(e) => eprintln!(
                "agent-tree: paused during a reconcile pass; cleared {cleared} panes; view clear failed: {e}"
            ),
        }
        *view = ViewState::default();
    }
    Ok(())
}

/// Explicit `apply` action: ensures a subscriber and re-installs the projection once.
///
/// Enable does not run startup hooks and disable clears the view without running plugin code,
/// so an explicit apply is the documented way to restore the projection in a running server.
/// Applying always means "show the tree": it clears the paused flag first so it can never be
/// a silent no-op.
pub fn apply() -> R<()> {
    let dir = state_dir()?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("cannot create plugin state dir: {e}"))?;
    let socket = socket_path()?;
    pause::set(&pause::path(&dir, &socket), false)?;
    ensure_subscriber(&dir, &socket, false)?;
    let paused = pause::path(&dir, &socket);
    let mut model = Model::default();
    let mut view = ViewState::default();
    let mut digest = String::new();
    pass(&socket, &paused, &mut model, &mut view, &mut digest)
}

/// Explicit `clear` action: removes only the plugin's own tokens and its own view.
///
/// It does not touch the paused flag: a clear while paused stays clear instead of
/// re-arming a subscriber that would immediately publish again.
pub fn clear() -> R<()> {
    let socket = socket_path()?;
    clear_projection(&socket)
}

/// `toggle` action: flips the paused flag and makes the change visible immediately.
///
/// Pausing clears the projection (native panel takes over); resuming applies it. The flag
/// lives in the plugin state dir and is not reset by `start`, so a deliberate off state
/// survives a server restart until `apply` or another `toggle`.
pub fn toggle() -> R<()> {
    let dir = state_dir()?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("cannot create plugin state dir: {e}"))?;
    let socket = socket_path()?;
    if pause::flip(&pause::path(&dir, &socket))? {
        clear_projection(&socket)?;
        eprintln!("agent-tree: paused; Herdr's native Agents panel is back until the next toggle");
    } else {
        apply()?;
        eprintln!("agent-tree: resumed; the delegation tree projection is back");
    }
    Ok(())
}

fn clear_projection(socket: &str) -> R<()> {
    let rows = transport::fetch_rows(socket)?;
    let mut model = Model::default();
    model.install(rows);
    let cleared = projection::clear_own_tokens(socket, &mut model);
    let view = projection::clear_view(socket)?;
    eprintln!("agent-tree: cleared {cleared} panes; view -> {view}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::TempDir;

    #[test]
    fn paused_pass_publishes_nothing_and_sets_no_view() {
        let dir = TempDir::new("paused-pass");
        let paused = pause::path(dir.path(), "/tmp/agent-tree-pass.sock");
        pause::set(&paused, true).unwrap();

        let mut model = Model::default();
        let mut view = ViewState::default();
        let mut digest = String::new();
        // The unreachable socket proves the paused pass returns before any transport call.
        let outcome = pass(
            "/nonexistent/agent-tree.sock",
            &paused,
            &mut model,
            &mut view,
            &mut digest,
        );
        assert!(
            outcome.is_ok(),
            "a paused pass must be a no-op: {outcome:?}"
        );
        assert!(model.order.is_empty());
        assert!(model.rows.is_empty());
        assert!(digest.is_empty());
        assert!(!view.owned());
        assert!(!view.passive());
    }
}
