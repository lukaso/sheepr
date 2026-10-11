//! Every place `run` can fail, and the one table that names its errno and its source (issues #21,
//! #23; plan §2). `error` says what failed, `error_code` the errno behind it (a fixed name table
//! per OS, canonical spellings), `error_source` whose failure it is:
//! - `resources`: the errno is EAGAIN, ENOMEM, EMFILE, ENFILE, ENOSPC or EDQUOT, on any step
//!   (the machine could not: a retry, or freeing space, may help);
//! - `command`: the command's own exec failed with any other errno (Linux: the shim's `E` line;
//!   macOS: `posix_spawnp` of the command), and the Linux shim spawn's E2BIG (the command line's
//!   size);
//! - `usage`: a parse error, an unknown mode, an option refused here;
//! - `sheepr`: any other step (a pipe, a fork, the handshake, its own executable, /proc, a panic).
//!
//! A step before the command can run returns `PreRoot`, and `Before::end` is the ONE place that
//! turns it into the status (`error`, `error_code`, `error_source`, root "not-started") and the
//! exit code; each OS's pre-root segment is one function returning `Result<_, Before>`, so an
//! early return there cannot compile without a step.
//!
//! Debug seam `SHEEPR_TEST_FAIL_STEP=<step>[:<errno>]` (an errno name or number; EIO when left
//! out): the step's syscall runs and its result is replaced by that failure, so the real error
//! branch runs; a step that creates a process (a fork, a spawn, the command's exec) skips the
//! call instead, so no second supervisor or stray root exists.

use std::io::Write;

/// Every step that can fail (`name` is the seam's word).
// each OS builds only its own steps (the other OS's are never constructed there); the step
// table's class cell checks every step has its seam point and its sites
#[allow(dead_code)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    /// Linux: /proc is missing or another pid namespace's
    Proc,
    /// the relay's fork (sheepr started with children)
    RelayFork,
    /// an unknown `--mode`
    Mode,
    /// Linux: sheepr's own executable, for the shim
    SelfExe,
    /// Linux: the shim's pipes
    Pipe,
    /// Linux: the shim's posix_spawn
    ShimSpawn,
    /// Linux: the shim's handshake (no answer, EOF, an unexpected answer)
    Handshake,
    /// Linux: the shim could not set PR_SET_PDEATHSIG (its `F` line)
    ShimPrctl,
    /// Linux: the shim's parent is not the supervisor (its `F` line)
    ShimParent,
    /// Linux: the command's exec in the shim (its `E` line)
    Exec,
    /// macOS: posix_spawnp of the command
    Spawn,
    /// macOS: --inherit-terminal-permissions refused in a phase-1 test environment
    Inherit,
    /// a usage error of `run`
    Usage,
    /// a panic
    Panic,
    /// the kill loop panicked
    KillInternal,
    /// macOS: the root's end was seen but its wait failed
    LostWait,
    /// a release build's line guard: sheepr ended before the command and recorded no reason
    Unrecorded,
    /// --require-journal: the job journal cannot be kept before the command runs (its open, or
    /// the root's line)
    Journal,
    /// --require-journal: the root's identity cannot be read, so its line cannot be written
    RootIdentity,
    /// --require-journal, macOS: the caller blocks SIGCONT, so the root would run before its line
    ContBlocked,
    /// --require-journal: the journal went dead while the job ran (it ends the job)
    JournalDead,
}

/// What a step's failure is when its errno is not a resource one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Command,
    Usage,
    Sheepr,
}

