//! `--status-fd N` (PLAN.md §3.1; PHASE2.md §1 decision 8): one JSON line, written once at the
//! end, by the supervisor only (a relay drops the fd), within IDLE and CAP (issue #14). Fields: `v`, `job`, `root` (`exited`,
//! `signaled`, `not-started`), `root_code`, `root_signal`, `code`, `trigger` (null, `term`,
//! `timeout`, `cap`), `trigger_at` (ms since start), `deadline_missed`, `killed`
//! (`[{pid, cmd, escaped}]`, escaped: null | `setsid` | `reparented`), `survivors`, `tracking`,
//! `degraded`, `error`, `error_code`, `error_source`, `notes`. The fd is set CLOEXEC once the
//! supervisor runs (after the macOS SETEXEC), so the job never holds it. The same record feeds the
//! kill report on stderr (PLAN.md §10.4).
//!
//! Why a run ended (issues #21, #23): ONE setter writes `error`, `error_code` (the errno's name
//! from crate::steps' table, null without one) and `error_source` (`command`, `resources`,
//! `sheepr`, `usage`: crate::steps' one table) together; the first error wins and later ones are
//! notes `also: ...`, except that an internal error (a panic, the kill loop's) is never a note
//! behind another. Every end before the command (crate::steps::PreRoot) and every TERM (`trigger`
//! "term") says why, and the line's guard keeps it so: root "not-started" with neither an error
//! nor a trigger panics in a debug build and gets "sheepr ended before the command started and
//! recorded no reason" in a release build. `root` is "not-started" only before the command may
//! run (`root_may_run`: the Linux go byte; macOS, the stop signals' unblock or a spawn that is not
//! suspended), so a panic says it right too.
//!
//! The root's own end (issue #17): one recorder per OS takes the wait status of every reap of
//! the root (Linux `wait_any`, the one `waitpid(-1, ...)`; macOS `reap_root`, the one wait on
//! the root), and the record keeps the first one for the root's pid. `root_code` is its exit code
//! when it exited, `root_signal` the number of the signal that ended it; `root` follows them
//! ("exited" exactly with `root_code`, "signaled" exactly with `root_signal`). Both are null when
//! the command never ran (`root` "not-started": an exec that failed clears and blocks them) and
//! when its end was not observed (`root` "signaled"): a macOS wait on the root that failed once
//! its exit was seen (a lost wait: exit 125, `error` names it, nothing made up; a failed poll of
//! a running root is never an end), a root still alive after the kill (the macOS reap after the
//! kill never waits on a root whose identity still reads, as a setuid root the scan cannot see),
//! a root that the macOS reap after the kill saw exiting but could not reap within its 1 s
//! (`root-after-kill unseen` in the debug trace), and `--mode root-disclaim`'s TERM path, which
//! does not reap the root. Under a trigger they are the root's end whoever caused it: its own end
//! (an exit as the TERM was taken, or during the grace), the caller's signal (a TERM to the whole
//! process group reaches the root too), or sheepr's kill; not the command's own verdict on the
//! job.

use std::io::Write;
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub struct Killed {
    pub pid: i32,
    pub cmd: String,
    pub escaped: Option<&'static str>,
}

struct Status {
    fd: Option<i32>,
    start: Option<Instant>,
    job: Option<String>,
    root: &'static str,
    /// set once the root's end is known for certain (an exec that failed): later guesses keep off
    root_final: bool,
    root_pid: i32,
    /// the command may have run (plan §2, round 3 N3): set just before the point where it can
    /// (the Linux go byte; macOS: the stop signals' unblock, or a spawn that is not suspended);
    /// before it, an end is "not-started"
    root_may_run: bool,
    /// the root's wait status, as the recorder took it (#17)
    root_end: Option<libc::c_int>,
    trigger: Option<(&'static str, u128)>,
    deadline_missed: bool,
    killed: Vec<Killed>,
    survivors: Vec<i32>,
    tracking: &'static str,
    degraded: Option<String>,
    error: Option<String>,
    /// the errno name behind `error` (crate::steps' table), and whose failure it is
    error_code: Option<&'static str>,
    error_source: Option<&'static str>,
    /// `error` is an internal error (never moved into a note behind another)
    error_internal: bool,
    quiet: bool,
    notes: Vec<String>,
}

impl Status {
    const fn new() -> Status {
        Status {
            fd: None,
            start: None,
            job: None,
            root: "not-started",
            root_final: false,
            root_pid: 0,
            root_may_run: false,
            root_end: None,
            trigger: None,
            deadline_missed: false,
            killed: Vec::new(),
            survivors: Vec::new(),
            tracking: "none",
            degraded: None,
            error: None,
            error_code: None,
            error_source: None,
            error_internal: false,
            quiet: false,
            notes: Vec::new(),
        }
    }

