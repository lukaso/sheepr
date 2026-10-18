#!/bin/sh
# PHASE3.md §1.2: `release.sh verify vTAG` works out the three facts of a release from its archive,
# never from the manifest: the bundle meets the release requirement, the staple ticket validates,
# and spctl accepts it — with the real tools by absolute path (scripts/lib/realtools.sh), so a
# shim on PATH cannot answer. Here: an unsigned build's archive is refused (by codesign), also
# with a lying codesign, xcrun and spctl first on PATH. (The rc leg adds: rc.1 accepted; the
# --no-notarize control refused by stapler and spctl.)
set -u
. "$(dirname "$0")/lib.sh"
[ "$(uname -s)" = Darwin ] || { echo "SKIP (macOS only)"; exit 0; }
fx_dir; fx_repo
fx_release 0.1.0 1 v0.1.0
# an output directory as the unsigned build makes it, but named as the signed one
D=$FX/out/v0.1.0; mkdir -p "$D"
printf 'int main(){return 0;}\n' > "$FX/m.c"; cc -o "$FX/bin" "$FX/m.c" || exit 3
app=$("$SR_ROOT/scripts/bundle.sh" "$FX/bin" "$FX/b" 0.1.0 1) || exit 3
"$SR_ROOT/scripts/lib/archive.sh" make "$app" "$D/sheepr-macos-universal.tar.gz" || exit 3
v() { (cd "$REPO" && env HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$@" sh scripts/release.sh verify --out "$FX/out" v0.1.0) > "$FX/o" 2>&1; }
v env; rc=$?
[ $rc = 1 ] && grep -q 'codesign' "$FX/o" && pass "an unsigned archive: refused, by codesign" || fail "unsigned: rc=$rc $(tail -1 "$FX/o")"
mkdir -p "$FX/liar"
for t in codesign xcrun spctl; do printf '#!/bin/sh\necho "valid on disk"\nexit 0\n' > "$FX/liar/$t"; chmod +x "$FX/liar/$t"; done
v env PATH="$FX/liar:$PATH"; rc=$?
[ $rc = 1 ] && grep -q 'codesign' "$FX/o" && pass "with lying codesign, xcrun and spctl on PATH: still refused, by codesign" || fail "liars: rc=$rc $(tail -1 "$FX/o")"
v env DEVELOPER_DIR="$FX/liar-dev"; rc=$?
[ $rc = 1 ] && pass "with a DEVELOPER_DIR set: still refused" || fail "DEVELOPER_DIR: rc=$rc"
# the bundle verify judges is the archive's own: with a lying `tar` first on PATH that unpacks a
# plain bundle, an archive holding a control build is still refused as one (the system's tar)
mkdir -p "$FX/mk" "$FX/liar-tar" && cp -R "$app" "$FX/mk/" && /usr/bin/plutil -insert SheeprControlBuild -bool true "$FX/mk/Sheepr.app/Contents/Info.plist" || exit 3
cp "$D/sheepr-macos-universal.tar.gz" "$FX/plain.tar.gz" && "$SR_ROOT/scripts/lib/archive.sh" make "$FX/mk/Sheepr.app" "$D/sheepr-macos-universal.tar.gz" || exit 3
printf '#!/bin/sh\nd=""; while [ $# -gt 0 ]; do [ "$1" = -C ] && d=$2; shift; done\nexec /usr/bin/tar -xzf "%s" -C "$d"\n' "$FX/plain.tar.gz" > "$FX/liar-tar/tar"; chmod 755 "$FX/liar-tar/tar"
v env PATH="$FX/liar-tar:$PATH"; rc=$?
[ $rc = 1 ] && grep -q 'the archive holds a control build' "$FX/o" && pass "a lying tar on PATH: the archive's control build is still refused as one" || fail "lying tar: rc=$rc $(tail -1 "$FX/o")"
cp "$FX/plain.tar.gz" "$D/sheepr-macos-universal.tar.gz"
# the staple check itself, with a lying `env` first on PATH (it would say yes to anything): the
# real tool still answers (no staple ticket on a plain directory)
mkdir -p "$FX/liar-env" "$FX/plain"; printf '#!/bin/sh\nexit 0\n' > "$FX/liar-env/env"; chmod 755 "$FX/liar-env/env"
[ "$(PATH="$FX/liar-env:$PATH" sh -c 'command -v env')" = "$FX/liar-env/env" ] || fail "premise: the lying env is not first on PATH"
r=$(PATH="$FX/liar-env:$PATH" sh -c '. "$1/scripts/release.conf"; . "$1/scripts/lib/realtools.sh"; rt_staple_ok "$2"; echo $?' sh "$SR_ROOT" "$FX/plain")
[ "$r" != 0 ] && [ -n "$r" ] && pass "rt_staple_ok with a lying env on PATH: still refuses (rc $r)" || fail "rt_staple_ok with a lying env: rc '$r'"
# a control build's bundle (the control marker) is never a release: refused before any real tool
mkdir -p "$FX/mk" && cp -R "$app" "$FX/mk/" && /usr/bin/plutil -insert SheeprControlBuild -bool true "$FX/mk/Sheepr.app/Contents/Info.plist" || exit 3
"$SR_ROOT/scripts/lib/archive.sh" make "$FX/mk/Sheepr.app" "$D/sheepr-macos-universal.tar.gz.m" || exit 3
mv "$D/sheepr-macos-universal.tar.gz" "$D/u.tgz" && mv "$D/sheepr-macos-universal.tar.gz.m" "$D/sheepr-macos-universal.tar.gz"
v env; rc=$?
[ $rc = 1 ] && grep -q 'a control build' "$FX/o" && ! grep -q codesign "$FX/o" && pass "a control build's archive (the marker): refused before any real-tool check" || fail "marked: rc=$rc $(tail -1 "$FX/o")"
mv "$D/u.tgz" "$D/sheepr-macos-universal.tar.gz"
# r12b F1: the content class only for a defect in the bytes. The real verify, as ship's C3 subshell
# runs it (__class-verify prints the class it left). A tool that cannot run, or a write that fails
# for room, leaves fix; codesign's verdict, a truncated archive and a tool that judges, content
vc() { (cd "$REPO" && env HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 sh scripts/release.sh __class-verify --out "$FX/out" v0.1.0) > "$FX/o" 2>&1; }
cls() { sed -n 's/^release: (class) //p' "$FX/o" | tail -1; }
vc; rc=$?
[ $rc = 1 ] && [ "$(cls)" = content ] && grep -q codesign "$FX/o" && pass "control: an unsigned archive (codesign's verdict): class content" || fail "unsigned class: rc=$rc '$(cls)' $(tail -1 "$FX/o")"
# a full temp dir: the archive's private copy fits, the bundle's unpack does not (ulimit -f, in blocks
# of 512 bytes: the copy fits, the 16 KB executable does not)
lim=$(( $(wc -c < "$D/sheepr-macos-universal.tar.gz") / 512 + 2 ))
[ $(( lim * 512 )) -lt "$(wc -c < "$FX/bin")" ] || fail "premise: the executable fits in $lim blocks (the row would prove nothing)"
(ulimit -f "$lim"; vc); rc=$?
[ $rc = 1 ] && [ "$(cls)" = fix ] && grep -q 'cannot unpack' "$FX/o" && pass "r12b F1: verify's unpack into a full temp dir (ulimit -f $lim): class fix" || fail "full temp dir: rc=$rc '$(cls)' $(grep release: "$FX/o" | tail -2 | tr '\n' '|')"
cp "$D/sheepr-macos-universal.tar.gz" "$FX/whole.tgz" && head -c 600 "$FX/whole.tgz" > "$D/sheepr-macos-universal.tar.gz" || exit 3
vc; rc=$?
[ $rc = 1 ] && [ "$(cls)" = content ] && pass "  control: a truncated archive: class content" || fail "  truncated: rc=$rc '$(cls)' $(tail -1 "$FX/o")"
cp "$FX/whole.tgz" "$D/sheepr-macos-universal.tar.gz" || exit 3
# an Apple tool that cannot run: codesign's path in the fixture's realtools.sh replaced by a stand-in
# (exit 127; an Xcode license text, exit 69; exit 1 with no output), then one that judges (exit 3, words)
cp "$REPO/scripts/lib/realtools.sh" "$FX/rt.real" || exit 3
for t_ in '127|' '69|You have not agreed to the Xcode license agreements.' '1|' '3|test-requirement: code failed to satisfy specified code requirement(s)'; do
  printf '#!/bin/sh\n[ -z "%s" ] || echo "%s" >&2\nexit %s\n' "${t_#*|}" "${t_#*|}" "${t_%%|*}" > "$FX/cs"; chmod +x "$FX/cs"
  sed "s#/usr/bin/codesign#$FX/cs#" "$FX/rt.real" > "$REPO/scripts/lib/realtools.sh"
  grep -q "$FX/cs" "$REPO/scripts/lib/realtools.sh" || fail "premise: codesign's path not replaced"
  vc; rc=$?; w_=fix; [ "${t_%%|*}" = 3 ] && w_=content
  [ $rc = 1 ] && [ "$(cls)" = $w_ ] && grep -q 'codesign' "$FX/o" \
    && pass "$( [ $w_ = content ] && echo '  control: ')an Apple tool that $( [ $w_ = content ] && echo 'judges' || echo 'cannot run or gives no verdict') (exit ${t_%%|*}$( [ -n "${t_#*|}" ] && echo ', words' || echo ', no output')): class $w_" \
    || fail "codesign stand-in ${t_%%|*}: rc=$rc '$(cls)' $(tail -1 "$FX/o")"
done
cp "$FX/rt.real" "$REPO/scripts/lib/realtools.sh" || exit 3
# rt_judge itself: 0 accepts, 1 judged (an exit that is not 126 or 127, words that name no license),
# 2 no verdict
mkdir -p "$FX/rj"; o_=""
for t_ in '0||0' '127||2' '126||2' '69|You have not agreed to the Xcode license agreements|2' '1||2' '3|rejected|1' '65|does not have a ticket stapled to it|1' '1|code failed|2' '3|xcrun: error: unable to find utility|2' '137|Processing: x|2'; do
  c_=${t_%%|*}; w_=${t_##*|}; m_=${t_#*|}; m_=${m_%|*}
  printf '#!/bin/sh\n[ -z "%s" ] || echo "%s"\nexit %s\n' "$m_" "$m_" "$c_" > "$FX/rj/t"; chmod +x "$FX/rj/t"
  g_=$(sh -c '. "$1/scripts/lib/realtools.sh"; RT_OUT=$2/out; rt_judge "3 65" "$2/t" x; echo $?' sh "$SR_ROOT" "$FX/rj")
  [ "$g_" = "$w_" ] || o_="$o_ exit $c_ '$m_': $g_ (want $w_);"
done
[ -z "$o_" ] && pass "rt_judge (the refusal codes 3 and 65): accepts 0; judged 1 for its own refusal exit with words; no verdict 2 for 126, 127, a license text, no output, any other exit" || fail "rt_judge:$o_"
g_=$(sh -c '. "$1/scripts/lib/realtools.sh"; RT_OUT=""; rt_judge "3 65" "$2/t" x; echo $?' sh "$SR_ROOT" "$FX/rj")
[ "$g_" = 2 ] && pass "  with no RT_OUT (its words not kept): no verdict, never a judgment" || fail "  no RT_OUT: $g_"
# r13b F1, F2, F5: a verdict only from the tool's own refusal (codesign 1 or 3, spctl 3, stapler 65:
# notes/r13b/probe/apple/*.out); anything else (an exit above 125, xcrun's own error, a license text) is
# no verdict: class fix, and the cause says the tool gave none, with its words, never the fixed
# verdict sentence. The fixture's realtools.sh points codesign, xcrun and spctl at stand-ins that accept
cp "$REPO/scripts/lib/realtools.sh" "$FX/rt.real0" || exit 3
mkt() { # NAME RC WORDS [SIG]: a stand-in tool $FX/t_NAME: its arguments to $FX/a_NAME, WORDS on stderr, then exit RC, or SIG to itself
  printf '%s' "$3" > "$FX/w_$1"; rm -f "$FX/a_$1"
  printf '#!/bin/sh\necho "$*" > "%s"\n[ -s "%s" ] && { cat "%s" >&2; echo >&2; }\n%s\nexit %s\n' "$FX/a_$1" "$FX/w_$1" "$FX/w_$1" "$( [ -n "${4:-}" ] && echo "kill -$4 \$\$; /bin/sleep 1")" "$2" > "$FX/t_$1"; chmod +x "$FX/t_$1"
}
rtset() { sed -e "s#/usr/bin/codesign#${1:-$FX/t_cs}#" -e "s#/usr/bin/xcrun#$FX/t_xc#" -e "s#/usr/sbin/spctl#$FX/t_sp#" "$FX/rt.real0" > "$REPO/scripts/lib/realtools.sh"; }
AP=$FX/b/Sheepr.app
for t_ in "xc|1|xcrun: error: missing DEVELOPER_DIR path: /nonexistent||fix|stapler gave no verdict" \
          "xc|1|xcrun: error: sh -c '/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -find stapler 2> /dev/null' failed with exit code 17664: (null) (errno=Undefined error: 0)
xcrun: error: unable to find utility \"stapler\", not a developer tool or in PATH||fix|unable to find utility" \
          "xc|72|xcrun: error: unable to find utility \"stapler\", not a developer tool or in PATH||fix|stapler gave no verdict" \
          "xc|0|Processing: $AP|KILL|fix|exit 137" \
          "xc|0|Processing: $AP|TERM|fix|exit 143" \
          "xc|69|You have not agreed to the Xcode license agreements. Please run 'sudo xcodebuild -license' from within a Terminal window to review and agree to the Xcode and Apple SDKs license.||fix|license" \
          "cs|missing|||fix|No such file or directory" \
          "cs|noexec|||fix|ermission denied" \
          "xc|65|Processing: $AP
Sheepr.app does not have a ticket stapled to it.||content|does not have a ticket stapled" \
          "cs|3|test-requirement: code failed to satisfy specified code requirement(s)||content|failed to satisfy" \
          "cs|1|$AP: code has no resources but signature indicates they must be present||content|no resources but signature" \
          "xc|68|Processing: $AP
error is Error Domain=NSPOSIXErrorDomain Code=1 \"Operation not permitted\"
The validate action failed! Error 68.||fix|stapler gave no verdict on the bundle (exit 68" \
          "sp|1|$AP: invalid API object reference||fix|spctl gave no verdict on the bundle (exit 1" \
          "cs|2|$AP: invalid or unsupported format for signature||fix|codesign gave no verdict on the bundle (exit 2"; do
  tl_=${t_%%|*} rest_=${t_#*|}; rc_=${rest_%%|*} rest_=${rest_#*|}; wd_=${rest_%%|*} rest_=${rest_#*|}; sg_=${rest_%%|*} rest_=${rest_#*|}; want_=${rest_%%|*} has_=${rest_#*|}
  mkt cs 0 ''; mkt xc 0 ''; mkt sp 0 ''; cpath_=""
  case $rc_ in
    missing) cpath_=$FX/t_nonexistent; rm -f "$FX/t_nonexistent" ;;
    noexec) printf '#!/bin/sh\nexit 0\n' > "$FX/t_noexec"; chmod 644 "$FX/t_noexec"; cpath_=$FX/t_noexec ;;
    *) mkt "$tl_" "$rc_" "$wd_" "$sg_" ;;
  esac
  rtset "$cpath_"; vc; rc=$?
  [ $rc = 1 ] && [ "$(cls)" = "$want_" ] && grep -qF -- "$has_" "$FX/o" && { [ "$want_" = content ] || ! grep -q -e 'no valid staple ticket' -e 'does not meet the release requirement' -e 'Gatekeeper rejects' "$FX/o"; } \
    && pass "$( [ "$want_" = content ] && echo '  control: ')r13b: $tl_ $( [ -n "$sg_" ] && echo "stopped by $sg_" || echo "exit $rc_")$( [ -n "$wd_" ] && printf ' (%s)' "$(printf '%s' "$wd_" | head -1 | cut -c1-50)"): class $want_; the cause holds '$has_'" \
    || fail "r13b $tl_ $rc_ $sg_: rc=$rc '$(cls)' cause: $(grep '^release: ' "$FX/o" | grep -v '(class)' | tail -1 | cut -c1-250)"
done
# REV 11a rule 11 (r14b P3-1): spctl runs with -vv (its source= line in its words). Its refusal (exit 3)
# of a bundle that codesign's release requirement and stapler accepted (they are checked first) is
# class fix, with spctl's words in the cause: a rebuild cannot change it. Control: codesign refuses
# first (exit 3), and spctl would refuse too ("source=no usable signature"): content, codesign's
# verdict, spctl not run (the order of the checks decides, not spctl's words)
mkt cs 0 ''; mkt xc 0 ''; mkt sp 3 "$AP: rejected
source=Notarized Developer ID"; rtset; vc; rc=$?
[ $rc = 1 ] && [ "$(cls)" = fix ] && grep -qF 'source=Notarized Developer ID' "$FX/o" && grep -q 'Gatekeeper rejects' "$FX/o" && grep -q '^-a -vv -t exec ' "$FX/a_sp" \
  && pass "REV 11a rule 11: spctl -a -vv refusing (exit 3) a bundle codesign and stapler accepted: class fix, its words (source=) in the cause" \
  || fail "rule 11: rc=$rc '$(cls)' spctl got '$(cat "$FX/a_sp" 2>/dev/null)'; $(grep '^release: ' "$FX/o" | grep -v '(class)' | tail -1 | cut -c1-250)"
mkt cs 3 'test-requirement: code failed to satisfy specified code requirement(s)'; mkt xc 0 ''; mkt sp 3 "$AP: rejected
source=no usable signature"; rtset; vc; rc=$?
[ $rc = 1 ] && [ "$(cls)" = content ] && grep -q 'failed to satisfy' "$FX/o" && ! grep -q 'source=' "$FX/o" && [ ! -e "$FX/a_sp" ] \
  && pass "  control: codesign refuses first (spctl would say 'source=no usable signature'): content, codesign's verdict, spctl not run" \
  || fail "  rule 11 control: rc=$rc '$(cls)' $(grep '^release: ' "$FX/o" | grep -v '(class)' | tail -1 | cut -c1-250)"
# r15b P4-1: the order of the checks decides the class: stapler (it refuses, exit 65) runs before spctl,
# so its verdict is content, with its words, and spctl does not run (it would refuse too, exit 3).
# Control: rule 11's row above (stapler accepts: spctl runs, fix)
mkt cs 0 ''; mkt xc 65 "Processing: $AP
Sheepr.app does not have a ticket stapled to it."; mkt sp 3 "$AP: rejected
source=Notarized Developer ID"; rtset; vc; rc=$?
[ $rc = 1 ] && [ "$(cls)" = content ] && grep -q 'does not have a ticket stapled' "$FX/o" && [ ! -e "$FX/a_sp" ] && ! grep -q 'Gatekeeper rejects' "$FX/o" \
  && pass "r15b P4-1: stapler refuses (65), spctl would too (3): content, stapler's words, spctl not run (the order of the checks decides)" \
  || fail "r15b P4-1 order: rc=$rc '$(cls)' spctl ran: $( [ -e "$FX/a_sp" ] && echo yes || echo no); $(grep '^release: ' "$FX/o" | grep -v '(class)' | tail -1 | cut -c1-200)"
# gkrun FILE ARCHIVE: the two Gatekeeper lines of a spctl stop (FILE) run as printed, from / in sh and
# in an interactive zsh -f, with a stub spctl first on PATH and TMPDIR under $FX (the line's mktemp names
# TMPDIR: macOS's mktemp -d with no template ignores it): `spctl --status`, and
# the line that unpacks ARCHIVE into a new temp dir and asks spctl about the bundle there (the stub
# records whether that bundle is a directory). 0 when both gave exactly that
gkrun() {
  mkdir -p "$FX/spb" "$FX/gk" || return 1
  printf '#!/bin/sh\n{ printf "spctl"; for a; do printf " [%%s]" "$a"; done; [ $# = 5 ] && { [ -d "$5" ] && printf " bundle=yes" || printf " bundle=no"; }; printf "\\n"; } >> "$REC"\n' > "$FX/spb/spctl"; chmod +x "$FX/spb/spctl"
  l1_=$(grep -x '  spctl --status' "$1"); l2_=$(grep -x "  d=\$(mktemp -d \"\${TMPDIR:-/tmp}/sheepr-gatekeeper.XXXXXX\") && tar -xzf '$2' -C \"\$d\" && spctl -a -vv -t exec \"\$d/[a-zA-Z/.]*\"" "$1")
  [ -n "$l1_" ] && [ -n "$l2_" ] || return 1
  g_=0
  for how_ in sh zsh; do
    for l_ in "$l1_" "$l2_"; do
      REC=$FX/gk.rec; : > "$REC"
      if [ $how_ = sh ]; then (cd / && env -i PATH="$FX/spb:/usr/bin:/bin" TMPDIR="$FX/gk" REC="$REC" /bin/sh -c "$l_") > /dev/null 2>&1
      else (cd / && printf '%s\n' "$l_" | env -i PATH="$FX/spb:/usr/bin:/bin" HOME="$FX" TMPDIR="$FX/gk" REC="$REC" /bin/zsh -f -i) > /dev/null 2>&1; fi
      case $l_ in
        *--status) [ "$(cat "$REC")" = "spctl [--status]" ] || g_=1 ;;
        *) case $(cat "$REC") in "spctl [-a] [-vv] [-t] [exec] [$FX/gk/sheepr-gatekeeper."*"/Sheepr.app] bundle=yes") ;; *) g_=1 ;; esac ;;
      esac
    done
  done
  rm -rf "${FX:?}/gk" "${FX:?}/gk.rec"; return $g_
}
# REV 11b rule 16 (r15b P4-7): the spctl stop names no "cannot change": a rerun stops here again until
# Gatekeeper accepts the bundle; what to check, each on a line of its own, run as printed; the signing
# certificate's remedy (move the build aside, rebuild with a valid one). The class stays fix
mkt cs 0 ''; mkt xc 0 ''; mkt sp 3 "$AP: rejected
source=Notarized Developer ID"; rtset; vc; rc=$?
[ $rc = 1 ] && [ "$(cls)" = fix ] && ! grep -qi 'cannot change' "$FX/o" && grep -q '^A rerun stops here again until Gatekeeper accepts the bundle' "$FX/o" \
  && grep -q '^When the cause is the signing certificate (revoked or expired), move the build aside and rebuild it with a valid one.$' "$FX/o" \
  && gkrun "$FX/o" "$D/sheepr-macos-universal.tar.gz" \
  && pass "REV 11b rule 16: the spctl stop: no 'cannot change'; a rerun stops here again; spctl --status and spctl -a -vv on the bundle, each a line that runs as printed; the certificate's remedy; class fix" \
  || fail "rule 16: rc=$rc '$(cls)'; $(grep -e 'cannot change' -e 'spctl' "$FX/o" | grep -v '(class)' | tr '\n' '|' | cut -c1-300)"
cp "$FX/rt.real0" "$REPO/scripts/lib/realtools.sh" || exit 3
# the census: every rt_* call in release.sh hands its status to rtfail (content only for a verdict)
n_rt=$(grep -v '^ *#' "$SR_ROOT/scripts/release.sh" | grep -cE 'rt_(meets|staple_ok|spctl_ok) "')
n_ok=$(grep -v '^ *#' "$SR_ROOT/scripts/release.sh" | grep -E 'rt_(meets|staple_ok|spctl_ok) "' | grep -cE '\|\| rtfail \$\? (codesign|stapler|spctl) "')
[ "$n_rt" -ge 6 ] && [ "$n_rt" = "$n_ok" ] && pass "every Apple tool call in release.sh ($n_rt lines) hands its status to rtfail" || fail "rt_* calls: $n_rt lines, $n_ok through rtfail"
n_sp=$(grep -v '^ *#' "$SR_ROOT/scripts/release.sh" | grep -cE 'rt_spctl_ok "')
n_spf=$(grep -v '^ *#' "$SR_ROOT/scripts/release.sh" | grep -E 'rt_spctl_ok "' | grep -cE '\|\| rtfail \$\? spctl "[^"]*" fix( |$)')
n_xf=$(grep -v '^ *#' "$SR_ROOT/scripts/release.sh" | grep -E 'rt_(meets|staple_ok) "' | grep -cE '" fix( |$)')
[ "$n_sp" -ge 2 ] && [ "$n_sp" = "$n_spf" ] && [ "$n_xf" = 0 ] && pass "  REV 11a rule 11: each spctl call ($n_sp lines: verify, npm-check) makes its refusal class fix; no codesign or stapler call does" \
  || fail "  spctl calls: $n_sp lines, $n_spf with class fix; $n_xf codesign or stapler calls with fix"
finish