impl Step {
    /// The one table: (seam word, kind, internal). An internal error is never moved into a note
    /// behind an earlier error (it says the tree may not be clean).
    fn row(self) -> (&'static str, Kind, bool) {
        match self {
            Step::Proc => ("proc", Kind::Sheepr, false),
            Step::RelayFork => ("relay-fork", Kind::Sheepr, false),
            Step::Mode => ("mode", Kind::Usage, false),
            Step::SelfExe => ("self-exe", Kind::Sheepr, false),
            Step::Pipe => ("pipe", Kind::Sheepr, false),
            Step::ShimSpawn => ("shim-spawn", Kind::Sheepr, false),
            Step::Handshake => ("handshake", Kind::Sheepr, false),
            Step::ShimPrctl => ("shim-prctl", Kind::Sheepr, false),
            Step::ShimParent => ("shim-parent", Kind::Sheepr, false),
            Step::Exec => ("exec", Kind::Command, false),
            Step::Spawn => ("spawn", Kind::Command, false),
            Step::Inherit => ("inherit", Kind::Usage, false),
            Step::Usage => ("usage", Kind::Usage, false),
            Step::Panic => ("panic", Kind::Sheepr, true),
            Step::KillInternal => ("kill-internal", Kind::Sheepr, true),
            Step::LostWait => ("lost-wait", Kind::Sheepr, false),
            Step::Unrecorded => ("unrecorded", Kind::Sheepr, false),
            Step::Journal => ("journal", Kind::Sheepr, false),
            Step::RootIdentity => ("root-identity", Kind::Sheepr, false),
            Step::ContBlocked => ("cont-blocked", Kind::Sheepr, false),
            Step::JournalDead => ("journal-dead", Kind::Sheepr, false),
        }
    }

    pub fn name(self) -> &'static str {
        self.row().0
    }

    pub fn internal(self) -> bool {
        self.row().2
    }

    /// `error_source` for this step's failure with `errno`.
    pub fn source(self, errno: Option<i32>) -> &'static str {
        const RESOURCES: [i32; 6] = [libc::EAGAIN, libc::ENOMEM, libc::EMFILE, libc::ENFILE, libc::ENOSPC, libc::EDQUOT];
        match (self.row().1, errno) {
            (_, Some(e)) if RESOURCES.contains(&e) => "resources",
            (Kind::Command, _) => "command",
            _ if self == Step::ShimSpawn && errno == Some(libc::E2BIG) => "command",
            (Kind::Usage, _) => "usage",
            (Kind::Sheepr, _) => "sheepr",
        }
    }

    /// The exit code of a run that ends at this step before its command ran (as phase 1 and
    /// v0.1.3 gave them).
    pub fn code(self, errno: Option<i32>) -> i32 {
        match self {
            // phase 1's posix_spawnp: no resources or too long arguments is 126; any other
            // failure is sheepr's own (it cannot run its own binary)
            Step::ShimSpawn if matches!(errno, Some(libc::EAGAIN | libc::ENOMEM | libc::E2BIG)) => 126,
            Step::Exec | Step::Spawn if errno == Some(libc::ENOENT) => 127,
            Step::Exec | Step::Spawn => 126,
            _ => 125,
        }
    }
}

/// A run that ends at `step` before its command can run: its errno, its exit code (the step's,
/// from the table) and its text (`error`, and the stderr line unless `said` already).
pub struct PreRoot {
    pub step: Step,
    pub errno: Option<i32>,
    pub code: i32,
    pub text: String,
    /// the stderr line was already written (by the shim, by the usage check)
    said: bool,
}

impl PreRoot {
    pub fn new(step: Step, errno: Option<i32>, text: impl Into<String>) -> PreRoot {
        PreRoot { step, errno, code: step.code(errno), text: text.into(), said: false }
    }

    /// The same, for a failure whose stderr line is already written.
    pub fn said(step: Step, errno: Option<i32>, text: impl Into<String>) -> PreRoot {
        PreRoot { said: true, ..PreRoot::new(step, errno, text) }
    }

    /// The status half of the one conversion: the stderr line, the error triple, and root
    /// "not-started" for certain (no later end changes it).
    pub fn record(&self) {
        if !self.said {
            crate::say!("sheepr: {}", self.text);
        }
        crate::status::set_error(self.step, self.errno, &self.text);
        crate::status::set_root_final("not-started");
    }
}

/// How a pre-root segment ends early: a step failed (`Failed`), or the process ended its own way
/// (`Ended`: a death by TERM, which says so in `trigger`, or a relay's own end, which writes no
/// status line). A bare exit code cannot be returned from that segment.
pub enum Before {
    Failed(PreRoot),
    Ended(i32),
}

impl From<PreRoot> for Before {
    fn from(p: PreRoot) -> Before {
        Before::Failed(p)
    }
}

impl Before {
    /// THE one conversion of an early end into the status and the exit code.
    pub fn end(self) -> i32 {
        match self {
            Before::Ended(code) => code,
            Before::Failed(p) => {
                p.record();
                p.code
            }
        }
    }
}

