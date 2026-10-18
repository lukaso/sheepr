#!/bin/sh
# PHASE3.md §1.5: scripts/lib/archive.sh makes the macOS release archive (no xattrs, no ACLs, no
# mac metadata, owners 0/0 with no names) and checks one: exactly the bundle's files (unsigned:
# Info.plist and the executable; --signed: also the signature and the staple ticket), directory
# entries only the parents of those, no xattr after extraction, no xattr pax header, owners 0/0.
# A QUIT or a USR1 while tar lists the archive: archive.sh waits for tar, exits 1, leaves no temp dir.
set -u
. "$(dirname "$0")/lib.sh"
[ "$(uname -s)" = Darwin ] || { echo "SKIP (macOS only)"; exit 0; }
fx_dir
A="$SR_ROOT/scripts/lib/archive.sh"
printf 'int main(){return 0;}\n' > "$FX/m.c"; cc -o "$FX/bin" "$FX/m.c" || exit 3
app=$("$SR_ROOT/scripts/bundle.sh" "$FX/bin" "$FX/b" 0.1.0 1) || exit 3
xattr -w com.apple.quarantine "0081;00000000;Safari;" "$app/Contents/Info.plist"
"$A" make "$app" "$FX/good.tar.gz" && pass "make" || fail "make failed"
"$A" check "$FX/good.tar.gz" && pass "a made archive passes (the planted xattr is not in it)" || fail "a made archive fails the check"
"$A" check "$FX/good.tar.gz" --signed >/dev/null 2>&1 && fail "--signed accepted an unsigned bundle" || pass "--signed refuses an unsigned bundle"
# the default tar keeps xattrs and owner names: refused
(cd "$FX/b" && tar -czf "$FX/plain.tar.gz" Sheepr.app) 2>/dev/null
"$A" check "$FX/plain.tar.gz" >/dev/null 2>&1 && fail "a plain tar (xattr, names) accepted" || pass "a plain tar with an xattr and owner names refused"
# an xattr only (owners already 0/0 without names), and only com.apple.provenance, which macOS
# puts on every file made here and extraction adds anyway: only the pax-header check can see it
xattr -d com.apple.quarantine "$app/Contents/Info.plist" 2>/dev/null
xattr -l "$app/Contents/Info.plist" | grep -q com.apple.provenance || fail "the fixture has no provenance xattr"
(cd "$FX/b" && tar --uid 0 --gid 0 --uname '' --gname '' -czf "$FX/xattr.tar.gz" Sheepr.app) 2>/dev/null
"$A" check "$FX/xattr.tar.gz" >/dev/null 2>&1 && fail "an archive with an xattr accepted" || pass "an archive with an xattr (and 0/0 owners) refused"
# an extra file: refused
echo x > "$app/Contents/extra"
"$A" make "$app" "$FX/extra.tar.gz" >/dev/null 2>&1
"$A" check "$FX/extra.tar.gz" >/dev/null 2>&1 && fail "an extra file accepted" || pass "an extra file refused"
rm -f "$app/Contents/extra"
# owner names only (no xattr): refused
xattr -c "$app/Contents/Info.plist"
(cd "$FX/b" && tar --no-xattrs --no-mac-metadata --no-acls -czf "$FX/names.tar.gz" Sheepr.app) 2>/dev/null
"$A" check "$FX/names.tar.gz" >/dev/null 2>&1 && fail "owner names accepted" || pass "owner names refused"
# a signed, not stapled bundle (the control mode): --signed-unstapled wants the signature and no
# ticket; --signed (a ticket) and the unsigned check refuse it
xattr -c -r "$app" 2>/dev/null
codesign -s - -f "$app" 2>/dev/null
"$A" make "$app" "$FX/su.tar.gz" >/dev/null 2>&1
"$A" check "$FX/su.tar.gz" --signed-unstapled && pass "a signed, unstapled bundle passes --signed-unstapled" || fail "--signed-unstapled refused a signed bundle"
"$A" check "$FX/su.tar.gz" --signed >/dev/null 2>&1 && fail "--signed accepted a bundle with no staple ticket" || pass "--signed refuses a bundle with no staple ticket"
"$A" check "$FX/su.tar.gz" >/dev/null 2>&1 && fail "the unsigned check accepted a signed bundle" || pass "the unsigned check refuses a signed bundle"
"$A" check "$FX/good.tar.gz" --signed-unstapled >/dev/null 2>&1 && fail "--signed-unstapled accepted an unsigned bundle" || pass "--signed-unstapled refuses an unsigned bundle"
# r13b F3: an extraction that runs out of room (ulimit -f: the listing passes, the 16 KB executable
# does not fit) is no finding about the archive: exit 3, "archive: cannot check:". Control: an extra
# file, exit 1, its refusal
lim=$(( $(wc -c < "$FX/good.tar.gz") / 512 + 4 ))
[ $(( lim * 512 )) -lt "$(wc -c < "$FX/bin")" ] || fail "premise: the executable fits in $lim blocks (the row would prove nothing)"
(ulimit -f "$lim"; "$A" check "$FX/good.tar.gz") > "$FX/room.o" 2>&1; rc=$?
[ $rc = 3 ] && grep -q '^archive: cannot check: cannot extract' "$FX/room.o" && pass "r13b F3: the extraction out of room (ulimit -f $lim): exit 3, cannot check" || fail "room: rc=$rc $(tail -2 "$FX/room.o" | tr '\n' '|')"
"$A" check "$FX/extra.tar.gz" > "$FX/extra.o" 2>&1; rc=$?
[ $rc = 1 ] && grep -q '^archive: ' "$FX/extra.o" && ! grep -q 'cannot check' "$FX/extra.o" && pass "  control: an extra file: exit 1, its refusal" || fail "  extra: rc=$rc $(tail -1 "$FX/extra.o")"
# r14b (arc/list2.out): the listing cannot be written to the temp dir (ulimit -f 0 with SIGXFSZ ignored:
# a write fails as on a full disk, and no signal is sent), and bsdtar's listing then exits 0, empty
# (notes/builder/arc14/x.out): no finding about the archive: exit 3, cannot check. (Its words through a
# pipe: the limit covers files.) Control: a truncated archive: exit 1, it cannot be listed
{ ( trap '' XFSZ; ulimit -f 0; "$A" check "$FX/good.tar.gz"; echo "rc=$?" ) 2>&1; } | cat > "$FX/list.o"
rc=$(sed -n 's/^rc=//p' "$FX/list.o")
[ "$rc" = 3 ] && grep -q '^archive: cannot check: ' "$FX/list.o" && ! grep -q 'not exactly the bundle' "$FX/list.o" \
  && pass "r14b: the listing cannot be written (ulimit -f 0, SIGXFSZ ignored): exit 3, cannot check" || fail "listing unwritable: rc=$rc $(grep '^archive:' "$FX/list.o" | head -1)"
