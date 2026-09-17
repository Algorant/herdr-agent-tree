//! Lifecycle: single-instance lock, detached subscriber, shutdown and explicit clear.
//!
//! Herdr startup hooks are one-shot commands, so `start`/`apply` acquire a lock and detach
//! exactly one subscriber per server socket. No supervisor, no reconnect loop, no polling.

use crate::config;
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

/// True when the pid exists, whether or not this user may signal it.
///
/// `kill(pid, 0)` reports `EPERM` for a live process owned by another user. Treating that
/// as dead would silently discard a foreign lock and start a competing subscriber, so
/// `EPERM` counts as alive; the verification path then refuses it instead of signaling it.
fn pid_alive(pid: i32) -> bool {
    if pid <= 0 {
        return false;
    }
    if unsafe { libc::kill(pid, 0) } == 0 {
        return true;
    }
    std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
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

fn proc_uid(pid: i32) -> Option<u32> {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(format!("/proc/{pid}"))
        .ok()
        .map(|metadata| metadata.uid())
}

fn proc_environ(pid: i32) -> Option<Vec<(String, String)>> {
    let raw = std::fs::read(format!("/proc/{pid}/environ")).ok()?;
    if raw.is_empty() {
        return None;
    }
    Some(
        raw.split(|byte| *byte == 0)
            .filter_map(|entry| {
                let text = String::from_utf8_lossy(entry);
                let (key, value) = text.split_once('=')?;
                Some((key.to_string(), value.to_string()))
            })
            .collect(),
    )
}

fn proc_cmdline(pid: i32) -> Option<Vec<String>> {
    let raw = std::fs::read(format!("/proc/{pid}/cmdline")).ok()?;
    let argv: Vec<String> = raw
        .split(|byte| *byte == 0)
        .filter(|entry| !entry.is_empty())
        .map(|entry| String::from_utf8_lossy(entry).into_owned())
        .collect();
    if argv.is_empty() {
        None
    } else {
        Some(argv)
    }
}

/// The kernel appends `" (deleted)"` once an executable is unlinked. `scripts/deploy.sh`
/// atomically replaces the stage directory by renaming it to a `.stage-old.*` sibling and
/// then deleting it, so a still-running subscriber's `/proc/<pid>/exe` is exactly that old
/// sibling path with the suffix. Normalizing the suffix away is what lets the replacement
/// verify the process it is about to signal instead of mistaking it for a foreign one.
fn proc_exe(pid: i32) -> Option<PathBuf> {
    let raw = std::fs::read_link(format!("/proc/{pid}/exe")).ok()?;
    let text = raw.to_string_lossy();
    let normalized = text.strip_suffix(" (deleted)").unwrap_or(text.as_ref());
    Some(PathBuf::from(normalized))
}

fn env_value<'a>(environ: &'a [(String, String)], key: &str) -> Option<&'a str> {
    environ
        .iter()
        .find(|(name, _)| name == key)
        .map(|(_, value)| value.as_str())
}