/// The shim's `F` line after its `F` (Linux): `<step> <errno>` from this version (`shim-prctl 1`)
/// or `<step>` (`shim-parent`), or an older shim's free text (`cannot set PR_SET_PDEATHSIG`; a
/// shim and a supervisor of different versions meet after an in-place upgrade): the step its
/// first word names (else the handshake's), the errno its second word gives, and the text for
/// `error`. Never panics, whatever the line.
#[cfg_attr(target_os = "macos", allow(dead_code))]
pub fn parse_f(rest: &str) -> (Step, Option<i32>, String) {
    let mut words = rest.split(' ');
    let (first, second) = (words.next().unwrap_or(""), words.next());
    match [Step::ShimPrctl, Step::ShimParent].into_iter().find(|s| s.name() == first) {
        Some(Step::ShimPrctl) => (Step::ShimPrctl, second.and_then(|e| e.parse().ok()), "the command's starter could not set PR_SET_PDEATHSIG".to_string()),
        Some(step) => (step, second.and_then(|e| e.parse().ok()), "the command's starter's parent is not this sheepr".to_string()),
        None => (Step::Handshake, None, rest.to_string()),
    }
}

/// Debug seam SHEEPR_TEST_FAIL_STEP: the errno to inject at `step`, if the seam names it.
pub fn injected(step: Step) -> Option<i32> {
    if !cfg!(debug_assertions) {
        return None;
    }
    seam_errno(&std::env::var("SHEEPR_TEST_FAIL_STEP").ok()?, step)
}

/// `<step>[:<errno>]` names `step`: its errno (a name or a number; EIO when left out).
fn seam_errno(v: &str, step: Step) -> Option<i32> {
    let (name, e) = v.split_once(':').map_or((v, None), |(n, e)| (n, Some(e)));
    (name == step.name()).then(|| e.and_then(errno_of).unwrap_or(libc::EIO))
}

/// The errnos `error_code` names on this OS, each with its canonical spelling (EAGAIN, never
/// EWOULDBLOCK; EDEADLK; EOPNOTSUPP, and on macOS also ENOTSUP, a value of its own there). The
/// names are libc's constants (the macro writes each name and its constant from one word).
macro_rules! errnos {
    ($($n:ident),* $(,)?) => { &[$((stringify!($n), libc::$n)),*] };
}

/// POSIX's errnos.
#[rustfmt::skip]
const POSIX: &[(&str, i32)] = errnos![
    E2BIG, EACCES, EADDRINUSE, EADDRNOTAVAIL, EAFNOSUPPORT, EAGAIN, EALREADY, EBADF, EBADMSG, EBUSY,
    ECANCELED, ECHILD, ECONNABORTED, ECONNREFUSED, ECONNRESET, EDEADLK, EDESTADDRREQ, EDOM, EDQUOT,
    EEXIST, EFAULT, EFBIG, EHOSTUNREACH, EIDRM, EILSEQ, EINPROGRESS, EINTR, EINVAL, EIO, EISCONN,
    EISDIR, ELOOP, EMFILE, EMLINK, EMSGSIZE, EMULTIHOP, ENAMETOOLONG, ENETDOWN, ENETRESET,
    ENETUNREACH, ENFILE, ENOBUFS, ENODATA, ENODEV, ENOENT, ENOEXEC, ENOLCK, ENOLINK, ENOMEM, ENOMSG,
    ENOPROTOOPT, ENOSPC, ENOSR, ENOSTR, ENOSYS, ENOTCONN, ENOTDIR, ENOTEMPTY, ENOTRECOVERABLE,
    ENOTSOCK, ENOTTY, ENXIO, EOPNOTSUPP, EOVERFLOW, EOWNERDEAD, EPERM, EPIPE, EPROTO,
    EPROTONOSUPPORT, EPROTOTYPE, ERANGE, EROFS, ESPIPE, ESRCH, ESTALE, ETIME, ETIMEDOUT, ETXTBSY, EXDEV,
];

