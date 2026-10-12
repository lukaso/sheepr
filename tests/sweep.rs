//! Phase-2 P4a: `sheepr sweep` (PLAN.md §3.5; PHASE2.md §3 sweep rules). Every cell has its
//! own test state; every process a sweep may aim at is built here from the fixture binary (its
//! environment carries the test tag: the sweep turns the latch on); decoys count every catchable
//! signal they get.

mod common;

use common::json::{self, Json};
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
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
    let d = std::env::temp_dir().join(format!("sr-sw-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn state(d: &Path) -> PathBuf {
    let s = d.join("state");
    std::fs::create_dir_all(&s).unwrap();
    std::fs::write(s.join(".sheepr-test"), b"").unwrap();
    s
}

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

fn journaled(s: &Path) -> Vec<i32> {
    journals(s)
        .iter()
        .flat_map(|j| std::fs::read_to_string(j).unwrap_or_default().lines().filter_map(|l| json::parse(l).ok()).collect::<Vec<_>>())
        .filter_map(|l| l.get("pid").and_then(Json::num).map(|n| n as i32))
        .collect()
}

/// An identity no process has: added to a real one to forge a mismatch. Never `+ 1`: on macOS
/// the identity is the uniqueid, which is system-wide and sequential, so `+ 1` is the NEXT process
/// created anywhere (another cell's), and a journaled id is a `puniq` link to its children.
const WRONG: u64 = 1 << 40;

/// The identity a forged header gives its gone supervisor: a uniqueid no process has had (they
/// count up from boot), never 1, which is launchd's (the original parent of hundreds of the
/// operator's processes: a sweep's `puniq` links must never be able to aim at them).
const NEVER: u64 = 1 << 40;

fn records(r: &Path) -> Vec<(i32, u64)> {
    std::fs::read_to_string(r)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| {
            let mut w = l.split_whitespace();
            Some((w.next()?.parse().ok()?, w.next()?.parse().ok()?))
        })
        .collect()
}

fn wait_until(secs: u64, mut f: impl FnMut() -> bool) -> bool {
    let end = Instant::now() + Duration::from_secs(secs);
    while !f() && Instant::now() < end {
        std::thread::sleep(Duration::from_millis(10));
    }
    f()
}

fn counted(r: &Path) -> usize {
    std::fs::read_to_string(format!("{}.sig", r.display())).map(|s| s.lines().count()).unwrap_or(0)
}

/// A decoy the test built: `sigcount R` (it counts every catchable signal it gets).
fn decoy(d: &Path, name: &str) -> (Decoy, (i32, u64), PathBuf) {
    let r = d.join(name);
    let c = Decoy(Command::new(fixture()).arg("sigcount").arg(&r).spawn().unwrap());
    assert!(wait_until(10, || !records(&r).is_empty()), "the decoy started");
    let p = records(&r)[0];
    (c, p, r)
}

/// A fixture process this file spawns (every one: `grep -n 'Command::new(fixture())\|/usr/bin/env'
/// tests/sweep.rs`), killed when the cell ends, a panic too: it holds the test's output and lives
/// up to 30 minutes, so a cell that fails before its `end_decoy` would otherwise hang the run
/// (reviews of f0ec620 and 63af0bf). It derefs to its `Child`, so `end_decoy(&mut c)` still works.
struct Decoy(Child);
impl std::ops::Deref for Decoy {
    type Target = Child;
    fn deref(&self) -> &Child {
        &self.0
    }
}
impl std::ops::DerefMut for Decoy {
    fn deref_mut(&mut self) -> &mut Child {
        &mut self.0
    }
}
impl Drop for Decoy {
    fn drop(&mut self) {
        if self.0.try_wait().ok().flatten().is_none() {
            end_decoy(&mut self.0);
        }
    }
}

/// An outer `sheepr run` a cell ends itself. If the cell fails first, a TERM on drop ends its whole
/// job (a SIGKILL would leave the job to a sweep), and a KILL follows after 5 s (review of
/// 6aa85ed, F3). It derefs to its `Child`.
struct Run(Child);
impl std::ops::Deref for Run {
    type Target = Child;
    fn deref(&self) -> &Child {
        &self.0
    }
}
impl std::ops::DerefMut for Run {
    fn deref_mut(&mut self) -> &mut Child {
        &mut self.0
    }
}
impl Drop for Run {
    fn drop(&mut self) {
        if self.0.try_wait().ok().flatten().is_none() {
            common::send_child(&mut self.0, libc::SIGTERM);
            let c = &mut self.0;
            if !wait_until(5, || c.try_wait().ok().flatten().is_some()) {
                end_decoy(&mut self.0);
            }
        }
    }
}

fn end_decoy(c: &mut Child) {
    common::send_child(c, libc::SIGKILL);
    let _ = c.wait();
}

