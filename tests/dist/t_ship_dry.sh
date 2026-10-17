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
# \$FX/onshow: a hook run once, before release.sh reads the tag's own release.sh (its \$0 compare)
if [ -e "$FX/onshow" ] && [ ! -e "$FX/onshow.done" ]; then case " \$* " in *" show v0.1.0:scripts/release.sh "*) : > "$FX/onshow.done"; sh "$FX/onshow" ;; esac; fi
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
if [ -e "$FX/buildint" ]; then
  # only in a process group ship leads (the row's own session): never the cell's group
  [ "\$(/usr/bin/perl -e 'print getpgrp()')" = "\$PPID" ] || { echo "UNSAFE buildint" >> "$FX/calls"; exit 1; }
  trap 'echo "build got INT" >> "$FX/calls"; exit 0' INT; kill -INT 0; /bin/sleep 5
fi
[ -e "$FX/buildhup" ] && { kill -HUP \$PPID; /bin/sleep 1; }
[ -e "$FX/buildusr1" ] && { kill -USR1 \$PPID; /bin/sleep 2; echo done > "$FX/build.done"; }
[ -e "$FX/buildsys" ] && { kill -SYS \$PPID; exit 0; }
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
[ ! -e "$FX/afterbuild" ] || sh "$FX/afterbuild"
[ ! -e "$FX/build.nomanifest" ] || rm -f "\$d/MANIFEST.json"
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
[ ! -e "$FX/npmcheck.badstamp" ] || echo "\$tg 0000" > "\$d/NPM-CHECKED"
[ ! -e "$FX/npmcheck.nostamp" ] || rm -f "\$d/NPM-CHECKED"
[ ! -e "$FX/npmcheck.touchpkg" ] || echo x >> "\$d/sheepr-linux-x64-0.1.0.tgz"
[ ! -e "$FX/npmcheck.touch" ] || echo x >> "\$d/sheepr-linux-x86_64"
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
  *"repos/lukaso/homebrew-tap --jq .permissions.push"*) [ -e "$FX/tappermfail" ] && { echo "gh: HTTP 502" >&2; exit 1; }; cat "$FX/tapperm" 2>/dev/null || echo true ;;
  *"-X PUT repos/lukaso/homebrew-tap/contents/Casks/sheepr.rb"*)
    [ -e "$FX/putfail" ] && { echo "gh: HTTP 409" >&2; exit 1; }
    for a; do case \$a in content=*) printf '%s' "\${a#content=}" | base64 -d > "$FX/tap/sheepr.rb" ;; esac; done
    echo c0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ff ;;
  *"homebrew-tap/contents/Casks/sheepr.rb"*) [ -e "$FX/tapreadfail" ] && { echo "gh: HTTP 502" >&2; exit 1; }; [ -f "$FX/tap/sheepr.rb" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }; cat "$FX/tap/sheepr.rb" ;;
  *"releases/tags/"*"--jq .draft, (.assets"*|*"releases/4242 --jq .draft, (.assets"*)
    echo false; i=0; for f in \$(ls "$FX/up"); do i=\$((i+1)); [ "\$f" = sheepr-macos-universal.tar.gz ] && echo \$i; done ;;
  "api -X POST repos/lukaso/sheepr/releases "*) [ -e "$FX/postfail" ] && exit 1; echo 4242 ;;
  *"uploads.github.com"*) [ -e "$FX/uploadfail" ] && { echo "gh: HTTP 502" >&2; exit 1; }; prev=""; for a; do case \$a in *assets\\?name=*) nm=\${a##*name=} ;; esac; [ "\$prev" = --input ] && in=\$a; prev=\$a; done
    mkdir -p "$FX/up"; cp "\$in" "$FX/up/\$nm"; echo 1 ;;
  "api repos/lukaso/sheepr/releases/4242 --jq .assets"*) i=0; for f in \$(ls "$FX/up"); do i=\$((i+1)); echo "\$i \$f"; done ;;
  *"releases/assets/"*) for a; do last=\$a; done; id=\${last##*/}; f=\$(ls "$FX/up" | sed -n "\${id}p"); cat "$FX/up/\$f" ;;
  *"PATCH"*) [ -e "$FX/patchfail" ] && exit 1; [ -e "$FX/stilldraft" ] && exit 1; [ -e "$FX/patch5" ] && : > "$FX/notpublished" ;;
  *"--jq .draft"*) if [ -e "$FX/stilldraft" ]; then echo true; else echo false; fi ;;
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
    [ -e "$FX/owner404.\$p" ] && { echo "npm error code E404" >&2; exit 1; }   # a name not on npm: every view is E404
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
  owner) [ -e "$FX/ownerfail" ] && { echo "npm error code ETIMEDOUT" >&2; exit 1; }
    [ -e "$FX/owner404.\$3" ] && { echo "npm error code E404" >&2; exit 1; }
    if [ -f "$FX/owner.\$3" ]; then echo "\$(cat "$FX/owner.\$3") <x@example.com>"; else echo "lukasco <x@example.com>"; fi; exit 0 ;;
  config) [ "\$2 \$3" = "get userconfig" ] && { echo "$FX/npmrc"; exit 0; } ;;
  whoami) [ -e "$FX/whoamibad" ] && { echo "npm error code ETIMEDOUT" >&2; exit 1; }
    if grep -q "^\$TOK" "$FX/npmrc" 2>/dev/null; then
      [ -e "$FX/whoamibad2" ] && { echo "npm error code ETIMEDOUT" >&2; exit 1; }
      [ -e "$FX/expired" ] && { echo "npm error code E401" >&2; exit 1; }
      cat "$FX/whoami" 2>/dev/null || echo lukasco; exit 0
    fi
    echo "npm error code ENEEDAUTH" >&2; exit 1 ;;
  login) [ -e "$FX/loginfail" ] && exit 1; echo "\${TOK}npm_dry" >> "$FX/npmrc"; exit 0 ;;
  logout) [ -e "$FX/logoutint" ] && exec /usr/bin/perl -e 'getpgrp() == getppid() or do { open(my \$f, ">>", "$FX/calls"); print \$f "UNSAFE logoutint\\n"; exit 1 }; \$SIG{INT} = "DEFAULT"; kill "INT", 0; sleep 5; exit 0'
    [ -e "$FX/logoutfail" ] && exit 1; [ -e "$FX/logoutstays" ] && exit 0; [ -e "$FX/logoutrm" ] && { rm -f "$FX/npmrc"; exit 0; }
    [ -e "$FX/logoutlies" ] && { grep -v "^\$TOK" "$FX/npmrc" > "$FX/npmrc.n" 2>/dev/null; mv "$FX/npmrc.n" "$FX/npmrc"; exit 1; }
    grep -v "^\$TOK" "$FX/npmrc" > "$FX/npmrc.n" 2>/dev/null; mv "$FX/npmrc.n" "$FX/npmrc"; exit 0 ;;
  publish) p=\$(basename "\$last" | sed 's/^\(.*\)-[0-9][0-9.a-z-]*\.tgz\$/\1/')
    if [ -e "$FX/pubquit" ] && [ ! -e "$FX/pubquit.done" ]; then
      : > "$FX/pubquit.done"
      [ "\$(/usr/bin/perl -e 'print getpgrp()')" = "\$(cat "$FX/out/.ship.lock/pid" 2>/dev/null)" ] || { echo "UNSAFE pubquit" >> "$FX/calls"; exit 1; }
      trap 'echo "npm got QUIT" >> "$FX/calls"' QUIT; kill -QUIT 0
    fi
    [ -e "$FX/pubfail.\$p" ] && { echo "npm error code E401" >&2; echo STOP >> "$FX/calls"; exit 1; }
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
# only local bare repos: any other remote is refused before git runs (the network is never reached)
case \$1 in push|fetch|ls-remote)
  for a; do case \$a in
    file://*) ;;
    *://*|*@*:*) echo "SGIT REFUSED \$a" >> "$FX/calls"; echo "sgit: refused \$a (only file:// remotes)" >&2; exit 1 ;;
    origin) # the named remote: its url and push url, in the repo the call names
      for u in \$(GIT_CONFIG_NOSYSTEM=1 /usr/bin/git \${c:+-C "\$c"} config --get-all remote.origin.url 2>/dev/null) \$(GIT_CONFIG_NOSYSTEM=1 /usr/bin/git \${c:+-C "\$c"} config --get-all remote.origin.pushurl 2>/dev/null); do
        case \$u in file://*) ;; *) echo "SGIT REFUSED origin \$u" >> "$FX/calls"; echo "sgit: refused origin \$u" >&2; exit 1 ;; esac
      done ;;
  esac; done ;;
