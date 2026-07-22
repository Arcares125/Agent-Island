//! Windows.
//!
//! Every Win32 call is declared by hand, the same way `getpeereid` is on the
//! Unix side, because the project takes no third-party crates — not even the
//! Microsoft-published `windows-sys`. The surface is deliberately small: a
//! process snapshot, three directory lookups, and one named pipe.
//!
//! The pipe is the Windows answer to the Unix socket, and it is held to the
//! same two guarantees: only the current user can reach it, and every failure
//! is silent so a blocked agent falls back to its own terminal prompt.

use std::ffi::c_void;
use std::path::PathBuf;

type Handle = *mut c_void;

const INVALID_HANDLE_VALUE: Handle = -1_isize as Handle;

// Error codes we actually branch on.
const ERROR_INSUFFICIENT_BUFFER: u32 = 122;
const ERROR_BROKEN_PIPE: u32 = 109;
const ERROR_PIPE_NOT_CONNECTED: u32 = 233;
const ERROR_IO_PENDING: u32 = 997;
const ERROR_PIPE_CONNECTED: u32 = 535;

const WAIT_OBJECT_0: u32 = 0;
const INFINITE: u32 = 0xFFFF_FFFF;

const TOKEN_QUERY: u32 = 0x0008;
/// `TOKEN_INFORMATION_CLASS::TokenUser`.
const TOKEN_USER_CLASS: u32 = 1;
const SDDL_REVISION_1: u32 = 1;

const TH32CS_SNAPPROCESS: u32 = 0x0000_0002;
const MAX_PATH: usize = 260;

#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetLastError() -> u32;
    fn CloseHandle(object: Handle) -> i32;
    fn GetCurrentProcess() -> Handle;
    fn GetCurrentThread() -> Handle;
    fn LocalFree(memory: *mut c_void) -> *mut c_void;

    fn CreateNamedPipeW(
        name: *const u16,
        open_mode: u32,
        pipe_mode: u32,
        max_instances: u32,
        out_buffer_size: u32,
        in_buffer_size: u32,
        default_timeout: u32,
        security_attributes: *mut SecurityAttributes,
    ) -> Handle;
    fn ConnectNamedPipe(pipe: Handle, overlapped: *mut Overlapped) -> i32;
    fn DisconnectNamedPipe(pipe: Handle) -> i32;
    fn CreateFileW(
        name: *const u16,
        desired_access: u32,
        share_mode: u32,
        security_attributes: *mut SecurityAttributes,
        creation_disposition: u32,
        flags_and_attributes: u32,
        template: Handle,
    ) -> Handle;

    fn ReadFile(
        file: Handle,
        buffer: *mut u8,
        to_read: u32,
        read: *mut u32,
        overlapped: *mut Overlapped,
    ) -> i32;
    fn WriteFile(
        file: Handle,
        buffer: *const u8,
        to_write: u32,
        written: *mut u32,
        overlapped: *mut Overlapped,
    ) -> i32;
    fn CancelIo(file: Handle) -> i32;
    fn GetOverlappedResult(
        file: Handle,
        overlapped: *mut Overlapped,
        transferred: *mut u32,
        wait: i32,
    ) -> i32;

    fn CreateEventW(
        security_attributes: *mut SecurityAttributes,
        manual_reset: i32,
        initial_state: i32,
        name: *const u16,
    ) -> Handle;
    fn ResetEvent(event: Handle) -> i32;
    fn WaitForSingleObject(object: Handle, milliseconds: u32) -> u32;

    fn CreateToolhelp32Snapshot(flags: u32, process_id: u32) -> Handle;
    fn Process32FirstW(snapshot: Handle, entry: *mut ProcessEntry32W) -> i32;
    fn Process32NextW(snapshot: Handle, entry: *mut ProcessEntry32W) -> i32;
}

