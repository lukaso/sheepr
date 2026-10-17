#!/bin/sh
# scripts/lib/notify.sh KEY TAG (the ship plan's notifications; PHASE3.md D2 step 3): the text comes
# from a fixed table by KEY, with the tag in it, and nothing else; osascript gets it after `--` (so a
# text can never be read as AppleScript); notify.sh always exits 0. Every call here runs in dry mode
# (SR_NOTIFY_OSASCRIPT names a recording stand-in) and inside the no-osascript wall (lib.sh), so no
# row can show a real notification. Checked:
#   - each key's text, and the exact osascript arguments: -e 'on run argv' -e 'display notification
#     (item 1 of argv) with title "sheepr release"' -e 'end run' -- TEXT;
#   - an unknown key, a bad phase in failed-PHASE, a bad or missing tag: nothing is run, exit 0;
#   - a failing osascript: exit 0 (the stand-in did run);
#   - SR_NOTIFY_OSASCRIPT is checked as release.sh's `standins` checks a stand-in: outside the
#     fixtures, a symlink, a binary, a file that cannot be run, a name with a control character, an
#     empty value: refused, nothing run;
#   - the text: the real mode runs /usr/bin/osascript and rings the bell on /dev/tty, and is chosen
#     only when SR_NOTIFY_OSASCRIPT is not set at all.
set -u
. "$(dirname "$0")/lib.sh"
[ "$(uname -s)" = Darwin ] || { echo "SKIP (macOS only)"; exit 0; }
fx_dir
N="$SR_ROOT/scripts/lib/notify.sh"
wall_ok && pass "the wall: a path naming osascript cannot run here, another can" || { fail "the no-osascript wall does not hold: nothing else runs"; finish; }
# the stand-in: one line per call, each argument in [ ]; exits with the code in osa.rc (0 if none)
cat > "$FX/osa" <<EOF
#!/bin/sh
for a; do printf '[%s]' "\$a"; done >> "$FX/rec"; echo >> "$FX/rec"
exit \$(cat "$FX/osa.rc" 2>/dev/null || echo 0)
EOF
chmod +x "$FX/osa"
nt() { # stand-in key tag [dir] -> rc in r, stderr in $FX/err
  rm -f "$FX/rec"
  no_osascript env SR_NOTIFY_OSASCRIPT="$1" sh "$N" "$2" "$3" ${4+"$4"} > /dev/null 2> "$FX/err"; r=$?
}
calls() { grep -c . "$FX/rec" 2>/dev/null || echo 0; }
T=v1.2.3
pre='[-e][on run argv][-e][display notification (item 1 of argv) with title "sheepr release"][-e][end run][--]'
for kv in \
  "password|$T: type the notary keychain password in the terminal" \
  "password-again|$T: Apple did not accept the submission. Type the notary keychain password again in the terminal, to fetch Apple's log" \
  "npm-login|$T: log in to npm in the browser (npm login)" \
  "npm-approve|$T: approve the npm upload in the browser (tick skip for 5 minutes)" \
  "npm-approve-again|$T: npm may ask again: approve the upload of the main package in the browser" \
  "npm-approve-next|$T: npm may ask again: approve the next npm upload in the browser" \
  "done|$T is public on GitHub, Homebrew and npm" \
  "logout-failed|$T: npm logout failed. Run cd / && npm logout --registry=https://registry.npmjs.org/ in the terminal" \
  "failed-push|$T stopped at push. What to run next is in $T.ship-next.txt" \
  "failed-npm-platform|$T stopped at npm-platform. What to run next is in $T.ship-next.txt" \
  "logout-failed-npm-main|$T stopped at npm-main, and npm logout failed. Run cd / && npm logout --registry=https://registry.npmjs.org/ in the terminal; what to run next is in $T.ship-next.txt"; do
  k=${kv%%|*} want=${kv#*|}
  nt "$FX/osa" "$k" "$T"
  [ $r = 0 ] && [ "$(calls)" = 1 ] && [ "$(cat "$FX/rec")" = "$pre[$want]" ] && pass "$k: the table's text, after --" || fail "$k: rc=$r got '$(cat "$FX/rec" 2>/dev/null)'"
done
nt "$FX/osa" failed-abcdefghijabcdefghijabcdefghijab "$T"   # a phase of exactly 32 characters
[ $r = 0 ] && [ "$(cat "$FX/rec" 2>/dev/null)" = "$pre[$T stopped at abcdefghijabcdefghijabcdefghijab. What to run next is in $T.ship-next.txt]" ] \
  && pass "a phase of exactly 32 characters: accepted" || fail "32-character phase: rc=$r $(cat "$FX/err")"
nt "$FX/osa" logout-failed-abcdefghijabcdefghijabcdefghijab "$T"
[ $r = 0 ] && [ "$(cat "$FX/rec" 2>/dev/null)" = "$pre[$T stopped at abcdefghijabcdefghijabcdefghijab, and npm logout failed. Run cd / && npm logout --registry=https://registry.npmjs.org/ in the terminal; what to run next is in $T.ship-next.txt]" ] \
  && pass "logout-failed-PHASE: a phase of exactly 32 characters accepted" || fail "logout-failed 32-character phase: rc=$r $(cat "$FX/err")"
# with the out dir (release.sh gives it to failed-PHASE and logout-failed-PHASE): the next file's full
# path, so the notification names a file that opens from any window; a dir that is not absolute, or
# holds a control character, is not used: the text names the next file by its name, and the one
# notification is still shown (r12b F7: a refused dir showed nothing, so a stop went unseen)
nt "$FX/osa" failed-push "$T" "/Users/o p/sheepr-release"
[ $r = 0 ] && [ "$(cat "$FX/rec" 2>/dev/null)" = "$pre[$T stopped at push. What to run next is in /Users/o p/sheepr-release/$T.ship-next.txt]" ] \
  && pass "failed-PHASE with the out dir: the next file's full path" || fail "failed-push with dir: rc=$r '$(cat "$FX/rec" 2>/dev/null)' $(cat "$FX/err")"
nt "$FX/osa" logout-failed-npm-main "$T" "/Users/o/sheepr-release"
[ $r = 0 ] && [ "$(cat "$FX/rec" 2>/dev/null)" = "$pre[$T stopped at npm-main, and npm logout failed. Run cd / && npm logout --registry=https://registry.npmjs.org/ in the terminal; what to run next is in /Users/o/sheepr-release/$T.ship-next.txt]" ] \
  && pass "logout-failed-PHASE with the out dir: the next file's full path" || fail "logout-failed with dir: rc=$r '$(cat "$FX/rec" 2>/dev/null)'"
for d in 'sheepr-release' "/Users/o/a$(printf '\001')b"; do
  nt "$FX/osa" failed-push "$T" "$d"
  [ $r = 0 ] && [ "$(calls)" = 1 ] && [ "$(cat "$FX/rec" 2>/dev/null)" = "$pre[$T stopped at push. What to run next is in $T.ship-next.txt]" ] && grep -q 'by its name only' "$FX/err" \
    && pass "an out dir that is not absolute, or holds a control character: the next file by its name, the one notification shown, stderr says why" || fail "bad dir: rc=$r calls=$(calls) '$(cat "$FX/rec" 2>/dev/null)' $(cat "$FX/err")"
done
nt "$FX/osa" password v0.1.4-rc.2
[ "$(cat "$FX/rec" 2>/dev/null)" = "$pre[v0.1.4-rc.2: type the notary keychain password in the terminal]" ] && pass "an rc tag is a tag" || fail "rc tag: rc=$r $(cat "$FX/err")"
# only table texts: an unknown key, a bad phase, a bad or missing tag run nothing
for k in hello password2 PASSWORD failed- failed-Push "failed-a b" 'failed-$(id)' failed-1a "failed-$(printf 'a\nb')" failed-abcdefghijabcdefghijabcdefghijabc "" \
    logout-failed- logout-failed-Push "logout-failed-a b" logout-failed-1a logout-failed-abcdefghijabcdefghijabcdefghijabc logout-failedx; do
  nt "$FX/osa" "$k" "$T"; l=$(printf '%s' "$k" | tr '\n' '~')   # (a newline shown as ~)
  [ $r = 0 ] && [ "$(calls)" = 0 ] && grep -q 'notify: ' "$FX/err" && pass "key '$l': nothing run, exit 0, said so" || fail "key '$l': rc=$r calls=$(calls)"
done
for t in v1.2 1.2.3 "v1.2.3 " v01.2.3 v1.2.3-rc.0 "$(printf 'v1.2.3\nv1.2.4')" '$(id)' ""; do
  nt "$FX/osa" password "$t"; l=$(printf '%s' "$t" | tr '\n' '~')
  [ $r = 0 ] && [ "$(calls)" = 0 ] && grep -q 'notify: ' "$FX/err" && pass "tag '$l': nothing run, exit 0, said so" || fail "tag '$l': rc=$r calls=$(calls)"
done
rm -f "$FX/rec"; no_osascript env SR_NOTIFY_OSASCRIPT="$FX/osa" sh "$N" > /dev/null 2> "$FX/err"; r=$?
[ $r = 0 ] && [ "$(calls)" = 0 ] && pass "no arguments: nothing run, exit 0" || fail "no arguments: rc=$r calls=$(calls)"
# a failing osascript: still exit 0 (the control: it was called)
echo 1 > "$FX/osa.rc"; nt "$FX/osa" done "$T"; rm -f "$FX/osa.rc"
[ $r = 0 ] && [ "$(calls)" = 1 ] && grep -q 'exit 1' "$FX/err" && pass "osascript fails: exit 0, the failure said" || fail "osascript failing: rc=$r calls=$(calls) $(cat "$FX/err")"

# SR_NOTIFY_OSASCRIPT, checked as a stand-in: each refused, nothing run
OUT=$(mktemp -d /private/tmp/sr-notify-out.XXXXXX) || exit 3
trap 'rm -rf "$FX" "${OUT:?}"' EXIT
printf '#!/bin/sh\necho "$0" >> "%s/ran"\n' "$OUT" > "$OUT/osa"; chmod +x "$OUT/osa"
ln -s "$FX/osa" "$FX/osa-link"
printf '#include <stdio.h>\nint main(void){FILE*f=fopen("%s/ran","a");if(f){fputs("binary\\n",f);fclose(f);}return 0;}\n' "$OUT" > "$FX/b.c" && cc -o "$FX/osa-bin" "$FX/b.c" || exit 3
cp "$FX/osa" "$FX/osa-noexec"; chmod 644 "$FX/osa-noexec"
nl=$(printf '%s/osa-nl\n_' "$FX"); nl=${nl%_}   # a name ending in a newline: a script that records
printf '#!/bin/sh\necho "$0" >> "%s/ran"\n' "$OUT" > "$nl"; chmod +x "$nl"
printf '#!/bin/sh\necho "$0" >> "%s/ran"\n' "$OUT" > "$FX/osa-nl"; chmod +x "$FX/osa-nl"   # the name without it
for spec in "outside the fixtures|$OUT/osa|fixtures" "a symlink|$FX/osa-link|symlink" "a binary|$FX/osa-bin|script" \
    "a file that cannot be run|$FX/osa-noexec|executable" "a name ending in a newline|$nl|control character" "empty||executable"; do
  l=${spec%%|*} rest=${spec#*|}; p=${rest%|*} why=${rest##*|}
  rm -f "$OUT/ran"; nt "$p" done "$T"
  [ $r = 0 ] && [ "$(calls)" = 0 ] && [ ! -e "$OUT/ran" ] && grep -q "refused.*$why" "$FX/err" \
    && pass "SR_NOTIFY_OSASCRIPT $l: refused ($why), nothing run, exit 0" || fail "SR_NOTIFY_OSASCRIPT $l: rc=$r calls=$(calls) ran=$(cat "$OUT/ran" 2>/dev/null | tr '\n' ' ') $(cat "$FX/err")"
done

# notify.sh's stand-in check is release.sh's `standins` check, line for line (two copies; this row
# keeps them one): the five checks from the control-character one to the `#!` one, the message verb
# and the variable name normalized; and each builds the run path from the checked one
checks5() { # file -> its stand-in check lines, normalized
  awk '/case \$p in \*\[\[:cntrl:\]\]\*\)/ { f = 1 } f { print } f && /head -c 2/ { exit }' "$1" \
    | sed -e 's/^[[:space:]]*//' -e 's/die "\$v/X "V/' -e 's/refuse "SR_NOTIFY_OSASCRIPT/X "V/'
}
a=$(checks5 "$SR_ROOT/scripts/release.sh"); b=$(checks5 "$N")
[ "$(printf '%s\n' "$a" | grep -c .)" = 5 ] && [ "$a" = "$b" ] && grep -qxF '    eval "$v=\$pd/\$(basename \"\$p\")"' "$SR_ROOT/scripts/release.sh" && grep -qxF '  osa=$pd/$(basename "$p") bell=no' "$N" \
  && pass "notify.sh's stand-in check is release.sh's standins check (5 lines), and both run the checked path" || fail "the two stand-in checks differ: release.sh: $(printf '%s' "$a" | tr '\n' '|') notify.sh: $(printf '%s' "$b" | tr '\n' '|')"
sed 's/ \[ ! -L "\$p" \] &&//' "$N" > "$FX/notify-nolink.sh"   # the control: a copy without the symlink check (never run)
[ "$(checks5 "$FX/notify-nolink.sh")" != "$a" ] && ! cmp -s "$N" "$FX/notify-nolink.sh" && pass "control: a copy without the symlink check differs" || fail "control: the copy without the symlink check compares equal"

# the text of the real mode (never run here): /usr/bin/osascript with the same arguments, the bell on
# /dev/tty, and the real mode only when SR_NOTIFY_OSASCRIPT is not set at all
grep -qxF '  osa=/usr/bin/osascript bell=yes' "$N" && pass "the real mode's osascript is /usr/bin/osascript" || fail "no 'osa=/usr/bin/osascript bell=yes' line"
[ "$(grep -c 'osascript' "$N")" -ge 1 ] && [ "$(grep -c '^ *"\$osa" ' "$N")" = 1 ] && grep -qF -- "\"\$osa\" -e 'on run argv' -e 'display notification (item 1 of argv) with title \"sheepr release\"' -e 'end run' -- \"\$text\"" "$N" \
  && pass "one osascript call, the text after --" || fail "the osascript call line"
grep -qF "{ printf '\\a' > /dev/tty; } 2>/dev/null" "$N" && pass "the real mode rings the bell on /dev/tty" || fail "no bell line"
grep -qF 'if [ "${SR_NOTIFY_OSASCRIPT+set}" = set ]; then' "$N" && pass "the dry mode is chosen when SR_NOTIFY_OSASCRIPT is set at all (an empty value too)" || fail "the mode choice"
finish