esac
extra="" real=no lie=""
[ "\$1" = ls-remote ] && [ -e "$FX/lsfail" ] && { echo "fatal: unable to access (stand-in)" >&2; exit 128; }
[ "\$1" = fetch ] && [ -e "$FX/fetchfail" ] && { echo "fatal: unable to access (stand-in)" >&2; exit 128; }
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
  rm -f "$FX/calls" "$FX/pathcalls" "$FX/asks" "$FX/npmenvs" "$FX/pipe.rc"
  set -- SR_ASK_RECORD="$FX/asks" SR_SHIP_DRY_BUILD="$S/build" SR_SHIP_DRY_NPMCHECK="$S/npmcheck" SR_SHIP_DRY_NOTIFY="$S/notify" SR_SHIP_DRY_CAFFEINATE="$S/caffeinate" \
    SR_SHIP_DRY_IDENTITY="$S/identity" SR_SHIP_DRY_DOCKER="$S/docker" SR_PUBLISH_DRY_GH="$S/gh" SR_PUBLISH_DRY_GIT="$S/sgit" \
    SR_PUBLISH_DRY_NPM="$S/npm" SR_PUBLISH_DRY_CURL="$S/curl" $( [ "${VERIFIED:-}" = - ] || printf '%s' "SR_PUBLISH_DRY_VERIFIED=${VERIFIED:-$AH}" ) "$@"
  envs=""; for a; do case $a in *=*) k=${a%%=*}; case " ${NO:-} " in *" $k "*) continue ;; esac; envs="$envs