#[link(name = "advapi32")]
unsafe extern "system" {
    fn OpenProcessToken(process: Handle, desired_access: u32, token: *mut Handle) -> i32;
    fn OpenThreadToken(
        thread: Handle,
        desired_access: u32,
        open_as_self: i32,
        token: *mut Handle,
    ) -> i32;
    fn GetTokenInformation(
        token: Handle,
        information_class: u32,
        information: *mut c_void,
        length: u32,
        return_length: *mut u32,
    ) -> i32;
    fn ImpersonateNamedPipeClient(pipe: Handle) -> i32;
    fn RevertToSelf() -> i32;
    fn ConvertSidToStringSidW(sid: *mut c_void, string_sid: *mut *mut u16) -> i32;
    fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
        string_security_descriptor: *const u16,
        revision: u32,
        security_descriptor: *mut *mut c_void,
        size: *mut u32,
    ) -> i32;
}

#[repr(C)]
struct SecurityAttributes {
    length: u32,
    security_descriptor: *mut c_void,
    inherit_handle: i32,
}

#[repr(C)]
struct Overlapped {
    internal: usize,
    internal_high: usize,
    offset: u32,
    offset_high: u32,
    event: Handle,
}

impl Overlapped {
    fn with_event(event: Handle) -> Self {
        Self {
            internal: 0,
            internal_high: 0,
            offset: 0,
            offset_high: 0,
            event,
        }
    }
}

#[repr(C)]
struct ProcessEntry32W {
    size: u32,
    usage: u32,
    process_id: u32,
    default_heap_id: usize,
    module_id: u32,
    threads: u32,
    parent_process_id: u32,
    priority_class_base: i32,
    flags: u32,
    executable: [u16; MAX_PATH],
}

#[repr(C)]
struct SidAndAttributes {
    sid: *mut c_void,
    attributes: u32,
}

#[repr(C)]
struct TokenUser {
    user: SidAndAttributes,
}

// ───────────────────────────── wide strings ─────────────────────────────

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Read a NUL-terminated UTF-16 string, stopping at `limit` units so a buffer
/// the OS did not terminate cannot run away.
fn from_wide(pointer: *const u16, limit: usize) -> String {
    let mut units = Vec::new();
    for offset in 0..limit {
        let unit = unsafe { *pointer.add(offset) };
        if unit == 0 {
            break;
        }
        units.push(unit);
    }
    String::from_utf16_lossy(&units)
}

// ───────────────────────────── directories ─────────────────────────────

pub fn home_dir() -> Option<PathBuf> {
    std::env::var_os("USERPROFILE").map(PathBuf::from)
}

/// `%LOCALAPPDATA%` is the Windows analogue of `~/Library`: per-user, already
/// ACL'd to the owner, and excluded from roaming profiles.
fn local_app_data() -> Option<PathBuf> {
    std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .or_else(|| Some(home_dir()?.join("AppData").join("Local")))
}

pub fn cache_dir() -> Option<PathBuf> {
    Some(local_app_data()?.join("AgentIsland").join("Cache"))
}

// ───────────────────────────── identity ─────────────────────────────

/// The string form of a token's user SID, e.g. `S-1-5-21-…-1001`.
///
/// String comparison stands in for `EqualSid`: a SID's string form is canonical,
/// so comparing strings decides identity exactly as the API would, without
/// having to keep the raw SID alive past the buffer that holds it.
fn sid_string(token: Handle) -> Option<String> {
    let mut needed = 0_u32;
    unsafe { GetTokenInformation(token, TOKEN_USER_CLASS, std::ptr::null_mut(), 0, &mut needed) };
    if unsafe { GetLastError() } != ERROR_INSUFFICIENT_BUFFER || needed == 0 {
        return None;
    }

    // TOKEN_USER leads with a pointer, so the buffer has to be pointer-aligned;
    // a Vec<u8> would only be byte-aligned.
    let words = (needed as usize).div_ceil(std::mem::size_of::<u64>());
    let mut buffer = vec![0_u64; words.max(1)];
    let ok = unsafe {
        GetTokenInformation(
            token,
            TOKEN_USER_CLASS,
            buffer.as_mut_ptr().cast(),
            needed,
            &mut needed,
        )
    };
    if ok == 0 {
        return None;
    }

    let token_user = buffer.as_ptr().cast::<TokenUser>();
    let sid = unsafe { (*token_user).user.sid };
    if sid.is_null() {
        return None;
    }

    let mut raw: *mut u16 = std::ptr::null_mut();
    if unsafe { ConvertSidToStringSidW(sid, &mut raw) } == 0 || raw.is_null() {
        return None;
    }
    let text = from_wide(raw, 512);
    unsafe { LocalFree(raw.cast()) };
    Some(text)
}

