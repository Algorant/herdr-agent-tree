//! agent-tree: show Pi Subagents and Workers beneath their immediate delegating agent in
//! Herdr's native Agents sidebar.
//!
//! Subcommands are invoked by the plugin manifest:
//!   start       startup hook: ensure exactly one subscriber for this server
//!   apply       explicit re-apply (enable does not run startup hooks)
//!   reload      deploy-grade re-apply: replace the running subscriber with this build
//!   clear       remove only plugin-owned tokens and a source-matched view, and restore the
//!               original ui.agent_panel_sort captured by cycle
//!   cycle       advance grouped -> priority -> tree -> grouped once
//!   subscriber  internal: the long-lived, event-driven projection process

mod config;
mod decoration;
mod forest;
mod identity;
mod lifecycle;
mod pause;
mod projection;
mod transport;
mod wire;

#[cfg(test)]
mod testutil;

use std::process::ExitCode;

fn main() -> ExitCode {
    let command = std::env::args().nth(1).unwrap_or_default();
    let outcome = match command.as_str() {
        "start" => lifecycle::start(),
        "apply" => lifecycle::apply(),
        "reload" => lifecycle::reload(),
        "clear" => lifecycle::clear(),
        "cycle" => lifecycle::cycle(),
        "subscriber" => lifecycle::run_subscriber(),
        other => {
            eprintln!("agent-tree: unknown command {other:?}; expected start, apply, reload, clear, cycle or subscriber");
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
