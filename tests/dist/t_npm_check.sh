#!/bin/sh
# PHASE3.md §5 step 5: `release.sh npm-check vTAG` before any `npm publish`: the manifest is this
# tag's signed, non-control build; the release archive and the four .tgz files are there and each
# matches its manifest hash; the darwin package's bundle passes the real-tool checks, and the
# release archive's bundle meets the requirement and is byte-identical to it; the main package
# carries the tag's README, and every package links the repository. A refusal removes any earlier
# stamp (NPM-CHECKED: publish refuses without one; the rc leg checks a pass writes it). Refused (exit 1)
# here: an unsigned build, a control build, a tarball or a release archive whose hash is not the
# manifest's, a missing tarball, and an unsigned bundle in the darwin package (by codesign).
# (The rc leg adds, on real builds: rc.1 accepted; a tampered or another Developer ID archive
# refused; the control refused.)
set -u
. "$(dirname "$0")/lib.sh"
[ "$(uname -s)" = Darwin ] || { echo "SKIP (macOS only)"; exit 0; }
fx_dir; fx_repo
fx_release 0.1.0 1 v0.1.0
nv=0.1.0 D=$FX/out/v0.1.0
printf 'int main(){return 0;}\n' > "$FX/m.c"; cc -o "$FX/bin" "$FX/m.c" || exit 3
app=$("$SR_ROOT/scripts/bundle.sh" "$FX/bin" "$FX/b" 0.1.0 1) || exit 3
# the packages come from scripts/lib/npm-pack.sh (what the build runs), around a .dev bundle and
# two stand-in Linux binaries that are also in the output dir, as a build leaves them
mk() { # mode control
  rm -rf "$D"; mkdir -p "$D"
  "$SR_ROOT/scripts/lib/archive.sh" make "$app" "$D/sheepr-macos-universal.tar.gz" || exit 3
  printf '#!/bin/sh\necho aarch64\n' > "$D/sheepr-linux-aarch64"; printf '#!/bin/sh\necho x86_64\n' > "$D/sheepr-linux-x86_64"
  chmod 755 "$D/sheepr-linux-aarch64" "$D/sheepr-linux-x86_64"
  mkdir -p "$FX/tmp" && TMPDIR=$FX/tmp sh "$SR_ROOT/scripts/lib/npm-pack.sh" "$nv" "$D/sheepr-macos-universal.tar.gz" "$D/sheepr-linux-aarch64" "$D/sheepr-linux-x86_64" "$SR_ROOT/npm/sheepr/bin/sheepr" "$D" >/dev/null || exit 3   # (npm pack's temp dir under the fixture: RULES line 13)
  { printf '{\n  "v": 1,\n  "tag": "v0.1.0",\n  "commit": "%s",\n  "mode": "%s",\n  "control": %s,\n  "files": [\n' "$(g rev-parse 'v0.1.0^{commit}')" "$1" "$2"
    sep=""; for f in "$D"/sheepr-macos-universal.tar.gz "$D"/sheepr-linux-aarch64 "$D"/sheepr-linux-x86_64 "$D"/*.tgz; do printf '%s    {"name": "%s", "sha256": "%s"}' "$sep" "$(basename "$f")" "$(shasum -a 256 "$f" | cut -d' ' -f1)"; sep=",
"; done; printf '\n  ]\n}\n'; } > "$D/MANIFEST.json"
}
nc() { (cd "$REPO" && env HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 sh scripts/release.sh npm-check --out "$FX/out" v0.1.0) > "$FX/o" 2>&1; }
# a stamp that publish would accept (the tag and this manifest's sha256), as an earlier pass left it
stamp() { printf 'v0.1.0 %s\n' "$(shasum -a 256 "$D/MANIFEST.json" | cut -d' ' -f1)" > "$D/NPM-CHECKED"; }
mk unsigned false; stamp; nc; r=$?; [ $r = 1 ] && grep -q "mode" "$FX/o" && pass "an unsigned build: refused (its mode)" || fail "unsigned: rc=$r $(tail -1 "$FX/o")"
[ ! -e "$D/NPM-CHECKED" ] && pass "a refused npm-check removes an earlier stamp (refused at the first check)" || fail "a refused npm-check left the stamp"
mk signed true; nc; r=$?; [ $r = 1 ] && grep -q "control" "$FX/o" && pass "a control build: refused (the control flag)" || fail "control: rc=$r $(tail -1 "$FX/o")"
mk signed false; echo x >> "$D/sheepr-linux-x64-$nv.tgz"; nc; r=$?
[ $r = 1 ] && grep -q 'hash' "$FX/o" && pass "a tarball not matching its manifest hash: refused" || fail "hash: rc=$r $(tail -1 "$FX/o")"
mk signed false; echo x >> "$D/sheepr-macos-universal.tar.gz"; nc; r=$?
[ $r = 1 ] && grep -q 'sheepr-macos-universal.tar.gz does not match its manifest hash' "$FX/o" && pass "a release archive not matching its manifest hash: refused" || fail "archive hash: rc=$r $(tail -1 "$FX/o")"
mk signed false; rm "$D/sheepr-$nv.tgz"; nc; r=$?; [ $r = 1 ] && grep -q "missing" "$FX/o" && pass "a missing tarball: refused (named missing)" || fail "missing: rc=$r $(tail -1 "$FX/o")"
# each package read raw, as npm reads it (plain ustar entries only; every installed byte accounted
# for): each variant with its manifest hash updated, so the hash check passes, and each refused
# before any real-tool check
E="$SR_ROOT/tests/lib/tgz-edit.py"
DT=sheepr-darwin-universal-$nv.tgz MT=sheepr-$nv.tgz XT=sheepr-linux-x64-$nv.tgz
resum() { h=$(shasum -a 256 "$D/$1" | cut -d' ' -f1); sed "s/\(\"name\": \"$1\", \"sha256\": \"\)[0-9a-f]*/\1$h/" "$D/MANIFEST.json" > "$D/m.n" && mv "$D/m.n" "$D/MANIFEST.json"; }
P=package/Sheepr.app/Contents
for v in "DT|add|zzz/Sheepr.app/Contents/MacOS/sheepr|NOT THE RELEASE|outside package/" \
         "DT|add|$P/MacOS/._sheepr|x|AppleDouble" \
         "DT|symlink|$P/MacOS/link|sheepr|type '2'" \
         "DT|after-null|$P/Resources/marker.txt|x|after the end" \
         "DT|raw-append|$P/Resources/px|x,ustar00,-|type 'x'" \
         "DT|raw-append|$P/Resources/pg|g,ustar00,-|type 'g'" \
         "DT|raw-append|$P/Resources/ln|L,ustar00,-|type 'L'" \
         "DT|raw-append|$P/Resources/sp|S,ustar00,-|type 'S'" \
         "DT|raw-append|$P/Resources/gm|0,gnu,-|not a plain ustar header" \
         "DT|raw-append|Resources/pf|0,ustar00,package/Sheepr.app/Contents|a ustar prefix" \
         "DT|raw-append|$P/Resources/a b|0,ustar00,-|a name outside" \
         "DT|badsum|$P/Resources/bs|-|bad header checksum" \
         "DT|raw-append|$P/MacOS/SHEEPR|0,ustar00,-|appears twice (case ignored)" \
         "DT|replace|package/LICENSE-MIT|not the license|LICENSE-MIT differs from the repo" \
         "DT|json-set|package/package.json|scripts={\"postinstall\": \"echo hi\"}|package.json is not the one npm-pack.sh writes: .*\"scripts\"" \
         "MT|replace|package/bin/sheepr|#!/bin/sh|bin/sheepr differs from the repo's launcher" \
         "MT|replace|package/README.md|not the readme|README.md differs from the repo's" \
         "MT|remove|package/README.md|-|the files are" \
         "MT|json-set|package/package.json|optionalDependencies={\"sheepr-darwin-universal\": \"*\"}|optionalDependencies" \
         "XT|replace|package/bin/sheepr|#!/bin/sh|bin/sheepr differs from sheepr-linux-x86_64" \
         "MT|add|package/binding.gyp|{}|the files are" \
         "DT|add|package/.npmrc|x|the files are" \
         "XT|json-set|package/package.json|os=[\"darwin\"]|package.json is not" \
         "MT|replace|package/package.json|not json|package.json is not" \
         "MT|mode|package/bin/sheepr|644|bin/sheepr's mode is 644, not 755" \
         "DT|raw-append|$P/Resources/lk|0,ustar00,-,target|a link name" \
         "DT|raw-append|$P/Resources/tr/|0,ustar00,-|a file name ending in /" \
         "DT|noend|-|-|ends without an end block" \
         "DT|short|$P/Resources/sh|-|is cut short" \
         "MT|mode|package/bin/sheepr|4755|bin/sheepr's mode 4755 has setuid" \
         "XT|mode|package/bin/sheepr|6755|bin/sheepr's mode 6755 has setuid" \
         "DT|mode|package/LICENSE-MIT|4644|LICENSE-MIT's mode 4644 has setuid" \
         "MT|mode|package/package.json|666|package.json's mode is 666, not 644"; do
  k=${v%%|*} rest=${v#*|}; op=${rest%%|*} rest=${rest#*|}; nm=${rest%%|*} rest=${rest#*|}; arg=${rest%%|*} why=${rest#*|}
  eval "t=\$$k"
  mk signed false; python3 "$E" "$D/$t" "$FX/e.tgz" "$op" "$nm" "$arg" && mv "$FX/e.tgz" "$D/$t" && resum "$t" || fail "could not make the $op variant of $t"
  nc; r=$?
  [ $r = 1 ] && grep -q "$why" "$FX/o" && ! grep -q codesign "$FX/o" && pass "$t with $op $nm: refused ($why), before any real-tool check" || fail "$t $op $nm: rc=$r $(tail -1 "$FX/o")"
done
# with a lying `env` first on PATH (it would say yes to anything): a package npm-same.py refuses is
# still refused by it, before any real-tool check (every env the release scripts run is /usr/bin/env)
mkdir -p "$FX/liar"; printf '#!/bin/sh\nexit 0\n' > "$FX/liar/env"; chmod 755 "$FX/liar/env"
mk signed false; python3 "$E" "$D/$MT" "$FX/e.tgz" replace package/README.md "not the readme" && mv "$FX/e.tgz" "$D/$MT" && resum "$MT" || fail "could not make the README variant"
(cd "$REPO" && env PATH="$FX/liar:$PATH" HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 sh scripts/release.sh npm-check --out "$FX/out" v0.1.0) > "$FX/o" 2>&1; r=$?
[ $r = 1 ] && grep -q "README.md differs from the repo's" "$FX/o" && [ ! -e "$D/NPM-CHECKED" ] && pass "a lying env on PATH: npm-same.py still refuses the package, no stamp" || fail "lying env: rc=$r $(tail -1 "$FX/o")"
# a control build's bundle (the control marker) in the darwin package: refused before any real tool
app_plain=$app; mkdir -p "$FX/mk" && cp -R "$app" "$FX/mk/" && /usr/bin/plutil -insert SheeprControlBuild -bool true "$FX/mk/Sheepr.app/Contents/Info.plist" || exit 3
app=$FX/mk/Sheepr.app; mk signed false; app=$app_plain; nc; r=$?
[ $r = 1 ] && grep -q 'a control build' "$FX/o" && ! grep -q codesign "$FX/o" && pass "a control build's bundle in the darwin package: refused before any real-tool check" || fail "marked: rc=$r $(tail -1 "$FX/o")"
# the same, with a lying `tar` first on PATH that unpacks a plain darwin package: still refused as a
# control build (the bundle the real tools judge is unpacked by the system's tar)
mkdir -p "$FX/liar-tar" "$FX/plainpk"; (app=$app_plain; mk signed false); cp "$D/$DT" "$FX/plainpk/p.tgz"
app=$FX/mk/Sheepr.app; mk signed false; app=$app_plain
printf '#!/bin/sh\nd=""; while [ $# -gt 0 ]; do [ "$1" = -C ] && d=$2; shift; done\nexec /usr/bin/tar -xzf "%s" -C "$d"\n' "$FX/plainpk/p.tgz" > "$FX/liar-tar/tar"; chmod 755 "$FX/liar-tar/tar"
(cd "$REPO" && env PATH="$FX/liar-tar:$PATH" HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 sh scripts/release.sh npm-check --out "$FX/out" v0.1.0) > "$FX/o" 2>&1; r=$?
[ $r = 1 ] && grep -q 'the darwin package holds a control build' "$FX/o" && pass "a lying tar on PATH: the darwin package's control build is still refused as one" || fail "lying tar: rc=$r $(tail -1 "$FX/o")"
mk signed false; stamp; nc; r=$?
[ $r = 1 ] && grep -q 'codesign' "$FX/o" && pass "an unsigned bundle in the darwin package: refused, by codesign" || fail "unsigned bundle: rc=$r $(tail -1 "$FX/o")"
[ ! -e "$D/NPM-CHECKED" ] && pass "a refused npm-check removes an earlier stamp (refused at a real-tool check)" || fail "a refused npm-check left the stamp"
# the npm page: the main package carries the README (npm shows it), and every package links the
# repository and its home page
tar -xzOf "$D/$MT" package/README.md 2>/dev/null | cmp -s - "$SR_ROOT/README.md" && pass "the main package carries the repo's README" || fail "the main package's README is missing or not the repo's"
for t in "$MT" "$DT" sheepr-linux-arm64-$nv.tgz "$XT"; do
  j=$(tar -xzOf "$D/$t" package/package.json 2>/dev/null)
  case $j in *'"url": "git+https://github.com/lukaso/sheepr.git"'*'"homepage": "https://github.com/lukaso/sheepr#readme"'*) pass "$t links the repository and its home page" ;; *) fail "$t: no repository or homepage in package.json" ;; esac
done
# the names npm-check passes are the one list publish and publish-npm check npm's owners of
# (release.conf's SR_NPM_PKGS): packages that are not that list are refused, the list named;
# control: the same packages with the list as it is pass
mk signed false; nc; r=$?; [ $r = 1 ] && grep -q 'codesign' "$FX/o" && ! grep -q 'SR_NPM_PKGS' "$FX/o" && pass "control: with the list as it is, the refusal is the .dev bundle's (codesign), not the list" || fail "control list: rc=$r $(tail -1 "$FX/o")"
sed -i.bak 's/^SR_NPM_PKGS=.*/SR_NPM_PKGS=\x27sheepr-linux-arm64 sheepr-linux-x86 sheepr-darwin-universal sheepr\x27/' "$REPO/scripts/release.conf" && rm -f "$REPO/scripts/release.conf.bak"
grep -q '^SR_NPM_PKGS=.*sheepr-linux-x86 ' "$REPO/scripts/release.conf" || fail "could not change the fixture's list"
mk signed false; nc; r=$?; g checkout -q scripts/release.conf
[ $r = 1 ] && grep -q 'SR_NPM_PKGS' "$FX/o" && [ ! -e "$D/NPM-CHECKED" ] && pass "packages that are not release.conf's list: refused, the list named, no stamp" || fail "another list: rc=$r $(tail -1 "$FX/o")"
# npm-same.py packages itself, against these packages and the tag's files: the list must be the
# packages npm-pack.sh writes (a wrong name or a repeated one is refused), and each tarball's package
# must be its file's (the x64 file holding the arm64 package is refused for that, before package.json)
R=$FX/ref; mkdir -p "$R"; for x in LICENSE-MIT LICENSE-APACHE README.md; do g show "v0.1.0:$x" > "$R/$x"; done; g show v0.1.0:npm/sheepr/bin/sheepr > "$R/launcher"
L="sheepr-linux-arm64 sheepr-linux-x64 sheepr-darwin-universal sheepr"; NS=$SR_ROOT/scripts/lib/npm-same.py
mk signed false; python3 "$NS" packages "$D" "$nv" "$R" "$L" > "$FX/o" 2>&1 && pass "control: npm-same.py passes these packages with the list" || fail "npm-same control: $(tail -1 "$FX/o")"
python3 "$NS" packages "$D" "$nv" "$R" "sheepr-linux-arm64 sheepr-linux-x64 sheepr-darwin-universal sheepr-cli" > "$FX/o" 2>&1; r=$?
[ $r != 0 ] && grep -q 'SR_NPM_PKGS' "$FX/o" && pass "npm-same.py: a list with another name is refused" || fail "npm-same other name: rc=$r $(tail -1 "$FX/o")"
python3 "$NS" packages "$D" "$nv" "$R" "sheepr sheepr-linux-arm64 sheepr-linux-x64 sheepr-darwin-universal sheepr" > "$FX/o" 2>&1; r=$?
[ $r != 0 ] && grep -q 'SR_NPM_PKGS' "$FX/o" && pass "npm-same.py: a list with a name twice is refused" || fail "npm-same repeated name: rc=$r $(tail -1 "$FX/o")"
cp "$D/sheepr-linux-arm64-$nv.tgz" "$D/sheepr-linux-x64-$nv.tgz"; python3 "$NS" packages "$D" "$nv" "$R" "$L" > "$FX/o" 2>&1; r=$?
[ $r != 0 ] && grep -q "sheepr-linux-x64-$nv.tgz: the package inside is 'sheepr-linux-arm64', not sheepr-linux-x64" "$FX/o" && pass "npm-same.py: a tarball holding another package than its file's is refused for that" || fail "npm-same swapped: rc=$r $(tail -1 "$FX/o")"
# the list's order is the upload order: the main package must come last (its optional dependencies
# name the others); and its optional dependencies are exactly the list's other names (a name there
# that is not in the list would never have its npm owner checked)
mk signed false; python3 "$NS" packages "$D" "$nv" "$R" "sheepr sheepr-linux-arm64 sheepr-linux-x64 sheepr-darwin-universal" > "$FX/o" 2>&1; r=$?
[ $r != 0 ] && grep -q 'last' "$FX/o" && pass "npm-same.py: a list with the main package first is refused" || fail "npm-same main first: rc=$r $(tail -1 "$FX/o")"
python3 "$E" "$D/sheepr-$nv.tgz" "$FX/e.tgz" json-set package/package.json "optionalDependencies={\"sheepr-linux-arm64\": \"$nv\", \"sheepr-linux-x64\": \"$nv\", \"sheepr-darwin-universal\": \"$nv\", \"sheepr-extra\": \"$nv\"}" && mv "$FX/e.tgz" "$D/sheepr-$nv.tgz" || fail "could not make the optionalDependencies variant"
python3 "$NS" packages "$D" "$nv" "$R" "$L" > "$FX/o" 2>&1; r=$?
[ $r != 0 ] && grep -q 'optionalDependencies' "$FX/o" && grep -q 'SR_NPM_PKGS' "$FX/o" && pass "npm-same.py: optional dependencies that are not the list's other names are refused, the list named" || fail "npm-same optionalDependencies: rc=$r $(tail -1 "$FX/o")"
# the stamp names the manifest npm-check copied at its start, not the output dir's read again at
# the end: a manifest replaced during the check (here at the last real-tool check) gets no stamp
# publish accepts. Stand-in real tools and archive check, in the fixture repo only, so the check
# can pass; the control: nothing replaced, the stamp is the manifest's
cp "$REPO/scripts/lib/realtools.sh" "$FX/rt.real" && cp "$REPO/scripts/lib/archive.sh" "$FX/ar.real" || exit 3
cat > "$REPO/scripts/lib/realtools.sh" <<EOF
rt_meets() { return 0; }
rt_staple_ok() { return 0; }
rt_spctl_ok() { [ -e "$FX/swapman" ] && printf ' ' >> "$D/MANIFEST.json"; return 0; }
EOF
printf '#!/bin/sh\nexit 0\n' > "$REPO/scripts/lib/archive.sh"
mk signed false; h0=$(shasum -a 256 "$D/MANIFEST.json" | cut -d' ' -f1); nc; r=$?
[ $r = 0 ] && [ "$(cat "$D/NPM-CHECKED" 2>/dev/null)" = "v0.1.0 $h0" ] \
  && pass "control: with stand-in real tools, npm-check stamps the manifest it checked" || fail "stand-in pass: rc=$r $(tail -1 "$FX/o")"
mk signed false; h0=$(shasum -a 256 "$D/MANIFEST.json" | cut -d' ' -f1); touch "$FX/swapman"; nc; r=$?; rm -f "$FX/swapman"
h1=$(shasum -a 256 "$D/MANIFEST.json" | cut -d' ' -f1)
[ $r = 0 ] && [ "$h1" != "$h0" ] && [ "$(cat "$D/NPM-CHECKED" 2>/dev/null)" = "v0.1.0 $h0" ] \
  && pass "a manifest replaced during npm-check: the stamp names the one checked, so publish refuses the replaced one" || fail "replaced during the check: rc=$r stamp '$(cat "$D/NPM-CHECKED" 2>/dev/null)' checked $h0 now $h1"
cp "$FX/rt.real" "$REPO/scripts/lib/realtools.sh" && cp "$FX/ar.real" "$REPO/scripts/lib/archive.sh" || exit 3

# r12b F1: npm_check sets the content class itself, only at a check that found a defect in the bytes
# (__class-npm-check: npm_check as ship's C2 subshell runs it, then the class it left). Controls: a
# package hash, a control build, codesign's verdict on the .dev bundle: content. An Apple tool that
# cannot run (codesign's path in the fixture's realtools.sh replaced by one that exits 127): fix
ncc() { (cd "$REPO" && env HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 sh scripts/release.sh __class-npm-check --out "$FX/out" v0.1.0) > "$FX/o" 2>&1; }
cls() { sed -n 's/^release: (class) //p' "$FX/o" | tail -1; }
mk signed false; echo x >> "$D/sheepr-linux-x64-$nv.tgz"; ncc; r=$?
[ $r = 1 ] && [ "$(cls)" = content ] && grep -q 'does not match its manifest hash' "$FX/o" && pass "control: a package not its manifest hash: class content" || fail "hash class: rc=$r '$(cls)' $(tail -1 "$FX/o")"
mk signed true; ncc; r=$?
[ $r = 1 ] && [ "$(cls)" = content ] && grep -q 'control' "$FX/o" && pass "  control: a control build: class content" || fail "control class: rc=$r '$(cls)' $(tail -1 "$FX/o")"
mk signed false; ncc; r=$?
[ $r = 1 ] && [ "$(cls)" = content ] && grep -q 'codesign' "$FX/o" && pass "  control: codesign's verdict on the .dev bundle: class content" || fail "codesign class: rc=$r '$(cls)' $(tail -1 "$FX/o")"
cp "$REPO/scripts/lib/realtools.sh" "$FX/rt.keep" || exit 3
printf '#!/bin/sh\nexit 127\n' > "$FX/cs127"; chmod +x "$FX/cs127"
sed "s#/usr/bin/codesign#$FX/cs127#" "$FX/rt.keep" > "$REPO/scripts/lib/realtools.sh"
grep -q "$FX/cs127" "$REPO/scripts/lib/realtools.sh" || fail "premise: codesign's path not replaced"
mk signed false; ncc; r=$?
[ $r = 1 ] && [ "$(cls)" = fix ] && grep -q 'codesign' "$FX/o" && pass "r12b F1: an Apple tool that cannot run (exit 127): class fix" || fail "codesign 127 class: rc=$r '$(cls)' $(tail -1 "$FX/o")"
cp "$FX/rt.keep" "$REPO/scripts/lib/realtools.sh" || exit 3
# r15b P4-1: npm-check's order of the checks: stapler refusing (65) runs before spctl, so its verdict is
# content, with its words, and spctl does not run (it would refuse too). Stand-in real tools (functions)
# and archive check, in the fixture repo only. Control: the stand-ins accepting (the stamp rows above)
cp "$REPO/scripts/lib/realtools.sh" "$FX/rt.keep3" && cp "$REPO/scripts/lib/archive.sh" "$FX/ar.keep3" || exit 3
cat > "$REPO/scripts/lib/realtools.sh" <<EOF
rt_meets() { return 0; }
rt_staple_ok() { echo "x.app does not have a ticket stapled to it." > "\${RT_OUT:-/dev/null}"; rt_rc=65; return 1; }
rt_spctl_ok() { : > "$FX/spctl.ran"; echo "x.app: rejected" > "\${RT_OUT:-/dev/null}"; rt_rc=3; return 1; }
EOF
printf '#!/bin/sh\nexit 0\n' > "$REPO/scripts/lib/archive.sh"
rm -f "$FX/spctl.ran"; mk signed false; ncc; r=$?
[ $r = 1 ] && [ "$(cls)" = content ] && grep -q 'does not have a ticket stapled' "$FX/o" && [ ! -e "$FX/spctl.ran" ] \
  && pass "r15b P4-1: npm-check, stapler refuses and spctl would too: content, stapler's words, spctl not run" \
  || fail "r15b P4-1 (npm-check): rc=$r '$(cls)' spctl ran: $( [ -e "$FX/spctl.ran" ] && echo yes || echo no); $(tail -1 "$FX/o" | cut -c1-200)"
cp "$FX/rt.keep3" "$REPO/scripts/lib/realtools.sh" && cp "$FX/ar.keep3" "$REPO/scripts/lib/archive.sh" || exit 3
# r17b F1: npm-check's stamp write that lands nothing (/usr/bin/printf exits 0 on a full disk: measured,
# notes/builder/i17/wprobe.out): here a link to /dev/null at NPM-CHECKED, planted by the last real-tool
# stand-in, after npm-check removed the old stamp. npm-check stops: exit 1, "cannot write", class fix
# (a full disk is no finding about the bytes), and no stamp is left (no link, no file). Control: the same
# stand-ins with no link: the stamp is written (the stamp rows above)
cp "$REPO/scripts/lib/realtools.sh" "$FX/rt.keep5" && cp "$REPO/scripts/lib/archive.sh" "$FX/ar.keep5" || exit 3
cat > "$REPO/scripts/lib/realtools.sh" <<EOF
rt_meets() { return 0; }
rt_staple_ok() { return 0; }
rt_spctl_ok() { [ -e "$FX/nullstamp" ] && ln -s /dev/null "$D/NPM-CHECKED"; return 0; }
EOF
printf '#!/bin/sh\nexit 0\n' > "$REPO/scripts/lib/archive.sh"
mk signed false; : > "$FX/nullstamp"; ncc; r=$?; rm -f "$FX/nullstamp"
[ $r = 1 ] && [ "$(cls)" = fix ] && grep -q "cannot write $D/NPM-CHECKED" "$FX/o" && [ ! -e "$D/NPM-CHECKED" ] && [ ! -L "$D/NPM-CHECKED" ] \
  && pass "r17b F1: npm-check's stamp write that lands nothing: exit 1, 'cannot write', class fix, no stamp left" \
  || fail "r17b F1 (npm-check's stamp): rc=$r '$(cls)' stamp: $( [ -L "$D/NPM-CHECKED" ] && echo link || { [ -e "$D/NPM-CHECKED" ] && echo file || echo none; })"
mk signed false; ncc; r=$?
[ $r = 0 ] && [ "$(cat "$D/NPM-CHECKED" 2>/dev/null)" = "v0.1.0 $(shasum -a 256 "$D/MANIFEST.json" | cut -d' ' -f1)" ] \
  && pass "  control: the same stand-ins, no link: the stamp is written" || fail "  control (stamp): rc=$r '$(cat "$D/NPM-CHECKED" 2>/dev/null)'"
cp "$FX/rt.keep5" "$REPO/scripts/lib/realtools.sh" && cp "$FX/ar.keep5" "$REPO/scripts/lib/archive.sh" || exit 3
# gkrun FILE ARCHIVE: the two Gatekeeper lines of a spctl stop (FILE) run as printed, from / in sh and
# in an interactive zsh -f, with a stub spctl first on PATH and TMPDIR under $FX (the line's mktemp names
# TMPDIR: macOS's mktemp -d with no template ignores it): `spctl --status`, and
# the line that unpacks ARCHIVE into a new temp dir, asks spctl about the bundle there (the stub
# records whether that bundle is a directory) and removes that dir (r16b F5: none is left). 0 when
# both gave exactly that
gkrun() {
  mkdir -p "$FX/spb" "$FX/gk" || return 1
  printf '#!/bin/sh\n{ printf "spctl"; for a; do printf " [%%s]" "$a"; done; [ $# = 5 ] && { [ -d "$5" ] && printf " bundle=yes" || printf " bundle=no"; }; printf "\\n"; } >> "$REC"\n' > "$FX/spb/spctl"; chmod +x "$FX/spb/spctl"
  l1_=$(grep -x '  spctl --status' "$1"); l2_=$(grep -x "  d=\$(mktemp -d \"\${TMPDIR:-/tmp}/sheepr-gatekeeper.XXXXXX\") && tar -xzf '$2' -C \"\$d\" && spctl -a -vv -t exec \"\$d/[a-zA-Z/.]*\"; rm -rf \"\${d:?}\"" "$1")
  [ -n "$l1_" ] && [ -n "$l2_" ] || return 1
  g_=0
  for how_ in sh zsh; do
    for l_ in "$l1_" "$l2_"; do
      REC=$FX/gk.rec; : > "$REC"
      if [ $how_ = sh ]; then (cd / && env -i PATH="$FX/spb:/usr/bin:/bin" TMPDIR="$FX/gk" REC="$REC" /bin/sh -c "$l_") > /dev/null 2>&1
      else (cd / && printf '%s\n' "$l_" | env -i PATH="$FX/spb:/usr/bin:/bin" HOME="$FX" TMPDIR="$FX/gk" REC="$REC" /bin/zsh -f -i) > /dev/null 2>&1; fi
      case $l_ in
        *--status) [ "$(cat "$REC")" = "spctl [--status]" ] || g_=1 ;;
        *) case $(cat "$REC") in "spctl [-a] [-vv] [-t] [exec] [$FX/gk/sheepr-gatekeeper."*"/Sheepr.app] bundle=yes") ;; *) g_=1 ;; esac
           # (r16b F5: the line removes its temp dir: none is left)
           [ "$(ls "$FX/gk" | grep -c '^sheepr-gatekeeper\.')" = 0 ] || g_=1 ;;
      esac
    done
  done
  rm -rf "${FX:?}/gk" "${FX:?}/gk.rec"; return $g_
}
# REV 11b rule 16: npm-check's spctl stop (stand-in real tools: codesign and stapler accept, spctl
# refuses, exit 3): class fix; no "cannot change"; its Gatekeeper lines run as printed, on the darwin
# package's bundle
cp "$REPO/scripts/lib/realtools.sh" "$FX/rt.keep4" && cp "$REPO/scripts/lib/archive.sh" "$FX/ar.keep4" || exit 3
cat > "$REPO/scripts/lib/realtools.sh" <<EOF
rt_meets() { return 0; }
rt_staple_ok() { return 0; }
rt_spctl_ok() { echo "x.app: rejected" > "\${RT_OUT:-/dev/null}"; echo "source=Notarized Developer ID" >> "\${RT_OUT:-/dev/null}"; rt_rc=3; return 1; }
EOF
printf '#!/bin/sh\nexit 0\n' > "$REPO/scripts/lib/archive.sh"
mk signed false; ncc; r=$?
[ $r = 1 ] && [ "$(cls)" = gatekeeper ] && ! grep -qi 'cannot change' "$FX/o" && grep -q 'source=Notarized Developer ID' "$FX/o" && gkrun "$FX/o" "$D/sheepr-darwin-universal-$nv.tgz" \
  && grep -qxF "If that prints nothing, v0.1.0 is not pushed yet: move the build aside and rebuild it with a valid certificate. If it prints a line, v0.1.0 is pushed: never rebuild v0.1.0; release a new version." "$FX/o" && ! grep -qxF "When the cause is a revoked signing certificate, move the build aside and rebuild it with a valid one." "$FX/o" && ! grep -qi 'expired' "$FX/o" \
  && pass "REV 11b rule 16, REV 12a, REV 12b rule 23: npm-check's spctl stop: class gatekeeper (a fix class), no 'cannot change', its Gatekeeper lines run as printed on the darwin package's bundle; the rebuild only if v0.1.0 is not pushed; never 'expired'" \
  || fail "rule 16 (npm-check): rc=$r '$(cls)'; $(grep -e 'spctl' -e 'cannot change' "$FX/o" | tr '\n' '|' | cut -c1-300)"
