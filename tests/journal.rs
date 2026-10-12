//! Phase-2 P1: the journal (PHASE2.md §1 decisions 1-6). Every cell runs with its own test state
//! directory (the sentinel planted), so it reads and writes nothing else.

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
    let d = std::env::temp_dir().join(format!("sr-jr-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// A test state directory: `<d>/state` with the sentinel.
fn state(d: &Path) -> PathBuf {
    let s = d.join("state");
    std::fs::create_dir_all(&s).unwrap();
    std::fs::write(s.join(".sheepr-test"), b"").unwrap();
    s
}

/// Every published journal under a state directory (never a temporary file).
fn journals(s: &Path) -> Vec<PathBuf> {
    let mut v = Vec::new();
    for b in std::fs::read_dir(s.join("jobs")).into_iter().flatten().flatten() {
        for f in std::fs::read_dir(b.path()).into_iter().flatten().flatten() {
            if f.path().extension().is_some_and(|e| e == "journal") {
                v.push(f.path());
            }
        }
    }
    v
}

fn wait_for(p: &Path, secs: u64) -> bool {
    let end = Instant::now() + Duration::from_secs(secs);
    while !p.exists() && Instant::now() < end {
        std::thread::sleep(Duration::from_millis(5));
    }
    p.exists()
}

fn finish(mut c: std::process::Child) -> Option<i32> {
    let end = Instant::now() + Duration::from_secs(30);
    loop {
        if let Some(s) = c.try_wait().unwrap() {
            return s.code();
        }
        if Instant::now() > end {
            common::send_child(&mut c, libc::SIGKILL);
            let _ = c.wait();
            return None;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
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

/// The parsed lines of a journal; panics on a line that does not parse.
fn lines(j: &Path) -> Vec<Json> {
    std::fs::read_to_string(j).unwrap().lines().map(|l| json::parse(l).unwrap_or_else(|e| panic!("{e}: {l}"))).collect()
}

fn marker() -> String {
    let n = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().subsec_nanos();
    format!("29.{:09}", n)
}

/// A member's journal line is written before the first signal to it: in the signal log, every
/// pid that is signalled has a `journal <pid>` line before its first signal line. The shape: a
/// member that forks an escapee when it gets TERM (`fork-on-term`), so the escapee is born during
/// the kill's grace, is first seen by a grace scan, and gets its TERM right after that very scan
/// (a journal written one scan late would come after it). The job is ended by a TERM to sheepr.
#[test]
fn a_member_is_journaled_before_its_first_signal() {
    let d = scratch("order");
    let s = state(&d);
    let r = d.join("rec");
    let log = d.join("log");
    let mut c = Command::new(sheepr())
        .args(["run", "--grace", "0.5", "--", fixture(), "fork-on-term", &marker()])
        .arg(&r)
        .env("SHEEPR_TEST_STATE", &s)
        .env("SHEEPR_TEST_SIGNAL_LOG", &log)
        .spawn()
        .unwrap();
    let started = records(&r, 2).len() == 2;
    common::send_child(&mut c, libc::SIGTERM);
    let _ = finish(c);
    let recs = records(&r, 3);
    for p in recs.iter().filter(|p| common::alive(**p)) {
        common::send(p.0, p.1, libc::SIGKILL);
    }
    assert!(started, "the member was ready");
    assert_eq!(recs.len(), 3, "the escapee was born during the kill: {recs:?}");
    let text = std::fs::read_to_string(&log).unwrap();
    let mut journaled = std::collections::HashSet::new();
    let mut checked = std::collections::HashSet::new();
    for l in text.lines() {
        let w: Vec<&str> = l.split_whitespace().collect();
        match w.as_slice() {
            ["journal", p, ..] => {
                journaled.insert(p.to_string());
            }
            [k, p, ..] if *k == "kill" || *k == "pidfd" => {
                assert!(journaled.contains(*p), "pid {p} was signalled before it was journaled:\n{text}");
                checked.insert(p.to_string());
            }
            _ => {}
        }
    }
    assert!(checked.contains(&recs[2].0.to_string()), "control: the escapee born in the kill was signalled:\n{text}");
    let _ = std::fs::remove_dir_all(&d);
}

/// The journal exists while the job runs (it names the root and the escapee, and its header is
/// the first line), and is deleted after a clean end.
#[test]
fn the_journal_exists_while_the_job_runs_and_is_deleted_after_a_clean_end() {
    let d = scratch("life");
    let s = state(&d);
    let (go, ready) = (d.join("go"), d.join("ready"));
    let script = format!(r#"touch "{}"; while [ ! -e "{}" ]; do sleep 0.01; done"#, ready.display(), go.display());
    let c = Command::new(sheepr()).args(["run", "--", "/bin/sh", "-c", &script]).env("SHEEPR_TEST_STATE", &s).spawn().unwrap();
    let sup = c.id() as i32;
    let started = wait_for(&ready, 20);
    let js = journals(&s);
    let text = js.first().map(|j| std::fs::read_to_string(j).unwrap_or_default());
    std::fs::write(&go, b"").unwrap(); // release the job before any assertion
    let code = finish(c);
    assert!(started, "the root ran");
    assert_eq!(js.len(), 1, "{js:?}");
    let ls: Vec<Json> = text.unwrap().lines().map(|l| json::parse(l).unwrap()).collect();
    assert_eq!(ls[0].get("kind").and_then(Json::str), Some("header"));
    assert_eq!(ls[0].get("sup").and_then(|x| x.get("pid")).and_then(Json::num), Some(sup as f64), "the header names the supervisor");
    let job = ls[0].get("job").and_then(Json::str).unwrap().to_string();
    assert!(job.starts_with("j-") && job.len() == 10 && js[0].file_stem().unwrap() == job.as_str(), "{job}");
    assert!(ls[1..].iter().any(|l| l.get("root") == Some(&Json::Bool(true))), "the root is journaled");
    assert_eq!(code, Some(0));
    assert!(journals(&s).is_empty(), "deleted after a clean end");
    let _ = std::fs::remove_dir_all(&d);
}

/// A journal is never visible unlocked: held just after it is published, the reader finds it
/// locked, and its header already there.
#[test]
fn a_published_journal_is_locked_and_has_its_header() {
    let d = scratch("locked");
    let s = state(&d);
    let (rel, ready) = (d.join("release"), d.join("ready"));
    let c = Command::new(sheepr())
        .args(["run", "--", "/bin/sh", "-c", "exit 0"])
        .env("SHEEPR_TEST_STATE", &s)
        .env("SHEEPR_TEST_HOLD_AFTER_LINK", &rel)
        .env("SHEEPR_TEST_READY_FILE", &ready)
        .spawn()
        .unwrap();
    let held = wait_for(&ready, 20);
    let js = journals(&s);
    let verdict = js.first().map(|j| {
        let f = std::fs::File::open(j).unwrap();
        let locked = unsafe { libc::flock(std::os::fd::AsRawFd::as_raw_fd(&f), libc::LOCK_EX | libc::LOCK_NB) } != 0;
        let header = std::fs::read_to_string(j).unwrap().lines().next().and_then(|l| json::parse(l).ok());
        (locked, header.and_then(|h| h.get("kind").and_then(Json::str).map(String::from)))
    });
    std::fs::write(&rel, b"").unwrap();
    assert_eq!(finish(c), Some(0));
    assert!(held, "held after the link");
    assert_eq!(js.len(), 1);
    assert_eq!(verdict, Some((true, Some("header".to_string()))), "locked, with its header");
    let _ = std::fs::remove_dir_all(&d);
}

/// The job holds no journal or lock fd: the root's own open files name nothing in the state
/// directory, while the supervisor's do (the control: the listing can see such an fd).
#[test]
fn the_job_holds_no_journal_fd() {
    let d = scratch("fds");
    let s = state(&d);
    let (own, sup) = (d.join("own"), d.join("sup"));
    let list = if cfg!(target_os = "macos") { "lsof -p {} -Fn" } else { "ls -l /proc/{}/fd/" };
    let script = format!(
        r#"{} > "{}" 2>/dev/null; {} > "{}" 2>/dev/null; exit 0"#,
        list.replace("{}", "$$"),
        own.display(),
        list.replace("{}", "$PPID"),
        sup.display()
    );
    let code = finish(Command::new(sheepr()).args(["run", "--", "/bin/sh", "-c", &script]).env("SHEEPR_TEST_STATE", &s).spawn().unwrap());
    assert_eq!(code, Some(0));
    let (own, sup) = (std::fs::read_to_string(&own).unwrap(), std::fs::read_to_string(&sup).unwrap());
    // the fd is listed by the name it was opened under (the temporary one, now removed) or by
    // the journal's own name
    let journal_fd = |t: &str| t.contains(".tmp-j-") || t.contains(".journal");
    assert!(journal_fd(&sup), "control: the supervisor's listing shows its journal:\n{sup}");
    assert!(!journal_fd(&own), "the root holds a journal fd:\n{own}");
    let _ = std::fs::remove_dir_all(&d);
}

/// Decision 2: the journal never stops the job. With no usable state directory (`jobs` is a
/// file) and with a write that fails (seam), the escapee still dies, the exit code is the
/// command's, and the run notes the failure.
#[test]
fn a_journal_that_cannot_be_written_never_stops_the_kill() {
    for (name, seam) in [("nodir", None), ("write", Some("SHEEPR_TEST_JOURNAL_WRITE_FAIL"))] {
        let d = scratch(name);
        let s = state(&d);
        if seam.is_none() {
            std::fs::write(s.join("jobs"), b"not a directory").unwrap();
        }
        let r = d.join("rec");
        let trace = d.join("trace");
        let mut cmd = Command::new(sheepr());
        cmd.args(["run", "--grace", "0", "--", "/bin/sh", "-c", &format!(r#""$FX" escape {} "$R"; exit 3"#, marker())])
            .env("FX", fixture())
            .env("R", &r)
            .env("SHEEPR_TEST_STATE", &s)
            .env("SHEEPR_TEST_TRACE", &trace);
        if let Some(k) = seam {
            cmd.env(k, "1");
        }
        let code = finish(cmd.spawn().unwrap());
        let g = records(&r, 1)[0];
        let alive = common::alive(g);
        common::send(g.0, g.1, libc::SIGKILL);
        assert!(!alive, "{name}: the escapee died");
        assert_eq!(code, Some(3), "{name}: the command's own code");
        let notes = std::fs::read_to_string(&trace).unwrap_or_default();
        assert!(notes.lines().any(|l| l.starts_with("journal-failed")), "{name}: {notes}");
        let _ = std::fs::remove_dir_all(&d);
    }
}

/// A scan with many new members writes one complete line per member (no count cap): 300
/// members, every line parses, every member is named.
#[test]
fn every_member_of_a_big_scan_has_a_complete_line() {
    let d = scratch("big");
    let s = state(&d);
    let r = d.join("rec");
    let code = finish(
        Command::new(sheepr())
            .args(["run", "--grace", "0.05", "--", fixture(), "swarm", "300"])
            .arg(&r)
            .env("SHEEPR_TEST_STATE", &s)
            .env("SHEEPR_TEST_KEEP_JOURNAL", "1")
            .spawn()
            .unwrap(),
    );
    let recs = records(&r, 300);
    for p in recs.iter().filter(|p| common::alive(**p)) {
        common::send(p.0, p.1, libc::SIGKILL);
    }
    assert_eq!(code, Some(0));
    let js = journals(&s);
    assert_eq!(js.len(), 1, "kept by the seam");
    let ls = lines(&js[0]);
    let named: std::collections::HashSet<i64> = ls.iter().filter_map(|l| l.get("pid").and_then(Json::num)).map(|n| n as i64).collect();
    let missing: Vec<_> = recs.iter().filter(|p| !named.contains(&(p.0 as i64))).collect();
    assert_eq!(recs.len(), 300);
    assert!(missing.is_empty(), "{} members not journaled", missing.len());
    let _ = std::fs::remove_dir_all(&d);
}

/// A non-UTF-8 argument is kept in the line, escaped as \xHH, and the line still parses.
#[test]
fn a_non_utf8_argument_is_escaped() {
    use std::os::unix::ffi::OsStrExt;
    let d = scratch("bytes");
    let s = state(&d);
    let bad = std::ffi::OsStr::from_bytes(b"a\xff\xfeb");
    let code = finish(
        Command::new(sheepr())
            .args(["run", "--", "/bin/sh", "-c", "exit 0"])
            .arg(bad)
            .env("SHEEPR_TEST_STATE", &s)
            .env("SHEEPR_TEST_KEEP_JOURNAL", "1")
            .spawn()
            .unwrap(),
    );
    assert_eq!(code, Some(0));
    let ls = lines(&journals(&s)[0]);
    let root = ls.iter().find(|l| l.get("root") == Some(&Json::Bool(true))).expect("the root line");
    let cmd = root.get("cmd").and_then(Json::str).unwrap();
    assert!(cmd.contains(r"a\xff\xfeb"), "{cmd}");
    let _ = std::fs::remove_dir_all(&d);
}

/// Publishing never replaces a journal: when the chosen id is taken, a new id is picked and the
/// existing file is left as it was. (`--no-sweep`: the first run's kept journal is a dead job's,
/// which the second run's auto-sweep would otherwise remove first.)
#[test]
fn a_taken_job_id_is_never_overwritten() {
    let d = scratch("taken");
    let s = state(&d);
    // a first run (kept) shows the folder; then a second run forced to the same id
    let first = finish(
        Command::new(sheepr())
            .args(["run", "--no-sweep", "--", "/bin/sh", "-c", "exit 0"])
            .env("SHEEPR_TEST_STATE", &s)
            .env("SHEEPR_TEST_KEEP_JOURNAL", "1")
            .env("SHEEPR_TEST_JOB_ID", "0badc0de")
            .spawn()
            .unwrap(),
    );
    assert_eq!(first, Some(0));
    let js = journals(&s);
    assert_eq!(js.len(), 1);
    assert_eq!(js[0].file_stem().unwrap(), "j-0badc0de", "the forced id");
    let before = std::fs::read(&js[0]).unwrap();
    let second = finish(
        Command::new(sheepr())
            .args(["run", "--no-sweep", "--", "/bin/sh", "-c", "exit 0"])
            .env("SHEEPR_TEST_STATE", &s)
            .env("SHEEPR_TEST_KEEP_JOURNAL", "1")
            .env("SHEEPR_TEST_JOB_ID", "0badc0de")
            .spawn()
            .unwrap(),
    );
    assert_eq!(second, Some(0));
    assert_eq!(std::fs::read(&js[0]).unwrap(), before, "the taken journal is unchanged");
    let js2 = journals(&s);
    assert_eq!(js2.len(), 2, "a second journal under a new id: {js2:?}");
    let _ = std::fs::remove_dir_all(&d);
}

/// The state wall, live (PHASE2.md §0.2): a debug run whose environment names the operator's
/// state (`SHEEPR_STATE`, `XDG_STATE_HOME` and `HOME` all pointing at a directory that even has
/// a sentinel) writes nothing there and notes that it has no state: with the runner's canary as
/// its test state (no sentinel), and with no test state at all. The control is every cell above:
/// with a sentinelled test state it writes a journal.
#[test]
fn a_debug_run_never_writes_the_operators_state() {
    for canary in [true, false] {
        let d = scratch(if canary { "wall-canary" } else { "wall-none" });
        let real = d.join("real");
        std::fs::create_dir_all(&real).unwrap();
        std::fs::write(real.join(".sheepr-test"), b"").unwrap();
        let trace = d.join("trace");
        let mut cmd = Command::new(sheepr());
        cmd.args(["run", "--", "/bin/sh", "-c", "exit 0"])
            .env("SHEEPR_STATE", &real)
            .env("XDG_STATE_HOME", &real)
            .env("HOME", &real)
            .env("SHEEPR_TEST_KEEP_JOURNAL", "1")
            .env("SHEEPR_TEST_TRACE", &trace);
        if !canary {
            cmd.env_remove("SHEEPR_TEST_STATE");
        }
        let code = finish(cmd.spawn().unwrap());
        assert_eq!(code, Some(0));
        // everything but the sentinel and the one known outside writer: Rosetta keeps its cache in
        // $HOME/.cache/rosetta on the emulated leg
        let written: Vec<_> = walk(&real)
            .into_iter()
            .filter(|p| {
                let r = p.strip_prefix(&real).unwrap().to_string_lossy().into_owned();
                r != ".sheepr-test" && r != ".cache" && r != ".cache/rosetta" && !r.starts_with(".cache/rosetta/")
            })
            .collect();
        assert!(written.is_empty(), "canary {canary}: {written:?}");
        let notes = std::fs::read_to_string(&trace).unwrap_or_default();
        assert!(notes.lines().any(|l| l == "state-unset"), "canary {canary}: {notes}");
        let _ = std::fs::remove_dir_all(&d);
    }
}

fn walk(p: &Path) -> Vec<PathBuf> {
    let mut v = Vec::new();
    for e in std::fs::read_dir(p).into_iter().flatten().flatten() {
        v.push(e.path());
        if e.path().is_dir() {
            v.extend(walk(&e.path()));
        }
    }
    v
}

/// The root is journaled before it runs (macOS: before the resuming CONT; Linux: before the root
/// shim's go byte). A seam SIGKILLs the supervisor right after the root's line: the journal names
/// the root, and the root never ran its command.
#[test]
fn the_root_is_journaled_before_it_runs() {
    let d = scratch("rootfirst");
    let s = state(&d);
    let ran = d.join("ran");
    let code = finish(
        Command::new(sheepr())
            .args(["run", "--", "/bin/sh", "-c", &format!(r#"touch "{}""#, ran.display())])
            .env("SHEEPR_TEST_STATE", &s)
            .env("SHEEPR_TEST_KILL_AFTER_ROOT_JOURNAL", "1")
            // Linux: PDEATHSIG would kill the shim anyway; off, only the go byte holds it back
            .env("SHEEPR_TEST_SHIM_NO_PDEATHSIG", "1")
            .spawn()
            .unwrap(),
    );
    assert_eq!(code, None, "the supervisor died of the seam's SIGKILL");
    let js = journals(&s);
    assert_eq!(js.len(), 1, "the journal stays (its supervisor died)");
    let ls = lines(&js[0]);
    let root = ls.iter().find(|l| l.get("root") == Some(&Json::Bool(true))).expect("the root was journaled");
    let (p, id) = (root.get("pid").and_then(Json::num).unwrap() as i32, root.get("id").and_then(Json::num).unwrap() as u64);
    std::thread::sleep(Duration::from_millis(300));
    let never_ran = !ran.exists();
    common::send(p, id, libc::SIGKILL); // the suspended root, by the identity the journal gave
    assert!(never_ran, "the root ran before it was journaled");
    let _ = std::fs::remove_dir_all(&d);
}

/// `--status-fd`, minimal (the full schema is P2): `root` says how the root ended, `job` names
/// the journal's id, and a journal failure is in `notes`.
#[test]
fn the_status_line_names_the_root_the_job_and_the_notes() {
    let d = scratch("status");
    let s = state(&d);
    let run = |cmd: &str, extra: &[(&str, &str)]| -> Json {
        let out = d.join("status");
        let _ = std::fs::remove_file(&out);
        let mut c = Command::new("/bin/sh");
        c.args(["-c", &format!(r#"exec "$SD" run --status-fd 3 -- /bin/sh -c '{cmd}' 3>"{}""#, out.display())])
            .env("SD", sheepr())
            .env("SHEEPR_TEST_STATE", &s);
        for (k, v) in extra {
            c.env(k, v);
        }
        finish(c.spawn().unwrap());
        json::parse(std::fs::read_to_string(&out).unwrap().trim_end()).unwrap()
    };
    let ok = run("exit 4", &[]);
    assert_eq!(ok.get("root").and_then(Json::str), Some("exited"));
    assert!(ok.get("job").and_then(Json::str).is_some_and(|j| j.starts_with("j-")));
    let sig = run("kill -KILL $$", &[]);
    assert_eq!(sig.get("root").and_then(Json::str), Some("signaled"));
    let failed = run("exit 0", &[("SHEEPR_TEST_JOURNAL_WRITE_FAIL", "1")]);
    let notes: Vec<&str> = failed.get("notes").and_then(Json::arr).unwrap_or(&[]).iter().filter_map(Json::str).collect();
    assert!(notes.iter().any(|n| n.starts_with("journal-failed")), "{notes:?}");
    // a root that never started (not found: 127)
    let out = d.join("status-missing");
    let code = finish(
        Command::new("/bin/sh")
            .args(["-c", &format!(r#"exec "$SD" run --status-fd 3 -- /nonexistent/cmd 3>"{}""#, out.display())])
            .env("SD", sheepr())
            .env("SHEEPR_TEST_STATE", &s)
            .spawn()
            .unwrap(),
    );
    assert_eq!(code, Some(127));
    let st = json::parse(std::fs::read_to_string(&out).unwrap().trim_end()).unwrap();
    assert_eq!(st.get("root").and_then(Json::str), Some("not-started"));
    let _ = std::fs::remove_dir_all(&d);
}

/// A running job's journal is locked for as long as the job runs, also after a journal write
/// failed (the published file must never look like a dead job's to `sweep`), and no journal is
/// left after a clean end. Probed mid-run, while the root waits.
#[test]
fn a_running_job_s_journal_stays_locked() {
    for fail in [false, true] {
        let d = scratch(if fail { "lockfail" } else { "lockok" });
        let s = state(&d);
        let (go, ready) = (d.join("go"), d.join("ready"));
        // the root starts an escapee, so a scan has a member line to write (and fail on)
        let script = format!(
            r#""$FX" escape {} "$R"; touch "{}"; while [ ! -e "{}" ]; do sleep 0.01; done"#,
            marker(),
            ready.display(),
            go.display()
        );
        let mut cmd = Command::new(sheepr());
        cmd.args(["run", "--grace", "0", "--", "/bin/sh", "-c", &script]).env("FX", fixture()).env("R", d.join("rec")).env("SHEEPR_TEST_STATE", &s);
        if fail {
            cmd.env("SHEEPR_TEST_JOURNAL_WRITE_FAIL", "1");
        }
        let c = cmd.spawn().unwrap();
        let started = wait_for(&ready, 20);
        std::thread::sleep(Duration::from_millis(600)); // a few scans (and failed writes)
        let unlocked: Vec<PathBuf> = journals(&s)
            .into_iter()
            .filter(|j| {
                let f = std::fs::File::open(j).unwrap();
                unsafe { libc::flock(std::os::fd::AsRawFd::as_raw_fd(&f), libc::LOCK_EX | libc::LOCK_NB) == 0 }
            })
            .collect();
        let published = journals(&s).len();
        std::fs::write(&go, b"").unwrap();
        let code = finish(c);
        for p in records(&d.join("rec"), 1) {
            common::send(p.0, p.1, libc::SIGKILL);
        }
        assert!(started, "fail {fail}");
        assert_eq!(published, 1, "fail {fail}: the journal is published (its header is written before any line)");
        assert!(unlocked.is_empty(), "fail {fail}: a running job's journal is unlocked: {unlocked:?}");
        assert_eq!(code, Some(0), "fail {fail}");
        assert!(journals(&s).is_empty(), "fail {fail}: a journal is left after a clean end");
        let _ = std::fs::remove_dir_all(&d);
    }
}

/// `--status-fd` gets exactly one line, from the supervisor, also when sheepr runs with a
/// relay (it started with children of its own: here the shell's background `sleep`), and also
/// when the job ends by a TERM to sheepr. The relay never writes it.
#[test]
fn the_status_line_is_written_once_with_a_relay() {
    let d = scratch("relay");
    let s = state(&d);
    let m = marker();
    for term in [false, true] {
        let (out, ready) = (d.join(format!("status-{term}")), d.join(format!("ready-{term}")));
        let root = if term { format!(r#"touch "{}"; sleep 30"#, ready.display()) } else { "exit 0".to_string() };
        let mut c = Command::new("/bin/sh")
            .args(["-c", &format!(r#"sleep {m} & exec "$SD" run --status-fd 3 -- /bin/sh -c '{root}' 3>"{}""#, out.display())])
            .env("SD", sheepr())
            .env("SHEEPR_TEST_STATE", &s)
            .spawn()
            .unwrap();
        if term {
            let started = wait_for(&ready, 20);
            common::send_child(&mut c, libc::SIGTERM);
            assert!(started);
        }
        let _ = finish(c);
        let text = std::fs::read_to_string(&out).unwrap_or_default();
        let lines: Vec<&str> = text.lines().collect();
        common::kill_marked(&[&m]);
        assert_eq!(lines.len(), 1, "term {term}: {text:?}");
        let j = json::parse(lines[0]).unwrap();
        assert!(j.get("job").and_then(Json::str).is_some_and(|x| x.starts_with("j-")), "term {term}: {text}");
    }
    let _ = std::fs::remove_dir_all(&d);
}

/// Under the phase-1 opt-out (PHASE2.md §0.1) no journal is written: the opt-out disables the
/// state outright. The control is every cell above, where the same run writes one.
#[test]
fn the_phase_one_opt_out_writes_no_journal() {
    let d = scratch("optout");
    let s = state(&d);
    let code = finish(
        Command::new(sheepr())
            .args(["run", "--", "/bin/sh", "-c", "exit 0"])
            .env("SHEEPR_TEST_STATE", &s)
            .env("SHEEPR_TEST_KEEP_JOURNAL", "1")
            .env("SHEEPR_TEST_PHASE1", "1")
            .spawn()
            .unwrap(),
    );
    assert_eq!(code, Some(0));
    assert!(!s.join("jobs").exists(), "a journal was written under the opt-out");
    let _ = std::fs::remove_dir_all(&d);
}

/// A journal that could not keep its lines under `--leave-strays` is not left behind without its
/// leave-strays mark (a sweep would take it for a dead job and kill the strays the operator chose
/// to keep). With a failed write, no journal remains; the control, the same run without the
/// failure, keeps one that carries the mark.
#[test]
fn a_leave_strays_journal_is_never_kept_without_its_mark() {
    for fail in [false, true] {
        let d = scratch(if fail { "strays-fail" } else { "strays-ok" });
        let s = state(&d);
        let m = marker();
        let mut cmd = Command::new(sheepr());
        cmd.args(["run", "--leave-strays", "--", fixture(), "escape", &m]).arg(d.join("rec")).env("SHEEPR_TEST_STATE", &s);
        if fail {
            cmd.env("SHEEPR_TEST_JOURNAL_WRITE_FAIL", "1");
        }
        let code = finish(cmd.spawn().unwrap());
        for p in records(&d.join("rec"), 1) {
            common::send(p.0, p.1, libc::SIGKILL); // the stray it left
        }
        let js = journals(&s);
        assert_eq!(code, Some(0), "fail {fail}");
        if fail {
            assert!(js.is_empty(), "a journal without its mark was kept: {js:?}");
        } else {
            assert_eq!(js.len(), 1, "control: the leave-strays journal is kept");
            let marked = lines(&js[0]).iter().any(|l| l.get("kind").and_then(Json::str) == Some("leave-strays"));
            assert!(marked, "control: it carries the mark");
        }
        let _ = std::fs::remove_dir_all(&d);
    }
}


// ---- #16: run --require-journal (plan §3) ----

/// One `sheepr run --status-fd 3 ARGS` through `/bin/sh -c 'exec ...'` (SIGCONT blocked when
/// `block_cont`), within 30 s: (exit code, status line, stderr).
fn run_st(d: &Path, name: &str, args: &str, env: &[(&str, &str)], block_cont: bool) -> (Option<i32>, Option<Json>, String) {
    use std::os::unix::process::CommandExt;
    let (out, err) = (d.join(format!("{name}.status")), d.join(format!("{name}.err")));
    let mut c = Command::new("/bin/sh");
    c.args(["-c", &format!(r#"exec "$SD" run --status-fd 3 {args} 3>"{}" 2>"{}""#, out.display(), err.display())]).env("SD", sheepr()).env("FX", fixture());
    for (k, v) in env {
        c.env(k, v);
    }
    if block_cont {
        unsafe {
            c.pre_exec(|| {
                let mut s: libc::sigset_t = std::mem::zeroed();
                libc::sigemptyset(&mut s);
                libc::sigaddset(&mut s, libc::SIGCONT);
                libc::sigprocmask(libc::SIG_BLOCK, &s, std::ptr::null_mut());
                Ok(())
            });
        }
    }
    let code = finish(c.spawn().unwrap());
    let st = json::parse(std::fs::read_to_string(&out).unwrap_or_default().trim_end()).ok();
    (code, st, std::fs::read_to_string(&err).unwrap_or_default())
}

fn get<'a>(st: &'a Option<Json>, k: &str) -> Option<&'a Json> {
    st.as_ref().and_then(|j| j.get(k))
}

/// A run refused before its command: 125, root "not-started", trigger null, an error that
/// starts with `starts`, its errno's name, its source; the command never ran.
fn refused(code: Option<i32>, st: &Option<Json>, mark: &Path, starts: &str, error_code: Option<&str>, source: &str) {
    refused_as(code, st, mark, "not-started", starts, error_code, source);
}

/// `refused`, with the `root` it must read.
fn refused_as(code: Option<i32>, st: &Option<Json>, mark: &Path, root: &str, starts: &str, error_code: Option<&str>, source: &str) {
    assert_eq!(code, Some(125), "{st:?}");
    assert_eq!(get(st, "root").and_then(Json::str), Some(root), "{st:?}");
    assert_eq!(get(st, "trigger"), Some(&Json::Null), "{st:?}");
    assert!(get(st, "error").and_then(Json::str).is_some_and(|e| e.starts_with(starts)), "{st:?}");
    assert_eq!(get(st, "error_code").and_then(Json::str), error_code, "{st:?}");
    assert_eq!(get(st, "error_source").and_then(Json::str), Some(source), "{st:?}");
    assert!(!mark.exists(), "the command ran: {st:?}");
}

/// Plan §3 (#16): with --require-journal a journal sheepr cannot keep refuses the command before
/// it runs: its state dir's `jobs` a regular file (mkdir: ENOTDIR, also as root): 125,
/// "not-started", trigger null, "the job journal cannot be kept: ...", ENOTDIR, source "sheepr",
/// the command never ran, and before any root is spawned (a spawn made to fail too is not the
/// error); a header that cannot be written for lack of space (seam: ENOSPC):
/// "resources", ENOSPC; no state directory at all: refused, source "sheepr". The controls: a
/// writable state dir runs the command (and leaves no journal); without the option the
/// unwritable dir runs it as today (a `journal-failed` note, no error). No refusal leaves a
/// journal behind.
#[test]
fn require_journal_refuses_a_journal_it_cannot_keep() {
    let d = scratch("reqopen");
    let (s, bad) = (state(&d), d.join("bad"));
    std::fs::create_dir_all(&bad).unwrap();
    std::fs::write(bad.join(".sheepr-test"), b"").unwrap();
    std::fs::write(bad.join("jobs"), b"a regular file").unwrap();
    let cmd = |m: &Path| format!(r#"-- /bin/sh -c 'touch "{}"'"#, m.display());
    let (m1, m2, m3, m4, m5) = (d.join("m1"), d.join("m2"), d.join("m3"), d.join("m4"), d.join("m5"));
    let bad_s = bad.to_str().unwrap();
    let (c, st, _) = run_st(&d, "notdir", &format!("--require-journal {}", cmd(&m1)), &[("SHEEPR_TEST_STATE", bad_s)], false);
    refused(c, &st, &m1, "the job journal cannot be kept: ", Some("ENOTDIR"), "sheepr");
    let (c, st, _) = run_st(&d, "nospace", &format!("--require-journal {}", cmd(&m2)), &[("SHEEPR_TEST_STATE", s.to_str().unwrap()), ("SHEEPR_TEST_JOURNAL_FAIL_AFTER", "0:ENOSPC")], false);
    refused(c, &st, &m2, "the job journal cannot be kept: ", Some("ENOSPC"), "resources");
    let (c, st, _) = run_st(&d, "nostate", &format!("--require-journal {}", cmd(&m3)), &[], false);
    refused(c, &st, &m3, "the job journal cannot be kept: ", None, "sheepr");
    // no boot id (seam): its errno is kept (review of the slice-4 fixes, P4-5)
    let (c, st, _) = run_st(&d, "noboot", &format!("--require-journal {}", cmd(&m3)), &[("SHEEPR_TEST_STATE", s.to_str().unwrap()), ("SHEEPR_TEST_BOOT_ID_ERRNO", "EACCES")], false);
    refused(c, &st, &m3, "the job journal cannot be kept: no boot id", Some("EACCES"), "sheepr");
    // the refusal comes before the root is spawned: with the spawn failing too (seam), the
    // error is still the journal's
    let spawn_seam = if cfg!(target_os = "macos") { "spawn:EAGAIN" } else { "shim-spawn:EAGAIN" };
    let (c, st, _) = run_st(&d, "first", &format!("--require-journal {}", cmd(&m3)), &[("SHEEPR_TEST_STATE", bad_s), ("SHEEPR_TEST_FAIL_STEP", spawn_seam)], false);
    refused(c, &st, &m3, "the job journal cannot be kept: ", Some("ENOTDIR"), "sheepr");
    assert!(journals(&s).is_empty(), "a refusal left a journal: {:?}", journals(&s));
    // controls
    let (c, st, _) = run_st(&d, "ok", &format!("--require-journal {}", cmd(&m4)), &[("SHEEPR_TEST_STATE", s.to_str().unwrap())], false);
    assert_eq!((c, get(&st, "error")), (Some(0), Some(&Json::Null)), "control: a writable dir: {st:?}");
    assert!(m4.exists(), "control: the command did not run");
    assert!(journals(&s).is_empty(), "control: the clean end left a journal");
    let (c, st, _) = run_st(&d, "today", &cmd(&m5), &[("SHEEPR_TEST_STATE", bad_s)], false);
    assert_eq!((c, get(&st, "error")), (Some(0), Some(&Json::Null)), "control: without the option: {st:?}");
    assert!(m5.exists(), "control: without the option the command did not run");
    let notes: Vec<&str> = get(&st, "notes").and_then(Json::arr).unwrap_or(&[]).iter().filter_map(Json::str).collect();
    assert!(notes.iter().any(|n| n.starts_with("journal-failed")), "{notes:?}");
    let _ = std::fs::remove_dir_all(&d);
}

/// Plan §3: with --require-journal the root runs only after its root line is written. A root
/// line that fails (seam: the journal's second write) or that cannot be made (seam: the root's
/// identity unreadable) abandons the root before it runs: 125, the command never ran and nothing
/// of it is left; the identity's refusal names the identity, not the journal. No journal is left.
/// `root`: "not-started" on Linux (the shim never got its go byte); "signaled" on macOS, where the
/// root was spawned (suspended) and any SIGCONT could have run it (review of slice 2, P2-1). The control: the identity seam without the option runs the command (today:
/// it runs unjournaled).
#[test]
fn require_journal_runs_the_root_only_after_its_line() {
    let d = scratch("reqline");
    let s = state(&d);
    let ss = s.to_str().unwrap();
    let mk = marker();
    let (m1, m2, m3) = (d.join("m1"), d.join("m2"), d.join("m3"));
    let cmd = |m: &Path| format!(r#"-- /bin/sh -c 'touch "{}"; exec /bin/sleep {mk}'"#, m.display());
    let (c, st, err) = run_st(&d, "line", &format!("--require-journal {}", cmd(&m1)), &[("SHEEPR_TEST_STATE", ss), ("SHEEPR_TEST_JOURNAL_FAIL_AFTER", "1")], false);
    let left1 = common::scan(&mk, |w| w.get(1) == Some(&"/bin/sleep")).map(|v| v.len());
    // the refusal is the one line: the end of the job does not say the failure again (P3-1)
    assert_eq!(err.lines().filter(|l| l.contains("journal") && l.contains("error")).count(), 1, "stderr:\n{err}");
    let spawned = if cfg!(target_os = "macos") { "signaled" } else { "not-started" };
    refused_as(c, &st, &m1, spawned, "the job journal cannot be kept: ", Some("EIO"), "sheepr");
    let (c, st, _) = run_st(&d, "ident", &format!("--require-journal {}", cmd(&m2)), &[("SHEEPR_TEST_STATE", ss), ("SHEEPR_TEST_FAIL_STEP", "root-identity")], false);
    let left2 = common::scan(&mk, |w| w.get(1) == Some(&"/bin/sleep")).map(|v| v.len());
    refused_as(c, &st, &m2, spawned, "the command's identity cannot be read", None, "sheepr");
    // Linux holds the root before its exec, so there it did not run; macOS cannot say so (P3-A)
    let claims = get(&st, "error").and_then(Json::str).is_some_and(|e| e.ends_with("; it did not run"));
    assert_eq!(claims, cfg!(target_os = "linux"), "{st:?}");
    assert_eq!((left1, left2), (Ok(0), Ok(0)), "an abandoned root was left");
    assert!(journals(&s).is_empty(), "a refusal left a journal: {:?}", journals(&s));
    let (c, st, _) = run_st(&d, "ctl", &format!(r#"-- /bin/sh -c 'touch "{}"'"#, m3.display()), &[("SHEEPR_TEST_STATE", ss), ("SHEEPR_TEST_FAIL_STEP", "root-identity")], false);
    assert_eq!((c, get(&st, "error")), (Some(0), Some(&Json::Null)), "control: {st:?}");
    assert!(m3.exists(), "control: the command did not run");
    common::kill_marked(&[&mk]);
    let _ = std::fs::remove_dir_all(&d);
}

/// Plan §3: with --require-journal a journal that goes dead while the job runs ends the job
/// (seam: the journal's third write, the first scan's): the tree is killed (the background sleep
/// is gone), `trigger` "journal", exit 125 (not a death by TERM), "the job journal failed: ...",
/// its errno's name, no "term after the trigger" note, and the kill report names the journal
/// (`report-cause journal`); stderr never says "the job runs". The control: the same without the
/// option runs to its own end (exit 0, trigger null, a `journal-failed` note).
#[test]
fn require_journal_ends_the_job_when_its_journal_dies() {
    let d = scratch("reqdead");
    let s = state(&d);
    let ss = s.to_str().unwrap();
    let mk = marker();
    let trace = d.join("trace");
    let t0 = Instant::now();
    let (c, st, err) = run_st(
        &d,
        "dead",
        // the root execs a sleep: it cannot exit by itself before the kill's TERM reaches it (a
        // shell's `wait` returned when its child died first, and it exited 143: a race)
        &format!("--require-journal -- /bin/sh -c '/bin/sleep {mk} & exec /bin/sleep {mk}'"),
        &[("SHEEPR_TEST_STATE", ss), ("SHEEPR_TEST_JOURNAL_FAIL_AFTER", "2:ENOSPC"), ("SHEEPR_TEST_TRACE", trace.to_str().unwrap())],
        false,
    );
    let took = t0.elapsed();
    let left = common::scan(&mk, |w| w.get(1) == Some(&"/bin/sleep")).map(|v| v.len());
    common::kill_marked(&[&mk]);
    let notes: Vec<&str> = get(&st, "notes").and_then(Json::arr).unwrap_or(&[]).iter().filter_map(Json::str).collect();
    let t = std::fs::read_to_string(&trace).unwrap_or_default();
    assert_eq!(c, Some(125), "{st:?}");
    assert!(took < Duration::from_secs(10), "the job ran on for {took:?}");
    assert_eq!(left, Ok(0), "the tree was not killed");
    assert_eq!(get(&st, "trigger").and_then(Json::str), Some("journal"), "{st:?}");
    assert!(get(&st, "error").and_then(Json::str).is_some_and(|e| e.starts_with("the job journal failed: ")), "{st:?}");
    assert_eq!(get(&st, "error_code").and_then(Json::str), Some("ENOSPC"), "{st:?}");
    assert_eq!(get(&st, "error_source").and_then(Json::str), Some("resources"), "{st:?}");
    assert!(!notes.iter().any(|n| n.contains("after the trigger")), "{notes:?}");
    assert!(t.lines().any(|l| l == "report-cause journal"), "trace:\n{t}");
    // the root was killed by sheepr's kill (review of slice 3, P4)
    assert_eq!(get(&st, "root").and_then(Json::str), Some("signaled"), "{st:?}");
    assert_eq!(get(&st, "root_code"), Some(&Json::Null), "{st:?}");
    assert!(get(&st, "root_signal").and_then(Json::num).is_some(), "{st:?}");
    assert!(!err.contains("the job runs"), "stderr:\n{err}");
    assert_eq!(err.lines().filter(|l| l.contains("No space left")).count(), 1, "one line names the failure:\n{err}");
    let (c, st, _) = run_st(&d, "ctl", "-- /bin/sh -c '/bin/sleep 0.5 & wait'", &[("SHEEPR_TEST_STATE", ss), ("SHEEPR_TEST_JOURNAL_FAIL_AFTER", "2:ENOSPC")], false);
    let notes: Vec<&str> = get(&st, "notes").and_then(Json::arr).unwrap_or(&[]).iter().filter_map(Json::str).collect();
    assert_eq!((c, get(&st, "trigger"), get(&st, "error")), (Some(0), Some(&Json::Null), Some(&Json::Null)), "control: {st:?}");
    assert!(notes.iter().any(|n| n.starts_with("journal-failed")), "control: {notes:?}");
    let _ = std::fs::remove_dir_all(&d);
}

/// Plan §3: --require-journal with --mode root-disclaim (which keeps no journal) is refused
/// before the command runs: 125, source "usage", the command never ran. On macOS the refusal names
/// the combination, at parse time (before anything runs); Linux has no root-disclaim mode, so
/// there it is the unknown mode, refused after the auto-sweep as without the option, and never
/// "cannot be used with" (review of slice 3, P4).
#[test]
fn require_journal_with_root_disclaim_is_a_usage_error() {
    let d = scratch("reqdisclaim");
    let s = state(&d);
    let m = d.join("ran");
    let (c, st, err) = run_st(&d, "rd", &format!(r#"--require-journal --mode root-disclaim -- /bin/sh -c 'touch "{}"'"#, m.display()), &[("SHEEPR_TEST_STATE", s.to_str().unwrap())], false);
    assert_eq!(c, Some(125), "{st:?}");
    let (says, never) = if cfg!(target_os = "macos") { ("--require-journal cannot be used with --mode root-disclaim", "unknown mode") } else { ("unknown mode root-disclaim", "cannot be used with") };
    assert!(err.contains(says) && !err.contains(never), "stderr:\n{err}");
    assert_eq!(get(&st, "error_source").and_then(Json::str), Some("usage"), "{st:?}");
    assert!(!m.exists(), "the command ran");
    let _ = std::fs::remove_dir_all(&d);
}

/// Plan §3 (macOS): a caller that blocks SIGCONT gets a root that is not suspended, so it would
/// run before its line is written: --require-journal refuses it before anything runs: 125,
/// "not-started", an error that names SIGCONT, source "sheepr" (the caller's environment). The
/// control: the same caller without the option runs the command.
#[cfg(target_os = "macos")]
#[test]
fn require_journal_refuses_a_caller_that_blocks_sigcont() {
    let d = scratch("reqcont");
    let s = state(&d);
    let (m1, m2) = (d.join("m1"), d.join("m2"));
    let ss = s.to_str().unwrap();
    let (c, st, _) = run_st(&d, "cont", &format!(r#"--require-journal -- /bin/sh -c 'touch "{}"'"#, m1.display()), &[("SHEEPR_TEST_STATE", ss)], true);
    refused(c, &st, &m1, "", None, "sheepr");
    assert!(get(&st, "error").and_then(Json::str).is_some_and(|e| e.contains("SIGCONT")), "{st:?}");
    let (c, _, _) = run_st(&d, "ctl", &format!(r#"-- /bin/sh -c 'touch "{}"'"#, m2.display()), &[("SHEEPR_TEST_STATE", ss)], true);
    assert_eq!(c, Some(0), "control");
    assert!(m2.exists(), "control: the command did not run");
    let _ = std::fs::remove_dir_all(&d);
}

/// The children of `pid` (macOS, `ps`), each with its identity read now.
#[cfg(target_os = "macos")]
fn children_of(pid: i32) -> Vec<(i32, u64)> {
    let out = Command::new("ps").args(["-Ao", "pid=,ppid="]).output().unwrap();
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| {
            let mut w = l.split_whitespace();
            let (p, pp): (i32, i32) = (w.next()?.parse().ok()?, w.next()?.parse().ok()?);
            (pp == pid).then(|| common::found(p)).flatten()
        })
        .collect()
}

/// One `run --require-journal --status-fd 3 FLAGS -- /bin/sh ROOT MARK REG` (macOS) whose root
/// line fails (seam), held after the spawn (seam): the cell sends the suspended root an outside
/// CONT, waits for MARK (the root ran), then releases the hold. `at_freeze`, when given, runs
/// with REG while the refusal's kill holds after its freeze (seam). (exit code, status, the root
/// ran, stderr)
#[cfg(target_os = "macos")]
fn resumed(d: &Path, name: &str, flags: &str, root: &Path, env: &[(&str, &str)], at_freeze: Option<&dyn Fn(&Path)>) -> (Option<i32>, Option<Json>, bool, String) {
    let s = state(&d.join(name));
    let (mark, reg) = (d.join(format!("{name}.ran")), d.join(format!("{name}.reg")));
    let (ready, rel1, rel2, out, err) = (d.join(format!("{name}.ready")), d.join(format!("{name}.rel1")), d.join(format!("{name}.rel2")), d.join(format!("{name}.status")), d.join(format!("{name}.err")));
    let c = Command::new("/bin/sh")
        .args(["-c", &format!(r#"exec "$SD" run --require-journal --status-fd 3 {flags} -- /bin/sh "{}" "{}" "{}" 3>"{}" 2>"{}""#, root.display(), mark.display(), reg.display(), out.display(), err.display())])
        .env("SD", sheepr())
        .env("SHEEPR_TEST_STATE", &s)
        .env("SHEEPR_TEST_JOURNAL_FAIL_AFTER", "1")
        .env("SHEEPR_TEST_HOLD_AFTER_SPAWN", &rel1)
        .env("SHEEPR_TEST_HOLD_AFTER_FREEZE", &rel2)
        .env("SHEEPR_TEST_READY_FILE", &ready)
        .envs(env.iter().copied())
        .spawn()
        .unwrap();
    assert!(wait_for(&ready, 20), "{name}: the hold after the spawn was never reached");
    let roots = children_of(c.id() as i32);
    for &(p, id) in &roots {
        common::send(p, id, libc::SIGCONT); // the outside CONT
    }
    let ran = wait_for(&mark, 10);
    let _ = std::fs::remove_file(&ready);
    std::fs::write(&rel1, b"").unwrap();
    if let Some(f) = at_freeze {
        assert!(wait_for(&ready, 20), "{name}: the refusal's kill never froze a member");
        f(&reg);
    }
    std::fs::write(&rel2, b"").unwrap();
    let code = finish(c);
    assert_eq!(roots.len(), 1, "{name}: expected the one suspended root: {roots:?}");
    assert!(journals(&s).is_empty(), "{name}: a refusal left a journal: {:?}", journals(&s));
    (code, json::parse(std::fs::read_to_string(&out).unwrap_or_default().trim_end()).ok(), ran, std::fs::read_to_string(&err).unwrap_or_default())
}

/// Plan §3 (macOS): a root that cannot be journaled is killed with its tree, since an outside CONT
/// may have resumed it while it waited suspended: here the cell itself sends that CONT while
/// sheepr holds after the spawn (seam), the root starts a child that ignores TERM and marks that
/// it ran, then its root line fails (seam): the run is refused (125, "the job journal cannot be
/// kept: ...") and the root's child is gone too. Review of slice 3, P4: the refusal's kill serves
/// no nested run (the registration socket the root inherited is gone by its freeze), a limit
/// does not set `trigger` during it (a 50 ms timeout has passed by then: trigger stays null, no
/// note), and a kill that misses its deadline (seam: 0 ms) leaves no journal either. The control:
/// the root did run (its mark) before the refusal.
#[cfg(target_os = "macos")]
#[test]
fn require_journal_kills_a_resumed_root_and_its_tree() {
    let d = scratch("reqtree");
    let mk = marker();
    let root = d.join("root.sh");
    std::fs::write(&root, format!("printf '%s\\n' \"$SHEEPR_OUTER\" > \"$2\"\n/bin/sh -c 'trap \"\" TERM; exec /bin/sleep {mk}' &\ntouch \"$1\"\nwait\n")).unwrap();
    let socket_left = std::cell::Cell::new(None);
    let at_freeze = |reg: &Path| {
        let chain = std::fs::read_to_string(reg).unwrap_or_default();
        let own = chain.lines().filter(|l| !l.is_empty()).last().and_then(|l| l.split_once(' ')).map(|(_, p)| PathBuf::from(p));
        socket_left.set(Some(own.as_ref().map(|p| p.exists())));
    };
    let (code, st, ran, _) = resumed(&d, "tree", "--grace 0.2 --timeout 0.05s", &root, &[], Some(&at_freeze));
    std::thread::sleep(Duration::from_millis(200));
    let left = common::scan(&mk, |w| w.get(1) == Some(&"/bin/sleep")).map(|v| v.len());
    common::kill_marked(&[&mk]);
    let notes: Vec<&str> = get(&st, "notes").and_then(Json::arr).unwrap_or(&[]).iter().filter_map(Json::str).collect();
    assert!(ran, "control: the outside CONT did not run the root, so this proves nothing");
    assert_eq!(code, Some(125), "{st:?}");
    assert!(get(&st, "error").and_then(Json::str).is_some_and(|e| e.starts_with("the job journal cannot be kept: ")), "{st:?}");
    assert_eq!(left, Ok(0), "the root's child was left");
    assert_eq!(socket_left.get(), Some(Some(false)), "the registration socket during the refusal's kill (None: the root did not record it)");
    assert_eq!(get(&st, "trigger"), Some(&Json::Null), "a limit set the trigger during the refusal's kill: {st:?}");
    assert!(!notes.iter().any(|n| n.contains("timeout")), "{notes:?}");
    // a kill that misses its deadline: the journal is not kept either (`resumed` asserts it)
    let (code, st, ran, _) = resumed(&d, "deadline", "--grace 0.2", &root, &[("SHEEPR_TEST_DEADLINE_MS", "0")], None);
    common::kill_marked(&[&mk]);
    assert!(ran, "deadline: control: the root ran");
    assert_eq!(code, Some(125), "deadline: {st:?}");
    assert_eq!(get(&st, "deadline_missed"), Some(&Json::Bool(true)), "deadline: the kill must miss its deadline, or this proves nothing: {st:?}");
    let _ = std::fs::remove_dir_all(&d);
}

/// Review of slice 2's fixes, P3-A (macOS): when the root's identity cannot be read (seam), the
/// refusal must not claim the command did not run: an outside CONT can run the suspended root
/// first (here the cell sends it while sheepr holds after the spawn). Neither `error` nor stderr
/// says "did not run"; the control: the command did run (its mark). (Linux, where the root is
/// held before its exec, keeps "it did not run": `require_journal_runs_the_root_only_after_its_line`.)
#[cfg(target_os = "macos")]
#[test]
fn require_journal_never_claims_a_resumed_root_did_not_run() {
    let d = scratch("reqidentcont");
    let mk = marker();
    let root = d.join("root.sh");
    std::fs::write(&root, format!("/bin/sleep {mk} &\ntouch \"$1\"\nwait\n")).unwrap();
    let (code, st, ran, err) = resumed(&d, "ident", "", &root, &[("SHEEPR_TEST_FAIL_STEP", "root-identity")], None);
    common::kill_marked(&[&mk]);
    let error = get(&st, "error").and_then(Json::str).unwrap_or_default().to_string();
    assert!(ran, "control: the outside CONT did not run the root, so this proves nothing");
    assert_eq!(code, Some(125), "{st:?}");
    assert!(error.starts_with("the command's identity cannot be read"), "{st:?}");
    assert!(!error.contains("did not run") && !err.contains("did not run"), "error: {error}\nstderr:\n{err}");
    let _ = std::fs::remove_dir_all(&d);
}

/// Review of slice 3, P3-3 (macOS): the refused root is SIGKILLed while it is still suspended,
/// before the tree's kill. A caller that ignores TERM passes that on to the root, so the kill's
/// TERM and CONT would run it: with such a caller and a root line that fails (seam), the command
/// never runs (its marker is absent). The control: the same caller without the option runs it.
#[cfg(target_os = "macos")]
#[test]
fn require_journal_never_runs_a_refused_root_of_a_caller_that_ignores_term() {
    let d = scratch("reqignterm");
    let s = state(&d);
    for (name, flags) in [("req", "--require-journal"), ("ctl", "")] {
        let m = d.join(format!("{name}.ran"));
        let c = Command::new("/bin/sh")
            .args(["-c", &format!(r#"trap "" TERM; exec "$SD" run {flags} -- /bin/sh -c 'touch "{}"' 2>/dev/null"#, m.display())])
            .env("SD", sheepr())
            .env("SHEEPR_TEST_STATE", &s)
            .env("SHEEPR_TEST_JOURNAL_FAIL_AFTER", "1")
            .spawn()
            .unwrap();
        let code = finish(c);
        std::thread::sleep(Duration::from_millis(300));
        if flags.is_empty() {
            assert_eq!((code, m.exists()), (Some(0), true), "control: without the option the command runs");
        } else {
            assert_eq!(code, Some(125));
            assert!(!m.exists(), "the refused command ran");
        }
    }
    let _ = std::fs::remove_dir_all(&d);
}

/// Review of slice 3, P3-1: under --require-journal a journal that dies where it does not end the
/// job (here during the kill: a TERMed member forks an escapee, whose line is the failing write)
/// is still said: one stderr line that names the failure, and never "the job runs". The control:
/// without the option, the warning as before ("the job runs, but ...").
#[test]
fn require_journal_says_a_journal_that_dies_as_the_job_ends() {
    let d = scratch("reqending");
    let s = state(&d);
    for (name, opt) in [("req", true), ("ctl", false)] {
        let (r, err) = (d.join(format!("rec-{name}")), d.join(format!("{name}.err")));
        let flags: &[&str] = if opt { &["--require-journal"] } else { &[] };
        let mut c = Command::new(sheepr())
            .arg("run")
            .args(flags)
            .args(["--grace", "0.5", "--", fixture(), "fork-on-term", &marker()])
            .arg(&r)
            .env("SHEEPR_TEST_STATE", &s)
            .env("SHEEPR_TEST_JOURNAL_FAIL_AFTER", "3:ENOSPC")
            .stderr(std::fs::File::create(&err).unwrap())
            .spawn()
            .unwrap();
        let started = records(&r, 2).len() == 2;
        common::send_child(&mut c, libc::SIGTERM);
        let _ = finish(c);
        let recs = records(&r, 3);
        for p in recs.iter().filter(|p| common::alive(**p)) {
            common::send(p.0, p.1, libc::SIGKILL);
        }
        let e = std::fs::read_to_string(&err).unwrap_or_default();
        let said: Vec<&str> = e.lines().filter(|l| l.contains("journal") && l.contains("No space left")).collect();
        assert!(started, "{name}: the member was ready");
        assert_eq!(recs.len(), 3, "{name}: the escapee was born during the kill: {recs:?}");
        assert_eq!(said.len(), 1, "{name}: one line names the failure:\n{e}");
        assert_eq!(said[0].contains("the job runs"), !opt, "{name}:\n{e}");
    }
    let _ = std::fs::remove_dir_all(&d);
}

/// Review of slice 3, P3-2: under --require-journal a journal whose name no longer names the open
/// file while the job runs is lost: removed (no link left) or replaced (another file at its name).
/// The job ends: trigger "journal", exit 125, `error` names the journal; a replacing file is not
/// sheepr's, and is left. The control: without the option the job runs to its end (exit 0).
#[test]
fn require_journal_ends_the_job_when_its_journal_is_removed() {
    let d = scratch("reqgone");
    for (name, opt, replace) in [("removed", true, false), ("replaced", true, true), ("ctl", false, false)] {
        let s = state(&d.join(name));
        let out = d.join(format!("{name}.status"));
        let flags = if opt { "--require-journal" } else { "" };
        let t0 = Instant::now();
        let c = Command::new("/bin/sh")
            .args(["-c", &format!(r#"exec "$SD" run --status-fd 3 {flags} -- /bin/sleep 3 3>"{}""#, out.display())])
            .env("SD", sheepr())
            .env("SHEEPR_TEST_STATE", &s)
            .spawn()
            .unwrap();
        let end = Instant::now() + Duration::from_secs(10);
        let j = loop {
            if let Some(j) = journals(&s).pop() {
                break Some(j);
            }
            if Instant::now() > end {
                break None;
            }
            std::thread::sleep(Duration::from_millis(5));
        };
        let j = j.expect("the job's journal");
        if replace {
            let other = j.with_extension("other");
            std::fs::write(&other, b"not sheepr's\n").unwrap();
            std::fs::rename(&other, &j).unwrap();
        } else {
            std::fs::remove_file(&j).unwrap();
        }
        let code = finish(c);
        let took = t0.elapsed();
        let st = json::parse(std::fs::read_to_string(&out).unwrap_or_default().trim_end()).ok();
        if opt {
            assert_eq!(code, Some(125), "{name}: {st:?}");
            assert!(took < Duration::from_millis(2500), "{name}: the job ran on for {took:?}");
            assert_eq!(get(&st, "trigger").and_then(Json::str), Some("journal"), "{name}: {st:?}");
            assert!(get(&st, "error").and_then(Json::str).is_some_and(|e| e.starts_with("the job journal failed: ") && e.contains(j.to_str().unwrap()) && e.contains(if replace { "replaced" } else { "was removed" })), "{name}: {st:?}");
            assert_eq!(std::fs::read(&j).ok().as_deref() == Some(&b"not sheepr's\n"[..]), replace, "{name}: the replacing file");
        } else {
            assert_eq!((code, get(&st, "trigger")), (Some(0), Some(&Json::Null)), "{name}: {st:?}");
        }
    }
    let _ = std::fs::remove_dir_all(&d);
}

/// The Linux run of slice 3 (`abandon_shim` without its wait and SIGKILL survived: the shim exits
/// by itself when its go pipe closes): a shim that does not (seam: it ignores the EOF and does
/// not die with sheepr) is still ended by the refused run (its root line fails): SIGKILLed after
/// 2 s and reaped, and nothing of it is left. The control: a shim that exits by itself ends the
/// same refusal well within those 2 s.
#[cfg(target_os = "linux")]
#[test]
fn require_journal_ends_a_shim_that_ignores_its_abandon() {
    let d = scratch("reqshim");
    let s = state(&d);
    let ss = s.to_str().unwrap();
    for (name, seam) in [("stuck", true), ("ctl", false)] {
        let mk = marker();
        let mut env = vec![("SHEEPR_TEST_STATE", ss), ("SHEEPR_TEST_JOURNAL_FAIL_AFTER", "1")];
        if seam {
            env.push(("SHEEPR_TEST_SHIM_IGNORES_ABANDON", "1"));
        }
        let t0 = Instant::now();
        let (c, st, _) = run_st(&d, name, &format!("--require-journal -- /bin/sleep {mk}"), &env, false);
        let took = t0.elapsed();
        std::thread::sleep(Duration::from_millis(300));
        let left = common::scan(&mk, |_| true).map(|v| v.len());
        common::kill_marked(&[&mk]);
        assert_eq!(c, Some(125), "{name}: {st:?}");
        assert_eq!(left, Ok(0), "{name}: the shim was left");
        if seam {
            assert!(took >= Duration::from_secs(2), "the seam did not keep the shim, so this proves nothing ({took:?})");
        } else {
            assert!(took < Duration::from_millis(1500), "control: the shim did not end by itself ({took:?})");
        }
    }
    let _ = std::fs::remove_dir_all(&d);
}

/// The whole-batch review, P4: under --require-journal a journal removed while the job is already
/// ending (here during the kill: the cell removes it while the kill holds after its freeze, seam;
/// the root ignores TERM, so the kill reaches its freeze) is said once at the end (the TERM, not
/// the journal, ended the job), and never "the job runs". The control: without the option, no
/// line names it.
#[test]
fn require_journal_says_a_journal_removed_as_the_job_ends() {
    let d = scratch("reqgoneend");
    for (name, opt) in [("req", true), ("ctl", false)] {
        let s = state(&d.join(name));
        let mk = marker();
        let (ready, release, err, trapped) = (d.join(format!("{name}.ready")), d.join(format!("{name}.release")), d.join(format!("{name}.err")), d.join(format!("{name}.trapped")));
        let flags: &[&str] = if opt { &["--require-journal"] } else { &[] };
        // the root marks that it ignores TERM, and the TERM is sent only then (a TERM before its
        // trap would end it, and the kill would never freeze)
        let mut c = Command::new(sheepr())
            .arg("run")
            .args(flags)
            .args(["--grace", "0.2", "--", "/bin/sh", "-c", &format!("trap '' TERM; : > \"{}\"; exec /bin/sleep {mk}", trapped.display())])
            .env("SHEEPR_TEST_STATE", &s)
            .env("SHEEPR_TEST_HOLD_AFTER_FREEZE", &release)
            .env("SHEEPR_TEST_READY_FILE", &ready)
            .stderr(std::fs::File::create(&err).unwrap())
            .spawn()
            .unwrap();
        let end = Instant::now() + Duration::from_secs(10);
        let j = loop {
            if let Some(j) = journals(&s).pop() {
                break Some(j);
            }
            if Instant::now() > end {
                break None;
            }
            std::thread::sleep(Duration::from_millis(5));
        };
        // the root has its line once the journal names it
        let named = j.as_ref().is_some_and(|j| {
            let end = Instant::now() + Duration::from_secs(10);
            while Instant::now() < end && !std::fs::read_to_string(j).unwrap_or_default().contains("\"root\":true") {
                std::thread::sleep(Duration::from_millis(5));
            }
            std::fs::read_to_string(j).unwrap_or_default().contains("\"root\":true")
        });
        let ignores = wait_for(&trapped, 10);
        common::send_child(&mut c, libc::SIGTERM);
        let froze = wait_for(&ready, 20);
        if let Some(j) = &j {
            let _ = std::fs::remove_file(j);
        }
        std::fs::write(&release, b"").unwrap();
        let _ = finish(c);
        common::kill_marked(&[&mk]);
        let e = std::fs::read_to_string(&err).unwrap_or_default();
        let said = e.lines().filter(|l| l.contains("was removed")).count();
        assert!(named && ignores && froze, "{name}: the journal named the root {named}, the root ignores TERM {ignores}, the kill froze {froze} (the row proves nothing)");
        assert_eq!(said, usize::from(opt), "{name}: stderr:\n{e}");
        assert!(!e.contains("the job runs"), "{name}: stderr:\n{e}");
    }
    let _ = std::fs::remove_dir_all(&d);
}
