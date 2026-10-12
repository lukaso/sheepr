# sheepr

Run a command, and make sure every process it starts is gone at the end: also the ones that
escaped with `setsid`, a double fork, or reparenting to PID 1 or launchd. It works on macOS, on
Linux, and in a default Docker container, with no root, no cgroups and no systemd.

## Install

**macOS** 12 or newer (installs `Sheepr.app`, signed and notarized, and a `sheepr` command
that runs it):

```sh
brew install --cask lukaso/tap/sheepr
```

The cask needs Homebrew 5.1.11 or newer (from May 2026; `brew --version` shows yours). If yours is
older, run `brew update` first.

Without Homebrew (into `~/Applications`, with the command in `~/.local/bin`; it tells you if that
is not on your PATH):

```sh
curl -fsSL https://github.com/lukaso/sheepr/releases/latest/download/install.sh | sh
```

With npm or pnpm (a global install; see [npm](#npm) below):

```sh
npm i -g sheepr
```

Tested on macOS 27 on Apple silicon. Intel Macs and macOS 12 to 26 are supported but not tested yet.

**Linux**, a static binary (`x86_64` and `aarch64`):

```sh
curl -fsSL https://github.com/lukaso/sheepr/releases/latest/download/install.sh | sh
```

**Docker**, pinned and checked:

```dockerfile
ARG SHEEPR_VERSION=0.1.3
RUN a=$(uname -m) \
 && case $a in x86_64) sum='<sha256 of sheepr-linux-x86_64>' ;; aarch64) sum='<sha256 of sheepr-linux-aarch64>' ;; *) exit 1 ;; esac \
 && curl -fsSL -o /usr/local/bin/sheepr "https://github.com/lukaso/sheepr/releases/download/v${SHEEPR_VERSION}/sheepr-linux-$a" \
 && echo "$sum  /usr/local/bin/sheepr" | sha256sum -c - \
 && chmod +x /usr/local/bin/sheepr
```

Put the two hashes from the release's `SHA256SUMS` in place of the placeholders. The image needs
`curl` (on Debian: `apt-get update && apt-get install -y curl ca-certificates`; on Alpine:
`apk add curl`).

On Linux the checksum proves the download is intact, not where it came from: `SHA256SUMS` comes
from the same release. On macOS, install.sh checks the Developer ID signature before it installs,
which does prove where it came from. Homebrew checks the archive against the sha256 in the tap;
macOS then checks the signature and notarization when you first run it.

## Use

- `sheepr run --timeout 5m -- npm test` stops the whole tree after 5 minutes.
- `sheepr run --max-mem 2G -- python3 job.py` stops it if the tree uses more than 2 GiB.
- `sheepr strays` lists leaked processes of yours, biggest first.
- `sheepr kill 4242` kills 4242 and the processes it provably started (see them first with
  `sheepr ps 4242`).

The command goes after `--`. Put a pipeline, `&&`, `cd` or `VAR=value` inside `sh -c`, for example
`sheepr run --timeout 5m -- sh -c 'cd app && npm test'`. Without it, your shell runs the part
after `&&` outside sheepr.

To stop a running job, send TERM to sheepr. Exit 124 means a limit fired. `sheepr help
<command>` shows a command's usage line.

## For coding agents

Put this in your `CLAUDE.md` or `AGENTS.md`:

```markdown
## Commands that may hang or leak processes
Wrap them: `sheepr run --timeout 5m -- <command>`. Put a pipeline, `&&`, `cd` or `VAR=value` inside `sh -c`, for example `sheepr run --timeout 5m -- sh -c 'cd app && npm test'`; otherwise part of it runs outside sheepr, or does not run. It kills the whole process tree when the command ends or a limit fires, including processes that escaped. Exit 124 means a limit fired; read the `sheepr:` lines on stderr. To stop a job, send TERM to sheepr (SIGINT to its pid does not reach the command). Leaked processes from earlier runs: `sheepr strays`. On macOS, if the project is in Documents, Desktop, Downloads or iCloud Drive, add `--inherit-terminal-permissions` (it tracks the tree less well) unless Sheepr has Full Disk Access.
```

## Limits

sheepr is not a sandbox. It does not reach:

- work started through another launcher: on macOS `open`, `osascript`, `xcodebuild test`, launchd
  agents; on Linux `systemd-run --user` and D-Bus activation;
- a process inside the job that disclaims itself again (Electron, VS Code and Chrome helpers), except
  on a best-effort basis;
- containers the job starts: they belong to `dockerd`;
- a process that leaves on purpose: `sudo`, another user, ptrace.

A caller that sends INT to sheepr's pid alone and then SIGKILLs it (for example Node's
`child.kill('SIGINT')` and then `child.kill('SIGKILL')`) kills sheepr (on Linux, the command it
started dies with it), not the rest of the tree. Such a caller should send TERM instead. Your next
`sheepr run` or `sheepr sweep` with the same `--owner` and the same state directory, before a
reboot (in a container: in the same container), ends most of what was left; a process sheepr
never saw can stay, and `sheepr strays` lists it. On macOS, any later `run` or `sweep` with the
same temp folder (`TMPDIR`) also removes the registration folder (`sr-…`) the killed sheepr left.
A `run` with `--no-sweep` skips both, and a `run` stops sweeping jobs after 200 ms (and folders
after 50 ms more), so when many were left, it can take more than one run. When a journal it
cannot read may belong to a running job (another user's file, one with no read permission), that
sweep ends nothing, and the run says so in one stderr line (not with `--quiet`); this repeats on
every run until the file is removed or fixed, and `sheepr sweep` says what to do. Its other stops
before any dead job is swept (a state folder it may not use, a folder it cannot list, a chain of
parent processes it cannot follow) are notes in the `--status-fd` line only.

On macOS a running job costs some CPU: sheepr checks your processes four times a second to find
the ones that escaped. Measured on a busy Mac (about 1000 of your processes, load average 16): about 1.5% of one CPU
core per running job. The cost grows with the number of processes and with the Mac's load.

Where a delegated cgroup v2 is available, a cgroup is stronger: processes cannot leave it. sheepr
is the portable floor, and on a Mac the only option.

## macOS privacy

A job under sheepr does not inherit your terminal's privacy permissions (Full Disk Access,
Documents, Desktop and so on): sheepr makes itself the job's responsible app, which is what lets
it track the whole tree. Protected folders include Documents, Desktop, Downloads and iCloud Drive, so
a project kept in one of them is protected too. If a job reads a protected folder, give Sheepr Full
Disk Access once:
System Settings > Privacy & Security > Full Disk Access, click +, press Cmd-Shift-G, paste the path
of `Sheepr.app` and press Return. It is in `~/Applications` for install.sh and for Homebrew with
`--appdir=~/Applications`, in `/Applications` for Homebrew otherwise, and inside the package for npm
and pnpm, where these commands print it:

- npm: `find "$(npm root -g)/sheepr" -name Sheepr.app -prune`
- pnpm: `find "$(pnpm root -g)/../.pnpm" -name Sheepr.app -prune`

In a standard (not admin) account the row may not appear in the list after you add it; the grant
still works. An upgrade with install.sh keeps the grant. After another kind of upgrade, run
`sheepr run --timeout 20s -- ls ~/Library/Safari`: only Full Disk Access lets it list that folder
(open Safari once first if the folder does not exist). If it is denied, add Sheepr again. If
sheepr says tracking falls back to parent ids, the result proves nothing: the job may then have
your terminal's permissions.
`sheepr doctor --grants` checks whether Sheepr can read `~/Documents` (this can show a macOS
privacy prompt; allowing Documents there is not Full Disk Access).

Or run one job with `--inherit-terminal-permissions`: it keeps your terminal's permissions, and
sheepr falls back to a weaker way of tracking the tree.

Uninstalling does not remove a grant. Remove it before you uninstall (afterwards macOS may no longer
find Sheepr):

```sh
tccutil reset SystemPolicyAllFiles com.lukaso.sheepr
```

In an admin account the row then stays in the list, switched off; remove it with − if you like.

## npm

- Install globally (`npm i -g`, `pnpm add -g`). The `sheepr` on your PATH then *is* sheepr (a
  small `sh` launcher replaces itself with it), so it keeps your process id, signal settings and
  environment, and TERM to it reaches the job.
- Do not run it through `npx`, `pnpm dlx` or `bunx`: they start it as a child of their own, so TERM
  to the process you hold does not reach sheepr.
- pnpm's own launcher adds a `NODE_PATH` to the job's environment, as it does for every global bin.
- If you use bun, check the installed files' permissions: a bun install has been measured to make
  them world-writable. Do not install with bun as root or into a shared prefix.

## Uninstall

First, if you gave Sheepr Full Disk Access, remove the grant while it is still installed:

```sh
tccutil reset SystemPolicyAllFiles com.lukaso.sheepr
```

Then remove it the way you installed it:

- Homebrew: `brew uninstall --cask sheepr` (with `--zap`, it also removes
  `~/.local/state/sheepr`)
- install.sh on macOS: `rm -rf ~/Applications/Sheepr.app ~/.local/bin/sheepr`
- install.sh on Linux: `rm ~/.local/bin/sheepr` (as root: `rm /usr/local/bin/sheepr`)
- npm: `npm rm -g sheepr`
- pnpm: `pnpm rm -g sheepr`

pnpm 10 keeps a copy of the app in its store after `pnpm rm -g`. To remove it:

```sh
find "$(pnpm root -g)/../.pnpm" -maxdepth 1 \( -name 'sheepr@*' -o -name 'sheepr-darwin-universal@*' \) -exec rm -rf {} +
```

sheepr keeps its job journals in `$SHEEPR_STATE` if set, else in `$XDG_STATE_HOME/sheepr` if
that is an absolute path, else in `~/.local/state/sheepr`; delete that directory to remove them. The privacy grant stays until you reset it (see
[macOS privacy](#macos-privacy)).

## Reference

- `run`'s exit codes follow `timeout(1)`: the command's own code; 124 when a limit fired
  (`--timeout`, a cap); 125 when sheepr failed, for a usage error of `run`, or when a process was
  still alive at the kill deadline; a job ended by a TERM from outside dies of SIGTERM itself (143
  in a shell). `--status-fd` says which, as one JSON line; read that fd while sheepr runs (from a
  regular file, wait for the line's newline or for sheepr's exit: the line goes out in several
  writes). sheepr
  gives up when the fd accepts nothing for 10 s (up to 20 s after its last byte on a terminal or
  a Linux TCP socket, which can take part of a write; on Linux a Unix socket such as node's stdio
  pair accepts nothing until its reader has drained three quarters of it), and at about 30 s in
  all; then the reader has part of the line or none, sheepr says so on stderr, and the exit code
  stays the same. A status is a line that parses as JSON (with `3>&2`, a cut line can also end in
  a newline: sheepr's notice starts a new line when that pipe takes it). Leave sheepr about 31 s
  after the kill deadline before you send it KILL (about 42 s at worst, and only while its stderr
  is read).
- In the `--status-fd` line, `root` says how the command ended: `exited`, `signaled`, or
  `not-started` when it never ran. `root_code` is its exit code when it exited and
  `root_signal` the number of the signal that ended it; the other one is null. Both are null
  when the command never ran, and when sheepr did not see how it ended (then `root` is
  `signaled`; for example with `--mode root-disclaim` when a TERM or a limit ends the job). When `trigger` is set, they say how the command ended while the job was being
  ended: by itself (it exited just as the TERM came, or while it had time to end), by your
  signal (a TERM to the whole process group reaches the command too), or by sheepr's kill. They
  are not the command's own result for the job.
- When something failed, `error` says what, `error_code` names the errno behind it (for example
  `ENOENT`, `EAGAIN`; null when there is none, or for a value sheepr has no name for), and
  `error_source` says whose failure it is: `command` (the command could not be run: not found,
  not executable), `resources` (the machine was out of processes, memory, file descriptors or
  disk space: trying again later, or freeing some, may help), `usage` (a usage error, or an
  option refused here), or `sheepr` (sheepr itself failed, or could not do its job in this
  environment: for example the caller's signal mask, the state directory, or on Linux a missing
  /proc). When two things fail in one run,
  `error` is the first, and the others are in `notes` as `also: …`; an internal error is never
  only a note. A run that ends before its command runs always says why: an `error`, or `trigger`
  `term` when a TERM ended it.
- `run --require-journal`: the command runs only once sheepr has written it into its job journal,
  the record that lets `sheepr sweep` (or your next `sheepr run`) end the job if sheepr is killed.
  When the journal cannot be kept (no state directory, a full disk, no permission), the command
  does not run: exit 125, and the `--status-fd` line's `error` says why. When the journal fails
  while the job runs (a write fails, or the journal file is removed or replaced), sheepr ends
  the job: exit 125, `trigger` `journal`. It does not end the job
  when the job is already ending: a journal that fails during the kill, in the same moment as a
  TERM, a limit or the command's own end (those end the job as usual), or when sheepr marks the
  journal for `--leave-strays`; then one stderr line names the failure. Not caught: a journal
  emptied in place while the job runs (it is still the same file), and on a filesystem that
  numbers its files by name (FUSE without `use_ino`, such as sshfs) a journal can look replaced
  when it is not: with the option the job then ends, and with or without it the journal is left
  after the job's end. Without the option, a
  journal that cannot be kept only costs the cleanup after a killed sheepr, and the job runs.
  Not with `--mode root-disclaim`; on macOS, not when the caller blocks SIGCONT. A limit on
  macOS: sheepr starts the command paused and resumes it only after its journal line, but a
  SIGCONT from outside (for example from `timeout`) in that short moment can run it before
  sheepr kills it, so a refusal there never says the command did not run.
- After an internal error (a panic) once the command may have run, sheepr does not end the
  process tree; the job's journal is kept, and `sheepr sweep` (or your next `sheepr run`) ends it.
  No status line is written when sheepr ends before it can: before it has read `--status-fd`,
  before it has set up its signals, and on macOS when a TERM was already pending across its
  self re-exec, or when the new image of that re-exec fails to start (a re-exec that is refused
  outright is not this case: sheepr then runs on, tracking by parent ids).
- `sweep` exits 0 when it is done, also when there is nothing to sweep; 1 when it refuses and
  signals nothing (the state directory or its journal folder is not safe, cannot be reached or
  cannot be listed; sheepr cannot follow its own chain of parent processes; on Linux, no /proc of
  its own pid namespace is mounted, which it checks first, so then also when there is nothing to
  sweep); 125 when a job's kill deadline passed with members alive, or sheepr failed inside.
  Something it could not sweep is one stderr line that names the file and what clears it, and
  does not change the exit code, unless you pass `--strict`: then `sweep` exits 3 when one of
  these is left (125 still wins over 3):
  - a file that holds no job, or that is not a journal at all (a folder, a FIFO, a socket, a
    symbolic link): remove it;
  - a journal it may not open: check its mode;
  - a journal it could not open, lock or read for another reason (for example too many open
    files, or a lock a network disk refuses): try again;
  - another user's file: sheepr will not read it; check how it got there;
  - a job that holds the process that ran `sweep`, or one of its parents: it clears when that
    process ends;
  - no boot id, while a journal may be there: try again.

  Never counted, and never a reason for 3: a running job (its journal is locked), a job that
  ended while `sweep` looked, a job kept with `--leave-strays`, another owner's job (whatever is
  wrong with it, a default sweep says nothing of it; that owner's `sweep --owner` does), and a
  journal of another boot or pid namespace (that one is still said). A journal whose lock fails
  for another reason is never swept: it may be a running job's, and the sweep before each `run`
  and `kill` take it for one, as before.
- Every command but `run` exits 2 for a usage error.
- Stable interfaces: the subcommands and the flags `sheepr help <command>` shows, the exit codes,
  the `--status-fd` and `--json` schemas (`"v": 1`), and the `sheepr:` at the start of the first
  line of each message sheepr itself writes to stderr (for a usage error, that line says what was
  wrong; `sheepr` alone prints the overview and exits 2). Every release has a
  [CHANGELOG](CHANGELOG.md) entry.

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT),
at your option. Unless you explicitly state otherwise, any contribution you submit for inclusion in
sheepr, as defined in the Apache-2.0 license, is dual licensed as above, without any additional
terms or conditions.
