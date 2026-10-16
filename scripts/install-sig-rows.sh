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
for shl in "$@"; do
  [ -x "$shl" ] || { bad "$shl: no such shell"; continue; }
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