cp "$FX/rt.keep4" "$REPO/scripts/lib/realtools.sh" && cp "$FX/ar.keep4" "$REPO/scripts/lib/archive.sh" || exit 3
# r13b F3, F4: judged takes a checking tool's failure for a finding only for its own refusal (exit 1,
# its "npm-same: " or "archive: " line). npm-same.py stand-ins (the fixture's): "npm-same: x", then a
# KILL (137); a traceback (exit 1, no "npm-same: " line); exit 2 (usage): fix. Control: the real
# npm-same refusing an extra file in a package: content
cp "$REPO/scripts/lib/npm-same.py" "$FX/ns.real" || exit 3
for t_ in 'kill|import os, signal, sys\nsys.stderr.write("npm-same: x\\n"); sys.stderr.flush(); os.kill(os.getpid(), signal.SIGKILL)' \
          'trace|raise RuntimeError("a bug (stand-in)")' \
          'usage|import sys\nsys.stderr.write("usage: npm-same.py (stand-in)\\n"); sys.exit(2)'; do
  printf "${t_#*|}\n" > "$REPO/scripts/lib/npm-same.py"
  mk signed false; ncc; r=$?
  [ $r = 1 ] && [ "$(cls)" = fix ] && grep -q 'an npm package is refused' "$FX/o" && pass "r13b F4: npm-same.py ${t_%%|*} (no refusal of its own): class fix" || fail "npm-same ${t_%%|*}: rc=$r '$(cls)' $(tail -2 "$FX/o" | tr '\n' '|')"