    /// The recorder's record (#17): the wait status `st` of a reaped `pid`, kept when `pid` is the
    /// root's and nothing was recorded before (the first wins: a later reap at that pid is a
    /// reused pid's), and the root's end is not final (an exec that failed). Only an exit or a
    /// death by signal is an end.
    fn record_root_end(&mut self, pid: i32, st: libc::c_int) {
        let end = libc::WIFEXITED(st) || libc::WIFSIGNALED(st);
        if end && pid > 0 && pid == self.root_pid && !self.root_final && self.root_end.is_none() {
            self.root_end = Some(st);
        }
    }

    /// The first trigger wins (PLAN.md §3.1 exit-code order); a later, other one is a note.
    fn set_trigger(&mut self, t: &'static str) {
        let at = self.start.map_or(0, |st| st.elapsed().as_millis());
        match self.trigger {
            None => self.trigger = Some((t, at)),
            Some((first, _)) if first != t => self.notes.push(format!("{t} after the trigger")),
            _ => {}
        }
    }

    /// `t` as the trigger only when none is set (never a note behind another trigger).
    fn set_trigger_if_none(&mut self, t: &'static str) {
        if self.trigger.is_none() {
            self.set_trigger(t);
        }
    }

    /// The root's end, known for certain: it clears what the recorder took and keeps it off.
    /// The one setter of `error`, `error_code` and `error_source` (plan §2): the three are set
    /// together from the step's row of crate::steps' table. The first error wins and a later one
    /// becomes a note `also: <text>`, except that an internal error (the tree may not be clean)
    /// is never a note behind an earlier one: it takes `error`, and the earlier one becomes the
    /// note.
    fn set_error(&mut self, step: crate::steps::Step, errno: Option<i32>, text: &str) {
        let taken = match &self.error {
            None => true,
            Some(old) if step.internal() && !self.error_internal => {
                self.notes.push(format!("also: {old}"));
                true
            }
            Some(_) => false,
        };
        if !taken {
            self.notes.push(format!("also: {text}"));
            return;
        }
        self.error = Some(text.to_string());
        self.error_code = errno.and_then(crate::steps::errno_name);
        self.error_source = Some(step.source(errno));
        self.error_internal = step.internal();
    }

    fn set_root_final(&mut self, root: &'static str) {
        self.root = root;
        self.root_final = true;
        self.root_end = None;
    }

    /// (`root`, `root_code`, `root_signal`): what the recorder took (option A: "exited" exactly
    /// with a code, "signaled" exactly with a signal); else, with both null, the final end
    /// ("not-started": the command never ran), "signaled" once the command may have run (its end
    /// not observed), or "not-started" before that (also after a panic there).
    fn root_fields(&self) -> (&'static str, Option<i32>, Option<i32>) {
        match self.root_end {
            Some(st) if libc::WIFSIGNALED(st) => ("signaled", None, Some(libc::WTERMSIG(st))),
            Some(st) => ("exited", Some(libc::WEXITSTATUS(st)), None),
            None if self.root_final => (self.root, None, None),
            None if self.root_may_run => ("signaled", None, None),
            None => ("not-started", None, None),
        }
    }
}

static S: Mutex<Status> = Mutex::new(Status::new());

fn with<R>(f: impl FnOnce(&mut Status) -> R) -> R {
    f(&mut S.lock().unwrap_or_else(|e| e.into_inner()))
}

pub fn start() {
    with(|s| s.start = Some(Instant::now()));
}
pub fn set_fd(fd: i32) {
    with(|s| s.fd = Some(fd));
}
/// The supervisor runs now (after any SETEXEC): the job must not inherit the status fd.
pub fn cloexec() {
    with(|s| {
        if let Some(fd) = s.fd {
            unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
        }
    });
}
pub fn set_job(job: Option<String>) {
    with(|s| s.job = job);
}
/// The command may run from now on (plan §2): `root` is no longer "not-started" by default.
pub fn set_root_may_run() {
    with(|s| s.root_may_run = true);
}
/// The root's end, known for certain; nothing later changes it (a step before the command ran:
/// `crate::steps::PreRoot::record`).
pub fn set_root_final(root: &'static str) {
    with(|s| s.set_root_final(root));
}
pub fn set_root_pid(pid: i32) {
    with(|s| s.root_pid = pid);
}
/// The recorder (#17): every reap of the root goes through it (Linux: `wait_any`, the one
/// `waitpid(-1, ...)`; macOS: `reap_root`, the one wait on the root), so the root's end is in the
/// record whichever pass reaped it. The first status for the root's pid wins.
pub fn record_root_end(pid: i32, st: libc::c_int) {
    with(|s| s.record_root_end(pid, st));
}
pub fn root_pid() -> i32 {
    with(|s| s.root_pid)
}
/// The first trigger wins (PLAN.md §3.1 exit-code order); a later one is a note.
pub fn set_trigger(t: &'static str) {
    with(|s| s.set_trigger(t));
}
/// A death by TERM's own trigger (`die_by_term`): "term" only when no trigger is set.
pub fn set_trigger_if_none(t: &'static str) {
    with(|s| s.set_trigger_if_none(t));
}
/// The trigger recorded, if any.
pub fn trigger() -> Option<&'static str> {
    with(|s| s.trigger.map(|t| t.0))
}
/// Whether a trigger is already recorded (a TERM from outside, taken before a cap fired).
pub fn has_trigger() -> bool {
    with(|s| s.trigger.is_some())
}
pub fn set_deadline(alive: &[i32]) {
    with(|s| {
        s.deadline_missed = true;
        s.survivors = alive.to_vec();
    });
}
pub fn add_killed(k: Killed) {
    with(|s| s.killed.push(k));
}
pub fn set_tracking(t: &'static str) {
    with(|s| s.tracking = t);
}
pub fn set_degraded(why: &str) {
    with(|s| s.degraded = Some(why.to_string()));
}
/// The one setter of the error triple (`Status::set_error`).
pub fn set_error(step: crate::steps::Step, errno: Option<i32>, text: &str) {
    with(|s| s.set_error(step, errno, text));
}
pub fn set_quiet(q: bool) {
    with(|s| s.quiet = q);
}
pub fn add_note(n: &str) {
    with(|s| s.notes.push(n.to_string()));
}