$a" ;; esac; done
  # the assignments as arguments to env, one per line (a value may hold spaces)
  printf '%s\n' "$envs" | sed '/^$/d' > "$FX/envs"
  set --; [ -z "${SETSID:-}" ] || set -- /usr/bin/perl -e 'use POSIX; setsid() or die "setsid: $!"; $SIG{$_} = "DEFAULT" for qw(INT QUIT); exec @ARGV or die' --
  if [ -z "${PIPEQ:-}" ]; then
    (cd "$REPO" && IFS='
'; no_osascript "$@" env -i PATH="$B:/usr/bin:/bin" HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      $(cat "$FX/envs") ${SETX:+"$SETX"} sh scripts/release.sh __ship-dry --out "${OUT:-$OUTR}" "${TAG:-v0.1.0}") > "$FX/o" 2>&1; r_=$?
  else
    { (cd "$REPO" && IFS='
'; no_osascript "$@" env -i PATH="$B:/usr/bin:/bin" HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      $(cat "$FX/envs") ${SETX:+"$SETX"} sh scripts/release.sh __ship-dry --out "${OUT:-$OUTR}" "${TAG:-v0.1.0}") 2> "$FX/o"; echo $? > "$FX/pipe.rc"; } | sed -n "/$PIPEQ/q"
    r_=$(cat "$FX/pipe.rc")
  fi
  dryhomes "$FX/o"
  [ ! -s "$FX/pathcalls" ] || fail "a PATH tool was called in a ship run: $(head -2 "$FX/pathcalls" | tr '\n' ' ')"
  [ -n "${KEEP:-}" ] || world_reset; return $r_
}
# this cell's own leaked phase dirs: publish's and publish-npm's private copies name the fixture
fxleaks() { for d in /private/tmp/sr-npmpub.* /private/tmp/sr-publish.*; do [ -d "$d" ] && grep -rqs -F -- "$FX" "$d" && echo "$d"; done; }
# the dry HOMEs the last run named are gone, and no phase dir of this cell is left
leakfree() { [ -z "$(fxleaks)" ] && [ -z "$(sed -n 's/.*a temp HOME, \(\/private\/tmp\/sr-dryhome\.[A-Za-z0-9]*\).*/\1/p' "$FX/o" | while read -r d; do [ ! -e "$d" ] || echo "$d"; done)" ]; }
# the dry HOMEs a run named (a phase's go to stderr, so a PIPEQ run's are read too), for the last row
dryhomes() { sed -n 's/.*a temp HOME, \(\/private\/tmp\/sr-dryhome\.[A-Za-z0-9]*\).*/\1/p' "$1" >> "$FX/dryhomes"; }
# what a run changed, kept for the rows (origin's refs, the tap's cask), then put back: origin's main
# at BASE and no v0.1.0 tag, npm with nothing published, the tap at 0.0.9, no uploads
world_reset() {
  git --git-dir="$FX/origin.git" for-each-ref --format='%(objectname) %(refname)' > "$FX/origin.after"
  cp "$FX/tap/sheepr.rb" "$FX/tap.after" 2>/dev/null || : > "$FX/tap.after"
  git --git-dir="$FX/origin.git" update-ref refs/heads/main "$BASE" && git --git-dir="$FX/origin.git" update-ref -d refs/tags/v0.1.0 2>/dev/null
  rm -rf "$FX"/pub.* "$FX/up" "$FX"/processing.* "$FX/pushtried"; rm -f "$FX/origin.git/hooks/pre-receive"; tapset 0.0.9
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
grep -qx 'Run ship again.' "$OUTR/v0.1.0.ship-next.txt" && grep -qx 'This run made nothing public.' "$OUTR/v0.1.0.ship-next.txt" && pass "  its stop text: this run made nothing public (before A4); run ship again" || fail "  disagree text: $(tr '\n' '|' < "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null)"
# origin's main diverged from the tag's commit
g branch -q side "$BASE" && (cd "$REPO" && env HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
# every file ship's parent sources from the checkout is compared with the tag's, as $0 is: an edit
# of scripts/lib/sigs.sh hidden from git status (assume-unchanged; PROF dropped from the list) is
# refused before any remote call
g update-index --assume-unchanged scripts/lib/sigs.sh && cp "$REPO/scripts/lib/sigs.sh" "$FX/sg.keep" \
  && sed -i '' 's/ VTALRM PROF"$/ VTALRM"/' "$REPO/scripts/lib/sigs.sh" && ! cmp -s "$FX/sg.keep" "$REPO/scripts/lib/sigs.sh" && [ -z "$(g status --porcelain)" ] \
  || fail "the hidden sigs.sh edit was not made"
rm -rf "${OUTR:?}"; ship; r=$?
cp "$FX/sg.keep" "$REPO/scripts/lib/sigs.sh"; g update-index --no-assume-unchanged scripts/lib/sigs.sh
[ $r = 1 ] && grep -q "scripts/lib/sigs.sh is not v0.1.0's" "$FX/o" && ! grep -q '^sgit' "$FX/calls" 2>/dev/null \
  && pass "a scripts/lib/sigs.sh that is not the tag's (assume-unchanged): refused before any remote call" || fail "sigs.sh compare: rc=$r $(lastline)"
# the files ship's parent sources from the checkout, enumerated from release.sh: the source commands
# outside any function are one, and it reads the list ship compares ($sourced)
awk '/^[a-z_]+\(\) *\{/ {f = 1} /^}/ {f = 0} !f && /(^|[;&|{(]|then|else|do)[ \t]*\.[ \t]+"/ {print NR ": " $0}' "$SR_ROOT/scripts/release.sh" > "$FX/top.src"
[ "$(grep -c . "$FX/top.src")" = 1 ] && grep -q '\. "\$root/\$sourced"' "$FX/top.src" && grep -q '^sourced=scripts/lib/sigs\.sh$' "$SR_ROOT/scripts/release.sh" \
  && pass "ship's parent sources one file from the checkout before its frozen tree, the one it compares" || fail "top-level source commands: $(tr '\n' '|' < "$FX/top.src")"
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
# (a line that only echoes text for the operator, with no $( in it, is not a call: ship's stop text
# names `git ls-remote origin ...` for the operator to run)
gitnet() { grep -n -E '(^|[^A-Za-z_$"])git( -C [^ ]+| -c [^ ]+)* (push|fetch|ls-remote)( |$)' "$1" | grep -v '^[0-9]*: *#' | awk '!/^[0-9]+: *echo "/ || /\$\(/'; }
[ -z "$(gitnet "$RS")" ] && pass "release.sh makes no push, fetch or ls-remote but through \$GITCMD" || fail "git network calls: $(gitnet "$RS" | head -2 | tr '\n' ' ')"
printf '  git -C "$root" fetch origin main\n' > "$FX/planted.sh"; [ -n "$(gitnet "$FX/planted.sh")" ] && pass "control: a planted 'git -C \"\$root\" fetch origin main' is caught" || fail "control: the planted line is not caught"
printf '  echo "$(git -C "$root" fetch origin main)"\n' > "$FX/planted.sh"; [ -n "$(gitnet "$FX/planted.sh")" ] && pass "control: a planted fetch inside an echo's \$( ) is caught" || fail "control: the planted echo line is not caught"
printf '  echo "  git ls-remote origin refs/tags/$tag"\n' > "$FX/planted.sh"; [ -z "$(gitnet "$FX/planted.sh")" ] && pass "control: a line that echoes an operator's command is not a call" || fail "control: the operator text is counted as a call"

# the stand-in git reaches local bare repos only: a planted https remote is refused before git runs
rm -f "$FX/calls"; env -i PATH="$B:/usr/bin:/bin" HOME="$FX/ghome" "$S/sgit" ls-remote https://127.0.0.1:9/x > /dev/null 2>&1; r=$?
[ $r != 0 ] && grep -q '^SGIT REFUSED https://127.0.0.1:9/x$' "$FX/calls" && pass "the stand-in git refuses a remote that is not file:// (a planted https URL)" || fail "sgit and an https URL: rc=$r $(tail -1 "$FX/calls" 2>/dev/null)"
env -i PATH="$B:/usr/bin:/bin" HOME="$FX/ghome" "$S/sgit" ls-remote "file://$FX/origin.git" > /dev/null 2>&1 && pass "control: the stand-in git takes a file:// remote" || fail "control: sgit refused file://"

# --- A4 to A8: nothing of the version public; the tap; npm (owners, no session); the build's
# preconditions, or a finished build's checks; then armed
reached_end3() { completed; }
nobuild() { ! grep -q '^build ' "$FX/calls" 2>/dev/null && ! grep -q '^notify ' "$FX/calls" 2>/dev/null; }
rm -rf "${OUTR:?}"; ship; r=$?
reached_end3 && pass "a clean pre-flight: A1 to A8 pass" || fail "the clean pre-flight: $(lastline)"
grep -q '^docker info' "$FX/calls" && grep -q '^identity find-identity -v -p codesigning' "$FX/calls" && pass "no build yet: Docker, the images and the signing identity checked" || fail "the preconditions: $(grep -e '^docker' -e '^identity' "$FX/calls" | tr '\n' ' ')"
pre_row() { # label want-text: the last run refused before the build, naming want-text (before A8: no notification)
  [ $r = 1 ] && grep -q "$2" "$FX/o" && nobuild && ! grep -q '^notify' "$FX/calls" && pass "$1: refused before the build ($2)" || fail "$1: rc=$r $(grep '^notify' "$FX/calls" | head -1) $(lastline)"
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
grep -qx 'ship does not continue: release a new version.' "$OUTR/v0.1.0.ship-next.txt" && pass "  its stop text: release a new version" || fail "  lost text: $(tr '\n' '|' < "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null)"
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
! grep -q '^npm logout' "$FX/calls" && [ "$(grep -c '^notify failed-build v0.1.0$' "$FX/calls")" = 1 ] && pass "  no logout (no login was tried); one notification, failed-build" || fail "  build failure: logouts $(grep -c '^npm logout' "$FX/calls"), notifications $(grep '^notify' "$FX/calls" | tr '\n' ' ')"
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
[ $r = 1 ] && grep -q 'moved since ship recorded it' "$FX/o" && nopub && grep -qx "Move $OUTR/v0.1.0 aside (never delete it), then run ship again." "$OUTR/v0.1.0.ship-next.txt" \
  && pass "the tag moved during the build: refused before the push; move the build aside" || fail "tag moved: rc=$r $(lastline)"
T=$T2
echo other > "$FX/whoami"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/whoami"
[ $r = 1 ] && grep -q 'logged in to npm as other' "$FX/o" && nopub && grep -qx 'When the cause above is fixed, run ship again.' "$OUTR/v0.1.0.ship-next.txt" && pass "another npm user after the login: stopped, nothing public" || fail "wrong user: rc=$r $(lastline)"
: > "$FX/loginfail"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/loginfail"
[ $r = 1 ] && grep -q 'npm login failed' "$FX/o" && nopub && grep -qx 'Run ship again.' "$OUTR/v0.1.0.ship-next.txt" && [ "$(grep -c '^npm logout' "$FX/calls")" = 1 ] && pass "a failing login: stopped, nothing public, one logout (logged in from the attempt on)" || fail "login fails: rc=$r logouts $(grep -c '^npm logout' "$FX/calls") $(lastline)"
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
[ $r = 1 ] && grep -q '^push refused: main moved$' "$OUTR/.v0.1.0.ship-progress" && ! grep -q 'refs/tags/v0.1.0' "$FX/origin.after" && ! grep -q -e '^npm publish' -e '^gh api -X POST' "$FX/calls" \
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
  [ $r = 1 ] && ! grep -q '^push refused' "$OUTR/.v0.1.0.ship-progress" && grep -q 'shows a part of it' "$FX/o" && ! grep -q -e '^npm publish' -e '^gh api -X POST' "$FX/calls" \
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
[ $r = 1 ] && ! grep -q '^push refused' "$OUTR/.v0.1.0.ship-progress" && grep -q 'cannot be read to tell whether it landed' "$FX/o" && pass "a refused push, then ls-remote failing: not 'push refused' (it cannot tell)" || fail "push refused unread: rc=$r $(tr '\n' ' ' < "$OUTR/.v0.1.0.ship-progress") $(lastline)"
rm -rf "${OUTR:?}"

# the push refused, nothing landed: why, from origin's main after it. Unmoved (the remote's own
# rules: a pre-receive hook): fix the cause, run ship again; moved on past the commit: run ship again
# (the race above, main moved elsewhere: move the build aside, tag again)
cat > "$FX/onpush" <<EOF
printf '#!/bin/sh\nexit 1\n' > "$FX/origin.git/hooks/pre-receive" && chmod +x "$FX/origin.git/hooks/pre-receive"
EOF
rm -rf "${OUTR:?}"; rm -f "$FX/onpush.done"; ship; r=$?; rm -f "$FX/onpush" "$FX/onpush.done"
[ $r = 1 ] && [ "$(lastprog)" = "push refused: main unmoved" ] && grep -qx 'When the cause above is fixed, run ship again.' "$OUTR/v0.1.0.ship-next.txt" \
  && ! grep -q -e aside -e 'Tag again' "$OUTR/v0.1.0.ship-next.txt" && ! grep -q -e '^npm publish' -e '^gh api -X POST' "$FX/calls" \
  && pass "a push refused by the remote's rules, main unmoved: fix the cause, run ship again (no move aside, no new tag)" || fail "pre-receive: rc=$r '$(lastprog)' $(tr '\n' '|' < "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null)"
cat > "$FX/onpush" <<EOF
cd "$REPO" && env HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \\
  /usr/bin/git push -q --no-follow-tags "file://$FX/origin.git" "$C:refs/heads/tmp" && /usr/bin/git --git-dir="$FX/origin.git" commit-tree -p "$C" -m on "$C^{tree}" > "$FX/past" \\
  && /usr/bin/git --git-dir="$FX/origin.git" update-ref refs/heads/main "\$(cat "$FX/past")" && /usr/bin/git --git-dir="$FX/origin.git" update-ref -d refs/heads/tmp
EOF
rm -rf "${OUTR:?}"; rm -f "$FX/onpush.done"; ship; r=$?; rm -f "$FX/onpush" "$FX/onpush.done"
[ $r = 1 ] && [ "$(lastprog)" = "push refused: main holds it" ] && grep -qx 'Run ship again.' "$OUTR/v0.1.0.ship-next.txt" && ! grep -q -e aside -e 'Tag again' "$OUTR/v0.1.0.ship-next.txt" \
  && pass "a push refused because main moved on past the commit: run ship again" || fail "main past: rc=$r '$(lastprog)' $(tr '\n' '|' < "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null)"
rm -rf "${OUTR:?}"

# --- the exit handler: the stop text (to its file, then stdout), the logout and the token count, one
# notification, the worktree, the temp dirs and the lock; signals; caffeinate
NF=$OUTR/v0.1.0.ship-next.txt
nots() { grep '^notify ' "$FX/calls" | sed 's/^notify \([^ ]*\) .*/\1/' | tr '\n' ' '; }
gone() { # the temp dir, the worktree, the lock and the dry HOMEs of the last run are gone
  [ "$(g worktree list | grep -c .)" = 1 ] && [ ! -e "$OUTR/.ship.lock" ] && [ -z "$(sed -n 's/^release: .*a temp HOME, \(\/private\/tmp\/sr-dryhome\.[A-Za-z0-9]*\).*/\1/p' "$FX/o" | while read -r d; do [ ! -e "$d" ] || echo "$d"; done)" ] \
    && [ -z "$(sed -n 's/.*\(\/private\/tmp\/sr-ship\.[A-Za-z0-9]*\)\/tree.*/\1/p' "$FX/calls" | sort -u | while read -r d; do [ ! -e "$d" ] || echo "$d"; done)" ]
}
# a success: one logout, then done (the count 0); no next file (an earlier one removed)
rm -rf "${OUTR:?}"; mkdir -p "$OUTR"; echo EARLIER > "$NF"; ship; r=$?
completed && [ "$(grep -c '^npm logout' "$FX/calls")" = 1 ] && [ "$(nots)" = "npm-login npm-approve npm-approve-again done " ] && [ "$(ln_ '^npm logout')" -lt "$(ln_ '^notify done')" ] && [ ! -e "$NF" ] && gone \
  && pass "a success: one logout, then 'done' (the last notification); an earlier next file removed; everything removed" || fail "success: rc=$r nots '$(nots)' next $(ls "$NF" 2>/dev/null) $(lastline)"
grep -q "^caffeinate -i -w $(sed -n 's/^run \([0-9]*\) .*/\1/p' "$OUTR/.v0.1.0.ship-progress")\$" "$FX/calls" && [ "$(grep -c '^caffeinate' "$FX/calls")" = 1 ] \
  && pass "caffeinate once: -i -w ship's pid" || fail "caffeinate: $(grep caffeinate "$FX/calls" | tr '\n' ' ') pid $(head -1 "$OUTR/.v0.1.0.ship-progress")"
# a success whose logout leaves the token: no done, one logout-failed, exit 1, npm logout named
: > "$FX/logoutstays"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/logoutstays"
[ $r = 1 ] && grep -q 'is public on GitHub, Homebrew and npm' "$FX/o" && [ "$(nots)" = "npm-login npm-approve npm-approve-again logout-failed " ] && grep -q 'run npm logout --registry=https://registry.npmjs.org/' "$FX/o" && grep -q 'run npm config delete //registry.npmjs.org/:_authToken' "$FX/o" && [ ! -e "$NF" ] && gone \
  && pass "a success whose logout leaves the token: exit 1, one logout-failed (no done), npm logout and npm config delete named" || fail "success, logout fails: rc=$r '$(nots)' $(lastline)"
# a failure after the login: one logout, one failed-PHASE; with the token left, one notification naming both
: > "$FX/pubfail.sheepr"; rm -rf "${OUTR:?}"; ship; r=$?
[ $r = 1 ] && [ "$(grep -c '^npm logout' "$FX/calls")" = 1 ] && [ "$(nots)" = "npm-login npm-approve npm-approve-again failed-npm-main " ] && gone \
  && pass "a failure after the login: one logout, one notification (failed-npm-main)" || fail "failure after login: rc=$r '$(nots)' $(lastline)"
[ -z "$(sed -n '/^STOP$/,$p' "$FX/calls" | sed 1d | grep -v -e '^npm logout --registry=https://registry.npmjs.org/$' -e '^npm config get userconfig$' -e '^notify ')" ] \
  && pass "  after the stop: no read but the logout and the token count (the stop text reads nothing)" || fail "  calls after the stop: $(sed -n '/^STOP$/,$p' "$FX/calls" | sed 1d | tr '\n' ' ')"
: > "$FX/logoutfail"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/logoutfail" "$FX/pubfail.sheepr"
[ $r = 1 ] && [ "$(nots)" = "npm-login npm-approve npm-approve-again logout-failed-npm-main " ] && [ "$(tail -1 "$NF")" = "npm logout did not end ship's npm login (login token lines left: 1): run npm logout --registry=https://registry.npmjs.org/; if a line stays (an expired token, which npm logout cannot revoke), run npm config delete //registry.npmjs.org/:_authToken" ] && gone \
  && pass "a failure, and the logout leaves the token: one notification naming both; the next file ends with npm logout" || fail "failure + logout fails: rc=$r '$(nots)' '$(tail -1 "$NF" 2>/dev/null)'"
# an INT while the logout runs (the stand-in resets INT, then sends it to ship's group): the handler
# goes on; the token left: logout-failed, everything removed, exit 1
: > "$FX/logoutint"; rm -rf "${OUTR:?}"; SETSID=1; ship; r=$?; SETSID=; rm -f "$FX/logoutint"
[ $r = 1 ] && [ "$(nots)" = "npm-login npm-approve npm-approve-again logout-failed " ] && gone && pass "an INT during the logout: the handler finishes, logout-failed, exit 1" || fail "INT in logout: rc=$r '$(nots)' $(lastline)"
# stdout closed during the npm uploads (its reader quits), and the logout leaves the token: the
# handler finishes; the next file is the stop text and nothing else
: > "$FX/logoutfail"; rm -rf "${OUTR:?}"; PIPEQ='uploaded (npm scans it'; ship; r=$?; PIPEQ=; rm -f "$FX/logoutfail"
[ "$r" = 1 ] && [ "$(nots)" = "npm-login npm-approve logout-failed-npm-platform " ] && [ "$(head -1 "$NF")" = "release: ship v0.1.0 stopped at npm-platform: the npm upload of a platform package stopped (above)" ] && [ "$(grep -c '^release:' "$NF")" = 1 ] && gone && leakfree \
  && pass "stdout closed during the uploads: the handler finishes, a clean next file, one notification, exit 1, no temp dir left" || fail "closed stdout: rc=$r '$(nots)' '$(head -1 "$NF" 2>/dev/null)'"
# SIGINT: ship in a group of its own, INT at its default; the build stand-in sends INT to the group,
# handles it and exits 0: ship stops (no later phase), its handler runs
rm -rf "${OUTR:?}"; : > "$FX/buildint"; SETSID=1; ship; r=$?; SETSID=; rm -f "$FX/buildint"
[ $r = 1 ] && grep -q '^build got INT$' "$FX/calls" && ! grep -q '^npmcheck' "$FX/calls" && [ "$(nots)" = "failed-build " ] && gone \
  && pass "an INT to ship's group during the build: no later phase, failed-build, everything removed" || fail "INT: rc=$r '$(nots)' $(grep -c '^npmcheck' "$FX/calls") npmcheck $(lastline)"
# QUIT to ship's group during a platform upload (QUIT's default runs no EXIT trap, measured): ship
# and the phase's subshell trap it; the handler runs
: > "$FX/pubquit"; rm -f "$FX/pubquit.done"; rm -rf "${OUTR:?}"; SETSID=1; ship; r=$?; SETSID=; rm -f "$FX/pubquit" "$FX/pubquit.done"
[ $r = 1 ] && grep -q '^npm got QUIT$' "$FX/calls" && [ "$(grep -c '^npm logout' "$FX/calls")" = 1 ] && ! grep -q '_authToken=' "$FX/npmrc.after" \
  && [ "$(nots)" = "npm-login npm-approve failed-npm-platform " ] && grep -q 'is pushed, and npm may hold a part of it' "$NF" && gone \
  && pass "a QUIT to ship's group during a platform upload: one logout, the count 0, the post-push text, failed-npm-platform, all removed, exit 1" \
  || fail "QUIT: rc=$r '$(nots)' logouts $(grep -c '^npm logout' "$FX/calls") '$(head -1 "$NF" 2>/dev/null)' lock $(ls -d "$OUTR/.ship.lock" 2>/dev/null)"
# USR1 to ship during the build: its trap waits for the build (a foreground child), then stops
rm -rf "${OUTR:?}"; mkdir -p "$OUTR"; echo EARLIER > "$NF"; rm -f "$FX/build.done"; : > "$FX/buildusr1"; ship; r=$?; rm -f "$FX/buildusr1"
[ $r = 1 ] && [ -e "$FX/build.done" ] && [ "$(nots)" = "failed-build " ] && [ "$(head -1 "$NF" 2>/dev/null)" = "release: ship v0.1.0 stopped at build: a signal, or a step that named no cause" ] && gone \
  && pass "a USR1 during the build: ship waits for the build, then stops: failed-build, this run's next file, exit 1" || fail "USR1: rc=$r build.done=$(ls "$FX/build.done" 2>/dev/null) '$(nots)' '$(head -1 "$NF" 2>/dev/null)'"
rm -f "$FX/build.done"
# a signal ship does not trap (SYS: its default runs the EXIT trap with status 0, measured): only
# ship_run's own end is a success, so the handler takes the run as stopped, never as done
rm -rf "${OUTR:?}"; mkdir -p "$OUTR"; echo EARLIER > "$NF"; : > "$FX/buildsys"; ship; r=$?; rm -f "$FX/buildsys"
[ $r != 0 ] && [ "$(nots)" = "failed-build " ] && [ "$(head -1 "$NF" 2>/dev/null)" = "release: ship v0.1.0 stopped at build: a signal, or a step that named no cause" ] \
  && pass "an untrapped SYS during the build: not done; failed-build, this run's next file, a non-zero exit" || fail "SYS: rc=$r '$(nots)' '$(head -1 "$NF" 2>/dev/null)'"
rm -rf "${OUTR:?}"
# HUP during the build: the next file is written
rm -rf "${OUTR:?}"; : > "$FX/buildhup"; ship; r=$?; rm -f "$FX/buildhup"
[ $r = 1 ] && [ "$(head -1 "$NF" 2>/dev/null)" = "release: ship v0.1.0 stopped at build: a signal, or a step that named no cause" ] && grep -qx 'Nothing is public.' "$NF" && ! grep -q '^npmcheck' "$FX/calls" \
  && pass "a HUP during the build: stopped, the next file written" || fail "HUP: rc=$r '$(head -1 "$NF" 2>/dev/null)'"
# a build with no manifest: a content stop (move it aside), never "fix the cause, run ship again" (it would loop)
rm -rf "${OUTR:?}"; : > "$FX/build.nomanifest"; ship; r=$?; rm -f "$FX/build.nomanifest"
[ $r = 1 ] && grep -q "no $OUTR/v0.1.0/MANIFEST.json" "$FX/o" && grep -qx "Move $OUTR/v0.1.0 aside (never delete it), then run ship again." "$NF" \
  && pass "a build with no manifest: move it aside, then run ship again" || fail "no manifest: rc=$r $(tr '\n' '|' < "$NF" 2>/dev/null)"
rm -rf "${OUTR:?}"
# every phase ship names is a key notify.sh takes (failed-PHASE and logout-failed-PHASE: its dry mode)
bad=""; for ph in $(sed -n 's/.*[ ;]phase=\([a-z0-9-]*\)[ ;].*/\1/p; s/.*[ ;]phase=\([a-z0-9-]*\)$/\1/p' "$RS" | sort -u); do
  for k in "failed-$ph" "logout-failed-$ph"; do
    no_osascript env -i PATH=/usr/bin:/bin SR_NOTIFY_OSASCRIPT="$S/notify" HOME="$FX/ghome" sh "$REPO/scripts/lib/notify.sh" "$k" v0.1.0 2> "$FX/nerr" >/dev/null
    ! grep -q 'refused' "$FX/nerr" || bad="$bad $k"
  done
done
n_ph=$(sed -n 's/.*[ ;]phase=\([a-z0-9-]*\)[ ;].*/\1/p; s/.*[ ;]phase=\([a-z0-9-]*\)$/\1/p' "$RS" | sort -u | grep -c .)
[ -z "$bad" ] && [ "$n_ph" -ge 9 ] && pass "every phase name ($n_ph) makes a key notify.sh takes" || fail "phases notify.sh refuses:$bad (found $n_ph)"
no_osascript env -i PATH=/usr/bin:/bin SR_NOTIFY_OSASCRIPT="$S/notify" HOME="$FX/ghome" sh "$REPO/scripts/lib/notify.sh" failed-Npm v0.1.0 2> "$FX/nerr" >/dev/null
grep -q refused "$FX/nerr" && pass "control: an upper-case phase is refused by notify.sh" || fail "control: failed-Npm accepted"

# the count decides, not logout's exit code: a logout that fails but removes the token is done
: > "$FX/logoutlies"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/logoutlies"
completed && [ "$(nots)" = "npm-login npm-approve npm-approve-again done " ] && pass "a logout that exits 1 but leaves no token: done, exit 0 (the count decides)" || fail "logout lies: rc=$r '$(nots)'"
# PIPE: ship's stdout closed, then ship itself writes (A7's line about a finished build): its trap
# exits 1 (not 141), the handler runs, the next file holds the stop text first
rm -rf "${OUTR:?}"; mkbuild "$OUTR/v0.1.0" v0.1.0 "$C"; PIPEQ='checks passed'; ship; r=$?; PIPEQ=
[ "$r" = 1 ] && [ "$(head -1 "$NF" 2>/dev/null)" = "release: ship v0.1.0 stopped at preflight: a signal, or a step that named no cause" ] && gone && ! grep -q '^notify' "$FX/calls" \
  && pass "stdout closed, then ship writes: exit 1, the handler ran, a clean next file, no notification (before A8)" || fail "PIPE: rc=$r '$(head -1 "$NF" 2>/dev/null)'"
# a stop before A4 passed keeps an earlier run's next file (it cannot vouch that nothing is public)
rm -rf "${OUTR:?}"; mkdir -p "$OUTR"; echo EARLIER > "$NF"; echo https://github.com/someone/sheepr.git > "$FX/pushurl"; ship; r=$?; rm -f "$FX/pushurl"
[ $r = 1 ] && [ "$(cat "$NF")" = EARLIER ] && grep -qx 'This run made nothing public.' "$FX/o" && pass "a stop before A4 passed: an earlier next file kept; this run 'made nothing public'" || fail "pre-A4 keep: $(head -2 "$NF" | tr '\n' '|')"
rm -rf "${OUTR:?}"
# network reads that fail: run ship again (A2's ls-remote, A3's fetch; C3's tap read and write right)
for sw in lsfail fetchfail; do
  : > "$FX/$sw"; ship; r=$?; rm -f "$FX/$sw"
  [ $r = 1 ] && grep -qx 'Run ship again.' "$NF" && pass "$sw: run ship again" || fail "$sw: $(tr '\n' '|' < "$NF" 2>/dev/null)"
  rm -rf "${OUTR:?}"
done
cat > "$FX/onbuild" <<EOF
awk '{print} /^  version /{print}' "$FX/tap/sheepr.rb" > "$FX/t2" && mv "$FX/t2" "$FX/tap/sheepr.rb"
EOF
ship; r=$?; rm -f "$FX/onbuild"
[ $r = 1 ] && grep -q 'has not exactly one version line' "$NF" && grep -qx 'When the cause above is fixed, run ship again.' "$NF" && ! grep -q aside "$NF" && pass "C3: the tap's cask with two version lines: fix it first, no move aside" || fail "C3 tap lines: $(tr '\n' '|' < "$NF" 2>/dev/null)"
rm -rf "${OUTR:?}"
for sw in tapreadfail tappermfail; do
  printf ': > "%s/%s"\n' "$FX" "$sw" > "$FX/onbuild"; ship; r=$?; rm -f "$FX/onbuild" "$FX/$sw"
  [ $r = 1 ] && grep -qx 'Run ship again.' "$NF" && ! grep -q aside "$NF" && pass "C3 $sw: run ship again, no move aside" || fail "C3 $sw: $(tr '\n' '|' < "$NF" 2>/dev/null)"
  rm -rf "${OUTR:?}"
done
# stdout closed during the uploads, and a logout that removes the npmrc (the count reads no file):
# the count is 0 (the handler drains the bytes the closed stdout left before it counts)
: > "$FX/logoutrm"; rm -rf "${OUTR:?}"; PIPEQ='uploaded (npm scans it'; ship; r=$?; PIPEQ=; rm -f "$FX/logoutrm"
[ "$r" = 1 ] && [ "$(nots)" = "npm-login npm-approve failed-npm-platform " ] && [ "$(grep -c '^release:' "$NF")" = 1 ] && leakfree && pass "stdout closed, the npmrc gone after the logout: the count 0, failed-npm-platform, no temp dir left" || fail "closed stdout, no npmrc: rc=$r '$(nots)'"
# a refusal at C5's A4, after A8 (something public, or the release list unreadable, during the
# build): this run's own text replaces an earlier run's next file (only a stop before A8 keeps one)
rm -rf "${OUTR:?}"; mkdir -p "$OUTR"; echo EARLIER > "$NF"
printf "printf 'v0.0.9 false false\\\\nv0.1.0 true false\\\\n' > '%s/rels'\n" "$FX" > "$FX/onbuild"; ship; r=$?; rm -f "$FX/onbuild"; echo "v0.0.9 false false" > "$FX/rels"
[ $r = 1 ] && grep -q 'GitHub has a release or a draft v0.1.0' "$FX/o" && head -1 "$NF" | grep -q "^release: ship v0.1.0 stopped at push: " && ! grep -qx EARLIER "$NF" \
  && pass "C5's A4 refusal (a draft made during the build): this run's text replaces an earlier next file" || fail "C5 A4 public: rc=$r $(head -2 "$NF" | tr '\n' '|')"
rm -rf "${OUTR:?}"; mkdir -p "$OUTR"; echo EARLIER > "$NF"
printf ': > "%s/relsfail"\n' "$FX" > "$FX/onbuild"; ship; r=$?; rm -f "$FX/onbuild" "$FX/relsfail"
[ $r = 1 ] && head -1 "$NF" | grep -q "^release: ship v0.1.0 stopped at push: " && grep -q 'cannot tell whether anything is public' "$NF" && ! grep -qx EARLIER "$NF" \
  && pass "C5's A4 refusal (the release list unreadable during the build): this run's text replaces an earlier next file" || fail "C5 A4 unreadable: rc=$r $(head -2 "$NF" | tr '\n' '|')"
rm -rf "${OUTR:?}"
# --- what to run after a stop: the fixed text, its file; the steps it names run through their dry
# entries against the state the stop left (after the operator steps the text names), and complete
cont() { # run each step the next file names, in order: npm login (the operator's), then each
         # release.sh entry through its dry entry; RC: the first refused step, or 0
  RC=0; : > "$FX/cont"; rm -f "$FX/cont.one"
  while IFS= read -r l; do
    case $l in
      *"npm login --registry=https://registry.npmjs.org/") echo "//registry.npmjs.org/:_authToken=npm_dry" >> "$FX/npmrc"; echo login >> "$FX/cont" ;;
      *"sh scripts/release.sh "*" --out \"$OUTR\" v0.1.0"*)
        e=$(printf '%s\n' "$l" | sed 's/.*sh scripts\/release\.sh \([a-z-]*\) --out.*/\1/')
        [ "$e" = "${2:-$e}" ] || continue
        [ -z "${2:-}" ] || [ ! -e "$FX/cont.one" ] || return
        [ -z "${2:-}" ] || : > "$FX/cont.one"
        echo "$e" >> "$FX/cont"; printf 'v0.1.0\nv0.1.0\n' > "$FX/ask"
        (cd "$REPO" && no_osascript env -i PATH="$B:/usr/bin:/bin" HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
          SR_PUBLISH_DRY_GH="$S/gh" SR_PUBLISH_DRY_GIT="$S/sgit" SR_PUBLISH_DRY_NPM="$S/npm" SR_PUBLISH_DRY_CURL="$S/curl" SR_PUBLISH_DRY_NOTIFY="$S/notify" \
          SR_PUBLISH_DRY_VERIFIED="$AH" SR_ASK_SCRIPT="$FX/ask" SR_ASK_RECORD="$FX/asks" sh scripts/release.sh "__$e-dry" --out "$OUTR" v0.1.0) > "$FX/co" 2>&1 \
          || { dryhomes "$FX/co"; RC=1; echo "refused: $e: $(tail -1 "$FX/co")" >> "$FX/cont"; return; }
        dryhomes "$FX/co" ;;
    esac
  done < "${1:-$NF}"
}
done_all() { # the release is complete: the tag on origin, the tap at 0.1.0, four npm versions
  git --git-dir="$FX/origin.git" rev-parse -q --verify refs/tags/v0.1.0 >/dev/null && grep -q '^  version "0.1.0"$' "$FX/tap/sheepr.rb" \
    && [ "$(ls "$FX"/pub.* 2>/dev/null | grep -c .)" = 4 ]
}
postpush_ok() { ! grep -i -q -e 'nothing is public' -e 'made nothing public' -e 'not public\.' "$NF"; }
stoprow() { # label: the steps of the next file ran and the release is complete
  cont; [ $RC = 0 ] && done_all && pass "$1: the steps named ($(tr '\n' ' ' < "$FX/cont")) complete the release" || fail "$1: $(tr '\n' ' ' < "$FX/cont")"
  world_reset
}
# before the push: a content check, a network read, the A4 refusals
rm -rf "${OUTR:?}"; : > "$FX/npmcheckfail"; ship; r=$?; rm -f "$FX/npmcheckfail"
grep -qx 'Nothing is public.' "$NF" && grep -qx "Move $OUTR/v0.1.0 aside (never delete it), then run ship again." "$NF" && pass "npm-check refused: 'Nothing is public', move the build aside, run ship again" || fail "npm-check text: $(tr '\n' '|' < "$NF")"
mv "$OUTR/v0.1.0" "$FX/aside"; ship; r=$?; rm -rf "${FX:?}/aside"
completed && pass "  and ship again (the build moved aside) completes" || fail "  ship again: $(lastline)"
rm -rf "${OUTR:?}"; printf ': > "%s/ownerfail"\n' "$FX" > "$FX/onbuild"; ship; r=$?; rm -f "$FX/onbuild" "$FX/ownerfail"
grep -qx 'Run ship again.' "$NF" && ! grep -q 'aside' "$NF" && grep -q 'cannot read the owners' "$NF" && pass "C3: npm's owners unreadable: 'Run ship again', no move aside (the first cause kept)" || fail "C3 network text: $(tr '\n' '|' < "$NF")"
ship; r=$?; completed && pass "  and ship again (the build kept) completes" || fail "  ship again: $(lastline)"
rm -rf "${OUTR:?}"; printf 'echo stranger > "%s/owner.sheepr"\n' "$FX" > "$FX/onbuild"; ship; r=$?; rm -f "$FX/onbuild" "$FX/owner.sheepr"
grep -qx 'When the cause above is fixed, run ship again.' "$NF" && ! grep -q 'aside' "$NF" && pass "C3: a name another npm user owns: fix it first, no move aside" || fail "C3 fix text: $(tr '\n' '|' < "$NF")"
rm -rf "${OUTR:?}"; : > "$FX/relsfail"; ship; r=$?; rm -f "$FX/relsfail"
grep -q 'cannot tell whether anything is public' "$NF" && grep -qx 'Nothing was done. Run ship again.' "$NF" && pass "A4 unreadable: 'cannot tell', run ship again" || fail "A4 unreadable: $(tr '\n' '|' < "$NF")"
g push -q --no-follow-tags origin "$T:refs/tags/v0.1.0" || exit 3
rm -rf "${OUTR:?}"; ship; r=$?
grep -qx 'ship does not continue a release of which anything is public.' "$NF" && grep -q 'separate steps of PHASE3.md §5: build --sign, npm-check' "$NF" && ! grep -q 'Never rebuild' "$NF" \
  && pass "A4, no build: the separate steps of §5" || fail "A4 no build: $(tr '\n' '|' < "$NF")"
