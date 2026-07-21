use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant, SystemTime};

#[derive(Debug, Clone, PartialEq, Eq)]
struct DetectedAgent {
    provider: &'static str,
    pid: u32,
}

#[derive(Debug, Clone, PartialEq)]
struct UsageTelemetry {
    context_used_tokens: Option<u64>,
    context_window_tokens: Option<u64>,
    session_total_tokens: Option<u64>,
    rate_limit_used_percent: Option<f64>,
    rate_limit_resets_at: Option<u64>,
    rate_limit_window_minutes: Option<u64>,
    source: &'static str,
    exact: bool,
}

struct TelemetryReader {
    provider: Option<&'static str>,
    path: Option<PathBuf>,
    offset: u64,
    pending: Vec<u8>,
    latest: Option<UsageTelemetry>,
    last_modified: Option<SystemTime>,
    activity_log: Vec<String>,
    changed_files: Vec<String>,
    workspace_path: Option<String>,
    model_name: Option<String>,
    reasoning_effort: Option<String>,
    latest_prompt: Option<String>,
    pending_question: Option<PendingQuestion>,
    revision: u64,
}

/// A question the agent is waiting on, surfaced read-only in the island so the
/// user can see the choices without switching to the terminal. Parsed from the
/// transcript; the answer is still delivered in the terminal.
struct PendingQuestion {
    prompt: String,
    header: Option<String>,
    options: Vec<QuestionOption>,
}

struct QuestionOption {
    label: String,
    description: Option<String>,
}

impl TelemetryReader {
    fn new() -> Self {
        Self {
            provider: None,
            path: None,
            offset: 0,
            pending: Vec::new(),
            latest: None,
            last_modified: None,
            activity_log: Vec::new(),
            changed_files: Vec::new(),
            workspace_path: None,
            model_name: None,
            reasoning_effort: None,
            latest_prompt: None,
            pending_question: None,
            revision: 0,
        }
    }

    fn attached(provider: &'static str, path: PathBuf, modified: SystemTime) -> Self {
        let mut reader = Self::new();
        reader.workspace_path = workspace_from_transcript_head(&path);
        reader.provider = Some(provider);
        reader.path = Some(path);
        reader.last_modified = Some(modified);
        reader.revision = 1;
        reader
    }

    fn session_id(&self) -> String {
        self.path
            .as_deref()
            .and_then(Path::file_stem)
            .and_then(|value| value.to_str())
            .unwrap_or("unknown-session")
            .chars()
            .take(160)
            .collect()
    }

    fn provider_name(&self) -> &'static str {
        if self.provider == Some("claude") {
            "Claude"
        } else {
            "Codex"
        }
    }

    fn activity_age(&self) -> Option<Duration> {
        self.last_modified
            .and_then(|modified| SystemTime::now().duration_since(modified).ok())
    }

    fn state(&self) -> &'static str {
        state_for_activity(
            self.activity_log.last().map(String::as_str),
            self.activity_age(),
        )
    }

    fn read_updates(&mut self, provider: &'static str) {
        const MAX_TAIL_BYTES: u64 = 1024 * 1024;

        let Some(path) = self.path.as_ref() else {
            return;
        };
        let Ok(mut file) = File::open(path) else {
            return;
        };
        let Ok(metadata) = file.metadata() else {
            return;
        };
        let length = metadata.len();
        self.last_modified = metadata.modified().ok();

        if length < self.offset {
            self.offset = 0;
            self.pending.clear();
            self.latest = None;
            self.model_name = None;
            self.reasoning_effort = None;
            self.latest_prompt = None;
        }
        if length == self.offset {
            return;
        }

        let mut start = self.offset;
        let mut starts_mid_line = false;
        if self.offset == 0 && length > MAX_TAIL_BYTES {
            start = length - MAX_TAIL_BYTES;
            starts_mid_line = true;
        } else if length.saturating_sub(self.offset) > MAX_TAIL_BYTES {
            start = length - MAX_TAIL_BYTES;
            starts_mid_line = true;
            self.pending.clear();
        }

        if file.seek(SeekFrom::Start(start)).is_err() {
            return;
        }
        let mut bytes = Vec::with_capacity((length - start) as usize);
        if file.read_to_end(&mut bytes).is_err() {
            return;
        }
        self.offset = length;

        if starts_mid_line {
            if let Some(newline) = bytes.iter().position(|byte| *byte == b'\n') {
                bytes.drain(..=newline);
            } else {
                return;
            }
        }

        self.pending.extend(bytes);
        while let Some(newline) = self.pending.iter().position(|byte| *byte == b'\n') {
            let line = self.pending.drain(..=newline).collect::<Vec<_>>();
            let Ok(line) = std::str::from_utf8(&line) else {
                continue;
            };
            let parsed = if provider == "codex" {
                parse_codex_usage(line)
            } else {
                parse_claude_usage(line)
            };
            if let Some(usage) = parsed {
                if self.latest.as_ref() != Some(&usage) {
                    self.latest = Some(usage);
                    self.revision = self.revision.wrapping_add(1);
                }
            }

            if let Some(workspace_path) = workspace_path_from_event(line) {
                if self.workspace_path.as_ref() != Some(&workspace_path) {
                    self.workspace_path = Some(workspace_path);
                    self.revision = self.revision.wrapping_add(1);
                }
            }

            let (model_name, reasoning_effort) = model_metadata_from_event(provider, line);
            if let Some(model_name) = model_name {
                if self.model_name.as_ref() != Some(&model_name) {
                    self.model_name = Some(model_name);
                    self.revision = self.revision.wrapping_add(1);
                }
            }
            if let Some(reasoning_effort) = reasoning_effort {
                if self.reasoning_effort.as_ref() != Some(&reasoning_effort) {
                    self.reasoning_effort = Some(reasoning_effort);
                    self.revision = self.revision.wrapping_add(1);
                }
            }

            if let Some(latest_prompt) = latest_prompt_from_event(provider, line) {
                if self.latest_prompt.as_ref() != Some(&latest_prompt) {
                    self.latest_prompt = Some(latest_prompt.clone());
                    // A new user turn answers or supersedes any pending question.
                    self.pending_question = None;
                    self.push_activity(task_start_activity(Some(&latest_prompt)));
                    self.revision = self.revision.wrapping_add(1);
                }
            }

            if let Some(question) = parse_pending_question(provider, line) {
                self.pending_question = Some(question);
                self.revision = self.revision.wrapping_add(1);
            }

            let (activity, changed_files) =
                parse_activity_event(provider, line, self.latest_prompt.as_deref());
            for item in activity {
                self.push_activity(item);
            }
            for file in changed_files {
                self.push_changed_file(file);
            }
        }

        // A malformed writer cannot make the helper retain an unbounded partial line.
        if self.pending.len() > 256 * 1024 {
            self.pending.clear();
        }
    }

    fn push_activity(&mut self, item: String) {
        const MAX_ACTIVITY_ITEMS: usize = 16;
        if item == "Started a new task" || item.starts_with("Started · ") {
            self.activity_log.clear();
            self.changed_files.clear();
            self.revision = self.revision.wrapping_add(1);
        }
        if self.activity_log.last() == Some(&item) {
            return;
        }
        if self.activity_log.len() == MAX_ACTIVITY_ITEMS {
            self.activity_log.remove(0);
        }
        self.activity_log.push(item);
        self.revision = self.revision.wrapping_add(1);
    }

    fn push_changed_file(&mut self, file: String) {
        const MAX_CHANGED_FILES: usize = 16;
        if self.changed_files.contains(&file) {
            return;
        }
        if self.changed_files.len() == MAX_CHANGED_FILES {
            self.changed_files.remove(0);
        }
        self.changed_files.push(file);
        self.revision = self.revision.wrapping_add(1);
    }
}

fn workspace_from_transcript_head(path: &Path) -> Option<String> {
    const MAX_HEAD_BYTES: u64 = 128 * 1024;
    let file = File::open(path).ok()?;
    let mut bytes = Vec::with_capacity(MAX_HEAD_BYTES as usize);
    file.take(MAX_HEAD_BYTES).read_to_end(&mut bytes).ok()?;
    let text = std::str::from_utf8(&bytes).ok()?;
    text.lines().find_map(workspace_path_from_event)
}

#[derive(Debug)]
struct SessionCandidate {
    provider: &'static str,
    modified: SystemTime,
    path: PathBuf,
}

struct SessionTracker {
    readers: Vec<TelemetryReader>,
    last_discovery: Option<Instant>,
    revision: u64,
}

impl SessionTracker {
    fn new() -> Self {
        Self {
            readers: Vec::new(),
            last_discovery: None,
            revision: 0,
        }
    }

    fn refresh(&mut self, detected_agents: &[DetectedAgent]) {
        let should_discover = self.readers.is_empty()
            || self
                .last_discovery
                .is_none_or(|last| last.elapsed() >= Duration::from_secs(15));
        if should_discover {
            self.rediscover(detected_agents);
        }

        for reader in &mut self.readers {
            let Some(provider) = reader.provider else {
                continue;
            };
            reader.read_updates(provider);
        }

        self.apply_claude_status_to_newest_session();
        self.readers.sort_by(session_sort_order);
    }