fn same_path(a: &Path, b: &Path) -> bool {
    if a == b {
        return true;
    }
    match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

fn refuse(pid: i32, why: &str) -> String {
    format!(
        "pid {pid} holds this plugin's subscriber lock but {why}; refusing to signal it or start a replacement (resolve pid {pid} manually)"
    )
}

/// True when a normalized `/proc/<pid>/exe` path is one of this plugin's own binaries.
///
/// The trusted set is derived only from the running reload executable, never from a holder's
/// self-reported environment: a same-user process can set `HERDR_PLUGIN_ROOT` to anything.
/// The reload executable's own staged root is trusted directly, and an atomically replaced
/// stage is trusted through its exact `.stage-old.*` sibling under the same prefix (the path
/// a still-running subscriber's `(deleted)` link names after `deploy.sh` renames and deletes
/// the previous stage).
fn trusted_binary(exe: &Path) -> bool {
    std::env::current_exe()
        .map(|current| trusted_binary_for(&current, exe))
        .unwrap_or(false)
}

fn trusted_binary_for(current: &Path, exe: &Path) -> bool {
    if !exe.file_name().is_some_and(|name| name == "agent-tree") {
        return false;
    }
    if exe == current {
        return true;
    }
    let Some(stage_root) = current.parent().and_then(Path::parent) else {
        return false;
    };
    if exe.starts_with(stage_root) {
        return true;
    }
    stage_root
        .parent()
        .is_some_and(|prefix| is_replaced_stage(exe, prefix))
}

/// True when `exe` sits under `base` inside a `.stage-old.*` directory, the sibling of a
/// stage directory that `scripts/deploy.sh` renames before deleting it.
fn is_replaced_stage(exe: &Path, base: &Path) -> bool {
    let Ok(relative) = exe.strip_prefix(base) else {
        return false;
    };
    matches!(
        relative.components().next(),
        Some(std::path::Component::Normal(first))
            if first.to_string_lossy().starts_with(".stage-old.")
    )
}

/// Confirms a live lock holder is this plugin's own subscriber for this socket before any
/// signal is sent. Every signal is required to agree: same UID, the plugin id, socket and
/// state directory in the process environment, `agent-tree subscriber` argv, and a
/// normalized executable path inside the plugin's own staged install paths.
fn verify_holder(pid: i32, dir: &Path, socket: &str) -> R<()> {
    let Some(uid) = proc_uid(pid) else {
        return Err(refuse(pid, "its /proc ownership cannot be read"));
    };
    let euid = unsafe { libc::geteuid() };
    if uid != euid {
        return Err(refuse(
            pid,
            &format!("it runs as uid {uid}, not this user's uid {euid}"),
        ));
    }
    let Some(environ) = proc_environ(pid) else {
        return Err(refuse(pid, "its /proc environ is unreadable or empty"));
    };
    match env_value(&environ, "HERDR_PLUGIN_ID") {
        Some("agent-tree") => {}
        Some(other) => {
            return Err(refuse(
                pid,
                &format!("its HERDR_PLUGIN_ID is {other:?}, not agent-tree"),
            ))
        }
        None => return Err(refuse(pid, "its HERDR_PLUGIN_ID is unset")),
    }
    match env_value(&environ, "HERDR_SOCKET_PATH") {
        Some(path) if path == socket => {}
        Some(other) => {
            return Err(refuse(
                pid,
                &format!("its HERDR_SOCKET_PATH is {other:?}, not the injected {socket:?}"),
            ))
        }
        None => return Err(refuse(pid, "its HERDR_SOCKET_PATH is unset")),
    }
    match env_value(&environ, "HERDR_PLUGIN_STATE_DIR") {
        Some(state) if same_path(Path::new(state), dir) => {}
        Some(state) => {
            return Err(refuse(
                pid,
                &format!(
                    "its HERDR_PLUGIN_STATE_DIR is {state:?}, not {}",
                    dir.display()
                ),
            ))
        }
        None => return Err(refuse(pid, "its HERDR_PLUGIN_STATE_DIR is unset")),
    }
    let Some(argv) = proc_cmdline(pid) else {
        return Err(refuse(pid, "its /proc cmdline is unreadable"));
    };
    let argv0_is_agent_tree = argv
        .first()
        .and_then(|arg| Path::new(arg).file_name())
        .is_some_and(|name| name == "agent-tree");
    let argv1_is_subscriber = argv.get(1).map(String::as_str) == Some("subscriber");
    if !argv0_is_agent_tree || !argv1_is_subscriber {
        return Err(refuse(
            pid,
            &format!("its argv is {argv:?}, not an `agent-tree subscriber` process"),
        ));
    }
    let Some(exe) = proc_exe(pid) else {
        return Err(refuse(pid, "its /proc executable link is unreadable"));
    };
    if !exe.file_name().is_some_and(|name| name == "agent-tree") {
        return Err(refuse(
            pid,
            &format!(
                "its executable is {}, not an agent-tree binary",
                exe.display()
            ),
        ));
    }
    if !trusted_binary(&exe) {
        return Err(refuse(
            pid,
            &format!(
                "its executable {} is outside this plugin's own staged install paths",
                exe.display()
            ),
        ));
    }
    Ok(())
}

/// Returns the verified live subscriber pid for this socket, or removes and ignores a dead
/// process's stale lock. A corrupt, socket-mismatched, foreign or unverifiable holder is a
/// hard error: nothing is signaled and no replacement is started.
fn live_verified_holder(dir: &Path, socket: &str) -> R<Option<i32>> {
    let path = lock_path(dir, socket);
    let info = match read_lock(&path) {
        Some(info) => info,
        None => {
            if path.exists() {
                return Err(format!(
                    "the subscriber lock {} is corrupt or unreadable; refusing to signal any process (remove it manually if no subscriber is running)",
                    path.display()
                ));
            }
            return Ok(None);
        }
    };
    if info.socket != socket {
        return Err(format!(
            "the subscriber lock {} names socket {:?}, not this server's {:?}; refusing to signal pid {}",
            path.display(),
            info.socket,
            socket,
            info.pid
        ));
    }
    if !pid_alive(info.pid) {
        // The recorded process is gone: recover the stale lock so a fresh subscriber can
        // take it.
        let _ = std::fs::remove_file(&path);
        return Ok(None);
    }
    verify_holder(info.pid, dir, socket)?;
    Ok(Some(info.pid))
}

/// Replaces the verified live subscriber with one started from the running executable.
///
/// The old process is signaled only after verification, then awaited with a bound; on
/// timeout this fails without spawning, so two subscribers never race for the lock.
fn replace_subscriber(dir: &Path, socket: &str) -> R<()> {
    if let Some(pid) = live_verified_holder(dir, socket)? {
        signal_subscriber(pid)?;
        wait_for_subscriber_exit(dir, socket, pid)?;
    }
    let pid = spawn_subscriber(dir)?;
    wait_for_new_subscriber(dir, socket, pid)
}

fn signal_subscriber(pid: i32) -> R<()> {
    if unsafe { libc::kill(pid, libc::SIGTERM) } == 0 {
        eprintln!("agent-tree: replacing subscriber pid {pid}");
        return Ok(());
    }
    let error = std::io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) {
        // It exited between verification and the signal; nothing is left to stop.
        return Ok(());
    }
    Err(format!(
        "cannot signal the verified subscriber pid {pid}: {error}"
    ))
}