/// This process is a relay (sheepr started with children): only the supervisor writes the
/// status line, so the relay drops the fd from its state.
pub fn disable() {
    with(|s| s.fd = None);
}

/// The kill report (PLAN.md §10.4) for a job whose root ended as `root_status` (None: ended
/// by a TERM from outside or a cap) and whose kill ended `clean` (no deadline, no internal error).
/// Nothing is printed when nothing was killed. `--quiet` keeps only the degraded line.
pub fn report(root_status: Option<crate::Reaped>, clean: bool) {
    // debug seam: the phase-1 hint cells count every stderr line, and the report is not theirs
    if crate::seam_flag("SHEEPR_TEST_NO_REPORT") {
        return;
    }
    let (killed, degraded, quiet) = with(|s| (s.killed.iter().map(|k| (k.pid, k.cmd.clone(), k.escaped)).collect::<Vec<_>>(), s.degraded.clone(), s.quiet));
    if killed.is_empty() {
        return;
    }
    if !quiet {
        // (the cause, for the trace; the words, for the reader)
        let (cause, why) = match root_status {
            Some(crate::Reaped::Status(st)) if libc::WIFSIGNALED(st) => ("signaled".to_string(), format!("the command died of signal {}", libc::WTERMSIG(st))),
            Some(crate::Reaped::Status(st)) => ("exited".to_string(), format!("the command exited {}", libc::WEXITSTATUS(st))),
            Some(crate::Reaped::Lost(_)) => ("lost".to_string(), "the command ended (its exit status was lost)".to_string()),
            None if trigger() == Some("journal") => ("journal".to_string(), "the job journal failed (--require-journal)".to_string()),
            None => match crate::caps::by() {
                Some(flag) => (flag.to_string(), format!("the {flag} limit fired")),
                None => ("term".to_string(), "TERM from outside".to_string()),
            },
        };
        crate::note(format!("report-cause {cause}"));
        let escaped: Vec<_> = killed.iter().filter(|k| k.2.is_some()).collect();
        crate::say!(
            "sheepr: {why}: ended the job, {} process{} killed, {} of them had escaped{}",
            killed.len(),
            if killed.len() == 1 { "" } else { "es" },
            escaped.len(),
            if escaped.is_empty() { "." } else { ":" }
        );
        for (pid, cmd, how) in escaped {
            let how = match how {
                Some("setsid") => "escaped with setsid",
                Some("reparented") => "escaped by reparenting",
                _ => "escaped",
            };
            crate::say!("  pid {pid}  {cmd}   {how}");
        }
    }
    if !clean {
        return; // the deadline or internal-error message says why the tree is not clean
    }
    match degraded {
        None if !quiet => {
            crate::say!("sheepr: tree clean. Machine-readable: --status-fd.");
            crate::note("report clean".to_string());
        }
        None => {}
        Some(r) => {
            crate::say!("sheepr: no members left that sheepr could see (tracking degraded: {r}).");
            crate::note("report degraded".to_string());
        }
    }
}