/// `sheepr sweep ARGS` with this state; (exit code, trace notes).
fn sweep(s: &Path, d: &Path, args: &[&str], env: &[(&str, &str)]) -> (Option<i32>, String) {
    let trace = d.join(format!("trace-{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
    let mut c = Command::new(sheepr());
    c.arg("sweep").args(args).env("SHEEPR_TEST_STATE", s).env("SHEEPR_TEST_TRACE", &trace);
    for (k, v) in env {
        c.env(k, v);
    }
    let mut ch = c.spawn().unwrap();
    let end = Instant::now() + Duration::from_secs(30);
    let code = loop {
        if let Some(st) = ch.try_wait().unwrap() {
            break st.code();
        }
        if Instant::now() > end {
            common::send_child(&mut ch, libc::SIGKILL);
            let _ = ch.wait();
            break None;
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    (code, std::fs::read_to_string(&trace).unwrap_or_default())
}

/// `sheepr sweep ARGS` with this state, within 30 s (then KILL, code None); (exit code, stderr).
fn sweep_said(s: &Path, args: &[&str]) -> (Option<i32>, String) {
    sweep_said_with(s, args, &[])
}

/// `sweep_said` with these variables set.
fn sweep_said_with(s: &Path, args: &[&str], env: &[(&str, &str)]) -> (Option<i32>, String) {
    let mut all = vec!["sweep"];
    all.extend_from_slice(args);
    let (code, text, _) = sheepr_within(s, &all, env, 30);
    (code, text)
}

/// `sheepr ARGS` with this state and these variables, SIGKILLed after `secs` (code None);
/// (exit code, stderr, how long it ran).
fn sheepr_within(s: &Path, args: &[&str], env: &[(&str, &str)], secs: u64) -> (Option<i32>, String, Duration) {
    let n = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let err = std::env::temp_dir().join(format!("sr-sw-said-{}-{n}.err", std::process::id()));
    let t0 = Instant::now();
    let mut c = Command::new(sheepr())
        .args(args)
        .env("SHEEPR_TEST_STATE", s)
        .envs(env.iter().copied())
        .stdout(std::process::Stdio::null())
        .stderr(std::fs::File::create(&err).unwrap())
        .spawn()
        .unwrap();
    let end = t0 + Duration::from_secs(secs);
    let code = loop {
        if let Some(st) = c.try_wait().unwrap() {
            break st.code();
        }
        if Instant::now() > end {
            common::send_child(&mut c, libc::SIGKILL);
            let _ = c.wait();
            break None;
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    let took = t0.elapsed();
    let text = std::fs::read_to_string(&err).unwrap_or_default();
    let _ = std::fs::remove_file(&err);
    (code, text, took)
}

/// `sheepr sweep --strict` with this state and these variables, within 10 s (then KILL, code
/// None); (exit code, stderr).
fn strict(s: &Path, env: &[(&str, &str)]) -> (Option<i32>, String) {
    let (code, text, _) = sheepr_within(s, &["sweep", "--strict"], env, 10);
    (code, text)
}

/// The lines of `err` that name `file`.
fn naming<'a>(err: &'a str, file: &str) -> Vec<&'a str> {
    err.lines().filter(|l| l.contains(file)).collect()
}

/// A file `name` with `text` in this boot's journal folder `here` of state `s` (0600; the
/// folders 0700).
fn plant(s: &Path, here: &str, name: &str, text: &str) -> PathBuf {
    let dir = s.join("jobs").join(here);
    std::fs::create_dir_all(&dir).unwrap();
    mode(&s.join("jobs"), 0o700);
    mode(&dir, 0o700);
    let p = dir.join(name);
    std::fs::write(&p, text).unwrap();
    mode(&p, 0o600);
    p
}

/// A FIFO at `p`.
fn mkfifo(p: &Path) {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(p.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0, "mkfifo {}", p.display());
}

fn mode(p: &Path, m: u32) {
    std::fs::set_permissions(p, std::os::unix::fs::PermissionsExt::from_mode(m)).unwrap();
}

/// Folders a cell narrowed, put back to 0700 when the cell ends, a panic too, so a failed cell
/// never leaves a folder `rm -rf` cannot remove.
struct Modes(Vec<PathBuf>);
impl Drop for Modes {
    fn drop(&mut self) {
        for p in &self.0 {
            let _ = std::fs::set_permissions(p, std::os::unix::fs::PermissionsExt::from_mode(0o700));
        }
    }
}

/// This machine's journal folder name (`<boot>-<pidns>`), from a kept journal of a short job.
fn folder(d: &Path) -> (String, String, String) {
    let s = state(&d.join("probe"));
    let st = Command::new(sheepr())
        .args(["run", "--", "/bin/sh", "-c", "exit 0"])
        .env("SHEEPR_TEST_STATE", &s)
        .env("SHEEPR_TEST_KEEP_JOURNAL", "1")
        .status()
        .unwrap();
    let _ = st;
    let j = journals(&s).pop().expect("a kept journal");
    let h = json::parse(std::fs::read_to_string(&j).unwrap().lines().next().unwrap()).unwrap();
    let boot = h.get("boot").and_then(Json::str).unwrap().to_string();
    let pidns = h.get("pidns").and_then(Json::str).unwrap().to_string();
    let _ = std::fs::remove_dir_all(d.join("probe"));
    (format!("{boot}-{pidns}"), boot, pidns)
}

/// A forged journal in `<state>/jobs/<dir>/<job>.journal` for a dead supervisor, naming `members`.
fn forge(s: &Path, dir: &str, job: &str, owner: &str, boot: &str, pidns: &str, members: &[(i32, u64)], leave_strays: bool) -> PathBuf {
    let folder = s.join("jobs").join(dir);
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::set_permissions(s.join("jobs"), std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    std::fs::set_permissions(&folder, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    let uid = unsafe { libc::getuid() };
    let mut text = format!(
        "{{\"v\":1,\"kind\":\"header\",\"job\":\"{job}\",\"boot\":\"{boot}\",\"pidns\":\"{pidns}\",\"owner\":\"{owner}\",\"uid\":{uid},\"sup\":{{\"pid\":999999,\"id\":{NEVER}}},\"argv\":\"sheepr run\"}}\n"
    );
    for &(p, id) in members {
        text.push_str(&format!("{{\"v\":1,\"pid\":{p},\"id\":{id},\"ppid\":1,\"pid_id\":null,\"puniq\":null,\"cmd\":\"decoy\"}}\n"));
    }
    if leave_strays {
        text.push_str("{\"v\":1,\"kind\":\"leave-strays\"}\n");
    }
    let path = folder.join(format!("{job}.journal"));
    std::fs::write(&path, text).unwrap();
    std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o600)).unwrap();
    path
}

/// Cell 14: a job whose supervisor was SIGKILLed leaves its escapee; `sweep` finds it through
/// the journal and ends it, and the journal is removed.
#[test]
fn cell_14_sweep_ends_a_dead_jobs_escapee() {
    let d = scratch("c14");
    let s = state(&d);
    let r = d.join("rec");
    let mut c = Command::new(sheepr()).args(["run", "--", fixture(), "escapee-and-wait"]).arg(&r).env("SHEEPR_TEST_STATE", &s).spawn().unwrap();
    let g = wait_until(15, || !records(&r).is_empty()).then(|| records(&r)[0]);
    let journaled_g = g.is_some_and(|g| wait_until(10, || journaled(&s).contains(&g.0)));
    common::send_child(&mut c, libc::SIGKILL);
    let _ = c.wait();
    let alive_before = g.is_some_and(common::alive);
    let (code, _) = sweep(&s, &d, &[], &[]);
    let alive_after = g.is_some_and(common::alive);
    let root = records(&PathBuf::from(format!("{}.root", r.display())));
    for p in g.iter().chain(root.iter()) {
        common::send(p.0, p.1, libc::SIGKILL);
    }
    assert!(journaled_g, "the escapee was journaled");
    assert!(alive_before, "control: the escapee outlived its SIGKILLed supervisor");
    assert_eq!(code, Some(0));
    assert!(!alive_after, "sweep left the escapee alive");
    assert!(root.iter().all(|p| !common::alive(*p)), "the root is gone too");
    assert!(journals(&s).is_empty(), "the swept journal is removed");
    let _ = std::fs::remove_dir_all(&d);
}

/// The fences: a forged journal naming a live decoy with its correct identity is swept only from
/// this boot's and this pid namespace's folder, only for its owner tag, never with the
/// leave-strays mark; a journal elsewhere is left in place. The control, the same journal in
/// this folder for the default owner, ends the decoy.
#[test]
fn sweep_keeps_to_its_own_boot_pid_namespace_and_owner() {
    let d = scratch("fences");
    let (here, boot, pidns) = folder(&d);
    let cases: Vec<(&str, String, &str, bool, &[&str])> = vec![
        ("other-boot", format!("00000000-0000-0000-0000-000000000000-{pidns}"), "default", false, &[]),
        ("other-pidns", format!("{boot}-12345.678"), "default", false, &[]),
        ("other-owner", here.clone(), "liveapp", false, &[]),
        ("leave-strays", here.clone(), "default", true, &[]),
    ];
    for (name, dir, owner, strays, args) in cases {
        let s = state(&d.join(name));
        // this boot's folder exists too (with nothing to sweep), so a sweep does read this state
        std::fs::create_dir_all(s.join("jobs").join(&here)).unwrap();
        std::fs::set_permissions(s.join("jobs").join(&here), std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
        let (hb, hp) = match name {
            "other-boot" => ("00000000-0000-0000-0000-000000000000".to_string(), pidns.clone()),
            "other-pidns" => (boot.clone(), "12345.678".to_string()),
            _ => (boot.clone(), pidns.clone()),
        };
        let (mut c, p, r) = decoy(&d, &format!("decoy-{name}"));
        let j = forge(&s, &dir, "j-0badf00d", owner, &hb, &hp, &[p], strays);
        let (code, _) = sweep(&s, &d, args, &[]);
        let (alive, n) = (common::alive(p), counted(&r));
        end_decoy(&mut c);
        assert_eq!(code, Some(0), "{name}");
        assert!(alive && n == 0, "{name}: the decoy got {n} signal(s), alive {alive}");
        assert!(j.exists(), "{name}: the journal was deleted");
    }
    // controls: the same decoy journal in this folder (default owner), and the other owner's
    // journal swept by `--owner liveapp`
    for (name, owner, args) in [("control", "default", &[][..]), ("owner-control", "liveapp", &["--owner", "liveapp"][..])] {
        let s = state(&d.join(name));
        let (mut c, p, _) = decoy(&d, &format!("decoy-{name}"));
        forge(&s, &here, "j-0badf00d", owner, &boot, &pidns, &[p], false);
        let (code, _) = sweep(&s, &d, args, &[]);
        let alive = common::alive(p);
        end_decoy(&mut c);
        assert_eq!(code, Some(0), "{name}");
        assert!(!alive, "{name}: the sweep did not end the decoy");
    }
    let _ = std::fs::remove_dir_all(&d);
}

/// A live job's journal is locked: `sweep` leaves it and its members alone.
#[test]
fn sweep_skips_a_live_job() {
    let d = scratch("live");
    let s = state(&d);
    let r = d.join("rec");
    let mut c = Command::new(sheepr()).args(["run", "--", fixture(), "escapee-and-wait"]).arg(&r).env("SHEEPR_TEST_STATE", &s).spawn().unwrap();
    let g = wait_until(15, || !records(&r).is_empty()).then(|| records(&r)[0]);
    let journaled_g = g.is_some_and(|g| wait_until(10, || journaled(&s).contains(&g.0)));
    let (code, _) = sweep(&s, &d, &[], &[]);
    let alive = g.is_some_and(common::alive);
    let n = counted(&PathBuf::from(format!("{}.g", r.display())));
    common::send_child(&mut c, libc::SIGTERM); // its own supervisor ends it
    let _ = c.wait();
    assert!(journaled_g);
    assert_eq!(code, Some(0));
    assert!(alive && n == 0, "the live job's member got {n} signal(s), alive {alive}");
    let _ = std::fs::remove_dir_all(&d);
}

/// A journal entry whose identity does not match the live process at its pid is never
/// signalled, and neither is that process's child (the closure starts only from matching entries).
#[test]
fn a_wrong_identity_entry_is_never_signalled() {
    let d = scratch("wrongid");
    let (here, boot, pidns) = folder(&d);
    let s = state(&d);
    let r = d.join("forker");
    let mut c = Decoy(Command::new(fixture()).args(["forker", "1", "10"]).arg(&r).spawn().unwrap());
    assert!(wait_until(10, || records(&r).len() == 1), "the child started");
    let parent = (c.id() as i32, sheepr::ident::identity(c.id() as i32).unwrap());
    let child = records(&r)[0];
    forge(&s, &here, "j-0badf00d", "default", &boot, &pidns, &[(parent.0, parent.1 + WRONG)], false);
    let (code, _) = sweep(&s, &d, &[], &[]);
    let (pa, ca) = (common::alive(parent), common::alive(child));
    common::send(child.0, child.1, libc::SIGKILL);
    end_decoy(&mut c);
    assert_eq!(code, Some(0));
    assert!(pa && ca, "parent alive {pa}, child alive {ca}");
    assert!(journals(&s).is_empty(), "control: the journal was read (and, naming nothing alive, removed)");
    let _ = std::fs::remove_dir_all(&d);
}

/// A state directory another user could write (the boot folder group-writable) is refused:
/// exit 1, nothing signalled. The control is the fences cell (a 0700 folder is swept).
#[test]
fn sweep_refuses_a_folder_others_can_write() {
    let d = scratch("perm");
    let (here, boot, pidns) = folder(&d);
    let s = state(&d);
    let (mut c, p, r) = decoy(&d, "decoy");
    forge(&s, &here, "j-0badf00d", "default", &boot, &pidns, &[p], false);
    std::fs::set_permissions(s.join("jobs").join(&here), std::os::unix::fs::PermissionsExt::from_mode(0o770)).unwrap();
    let (code, _) = sweep(&s, &d, &[], &[]);
    let (alive, n) = (common::alive(p), counted(&r));
    end_decoy(&mut c);
    assert_eq!(code, Some(1), "refused");
    assert!(alive && n == 0, "the decoy got {n} signal(s)");
    let _ = std::fs::remove_dir_all(&d);
}

/// The wall control for the sweep (PHASE2.md §0.1): a journal that names an untagged process the
/// test built, with its correct identity: the sweep turns the latch on, and the door withholds
/// every signal to it (its own counter stays 0, a `withheld` line names it).
#[test]
fn the_sweep_turns_the_latch_on() {
    let d = scratch("latch");
    let (here, boot, pidns) = folder(&d);
    let s = state(&d);
    let r = d.join("untagged");
    let mut c = Decoy(Command::new("/usr/bin/env").args(["-i", fixture(), "sigcount"]).arg(&r).spawn().unwrap());
    assert!(wait_until(10, || !records(&r).is_empty()));
    let p = records(&r)[0];
    forge(&s, &here, "j-0badf00d", "default", &boot, &pidns, &[p], false);
    let sink = d.join("sink");
    let mut cmd = Command::new(sheepr());
    cmd.arg("sweep").env("SHEEPR_TEST_STATE", &s).env("SHEEPR_TEST_DEADLINE_MS", "500");
    common::cell_sink(&mut cmd, &sink);
    let _ = cmd.status();
    let (alive, n) = (common::alive(p), counted(&r));
    let lines = std::fs::read_to_string(&sink).unwrap_or_default();
    end_decoy(&mut c);
    assert!(alive && n == 0, "the untagged process got {n} signal(s)");
    assert!(lines.lines().any(|l| l.starts_with("withheld ") && l.split_whitespace().nth(1) == Some(&p.0.to_string())), "{lines:?}");
    let _ = std::fs::remove_dir_all(&d);
}

/// A child born to a journaled member after the supervisor died (no scan saw it) is swept
/// through the closure, and the sweeper journals it before its first signal to it.
#[test]
fn a_child_born_after_the_last_scan_is_swept_and_journaled_first() {
    let d = scratch("closure");
    let s = state(&d);
    let (go, r) = (d.join("go"), d.join("rec"));
    let log = d.join("log");
    // the member is a background child of the root (the root becomes a counting fixture), so it
    // outlives its supervisor on Linux too, where the root dies with it (PDEATHSIG)
    let rr = d.join("root");
    let script = format!(r#""$FX" spawn-on "{}" "{}" & exec "$FX" sigcount "{}""#, go.display(), r.display(), rr.display());
    let mut c = Command::new(sheepr()).args(["run", "--", "/bin/sh", "-c", &script]).env("FX", fixture()).env("SHEEPR_TEST_STATE", &s).spawn().unwrap();
    let parent = wait_until(15, || !records(&r).is_empty()).then(|| records(&r)[0]);
    let journaled_parent = parent.is_some_and(|p| wait_until(10, || journaled(&s).contains(&p.0)));
    common::send_child(&mut c, libc::SIGKILL);
    let _ = c.wait();
    let parent_alive = parent.is_some_and(common::alive);
    std::fs::write(&go, b"").unwrap();
    let child = wait_until(10, || records(&r).len() >= 2).then(|| records(&r)[1]);
    let (code, _) = sweep(&s, &d, &[], &[("SHEEPR_TEST_SIGNAL_LOG", log.to_str().unwrap())]);
    let alive: Vec<_> = records(&r).into_iter().chain(records(&rr)).filter(|p| common::alive(*p)).collect();
    for p in &alive {
        common::send(p.0, p.1, libc::SIGKILL);
    }
    assert!(journaled_parent && parent_alive && child.is_some(), "the member outlived its supervisor and forked");
    assert_eq!(code, Some(0));
    assert!(alive.is_empty(), "survivors {alive:?}");
    let text = std::fs::read_to_string(&log).unwrap_or_default();
    let cp = child.unwrap().0.to_string();
    let j = text.lines().position(|l| l.split_whitespace().collect::<Vec<_>>() == ["journal", cp.as_str()]);
    let first = text.lines().position(|l| {
        let w: Vec<&str> = l.split_whitespace().collect();
        w.len() >= 2 && (w[0] == "kill" || w[0] == "pidfd") && w[1] == cp
    });
    assert!(j.is_some() && first.is_some() && j < first, "journal at {j:?}, first signal at {first:?}:\n{text}");
    let _ = std::fs::remove_dir_all(&d);
}

/// `sweep` never touches its own ancestors: run from inside a dead job (the job's member is the
/// shell that starts it), it skips that job whole (the member lives, the journal is kept), and it
/// ends (never stops itself). A note names the skipped job.
#[test]
fn sweep_never_touches_its_own_ancestors() {
    let d = scratch("ancestors");
    let s = state(&d);
    let (go, rc, me) = (d.join("go"), d.join("rc"), d.join("me"));
    let rr = d.join("root");
    // the member W is a shell that waits for GO, then runs `sheepr sweep` (the debug build on
    // the test PATH) and writes its code
    // after it, W stays alive (a marked sleep), so the checks below see W itself
    let m = format!("29.{}", std::process::id());
    let w = format!(r#"echo $$ > "{}"; while [ ! -e "{}" ]; do sleep 0.02; done; sheepr sweep; echo $? > "{}"; sleep {m}"#, me.display(), go.display(), rc.display());
    // a witness member, also a background child (the root dies with its supervisor on Linux):
    // skipped whole, the job's witness is untouched
    let wit = d.join("witness");
    let script = format!(r#"/bin/sh -c '{}' & "$FX" sigcount "{}" & exec "$FX" sigcount "{}""#, w.replace('\'', r#"'\''"#), wit.display(), rr.display());
    let mut c = Command::new(sheepr()).args(["run", "--", "/bin/sh", "-c", &script]).env("FX", fixture()).env("SHEEPR_TEST_STATE", &s).spawn().unwrap();
    let wpid: Option<i32> = wait_until(15, || std::fs::read_to_string(&me).is_ok_and(|t| !t.trim().is_empty())).then(|| std::fs::read_to_string(&me).unwrap().trim().parse().unwrap());
    let wid = wpid.and_then(sheepr::ident::identity);
    let journaled_w = wpid.is_some_and(|p| wait_until(10, || journaled(&s).contains(&p)));
    common::send_child(&mut c, libc::SIGKILL);
    let _ = c.wait();
    let trace = d.join("trace");
    std::fs::write(d.join("trace-env"), trace.to_str().unwrap()).unwrap();
    std::fs::write(&go, b"").unwrap();
    // wait for the code itself, to its newline, not for the file: the shell creates the file
    // before it writes the code, and a read between the two parses nothing (the enosys leg)
    let finished = wait_until(20, || std::fs::read_to_string(&rc).is_ok_and(|t| t.ends_with('\n')));
    let code: Option<i32> = std::fs::read_to_string(&rc).ok().and_then(|t| t.trim().parse().ok());
    let w_alive = wpid.zip(wid).is_some_and(common::alive);
    // the job is skipped WHOLE: its other member (the root, a counting fixture) is untouched too
    let root = records(&rr);
    let witness = records(&wit);
    let root_untouched = !witness.is_empty() && witness.iter().all(|p| common::alive(*p)) && counted(&wit) == 0;
    let kept = !journals(&s).is_empty();
    if let Some(p) = wpid.zip(wid) {
        common::send(p.0, p.1, libc::SIGKILL);
    }
    for p in root.into_iter().chain(witness) {
        common::send(p.0, p.1, libc::SIGKILL);
    }
    common::kill_marked(&[&m]);
    assert!(journaled_w, "the shell was journaled as a member");
    assert!(finished, "the sweep did not end (did it stop itself?)");
    assert_eq!(code, Some(0));
    assert!(w_alive, "the sweep signalled its own ancestor");
    assert!(root_untouched, "the job holding the sweep's ancestor was swept");
    assert!(kept, "the skipped job's journal is kept");
    let _ = std::fs::remove_dir_all(&d);
}

/// An inner supervisor in a dead job is ended first (TERM, then CONT): it then ends its own job.
/// The inner job's escapee is born after the outer supervisor died (GO), so no outer scan saw it:
/// on macOS only the inner supervisor can reach it; on Linux the ppid closure does too.
#[test]
fn sweep_ends_an_inner_supervisor_first() {
    let d = scratch("inner");
    let s = state(&d);
    let (r, rr, go) = (d.join("rec"), d.join("root"), d.join("go"));
    let inner_state = state(&d.join("inner"));
    // the inner run is a background child (so it inherits no PDEATHSIG on Linux) with a state of
    // its own; the outer root becomes a counting fixture
    let script = format!(
        r#"SHEEPR_TEST_STATE="{}" sheepr run -- "$FX" escapee-and-wait "{}" "{}" & echo $! > "{}"; exec "$FX" sigcount "{}""#,
        inner_state.display(),
        r.display(),
        go.display(),
        d.join("innerpid").display(),
        rr.display()
    );
    let mut c = Run(Command::new(sheepr()).args(["run", "--", "/bin/sh", "-c", &script]).env("FX", fixture()).env("SHEEPR_TEST_STATE", &s).spawn().unwrap());
    // the inner supervisor is journaled by the outer (readiness), then the outer is SIGKILLed
    let inner: i32 = { assert!(wait_until(15, || std::fs::read_to_string(d.join("innerpid")).is_ok_and(|t| !t.trim().is_empty()))); std::fs::read_to_string(d.join("innerpid")).unwrap().trim().parse().unwrap() };
    assert!(wait_until(10, || journaled(&s).contains(&inner)), "the inner supervisor was journaled");
    common::send_child(&mut c, libc::SIGKILL);
    let _ = c.wait();
    std::fs::write(&go, b"").unwrap();
    let g = wait_until(15, || !records(&r).is_empty()).then(|| records(&r)[0]);
    let g_before = g.is_some_and(common::alive);
    let (code, _) = sweep(&s, &d, &[], &[]);
    let g_after = wait_until(5, || !g.is_some_and(common::alive)) == false;
    for p in g.iter().copied().chain(records(&rr)).chain(records(&PathBuf::from(format!("{}.root", r.display())))) {
        common::send(p.0, p.1, libc::SIGKILL);
    }
    assert!(g_before, "control: the inner escapee was born and lives");
    assert_eq!(code, Some(0));
    assert!(!g_after, "the inner job's escapee survived the sweep");
    let _ = std::fs::remove_dir_all(&d);
}

/// Review P2-9: the header is a fence of its own: a journal in THIS folder whose header names
/// another boot (or pid namespace) is not swept.
#[test]
fn a_header_from_another_boot_is_not_swept_from_this_folder() {
    let d = scratch("header");
    let (here, boot, pidns) = folder(&d);
    for (name, hb, hp) in [("boot", "00000000-0000-0000-0000-000000000000".to_string(), pidns.clone()), ("pidns", boot.clone(), "12345.678".to_string())] {
        let s = state(&d.join(name));
        let (mut c, p, r) = decoy(&d, &format!("decoy-{name}"));
        let j = forge(&s, &here, "j-0badf00d", "default", &hb, &hp, &[p], false);
        let (code, _) = sweep(&s, &d, &[], &[]);
        let (alive, n) = (common::alive(p), counted(&r));
        end_decoy(&mut c);
        assert_eq!(code, Some(0), "{name}");
        assert!(alive && n == 0, "{name}: swept ({n})");
        assert!(j.exists(), "{name}: deleted");
    }
    let _ = std::fs::remove_dir_all(&d);
}

/// Issue #15 (first step): a journal `sweep` cannot read (no header), or will not act on for
/// safety (another boot's header in this boot's folder), is said on stderr, one line naming the
/// file; before, only a debug build's trace saw it. A journal kept on purpose (`--leave-strays`)
/// says nothing. The exit code stays 0. The control, a readable dead journal, names no file.
/// The cell runs the debug build (a release build refuses a test environment); the line is a
/// plain `say!`, the same in both builds.
#[test]
fn a_skipped_journal_is_said_on_stderr() {
    let d = scratch("saysskip");
    let (here, boot, pidns) = folder(&d);
    let say = |s: &Path| sweep_said(s, &[]);
    let s = state(&d.join("skips"));
    forge(&s, &here, "j-0th3rb00t", "default", "00000000-0000-0000-0000-000000000000", &pidns, &[], false);
    forge(&s, &here, "j-k3pt", "default", &boot, &pidns, &[], true);
    let bad = s.join("jobs").join(&here).join("j-b4d.journal");
    std::fs::write(&bad, "not a journal\n").unwrap();
    std::fs::set_permissions(&bad, std::os::unix::fs::PermissionsExt::from_mode(0o600)).unwrap();
    let (code, err) = say(&s);
    let lines = |name: &str| err.lines().filter(|l| l.contains(name)).count();
    assert_eq!(code, Some(0), "{err}");
    assert_eq!(lines("j-b4d.journal"), 1, "the unreadable journal:\n{err}");
    assert_eq!(lines("j-0th3rb00t.journal"), 1, "another boot's journal:\n{err}");
    assert_eq!(lines("j-k3pt"), 0, "a journal kept on purpose:\n{err}");
    let c = state(&d.join("control"));
    forge(&c, &here, "j-0k", "default", &boot, &pidns, &[], false);
    let (code, err) = say(&c);
    assert_eq!(code, Some(0), "control: {err}");
    assert!(journals(&c).is_empty(), "control: the readable journal was swept");
    assert!(!err.contains(".journal"), "control:\n{err}");
    let _ = std::fs::remove_dir_all(&d);
}

/// Review of 6d0ae1a, P2-1: a journal folder `sweep` cannot list (mode 0300), or cannot reach
/// (`jobs/` at 0600), is refused with one stderr line that names it, exit 1, as an unsafe folder
/// is; before, it was read as empty: exit 0, nothing said, the stale job's decoy alive. The
/// control, the same state at 0700, is swept. Skipped as root (root reads a folder of any mode).
/// (No "the decoy lives" assertion: nothing can reach a journal it cannot name, review of
/// 35624d5 P3-4.)
#[test]
fn a_folder_sweep_cannot_read_is_refused_and_said() {
    if unsafe { libc::geteuid() } == 0 {
        eprintln!("skipped: root reads a folder of any mode");
        return;
    }
    let d = scratch("unlisted");
    let (here, boot, pidns) = folder(&d);
    let s = state(&d);
    let (mut c, p, _r) = decoy(&d, "decoy");
    forge(&s, &here, "j-0badf00d", "default", &boot, &pidns, &[p], false);
    let dir = s.join("jobs").join(&here);
    let _restore = Modes(vec![dir.clone(), s.join("jobs")]);
    mode(&dir, 0o300);
    let (code1, err1) = sweep_said(&s, &[]);
    mode(&dir, 0o700);
    mode(&s.join("jobs"), 0o600);
    let (code2, err2) = sweep_said(&s, &[]);
    mode(&s.join("jobs"), 0o700);
    let (code3, err3) = sweep_said(&s, &[]);
    let gone = !common::alive(p);
    end_decoy(&mut c);
    let names = |e: &str| e.lines().filter(|l| l.contains(here.as_str())).count();
    assert_eq!((code1, names(&err1)), (Some(1), 1), "a folder it cannot list:\n{err1}");
    assert_eq!((code2, names(&err2)), (Some(1), 1), "a folder it cannot reach:\n{err2}");
    assert_eq!(code3, Some(0), "control: {err3}");
    assert!(gone, "control: the same state at 0700 is swept");
    assert_eq!(names(&err3), 0, "control:\n{err3}");
    let _ = std::fs::remove_dir_all(&d);
}

/// Review of 35624d5, P2-1: a normal state is swept in silence, exit 0, nothing on stderr: a fresh
/// state (only the sentinel), `jobs/` with no folder for this boot and an old boot's folder that
/// still holds a journal (as after a reboot), and this boot's folder empty. Only "not found" means nothing to sweep; liveapp's boot sweep meets the
/// first two on every new instance and after every reboot.
#[test]
fn a_normal_state_is_swept_in_silence() {
    let d = scratch("normal");
    let (here, _, _) = folder(&d);
    let fresh = state(&d.join("fresh"));
    let noboot = state(&d.join("noboot"));
    // after a reboot: no folder for this boot, and the old boot's folder still holds a journal
    let old = noboot.join("jobs").join("00000000-0000-0000-0000-000000000000-0");
    std::fs::create_dir_all(&old).unwrap();
    mode(&noboot.join("jobs"), 0o700);
    mode(&old, 0o700);
    std::fs::write(old.join("j-0ldb00t0.journal"), "not read\n").unwrap();
    let empty = state(&d.join("empty"));
    std::fs::create_dir_all(empty.join("jobs").join(&here)).unwrap();
    mode(&empty.join("jobs"), 0o700);
    mode(&empty.join("jobs").join(&here), 0o700);
    for (n, s) in [("fresh", &fresh), ("no boot folder", &noboot), ("empty boot folder", &empty)] {
        let (code, err) = sweep_said(s, &[]);
        assert_eq!((code, err.as_str()), (Some(0), ""), "{n}");
    }
    let _ = std::fs::remove_dir_all(&d);
}

/// The `go` file of a live job's root loop, written when the cell ends, a panic too, so a cell
/// that fails before its own `go` never leaves the loop (and its supervisor) running, which would
/// hold the test's output and hang the run (whole-branch review P3-1). Declare it after the job,
/// so it drops first.
struct GoOnDrop(PathBuf);
impl Drop for GoOnDrop {
    fn drop(&mut self) {
        let _ = std::fs::write(&self.0, b"");
    }
}

/// A live job whose journal sorts after a stale job's, during a `sweep` held inside the stale
/// job's kill (after its freeze). `end_during`: the live job ends cleanly in that hold, so its
/// journal is gone when the sweep comes to it. Returns (held, gone, stderr).
fn race(tag: &str, end_during: bool) -> (bool, bool, String) {
    let d = scratch(tag);
    let (here, boot, pidns) = folder(&d);
    let s = state(&d);
    let go = d.join("go");
    let script = format!(r#"while [ ! -e "{}" ]; do sleep 0.05; done"#, go.display());
    let mut live = Command::new(sheepr())
        .args(["run", "--no-sweep", "--", "/bin/sh", "-c", &script])
        .env("SHEEPR_TEST_STATE", &s)
        .env("SHEEPR_TEST_JOB_ID", "zzzzzzzz")
        .spawn()
        .unwrap();
    let _go = GoOnDrop(go.clone());
    let lj = s.join("jobs").join(&here).join("j-zzzzzzzz.journal");
    assert!(wait_until(15, || lj.exists()), "the live job's journal");
    let (mut c, p, _r) = decoy(&d, "decoy");
    forge(&s, &here, "j-00000000", "default", &boot, &pidns, &[p], false);
    let (ready, release) = (d.join("ready"), d.join("release"));
    let (s2, rd2, rl2) = (s.clone(), ready.clone(), release.clone());
    let t = std::thread::spawn(move || {
        let o = Command::new(sheepr())
            .arg("sweep")
            .env("SHEEPR_TEST_STATE", &s2)
            .env("SHEEPR_TEST_DEADLINE_MS", "5000")
            .env("SHEEPR_TEST_HOLD_AFTER_FREEZE", &rl2)
            .env("SHEEPR_TEST_READY_FILE", &rd2)
            .output()
            .unwrap();
        String::from_utf8_lossy(&o.stderr).into_owned()
    });
    let held = wait_until(15, || ready.exists());
    if end_during {
        std::fs::write(&go, b"").unwrap();
        let _ = live.wait();
    }
    let gone = !lj.exists();
    std::fs::write(&release, b"").unwrap();
    let err = t.join().unwrap();
    if !end_during {
        std::fs::write(&go, b"").unwrap();
        let _ = live.wait();
    }
    end_decoy(&mut c);
    let _ = std::fs::remove_dir_all(&d);
    (held, gone, err)
}

/// Review of e3e2d3a, P1: a job that ends cleanly while a `sweep` works on another job is not
/// said (its journal is gone between the listing and the open: that is a live job ending, as a
/// clean end that unlinks after the lock is); the control, a job that stays live, is not said
/// either.
#[test]
fn a_job_that_ends_during_a_sweep_is_not_said() {
    let (held, gone, err) = race("ends", true);
    assert!(held && gone, "the race did not happen: held {held}, gone {gone}");
    assert!(!err.contains("j-zzzzzzzz"), "a job that ended cleanly during the sweep was said:\n{err}");
    let (held, gone, err) = race("stays", false);
    assert!(held && !gone, "control: held {held}, gone {gone}");
    assert!(!err.contains("j-zzzzzzzz"), "control: a live job was said:\n{err}");
}

/// The second wall control (PHASE2.md §4a, round 2): a journaled pid now held by an untagged
/// process under another identity is refused as `gone`: no signal, no `withheld` line.
#[test]
fn a_reused_journaled_pid_is_gone_not_withheld() {
    let d = scratch("reusedwall");
    let (here, boot, pidns) = folder(&d);
    let s = state(&d);
    let r = d.join("untagged");
    let mut c = Decoy(Command::new("/usr/bin/env").args(["-i", fixture(), "sigcount"]).arg(&r).spawn().unwrap());
    assert!(wait_until(10, || !records(&r).is_empty()));
    let p = records(&r)[0];
    forge(&s, &here, "j-0badf00d", "default", &boot, &pidns, &[(p.0, p.1 + WRONG)], false);
    let sink = d.join("sink");
    let mut cmd = Command::new(sheepr());
    cmd.arg("sweep").env("SHEEPR_TEST_STATE", &s);
    common::cell_sink(&mut cmd, &sink);
    let code = cmd.status().unwrap().code();
    let (alive, n) = (common::alive(p), counted(&r));
    let lines = std::fs::read_to_string(&sink).unwrap_or_default();
    end_decoy(&mut c);
    assert_eq!(code, Some(0));
    assert!(alive && n == 0, "{n}");
    assert!(lines.is_empty(), "a reused pid is gone, not withheld: {lines:?}");
    assert!(journals(&s).is_empty(), "control: the journal was read (and, naming nothing alive, removed)");
    let _ = std::fs::remove_dir_all(&d);
}

/// Review P2-9 (other-user leg only): a journal the leg planted as root, owned by another user,
/// naming this user's decoy with its correct identity, is not swept; the same journal owned by
/// this user is (the control). The leg passes the directories and the decoy in SR_PLANTED.
/// Issue #15 (`--strict`): another user's file is counted (3), and its line says sheepr will not
/// read it and to check how it got there, never "remove"; the action (checked, and removed: its
/// folder is this user's), the next strict sweep exits 0.
#[test]
fn another_users_journal_is_never_swept() {
    let Ok(planted) = std::env::var("SR_PLANTED") else {
        eprintln!("skipped: only the other-user leg plants a journal as root");
        return;
    };
    // "<state owned>|<state control>|<decoy pid>|<decoy id>|<decoy record>"
    let v: Vec<&str> = planted.split('|').collect();
    let (foreign, own, p, rec) = (PathBuf::from(v[0]), PathBuf::from(v[1]), (v[2].parse::<i32>().unwrap(), v[3].parse::<u64>().unwrap()), PathBuf::from(v[4]));
    let d = scratch("planted");
    let (code, err) = sweep_said(&foreign, &[]);
    let (code3, err3) = strict(&foreign, &[]);
    let (alive, n) = (common::alive(p), counted(&rec));
    let planted_journal = journals(&foreign).into_iter().find(|j| j.ends_with("j-0badf00d.journal")).expect("the planted journal");
    let removed = std::fs::remove_file(&planted_journal).is_ok();
    let (code4, err4) = strict(&foreign, &[]);
    assert_eq!(code3, Some(3), "--strict: {err3}");
    let l = naming(&err3, "j-0badf00d.journal");
    assert!(l.len() == 1 && l[0].contains("not this user's file; sheepr will not read it; check how it got there"), "--strict: {err3}");
    assert!(!err3.contains("remove"), "--strict: {err3}");
    assert!(removed, "the planted journal could not be removed from this user's folder");
    assert_eq!((code4, err4.as_str()), (Some(0), ""), "--strict, after the action");
    let (code2, err2) = sweep_said(&own, &[]);
    let gone = !common::alive(p);
    assert_eq!(code, Some(0));
    assert!(alive && n == 0, "another user's journal was swept ({n})");
    // issue #15: the skip is said, one line naming the file
    assert_eq!(err.lines().filter(|l| l.contains("j-0badf00d.journal")).count(), 1, "another user's journal:\n{err}");
    assert_eq!(code2, Some(0));
    assert!(gone, "control: the same journal owned by this user is swept");
    assert!(!err2.contains("j-0badf00d.journal"), "control:\n{err2}");
    let _ = std::fs::remove_dir_all(&d);
}

/// Every candidate a sweep finds is journaled before its first signal, not only those of its
/// first scan (PHASE2.md §3 rule 2): a member's child born while the sweep waits for an inner
/// supervisor to end (its caller ignores TERM, so the wait runs its full length) has its journal
/// line before any signal to it.
#[test]
fn a_member_born_during_the_supervisor_wait_is_journaled_first() {
    let d = scratch("latejournal");
    let s = state(&d);
    let (go, r, inner, rr, log) = (d.join("go"), d.join("rec"), d.join("inner"), d.join("root"), d.join("log"));
    let script = format!(
        r#"(trap "" TERM; exec "$SD" run -- "$FX" sigcount "{}") & "$FX" spawn-on "{}" "{}" & exec "$FX" sigcount "{}""#,
        inner.display(),
        go.display(),
        r.display(),
        rr.display()
    );
    let mut c = Command::new(sheepr()).args(["run", "--", "/bin/sh", "-c", &script]).env("FX", fixture()).env("SD", sheepr()).env("SHEEPR_TEST_STATE", &s).spawn().unwrap();
    let parent = wait_until(15, || !records(&r).is_empty() && !records(&inner).is_empty()).then(|| records(&r)[0]);
    let ir = records(&inner).first().copied();
    let isup = ir.and_then(|x| {
        let o = Command::new("ps").args(["-o", "ppid=", "-p", &x.0.to_string()]).output().ok()?;
        common::found(String::from_utf8_lossy(&o.stdout).trim().parse().ok()?)
    });
    let journaled_all = parent.is_some_and(|p| wait_until(10, || journaled(&s).contains(&p.0) && isup.is_some_and(|i| journaled(&s).contains(&i.0))));
    common::send_child(&mut c, libc::SIGKILL);
    let _ = c.wait();
    // the child is born while the sweep waits for the inner supervisor (grace 2 s + the
    // deadline): `go` is written once the signal log shows that wait has begun
    let (g2, l2) = (go.clone(), log.clone());
    let t = std::thread::spawn(move || {
        let end = Instant::now() + Duration::from_secs(20);
        while !std::fs::read_to_string(&l2).unwrap_or_default().lines().any(|l| l.starts_with("supervisor ")) && Instant::now() < end {
            std::thread::sleep(Duration::from_millis(5));
        }
        std::fs::write(&g2, b"").unwrap();
    });
    let (code, _) = sweep(&s, &d, &[], &[("SHEEPR_TEST_SIGNAL_LOG", log.to_str().unwrap()), ("SHEEPR_TEST_DEADLINE_MS", "1500")]);
    let _ = t.join();
    let child = records(&r).get(1).copied();
    let everyone: Vec<(i32, u64)> = records(&r).into_iter().chain(records(&rr)).chain(records(&inner)).chain(isup).collect();
    for p in &everyone {
        common::send(p.0, p.1, libc::SIGKILL);
    }
    assert!(journaled_all, "the outer did not journal the member and the inner supervisor");
    let cp = child.expect("the member's child was not born").0.to_string();
    let text = std::fs::read_to_string(&log).unwrap_or_default();
    let j = text.lines().position(|l| l.split_whitespace().collect::<Vec<_>>() == ["journal", cp.as_str()]);
    let first = text.lines().position(|l| {
        let w: Vec<&str> = l.split_whitespace().collect();
        w.len() >= 2 && (w[0] == "kill" || w[0] == "pidfd") && w[1] == cp
    });
    assert!(first.is_some(), "the sweep never signalled the late child (code {code:?}):\n{text}");
    assert!(j.is_some() && j < first, "journal at {j:?}, first signal at {first:?}:\n{text}");
    // born during the wait, not before the sweep's first scan
    let wait = text.lines().position(|l| l.starts_with("supervisor "));
    assert!(wait.is_some() && wait < j, "the child was journaled before the supervisor wait (at {j:?}, wait at {wait:?})");
    let _ = std::fs::remove_dir_all(&d);
}

/// The same rule inside the kill itself: a child born after the sweep's first freeze (its
/// parent, a member the test resumes while the sweep holds) is found by a later scan of the
/// kill, and has its journal line before any signal to it.
#[test]
fn a_member_born_during_the_kill_is_journaled_first() {
    let d = scratch("killjournal");
    let s = state(&d);
    let (go, r, rr, log, ready, release) = (d.join("go"), d.join("rec"), d.join("root"), d.join("log"), d.join("ready"), d.join("release"));
    let script = format!(r#""$FX" spawn-on "{}" "{}" & exec "$FX" sigcount "{}""#, go.display(), r.display(), rr.display());
    let mut c = Command::new(sheepr()).args(["run", "--", "/bin/sh", "-c", &script]).env("FX", fixture()).env("SHEEPR_TEST_STATE", &s).spawn().unwrap();
    let parent = wait_until(15, || !records(&r).is_empty() && !records(&rr).is_empty()).then(|| records(&r)[0]);
    let journaled_all = parent.is_some_and(|p| wait_until(10, || journaled(&s).contains(&p.0) && journaled(&s).contains(&records(&rr)[0].0)));
    common::send_child(&mut c, libc::SIGKILL);
    let _ = c.wait();
    let (s2, d2, l2, rd2, rl2) = (s.clone(), d.clone(), log.clone(), ready.clone(), release.clone());
    let t = std::thread::spawn(move || {
        let env = [("SHEEPR_TEST_SIGNAL_LOG", l2.to_str().unwrap()), ("SHEEPR_TEST_DEADLINE_MS", "5000"), ("SHEEPR_TEST_HOLD_AFTER_FREEZE", rl2.to_str().unwrap()), ("SHEEPR_TEST_READY_FILE", rd2.to_str().unwrap())];
        sweep(&s2, &d2, &[], &env)
    });
    // the sweep has frozen the job and holds: resume the parent, which spawns its child now
    let held = wait_until(15, || ready.exists());
    if let Some(p) = parent {
        common::send(p.0, p.1, libc::SIGCONT);
    }
    std::fs::write(&go, b"").unwrap();
    let born = wait_until(10, || records(&r).len() >= 2);
    std::fs::write(&release, b"").unwrap();
    let (code, _) = t.join().unwrap();
    let child = records(&r).get(1).copied();
    for p in records(&r).into_iter().chain(records(&rr)) {
        common::send(p.0, p.1, libc::SIGKILL);
    }
    assert!(journaled_all, "the job did not journal its members");
    assert!(held, "the sweep never reached its hold after the freeze");
    assert!(born, "the member's child was not born during the hold");
    let cp = child.unwrap().0.to_string();
    let text = std::fs::read_to_string(&log).unwrap_or_default();
    let j = text.lines().position(|l| l.split_whitespace().collect::<Vec<_>>() == ["journal", cp.as_str()]);
    let first = text.lines().position(|l| {
        let w: Vec<&str> = l.split_whitespace().collect();
        w.len() >= 2 && (w[0] == "kill" || w[0] == "pidfd") && w[1] == cp
    });
    assert!(first.is_some(), "the sweep never signalled the child born during the kill (code {code:?}):\n{text}");
    assert!(j.is_some() && j < first, "journal at {j:?}, first signal at {first:?}:\n{text}");
    let _ = std::fs::remove_dir_all(&d);
}

/// A journal line that names another user's process (with its correct identity) never reaches
/// the signal door: a root sweeper would otherwise deliver to it. Linux legs run as root; on a
/// normal account the kernel refuses the signal anyway, so the cell needs root.
#[cfg(target_os = "linux")]
#[test]
fn a_line_naming_another_users_process_is_never_signalled() {
    if unsafe { libc::getuid() } != 0 {
        eprintln!("skipped: needs root (a normal account cannot signal another user's process)");
        return;
    }
    let d = scratch("foreignuid");
    std::fs::set_permissions(&d, std::os::unix::fs::PermissionsExt::from_mode(0o777)).unwrap();
    let (here, boot, pidns) = folder(&d);
    let s = state(&d);
    let r = d.join("nobody");
    let mut c = Decoy(Command::new(fixture()).args(["as-uid", "65534", fixture(), "sigcount"]).arg(&r).spawn().unwrap());
    assert!(wait_until(10, || !records(&r).is_empty()), "the other user's process did not start");
    let p = records(&r)[0];
    forge(&s, &here, "j-0badf00d", "default", &boot, &pidns, &[p], false);
    let (code, _) = sweep(&s, &d, &[], &[]);
    let (alive, n) = (common::alive(p), counted(&r));
    end_decoy(&mut c);
    assert!(alive && n == 0, "another user's process was signalled: alive {alive}, {n} counted signal(s) (code {code:?})");
    let _ = std::fs::remove_dir_all(&d);
}

/// `kill j-` of a journal whose header names a live process that is no `sheepr` refuses and
/// signals nothing (a live job's supervisor is always a sheepr; anything else is a stale or
/// forged header, and its process's tree is outside the journal's lineage).
#[test]
fn kill_job_refuses_a_header_that_names_no_supervisor() {
    let d = scratch("fakesup");
    let (here, boot, pidns) = folder(&d);
    let s = state(&d);
    let r = d.join("decoy");
    let mut c = Decoy(Command::new(fixture()).args(["sigcount"]).arg(&r).spawn().unwrap());
    assert!(wait_until(10, || !records(&r).is_empty()));
    let p = records(&r)[0];
    let path = forge(&s, &here, "j-0badf00d", "default", &boot, &pidns, &[], false);
    let text = std::fs::read_to_string(&path).unwrap().replace(&format!("\"sup\":{{\"pid\":999999,\"id\":{NEVER}}}"), &format!("\"sup\":{{\"pid\":{},\"id\":{}}}", p.0, p.1));
    std::fs::write(&path, text).unwrap();
    let st = Command::new(sheepr()).args(["kill", "j-0badf00d"]).env("SHEEPR_TEST_STATE", &s).env("SHEEPR_TEST_DEADLINE_MS", "1000").status().unwrap();
    let (alive, n) = (common::alive(p), counted(&r));
    end_decoy(&mut c);
    assert!(alive && n == 0, "the process the header named got {n} signal(s)");
    assert_eq!(st.code(), Some(1));
    let _ = std::fs::remove_dir_all(&d);
}

/// A process a cell found, SIGKILLed by its identity when the cell ends, a panic too.
#[cfg(target_os = "macos")]
struct Ends((i32, u64));
#[cfg(target_os = "macos")]
impl Drop for Ends {
    fn drop(&mut self) {
        common::send(self.0 .0, self.0 .1, libc::SIGKILL);
    }
}

/// A root its supervisor never journaled (macOS): a supervisor SIGKILLed after the spawn and
/// before the root's line (a debug seam) leaves a journal with no root line, and the root stopped
/// for ever (it starts suspended, and only the supervisor's CONT resumes it). The kernel's parent
/// unique id (`puniq`) of the root is the supervisor the header names, so `ps <job>` lists the
/// root and the sweep ends it. The root is the fixture (the wall reads no environment of a
/// platform binary such as `/bin/sh`, so it would withhold every signal to it); it is found here
/// by its record path in its argv, and is ended by its identity if the cell fails. Linux has no
/// such root: its shim exits when the supervisor dies.
#[cfg(target_os = "macos")]
#[test]
fn a_root_its_supervisor_never_journaled_is_swept() {
    use std::os::unix::process::ExitStatusExt;
    let d = scratch("unjournaled");
    let s = state(&d);
    let mark = d.join("root").display().to_string();
    let mut c = Command::new(sheepr())
        .args(["run", "--", fixture(), "sigcount", &mark])
        .env("SHEEPR_TEST_STATE", &s)
        .env("SHEEPR_TEST_KILL_BEFORE_ROOT_JOURNAL", "1")
        .spawn()
        .unwrap();
    if !wait_until(30, || c.try_wait().ok().flatten().is_some()) {
        common::send_child(&mut c, libc::SIGKILL);
    }
    let st = c.wait().unwrap();
    // no unwrap before the guard: a stopped root never ends by itself
    let roots = common::scan(&mark, |w| w.get(2) == Some(&"sigcount")).unwrap_or_default();
    let _ends: Vec<Ends> = roots.iter().map(|&p| Ends(p)).collect();
    let js = journals(&s);
    let root_lines = js.iter().flat_map(|j| std::fs::read_to_string(j).unwrap_or_default().lines().map(String::from).collect::<Vec<_>>()).filter(|l| l.contains("\"root\":true")).count();
    let job = js.first().and_then(|j| j.file_stem()).map(|x| x.to_string_lossy().into_owned()).unwrap_or_default();
    let stopped_before = roots.len() == 1 && common::stopped(roots[0]);
    let listed = Command::new(sheepr()).args(["ps", "--json", &job]).env("SHEEPR_TEST_STATE", &s).output().unwrap();
    let listed = String::from_utf8_lossy(&listed.stdout).into_owned();
    let lists_root = roots.first().is_some_and(|r| listed.lines().filter_map(|l| json::parse(l).ok()).any(|j| j.get("pid").and_then(Json::num) == Some(r.0 as f64)));
    let (code, said) = sweep_said(&s, &[]);
    let gone = roots.first().is_some_and(|&r| wait_until(5, || !common::alive(r)));
    assert_eq!(st.signal(), Some(libc::SIGKILL), "control: the supervisor died of the seam's SIGKILL ({st:?})");
    assert_eq!(js.len(), 1, "control: its journal stays");
    assert_eq!(root_lines, 0, "control: the root was not journaled (the seam's window)");
    assert_eq!(roots.len(), 1, "control: one root carries the marker: {roots:?}");
    assert!(stopped_before, "control: the root was left stopped");
    assert!(lists_root, "ps {job} does not list the root {:?}:\n{listed}", roots[0]);
    assert_eq!(code, Some(0), "{said}");
    assert!(gone, "the sweep left the stopped root alive: {said}");
    assert!(said.contains("swept 1 dead job (1 process ended)"), "{said}");
    assert!(journals(&s).is_empty(), "the swept journal is removed");
    let _ = std::fs::remove_dir_all(&d);
}

/// A live parent P (`/bin/sh`) and its counting decoy child C, whose `puniq` is P's id: P as a
/// guard, P's and C's (pid, identity), and C's record.
#[cfg(target_os = "macos")]
fn parent_and_child(d: &Path) -> (Decoy, (i32, u64), (i32, u64), PathBuf) {
    let r = d.join("c");
    let p = Decoy(Command::new("/bin/sh").args(["-c", r#""$0" sigcount "$1" & wait"#]).arg(fixture()).arg(&r).spawn().unwrap());
    assert!(wait_until(10, || !records(&r).is_empty()), "the child started");
    let c = records(&r)[0];
    let pp = common::found(p.id() as i32).expect("P is alive");
    (p, pp, c, r)
}

/// A journal id is a `puniq` link (macOS) only when its process is one the scan can hold (alive at
/// the line's pid, this user's, above pid 1), or no live process has it: a header or a member line
/// that names a live process's id at another pid (forged or corrupt; launchd's id 1 is the
/// original parent of hundreds of this user's processes) brings in none of its children. P is a live `sh` whose child C is a counting
/// decoy (C's `puniq` is P's id). A forged dead job names P's id as its supervisor, then another
/// names it in a member line at another pid: C gets nothing. Once P is gone, a list of live ids
/// read as if other users' processes were refused (a debug seam) lacks launchd, so it is not
/// credible: the header's id is still no link. The control: the same header's sweep without the
/// seam ends C.
#[cfg(target_os = "macos")]
#[test]
fn a_journal_id_of_a_live_process_elsewhere_links_none_of_its_children() {
    let d = scratch("liveid");
    let (here, boot, pidns) = folder(&d);
    let s = state(&d);
    let (mut p, pp, c, r) = parent_and_child(&d);
    let _ends = Ends(c);
    let as_sup_at = |job: &str, pid: i32| {
        let path = forge(&s, &here, job, "default", &boot, &pidns, &[], false);
        let text = std::fs::read_to_string(&path).unwrap().replace(&format!("\"sup\":{{\"pid\":999999,\"id\":{NEVER}}}"), &format!("\"sup\":{{\"pid\":{pid},\"id\":{}}}", pp.1));
        std::fs::write(&path, text).unwrap();
    };
    let as_sup = |job: &str| as_sup_at(job, 999999);
    as_sup("j-0d1d0001");
    let (code_sup, said_sup) = sweep_said(&s, &[]);
    let after_sup = (common::alive(c), common::stopped(c), counted(&r));
    // a header naming P at its own pid: a dead job's supervisor is gone, so a live one is no link
    as_sup_at("j-0d1d0005", pp.0);
    let (code_own, said_own) = sweep_said(&s, &[]);
    let after_own = (common::alive(c), common::stopped(c), counted(&r));
    forge(&s, &here, "j-0d1d0002", "default", &boot, &pidns, &[(999998, pp.1)], false);
    let (code_line, said_line) = sweep_said(&s, &[]);
    let after_line = (common::alive(c), common::stopped(c), counted(&r));
    end_decoy(&mut p); // C is now an orphan whose `puniq` names a dead process
    let p_gone = wait_until(5, || !common::alive(pp));
    as_sup("j-0d1d0003");
    let (code_empty, said_empty) = sweep_said_with(&s, &[], &[("SHEEPR_TEST_LIVE_IDS_MINE", "1")]);
    let after_empty = (common::alive(c), common::stopped(c), counted(&r));
    as_sup("j-0d1d0004");
    let (code_ctl, said_ctl) = sweep_said(&s, &[]);
    let c_gone = wait_until(5, || !common::alive(c));
    assert_eq!(code_sup, Some(0), "{said_sup}");
    assert_eq!(after_sup, (true, false, 0), "a header naming a live process's id reached its child: {said_sup}");
    assert_eq!(code_own, Some(0), "{said_own}");
    assert_eq!(after_own, (true, false, 0), "a header naming a live process at its own pid reached its child: {said_own}");
    assert_eq!(code_line, Some(0), "{said_line}");
    assert_eq!(after_line, (true, false, 0), "a member line naming a live process's id at another pid reached its child: {said_line}");
    assert!(p_gone, "control: P ended");
    assert_eq!(code_empty, Some(0), "{said_empty}");
    assert_eq!(after_empty, (true, false, 0), "a list of live ids without other users' processes made a link: {said_empty}");
    assert_eq!(code_ctl, Some(0), "{said_ctl}");
    assert!(c_gone, "control: with P gone, the header's id is a link and the sweep ends C: {said_ctl}");
    assert!(said_ctl.contains("swept 1 dead job (1 process ended)"), "{said_ctl}");
    let _ = std::fs::remove_dir_all(&d);
}

/// `kill <pid>` keeps to the same fence as the sweep (macOS): when a dead job's journal names the
/// target T, a line in T's subtree (its parent is T) that names a live process P's id at another
/// pid brings in none of P's children. The control: once P is gone, the same line under another
/// target makes `kill` end C.
#[cfg(target_os = "macos")]
#[test]
fn kill_of_a_journaled_pid_links_no_live_id_elsewhere() {
    use std::io::Write;
    let d = scratch("killid");
    let (here, boot, pidns) = folder(&d);
    let s = state(&d);
    let (mut p, pp, c, r) = parent_and_child(&d);
    let _ends = Ends(c);
    let target = |name: &str, job: &str| -> (Decoy, (i32, u64)) {
        let (t, tp, _) = decoy(&d, name);
        let path = forge(&s, &here, job, "default", &boot, &pidns, &[tp], false);
        let mut f = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        writeln!(f, "{{\"v\":1,\"pid\":999998,\"id\":{},\"ppid\":{},\"pid_id\":{},\"puniq\":null,\"cmd\":\"x\"}}", pp.1, tp.0, tp.1).unwrap();
        (t, tp)
    };
    let kill = |t: (i32, u64)| Command::new(sheepr()).args(["kill", &format!("{}:{}", t.0, t.1)]).env("SHEEPR_TEST_STATE", &s).env("SHEEPR_TEST_DEADLINE_MS", "2000").output().unwrap();
    let (_t1, tp1) = target("t1", "j-0d1d0011");
    let o1 = kill(tp1);
    let t1_gone = wait_until(5, || !common::alive(tp1));
    let after = (common::alive(c), common::stopped(c), counted(&r));
    end_decoy(&mut p);
    let p_gone = wait_until(5, || !common::alive(pp));
    let (_t2, tp2) = target("t2", "j-0d1d0012");
    let o2 = kill(tp2);
    let c_gone = wait_until(5, || !common::alive(c));
    let said = |o: &std::process::Output| String::from_utf8_lossy(&o.stderr).into_owned();
    assert_eq!(o1.status.code(), Some(0), "{}", said(&o1));
    assert!(t1_gone, "control: kill ended its target");
    assert_eq!(after, (true, false, 0), "a journal line naming a live process's id reached its child: {}", said(&o1));
    assert!(p_gone, "control: P ended");
    assert_eq!(o2.status.code(), Some(0), "{}", said(&o2));
    assert!(c_gone, "control: with P gone, the line's id is a link and kill ends C: {}", said(&o2));
    let _ = std::fs::remove_dir_all(&d);
}

/// Runs `sheepr CMD` from inside a root that only the header's supervisor ties to its dead job
/// (macOS): the seam leaves the root unjournaled; the cell continues it (as something else may),
/// and it runs `sheepr CMD` as its child. The root is the fixture's `nosession`, which does not
/// exec again: `/bin/sh` is a trampoline that execs the shell, and an exec after the reparenting
/// resets `puniq` to 1. The job is j-0d1d0041. Returns (stderr, stdout, journals kept) once the
/// root has ended.
#[cfg(target_os = "macos")]
fn inside_an_unjournaled_root(name: &str, cmd: &[&str]) -> (String, String, usize) {
    let d = scratch(name);
    let s = state(&d);
    let mark = d.join("inner").display().to_string();
    let (err, out) = (d.join("err"), d.join("out"));
    let mut c = Command::new(sheepr())
        .args(["run", "--", fixture(), "nosession", &mark, sheepr()])
        .args(cmd)
        .env("SHEEPR_TEST_STATE", &s)
        .env("SHEEPR_TEST_KILL_BEFORE_ROOT_JOURNAL", "1")
        .env("SHEEPR_TEST_JOB_ID", "0d1d0041")
        .stdout(std::fs::File::create(&out).unwrap())
        .stderr(std::fs::File::create(&err).unwrap())
        .spawn()
        .unwrap();
    if !wait_until(30, || c.try_wait().ok().flatten().is_some()) {
        common::send_child(&mut c, libc::SIGKILL);
    }
    let _ = c.wait();
    // no unwrap before the guard: a stopped root never ends by itself
    let roots = common::scan(&mark, |w| w.get(2) == Some(&"nosession")).unwrap_or_default();
    let _ends: Vec<Ends> = roots.iter().map(|&p| Ends(p)).collect();
    let stopped_before = roots.len() == 1 && common::stopped(roots[0]);
    if let Some(&r) = roots.first() {
        common::send(r.0, r.1, libc::SIGCONT);
    }
    // the root waits for its child and then exits as it did
    let ran = roots.first().is_some_and(|&r| wait_until(30, || !common::alive(r)));
    let (e, o) = (std::fs::read_to_string(&err).unwrap_or_default(), std::fs::read_to_string(&out).unwrap_or_default());
    let kept = journals(&s).len();
    assert!(stopped_before, "control: one root, left stopped: {roots:?}");
    assert!(ran, "control: the continued root ran `sheepr {}` and ended: {e}", cmd.join(" "));
    let _ = std::fs::remove_dir_all(&d);
    (e, o, kept)
}

/// A sweep from inside a root that only the header's supervisor ties to its dead job skips that
/// job whole and keeps its journal (macOS), as for a root a line names: the root is the sweep's
/// ancestor (never a signal to the caller, and the record stays).
#[cfg(target_os = "macos")]
#[test]
fn a_sweep_inside_an_unjournaled_root_skips_its_job() {
    let (text, _, kept) = inside_an_unjournaled_root("inroot", &["sweep"]);
    assert!(text.contains("skipped job") && text.contains("this sheepr or one of its ancestors, was started by this job"), "the sweep inside the root did not skip its job: {text}");
    assert_eq!(kept, 1, "the journal is kept: {text}");
}

/// `kill j-JOBID` from inside such a root refuses (it sweeps a dead job the same way) and keeps
/// the journal, and the dry runs that say what it would do (`kill --dry-run`, `ps`) refuse with
/// the same line: with `--json`, one "refused" error line (macOS). (The root's own exit code is
/// lost: it is an orphan. a_dead_job_that_holds_the_caller_is_refused_by_every_command checks the
/// exit 1, and rows that a dry run without the check would list.)
#[cfg(target_os = "macos")]
#[test]
fn kill_and_its_dry_runs_inside_an_unjournaled_root_refuse_alike() {
    for (name, cmd) in [("inkill", &["kill", "j-0d1d0041"][..]), ("indry", &["kill", "--dry-run", "--json", "j-0d1d0041"][..]), ("inps", &["ps", "--json", "j-0d1d0041"][..])] {
        let (text, out, kept) = inside_an_unjournaled_root(name, cmd);
        assert!(text.contains("refusing to sweep j-0d1d0041") && text.contains("this sheepr or one of its ancestors, was started by this job"), "`{}` inside the root did not refuse as kill does: {text}", cmd.join(" "));
        if cmd.contains(&"--json") {
            assert!(refused_json(&out), "`{}`: not one refused line: {out}", cmd.join(" "));
        } else {
            assert_eq!(kept, 1, "`{}`: the journal is kept: {text}", cmd.join(" "));
        }
    }
}

/// A journal line that names a live process the scan can never hold as a member (launchd: pid 1,
/// the original parent of hundreds of this user's processes) is no `puniq` link (macOS), also at
/// its own pid: `ps` of a target that a dead job's journal names (the line in its subtree) and
/// `ps` of the job list nothing through it. `ps` only, so a regression signals nothing. The
/// control: the same line for a parent that is gone (P) lists its orphaned child C both ways.
#[cfg(target_os = "macos")]
#[test]
fn a_journal_line_naming_launchd_links_nothing() {
    use std::io::Write;
    let d = scratch("launchd");
    let (here, boot, pidns) = folder(&d);
    let s = state(&d);
    let (mut p, pp, c, _r) = parent_and_child(&d);
    let _ends = Ends(c);
    let (_t, tp, _) = decoy(&d, "t");
    let launchd = (1, sheepr::ident::identity(1).expect("launchd's identity"));
    let job = |line: (i32, u64)| {
        let path = forge(&s, &here, "j-0d1d0021", "default", &boot, &pidns, &[tp], false);
        let mut f = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        writeln!(f, "{{\"v\":1,\"pid\":{},\"id\":{},\"ppid\":{},\"pid_id\":{},\"puniq\":null,\"cmd\":\"x\"}}", line.0, line.1, tp.0, tp.1).unwrap();
    };
    // the proved rows only: a suspect row (an orphan in T's session that another cell left) is no
    // link's work
    let listed = |what: &str| -> Vec<i32> {
        let o = Command::new(sheepr()).args(["ps", "--json", what]).env("SHEEPR_TEST_STATE", &s).output().unwrap();
        String::from_utf8_lossy(&o.stdout)
            .lines()
            .filter_map(|l| json::parse(l).ok())
            .filter(|j| j.get("class").and_then(Json::str) != Some("suspect"))
            .filter_map(|j| j.get("pid").and_then(Json::num).map(|n| n as i32))
            .collect()
    };
    let t_arg = format!("{}:{}", tp.0, tp.1);
    job(launchd);
    let (by_t, by_job) = (listed(&t_arg), listed("j-0d1d0021"));
    end_decoy(&mut p); // C is now an orphan whose `puniq` names a dead process
    let p_gone = wait_until(5, || !common::alive(pp));
    job(pp);
    let (ctl_t, ctl_job) = (listed(&t_arg), listed("j-0d1d0021"));
    assert!(by_t == vec![tp.0], "ps of T lists more than T through a line naming launchd: {} rows", by_t.len());
    assert!(by_job == vec![tp.0], "ps of the job lists more than T through a line naming launchd: {} rows", by_job.len());
    assert!(p_gone, "control: P ended");
    assert!(ctl_t.contains(&c.0), "control: ps of T lists C through the line of its gone parent: {ctl_t:?}");
    assert!(ctl_job.contains(&c.0), "control: ps of the job lists C through the line of its gone parent: {ctl_job:?}");
    let _ = std::fs::remove_dir_all(&d);
}

/// A journaled member alive when the fence reads the live processes, and gone before the first
/// scan, still links its orphan (macOS): its id was one the scan could hold (alive at its pid, this
/// user's), so it is a link, and the sweep ends C. A debug seam pauses after the fence's two reads,
/// or between them (the held set is read first: a member that ends between the reads is then held,
/// and gone at the second read); the cell ends P in the pause.
#[cfg(target_os = "macos")]
fn member_gone_before_the_scan(name: &str, seam: &str, args: impl Fn(&Path, (i32, u64)) -> Vec<String>, line_under: bool) -> (Option<i32>, String, bool) {
    use std::io::Write;
    let d = scratch(name);
    let (here, boot, pidns) = folder(&d);
    let s = state(&d);
    let (mut p, pp, c, _r) = parent_and_child(&d);
    let _ends = Ends(c);
    let (_t, tp, _) = decoy(&d, "t");
    // a dead job naming P at its own pid: as a member line, or (for `kill T`) under T
    let path = forge(&s, &here, "j-0d1d0031", "default", &boot, &pidns, &[tp], false);
    if line_under {
        let mut f = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        writeln!(f, "{{\"v\":1,\"pid\":{},\"id\":{},\"ppid\":{},\"pid_id\":{},\"puniq\":null,\"cmd\":\"x\"}}", pp.0, pp.1, tp.0, tp.1).unwrap();
    } else {
        forge(&s, &here, "j-0d1d0031", "default", &boot, &pidns, &[pp], false);
    }
    let ready = d.join("ready");
    let err = d.join("err");
    let mut run = Run(Command::new(sheepr())
        .args(args(&s, tp))
        .env("SHEEPR_TEST_STATE", &s)
        .env(seam, "3000")
        .env("SHEEPR_TEST_READY_FILE", &ready)
        .env("SHEEPR_TEST_DEADLINE_MS", "2000")
        .stderr(std::fs::File::create(&err).unwrap())
        .spawn()
        .unwrap());
    let paused = wait_until(15, || ready.exists());
    end_decoy(&mut p); // P ends inside the pause: C is an orphan whose `puniq` names it
    // timed from the pause's own start: the seam creates the ready file just before it sleeps
    let began = std::fs::metadata(&ready).and_then(|m| m.created()).ok();
    let p_gone = wait_until(2, || !common::alive(pp)) && began.is_some_and(|b| b.elapsed().is_ok_and(|e| e < Duration::from_millis(2500)));
    let r = &mut run;
    let ended = wait_until(30, || r.try_wait().ok().flatten().is_some());
    let code = run.try_wait().ok().flatten().and_then(|st| st.code());
    let c_gone = wait_until(5, || !common::alive(c));
    let said = std::fs::read_to_string(&err).unwrap_or_default();
    assert!(paused, "control: sheepr paused after the fence: {said}");
    assert!(p_gone, "control: P ended inside the 3 s pause (within 2.5 s of it)");
    assert!(ended, "sheepr did not end: {said}");
    let _ = std::fs::remove_dir_all(&d);
    (code, said, c_gone)
}

#[cfg(target_os = "macos")]
#[test]
fn a_member_gone_before_the_sweeps_scan_still_links_its_orphan() {
    for (name, seam) in [("gonesw", "SHEEPR_TEST_SLEEP_AFTER_FENCE_MS"), ("gonesw2", "SHEEPR_TEST_SLEEP_BETWEEN_FENCE_READS_MS")] {
        let (code, said, c_gone) = member_gone_before_the_scan(name, seam, |_, _| vec!["sweep".into()], false);
        assert_eq!(code, Some(0), "{seam}: {said}");
        assert!(c_gone, "{seam}: the sweep left the orphan of a member that was alive at the fence: {said}");
        assert!(said.contains("swept 1 dead job (1 process ended)"), "{seam}: {said}");
    }
}

#[cfg(target_os = "macos")]
#[test]
fn a_member_gone_before_kills_scan_still_links_its_orphan() {
    for (name, seam) in [("gonekill", "SHEEPR_TEST_SLEEP_AFTER_FENCE_MS"), ("gonekill2", "SHEEPR_TEST_SLEEP_BETWEEN_FENCE_READS_MS")] {
        let (code, said, c_gone) = member_gone_before_the_scan(name, seam, |_, t| vec!["kill".into(), format!("{}:{}", t.0, t.1)], true);
        assert_eq!(code, Some(0), "{seam}: {said}");
        assert!(c_gone, "{seam}: kill left the orphan of a member that was alive at the fence: {said}");
    }
}

/// One `--json` refusal: stdout is exactly one error line whose code is "refused" (written only
/// with exit 1).
fn refused_json(out: &str) -> bool {
    let ls: Vec<&str> = out.lines().collect();
    ls.len() == 1 && json::parse(ls[0]).is_ok_and(|j| j.get("error").and_then(|e| e.get("code")).and_then(Json::str) == Some("refused"))
}

/// A dead job whose journal names the sweeping process itself (W, a shell that then execs sheepr)
/// and a live witness X: `sweep` skips it ("it holds pid"), and `kill j-JOBID` and its dry runs
/// (`kill --dry-run`, `ps`) refuse with exit 1; X gets nothing and the journal stays. On macOS no
/// other check catches this shape (W's original parent is the test, no member). Without the
/// check, the dry runs would list X.
#[test]
fn a_dead_job_that_holds_the_caller_is_refused_by_every_command() {
    let d = scratch("holds");
    let (here, boot, pidns) = folder(&d);
    let s = state(&d);
    let (_x, xp, xr) = decoy(&d, "x");
    for (i, cmd) in [&["sweep"][..], &["kill", "j-0d1d0051"][..], &["kill", "--dry-run", "--json", "j-0d1d0051"][..], &["ps", "--json", "j-0d1d0051"][..]].iter().enumerate() {
        let base = d.join(format!("w{i}"));
        let (out, err) = (d.join(format!("w{i}.out")), d.join(format!("w{i}.err")));
        let mut w = Decoy(
            Command::new("/bin/sh")
                .args(["-c", r#"echo $$ >"$0.pid"; while [ ! -e "$0.go" ]; do sleep 0.02; done; exec "$@""#])
                .arg(&base)
                .arg(sheepr())
                .args(cmd.iter())
                .env("SHEEPR_TEST_STATE", &s)
                .env("SHEEPR_TEST_DEADLINE_MS", "1000")
                .stdout(std::fs::File::create(&out).unwrap())
                .stderr(std::fs::File::create(&err).unwrap())
                .spawn()
                .unwrap(),
        );
        let pidf = PathBuf::from(format!("{}.pid", base.display()));
        assert!(wait_until(10, || std::fs::read_to_string(&pidf).is_ok_and(|t| t.ends_with('\n'))), "W started");
        let wp = common::found(std::fs::read_to_string(&pidf).unwrap().trim().parse().unwrap()).expect("W is alive");
        forge(&s, &here, "j-0d1d0051", "default", &boot, &pidns, &[wp, xp], false);
        std::fs::write(format!("{}.go", base.display()), b"").unwrap();
        let w0 = &mut w;
        assert!(wait_until(30, || w0.try_wait().ok().flatten().is_some()), "`{}` did not end", cmd.join(" "));
        let code = w.try_wait().ok().flatten().and_then(|st| st.code());
        let (o, e) = (std::fs::read_to_string(&out).unwrap_or_default(), std::fs::read_to_string(&err).unwrap_or_default());
        let what = cmd.join(" ");
        assert!(e.contains(&format!("it holds pid {}, this sheepr or one of its ancestors", wp.0)), "`{what}`: {e}");
        if cmd[0] == "sweep" {
            assert_eq!(code, Some(0), "`{what}`: {e}");
        } else {
            assert_eq!(code, Some(1), "`{what}`: {e}");
            assert!(e.contains("refusing to sweep j-0d1d0051"), "`{what}`: {e}");
        }
        if cmd.contains(&"--json") {
            assert!(refused_json(&o), "`{what}` listed rows of a job kill refuses: {o}");
        }
        assert_eq!((common::alive(xp), counted(&xr)), (true, 0), "`{what}` reached the witness: {e}");
        assert_eq!(journals(&s).len(), 1, "`{what}`: the journal is kept: {e}");
    }
    let _ = std::fs::remove_dir_all(&d);
}

/// The dry runs of a dead job (`ps`, `kill --dry-run`) refuse where `kill j-JOBID` refuses, with
/// the same line and exit 1: when sheepr cannot read its own chain of parent processes (a debug
/// seam makes this test's parent unreadable), for a journal kept with `--leave-strays`, and for a
/// busy journal (the cell holds its lock, as another sweep would). The control: with the chain
/// readable, and once the lock is released, `ps` lists the job's witness X.
#[test]
fn the_dry_runs_of_a_dead_job_refuse_where_kill_does() {
    let d = scratch("dryref");
    let (here, boot, pidns) = folder(&d);
    let s = state(&d);
    let (_x, xp, xr) = decoy(&d, "x");
    forge(&s, &here, "j-0d1d0061", "default", &boot, &pidns, &[xp], false);
    forge(&s, &here, "j-0d1d0062", "default", &boot, &pidns, &[xp], true);
    let busy = forge(&s, &here, "j-0d1d0063", "default", &boot, &pidns, &[xp], false);
    let lock = std::fs::File::open(&busy).unwrap();
    assert_eq!(unsafe { libc::flock(std::os::fd::AsRawFd::as_raw_fd(&lock), libc::LOCK_EX) }, 0);
    let me = std::process::id().to_string();
    let run = |args: &[&str], env: &[(&str, &str)]| {
        let o = Command::new(sheepr()).args(args).env("SHEEPR_TEST_STATE", &s).envs(env.iter().copied()).output().unwrap();
        (o.status.code(), String::from_utf8_lossy(&o.stdout).into_owned(), String::from_utf8_lossy(&o.stderr).into_owned())
    };
    let unreadable = [("SHEEPR_TEST_PARENT_UNREADABLE", me.as_str())];
    let (_, _, kill_err) = run(&["kill", "j-0d1d0061"], &unreadable);
    let (_, _, kept_err) = run(&["kill", "j-0d1d0062"], &[]);
    let (_, _, busy_err) = run(&["kill", "j-0d1d0063"], &[]);
    assert!(kill_err.contains("cannot follow its own chain"), "control: kill refuses: {kill_err}");
    assert!(kept_err.contains("left its strays"), "control: kill refuses a kept job: {kept_err}");
    assert!(busy_err.contains("is busy"), "control: kill refuses a busy job: {busy_err}");
    for dry in [&["ps", "--json"][..], &["kill", "--dry-run", "--json"][..]] {
        let what = dry.join(" ");
        let (code, out, err) = run(&[dry, &["j-0d1d0061"]].concat(), &unreadable);
        assert_eq!(code, Some(1), "`{what}` with the chain unreadable: {err}");
        assert!(err.trim_end() == kill_err.trim_end() && refused_json(&out), "`{what}` with the chain unreadable: {err}{out}");
        let (code, out, err) = run(&[dry, &["j-0d1d0062"]].concat(), &[]);
        assert_eq!(code, Some(1), "`{what}` of a kept job: {err}");
        assert!(err.trim_end() == kept_err.trim_end() && refused_json(&out), "`{what}` of a kept job: {err}{out}");
        let (code, out, err) = run(&[dry, &["j-0d1d0063"]].concat(), &[]);
        assert_eq!(code, Some(1), "`{what}` of a busy job: {err}");
        assert!(err.trim_end() == busy_err.trim_end() && refused_json(&out), "`{what}` of a busy job: {err}{out}");
    }
    drop(lock);
    let (code, out, err) = run(&["ps", "--json", "j-0d1d0063"], &[]);
    assert_eq!(code, Some(0), "control: the lock released: {err}");
    assert!(out.lines().any(|l| json::parse(l).is_ok_and(|j| j.get("pid").and_then(Json::num) == Some(xp.0 as f64))), "control: the lock released, ps lists X: {out}");
    let (code, out, err) = run(&["ps", "--json", "j-0d1d0061"], &[]);
    assert_eq!(code, Some(0), "control: {err}");
    assert!(out.lines().any(|l| json::parse(l).is_ok_and(|j| j.get("pid").and_then(Json::num) == Some(xp.0 as f64))), "control: ps lists X: {out}");
    assert_eq!((common::alive(xp), counted(&xr)), (true, 0), "X got a signal");
    let _ = std::fs::remove_dir_all(&d);
}

/// A run's registration folder (macOS: `$TMPDIR/sr-XXXXXXXX`, holding the socket `s` and an
/// `owner` record): a run started here with TMPDIR in the cell's scratch, its folder from the
/// trace's `listening` line, and its root (sigcount) once it runs.
#[cfg(target_os = "macos")]
fn listener_run(d: &Path, tmp: &Path, s: &Path, name: &str) -> (Run, PathBuf, (i32, u64)) {
    let trace = d.join(format!("{name}.trace"));
    let rec = d.join(format!("{name}.rec"));
    let c = Run(Command::new(sheepr()).args(["run", "--", fixture(), "sigcount"]).arg(&rec).env("TMPDIR", tmp).env("SHEEPR_TEST_STATE", s).env("SHEEPR_TEST_TRACE", &trace).spawn().unwrap());
    let line = || std::fs::read_to_string(&trace).unwrap_or_default().lines().find_map(|l| l.strip_prefix("listening ").map(PathBuf::from));
    assert!(wait_until(15, || line().is_some()), "{name}: the run is not listening");
    assert!(wait_until(15, || !records(&rec).is_empty()), "{name}: the root did not start");
    let folder = line().unwrap().parent().unwrap().to_path_buf();
    (c, folder, records(&rec)[0])
}

/// A socket file nobody listens on (bound, then closed: the file stays).
#[cfg(target_os = "macos")]
fn dead_socket(p: &Path) {
    drop(std::os::unix::net::UnixListener::bind(p).unwrap());
}

/// A registration folder made here: 0700, an owner record (if any), a dead socket, extra files.
#[cfg(target_os = "macos")]
fn regdir(tmp: &Path, name: &str, owner: Option<&str>, extra: &[&str]) -> PathBuf {
    let f = tmp.join(name);
    std::fs::create_dir(&f).unwrap();
    mode(&f, 0o700);
    if let Some(o) = owner {
        std::fs::write(f.join("owner"), o).unwrap();
    }
    dead_socket(&f.join("s"));
    for x in extra {
        std::fs::write(f.join(x), b"x").unwrap();
    }
    f
}

/// The mark a debug sweep needs in its TMPDIR before it reaps there (src/sweep.rs reap_bases).
#[cfg(target_os = "macos")]
const MARK: &str = ".sheepr-test-reap";

/// A cell's own temp folder for the registration-folder cells: `<d>/t`, 0700, marked as the cell's.
#[cfg(target_os = "macos")]
fn reap_tmp(d: &Path) -> PathBuf {
    let tmp = d.join("t");
    std::fs::create_dir(&tmp).unwrap();
    mode(&tmp, 0o700);
    std::fs::write(tmp.join(MARK), b"").unwrap();
    tmp
}

/// Set a path's modification time to two days ago.
#[cfg(target_os = "macos")]
fn age(p: &Path) {
    let t = std::time::SystemTime::now() - Duration::from_secs(2 * 86400);
    std::fs::File::open(p).unwrap().set_modified(t).unwrap();
}

/// Issue #20: a run killed with SIGKILL leaves its registration folder; `sweep` removes it, and
/// keeps the folder of a run that is alive. A debug build does so only with the seam
/// SHEEPR_TEST_REAP_LISTENERS=1 (the cell's TMPDIR is its own scratch: the operator's temp folder
/// is never read). The folder's owner record names the run's supervisor.
#[cfg(target_os = "macos")]
#[test]
fn a_killed_runs_registration_folder_is_removed_by_the_sweep() {
    let d = scratch("reap");
    let s = state(&d);
    let tmp = reap_tmp(&d);
    let (mut dead, fdead, rdead) = listener_run(&d, &tmp, &s, "dead");
    let (_live, flive, _rlive) = listener_run(&d, &tmp, &s, "live");
    let owner = std::fs::read_to_string(fdead.join("owner")).unwrap_or_default();
    let sup = common::found(dead.id() as i32).expect("the supervisor");
    common::send_child(&mut dead, libc::SIGKILL);
    let _ = dead.wait();
    common::send(rdead.0, rdead.1, libc::SIGKILL);
    let kept_after_kill = fdead.exists();
    let tmp_s = tmp.display().to_string();
    let (code0, said0) = sweep_said_with(&s, &[], &[("TMPDIR", tmp_s.as_str())]);
    let kept_without_seam = fdead.exists();
    let (code, said) = sweep_said_with(&s, &[], &[("TMPDIR", tmp_s.as_str()), ("SHEEPR_TEST_REAP_LISTENERS", "1")]);
    assert_eq!(owner, format!("v1 {} {} 0\n", sup.0, sup.1), "the owner record names the supervisor");
    assert!(kept_after_kill, "control: the killed run's folder stays after the kill");
    assert_eq!(code0, Some(0), "{said0}");
    assert!(kept_without_seam, "a debug sweep without the seam removed a folder: {said0}");
    assert_eq!(code, Some(0), "{said}");
    assert!(!fdead.exists(), "the sweep left the killed run's folder: {said}");
    assert!(flive.join("s").exists(), "the sweep removed a live run's folder: {said}");
    assert!(said.contains("removed 1 registration folder of a sheepr that is gone"), "{said}");
    let _ = std::fs::remove_dir_all(&d);
}

/// What the sweep removes, and what it leaves (macOS): a folder of a dead owner is removed only
/// when it is a registration folder exactly (the name `sr-` and 8 characters, this user's, 0700,
/// not a symlink, holding nothing but `s` and `owner`) and of this pid namespace; each row below
/// differs from the removed control in one of these. A folder with no owner record (an older
/// sheepr's) is removed only when it is more than a day old and nothing listens on its socket;
/// an old empty one (made, then never bound) too.
#[cfg(target_os = "macos")]
#[test]
fn the_sweep_removes_only_dead_registration_folders() {
    let d = scratch("reapx");
    let s = state(&d);
    let tmp = reap_tmp(&d);
    let dead = format!("v1 999998 {NEVER} 0\n");
    let ctl = regdir(&tmp, "sr-Ctl00001", Some(&dead), &[]);
    let extra = regdir(&tmp, "sr-Xtra0001", Some(&dead), &["x"]);
    let open = regdir(&tmp, "sr-Mode0755", Some(&dead), &[]);
    mode(&open, 0o755);
    let target = regdir(&d, "linked", Some(&dead), &[]);
    std::os::unix::fs::symlink(&target, tmp.join("sr-Link0001")).unwrap();
    let ns = regdir(&tmp, "sr-Pidns001", Some(&format!("v1 999998 {NEVER} 9.9\n")), &[]);
    let short = regdir(&tmp, "sr-short", Some(&dead), &[]);
    let old = regdir(&tmp, "sr-Old00001", None, &[]);
    age(&old);
    let young = regdir(&tmp, "sr-Young001", None, &[]);
    let listened = tmp.join("sr-Lstn0001");
    std::fs::create_dir(&listened).unwrap();
    mode(&listened, 0o700);
    let _l = std::os::unix::net::UnixListener::bind(listened.join("s")).unwrap();
    age(&listened);
    let empty = tmp.join("sr-Empty001");
    std::fs::create_dir(&empty).unwrap();
    mode(&empty, 0o700);
    age(&empty);
    // an owner record that does not parse (an empty one: a failed or cut write) counts as none
    let blank = regdir(&tmp, "sr-Blank001", Some(""), &[]);
    age(&blank);
    let cut = regdir(&tmp, "sr-Cut00001", Some("v1 999998"), &[]);
    age(&cut);
    let blank_young = regdir(&tmp, "sr-Blank002", Some(""), &[]);
    // only positive evidence that the owner is gone: a live owner whose identity cannot be read
    // (a debug seam) stays; a pid that now holds another process (its identity differs) is gone
    let (_x, xp, _) = decoy(&d, "owner");
    let (_y, yp, _) = decoy(&d, "other");
    let alive = regdir(&tmp, "sr-Alive001", Some(&format!("v1 {} {} 0\n", xp.0, xp.1)), &[]);
    let reused = regdir(&tmp, "sr-Reuse001", Some(&format!("v1 {} {NEVER} 0\n", yp.0)), &[]);
    // a record that does not parse, on an old folder whose socket is listened on: kept
    let blank_listened = tmp.join("sr-Blank003");
    std::fs::create_dir(&blank_listened).unwrap();
    mode(&blank_listened, 0o700);
    std::fs::write(blank_listened.join("owner"), "").unwrap();
    let _bl = std::os::unix::net::UnixListener::bind(blank_listened.join("s")).unwrap();
    age(&blank_listened);
    let tmp_s = tmp.display().to_string();
    let xs = xp.0.to_string();
    let (code, said) = sweep_said_with(&s, &[], &[("TMPDIR", tmp_s.as_str()), ("SHEEPR_TEST_REAP_LISTENERS", "1"), ("SHEEPR_TEST_IDENTITY_UNREADABLE", xs.as_str())]);
    let gone = |p: &Path| std::fs::symlink_metadata(p).is_err();
    // a folder that stays keeps everything it held (removing its socket or owner record would
    // break it even when the folder itself stays)
    let whole = |p: &Path, owner: bool| p.join("s").exists() && p.join("owner").exists() == owner;
    assert_eq!(code, Some(0), "{said}");
    assert!(gone(&ctl), "control: a dead owner's folder is removed: {said}");
    assert!(whole(&extra, true) && extra.join("x").exists(), "a folder holding another file was touched");
    assert!(whole(&open, true), "a folder others can read (0755) was touched");
    assert!(!gone(&tmp.join("sr-Link0001")) && whole(&target, true), "a symlink (or its target) was touched");
    assert!(whole(&ns, true), "a folder of another pid namespace was touched");
    assert!(whole(&short, true), "a folder whose name is not a registration folder's was touched");
    assert!(gone(&old), "an old owner-less folder nobody listens on stayed: {said}");
    assert!(whole(&young, false), "a young owner-less folder was touched");
    assert!(whole(&listened, false), "an owner-less folder whose socket is listened on was touched");
    assert!(gone(&empty), "an old empty folder stayed: {said}");
    assert!(gone(&blank) && gone(&cut), "an old folder whose owner record does not parse stayed: {said}");
    assert!(whole(&blank_young, true), "a young folder whose owner record does not parse was touched");
    assert!(whole(&blank_listened, true), "an old folder whose owner record does not parse, listened on, was touched");
    assert!(whole(&alive, true), "a live owner's folder was removed because its identity could not be read");
    assert!(gone(&reused), "a folder whose owner's pid now holds another process stayed: {said}");
    assert!(said.contains("removed 6 registration folders of sheeprs that are gone"), "{said}");
    let _ = std::fs::remove_dir_all(&d);
}

/// The auto-sweep before a `run` removes a gone sheepr's registration folder too (macOS; the
/// seam, as above), and the run's own folder goes when it ends.
#[cfg(target_os = "macos")]
#[test]
fn the_auto_sweep_removes_a_dead_registration_folder() {
    let d = scratch("reapauto");
    let s = state(&d);
    let tmp = reap_tmp(&d);
    let f = regdir(&tmp, "sr-Auto0001", Some(&format!("v1 999998 {NEVER} 0\n")), &[]);
    // the auto-sweep's 50 ms for the folders, widened here (one stall under load would skip the
    // only entry)
    let st = Command::new(sheepr()).args(["run", "--", "/usr/bin/true"]).env("TMPDIR", &tmp).env("SHEEPR_TEST_STATE", &s).env("SHEEPR_TEST_REAP_LISTENERS", "1").env("SHEEPR_TEST_REAP_MS", "5000").status().unwrap();
    let left: Vec<String> = std::fs::read_dir(&tmp).unwrap().flatten().map(|e| e.file_name().to_string_lossy().into_owned()).filter(|n| n != MARK).collect();
    assert_eq!(st.code(), Some(0));
    assert!(!f.exists(), "the auto-sweep left a gone sheepr's folder");
    assert!(left.is_empty(), "the temp folder still holds {left:?}");
    let _ = std::fs::remove_dir_all(&d);
}

/// A debug build reaps only a temp folder its cell marked as its own (`.sheepr-test-reap`, a
/// regular file), also with the seam (macOS): the operator's temp folders never hold the mark, so
/// no cell aims a sweep at them. A dead registration folder in an unmarked folder of the cell
/// stays, and in one whose mark is a symlink; the control: the same in the marked folder goes.
#[cfg(target_os = "macos")]
#[test]
fn a_debug_sweep_reaps_only_a_folder_its_cell_marked() {
    let d = scratch("reapmark");
    let s = state(&d);
    let dead = format!("v1 999998 {NEVER} 0\n");
    let unmarked = d.join("u");
    std::fs::create_dir(&unmarked).unwrap();
    mode(&unmarked, 0o700);
    let in_unmarked = regdir(&unmarked, "sr-Unmk0001", Some(&dead), &[]);
    let linked = d.join("l");
    std::fs::create_dir(&linked).unwrap();
    mode(&linked, 0o700);
    std::fs::write(d.join("elsewhere"), b"").unwrap();
    std::os::unix::fs::symlink(d.join("elsewhere"), linked.join(MARK)).unwrap();
    let in_linked = regdir(&linked, "sr-Link0002", Some(&dead), &[]);
    let tmp = reap_tmp(&d);
    let ctl = regdir(&tmp, "sr-Ctl00002", Some(&dead), &[]);
    let whole = |p: &Path| p.join("s").exists() && p.join("owner").exists();
    let mut rows = Vec::new();
    for t in [&unmarked, &linked] {
        let ts = t.display().to_string();
        let (code, said) = sweep_said_with(&s, &[], &[("TMPDIR", ts.as_str()), ("SHEEPR_TEST_REAP_LISTENERS", "1")]);
        rows.push((ts, code, said));
    }
    let tmp_s = tmp.display().to_string();
    // the refusal is applied to the base: a marked folder the seam refuses as it would /tmp keeps
    // its dead folder (the same folder, without the seam, is the control below)
    let (code_r, said_r) = sweep_said_with(&s, &[], &[("TMPDIR", tmp_s.as_str()), ("SHEEPR_TEST_REAP_LISTENERS", "1"), ("SHEEPR_TEST_REFUSE_AS_TMP", tmp_s.as_str())]);
    let kept_refused = whole(&ctl);
    let (code, said) = sweep_said_with(&s, &[], &[("TMPDIR", tmp_s.as_str()), ("SHEEPR_TEST_REAP_LISTENERS", "1")]);
    assert_eq!(code_r, Some(0), "{said_r}");
    assert!(kept_refused && !said_r.contains("registration folder"), "a folder refused as /tmp is, marked, was reaped: {said_r}");
    for (t, c, said) in &rows {
        assert_eq!(*c, Some(0), "TMPDIR {t}: {said}");
        assert!(!said.contains("registration folder"), "TMPDIR {t} (not marked as the cell's): {said}");
    }
    assert!(whole(&in_unmarked), "a debug sweep reaped a folder not marked as the cell's");
    assert!(whole(&in_linked), "a debug sweep took a symlink for the mark");
    assert_eq!(code, Some(0), "{said}");
    assert!(!ctl.exists() && said.contains("removed 1 registration folder"), "control: the marked folder's dead folder is removed: {said}");
    let _ = std::fs::remove_dir_all(&d);
}

// Issue #15, step 2: `sweep --strict` exits 3 when a cause it cannot clear by itself remains. Each
// counted cause is one stderr line that names the file and what clears it; each row applies that
// action, and the next strict sweep exits 0. What a sweep leaves on purpose is never counted.

/// A file in the journal folder that holds no job (opened, locked, read whole: no header line) is
/// counted: `sweep --strict` exits 3, and its one line says to remove it; without `--strict` the
/// same line, exit 0 (nothing changes). Removed, the next strict sweep exits 0 and says nothing.
#[test]
fn strict_counts_a_file_that_holds_no_job_until_it_is_removed() {
    let d = scratch("nojob");
    let (here, _, _) = folder(&d);
    let s = state(&d);
    let bad = plant(&s, &here, "j-b4d.journal", "not a journal\n");
    let (code, err) = strict(&s, &[]);
    assert_eq!(code, Some(3), "{err}");
    let l = naming(&err, "j-b4d.journal");
    assert!(l.len() == 1 && l[0].contains("it holds no job; remove it"), "{err}");
    let (code, err) = sweep_said(&s, &[]);
    assert_eq!(code, Some(0), "without --strict: {err}");
    assert_eq!(naming(&err, "j-b4d.journal").len(), 1, "without --strict, the same line: {err}");
    std::fs::remove_file(&bad).unwrap();
    let (code, err) = strict(&s, &[]);
    assert_eq!((code, err.as_str()), (Some(0), ""), "removed");
    let _ = std::fs::remove_dir_all(&d);
}

/// N5, N6: what is not a regular file is not a journal: a FIFO, a folder, a symlink (to a valid
/// journal elsewhere: never followed), a Unix socket (its open fails: EOPNOTSUPP on macOS, ENXIO
/// on Linux; review of slice 4, P3-2), each named `*.journal` in this boot's folder. `sweep
/// --strict` returns at once (before, a FIFO hung it: its open waited for a writer), exits 3, and
/// its one line says to remove it. Removed, the next strict sweep exits 0.
#[test]
fn strict_counts_what_is_not_a_journal_until_it_is_removed() {
    let d = scratch("notj");
    let (here, boot, pidns) = folder(&d);
    for kind in ["fifo", "folder", "symlink", "socket"] {
        let s = state(&d.join(kind));
        let dir = s.join("jobs").join(&here);
        std::fs::create_dir_all(&dir).unwrap();
        mode(&s.join("jobs"), 0o700);
        mode(&dir, 0o700);
        let p = dir.join("j-n0tj.journal");
        match kind {
            "fifo" => mkfifo(&p),
            "folder" => {
                std::fs::create_dir(&p).unwrap();
                mode(&p, 0o700);
            }
            "socket" => {
                // bound at a short path (a socket path has at most 104 bytes), then moved in
                let short = std::env::temp_dir().join(format!("sk{}", std::process::id()));
                let _ = std::fs::remove_file(&short);
                drop(std::os::unix::net::UnixListener::bind(&short).unwrap());
                std::fs::rename(&short, &p).unwrap();
            }
            _ => {
                let real = forge(&state(&d.join("elsewhere")), &here, "j-n0tj", "default", &boot, &pidns, &[], false);
                std::os::unix::fs::symlink(&real, &p).unwrap();
            }
        }
        let (code, err) = strict(&s, &[]);
        assert!(code.is_some(), "{kind}: the sweep did not return in 10 s");
        assert_eq!(code, Some(3), "{kind}: {err}");
        let l = naming(&err, "j-n0tj.journal");
        assert!(l.len() == 1 && l[0].contains("not a journal; remove it"), "{kind}: {err}");
        if kind == "folder" {
            std::fs::remove_dir(&p).unwrap();
        } else {
            std::fs::remove_file(&p).unwrap();
        }
        let (code, err) = strict(&s, &[]);
        assert_eq!((code, err.as_str()), (Some(0), ""), "{kind}: removed");
    }
    let _ = std::fs::remove_dir_all(&d);
}

/// N5: a journal sweep may not open (EPERM from the seam, as any user; EACCES from a real mode
/// 000, not as root) is counted with "check its mode", never "remove": the journal and its
/// member are left. The action (its mode put right; for the seam, the seam left out): the next
/// strict sweep exits 0 and sweeps the job.
#[test]
fn strict_counts_a_journal_it_may_not_open_until_its_mode_is_fixed() {
    let d = scratch("mode");
    let (here, boot, pidns) = folder(&d);
    for (name, real) in [("EPERM", false), ("EACCES", true)] {
        if real && unsafe { libc::geteuid() } == 0 {
            eprintln!("skipped {name}: root opens a file of any mode");
            continue;
        }
        let s = state(&d.join(name));
        let (mut c, p, _r) = decoy(&d, &format!("decoy-{name}"));
        let j = forge(&s, &here, "j-m0de", "default", &boot, &pidns, &[p], false);
        let _restore = Modes(vec![j.clone()]);
        if real {
            mode(&j, 0o000);
        }
        let env: Vec<(&str, &str)> = if real { vec![] } else { vec![("SHEEPR_TEST_JOURNAL_ERRNO", "open:EPERM:j-m0de.journal")] };
        let (code, err) = strict(&s, &env);
        let alive = common::alive(p);
        assert_eq!(code, Some(3), "{name}: {err}");
        let l = naming(&err, "j-m0de.journal");
        assert!(l.len() == 1 && l[0].contains(&format!("({name}); check its mode")), "{name}: {err}");
        assert!(!err.contains("remove"), "{name}: {err}");
        assert!(j.exists() && alive, "{name}: the journal and its member are left");
        if real {
            mode(&j, 0o600);
        }
        let (code, err) = strict(&s, &[]);
        let gone = wait_until(5, || !common::alive(p));
        end_decoy(&mut c);
        assert_eq!((code, err.contains(".journal")), (Some(0), false), "{name}: after the action: {err}");
        assert!(gone && !j.exists(), "{name}: the action applied, the job is swept");
    }
    let _ = std::fs::remove_dir_all(&d);
}

/// N5, round 2's P2-1: an error that a retry may clear (EMFILE, ENFILE, ENOMEM at the open;
/// ENOLCK at the lock, as on a network mount; EIO at the read, from the seam) is counted with "try
/// again", never "remove": it may be a live job's journal, and the open, lock and lock rows are on
/// one, which is left in place. Tried again (the seam left out), the strict sweep exits 0: the
/// live job is not counted, and the dead job of the read row is swept.
#[test]
fn strict_counts_an_error_a_retry_may_clear_and_never_says_remove() {
    let d = scratch("retry");
    let (here, boot, pidns) = folder(&d);
    let s = state(&d);
    let go = d.join("go");
    let script = format!(r#"while [ ! -e "{}" ]; do sleep 0.05; done"#, go.display());
    let mut live = Command::new(sheepr()).args(["run", "--no-sweep", "--", "/bin/sh", "-c", &script]).env("SHEEPR_TEST_STATE", &s).env("SHEEPR_TEST_JOB_ID", "11ve0000").spawn().unwrap();
    let _go = GoOnDrop(go.clone());
    let lj = s.join("jobs").join(&here).join("j-11ve0000.journal");
    assert!(wait_until(15, || lj.exists()), "the live job's journal");
    for (stage, errno) in [("open", "EMFILE"), ("open", "ENFILE"), ("open", "ENOMEM"), ("lock", "ENOLCK")] {
        let seam = format!("{stage}:{errno}:j-11ve0000.journal");
        let (code, err) = strict(&s, &[("SHEEPR_TEST_JOURNAL_ERRNO", &seam)]);
        assert_eq!(code, Some(3), "{seam}: {err}");
        let l = naming(&err, "j-11ve0000.journal");
        assert!(l.len() == 1 && l[0].contains(&format!("({errno}); try again")), "{seam}: {err}");
        assert!(!err.contains("remove"), "{seam}: {err}");
        assert!(lj.exists(), "{seam}: the live job's journal is left");
        let (code, err) = strict(&s, &[]);
        assert_eq!((code, err.as_str()), (Some(0), ""), "{seam}: tried again");
    }
    // the read comes after the lock, which a live job holds: a dead job's journal
    let (mut c, p, _r) = decoy(&d, "decoy");
    let dj = forge(&s, &here, "j-dead0000", "default", &boot, &pidns, &[p], false);
    let (code, err) = strict(&s, &[("SHEEPR_TEST_JOURNAL_ERRNO", "read:EIO:j-dead0000.journal")]);
    let alive = common::alive(p);
    let (code2, err2) = strict(&s, &[]);
    let gone = wait_until(5, || !common::alive(p));
    end_decoy(&mut c);
    std::fs::write(&go, b"").unwrap();
    let _ = live.wait();
    assert_eq!(code, Some(3), "read: {err}");
    let l = naming(&err, "j-dead0000.journal");
    assert!(l.len() == 1 && l[0].contains("(EIO); try again"), "read: {err}");
    assert!(!err.contains("remove") && alive, "read: {err}");
    assert_eq!((code2, err2.contains(".journal")), (Some(0), false), "read, tried again: {err2}");
    assert!(gone && !dj.exists(), "read, tried again: the dead job is swept");
    let _ = std::fs::remove_dir_all(&d);
}

/// N4: a journal that vanishes between the listing and the open, or after the lock (the name no
/// longer the file the lock is on), is a job that just ended: no line, not counted. The seam
/// unlinks a file that holds no job at that point; the control, the same file left in place, is
/// counted.
#[test]
fn strict_does_not_count_a_journal_that_vanished() {
    let d = scratch("vanish");
    let (here, _, _) = folder(&d);
    for stage in ["open", "lock"] {
        let s = state(&d.join(stage));
        let f = plant(&s, &here, "j-g0ne0000.journal", "not a journal\n");
        let (code, err) = strict(&s, &[]);
        assert_eq!(code, Some(3), "{stage}: control: {err}");
        let seam = format!("{stage}:j-g0ne0000.journal");
        let (code, err) = strict(&s, &[("SHEEPR_TEST_JOURNAL_VANISH", &seam)]);
        assert!(!f.exists(), "{stage}: the seam did not unlink it (the row proves nothing)");
        assert_eq!((code, naming(&err, "j-g0ne0000").len()), (Some(0), 0), "{stage}: {err}");
    }
    let _ = std::fs::remove_dir_all(&d);
}

/// What a sweep leaves on purpose is never counted (exit 0 under `--strict`), each alone in a
/// state of its own: another owner's journal, also of another boot and also one whose lock fails
/// (its header is read first, whatever else is wrong with it), with no line; a header of another
/// boot or pid namespace in this folder (with its line, as before); a journal kept on purpose
/// (`--leave-strays`); a job swept clean; nothing to sweep. Each row's control: a file that holds
/// no job added to the same state gives 3, so the row's sweep did read that state.
#[test]
fn strict_does_not_count_what_a_sweep_leaves_on_purpose() {
    let d = scratch("onpurpose");
    let (here, boot, pidns) = folder(&d);
    let zero = "00000000-0000-0000-0000-000000000000";
    let (bt, pn) = (boot.as_str(), pidns.as_str());
    // (row, owner, boot, pidns, leave-strays, the sweep's arguments, the seam, lines naming it)
    let rows: Vec<(&str, &str, &str, &str, bool, Vec<&str>, Option<&str>, usize)> = vec![
        ("another owner, another boot", "liveapp", zero, pn, false, vec![], None, 0),
        ("another owner, a lock error", "liveapp", bt, pn, false, vec![], Some("lock:ENOLCK:j-0badf00d.journal"), 0),
        ("its owner's sweep: another boot", "liveapp", zero, pn, false, vec!["--owner", "liveapp"], None, 1),
        ("another boot", "default", zero, pn, false, vec![], None, 1),
        ("another pid namespace", "default", bt, "12345.678", false, vec![], None, 1),
        ("kept on purpose", "default", bt, pn, true, vec![], None, 0),
        ("swept clean", "default", bt, pn, false, vec![], None, 0),
    ];
    for (i, (row, owner, hb, hp, strays, args, seam, lines)) in rows.into_iter().enumerate() {
        let s = state(&d.join(format!("r{i}")));
        let j = forge(&s, &here, "j-0badf00d", owner, hb, hp, &[], strays);
        let mut all = vec!["sweep", "--strict"];
        all.extend(args.iter().copied());
        let env: Vec<(&str, &str)> = seam.map(|v| vec![("SHEEPR_TEST_JOURNAL_ERRNO", v)]).unwrap_or_default();
        let (code, err, _) = sheepr_within(&s, &all, &env, 10);
        assert_eq!(code, Some(0), "{row}: {err}");
        assert_eq!(naming(&err, "j-0badf00d.journal").len(), lines, "{row}: {err}");
        assert!(!err.contains("remove") && !err.contains("try again"), "{row}: {err}");
        assert_eq!(j.exists(), row != "swept clean", "{row}: the journal");
        plant(&s, &here, "j-b4d.journal", "not a journal\n");
        let (code, err, _) = sheepr_within(&s, &all, &env, 10);
        assert_eq!(code, Some(3), "{row}: control: {err}");
    }
    let fresh = state(&d.join("fresh"));
    let (code, err) = strict(&fresh, &[]);
    assert_eq!((code, err.as_str()), (Some(0), ""), "nothing to sweep");
    let _ = std::fs::remove_dir_all(&d);
}

/// A job whose sweep is skipped because it holds the sweeper's own ancestor is counted: run from
/// inside a dead job (its member W runs `sheepr sweep --strict`), the strict sweep exits 3 and its
/// line says the job clears when that process ends. The action (W ends): the next strict sweep
/// exits 0 and ends the job's other members. (W then execs the fixture: the wall reads no
/// environment of a platform binary such as `/bin/sleep`, so a debug sweep could not end one.)
#[test]
fn strict_counts_a_job_that_holds_its_ancestor_until_that_process_ends() {
    let d = scratch("strictanc");
    let s = state(&d);
    let (go, rc, me, said, wr) = (d.join("go"), d.join("rc"), d.join("me"), d.join("said"), d.join("w"));
    let w = format!(r#"echo $$ > "{}"; while [ ! -e "{}" ]; do sleep 0.02; done; sheepr sweep --strict 2> "{}"; echo $? > "{}"; exec "$FX" sigcount "{}""#, me.display(), go.display(), said.display(), rc.display(), wr.display());
    let (wit, rr) = (d.join("witness"), d.join("root"));
    let script = format!(r#"/bin/sh -c '{}' & "$FX" sigcount "{}" & exec "$FX" sigcount "{}""#, w.replace('\'', r#"'\''"#), wit.display(), rr.display());
    let mut c = Command::new(sheepr()).args(["run", "--", "/bin/sh", "-c", &script]).env("FX", fixture()).env("SHEEPR_TEST_STATE", &s).spawn().unwrap();
    let wpid: Option<i32> = wait_until(15, || std::fs::read_to_string(&me).is_ok_and(|t| !t.trim().is_empty())).then(|| std::fs::read_to_string(&me).unwrap().trim().parse().unwrap());
    let wid = wpid.and_then(sheepr::ident::identity);
    let journaled_w = wpid.is_some_and(|p| wait_until(10, || journaled(&s).contains(&p)));
    let witness = wait_until(10, || !records(&wit).is_empty()).then(|| records(&wit)[0]);
    let journaled_wit = witness.is_some_and(|p| wait_until(10, || journaled(&s).contains(&p.0)));
    common::send_child(&mut c, libc::SIGKILL);
    let _ = c.wait();
    std::fs::write(&go, b"").unwrap();
    let finished = wait_until(20, || std::fs::read_to_string(&rc).is_ok_and(|t| t.ends_with('\n')));
    let code: Option<i32> = std::fs::read_to_string(&rc).ok().and_then(|t| t.trim().parse().ok());
    let err = std::fs::read_to_string(&said).unwrap_or_default();
    let wit_alive = witness.is_some_and(common::alive);
    // the action: that process (W) ends
    if let Some(p) = wpid.zip(wid) {
        common::send(p.0, p.1, libc::SIGKILL);
    }
    let w_gone = wpid.zip(wid).is_some_and(|p| wait_until(5, || !common::alive(p)));
    let (code2, err2) = strict(&s, &[]);
    let wit_gone = witness.is_some_and(|p| wait_until(5, || !common::alive(p)));
    for p in records(&rr).into_iter().chain(witness) {
        common::send(p.0, p.1, libc::SIGKILL);
    }
    assert!(journaled_w && journaled_wit, "W and the witness were journaled as members");
    assert!(finished, "the inner sweep did not end");
    assert_eq!(code, Some(3), "{err}");
    assert!(err.lines().any(|l| l.contains("skipped job j-") && l.contains("it clears when that process ends")), "{err}");
    assert!(wit_alive, "the job that holds the sweep's ancestor was swept");
    assert!(w_gone, "W did not end");
    assert_eq!(code2, Some(0), "after the action: {err2}");
    assert!(wit_gone && journals(&s).is_empty(), "after the action, the job is swept: {err2}");
    let _ = std::fs::remove_dir_all(&d);
}

/// No boot id (a seam gives its errno): with ENOENT, nothing to sweep when no `jobs/` folder holds
/// a journal (0, silent: a fresh state, an empty folder); when one does (an old boot's, here), it
/// is counted: 3, one line that names the cause and says to try again, and the folder is left.
/// Another errno is counted with nothing in `jobs/` too. Without `--strict`: the line, exit 0.
/// The action (tried again, the boot id read): 0.
#[test]
fn strict_without_a_boot_id_counts_only_when_a_journal_may_be_missed() {
    let d = scratch("nobootid");
    let seam = |e: &'static str| [("SHEEPR_TEST_BOOT_ID_ERRNO", e)];
    let fresh = state(&d.join("fresh"));
    let empty = state(&d.join("empty"));
    let zero = "00000000-0000-0000-0000-000000000000-0";
    std::fs::create_dir_all(empty.join("jobs").join(zero)).unwrap();
    mode(&empty.join("jobs"), 0o700);
    mode(&empty.join("jobs").join(zero), 0o700);
    for (n, s) in [("fresh", &fresh), ("empty", &empty)] {
        let (code, err) = strict(s, &seam("ENOENT"));
        assert_eq!((code, err.as_str()), (Some(0), ""), "{n}");
    }
    let old = state(&d.join("old"));
    let oj = plant(&old, zero, "j-0ldb00t0.journal", "not read\n");
    let (code, err) = strict(&old, &seam("ENOENT"));
    let line = "cannot read the boot id (ENOENT); nothing was swept; try again";
    assert_eq!(code, Some(3), "{err}");
    assert_eq!(err.lines().filter(|l| l.contains(line)).count(), 1, "{err}");
    assert!(oj.exists(), "the old boot's folder is left");
    let (code, err) = sweep_said_with(&old, &[], &seam("ENOENT"));
    assert_eq!((code, err.lines().filter(|l| l.contains(line)).count()), (Some(0), 1), "without --strict: {err}");
    let (code, err) = strict(&fresh, &seam("EACCES"));
    assert_eq!(code, Some(3), "EACCES: {err}");
    assert!(err.contains("cannot read the boot id (EACCES); nothing was swept; try again"), "EACCES: {err}");
    for (n, s) in [("old", &old), ("fresh", &fresh)] {
        let (code, err) = strict(s, &[]);
        assert_eq!((code, err.as_str()), (Some(0), ""), "{n}: tried again");
    }
    let _ = std::fs::remove_dir_all(&d);
}

/// A missed kill deadline (125) wins over a counted cause (3): a dead job whose member a seam
/// makes unkillable, with a file that holds no job beside it. The control, the same state
/// without the seam: the job is swept and the file still counts, 3.
#[test]
fn a_missed_deadline_wins_over_strict() {
    let d = scratch("deadline3");
    let (here, boot, pidns) = folder(&d);
    let s = state(&d);
    let (mut c, p, _r) = decoy(&d, "decoy");
    forge(&s, &here, "j-0badf00d", "default", &boot, &pidns, &[p], false);
    plant(&s, &here, "j-b4d.journal", "not a journal\n");
    let unkillable = p.0.to_string();
    let (code, err) = strict(&s, &[("SHEEPR_TEST_UNKILLABLE", &unkillable), ("SHEEPR_TEST_DEADLINE_MS", "500")]);
    let (code2, err2) = strict(&s, &[]);
    let gone = wait_until(5, || !common::alive(p));
    end_decoy(&mut c);
    assert_eq!(code, Some(125), "{err}");
    assert_eq!(naming(&err, "j-b4d.journal").len(), 1, "the counted cause is still said: {err}");
    assert_eq!(code2, Some(3), "control: {err2}");
    assert!(gone, "control: the job was swept");
    let _ = std::fs::remove_dir_all(&d);
}

/// N6, the class: no reader of the journal folder hangs on a FIFO named `*.journal` (before, each
/// open waited for a writer): `strays`, `doctor`, `kill` of a job id that names it, and `kill` of
/// a pid (it reads every journal for the pid's journaled subtree) each return within 10 s. The
/// pid is a decoy, so `kill <pid>` ends it (exit 0).
#[test]
fn a_fifo_named_like_a_journal_hangs_no_reader() {
    let d = scratch("fifo");
    let (here, _, _) = folder(&d);
    let s = state(&d);
    let dir = s.join("jobs").join(&here);
    std::fs::create_dir_all(&dir).unwrap();
    mode(&s.join("jobs"), 0o700);
    mode(&dir, 0o700);
    mkfifo(&dir.join("j-f1f0f1f0.journal"));
    let (mut c, p, _r) = decoy(&d, "decoy");
    let pid = p.0.to_string();
    let mut got = Vec::new();
    for args in [vec!["strays"], vec!["doctor"], vec!["kill", "j-f1f0"], vec!["kill", pid.as_str()]] {
        let (code, err, took) = sheepr_within(&s, &args, &[("SHEEPR_TEST_DEADLINE_MS", "2000")], 10);
        got.push((args.join(" "), code, took, err));
    }
    let gone = wait_until(5, || !common::alive(p));
    end_decoy(&mut c);
    for (what, code, took, err) in &got {
        assert!(code.is_some(), "{what} did not return in 10 s ({took:?}): {err}");
    }
    assert_eq!(got[2].1, Some(1), "kill of the FIFO's job id refuses: {}", got[2].3);
    assert_eq!(got[3].1, Some(0), "kill of the decoy: {}", got[3].3);
    assert!(gone, "kill of the decoy ended it");
    let _ = std::fs::remove_dir_all(&d);
}

/// N7: `kill` of a dead job's id still takes a lock error (a seam: ENOLCK, as on a network mount)
/// for a live job's: it refuses as busy (exit 1) and signals nothing. The control, without the
/// seam: the job is swept, exit 0.
#[test]
fn kill_job_takes_a_lock_error_for_a_live_job() {
    let d = scratch("killlock");
    let (here, boot, pidns) = folder(&d);
    let s = state(&d);
    let (mut c, p, r) = decoy(&d, "decoy");
    let j = forge(&s, &here, "j-0badf00d", "default", &boot, &pidns, &[p], false);
    let env = [("SHEEPR_TEST_JOURNAL_ERRNO", "lock:ENOLCK:j-0badf00d.journal"), ("SHEEPR_TEST_DEADLINE_MS", "2000")];
    let (code, err, _) = sheepr_within(&s, &["kill", "j-0badf00d"], &env, 10);
    let (alive, n) = (common::alive(p), counted(&r));
    let (code2, err2, _) = sheepr_within(&s, &["kill", "j-0badf00d"], &env[1..], 10);
    let gone = wait_until(5, || !common::alive(p));
    end_decoy(&mut c);
    assert_eq!(code, Some(1), "{err}");
    assert!(err.contains("busy"), "{err}");
    assert!(alive && n == 0, "the job's member got {n} signal(s)");
    assert_eq!(code2, Some(0), "control: {err2}");
    assert!(gone && !j.exists(), "control: the job is swept");
    let _ = std::fs::remove_dir_all(&d);
}

/// Review of slice 4, P4: after the lock, the name is checked against the locked file: only a name
/// that is gone (ENOENT) or names another file is a job that just ended. Any other error of that
/// stat (seam: EIO) is counted by `sweep --strict` ("could not stat it (EIO); try again", the job
/// and its journal left), and `kill` of the job still takes it for a live job's (busy, exit 1,
/// nothing signalled). Tried again without the seam, the strict sweep sweeps the job (0).
#[test]
fn a_stat_error_after_the_lock_is_counted_and_never_gone() {
    let d = scratch("staterr");
    let (here, boot, pidns) = folder(&d);
    let s = state(&d);
    let (mut c, p, r) = decoy(&d, "decoy");
    let j = forge(&s, &here, "j-57a70000", "default", &boot, &pidns, &[p], false);
    let seam = [("SHEEPR_TEST_JOURNAL_ERRNO", "stat:EIO:j-57a70000.journal")];
    let (code, err) = strict(&s, &seam);
    let (kcode, kerr, _) = sheepr_within(&s, &["kill", "j-57a70000"], &seam, 30);
    let (alive, n) = (common::alive(p), counted(&r));
    let kept = j.exists();
    let (code2, err2) = strict(&s, &[]);
    let gone = wait_until(5, || !common::alive(p));
    end_decoy(&mut c);
    assert_eq!(code, Some(3), "{err}");
    let l = naming(&err, "j-57a70000.journal");
    assert!(l.len() == 1 && l[0].contains("could not stat it (EIO); try again"), "{err}");
    assert!(!err.contains("remove"), "{err}");
    assert_eq!(kcode, Some(1), "kill: {kerr}");
    assert!(kerr.contains("busy"), "kill: {kerr}");
    assert!(alive && n == 0 && kept, "the job was touched: alive {alive}, {n} signal(s), journal kept {kept}");
    assert_eq!(code2, Some(0), "tried again: {err2}");
    assert!(gone && !j.exists(), "tried again: the job is swept");
    let _ = std::fs::remove_dir_all(&d);
}

/// Review of slice 4, P4: the boot id is read once per sweep, so every journal is judged by the
/// same answer: with a seam that fails every read after the first (as EMFILE can, on Linux, while
/// a sweep holds journals open), this boot's dead job is still swept (exit 0, its decoy ends, no
/// "another boot" line). Before, each journal's open read it again and took this boot's journal
/// for another boot's.
#[test]
fn the_boot_id_is_read_once_per_sweep() {
    let d = scratch("bootonce");
    let (here, boot, pidns) = folder(&d);
    let s = state(&d);
    let (mut c, p, _r) = decoy(&d, "decoy");
    let j = forge(&s, &here, "j-b0071d00", "default", &boot, &pidns, &[p], false);
    let (code, err) = strict(&s, &[("SHEEPR_TEST_BOOT_ID_FAIL_AFTER", "1:EMFILE")]);
    let gone = wait_until(5, || !common::alive(p));
    end_decoy(&mut c);
    assert_eq!(code, Some(0), "{err}");
    assert!(gone && !j.exists(), "this boot's dead job was not swept: {err}");
    assert!(!err.contains("another boot"), "{err}");
    let _ = std::fs::remove_dir_all(&d);
}