/// Bounded wait for the verified subscriber to exit and release its lock. A timeout is an
/// error and no replacement is spawned while the old holder may still own the lock.
fn wait_for_subscriber_exit(dir: &Path, socket: &str, pid: i32) -> R<()> {
    let path = lock_path(dir, socket);
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if !pid_alive(pid) {
            // Any lock still naming the exited process is stale; drop it before spawning.
            if read_lock(&path).is_some_and(|info| info.pid == pid) {
                let _ = std::fs::remove_file(&path);
            }
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "subscriber pid {pid} did not exit and release {} after SIGTERM; not starting a replacement",
                path.display()
            ));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Bounded wait for the freshly spawned subscriber to own the lock, so `reload` returns
/// only once the new build is the confirmed sole subscriber.
fn wait_for_new_subscriber(dir: &Path, socket: &str, pid: i32) -> R<()> {
    let path = lock_path(dir, socket);
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if read_lock(&path).is_some_and(|info| info.pid == pid) && pid_alive(pid) {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "the replacement subscriber pid {pid} did not acquire {} within 10s",
                path.display()
            ));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Startup entrypoint: ensures exactly one subscriber per server socket.
///
/// Paused means no subscriber is started at all, so nothing can publish and the native
/// panel is left alone. The paused flag lives in the state dir and is not reset here, so a
/// deliberate off state survives a server restart until `apply` or `cycle` clears it.
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

    spawn_subscriber(dir)?;
    Ok(())
}