/// How long one write of the status line may go with the fd accepting nothing before sheepr
/// gives up on its reader (issue #14; debug seam SHEEPR_TEST_STATUS_IDLE_MS). A reader that
/// drains its end takes the line at once; one that has stopped must never hold sheepr after the
/// job is killed. Long, so a caller that is alive but stalled (a busy event loop, swap) still
/// gets its line once it holds more than its pipe (64 KiB for a pipe or node's stdio pair, 8 KiB
/// for a raw macOS socketpair).
const IDLE: Duration = Duration::from_secs(10);
/// The longest the line may take in all, however steadily its reader reads (debug seam
/// SHEEPR_TEST_STATUS_CAP_MS).
const CAP: Duration = Duration::from_secs(30);
/// An EINTR this close to the end of its window counts as the timer's tick.
const TICK_SLACK: Duration = Duration::from_millis(10);
/// The notice that the line did not arrive waits at most this long for stderr.
const NOTICE: Duration = Duration::from_secs(1);
/// One write's size: PIPE_BUF, which a pipe takes whole or not at all (as a macOS socket does
/// below its 2048-byte low-water mark), so no write waits on with part of it taken, and a reader
/// that takes part of a write and stops is cut one idle later, not two (review of fa07b06, P3-1).
/// Each write at a new offset starts a new idle window, so a buffer that fills at once is
/// progress, and a reader that reads steadily keeps every window short.
#[cfg(target_os = "macos")]
const CHUNK: usize = 512;
#[cfg(not(target_os = "macos"))]
const CHUNK: usize = 4096;

/// Write the status line (once) and return `code`. A line its reader does not take (the fd
/// accepts nothing for IDLE, the line takes longer than CAP, or the reader has closed its
/// end) is said in one stderr line, also under `--quiet` (the machine-readable record is gone),
/// which waits at most NOTICE; the exit code stays the command's.
pub fn write(code: i32) -> i32 {
    let Some((fd, line)) = line(code) else { return code };
    // sheepr's end: only an exit or a raise follows (die_like resets the one signal it raises).
    // A closed reader must be EPIPE, never a SIGPIPE death, also before setup_signals blocked it
    // (a usage error, an early panic)
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) };
    let idle = crate::seam_ms("SHEEPR_TEST_STATUS_IDLE_MS").map_or(IDLE, Duration::from_millis);
    let cap = crate::seam_ms("SHEEPR_TEST_STATUS_CAP_MS").map_or(CAP, Duration::from_millis);
    let (total, start) = (line.len(), Instant::now());
    if let Err((cause, why, sent)) = bounded_write(fd, line.as_bytes(), idle, cap) {
        crate::note(format!("status-undelivered {cause} {} {sent}/{total}", start.elapsed().as_millis()));
        // a cut line has no newline: when stderr is the same file (a shell's `3>&2`), the notice
        // still starts a line of its own
        let nl = if sent > 0 && sent < total && same_file(fd, 2) { "\n" } else { "" };
        let said = format!("{nl}sheepr: the status line did not reach fd {fd}: {why} ({sent} of {total} bytes written).\n");
        let notice = idle.min(NOTICE);
        let t = Instant::now();
        let _ = bounded_write(2, said.as_bytes(), notice, notice);
        crate::note(format!("status-notice {}", t.elapsed().as_millis()));
    }
    code
}

/// Whether fds `a` and `b` are the same file (device and inode).
fn same_file(a: i32, b: i32) -> bool {
    let (mut x, mut y): (libc::stat, libc::stat) = unsafe { (std::mem::zeroed(), std::mem::zeroed()) };
    let read = unsafe { libc::fstat(a, &mut x) == 0 && libc::fstat(b, &mut y) == 0 };
    read && x.st_dev == y.st_dev && x.st_ino == y.st_ino
}

extern "C" fn on_alarm(_: libc::c_int) {}

fn arm(first: Duration, every: Duration) {
    let tv = |d: Duration| libc::timeval { tv_sec: d.as_secs() as _, tv_usec: d.subsec_micros() as _ };
    let it = libc::itimerval { it_value: tv(first), it_interval: tv(every) };
    unsafe { libc::setitimer(libc::ITIMER_REAL, &it, std::ptr::null_mut()) };
}

