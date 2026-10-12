#!/bin/sh
# The ship plan (PHASE3.md §5): `release.sh __ship-dry vTAG`, ship_run with stand-ins, never `ship`.
# The harness:
#   - git: release.sh's local git calls reach a PATH git shim that skips git's global options, passes
#     only local subcommands (status show rev-parse worktree tag merge-base config cat-file
#     for-each-ref show-ref) to /usr/bin/git, and records anything else (zero in every row); the
#     remote ones go through $GITCMD's stand-in, which answers `remote get-url` with the GitHub
#     spelling and forwards push, fetch and ls-remote to /usr/bin/git against local bare repos (origin
#     is a file:// bare repo; only github.com/lukaso/sheepr is rewritten);
#   - gh, npm, curl, docker, caffeinate, security, osascript: PATH shims that record (zero calls in
#     every row); the stand-ins (by variable, checked as release.sh's standins checks one) answer;
#   - every run is inside lib.sh's no-osascript wall.
set -u
. "$(dirname "$0")/lib.sh"
[ "$(uname -s)" = Darwin ] || { echo "SKIP (macOS only)"; exit 0; }
fx_dir; fx_repo
wall_ok && pass "the wall: a path naming osascript cannot run here, another can" || { fail "the no-osascript wall does not hold: nothing else runs"; finish; }
# main on origin: the base commit; the release commit and its annotated tag only local
g remote add origin "file://$FX/origin.git" && git init -q --bare "$FX/origin.git" && g push -q origin HEAD:refs/heads/main || exit 3
fx_release 0.1.0 1 v0.1.0
C=$(g rev-parse "v0.1.0^{commit}"); T=$(g rev-parse v0.1.0)
g config fetch.prune true && g config fetch.pruneTags true && g config push.followTags true && g tag -a x-follow -m x-follow HEAD~1 || exit 3
BASE=$(g rev-parse HEAD~1)
OUTR=$FX/out
mkdir -p "$FX/rc/scripts/lib" "$FX/rc/packaging/homebrew" && cp "$REPO/scripts/lib/render-cask.sh" "$FX/rc/scripts/lib/" \
  && cp "$REPO/packaging/homebrew/sheepr.rb.in" "$FX/rc/packaging/homebrew/" || exit 3
tapset() { sh "$FX/rc/scripts/lib/render-cask.sh" "$1" "${2:-$(printf '%064d' 7)}" "$FX/tap/sheepr.rb" || exit 3; }
# the PATH shims: record, never answer; the git shim forwards local subcommands only
B=$FX/bin; mkdir -p "$B"
for t in gh npm curl docker caffeinate security; do
  printf '#!/bin/sh\necho "PATH %s $*" >> "%s/pathcalls"\nexit 1\n' "$t" "$FX" > "$B/$t"; chmod +x "$B/$t"
done
cat > "$B/git" <<EOF
#!/bin/sh
# skip git's global options, then classify the subcommand
i=1; sub=""; skip=0
for x; do
  if [ \$skip = 1 ]; then skip=0; i=\$((i + 1)); continue; fi
  case \$x in
    -C|-c) skip=1 ;;
    --git-dir=*|--work-tree=*|--no-pager|-c*|-C*) ;;
    *) sub=\$x; break ;;
  esac
  i=\$((i + 1))
done
case \$sub in
  status|show|rev-parse|worktree|tag|merge-base|config|cat-file|for-each-ref|show-ref) exec /usr/bin/git "\$@" ;;
esac
echo "PATH git \$*" >> "$FX/pathcalls"
exit 1
EOF
chmod +x "$B/git"
printf '#!/bin/sh\necho "$1" >> "%s/sleeps"\n' "$FX" > "$B/sleep"; chmod +x "$B/sleep"
# the stand-ins (in the fixtures, by variable): each records "NAME args" in calls and whether its
# HOME exists
S=$FX/st; mkdir -p "$S"
standin() { # name body
  { printf '#!/bin/sh\n[ -d "$HOME" ] || echo "NOHOME %s" >> "%s/calls"\necho "%s $*" >> "%s/calls"\n' "$1" "$FX" "$1" "$FX"; printf '%s\n' "$2"; } > "$S/$1"
  chmod +x "$S/$1"
}
standin notify 'exit 0'
standin caffeinate 'exit 0'
standin identity 'echo "  1) 1E3722600BE155B5134D6CCBFEF916BBC8372854 \"Developer ID Application: X (P7UM972E39)\""; echo "     1 valid identities found"'
standin curl "cat '$FX/up/sheepr-macos-universal.tar.gz'"
# the build's stand-in: called as `<release.sh> build --sign --out OUT TAG`; makes the finished
# build in OUT/TAG (as mkbuild does) at the frozen tree's commit ($FX/build.other: another commit),
# or fails ($FX/buildfail); $FX/onbuild runs first (a script)
cat > "$S/build" <<EOF
#!/bin/sh
[ -d "\$HOME" ] || echo "NOHOME build" >> "$FX/calls"
echo "build \$*" >> "$FX/calls"
[ -e "$FX/onbuild" ] && sh "$FX/onbuild"
[ -e "$FX/buildfail" ] && { echo "build: failed (stand-in)" >&2; exit 1; }
rs=\$1 o=\$5 tg=\$6; v=\${tg#v}; d=\$o/\$tg
c=\$(cat "$FX/build.other" 2>/dev/null || git -C "\$(dirname "\$rs")/.." rev-parse HEAD)
mkdir -p "\$d" || exit 1
for f in sheepr-macos-universal.tar.gz sheepr-linux-aarch64 sheepr-linux-x86_64 install.sh sheepr-\$v.tgz sheepr-darwin-universal-\$v.tgz sheepr-linux-arm64-\$v.tgz sheepr-linux-x64-\$v.tgz; do echo "\$f \$d" > "\$d/\$f"; done
(cd "\$d" && shasum -a 256 sheepr-macos-universal.tar.gz sheepr-linux-aarch64 sheepr-linux-x86_64 install.sh > SHA256SUMS)
{ printf '{\n  "v": 1,\n  "tag": "%s",\n  "commit": "%s",\n  "mode": "signed",\n  "control": false,\n  "files": [\n' "\$tg" "\$c"
  sep=""; for f in sheepr-macos-universal.tar.gz sheepr-linux-aarch64 sheepr-linux-x86_64 install.sh sheepr-\$v.tgz sheepr-darwin-universal-\$v.tgz sheepr-linux-arm64-\$v.tgz sheepr-linux-x64-\$v.tgz; do
    printf '%s    {"name": "%s", "sha256": "%s"}' "\$sep" "\$f" "\$(shasum -a 256 "\$d/\$f" | cut -d' ' -f1)"; sep=",
"; done; printf '\n  ]\n}\n'; } > "\$d/MANIFEST.json"
sh "\$(dirname "\$rs")/lib/render-cask.sh" "\$v" "\$(shasum -a 256 "\$d/sheepr-macos-universal.tar.gz" | cut -d' ' -f1)" "\$d/sheepr.rb"
EOF
chmod +x "$S/build"
# npm-check's stand-in: writes the stamp for the manifest it is given ($FX/npmcheckfail: refuses;
# $FX/npmcheck.swap: changes the manifest and stamps the changed one)
cat > "$S/npmcheck" <<EOF
#!/bin/sh
[ -d "\$HOME" ] || echo "NOHOME npmcheck" >> "$FX/calls"
echo "npmcheck \$*" >> "$FX/calls"
[ -e "$FX/npmcheckfail" ] && { echo "npm-check: refused (stand-in)" >&2; exit 1; }
d=\$1; tg=\$(basename "\$d")
[ -e "$FX/npmcheck.swap" ] && echo ' ' >> "\$d/MANIFEST.json"
printf '%s %s\n' "\$tg" "\$(shasum -a 256 "\$d/MANIFEST.json" | cut -d' ' -f1)" > "\$d/NPM-CHECKED"
EOF
chmod +x "$S/npmcheck"
# gh's stand-in: A4's release list (tag, draft, prerelease: $FX/rels), the repos' write rights, the
# tap's cask ($FX/tap/sheepr.rb), and publish's own calls (as t_publish_dry's stand-in answers them)
mkdir -p "$FX/tap"
cat > "$S/gh" <<EOF
#!/bin/sh
[ -d "\$HOME" ] || echo "NOHOME gh" >> "$FX/calls"
echo "gh \$*" >> "$FX/calls"
case "\$*" in
  *"@tsv"*) [ -e "$FX/relsfail" ] && { echo "gh: HTTP 502" >&2; exit 1; }; tr ' ' '\t' < "$FX/rels" ;;
  *".[].tag_name"*) awk '{print \$1}' "$FX/rels" ;;
  *"repos/lukaso/sheepr --jq .permissions.push"*) cat "$FX/repoperm" 2>/dev/null || echo true ;;
  *"repos/lukaso/homebrew-tap --jq .permissions.push"*) cat "$FX/tapperm" 2>/dev/null || echo true ;;
  *"-X PUT repos/lukaso/homebrew-tap/contents/Casks/sheepr.rb"*)
    [ -e "$FX/putfail" ] && { echo "gh: HTTP 409" >&2; exit 1; }
    for a; do case \$a in content=*) printf '%s' "\${a#content=}" | base64 -d > "$FX/tap/sheepr.rb" ;; esac; done
    echo c0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ff ;;
  *"homebrew-tap/contents/Casks/sheepr.rb"*) [ -f "$FX/tap/sheepr.rb" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }; cat "$FX/tap/sheepr.rb" ;;
  *"releases/tags/"*"--jq .draft, (.assets"*|*"releases/4242 --jq .draft, (.assets"*)
    echo false; i=0; for f in \$(ls "$FX/up"); do i=\$((i+1)); [ "\$f" = sheepr-macos-universal.tar.gz ] && echo \$i; done ;;
  "api -X POST repos/lukaso/sheepr/releases "*) [ -e "$FX/postfail" ] && exit 1; echo 4242 ;;
  *"uploads.github.com"*) prev=""; for a; do case \$a in *assets\\?name=*) nm=\${a##*name=} ;; esac; [ "\$prev" = --input ] && in=\$a; prev=\$a; done
    mkdir -p "$FX/up"; cp "\$in" "$FX/up/\$nm"; echo 1 ;;
  "api repos/lukaso/sheepr/releases/4242 --jq .assets"*) i=0; for f in \$(ls "$FX/up"); do i=\$((i+1)); echo "\$i \$f"; done ;;
  *"releases/assets/"*) for a; do last=\$a; done; id=\${last##*/}; f=\$(ls "$FX/up" | sed -n "\${id}p"); cat "$FX/up/\$f" ;;
  *"PATCH"*) [ -e "$FX/patchfail" ] && exit 1; [ -e "$FX/patch5" ] && : > "$FX/notpublished" ;;
  *"--jq .draft"*) echo false ;;