done
cp "$FX/ns.real" "$REPO/scripts/lib/npm-same.py" || exit 3
mk signed false; python3 "$E" "$D/$MT" "$FX/e.tgz" add package/binding.gyp '{}' && mv "$FX/e.tgz" "$D/$MT" && resum "$MT" || fail "could not add a file to $MT"
ncc; r=$?
[ $r = 1 ] && [ "$(cls)" = content ] && grep -q 'the files are' "$FX/o" && pass "  control: the real npm-same refusing an extra file in a package: class content" || fail "  extra file: rc=$r '$(cls)' $(tail -1 "$FX/o")"
# archive.sh stand-ins (the fixture's; the real tools stand in and accept): exit 3, "archive: cannot
# check: ..." (its extraction out of room): fix. Control: exit 1, "archive: ..." (its refusal): content
cp "$REPO/scripts/lib/realtools.sh" "$FX/rt.keep2" && cp "$REPO/scripts/lib/archive.sh" "$FX/ar.keep2" || exit 3
printf 'rt_meets() { return 0; }\nrt_staple_ok() { return 0; }\nrt_spctl_ok() { return 0; }\n' > "$REPO/scripts/lib/realtools.sh"
for t_ in '3|archive: cannot check: cannot extract x into y (a full or unwritable temp dir, or a stopped tar)|fix' "1|archive: the files are not exactly the bundle's: x|content"; do
  printf '#!/bin/sh\necho "%s" >&2\nexit %s\n' "$(printf '%s' "$t_" | cut -d'|' -f2)" "${t_%%|*}" > "$REPO/scripts/lib/archive.sh"; chmod +x "$REPO/scripts/lib/archive.sh"
  mk signed false; ncc; r=$?; w_=${t_##*|}
  [ $r = 1 ] && [ "$(cls)" = "$w_" ] && grep -q 'the release archive fails its check' "$FX/o" \
    && pass "$( [ $w_ = content ] && echo '  control: ')r13b F3: archive.sh exit ${t_%%|*}$( [ $w_ = fix ] && echo ' (cannot check)' || echo ' (its refusal)'): class $w_" || fail "archive.sh ${t_%%|*}: rc=$r '$(cls)' $(tail -1 "$FX/o")"
done
cp "$FX/rt.keep2" "$REPO/scripts/lib/realtools.sh" && cp "$FX/ar.keep2" "$REPO/scripts/lib/archive.sh" || exit 3
# RULES line 13 (round 13 item 6): the fixture's own npm pack (npm-pack.sh, what the build runs too) is
# walled: its temp HOME, userconfig, global config and cache under its own temp dir (in the fixture: mk
# gives npm-pack.sh TMPDIR=$FX/tmp), no update notifier,
# the proxies at 127.0.0.1:9 and NO_PROXY 127.0.0.1. A stand-in npm first on PATH, for one npm-pack.sh
# run, writes those variables only (never the whole environment) and makes no file
mkdir -p "$FX/npmrec" || exit 3
cat > "$FX/npmrec/npm" <<'EOS'
#!/bin/sh
o_=$(dirname "$0")/env.$$
for k in HOME NPM_CONFIG_USERCONFIG NPM_CONFIG_GLOBALCONFIG npm_config_cache npm_config_update_notifier HTTPS_PROXY HTTP_PROXY NO_PROXY npm_config_userconfig NPM_CONFIG_REGISTRY; do
  eval "v_=\${$k-<unset>}"; printf '%s=%s\n' "$k" "$v_"
done > "$o_"
exit 0
EOS
chmod +x "$FX/npmrec/npm"
mkdir -p "$FX/pk.out" "$FX/tmp"; TMPDIR=$FX/tmp PATH="$FX/npmrec:$PATH" sh "$SR_ROOT/scripts/lib/npm-pack.sh" "$nv" "$D/sheepr-macos-universal.tar.gz" "$D/sheepr-linux-aarch64" "$D/sheepr-linux-x86_64" "$SR_ROOT/npm/sheepr/bin/sheepr" "$FX/pk.out" > /dev/null 2>&1
e_=$(ls "$FX"/npmrec/env.* 2>/dev/null | head -1); bad_=""
if [ -z "$e_" ]; then bad_=" no npm call recorded"; else
  pd_=$(sed -n 's/^HOME=\(.*\)\/home$/\1/p' "$e_")
  case $pd_ in "$FX/tmp/sr-npmpack."*) ;; *) bad_="$bad_ HOME=$(sed -n 's/^HOME=//p' "$e_") (not under the fixture)" ;; esac
  for kv in "NPM_CONFIG_USERCONFIG=$pd_/npmrc" "NPM_CONFIG_GLOBALCONFIG=$pd_/globalrc" "npm_config_cache=$pd_/cache" npm_config_update_notifier=false \
            HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=127.0.0.1 'npm_config_userconfig=<unset>' 'NPM_CONFIG_REGISTRY=<unset>'; do
    grep -qxF "$kv" "$e_" || bad_="$bad_ [want $kv: $(grep "^${kv%%=*}=" "$e_")]"
  done
fi
[ -z "$bad_" ] && pass "npm-pack.sh's npm pack: its HOME, userconfig, global config and cache in its own temp dir; no update notifier; the proxies walled" || fail "npm pack's isolation:$bad_"
rm -rf "${FX:?}/npmrec" "${FX:?}/pk.out"
finish
