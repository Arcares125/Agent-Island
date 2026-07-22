//! macOS and other Unix hosts.
//!
//! Behaviour here is unchanged from before the port: the same directories, the
//! same `ps` parsing, the same Unix-domain socket guarded by owner-only file
//! permissions and a `getpeereid` check.

use std::path::PathBuf;
use std::process::Command;

pub fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

/// Join a user-relative path under the home directory, or `None` without one.
fn under_home(segments: &[&str]) -> Option<PathBuf> {
    let mut path = home_dir()?;
    path.extend(segments);
    Some(path)
}

/// Where the Claude status-line usage cache lives.
pub fn cache_dir() -> Option<PathBuf> {
    under_home(&["Library", "Caches", "com.agentisland.AgentIsland"])
}

/// Where the answer socket lives. Application Support rather than a temp dir so
/// it is not world-traversable and does not evaporate on reboot cleanup.
fn data_dir() -> Option<PathBuf> {
    under_home(&["Library", "Application Support", "AgentIsland"])
}

pub fn scan_processes() -> Vec<crate::DetectedAgent> {
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

/// One `ps` line to an agent, or `None` for everything that is not one.
///
/// Unix gets to filter on argv, which is more precise than the parentage
/// heuristic Windows falls back to, so it keeps doing that.
fn parse_process_line(line: &str) -> Option<crate::DetectedAgent> {
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

    Some(crate::DetectedAgent { provider, pid })
}

/// The answer transport: a Unix-domain socket in the app's data directory.
pub mod ipc {
    use std::io::{self, Read, Write};
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::io::AsRawFd;
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::path::PathBuf;
    use std::time::Duration;

    /// `getpeereid` tells us who is on the other end. Declared by hand because
    /// the project takes no third-party crates.
    mod ffi {
        use std::os::raw::c_int;

        unsafe extern "C" {
            pub fn getpeereid(fd: c_int, euid: *mut u32, egid: *mut u32) -> c_int;
            pub fn geteuid() -> u32;
        }
    }

    fn socket_path() -> Option<PathBuf> {
        Some(super::data_dir()?.join("ask.sock"))
    }

    /// One connection between a blocked hook helper and the island.
    pub struct AskStream(UnixStream);

    impl AskStream {
        pub fn connect() -> Option<Self> {
            UnixStream::connect(socket_path()?).ok().map(Self)
        }

        pub fn set_read_timeout(&mut self, timeout: Duration) -> bool {
            self.0.set_read_timeout(Some(timeout)).is_ok()
        }

        pub fn set_write_timeout(&mut self, timeout: Duration) -> bool {
            self.0.set_write_timeout(Some(timeout)).is_ok()
        }

        /// File permissions already restrict the socket, but a peer check is
        /// what actually proves the caller is us rather than something that
        /// inherited the descriptor.
        pub fn peer_is_current_user(&self) -> bool {
            let mut uid = 0_u32;
            let mut gid = 0_u32;
            let result = unsafe { ffi::getpeereid(self.0.as_raw_fd(), &mut uid, &mut gid) };
            result == 0 && uid == unsafe { ffi::geteuid() }
        }
    }

    impl Read for AskStream {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            self.0.read(buffer)
        }
    }

    impl Write for AskStream {
        fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
            self.0.write(buffer)
        }

        fn flush(&mut self) -> io::Result<()> {
            self.0.flush()
        }
    }

    /// The island's end of the transport.
    pub struct AskListener(UnixListener);

    impl AskListener {
        /// `None` when the endpoint cannot be claimed — another island already
        /// owns it, or the directory is not writable.
        pub fn bind() -> Option<Self> {
            let path = socket_path()?;
            let directory = path.parent()?.to_path_buf();
            std::fs::create_dir_all(&directory).ok()?;
            // Owner-only: nobody else on a shared Mac may enumerate or connect.
            let _ =
                std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700));

            // A socket left behind by a crashed island would block the bind.
            if path.exists() {
                if UnixStream::connect(&path).is_ok() {
                    return None; // A live island already owns it.
                }
                let _ = std::fs::remove_file(&path);
            }

            let listener = UnixListener::bind(&path).ok()?;
            let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
            Some(Self(listener))
        }

        /// Block until a helper connects. `None` only on a fatal accept error,
        /// which ends the serving loop.
        pub fn accept(&mut self) -> Option<AskStream> {
            loop {
                match self.0.accept() {
                    Ok((stream, _)) => return Some(AskStream(stream)),
                    // A single refused connection must not take the island's
                    // answering down with it.
                    Err(error) if error.kind() == io::ErrorKind::ConnectionAborted => continue,
                    Err(_) => return None,
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_codex_cli() {
        assert_eq!(
            parse_process_line("  123 /opt/homebrew/bin/codex --profile work"),
            Some(crate::DetectedAgent {
                provider: "codex",
                pid: 123
            })
        );
    }

    #[test]
    fn detects_claude_cli() {
        assert_eq!(
            parse_process_line("456 /Users/test/.local/bin/claude"),
            Some(crate::DetectedAgent {
                provider: "claude",
                pid: 456
            })
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
}