g push -q --no-follow-tags origin "$T:refs/tags/v0.1.0" || exit 3
rm -rf "${OUTR:?}"; mkbuild "$OUTR/v0.1.0" v0.1.0 "$C"; ship; r=$?
grep -q "^Never rebuild it: continue from $OUTR/v0.1.0" "$NF" && grep -qx "  sh scripts/release.sh npm-check --out \"$OUTR\" v0.1.0" "$NF" && pass "A4, this build in the out dir: never rebuild, continue from it" || fail "A4 with build: $(tr '\n' '|' < "$NF")"
# an A4 refusal keeps an earlier run's next file (and shows it); a refused lock writes nothing
echo EARLIER > "$NF"; g push -q --no-follow-tags origin "$T:refs/tags/v0.1.0" || exit 3; ship; r=$?
[ "$(cat "$NF")" = EARLIER ] && grep -qx EARLIER "$FX/o" && pass "an A4 refusal keeps an earlier next file, and shows it" || fail "A4 keep: $(head -2 "$NF" | tr '\n' '|')"
mkdir -p "$OUTR/.ship.lock"; printf 'run 1 x\nstart push\n' > "$OUTR/.v0.1.0.ship-progress"; ship; r=$?; rm -rf "${OUTR:?}/.ship.lock"
[ $r = 1 ] && [ "$(cat "$NF")" = EARLIER ] && [ "$(tr '\n' '|' < "$OUTR/.v0.1.0.ship-progress")" = "run 1 x|start push|" ] && pass "a ship refused at the lock: the other run's next and progress files left as they are" || fail "lock keep: $(head -1 "$NF")"
rm -rf "${OUTR:?}"
# N2: an earlier run's progress file ('start push'), then a diverged main: the diverged text
mkdir -p "$OUTR"; printf 'run 1 x\nstart push\n' > "$OUTR/.v0.1.0.ship-progress"
g push -q -f --no-follow-tags origin "$(cat "$FX/side"):refs/heads/main" || exit 3
ship; r=$?
grep -q "Tag again on top of origin's main, then run ship." "$NF" && ! grep -q 'push started' "$NF" && [ "$(grep -vc '^run ' "$OUTR/.v0.1.0.ship-progress")" = 0 ] \
  && pass "an earlier run's 'start push', then a diverged main: the diverged text (each run's own record)" || fail "N2 diverged: $(tr '\n' '|' < "$NF")"