# REV 11b rule 18 (r15b P4-9, dmg/fd.out): and no stray bytes on stderr: the failed append of the line
# after the listing left "end" in the shell's buffer, which the next write to stderr carried out
grep -qx end "$FX/list.o" && fail "  a stray 'end' line on stderr: $(tr '\n' '|' < "$FX/list.o" | cut -c1-200)" || pass "  REV 11b rule 18: no stray bytes on stderr (only archive.sh's own line, and rc)"
# REV 11b rule 18 (r15b P4-3, dmg/openfail.out): the listing FILE cannot be created (the temp dir made
# read-only right after mktemp, in a copy of archive.sh: an injection): exit 3, cannot check, not "cannot
# list" (a finding, exit 1). Control: the same copy, no injection: exit 0
mkdir -p "$FX/inj" && cp "$SR_ROOT/scripts/lib/sigs.sh" "$FX/inj/" || exit 3
sed 's#^    trap .rm -rf "\$t"; exit 1. \$SIGS$#&\
    [ -z "${INJ:-}" ] || chmod 555 "$t"#' "$A" > "$FX/inj/archive.sh"
[ "$(grep -c 'INJ' "$FX/inj/archive.sh")" = 1 ] || fail "premise: the injection is not in the copy (the row would prove nothing)"
INJ=1 sh "$FX/inj/archive.sh" check "$FX/good.tar.gz" > "$FX/of.o" 2>&1; rc=$?
[ $rc = 3 ] && grep -q '^archive: cannot check: ' "$FX/of.o" && ! grep -q 'cannot list' "$FX/of.o" && ! grep -qi 'permission denied' "$FX/of.o" \
  && pass "REV 11b rule 18 (r15b P4-3): the listing file cannot be created: exit 3, cannot check; no stray words" || fail "listing file not created: rc=$rc $(tr '\n' '|' < "$FX/of.o" | cut -c1-200)"