/// The SID of the user this process runs as.
fn current_user_sid() -> Option<String> {
    let mut token: Handle = std::ptr::null_mut();
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
        return None;
    }
    let sid = sid_string(token);
    unsafe { CloseHandle(token) };
    sid
}

// ───────────────────────────── processes ─────────────────────────────

pub fn scan_processes() -> Vec<crate::DetectedAgent> {
    super::agents_from_parentage(&snapshot_processes(), std::process::id())
}

/// Every running process, as pid, parent pid, and executable name.
///
/// Toolhelp gives no command line — that would mean opening each process and
/// reading its PEB — which is why the classifier upstream leans on parentage.
fn snapshot_processes() -> Vec<super::ProcessEntry> {
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
    if snapshot == INVALID_HANDLE_VALUE || snapshot.is_null() {
        return Vec::new();
    }

    let mut entries = Vec::new();
    let mut raw = ProcessEntry32W {
        size: std::mem::size_of::<ProcessEntry32W>() as u32,
        usage: 0,
        process_id: 0,
        default_heap_id: 0,
        module_id: 0,
        threads: 0,
        parent_process_id: 0,
        priority_class_base: 0,
        flags: 0,
        executable: [0; MAX_PATH],
    };

    let mut more = unsafe { Process32FirstW(snapshot, &mut raw) };
    while more != 0 {
        entries.push(super::ProcessEntry {
            pid: raw.process_id,
            parent_pid: raw.parent_process_id,
            executable: super::executable_stem(&from_wide(raw.executable.as_ptr(), MAX_PATH)),
        });
        more = unsafe { Process32NextW(snapshot, &mut raw) };
    }

    unsafe { CloseHandle(snapshot) };
    entries
}

// ───────────────────────────── the transport ─────────────────────────────

/// The answer transport: a named pipe reachable only by the current user.
pub mod ipc {
    use super::*;
    use std::io::{self, Read, Write};
    use std::time::Duration;

    const PIPE_ACCESS_DUPLEX: u32 = 0x0000_0003;
    const FILE_FLAG_OVERLAPPED: u32 = 0x4000_0000;
    const FILE_FLAG_FIRST_PIPE_INSTANCE: u32 = 0x0008_0000;
    const PIPE_TYPE_BYTE: u32 = 0x0000_0000;
    const PIPE_READMODE_BYTE: u32 = 0x0000_0000;
    const PIPE_WAIT: u32 = 0x0000_0000;
    /// Refuses connections arriving over SMB from another machine. A local
    /// answer channel has no business being reachable from the network.
    const PIPE_REJECT_REMOTE_CLIENTS: u32 = 0x0000_0008;
    const PIPE_UNLIMITED_INSTANCES: u32 = 255;

    const GENERIC_READ: u32 = 0x8000_0000;
    const GENERIC_WRITE: u32 = 0x4000_0000;
    const OPEN_EXISTING: u32 = 3;

    const PIPE_BUFFER_BYTES: u32 = 64 * 1024;