esac
exit 0
EOF
chmod +x "$S/gh"
# npm's stand-in: views (a version's integrity, a name's time record, its latest tag), owners, the
# userconfig and the session it holds ($FX/npmrc: a token line is a session), login, logout, publish
cat > "$S/npm" <<EOF
#!/bin/sh
[ -d "\$HOME" ] || echo "NOHOME npm" >> "$FX/calls"
echo "npm \$*" >> "$FX/calls"
echo "\${NODE_EXTRA_CA_CERTS:-none} \$1" >> "$FX/npmenvs"
last=""; for a; do last=\$a; done
TOK='//registry.npmjs.org/:_authToken='
case \$1 in
  view) p=""; for a; do case \$a in sheepr*) p=\${a%@*} ;; esac; done
    [ -e "$FX/viewfail.\$p" ] && { echo "npm error code ETIMEDOUT" >&2; exit 1; }
    case \$last in
      time) cat "$FX/time.\$p" 2>/dev/null || printf '{\n  "created": "2026-10-01T00:00:00.000Z",\n  "0.0.9": "2026-10-02T00:00:00.000Z"\n}\n'; exit 0 ;;
      dist-tags.latest) printf '"%s"\n' "\$(cat "$FX/latest.\$p" 2>/dev/null || echo 0.0.9)"; exit 0 ;;
    esac
    [ -e "$FX/viewfailv.\$p" ] && { echo "npm error code ETIMEDOUT" >&2; exit 1; }   # the version's view only
    if [ -f "$FX/pub.\$p" ]; then
      k=\$(cat "$FX/processing.\$p" 2>/dev/null || echo 0)
      if [ "\$k" -gt 0 ]; then echo \$((k - 1)) > "$FX/processing.\$p"; echo "npm error code E404" >&2; exit 1; fi
      printf '"%s"\n' "\$(cat "$FX/pub.\$p")"; exit 0
    fi
    if [ -f "$FX/view.\$p" ]; then printf '"%s"\n' "\$(cat "$FX/view.\$p")"; exit 0; fi
    printf '{\n  "error": {\n    "code": "E404"\n  }\n}\n'; echo "npm error code E404" >&2; exit 1 ;;
  owner) if [ -f "$FX/owner.\$3" ]; then echo "\$(cat "$FX/owner.\$3") <x@example.com>"; else echo "lukasco <x@example.com>"; fi; exit 0 ;;
  config) [ "\$2 \$3" = "get userconfig" ] && { echo "$FX/npmrc"; exit 0; } ;;
  whoami) [ -e "$FX/whoamibad" ] && { echo "npm error code ETIMEDOUT" >&2; exit 1; }
    if grep -q "^\$TOK" "$FX/npmrc" 2>/dev/null; then
      [ -e "$FX/whoamibad2" ] && { echo "npm error code ETIMEDOUT" >&2; exit 1; }
      [ -e "$FX/expired" ] && { echo "npm error code E401" >&2; exit 1; }
      cat "$FX/whoami" 2>/dev/null || echo lukasco; exit 0
    fi
    echo "npm error code ENEEDAUTH" >&2; exit 1 ;;
  login) [ -e "$FX/loginfail" ] && exit 1; echo "\${TOK}npm_dry" >> "$FX/npmrc"; exit 0 ;;
  logout) [ -e "$FX/logoutfail" ] && exit 1; grep -v "^\$TOK" "$FX/npmrc" > "$FX/npmrc.n" 2>/dev/null; mv "$FX/npmrc.n" "$FX/npmrc"; exit 0 ;;
  publish) p=\$(basename "\$last" | sed 's/^\(.*\)-[0-9][0-9.a-z-]*\.tgz\$/\1/')
    [ -e "$FX/pubfail.\$p" ] && { echo "npm error code E401" >&2; exit 1; }
    python3 -c 'import base64, hashlib, sys; print("sha512-" + base64.b64encode(hashlib.sha512(open(sys.argv[1], "rb").read()).digest()).decode())' "\$last" > "$FX/pub.\$p"
    exit 0 ;;
esac
exit 1
EOF
chmod +x "$S/npm"
# docker's stand-in: the daemon answers (or $FX/nodocker), the images are there (or $FX/noimage)
cat > "$S/docker" <<EOF
#!/bin/sh
[ -d "\$HOME" ] || echo "NOHOME docker" >> "$FX/calls"
echo "docker \$*" >> "$FX/calls"
case \$1 in info) [ -e "$FX/nodocker" ] && exit 1; exit 0 ;;
  image) case \$3 in rust:*) [ -e "$FX/nobase" ] && exit 1 ;; sr-amd64-*) [ -e "$FX/noamd64" ] && exit 1 ;; esac; exit 0 ;; esac