sh "$FX/inj/archive.sh" check "$FX/good.tar.gz" > "$FX/of.o" 2>&1; rc=$?
[ $rc = 0 ] && pass "  control: the same copy, no injection: it passes" || fail "  injection control: rc=$rc $(tail -1 "$FX/of.o")"
head -c 300 "$FX/good.tar.gz" > "$FX/cut.tar.gz"
"$A" check "$FX/cut.tar.gz" > "$FX/cut.o" 2>&1; rc=$?
[ $rc = 1 ] && grep -q '^archive: cannot list ' "$FX/cut.o" && pass "  control: a truncated archive: exit 1, it cannot be listed" || fail "  truncated: rc=$rc $(tail -1 "$FX/cut.o")"
# a QUIT (its default runs no EXIT trap) and a USR1 to `archive.sh check` while tar lists the
# archive (400 MiB of zeros, small once compressed, so tar runs long enough; tests/lib/sigchild.c
# sends the signal once tar is archive.sh's child): archive.sh waits for tar, exits 1, writes
# nothing, and leaves no /private/tmp/sr-archive.* dir; the control, no signal (sigchild's 0): the
# check runs on and refuses the archive by name (its own line, which a stopped run must not write)
cc -o "$FX/sigchild" "$SR_ROOT/tests/lib/sigchild.c" || exit 3
/usr/bin/python3 -I - "$FX/big.tgz" <<'EOF' || exit 3
import io, sys, tarfile
class Z(io.RawIOBase):
    def __init__(s, n): s.n = n
    def readable(s): return True
    def readinto(s, b):
        k = min(len(b), s.n); b[:k] = bytes(k); s.n -= k; return k
with tarfile.open(sys.argv[1], 'w:gz', compresslevel=1) as t:
    for name, size in (('Sheepr.app/Contents/Info.plist', 10), ('Sheepr.app/Contents/MacOS/sheepr', 400 * 1024 * 1024)):
        i = tarfile.TarInfo(name); i.size = size; i.uid = i.gid = 0; i.uname = i.gname = ''
        t.addfile(i, io.BufferedReader(Z(size)))
EOF
FXARCOUT=$FX/arc.out; export FXARCOUT
for sg in QUIT USR1 0; do
  case $sg in QUIT) n=3 ;; USR1) n=30 ;; *) n=0 ;; esac
  before=$(ls -d /private/tmp/sr-archive.* 2>/dev/null)
  "$FX/sigchild" tool:bsdtar $n /bin/sh -c 'exec "$0" "$@" > "$FXARCOUT" 2>&1' /bin/sh "$A" check "$FX/big.tgz" > "$FX/sc.o" 2>&1
  sent=$(sed -n 's/^sent //p' "$FX/sc.o"); rc=$(sed -n 's/^rc //p' "$FX/sc.o"); gone=$(sed -n 's/^toolgone //p' "$FX/sc.o")
  after=$(ls -d /private/tmp/sr-archive.* 2>/dev/null)
  if [ $sg = 0 ]; then
    [ "$rc" = 1 ] && grep -q '^archive: ' "$FXARCOUT" && [ "$after" = "$before" ] \
      && pass "control: with no signal the check runs on and refuses the archive by name (1)" || fail "control: rc=$rc out: $(head -2 "$FXARCOUT" | tr '\n' '|') ($(tr '\n' '|' < "$FX/sc.o"))"
  else
    [ -n "$sent" ] && [ "$sent" != none ] && [ "$rc" = 1 ] && [ "$gone" = yes ] && [ ! -s "$FXARCOUT" ] && [ "$after" = "$before" ] \
      && pass "a $sg to archive.sh while tar lists: it waits for tar, exits 1, writes nothing, leaves no temp dir" \
      || fail "$sg while tar lists: sent '$sent' rc=$rc tar gone: $gone out: $(head -2 "$FXARCOUT" | tr '\n' '|') new dirs: $(printf '%s\n' "$after" | grep -v -x -F -e "$before" | tr '\n' ' ')"
  fi
done
finish