    fn rediscover(&mut self, detected_agents: &[DetectedAgent]) {
        const SESSION_RETENTION: Duration = Duration::from_secs(30 * 60);
        const MAX_TRACKED_SESSIONS: usize = 8;

        self.last_discovery = Some(Instant::now());
        let codex_processes = detected_agents
            .iter()
            .filter(|agent| agent.provider == "codex")
            .count();
        let claude_processes = detected_agents
            .iter()
            .filter(|agent| agent.provider == "claude")
            .count();

        let mut candidates = Vec::new();
        collect_provider_candidates("codex", &mut candidates);
        collect_provider_candidates("claude", &mut candidates);
        candidates.sort_by(|left, right| right.modified.cmp(&left.modified));

        let mut provider_rank = HashMap::new();
        candidates.retain(|candidate| {
            let rank = provider_rank.entry(candidate.provider).or_insert(0_usize);
            let provider_processes = if candidate.provider == "codex" {
                codex_processes
            } else {
                claude_processes
            };
            let is_process_candidate = *rank < provider_processes;
            *rank += 1;
            let is_recent = SystemTime::now()
                .duration_since(candidate.modified)
                .is_ok_and(|age| age <= SESSION_RETENTION);
            is_process_candidate || is_recent
        });
        candidates = select_bounded_candidates(
            candidates,
            (codex_processes, claude_processes),
            MAX_TRACKED_SESSIONS,
        );

        let mut existing = std::mem::take(&mut self.readers)
            .into_iter()
            .filter_map(|reader| reader.path.clone().map(|path| (path, reader)))
            .collect::<HashMap<_, _>>();
        let mut previous_paths = existing.keys().cloned().collect::<Vec<_>>();
        previous_paths.sort();
        self.readers = candidates
            .into_iter()
            .map(|candidate| {
                existing.remove(&candidate.path).unwrap_or_else(|| {
                    TelemetryReader::attached(
                        candidate.provider,
                        candidate.path,
                        candidate.modified,
                    )
                })
            })
            .collect();

        let mut current_paths = self
            .readers
            .iter()
            .filter_map(|reader| reader.path.clone())
            .collect::<Vec<_>>();
        current_paths.sort();
        if current_paths != previous_paths {
            self.revision = self.revision.wrapping_add(1);
        }
    }

    fn apply_claude_status_to_newest_session(&mut self) {
        let Some((modified, usage)) = read_claude_cache() else {
            return;
        };
        let is_fresh = SystemTime::now()
            .duration_since(modified)
            .is_ok_and(|age| age <= Duration::from_secs(10 * 60));
        if !is_fresh {
            return;
        }

        let Some(reader) = self
            .readers
            .iter_mut()
            .filter(|reader| reader.provider == Some("claude"))
            .max_by_key(|reader| reader.last_modified)
        else {
            return;
        };
        if reader.latest.as_ref() != Some(&usage) {
            reader.latest = Some(usage);
            reader.revision = reader.revision.wrapping_add(1);
        }
    }

    fn selected(&self) -> Option<&TelemetryReader> {
        self.readers.first()
    }

    fn session_counts(&self) -> (usize, usize) {
        let codex = self
            .readers
            .iter()
            .filter(|reader| reader.provider == Some("codex"))
            .count();
        let claude = self.readers.len().saturating_sub(codex);
        (codex, claude)
    }

    fn combined_revision(&self) -> u64 {
        self.readers.iter().fold(self.revision, |revision, reader| {
            revision.wrapping_mul(31).wrapping_add(reader.revision)
        })
    }
}

fn select_bounded_candidates(
    candidates: Vec<SessionCandidate>,
    process_counts: (usize, usize),
    maximum: usize,
) -> Vec<SessionCandidate> {
    const MAX_RESERVED_PER_PROVIDER: usize = 3;

    if candidates.len() <= maximum {
        return candidates;
    }

    let mut keep = vec![false; candidates.len()];
    let mut kept = 0_usize;
    for (provider, process_count) in [("codex", process_counts.0), ("claude", process_counts.1)] {
        let reservation = process_count
            .min(MAX_RESERVED_PER_PROVIDER)
            .min(maximum.saturating_sub(kept));
        for (index, _) in candidates
            .iter()
            .enumerate()
            .filter(|(_, candidate)| candidate.provider == provider)
            .take(reservation)
        {
            keep[index] = true;
            kept += 1;
        }
    }

    for selected in &mut keep {
        if kept == maximum {
            break;
        }
        if !*selected {
            *selected = true;
            kept += 1;
        }
    }

    candidates
        .into_iter()
        .zip(keep)
        .filter_map(|(candidate, keep)| keep.then_some(candidate))
        .collect()
}

fn session_sort_order(left: &TelemetryReader, right: &TelemetryReader) -> std::cmp::Ordering {
    session_state_priority(right.state())
        .cmp(&session_state_priority(left.state()))
        .then_with(|| right.last_modified.cmp(&left.last_modified))
}

fn session_state_priority(state: &str) -> u8 {
    match state {
        "question" => 4,
        "thinking" => 3,
        "complete" => 2,
        _ => 1,
    }
}

fn main() {
    match std::env::args().nth(1).as_deref() {
        Some("--ingest-claude-status") => {
            ingest_claude_status();
            return;
        }
        Some("--list-detected") => {
            for agent in scan_processes() {
                println!("{} {}", agent.provider, agent.pid);
            }
            return;
        }
        _ => {}
    }

    let mut active_session_id: Option<String> = None;
    let mut active_since = Instant::now();
    let mut last_emitted = Instant::now() - Duration::from_secs(30);
    let mut last_session_revision = 0_u64;
    let mut last_process_counts = (0_usize, 0_usize);
    let mut session_tracker = SessionTracker::new();

    loop {
        let detected_agents = scan_processes();
        let codex_process_count = detected_agents
            .iter()
            .filter(|agent| agent.provider == "codex")
            .count();
        let claude_process_count = detected_agents
            .iter()
            .filter(|agent| agent.provider == "claude")
            .count();
        let process_counts = (codex_process_count, claude_process_count);

        session_tracker.refresh(&detected_agents);
        let selected_reader = session_tracker.selected();
        let selected_id = selected_reader.map(TelemetryReader::session_id);
        let selected_agent = selected_reader
            .and_then(|reader| {
                let provider = reader.provider?;
                detected_agents
                    .iter()
                    .filter(|agent| agent.provider == provider)
                    .max_by_key(|agent| agent.pid)
                    .cloned()
                    .or(Some(DetectedAgent { provider, pid: 0 }))
            })
            .or_else(|| {
                detected_agents
                    .iter()
                    .max_by_key(|agent| agent.pid)
                    .cloned()
            });
        let session_counts = if session_tracker.readers.is_empty() {
            process_counts
        } else {
            session_tracker.session_counts()
        };
        let session_revision = session_tracker.combined_revision();

        if selected_id != active_session_id {
            active_session_id = selected_id;
            active_since = Instant::now();
            last_session_revision = session_revision;
            last_process_counts = process_counts;
            emit_snapshot(
                selected_agent.as_ref(),
                0,
                selected_reader.and_then(|reader| reader.latest.as_ref()),
                selected_reader,
                session_counts,
                &session_tracker.readers,
                process_counts,
            );
            last_emitted = Instant::now();
        } else if session_revision != last_session_revision || process_counts != last_process_counts
        {
            last_session_revision = session_revision;
            last_process_counts = process_counts;
            emit_snapshot(
                selected_agent.as_ref(),
                active_since.elapsed().as_secs(),
                selected_reader.and_then(|reader| reader.latest.as_ref()),
                selected_reader,
                session_counts,
                &session_tracker.readers,
                process_counts,
            );
            last_emitted = Instant::now();
        } else if last_emitted.elapsed() >= Duration::from_secs(15) {
            emit_snapshot(
                selected_agent.as_ref(),
                active_since.elapsed().as_secs(),
                selected_reader.and_then(|reader| reader.latest.as_ref()),
                selected_reader,
                session_counts,
                &session_tracker.readers,
                process_counts,
            );
            last_emitted = Instant::now();
        }

        let scan_interval = if selected_agent.is_some() {
            Duration::from_secs(5)
        } else {
            Duration::from_secs(8)
        };
        thread::sleep(scan_interval);
    }
}

fn scan_processes() -> Vec<DetectedAgent> {
    let Ok(output) = Command::new("/bin/ps")
        .args(["-axo", "pid=,command="])
        .output()
    else {
        return Vec::new();
    };

    let process_list = String::from_utf8_lossy(&output.stdout);
    let mut agents = process_list
        .lines()
        .filter_map(parse_process_line)
        .collect::<Vec<_>>();
    agents.sort_by_key(|agent| agent.pid);
    agents
}

fn parse_process_line(line: &str) -> Option<DetectedAgent> {
    let trimmed = line.trim();
    let split_at = trimmed.find(char::is_whitespace)?;
    let pid = trimmed[..split_at].parse::<u32>().ok()?;
    if pid == std::process::id() {
        return None;
    }

    let command = trimmed[split_at..].trim();
    // `ps` does not quote executable paths containing spaces. Without this
    // guard, paths such as ".../Frameworks/Codex Framework.framework/..."
    // look like an executable named Codex after whitespace splitting.
    if command.contains("/Contents/Frameworks/") || command.contains(".app/Contents/MacOS/") {
        return None;
    }
    let mut command_parts = command.split_whitespace();
    let executable = command_parts.next()?;
    let executable_name = executable.rsplit('/').next()?.to_ascii_lowercase();
    let first_argument = command_parts.next();

    let provider = match executable_name.as_str() {
        "codex" => {
            // A Codex session may own sandbox workers. They are implementation
            // details of one session and must never inflate the session count.
            if first_argument == Some("sandbox") {
                return None;
            }
            "codex"
        }
        "claude" => {
            // Claude keeps daemons and spare PTY hosts around. Count interactive
            // processes, not those background helpers.
            if matches!(first_argument, Some("daemon" | "bg-pty-host" | "bg-spare"))
                || command.contains(" --bg-pty-host ")
                || command.contains(" --bg-spare ")
            {
                return None;
            }
            "claude"
        }
        _ => return None,
    };

    Some(DetectedAgent { provider, pid })
}