exit 1
EOF
chmod +x "$S/docker"
# the notary keychain file the build needs (its existence only), and the tap's cask (0.0.9)
mkdir -p "$FX/ghome/Library/Keychains" && : > "$FX/ghome/Library/Keychains/sheepr-notary.keychain-db"
tapset 0.0.9
echo "v0.0.9 false false" > "$FX/rels"
# a finished build in the out dir (as t_publish_dry's mkout makes one): the files, the manifest of
# DIR's tag and COMMIT, npm-check's stamp, the cask
mkbuild() { # dir tag commit [control]
  rm -rf "$1"; mkdir -p "$1"; v=${2#v}
  for f in sheepr-macos-universal.tar.gz sheepr-linux-aarch64 sheepr-linux-x86_64 install.sh \
           sheepr-$v.tgz sheepr-darwin-universal-$v.tgz sheepr-linux-arm64-$v.tgz sheepr-linux-x64-$v.tgz; do echo "$f $1" > "$1/$f"; done
  (cd "$1" && shasum -a 256 sheepr-macos-universal.tar.gz sheepr-linux-aarch64 sheepr-linux-x86_64 install.sh > SHA256SUMS)
  { printf '{\n  "v": 1,\n  "tag": "%s",\n  "commit": "%s",\n  "mode": "signed",\n  "control": %s,\n  "files": [\n' "$2" "$3" "${4:-false}"
    sep=""; for f in sheepr-macos-universal.tar.gz sheepr-linux-aarch64 sheepr-linux-x86_64 install.sh \
                     sheepr-$v.tgz sheepr-darwin-universal-$v.tgz sheepr-linux-arm64-$v.tgz sheepr-linux-x64-$v.tgz; do
      printf '%s    {"name": "%s", "sha256": "%s"}' "$sep" "$f" "$(shasum -a 256 "$1/$f" | cut -d' ' -f1)"; sep=",
"; done; printf '\n  ]\n}\n'; } > "$1/MANIFEST.json"
  printf '%s %s\n' "$2" "$(shasum -a 256 "$1/MANIFEST.json" | cut -d' ' -f1)" > "$1/NPM-CHECKED"
  sh "$FX/rc/scripts/lib/render-cask.sh" "$v" "$(shasum -a 256 "$1/sheepr-macos-universal.tar.gz" | cut -d' ' -f1)" "$1/sheepr.rb" || exit 3
}
# $GITCMD's stand-in: `remote get-url` answered with the GitHub spelling ($FX/pushurl, $FX/fetchurl);
# push, fetch and ls-remote forwarded to /usr/bin/git, with only github.com/lukaso/sheepr rewritten
# (to $FX/updir, origin's bare repo by default); $FX/dryextra adds a line to a dry-run push;
# $FX/onpush runs once before the first real push, $FX/afterpush after each real push that succeeded;
# $FX/pushlie (tag or main): a real push sends only that refspec, then fails; $FX/mirror (none, tag;
# default all): what a real push that succeeded also sends to $FX/updir
cat > "$S/sgit" <<EOF
#!/bin/sh
[ -d "\$HOME" ] || echo "NOHOME sgit" >> "$FX/calls"
echo "sgit \$*" >> "$FX/calls"
c=""; if [ "\$1" = -C ]; then c=\$2; shift 2; fi
if [ "\$1 \$2" = "remote get-url" ]; then
  case " \$* " in *" --push "*) cat "$FX/pushurl" 2>/dev/null || echo https://github.com/lukaso/sheepr.git ;; *) cat "$FX/fetchurl" 2>/dev/null || echo https://github.com/lukaso/sheepr.git ;; esac
  exit 0
fi
up=\$(cat "$FX/updir" 2>/dev/null || echo "file://$FX/origin.git")
n=\$#; for a; do [ "\$a" = https://github.com/lukaso/sheepr ] && a=\$up; set -- "\$@" "\$a"; done; shift \$n
extra="" real=no lie=""
[ "\$1" = ls-remote ] && [ -e "$FX/lsfailafter" ] && [ -e "$FX/pushtried" ] && { echo "fatal: unable to access (stand-in)" >&2; exit 128; }
if [ "\$1" = push ]; then
  case " \$* " in *" --dry-run "*) [ -e "$FX/dryextra" ] && extra=1 ;; *) real=yes; : > "$FX/pushtried"; [ -e "$FX/onpush" ] && [ ! -e "$FX/onpush.done" ] && { : > "$FX/onpush.done"; sh "$FX/onpush"; } ;; esac
fi
if [ \$real = yes ] && [ -e "$FX/pushlie" ]; then
  lie=\$(cat "$FX/pushlie")
  n=\$#; for a; do case \$a in *:refs/tags/*) [ "\$lie" = tag ] || continue ;; *:refs/heads/*) [ "\$lie" = main ] || continue ;; esac; set -- "\$@" "\$a"; done; shift \$n
fi
[ -z "\$c" ] || set -- -C "\$c" "\$@"
GIT_CONFIG_NOSYSTEM=1 /usr/bin/git "\$@"; r=\$?
[ -z "\$extra" ] || printf '*\trefs/heads/x:refs/heads/x\t[new branch]\n'
if [ \$real = yes ] && [ \$r = 0 ]; then
  [ ! -e "$FX/afterpush" ] || sh "$FX/afterpush"
  # mirrored to \$FX/updir when one is set (in the real world origin and github.com/lukaso/sheepr
  # are one repo)
  mk=\$(cat "$FX/mirror" 2>/dev/null || echo all)
  if [ -e "$FX/updir" ] && [ "\$mk" != none ]; then
    n=\$#; for a; do case \$a in origin) a=\$up ;; *:refs/heads/*) [ "\$mk" = tag ] && continue ;; esac; set -- "\$@" "\$a"; done; shift \$n
    GIT_CONFIG_NOSYSTEM=1 /usr/bin/git "\$@" >/dev/null 2>&1 || echo "MIRROR FAILED" >> "$FX/calls"
  fi
fi
[ -z "\$lie" ] || exit 1
exit \$r
EOF
chmod +x "$S/sgit"

ship() { # args... -> rc; output in $FX/o. The default stand-ins; NO: names whose variable is left out;
         # SETX: one more assignment
  rm -f "$FX/calls" "$FX/pathcalls" "$FX/asks" "$FX/npmenvs"
  set -- SR_ASK_RECORD="$FX/asks" SR_SHIP_DRY_BUILD="$S/build" SR_SHIP_DRY_NPMCHECK="$S/npmcheck" SR_SHIP_DRY_NOTIFY="$S/notify" SR_SHIP_DRY_CAFFEINATE="$S/caffeinate" \
    SR_SHIP_DRY_IDENTITY="$S/identity" SR_SHIP_DRY_DOCKER="$S/docker" SR_PUBLISH_DRY_GH="$S/gh" SR_PUBLISH_DRY_GIT="$S/sgit" \
    SR_PUBLISH_DRY_NPM="$S/npm" SR_PUBLISH_DRY_CURL="$S/curl" $( [ "${VERIFIED:-}" = - ] || printf '%s' "SR_PUBLISH_DRY_VERIFIED=${VERIFIED:-$AH}" ) "$@"
  envs=""; for a; do case $a in *=*) k=${a%%=*}; case " ${NO:-} " in *" $k "*) continue ;; esac; envs="$envs
$a" ;; esac; done
  # the assignments as arguments to env, one per line (a value may hold spaces)
  printf '%s\n' "$envs" | sed '/^$/d' > "$FX/envs"
  (cd "$REPO" && IFS='
'; no_osascript env -i PATH="$B:/usr/bin:/bin" HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    $(cat "$FX/envs") ${SETX:+"$SETX"} sh scripts/release.sh __ship-dry --out "${OUT:-$OUTR}" "${TAG:-v0.1.0}") > "$FX/o" 2>&1; r_=$?
  world_reset; return $r_
}
# what a run changed, kept for the rows (origin's refs, the tap's cask), then put back: origin's main
# at BASE and no v0.1.0 tag, npm with nothing published, the tap at 0.0.9, no uploads
world_reset() {
  git --git-dir="$FX/origin.git" for-each-ref --format='%(objectname) %(refname)' > "$FX/origin.after"
  cp "$FX/tap/sheepr.rb" "$FX/tap.after" 2>/dev/null || : > "$FX/tap.after"
  git --git-dir="$FX/origin.git" update-ref refs/heads/main "$BASE" && git --git-dir="$FX/origin.git" update-ref -d refs/tags/v0.1.0 2>/dev/null
  rm -rf "$FX"/pub.* "$FX/up" "$FX"/processing.* "$FX/pushtried"; tapset 0.0.9
  cp "$FX/npmrc" "$FX/npmrc.after" 2>/dev/null || : > "$FX/npmrc.after"
  [ ! -f "$FX/npmrc" ] || { grep -v '_authToken=npm_dry$' "$FX/npmrc" > "$FX/npmrc.n"; mv "$FX/npmrc.n" "$FX/npmrc"; }
}
completed() { [ $r = 0 ] && grep -q 'release: ship: v0.1.0 is public on GitHub, Homebrew and npm' "$FX/o"; }
nopath() { [ ! -s "$FX/pathcalls" ]; }
# the archive hash verify (dry) judges: the build stand-in's archive for $OUTR/v0.1.0
AH=$(printf 'sheepr-macos-universal.tar.gz %s\n' "$OUTR/v0.1.0" | shasum -a 256 | cut -d' ' -f1)

# --- the walls: each stand-in is checked as release.sh's standins checks one; a real tool, or none,
# is refused before any call
for v in SR_SHIP_DRY_BUILD SR_SHIP_DRY_NPMCHECK SR_SHIP_DRY_NOTIFY SR_SHIP_DRY_CAFFEINATE SR_SHIP_DRY_IDENTITY SR_SHIP_DRY_DOCKER \
    SR_PUBLISH_DRY_GH SR_PUBLISH_DRY_GIT SR_PUBLISH_DRY_NPM SR_PUBLISH_DRY_CURL; do
  NO=$v; ship; r=$?; NO=
  [ $r = 1 ] && [ ! -e "$FX/calls" ] && nopath && grep -q "$v is not an executable file" "$FX/o" && pass "no $v: refused before any call" || fail "no $v: rc=$r $(tail -1 "$FX/o")"