/// Write all of `b` to `fd` from this thread, in CHUNKs, as plain blocking writes: the fd is
/// never changed (its open file description may be shared, e.g. a shell's `3>&2`), so any kind
/// works. Before each write a SIGALRM timer is set to `idle` (or what is left of `cap`), and it
/// repeats; the handler does nothing and has no SA_RESTART, so the tick ends a write that is
/// waiting: one that took some bytes returns their count, one that took none returns EINTR, and
/// then sheepr gives up. Nothing is left writing when this returns, so the count is exact, and
/// no thread is needed (a job can use up the pids). SIGALRM is unblocked for this thread only,
/// while it writes; sheepr's other thread (macOS `tcc-probe`) starts after setup_signals and
/// blocks it, so the tick reaches this one. A non-blocking fd (the caller's choice; its open file
/// description is shared, so it is left as it is): an EAGAIN waits in poll for room, in the same
/// window, and the tick ends that wait as it ends a write. A signal from outside that ends a
/// write or a poll before the window is up is not the tick: the write is tried again. Stated: a tick that falls between setting the timer
/// and the write itself is missed, and the next one ends the write (twice the limit at worst);
/// a file on a hard network mount can hold a write that no signal ends.
/// Err: (cause, why, bytes written).
fn bounded_write(fd: i32, b: &[u8], idle: Duration, cap: Duration) -> Result<(), (&'static str, String, usize)> {
    let (mut old_act, mut old_mask): (libc::sigaction, libc::sigset_t) = unsafe { (std::mem::zeroed(), std::mem::zeroed()) };
    unsafe {
        let mut act: libc::sigaction = std::mem::zeroed();
        act.sa_sigaction = on_alarm as extern "C" fn(libc::c_int) as libc::sighandler_t;
        libc::sigemptyset(&mut act.sa_mask);
        libc::sigaction(libc::SIGALRM, &act, &mut old_act);
        let mut alrm: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut alrm);
        libc::sigaddset(&mut alrm, libc::SIGALRM);
        libc::pthread_sigmask(libc::SIG_UNBLOCK, &alrm, &mut old_mask);
    }
    let errno = || std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
    // debug seam: every write of the status line says EAGAIN and writes nothing, while poll says
    // the fd is ready (a FUSE file can do both)
    let eagain = fd != 2 && crate::seam_flag("SHEEPR_TEST_STATUS_EAGAIN");
    let start = Instant::now();
    // (offset, since, length): the window of the write at that offset; a retry after EAGAIN keeps it
    let (mut off, mut window): (usize, Option<(usize, Instant, Duration)>) = (0, None);
    let r = loop {
        if off == b.len() {
            break Ok(());
        }
        let (since, w) = match window {
            Some((o, since, w)) if o == off => (since, w),
            _ => {
                // past the cap a write gets 1 ms: one that waits ends as `cap` below
                let w = cap.saturating_sub(start.elapsed()).min(idle).max(Duration::from_millis(1));
                // the clock before the timer: the timer's tick then comes a full window after
                // `since`, so an EINTR before that is a signal from outside (below)
                let since = Instant::now();
                arm(w, w);
                window = Some((off, since, w));
                (since, w)
            }
        };
        let end = (off + CHUNK).min(b.len());
        let (n, mut e) = if eagain {
            (-1, libc::EAGAIN)
        } else {
            let n = unsafe { libc::write(fd, b[off..end].as_ptr() as *const libc::c_void, end - off) };
            (n, errno())
        };
        if n > 0 {
            off += n as usize;
            continue;
        }
        let mut polled = false;
        if n < 0 && (e == libc::EAGAIN || e == libc::EWOULDBLOCK) {
            // wait for room for what is left of this window: a poll that says ready while each
            // write says EAGAIN (a FUSE file can) still ends with the window, as the tick ends a
            // write (review of 03da4f8, F2)
            let left = w.saturating_sub(since.elapsed());
            let r = if left.is_zero() {
                0
            } else {
                let mut p = libc::pollfd { fd, events: libc::POLLOUT, revents: 0 };
                unsafe { libc::poll(&mut p, 1, (left.as_millis() as libc::c_int).saturating_add(1)) }
            };
            if r > 0 {
                continue;
            }
            e = if r == 0 { libc::EINTR } else { errno() };
            polled = r < 0;
        }
        // an EINTR before the window is up is a signal sent from outside (SIGALRM is unblocked
        // while the line is written), not the timer's tick: try again in the same window, so the
        // signal never cuts the line (issue #14). TICK_SLACK takes a tick that comes a little early
        // for the tick.
        if n < 0 && e == libc::EINTR && since.elapsed() + TICK_SLACK < w {
            crate::note(format!("status-retry {}", if polled { "poll" } else { "write" }));
            continue;
        }
        break Err(match (n, e) {
            (0, _) => ("error", "a write took nothing".to_string(), off),
            (_, libc::EINTR) if start.elapsed() >= cap => ("cap", format!("its reader did not take it all within {} ms", cap.as_millis()), off),
            (_, libc::EINTR) => ("timeout", format!("the fd accepted nothing for {} ms", since.elapsed().as_millis()), off),
            (_, libc::EPIPE) => ("closed", "its reader has closed it".to_string(), off),
            (_, e) => ("error", std::io::Error::from_raw_os_error(e).to_string(), off),
        });
    };
    arm(Duration::ZERO, Duration::ZERO);
    unsafe {
        libc::pthread_sigmask(libc::SIG_SETMASK, &old_mask, std::ptr::null_mut());
        libc::sigaction(libc::SIGALRM, &old_act, std::ptr::null_mut());
    }
    r
}

