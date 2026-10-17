#!/bin/sh
# install.sh's signal cleanup under each shell it may be piped to: the rows for tests/dist/t_install.sh
# (macOS: zsh, sh, dash, bash, ksh) and scripts/dist-linux.sh (the Linux images' /bin/sh: busybox ash
# in Alpine, dash in slim; and bash where the image has one).
#   install-sig-rows.sh WORKDIR INSTALL_SH SHELL...
# WORKDIR is the caller's (an empty dir it made and removes); INSTALL_SH is install.sh as rendered.
# Each row runs INSTALL_SH with SHELL, a temp HOME and TMPDIR, and a stand-in curl that, at the first
# download, sends a signal to install.sh (its parent), takes 1 s, marks itself done and succeeds: so
# only install.sh's trap can make it fail. For INT, QUIT and USR1: install.sh waits for curl, exits 1,
# its temp dir is gone, and it writes nothing on stderr (no trap error, and none of its own error
# lines, which a run that went on past the signal would write). INT and QUIT start at their defaults:
# perl sets them when there is one; with no perl the rows need them not ignored on entry (read from
# /proc on Linux), and say so when they are.
# And for each shell, stdout closed: install.sh's stdout is a pipe whose reader has exited, PIPE at
# its default, so its first `say` gets SIGPIPE. The run starts in a process group of its own, KILLed
# at 10 s (a KILL is a FAIL: zsh loops on a write error when PIPE is trapped but not held off in the
# cleanup), and must end with 1 and an empty TMPDIR. perl makes the pipe and the group where there
# is one; else (busybox) a FIFO whose reader has gone, and setsid.
# Prints ok/FAIL lines; exit 0 only when every row passed.
set -u
[ $# -ge 3 ] || { echo "usage: install-sig-rows.sh WORKDIR INSTALL_SH SHELL..." >&2; exit 2; }
W=$1 I=$2; shift 2
[ -d "$W" ] && [ -f "$I" ] || { echo "install-sig-rows: no dir $W or no file $I" >&2; exit 2; }
fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
mkdir -p "$W/sb" "$W/h" || exit 3
cat > "$W/sb/curl" <<EOF
#!/bin/sh
[ -e "$W/sent" ] && exit 0
: > "$W/sent"; kill -\$(cat "$W/sig") \$PPID; sleep 1; : > "$W/curl.done"; exit 0
EOF
chmod 755 "$W/sb/curl" || exit 3
# can INT and QUIT start at their defaults?
can=yes why=""
if [ ! -x /usr/bin/perl ]; then
  if [ -r /proc/self/status ]; then
    # what a command this shell runs starts with (sed's own /proc/self; busybox ash ignores QUIT
    # in itself, and not in what it runs: measured)
    m=$(sed -n 's/^SigIgn:[[:space:]]*//p' /proc/self/status); d=$(printf %s "$m" | tail -c 1)
    # signal n is bit n-1: INT (2) and QUIT (3) are the last hex digit's 2 and 4
    case $d in [0-9a-fA-F]) [ $((0x$d & 6)) = 0 ] || { can=no why="INT or QUIT is ignored on entry and there is no perl to set it back"; } ;;
      *) can=no why="cannot read SigIgn" ;; esac
  else can=no why="no perl, and no /proc to read what is ignored"; fi