done
for spec in "SR_SHIP_DRY_NOTIFY|$REPO/scripts/lib/notify.sh|the real notify.sh" "SR_SHIP_DRY_CAFFEINATE|/usr/bin/caffeinate|must be a stand-in" \
    "SR_SHIP_DRY_IDENTITY|/usr/bin/security|must be a stand-in" "SR_SHIP_DRY_DOCKER|docker|not an executable file"; do
  v=${spec%%|*} rest=${spec#*|}; val=${rest%%|*} why=${rest#*|}
  SETX="$v=$val"; ship; r=$?; SETX=
  [ $r = 1 ] && [ ! -e "$FX/calls" ] && nopath && grep -q "$v" "$FX/o" && grep -q "$why" "$FX/o" && pass "$v=$val (a real one): refused before any call" || fail "$v=$val: rc=$r $(tail -1 "$FX/o")"
done
# the real entry's values and the dispatch, by text (no cell runs ship)
RS=$SR_ROOT/scripts/release.sh
fbody() { sed -n "/^$1() {/,/^}/p" "$RS"; }   # (a pattern with () inside a $( ) ends it early under bash 3.2)
want_ship='ship() {
  SHIP_BUILD=/bin/sh SHIP_NPMCHECK=npm_check SHIP_VERIFY=verify NOTIFY=frozen-tree CAFFEINATE=/usr/bin/caffeinate SHIP_IDENTITY=/usr/bin/security SHIP_DOCKER=docker
  real_tools
  shipping=yes
  ship_run
}'
[ "$(fbody ship)" = "$want_ship" ] && [ "$(grep -c '^ship() {' "$RS")" = 1 ] && pass "ship: exactly its pinned body, defined once" || fail "ship's body: $(fbody ship | tr '\n' ' ')"
grep -qxF '  ship) ship ;;' "$RS" && grep -qxF '  __ship-dry) ship_dry ;;' "$RS" && pass "the dispatch: ship and __ship-dry" || fail "the dispatch arms"
# the gate: ship is one of its entries, and its one question
grep -qF 'if { [ "$sub" = build ] && [ $sign = yes ]; } || [ "$sub" = publish ] || [ "$sub" = publish-cask ] || [ "$sub" = publish-npm ] || [ "$sub" = ship ]; then' "$RS" \
  && pass "the gate covers ship" || fail "the gate's condition"
grep -qF 'release: ship %s: build, sign and notarize it, push main and the tag, publish it on GitHub, update lukaso/homebrew-tap and publish the four npm packages. Type the tag to go on: ' "$RS" \
  && pass "ship's one question, word for word" || fail "ship's question"
# real_tools refuses in a dry entry (the dry entries set the marker first)
[ "$(fbody real_tools | sed -n 2p)" = '  [ "$dryentry" = no ] || die "real_tools in a dry entry"' ] && pass "real_tools refuses in a dry entry" || fail "real_tools: $(fbody real_tools | tr '\n' ' ')"
bad=""; for e in publish_dry publish_cask_dry publish_npm_dry ship_dry; do [ "$(fbody $e | sed -n 2p)" = '  dryentry=yes' ] || bad="$bad $e"; done
[ -z "$bad" ] && pass "every dry entry sets the dry marker first" || fail "no dry marker first in:$bad"

# --- the tag and the out dir: a final tag only; a relative --out made absolute; the lock
TAG=v0.1.0-rc.1; ship; r=$?; TAG=
[ $r = 1 ] && [ ! -e "$FX/calls" ] && grep -q 'an rc' "$FX/o" && grep -q 'separate entries' "$FX/o" && [ ! -e "$OUTR" ] && pass "an rc tag: refused, the separate entries named, nothing made" || fail "rc: rc=$r $(tail -1 "$FX/o")"
TAG='v0.1.0;x'; ship; r=$?; TAG=
[ $r = 1 ] && [ ! -e "$OUTR" ] && pass "a tag off the grammar: refused before any path is made" || fail "bad tag: rc=$r $(tail -1 "$FX/o")"
mkdir -p "$OUTR/.ship.lock"; echo 99999 > "$OUTR/.ship.lock/pid"; ship; r=$?
[ $r = 1 ] && [ "$(cat "$OUTR/.ship.lock/pid")" = 99999 ] && grep -q "$OUTR/.ship.lock" "$FX/o" && [ ! -e "$OUTR/.v0.1.0.ship-progress" ] && [ ! -e "$OUTR/v0.1.0.ship-next.txt" ] \
  && pass "a held lock: refused, the lock and its pid left, the directory named, no file written" || fail "held lock: rc=$r $(tail -1 "$FX/o") $(ls -A "$OUTR")"
rm -rf "${OUTR:?}"
ship; r=$?
grep -q '^run ' "$OUTR/.v0.1.0.ship-progress" 2>/dev/null && [ ! -e "$OUTR/.ship.lock" ] && pass "a run that took the lock (its progress file started) removes it at its end" || fail "the lock: progress '$(head -1 "$OUTR/.v0.1.0.ship-progress" 2>/dev/null)', lock $(ls -d "$OUTR/.ship.lock" 2>/dev/null) $(tail -1 "$FX/o")"
nopath && pass "no PATH tool was called (git's local subcommands aside)" || fail "PATH calls: $(cat "$FX/pathcalls")"
# a relative --out is made absolute from where ship ran: a held lock there is named by its absolute path
rm -rf "${OUTR:?}"; mkdir -p "$FX/rel/out/.ship.lock"
(cd "$FX" && no_osascript env -i PATH="$B:/usr/bin:/bin" HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 $(cat "$FX/envs") \
  sh "$REPO/scripts/release.sh" __ship-dry --out rel/out v0.1.0) > "$FX/o" 2>&1
grep -qF "another ship holds $FX/rel/out/.ship.lock" "$FX/o" && pass "a relative --out: made absolute from where ship ran (the lock named by its absolute path)" || fail "relative out: $(tail -1 "$FX/o")"
rm -rf "${FX:?}/rel"

# --- A1 to A3: the checks in the checkout, the $0 compare, the frozen tree, the push target, the
# fetch, the ancestry and the dry-run push (the run goes on to the phases after them)
lastline() { tail -1 "$FX/o"; }
reached_a4() { completed; }
rm -rf "${OUTR:?}"; ship; r=$?
WTP='/private/tmp/sr-ship\.[A-Za-z0-9]*/tree'
grep -q "^sgit -C $WTP push --dry-run --porcelain --atomic --no-follow-tags origin $C:refs/heads/main $T:refs/tags/v0.1.0\$" "$FX/calls" \
  && pass "the dry-run push: exactly main at the tag's commit and the tag object, atomic, --no-follow-tags, from the frozen tree" || fail "the dry-run push: $(grep 'push' "$FX/calls" | head -2 | tr '\n' ' ') $(lastline)"
grep -q "^sgit -C $WTP fetch -q origin main\$" "$FX/calls" && pass "origin's main fetched with its refspec, in the frozen tree" || fail "the fetch: $(grep fetch "$FX/calls" | head -1)"
grep -q "^sgit -C $WTP ls-remote origin refs/heads/main refs/tags/v0\.1\.0\*\$" "$FX/calls" && grep -q "^sgit -C $WTP ls-remote https://github.com/lukaso/sheepr refs/heads/main refs/tags/v0\.1\.0\*\$" "$FX/calls" \
  && pass "ls-remote of origin and of github.com/lukaso/sheepr" || fail "ls-remote: $(grep ls-remote "$FX/calls" | tr '\n' ' ')"
[ "$(g rev-parse -q --verify refs/tags/v0.1.0)" = "$T" ] && pass "the unpushed tag survives the fetch (fetch.prune and pruneTags on)" || fail "the local tag is gone"
[ "$(sort "$FX/origin.after" | tr '\n' ' ')" = "$(printf '%s refs/heads/main\n%s refs/tags/v0.1.0\n' "$C" "$T" | sort | tr '\n' ' ')" ] \
  && pass "the push reached origin: main at the tag's commit and the tag object, nothing else (not x-follow, push.followTags on)" || fail "origin after: $(tr '\n' ' ' < "$FX/origin.after")"