/// The class guard (plan §2): a line never says root "not-started" with neither an `error` nor a
/// `trigger` (an early end that recorded no reason). A debug build panics, so a cell sees it; a
/// release build fills the error, source "sheepr".
const NO_REASON: &str = "sheepr ended before the command started and recorded no reason";
fn guard(s: &mut Status, debug: bool) {
    if s.root_fields().0 != "not-started" || s.error.is_some() || s.trigger.is_some() {
        return;
    }
    if debug {
        panic!("{NO_REASON}");
    }
    s.set_error(crate::steps::Step::Unrecorded, None, NO_REASON);
}

/// The status line, and the fd it goes to (taken: the line is written once).
fn line(code: i32) -> Option<(i32, String)> {
    with(|s| {
        s.fd?;
        // before the fd is taken: in a debug build the panic's own line is written after it
        guard(s, cfg!(debug_assertions));
        let fd = s.fd.take()?;
        // debug seam: a note of this many bytes, so a test's line is larger than any pipe buffer
        // (a real job reaches that size with a few hundred killed members; seam_ms reads a number)
        if let Some(n) = crate::seam_ms("SHEEPR_TEST_STATUS_PAD") {
            s.notes.push("x".repeat(n as usize));
        }
        Some((fd, render(s, code)))
    })
}