fn emit_snapshot(
    agent: Option<&DetectedAgent>,
    elapsed_seconds: u64,
    usage: Option<&UsageTelemetry>,
    reader: Option<&TelemetryReader>,
    session_counts: (usize, usize),
    sessions: &[TelemetryReader],
    process_counts: (usize, usize),
) {
    let usage_json = usage_fields_json(usage);
    let activity_json = activity_fields_json(reader, session_counts);
    let sessions_json = session_array_json(sessions);
    let process_count = process_counts.0 + process_counts.1;
    let json = match agent {
        Some(agent) => {
            let name = if agent.provider == "codex" {
                "Codex"
            } else {
                "Claude"
            };
            let current_activity = reader
                .and_then(|reader| reader.activity_log.last())
                .cloned();
            let activity_age = reader
                .and_then(|reader| reader.last_modified)
                .and_then(|modified| SystemTime::now().duration_since(modified).ok());
            let state = state_for_activity(current_activity.as_deref(), activity_age);
            let workspace = reader
                .and_then(|reader| reader.workspace_path.as_deref())
                .map(display_file_name);
            let task = task_for_snapshot(
                name,
                state,
                current_activity.as_deref(),
                workspace.as_deref(),
            );
            let detail = if state == "idle" {
                let active_count = session_counts.0 + session_counts.1;
                workspace.as_deref().map_or_else(
                    || format!("{active_count} sessions open · waiting for activity"),
                    |workspace| format!("Waiting in {workspace} · {active_count} sessions open"),
                )
            } else {
                workspace
                    .as_deref()
                    .map(|workspace| format!("Working in {workspace}"))
                    .unwrap_or_else(|| format!("Tracking {name} process {}", agent.pid))
            };
            let emitted_elapsed = if state == "idle" { 0 } else { elapsed_seconds };
            let pid_json = if agent.pid == 0 {
                String::from("null")
            } else {
                agent.pid.to_string()
            };
            let selected_session_id = reader
                .map(TelemetryReader::session_id)
                .map(|id| format!("\"{}\"", escape_json(&id)))
                .unwrap_or_else(|| String::from("null"));
            format!(
                "{{\"type\":\"snapshot\",\"provider\":\"{}\",\"state\":\"{}\",\"task\":\"{}\",\"detail\":\"{}\",\"elapsedSeconds\":{},\"pid\":{},\"selectedSessionId\":{},\"detectedProcessCount\":{}{}{},\"sessions\":{}}}",
                agent.provider,
                state,
                escape_json(&task),
                escape_json(&detail),
                emitted_elapsed,
                pid_json,
                selected_session_id,
                process_count,
                usage_json,
                activity_json,
                sessions_json
            )
        }
        None => format!(
            "{{\"type\":\"snapshot\",\"provider\":\"codex\",\"state\":\"idle\",\"task\":\"No active agent sessions\",\"detail\":\"Start Codex or Claude and the session will appear here.\",\"elapsedSeconds\":0,\"pid\":null,\"selectedSessionId\":null,\"detectedProcessCount\":{process_count},\"contextUsedTokens\":null,\"contextWindowTokens\":null,\"sessionTotalTokens\":null,\"rateLimitUsedPercent\":null,\"rateLimitResetsAt\":null,\"rateLimitWindowMinutes\":null,\"usageSource\":null,\"usageExact\":false{activity_json},\"sessions\":{sessions_json}}}"
        ),
    };

    println!("{json}");
}

fn session_array_json(sessions: &[TelemetryReader]) -> String {
    let values = sessions
        .iter()
        .map(session_json)
        .collect::<Vec<_>>()
        .join(",");
    format!("[{values}]")
}

fn session_json(reader: &TelemetryReader) -> String {
    let provider = reader.provider.unwrap_or("codex");
    let state = reader.state();
    let workspace = reader.workspace_path.as_deref().map(display_file_name);
    let current_activity = reader.activity_log.last().map(String::as_str);
    let task = task_for_snapshot(
        reader.provider_name(),
        state,
        current_activity,
        workspace.as_deref(),
    );
    let detail = if state == "question" {
        workspace.as_deref().map_or_else(
            || String::from("Open the agent session to answer"),
            |workspace| format!("Waiting for your answer in {workspace}"),
        )
    } else if state == "idle" {
        workspace.as_deref().map_or_else(
            || String::from("Waiting for new activity"),
            |workspace| format!("Waiting in {workspace}"),
        )
    } else {
        workspace.as_deref().map_or_else(
            || String::from("Tracking local transcript activity"),
            |workspace| format!("Working in {workspace}"),
        )
    };
    let updated_seconds_ago = reader.activity_age().map_or(0, |age| age.as_secs());
    let usage_json = usage_fields_json(reader.latest.as_ref());
    let activity_json = session_activity_fields_json(reader);
    let model_json = model_fields_json(Some(reader));

    format!(
        "{{\"id\":\"{}\",\"provider\":\"{}\",\"state\":\"{}\",\"task\":\"{}\",\"detail\":\"{}\",\"updatedSecondsAgo\":{}{}{}{}}}",
        escape_json(&reader.session_id()),
        provider,
        state,
        escape_json(&task),
        escape_json(&detail),
        updated_seconds_ago,
        usage_json,
        activity_json,
        model_json
    )
}

fn session_activity_fields_json(reader: &TelemetryReader) -> String {
    let mut activity = reader.activity_log.clone();
    if activity.last().is_some_and(|item| item == "Completed task") {
        if let Some(workspace) = reader.workspace_path.as_deref().map(display_file_name) {
            if let Some(last) = activity.last_mut() {
                *last = format!("Completed · {workspace}");
            }
        }
    }
    let workspace_path = reader
        .workspace_path
        .as_deref()
        .map(|path| format!("\"{}\"", escape_json(path)))
        .unwrap_or_else(|| String::from("null"));

    format!(
        ",\"activityLog\":{},\"changedFiles\":{},\"workspacePath\":{}",
        string_array_json(&activity),
        string_array_json(&reader.changed_files),
        workspace_path
    )
}

fn state_for_activity(activity: Option<&str>, age: Option<Duration>) -> &'static str {
    const COMPLETE_GRACE: Duration = Duration::from_secs(12);
    const STALE_ACTIVITY: Duration = Duration::from_secs(60);

    match (activity, age) {
        (Some("Waiting for your answer"), _) => "question",
        (Some("Completed task"), Some(age)) if age <= COMPLETE_GRACE => "complete",
        (Some("Completed task"), _) => "idle",
        (_, Some(age)) if age > STALE_ACTIVITY => "idle",
        (Some(_), Some(_)) => "thinking",
        _ => "idle",
    }
}

fn task_for_snapshot(
    provider_name: &str,
    state: &str,
    activity: Option<&str>,
    workspace: Option<&str>,
) -> String {
    if state == "question" {
        return workspace.map_or_else(
            || format!("{provider_name} needs your input"),
            |workspace| format!("Input needed · {workspace}"),
        );
    }
    if activity == Some("Completed task") {
        return workspace.map_or_else(
            || String::from("Completed task"),
            |workspace| format!("Completed · {workspace}"),
        );
    }
    if state == "idle" {
        return format!("{provider_name} is idle");
    }
    activity
        .map(String::from)
        .unwrap_or_else(|| format!("{provider_name} is working"))
}

fn activity_fields_json(
    reader: Option<&TelemetryReader>,
    session_counts: (usize, usize),
) -> String {
    let mut activity = reader.map_or_else(Vec::new, |reader| reader.activity_log.clone());
    let changed_files = reader.map_or_else(Vec::new, |reader| reader.changed_files.clone());
    if activity.last().is_some_and(|item| item == "Completed task") {
        if let Some(workspace) = reader
            .and_then(|reader| reader.workspace_path.as_deref())
            .map(display_file_name)
        {
            if let Some(last) = activity.last_mut() {
                *last = format!("Completed · {workspace}");
            }
        }
    }
    let active_count = session_counts.0 + session_counts.1;
    let workspace_path = reader
        .and_then(|reader| reader.workspace_path.as_deref())
        .map(|path| format!("\"{}\"", escape_json(path)))
        .unwrap_or_else(|| String::from("null"));

    let model_json = model_fields_json(reader);

    format!(
        ",\"activityLog\":{},\"changedFiles\":{},\"activeSessionCount\":{},\"codexSessionCount\":{},\"claudeSessionCount\":{},\"workspacePath\":{}{}",
        string_array_json(&activity),
        string_array_json(&changed_files),
        active_count,
        session_counts.0,
        session_counts.1,
        workspace_path,
        model_json
    )
}

fn model_fields_json(reader: Option<&TelemetryReader>) -> String {
    let model_name = reader
        .and_then(|reader| reader.model_name.as_deref())
        .map(|value| format!("\"{}\"", escape_json(value)))
        .unwrap_or_else(|| String::from("null"));
    let reasoning_effort = reader
        .and_then(|reader| reader.reasoning_effort.as_deref())
        .map(|value| format!("\"{}\"", escape_json(value)))
        .unwrap_or_else(|| String::from("null"));
    let latest_prompt = reader
        .and_then(|reader| reader.latest_prompt.as_deref())
        .map(|value| format!("\"{}\"", escape_json(value)))
        .unwrap_or_else(|| String::from("null"));
    let pending_question = reader.map_or_else(|| String::from("null"), pending_question_json);
    format!(
        ",\"modelName\":{},\"reasoningEffort\":{},\"latestPrompt\":{},\"pendingQuestion\":{}",
        model_name, reasoning_effort, latest_prompt, pending_question
    )
}

fn string_array_json(values: &[String]) -> String {
    let values = values
        .iter()
        .map(|value| format!("\"{}\"", escape_json(value)))
        .collect::<Vec<_>>()
        .join(",");
    format!("[{values}]")
}

fn escape_json(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '\"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            character if character.is_control() => escaped.push(' '),
            character => escaped.push(character),
        }
    }
    escaped
}

fn usage_fields_json(usage: Option<&UsageTelemetry>) -> String {
    let Some(usage) = usage else {
        return String::from(
            ",\"contextUsedTokens\":null,\"contextWindowTokens\":null,\"sessionTotalTokens\":null,\"rateLimitUsedPercent\":null,\"rateLimitResetsAt\":null,\"rateLimitWindowMinutes\":null,\"usageSource\":null,\"usageExact\":false",
        );
    };

    format!(
        ",\"contextUsedTokens\":{},\"contextWindowTokens\":{},\"sessionTotalTokens\":{},\"rateLimitUsedPercent\":{},\"rateLimitResetsAt\":{},\"rateLimitWindowMinutes\":{},\"usageSource\":\"{}\",\"usageExact\":{}",
        option_u64_json(usage.context_used_tokens),
        option_u64_json(usage.context_window_tokens),
        option_u64_json(usage.session_total_tokens),
        option_f64_json(usage.rate_limit_used_percent),
        option_u64_json(usage.rate_limit_resets_at),
        option_u64_json(usage.rate_limit_window_minutes),
        usage.source,
        usage.exact
    )
}