fn spawn_subscriber(dir: &Path) -> R<i32> {
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
    let pid = child.id() as i32;
    eprintln!("agent-tree: started subscriber pid {pid}");
    Ok(pid)
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

/// Deploy-grade entrypoint: guarantee the sole subscriber runs this build, then re-apply.
///
/// Unlike `apply`, which only ensures some subscriber is present, `reload` replaces a live
/// subscriber with one started from the running executable. Every holder is verified before
/// it is signaled, a dead lock is recovered, and a foreign or unverifiable holder fails
/// clearly without being touched. The projection is then confirmed with a synchronous pass.
pub fn reload() -> R<()> {
    let dir = state_dir()?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("cannot create plugin state dir: {e}"))?;
    let socket = socket_path()?;
    replace_subscriber(&dir, &socket)?;
    let paused = pause::path(&dir, &socket);
    pause::set(&paused, false)?;
    let mut model = Model::default();
    let mut view = ViewState::default();
    let mut digest = String::new();
    pass(&socket, &paused, &mut model, &mut view, &mut digest)
}

/// Explicit `clear` action: removes only the plugin's own tokens and its own view, and
/// restores the user's pre-existing `ui.agent_panel_sort` captured by the cycle.
///
/// It does not touch the paused flag: a clear while paused stays clear instead of
/// re-arming a subscriber that would immediately publish again.
pub fn clear() -> R<()> {
    let dir = state_dir()?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("cannot create plugin state dir: {e}"))?;
    let socket = socket_path()?;
    clear_projection(&socket)?;
    let config = config::config_path()?;
    if config::restore_original(&dir, &socket, &config)? {
        reload_config(&socket)?;
        eprintln!("agent-tree: restored the original ui.agent_panel_sort value");
    }
    Ok(())
}

/// Native agent-panel mode. Grouped and priority are Herdr's own modes; tree is this
/// plugin's view.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Grouped,
    Priority,
    Tree,
}

impl Mode {
    pub fn next(self) -> Mode {
        match self {
            Mode::Grouped => Mode::Priority,
            Mode::Priority => Mode::Tree,
            Mode::Tree => Mode::Grouped,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Mode::Grouped => "grouped",
            Mode::Priority => "priority",
            Mode::Tree => "tree",
        }
    }
}

/// The pause flag is the tree/native discriminator; the config value tells the two native
/// modes apart. Unknown, absent and `workspaces` values are grouped (task-10 §2.1).
pub fn detect_mode(paused: bool, sort: config::SortMode) -> Mode {
    if !paused {
        return Mode::Tree;
    }
    match sort {
        config::SortMode::Priority => Mode::Priority,
        config::SortMode::Grouped => Mode::Grouped,
    }
}

/// Ownership of the agent view reported by the read-only probe.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ViewOwner {
    None,
    Ours,
    Foreign(String),
}

/// Classifies a probe result. A reported active view without a named source, or a probe that
/// does not report `active`, is a hard error: the cycle never guesses and never evicts.
pub fn classify_view(active: Option<bool>, source: Option<&str>) -> R<ViewOwner> {
    match active {
        Some(false) => Ok(ViewOwner::None),
        Some(true) => match source {
            Some(source) if source == projection::VIEW_SOURCE => Ok(ViewOwner::Ours),
            Some(source) => Ok(ViewOwner::Foreign(source.to_string())),
            None => Err(
                "Herdr reported an active agent view without naming its source; refusing to cycle"
                    .to_string(),
            ),
        },
        None => {
            Err("could not determine the active agent view owner; refusing to cycle".to_string())
        }
    }
}