/// The status line of record `s` for exit code `code`.
fn render(s: &Status, code: i32) -> String {
    let js = crate::journal::json_str;
    let opt = |v: &Option<String>| v.as_deref().map_or_else(|| "null".to_string(), js);
    let killed: Vec<String> = s
        .killed
        .iter()
        .map(|k| format!("{{\"pid\":{},\"cmd\":{},\"escaped\":{}}}", k.pid, js(&k.cmd), k.escaped.map_or_else(|| "null".to_string(), js)))
        .collect();
    let survivors: Vec<String> = s.survivors.iter().map(|p| p.to_string()).collect();
    let notes: Vec<String> = s.notes.iter().map(|n| js(n)).collect();
    let (trigger, at) = match s.trigger {
        Some((t, at)) => (js(t), at.to_string()),
        None => ("null".to_string(), "null".to_string()),
    };
    let (root, root_code, root_signal) = s.root_fields();
    let num = |v: Option<i32>| v.map_or_else(|| "null".to_string(), |n| n.to_string());
    format!(
        "{{\"v\":1,\"job\":{},\"root\":\"{}\",\"root_code\":{},\"root_signal\":{},\"code\":{code},\"trigger\":{trigger},\"trigger_at\":{at},\"deadline_missed\":{},\"killed\":[{}],\"survivors\":[{}],\"tracking\":\"{}\",\"degraded\":{},\"error\":{},\"error_code\":{},\"error_source\":{},\"notes\":[{}]}}\n",
        opt(&s.job),
        root,
        num(root_code),
        num(root_signal),
        s.deadline_missed,
        killed.join(","),
        survivors.join(","),
        s.tracking,
        opt(&s.degraded),
        opt(&s.error),
        s.error_code.map_or_else(|| "null".to_string(), js),
        s.error_source.map_or_else(|| "null".to_string(), js),
        notes.join(",")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The stated limits (whole-branch review P2-2): the 10 s idle and 30 s cap that README.md,
    /// CHANGELOG.md and PLAN.md §3.1 state, and the 1 s notice and 10 ms tick slack that PLAN.md
    /// §3.1 states. tests/status.rs proves the idle end to end with no seam.
    #[test]
    fn the_stated_limits() {
        assert_eq!((IDLE, CAP, NOTICE), (Duration::from_secs(10), Duration::from_secs(30), Duration::from_secs(1)));
        // PLAN.md §3.1: an EINTR in a window's last 10 ms is the tick, not a signal from outside
        assert_eq!(TICK_SLACK, Duration::from_millis(10));
    }

    /// A wait status for death by signal `sig` (the encoding both OSes use).
    fn killed_by(sig: i32) -> libc::c_int {
        sig
    }

    /// #17: the recorder keeps the FIRST end recorded for the root's pid: a later reap at that
    /// pid (a reused pid) never overwrites it. It records nothing for another pid, nor before the
    /// root's pid is set (root-disclaim once set none). `root` follows what it recorded: "exited"
    /// exactly with `root_code`, "signaled" exactly with `root_signal`.
    #[test]
    fn the_recorder_keeps_the_first_end_of_the_root() {
        let mut s = Status::new();
        s.record_root_end(42, crate::exit_status(3));
        assert_eq!(s.root_fields(), ("not-started", None, None), "no root pid set: nothing is recorded");
        s.root_pid = 42;
        s.root_may_run = true;
        s.record_root_end(43, killed_by(libc::SIGKILL));
        assert_eq!(s.root_fields(), ("signaled", None, None), "another pid is not the root");
        s.record_root_end(42, (libc::SIGSTOP << 8) | 0x7f);
        assert_eq!(s.root_fields(), ("signaled", None, None), "a stop is not an end");
        s.record_root_end(42, crate::exit_status(3));
        assert_eq!(s.root_fields(), ("exited", Some(3), None));
        s.record_root_end(42, killed_by(libc::SIGKILL));
        assert_eq!(s.root_fields(), ("exited", Some(3), None), "a second record at the root's pid");
        let mut k = Status::new();
        (k.root_pid, k.root_may_run) = (7, true);
        k.record_root_end(7, killed_by(libc::SIGKILL));
        k.record_root_end(7, crate::exit_status(0));
        assert_eq!(k.root_fields(), ("signaled", None, Some(libc::SIGKILL)));
    }

    /// #17: `set_root_final("not-started")` (the command never ran) clears both fields and keeps
    /// every later record off; the control, the same record without it, shows the code.
    #[test]
    fn a_final_not_started_clears_and_blocks_the_root_fields() {
        let mut s = Status::new();
        (s.root_pid, s.root_may_run) = (42, true);
        s.record_root_end(42, crate::exit_status(127));
        assert_eq!(s.root_fields(), ("exited", Some(127), None), "control");
        s.set_root_final("not-started");
        assert_eq!(s.root_fields(), ("not-started", None, None), "cleared");
        let mut b = Status::new();
        (b.root_pid, b.root_may_run) = (42, true);
        b.set_root_final("not-started");
        b.record_root_end(42, crate::exit_status(127));
        assert_eq!(b.root_fields(), ("not-started", None, None), "blocked");
    }

    /// Round 3 P4: the trigger a death by TERM sets is set only when none is set: no "term after
    /// the trigger" note behind another trigger; the control, a later trigger by `set_trigger`,
    /// is that note.
    #[test]
    fn a_term_s_own_trigger_never_notes_behind_another() {
        let mut s = Status::new();
        s.set_trigger_if_none("term");
        assert_eq!(s.trigger.map(|t| t.0), Some("term"));
        let mut t = Status::new();
        t.trigger = Some(("timeout", 5));
        t.set_trigger_if_none("term");
        assert_eq!((t.trigger.map(|t| t.0), t.notes.len()), (Some("timeout"), 0));
        let mut c = Status::new();
        c.trigger = Some(("timeout", 5));
        c.set_trigger("term");
        assert_eq!(c.notes, ["term after the trigger"], "control");
    }

    /// Plan §2's class guard, a release build: root "not-started" with no error and no trigger
    /// gets the no-reason error (source "sheepr"); the controls: an error, a trigger, or a root
    /// that may have run leave the record as it is.
    #[test]
    fn a_release_line_never_says_not_started_without_a_reason() {
        let mut s = Status::new();
        guard(&mut s, false);
        assert_eq!((s.error.as_deref(), s.error_source), (Some(NO_REASON), Some("sheepr")));
        let mut e = Status::new();
        e.set_error(crate::steps::Step::Usage, None, "usage");
        guard(&mut e, false);
        assert_eq!(e.error.as_deref(), Some("usage"));
        let mut t = Status::new();
        t.set_trigger("term");
        guard(&mut t, false);
        assert_eq!(t.error, None);
        let mut r = Status::new();
        r.root_may_run = true;
        guard(&mut r, false);
        assert_eq!(r.error, None);
    }

    /// The same guard in a debug build panics (a cell sees the bare early return).
    #[test]
    #[should_panic(expected = "recorded no reason")]
    fn a_debug_line_panics_on_not_started_without_a_reason() {
        guard(&mut Status::new(), true);
    }

    /// Plan §2: the one setter of the error triple. The first error wins, and its errno name and
    /// source go with it; a later one becomes a note `also: <text>`.
    #[test]
    fn the_first_error_wins_and_later_ones_are_notes() {
        use crate::steps::Step;
        let mut s = Status::new();
        s.set_error(Step::Pipe, Some(libc::EMFILE), "cannot make a pipe");
        s.set_error(Step::Exec, Some(libc::ENOENT), "cannot run x");
        assert_eq!((s.error.as_deref(), s.error_code, s.error_source), (Some("cannot make a pipe"), Some("EMFILE"), Some("resources")));
        assert_eq!(s.notes, ["also: cannot run x"]);
        let mut n = Status::new();
        n.set_error(Step::Usage, None, "usage");
        assert_eq!((n.error.as_deref(), n.error_code, n.error_source), (Some("usage"), None, Some("usage")));
    }

    /// Round 3 P4: an internal error is never moved into a note behind an earlier error: it takes
    /// `error` (with its own code and source) and the earlier one becomes the note; a second
    /// internal error is a note.
    #[test]
    fn an_internal_error_is_never_a_note_behind_an_earlier_one() {
        use crate::steps::Step;
        let mut s = Status::new();
        s.set_error(Step::Exec, Some(libc::ENOENT), "cannot run x");
        s.set_error(Step::KillInternal, None, "internal error while killing the tree");
        assert_eq!((s.error.as_deref(), s.error_code, s.error_source), (Some("internal error while killing the tree"), None, Some("sheepr")));
        assert_eq!(s.notes, ["also: cannot run x"]);
        s.set_error(Step::Panic, None, "internal error (a panic)");
        assert_eq!(s.error.as_deref(), Some("internal error while killing the tree"));
        assert_eq!(s.notes, ["also: cannot run x", "also: internal error (a panic)"]);
    }

    /// Plan §2: the line carries `error_code` and `error_source` beside `error`, null without one.
    #[test]
    fn the_line_carries_the_error_s_code_and_source() {
        let field = |s: &Status, k: &str| sheepr::json::parse(render(s, 0).trim_end()).expect("the line parses").get(k).cloned();
        let mut s = Status::new();
        assert_eq!((field(&s, "error_code"), field(&s, "error_source")), (Some(sheepr::json::Json::Null), Some(sheepr::json::Json::Null)));
        s.set_error(crate::steps::Step::ShimSpawn, Some(libc::EAGAIN), "cannot start the command");
        assert_eq!(field(&s, "error_code"), Some(sheepr::json::Json::Str("EAGAIN".into())));
        assert_eq!(field(&s, "error_source"), Some(sheepr::json::Json::Str("resources".into())));
    }

    /// #17: the line carries `root_code` and `root_signal`, numbers or null, beside `root`.
    #[test]
    fn the_line_carries_the_root_s_code_and_signal() {
        let field = |s: &Status, k: &str| sheepr::json::parse(render(s, 0).trim_end()).expect("the line parses").get(k).cloned();
        let mut s = Status::new();
        assert_eq!(field(&s, "root_code"), Some(sheepr::json::Json::Null), "never ran");
        assert_eq!(field(&s, "root_signal"), Some(sheepr::json::Json::Null), "never ran");
        (s.root_pid, s.root_may_run) = (42, true);
        s.record_root_end(42, crate::exit_status(3));
        assert_eq!(field(&s, "root").as_ref().and_then(|j| j.str().map(String::from)), Some("exited".to_string()));
        assert_eq!(field(&s, "root_code").as_ref().and_then(|j| j.num()), Some(3.0));
        assert_eq!(field(&s, "root_signal"), Some(sheepr::json::Json::Null));
        let mut k = Status::new();
        (k.root_pid, k.root_may_run) = (42, true);
        k.record_root_end(42, killed_by(libc::SIGTERM));
        assert_eq!(field(&k, "root_code"), Some(sheepr::json::Json::Null));
        assert_eq!(field(&k, "root_signal").as_ref().and_then(|j| j.num()), Some(libc::SIGTERM as f64));
    }
}