/// macOS's own: ENOTSUP (45, apart from EOPNOTSUPP's 102) and the exec errors.
#[cfg(target_os = "macos")]
const OWN: &[(&str, i32)] = errnos![ENOTSUP, EBADEXEC, EBADARCH, ESHLIBVERS, EBADMACHO];
/// Linux has none of its own here (its ENOTSUP is EOPNOTSUPP's value).
#[cfg(not(target_os = "macos"))]
const OWN: &[(&str, i32)] = &[];

/// The errno's canonical name, or None for a value outside the table (the text keeps strerror).
pub fn errno_name(errno: i32) -> Option<&'static str> {
    POSIX.iter().chain(OWN).find(|&&(_, v)| v == errno).map(|&(n, _)| n)
}

/// The errno named `s` (a name from the table, or a number).
pub fn errno_of(s: &str) -> Option<i32> {
    s.parse().ok().or_else(|| POSIX.iter().chain(OWN).find(|(n, _)| *n == s).map(|&(_, v)| v))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The table: one name per value (so each errno has ONE spelling), and the spellings that
    /// matter: EAGAIN for EWOULDBLOCK, EDEADLK, EOPNOTSUPP; macOS's ENOTSUP and EOPNOTSUPP apart
    /// and its exec errors; Linux's ENOTSUP is EOPNOTSUPP's value and name. A value outside the
    /// table has no name.
    #[test]
    fn the_errno_table_has_one_canonical_name_per_value() {
        let all: Vec<(&str, i32)> = POSIX.iter().chain(OWN).copied().collect();
        let mut values: Vec<i32> = all.iter().map(|e| e.1).collect();
        values.sort();
        values.dedup();
        assert_eq!(values.len(), all.len(), "two names share a value");
        for &(n, v) in &all {
            assert_eq!(errno_name(v), Some(n), "{n}");
            assert_eq!(errno_of(n), Some(v), "{n}");
        }
        assert_eq!(errno_name(libc::EWOULDBLOCK), Some("EAGAIN"));
        assert_eq!(errno_name(libc::EDEADLK), Some("EDEADLK"));
        assert_eq!(errno_name(libc::EOPNOTSUPP), Some("EOPNOTSUPP"));
        #[cfg(target_os = "macos")]
        {
            assert_eq!((libc::ENOTSUP, libc::EOPNOTSUPP), (45, 102));
            assert_eq!(errno_name(45), Some("ENOTSUP"));
            for n in ["EBADEXEC", "EBADARCH", "ESHLIBVERS", "EBADMACHO"] {
                assert!(errno_of(n).and_then(errno_name) == Some(n), "{n}");
            }
        }
        #[cfg(target_os = "linux")]
        assert_eq!(errno_name(libc::ENOTSUP), Some("EOPNOTSUPP"));
        assert_eq!(errno_name(9999), None);
        assert_eq!(errno_name(0), None);
        assert_eq!(errno_of("42"), Some(42));
        assert_eq!(errno_of("ENOPE"), None);
    }

    /// The seam's word: `<step>[:<errno>]`, an errno by name or number, EIO when left out; another
    /// step's word, or an unknown errno name, injects nothing there (EIO for the unknown name).
    #[test]
    fn the_seam_names_a_step_and_an_errno() {
        assert_eq!(seam_errno("pipe:EMFILE", Step::Pipe), Some(libc::EMFILE));
        assert_eq!(seam_errno("pipe:24", Step::Pipe), Some(24));
        assert_eq!(seam_errno("pipe", Step::Pipe), Some(libc::EIO));
        assert_eq!(seam_errno("pipe:ENOPE", Step::Pipe), Some(libc::EIO));
        assert_eq!(seam_errno("pipe:EMFILE", Step::Spawn), None);
        assert_eq!(seam_errno("shim-spawn:EAGAIN", Step::ShimSpawn), Some(libc::EAGAIN));
        assert_eq!(seam_errno("", Step::Pipe), None);
    }

    /// Plan §2: the shim's `F` line, this version's and an older shim's, and lines no shim
    /// writes: the step, the errno (only after a step word, only a number), the text; no panic.
    #[test]
    fn the_shim_s_f_line_is_read_leniently() {
        let (s, e, t) = parse_f("shim-prctl 1");
        assert_eq!((s, e), (Step::ShimPrctl, Some(1)));
        assert!(t.contains("PR_SET_PDEATHSIG"), "{t}");
        let (s, e, t) = parse_f("shim-parent");
        assert_eq!((s, e), (Step::ShimParent, None));
        assert!(t.contains("parent"), "{t}");
        // an older shim's lines: free text, no errno
        assert_eq!(parse_f("cannot set PR_SET_PDEATHSIG"), (Step::Handshake, None, "cannot set PR_SET_PDEATHSIG".to_string()));
        assert_eq!(parse_f("its parent is not the supervisor"), (Step::Handshake, None, "its parent is not the supervisor".to_string()));
        assert_eq!(parse_f("pipe 24"), (Step::Handshake, None, "pipe 24".to_string()), "only the shim's own steps, and no errno from free text");
        assert_eq!(parse_f("1 2 3").1, None, "no errno from free text");
        assert_eq!(parse_f("shim-prctl x").1, None);
        assert_eq!(parse_f("shim-prctl 99999999999999999999").1, None);
        for odd in ["", " ", "shim-prctl", "shim-prctl  ", "\u{0}\u{ffff}", "1 2 3"] {
            let _ = parse_f(odd);
        }
    }

    /// The one source table: a resource errno is "resources" on any step; the command's exec is
    /// "command" for any other errno, and so is the shim spawn's E2BIG (only E2BIG); the usage
    /// steps are "usage"; everything else is "sheepr". The exit codes are v0.1.3's.
    #[test]
    fn the_source_table() {
        for e in [libc::EAGAIN, libc::ENOMEM, libc::EMFILE, libc::ENFILE, libc::ENOSPC, libc::EDQUOT] {
            for s in [Step::Pipe, Step::Exec, Step::Spawn, Step::ShimSpawn, Step::RelayFork, Step::Handshake, Step::LostWait] {
                assert_eq!(s.source(Some(e)), "resources", "{s:?} {e}");
            }
        }
        assert_eq!(Step::Exec.source(Some(libc::EPERM)), "command");
        assert_eq!(Step::Exec.source(Some(libc::ENOENT)), "command");
        assert_eq!(Step::Spawn.source(Some(libc::EACCES)), "command");
        assert_eq!(Step::ShimSpawn.source(Some(libc::E2BIG)), "command");
        assert_eq!(Step::ShimSpawn.source(Some(libc::ENOENT)), "sheepr");
        assert_eq!(Step::Pipe.source(Some(libc::E2BIG)), "sheepr", "E2BIG is the command's only on the shim spawn");
        for s in [Step::Usage, Step::Mode, Step::Inherit] {
            assert_eq!(s.source(None), "usage", "{s:?}");
        }
        assert_eq!(Step::Journal.source(Some(libc::ENOSPC)), "resources", "§3: a journal with no space");
        assert_eq!(Step::JournalDead.source(Some(libc::EDQUOT)), "resources");
        for s in [Step::Proc, Step::SelfExe, Step::Handshake, Step::ShimPrctl, Step::ShimParent, Step::Panic, Step::KillInternal, Step::LostWait, Step::RelayFork, Step::Journal, Step::RootIdentity, Step::ContBlocked, Step::JournalDead] {
            assert_eq!(s.source(None), "sheepr", "{s:?}");
            assert_eq!(s.source(Some(libc::EPERM)), "sheepr", "{s:?}");
        }
        assert_eq!(Step::ShimSpawn.code(Some(libc::EAGAIN)), 126);
        assert_eq!(Step::ShimSpawn.code(Some(libc::E2BIG)), 126);
        assert_eq!(Step::ShimSpawn.code(Some(libc::ENOENT)), 125);
        assert_eq!(Step::Exec.code(Some(libc::ENOENT)), 127);
        assert_eq!(Step::Exec.code(Some(libc::EACCES)), 126);
        assert_eq!(Step::Spawn.code(Some(libc::ENOENT)), 127);
        assert_eq!(Step::Spawn.code(Some(libc::EAGAIN)), 126);
        for s in [Step::Proc, Step::RelayFork, Step::Mode, Step::SelfExe, Step::Pipe, Step::Handshake, Step::Inherit, Step::Usage] {
            assert_eq!(s.code(Some(libc::EIO)), 125, "{s:?}");
        }
    }
}
