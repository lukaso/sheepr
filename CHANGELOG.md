# Changelog

Every release has an entry here. sheepr follows semver; the stable interfaces are the subcommands
and the flags `sheepr help <command>` shows, the exit codes, the `--status-fd` and `--json`
schemas (`"v": 1`, additive changes only) and the `sheepr:` at the start of the first line of
each message sheepr itself writes to stderr (for a usage error, that line says what was wrong;
`sheepr` alone prints the overview and exits 2).

## Unreleased

- `run --status-fd`: two new fields, `root_code` (the command's exit code when it exited) and
  `root_signal` (the number of the signal that ended it), each null otherwise. Both are null when
  the command never ran, and when sheepr did not see how it ended. When `trigger` is set (`term`,
  `timeout`, `cap`), they say how the command ended while the job was being ended: by itself (it
  exited just as the TERM came, or while it had time to end), by the caller's signal (a TERM to
  the whole process group reaches the command too), or by sheepr's kill. They are not the
  command's own result for the job ([#17](https://github.com/lukaso/sheepr/issues/17)).
- `run --status-fd`: `root` now follows how the command really ended. Values that change:
  - a command that exits by itself as sheepr takes a TERM, or while sheepr ends the job (after a
    TERM from outside or a limit, during the grace), is `"exited"`, not `"signaled"`;
  - on Linux, a command that cannot be run (not found, not executable) is `"not-started"` also
    when a TERM reaches sheepr at the same moment, or when it fails while the job is being ended;
    before, that was `"signaled"`. In both cases `error` now says `cannot run …`; before, it was
    null;
  - with `--mode root-disclaim` (macOS, not a stable flag), a job ended by a TERM from outside
    is `"signaled"` with both new fields null, not `"not-started"`;
  - on macOS, when sheepr has seen the command end but its wait for it fails, `root` is
    `"signaled"` with both new fields null, `trigger` null, and `error` says the exit status was
    lost; before, `root` was `"exited"`, as if the command had exited 125. The exit code of that
    case stays 125. A check on a command that is still running that fails (for example while a
    debugger is attached to it) never ends the job, as before.

