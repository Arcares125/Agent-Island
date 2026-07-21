//! Answer transport: lets the island deliver an answer to an agent that is
//! blocked on a question.
//!
//! The agent's `PreToolUse` hook runs `agent-core --ask-hook`, which connects to
//! the island's Unix socket, hands over the question, and blocks. The island
//! renders the card; the user's pick travels back down the same connection; the
//! helper prints the hook verdict carrying the chosen label, and the agent
//! continues.
//!
//! Two properties keep this from becoming a general write channel into the
//! agent, which is the whole reason the app was observe-only until now:
//!
//! 1. The island may only return an **index into the option list the agent
//!    itself authored**. It never supplies text. The label written into the
//!    verdict is read back out of the agent's own payload, so the worst a
//!    compromised island can do is pick a different one of the agent's choices.
//! 2. Every failure path is silent and non-blocking — no socket, no island, no
//!    answer in time, malformed anything — so the agent falls through to its own
//!    terminal prompt exactly as if this feature did not exist.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::io::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Beyond this the payload is not a question, it is an attack or a bug.
const MAX_REQUEST_BYTES: usize = 64 * 1024;
/// How long the helper waits for the user before releasing the agent back to its
/// own terminal prompt. Deliberately shorter than the hook timeout configured in
/// the agent's settings so *we* decide the fallback, not the agent's kill.
const ANSWER_TIMEOUT: Duration = Duration::from_secs(110);
/// A stalled reader must not pin a connection forever.
const SOCKET_IO_TIMEOUT: Duration = Duration::from_secs(5);
/// More simultaneous blocked agents than this is pathological; refuse rather,
/// than let the pending map grow without bound.
const MAX_CONCURRENT_ASKS: usize = 8;

/// `getpeereid` is the macOS way to learn who is on the other end of a Unix
/// socket. Declared by hand because the project takes no third-party crates.
mod ffi {
    use std::os::raw::c_int;

    unsafe extern "C" {
        pub fn getpeereid(fd: c_int, euid: *mut u32, egid: *mut u32) -> c_int;
        pub fn geteuid() -> u32;
    }
}

/// The socket lives under Application Support rather than a temp dir so it is
/// not world-traversable and does not evaporate on reboot cleanup.
pub fn socket_path() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(
        PathBuf::from(home)
            .join("Library")
            .join("Application Support")
            .join("AgentIsland")
            .join("ask.sock"),
    )
}

// ───────────────────────────── helper side ─────────────────────────────

/// `agent-core --ask-hook`, run by the agent as a `PreToolUse` hook.
///
/// Returns the process exit code. Always 0: a hook that fails loudly would
/// interrupt the agent, and the correct behaviour on every failure here is for
/// the agent to carry on and prompt in its own terminal.
pub fn run_hook_helper() -> i32 {
    let Some(payload) = read_bounded_stdin() else {
        return 0;
    };

    // No question we can render means nothing to ask, so stay out of the way.
    let Some(question) = crate::parse_hook_question(&payload) else {
        return 0;
    };
    if question.options.is_empty() {
        return 0;
    }

    let Some(index) = request_answer(&payload, &question) else {
        return 0;
    };
    let Some(option) = question.options.get(index) else {
        return 0;
    };

    // The label is echoed back out of the agent's own payload, never composed
    // here, so this verdict cannot smuggle in text the agent did not write.
    print!("{}", verdict_json(&option.label));
    0
}

/// Connect, hand over the question, block for the pick. `None` for every
/// failure, which the caller turns into "let the terminal handle it".
fn request_answer(payload: &str, question: &crate::PendingQuestion) -> Option<usize> {
    let path = socket_path()?;
    let stream = UnixStream::connect(path).ok()?;
    stream.set_read_timeout(Some(ANSWER_TIMEOUT)).ok()?;
    stream.set_write_timeout(Some(SOCKET_IO_TIMEOUT)).ok()?;

    let mut writer = stream.try_clone().ok()?;
    writer.write_all(ask_request_json(payload, question).as_bytes()).ok()?;
    writer.write_all(b"\n").ok()?;
    writer.flush().ok()?;

    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).ok()?;
    parse_answer_index(&line)
}

