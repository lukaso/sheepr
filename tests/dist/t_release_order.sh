#!/bin/sh
# PHASE3.md S2 and D2 step 3: the build's order, its staging dir and its one rename, in unsigned
# mode (one sequence serves every mode), with every tool that would compile, fetch or run a
# container as a shim: cargo, rustc, docker, lipo, vtool and npm (nothing is compiled, no Docker
# call is made). The build runs with PATH = the shims, /usr/bin and /bin only, where no real
# docker, cargo, rustc or npm exists (checked first: the cell refuses to run otherwise). The Mac
# binary is a tiny universal program that prints the tag's commit, so bundle.sh, the door and the
# archive run for real. Checked:
#   - the order: the compiler pin and the Linux images (the preconditions), the Linux `cargo
#     fetch` (the only networked Linux step), the macOS compile, the bundle, the Linux builds
#     (offline), the packages, the manifest, the rename; a text pin: the signing branch (sign.sh)
#     sits between the bundle step and the Linux builds, and the signing identity is checked
#     before the staging dir is made;
#   - a failed precondition (a compiler off the pin, no Linux image) leaves nothing in the output
#     root and makes no cargo call;
#   - the build writes into a hidden staging dir in the output root and renames it to the output
#     dir once the manifest is written (the same inode); a stop after the staging dir exists (the
#     Linux fetch; a Linux build, after the bundle) leaves no output dir and keeps the staging dir,
#     named in the message; an output dir that appears during the build is refused at the rename
#     and nothing nests in it; one that appears during the rename itself (a stand-in mv) is caught
#     after it; an earlier run's staging dir is left as it is and does not stop the next build.
set -u
. "$(dirname "$0")/lib.sh"
[ "$(uname -s)" = Darwin ] || { echo "SKIP (macOS only)"; exit 0; }
# the wall: with PATH=/usr/bin:/bin no real tool of the build can be reached, so a missing shim
# fails the build instead of calling Docker or compiling
for t in docker cargo rustc npm; do
  p=$(env PATH=/usr/bin:/bin sh -c 'command -v "$1"' sh "$t" 2>/dev/null)   # a fresh shell: no hashed path
  [ -z "$p" ] || { echo "refused: a real $t at $p on PATH=/usr/bin:/bin"; exit 3; }
done
fx_dir; fx_repo
fx_release 0.1.0 1 v0.1.0-rc.1
pin=$(sed -n 's/^channel = "\(.*\)"$/\1/p' "$SR_ROOT/rust-toolchain.toml")
short=$(g rev-parse --short=12 "v0.1.0-rc.1^{commit}")
OUTR=$FX/out FINAL=$FX/out/v0.1.0-rc.1-unsigned
STG=.v0.1.0-rc.1-unsigned-build.
S=$FX/shims; mkdir -p "$S"
# the Mac binary: a universal program that prints the tag's commit (lipo's stand-in copies it)
printf '#include <stdio.h>\nint main(void){puts("sheepr 0.1.0 (%s)");return 0;}\n' "$short" > "$FX/fake.c"
cc -arch arm64 -arch x86_64 -o "$FX/fakebin" "$FX/fake.c" || exit 3
echo "rustc $pin (000000000 2026-01-01)" > "$S/rustc.v"
cat > "$S/rustc" <<EOF
#!/bin/sh
echo "rustc \$*" >> "$S/calls"
cat "$S/rustc.v"
EOF
cat > "$S/cargo" <<EOF
#!/bin/sh
echo "cargo \$*" >> "$S/calls"
exit 0
EOF
cat > "$S/lipo" <<EOF
#!/bin/sh
echo "lipo \$*" >> "$S/calls"
o=""; prev=""
for a; do [ "\$prev" = -output ] && o=\$a; prev=\$a; done
[ -n "\$o" ] && cp "$FX/fakebin" "\$o"
EOF
cat > "$S/vtool" <<EOF
#!/bin/sh
echo "vtool \$*" >> "$S/calls"
echo "    minos 12.0"
EOF
# docker: the image checks, the Linux fetch, the two offline builds (each writes what the real
# container writes into /tgt) and the empty-image run; a fail.<step> file makes that step fail
cat > "$S/docker" <<EOF
#!/bin/sh
echo "docker \$*" >> "$S/calls"
case "\$*" in
  "image inspect "*) [ -e "$S/fail.inspect" ] && exit 1; exit 0 ;;
  *" cargo fetch "*) [ -e "$S/fail.fetch" ] && exit 1; exit 0 ;;
  *"/sheepr --version") echo "sheepr 0.1.0 ($short)"; exit 0 ;;
  *":/tgt "*) [ -e "$S/fail.linux" ] && exit 1
    tgt="" pf="" prev=""
    for a; do
      [ "\$prev" = -v ] && case \$a in *:/tgt) tgt=\${a%:/tgt} ;; esac
      [ "\$prev" = --platform ] && pf=\$a
      prev=\$a
    done
    case \$pf in linux/arm64) ar=aarch64 ;; linux/amd64) ar=x86_64 ;; *) exit 1 ;; esac
    mkdir -p "\$tgt/release" && echo "linux \$ar" > "\$tgt/release/sheepr" && echo "\$ar" > "\$tgt/arch" && cat "$S/rustc.v" > "\$tgt/rustc"
    exit \$? ;;
