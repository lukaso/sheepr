#!/bin/sh
# Every cleanup trap of the release catches one list of terminating signals (scripts/lib/sigs.sh):
#   - the list: every signal `kill -l` names whose default ends /bin/sh without its EXIT trap
#     (measured on each run: QUIT and PROF) is on it;
#   - the sweep: each EXIT cleanup trap in scripts/ has a trap on $SIGS beside it (within five
#     lines), never a literal list; each file with one reads the list from sigs.sh, or has it
#     written in when it is rendered (install.sh), or carries sigs.sh's SIGS line verbatim
#     (exec-guard.sh, copied as one file; smoke.sh and s7-clean-user.sh, which the S7 test user
#     runs alone); the sites are counted, and planted files that break each rule are caught;
#   - for each script here that a row can stop where its cleanup must run (npm-pack.sh at npm pack,
#     smoke.sh at `SHEEPR --version`, s7-clean-user.sh's tools at its download and its channel at
#     its manifest read): a QUIT (whose default runs no EXIT trap) and a USR1 (whose default runs
#     it at once, without waiting for the running tool), each sent to the script by its pid while
#     the tool runs: the script waits for the tool, then its temp dir is gone. sign.sh's and
#     install.sh's rows are in their own cells (t_sign, t_install). exec-guard.sh's checks and
#     archive.sh's check have no such point (PATH pinned to /usr/bin:/bin, their tools called by
#     path, a regular file as input; plutil does not block on a FIFO plist: measured): the sweep
#     is all they get.
set -u
. "$(dirname "$0")/lib.sh"
[ "$(uname -s)" = Darwin ] || { echo "SKIP (macOS only)"; exit 0; }
fx_dir
L=$SR_ROOT/scripts/lib/sigs.sh
line=$(grep '^SIGS="' "$L" 2>/dev/null)
[ "$(grep -c '^SIGS=' "$L" 2>/dev/null)" = 1 ] && [ "$line" = 'SIGS="HUP INT TERM QUIT ALRM USR1 USR2 XCPU XFSZ VTALRM PROF"' ] \
  && pass "scripts/lib/sigs.sh: one SIGS line, ship's list" || fail "sigs.sh: '$line'"
# the list holds every signal whose default ends sh without running its EXIT trap: each signal
# `kill -l` names (but the uncatchable and the job-control ones), sent by a child to a /bin/sh that
# has an EXIT trap, every signal at its default; the controls: QUIT is found, TERM runs the trap
cat > "$FX/selfsig.sh" <<'EOF'
trap 'echo exit-trap >> "$2"' EXIT
/bin/sh -c 'kill -$1 $PPID' sh "$1"
/bin/sleep 0.3
echo went-on >> "$2"
EOF
silent= trm=
for s in $(/bin/sh -c 'kill -l' | tr ' \t' '\n\n' | grep -v '^$' | sed 's/^SIG//'); do
  case $s in KILL|STOP|TSTP|TTIN|TTOU|CONT) continue ;; esac
  : > "$FX/sl"
  ( /usr/bin/perl -e 'for (keys %SIG) { $SIG{$_} = "DEFAULT" } exec @ARGV' -- /bin/sh "$FX/selfsig.sh" "$s" "$FX/sl" ) 2>/dev/null; r=$?
  [ $r -gt 128 ] && ! grep -q exit-trap "$FX/sl" && silent="$silent $s"
  [ $s = TERM ] && trm="$r:$(tr '\n' + < "$FX/sl")"
done
eval "$line"; miss=
for s in $silent; do case " $SIGS " in *" $s "*) ;; *) miss="$miss $s" ;; esac; done
case " $silent " in *" QUIT "*) qf=yes ;; *) qf=no ;; esac
[ $qf = yes ] && [ "$trm" = "143:exit-trap+" ] && pass "control: the scan finds QUIT, and TERM runs the EXIT trap" || fail "control: QUIT found: $qf, TERM: $trm"
[ -n "$silent" ] && [ -z "$miss" ] && pass "every signal whose default skips the EXIT trap ($silent ) is on the list" || fail "skip the EXIT trap but not on the list:$miss (found:$silent )"

