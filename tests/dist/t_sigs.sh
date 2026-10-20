#!/bin/sh
# Every cleanup trap of the release catches one list of terminating signals (scripts/lib/sigs.sh):
#   - the list: every signal `kill -l` names whose default ends /bin/sh without its EXIT trap
#     (measured on each run: QUIT and PROF) is on it;
#   - the sweep (tests/lib/sigsweep.py, which reads each shell file as the shell does: a comment, a
#     quoted string or a heredoc holds no trap): each EXIT cleanup trap in scripts/ starts by
#     holding the list off (`trap '' $SIGS`, itself or first in the function it calls), and has a
#     trap beside it (within five lines) with an action, on $SIGS unquoted; no literal list; no
#     other SIGS= line; each file with one reads the list from sigs.sh, or is scripts/install.sh
#     (the list is written into its trap lines at render: t_install), or carries sigs.sh's SIGS
#     line verbatim (exec-guard.sh, copied as one file; smoke.sh and s7-clean-user.sh, which the
#     S7 test user runs alone); the sites are counted; a planted file per rule breaks that rule
#     alone and must get exactly its tag, and four good files must pass;
#   - for each script here that a row can stop where its cleanup must run (npm-pack.sh at npm pack,
#     smoke.sh at `SHEEPR --version`, s7-clean-user.sh's tools at its download and its channel at
#     its manifest read): a QUIT (whose default runs no EXIT trap) and a USR1 (whose default runs
#     it at once, without waiting for the running tool), each sent to the script by its pid while
#     the tool runs (a stand-in that succeeds, so only the trap can end the script with 1): the
#     script waits for the tool, writes none of its own later lines, then its temp dir is gone. sign.sh's,
#     install.sh's, exec-guard.sh's (its judging subshell) and archive.sh's rows are in their own
#     cells (t_sign, t_install, t_exec_guard, t_archive); the last two find their moment with
#     tests/lib/sigchild.c, since those scripts pin PATH and call their tools by path.
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

# --- the sweep (tests/lib/sigsweep.py reads each shell file as the shell does; its rules: near,
# ignore, listed, other, literal)
sweep() { # dir [rendered-file] -> violations, then "SITES n"
  python3 -I "$SR_ROOT/tests/lib/sigsweep.py" "$1" "$line" "${2:-$SR_ROOT/scripts/install.sh}"
}
sweep "$SR_ROOT/scripts" > "$FX/sw.out" 2>&1; swrc=$?
ns=$(sed -n 's/^SITES //p' "$FX/sw.out"); v=$(grep -v '^SITES ' "$FX/sw.out")
[ $swrc = 0 ] && [ -z "$v" ] && [ "${ns:-0}" -ge 20 ] \
  && pass "every EXIT cleanup trap in scripts/ ($ns) starts by holding off \$SIGS, has a trap on \$SIGS beside it, from the one list" \
  || fail "the sweep (rc $swrc, $ns sites): $(printf '%s\n' "$v" | head -5 | tr '\n' '|')"