rm -rf "${OUTR:?}"
# N4: the push refused: its text
cat > "$FX/onpush" <<EOF
/usr/bin/git --git-dir="$FX/origin.git" commit-tree -p "$BASE" -m race "$BASE^{tree}" > "$FX/raced" && /usr/bin/git --git-dir="$FX/origin.git" update-ref refs/heads/main "\$(cat "$FX/raced")"
EOF
rm -f "$FX/onpush.done"; ship; r=$?; rm -f "$FX/onpush" "$FX/onpush.done"
grep -qx 'Nothing is public: the push was refused, and nothing of it landed.' "$NF" && grep -q "Move $OUTR/v0.1.0 aside" "$NF" && pass "a refused push: 'nothing is public', move aside, tag again" || fail "N4: $(tr '\n' '|' < "$NF")"
rm -rf "${OUTR:?}"
# after the push started: each stop point's text, then its steps complete the release
echo tag > "$FX/pushlie"; KEEP=1; ship; r=$?; KEEP=; rm -f "$FX/pushlie"
grep -q 'The push started and was not confirmed' "$NF" && grep -qx '  git ls-remote origin refs/tags/v0.1.0' "$NF" && postpush_ok && pass "the push not confirmed: check ls-remote; the steps if it is there" || fail "push unconfirmed: $(tr '\n' '|' < "$NF")"
stoprow "the push not confirmed (the tag is there)"
printf ': > "%s/viewfailv.sheepr-linux-arm64"\n' "$FX" > "$FX/afterpush"; rm -rf "${OUTR:?}"; KEEP=1; ship; r=$?; KEEP=; rm -f "$FX/afterpush" "$FX/viewfailv.sheepr-linux-arm64"
[ "$(lastprog)" = "done push" ] && grep -q '^v0.1.0 is pushed; nothing else is public. Run in order:' "$NF" && ! grep -q 'npmjs.com/package' "$NF" && pass "the push done, no upload: publish, npm login, publish-npm (no wait note)" || fail "push done: '$(lastprog)' $(tr '\n' '|' < "$NF")"
stoprow "the push done, no upload"
for pk in sheepr-linux-arm64 sheepr-linux-x64 sheepr-darwin-universal; do
  : > "$FX/pubfail.$pk"; rm -rf "${OUTR:?}"; KEEP=1; ship; r=$?; KEEP=; rm -f "$FX/pubfail.$pk"
  grep -q "https://www.npmjs.com/package/$pk shows 0.1.0" "$NF" && grep -q "npm's email to lukasco. A blocked version needs a new version number." "$NF" && grep -q 'GitHub has no release of it' "$NF" && postpush_ok \
    && pass "a platform upload stopped ($pk): publish, npm login, publish-npm, the wait note and npm's review" || fail "platform stop $pk: $(tr '\n' '|' < "$NF")"
  stoprow "the platform uploads stopped at $pk"