esac
exit 1
EOF
# npm pack: writes NAME-VERSION.tgz (from ./package.json) into --pack-destination and records that
# directory and its inode once; with make.final, its first call makes the output dir (with a marker)
cat > "$S/npm" <<EOF
#!/bin/sh
echo "npm \$*" >> "$S/calls"
d="" prev=""
for a; do [ "\$prev" = --pack-destination ] && d=\$a; prev=\$a; done
[ -n "\$d" ] || exit 1
[ -e "$S/packdest" ] || echo "\$d \$(ls -di "\$d" | awk '{print \$1}')" > "$S/packdest"
if [ -e "$S/make.final" ] && [ ! -e "$S/made.final" ]; then : > "$S/made.final"; mkdir -p "$FINAL" && echo m > "$FINAL/marker"; fi
n=\$(sed -n 's/^  "name": "\(.*\)",\$/\1/p' package.json | head -1); v=\$(sed -n 's/^  "version": "\(.*\)",\$/\1/p' package.json | head -1)
[ -n "\$n" ] && [ -n "\$v" ] || exit 1
echo "pkg \$n \$v" > "\$d/\$n-\$v.tgz"
EOF
# mv: the real one; with race, a mv of the staging dir first makes its target (the output dir
# appears between the check before the rename and the rename itself)
cat > "$S/mv" <<EOF
#!/bin/sh
if [ -e "$S/race" ]; then
  case \$1 in "$OUTR/$STG"??????) mkdir -p "\$2" && echo "race \$2" >> "$S/calls" ;; esac   # the staging dir itself only