fn option_u64_json(value: Option<u64>) -> String {
    value.map_or_else(|| String::from("null"), |number| number.to_string())
}

fn option_f64_json(value: Option<f64>) -> String {
    value.map_or_else(|| String::from("null"), |number| number.to_string())
}

fn ingest_claude_status() {
    let mut input = String::new();
    let mut limited_stdin = std::io::stdin().take(256 * 1024);
    if limited_stdin.read_to_string(&mut input).is_err() {
        return;
    }
    let Some(usage) = parse_claude_status(&input) else {
        return;
    };
    let _ = write_claude_cache(&usage);

    if let (Some(used), Some(window)) = (usage.context_used_tokens, usage.context_window_tokens) {
        let percent = (used as f64 / window.max(1) as f64 * 100.0).round() as u64;
        println!("Agent Island · {percent}% context");
    } else {
        println!("Agent Island · context pending");
    }
}

fn claude_cache_path() -> Option<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    Some(
        home.join("Library")
            .join("Caches")
            .join("com.agentisland.AgentIsland")
            .join("claude-usage.json"),
    )
}

fn write_claude_cache(usage: &UsageTelemetry) -> std::io::Result<()> {
    let Some(path) = claude_cache_path() else {
        return Ok(());
    };
    let Some(directory) = path.parent() else {
        return Ok(());
    };
    fs::create_dir_all(directory)?;

    let payload = format!(
        "{{\"contextUsedTokens\":{},\"contextWindowTokens\":{},\"sessionTotalTokens\":{},\"rateLimitUsedPercent\":{},\"rateLimitResetsAt\":{},\"rateLimitWindowMinutes\":{}}}",
        option_u64_json(usage.context_used_tokens),
        option_u64_json(usage.context_window_tokens),
        option_u64_json(usage.session_total_tokens),
        option_f64_json(usage.rate_limit_used_percent),
        option_u64_json(usage.rate_limit_resets_at),
        option_u64_json(usage.rate_limit_window_minutes)
    );
    let temporary = directory.join(format!("claude-usage-{}.tmp", std::process::id()));
    fs::write(&temporary, payload)?;
    fs::rename(temporary, path)
}

fn read_claude_cache() -> Option<(SystemTime, UsageTelemetry)> {
    let path = claude_cache_path()?;
    let modified = fs::metadata(&path).ok()?.modified().ok()?;
    let payload = fs::read_to_string(path).ok()?;
    Some((
        modified,
        UsageTelemetry {
            context_used_tokens: unsigned_for_key(&payload, "contextUsedTokens"),
            context_window_tokens: unsigned_for_key(&payload, "contextWindowTokens"),
            session_total_tokens: unsigned_for_key(&payload, "sessionTotalTokens"),
            rate_limit_used_percent: number_for_key(&payload, "rateLimitUsedPercent"),
            rate_limit_resets_at: unsigned_for_key(&payload, "rateLimitResetsAt"),
            rate_limit_window_minutes: unsigned_for_key(&payload, "rateLimitWindowMinutes"),
            source: "claude-status-line",
            exact: true,
        },
    ))
}

fn telemetry_roots_for_home(provider: &str, home: &Path) -> Vec<PathBuf> {
    if provider == "codex" {
        let codex_home = std::env::var_os("CODEX_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".codex"));
        vec![codex_home.join("sessions")]
    } else {
        // `claude2` is a separate local Claude profile whose shell launcher sets
        // CLAUDE_CONFIG_DIR to ~/.claude2. The long-running executable is still
        // named `claude`, so both transcript roots must be discovered explicitly.
        vec![
            home.join(".claude").join("projects"),
            home.join(".claude2").join("projects"),
        ]
    }
}

fn collect_provider_candidates(provider: &'static str, candidates: &mut Vec<SessionCandidate>) {
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return;
    };
    let max_depth = if provider == "codex" { 5 } else { 4 };
    for root in telemetry_roots_for_home(provider, &home) {
        collect_jsonl_candidates(&root, 0, max_depth, provider, candidates);
    }
}

fn collect_jsonl_candidates(
    directory: &Path,
    depth: usize,
    max_depth: usize,
    provider: &'static str,
    candidates: &mut Vec<SessionCandidate>,
) {
    if depth > max_depth {
        return;
    }
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path
            .components()
            .any(|part| part.as_os_str() == "subagents")
        {
            continue;
        }
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_dir() {
            collect_jsonl_candidates(&path, depth + 1, max_depth, provider, candidates);
            continue;
        }
        if !file_type.is_file()
            || path.extension().and_then(|value| value.to_str()) != Some("jsonl")
        {
            continue;
        }
        let Ok(modified) = entry.metadata().and_then(|metadata| metadata.modified()) else {
            continue;
        };
        candidates.push(SessionCandidate {
            provider,
            modified,
            path,
        });
    }
}

fn parse_activity_event(
    provider: &str,
    line: &str,
    latest_prompt: Option<&str>,
) -> (Vec<String>, Vec<String>) {
    if provider == "codex" {
        parse_codex_activity(line, latest_prompt)
    } else {
        parse_claude_activity(line, latest_prompt)
    }
}

fn workspace_path_from_event(line: &str) -> Option<String> {
    let workspace = string_for_key(line, "cwd")?;
    let path = Path::new(&workspace);
    if !path.is_absolute() || workspace.len() > 1_024 {
        return None;
    }
    Some(workspace)
}

fn model_metadata_from_event(provider: &str, line: &str) -> (Option<String>, Option<String>) {
    let event_type = top_level_string_for_key(line, "type");
    if provider == "codex" {
        if event_type.as_deref() != Some("turn_context") {
            return (None, None);
        }
        let Some(payload) = object_for_key(line, "payload") else {
            return (None, None);
        };
        let model_name = string_for_key(payload, "model").and_then(sanitize_model_identifier);
        let reasoning_effort = string_for_key(payload, "reasoning_effort")
            .or_else(|| string_for_key(payload, "effort"))
            .and_then(sanitize_reasoning_effort);
        return (model_name, reasoning_effort);
    }

    if event_type.as_deref() != Some("assistant") {
        return (None, None);
    }
    let Some(message) = object_for_key(line, "message") else {
        return (None, None);
    };
    (
        string_for_key(message, "model").and_then(sanitize_model_identifier),
        top_level_string_for_key(line, "effort")
            .or_else(|| top_level_string_for_key(line, "reasoning_effort"))
            .and_then(sanitize_reasoning_effort),
    )
}

fn latest_prompt_from_event(provider: &str, line: &str) -> Option<String> {
    let event_type = string_for_key(line, "type")?;

    let parts = if provider == "codex" {
        if event_type != "response_item" {
            return None;
        }
        let payload = object_for_key(line, "payload")?;
        if string_for_key(payload, "type").as_deref() != Some("message")
            || string_for_key(payload, "role").as_deref() != Some("user")
        {
            return None;
        }
        text_parts_for_content(payload, &["input_text"])
    } else {
        if event_type != "user" || boolean_for_key(line, "isMeta") == Some(true) {
            return None;
        }
        let message = object_for_key(line, "message")?;
        if string_for_key(message, "role").as_deref() != Some("user") {
            return None;
        }
        text_parts_for_content(message, &["text"])
    };

    normalize_latest_prompt(parts)
}

fn text_parts_for_content(container: &str, accepted_types: &[&str]) -> Vec<String> {
    if let Some(content) = string_for_key(container, "content") {
        return vec![content];
    }

    let Some(content) = array_for_key(container, "content") else {
        return Vec::new();
    };
    object_values(content)
        .into_iter()
        .filter(|item| {
            string_for_key(item, "type").is_some_and(|kind| accepted_types.contains(&kind.as_str()))
        })
        .filter_map(|item| string_for_key(item, "text"))
        .collect()
}

fn normalize_latest_prompt(parts: Vec<String>) -> Option<String> {
    const MAX_PROMPT_CHARACTERS: usize = 600;

    let normalized = parts
        .into_iter()
        .filter_map(|part| {
            let part = part.split_whitespace().collect::<Vec<_>>().join(" ");
            (!part.is_empty() && !is_internal_prompt_text(&part)).then_some(part)
        })
        .collect::<Vec<_>>()
        .join(" ");
    if normalized.is_empty() {
        return None;
    }

    let mut characters = normalized.chars();
    let mut bounded = characters
        .by_ref()
        .take(MAX_PROMPT_CHARACTERS)
        .collect::<String>();
    if characters.next().is_some() {
        bounded.push('…');
    }
    Some(bounded)
}

fn is_internal_prompt_text(value: &str) -> bool {
    let value = value.trim_start().to_ascii_lowercase();
    [
        "<environment_context>",
        "<permissions instructions>",
        "<collaboration_mode>",
        "<skills_instructions>",
        "<apps_instructions>",
        "<plugins_instructions>",
        "# agents.md instructions",
    ]
    .iter()
    .any(|prefix| value.starts_with(prefix))
}

fn sanitize_model_identifier(value: String) -> Option<String> {
    if value.is_empty()
        || value.len() > 96
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return None;
    }
    Some(value)
}

fn sanitize_reasoning_effort(value: String) -> Option<String> {
    match value.to_ascii_lowercase().as_str() {
        "none" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max" => {
            Some(value.to_ascii_lowercase())
        }
        _ => None,
    }
}

