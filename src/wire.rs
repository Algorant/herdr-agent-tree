//! Socket client for the injected Herdr server socket.
//!
//! Newline-delimited JSON over a Unix domain socket, matching the public socket API.

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

/// Crate-wide fallible result. Messages are user-facing and always name the operation.
pub type R<T> = Result<T, String>;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

/// One decoded line from the server.
pub enum Incoming {
    Message(Value),
    /// No complete line arrived before the read timeout.
    Timeout,
    /// The server closed the connection.
    Closed,
}

/// Sends one request on its own connection.
///
/// Herdr serves exactly one request per connection and closes it afterwards, so every
/// request opens a fresh connection; only the event subscription keeps a connection open.
pub fn request(socket: &str, method: &str, params: Value) -> R<Value> {
    let mut client = Client::connect(socket)?;
    client.request(method, params)
}

pub struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next_id: u64,
    /// Timeout used while streaming events; requests temporarily use REQUEST_TIMEOUT.
    stream_timeout: Option<Duration>,
}

impl Client {
    pub fn connect(socket: &str) -> R<Client> {
        let stream = UnixStream::connect(socket)
            .map_err(|e| format!("cannot connect to Herdr socket {socket}: {e}"))?;
        stream
            .set_read_timeout(Some(REQUEST_TIMEOUT))
            .map_err(|e| format!("cannot set read timeout on {socket}: {e}"))?;
        let writer = stream
            .try_clone()
            .map_err(|e| format!("cannot clone Herdr socket handle: {e}"))?;
        Ok(Client {
            reader: BufReader::new(stream),
            writer,
            next_id: 0,
            stream_timeout: None,
        })
    }

    /// Shorter read timeout used while streaming events so signals are noticed promptly.
    pub fn set_stream_timeout(&mut self, timeout: Duration) -> R<()> {
        self.reader
            .get_ref()
            .set_read_timeout(Some(timeout))
            .map_err(|e| format!("cannot set stream timeout: {e}"))?;
        self.stream_timeout = Some(timeout);
        Ok(())
    }

    /// Sends one request and returns its `result`, mapping `error` to a message.
    pub fn request(&mut self, method: &str, params: Value) -> R<Value> {
        self.next_id += 1;
        let id = format!("agent-tree:{}", self.next_id);
        let line = json!({ "id": id, "method": method, "params": params }).to_string();
        self.writer
            .write_all(line.as_bytes())
            .and_then(|()| self.writer.write_all(b"\n"))
            .and_then(|()| self.writer.flush())
            .map_err(|e| format!("cannot send {method}: {e}"))?;

        let message = {
            let _ = self.reader.get_ref().set_read_timeout(Some(REQUEST_TIMEOUT));
            let outcome = self.read();
            if let Some(timeout) = self.stream_timeout {
                let _ = self.reader.get_ref().set_read_timeout(Some(timeout));
            }
            match outcome? {
                Incoming::Message(value) => value,
                Incoming::Timeout => {
                    return Err(format!("{method}: timed out waiting for a response"))
                }
                Incoming::Closed => {
                    return Err(format!("{method}: Herdr closed the connection"))
                }
            }
        };
        if let Some(error) = message.get("error") {
            let code = error
                .get("code")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let text = error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("no message");
            return Err(format!("{method} failed: {code}: {text}"));
        }
        Ok(message.get("result").cloned().unwrap_or(Value::Null))
    }

    /// Subscribes first and waits for the acknowledgement before any snapshot is taken.
    pub fn subscribe(&mut self, event_types: &[&str]) -> R<()> {
        let subscriptions: Vec<Value> = event_types
            .iter()
            .map(|name| json!({ "type": name }))
            .collect();
        let result = self.request("events.subscribe", json!({ "subscriptions": subscriptions }))?;
        match result.get("type").and_then(Value::as_str) {
            Some("subscription_started") => Ok(()),
            other => Err(format!(
                "events.subscribe returned an unexpected acknowledgement: {other:?}"
            )),
        }
    }

    pub fn read(&mut self) -> R<Incoming> {
        let mut line = String::new();
        match self.reader.read_line(&mut line) {
            Ok(0) => Ok(Incoming::Closed),
            Ok(_) => {
                let trimmed = line.trim_end();
                if trimmed.is_empty() {
                    return Ok(Incoming::Timeout);
                }
                serde_json::from_str::<Value>(trimmed)
                    .map(Incoming::Message)
                    .map_err(|e| format!("cannot decode a Herdr message: {e}"))
            }
            Err(e)
                if e.kind() == std::io::ErrorKind::WouldBlock
                    || e.kind() == std::io::ErrorKind::TimedOut =>
            {
                Ok(Incoming::Timeout)
            }
            Err(e) => Err(format!("cannot read from the Herdr socket: {e}")),
        }
    }
}