fi
exec /bin/mv "\$@"
EOF
chmod +x "$S"/*
for t in docker cargo rustc npm lipo vtool mv; do
  [ "$(env PATH="$S:/usr/bin:/bin" sh -c 'command -v "$1"' sh "$t")" = "$S/$t" ] || { echo "refused: the $t shim is not first on the build's PATH"; exit 3; }
done

fresh() { rm -f "$S/calls" "$S/packdest" "$S/made.final" "$S/make.final" "$S/race" "$S"/fail.*; rm -rf "${OUTR:?}"; }
b() { (cd "$REPO" && env PATH="$S:/usr/bin:/bin" HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 sh scripts/release.sh build --out "$OUTR" v0.1.0-rc.1) > "$FX/o" 2>&1; }
# the phases the calls show, in order, a repeat folded into one
phases() {
  awk '{ p = "" }
    /^rustc / { p = "compiler" } /^docker image inspect / { p = "images" } /^docker run .* cargo fetch / { p = "linux-fetch" }
    /^cargo / { p = "mac" } /^lipo / { p = "bundle" } /^docker run .*:\/tgt / { p = "linux-build" } /^npm pack/ { p = "packages" }
    p != "" && p != last { printf "%s ", p; last = p }' "$S/calls" 2>/dev/null
}
steps() { sed -n 's/^release: step: //p' "$FX/o" | tr '\n' '|'; }
stages() { (cd "$OUTR" 2>/dev/null && ls -d "$STG"* 2>/dev/null); }   # the staging dirs in the output root
inode() { ls -di "$1" 2>/dev/null | awk '{print $1}'; }

# 1. a compiler off the pin: refused first, before any Linux or cargo step; nothing in the output root
echo "rustc 1.0.0 (000000000 2020-01-01)" > "$S/rustc.v"; fresh; b; r=$?
[ $r = 1 ] && grep -q "pinned $pin" "$FX/o" && [ "$(phases)" = "compiler " ] \
  && pass "a compiler off the pin: refused first (no docker or cargo call)" || fail "off-pin: rc=$r phases='$(phases)' $(tail -1 "$FX/o")"
[ -z "$(ls -A "$OUTR" 2>/dev/null)" ] && pass "a failed precondition (the compiler) leaves nothing in the output root" || fail "the output root holds: $(ls -A "$OUTR" | tr '\n' ' ')"
echo "rustc $pin (000000000 2026-01-01)" > "$S/rustc.v"

# 2. no Linux image: refused before any cargo call; nothing in the output root
fresh; : > "$S/fail.inspect"; b; r=$?
[ $r = 1 ] && grep -q 'step: the Linux images' "$FX/o" && [ "$(phases)" = "compiler images " ] \
  && pass "no Linux image: refused before the Linux fetch and the macOS compile" || fail "no image: rc=$r phases='$(phases)' $(tail -1 "$FX/o")"
[ -z "$(ls -A "$OUTR" 2>/dev/null)" ] && pass "a failed precondition (the images) leaves nothing in the output root" || fail "the output root holds: $(ls -A "$OUTR" | tr '\n' ' ')"

# 3. the build in full: the order, the staging dir, the one rename
fresh; b; r=$?
[ $r = 0 ] && pass "the build with stand-ins: rc 0" || fail "the build: rc=$r $(tail -3 "$FX/o" | tr '\n' ' ')"
[ "$(phases)" = "compiler images linux-fetch mac bundle linux-build packages " ] \
  && pass "the order: compiler, images, Linux fetch, macOS compile, bundle, Linux builds, packages" || fail "the order: '$(phases)'"
[ "$(steps)" = "the compiler|the Linux images|the Linux fetch|the macOS compile|the macOS bundle|the Linux builds (offline)|install.sh, the checksums, the cask, the npm packages|the manifest, then the rename|" ] \
  && pass "the steps, in order" || fail "the steps: $(steps)"
lb=$(grep -n '^docker run .*:/tgt ' "$S/calls" | head -1 | cut -d: -f1)
if [ -z "$lb" ]; then fail "no Linux build call"
elif sed -n "${lb},\$p" "$S/calls" | grep '^docker run ' | grep -v -q -e '--network none'; then fail "a networked docker run after the Linux builds started"
else pass "every docker run from the Linux builds on is offline (--network none)"; fi
pd=$(cut -d' ' -f1 "$S/packdest" 2>/dev/null) pi=$(cut -d' ' -f2 "$S/packdest" 2>/dev/null)
case $pd in "$OUTR/$STG"??????) pass "the packages were written into a staging dir in the output root ($(basename "$pd"))" ;; *) fail "the packages were written into '$pd', not a staging dir $OUTR/$STG*" ;; esac
[ -n "$pi" ] && [ "$(inode "$FINAL")" = "$pi" ] && [ ! -e "$pd" ] && pass "the output dir is the staging dir, renamed (the same inode; the staging name is gone)" || fail "rename: final inode $(inode "$FINAL"), staging '$pd' inode '$pi', staging left: $([ -e "$pd" ] && echo yes || echo no)"
[ "$(ls -A "$OUTR" | tr '\n' ' ')" = "v0.1.0-rc.1-unsigned " ] && pass "the output root holds only the output dir" || fail "the output root holds: $(ls -A "$OUTR" | tr '\n' ' ')"
n=$(sed -n 's/.*"name": "\([^"]*\)", "sha256": "[0-9a-f]\{64\}".*/\1/p' "$FINAL/MANIFEST.json" 2>/dev/null | grep -c .)
[ "$n" = 8 ] && (cd "$FINAL" && shasum -a 256 -c --strict SHA256SUMS >/dev/null 2>&1) && pass "the output dir holds the manifest (8 files) and a matching SHA256SUMS" || fail "the output dir: $n manifest entries; $(ls "$FINAL" 2>/dev/null | tr '\n' ' ')"
[ "$(tail -1 "$FX/o")" = "release: v0.1.0-rc.1 built (unsigned) in $FINAL" ] && ! grep -q -e 'stopped' -e 'kept in' "$FX/o" \
  && pass "the build's last line names the output dir; no 'stopped' or 'kept in' line" || fail "a finished build's output: $(grep -e stopped -e 'kept in' "$FX/o" | head -1) / last: $(tail -1 "$FX/o")"