# --- the sweep
sites() { # file -> "SITES n", then one line per EXIT trap with no $SIGS trap beside it
  awk -v f="$1" -v q="'" '
    { L[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        s = L[i]; if (s ~ /^[ \t]*#/) continue
        if (s ~ /trap - EXIT/) continue
        if (s ~ /trap .*EXIT/ || index(s, q " EXIT") > 0) {
          n++; ok = 0
          for (j = i; j <= i + 5 && j <= NR; j++) if (index(L[j], "$SIGS") > 0) ok = 1
          if (!ok) print f ":" i ": an EXIT trap with no trap on $SIGS beside it"
        }
      }
      print "SITES " n + 0
    }' "$1"
}
listed() { # file -> 0 if it gets the list: it reads sigs.sh, is scripts/install.sh (the list is
  # written into its trap lines at render: t_install.sh), or has the verbatim line
  grep -q -E '^[^#]*\. +".*sigs\.sh"' "$1" || [ "$1" = "$SR_ROOT/scripts/install.sh" ] || grep -qxF "$line" "$1"
}
sweep() { # dir -> violations on stdout, the site count in $FX/nsites
  : > "$FX/nsites.l"
  for f in $(grep -rl -e 'EXIT' "$1" | sort); do
    sites "$f" > "$FX/s.out"
    n=$(sed -n 's/^SITES //p' "$FX/s.out"); echo "$n" >> "$FX/nsites.l"
    grep -v '^SITES ' "$FX/s.out"
    [ "$n" = 0 ] || listed "$f" || echo "$f: has an EXIT trap but does not get the list (sigs.sh, the render, or its verbatim line)"
    grep -n -E "^[^#]*trap +('[^']*'|\"[^\"]*\"|[a-z_]+) +(HUP|INT|TERM|QUIT)( |;|$)" "$f" | grep -v -E "trap +'exit 1(29|30|43)' +(HUP|INT|TERM)" | sed "s|^|$f: a literal signal list: |"
    grep -n '^ *SIGS=' "$f" | grep -v -x -F -e "$(grep -n -x -F -- "$line" "$f" | head -1)" | grep -v ':SIGS=$' | sed "s|^|$f: another SIGS: |"
  done
  awk '{ s += $1 } END { print s + 0 }' "$FX/nsites.l" > "$FX/nsites"
}
v=$(sweep "$SR_ROOT/scripts"); ns=$(cat "$FX/nsites")
[ -z "$v" ] && [ "$ns" -ge 20 ] && pass "every EXIT cleanup trap in scripts/ ($ns) traps \$SIGS beside it, from the one list" || fail "the sweep ($ns sites): $(printf '%s\n' "$v" | head -5 | tr '\n' '|')"
# the controls: planted files break each rule
mkdir -p "$FX/plant"
printf '#!/bin/sh\n. "$(dirname "$0")/sigs.sh"\ntrap %s EXIT\ntrap %s HUP INT TERM\n' "'rm -rf x'" "'exit 1'" > "$FX/plant/a.sh"
printf '#!/bin/sh\ntrap %s EXIT\ntrap %s $SIGS\n' "'rm -rf x'" "'exit 1'" > "$FX/plant/b.sh"
printf '#!/bin/sh\n. "$(dirname "$0")/sigs.sh"\ntrap %s EXIT\n:\n:\n:\n:\n:\n:\ntrap %s $SIGS\n' "'rm -rf x'" "'exit 1'" > "$FX/plant/c.sh"
for pf in a b c; do
  rm -rf "$FX/p1"; mkdir -p "$FX/p1"; cp "$FX/plant/$pf.sh" "$FX/p1/"
  [ -n "$(sweep "$FX/p1")" ] && pass "control: the sweep catches planted file $pf" || fail "control: planted file $pf passes the sweep"
done

# --- the rows: a stand-in tool sends the signal to the script's pid ($FX/target.pid), takes 1 s,
# marks itself done and fails
mkdir -p "$FX/sb"
sigtool() { # path
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
#!/bin/sh
i=0; while [ ! -s "$FX/target.pid" ] && [ \$i -lt 100 ]; do /bin/sleep 0.1; i=\$((i + 1)); done
kill -\$(cat "$FX/sig") \$(cat "$FX/target.pid")
/bin/sleep 1; : > "$FX/tool.done"; exit 1
EOF
  chmod +x "$1"
}
prep() { # signal tmpdir
  rm -f "$FX/target.pid" "$FX/tool.done"; echo "$1" > "$FX/sig"; rm -rf "${2:?}"; mkdir -p "$2"
}
sigrow() { # label tmpdir (rc in $rc): the tool had ended when the script did; then its own end is awaited
  waited=no; [ ! -e "$FX/tool.done" ] || waited=yes
  i=0; while [ ! -e "$FX/tool.done" ] && [ $i -lt 40 ]; do sleep 0.1; i=$((i + 1)); done
  [ "$rc" = 1 ] && [ $waited = yes ] && [ -z "$(ls -A "$2" 2>/dev/null)" ] \
    && pass "$1: it waits for the tool, then its temp dir is gone (rc $rc)" || fail "$1: rc=$rc tool done: $(ls "$FX/tool.done" 2>/dev/null) left: $(ls -A "$2" 2>/dev/null | tr '\n' ' ')"
}
# npm-pack.sh, at npm pack
sigtool "$FX/sb/npm"
mkdir -p "$FX/arc/Sheepr.app" && tar -czf "$FX/arc.tgz" -C "$FX/arc" Sheepr.app && printf x > "$FX/la" && printf x > "$FX/lx" && printf '#!/bin/sh\n' > "$FX/launcher" || exit 3
for sg in QUIT USR1; do
  prep $sg "$FX/ntmp"; rm -rf "$FX/ndest"; mkdir -p "$FX/ndest" "$FX/h"
  /usr/bin/perl -e '$SIG{QUIT} = $SIG{INT} = "DEFAULT"; exec @ARGV or die' -- env -i PATH="$FX/sb:/usr/bin:/bin" HOME="$FX/h" TMPDIR="$FX/ntmp" sh "$SR_ROOT/scripts/lib/npm-pack.sh" 0.1.0 "$FX/arc.tgz" "$FX/la" "$FX/lx" "$FX/launcher" "$FX/ndest" > "$FX/o" 2>&1 & tp=$!
  echo $tp > "$FX/target.pid"; wait $tp; rc=$?
  sigrow "npm-pack.sh, a $sg during npm pack" "$FX/ntmp"
done
# smoke.sh, at SHEEPR --version (the stand-in is the sheepr under test)
sigtool "$FX/sd/sheepr"
for sg in QUIT USR1; do
  prep $sg "$FX/stmp"
  /usr/bin/perl -e '$SIG{QUIT} = $SIG{INT} = "DEFAULT"; exec @ARGV or die' -- env -i PATH=/usr/bin:/bin HOME="$FX/h" TMPDIR="$FX/stmp" sh "$SR_ROOT/scripts/smoke.sh" "$FX/sd/sheepr" < /dev/null > "$FX/o" 2>&1 & tp=$!
  echo $tp > "$FX/target.pid"; wait $tp; rc=$?
  sigrow "smoke.sh, a $sg during sheepr --version" "$FX/stmp"
done
# s7-clean-user.sh's tools, at its download (the library, the wall stubbed, as t_s7_clean_user runs it)
sigtool "$FX/sb/s7curl"
for sg in QUIT USR1; do
  prep $sg "$FX/s7tmp"; rm -rf "$FX/s7h"; mkdir -p "$FX/s7h/Library/Safari"
  /usr/bin/perl -e '$SIG{QUIT} = $SIG{INT} = "DEFAULT"; exec @ARGV or die' -- sh -c 'SR_S7_LIB=1; . "$1"; s7_walled() { :; }; S7_CURL=$2; HOME=$3; TMPDIR=$4; export HOME TMPDIR; s7_cmd_tools' sh \
    "$SR_ROOT/scripts/s7-clean-user.sh" "$FX/sb/s7curl" "$FX/s7h" "$FX/s7tmp" < /dev/null > "$FX/o" 2>&1 & tp=$!
  echo $tp > "$FX/target.pid"; wait $tp; rc=$?
  sigrow "s7-clean-user.sh tools, a $sg during its download" "$FX/s7tmp"
done
# s7-clean-user.sh's channel, at its manifest read (python3: the first on the PATH ~/s7-env.sh sets)
for sg in QUIT USR1; do
  prep $sg "$FX/s7tmp"; rm -rf "$FX/s7h" "$FX/s7d"; mkdir -p "$FX/s7h/Library/Safari" "$FX/s7d/results"; : > "$FX/s7tty"
  ( SR_S7_LIB=1; . "$SR_ROOT/scripts/s7-clean-user.sh"; s7_env ) > "$FX/s7h/s7-env.sh"; sigtool "$FX/s7h/npm-global/bin/python3"
  /usr/bin/perl -e '$SIG{QUIT} = $SIG{INT} = "DEFAULT"; exec @ARGV or die' -- sh -c 'SR_S7_LIB=1; . "$1"; s7_walled() { :; }; S7_DIR=$2; S7_TTY=$3; S7_TTY_OUT=/dev/null; HOME=$4; TMPDIR=$5; export HOME TMPDIR; s7_cmd_channel npm' sh \
    "$SR_ROOT/scripts/s7-clean-user.sh" "$FX/s7d" "$FX/s7tty" "$FX/s7h" "$FX/s7tmp" < /dev/null > "$FX/o" 2>&1 & tp=$!
  echo $tp > "$FX/target.pid"; wait $tp; rc=$?
  sigrow "s7-clean-user.sh channel, a $sg during its manifest read" "$FX/s7tmp"
done
finish