[ "$(g worktree list | grep -c .)" = 1 ] && pass "the frozen tree is removed at the end" || fail "worktrees left: $(g worktree list | tr '\n' ' ')"
nopath && pass "no git call outside \$GITCMD reached the network (the PATH shim saw local subcommands only)" || fail "PATH calls: $(cat "$FX/pathcalls")"
# the $0 compare: an edit hidden from git status (assume-unchanged) is still refused
g update-index --assume-unchanged scripts/release.sh && cp "$REPO/scripts/release.sh" "$FX/rs.keep" && echo '# an edit' >> "$REPO/scripts/release.sh"
rm -rf "${OUTR:?}"; ship; r=$?
cp "$FX/rs.keep" "$REPO/scripts/release.sh"; g update-index --no-assume-unchanged scripts/release.sh
[ $r = 1 ] && grep -q "is not v0.1.0's" "$FX/o" && ! grep -q '^sgit' "$FX/calls" 2>/dev/null && pass "a scripts/release.sh that is not the tag's (assume-unchanged): refused before any remote call" || fail "\$0 compare: rc=$r $(lastline)"
# the push target
pt_row() { # label want-text: set up by the caller; one run
  rm -rf "${OUTR:?}"; ship; r=$?
  [ $r = 1 ] && grep -q "$2" "$FX/o" && ! grep -q 'push --dry-run' "$FX/calls" && pass "$1: refused before any push" || fail "$1: rc=$r $(lastline)"
}
echo https://github.com/someone/sheepr.git > "$FX/pushurl"; pt_row "a push URL that is not lukaso/sheepr" "is not lukaso/sheepr"; rm -f "$FX/pushurl"
echo git@gh-alias:lukaso/sheepr.git > "$FX/pushurl"; pt_row "an ssh host alias" "ssh host alias"; rm -f "$FX/pushurl"
printf 'https://github.com/lukaso/sheepr.git\ngit@github.com:lukaso/sheepr.git\n' > "$FX/pushurl"; pt_row "two push URLs" "push URLs"; rm -f "$FX/pushurl"
echo https://example.com/lukaso/sheepr.git > "$FX/fetchurl"; pt_row "a fetch URL that is not lukaso/sheepr" "is not lukaso/sheepr"; rm -f "$FX/fetchurl"
for u in git@github.com:lukaso/sheepr.git https://github.com/lukaso/sheepr ssh://git@github.com/lukaso/sheepr.git; do
  echo "$u" > "$FX/pushurl"; echo "$u" > "$FX/fetchurl"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/pushurl" "$FX/fetchurl"
  grep -q 'push --dry-run' "$FX/calls" && pass "control: origin as $u: accepted" || fail "control: origin as $u: $(lastline)"
done
# origin and github.com/lukaso/sheepr disagree (two bare repos)
# (the fixture's own pushes say --no-follow-tags: push.followTags is on here, and would add v0.1.0)
git init -q --bare "$FX/origin2.git" && g push -q --no-follow-tags "file://$FX/origin2.git" "$C:refs/heads/main" || exit 3
echo "file://$FX/origin2.git" > "$FX/updir"; pt_row "origin and github.com/lukaso/sheepr disagree on main" "disagree"; rm -f "$FX/updir"
# origin's main diverged from the tag's commit
g branch -q side "$BASE" && (cd "$REPO" && env HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  git commit-tree -p "$BASE" -m side "$BASE^{tree}" > "$FX/side") && g push -q -f --no-follow-tags origin "$(cat "$FX/side"):refs/heads/main" || exit 3
pt_row "origin's main diverged from the tag's commit" "diverged"
g push -q -f --no-follow-tags origin "$BASE:refs/heads/main" || exit 3
# a dry run that lists another ref than the intended two
: > "$FX/dryextra"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/dryextra"
[ $r = 1 ] && grep -q 'dry-run push' "$FX/o" && pass "a dry-run push that lists another ref: refused" || fail "dry-run extra: rc=$r $(lastline)"
# an rc tag of this version on github.com/lukaso/sheepr only (a second bare repo, the same main; the
# push mirrored there): A2's glob lists it and its agreement ignores it, and so does C7's planner
rm -rf "${FX:?}/origin2.git"; git init -q --bare "$FX/origin2.git" && g push -q --no-follow-tags "file://$FX/origin2.git" "$BASE:refs/heads/main" \
  && g push -q --no-follow-tags "file://$FX/origin2.git" "$BASE:refs/tags/v0.1.0-rc.1" || exit 3
echo "file://$FX/origin2.git" > "$FX/updir"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/updir"
grep -q 'push --dry-run' "$FX/calls" && grep -q '^gh api -X PATCH' "$FX/calls" && reached_a4 v0.1.0 && ! grep -q 'MIRROR FAILED' "$FX/calls" \
  && pass "an rc tag of this version on github.com/lukaso/sheepr only: ignored (A2, C7's planner), the run completes" || fail "rc tag upstream: $(lastline)"
# the text: no push, fetch or ls-remote git call in release.sh outside $GITCMD (the pattern: the
# word git, then a subcommand among them; a planted line is caught)
gitnet() { grep -n -E '(^|[^A-Za-z_$"])git( -C [^ ]+| -c [^ ]+)* (push|fetch|ls-remote)( |$)' "$1" | grep -v '^[0-9]*: *#'; }
[ -z "$(gitnet "$RS")" ] && pass "release.sh makes no push, fetch or ls-remote but through \$GITCMD" || fail "git network calls: $(gitnet "$RS" | head -2 | tr '\n' ' ')"
printf '  git -C "$root" fetch origin main\n' > "$FX/planted.sh"; [ -n "$(gitnet "$FX/planted.sh")" ] && pass "control: a planted 'git -C \"\$root\" fetch origin main' is caught" || fail "control: the planted line is not caught"

# --- A4 to A8: nothing of the version public; the tap; npm (owners, no session); the build's
# preconditions, or a finished build's checks; then armed
reached_end3() { completed; }
nobuild() { ! grep -q '^build ' "$FX/calls" 2>/dev/null && ! grep -q '^notify ' "$FX/calls" 2>/dev/null; }
rm -rf "${OUTR:?}"; ship; r=$?
reached_end3 && pass "a clean pre-flight: A1 to A8 pass" || fail "the clean pre-flight: $(lastline)"
grep -q '^docker info' "$FX/calls" && grep -q '^identity find-identity -v -p codesigning' "$FX/calls" && pass "no build yet: Docker, the images and the signing identity checked" || fail "the preconditions: $(grep -e '^docker' -e '^identity' "$FX/calls" | tr '\n' ' ')"
pre_row() { # label want-text: the last run refused before the build, naming want-text
  [ $r = 1 ] && grep -q "$2" "$FX/o" && nobuild && pass "$1: refused before the build ($2)" || fail "$1: rc=$r $(lastline)"
}
# A4: anything of the version public
g push -q --no-follow-tags origin "$T:refs/tags/v0.1.0" || exit 3
rm -rf "${OUTR:?}"; ship; r=$?; pre_row "the tag on origin (and on github.com)" "public"
:
for rel in "v0.1.0 false false" "v0.1.0 true false"; do
  printf 'v0.0.9 false false\n%s\n' "$rel" > "$FX/rels"; rm -rf "${OUTR:?}"; ship; r=$?; pre_row "a release '$rel' on GitHub" "public"