mkdir "$FX/moderef"; want=$(/usr/bin/stat -f %Lp "$FX/moderef"); got=$(/usr/bin/stat -f %Lp "$FINAL" 2>/dev/null)
[ "$got" = "$want" ] && pass "the output dir has the mode a mkdir gives under the same umask ($want), not mktemp's 700" || fail "the output dir's mode is '$got', a mkdir's is $want"
[ "$(g worktree list | grep -c .)" = 1 ] && pass "no worktree left after a build" || fail "a worktree left"

# 4. the Linux fetch fails: stopped before the macOS compile; the staging dir kept and named
fresh; : > "$S/fail.fetch"; b; r=$?
st=$(stages)
[ $r = 1 ] && [ "$(phases)" = "compiler images linux-fetch " ] && pass "the Linux fetch fails: stopped before the macOS compile" || fail "fetch failing: rc=$r phases='$(phases)'"
[ ! -e "$FINAL" ] && [ "$(printf '%s\n' "$st" | grep -c .)" = 1 ] && grep -q "kept in $OUTR/$st" "$FX/o" \
  && pass "a stop after the staging dir exists: no output dir; the staging dir kept and named" || fail "fetch failing: final $([ -e "$FINAL" ] && echo exists || echo absent), staging '$st', $(tail -1 "$FX/o")"

# 5. a failure after the bundle (the first Linux build): no output dir, the staging dir kept (with
#    the bundle's archive in it) and named
fresh; : > "$S/fail.linux"; b; r=$?
st=$(stages)
[ $r = 1 ] && [ "$(phases)" = "compiler images linux-fetch mac bundle linux-build " ] && pass "a Linux build fails after the bundle" || fail "Linux build failing: rc=$r phases='$(phases)'"
[ ! -e "$FINAL" ] && [ "$(printf '%s\n' "$st" | grep -c .)" = 1 ] && [ -f "$OUTR/$st/sheepr-macos-universal.tar.gz" ] && [ ! -e "$OUTR/$st/MANIFEST.json" ] && grep -q "kept in $OUTR/$st" "$FX/o" \
  && pass "a failure after the bundle: no output dir; the staging dir (with the archive) kept and named" || fail "after the bundle: final $([ -e "$FINAL" ] && echo exists || echo absent), staging '$st', $(tail -1 "$FX/o")"
[ "$(g worktree list | grep -c .)" = 1 ] && pass "no worktree left after a failed build" || fail "a worktree left"

