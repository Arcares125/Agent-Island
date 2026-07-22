//! The line between portable logic and the operating system.
//!
//! Everything above this module — transcript parsing, session tracking, the
//! question protocol — is plain Rust that runs anywhere. Everything the OS owns
//! lives below it: where a user's files are, which processes are running, and
//! how a blocked agent reaches the island.
//!
//! The two implementations are not translations of each other. Each platform is
//! asked for what it can answer cheaply and honestly, and the portable side is
//! shaped to accept either. Where that forces a real behavioural difference —
//! notably how a helper process is told apart from an interactive session — the
//! difference is documented at the point it is made rather than papered over.

#[cfg(unix)]
mod unix;
#[cfg(unix)]
pub use unix::{cache_dir, home_dir, ipc, scan_processes};

#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use windows::{cache_dir, home_dir, ipc, scan_processes};

// The three items below are Windows' half of process detection, but they are
// compiled everywhere rather than behind `#[cfg(windows)]`. They are pure, so
// building and testing them on the development machine catches mistakes that
// would otherwise only surface on the machine they ship to — which is the whole
// point of keeping the policy out of the FFI.

/// One running process, reduced to the fields any platform can supply.
///
/// `parent_pid` is the fallback signal for platforms that cannot hand over a
/// command line without paying for it — see [`agents_from_parentage`].
#[cfg_attr(not(windows), allow(dead_code))]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessEntry {
    pub pid: u32,
    pub parent_pid: u32,
    /// Lowercased executable stem: `claude`, `codex`, `explorer`.
    pub executable: String,
}

/// Interactive agent sessions, told apart from the helpers they spawn by
/// parentage rather than by argv.
///
/// macOS reads `ps -axo command=` and filters on the arguments, because a
/// session's helpers announce themselves there (`claude daemon`, `codex
/// sandbox`). Windows has no equally cheap way to read another process's
/// command line — it means opening the process and walking its PEB — so this
/// uses the one relationship a snapshot does include: a helper's parent is the
/// session that spawned it, whereas an interactive session's parent is a shell.
///
/// Pure and platform-independent so it can be tested on any host, not only the
/// one it ships to.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn agents_from_parentage(entries: &[ProcessEntry], self_pid: u32) -> Vec<crate::DetectedAgent> {
    let provider_of = |name: &str| match name {
        "codex" => Some("codex"),
        "claude" => Some("claude"),
        _ => None,
    };

    let mut agents: Vec<crate::DetectedAgent> = entries
        .iter()
        .filter(|entry| entry.pid != self_pid)
        .filter_map(|entry| {
            let provider = provider_of(&entry.executable)?;
            // A process whose parent runs the same agent binary is one of that
            // session's workers, not a session of its own.
            let parent_is_same_agent = entries
                .iter()
                .find(|candidate| candidate.pid == entry.parent_pid)
                .and_then(|parent| provider_of(&parent.executable))
                .is_some_and(|parent_provider| parent_provider == provider);
            (!parent_is_same_agent).then_some(crate::DetectedAgent {
                provider,
                pid: entry.pid,
            })
        })
        .collect();

    agents.sort_by_key(|agent| agent.pid);
    agents
}

/// Strip a directory and an extension off an executable path, lowercased.
///
/// Accepts both separators because a Windows snapshot can report either, and a
/// name arriving as `Claude.exe` must match one arriving as `claude`.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn executable_stem(path: &str) -> String {
    let file = path.rsplit(['/', '\\']).next().unwrap_or(path);
    // Case first: Windows paths are case-insensitive, so the extension can
    // arrive as `.EXE` and would survive a case-sensitive strip.
    let mut stem = file.to_ascii_lowercase();
    if stem.ends_with(".exe") {
        stem.truncate(stem.len() - ".exe".len());
    }
    stem
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(pid: u32, parent_pid: u32, executable: &str) -> ProcessEntry {
        ProcessEntry {
            pid,
            parent_pid,
            executable: String::from(executable),
        }
    }

    #[test]
    fn executable_stem_normalises_both_separators_and_case() {
        assert_eq!(executable_stem("C:\\Program Files\\Claude\\Claude.exe"), "claude");
        assert_eq!(executable_stem("/opt/homebrew/bin/codex"), "codex");
        assert_eq!(executable_stem("CODEX.EXE"), "codex");
    }

    #[test]
    fn counts_a_session_launched_from_a_shell() {
        let snapshot = [entry(400, 100, "windowsterminal"), entry(500, 400, "claude")];
        assert_eq!(
            agents_from_parentage(&snapshot, 1),
            vec![crate::DetectedAgent {
                provider: "claude",
                pid: 500
            }]
        );
    }

    /// The whole reason parentage is the signal: a session's own workers must
    /// not inflate the count the island shows.
    #[test]
    fn ignores_workers_spawned_by_a_session() {
        let snapshot = [
            entry(400, 100, "pwsh"),
            entry(500, 400, "claude"),
            entry(501, 500, "claude"),
            entry(502, 500, "claude"),
        ];
        assert_eq!(
            agents_from_parentage(&snapshot, 1),
            vec![crate::DetectedAgent {
                provider: "claude",
                pid: 500
            }]
        );
    }

    #[test]
    fn counts_two_independent_sessions() {
        let snapshot = [
            entry(400, 100, "pwsh"),
            entry(500, 400, "claude"),
            entry(600, 400, "codex"),
            entry(601, 600, "codex"),
        ];
        assert_eq!(
            agents_from_parentage(&snapshot, 1),
            vec![
                crate::DetectedAgent {
                    provider: "claude",
                    pid: 500
                },
                crate::DetectedAgent {
                    provider: "codex",
                    pid: 600
                },
            ]
        );
    }

    /// A codex launched from inside a claude session is still a real session —
    /// only same-provider parentage means "worker".
    #[test]
    fn nested_providers_both_count() {
        let snapshot = [entry(500, 400, "claude"), entry(600, 500, "codex")];
        assert_eq!(agents_from_parentage(&snapshot, 1).len(), 2);
    }

    #[test]
    fn ignores_unrelated_processes() {
        let snapshot = [entry(1, 0, "explorer"), entry(2, 1, "code"), entry(3, 1, "node")];
        assert!(agents_from_parentage(&snapshot, 99).is_empty());
    }

    #[test]
    fn never_counts_the_sidecar_itself() {
        let snapshot = [entry(777, 400, "claude")];
        assert!(agents_from_parentage(&snapshot, 777).is_empty());
    }

    /// A snapshot is a moment in time: the parent may already have exited, which
    /// must not turn its child into a phantom worker that is silently dropped.
    #[test]
    fn counts_an_orphan_whose_parent_is_gone() {
        let snapshot = [entry(500, 400, "claude")];
        assert_eq!(agents_from_parentage(&snapshot, 1).len(), 1);
    }
}