/// The paused flag with our own view still active is a desync: the native panel is in charge,
/// so the stale view must be cleared before the native mode is advanced.
pub fn needs_desync_clear(owner: &ViewOwner, paused: bool) -> bool {
    matches!(owner, ViewOwner::Ours) && paused
}

/// `cycle` action: advances grouped -> priority -> tree -> grouped exactly once.
///
/// Grouped and priority delegate entirely to Herdr's native modes through
/// `ui.agent_panel_sort` plus a live config reload; tree uses the existing projection. A view
/// owned by another source is never evicted: the action refuses and changes nothing.
pub fn cycle() -> R<()> {
    let dir = state_dir()?;
    std::fs::create_dir_all(&dir).map_err(|e| format!("cannot create plugin state dir: {e}"))?;
    let socket = socket_path()?;
    let config = config::config_path()?;
    let paused = pause::path(&dir, &socket);

    let probe = projection::probe_view(&socket)?;
    let owner = classify_view(
        probe.get("active").and_then(Value::as_bool),
        probe.get("source").and_then(Value::as_str),
    )?;
    if let ViewOwner::Foreign(source) = &owner {
        return Err(format!(
            "the agent view is owned by {source}; refusing to cycle and never evicting another source (clear or disable it first)"
        ));
    }
    if needs_desync_clear(&owner, pause::is_paused(&paused)) {
        projection::clear_view(&socket)?;
        eprintln!("agent-tree: cleared a stale tree view while the native panel was paused");
    }

    let from = detect_mode(pause::is_paused(&paused), config::read_sort(&config)?);
    let to = from.next();
    match from {
        Mode::Grouped => {
            config::capture_original(&dir, &socket, &config)?;
            pause::set(&paused, true)?;
            config::set_sort(&config, config::PRIORITY_VALUE)?;
            reload_config(&socket)?;
        }
        Mode::Priority => {
            apply()?;
        }
        Mode::Tree => {
            config::capture_original(&dir, &socket, &config)?;
            // Set the pause flag before the config write so a concurrent subscriber pass
            // cannot reinstall the view between the clear and the reload.
            pause::set(&paused, true)?;
            clear_projection(&socket)?;
            config::set_sort(&config, config::GROUPED_VALUE)?;
            reload_config(&socket)?;
        }
    }
    eprintln!("agent-tree: mode {} -> {}", from.label(), to.label());
    Ok(())
}