fn parse_codex_activity(line: &str, latest_prompt: Option<&str>) -> (Vec<String>, Vec<String>) {
    let Some(payload) = object_for_key(line, "payload") else {
        return (Vec::new(), Vec::new());
    };
    let Some(event_type) = string_for_key(payload, "type") else {
        return (Vec::new(), Vec::new());
    };

    match event_type.as_str() {
        "task_started" => (vec![task_start_activity(latest_prompt)], Vec::new()),
        "task_complete" => (vec![String::from("Completed task")], Vec::new()),
        "context_compacted" => (vec![String::from("Compacted context")], Vec::new()),
        "patch_apply_end" => {
            let Some(changes) = object_for_key(payload, "changes") else {
                return (vec![String::from("Applied file changes")], Vec::new());
            };
            let files = top_level_object_keys(changes)
                .into_iter()
                .map(|path| display_file_name(&path))
                .collect::<Vec<_>>();
            let activity = files
                .iter()
                .map(|file| format!("Changed {file}"))
                .collect::<Vec<_>>();
            (activity, files)
        }
        "function_call" | "custom_tool_call" => {
            let command = command_from_codex_tool_payload(payload);
            let activity = string_for_key(payload, "name")
                .and_then(|name| sanitized_tool_activity(&name, command.as_deref()))
                .into_iter()
                .collect();
            (activity, Vec::new())
        }
        _ => (Vec::new(), Vec::new()),
    }
}

fn parse_claude_activity(line: &str, _latest_prompt: Option<&str>) -> (Vec<String>, Vec<String>) {
    let Some(tool_name) = string_for_key(line, "name") else {
        return (Vec::new(), Vec::new());
    };
    let file_path = string_for_key(line, "file_path")
        .or_else(|| string_for_key(line, "path"))
        .map(|path| display_file_name(&path));

    match tool_name.as_str() {
        "Edit" | "Write" | "NotebookEdit" => {
            if let Some(file) = file_path {
                (vec![format!("Changed {file}")], vec![file])
            } else {
                (vec![String::from("Applied file changes")], Vec::new())
            }
        }
        "Read" => (
            vec![file_path.map_or_else(
                || String::from("Read a project file"),
                |file| format!("Read {file}"),
            )],
            Vec::new(),
        ),
        "Bash" => (
            vec![safe_command_activity(
                string_for_key(line, "command").as_deref(),
            )],
            Vec::new(),
        ),
        "Glob" | "Grep" => (vec![String::from("Searching the project")], Vec::new()),
        "Task" => (vec![String::from("Started a delegated task")], Vec::new()),
        "AskUserQuestion" => (vec![String::from("Waiting for your answer")], Vec::new()),
        _ => (Vec::new(), Vec::new()),
    }
}

fn sanitized_tool_activity(name: &str, command: Option<&str>) -> Option<String> {
    match name {
        "apply_patch" => Some(String::from("Preparing file changes")),
        "exec" | "exec_command" => Some(safe_command_activity(command)),
        "write_stdin" => Some(String::from("Continuing the active command")),
        "wait" => Some(String::from("Waiting for a process")),
        "view_image" => Some(String::from("Inspecting an image")),
        "web__run" => Some(String::from("Checking a reference")),
        "update_plan" => Some(String::from("Updated the work plan")),
        "request_user_input" => Some(String::from("Waiting for your answer")),
        _ => None,
    }
}

const MAX_QUESTION_OPTIONS: usize = 8;
const MAX_QUESTION_TEXT: usize = 400;
const MAX_OPTION_LABEL: usize = 160;
const MAX_OPTION_DESCRIPTION: usize = 400;

fn truncate_chars(value: &str, max: usize) -> String {
    value.chars().take(max).collect()
}

/// Extract the agent's pending question and its offered options from a transcript
/// line. Only Claude's `AskUserQuestion` carries a structured option list; Codex's
/// interactive prompts do not, so those return `None` and fall back to the plain
/// "Waiting for your answer" label. All fields are length-bounded.
fn parse_pending_question(provider: &str, line: &str) -> Option<PendingQuestion> {
    if provider != "claude" {
        return None;
    }
    // Scope to the AskUserQuestion tool call so an unrelated `input` object on the
    // same line cannot be mistaken for the question payload.
    let name_index = line.find("\"name\":\"AskUserQuestion\"")?;
    let input = object_for_key(&line[name_index..], "input")?;
    let questions = array_for_key(input, "questions")?;
    let first = object_values(questions).into_iter().next()?;

    let prompt = string_for_key(first, "question").filter(|value| !value.is_empty())?;
    let header = string_for_key(first, "header").filter(|value| !value.is_empty());
    let options_array = array_for_key(first, "options")?;

    let mut options = Vec::new();
    for option in object_values(options_array)
        .into_iter()
        .take(MAX_QUESTION_OPTIONS)
    {
        let Some(label) = string_for_key(option, "label").filter(|value| !value.is_empty()) else {
            continue;
        };
        let description = string_for_key(option, "description")
            .filter(|value| !value.is_empty())
            .map(|value| truncate_chars(&value, MAX_OPTION_DESCRIPTION));
        options.push(QuestionOption {
            label: truncate_chars(&label, MAX_OPTION_LABEL),
            description,
        });
    }

    if options.is_empty() {
        return None;
    }

    Some(PendingQuestion {
        prompt: truncate_chars(&prompt, MAX_QUESTION_TEXT),
        header: header.map(|value| truncate_chars(&value, MAX_OPTION_LABEL)),
        options,
    })
}

/// JSON for the `pendingQuestion` field, emitted only while the session is
/// actually in the question state so a stale parse never shows a phantom prompt.
fn pending_question_json(reader: &TelemetryReader) -> String {
    if reader.state() != "question" {
        return String::from("null");
    }
    let Some(question) = reader.pending_question.as_ref() else {
        return String::from("null");
    };
    let options = question
        .options
        .iter()
        .map(|option| {
            let description = option.description.as_deref().map_or_else(
                || String::from("null"),
                |value| format!("\"{}\"", escape_json(value)),
            );
            format!(
                "{{\"label\":\"{}\",\"description\":{}}}",
                escape_json(&option.label),
                description
            )
        })
        .collect::<Vec<_>>()
        .join(",");
    let header = question.header.as_deref().map_or_else(
        || String::from("null"),
        |value| format!("\"{}\"", escape_json(value)),
    );
    format!(
        "{{\"prompt\":\"{}\",\"header\":{},\"options\":[{}]}}",
        escape_json(&question.prompt),
        header,
        options
    )
}

fn task_start_activity(latest_prompt: Option<&str>) -> String {
    let Some(summary) = latest_prompt.and_then(|prompt| bounded_summary(prompt, 92)) else {
        return String::from("Started a new task");
    };
    format!("Started · {summary}")
}

fn command_from_codex_tool_payload(payload: &str) -> Option<String> {
    if let Some(command) = string_for_key(payload, "cmd") {
        return Some(command);
    }

    for key in ["arguments", "input"] {
        let Some(container) = string_for_key(payload, key) else {
            continue;
        };
        if let Some(command) =
            string_for_key(&container, "cmd").or_else(|| string_for_key(&container, "command"))
        {
            return Some(command);
        }
    }
    None
}

fn safe_command_activity(command: Option<&str>) -> String {
    let Some(command) = command else {
        return String::from("Running a command");
    };
    let normalized = command.split_whitespace().collect::<Vec<_>>().join(" ");
    let lower = normalized.to_ascii_lowercase();

    let known_activity = if lower.contains("cargo test") {
        Some("Testing Rust · cargo test")
    } else if lower.contains("cargo clippy") {
        Some("Checking Rust warnings · cargo clippy")
    } else if lower.contains("cargo build") {
        Some("Building Rust helper · cargo build")
    } else if lower.contains("swift test") {
        Some("Testing Swift · swift test")
    } else if lower.contains("swift build") {
        Some("Checking Swift build errors · swift build")
    } else if lower.contains("build-app.sh") {
        Some("Building Agent Island · build-app.sh")
    } else if lower.contains("codesign") {
        Some("Verifying app signature · codesign")
    } else if lower.contains("git diff") {
        Some("Reviewing file changes · git diff")
    } else if lower.contains("git status") {
        Some("Checking workspace changes · git status")
    } else if command_contains_tool(&lower, "rg") || command_contains_tool(&lower, "grep") {
        if lower.contains("error") || lower.contains("fail") {
            Some("Searching for error output · rg")
        } else {
            Some("Searching project text · rg")
        }
    } else if command_contains_tool(&lower, "sed")
        || command_contains_tool(&lower, "head")
        || command_contains_tool(&lower, "tail")
    {
        Some("Reading project details · shell")
    } else if command_contains_tool(&lower, "find") || command_contains_tool(&lower, "ls") {
        Some("Inspecting project files · shell")
    } else if command_contains_tool(&lower, "curl") {
        Some("Checking an endpoint · curl")
    } else {
        None
    };
    if let Some(activity) = known_activity {
        return String::from(activity);
    }

    safe_executable_name(&normalized)
        .map(|executable| format!("Running · {executable}"))
        .unwrap_or_else(|| String::from("Running a command"))
}

fn command_contains_tool(command: &str, tool: &str) -> bool {
    command
        .split(|character: char| {
            character.is_whitespace()
                || matches!(character, '/' | ';' | '|' | '&' | '(' | ')' | '\'' | '"')
        })
        .any(|part| part == tool)
}

fn safe_executable_name(command: &str) -> Option<String> {
    command
        .split_whitespace()
        .map(|part| part.trim_matches(|character| matches!(character, '\'' | '"')))
        .find(|part| {
            !part.is_empty() && !part.contains('=') && !matches!(*part, "env" | "command" | "sudo")
        })
        .and_then(|part| Path::new(part).file_name())
        .and_then(|name| name.to_str())
        .filter(|name| {
            !name.is_empty()
                && name.len() <= 40
                && name
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        })
        .map(String::from)
}

fn bounded_summary(value: &str, maximum_characters: usize) -> Option<String> {
    let normalized = value.split_whitespace().collect::<Vec<_>>().join(" ");
    if normalized.is_empty() {
        return None;
    }

    let first_sentence = normalized
        .split(['\n', '\r'])
        .next()
        .unwrap_or(&normalized)
        .trim();
    let mut characters = first_sentence.chars();
    let mut summary = characters
        .by_ref()
        .take(maximum_characters)
        .collect::<String>();
    if characters.next().is_some() {
        summary.push('…');
    }
    Some(summary)
}