fi
run() { # shell: install.sh, its output in $W/o and $W/e
  if [ -x /usr/bin/perl ]; then
    /usr/bin/perl -e '$SIG{QUIT} = $SIG{INT} = "DEFAULT"; exec @ARGV or die' -- \
      env -i PATH="$W/sb:/usr/bin:/bin" HOME="$W/h" TMPDIR="$W/itmp" SHEEPR_INSTALL_BASE=https://sheepr.invalid "$1" "$I" > "$W/o" 2> "$W/e"
  else
    env -i PATH="$W/sb:/usr/bin:/bin" HOME="$W/h" TMPDIR="$W/itmp" SHEEPR_INSTALL_BASE=https://sheepr.invalid "$1" "$I" > "$W/o" 2> "$W/e"
  fi
}
# closed SHELL: install.sh with its stdout closed (the reader gone) -> $res: its status, or KILLED (at
# 10 s), and " STRAY" when a process of its group outlived it (then KILLed too)
closed() {
  if [ -x /usr/bin/perl ]; then
    res=$(/usr/bin/perl -e '
      my $p = fork(); defined $p or die "fork";
      if ($p == 0) { setpgrp(0, 0); $SIG{$_} = "DEFAULT" for qw(PIPE INT QUIT);
        pipe(my $r, my $w) or die; close($r); open(STDOUT, ">&", $w) or die; close($w); exec @ARGV or die }
      my $res = "KILLED";
      for (1..100) { if (waitpid($p, 1) == $p) { my $s = $?; $res = ($s & 127) ? 128 + ($s & 127) : $s >> 8; last } select(undef, undef, undef, 0.1) }
      if ($res eq "KILLED") { kill("KILL", -$p); waitpid($p, 0) }
      elsif (kill(0, -$p)) { kill("KILL", -$p); $res .= " STRAY" }
      print $res' -- env -i PATH="$W/sb:/usr/bin:/bin" HOME="$W/h" TMPDIR="$W/itmp" SHEEPR_INSTALL_BASE=https://sheepr.invalid "$1" "$I" 2> "$W/e")
    return
  fi
  # no perl (busybox): PIPE must be at its default in what this shell runs (signal 13: bit 12)
  m=$(sed -n 's/^SigIgn:[[:space:]]*//p' /proc/self/status 2>/dev/null); d=$(printf %s "$m" | tail -c 4 | head -c 1)
  case $d in [0-9a-fA-F]) [ $((0x$d & 1)) = 0 ] || { res="not run (PIPE ignored on entry, no perl)"; return; } ;; *) res="not run (cannot read SigIgn)"; return ;; esac
  command -v setsid > /dev/null 2>&1 || { res="not run (no perl, no setsid)"; return; }
  rm -f "$W/fifo"; mkfifo "$W/fifo" || { res="not run (no fifo)"; return; }
  sh -c 'exec < "$1"' sh "$W/fifo" & rp=$!
  # the writer opens the FIFO (the reader then exits), waits until the reader is gone, then runs
  setsid sh -c 'while kill -0 "$1" 2>/dev/null; do sleep 0.1; done; shift; exec "$@"' sh "$rp" \
    env -i PATH="$W/sb:/usr/bin:/bin" HOME="$W/h" TMPDIR="$W/itmp" SHEEPR_INSTALL_BASE=https://sheepr.invalid "$1" "$I" > "$W/fifo" 2> "$W/e" & wp=$!
  wait "$rp"
  i=0; while [ $i -lt 100 ]; do
    st=$(sed 's/.*) //' "/proc/$wp/stat" 2>/dev/null | cut -c1); { [ -z "$st" ] || [ "$st" = Z ]; } && break
    sleep 0.1; i=$((i + 1))
  done
  if [ $i -ge 100 ]; then kill -KILL "-$wp" 2>/dev/null; wait "$wp" 2>/dev/null; res=KILLED
  else wait "$wp"; res=$?; ! kill -0 "-$wp" 2>/dev/null || { kill -KILL "-$wp" 2>/dev/null; res="$res STRAY"; }; fi
}
for shl in "$@"; do
  [ -x "$shl" ] || { bad "$shl: no such shell"; continue; }
  rm -rf "${W:?}/itmp"; mkdir -p "$W/itmp" || exit 3; : > "$W/sent"   # (the stand-in curl: no signal)
  closed "$shl"; left=$(ls -A "$W/itmp" 2>/dev/null); e1=$(head -c 120 "$W/e" | tr '\n' '|'); : > "$W/e"   # (no write-error flood kept)
  if [ "$res" = 1 ] && [ -z "$left" ]; then
    ok "$shl, install.sh with its stdout closed (PIPE at its default): exits 1, its temp dir is gone, within 10 s"
  else
    bad "$shl, stdout closed: rc=$res left: $(echo $left) stderr: $e1"
  fi
  for sg in INT QUIT USR1; do
    case $sg in INT|QUIT) [ $can = yes ] || { bad "$shl, a $sg: not run ($why)"; continue; } ;; esac
    rm -rf "${W:?}/itmp"; rm -f "$W/sent" "$W/curl.done"; mkdir -p "$W/itmp" || exit 3; echo $sg > "$W/sig"
    ( run "$shl" ) 2>/dev/null; rc=$?   # (the shell's own line about a job a signal ended, not install.sh's)
    waited=no; [ -e "$W/curl.done" ] && waited=yes
    i=0; while [ ! -e "$W/curl.done" ] && [ $i -lt 40 ]; do sleep 0.1; i=$((i + 1)); done   # the stand-in's own end, before the next row
    left=$(ls -A "$W/itmp" 2>/dev/null)
    if [ $rc = 1 ] && [ -e "$W/sent" ] && [ $waited = yes ] && [ -z "$left" ] && [ ! -s "$W/e" ]; then
      ok "$shl, a $sg to install.sh during its download: it waits for curl, exits 1, its temp dir is gone, nothing on stderr"
    else
      bad "$shl, a $sg: rc=$rc signal sent: $([ -e "$W/sent" ] && echo yes || echo no) waited: $waited left: $(echo $left) stderr: $(head -3 "$W/e" | tr '\n' '|')"
    fi
  done
done
[ $fails = 0 ]
