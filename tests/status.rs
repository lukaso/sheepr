//! Phase-2 P2: `--status-fd` (PLAN.md §3.1; PHASE2.md §1 decision 8), the exit-code order, the
//! kill report (PLAN.md §10.4) and `--quiet`. Cells read the status JSON, exit codes, pids on
//! stderr and the trace; never the report's wording.

mod common;

use common::json::{self, Json};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

fn sheepr() -> &'static str {
    common::test_env();
    env!("CARGO_BIN_EXE_sheepr")
}
fn fixture() -> &'static str {
    common::test_env();
    env!("CARGO_BIN_EXE_sr-fixture")
}

fn scratch(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("sr-st-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn marker() -> String {
    let n = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().subsec_nanos();
    format!("29.{:09}", n)
}

fn records(r: &Path, n: usize) -> Vec<(i32, u64)> {
    let end = Instant::now() + Duration::from_secs(10);
    loop {
        let v: Vec<(i32, u64)> = std::fs::read_to_string(r)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| {
                let mut w = l.split_whitespace();
                Some((w.next()?.parse().ok()?, w.next()?.parse().ok()?))
            })
            .collect();
        if v.len() >= n || Instant::now() > end {
            return v;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

struct Run {
    code: Option<i32>,
    status: Option<Json>,
    lines: usize,
    stderr: String,
    /// the status file as it was read
    raw: String,
}

/// `sheepr run ARGS` with `--status-fd 3` pointed at a file (through a shell, `exec`), within
/// 30 s; `pre` runs with the child (e.g. to send it TERM).
fn run(d: &Path, name: &str, args: &str, env: &[(&str, &str)], pre: impl FnOnce(&mut std::process::Child)) -> Run {
    run_after(d, name, "", args, env, pre)
}

/// `run`, with shell text `prefix` run before the `exec` (e.g. a background child, so sheepr
/// starts with children and forks its relay).
fn run_after(d: &Path, name: &str, prefix: &str, args: &str, env: &[(&str, &str)], pre: impl FnOnce(&mut std::process::Child)) -> Run {
    let out = d.join(format!("{name}.status"));
    let err = d.join(format!("{name}.err"));
    let mut cmd = Command::new("/bin/sh");
    cmd.args(["-c", &format!(r#"{prefix} exec "$SD" run --status-fd 3 {args} 3>"{}" 2>"{}""#, out.display(), err.display())])
        .env("SD", sheepr())
        .env("FX", fixture());
    for (k, v) in env {
        cmd.env(k, v);
    }
    let mut c = cmd.spawn().unwrap();
    pre(&mut c);
    let end = Instant::now() + Duration::from_secs(30);
    let code = loop {
        if let Some(s) = c.try_wait().unwrap() {
            break s.code();
        }
        if Instant::now() > end {
            common::send_child(&mut c, libc::SIGKILL);
            let _ = c.wait();
            break None;
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    let text = std::fs::read_to_string(&out).unwrap_or_default();
    Run {
        code,
        status: text.lines().next().and_then(|l| json::parse(l).ok()),
        lines: text.lines().count(),
        stderr: std::fs::read_to_string(&err).unwrap_or_default(),
        raw: text,
    }
}

fn field<'a>(r: &'a Run, k: &str) -> Option<&'a Json> {
    r.status.as_ref().and_then(|s| s.get(k))
}

/// Cell 26: three different status lines for three runs that all exit 125 (a command that
/// exits 125 by itself, a usage error, and a deadline with a live member), and an external TERM
/// gives `trigger: "term"`; a command that exits 143 by itself does not.
#[test]
fn cell_26_the_status_line_tells_the_125s_apart() {
    let d = scratch("c26");
    let by_itself = run(&d, "self", r#"-- /bin/sh -c 'exit 125'"#, &[], |_| {});
    let usage = run(&d, "usage", r#"--no-such-flag -- /bin/sh -c 'exit 0'"#, &[], |_| {});
    let m = marker();
    let r = d.join("rec");
    let deadline = run(
        &d,
        "deadline",
        &format!(r#"--grace 0 -- "$FX" escape {m} "{}""#, r.display()),
        &[("SHEEPR_TEST_NOKILL", "1"), ("SHEEPR_TEST_DEADLINE_MS", "500")],
        |_| {},
    );
    let g = records(&r, 1);
    for p in &g {
        common::send(p.0, p.1, libc::SIGKILL);
    }
    for (n, x) in [("self", &by_itself), ("usage", &usage), ("deadline", &deadline)] {
        assert_eq!(x.code, Some(125), "{n}");
        assert_eq!(x.lines, 1, "{n}: one status line");
        assert_eq!(field(x, "code").and_then(Json::num), Some(125.0), "{n}");
    }
    assert_eq!(field(&by_itself, "error"), Some(&Json::Null));
    assert_eq!(field(&by_itself, "deadline_missed"), Some(&Json::Bool(false)));
    assert_eq!(field(&by_itself, "root").and_then(Json::str), Some("exited"));
    assert!(field(&usage, "error").and_then(Json::str).is_some(), "the usage error is named");
    assert_eq!(field(&deadline, "deadline_missed"), Some(&Json::Bool(true)));
    let survivors: Vec<i64> = field(&deadline, "survivors").and_then(Json::arr).unwrap_or(&[]).iter().filter_map(Json::num).map(|n| n as i64).collect();
    assert!(g.iter().all(|p| survivors.contains(&(p.0 as i64))), "survivors {survivors:?}, escapee {g:?}");
    // TERM from outside, against a command that exits 143 by itself
    let ready = d.join("ready");
    let termed = run(&d, "term", &format!(r#"-- /bin/sh -c 'touch "{}"; sleep 30'"#, ready.display()), &[], |c| {
        let end = Instant::now() + Duration::from_secs(20);
        while !ready.exists() && Instant::now() < end {
            std::thread::sleep(Duration::from_millis(5));
        }
        common::send_child(c, libc::SIGTERM);
    });
    let own143 = run(&d, "own143", r#"-- /bin/sh -c 'exit 143'"#, &[], |_| {});
    assert_eq!(field(&termed, "trigger").and_then(Json::str), Some("term"));
    assert!(field(&termed, "trigger_at").and_then(Json::num).is_some(), "trigger_at in ms");
    assert_eq!(own143.code, Some(143));
    assert_eq!(field(&own143, "trigger"), Some(&Json::Null), "a command's own 143 is no trigger");
    let _ = std::fs::remove_dir_all(&d);
}

/// A command that cannot be run: exit 127 (126 when it is not executable), `root`
/// "not-started" and an `error` that names the failure; the control, a command that runs and
/// exits 127 by itself, has no error.
#[test]
fn a_command_that_cannot_run_names_the_error() {
    let d = scratch("spawnerr");
    let missing = run(&d, "missing", "-- /nonexistent/x", &[], |_| {});
    let noexec = d.join("noexec");
    std::fs::write(&noexec, "#!/bin/sh\n").unwrap();
    let denied = run(&d, "denied", &format!("-- {}", noexec.display()), &[], |_| {});
    let own = run(&d, "own", r#"-- /bin/sh -c 'exit 127'"#, &[], |_| {});
    for (x, code) in [(&missing, 127), (&denied, 126)] {
        assert_eq!(x.code, Some(code), "{:?}", x.status);
        assert_eq!(field(x, "root").and_then(Json::str), Some("not-started"), "{:?}", x.status);
        assert!(field(x, "error").and_then(Json::str).is_some_and(|e| e.contains("cannot run")), "{:?}", x.status);
    }
    assert_eq!(own.code, Some(127));
    assert_eq!(field(&own, "error"), Some(&Json::Null), "control: {:?}", own.status);
    let _ = std::fs::remove_dir_all(&d);
}

/// Cell 26: the status fd is set CLOEXEC, so the root does not hold it. The fd is 57, far above
/// the low fds a translator keeps open (Rosetta holds 3 and up on the emulated leg).
#[test]
fn the_root_does_not_hold_the_status_fd() {
    let d = scratch("cloexec");
    let (flag, out) = (d.join("open"), d.join("status57"));
    // fd 57 is set up here, not by a shell: dash redirects single-digit fds only
    let file = std::fs::File::create(&out).unwrap();
    let raw = std::os::fd::AsRawFd::as_raw_fd(&file);
    let mut cmd = Command::new(sheepr());
    cmd.args(["run", "--status-fd", "57", "--", "/bin/sh", "-c", &format!(r#"if [ -e /dev/fd/57 ]; then touch "{}"; fi"#, flag.display())]);
    unsafe {
        std::os::unix::process::CommandExt::pre_exec(&mut cmd, move || {
            if libc::dup2(raw, 57) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let code = cmd.status().unwrap().code();
    drop(file);
    assert_eq!(code, Some(0));
    assert_eq!(std::fs::read_to_string(&out).unwrap_or_default().lines().count(), 1, "control: sheepr wrote its line to fd 57");
    assert!(!flag.exists(), "the root holds the status fd");
    let _ = std::fs::remove_dir_all(&d);
}

/// `killed[].escaped` names how each killed process escaped: `setsid` for a new session,
/// `reparented` for a double fork in the same session; the report on stderr names every killed
/// escapee's pid.
#[test]
fn killed_processes_say_how_they_escaped() {
    let d = scratch("escaped");
    let (m1, m2) = (marker(), marker());
    let (r1, r2) = (d.join("r1"), d.join("r2"));
    let x = run(
        &d,
        "esc",
        &format!(r#"--grace 0 -- /bin/sh -c '"$FX" escape {m1} "{}"; "$FX" doublefork {m2} "{}"'"#, r1.display(), r2.display()),
        &[],
        |_| {},
    );
    let (s, f) = (records(&r1, 1), records(&r2, 1));
    for p in s.iter().chain(f.iter()) {
        common::send(p.0, p.1, libc::SIGKILL);
    }
    assert_eq!(x.code, Some(0));
    let killed = field(&x, "killed").and_then(Json::arr).unwrap_or(&[]).to_vec();
    let how = |pid: i32| killed.iter().find(|k| k.get("pid").and_then(Json::num) == Some(pid as f64)).and_then(|k| k.get("escaped").and_then(Json::str).map(String::from));
    assert_eq!(how(s[0].0), Some("setsid".to_string()), "{killed:?}");
    assert_eq!(how(f[0].0), Some("reparented".to_string()), "{killed:?}");
    for p in [s[0].0, f[0].0] {
        assert!(x.stderr.split(|c: char| !c.is_ascii_digit()).any(|w| w == p.to_string()), "the report does not name pid {p}:\n{}", x.stderr);
    }
    let _ = std::fs::remove_dir_all(&d);
}

/// `tracking` names the mechanism and `degraded` is null when tracking is complete; the report's
/// last line says "clean" only then (the trace records which ending was printed). macOS: with
/// the responsibility SPI forced missing, `degraded` names why and the report never says clean.
#[test]
fn the_report_says_clean_only_when_tracking_was_complete() {
    let d = scratch("clean");
    let m = marker();
    let r = d.join("rec");
    let trace = d.join("trace");
    let full = run(&d, "full", &format!(r#"--grace 0 -- "$FX" escape {m} "{}""#, r.display()), &[("SHEEPR_TEST_TRACE", trace.to_str().unwrap())], |_| {});
    for p in records(&r, 1) {
        common::send(p.0, p.1, libc::SIGKILL);
    }
    let expect = if cfg!(target_os = "macos") { "responsibility" } else { "subreaper" };
    assert_eq!(field(&full, "tracking").and_then(Json::str), Some(expect));
    assert_eq!(field(&full, "degraded"), Some(&Json::Null));
    let notes = std::fs::read_to_string(&trace).unwrap_or_default();
    assert!(notes.lines().any(|l| l == "report clean"), "{notes}");
    if cfg!(target_os = "macos") {
        let m = marker();
        let r = d.join("rec2");
        let trace2 = d.join("trace2");
        // a background child of the root: the degraded tracking (puniq) still sees it, so the
        // kill has something to report (a setsid escapee would not be seen at all)
        let _ = r;
        let deg = run(
            &d,
            "degraded",
            &format!(r#"--grace 0 -- /bin/sh -c '/bin/sleep {m} & exit 0'"#),
            &[("SHEEPR_TEST_SPI", "broken"), ("SHEEPR_TEST_TRACE", trace2.to_str().unwrap())],
            |_| {},
        );
        common::kill_marked(&[&m]);
        let killed = deg.status.as_ref().and_then(|s| s.get("killed")).and_then(Json::arr).map_or(0, |a| a.len());
        // the message says which way it failed: no status line at all (the write), or a line
        // whose killed list is empty (the tracking)
        assert!(killed > 0, "control: the degraded run killed something; code {:?}, status file {:?}, stderr {:?}, trace:\n{}", deg.code, deg.raw, deg.stderr, std::fs::read_to_string(&trace2).unwrap_or_default());
        assert!(field(&deg, "degraded").and_then(Json::str).is_some(), "degraded is named");
        let notes = std::fs::read_to_string(&trace2).unwrap_or_default();
        assert!(notes.lines().any(|l| l == "report degraded"), "{notes}");
        assert!(!notes.lines().any(|l| l == "report clean"), "{notes}");
    }
    let _ = std::fs::remove_dir_all(&d);
}

/// `--quiet`: a kill with escapees prints nothing on stderr (the machine reads `--status-fd`);
/// the control run without `--quiet` prints the report.
#[test]
fn quiet_suppresses_the_report() {
    let d = scratch("quiet");
    let mut stderr = Vec::new();
    for quiet in [false, true] {
        let m = marker();
        let r = d.join(format!("rec-{quiet}"));
        let flag = if quiet { "--quiet " } else { "" };
        let x = run(&d, &format!("q{quiet}"), &format!(r#"{flag}--grace 0 -- "$FX" escape {m} "{}""#, r.display()), &[], |_| {});
        for p in records(&r, 1) {
            common::send(p.0, p.1, libc::SIGKILL);
        }
        assert_eq!(x.code, Some(0));
        stderr.push(x.stderr);
    }
    assert!(!stderr[0].trim().is_empty(), "control: the report is printed without --quiet");
    assert!(stderr[1].trim().is_empty(), "--quiet printed: {}", stderr[1]);
    let _ = std::fs::remove_dir_all(&d);
}

#[derive(Clone, Copy, PartialEq)]
enum Reader {
    /// the test holds the read end and reads nothing while sheepr runs (it reads the pipe to its
    /// end after, so `got` is exactly what sheepr wrote)
    Stuck,
    /// a thread reads to the newline
    Drain,
    /// a thread reads at most `.0` bytes every `.1` ms, to the newline
    Slow(usize, u64),
    /// a thread waits for the trace's `status-undelivered` note (sheepr has given up), then reads
    /// to the end of the pipe
    AfterNote,
    /// a thread waits until the pipe is full (its count unchanged for 200 ms), takes `.0` bytes
    /// once, and reads nothing more while sheepr runs
    TakeThenStop(usize),
    /// a thread waits until the pipe is full, sends sheepr one SIGALRM from outside, waits 500 ms,
    /// then reads to the newline
    AlarmThenDrain,
    /// no reader at all: the child makes the pipe and closes its read end before the exec, so no
    /// other process (another cell's child) can hold that end
    Closed,
}

#[derive(Default)]
struct Opts<'a> {
    /// words between `run --quiet --status-fd 3` and `--`
    args: &'a [&'a str],
    env: &'a [(&'a str, &'a str)],
    /// stderr is a full pipe nobody reads (then `stderr` is empty)
    full_stderr: bool,
    /// stderr is the status pipe itself, as a shell's `3>&2` (then `got` holds both)
    shared_stderr: bool,
    /// the write end is O_NONBLOCK (set on the test's copy: the open file description is shared)
    nonblock: bool,
    /// count sheepr's threads once the pipe is full (its count unchanged for 200 ms): sheepr is
    /// then in the line's write
    threads_when_full: bool,
}

struct Piped {
    code: Option<i32>,
    signal: Option<i32>,
    stderr: String,
    trace: String,
    /// what the reader got; a `Stuck` or `TakeThenStop` reader's rest is read after sheepr's end,
    /// to the end of the pipe
    got: Vec<u8>,
    /// from the spawn to sheepr's end
    ms: u128,
    /// from the spawn to the reader's first read (`AfterNote`, `TakeThenStop`)
    read_at_ms: Option<u128>,
    threads: Option<usize>,
    /// O_NONBLOCK on the test's own copy of the write end (the same open file description),
    /// read after sheepr exited; None when the test kept no copy
    nonblock_after: Option<bool>,
}

/// Fill the pipe whose write end is `w` (non-blocking for the fill only), so the next blocking
/// write to it waits for a reader.
fn fill(w: &std::io::PipeWriter) {
    let fd = std::os::fd::AsRawFd::as_raw_fd(w);
    let fl = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    unsafe { libc::fcntl(fd, libc::F_SETFL, fl | libc::O_NONBLOCK) };
    for size in [65536, 1] {
        let chunk = vec![b'e'; size];
        while unsafe { libc::write(fd, chunk.as_ptr() as *const libc::c_void, size) } > 0 {}
    }
    unsafe { libc::fcntl(fd, libc::F_SETFL, fl) };
}

/// The bytes waiting in the pipe whose read end is `fd`.
fn waiting(fd: i32) -> i32 {
    let mut n: libc::c_int = 0;
    unsafe { libc::ioctl(fd, libc::FIONREAD, &mut n) };
    n
}

/// Wait (20 s at most) until the pipe whose read end is `fd` is full: its count has not changed
/// for 200 ms.
fn until_full(fd: i32) {
    let (end, mut last) = (Instant::now() + Duration::from_secs(20), (0, Instant::now()));
    loop {
        let w = waiting(fd);
        if w != last.0 {
            last = (w, Instant::now());
        } else if w > 0 && last.1.elapsed() >= Duration::from_millis(200) {
            return;
        }
        if Instant::now() > end {
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// The number of threads of process `pid`, if it can be read.
fn threads(pid: u32) -> Option<usize> {
    if cfg!(target_os = "linux") {
        return std::fs::read_dir(format!("/proc/{pid}/task")).ok().map(|d| d.count());
    }
    let o = Command::new("ps").args(["-M", "-p", &pid.to_string()]).output().ok()?;
    Some(String::from_utf8_lossy(&o.stdout).lines().count().checked_sub(1)?)
}

/// `sheepr run --quiet --status-fd 3 ARGS -- /bin/sh -c 'exit 7'` with fd 3 the write end of a
/// pipe and the status line padded by `pad` bytes (debug seam), within 20 s (then KILL, code
/// None). The test keeps its own copy of the write end unless the reader is `Closed`.
fn piped(d: &Path, name: &str, reader: Reader, pad: usize, o: Opts) -> Piped {
    let trace = d.join(format!("{name}.trace"));
    let err = d.join(format!("{name}.err"));
    let mut cmd = Command::new(sheepr());
    cmd.args(["run", "--quiet", "--status-fd", "3"]).args(o.args).args(["--", "/bin/sh", "-c", "exit 7"]);
    cmd.env("SHEEPR_TEST_STATUS_PAD", pad.to_string()).env("SHEEPR_TEST_TRACE", &trace);
    for (k, v) in o.env {
        cmd.env(k, v);
    }
    let held_err = if o.full_stderr {
        let (er, ew) = std::io::pipe().unwrap();
        fill(&ew);
        cmd.stderr(ew);
        Some(er)
    } else {
        if !o.shared_stderr {
            cmd.stderr(std::fs::File::create(&err).unwrap());
        }
        None
    };
    let (r, w) = if reader == Reader::Closed {
        unsafe {
            std::os::unix::process::CommandExt::pre_exec(&mut cmd, || {
                let mut p = [0; 2];
                if libc::pipe(p.as_mut_ptr()) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                libc::close(p[0]);
                if p[1] != 3 {
                    libc::dup2(p[1], 3);
                    libc::close(p[1]);
                }
                Ok(())
            });
        }
        (None, None)
    } else {
        let (r, w) = std::io::pipe().unwrap();
        let raw = std::os::fd::AsRawFd::as_raw_fd(&w);
        if o.nonblock {
            unsafe { libc::fcntl(raw, libc::F_SETFL, libc::fcntl(raw, libc::F_GETFL) | libc::O_NONBLOCK) };
        }
        if o.shared_stderr {
            cmd.stderr(w.try_clone().unwrap());
        }
        unsafe {
            std::os::unix::process::CommandExt::pre_exec(&mut cmd, move || {
                // dup2 onto itself would keep CLOEXEC
                let ok = if raw == 3 { libc::fcntl(3, libc::F_SETFD, 0) } else { libc::dup2(raw, 3) };
                if ok < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        (Some(r), Some(w))
    };
    let t0 = Instant::now();
    let mut c = cmd.spawn().unwrap();
    drop(cmd); // its copies of the stderr ends: a reader must see the end of the pipe with sheepr's
    let keep = w; // the test's own copy of the write end, read for its flags after the end
    let note = trace.clone();
    let pid = c.id() as i32;
    let rfd = r.as_ref().map(std::os::fd::AsRawFd::as_raw_fd);
    let reading = r.map(|mut r| {
        std::thread::spawn(move || {
            let mut got = Vec::new();
            let fd = std::os::fd::AsRawFd::as_raw_fd(&r);
            let wait_until = |f: &dyn Fn() -> bool| {
                let end = Instant::now() + Duration::from_secs(20);
                while !f() && Instant::now() < end {
                    std::thread::sleep(Duration::from_millis(20));
                }
            };
            let (step, every, to_end) = match reader {
                Reader::Slow(n, ms) => (n, ms, false),
                Reader::Stuck => return (got, Some(r), None),
                Reader::AfterNote => {
                    wait_until(&|| std::fs::read_to_string(&note).unwrap_or_default().contains("status-undelivered "));
                    (65536, 0, true)
                }
                Reader::AlarmThenDrain => {
                    until_full(fd);
                    unsafe { libc::kill(pid, libc::SIGALRM) };
                    std::thread::sleep(Duration::from_millis(500));
                    (65536, 0, false)
                }
                Reader::TakeThenStop(n) => {
                    until_full(fd);
                    let at = t0.elapsed().as_millis();
                    let mut buf = vec![0u8; n];
                    if let Ok(k) = std::io::Read::read(&mut r, &mut buf) {
                        got.extend_from_slice(&buf[..k]);
                    }
                    return (got, Some(r), Some(at));
                }
                _ => (65536, 0, false),
            };
            let at = t0.elapsed().as_millis();
            let mut buf = vec![0u8; step];
            while to_end || !got.contains(&b'\n') {
                match std::io::Read::read(&mut r, &mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => got.extend_from_slice(&buf[..n]),
                }
                std::thread::sleep(Duration::from_millis(every));
            }
            (got, None, (reader == Reader::AfterNote).then_some(at))
        })
    });
    let end = t0 + Duration::from_secs(20);
    let (mut counted, mut last) = (None, (0, Instant::now()));
    let st = loop {
        if let Some(s) = c.try_wait().unwrap() {
            break Some(s);
        }
        if let (true, None, Some(fd)) = (o.threads_when_full, &counted, rfd) {
            let w = waiting(fd);
            if w != last.0 {
                last = (w, Instant::now());
            } else if w > 0 && last.1.elapsed() >= Duration::from_millis(200) {
                counted = Some(threads(c.id()));
            }
        }
        if Instant::now() > end {
            common::send_child(&mut c, libc::SIGKILL);
            let _ = c.wait();
            break None;
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    let ms = t0.elapsed().as_millis();
    let nonblock_after = keep.as_ref().map(|k| unsafe { libc::fcntl(std::os::fd::AsRawFd::as_raw_fd(k), libc::F_GETFL) } & libc::O_NONBLOCK != 0);
    drop(keep);
    let (mut got, held, read_at_ms) = reading.map(|t| t.join().unwrap()).unwrap_or_default();
    // a held reader and the full stderr are released only now, after sheepr's end; what a held
    // reader's pipe still holds is exactly what sheepr wrote after its read (every writer is gone)
    if let Some(mut r) = held {
        let _ = std::io::Read::read_to_end(&mut r, &mut got);
    }
    drop(held_err);
    Piped {
        code: st.and_then(|s| s.code()),
        signal: st.and_then(|s| std::os::unix::process::ExitStatusExt::signal(&s)),
        stderr: std::fs::read_to_string(&err).unwrap_or_default(),
        trace: std::fs::read_to_string(&trace).unwrap_or_default(),
        got,
        ms,
        read_at_ms,
        threads: counted.flatten(),
        nonblock_after,
    }
}

/// The trace's `status-undelivered CAUSE MS SENT/TOTAL` note, if any: (cause, ms).
fn undelivered(p: &Piped) -> Option<(String, u64)> {
    let (cause, ms, _) = undelivered_sent(p)?;
    Some((cause, ms))
}

/// The same note with SENT: (cause, ms, sent).
fn undelivered_sent(p: &Piped) -> Option<(String, u64, usize)> {
    let l = p.trace.lines().find(|l| l.starts_with("status-undelivered "))?;
    let mut w = l.split_whitespace().skip(1);
    Some((w.next()?.to_string(), w.next()?.parse().ok()?, w.next()?.split('/').next()?.parse().ok()?))
}

/// The debug seam that shortens the 10 s idle limit for a cell.
const IDLE_1S: (&str, &str) = ("SHEEPR_TEST_STATUS_IDLE_MS", "1000");

/// The notice: under `--quiet` it is the only line, and it is sheepr's own.
fn one_notice(p: &Piped) -> bool {
    let l: Vec<&str> = p.stderr.lines().collect();
    l.len() == 1 && l[0].starts_with("sheepr: ")
}

/// The whole status line arrived and parses, with the command's code.
fn whole(p: &Piped, pad: usize) -> bool {
    p.got.len() > pad && p.got.ends_with(b"\n") && json::parse(String::from_utf8_lossy(&p.got).trim_end()).ok().and_then(|s| s.get("code").and_then(Json::num)) == Some(7.0)
}

/// Issue #14: the status line never holds sheepr's exit. Against a line larger than any pipe
/// buffer (1 MiB of debug pad) and a reader that never reads, sheepr exits with the command's
/// code once the fd has accepted nothing for its idle limit (a seam makes it 3 s here; 10 s by
/// default), and not much later (a buffer that fills at once is progress: the window starts
/// at the write that waits, so the give-up is one idle, not two); it says so in one stderr line
/// (also under `--quiet`), and it never touches the flags of the write end it was given. What
/// the pipe holds after the end is exactly the count the note gives. While it waits, sheepr has
/// one thread (review of fa07b06, P3-2: no writer thread of any kind). The control drains: the
/// whole line arrives, and stderr and the trace say nothing.
#[test]
fn a_reader_that_never_reads_cannot_hold_sheeprs_exit() {
    let d = scratch("stuck");
    let pad = 1 << 20;
    let stuck = piped(&d, "stuck", Reader::Stuck, pad, Opts { env: &[("SHEEPR_TEST_STATUS_IDLE_MS", "3000")], threads_when_full: true, ..Default::default() });
    assert_eq!(stuck.code, Some(7), "sheepr did not exit within 20 s (or not with the command's code); trace:\n{}", stuck.trace);
    let (cause, ms, sent) = undelivered_sent(&stuck).unwrap_or_else(|| panic!("no status-undelivered note:\n{}", stuck.trace));
    assert_eq!(cause, "timeout");
    assert!((3000..5500).contains(&ms), "waited {ms} ms for the reader, not its 3 s");
    assert_eq!(stuck.got.len(), sent, "the note's count is not what the pipe holds");
    assert!(one_notice(&stuck), "stderr: {:?}", stuck.stderr);
    assert_eq!(stuck.nonblock_after, Some(false), "the caller's write end was left non-blocking");
    assert_eq!(stuck.threads, Some(1), "sheepr's threads while it waits on the line");
    let drain = piped(&d, "drain", Reader::Drain, pad, Opts { env: &[IDLE_1S], ..Default::default() });
    assert_eq!(drain.code, Some(7), "control");
    assert!(whole(&drain, pad), "control: {} bytes", drain.got.len());
    assert_eq!(undelivered(&drain), None, "control:\n{}", drain.trace);
    assert!(drain.stderr.trim().is_empty(), "control: --quiet printed {}", drain.stderr);
    assert_eq!(drain.nonblock_after, Some(false), "control: the caller's write end was left non-blocking");
    let _ = std::fs::remove_dir_all(&d);
}

/// Whole-branch review P2-2: the stated default holds in the build as shipped, not only under the
/// seams: with no idle seam, a stuck reader is cut 10 s after the pipe filled (README's number).
/// (The 30 s cap and the 1 s notice are pinned by the unit cell in src/status.rs.)
#[test]
fn the_default_idle_is_ten_seconds() {
    let d = scratch("default");
    let x = piped(&d, "default", Reader::Stuck, 1 << 20, Opts::default());
    assert_eq!(x.code, Some(7), "{}", x.trace);
    let (cause, ms) = undelivered(&x).unwrap_or_else(|| panic!("no status-undelivered note:\n{}", x.trace));
    assert_eq!(cause, "timeout");
    assert!((10_000..13_000).contains(&ms), "cut after {ms} ms, not the default 10 s");
    let _ = std::fs::remove_dir_all(&d);
}

/// Review of a1419bc, P2-3: the idle limit counts only the time the fd accepts nothing. A reader
/// that reads slowly but steadily (4 KiB every 25 ms) gets the whole 400 KiB line, which takes
/// it longer than the 1 s idle. A steady reader of a line too large for it is cut at the cap (a
/// seam makes it 3 s here, apart from the idle, review of a19592d F6; 30 s by default); the
/// control, a stuck reader under the same seams, is cut by the idle, before the cap. With a full
/// stderr too, sheepr still ends within the cap, one idle of tick, and the notice's 1 s (F5).
#[test]
fn a_slow_reader_gets_the_line_and_the_cap_still_ends_it() {
    let d = scratch("slow");
    let pad = 400 << 10;
    let cap = ("SHEEPR_TEST_STATUS_CAP_MS", "3000");
    let slow = piped(&d, "slow", Reader::Slow(4096, 25), pad, Opts { env: &[IDLE_1S], ..Default::default() });
    assert_eq!(slow.code, Some(7), "{}", slow.trace);
    assert_eq!(undelivered(&slow), None, "a reader that kept reading was cut:\n{}", slow.trace);
    assert!(whole(&slow, pad), "{} bytes", slow.got.len());
    let capped = piped(&d, "capped", Reader::Slow(4096, 300), 1 << 20, Opts { env: &[IDLE_1S, cap], ..Default::default() });
    assert_eq!(capped.code, Some(7), "sheepr did not exit within 20 s:\n{}", capped.trace);
    let (cause, ms) = undelivered(&capped).unwrap_or_else(|| panic!("no status-undelivered note:\n{}", capped.trace));
    assert_eq!(cause, "cap");
    assert!((3000..6000).contains(&ms), "capped at {ms} ms, not at 3 s");
    assert!(one_notice(&capped), "stderr: {:?}", capped.stderr);
    let stuck = piped(&d, "stuck", Reader::Stuck, 1 << 20, Opts { env: &[IDLE_1S, cap], ..Default::default() });
    let (cause, ms) = undelivered(&stuck).unwrap_or_else(|| panic!("control: no note:\n{}", stuck.trace));
    assert_eq!(cause, "timeout", "control");
    assert!(ms < 3000, "control: {ms} ms, not the idle's 1 s");
    let full = piped(&d, "capped-full", Reader::Slow(4096, 300), 1 << 20, Opts { env: &[IDLE_1S, cap], full_stderr: true, ..Default::default() });
    assert_eq!(full.code, Some(7), "{}", full.trace);
    assert!(full.ms < 3000 + 1000 + 1000 + 4000, "a capped line and a full stderr took {} ms", full.ms);
    let _ = std::fs::remove_dir_all(&d);
}

/// Issue #14: a reader that has closed its end gets no line, and sheepr says so on stderr (also
/// under `--quiet`) and keeps the command's code. Review of a1419bc, P2-1: a full stderr that
/// nobody reads cannot hold sheepr's exit either: the notice waits at most 1 s, also with the
/// default 10 s idle (review of fa07b06, P2-2).
#[test]
fn a_closed_status_reader_is_said_on_stderr() {
    let d = scratch("closed");
    let x = piped(&d, "closed", Reader::Closed, 0, Opts::default());
    assert_eq!(x.code, Some(7), "{}", x.trace);
    assert_eq!(undelivered(&x).map(|u| u.0), Some("closed".to_string()), "{}", x.trace);
    assert!(one_notice(&x), "stderr: {:?}", x.stderr);
    let full = piped(&d, "full", Reader::Closed, 0, Opts { full_stderr: true, ..Default::default() });
    assert_eq!(full.code, Some(7), "a full stderr held sheepr; trace:\n{}", full.trace);
    assert_eq!(undelivered(&full).map(|u| u.0), Some("closed".to_string()), "{}", full.trace);
    // on sheepr's own clock (no process start in it): the notice waited its 1 s on the full stderr
    // (so stderr was full) and no more; the control's stderr took it at once
    let notice = |p: &Piped| p.trace.lines().find_map(|l| l.strip_prefix("status-notice ")?.parse::<u64>().ok());
    assert!(notice(&full).is_some_and(|ms| (900..2000).contains(&ms)), "the notice to a full stderr: {:?} ms, not its 1 s", notice(&full));
    assert!(notice(&x).is_some_and(|ms| ms < 500), "control: the notice to a stderr that takes it: {:?} ms", notice(&x));
    // and the full stderr holds sheepr's whole exit no longer than that (the control runs first
    // and takes any first-launch delay, so this upper bound cannot be made red by a cold start)
    assert!(full.ms < x.ms + 2000, "a full stderr held sheepr {} ms more than the control", full.ms.saturating_sub(x.ms));
    let _ = std::fs::remove_dir_all(&d);
}

/// Review of a1419bc, P2-2: before sheepr has blocked its signals (a usage error, a panic early
/// in `run`) SIGPIPE still has the caller's action, the default for most callers. A closed
/// status reader there is a closed reader like any other: exit 125, never death by SIGPIPE.
#[test]
fn a_closed_reader_before_the_job_is_not_a_sigpipe_death() {
    let d = scratch("early");
    let usage = piped(&d, "usage", Reader::Closed, 0, Opts { args: &["--timeout", "bad"], ..Default::default() });
    let panic = piped(&d, "panic", Reader::Closed, 0, Opts { env: &[("SHEEPR_TEST_PANIC_IN_RUN", "1")], ..Default::default() });
    for (n, x) in [("usage", &usage), ("panic", &panic)] {
        assert_eq!((x.code, x.signal), (Some(125), None), "{n}: {}", x.stderr);
        assert_eq!(undelivered(x).map(|u| u.0), Some("closed".to_string()), "{n}: {}", x.trace);
    }
    let _ = std::fs::remove_dir_all(&d);
}

/// Review of a19592d, F1: the line needs no new thread, so a process that cannot start one (a
/// pids limit the job used up; here a stack no `std::thread` can get) still delivers it whole.
/// The thread count in the stuck cell is the wider check.
#[test]
fn the_line_needs_no_new_thread() {
    let d = scratch("nothread");
    let pad = 1 << 20;
    let x = piped(&d, "nothread", Reader::Drain, pad, Opts { env: &[("RUST_MIN_STACK", "1125899906842624")], ..Default::default() });
    assert_eq!(x.code, Some(7), "{}", x.trace);
    assert!(whole(&x, pad), "{} bytes; trace:\n{}", x.got.len(), x.trace);
    let _ = std::fs::remove_dir_all(&d);
}

/// Review of a19592d, F3, and of fa07b06, P2-1: once sheepr gives up, nothing more is written.
/// The reader waits for the give-up note, then reads to the end of the pipe while sheepr is
/// still alive (its notice waits on a full stderr): it gets exactly the count the note gives.
#[test]
fn nothing_is_written_after_the_give_up() {
    let d = scratch("late");
    let pad = 1 << 20;
    let late = piped(&d, "late", Reader::AfterNote, pad, Opts { env: &[IDLE_1S], full_stderr: true, ..Default::default() });
    assert_eq!(late.code, Some(7), "{}", late.trace);
    let (cause, _, sent) = undelivered_sent(&late).unwrap_or_else(|| panic!("no status-undelivered note:\n{}", late.trace));
    assert_eq!(cause, "timeout");
    let at = late.read_at_ms.expect("the reader read");
    assert!(at < late.ms, "the reader started at {at} ms, after sheepr's end at {} ms: the cell proves nothing", late.ms);
    assert_eq!(late.got.len(), sent, "bytes were written after sheepr gave up");
    let _ = std::fs::remove_dir_all(&d);
}

/// Review of fa07b06, P2-3: a status fd the caller made non-blocking (the open file description
/// is shared) still waits for its reader: a reader that keeps reading gets the whole line, and
/// the flag is left as the caller set it. The control, a stuck reader on such an fd, is cut by
/// the idle, not at once by EAGAIN.
#[test]
fn a_non_blocking_status_fd_still_waits_for_its_reader() {
    let d = scratch("nonblock");
    let pad = 400 << 10;
    let x = piped(&d, "nonblock", Reader::Slow(65536, 5), pad, Opts { env: &[IDLE_1S], nonblock: true, ..Default::default() });
    assert_eq!(x.code, Some(7), "{}", x.trace);
    assert_eq!(undelivered(&x), None, "{}", x.trace);
    assert!(whole(&x, pad), "{} bytes", x.got.len());
    assert!(x.stderr.trim().is_empty(), "{}", x.stderr);
    assert_eq!(x.nonblock_after, Some(true), "the caller's O_NONBLOCK was changed");
    let stuck = piped(&d, "nonblock-stuck", Reader::Stuck, pad, Opts { env: &[IDLE_1S], nonblock: true, ..Default::default() });
    let (cause, ms) = undelivered(&stuck).unwrap_or_else(|| panic!("control: no note:\n{}", stuck.trace));
    assert_eq!(cause, "timeout", "control: {}", stuck.trace);
    assert!(ms >= 1000, "control: cut after {ms} ms, not after the idle");
    let _ = std::fs::remove_dir_all(&d);
}

/// Review of 03da4f8, F2: when poll says the fd is ready but each write says EAGAIN (a FUSE file
/// can; a debug seam does it here), sheepr still gives up within the idle, not spins for ever.
#[test]
fn an_fd_that_is_ready_but_takes_nothing_is_cut_at_the_idle() {
    let d = scratch("eagain");
    let x = piped(&d, "eagain", Reader::Drain, 0, Opts { env: &[IDLE_1S, ("SHEEPR_TEST_STATUS_EAGAIN", "1")], ..Default::default() });
    assert_eq!(x.code, Some(7), "sheepr did not exit within 20 s:\n{}", x.trace);
    let (cause, ms) = undelivered(&x).unwrap_or_else(|| panic!("no status-undelivered note:\n{}", x.trace));
    assert_eq!(cause, "timeout");
    assert!((1000..3000).contains(&ms), "cut after {ms} ms, not at the 1 s idle");
    let _ = std::fs::remove_dir_all(&d);
}

/// Issue #14 ("a write interrupted by a signal is retried, so the line is never cut"; whole-branch
/// review P3-1): one SIGALRM sent from outside while the line waits on a full pipe does not end
/// the write (only the timer's own tick, a full window in, does): a reader that then drains gets
/// the whole line, and nothing is said. The idle (5 s) is far longer than the 500 ms between the
/// signal and the drain, so a give-up there can only be the signal's.
#[test]
fn a_signal_from_outside_does_not_cut_the_line() {
    let d = scratch("alarm");
    let pad = 200 << 10;
    let x = piped(&d, "alarm", Reader::AlarmThenDrain, pad, Opts { env: &[("SHEEPR_TEST_STATUS_IDLE_MS", "5000")], ..Default::default() });
    assert_eq!(x.code, Some(7), "{}", x.trace);
    assert_eq!(undelivered(&x), None, "a SIGALRM from outside cut the line:\n{}", x.trace);
    assert!(whole(&x, pad), "{} bytes", x.got.len());
    assert!(x.stderr.trim().is_empty(), "{}", x.stderr);
    // the signal landed in the blocked write and the write was tried again: not a vacuous pass
    assert_eq!(retries(&x, "write"), 1, "{}", x.trace);
    let _ = std::fs::remove_dir_all(&d);
}

/// The same on a non-blocking fd (review of 5ef936c, P2): there the signal ends sheepr's poll for
/// room, not a write, and that poll is tried again too.
#[test]
fn a_signal_from_outside_does_not_cut_a_non_blocking_line() {
    let d = scratch("alarm-nb");
    let pad = 200 << 10;
    let x = piped(&d, "alarm-nb", Reader::AlarmThenDrain, pad, Opts { env: &[("SHEEPR_TEST_STATUS_IDLE_MS", "5000")], nonblock: true, ..Default::default() });
    assert_eq!(x.code, Some(7), "{}", x.trace);
    assert_eq!(undelivered(&x), None, "a SIGALRM from outside cut the line:\n{}", x.trace);
    assert!(whole(&x, pad), "{} bytes", x.got.len());
    assert!(x.stderr.trim().is_empty(), "{}", x.stderr);
    assert_eq!(retries(&x, "poll"), 1, "{}", x.trace);
    let _ = std::fs::remove_dir_all(&d);
}

/// The trace's `status-retry KIND` notes: a write or a poll that a signal from outside ended
/// before its window, tried again.
fn retries(p: &Piped, kind: &str) -> usize {
    p.trace.lines().filter(|l| *l == format!("status-retry {kind}")).count()
}

/// Review of fa07b06, P3-1: a reader that takes part of a write and stops is cut one idle after
/// it stopped, not two: each write is at most PIPE_BUF (512 on macOS), which a pipe takes whole
/// or not at all, so no write waits on with part of it taken. (Linux pipes take 4096 whole, so
/// there this cell holds either way.)
#[test]
fn a_reader_that_takes_part_of_a_write_is_cut_after_one_idle() {
    let d = scratch("part");
    let x = piped(&d, "part", Reader::TakeThenStop(1000), 1 << 20, Opts { env: &[("SHEEPR_TEST_STATUS_IDLE_MS", "2000")], ..Default::default() });
    assert_eq!(x.code, Some(7), "{}", x.trace);
    assert_eq!(undelivered(&x).map(|u| u.0), Some("timeout".to_string()), "{}", x.trace);
    let at = x.read_at_ms.expect("the reader read");
    assert!(x.ms - at < 3000, "cut {} ms after the reader stopped, not one 2 s idle", x.ms - at);
    let _ = std::fs::remove_dir_all(&d);
}

/// Review of fa07b06, P3-3: with stderr the status pipe itself (`3>&2`), the notice after a cut
/// line starts a line of its own: the line's part, a newline, then `sheepr: `.
#[test]
fn a_notice_after_a_cut_line_in_the_same_file_starts_a_line() {
    let d = scratch("shared");
    let x = piped(&d, "shared", Reader::AfterNote, 1 << 20, Opts { env: &[IDLE_1S], shared_stderr: true, ..Default::default() });
    assert_eq!(x.code, Some(7), "{}", x.trace);
    let out = String::from_utf8_lossy(&x.got);
    let at = out.find("sheepr: ").unwrap_or_else(|| panic!("no notice in the shared pipe:\n{}", x.trace));
    assert!(out.starts_with("{\"v\":1"), "the line's part comes first");
    assert_eq!(&out[at - 1..at], "\n", "the notice does not start a line");
    assert!(!out[..at - 1].contains('\n'), "the cut line holds a newline");
    assert!(out[at..].ends_with(".\n") && out[at..].lines().count() == 1, "the notice is one line at the end");
    let _ = std::fs::remove_dir_all(&d);
}

/// Review P2-5: `--status-fd` 0, 1 or 2 would take the command's own stream (it is set
/// close-on-exec): a usage error (125), and the command does not run.
#[test]
fn the_status_fd_is_never_a_standard_stream() {
    let d = scratch("stdfd");
    for fd in ["0", "1", "2"] {
        let ran = d.join(format!("ran{fd}"));
        let st = Command::new(sheepr()).args(["run", "--status-fd", fd, "--", "/bin/sh", "-c", &format!(r#"touch "{}""#, ran.display())]).stderr(std::process::Stdio::null()).status().unwrap();
        assert_eq!(st.code(), Some(125), "--status-fd {fd}");
        assert!(!ran.exists(), "--status-fd {fd}: the command ran");
    }
    let _ = std::fs::remove_dir_all(&d);
}

// ---- #17: the root's own end, `root_code` and `root_signal` ----

/// `root`, `root_code` and `root_signal` of a run, as (str, number, number) with null as None.
fn root_end(r: &Run) -> (Option<String>, Option<i64>, Option<i64>) {
    let num = |k: &str| field(r, k).and_then(Json::num).map(|n| n as i64);
    (field(r, "root").and_then(Json::str).map(String::from), num("root_code"), num("root_signal"))
}

/// Both fields are in the line, as null (not missing).
fn both_null(r: &Run) -> bool {
    field(r, "root_code") == Some(&Json::Null) && field(r, "root_signal") == Some(&Json::Null)
}

/// Wait (20 s at most) for `p` to exist.
fn wait_file(p: &Path) -> bool {
    let end = Instant::now() + Duration::from_secs(20);
    while !p.exists() && Instant::now() < end {
        std::thread::sleep(Duration::from_millis(5));
    }
    p.exists()
}

/// #17: the root's own end is in the line: an exit code in `root_code`, a signal in
/// `root_signal` (each null when the other applies), and `root` agrees (option A). Also when the
/// kill misses its deadline after the root exited 3 (exit 125, `root_code` 3). The control, a
/// root that exits 0, has `root_code` 0, not null.
#[test]
fn the_root_s_own_end_is_in_root_code_and_root_signal() {
    let d = scratch("rootend");
    let m = marker();
    let r = d.join("rec");
    let missed = run(
        &d,
        "missed",
        &format!(r#"--grace 0 -- /bin/sh -c '"$FX" escape {m} "{}"; exit 3'"#, r.display()),
        &[("SHEEPR_TEST_NOKILL", "1"), ("SHEEPR_TEST_DEADLINE_MS", "500")],
        |_| {},
    );
    for p in records(&r, 1) {
        common::send(p.0, p.1, libc::SIGKILL);
    }
    let zero = run(&d, "zero", r#"-- /bin/sh -c 'exit 0'"#, &[], |_| {});
    let killed = run(&d, "killed", r#"-- /bin/sh -c 'kill -KILL $$'"#, &[], |_| {});
    let termed = run(&d, "termed", r#"-- /bin/sh -c 'kill -TERM $$'"#, &[], |_| {});
    assert_eq!(missed.code, Some(125), "{:?}", missed.status);
    assert_eq!(field(&missed, "deadline_missed"), Some(&Json::Bool(true)));
    assert_eq!(root_end(&missed), (Some("exited".into()), Some(3), None), "{:?}", missed.status);
    assert_eq!(zero.code, Some(0));
    assert_eq!(root_end(&zero), (Some("exited".into()), Some(0), None), "{:?}", zero.status);
    assert_eq!(field(&zero, "root_signal"), Some(&Json::Null), "a null field is written as null");
    assert_eq!(killed.code, Some(128 + libc::SIGKILL));
    assert_eq!(root_end(&killed), (Some("signaled".into()), None, Some(libc::SIGKILL as i64)), "{:?}", killed.status);
    assert_eq!(field(&killed, "root_code"), Some(&Json::Null), "a null field is written as null");
    assert_eq!(termed.code, Some(128 + libc::SIGTERM));
    assert_eq!(root_end(&termed), (Some("signaled".into()), None, Some(libc::SIGTERM as i64)), "{:?}", termed.status);
    assert_eq!(field(&termed, "trigger"), Some(&Json::Null), "the root's own TERM is no trigger");
    let _ = std::fs::remove_dir_all(&d);
}

/// #17: under a trigger the fields say how sheepr's kill ended the root. A TERM from outside: the
/// root (a `sleep`) dies of the grace's TERM, `root_signal` 15, `trigger` "term". A timeout with
/// a root that traps TERM and exits 0 during the grace: `root` "exited", `root_code` 0, exit 124.
/// On macOS the root is reaped after the kill here (the visible root: the control of the hidden
/// root's row).
#[test]
fn under_a_trigger_the_root_fields_say_how_the_kill_ended_it() {
    let d = scratch("trigend");
    let (m1, m2) = (marker(), marker());
    let (ready, trace) = (d.join("ready"), d.join("trace"));
    let termed = run(&d, "term", &format!(r#"-- /bin/sh -c 'touch "{}"; exec /bin/sleep {m1}'"#, ready.display()), &[("SHEEPR_TEST_TRACE", trace.to_str().unwrap())], |c| {
        wait_file(&ready);
        common::send_child(c, libc::SIGTERM);
    });
    kill_marked(&m1);
    if cfg!(target_os = "macos") {
        // the visible root: the reap after the kill took it (the hidden root's control)
        let t = std::fs::read_to_string(&trace).unwrap_or_default();
        assert!(t.lines().any(|l| l == "root-after-kill reaped"), "trace:\n{t}");
    }
    let timed = run(&d, "timeout", &format!(r#"--timeout 1s -- /bin/sh -c 'trap "exit 0" TERM; /bin/sleep {m2} & wait'"#), &[], |_| {});
    kill_marked(&m2);
    assert_eq!(termed.code, None, "sheepr dies of the TERM: {:?}", termed.status);
    assert_eq!(field(&termed, "trigger").and_then(Json::str), Some("term"));
    assert_eq!(root_end(&termed), (Some("signaled".into()), None, Some(libc::SIGTERM as i64)), "{:?}", termed.status);
    assert_eq!(timed.code, Some(124), "{:?}", timed.status);
    assert_eq!(field(&timed, "trigger").and_then(Json::str), Some("timeout"));
    assert_eq!(root_end(&timed), (Some("exited".into()), Some(0), None), "{:?}", timed.status);
    let _ = std::fs::remove_dir_all(&d);
}

/// Every live `/bin/sleep MARKER` of this test, killed (a leak from a failed row).
fn kill_marked(m: &str) {
    common::kill_marked(&[m]);
}

/// #17, round 3 N1 (macOS): after the kill sheepr never waits on a root that may still be alive.
/// A debug seam hides the root from the scan (as a setuid root is hidden), so the kill cannot
/// end it: on TERM sheepr still ends within 5 s (far inside README's bound: the kill deadline
/// plus about 31 s), with `root` "signaled" and both fields null (its end was not observed), and
/// the root is still alive then (the seam took effect). The control is the visible root of
/// `under_a_trigger_the_root_fields_say_how_the_kill_ended_it`: `root_signal` 15.
#[cfg(target_os = "macos")]
#[test]
fn a_root_the_scan_cannot_see_never_holds_sheeprs_end() {
    let d = scratch("hidden");
    let m = marker();
    let (pidf, trace) = (d.join("pid"), d.join("trace"));
    let took = std::cell::Cell::new(None::<Instant>);
    let mut root = None;
    let x = run(
        &d,
        "hidden",
        &format!(r#"--grace 0 -- /bin/sh -c 'echo $$ > "{}.t" && mv "{}.t" "{}"; exec /bin/sleep {m}'"#, pidf.display(), pidf.display(), pidf.display()),
        &[("SHEEPR_TEST_HIDE_ROOT", "1"), ("SHEEPR_TEST_TRACE", trace.to_str().unwrap())],
        |c| {
            wait_file(&pidf);
            root = std::fs::read_to_string(&pidf).ok().and_then(|s| s.trim().parse::<i32>().ok()).and_then(common::found);
            // the root has exec'd its sleep (its command line names the marker)
            let end = Instant::now() + Duration::from_secs(10);
            while common::scan(&m, |w| w.get(1) == Some(&"/bin/sleep")).map_or(true, |v| v.is_empty()) && Instant::now() < end {
                std::thread::sleep(Duration::from_millis(5));
            }
            took.set(Some(Instant::now()));
            common::send_child(c, libc::SIGTERM);
        },
    );
    let elapsed = took.get().map(|t| t.elapsed());
    let alive = root.is_some_and(common::alive);
    if let Some(p) = root {
        common::send(p.0, p.1, libc::SIGKILL);
    }
    kill_marked(&m);
    assert!(root.is_some(), "the root never wrote its pid");
    assert!(elapsed.is_some_and(|e| e < Duration::from_secs(5)), "sheepr took {elapsed:?} to end after the TERM");
    assert!(alive, "control: the hidden root was killed, so the seam did not hide it");
    // it saw the root alive and did not wait for it (never the bounded poll's 1 s)
    let t = std::fs::read_to_string(&trace).unwrap_or_default();
    assert!(t.lines().any(|l| l == "root-after-kill alive"), "trace:\n{t}");
    assert_eq!(x.code, None, "sheepr dies of the TERM: {:?}", x.status);
    assert_eq!(field(&x, "trigger").and_then(Json::str), Some("term"));
    assert_eq!(field(&x, "root").and_then(Json::str), Some("signaled"), "{:?}", x.status);
    assert!(both_null(&x), "{:?}", x.status);
    let _ = std::fs::remove_dir_all(&d);
}

/// #17, round 3 N2 (macOS `--mode root-disclaim`): the recorder keys on the root's pid there
/// too: a root that exits 3 is "exited" with `root_code` 3. Its TERM path does not reap the root
/// (stated), so a TERM from outside reads "signaled" with both fields null and `trigger` "term"
/// (it read "not-started" before).
#[cfg(target_os = "macos")]
#[test]
fn root_disclaim_records_the_root_s_end() {
    let d = scratch("rdisclaim");
    let m = marker();
    let ready = d.join("ready");
    let own = run(&d, "own", r#"--mode root-disclaim -- /bin/sh -c 'exit 3'"#, &[], |_| {});
    let termed = run(&d, "term", &format!(r#"--mode root-disclaim -- /bin/sh -c 'touch "{}"; exec /bin/sleep {m}'"#, ready.display()), &[], |c| {
        wait_file(&ready);
        common::send_child(c, libc::SIGTERM);
    });
    kill_marked(&m);
    assert_eq!(own.code, Some(3));
    assert_eq!(root_end(&own), (Some("exited".into()), Some(3), None), "{:?}", own.status);
    assert_eq!(termed.code, None, "sheepr dies of the TERM: {:?}", termed.status);
    assert_eq!(field(&termed, "trigger").and_then(Json::str), Some("term"));
    assert_eq!(field(&termed, "root").and_then(Json::str), Some("signaled"), "{:?}", termed.status);
    assert!(both_null(&termed), "{:?}", termed.status);
    let _ = std::fs::remove_dir_all(&d);
}

/// #17 (macOS): a wait on the root that fails is a lost end, never a made-up status. A debug seam
/// replaces the result of the root's reap with a failure (the real wait runs): exit 125 as
/// before, `root` "signaled" with both fields null, `trigger` null, and `error` names it. The
/// control, the same root without the seam, exits 3 with `root_code` 3 and no error.
#[cfg(target_os = "macos")]
#[test]
fn a_lost_wait_on_the_root_makes_up_no_status() {
    let d = scratch("lost");
    let lost = run(&d, "lost", r#"-- /bin/sh -c 'exit 3'"#, &[("SHEEPR_TEST_ROOT_WAIT_LOST", "1")], |_| {});
    let ctl = run(&d, "ctl", r#"-- /bin/sh -c 'exit 3'"#, &[], |_| {});
    // polling mode (the exit's kqueue watch refused): the seam acts only on the blocking wait,
    // so it never takes a poll's reap (that hung sheepr: its status gone, every later poll
    // ECHILD). Polling mode has no blocking wait, so its poll takes the root's own end there
    let log = d.join("polled.log");
    let t0 = Instant::now();
    let polled = run(&d, "polled", r#"-- /bin/sh -c 'exit 3'"#, &[("SHEEPR_TEST_ROOT_WAIT_LOST", "1"), ("SHEEPR_TEST_KQ_EINVAL", "1"), ("SHEEPR_TEST_SIGNAL_LOG", log.to_str().unwrap())], |_| {});
    let polled_took = t0.elapsed();
    let l = std::fs::read_to_string(&log).unwrap_or_default();
    assert!(l.lines().any(|x| x == "polling exit"), "control: polling mode was not on; signal log:\n{l}");
    assert!(polled_took < Duration::from_secs(10), "polling mode with the lost-wait seam took {polled_took:?}: {:?}", polled.status);
    assert_eq!(polled.code, Some(3), "{:?}", polled.status);
    assert_eq!(root_end(&polled), (Some("exited".into()), Some(3), None), "{:?}", polled.status);
    assert_eq!(field(&polled, "error"), Some(&Json::Null), "{:?}", polled.status);
    assert_eq!(ctl.code, Some(3));
    assert_eq!(root_end(&ctl), (Some("exited".into()), Some(3), None), "control: {:?}", ctl.status);
    assert_eq!(field(&ctl, "error"), Some(&Json::Null));
    assert_eq!(lost.code, Some(125), "{:?}", lost.status);
    assert_eq!(field(&lost, "root").and_then(Json::str), Some("signaled"), "{:?}", lost.status);
    assert!(both_null(&lost), "{:?}", lost.status);
    assert_eq!(field(&lost, "trigger"), Some(&Json::Null));
    assert!(field(&lost, "error").and_then(Json::str).is_some_and(|e| e.contains("lost")), "{:?}", lost.status);
    let _ = std::fs::remove_dir_all(&d);
}

/// The children of `pid` (Linux, from /proc), with their state letter.
#[cfg(target_os = "linux")]
fn children_of(pid: i32) -> Vec<(i32, char)> {
    let mut v = Vec::new();
    for e in std::fs::read_dir("/proc").into_iter().flatten().flatten() {
        let Some(p) = e.file_name().to_str().and_then(|n| n.parse::<i32>().ok()) else { continue };
        let Ok(s) = std::fs::read_to_string(format!("/proc/{p}/stat")) else { continue };
        let Some(rest) = s.rfind(')').and_then(|i| s.get(i + 2..)) else { continue };
        let mut w = rest.split_whitespace();
        let (Some(st), Some(pp)) = (w.next().and_then(|x| x.chars().next()), w.next().and_then(|x| x.parse::<i32>().ok())) else { continue };
        if pp == pid {
            v.push((p, st));
        }
    }
    v
}

/// One run of `cmd` in which the root's end and a TERM from outside reach sheepr in ONE wake
/// (Linux, tests/loop.rs's window): the loop sleeps 4 s before each wait (seam), the shim is held
/// before its exec (seam) and let go 1 s into the loop's first sleep; once it is a zombie
/// (exited, not reaped) sheepr gets TERM, so its next pass both reaps it and takes the TERM.
/// Returns the run, and whether the zombie was seen before the TERM.
#[cfg(target_os = "linux")]
fn term_with_the_root_s_end(d: &Path, name: &str, cmd: &str) -> (Run, bool) {
    let (ready, rel) = (d.join(format!("{name}.ready")), d.join(format!("{name}.release")));
    let mut zombie = false;
    let x = run(
        d,
        name,
        &format!("-- {cmd}"),
        &[("SHEEPR_TEST_SLEEP_BEFORE_WAIT_MS", "4000"), ("SHEEPR_TEST_HOLD_SHIM", rel.to_str().unwrap()), ("SHEEPR_TEST_READY_FILE", ready.to_str().unwrap())],
        |c| {
            wait_file(&ready);
            // both the held shim and the loop's first sleep create the ready file; the loop's first
            // pass takes milliseconds, so 1 s in, it sleeps (until about 4 s)
            std::thread::sleep(Duration::from_secs(1));
            std::fs::write(&rel, b"").unwrap();
            let sd = c.id() as i32;
            let end = Instant::now() + Duration::from_secs(2);
            while !zombie && Instant::now() < end {
                zombie = children_of(sd).iter().any(|&(_, st)| st == 'Z');
                std::thread::sleep(Duration::from_millis(2));
            }
            common::send_child(c, libc::SIGTERM);
        },
    );
    (x, zombie)
}

/// #17 (Linux): a command that cannot be run and a TERM from outside in the same wake: the
/// shim's `E` line is read whenever the shim was reaped, also when the TERM won that pass, so
/// the root is "not-started" with both fields null and `error` names ENOENT (it read "signaled"
/// before). The control, a command that runs and exits 127 by itself in the same window, is
/// "exited" with `root_code` 127 and no error. In both, sheepr dies of the TERM (a run that
/// exits 127 instead means the window closed before the TERM: the harness, not the product).
#[cfg(target_os = "linux")]
#[test]
fn a_missing_command_and_a_term_in_one_wake_is_not_started() {
    let d = scratch("missterm");
    let (missing, z1) = term_with_the_root_s_end(&d, "missing", "/nonexistent/sr-missing");
    let (own, z2) = term_with_the_root_s_end(&d, "own", r#"/bin/sh -c 'exit 127'"#);
    for (n, x, z) in [("missing", &missing, z1), ("own", &own, z2)] {
        assert!(z, "{n}: the shim never became a zombie before the TERM");
        assert_eq!(x.code, None, "{n}: sheepr must die of the TERM (the window closed?): {:?}", x.status);
        assert_eq!(field(x, "trigger").and_then(Json::str), Some("term"), "{n}");
    }
    assert_eq!(field(&missing, "root").and_then(Json::str), Some("not-started"), "{:?}", missing.status);
    assert!(both_null(&missing), "{:?}", missing.status);
    let enoent = std::io::Error::from_raw_os_error(libc::ENOENT).to_string();
    assert!(field(&missing, "error").and_then(Json::str).is_some_and(|e| e.contains(&enoent)), "{:?}", missing.status);
    assert_eq!(root_end(&own), (Some("exited".into()), Some(127), None), "control: {:?}", own.status);
    assert_eq!(field(&own, "error"), Some(&Json::Null), "control");
    let _ = std::fs::remove_dir_all(&d);
}

/// One run of `cmd` whose shim reaches its exec only while the job is being killed (Linux): the
/// caller blocks TERM, so the kill's TERM stays pending in the shim and its exec goes ahead;
/// sheepr gets a TERM while the shim is held before its exec (seam), and the shim is let go
/// once the kill's grace has sent it that TERM (the signal log says so). The grace is 20 s, so a
/// slow (emulated) start of the released shim is never cut by the kill's SIGKILL; it ends as
/// soon as the shim has exited. Returns sheepr's exit code, the status line, and whether the
/// grace's TERM to the shim was seen before the release.
#[cfg(target_os = "linux")]
fn exec_during_the_kill(d: &Path, name: &str, cmd: &str) -> (Option<i32>, Option<Json>, bool) {
    use std::os::unix::process::CommandExt;
    let (out, ready, rel, log) = (d.join(format!("{name}.status")), d.join(format!("{name}.ready")), d.join(format!("{name}.release")), d.join(format!("{name}.log")));
    let mut c = Command::new("/bin/sh");
    c.args(["-c", &format!(r#"exec "$SD" run --grace 20s --status-fd 3 -- {cmd} 3>"{}" 2>/dev/null"#, out.display())])
        .env("SD", sheepr())
        .env("FX", fixture())
        .env("SHEEPR_TEST_HOLD_SHIM", &rel)
        .env("SHEEPR_TEST_READY_FILE", &ready)
        .env("SHEEPR_TEST_SIGNAL_LOG", &log);
    unsafe {
        c.pre_exec(|| {
            let mut s: libc::sigset_t = std::mem::zeroed();
            libc::sigemptyset(&mut s);
            libc::sigaddset(&mut s, libc::SIGTERM);
            libc::sigprocmask(libc::SIG_BLOCK, &s, std::ptr::null_mut());
            Ok(())
        });
    }
    let mut c = c.spawn().unwrap();
    let held = wait_file(&ready); // the shim is held before its exec
    let shim = children_of(c.id() as i32).first().map(|&(p, _)| p);
    common::send_child(&mut c, libc::SIGTERM);
    let end = Instant::now() + Duration::from_secs(10);
    let termed = loop {
        let l = std::fs::read_to_string(&log).unwrap_or_default();
        if shim.is_some_and(|p| l.lines().any(|x| x == format!("kill {p} 15") || x == format!("pidfd {p} 15"))) {
            break true;
        }
        if Instant::now() > end {
            break false;
        }
        std::thread::sleep(Duration::from_millis(5));
    };
    std::fs::write(&rel, b"").unwrap();
    let end = Instant::now() + Duration::from_secs(45);
    let code = loop {
        if let Some(s) = c.try_wait().unwrap() {
            break s.code();
        }
        if Instant::now() > end {
            common::send_child(&mut c, libc::SIGKILL);
            let _ = c.wait();
            break Some(-1);
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    let st = json::parse(std::fs::read_to_string(&out).unwrap_or_default().trim_end()).ok();
    (code, st, held && termed)
}

/// #17 (Linux): a command whose exec fails while the job is being killed (after the event loop
/// ended on a TERM): the shim's `E` line is read again after the final reap, so the root is
/// "not-started" with both fields null and `error` naming ENOENT. The control, a command that
/// runs during the kill and exits 127 by itself, is "exited" with `root_code` 127 and no error
/// (the fixture's `spawnp` of a missing program: no shell, which could unblock the pending TERM).
#[cfg(target_os = "linux")]
#[test]
fn a_command_whose_exec_fails_during_the_kill_is_not_started() {
    let d = scratch("killexec");
    let (c1, missing, w1) = exec_during_the_kill(&d, "missing", "/nonexistent/sr-missing");
    let (c2, own, w2) = exec_during_the_kill(&d, "own", r#""$FX" spawnp /nonexistent/sr-missing"#);
    let get = |j: &Option<Json>, k: &str| j.as_ref().and_then(|j| j.get(k)).cloned();
    for (n, code, x, w) in [("missing", c1, &missing, w1), ("own", c2, &own, w2)] {
        assert!(w, "{n}: the shim was not held, or the kill's TERM to it was never seen");
        assert_eq!(code, None, "{n}: sheepr dies of the TERM: {x:?}");
        assert_eq!(get(x, "trigger").as_ref().and_then(Json::str), Some("term"), "{n}: {x:?}");
    }
    assert_eq!(get(&missing, "root").as_ref().and_then(Json::str), Some("not-started"), "{missing:?}");
    assert_eq!((get(&missing, "root_code"), get(&missing, "root_signal")), (Some(Json::Null), Some(Json::Null)), "{missing:?}");
    let enoent = std::io::Error::from_raw_os_error(libc::ENOENT).to_string();
    assert!(get(&missing, "error").as_ref().and_then(Json::str).is_some_and(|e| e.contains(&enoent)), "{missing:?}");
    assert_eq!(get(&own, "root").as_ref().and_then(Json::str), Some("exited"), "control: {own:?}");
    assert_eq!(get(&own, "root_code").as_ref().and_then(Json::num), Some(127.0), "control: {own:?}");
    assert_eq!(get(&own, "error"), Some(Json::Null), "control: {own:?}");
    let _ = std::fs::remove_dir_all(&d);
}

/// The forms of a wait that can reap a child (#17's class sweep), on a line of code: an
/// identifier `waitpid`, `wait3`, `wait4` or `waitid`, or one that starts `SYS_wait` (a call, a
/// raw syscall, an import under another name, a function pointer); `libc::wait(`, or a `use` line
/// that names `wait`; std's `.wait()`, `.try_wait()` and `.wait_with_output()`. A `waitid` with
/// `WNOWAIT` on its line only looks; it is reported apart.
#[derive(Debug, PartialEq, PartialOrd, Eq, Ord, Clone)]
enum Wait {
    Reaps,
    Looks,
}

fn wait_form(line: &str) -> Option<Wait> {
    let words: Vec<&str> = line.split(|c: char| !(c.is_ascii_alphanumeric() || c == '_')).filter(|w| !w.is_empty()).collect();
    let named = |w: &&str| ["waitpid", "wait3", "wait4", "waitid"].contains(w) || w.starts_with("SYS_wait");
    let calls = [".wait()", ".try_wait()", ".wait_with_output()", "libc::wait("];
    let import = line.trim_start().starts_with("use ") && words.contains(&"wait");
    if words.iter().any(|w| *w == "waitid" || *w == "SYS_waitid") && !words.iter().any(|w| named(w) && !w.ends_with("waitid")) {
        return Some(if words.contains(&"WNOWAIT") { Wait::Looks } else { Wait::Reaps });
    }
    (words.iter().any(named) || import || calls.iter().any(|c| line.contains(c))).then_some(Wait::Reaps)
}

/// Every wait in `src` outside its test modules and comments: (enclosing fn, form, line). A test
/// module is `#[cfg(test)]` then `mod NAME {` up to the next line that is `}` alone (rustfmt's
/// closing brace of a top-level item); the enclosing fn is the last `fn NAME` line above.
fn waits_in(src: &str) -> Vec<(String, Wait, String)> {
    let lines: Vec<&str> = src.lines().collect();
    let (mut out, mut f, mut i) = (Vec::new(), String::new(), 0);
    while i < lines.len() {
        let l = lines[i];
        if l.trim() == "#[cfg(test)]" && lines.get(i + 1).is_some_and(|n| n.starts_with("mod ") && n.trim_end().ends_with('{')) {
            i += 2;
            while i < lines.len() && lines[i] != "}" {
                i += 1;
            }
            i += 1;
            continue;
        }
        let code = l.split("//").next().unwrap_or("");
        if let Some(at) = code.find("fn ") {
            let name: String = code[at + 3..].chars().take_while(|c| c.is_alphanumeric() || *c == '_').collect();
            if !name.is_empty() && (at == 0 || !code.as_bytes()[at - 1].is_ascii_alphanumeric()) {
                f = name;
            }
        }
        if let Some(w) = wait_form(code) {
            out.push((f.clone(), w, l.trim().to_string()));
        }
        i += 1;
    }
    out
}

/// Every `.rs` file under `dir`, at any depth, as a path relative to `dir`.
fn rs_files(dir: &Path, rel: &Path, out: &mut Vec<PathBuf>) {
    for e in std::fs::read_dir(dir.join(rel)).unwrap().flatten() {
        let r = rel.join(e.file_name());
        if e.file_type().unwrap().is_dir() {
            rs_files(dir, &r, out);
        } else if r.extension().is_some_and(|x| x == "rs") {
            out.push(r);
        }
    }
}

/// #17's class sweep: no wait outside the recorder can reap the root. Every wait in the
/// supervisor's sources (every `.rs` file under src/, at any depth; test modules and comments
/// left out) must be on this allow-list, pinned by file, enclosing fn and its exact line, and
/// every entry must be found: the recorders (Linux `wait_any`, the one `waitpid(-1, ...)`; macOS
/// `reap_root`, the one wait on the root) and the waits that are not the root's end (round 3's
/// list: a probe child, the relay's wait for its supervisor, the shim that failed its
/// handshake, the shim reaped when a TERM came before its go byte (its end is "not-started" for
/// certain), the macOS root killed while suspended, which records nothing). A `waitid` with
/// WNOWAIT only looks: those are pinned the same way (main.rs's `has_children` and
/// `root_ended`). src/bin/ holds other binaries (the test fixture), never the supervisor: they
/// are named, and a new file there is a finding. The controls: one planted line of each form is
/// found in its fn (a raw `SYS_wait4` syscall and an aliased import among them); a commented one
/// and one in a test module are not; a WNOWAIT one is told apart; the walk reached a nested file.
#[test]
fn the_root_is_reaped_only_through_the_recorder() {
    let planted = "fn planted() {\n    libc::waitpid(-1, &mut st, 0);\n    libc::wait4(root, &mut st, 0, ru);\n    libc::wait3(&mut st, 0, ru);\n    libc::wait(&mut st);\n    child.wait();\n    child.try_wait();\n    child.wait_with_output();\n    libc::waitid(libc::P_PID, root, &mut info, libc::WEXITED);\n    libc::waitid(libc::P_PID, root, &mut info, libc::WEXITED | libc::WNOWAIT);\n    // libc::waitpid(root, &mut st, 0);\n    libc::syscall(libc::SYS_wait4, root, &mut st, 0, 0);\n    use libc::waitpid as reap_it;\n}\n\n#[cfg(test)]\nmod tests {\n    fn t() { libc::waitpid(-1, &mut st, 0); }\n}\n\nfn after() {\n    libc::waitpid(root, &mut st, 0);\n}\n";
    let found = waits_in(planted);
    let forms: Vec<(&str, &Wait)> = found.iter().map(|(f, w, _)| (f.as_str(), w)).collect();
    let mut want: Vec<(&str, &Wait)> = vec![("planted", &Wait::Reaps); 8];
    want.push(("planted", &Wait::Looks));
    want.extend([("planted", &Wait::Reaps); 2]); // the raw syscall, the aliased import
    want.push(("after", &Wait::Reaps));
    assert_eq!(forms, want, "the planted controls: {found:#?}");
    const OTHER_BINARIES: [&str; 1] = ["bin/sr-fixture.rs"];
    let allowed: &[(&str, &str, Wait, &str)] = &[
        ("linux.rs", "wait_any", Wait::Reaps, "let r = unsafe { libc::waitpid(-1, &mut st, flags) };"),
        ("linux.rs", "doctor_mechanisms", Wait::Reaps, "libc::waitpid(c, &mut st, 0) == c && libc::WIFEXITED(st) && libc::WEXITSTATUS(st) == 0"),
        ("linux.rs", "spawn", Wait::Reaps, "libc::waitpid(pid, &mut st, 0);"),
        ("linux.rs", "relay_if_needed", Wait::Reaps, "if libc::waitpid(sup, &mut st, libc::WNOHANG | libc::WUNTRACED) == sup {"),
        ("linux.rs", "pre_root", Wait::Reaps, "while unsafe { libc::waitpid(root, std::ptr::null_mut(), libc::WNOHANG) } == 0 {"),
        ("linux.rs", "pre_root", Wait::Reaps, "libc::waitpid(root, std::ptr::null_mut(), 0);"),
        ("macos.rs", "reap_root", Wait::Reaps, "let mut r = unsafe { libc::waitpid(pid, &mut st, if block { 0 } else { libc::WNOHANG }) };"),
        ("macos.rs", "probe_child", Wait::Reaps, "(unsafe { libc::waitpid(pid, &mut st, 0) } == pid && libc::WIFEXITED(st)).then(|| libc::WEXITSTATUS(st))"),
        ("macos.rs", "relay_loop", Wait::Reaps, "if libc::waitpid(sup, &mut st, libc::WNOHANG | libc::WUNTRACED) == sup {"),
        ("macos.rs", "responsible", Wait::Reaps, "libc::waitpid(root, &mut st, 0);"),
        ("main.rs", "has_children", Wait::Looks, "let r = unsafe { libc::waitid(libc::P_ALL, 0, &mut info, libc::WEXITED | libc::WNOHANG | libc::WNOWAIT) };"),
        ("main.rs", "root_ended", Wait::Looks, "let r = unsafe { libc::waitid(libc::P_PID, root as libc::id_t, &mut info, libc::WEXITED | libc::WNOHANG | libc::WNOWAIT) };"),
    ];
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files = Vec::new();
    rs_files(&dir, Path::new(""), &mut files);
    files.sort();
    let others: Vec<String> = files.iter().map(|f| f.to_string_lossy().into_owned()).filter(|f| f.starts_with("bin/")).collect();
    assert_eq!(others, OTHER_BINARIES, "src/bin/ holds another binary: is it the supervisor's code?");
    assert!(files.len() >= 16, "control: the sweep read {} source files", files.len());
    let mut seen: Vec<(String, String, Wait, String)> = Vec::new();
    for f in files.iter().filter(|f| !f.starts_with("bin")) {
        let name = f.to_string_lossy().into_owned();
        for (func, w, l) in waits_in(&std::fs::read_to_string(dir.join(f)).unwrap()) {
            seen.push((name.clone(), func, w, l));
        }
    }
    seen.sort();
    let mut want: Vec<(String, String, Wait, String)> = allowed.iter().map(|(n, f, w, l)| (n.to_string(), f.to_string(), w.clone(), l.to_string())).collect();
    want.sort();
    assert_eq!(seen, want, "every wait in src/ (file, fn, form, line) against the allow-list");
}

/// #17 (macOS): a root that sheepr kills while it is still suspended (a TERM came before the
/// resuming CONT) is reaped there and records nothing: both fields null, and the reap after the
/// kill is not run for it (its pid is no longer sheepr's child; the trace has no
/// `root-after-kill` line). Its `root` value is not pinned here: plan §1 keeps it
/// "not-started", round 3's N3 (slice 2, with `root_may_run()`) makes it "signaled" once the stop
/// signals were let through.
#[cfg(target_os = "macos")]
#[test]
fn a_root_killed_while_suspended_records_nothing() {
    let d = scratch("suspkill");
    let m = marker();
    let (ready, trace) = (d.join("ready"), d.join("trace"));
    let x = run(
        &d,
        "susp",
        &format!("-- /bin/sleep {m}"),
        &[("SHEEPR_TEST_SLEEP_BEFORE_CONT_CHECK_MS", "1500"), ("SHEEPR_TEST_READY_FILE", ready.to_str().unwrap()), ("SHEEPR_TEST_TRACE", trace.to_str().unwrap())],
        |c| {
            wait_file(&ready);
            common::send_child(c, libc::SIGTERM);
        },
    );
    kill_marked(&m);
    let t = std::fs::read_to_string(&trace).unwrap_or_default();
    assert_eq!(x.code, None, "sheepr dies of the TERM: {:?}", x.status);
    assert_eq!(field(&x, "trigger").and_then(Json::str), Some("term"));
    assert!(both_null(&x), "{:?}", x.status);
    assert!(!t.lines().any(|l| l.starts_with("root-after-kill")), "trace:\n{t}");
    let _ = std::fs::remove_dir_all(&d);
}

/// #17 (macOS): after the kill, a root that is exiting but not yet reapable (the kill saw it gone;
/// its zombie is not there yet) is waited for, within 1 s: a debug seam makes the root read as
/// not yet ended for its first 150 ms (the real check still runs). Its signal is recorded
/// (`root_signal` 15) and the trace says `root-after-kill reaped`.
#[cfg(target_os = "macos")]
#[test]
fn a_root_not_yet_reapable_after_the_kill_is_waited_for() {
    let d = scratch("notyet");
    let m = marker();
    let (ready, trace) = (d.join("ready"), d.join("trace"));
    let x = run(
        &d,
        "late",
        &format!(r#"-- /bin/sh -c 'touch "{}"; exec /bin/sleep {m}'"#, ready.display()),
        &[("SHEEPR_TEST_ROOT_REAPABLE_AFTER_MS", "150"), ("SHEEPR_TEST_TRACE", trace.to_str().unwrap())],
        |c| {
            wait_file(&ready);
            common::send_child(c, libc::SIGTERM);
        },
    );
    kill_marked(&m);
    let t = std::fs::read_to_string(&trace).unwrap_or_default();
    assert!(t.lines().any(|l| l == "root-after-kill reaped"), "trace:\n{t}");
    assert_eq!(root_end(&x), (Some("signaled".into()), None, Some(libc::SIGTERM as i64)), "{:?}", x.status);
    let _ = std::fs::remove_dir_all(&d);
}

/// Review of slice 1, P2-1 (macOS): a poll of the root (WNOHANG) that fails is never the root's
/// end: the loop goes on, and the root runs to its own exit. A debug seam makes every poll of the
/// running root fail with ECHILD (the real poll runs; a debugger's attach does this for real).
/// The root exits 3 by itself: sheepr exits 3, `root` "exited" with `root_code` 3, no error, no
/// trigger, and the trace shows the failed polls (the seam took effect). A lost wait comes only
/// from the blocking wait that runs once the exit was seen (`a_lost_wait_on_the_root_makes_up_no_status`,
/// the control: 125 and "lost").
#[cfg(target_os = "macos")]
#[test]
fn a_failed_poll_of_the_root_is_not_its_end() {
    let d = scratch("pollfail");
    let trace = d.join("trace");
    let x = run(&d, "poll", r#"-- /bin/sh -c 'sleep 0.6; exit 3'"#, &[("SHEEPR_TEST_ROOT_POLL_FAIL", "1"), ("SHEEPR_TEST_TRACE", trace.to_str().unwrap())], |_| {});
    let t = std::fs::read_to_string(&trace).unwrap_or_default();
    assert!(t.lines().any(|l| l == "seam root-poll-fail"), "control: no poll was made to fail, so the seam did not act; trace:\n{t}");
    assert_eq!(x.code, Some(3), "{:?}", x.status);
    assert_eq!(root_end(&x), (Some("exited".into()), Some(3), None), "{:?}", x.status);
    assert_eq!(field(&x, "error"), Some(&Json::Null), "{:?}", x.status);
    assert_eq!(field(&x, "trigger"), Some(&Json::Null), "{:?}", x.status);
    let _ = std::fs::remove_dir_all(&d);
}

/// Review of slice 1, P2-2: when the event loop has already reaped the root (its end and the
/// TERM came in one wake), nothing polls for the root after the kill: sheepr ends within 500 ms
/// of the TERM (the poll's bound is 1 s; v0.1.3 took 20 ms), keeps the root's recorded end, and
/// the trace has no `root-after-kill unseen`. Here the root sends TERM to sheepr and exits 3:
/// `root` "exited", `root_code` 3. The control is the visible root of
/// `under_a_trigger_the_root_fields_say_how_the_kill_ended_it`, which still traces
/// `root-after-kill reaped` on macOS.
#[test]
fn a_root_that_terms_sheepr_and_exits_does_not_hold_it() {
    let d = scratch("rootterm");
    let (f, trace) = (d.join("ready"), d.join("trace"));
    let t0 = std::cell::Cell::new(None::<Instant>);
    let a = run(&d, "a", &format!(r#"-- /bin/sh -c 'touch "{}"; kill -TERM $PPID; exit 3'"#, f.display()), &[("SHEEPR_TEST_TRACE", trace.to_str().unwrap())], |_| {
        wait_file(&f);
        t0.set(Some(Instant::now()));
    });
    let took = t0.get().map(|t| t.elapsed());
    let t = std::fs::read_to_string(&trace).unwrap_or_default();
    assert!(took.is_some_and(|t| t < Duration::from_millis(500)), "sheepr took {took:?} after the root's TERM; trace:\n{t}");
    assert!(!t.lines().any(|l| l == "root-after-kill unseen"), "trace:\n{t}");
    assert_eq!(a.code, None, "sheepr dies of the TERM: {:?}", a.status);
    assert_eq!(field(&a, "trigger").and_then(Json::str), Some("term"));
    assert_eq!(root_end(&a), (Some("exited".into()), Some(3), None), "{:?}", a.status);
    let _ = std::fs::remove_dir_all(&d);
}

/// Review of slice 1, P2-2, the second shape: a TERM to sheepr's whole process group (sheepr
/// leads its own), which also ends the root, a sleep: sheepr ends within 500 ms of the TERM,
/// with no `root-after-kill unseen` in the trace, `root_signal` 15 (the caller's TERM, not
/// sheepr's kill) and `trigger` "term".
#[test]
fn a_group_term_does_not_hold_sheepr() {
    use std::os::unix::process::CommandExt;
    let d = scratch("groupterm");
    let m = marker();
    let (f, trace, out) = (d.join("ready"), d.join("trace"), d.join("status"));
    let mut c = Command::new("/bin/sh");
    c.args(["-c", &format!(r#"exec "$SD" run --status-fd 3 -- /bin/sh -c 'touch "{}"; exec /bin/sleep {m}' 3>"{}" 2>/dev/null"#, f.display(), out.display())])
        .env("SD", sheepr())
        .env("SHEEPR_TEST_TRACE", &trace)
        .process_group(0);
    let mut c = c.spawn().unwrap();
    let leader = common::found(c.id() as i32);
    wait_file(&f);
    let sent = Instant::now();
    let grouped = leader.is_some_and(|(p, id)| common::send_group(p, id, libc::SIGTERM));
    let end = Instant::now() + Duration::from_secs(10);
    let st = loop {
        if let Some(s) = c.try_wait().unwrap() {
            break Some(s);
        }
        if Instant::now() > end {
            common::send_child(&mut c, libc::SIGKILL);
            let _ = c.wait();
            break None;
        }
        std::thread::sleep(Duration::from_millis(2));
    };
    let took = sent.elapsed();
    kill_marked(&m);
    let b = json::parse(std::fs::read_to_string(&out).unwrap_or_default().trim_end()).ok();
    let t = std::fs::read_to_string(&trace).unwrap_or_default();
    let get = |k: &str| b.as_ref().and_then(|j| j.get(k)).cloned();
    assert!(grouped, "the group TERM was not sent");
    assert!(took < Duration::from_millis(500), "sheepr took {took:?} after the group TERM; trace:\n{t}");
    assert!(!t.lines().any(|l| l == "root-after-kill unseen"), "trace:\n{t}");
    assert_eq!(st.and_then(|s| std::os::unix::process::ExitStatusExt::signal(&s)), Some(libc::SIGTERM), "{b:?}");
    assert_eq!(get("trigger").as_ref().and_then(Json::str), Some("term"), "{b:?}");
    assert_eq!(get("root").as_ref().and_then(Json::str), Some("signaled"), "{b:?}");
    assert_eq!(get("root_signal").as_ref().and_then(Json::num), Some(libc::SIGTERM as f64), "{b:?}");
    let _ = std::fs::remove_dir_all(&d);
}

/// Review of slice 1, P4: with `--leave-strays` the job ends at the root's own end, before any
/// kill, so the shim's `E` line read after the loop is the only one (Linux): a command that
/// cannot be run is "not-started" with both fields null and `error` set, exit 127 (on macOS the
/// spawn itself fails, the same answer).
#[test]
fn leave_strays_with_a_missing_command_is_not_started() {
    let d = scratch("leavemiss");
    let x = run(&d, "miss", "--leave-strays -- /nonexistent/sr-missing", &[], |_| {});
    assert_eq!(x.code, Some(127), "{:?}", x.status);
    assert_eq!(field(&x, "root").and_then(Json::str), Some("not-started"), "{:?}", x.status);
    assert!(both_null(&x), "{:?}", x.status);
    assert!(field(&x, "error").and_then(Json::str).is_some(), "{:?}", x.status);
    let _ = std::fs::remove_dir_all(&d);
}

// ---- #21, #23: every end before the command says why ----

/// One pre-root step of the table (plan §2), how a cell provokes it, and what the line must say.
struct StepRow {
    /// the step's word (src/steps.rs)
    step: &'static str,
    os: &'static str,
    /// the seam's value (SHEEPR_TEST_FAIL_STEP), or "" when `args` provoke it
    seam: &'static str,
    /// run's arguments before `--` ("" for none), and whether the command is missing
    args: &'static str,
    missing: bool,
    /// a background child before sheepr starts (so it forks its relay)
    child: bool,
    env: &'static [(&'static str, &'static str)],
    code: i32,
    error_code: Option<&'static str>,
    source: &'static str,
}

/// The step table's rows: each pre-root step at least once, on its OS.
const STEP_ROWS: &[StepRow] = &[
    StepRow { step: "relay-fork", os: "any", seam: "relay-fork:EAGAIN", args: "", missing: false, child: true, env: &[], code: 125, error_code: Some("EAGAIN"), source: "resources" },
    StepRow { step: "mode", os: "any", seam: "", args: "--mode bogus", missing: false, child: false, env: &[], code: 125, error_code: None, source: "usage" },
    StepRow { step: "usage", os: "any", seam: "", args: "--no-such-flag", missing: false, child: false, env: &[], code: 125, error_code: None, source: "usage" },
    StepRow { step: "spawn", os: "macos", seam: "", args: "", missing: true, child: false, env: &[], code: 127, error_code: Some("ENOENT"), source: "command" },
    StepRow { step: "spawn", os: "macos", seam: "spawn:EAGAIN", args: "", missing: false, child: false, env: &[], code: 126, error_code: Some("EAGAIN"), source: "resources" },
    StepRow { step: "spawn", os: "macos", seam: "spawn:EPERM", args: "", missing: false, child: false, env: &[], code: 126, error_code: Some("EPERM"), source: "command" },
    StepRow { step: "inherit", os: "macos", seam: "", args: "--inherit-terminal-permissions", missing: false, child: false, env: &[("SHEEPR_TEST_PHASE1", "1")], code: 125, error_code: None, source: "usage" },
    StepRow { step: "exec", os: "linux", seam: "", args: "", missing: true, child: false, env: &[], code: 127, error_code: Some("ENOENT"), source: "command" },
    StepRow { step: "exec", os: "linux", seam: "exec:EPERM", args: "", missing: false, child: false, env: &[], code: 126, error_code: Some("EPERM"), source: "command" },
    StepRow { step: "proc", os: "linux", seam: "proc:ENOENT", args: "", missing: false, child: false, env: &[], code: 125, error_code: Some("ENOENT"), source: "sheepr" },
    StepRow { step: "self-exe", os: "linux", seam: "self-exe:EACCES", args: "", missing: false, child: false, env: &[], code: 125, error_code: Some("EACCES"), source: "sheepr" },
    StepRow { step: "pipe", os: "linux", seam: "pipe:EMFILE", args: "", missing: false, child: false, env: &[], code: 125, error_code: Some("EMFILE"), source: "resources" },
    StepRow { step: "shim-spawn", os: "linux", seam: "shim-spawn:EAGAIN", args: "", missing: false, child: false, env: &[], code: 126, error_code: Some("EAGAIN"), source: "resources" },
    StepRow { step: "shim-spawn", os: "linux", seam: "shim-spawn:E2BIG", args: "", missing: false, child: false, env: &[], code: 126, error_code: Some("E2BIG"), source: "command" },
    StepRow { step: "shim-spawn", os: "linux", seam: "shim-spawn:ENOENT", args: "", missing: false, child: false, env: &[], code: 125, error_code: Some("ENOENT"), source: "sheepr" },
    StepRow { step: "handshake", os: "linux", seam: "handshake", args: "", missing: false, child: false, env: &[], code: 125, error_code: None, source: "sheepr" },
    StepRow { step: "shim-prctl", os: "linux", seam: "shim-prctl:EPERM", args: "", missing: false, child: false, env: &[], code: 125, error_code: Some("EPERM"), source: "sheepr" },
    StepRow { step: "shim-parent", os: "linux", seam: "shim-parent", args: "", missing: false, child: false, env: &[], code: 125, error_code: None, source: "sheepr" },
];

/// Plan §2 (#21, #23): every way `run` ends before its command, one row per step of the table on
/// this OS, through SHEEPR_TEST_FAIL_STEP (the step's syscall runs and its result is replaced;
/// a process-creating step is skipped) or the arguments that cause it: the exit code (v0.1.3's),
/// `root` "not-started" with both root fields null, `trigger` null, an `error`, its `error_code`
/// (the injected errno's name) and its `error_source`; and the command never ran (its marker file
/// is absent; a seam row's command is a `touch`).
#[test]
fn every_pre_root_step_says_why() {
    let d = scratch("steps");
    let os = std::env::consts::OS;
    let mut ran = 0;
    for (i, r) in STEP_ROWS.iter().enumerate().filter(|(_, r)| r.os == "any" || r.os == os) {
        ran += 1;
        let mark = d.join(format!("ran{i}"));
        let m = marker();
        let cmd = if r.missing { "/nonexistent/sr-missing".to_string() } else { format!(r#"/bin/sh -c 'touch "{}"'"#, mark.display()) };
        let mut env: Vec<(&str, &str)> = r.env.to_vec();
        if !r.seam.is_empty() {
            env.push(("SHEEPR_TEST_FAIL_STEP", r.seam));
        }
        let prefix = if r.child { format!("/bin/sleep {m} &") } else { String::new() };
        let x = run_after(&d, &format!("s{i}"), &prefix, &format!("{} -- {cmd}", r.args), &env, |_| {});
        kill_marked(&m);
        let what = format!("{} ({}): {:?}\nstderr: {}", r.step, r.seam, x.status, x.stderr);
        assert_eq!(x.code, Some(r.code), "{what}");
        assert_eq!(field(&x, "root").and_then(Json::str), Some("not-started"), "{what}");
        assert!(both_null(&x), "{what}");
        assert_eq!(field(&x, "trigger"), Some(&Json::Null), "{what}");
        assert!(field(&x, "error").and_then(Json::str).is_some(), "{what}");
        assert_eq!(field(&x, "error_code").and_then(Json::str), r.error_code, "{what}");
        assert_eq!(field(&x, "error_source").and_then(Json::str), Some(r.source), "{what}");
        assert!(!mark.exists(), "the command ran: {what}");
    }
    assert!(ran >= 6, "control: {ran} rows ran on {os}");
    let _ = std::fs::remove_dir_all(&d);
}

/// Plan §2: a step that creates a process is skipped by its seam, so no root exists: under the
/// macOS posix_spawnp seam the command, a sleep with this cell's marker, is not running afterwards
/// (and its marker file is absent); the control, the same command without the seam, runs.
#[cfg(target_os = "macos")]
#[test]
fn the_spawn_seam_starts_no_root() {
    let d = scratch("spawnseam");
    let (m, mark, ctl) = (marker(), d.join("ran"), d.join("ctl"));
    let x = run(&d, "seam", &format!(r#"-- /bin/sh -c 'touch "{}"; exec /bin/sleep {m}'"#, mark.display()), &[("SHEEPR_TEST_FAIL_STEP", "spawn:EAGAIN")], |_| {});
    let left = common::scan(&m, |w| w.get(1) == Some(&"/bin/sleep")).map(|v| v.len());
    kill_marked(&m);
    let c = run(&d, "ctl", &format!(r#"-- /bin/sh -c 'touch "{}"'"#, ctl.display()), &[], |_| {});
    assert_eq!(c.code, Some(0), "control");
    assert!(ctl.exists(), "control: the command did not run");
    assert_eq!(x.code, Some(126), "{:?}", x.status);
    assert_eq!(left, Ok(0), "a root exists under the spawn seam");
    assert!(!mark.exists(), "the command ran under the spawn seam");
    let _ = std::fs::remove_dir_all(&d);
}
