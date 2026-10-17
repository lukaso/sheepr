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
for t_ in '0||0' '127||2' '126||2' '69|You have not agreed to the Xcode license agreements|2' '1||2' '3|rejected|1' '65|does not have a ticket stapled to it|1'; do
  c_=${t_%%|*}; w_=${t_##*|}; m_=${t_#*|}; m_=${m_%|*}
  printf '#!/bin/sh\n[ -z "%s" ] || echo "%s"\nexit %s\n' "$m_" "$m_" "$c_" > "$FX/rj/t"; chmod +x "$FX/rj/t"
  g_=$(sh -c '. "$1/scripts/lib/realtools.sh"; RT_OUT=$2/out; rt_judge "$2/t" x; echo $?' sh "$SR_ROOT" "$FX/rj")
  [ "$g_" = "$w_" ] || o_="$o_ exit $c_ '$m_': $g_ (want $w_);"
done
[ -z "$o_" ] && pass "rt_judge: accepts 0; judged 1 for an exit with words; no verdict 2 for 126, 127, a license text, no output" || fail "rt_judge:$o_"
g_=$(sh -c '. "$1/scripts/lib/realtools.sh"; RT_OUT=""; rt_judge "$2/t" x; echo $?' sh "$SR_ROOT" "$FX/rj")
[ "$g_" = 2 ] && pass "  with no RT_OUT (its words not kept): no verdict, never a judgment" || fail "  no RT_OUT: $g_"
# the census: every rt_* call in release.sh hands its status to rtfail (content only for a verdict)
n_rt=$(grep -v '^ *#' "$SR_ROOT/scripts/release.sh" | grep -cE 'rt_(meets|staple_ok|spctl_ok) "')
n_ok=$(grep -v '^ *#' "$SR_ROOT/scripts/release.sh" | grep -E 'rt_(meets|staple_ok|spctl_ok) "' | grep -c '|| rtfail \$? "')
[ "$n_rt" -ge 6 ] && [ "$n_rt" = "$n_ok" ] && pass "every Apple tool call in release.sh ($n_rt lines) hands its status to rtfail" || fail "rt_* calls: $n_rt lines, $n_ok through rtfail"
finish