fn display_file_name(path: &str) -> String {
    Path::new(path)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(path)
        .chars()
        .take(96)
        .collect()
}

fn top_level_object_keys(json: &str) -> Vec<String> {
    let bytes = json.as_bytes();
    let mut keys = Vec::new();
    let mut depth = 0_usize;
    let mut index = 0_usize;

    while index < bytes.len() {
        match bytes[index] {
            b'{' => {
                depth += 1;
                index += 1;
            }
            b'}' => {
                depth = depth.saturating_sub(1);
                index += 1;
            }
            b'\"' => {
                let start = index + 1;
                index = start;
                let mut escaped = false;
                while index < bytes.len() {
                    if escaped {
                        escaped = false;
                    } else if bytes[index] == b'\\' {
                        escaped = true;
                    } else if bytes[index] == b'\"' {
                        break;
                    }
                    index += 1;
                }
                if index >= bytes.len() {
                    break;
                }

                let mut after = index + 1;
                while after < bytes.len() && bytes[after].is_ascii_whitespace() {
                    after += 1;
                }
                if depth == 1 && after < bytes.len() && bytes[after] == b':' {
                    keys.push(decode_json_string(&json[start..index]));
                }
                index += 1;
            }
            _ => index += 1,
        }
    }

    keys
}

fn top_level_string_for_key(json: &str, key: &str) -> Option<String> {
    let bytes = json.as_bytes();
    let mut depth = 0_usize;
    let mut index = 0_usize;

    while index < bytes.len() {
        match bytes[index] {
            b'{' => {
                depth += 1;
                index += 1;
            }
            b'}' => {
                depth = depth.saturating_sub(1);
                index += 1;
            }
            b'"' => {
                let start = index + 1;
                index = start;
                let mut escaped = false;
                while index < bytes.len() {
                    if escaped {
                        escaped = false;
                    } else if bytes[index] == b'\\' {
                        escaped = true;
                    } else if bytes[index] == b'"' {
                        break;
                    }
                    index += 1;
                }
                if index >= bytes.len() {
                    return None;
                }

                let mut after = index + 1;
                while after < bytes.len() && bytes[after].is_ascii_whitespace() {
                    after += 1;
                }
                if depth == 1
                    && after < bytes.len()
                    && bytes[after] == b':'
                    && decode_json_string(&json[start..index]) == key
                {
                    let mut value_start = after + 1;
                    while value_start < bytes.len() && bytes[value_start].is_ascii_whitespace() {
                        value_start += 1;
                    }
                    if value_start >= bytes.len() || bytes[value_start] != b'"' {
                        return None;
                    }

                    let content_start = value_start + 1;
                    let mut value_end = content_start;
                    let mut value_escaped = false;
                    while value_end < bytes.len() {
                        if value_escaped {
                            value_escaped = false;
                        } else if bytes[value_end] == b'\\' {
                            value_escaped = true;
                        } else if bytes[value_end] == b'"' {
                            return Some(decode_json_string(&json[content_start..value_end]));
                        }
                        value_end += 1;
                    }
                    return None;
                }
                index += 1;
            }
            _ => index += 1,
        }
    }
    None
}

fn string_for_key(json: &str, key: &str) -> Option<String> {
    let marker = format!("\"{key}\":");
    let start = json.find(&marker)? + marker.len();
    let value = json[start..].trim_start();
    let value = value.strip_prefix('\"')?;
    let bytes = value.as_bytes();
    let mut escaped = false;
    for (index, byte) in bytes.iter().enumerate() {
        if escaped {
            escaped = false;
        } else if *byte == b'\\' {
            escaped = true;
        } else if *byte == b'\"' {
            return Some(decode_json_string(&value[..index]));
        }
    }
    None
}

fn decode_json_string(value: &str) -> String {
    let mut decoded = String::with_capacity(value.len());
    let mut characters = value.chars();
    while let Some(character) = characters.next() {
        if character != '\\' {
            decoded.push(character);
            continue;
        }

        match characters.next() {
            Some('\"') => decoded.push('\"'),
            Some('\\') => decoded.push('\\'),
            Some('/') => decoded.push('/'),
            Some('n') => decoded.push('\n'),
            Some('r') => decoded.push('\r'),
            Some('t') => decoded.push('\t'),
            Some('b') => decoded.push('\u{0008}'),
            Some('f') => decoded.push('\u{000C}'),
            Some(other) => decoded.push(other),
            None => break,
        }
    }
    decoded
}

fn parse_codex_usage(line: &str) -> Option<UsageTelemetry> {
    if !line.contains("\"type\":\"token_count\"") {
        return None;
    }

    let info = object_for_key(line, "info")?;
    let last = object_for_key(info, "last_token_usage")?;
    let total = object_for_key(info, "total_token_usage")?;
    let rate_limits = object_for_key(line, "rate_limits");
    let primary = rate_limits.and_then(|value| object_for_key(value, "primary"));
    let secondary = rate_limits.and_then(|value| object_for_key(value, "secondary"));
    let selected_window = [primary, secondary]
        .into_iter()
        .flatten()
        .filter_map(|window| {
            let reset = unsigned_for_key(window, "resets_at")?;
            Some((reset, window))
        })
        .min_by_key(|(reset, _)| *reset)
        .map(|(_, window)| window);

    Some(UsageTelemetry {
        context_used_tokens: unsigned_for_key(last, "total_tokens"),
        context_window_tokens: unsigned_for_key(info, "model_context_window"),
        session_total_tokens: unsigned_for_key(total, "total_tokens"),
        rate_limit_used_percent: selected_window
            .and_then(|window| number_for_key(window, "used_percent")),
        rate_limit_resets_at: selected_window
            .and_then(|window| unsigned_for_key(window, "resets_at")),
        rate_limit_window_minutes: selected_window
            .and_then(|window| unsigned_for_key(window, "window_minutes")),
        source: "codex-session-log",
        exact: true,
    })
}

// Claude transcripts record token usage but not the model's context window.
// Current Claude models used with Claude Code (Sonnet 5, Opus 4.x, Sonnet 4.6)
// all expose a 1M-token window, so default to that when the exact size is not
// available from the Claude status-line metrics bridge (`parse_claude_status`).
const CLAUDE_DEFAULT_CONTEXT_WINDOW: u64 = 1_000_000;

fn parse_claude_usage(line: &str) -> Option<UsageTelemetry> {
    if !line.contains("\"type\":\"assistant\"") {
        return None;
    }
    let message = object_for_key(line, "message")?;
    let usage = object_for_key(message, "usage")?;
    let context_used_tokens = [
        "input_tokens",
        "cache_creation_input_tokens",
        "cache_read_input_tokens",
    ]
    .into_iter()
    .filter_map(|key| unsigned_for_key(usage, key))
    .sum::<u64>();

    Some(UsageTelemetry {
        context_used_tokens: Some(context_used_tokens),
        context_window_tokens: Some(CLAUDE_DEFAULT_CONTEXT_WINDOW),
        session_total_tokens: None,
        rate_limit_used_percent: None,
        rate_limit_resets_at: None,
        rate_limit_window_minutes: None,
        source: "claude-transcript",
        exact: true,
    })
}

fn parse_claude_status(json: &str) -> Option<UsageTelemetry> {
    let context = object_for_key(json, "context_window")?;
    let context_used_tokens = unsigned_for_key(context, "total_input_tokens");
    let context_window_tokens = unsigned_for_key(context, "context_window_size");
    if context_used_tokens.is_none() && context_window_tokens.is_none() {
        return None;
    }

    let rate_limits = object_for_key(json, "rate_limits");
    let five_hour = rate_limits.and_then(|value| object_for_key(value, "five_hour"));
    let seven_day = rate_limits.and_then(|value| object_for_key(value, "seven_day"));
    let selected_window = [(five_hour, 300_u64), (seven_day, 10_080_u64)]
        .into_iter()
        .filter_map(|(window, minutes)| {
            let window = window?;
            let reset = unsigned_for_key(window, "resets_at")?;
            Some((reset, minutes, window))
        })
        .min_by_key(|(reset, _, _)| *reset);

    Some(UsageTelemetry {
        context_used_tokens,
        context_window_tokens,
        session_total_tokens: None,
        rate_limit_used_percent: selected_window
            .and_then(|(_, _, window)| number_for_key(window, "used_percentage")),
        rate_limit_resets_at: selected_window.map(|(reset, _, _)| reset),
        rate_limit_window_minutes: selected_window.map(|(_, minutes, _)| minutes),
        source: "claude-status-line",
        exact: true,
    })
}

fn object_for_key<'a>(json: &'a str, key: &str) -> Option<&'a str> {
    let marker = format!("\"{key}\":");
    let key_start = json.find(&marker)? + marker.len();
    let relative_start = json[key_start..].find('{')?;
    let start = key_start + relative_start;
    if json[key_start..start].contains("null") {
        return None;
    }

    let mut depth = 0_u32;
    let mut in_string = false;
    let mut escaped = false;
    for (relative_index, character) in json[start..].char_indices() {
        if in_string {
            if escaped {
                escaped = false;
            } else if character == '\\' {
                escaped = true;
            } else if character == '"' {
                in_string = false;
            }
            continue;
        }

        match character {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth = depth.checked_sub(1)?;
                if depth == 0 {
                    return Some(&json[start..=start + relative_index]);
                }
            }
            _ => {}
        }
    }
    None
}