- `run --status-fd`: two new fields, `error_code` (the errno behind `error`, by name, such as
  `ENOENT` or `EAGAIN`) and `error_source` (`command`, `resources`, `sheepr` or `usage`: whose
  failure it is; `resources` means a retry, or freeing processes, memory, files or disk space,
  may help) ([#21](https://github.com/lukaso/sheepr/issues/21),
  [#23](https://github.com/lukaso/sheepr/issues/23)).
- `run --status-fd`: a run that ends before its command runs now always says why. Values that
  change:
  - `trigger` (and `trigger_at`) is `"term"`, not null, when a TERM ends the run before the
    command: a TERM already pending when sheepr starts, one before its relay starts, one before
    the command is let go (Linux), and on macOS a relay that is gone before the command starts
    and `--mode root-disclaim`;
  - `error` names the failure, not null, when sheepr cannot start the command: an unknown mode,
    a failed fork, and on Linux no usable /proc, its own executable not found, no pipe, the
    command's starter not started, or not answering (its end, or "no answer in 5000 ms");
  - after an internal error (a panic), `error` is `internal error (a panic)`, not null; `root`
    is `"not-started"` only when the command cannot have run yet: on Linux before the command
    is let go (it was `"signaled"` there), on macOS before the command is started;
  - when two errors happen in one run, `error` is the first one (before: the last), and the
    others are in `notes` as `also: …`; an internal error is never only a note;
  - on macOS, a command that sheepr ends while it is still suspended (a TERM, or its relay's
    end, just before sheepr would resume it) is `"signaled"`, not `"not-started"`: any CONT
    (a `timeout` that sends TERM and CONT, a plain `kill -CONT`) may have run it.
- `run --require-journal`: the command runs only once sheepr has written it into its job journal
  (the record `sheepr sweep` uses to end a job whose sheepr was killed). When the journal cannot
  be kept, the command does not run: exit 125, root `"not-started"`, and `error` says why (with
  `error_code`, and `error_source` `resources` for a full disk). When the journal fails while the
  job runs, sheepr ends the job: exit 125 and `trigger` `"journal"`, a value only this option
  gives. It cannot be used with `--mode root-disclaim`, and on macOS it refuses a caller that
  blocks SIGCONT. Without the option nothing changes
  ([#16](https://github.com/lukaso/sheepr/issues/16)).
- `run` (Linux): when the command's starter fails, stderr and `error` say how: it ended before
  it answered (its exit code or signal), it gave no answer in time, or which of its own steps
  failed, with the errno.

## 0.1.3 (2026-10-10)

- `sweep` and the auto-sweep before each `run` (macOS): they remove the registration folders
  (`$TMPDIR/sr-XXXXXXXX`, or under `/tmp`) that a sheepr killed with SIGKILL leaves behind. Each
  folder now records which sheepr owns it, and only the folder of a sheepr that is gone is
  removed; `sweep` says how many. A folder from an older sheepr is removed when it is more than a
  day old and nothing listens on it. A sweep looks only where its own sheepr would make that
  folder (`$TMPDIR`, or `/tmp` when that path is too long or `TMPDIR` is unset)
  ([#20](https://github.com/lukaso/sheepr/issues/20)).

## 0.1.2 (2026-10-09)

0.1.1 was never published: its changes (the first two items) are in this release.

- `run --status-fd`: a reader that stops reading can no longer keep sheepr running after the job
  is killed. sheepr gives up when the fd accepts nothing for 10 s, and at about 30 s in all; then
  it says on stderr that the line did not arrive (also with `--quiet`) and exits with its usual
  code. The line now goes out in several writes, so a reader of a regular file must wait for its
  newline or for sheepr's exit. A closed reader gives that line too, also on a usage error, where it could kill sheepr
  with SIGPIPE before (unless the status fd is stderr itself, as with `3>&2`: then the usage
  message meets the closed reader first, and SIGPIPE still ends sheepr). A status fd the caller made non-blocking now waits for its reader too;
  before, the line was cut at the first full buffer ([#14](https://github.com/lukaso/sheepr/issues/14)).
- `sweep`: a journal it skips because it cannot read it, or will not act on it for safety, is said
  on stderr, one line that names the file, and the exit code does not change; the auto-sweep
  before each `run` puts the same skip in the `--status-fd` notes. Before, `sweep` wrote it only
  to a debug build's test trace, never to stderr, and the auto-sweep said nothing at all. A job kept with `--leave-strays` is
  still skipped without a word. Only a journal folder that is not there means "nothing to
  sweep": one sheepr cannot reach or list (no permission, not a directory) is no longer taken as
  empty, so `sweep` refuses it (exit 1, as an unsafe folder) and the auto-sweep notes it
  ([#15](https://github.com/lukaso/sheepr/issues/15)).
- `sweep` (macOS): a job whose sheepr was killed with SIGKILL just after it started the job's first
  process, before it wrote that process into the journal, left the process stopped for ever, and
  `sweep` said "0 processes ended" and removed the journal. `sweep`, the auto-sweep, `kill j-JOBID`,
  and `ps` or `kill --dry-run` of such a job now find that process through the sheepr that started
  it, as the journal's header names it ([#19](https://github.com/lukaso/sheepr/issues/19)).
- `sweep`, `kill` and `ps` (macOS): a line of an edited or damaged journal that names launchd,
  another user's process, or a live process at another pid than its own no longer brings that
  process's children in.
- `sweep`, `kill` and `ps` (macOS): a process of the job that became another user's (it ran `sudo`
  or `su`) and is still alive no longer leads them to its children that sheepr had not recorded
  yet (started just before sheepr died, or after); 0.1.0 ended those. Its children that the
  journal names are still ended.
- `sweep`, the auto-sweep and `kill j-JOBID` (macOS): run from inside a process that a dead job
  started (its original parent was the job's sheepr or one of the job's processes, for example a
  terminal opened from the job), they leave that job alone and keep its journal, as they already
  did for a job that holds their own process: `sweep` says it skipped the job, and `kill j-JOBID`
  refuses with exit 1. Before, they ended the job's other processes and removed the journal.
- `kill --dry-run j-JOBID` and `ps j-JOBID`: for a dead job that `kill j-JOBID` would refuse to
  sweep (its journal is busy or kept, sheepr cannot read its own chain of parent processes, or the
  job holds or started the caller's process), they now refuse with the same line and exit 1.
  Before, they listed what they could reach, or nothing, and exited 0.

## 0.1.0 (2026-10-06)

The first release.

- `sheepr run`: runs a command and, when it ends, a limit fires (`--timeout`, `--max-mem`,
  `--max-procs`) or sheepr gets TERM, kills every process it started, including processes that
  escaped with `setsid`, a double fork or reparenting. macOS (tracking by the kernel's responsible
  process) and Linux (a child subreaper), no root.
- `sheepr kill <pid>` / `kill <job>`, `ps`, `strays [--kill]`, `sweep`, `doctor`.
- A journal of every job, so `sweep` can end what a killed sheepr left behind.
- A usage error names what it rejected and the rule it broke; `run` without `--` runs nothing and
  prints the corrected command.
- macOS 12 or newer: `Sheepr.app`, Developer ID-signed and notarized; Homebrew cask, `install.sh`,
  npm and pnpm. A job does not inherit the terminal's privacy permissions (Full Disk Access,
  Documents and so on); give Sheepr Full Disk Access once, or run a job with
  `--inherit-terminal-permissions`.
- Linux: static binaries for `x86_64` and `aarch64`, and npm.
- Licensed under MIT OR Apache-2.0; every npm package carries both texts.