/// The request the island renders. `cwd` and `sessionId` are passed through so
/// the card can name the workspace the question came from.
fn ask_request_json(payload: &str, question: &crate::PendingQuestion) -> String {
    let cwd = crate::string_for_key(payload, "cwd").unwrap_or_default();
    let session = crate::string_for_key(payload, "session_id")
        .or_else(|| crate::string_for_key(payload, "sessionId"))
        .unwrap_or_default();
    let provider = if payload.contains("request_user_input") {
        "codex"
    } else {
        "claude"
    };

    format!(
        "{{\"v\":1,\"provider\":\"{}\",\"sessionId\":\"{}\",\"cwd\":\"{}\",\"question\":{}}}",
        provider,
        crate::escape_json(&session),
        crate::escape_json(&cwd),
        crate::question_json(question)
    )
}

/// The verdict handed back to the agent.
///
/// `deny` is the only `PreToolUse` decision whose reason is delivered to the
/// model, so it is the carrier for the answer even though nothing was denied in
/// spirit. The wording matters: left bare, the model reports "a hook blocked
/// this" instead of acting on the choice.
fn verdict_json(label: &str) -> String {
    format!(
        "{{\"hookSpecificOutput\":{{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"The user answered in Agent Island and chose: \\\"{}\\\". Treat this as the answer to the question you just asked and continue. Do not ask again.\"}}}}",
        crate::escape_json(label)
    )
}

fn read_bounded_stdin() -> Option<String> {
    let mut buffer = Vec::new();
    std::io::stdin()
        .take(MAX_REQUEST_BYTES as u64)
        .read_to_end(&mut buffer)
        .ok()?;
    String::from_utf8(buffer).ok()
}

/// `{"answer":{"optionIndex":N}}` → `Some(N)`; `{"answer":null}` → `None`.
fn parse_answer_index(line: &str) -> Option<usize> {
    let answer = crate::object_for_key(line, "answer")?;
    crate::unsigned_for_key(answer, "optionIndex").map(|value| value as usize)
}

// ───────────────────────────── island side ─────────────────────────────

/// Questions currently blocked on a user pick, keyed by request id.
pub struct AskRegistry {
    pending: Mutex<HashMap<String, Sender<Option<usize>>>>,
    counter: AtomicU64,
}

impl AskRegistry {
    fn new() -> Self {
        Self {
            pending: Mutex::new(HashMap::new()),
            counter: AtomicU64::new(0),
        }
    }

    /// Route an answer arriving on stdin to the blocked helper. Unknown ids are
    /// dropped: the helper already timed out, or the id was never ours.
    pub fn resolve(&self, request_id: &str, index: Option<usize>) {
        let sender = self
            .pending
            .lock()
            .ok()
            .and_then(|mut pending| pending.remove(request_id));
        if let Some(sender) = sender {
            let _ = sender.send(index);
        }
    }

    fn next_id(&self) -> String {
        let ordinal = self.counter.fetch_add(1, Ordering::Relaxed);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.subsec_nanos());
        format!("{}-{}-{}", std::process::id(), ordinal, nanos)
    }
}

/// Bind the socket and serve forever on a background thread.
///
/// Returns `None` when the socket cannot be bound — another island already owns
/// it, or the directory is not writable. The sidecar keeps reporting telemetry
/// either way; only answering is lost.
pub fn serve() -> Option<Arc<AskRegistry>> {
    let path = socket_path()?;
    let directory = path.parent()?.to_path_buf();
    std::fs::create_dir_all(&directory).ok()?;
    // Owner-only: nobody else on a shared Mac may enumerate or connect.
    let _ = std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700));

    // A socket left behind by a crashed island would block the bind.
    if path.exists() {
        if UnixStream::connect(&path).is_ok() {
            return None; // A live island already owns it.
        }
        let _ = std::fs::remove_file(&path);
    }

    let listener = UnixListener::bind(&path).ok()?;
    let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));

    let registry = Arc::new(AskRegistry::new());
    let accept_registry = Arc::clone(&registry);
    thread::spawn(move || accept_loop(listener, accept_registry));
    Some(registry)
}