done
: > "$FX/uploadfail"; rm -rf "${OUTR:?}"; KEEP=1; ship; r=$?; KEEP=; rm -f "$FX/uploadfail"
grep -q "a draft is not public: delete it on GitHub, then run:" "$NF" && postpush_ok && pass "GitHub stopped with a draft: the three cases named" || fail "draft left: $(tr '\n' '|' < "$NF")"
rm -rf "${FX:?}/up"   # the operator deletes the draft
cont "$NF" publish; [ $RC = 0 ] && pass "  the draft deleted: publish completes" || fail "  publish after the draft: $(tr '\n' ' ' < "$FX/cont")"
cont "$NF" publish-npm; [ $RC = 0 ] && done_all && pass "  then npm login, publish-npm: the release complete" || fail "  publish-npm: $(tr '\n' ' ' < "$FX/cont")"
world_reset
: > "$FX/postfail"; rm -rf "${OUTR:?}"; KEEP=1; ship; r=$?; KEEP=; rm -f "$FX/postfail"
grep -q '^  neither: run:' "$NF" && pass "N12: GitHub stopped before the POST: 'neither: run publish' among the cases" || fail "N12: $(tr '\n' '|' < "$NF")"
cont "$NF" publish; [ $RC = 0 ] && cont "$NF" publish-npm && [ $RC = 0 ] && done_all && pass "  publish, then publish-npm: the release complete" || fail "  N12 steps: $(tr '\n' ' ' < "$FX/cont")"
world_reset
: > "$FX/putfail"; rm -rf "${OUTR:?}"; KEEP=1; ship; r=$?; KEEP=; rm -f "$FX/putfail"
grep -q 'is public on GitHub, but its Homebrew cask is not updated' "$NF" && grep -qx "  sh scripts/release.sh publish-cask --out \"$OUTR\" v0.1.0" "$NF" && postpush_ok && pass "exit 5: publish-cask, npm login, publish-npm" || fail "exit5 text: $(tr '\n' '|' < "$NF")"
stoprow "exit 5"
: > "$FX/pubfail.sheepr"; rm -rf "${OUTR:?}"; KEEP=1; ship; r=$?; KEEP=; rm -f "$FX/pubfail.sheepr"
grep -q 'public on GitHub and Homebrew, and npm may hold a part of it' "$NF" && ! grep -q 'release.sh publish ' "$NF" && grep -q 'npmjs.com/package/sheepr shows' "$NF" && postpush_ok \
  && pass "the main upload refused: npm login, publish-npm only" || fail "main refused: $(tr '\n' '|' < "$NF")"
