#!/bin/sh
# Issue #16 (plan §3): a RELEASE build of `run --require-journal` refuses a job journal it cannot
# keep. Its state directory under a regular file (mkdir: ENOTDIR, which holds as root too):
# exit 125, the status line says root "not-started", trigger null, error_code ENOTDIR,
# error_source "sheepr", an error that names the journal, and the command never ran. The
# controls: a writable state directory runs the command (exit 0, no error); without the option
# the unwritable one runs it as before, with the warning that the job runs. Release-binary rules,
# as t_smoke.sh: the build through the exec door, a cleared environment, a temp HOME and state.
set -u
. "$(dirname "$0")/lib.sh"
fx_dir
(cd "$SR_ROOT" && env CARGO_TARGET_DIR="$FX/target" timeout 1200 cargo build -q --release --locked --bin sheepr) || { fail "release build"; finish; }
B=$FX/target/release/sheepr
"$SR_ROOT/scripts/lib/exec-guard.sh" check "$B" || { fail "the door refuses the build"; finish; }
mkdir -p "$FX/h"
printf 'a regular file\n' > "$FX/h/file"
# rel STATE NAME ARGS...: the release build with SHEEPR_STATE=STATE, its status line in
# $FX/NAME.st and its stderr in $FX/NAME.err; its exit code
rel() {
  st=$1 name=$2; shift 2
  env -i PATH=/usr/bin:/bin HOME="$FX/h" XDG_STATE_HOME="$FX/h/x" SHEEPR_STATE="$st" TMPDIR="$FX/h" "$B" run --status-fd 3 "$@" \
    3> "$FX/$name.st" 2> "$FX/$name.err" < /dev/null
}
has() { grep -c "$2" "$FX/$1.st" > /dev/null; }

rel "$FX/h/file/state" refused --require-journal -- /bin/sh -c "touch '$FX/ran1'"; r=$?
if [ "$r" = 125 ] && [ ! -e "$FX/ran1" ] && has refused '"root":"not-started"' && has refused '"trigger":null' \
  && has refused '"error_code":"ENOTDIR"' && has refused '"error_source":"sheepr"' && has refused '"error":"the job journal cannot be kept: '; then
  pass "a release run --require-journal refuses a state dir under a regular file (ENOTDIR), the command not run"
else
  fail "rc=$r, ran=$([ -e "$FX/ran1" ] && echo yes || echo no): $(cat "$FX/refused.st") / $(tr '\n' ' ' < "$FX/refused.err")"
fi
rel "$FX/h/s" writable --require-journal -- /bin/sh -c "touch '$FX/ran2'"; r=$?
[ "$r" = 0 ] && [ -e "$FX/ran2" ] && has writable '"error":null' && pass "control: a writable state dir runs the command" \
  || fail "control: rc=$r: $(cat "$FX/writable.st") / $(tr '\n' ' ' < "$FX/writable.err")"
rel "$FX/h/file/state" today -- /bin/sh -c "touch '$FX/ran3'"; r=$?
n=$(grep -c 'the job runs' "$FX/today.err")
[ "$r" = 0 ] && [ -e "$FX/ran3" ] && [ "$n" = 1 ] && pass "control: without the option the command runs as before, with the warning" \
  || fail "control: rc=$r, $n warning(s): $(tr '\n' ' ' < "$FX/today.err")"
finish