done; echo "v0.0.9 false false" > "$FX/rels"
tapset 0.1.0; rm -rf "${OUTR:?}"; ship; r=$?; pre_row "the tap's cask at 0.1.0" "public"; tapset 0.0.9
echo "sha512-x" > "$FX/view.sheepr-linux-x64"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/view.sheepr-linux-x64"; pre_row "sheepr-linux-x64@0.1.0 on npm" "public"
printf '{\n  "created": "x",\n  "0.1.0": "x"\n}\n' > "$FX/time.sheepr"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/time.sheepr"; pre_row "0.1.0 in sheepr's npm time record (once unpublished)" "can never be published on npm again"
: > "$FX/viewfailv.sheepr-darwin-universal"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/viewfailv.sheepr-darwin-universal"; pre_row "the version's npm view failing (not E404; time and latest answer)" "cannot tell whether anything is public"
: > "$FX/viewfail.sheepr-darwin-universal"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/viewfail.sheepr-darwin-universal"; pre_row "every npm view of a name failing" "cannot tell whether anything is public"
: > "$FX/relsfail"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/relsfail"; pre_row "the release list that cannot be read" "cannot tell whether anything is public"
# A4: newer than GitHub's latest final release and than npm's latest
printf 'v0.0.9 false false\nv0.2.0 false false\n' > "$FX/rels"; rm -rf "${OUTR:?}"; ship; r=$?; echo "v0.0.9 false false" > "$FX/rels"; pre_row "GitHub's latest release 0.2.0" "not newer"
printf 'v0.0.9 false false\nv0.3.0 true false\nv0.3.0-rc.1 false true\n' > "$FX/rels"; rm -rf "${OUTR:?}"; ship; r=$?; echo "v0.0.9 false false" > "$FX/rels"
reached_end3 && pass "control: a newer draft and a newer prerelease do not count as GitHub's latest" || fail "draft and prerelease: $(lastline)"
echo 0.2.0 > "$FX/latest.sheepr"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/latest.sheepr"; pre_row "npm's latest sheepr 0.2.0" "not newer"
# A5: the tap
rm -f "$FX/tap/sheepr.rb"; rm -rf "${OUTR:?}"; ship; r=$?; tapset 0.0.9; pre_row "no cask in the tap" "add it by hand"
sed 's/^\(  version .*\)$/\1\n\1/' "$FX/tap/sheepr.rb" > "$FX/t2" && mv "$FX/t2" "$FX/tap/sheepr.rb"; rm -rf "${OUTR:?}"; ship; r=$?; tapset 0.0.9; pre_row "two version lines in the tap's cask" "one version line"
tapset 0.2.0; rm -rf "${OUTR:?}"; ship; r=$?; tapset 0.0.9; pre_row "the tap's cask at 0.2.0 (newer)" "not below"
echo false > "$FX/tapperm"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/tapperm"; pre_row "no right to write the tap" "cannot write lukaso/homebrew-tap"
echo false > "$FX/repoperm"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/repoperm"; pre_row "no right to write lukaso/sheepr" "cannot write lukaso/sheepr"
# A6: npm's owners, and no session ship did not make
echo stranger > "$FX/owner.sheepr"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/owner.sheepr"; pre_row "an npm name owned by someone else" "belongs to stranger"
echo "//registry.npmjs.org/:_authToken=npm_old" > "$FX/npmrc"; rm -rf "${OUTR:?}"; ship; r=$?
pre_row "an npm session from before ship" "npm logout"; ! grep -q '^npm logout' "$FX/calls" && pass "  and no logout call" || fail "  a logout ran"
: > "$FX/expired"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/expired" "$FX/npmrc"
pre_row "an expired npm token (the count 1, whoami E401)" "npm config delete //registry.npmjs.org/:_authToken"
: > "$FX/whoamibad"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/whoamibad"; pre_row "a whoami failure that is not ENEEDAUTH" "cannot tell whether an npm session"
# A7: the build's preconditions
: > "$FX/nodocker"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/nodocker"; pre_row "Docker does not answer" "Docker"
: > "$FX/nobase"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/nobase"; pre_row "the pinned base image missing" "no local image rust:"
: > "$FX/noamd64"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/noamd64"; pre_row "the amd64 image missing" "no local amd64 image"
SETX="SR_SHIP_DRY_IDENTITY=$S/docker"; rm -rf "${OUTR:?}"; ship; r=$?; SETX=; pre_row "the signing identity not in the keychain" "signing identity"
mv "$FX/ghome/Library/Keychains/sheepr-notary.keychain-db" "$FX/kc.away"; rm -rf "${OUTR:?}"; ship; r=$?; mv "$FX/kc.away" "$FX/ghome/Library/Keychains/sheepr-notary.keychain-db"
pre_row "no notary keychain" "D2"
# A7: a finished build of this tag and commit: its checks instead of the preconditions
rm -rf "${OUTR:?}"; mkbuild "$OUTR/v0.1.0" v0.1.0 "$C"; ship; r=$?
reached_end3 && ! grep -q -e '^docker' -e '^identity' "$FX/calls" && pass "a finished build in the out dir: checked, the preconditions not asked" || fail "finished build: $(lastline)"
rm -rf "${OUTR:?}"; mkbuild "$OUTR/v0.1.0" v0.1.0 0000000000000000000000000000000000000000; ship; r=$?; pre_row "a build of another commit in the out dir" "holds no signed build of v0.1.0"
rm -rf "${OUTR:?}"; mkbuild "$OUTR/v0.1.0" v0.1.0 "$C"; echo x >> "$OUTR/v0.1.0/sheepr-linux-x86_64"; ship; r=$?; pre_row "a file of the finished build changed" "missing or not its manifest hash"
# round 6 N1: a control build beside the release dir is allowed; one inside it is refused
rm -rf "${OUTR:?}"; mkbuild "$OUTR/v0.1.0" v0.1.0 "$C"; mkbuild "$OUTR/v0.1.0-control" v0.1.0 "$C" true; ship; r=$?
reached_end3 && pass "a control build beside it (\$out/v0.1.0-control): allowed" || fail "control sibling: $(lastline)"
rm -rf "${OUTR:?}"; mkbuild "$OUTR/v0.1.0" v0.1.0 "$C"; mkdir -p "$OUTR/v0.1.0/sub"; cp "$OUTR/v0.1.0/MANIFEST.json" "$OUTR/v0.1.0/sub/"; sed -i.b 's/"control": false/"control": true/' "$OUTR/v0.1.0/sub/MANIFEST.json"; rm -f "$OUTR/v0.1.0/sub/MANIFEST.json.b"
ship; r=$?; pre_row "a control manifest inside the release dir" "control build's manifest lies inside"
rm -rf "${OUTR:?}"

# --- B and C0 to C3: the build (the frozen tree's release.sh, when there is none), its checks on
# every path, the manifest's hash, npm-check, and verify with publish_check in one subshell
reached_c3() { completed; }
taps() { grep -c 'api -H Accept: application/vnd.github.raw repos/lukaso/homebrew-tap/contents' "$FX/calls"; }
rm -rf "${OUTR:?}"; ship; r=$?
[ "$(grep -c '^build ' "$FX/calls")" = 1 ] && grep -q "^build $WTP/scripts/release.sh build --sign --out $OUTR v0.1.0\$" "$FX/calls" \
  && pass "no build yet: the build child once, exactly <frozen tree>/scripts/release.sh build --sign --out OUT TAG" || fail "the build call: $(grep '^build' "$FX/calls" | tr '\n' ' ')"
grep -q "^npmcheck $OUTR/v0.1.0\$" "$FX/calls" && reached_c3 && [ "$(taps)" -ge 2 ] && pass "npm-check, then verify and publish_check (the tap read again): the checks before the push pass" || fail "C2/C3: taps=$(taps) $(lastline)"
grep -q '^NOHOME' "$FX/calls" && fail "a stand-in ran without its HOME: $(grep '^NOHOME' "$FX/calls" | sort -u | tr '\n' ' ')" || pass "every stand-in call had its temp HOME"
rm -rf "${OUTR:?}"; mkbuild "$OUTR/v0.1.0" v0.1.0 "$C"; rm -f "$OUTR/v0.1.0/NPM-CHECKED"; ship; r=$?
! grep -q '^build ' "$FX/calls" && reached_c3 && pass "a finished build: not built again; npm-check and the checks run on it" || fail "finished build: $(lastline)"
c_row() { # label want-text: refused, nothing pushed
  [ $r = 1 ] && grep -q "$2" "$FX/o" && ! grep -q 'push --porcelain --atomic --no-follow-tags origin' "$FX/calls" 2>/dev/null && pass "$1: stopped ($2), no push" || fail "$1: rc=$r $(lastline)"
}
rm -rf "${OUTR:?}"; : > "$FX/buildfail"; ship; r=$?; rm -f "$FX/buildfail"; c_row "the build fails" "the build failed"
! grep -q '^npmcheck' "$FX/calls" && pass "  and no npm-check" || fail "  npm-check ran"
rm -rf "${OUTR:?}"; echo 0000000000000000000000000000000000000000 > "$FX/build.other"; ship; r=$?; rm -f "$FX/build.other"; c_row "the build makes another commit's build" "holds no signed build of v0.1.0"
! grep -q '^npmcheck' "$FX/calls" && pass "  and no npm-check (post_build_check first)" || fail "  npm-check ran"
rm -rf "${OUTR:?}"; : > "$FX/npmcheckfail"; ship; r=$?; rm -f "$FX/npmcheckfail"; c_row "npm-check refuses" "npm-check refused"
rm -rf "${OUTR:?}"; VERIFIED=-; ship; r=$?; VERIFIED=; c_row "verify judges no archive" "the checks before publishing refused"
[ "$(taps)" = 1 ] && ! grep -q 'verify has not judged' "$FX/o" && pass "  and publish_check does not run (verify && publish_check)" || fail "  publish_check ran: taps=$(taps) $(grep -c 'verify has not judged' "$FX/o")"
rm -rf "${OUTR:?}"; VERIFIED=0000000000000000000000000000000000000000000000000000000000000000; ship; r=$?; VERIFIED=; c_row "verify judged another archive" "verify judged"
rm -rf "${OUTR:?}"; : > "$FX/npmcheck.swap"; ship; r=$?; rm -f "$FX/npmcheck.swap"; c_row "the manifest changed after the build's checks (npm-check stamped the changed one)" "not the one ship checked"
# the frozen tree: the checkout's helpers replaced during the build write a marker if run; none runs
cat > "$FX/onbuild" <<EOF
for h in scripts/lib/cask-version.sh scripts/lib/render-cask.sh scripts/lib/npm-same.py scripts/release-plan.sh; do
  cp "$REPO/\$h" "$FX/keep.\$(basename "\$h")"; printf '#!/bin/sh\necho CHECKOUT-HELPER >> "%s/marker"\nexit 1\n' "$FX" > "$REPO/\$h"