fn array_for_key<'a>(json: &'a str, key: &str) -> Option<&'a str> {
    let marker = format!("\"{key}\":");
    let key_start = json.find(&marker)? + marker.len();
    let relative_start = json[key_start..].find('[')?;
    let start = key_start + relative_start;
    if json[key_start..start].contains("null") {
        return None;
    }

    let mut depth = 0_u32;
    let mut in_string = false;
    let mut escaped = false;
    for (relative_index, character) in json[start..].char_indices() {
        if in_string {
            if escaped {
                escaped = false;
            } else if character == '\\' {
                escaped = true;
            } else if character == '"' {
                in_string = false;
            }
            continue;
        }

        match character {
            '"' => in_string = true,
            '[' => depth += 1,
            ']' => {
                depth = depth.checked_sub(1)?;
                if depth == 0 {
                    return Some(&json[start..=start + relative_index]);
                }
            }
            _ => {}
        }
    }
    None
}

fn object_values(json: &str) -> Vec<&str> {
    let mut values = Vec::new();
    let mut depth = 0_u32;
    let mut start = None;
    let mut in_string = false;
    let mut escaped = false;

    for (index, character) in json.char_indices() {
        if in_string {
            if escaped {
                escaped = false;
            } else if character == '\\' {
                escaped = true;
            } else if character == '"' {
                in_string = false;
            }
            continue;
        }

        match character {
            '"' => in_string = true,
            '{' => {
                if depth == 0 {
                    start = Some(index);
                }
                depth += 1;
            }
            '}' => {
                let Some(next_depth) = depth.checked_sub(1) else {
                    continue;
                };
                depth = next_depth;
                if depth == 0 {
                    if let Some(start) = start.take() {
                        values.push(&json[start..=index]);
                    }
                }
            }
            _ => {}
        }
    }
    values
}

fn boolean_for_key(json: &str, key: &str) -> Option<bool> {
    let marker = format!("\"{key}\":");
    let start = json.find(&marker)? + marker.len();
    let value = json[start..].trim_start();
    if value.starts_with("true") {
        Some(true)
    } else if value.starts_with("false") {
        Some(false)
    } else {
        None
    }
}

fn unsigned_for_key(json: &str, key: &str) -> Option<u64> {
    number_text_for_key(json, key)?.parse().ok()
}

fn number_for_key(json: &str, key: &str) -> Option<f64> {
    number_text_for_key(json, key)?.parse().ok()
}