# the controls: one planted file per rule, each breaking that rule alone (the tags it gets must be
# exactly the expected ones), and good files that must pass (an inline cleanup, one in a function,
# the verbatim line, and a file the render writes into)
S1=". \"\$(dirname \"\$0\")/sigs.sh\""
EX="trap 'trap \"\" \$SIGS; rm -rf x' EXIT"
SG="trap 'exit 1' \$SIGS"
plant() { # name expected-tags lines...
  pn=$1 pe=$2; shift 2
  rm -rf "${FX:?}/plant/$pn"; mkdir -p "$FX/plant/$pn"; printf '#!/bin/sh\n' > "$FX/plant/$pn/f.sh"
  for pl; do printf '%s\n' "$pl" >> "$FX/plant/$pn/f.sh"; done
  rf=$SR_ROOT/scripts/install.sh; [ "$pn" = rendered ] && rf=$FX/plant/$pn/f.sh
  sweep "$FX/plant/$pn" "$rf" > "$FX/pl.out" 2>&1
  got=$(grep -v '^SITES ' "$FX/pl.out" | cut -d' ' -f1 | sort -u | tr '\n' ' ' | sed 's/ $//')
  [ "$got" = "$pe" ] && [ "$(sed -n 's/^SITES //p' "$FX/pl.out")" = 1 ] \
    && pass "control $pn: the sweep says '${pe:-nothing}'" || fail "control $pn: expected '${pe:-nothing}', got '$got' ($(tr '\n' '|' < "$FX/pl.out"))"
}
plant good "" "$S1" "$EX" "$SG"
plant goodfn "" "$S1" 'cl() { # the cleanup' "  trap '' \$SIGS" '  rm -rf x' '}' 'trap cl EXIT' "trap 'cl; exit 1' \$SIGS"
plant verbatim "" "$line" "$EX" "$SG"
plant rendered "" "$EX" "$SG"
plant commented near "$S1" "$EX" "# $SG"
plant quoted near "$S1" "$EX" "trap 'exit 1' \"\$SIGS\""
plant emptyaction near "$S1" "$EX" "trap '' \$SIGS"
plant far near "$S1" "$EX" : : : : : : "$SG"
plant noignore ignore "$S1" "trap 'rm -rf x' EXIT" "$SG"
plant noignorefn ignore "$S1" 'cl() {' '  rm -rf x' "  trap '' \$SIGS" '}' 'trap cl EXIT' "trap 'cl; exit 1' \$SIGS"
plant unlisted listed "$EX" "$SG"
plant viavar "" 'f=scripts/lib/sigs.sh' '. "$root/$f"' "$EX" "$SG"
plant viavarother listed 'f=scripts/lib/other.sh' '. "$root/$f"' "$EX" "$SG"
plant bare other "$S1" 'SIGS=' "$EX" "$SG"
plant literal literal "$S1" "$EX" "$SG" "trap 'exit 1' HUP INT TERM"

# --- the rows: a stand-in tool, at its first call, sends the signal to the script's pid
# ($FX/target.pid), takes 1 s, marks itself done; every call succeeds (exit 0, no output), so only
# the script's trap can end it with 1, and a script that went on past the signal is seen by the
# lines it writes after the tool (each row names them: they must be absent)
mkdir -p "$FX/sb"
sigtool() { # path
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
#!/bin/sh
[ -e "$FX/sent" ] && exit 0
: > "$FX/sent"
i=0; while [ ! -s "$FX/target.pid" ] && [ \$i -lt 100 ]; do /bin/sleep 0.1; i=\$((i + 1)); done
kill -\$(cat "$FX/sig") \$(cat "$FX/target.pid")
/bin/sleep 1; : > "$FX/tool.done"; exit 0
EOF
  chmod +x "$1"
}
prep() { # signal tmpdir
  rm -f "$FX/target.pid" "$FX/tool.done" "$FX/sent"; echo "$1" > "$FX/sig"; rm -rf "${2:?}"; mkdir -p "$2"
}
sigrow() { # label tmpdir own-lines-pattern (rc in $rc, the script's output in $FX/o): the tool had
           # ended when the script did, the script wrote none of its own lines after it, its temp
           # dir is gone; then the tool's own end is awaited
  waited=no; [ ! -e "$FX/tool.done" ] || waited=yes
  i=0; while [ ! -e "$FX/tool.done" ] && [ $i -lt 40 ]; do sleep 0.1; i=$((i + 1)); done
  own=$(grep -E -c "$3" "$FX/o")
  [ "$rc" = 1 ] && [ -e "$FX/sent" ] && [ $waited = yes ] && [ "$own" = 0 ] && [ -z "$(ls -A "$2" 2>/dev/null)" ] \
    && pass "$1: it waits for the tool, writes nothing after it, then its temp dir is gone (rc $rc)" \
    || fail "$1: rc=$rc sent: $(ls "$FX/sent" 2>/dev/null) tool done: $(ls "$FX/tool.done" 2>/dev/null) own lines: $own ($(head -3 "$FX/o" | tr '\n' '|')) left: $(ls -A "$2" 2>/dev/null | tr '\n' ' ')"
}
# the lines each script writes after the tool returns (measured: none before it, but smoke.sh's
# `smoke: testing` line, which holds the tool's call)
OWN_NPMPACK=. OWN_SMOKE='^(ok|FAIL): ' OWN_S7TOOLS=. OWN_S7CHAN=.
# npm-pack.sh, at npm pack
sigtool "$FX/sb/npm"
mkdir -p "$FX/arc/Sheepr.app" && tar -czf "$FX/arc.tgz" -C "$FX/arc" Sheepr.app && printf x > "$FX/la" && printf x > "$FX/lx" && printf '#!/bin/sh\n' > "$FX/launcher" || exit 3
for sg in QUIT USR1; do
  prep $sg "$FX/ntmp"; rm -rf "$FX/ndest"; mkdir -p "$FX/ndest" "$FX/h"
  /usr/bin/perl -e '$SIG{QUIT} = $SIG{INT} = "DEFAULT"; exec @ARGV or die' -- env -i PATH="$FX/sb:/usr/bin:/bin" HOME="$FX/h" TMPDIR="$FX/ntmp" sh "$SR_ROOT/scripts/lib/npm-pack.sh" 0.1.0 "$FX/arc.tgz" "$FX/la" "$FX/lx" "$FX/launcher" "$FX/ndest" > "$FX/o" 2>&1 & tp=$!
  echo $tp > "$FX/target.pid"; wait $tp; rc=$?
  sigrow "npm-pack.sh, a $sg during npm pack" "$FX/ntmp" "$OWN_NPMPACK"