fn accept_loop(listener: UnixListener, registry: Arc<AskRegistry>) {
    for stream in listener.incoming().flatten() {
        let registry = Arc::clone(&registry);
        thread::spawn(move || handle_connection(stream, &registry));
    }
}

fn handle_connection(stream: UnixStream, registry: &AskRegistry) {
    // File permissions already restrict this, but a peer check is what actually
    // proves the caller is us rather than something that inherited the fd.
    if !peer_is_current_user(&stream) {
        return;
    }
    let _ = stream.set_read_timeout(Some(SOCKET_IO_TIMEOUT));
    let _ = stream.set_write_timeout(Some(SOCKET_IO_TIMEOUT));

    let Some(request) = read_request_line(&stream) else {
        return;
    };

    let (sender, receiver) = mpsc::channel();
    let request_id = registry.next_id();
    {
        let Ok(mut pending) = registry.pending.lock() else {
            return;
        };
        if pending.len() >= MAX_CONCURRENT_ASKS {
            return;
        }
        pending.insert(request_id.clone(), sender);
    }

    // Hand the question to the app. Whole lines, so this cannot interleave with
    // the snapshot emitter sharing stdout.
    println!("{}", ask_event_json(&request_id, &request));

    let answer = match receiver.recv_timeout(ANSWER_TIMEOUT) {
        Ok(index) => index,
        Err(RecvTimeoutError::Timeout | RecvTimeoutError::Disconnected) => {
            registry.resolve(&request_id, None);
            None
        }
    };

    // Tell the app to retire the card whatever happened, so a timed-out question
    // never lingers as a phantom prompt.
    println!(
        "{{\"type\":\"askResolved\",\"requestId\":\"{}\"}}",
        crate::escape_json(&request_id)
    );

    let mut stream = stream;
    let _ = stream.write_all(answer_json(answer).as_bytes());
    let _ = stream.write_all(b"\n");
    let _ = stream.flush();
}

/// Splice the request's fields into an `ask` event.
///
/// Exactly one brace comes off each end: trimming every trailing `}` would also
/// eat the nested question object's, producing a line the island cannot decode.
fn ask_event_json(request_id: &str, request: &str) -> String {
    let body = request
        .trim()
        .strip_prefix('{')
        .and_then(|rest| rest.strip_suffix('}'))
        .unwrap_or("");
    if body.is_empty() {
        return format!(
            "{{\"type\":\"ask\",\"requestId\":\"{}\"}}",
            crate::escape_json(request_id)
        );
    }
    format!(
        "{{\"type\":\"ask\",\"requestId\":\"{}\",{}}}",
        crate::escape_json(request_id),
        body
    )
}

fn answer_json(index: Option<usize>) -> String {
    index.map_or_else(
        || String::from("{\"answer\":null}"),
        |index| format!("{{\"answer\":{{\"optionIndex\":{index}}}}}"),
    )
}

fn read_request_line(stream: &UnixStream) -> Option<String> {
    let mut line = String::new();
    let mut reader = BufReader::new(stream.try_clone().ok()?).take(MAX_REQUEST_BYTES as u64);
    reader.read_line(&mut line).ok()?;
    (!line.trim().is_empty()).then_some(line)
}

fn peer_is_current_user(stream: &UnixStream) -> bool {
    let mut uid = 0_u32;
    let mut gid = 0_u32;
    let result = unsafe { ffi::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) };
    result == 0 && uid == unsafe { ffi::geteuid() }
}

