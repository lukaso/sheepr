#!/bin/sh
# The macOS release archive (PHASE3.md §1.5).
#
#   archive.sh make APP OUT.tar.gz          tar APP (Sheepr.app) with no xattrs, ACLs or mac
#                                           metadata, owners 0/0 with no names
#   archive.sh check ARCHIVE [--signed|--signed-unstapled]
#                                           exit 0 only if ARCHIVE holds exactly the bundle; 1 when
#                                           it does not ("archive: ..."); 3 when the check could not
#                                           run ("archive: cannot check: ...": no temp dir, a tar a
#                                           signal stopped, an extraction that fails once the listing
#                                           passed, i.e. a full or unwritable temp dir): no finding
#
# The default macOS tar stores com.apple.provenance and any com.apple.quarantine in pax headers
# that `tar -t` does not show, and extraction restores them; it also stores the user's name.
# check: the regular files are exactly Sheepr.app/Contents/Info.plist and .../MacOS/sheepr
# (with --signed also .../_CodeSignature/CodeResources and the staple ticket .../CodeResources;
# with --signed-unstapled, the control mode's, the signature and no ticket),
# the directories exactly their parents, every entry owned 0/0 with no names, no xattr pax header,
# and no xattr on anything after extraction.
set -u
PATH=/usr/bin:/bin; export PATH
. "$(dirname "$0")/sigs.sh" || exit 1   # SIGS: the signals the cleanup trap catches
usage() { echo "usage: archive.sh make APP OUT.tar.gz | archive.sh check ARCHIVE [--signed|--signed-unstapled]" >&2; exit 2; }
bad() { echo "archive: $*" >&2; exit 1; }
nocheck() { echo "archive: cannot check: $*" >&2; exit 3; }   # (no finding about the archive: r13b F3)
[ $# -ge 2 ] || usage
case $1 in
  make)
    [ $# -eq 3 ] || usage
    app=$2 outf=$3
    [ "$(basename "$app")" = Sheepr.app ] && [ -d "$app" ] || bad "not a Sheepr.app: $app"
    (cd "$(dirname "$app")" && tar --no-xattrs --no-mac-metadata --no-acls --uid 0 --gid 0 --uname '' --gname '' \
      -czf "$outf" Sheepr.app) || bad "tar failed"
    ;;
  check)
    arc=$2 signed=no
    [ $# -le 3 ] || usage
    [ $# -eq 3 ] && case $3 in --signed) signed=yes ;; --signed-unstapled) signed=unstapled ;; *) usage ;; esac
    [ -f "$arc" ] || bad "no archive $arc"
    t=$(mktemp -d /private/tmp/sr-archive.XXXXXX 2>/dev/null || mktemp -d) || nocheck "no temp dir"
    trap 'trap "" $SIGS; rm -rf "$t"' EXIT
    trap 'rm -rf "$t"; exit 1' $SIGS
    want="Sheepr.app/Contents/Info.plist
Sheepr.app/Contents/MacOS/sheepr"
    [ $signed != no ] && want="$want
Sheepr.app/Contents/_CodeSignature/CodeResources"
    [ $signed = yes ] && want="$want
Sheepr.app/Contents/CodeResources"
    want=$(printf '%s\n' "$want" | sort)
    wantdirs=$(printf '%s\n' "$want" | while IFS= read -r f; do d=$(dirname "$f"); while [ "$d" != . ]; do echo "$d/"; d=$(dirname "$d"); done; done | sort -u)
    # the listing: regular files and directories, owners. bsdtar exits 0 when its listing cannot be
    # written (a full temp dir: an empty or a cut listing, read as a defect of the archive;
    # notes/r14b/arc/list2.out, notes/builder/arc14/x.out): a line written after it must land, or there
    # is no listing to judge (a write failure that clears before that line is not seen). tar stays
    # this script's own child (the signal rows send to it there)
    tar -tvzf "$arc" > "$t/list" 2>/dev/null; r_=$?
    [ $r_ -le 125 ] || nocheck "tar stopped by a signal while it listed $arc (exit $r_)"
    [ $r_ = 0 ] || bad "cannot list $arc"
    { printf 'end\n' >> "$t/list"; } 2>/dev/null && [ "$(tail -n 1 "$t/list")" = end ] \
      || nocheck "the listing of $arc could not be written into $t (a full or unwritable temp dir)"
    list=$(sed '$d' "$t/list")
    files=$(printf '%s\n' "$list" | awk '$1 ~ /^-/ {print $NF}' | sort)
    dirs=$(printf '%s\n' "$list" | awk '$1 ~ /^d/ {print $NF}' | sed 's#/*$#/#' | sort -u)
    others=$(printf '%s\n' "$list" | awk '$1 !~ /^[-d]/ && NF')
    [ -z "$others" ] || bad "entries that are neither files nor directories: $others"
    [ "$files" = "$want" ] || bad "the files are not exactly the bundle's: $(printf '%s' "$files" | tr '\n' ' ')"
    [ "$dirs" = "$wantdirs" ] || bad "the directories are not exactly the files' parents: $(printf '%s' "$dirs" | tr '\n' ' ')"
    owners=$(printf '%s\n' "$list" | awk 'NF {print $3 " " $4}' | sort -u)
    [ "$owners" = "0 0" ] || bad "owners are not 0/0 without names: $(printf '%s' "$owners" | tr '\n' ',')"
    gzip -dc "$arc" | grep -a -q -e 'SCHILY.xattr' -e 'LIBARCHIVE.xattr' && bad "an xattr pax header"
    # (the listing passed: an extraction that fails is the temp dir's (full, unwritable) or a signal's)
    mkdir "$t/x" && tar -xzf "$arc" -C "$t/x" || nocheck "cannot extract $arc into $t/x (a full or unwritable temp dir, or a stopped tar)"
    # macOS adds com.apple.provenance to every file this process creates (measured: even
    # `echo > f`), so that one is the extraction's own; any other (quarantine, ...) came from the
    # archive. The pax-header check above is the one that sees what the archive carries.
    ex=$(xattr -lr "$t/x" 2>/dev/null | grep -v ': com.apple.provenance:' || true)
    [ -z "$ex" ] || bad "xattrs after extraction: $ex"
    ;;
  *) usage ;;
esac