stoprow "the main upload refused"
# N6: a C8 wait that times out (npm still scans a platform package): the review and block text
printf 'echo 100000 > "%s/processing.sheepr-linux-x64"\n' "$FX" > "$FX/afterpush"; rm -rf "${OUTR:?}"; KEEP=1; ship; r=$?; KEEP=; rm -f "$FX/afterpush"
[ "$(lastprog)" = "done github" ] && grep -q "held the version for review or blocked it" "$FX/o" && grep -q "npm may hold a version for review, or block it" "$NF" \
  && grep -q 'npmjs.com/package/sheepr-linux-x64 shows' "$NF" && ! grep -q 'npmjs.com/package/sheepr shows' "$NF" && pass "N6: a C8 wait timed out: the review and block text; no wait line for the main package (never uploaded)" || fail "N6: '$(lastprog)' $(tr '\n' '|' < "$NF")"
rm -f "$FX"/processing.*   # npm's scan finished
stoprow "the C8 wait timed out (then the scan finished)"
rm -rf "${OUTR:?}"

# --- next_hint: under ship, no message but the stop text names an entry to run next; the remedies stay
hint_free() { # the lines of the run's output that are not the stop text name no entry to run next
  if [ -f "$NF" ]; then grep -v -x -F -f "$NF" "$FX/o"; else cat "$FX/o"; fi \
    | grep -e 'release\.sh \(publish\|npm-check\)' -e 'publish-npm again' -e 'publish again' -e 'this again' -e 'Next:' -e 'comes next' -e 'Run: ' > "$FX/hints"
  [ ! -s "$FX/hints" ]
}
hint_row() { # label want-text
  [ $r != 0 ] && grep -q "$2" "$FX/o" && hint_free && pass "under ship, $1: '$2', and no other entry named" || fail "$1: rc=$r $(head -2 "$FX/hints" 2>/dev/null | tr '\n' '|') $(lastline)"
}
rm -rf "${OUTR:?}"; : > "$FX/npmcheck.badstamp"; ship; r=$?; rm -f "$FX/npmcheck.badstamp"; hint_row "C3's stamp check" "npm-check has not passed on"
rm -rf "${OUTR:?}"; : > "$FX/npmcheck.touch"; ship; r=$?; rm -f "$FX/npmcheck.touch"; hint_row "C3's file check" "a file npm-check checked has changed since"
rm -rf "${OUTR:?}"; : > "$FX/stilldraft"; ship; r=$?; rm -f "$FX/stilldraft"; hint_row "the release still a draft" "it is still a draft"
rm -rf "${OUTR:?}"; : > "$FX/putfail"; ship; r=$?; rm -f "$FX/putfail"; hint_row "the cask refused (exit 5)" "its Homebrew cask is not updated"
printf 'echo 100000 > "%s/processing.sheepr-linux-x64"\n' "$FX" > "$FX/afterpush"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/afterpush"
hint_row "a C8 wait timed out" "held the version for review or blocked it"
grep -q 'A blocked version needs a new version number' "$FX/o" && pass "  npm's review and blocking text kept (N5)" || fail "  the review text is gone"
rm -rf "${OUTR:?}"; : > "$FX/owner404.sheepr-linux-x64"; ship; r=$?; rm -f "$FX/owner404.sheepr-linux-x64"; hint_row "a name not on npm (A4)" "reserve the name first (publish a 0.0.0 placeholder as lukasco)"
grep -qx 'When the cause above is fixed, run ship again.' "$NF" && ! grep -qx 'Run ship again.' "$NF" && ! grep -q '^build ' "$FX/calls" \
  && pass "  refused at A4, before the build; the fix named first, never a bare 'run ship again'" || fail "  a name not on npm: $(tr '\n' '|' < "$NF" 2>/dev/null)"