# 6. the output dir appears during the build: refused at the rename; nothing nests in it
fresh; : > "$S/make.final"; b; r=$?
st=$(stages)
[ $r = 1 ] && [ "$(ls -A "$FINAL" | tr '\n' ' ')" = "marker " ] && pass "an output dir made during the build: refused at the rename, nothing nested in it" || fail "made during the build: rc=$r, it holds: $(ls -A "$FINAL" 2>/dev/null | tr '\n' ' ')"
[ "$(printf '%s\n' "$st" | grep -c .)" = 1 ] && [ -f "$OUTR/$st/MANIFEST.json" ] && grep -q "kept in $OUTR/$st" "$FX/o" \
  && pass "  ... the finished build stays in its staging dir, named" || fail "made during the build: staging '$st', $(tail -2 "$FX/o" | tr '\n' ' ')"

# 7. the output dir appears during the rename itself (mv nests and returns 0): caught after it
fresh; : > "$S/race"; b; r=$?
nest=$(cd "$FINAL" 2>/dev/null && ls -d "$STG"* 2>/dev/null)
[ $r = 1 ] && grep -q '^race ' "$S/calls" && [ -n "$nest" ] && grep -q "$FINAL/$nest" "$FX/o" && ! grep -q 'kept in' "$FX/o" \
  && pass "an output dir made during the rename: caught after it (rc 1), the build's place named, and only that place" || fail "race: rc=$r nested '$nest' $(grep 'kept in' "$FX/o" | head -1) $(tail -1 "$FX/o")"

# 7b. a relative --out is the directory it names from where build was started (made absolute first)
fresh; rm -rf "${FX:?}/rel"
(cd "$FX" && env PATH="$S:/usr/bin:/bin" HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 sh "$REPO/scripts/release.sh" build --out rel/out v0.1.0-rc.1) > "$FX/o" 2>&1; r=$?
[ $r = 0 ] && [ -f "$FX/rel/out/v0.1.0-rc.1-unsigned/MANIFEST.json" ] && [ "$(tail -1 "$FX/o")" = "release: v0.1.0-rc.1 built (unsigned) in $FX/rel/out/v0.1.0-rc.1-unsigned" ] \
  && pass "a relative --out: made absolute from where build ran; the build is there (0)" || fail "relative --out: rc=$r $(tail -1 "$FX/o")"
rm -rf "${FX:?}/rel"

# 8. an earlier run's staging dir: left as it is, and the next build is not stopped by it
fresh; mkdir -p "$OUTR/${STG}OLD000"; echo old > "$OUTR/${STG}OLD000/MANIFEST.json"; b; r=$?
[ $r = 0 ] && [ -d "$FINAL" ] && [ "$(cat "$OUTR/${STG}OLD000/MANIFEST.json" 2>/dev/null)" = old ] && [ "$(cut -d' ' -f1 "$S/packdest")" != "$OUTR/${STG}OLD000" ] \
  && pass "an earlier staging dir: untouched, and the build makes its own" || fail "earlier staging dir: rc=$r $(tail -1 "$FX/o")"

# 9. the text: the signing branch between the bundle step and the Linux builds; the identity and
#    the images before the staging dir; the manifest before the rename
body=$(awk '/^build_release\(\) \{/ { f = 1 } f { print NR ": " $0 } f && /^}/ { exit }' "$SR_ROOT/scripts/release.sh")
prev=0 bad=""
for m in 'step "the signing identity"' 'step "the compiler"' 'step "the Linux images"' 'mktemp -d "$out/.' 'step "the Linux fetch"' \
    'step "the macOS compile"' 'step "the macOS bundle"' '"$S/lib/sign.sh" "$@" || die "signing failed"' 'step "the Linux builds' '> "$dest/MANIFEST.json"' 'mv "$dest" "$final"'; do
  l=$(printf '%s\n' "$body" | grep -F -- "$m" | cut -d: -f1)
  [ "$(printf '%s\n' "$l" | grep -c .)" = 1 ] || { bad="$bad [$m: $(printf '%s\n' "$l" | grep -c .) lines]"; continue; }
  [ "$l" -gt "$prev" ] || bad="$bad [$m at $l, before $prev]"
  prev=$l
done
[ -z "$bad" ] && pass "the text: identity, compiler, images, staging, Linux fetch, macOS compile, bundle, sign.sh, Linux builds, manifest, rename" || fail "the text order:$bad"
finish