/// Applies a written `agent_panel_sort` to the running server without a restart.
fn reload_config(socket: &str) -> R<()> {
    let result = crate::wire::request(socket, "server.reload_config", json!({}))?;
    let status = result
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    if status != "applied" {
        return Err(format!(
            "Herdr did not apply the configuration (status {status}); the agent panel may still show the previous mode"
        ));
    }
    if let Some(diagnostics) = result.get("diagnostics") {
        if diagnostics.as_array().is_some_and(|list| !list.is_empty()) {
            eprintln!("agent-tree: config reload reported diagnostics: {diagnostics}");
        }
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

    #[test]
    fn mode_detection_and_cycle_order_are_exact() {
        use config::SortMode;

        assert_eq!(detect_mode(false, SortMode::Grouped), Mode::Tree);
        assert_eq!(detect_mode(false, SortMode::Priority), Mode::Tree);
        assert_eq!(detect_mode(true, SortMode::Grouped), Mode::Grouped);
        assert_eq!(detect_mode(true, SortMode::Priority), Mode::Priority);

        assert_eq!(Mode::Grouped.next(), Mode::Priority);
        assert_eq!(Mode::Priority.next(), Mode::Tree);
        assert_eq!(Mode::Tree.next(), Mode::Grouped);
        assert_eq!(Mode::Grouped.label(), "grouped");
        assert_eq!(Mode::Priority.label(), "priority");
        assert_eq!(Mode::Tree.label(), "tree");
    }

    #[test]
    fn view_owner_classification_refuses_foreign_and_unknown_owners() {
        assert_eq!(classify_view(Some(false), None).unwrap(), ViewOwner::None);
        assert_eq!(
            classify_view(Some(true), Some(projection::VIEW_SOURCE)).unwrap(),
            ViewOwner::Ours
        );
        assert_eq!(
            classify_view(Some(true), Some("plugin:other")).unwrap(),
            ViewOwner::Foreign("plugin:other".to_string())
        );
        assert!(classify_view(Some(true), None).is_err());
        assert!(classify_view(None, None).is_err());

        assert!(needs_desync_clear(&ViewOwner::Ours, true));
        assert!(!needs_desync_clear(&ViewOwner::Ours, false));
        assert!(!needs_desync_clear(&ViewOwner::None, true));
        assert!(!needs_desync_clear(
            &ViewOwner::Foreign("plugin:other".to_string()),
            true
        ));
    }

    #[test]
    fn trusted_binary_accepts_only_the_current_stage_and_its_replaced_sibling() {
        let prefix = Path::new("/home/user/.local/share/herdr-agent-tree");
        let current = prefix.join("stage/src/agent-tree");
        let replaced = prefix.join(".stage-old.42/src/agent-tree");

        assert!(trusted_binary_for(&current, &current));
        assert!(
            trusted_binary_for(&current, &replaced),
            "the (deleted) sibling of an atomically replaced stage still belongs to the plugin"
        );
        assert!(trusted_binary_for(
            &current,
            &prefix.join("stage/other/agent-tree")
        ));
        assert!(!trusted_binary_for(
            &current,
            Path::new("/usr/bin/agent-tree")
        ));
        assert!(!trusted_binary_for(&current, Path::new("/tmp/agent-tree")));
        assert!(!trusted_binary_for(
            &current,
            Path::new("/home/user/.local/share/herdr-agent-tree/other/agent-tree")
        ));
        assert!(!trusted_binary_for(
            &current,
            Path::new("/home/user/.local/share/herdr-agent-tree/other/stage/src/agent-tree")
        ));
    }

    #[test]
    fn unreadable_lock_and_wrong_socket_are_refused() {
        let dir = TempDir::new("refuse-lock");
        let socket = "/tmp/agent-tree-refuse.sock";
        let path = lock_path(dir.path(), socket);
        std::fs::write(&path, b"not json").unwrap();
        let corrupt = live_verified_holder(dir.path(), socket).unwrap_err();
        assert!(corrupt.contains("corrupt or unreadable"), "{corrupt}");

        std::fs::write(
            &path,
            format!(
                "{{\"pid\":{},\"socket_path\":\"/tmp/other.sock\",\"started_unix_ms\":0}}",
                std::process::id()
            ),
        )
        .unwrap();
        let mismatch = live_verified_holder(dir.path(), socket).unwrap_err();
        assert!(mismatch.contains("names socket"), "{mismatch}");
    }

    #[test]
    fn a_dead_pid_is_a_recovered_stale_lock() {
        let dir = TempDir::new("stale-lock");
        let socket = "/tmp/agent-tree-stale.sock";
        let path = lock_path(dir.path(), socket);
        // PID 1 is alive but is never this plugin's process; use a dead pid instead by
        // asking for a pid that has already been reaped.
        let dead = dead_pid();
        std::fs::write(
            &path,
            format!("{{\"pid\":{dead},\"socket_path\":\"{socket}\",\"started_unix_ms\":0}}"),
        )
        .unwrap();
        assert_eq!(live_verified_holder(dir.path(), socket).unwrap(), None);
        assert!(!path.exists(), "the stale lock must be removed");
    }

    fn dead_pid() -> i32 {
        let mut child = std::process::Command::new("true")
            .spawn()
            .expect("spawn true");
        let pid = child.id() as i32;
        let _ = child.wait();
        // The child was reaped by us, so this pid is gone (until reuse).
        pid
    }
}