done
EOF
rm -rf "${OUTR:?}"; rm -f "$FX/marker"; ship; r=$?; rm -f "$FX/onbuild"
for h in scripts/lib/cask-version.sh scripts/lib/render-cask.sh scripts/lib/npm-same.py scripts/release-plan.sh; do cp "$FX/keep.$(basename "$h")" "$REPO/$h"; done
[ -z "$(g status --porcelain)" ] || fail "the checkout's helpers were not put back"
reached_c3 && [ ! -e "$FX/marker" ] && pass "the checkout's helpers replaced during the build: none of them runs (the frozen tree's do)" || fail "frozen tree: marker=$(cat "$FX/marker" 2>/dev/null | head -1) $(lastline)"
rm -rf "${OUTR:?}"

# --- C4 to C9: the npm login (in the parent), the push of the recorded object, the platform
# packages back to back, GitHub while npm scans, the main package, the logout
ln_() { grep -n -e "$1" "$FX/calls" | head -1 | cut -d: -f1; }
rm -rf "${OUTR:?}"; ship; r=$?
completed && pass "a fresh run: done (0)" || fail "the fresh run: rc=$r $(lastline)"
li=$(ln_ '^npm login'); wi=$(grep -n '^npm whoami' "$FX/calls" | sed -n 2p | cut -d: -f1)
pi=$(ln_ "^sgit -C $WTP push --porcelain --atomic --no-follow-tags origin $C:refs/heads/main $T:refs/tags/v0.1.0\$")
[ -n "$li" ] && [ -n "$pi" ] && [ "$li" -lt "$pi" ] && [ -n "$wi" ] && [ "$wi" -gt "$li" ] && [ "$wi" -lt "$pi" ] \
  && pass "npm login (then whoami) before the push; the push: the recorded object, --atomic --no-follow-tags" || fail "login $li whoami $wi push $pi"
grep -q '^npm login --registry=https://registry.npmjs.org/$' "$FX/calls" && pass "the login names the registry" || fail "the login: $(grep '^npm login' "$FX/calls")"
seq_=$(grep -e '^npm publish' -e '^npm view .*dist.integrity' -e '^gh api -X POST repos' -e '^gh api -X PATCH' "$FX/calls" | sed -e 's/^npm publish .*\/\(sheepr[a-z0-9-]*\)-0\.1\.0\.tgz$/P:\1/' -e 's/^npm view .* \(sheepr[a-z0-9-]*\)@0\.1\.0 dist\.integrity$/V:\1/' -e 's/^gh api -X POST.*/POST/' -e 's/^gh api -X PATCH.*/PATCH/' | tr '\n' ' ')
case $seq_ in *"P:sheepr-linux-arm64 V:sheepr-linux-x64 P:sheepr-linux-x64 V:sheepr-darwin-universal P:sheepr-darwin-universal POST"*"PATCH V:sheepr-linux-arm64 V:sheepr-linux-x64 V:sheepr-darwin-universal V:sheepr P:sheepr V:sheepr "*)
  pass "the platform packages back to back, then GitHub (POST ... PATCH), then the waits, the main package, its wait" ;;
  *) fail "the order: $seq_" ;; esac
[ "$(grep -c '^npm publish' "$FX/calls")" = 4 ] && [ ! -s "$FX/asks" ] && pass "four uploads; GitHub's publish asked nothing (ship's one question was at the gate)" || fail "uploads $(grep -c '^npm publish' "$FX/calls")"
[ "$(grep -c '^npm logout' "$FX/calls")" = 1 ] && [ "$(ln_ '^npm logout')" -gt "$(grep -n '^npm publish' "$FX/calls" | tail -1 | cut -d: -f1)" ] && pass "one logout, after the last upload" || fail "logouts: $(grep -c '^npm logout' "$FX/calls")"
grep -qx 'version "0.1.0"' "$FX/tap.after" 2>/dev/null || grep -q '^  version "0.1.0"$' "$FX/tap.after" && grep -q '^gh api -X PUT repos/lukaso/homebrew-tap' "$FX/calls" && pass "the cask PUT (the tap at 0.1.0)" || fail "the tap: $(grep '^  version' "$FX/tap.after")"
nots=$(grep '^notify ' "$FX/calls" | sed 's/^notify \([a-z-]*\) .*/\1/' | tr '\n' ' ')
case $nots in "npm-login npm-approve npm-approve-again "*) pass "the notifications, in order: npm-login, npm-approve, npm-approve-again" ;; *) fail "the notifications: $nots" ;; esac
grep -q '^NOHOME' "$FX/calls" && fail "a stand-in ran without its HOME: $(grep '^NOHOME' "$FX/calls" | sort -u | tr '\n' ' ')" || pass "every stand-in call had its temp HOME"
nopath && pass "no PATH tool was called" || fail "PATH calls: $(cat "$FX/pathcalls")"
! grep -q '_authToken=' "$FX/npmrc.after" && pass "the run left no npm session" || fail "the npmrc after the run: $(grep -c _authToken= "$FX/npmrc.after") token line(s)"
prog=$(grep -v '^run ' "$OUTR/.v0.1.0.ship-progress" 2>/dev/null | tr '\n' '|')
[ "$prog" = "start push|done push|start npm-platform sheepr-linux-arm64|done npm-platform sheepr-linux-arm64|start npm-platform sheepr-linux-x64|done npm-platform sheepr-linux-x64|start npm-platform sheepr-darwin-universal|done npm-platform sheepr-darwin-universal|start github|done github|start npm-main|done npm-main|" ] \
  && pass "the progress file: each phase started and done, in order" || fail "the progress: $prog"
# stops before anything is public: no push, no npm upload, no POST
nopub() { ! grep -q -e "push --porcelain --atomic --no-follow-tags origin" -e '^npm publish' -e '^gh api -X POST' "$FX/calls"; }
cat > "$FX/onbuild" <<EOF
(cd "$REPO" && env HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t /usr/bin/git tag -f -a v0.1.0 -m moved "$C" >/dev/null)
EOF
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/onbuild"; g tag -f -a v0.1.0 -m v0.1.0 "$C" >/dev/null; T2=$(g rev-parse v0.1.0)
[ $r = 1 ] && grep -q 'moved since ship recorded it' "$FX/o" && nopub && pass "the tag moved during the build: refused before the push" || fail "tag moved: rc=$r $(lastline)"
T=$T2
echo other > "$FX/whoami"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/whoami"
[ $r = 1 ] && grep -q 'logged in to npm as other' "$FX/o" && nopub && pass "another npm user after the login: stopped, nothing public" || fail "wrong user: rc=$r $(lastline)"
: > "$FX/loginfail"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/loginfail"
[ $r = 1 ] && grep -q 'npm login failed' "$FX/o" && nopub && [ "$(grep -c '^npm logout' "$FX/calls")" = 1 ] && pass "a failing login: stopped, nothing public, one logout (logged in from the attempt on)" || fail "login fails: rc=$r logouts $(grep -c '^npm logout' "$FX/calls") $(lastline)"
: > "$FX/whoamibad2"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/whoamibad2"
[ $r = 1 ] && grep -q 'npm whoami failed after the login' "$FX/o" && nopub && pass "whoami failing after the login: stopped, nothing public" || fail "whoami after login: rc=$r $(lastline)"
cat > "$FX/onbuild" <<EOF
cd "$REPO" && env HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \\
  /usr/bin/git --git-dir="$FX/origin.git" commit-tree -p "$BASE" -m moved "$BASE^{tree}" > "$FX/moved" && /usr/bin/git --git-dir="$FX/origin.git" update-ref refs/heads/main "\$(cat "$FX/moved")"
EOF
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/onbuild"
[ $r = 1 ] && grep -q 'diverged' "$FX/o" && nopub && pass "origin's main moved during the build: refused by the second A3, before any push" || fail "main moved in the build: rc=$r $(lastline)"
cat > "$FX/onpush" <<EOF
cd "$REPO" && env HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \\
  /usr/bin/git --git-dir="$FX/origin.git" commit-tree -p "$BASE" -m race "$BASE^{tree}" > "$FX/raced" && /usr/bin/git --git-dir="$FX/origin.git" update-ref refs/heads/main "\$(cat "$FX/raced")"
EOF
rm -rf "${OUTR:?}"; rm -f "$FX/onpush.done"; ship; r=$?; rm -f "$FX/onpush" "$FX/onpush.done"
[ $r = 1 ] && grep -q '^push refused$' "$OUTR/.v0.1.0.ship-progress" && ! grep -q 'refs/tags/v0.1.0' "$FX/origin.after" && ! grep -q -e '^npm publish' -e '^gh api -X POST' "$FX/calls" \
  && pass "main moved at the real push: the atomic push refused, nothing moved (ls-remote), 'push refused' recorded, no upload" || fail "push race: rc=$r $(tr '\n' ' ' < "$OUTR/.v0.1.0.ship-progress" 2>/dev/null) $(lastline)"