fn number_text_for_key<'a>(json: &'a str, key: &str) -> Option<&'a str> {
    let marker = format!("\"{key}\":");
    let start = json.find(&marker)? + marker.len();
    let value = json[start..].trim_start();
    let length = value
        .bytes()
        .take_while(|byte| byte.is_ascii_digit() || matches!(*byte, b'.' | b'-' | b'+'))
        .count();
    (length > 0).then_some(&value[..length])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_codex_cli() {
        assert_eq!(
            parse_process_line("  123 /opt/homebrew/bin/codex --profile work"),
            Some(DetectedAgent {
                provider: "codex",
                pid: 123
            })
        );
    }

    #[test]
    fn detects_claude_cli() {
        assert_eq!(
            parse_process_line("456 /Users/test/.local/bin/claude"),
            Some(DetectedAgent {
                provider: "claude",
                pid: 456
            })
        );
    }

    #[test]
    fn discovers_primary_and_secondary_claude_profile_roots() {
        assert_eq!(
            telemetry_roots_for_home("claude", Path::new("/Users/test")),
            vec![
                PathBuf::from("/Users/test/.claude/projects"),
                PathBuf::from("/Users/test/.claude2/projects"),
            ]
        );
    }

    #[test]
    fn ignores_unrelated_processes() {
        assert_eq!(
            parse_process_line("789 /Applications/Code.app/Contents/MacOS/Electron"),
            None
        );
    }

    #[test]
    fn ignores_agent_background_workers() {
        assert_eq!(
            parse_process_line(
                "790 /Applications/ChatGPT.app/Contents/Resources/codex sandbox -- command"
            ),
            None
        );
        assert_eq!(
            parse_process_line("791 /Users/test/.local/bin/claude daemon run"),
            None
        );
        assert_eq!(
            parse_process_line("792 claude bg-pty-host --bg-pty-host /tmp/session.sock"),
            None
        );
        assert_eq!(
            parse_process_line(
                "793 /Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Helpers/Codex (Renderer)"
            ),
            None
        );
        assert_eq!(
            parse_process_line(
                "794 /Users/test/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService"
            ),
            None
        );
    }

    #[test]
    fn session_cap_reserves_live_provider_slots_before_filling_by_recency() {
        let now = SystemTime::now();
        let mut candidates = (0..8)
            .map(|index| SessionCandidate {
                provider: "codex",
                modified: now - Duration::from_secs(index),
                path: PathBuf::from(format!("/sessions/codex-{index}.jsonl")),
            })
            .collect::<Vec<_>>();
        candidates.extend((0..4).map(|index| SessionCandidate {
            provider: "claude",
            modified: now - Duration::from_secs(3_600 + index),
            path: PathBuf::from(format!("/sessions/claude-{index}.jsonl")),
        }));

        let selected = select_bounded_candidates(candidates, (8, 4), 8);
        assert_eq!(selected.len(), 8);
        assert_eq!(
            selected
                .iter()
                .filter(|candidate| candidate.provider == "codex")
                .count(),
            5
        );
        assert_eq!(
            selected
                .iter()
                .filter(|candidate| candidate.provider == "claude")
                .count(),
            3
        );
        for index in 0..3 {
            assert!(selected.iter().any(|candidate| {
                candidate.path == PathBuf::from(format!("/sessions/claude-{index}.jsonl"))
            }));
        }
    }

    #[test]
    fn derives_status_from_activity_instead_of_process_presence() {
        assert_eq!(
            state_for_activity(Some("Running a command"), Some(Duration::from_secs(3))),
            "thinking"
        );
        assert_eq!(
            state_for_activity(Some("Completed task"), Some(Duration::from_secs(3))),
            "complete"
        );
        assert_eq!(
            state_for_activity(Some("Completed task"), Some(Duration::from_secs(15))),
            "idle"
        );
        assert_eq!(
            state_for_activity(Some("Running a command"), Some(Duration::from_secs(61))),
            "idle"
        );
        assert_eq!(
            state_for_activity(
                Some("Waiting for your answer"),
                Some(Duration::from_secs(3_600))
            ),
            "question"
        );
        assert_eq!(state_for_activity(None, None), "idle");

        assert_eq!(
            task_for_snapshot(
                "Codex",
                "complete",
                Some("Completed task"),
                Some("dynamic_island")
            ),
            "Completed · dynamic_island"
        );

        let mut reader = TelemetryReader::new();
        reader.activity_log = vec![String::from("Completed task")];
        reader.workspace_path = Some(String::from("/work/dynamic_island"));
        let fields = activity_fields_json(Some(&reader), (2, 1));
        assert!(fields.contains("Completed · dynamic_island"));
    }

    #[test]
    fn parses_codex_context_and_next_reset() {
        let line = r#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":12711634},"last_token_usage":{"total_tokens":86726},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":42.5,"window_minutes":300,"resets_at":1785000000},"secondary":{"used_percent":10.0,"window_minutes":10080,"resets_at":1785500000}}}}"#;
        let usage = parse_codex_usage(line).expect("Codex usage should parse");

        assert_eq!(usage.context_used_tokens, Some(86_726));
        assert_eq!(usage.context_window_tokens, Some(258_400));
        assert_eq!(usage.session_total_tokens, Some(12_711_634));
        assert_eq!(usage.rate_limit_used_percent, Some(42.5));
        assert_eq!(usage.rate_limit_resets_at, Some(1_785_000_000));
        assert_eq!(usage.rate_limit_window_minutes, Some(300));
        assert!(usage.exact);
    }

    #[test]
    fn parses_codex_changed_file_names_without_contents() {
        let line = r#"{"type":"event_msg","payload":{"type":"patch_apply_end","changes":{"/work/Sources/IslandViews.swift":{"type":"update","unified_diff":"private change"},"/work/README.md":{"type":"update","unified_diff":"private change"}}}}"#;
        let (activity, files) = parse_codex_activity(line, None);

        assert_eq!(
            activity,
            vec!["Changed IslandViews.swift", "Changed README.md"]
        );
        assert_eq!(files, vec!["IslandViews.swift", "README.md"]);
        assert!(!activity.iter().any(|item| item.contains("private change")));
    }

    #[test]
    fn extracts_only_absolute_workspace_paths() {
        let event =
            r#"{"type":"turn_context","payload":{"cwd":"/work/agent-island","model":"gpt"}}"#;
        assert_eq!(
            workspace_path_from_event(event),
            Some(String::from("/work/agent-island"))
        );
        assert_eq!(
            workspace_path_from_event(r#"{"cwd":"relative/project"}"#),
            None
        );
    }

    #[test]
    fn parses_only_sanitized_model_metadata_from_provider_events() {
        let codex = r#"{"type":"turn_context","payload":{"model":"gpt-5.6-sol","effort":"xhigh","private_prompt":"never"}}"#;
        assert_eq!(
            model_metadata_from_event("codex", codex),
            (
                Some(String::from("gpt-5.6-sol")),
                Some(String::from("xhigh"))
            )
        );

        let claude = r#"{"type":"assistant","message":{"model":"claude-sonnet-5","content":[]},"effort":"xhigh"}"#;
        assert_eq!(
            model_metadata_from_event("claude", claude),
            (
                Some(String::from("claude-sonnet-5")),
                Some(String::from("xhigh"))
            )
        );

        let maximum = r#"{"type":"assistant","message":{"model":"claude-fable-5","content":[]},"effort":"max"}"#;
        assert_eq!(
            model_metadata_from_event("claude", maximum),
            (
                Some(String::from("claude-fable-5")),
                Some(String::from("max"))
            )
        );

        let nested_effort = r#"{"type":"assistant","message":{"model":"claude-sonnet-5","effort":"xhigh","content":[]}}"#;
        assert_eq!(
            model_metadata_from_event("claude", nested_effort),
            (Some(String::from("claude-sonnet-5")), None)
        );

        let prompt = r#"{"type":"user","message":{"content":"{\"model\":\"private-model\"}"}}"#;
        assert_eq!(model_metadata_from_event("claude", prompt), (None, None));

        let synthetic = r#"{"type":"assistant","message":{"model":"<synthetic>","content":[]}}"#;
        assert_eq!(model_metadata_from_event("claude", synthetic), (None, None));
    }

    #[test]
    fn extracts_latest_user_prompts_without_internal_or_tool_messages() {
        let codex = r#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>private</environment_context>"},{"type":"input_text","text":"Please make the island feel alive.\nKeep it efficient."}]}}"#;
        assert_eq!(
            latest_prompt_from_event("codex", codex),
            Some(String::from(
                "Please make the island feel alive. Keep it efficient."
            ))
        );

        let claude = r#"{"type":"user","message":{"role":"user","content":"Polish the multi-agent session panel."}}"#;
        assert_eq!(
            latest_prompt_from_event("claude", claude),
            Some(String::from("Polish the multi-agent session panel."))
        );

        let claude_meta = r#"{"type":"user","isMeta":true,"message":{"role":"user","content":"Do not display this generated record."}}"#;
        assert_eq!(latest_prompt_from_event("claude", claude_meta), None);

        let tool_result = r#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"private tool output"}]}}"#;
        assert_eq!(latest_prompt_from_event("claude", tool_result), None);
    }

    #[test]
    fn finds_workspace_in_bounded_transcript_header() {
        let unique = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .expect("system time should be valid")
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "agent-island-workspace-{}-{unique}.jsonl",
            std::process::id()
        ));
        fs::write(
            &path,
            "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/work/multi-session\",\"private_prompt\":\"never emit this\"}}\n",
        )
        .expect("test transcript should be written");

        assert_eq!(
            workspace_from_transcript_head(&path),
            Some(String::from("/work/multi-session"))
        );
        fs::remove_file(path).expect("owned test transcript should be removed");
    }

    #[test]
    fn serializes_sessions_with_bounded_display_metadata_without_transcript_paths() {
        let mut reader = TelemetryReader::attached(
            "codex",
            PathBuf::from("/private/transcripts/rollout-session-12345678.jsonl"),
            SystemTime::now(),
        );
        reader.workspace_path = Some(String::from("/work/agent-island"));
        reader.activity_log = vec![String::from("Running a command")];
        reader.changed_files = vec![String::from("IslandModel.swift")];
        reader.model_name = Some(String::from("gpt-5.6-sol"));
        reader.reasoning_effort = Some(String::from("xhigh"));
        reader.latest_prompt = Some(String::from("Make the compact cluster show three agents."));

        let json = session_json(&reader);
        assert!(json.contains("rollout-session-12345678"));
        assert!(json.contains("agent-island"));
        assert!(json.contains("IslandModel.swift"));
        assert!(json.contains("gpt-5.6-sol"));
        assert!(json.contains("xhigh"));
        assert!(json.contains("Make the compact cluster show three agents."));
        assert!(!json.contains("/private/transcripts"));
        assert!(!json.contains("private_prompt"));
    }

    #[test]
    fn parses_claude_file_tools_without_arguments() {
        let line = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/work/payment.swift","old_string":"secret"}}]}}"#;
        let (activity, files) = parse_claude_activity(line, None);

        assert_eq!(activity, vec!["Changed payment.swift"]);
        assert_eq!(files, vec!["payment.swift"]);
        assert!(!activity[0].contains("secret"));
    }

    #[test]
    fn summarizes_tasks_and_commands_without_exposing_arguments() {
        let started = r#"{"type":"event_msg","payload":{"type":"task_started"}}"#;
        let (activity, _) = parse_codex_activity(
            started,
            Some("Make the complete color lighter and keep the interface readable."),
        );
        assert_eq!(
            activity,
            vec!["Started · Make the complete color lighter and keep the interface readable."]
        );

        let codex_command = r#"{"type":"event_msg","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"swift build --secret private-value\"}"}}"#;
        let (activity, _) = parse_codex_activity(codex_command, None);
        assert_eq!(activity, vec!["Checking Swift build errors · swift build"]);
        assert!(!activity[0].contains("private-value"));

        let claude_command = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cargo test --token private-value"}}]}}"#;
        let (activity, _) = parse_claude_activity(claude_command, None);
        assert_eq!(activity, vec!["Testing Rust · cargo test"]);
        assert!(!activity[0].contains("private-value"));

        assert_eq!(
            safe_command_activity(Some("unknown-tool --password private-value")),
            "Running · unknown-tool"
        );
    }

    #[test]
    fn records_prompt_start_before_later_safe_command_activity() {
        let unique = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .expect("system time should be valid")
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "agent-island-activity-summary-{}-{unique}.jsonl",
            std::process::id()
        ));
        fs::write(
            &path,
            concat!(
                "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Make the status label easier to read.\"}}\n",
                "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"swift build --token private-value\"}}]}}\n"
            ),
        )
        .expect("test transcript should be written");

        let modified = fs::metadata(&path)
            .and_then(|metadata| metadata.modified())
            .expect("test transcript should have a modified time");
        let mut reader = TelemetryReader::attached("claude", path.clone(), modified);
        reader.read_updates("claude");

        assert_eq!(
            reader.activity_log,
            vec![
                "Started · Make the status label easier to read.",
                "Checking Swift build errors · swift build"
            ]
        );
        assert!(
            !reader
                .activity_log
                .iter()
                .any(|activity| activity.contains("private-value"))
        );
        fs::remove_file(path).expect("owned test transcript should be removed");
    }

    #[test]
    fn parses_claude_context_with_default_window() {
        let line = r#"{"type":"assistant","message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":1205,"cache_read_input_tokens":34428,"output_tokens":1322}}}"#;
        let usage = parse_claude_usage(line).expect("Claude usage should parse");

        assert_eq!(usage.context_used_tokens, Some(35_635));
        // The transcript omits the window; fall back to the current Claude default
        // so the island can show a context percentage instead of a dash.
        assert_eq!(usage.context_window_tokens, Some(CLAUDE_DEFAULT_CONTEXT_WINDOW));
        assert_eq!(usage.rate_limit_resets_at, None);
        assert_eq!(usage.source, "claude-transcript");
    }

    #[test]
    fn parses_claude_status_line_context_and_next_reset() {
        let json = r#"{"context_window":{"total_input_tokens":42800,"total_output_tokens":2100,"context_window_size":200000,"used_percentage":21},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1785000000},"seven_day":{"used_percentage":41.2,"resets_at":1785500000}}}"#;
        let usage = parse_claude_status(json).expect("Claude status should parse");

        assert_eq!(usage.context_used_tokens, Some(42_800));
        assert_eq!(usage.context_window_tokens, Some(200_000));
        assert_eq!(usage.rate_limit_used_percent, Some(23.5));
        assert_eq!(usage.rate_limit_resets_at, Some(1_785_000_000));
        assert_eq!(usage.rate_limit_window_minutes, Some(300));
        assert_eq!(usage.source, "claude-status-line");
    }

    #[test]
    fn parses_claude_ask_user_question_options() {
        let line = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","input":{"questions":[{"question":"Which theme should the dashboard default to?","header":"Theme","multiSelect":false,"options":[{"label":"Dark","description":"Matches the terminal aesthetic"},{"label":"Light","description":"Better for daytime use"},{"label":"System","description":"Follow macOS appearance"}]}]}}]}}"#;
        let question = parse_pending_question("claude", line).expect("should parse a question");

        assert_eq!(question.prompt, "Which theme should the dashboard default to?");
        assert_eq!(question.header.as_deref(), Some("Theme"));
        assert_eq!(question.options.len(), 3);
        assert_eq!(question.options[0].label, "Dark");
        assert_eq!(
            question.options[0].description.as_deref(),
            Some("Matches the terminal aesthetic")
        );
        assert_eq!(question.options[2].label, "System");
    }

    #[test]
    fn returns_no_question_for_non_claude_or_unrelated_lines() {
        let claude_question = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","input":{"questions":[{"question":"Pick","header":"H","options":[{"label":"A"}]}]}}]}}"#;
        // Codex has no structured option list, so it must fall back to None.
        assert!(parse_pending_question("codex", claude_question).is_none());

        let unrelated = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#;
        assert!(parse_pending_question("claude", unrelated).is_none());
    }

    #[test]
    fn bounds_question_option_count_and_length() {
        let mut options = String::new();
        for index in 0..20 {
            if index > 0 {
                options.push(',');
            }
            options.push_str(&format!("{{\"label\":\"opt {index}\"}}"));
        }
        let long = "x".repeat(1000);
        let line = format!(
            r#"{{"type":"assistant","message":{{"content":[{{"type":"tool_use","name":"AskUserQuestion","input":{{"questions":[{{"question":"{long}","options":[{options}]}}]}}}}]}}}}"#
        );
        let question = parse_pending_question("claude", &line).expect("should parse");

        assert_eq!(question.options.len(), MAX_QUESTION_OPTIONS);
        assert_eq!(question.prompt.chars().count(), MAX_QUESTION_TEXT);
        assert!(question.header.is_none());
    }

    #[test]
    fn serializes_pending_question_only_while_in_question_state() {
        let mut reader = TelemetryReader::attached(
            "claude",
            PathBuf::from("/transcripts/session-abc.jsonl"),
            SystemTime::now(),
        );
        reader.pending_question = Some(PendingQuestion {
            prompt: String::from("Pick one"),
            header: Some(String::from("Choice")),
            options: vec![
                QuestionOption {
                    label: String::from("Alpha"),
                    description: None,
                },
                QuestionOption {
                    label: String::from("Beta"),
                    description: Some(String::from("second")),
                },
            ],
        });

        // Thinking state must not leak the parsed question.
        reader.activity_log = vec![String::from("Running verification")];
        assert!(session_json(&reader).contains("\"pendingQuestion\":null"));

        // Question state exposes the prompt and options.
        reader.activity_log = vec![String::from("Waiting for your answer")];
        let json = session_json(&reader);
        assert!(json.contains("\"prompt\":\"Pick one\""));
        assert!(json.contains("\"label\":\"Alpha\""));
        assert!(json.contains("\"label\":\"Beta\""));
    }
}
