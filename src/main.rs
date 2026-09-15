//! agent-tree: show Pi Subagents and Workers beneath their immediate delegating agent in
//! Herdr's native Agents sidebar.
//!
//! Subcommands are invoked by the plugin manifest:
//!   start       startup hook: ensure exactly one subscriber for this server
//!   apply       explicit re-apply (enable does not run startup hooks)
//!   clear       remove only plugin-owned tokens and a source-matched view
//!   subscriber  internal: the long-lived, event-driven projection process

mod decoration;
mod forest;
mod identity;
mod lifecycle;
mod projection;
mod transport;
mod wire;

use std::process::ExitCode;

fn main() -> ExitCode {
    let command = std::env::args().nth(1).unwrap_or_default();
    let outcome = match command.as_str() {
        "start" => lifecycle::start(),
        "apply" => lifecycle::apply(),
        "clear" => lifecycle::clear(),
        "subscriber" => lifecycle::run_subscriber(),
        other => {
            eprintln!("agent-tree: unknown command {other:?}; expected start, apply, clear or subscriber");
            return ExitCode::from(2);
        }
    };
    match outcome {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("agent-tree: {message}");
            ExitCode::FAILURE
        }
    }
}