/// Parse `{"type":"answer","requestId":"…","optionIndex":N}` off the app's stdin.
/// A missing `optionIndex` means "dismissed" and releases the agent.
pub fn parse_answer_command(line: &str) -> Option<(String, Option<usize>)> {
    if crate::string_for_key(line, "type").as_deref() != Some("answer") {
        return None;
    }
    let request_id = crate::string_for_key(line, "requestId")?;
    let index = crate::unsigned_for_key(line, "optionIndex").map(|value| value as usize);
    Some((request_id, index))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn answer_index_round_trips() {
        assert_eq!(parse_answer_index(&answer_json(Some(2))), Some(2));
        assert_eq!(parse_answer_index(&answer_json(None)), None);
    }

    #[test]
    fn answer_index_rejects_junk() {
        assert_eq!(parse_answer_index("not json"), None);
        assert_eq!(parse_answer_index("{\"answer\":{}}"), None);
    }

    #[test]
    fn verdict_carries_the_label_and_escapes_it() {
        let verdict = verdict_json("Ship \"now\"");
        assert!(verdict.contains("\\\"permissionDecision\\\"") || verdict.contains("permissionDecision"));
        assert!(verdict.contains("Ship \\\"now\\\""), "label must be escaped: {verdict}");
        assert!(
            verdict.contains("Treat this as the answer"),
            "bare reasons read to the model as a blocked tool"
        );
    }

    /// Regression: `trim_end_matches('}')` stripped the nested question's brace
    /// too, so the island received a line that would not parse.
    #[test]
    fn ask_event_keeps_nested_braces_balanced() {
        let request = "{\"v\":1,\"provider\":\"claude\",\"question\":{\"prompt\":\"Pick\",\"options\":[{\"label\":\"A\"}]}}";
        let event = ask_event_json("req-1", request);

        let opens = event.matches('{').count();
        let closes = event.matches('}').count();
        assert_eq!(opens, closes, "unbalanced braces in {event}");
        assert!(event.starts_with("{\"type\":\"ask\",\"requestId\":\"req-1\","));
        assert!(event.ends_with("}"));
        assert!(event.contains("\"prompt\":\"Pick\""));
    }

    #[test]
    fn ask_event_survives_a_malformed_request() {
        let event = ask_event_json("req-2", "not json at all");
        assert_eq!(event, "{\"type\":\"ask\",\"requestId\":\"req-2\"}");
    }

    #[test]
    fn answer_command_parses_pick_and_dismiss() {
        let picked = parse_answer_command("{\"type\":\"answer\",\"requestId\":\"a-1-2\",\"optionIndex\":1}");
        assert_eq!(picked, Some((String::from("a-1-2"), Some(1))));

        let dismissed = parse_answer_command("{\"type\":\"answer\",\"requestId\":\"a-1-2\"}");
        assert_eq!(dismissed, Some((String::from("a-1-2"), None)));
    }

    #[test]
    fn answer_command_ignores_other_traffic() {
        assert_eq!(parse_answer_command("{\"type\":\"snapshot\"}"), None);
        assert_eq!(parse_answer_command("garbage"), None);
    }

    #[test]
    fn registry_routes_only_to_the_matching_request() {
        let registry = AskRegistry::new();
        let (sender, receiver) = mpsc::channel();
        registry
            .pending
            .lock()
            .expect("lock")
            .insert(String::from("req-1"), sender);

        registry.resolve("req-other", Some(3));
        assert!(receiver.try_recv().is_err(), "a stray id must not resolve a request");

        registry.resolve("req-1", Some(3));
        assert_eq!(receiver.try_recv().expect("delivered"), Some(3));
    }

    #[test]
    fn registry_ids_are_unique() {
        let registry = AskRegistry::new();
        assert_ne!(registry.next_id(), registry.next_id());
    }
}
