#!/bin/sh
# scripts/release.sh's typed-tag confirmation, at a real terminal (a pty from `script`): `publish`,
# `publish-npm`, `publish-cask` and `ship` make a release public and ask for the tag (ship once, for
# every public step);
# `build --sign` does not ask (the notary keychain's own password is its gate). Every run names a
# tag that does not exist, with no input: a run that asks stops at the empty answer (exit 4), one
# that does not goes on to the checks and stops there (no tag: exit 1), before any tool runs. ship and
# publish-npm also refuse a stdout that is not a terminal (a pipe, a file: npm offers its browser login
# and the upload's approval only at one; r18b F2), before they ask.
# No test-environment variable is set (the entries refuse those first: exit 3).
set -u
. "$(dirname "$0")/lib.sh"
[ "$(uname -s)" = Darwin ] || { echo "SKIP (macOS script syntax)"; exit 0; }
fx_dir; fx_repo
t() { # label want-rc want-prompt(yes|no) want-text args...: the output holds want-text and no
  # `release: building` (the no-tag refusal is the build's only stop before its tools run)
  l=$1 want=$2 asks=$3 txt=$4; shift 4
  (cd "$REPO" && env -i PATH=/usr/bin:/bin HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    script -q /dev/null sh scripts/release.sh "$@" < /dev/null) > "$FX/o" 2>&1; rc=$?
  # script returns its command's status; the prompt is written to the pty, which script copies out
  p=no; grep -q 'Type the tag' "$FX/o" && p=yes
  if [ "$rc" = "$want" ] && [ "$p" = "$asks" ] && grep -qF "$txt" "$FX/o" && ! grep -q 'release: building' "$FX/o"; then pass "$l"
  else fail "$l: rc=$rc (want $want), prompt=$p (want $asks): $(tr '\r\n' '  ' < "$FX/o" | cut -c1-200)"; fi
}
t "build --sign at a terminal: no typed tag, on to the checks (no tag v9.9.9)" 1 no "release: no tag v9.9.9" build --sign v9.9.9
t "build --sign --no-notarize at a terminal: no typed tag either" 1 no "release: no tag v9.9.9" build --sign --no-notarize v9.9.9
t "control: publish at a terminal asks for the tag (no answer: not confirmed)" 4 yes "Type the tag" publish v9.9.9
t "control: publish-npm at a terminal asks for the tag" 4 yes "Type the tag" publish-npm v9.9.9
t "publish-cask at a terminal asks for the tag" 4 yes "Type the tag" publish-cask v9.9.9
t "ship at a terminal asks for the tag (no answer: not confirmed)" 4 yes "Type the tag" ship v9.9.9
[ "$(grep -o 'Type the tag' "$FX/o" | grep -c .)" = 1 ] && grep -q 'release: ship v9.9.9: build, sign and notarize it' "$FX/o" && pass "  ship asks once, its own question" || fail "  ship's questions: $(grep -o 'Type the tag' "$FX/o" | grep -c .)"
# r18b F2 (PLAN-ship.md REV 12c rule 31): release.sh's stdout a pipe (to cat) or a file, inside the pty
# (stdin and /dev/tty the terminal): npm 9.6.7, 10.9.2 and 11.6.0 offer the browser login and the
# upload's approval only when stdin and stdout are both terminals, so ship and publish-npm refuse (exit 4)
# before they ask, and say why. Controls: the rows above (stdout the pty: they ask), and publish (no npm)
# with its stdout a pipe: it asks still
tp() { # label pipe|file want-rc want-prompt want-text args...
  l=$1 how=$2 want=$3 asks=$4 txt=$5; shift 5; rm -f "$FX/rc" "$FX/rc.so"
  case $how in
    pipe) set -- sh -c '{ sh scripts/release.sh "$@"; echo $? > "$0"; } | cat' "$FX/rc" "$@" ;;
    file) set -- sh -c 'sh scripts/release.sh "$@" > "$0.so"; echo $? > "$0"' "$FX/rc" "$@" ;;
  esac
  (cd "$REPO" && env -i PATH=/usr/bin:/bin HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    script -q /dev/null "$@" < /dev/null) > "$FX/o" 2>&1
  rc=$(cat "$FX/rc" 2>/dev/null); cat "$FX/rc.so" >> "$FX/o" 2>/dev/null
  p=no; grep -q 'Type the tag' "$FX/o" && p=yes
  if [ "$rc" = "$want" ] && [ "$p" = "$asks" ] && grep -qF "$txt" "$FX/o" && ! grep -q 'release: building' "$FX/o"; then pass "$l"
  else fail "$l: rc=$rc (want $want), prompt=$p (want $asks): $(tr '\r\n' '  ' < "$FX/o" | cut -c1-240)"; fi
}
SO="needs a terminal on its stdout too"
tp "r18b F2: ship with its stdout a pipe: refused before the question" pipe 4 no "release: refused: ship $SO" ship v9.9.9
tp "r18b F2: ship with its stdout a file: refused before the question" file 4 no "release: refused: ship $SO" ship v9.9.9
tp "r18b F2: publish-npm with its stdout a pipe: refused before the question" pipe 4 no "release: refused: publish-npm $SO" publish-npm v9.9.9
tp "r18b F2: publish-npm with its stdout a file: refused before the question" file 4 no "release: refused: publish-npm $SO" publish-npm v9.9.9
tp "r18b F2: ship's refusal says where the next steps go after a stop" pipe 4 no "After a stop, ship writes what to run next into" ship v9.9.9
tp "  control: publish (no npm) with its stdout a pipe asks for the tag" pipe 4 yes "Type the tag" publish v9.9.9
rm -f "$FX/rc" "$FX/rc.so"
finish