printf 'cd "%s/v0.1.0" && echo x > NPM-CHECKED\n' "$OUTR" > "$FX/afterpush"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/afterpush"; hint_row "C6's stamp check" "npm-check has not passed on"
printf 'echo x >> "%s/v0.1.0/sheepr-linux-x86_64"\n' "$OUTR" > "$FX/afterpush"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/afterpush"; hint_row "C6's file check" "a file npm-check checked has changed since"
printf ': > "%s/whoamibad2"\n' "$FX" > "$FX/afterpush"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/afterpush" "$FX/whoamibad2"; hint_row "C6's whoami failing" "npm whoami failed (not logged in to npm?); nothing was published"
printf 'echo other > "%s/whoami"\n' "$FX" > "$FX/afterpush"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/afterpush" "$FX/whoami"; hint_row "C6's whoami another user" "but the packages belong to lukasco; nothing was published"
: > "$FX/pubfail.sheepr-linux-x64"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/pubfail.sheepr-linux-x64"; hint_row "an upload refused" "A browser login or 2FA approval that failed or timed out may be the cause"
rm -rf "${OUTR:?}"; ship; r=$?
completed && hint_free && pass "under ship, a success names no next entry (no 'Next:')" || fail "success hints: $(head -2 "$FX/hints" | tr '\n' '|')"
# npm-check runs only in the real ship (its dry stand-in stands in): its last line, by text
grep -qF 'echo "release: the npm tarballs of $tag check out (NPM-CHECKED written)$(next_hint "; publish comes next, then publish-npm")"' "$RS" \
  && pass "npm-check's 'publish comes next' goes through next_hint (text)" || fail "npm-check's last line"
# control: the sweep's pattern catches a planted next-entry line
printf 'release: x; run release.sh npm-check v0.1.0 first\n' > "$FX/o"; rm -f "$NF"; hint_free && fail "control: the planted line is not caught" || pass "control: a planted 'run release.sh npm-check' line is caught"
# N5: the CHANGELOG's remedy kept under ship (a tag whose entry is undated)
br=$(g symbolic-ref --short HEAD) && g checkout -q --detach "$C" && sed -i.b 's/^## 0\.1\.0 (20[0-9-]*)$/## 0.1.0 (not yet released)/' "$REPO/CHANGELOG.md" && rm -f "$REPO/CHANGELOG.md.b" \
  && g commit -qam undated && g tag -f -a v0.1.0 -m undated HEAD >/dev/null || exit 3
rm -rf "${OUTR:?}"; ship; r=$?
g checkout -q "$br" && g update-ref refs/tags/v0.1.0 "$T" && [ "$(g rev-parse v0.1.0)" = "$T" ] && [ -z "$(g status --porcelain)" ] || exit 3
[ $r = 1 ] && grep -q 'fix it, commit, and tag again' "$FX/o" && pass "under ship, an undated CHANGELOG: its remedy kept (fix it, commit, and tag again)" || fail "N5 changelog: rc=$r $(lastline)"
rm -rf "${OUTR:?}"

# --- the docs: a pushed tag is never deleted (no `push --delete`, `push -d` or deletion refspec
# `:refs/tags/` in PHASE3.md, README.md or release.sh)
tagdel() { grep -n -E -e 'push +(--delete|-d)( |$)' -e '(^|[] "'"'"'`(])\+?:refs/tags/' "$@"; }
[ -z "$(tagdel "$SR_ROOT/PHASE3.md" "$SR_ROOT/README.md" "$RS")" ] && pass "no tag deletion in PHASE3.md, README.md or release.sh" || fail "tag deletion: $(tagdel "$SR_ROOT/PHASE3.md" "$SR_ROOT/README.md" "$RS" | cut -c1-120 | tr '\n' '|')"
printf '%s\n' 'delete it with `git push --delete origin v0.1.0`' '  git push -d origin v0.1.0' '  git push origin :refs/tags/v0.1.0' > "$FX/planted.md"
[ "$(tagdel "$FX/planted.md" | grep -c .)" = 3 ] && pass "control: the three planted deletions are caught" || fail "control: caught $(tagdel "$FX/planted.md" | grep -c .) of 3"
printf '%s\n' '  set -- "$tagobj:refs/tags/$tag"' > "$FX/planted.md"; [ -z "$(tagdel "$FX/planted.md")" ] && pass "control: a push refspec of the tag object is not a deletion" || fail "control: the push refspec is counted"

# --- t_publish_dry's refusals before anything is public, under ship (C3): no push, no upload, no
# POST; the build moved aside (each check of publish_check also has its own row in t_publish_dry)
cr() { # label want-text
  [ $r = 1 ] && grep -q "$2" "$FX/o" && ! grep -q -e 'push --porcelain --atomic' -e '^npm publish' -e '^gh api -X POST' "$FX/calls" \
    && grep -qx "Move $OUTR/v0.1.0 aside (never delete it), then run ship again." "$NF" && pass "under ship, $1: refused at C3, nothing public; move the build aside" || fail "$1: rc=$r $(lastline)"
}
printf 'cd "%s/v0.1.0" && sort -r -k2 SHA256SUMS > S && mv S SHA256SUMS\n' "$OUTR" > "$FX/afterbuild"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/afterbuild"
cr "a SHA256SUMS that is not the build's (reordered)" "SHA256SUMS is not the one the build wrote"
printf 'echo "# edited" >> "%s/v0.1.0/sheepr.rb"\n' "$OUTR" > "$FX/afterbuild"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/afterbuild"
cr "the out dir's cask edited" "is not the cask the tag renders"
: > "$FX/npmcheck.nostamp"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/npmcheck.nostamp"; cr "no npm-check stamp" "npm-check has not passed on"
: > "$FX/npmcheck.touchpkg"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/npmcheck.touchpkg"; cr "an npm package changed after npm-check" "a file npm-check checked has changed since"
rm -rf "${OUTR:?}"

# --- by text, what only the real ship reaches: the notifier swapped to the frozen tree's notify.sh
# (once, after root is the frozen tree, before A8), and shipcall's and shipdocker's real branches
ln_rs() { grep -n -x -F -- "$1" "$RS" | cut -d: -f1; }
sw=$(ln_rs '  [ "$NOTIFY" != frozen-tree ] || NOTIFY=$root/scripts/lib/notify.sh'); rt=$(ln_rs '  wt=$st/tree root=$st/tree'); ar=$(grep -n '^  armed=yes ' "$RS" | cut -d: -f1)
[ "$(printf '%s\n' "$sw" | grep -c .)" = 1 ] && [ -n "$rt" ] && [ -n "$ar" ] && [ "$sw" -gt "$rt" ] && [ "$sw" -lt "$ar" ] \
  && pass "the notifier's swap to the frozen tree's notify.sh: once, after root is the frozen tree, before A8 (text)" || fail "the notifier swap: lines '$sw' root '$rt' armed '$ar'"
grep -qx -F 'shipcall() { if [ "$dryentry" = yes ]; then tool dry "$@"; else "$@"; fi; }' "$RS" && pass "shipcall: the real branch runs the tool as the operator has it (text)" || fail "shipcall's text"
grep -qx -F '  else tool base /usr/bin/env ${DOCKER_HOST:+DOCKER_HOST="$DOCKER_HOST"} ${DOCKER_CONFIG:+DOCKER_CONFIG="$DOCKER_CONFIG"} "$SHIP_DOCKER" "$@"; fi' "$RS" \
  && pass "shipdocker: the real branch, the docker class (text)" || fail "shipdocker's text"
# the tag moved between the checks and its recording (a hook moves it at the $0 compare, to another
# commit with the same tree): refused before anything, since the checked commit is no longer the tag's
cat > "$FX/onshow" <<EOF
cd "$REPO" && env HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \\
  /usr/bin/git commit-tree -p "$C" -m moved "$C^{tree}" > "$FX/movedc" && env HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \\
  /usr/bin/git tag -f -a v0.1.0 -m moved "\$(cat "$FX/movedc")" >/dev/null
EOF
rm -rf "${OUTR:?}"; rm -f "$FX/onshow.done"; ship; r=$?; rm -f "$FX/onshow" "$FX/onshow.done"; g update-ref refs/tags/v0.1.0 "$T" || exit 3
[ $r = 1 ] && grep -q 'moved while ship checked it' "$FX/o" && ! grep -q -e 'push --porcelain --atomic' -e '^npm publish' -e '^gh api -X POST' -e '^build ' "$FX/calls" \
  && pass "the tag moved between the checks and its recording: refused before anything" || fail "the tag moved early: rc=$r $(lastline)"
rm -rf "${OUTR:?}"
# --- no dry HOME left: every one the cell's runs named is gone (refusals included: an rc tag and a
# tag off the grammar are refused before ship's own exit handler is set)
n_dh=$(sort -u "$FX/dryhomes" 2>/dev/null | grep -c .)
left_dh=$(sort -u "$FX/dryhomes" 2>/dev/null | while read -r d; do [ ! -e "$d" ] || echo "$d"; done)
[ -z "$left_dh" ] && [ "$n_dh" -ge 100 ] && [ -z "$(fxleaks)" ] && pass "none of the $n_dh dry HOMEs this cell's runs named is left, nor a phase dir naming it" || fail "dry HOMEs left ($(printf '%s\n' "$left_dh" | grep -c .) of $n_dh): $(printf '%s\n' "$left_dh" | tr '\n' ' ') phase dirs: $(fxleaks | tr '\n' ' ')"
finish