done
# smoke.sh, at SHEEPR --version (the stand-in is the sheepr under test)
sigtool "$FX/sd/sheepr"
for sg in QUIT USR1; do
  prep $sg "$FX/stmp"
  /usr/bin/perl -e '$SIG{QUIT} = $SIG{INT} = "DEFAULT"; exec @ARGV or die' -- env -i PATH=/usr/bin:/bin HOME="$FX/h" TMPDIR="$FX/stmp" sh "$SR_ROOT/scripts/smoke.sh" "$FX/sd/sheepr" < /dev/null > "$FX/o" 2>&1 & tp=$!
  echo $tp > "$FX/target.pid"; wait $tp; rc=$?
  sigrow "smoke.sh, a $sg during sheepr --version" "$FX/stmp" "$OWN_SMOKE"
done
# s7-clean-user.sh's tools, at its download (the library, the wall stubbed, as t_s7_clean_user runs it)
sigtool "$FX/sb/s7curl"
for sg in QUIT USR1; do
  prep $sg "$FX/s7tmp"; rm -rf "$FX/s7h"; mkdir -p "$FX/s7h/Library/Safari"
  /usr/bin/perl -e '$SIG{QUIT} = $SIG{INT} = "DEFAULT"; exec @ARGV or die' -- sh -c 'SR_S7_LIB=1; . "$1"; s7_walled() { :; }; S7_CURL=$2; HOME=$3; TMPDIR=$4; export HOME TMPDIR; s7_cmd_tools' sh \
    "$SR_ROOT/scripts/s7-clean-user.sh" "$FX/sb/s7curl" "$FX/s7h" "$FX/s7tmp" < /dev/null > "$FX/o" 2>&1 & tp=$!
  echo $tp > "$FX/target.pid"; wait $tp; rc=$?
  sigrow "s7-clean-user.sh tools, a $sg during its download" "$FX/s7tmp" "$OWN_S7TOOLS"
done
# s7-clean-user.sh's channel, at its manifest read (python3: the first on the PATH ~/s7-env.sh sets)
for sg in QUIT USR1; do
  prep $sg "$FX/s7tmp"; rm -rf "$FX/s7h" "$FX/s7d"; mkdir -p "$FX/s7h/Library/Safari" "$FX/s7d/results"; : > "$FX/s7tty"
  ( SR_S7_LIB=1; . "$SR_ROOT/scripts/s7-clean-user.sh"; s7_env ) > "$FX/s7h/s7-env.sh"; sigtool "$FX/s7h/npm-global/bin/python3"
  /usr/bin/perl -e '$SIG{QUIT} = $SIG{INT} = "DEFAULT"; exec @ARGV or die' -- sh -c 'SR_S7_LIB=1; . "$1"; s7_walled() { :; }; S7_DIR=$2; S7_TTY=$3; S7_TTY_OUT=/dev/null; HOME=$4; TMPDIR=$5; export HOME TMPDIR; s7_cmd_channel npm' sh \
    "$SR_ROOT/scripts/s7-clean-user.sh" "$FX/s7d" "$FX/s7tty" "$FX/s7h" "$FX/s7tmp" < /dev/null > "$FX/o" 2>&1 & tp=$!
  echo $tp > "$FX/target.pid"; wait $tp; rc=$?
  sigrow "s7-clean-user.sh channel, a $sg during its manifest read" "$FX/s7tmp" "$OWN_S7CHAN"
done
finish