    /// Per-user so two people signed into one machine cannot collide on, or
    /// reach, each other's pipe. The SID is already canonical and contains only
    /// characters a pipe name allows.
    fn pipe_name() -> Option<Vec<u16>> {
        Some(wide(&format!(
            r"\\.\pipe\AgentIsland.ask.{}",
            current_user_sid()?
        )))
    }

    /// A DACL naming exactly one trustee: us.
    ///
    /// `D:P` blocks inherited entries, and the single `(A;;GA;;;<sid>)` ace
    /// grants the current user full control. This is the counterpart of the
    /// `0600`/`0700` modes the Unix socket sets, and slightly stricter — not
    /// even LocalSystem is listed.
    struct SecurityDescriptor(*mut c_void);

    impl SecurityDescriptor {
        fn owner_only() -> Option<Self> {
            let sddl = wide(&format!("D:P(A;;GA;;;{})", current_user_sid()?));
            let mut descriptor: *mut c_void = std::ptr::null_mut();
            let ok = unsafe {
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    sddl.as_ptr(),
                    SDDL_REVISION_1,
                    &mut descriptor,
                    std::ptr::null_mut(),
                )
            };
            (ok != 0 && !descriptor.is_null()).then_some(Self(descriptor))
        }

        fn attributes(&self) -> SecurityAttributes {
            SecurityAttributes {
                length: std::mem::size_of::<SecurityAttributes>() as u32,
                security_descriptor: self.0,
                inherit_handle: 0,
            }
        }
    }

    impl Drop for SecurityDescriptor {
        fn drop(&mut self) {
            unsafe { LocalFree(self.0) };
        }
    }

    fn last_error_to_io(context: &'static str) -> io::Error {
        let code = unsafe { GetLastError() };
        io::Error::new(io::ErrorKind::Other, format!("{context} (win32 {code})"))
    }

    fn milliseconds(timeout: Option<Duration>) -> u32 {
        timeout.map_or(INFINITE, |value| {
            u32::try_from(value.as_millis()).unwrap_or(INFINITE)
        })
    }

    /// One connection between a blocked hook helper and the island.
    ///
    /// Holds its own event object because every read and write is overlapped —
    /// which is the only way a synchronous pipe handle can honour the timeouts
    /// the Unix socket gets from `SO_RCVTIMEO`.
    pub struct AskStream {
        pipe: Handle,
        event: Handle,
        read_timeout: Option<Duration>,
        write_timeout: Option<Duration>,
        /// The island's end must disconnect the instance; a client's must not.
        server_side: bool,
    }

    // The pipe is handed to a worker thread per connection and never touched
    // from two threads at once.
    unsafe impl Send for AskStream {}

    impl AskStream {
        fn adopt(pipe: Handle, server_side: bool) -> Option<Self> {
            let event = unsafe {
                CreateEventW(std::ptr::null_mut(), 1, 0, std::ptr::null())
            };
            if event.is_null() {
                unsafe { CloseHandle(pipe) };
                return None;
            }
            Some(Self {
                pipe,
                event,
                read_timeout: None,
                write_timeout: None,
                server_side,
            })
        }

        pub fn connect() -> Option<Self> {
            let name = pipe_name()?;
            let pipe = unsafe {
                CreateFileW(
                    name.as_ptr(),
                    GENERIC_READ | GENERIC_WRITE,
                    0,
                    std::ptr::null_mut(),
                    OPEN_EXISTING,
                    FILE_FLAG_OVERLAPPED,
                    std::ptr::null_mut(),
                )
            };
            if pipe == INVALID_HANDLE_VALUE || pipe.is_null() {
                return None;
            }
            Self::adopt(pipe, false)
        }

        /// Unlike a socket option, this is only remembered — it is applied at
        /// each overlapped wait below.
        pub fn set_read_timeout(&mut self, timeout: Duration) -> bool {
            self.read_timeout = Some(timeout);
            true
        }

        pub fn set_write_timeout(&mut self, timeout: Duration) -> bool {
            self.write_timeout = Some(timeout);
            true
        }

        /// Whether the process on the other end runs as the same user.
        ///
        /// The DACL already restricts the pipe, but impersonating the client and
        /// reading its token is what actually proves who connected — the direct
        /// counterpart of `getpeereid` on Unix.
        pub fn peer_is_current_user(&self) -> bool {
            if !self.server_side {
                return true; // Only the listening side has a client to inspect.
            }
            if unsafe { ImpersonateNamedPipeClient(self.pipe) } == 0 {
                return false;
            }

            let mut token: Handle = std::ptr::null_mut();
            let opened =
                unsafe { OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, 1, &mut token) };
            let client = (opened != 0).then(|| sid_string(token)).flatten();
            if opened != 0 {
                unsafe { CloseHandle(token) };
            }

            // Impersonation must be dropped on every path; leaving the thread
            // running as somebody else would be far worse than refusing.
            unsafe { RevertToSelf() };

            match (client, current_user_sid()) {
                (Some(client), Some(ours)) => client.eq_ignore_ascii_case(&ours),
                _ => false,
            }
        }

        /// Run one overlapped operation to completion, or to its timeout.
        fn complete(
            &self,
            started: i32,
            overlapped: &mut Overlapped,
            timeout: Option<Duration>,
            context: &'static str,
        ) -> io::Result<usize> {
            if started == 0 {
                let error = unsafe { GetLastError() };
                // The peer closing the pipe is end-of-stream, not a failure —
                // without this a `read_line` at EOF would surface as an error.
                if error == ERROR_BROKEN_PIPE || error == ERROR_PIPE_NOT_CONNECTED {
                    return Ok(0);
                }
                if error != ERROR_IO_PENDING {
                    return Err(last_error_to_io(context));
                }
                if unsafe { WaitForSingleObject(self.event, milliseconds(timeout)) }
                    != WAIT_OBJECT_0
                {
                    unsafe { CancelIo(self.pipe) };
                    // Let the cancellation settle before the buffer goes away.
                    let mut discarded = 0_u32;
                    unsafe {
                        GetOverlappedResult(self.pipe, overlapped, &mut discarded, 1);
                    }
                    return Err(io::Error::new(io::ErrorKind::TimedOut, context));
                }
            }

            let mut transferred = 0_u32;
            let ok =
                unsafe { GetOverlappedResult(self.pipe, overlapped, &mut transferred, 1) };
            if ok == 0 {
                let error = unsafe { GetLastError() };
                if error == ERROR_BROKEN_PIPE || error == ERROR_PIPE_NOT_CONNECTED {
                    return Ok(0);
                }
                return Err(last_error_to_io(context));
            }
            Ok(transferred as usize)
        }
    }

    impl Drop for AskStream {
        fn drop(&mut self) {
            if self.server_side {
                unsafe { DisconnectNamedPipe(self.pipe) };
            }
            unsafe {
                CloseHandle(self.pipe);
                CloseHandle(self.event);
            }
        }
    }

    impl Read for AskStream {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            if buffer.is_empty() {
                return Ok(0);
            }
            unsafe { ResetEvent(self.event) };
            let mut overlapped = Overlapped::with_event(self.event);
            let started = unsafe {
                ReadFile(
                    self.pipe,
                    buffer.as_mut_ptr(),
                    u32::try_from(buffer.len()).unwrap_or(u32::MAX),
                    std::ptr::null_mut(),
                    &mut overlapped,
                )
            };
            self.complete(started, &mut overlapped, self.read_timeout, "pipe read")
        }
    }

    impl Write for AskStream {
        fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
            if buffer.is_empty() {
                return Ok(0);
            }
            unsafe { ResetEvent(self.event) };
            let mut overlapped = Overlapped::with_event(self.event);
            let started = unsafe {
                WriteFile(
                    self.pipe,
                    buffer.as_ptr(),
                    u32::try_from(buffer.len()).unwrap_or(u32::MAX),
                    std::ptr::null_mut(),
                    &mut overlapped,
                )
            };
            let written =
                self.complete(started, &mut overlapped, self.write_timeout, "pipe write")?;
            if written == 0 {
                return Err(io::Error::from(io::ErrorKind::BrokenPipe));
            }
            Ok(written)
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    /// The island's end of the transport.
    ///
    /// A named pipe has no listening socket to hand connections out of: each
    /// client needs its own instance. So one idle instance is kept ready, given
    /// away once a client attaches, and immediately replaced.
    pub struct AskListener {
        descriptor: SecurityDescriptor,
        idle: Handle,
    }

    unsafe impl Send for AskListener {}

    impl AskListener {
        /// `None` when the endpoint cannot be claimed — another island already
        /// owns it, or the user's SID could not be read.
        pub fn bind() -> Option<Self> {
            let descriptor = SecurityDescriptor::owner_only()?;
            // FIRST_PIPE_INSTANCE fails outright if the name is already taken,
            // which is exactly the "a live island already owns it" check the
            // Unix side performs by connecting to the stale socket.
            let idle = create_instance(&descriptor, true)?;
            Some(Self { descriptor, idle })
        }

        /// Block until a helper connects. `None` only on a fatal error, which
        /// ends the serving loop.
        pub fn accept(&mut self) -> Option<AskStream> {
            loop {
                let connected = self.wait_for_client(self.idle);
                // Replace the instance before handing this one over, so the next
                // helper is never told the pipe is missing.
                let replacement = create_instance(&self.descriptor, false)?;
                let claimed = std::mem::replace(&mut self.idle, replacement);

                if connected {
                    return AskStream::adopt(claimed, true);
                }
                unsafe {
                    DisconnectNamedPipe(claimed);
                    CloseHandle(claimed);
                }
                // Without this, a connect that keeps failing for a reason we do
                // not recognise would spin this loop at full tilt for the life
                // of a background app that is supposed to cost nothing.
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
        }

        fn wait_for_client(&self, pipe: Handle) -> bool {
            let event = unsafe { CreateEventW(std::ptr::null_mut(), 1, 0, std::ptr::null()) };
            if event.is_null() {
                return false;
            }
            let mut overlapped = Overlapped::with_event(event);
            let started = unsafe { ConnectNamedPipe(pipe, &mut overlapped) };

            let connected = if started != 0 {
                true
            } else {
                match unsafe { GetLastError() } {
                    // The client won the race and attached before we asked.
                    ERROR_PIPE_CONNECTED => true,
                    ERROR_IO_PENDING => {
                        unsafe { WaitForSingleObject(event, INFINITE) == WAIT_OBJECT_0 }
                    }
                    _ => false,
                }
            };

            unsafe { CloseHandle(event) };
            connected
        }
    }

    impl Drop for AskListener {
        fn drop(&mut self) {
            unsafe { CloseHandle(self.idle) };
        }
    }

    fn create_instance(descriptor: &SecurityDescriptor, first: bool) -> Option<Handle> {
        let name = pipe_name()?;
        let mut attributes = descriptor.attributes();
        let open_mode = PIPE_ACCESS_DUPLEX
            | FILE_FLAG_OVERLAPPED
            | if first { FILE_FLAG_FIRST_PIPE_INSTANCE } else { 0 };

        let pipe = unsafe {
            CreateNamedPipeW(
                name.as_ptr(),
                open_mode,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                PIPE_UNLIMITED_INSTANCES,
                PIPE_BUFFER_BYTES,
                PIPE_BUFFER_BYTES,
                0,
                &mut attributes,
            )
        };
        (pipe != INVALID_HANDLE_VALUE && !pipe.is_null()).then_some(pipe)
    }
}