rm -rf "${OUTR:?}"
# during the build: a release of the version appears on GitHub (C5's A4), the tag reaches origin (C5's
# A2 read fresh): refused before the push
cat > "$FX/onbuild" <<EOF
printf 'v0.0.9 false false\nv0.1.0 true false\n' > "$FX/rels"
EOF
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/onbuild"; echo "v0.0.9 false false" > "$FX/rels"
[ $r = 1 ] && grep -q 'GitHub has a release or a draft v0.1.0' "$FX/o" && nopub && pass "a draft of the version made during the build: C5's A4 refuses, before the push" || fail "public in the build: rc=$r $(lastline)"
cat > "$FX/onbuild" <<EOF
cd "$REPO" && env HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 /usr/bin/git push -q --no-follow-tags "file://$FX/origin.git" "$T:refs/tags/v0.1.0"
EOF
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/onbuild"
[ $r = 1 ] && grep -q 'the tag is on origin' "$FX/o" && nopub && pass "the tag pushed to origin during the build: C5's fresh A2 read sees it, refused before the push" || fail "tag on origin in the build: rc=$r $(lastline)"
# a push that fails after a part of it landed (the stand-in sends one refspec, then fails): never
# "push refused"
for lk in tag main; do   # (not k: ship() uses it)
  echo $lk > "$FX/pushlie"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/pushlie"
  [ $r = 1 ] && ! grep -q '^push refused$' "$OUTR/.v0.1.0.ship-progress" && grep -q 'shows a part of it' "$FX/o" && ! grep -q -e '^npm publish' -e '^gh api -X POST' "$FX/calls" \
    && pass "a failed push that landed its $lk: not 'push refused' (it shows a part), no upload" || fail "push lie $lk: rc=$r $(tr '\n' ' ' < "$OUTR/.v0.1.0.ship-progress") $(lastline)"
done
# after the push, github.com/lukaso/sheepr must show the tag at the recorded object and main at or
# past the commit (a second bare repo the push does not reach, or reaches with the tag only)
rm -rf "${FX:?}/origin2.git"; git init -q --bare "$FX/origin2.git" && g push -q --no-follow-tags "file://$FX/origin2.git" "$C:refs/heads/main" \
  && g push -q -f --no-follow-tags origin "$C:refs/heads/main" || exit 3
echo "file://$FX/origin2.git" > "$FX/updir"; echo none > "$FX/mirror"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/updir" "$FX/mirror"
grep -q "push --porcelain --atomic --no-follow-tags origin $T:refs/tags/v0.1.0\$" "$FX/calls" && [ $r = 1 ] && grep -q 'is not the recorded object' "$FX/o" && ! grep -q '^npm publish' "$FX/calls" \
  && pass "main already at the tag's commit: the tag alone pushed; github.com/lukaso/sheepr without it after the push: stopped, no upload" || fail "after-push tag: rc=$r $(lastline)"
rm -rf "${FX:?}/origin2.git"; git init -q --bare "$FX/origin2.git" && g push -q --no-follow-tags "file://$FX/origin2.git" "$BASE:refs/heads/main" || exit 3
echo "file://$FX/origin2.git" > "$FX/updir"; echo tag > "$FX/mirror"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/updir" "$FX/mirror"
[ $r = 1 ] && grep -q 'does not hold' "$FX/o" && ! grep -q '^npm publish' "$FX/calls" && pass "github.com/lukaso/sheepr's main not at the commit after the push: stopped, no upload" || fail "after-push main: rc=$r $(lastline)"
cat > "$FX/afterpush" <<EOF
/usr/bin/git --git-dir="$FX/origin.git" commit-tree -p "$C" -m next "$C^{tree}" > "$FX/next" && /usr/bin/git --git-dir="$FX/origin.git" update-ref refs/heads/main "\$(cat "$FX/next")"
EOF
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/afterpush"
completed && [ "$(git --git-dir="$FX/origin.git" cat-file -t "$(cat "$FX/next")" 2>/dev/null)" = commit ] && pass "main moved past the tag's commit right after the push (fetched, then checked): accepted" || fail "main past: rc=$r $(lastline)"
# the progress line before the real push: directly before it, in the text
[ "$(grep -B1 'push --porcelain --atomic --no-follow-tags origin "\$@" > "\$st/push"' "$RS" | head -1)" = '  progress "start push"' ] && pass "'start push' is written directly before the real push" || fail "start push: $(grep -B1 'push --porcelain --atomic --no-follow-tags origin' "$RS" | head -1)"
# every npm call in the npm class (it passes NODE_EXTRA_CA_CERTS; the dry class does not)
SETX="NODE_EXTRA_CA_CERTS=$FX/ca.pem"; rm -rf "${OUTR:?}"; ship; r=$?; SETX=
completed && [ -s "$FX/npmenvs" ] && [ -z "$(grep -v "^$FX/ca.pem " "$FX/npmenvs")" ] && grep -q ' login$' "$FX/npmenvs" && grep -q ' publish$' "$FX/npmenvs" && grep -q ' logout$' "$FX/npmenvs" \
  && pass "every npm call (views, login, uploads, logout) in the npm class" || fail "npm classes: $(grep -v "^$FX/ca.pem " "$FX/npmenvs" 2>/dev/null | sort | uniq -c | tr '\n' ' ') $(lastline)"
# GitHub public, its cask refused (publish's exit 5): stopped, 'exit5' recorded, no main upload
: > "$FX/putfail"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/putfail"
[ $r = 1 ] && [ "$(tail -2 "$OUTR/.v0.1.0.ship-progress" | tr '\n' '|')" = "start github|exit5|" ] && [ "$(grep -c '^npm publish' "$FX/calls")" = 3 ] \
  && pass "the cask refused after GitHub's publish (exit 5): 'exit5' recorded, the main package not uploaded" || fail "exit5: rc=$r $(tail -2 "$OUTR/.v0.1.0.ship-progress" | tr '\n' ' ') $(lastline)"
rm -rf "${OUTR:?}"
# a stop in each later phase: the progress file's last line, and nothing after it
lastprog() { tail -1 "$OUTR/.v0.1.0.ship-progress" 2>/dev/null; }
: > "$FX/pubfail.sheepr-linux-x64"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/pubfail.sheepr-linux-x64"
[ $r = 1 ] && [ "$(lastprog)" = "start npm-platform sheepr-linux-x64" ] && ! grep -q '^gh api -X POST' "$FX/calls" && [ "$(grep -c '^npm publish' "$FX/calls")" = 2 ] \
  && pass "a platform upload refused: stopped at it ('start npm-platform NAME' last), no GitHub call, nothing after it" || fail "platform refused: rc=$r '$(lastprog)' $(lastline)"
: > "$FX/postfail"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/postfail"
[ $r = 1 ] && [ "$(lastprog)" = "start github" ] && [ "$(grep -c '^npm publish' "$FX/calls")" = 3 ] && pass "GitHub's draft refused (not exit 5): stopped, 'start github' last, the main package not uploaded" || fail "post fails: rc=$r '$(lastprog)' $(lastline)"
: > "$FX/pubfail.sheepr"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/pubfail.sheepr"
[ $r = 1 ] && [ "$(lastprog)" = "start npm-main" ] && ! grep -q 'is public on GitHub, Homebrew and npm' "$FX/o" && pass "the main upload refused: stopped, 'start npm-main' last, no success line" || fail "main refused: rc=$r '$(lastprog)' $(lastline)"
# the progress file cannot take 'start push': no push
cat > "$FX/onbuild" <<EOF
chmod 444 "$OUTR/.v0.1.0.ship-progress"
EOF
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/onbuild"
[ $r = 1 ] && grep -q "cannot write $OUTR/.v0.1.0.ship-progress" "$FX/o" && nopub && pass "'start push' cannot be written: no push (each line before the step it names)" || fail "progress unwritable: rc=$r $(lastline)"
rm -rf "${OUTR:?}"
# a refused push whose aftermath cannot be read: never 'push refused'
cat > "$FX/onpush" <<EOF
/usr/bin/git --git-dir="$FX/origin.git" commit-tree -p "$BASE" -m race "$BASE^{tree}" > "$FX/raced" && /usr/bin/git --git-dir="$FX/origin.git" update-ref refs/heads/main "\$(cat "$FX/raced")"
EOF
: > "$FX/lsfailafter"; rm -rf "${OUTR:?}"; rm -f "$FX/onpush.done"; ship; r=$?; rm -f "$FX/onpush" "$FX/onpush.done" "$FX/lsfailafter"
[ $r = 1 ] && ! grep -q '^push refused$' "$OUTR/.v0.1.0.ship-progress" && grep -q 'cannot be read to tell whether it landed' "$FX/o" && pass "a refused push, then ls-remote failing: not 'push refused' (it cannot tell)" || fail "push refused unread: rc=$r $(tr '\n' ' ' < "$OUTR/.v0.1.0.ship-progress") $(lastline)"
rm -rf "${OUTR:?}"
finish
