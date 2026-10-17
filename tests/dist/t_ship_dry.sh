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
for f_ in 8 9; do ( exec 3>&\$f_ ) 2>/dev/null && echo "FD\$f_ git \$*" >> "$FX/fds"; done
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
if [ -e "$FX/onshow" ] && [ ! -e "$FX/onshow.done" ]; then case " \$* " in *" show refs/tags/v0.1.0:scripts/release.sh "*) : > "$FX/onshow.done"; sh "$FX/onshow" ;; esac; fi
case \$sub in
  status|show|rev-parse|worktree|tag|merge-base|config|cat-file|for-each-ref|show-ref|ls-tree|hash-object) exec /usr/bin/git "\$@" ;;
esac
echo "PATH git \$*" >> "$FX/pathcalls"
exit 1
EOF
chmod +x "$B/git"
printf '#!/bin/sh\necho "$1" >> "%s/sleeps"\n' "$FX" > "$B/sleep"; chmod +x "$B/sleep"
# mktemp: the real one; each dir it makes for release.sh (sr-ship, sr-publish, sr-npmpub, sr-dryhome,
# sr-release) is recorded in $FX/made, so a row can hold every one to a name on the run's stderr
cat > "$B/mktemp" <<EOF
#!/bin/sh
# (\$FX/dryhomefail: the next temp HOME is not made; \$FX/publishro: the next sr-publish dir is made
# unwritable; each once)
case "\$*" in *sr-dryhome.*) [ -e "$FX/dryhomefail" ] && { rm -f "$FX/dryhomefail"; echo "mktemp: (stand-in) no dir made" >&2; exit 1; } ;; esac
d=\$(/usr/bin/mktemp "\$@") || exit \$?
case \${d##*/} in sr-publish.*) [ -e "$FX/publishro" ] && { rm -f "$FX/publishro"; chmod 500 "\$d"; } ;; esac
case \${d##*/} in sr-ship.*|sr-publish.*|sr-npmpub.*|sr-dryhome.*|sr-release.*) echo "\$d" >> "$FX/made" ;; esac
printf '%s\n' "\$d"
EOF
chmod +x "$B/mktemp"
# the stand-ins (in the fixtures, by variable): each records "NAME args" in calls and whether its
# HOME exists
S=$FX/st; mkdir -p "$S"
standin() { # name body
  { printf '#!/bin/sh\n[ -d "$HOME" ] || echo "NOHOME %s" >> "%s/calls"\necho "%s $*" >> "%s/calls"\n' "$1" "$FX" "$1" "$FX"
    printf 'for f_ in 8 9; do ( exec 3>&$f_ ) 2>/dev/null && echo "FD$f_ %s" >> "%s/fds"; done\n' "$1" "$FX"; printf '%s\n' "$2"; } > "$S/$1"
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
for f_ in 8 9; do ( exec 3>&\$f_ ) 2>/dev/null && echo "FD\$f_ build" >> "$FX/fds"; done   # (a child that holds ship's fd 8 or 9: the census row)
echo "build \$*" >> "$FX/calls"
[ -e "$FX/onbuild" ] && sh "$FX/onbuild"
# (\$FX/buildlinger: a child left behind, fds 0-2 closed, any other kept; \$FX/buildlinger1: fd 1 kept too)
[ -e "$FX/buildlinger" ] && { /bin/sleep 15 < /dev/null > /dev/null 2>&1 & echo \$! > "$FX/linger.pid"; }
[ -e "$FX/buildlinger1" ] && { /bin/sleep 15 < /dev/null 2>/dev/null & echo \$! > "$FX/linger.pid"; }
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
for f_ in 8 9; do ( exec 3>&\$f_ ) 2>/dev/null && echo "FD\$f_ npmcheck" >> "$FX/fds"; done   # (a child that holds ship's fd 8 or 9: the census row)
echo "npmcheck \$*" >> "$FX/calls"
[ -e "$FX/onnpmcheck" ] && sh "$FX/onnpmcheck"   # (\$FX/onnpmcheck: a hook at C2's npm-check)
# (\$FX/npmcheckfail: npm-check refuses the build's bytes, as npm_check's own checks do: its words for
# the kind in the file (hash, control, codesign; any other: a refusal), and the content class into the
# class file ship gives it, SR_SHIP_DRY_CLASS)
if [ -e "$FX/npmcheckfail" ]; then
  case "\$(cat "$FX/npmcheckfail")" in
    hash) echo "release: sheepr-linux-x64-0.1.0.tgz does not match its manifest hash" >&2 ;;
    control) echo "release: the manifest is a control build" >&2 ;;
    codesign) echo "release: codesign: the darwin package's bundle does not meet the release requirement" >&2 ;;
    *) echo "npm-check: refused (stand-in)" >&2 ;;
  esac
  [ -z "\${SR_SHIP_DRY_CLASS:-}" ] || echo content > "\$SR_SHIP_DRY_CLASS"; exit 1
fi
d=\$1; tg=\$(basename "\$d")
[ -e "$FX/npmcheck.swap" ] && echo ' ' >> "\$d/MANIFEST.json"
printf '%s %s\n' "\$tg" "\$(/usr/bin/shasum -a 256 "\$d/MANIFEST.json" | cut -d' ' -f1)" > "\$d/NPM-CHECKED"
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
for f_ in 8 9; do ( exec 3>&\$f_ ) 2>/dev/null && echo "FD\$f_ gh" >> "$FX/fds"; done   # (a child that holds ship's fd 8 or 9: the census row)
echo "gh \$*" >> "$FX/calls"
case "\$*" in
  *"@tsv"*) [ -e "$FX/relsfail" ] && { if [ -e "$FX/relserr" ]; then cat "$FX/relserr" >&2; else echo "gh: HTTP 502" >&2; fi; exit 1; }; tr ' ' '\t' < "$FX/rels" ;;
  *".[].tag_name"*) awk '{print \$1}' "$FX/rels" ;;
  # (\$FX/repopermfail, tappermfail, tapreadfail: that read fails, with the file's text on stderr, or gh: HTTP 502)
  *"repos/lukaso/sheepr --jq .permissions.push"*) [ -e "$FX/repopermfail" ] && { if [ -s "$FX/repopermfail" ]; then cat "$FX/repopermfail" >&2; else echo "gh: HTTP 502" >&2; fi; exit 1; }; cat "$FX/repoperm" 2>/dev/null || echo true ;;
  *"repos/lukaso/homebrew-tap --jq .permissions.push"*) [ -e "$FX/tappermfail" ] && { if [ -s "$FX/tappermfail" ]; then cat "$FX/tappermfail" >&2; else echo "gh: HTTP 502" >&2; fi; exit 1; }; cat "$FX/tapperm" 2>/dev/null || echo true ;;
  *"-X PUT repos/lukaso/homebrew-tap/contents/Casks/sheepr.rb"*)
    [ -e "$FX/putfail" ] && { echo "gh: HTTP 409" >&2; exit 1; }
    for a; do case \$a in content=*) printf '%s' "\${a#content=}" | base64 -d > "$FX/tap/sheepr.rb" ;; esac; done
    echo c0ffeec0ffeec0ffeec0ffeec0ffeec0ffeec0ff ;;
  *"homebrew-tap/contents/Casks/sheepr.rb"*) [ -e "$FX/tapreadfail" ] && { if [ -s "$FX/tapreadfail" ]; then cat "$FX/tapreadfail" >&2; else echo "gh: HTTP 502" >&2; fi; exit 1; }; [ -f "$FX/tap/sheepr.rb" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }; cat "$FX/tap/sheepr.rb" ;;
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
# npm's userconfig, as npm picks it (REV 11): --userconfig on its command line, else the environment's
# NPM_CONFIG_USERCONFIG or npm_config_userconfig, else \$HOME/.npmrc; the path as npm normalizes it
# (path.resolve: a trailing space trimmed, // and /./ collapsed, .. resolved, a trailing / dropped:
# notes/r14a/np/t1 d). npm's scope: --scope on its
# command line (--scope= empties it), else the userconfig's scope= line; the scope's registry SR, when
# it is not registry.npmjs.org (npm routes login, logout, view, owner and publish to it: notes/builder/np13)
UC=""; SC=""; scset=no
for a_; do case \$a_ in --userconfig=*) UC=\${a_#--userconfig=} ;; --scope=*) SC=\${a_#--scope=}; scset=yes ;; esac; done
[ -n "\$UC" ] || UC=\${NPM_CONFIG_USERCONFIG:-\${npm_config_userconfig:-}}
ucdef=no; [ -n "\$UC" ] || { UC=\$HOME/.npmrc; ucdef=yes; }
case \$UC in *[[:space:]]|*//*|*/./*|*/../*|*/.|*/..|*/) UC=\$(printf '%s\n' "\$UC" | sed -E -e 's/[[:space:]]+\$//' -e 's#/+#/#g' -e ':d' -e 's#/\./#/#' -e 'td' -e 's#/\.\$##' -e ':u' -e 's#/[^/]+/\.\.(/|\$)#/#' -e 'tu' -e 's#(.)/\$#\1#') ;; esac
[ \$scset = yes ] || SC=\$(sed -n 's/^scope=//p' "\$UC" 2>/dev/null | tail -1)
SR=""; [ -z "\$SC" ] || SR=\$(sed -n "s|^\$SC:registry=||p" "\$UC" 2>/dev/null | tail -1)
case \$SR in https://registry.npmjs.org/) SR="" ;; esac
# npm's heading (the first word of each of its log lines): the environment's npm_config_heading, else
# the userconfig's heading= line, else npm, as npm reads it; another heading rewrites this stand-in's
# stderr (its \`npm error code X\` lines among them)
if [ -z "\${SR_NPM_INNER:-}" ]; then
  hd_=\${npm_config_heading:-\$(sed -n 's/^heading=//p' "\$UC" 2>/dev/null | tail -1)}
  if [ -n "\$hd_" ] && [ "\$hd_" != npm ]; then
    SR_NPM_INNER=1 "\$0" "\$@" 2> "$FX/npmhd.err"; r_=\$?; sed "s/^npm /\$hd_ /" "$FX/npmhd.err" >&2; exit \$r_
  fi
fi
[ -d "\$HOME" ] || echo "NOHOME npm" >> "$FX/calls"
for f_ in 8 9; do ( exec 3>&\$f_ ) 2>/dev/null && echo "FD\$f_ npm" >> "$FX/fds"; done   # (a child that holds ship's fd 8 or 9: the census row)
echo "npm \$*" >> "$FX/calls"
echo "\${NODE_EXTRA_CA_CERTS:-none} \$1" >> "$FX/npmenvs"
last=""; for a; do last=\$a; done
TOK='//registry.npmjs.org/:_authToken='
# (\$FX/npmall: every npm command that reaches the registry writes this text on stderr and fails)
case \$1 in view|owner|whoami|login|publish) [ -e "$FX/npmall" ] && { cat "$FX/npmall" >&2; exit 1; } ;; esac
# npm's project config, as npm finds it: the .npmrc in the first dir up from the cwd that holds a
# package.json or a node_modules; a token there wins over the userconfig's (here: an expired one)
echo "\$PWD" >> "$FX/npmcwds"
pd_=\$PWD; while [ ! -e "\$pd_/package.json" ] && [ ! -d "\$pd_/node_modules" ]; do [ "\$pd_" = / ] && { pd_=""; break; }; pd_=\$(dirname "\$pd_"); done
if [ -n "\$pd_" ] && grep -q '_authToken=' "\$pd_/.npmrc" 2>/dev/null; then
  case \$1 in view|owner|whoami) printf 'npm error code E401\nnpm error 401 Unauthorized - the project config token (stand-in)\n' >&2; exit 1 ;;
    logout) grep -v '_authToken=' "\$pd_/.npmrc" > "\$pd_/.npmrc.n"; mv "\$pd_/.npmrc.n" "\$pd_/.npmrc"; echo "LOGOUT ended the project token" >> "$FX/calls"; exit 0 ;; esac
fi
# npm's scope routing to B (npm 10 and 11; npm 9 sends B's token to --registry instead): every request
# that reaches B is recorded in \$FX/reqs with the token it carries; B holds no sheepr
if [ -n "\$SR" ]; then
  bh_=\${SR#*//}; bh_=\${bh_%/}; bt_=\$(sed -n "s|^//\$bh_/:_authToken=||p" "\$UC" 2>/dev/null | tail -1)
  case \$1 in
    logout) echo "REQ B logout auth=\${bt_:-none}" >> "$FX/reqs"
      grep -v -e "^//\$bh_/:_authToken=" -e "^\$SC:registry=" "\$UC" > "\$UC.n"; mv "\$UC.n" "\$UC"; exit 0 ;;
    view|owner|publish) echo "REQ B \$1 auth=\${bt_:-none}" >> "$FX/reqs"; echo "npm error code E404" >&2; echo "npm error 404 Not Found - GET \$SR (stand-in B)" >&2; exit 1 ;;
  esac
fi
case \$1 in
  view) p=""; for a; do case \$a in sheepr*) p=\${a%@*} ;; esac; done
    [ -e "$FX/owner404.\$p" ] && { echo "npm error code E404" >&2; exit 1; }   # a name not on npm: every view is E404
    [ -e "$FX/owner404json.\$p" ] && { printf '{\n  "error": {\n    "code": "E404",\n    "summary": "Not Found"\n  }\n}\n'; exit 1; }   # the same, said only in --json's stdout
    [ -e "$FX/viewfail.\$p" ] && { echo "npm error code ETIMEDOUT" >&2; exit 1; }
    # (\$FX/viewcode.FIELD: the view of FIELD, time or dist-tags.latest, answers that npm error code)
    [ -e "$FX/viewcode.\$last" ] && { echo "npm error code \$(cat "$FX/viewcode.\$last")" >&2; echo "npm error the view of \$p \$last (stand-in)" >&2; exit 1; }
    case \$last in
      time) cat "$FX/time.\$p" 2>/dev/null || printf '{\n  "created": "2026-10-01T00:00:00.000Z",\n  "0.0.9": "2026-10-02T00:00:00.000Z"\n}\n'; exit 0 ;;
      dist-tags.latest) printf '"%s"\n' "\$(cat "$FX/latest.\$p" 2>/dev/null || echo 0.0.9)"; exit 0 ;;
    esac
    [ -e "$FX/viewfailv.\$p" ] && { echo "npm error code ETIMEDOUT" >&2; exit 1; }   # the version's view only
    # (\$FX/viewother.\$p N: once N uploads are recorded, the version's view answers another file;
    # \$FX/onviewpush.\$p: a hook run once at the version's view, once the push is done)
    [ -e "$FX/viewother.\$p" ] && [ "\$(grep -c '^npm publish' "$FX/calls")" -ge "\$(cat "$FX/viewother.\$p")" ] && { printf '"sha512-another"\n'; exit 0; }
    if [ -e "$FX/onviewpush.\$p" ] && [ ! -e "$FX/onviewpush.\$p.done" ] && grep -qx 'done push' "$FX/out/.v0.1.0.ship-progress" 2>/dev/null; then
      : > "$FX/onviewpush.\$p.done"; sh "$FX/onviewpush.\$p"
    fi
    if [ -f "$FX/pub.\$p" ]; then
      k=\$(cat "$FX/processing.\$p" 2>/dev/null || echo 0)
      if [ "\$k" -gt 0 ]; then echo \$((k - 1)) > "$FX/processing.\$p"; echo "npm error code E404" >&2; exit 1; fi
      printf '"%s"\n' "\$(cat "$FX/pub.\$p")"; exit 0
    fi
    if [ -f "$FX/view.\$p" ]; then printf '"%s"\n' "\$(cat "$FX/view.\$p")"; exit 0; fi
    printf '{\n  "error": {\n    "code": "E404"\n  }\n}\n'; echo "npm error code E404" >&2; exit 1 ;;
  # (\$FX/onowner: a hook at owner ls once the build ran, i.e. C3's publish_check)
  owner) [ -e "$FX/onowner" ] && grep -q '^build ' "$FX/calls" && sh "$FX/onowner"
    [ -e "$FX/ownererr" ] && { cat "$FX/ownererr" >&2; exit 1; }   # (\$FX/ownererr: npm's own words, then a failure)
    [ -e "$FX/ownerfail" ] && { echo "npm error code ETIMEDOUT" >&2; exit 1; }
    [ -e "$FX/ownercode" ] && { echo "npm error code \$(cat "$FX/ownercode")" >&2; exit 1; }   # (\$FX/ownercode: the code it answers)
    # (\$FX/ownerfailafter: fails once three uploads are recorded, i.e. after C6)
    [ -e "$FX/ownerfailafter" ] && [ "\$(grep -c '^npm publish' "$FX/calls")" -ge 3 ] && { echo "npm error code ETIMEDOUT" >&2; exit 1; }
    [ -e "$FX/owner404.\$3" ] && { echo "npm error code E404" >&2; exit 1; }
    if [ -f "$FX/owner.\$3" ]; then echo "\$(cat "$FX/owner.\$3") <x@example.com>"; else echo "lukasco <x@example.com>"; fi; exit 0 ;;
  # (config get userconfig, as npm answers it (notes/r14a/np/t1 a, b): the userconfig --userconfig or the
  # environment names, normalized, even when that file holds a userconfig= key; with neither, a
  # userconfig= key in \$HOME/.npmrc, else that file. \$FX/homekey: that key, put into the HOME's .npmrc
  # at this call (a dry entry makes its HOME at the run). config delete KEY: that key's lines out of the userconfig)
  config) case "\$2 \$3" in
      "get userconfig") [ \$ucdef = yes ] && [ -s "$FX/homekey" ] && ! grep -q '^userconfig=' "\$UC" 2>/dev/null && echo "userconfig=\$(cat "$FX/homekey")" >> "\$UC"
        k_=""; [ \$ucdef = no ] || k_=\$(sed -n 's/^userconfig=//p' "\$UC" 2>/dev/null | tail -1); echo "\${k_:-\$UC}"; exit 0 ;;
      "delete //registry.npmjs.org/:_authToken") [ -f "\$UC" ] && { grep -v "^\$TOK" "\$UC" > "\$UC.n"; mv "\$UC.n" "\$UC"; }; exit 0 ;;
    esac ;;
  whoami) [ -e "$FX/whoamibad" ] && { echo "npm error code ETIMEDOUT" >&2; exit 1; }
    # (\$FX/whoamiansi: the code it answers, in npm's colours, as color=always writes it)
    [ -e "$FX/whoamiansi" ] && { printf '\033[1mnpm\033[22m \033[31merror\033[39m \033[94mcode\033[39m %s\n' "\$(cat "$FX/whoamiansi")" >&2; exit 1; }
    [ -e "$FX/whoamicode" ] && { echo "npm error code \$(cat "$FX/whoamicode")" >&2; exit 1; }   # (\$FX/whoamicode: the code it answers)
    # (\$FX/whoamipostlogin: the code it answers once npm login ran: C4's whoami, not A6's)
    [ -e "$FX/whoamipostlogin" ] && grep -q '^npm login' "$FX/calls" && { echo "npm error code \$(cat "$FX/whoamipostlogin")" >&2; exit 1; }
    # (\$FX/whoamibadmain: fails once three uploads are recorded, i.e. at C8)
    [ -e "$FX/whoamibadmain" ] && [ "\$(grep -c '^npm publish' "$FX/calls")" -ge 3 ] && { echo "npm error code ETIMEDOUT" >&2; exit 1; }
    # (a username and _password pair: whoami answers the user name, as npm does)
    grep -q '^//registry.npmjs.org/:username=' "\$UC" 2>/dev/null && grep -q '^//registry.npmjs.org/:_password=' "\$UC" && { sed -n 's|^//registry.npmjs.org/:username=||p' "\$UC" | head -1; exit 0; }
    # (an //registry.npmjs.org/:_auth= line: whoami answers its user, as npm does for basic auth)
    grep -q '^//registry.npmjs.org/:_auth=' "\$UC" 2>/dev/null && { cat "$FX/whoami" 2>/dev/null || echo lukasco; exit 0; }
    if grep -q "^\$TOK" "\$UC" 2>/dev/null; then
      [ -e "$FX/whoamibad2" ] && { echo "npm error code ETIMEDOUT" >&2; exit 1; }
      [ -e "$FX/expired" ] && { echo "npm error code E401" >&2; exit 1; }
      cat "$FX/whoami" 2>/dev/null || echo lukasco; exit 0
    fi
    # no token line: ENEEDAUTH (\$FX/whoamierr: npm's whole answer instead, e.g. coloured, or npm 9's)
    if [ -e "$FX/whoamierr" ]; then cat "$FX/whoamierr" >&2; else echo "npm error code ENEEDAUTH" >&2; fi; exit 1 ;;
  # (\$FX/loginnormalizes: the login rewrites the file as npm's ini writer does, a quoted key unquoted)
  login) [ -e "$FX/onlogin" ] && sh "$FX/onlogin"   # (\$FX/onlogin: a hook at C4's npm login)
    [ -e "$FX/loginfail" ] && exit 1
    # (with a scope, npm login writes <scope>:registry=<--registry>: the scope's routing is rewritten)
    [ -n "\$SC" ] && { grep -v "^\$SC:registry=" "\$UC" > "\$UC.n" 2>/dev/null; echo "\$SC:registry=https://registry.npmjs.org/" >> "\$UC.n"; mv "\$UC.n" "\$UC"; echo "REQ A login rewrote \$SC:registry" >> "$FX/reqs"; }
    [ -e "$FX/loginnormalizes" ] && [ -f "\$UC" ] && { sed -e "s/^'\\([^']*\\)'=/\\1=/" "\$UC" > "\$UC.n"; mv "\$UC.n" "\$UC"; }
    # (\$FX/logintoken: the token the login writes, instead of npm_dry)
    echo LOGIN >> "$FX/tokops"   # (\$FX/tokops: each login's write, in order with the tokens the logouts end)
    if [ -s "$FX/logintoken" ]; then echo "\${TOK}\$(cat "$FX/logintoken")" >> "\$UC"; else echo "\${TOK}npm_dry" >> "\$UC"; fi; exit 0 ;;
  logout) [ -e "$FX/onlogout" ] && sh "$FX/onlogout"   # (\$FX/onlogout: a hook as ship's logout starts)
    [ -e "$FX/logoutint" ] && exec /usr/bin/perl -e 'getpgrp() == getppid() or do { open(my \$f, ">>", "$FX/calls"); print \$f "UNSAFE logoutint\\n"; exit 1 }; \$SIG{INT} = "DEFAULT"; kill "INT", 0; sleep 5; exit 0'
    # (\$FX/logoutmsg CODE: the logout fails with npm's own words for CODE, the request's URL naming the
    # token it sends (npm masks only its npm_ shape, as npm_***: notes/r13a/np/t9b-*), and the line stays)
    if [ -s "$FX/logoutmsg" ]; then
      t_=\$(sed -n "s|^\$TOK||p" "\$UC" | tail -1); case \$t_ in npm_*) t_='npm_***' ;; esac
      case \$(cat "$FX/logoutmsg") in
        E401) printf 'npm error code E401\nnpm error 401 Unauthorized - DELETE https://registry.npmjs.org/-/user/token/%s - token expired or revoked\n' "\$t_" >&2 ;;
        E503) printf 'npm error code E503\nnpm error 503 Service Unavailable - DELETE https://registry.npmjs.org/-/user/token/%s - down\n' "\$t_" >&2 ;;
        *) printf 'npm error code FETCH_ERROR\nnpm error errno FETCH_ERROR\nnpm error network timeout at: https://registry.npmjs.org/-/user/token/%s\n' "\$t_" >&2 ;;
      esac; exit 1
    fi
    # (\$FX/logoutcode: the logout fails with that npm error code, and the line stays)
    [ -e "$FX/logoutcode" ] && { echo "npm error code \$(cat "$FX/logoutcode")" >&2; exit 1; }
    # (a username and _password pair and no token line: npm logout removes the pair, as npm does)
    if grep -q '^//registry.npmjs.org/:username=' "\$UC" 2>/dev/null && ! grep -q "^\$TOK" "\$UC"; then
      grep -v -e '^//registry.npmjs.org/:username=' -e '^//registry.npmjs.org/:_password=' "\$UC" > "\$UC.n"; mv "\$UC.n" "\$UC"; exit 0
    fi
    # (an _auth line and no token line: npm logout answers ENEEDAUTH and leaves the line)
    grep -q '^//registry.npmjs.org/:_auth=' "\$UC" 2>/dev/null && ! grep -q "^\$TOK" "\$UC" && { echo "npm error code ENEEDAUTH" >&2; exit 1; }
    [ -e "$FX/logoutfail" ] && exit 1; [ -e "$FX/logoutstays" ] && exit 0; [ -e "$FX/logoutrm" ] && { rm -f "\$UC"; exit 0; }
    [ -e "$FX/logoutlies" ] && { grep -v "^\$TOK" "\$UC" > "\$UC.n" 2>/dev/null; mv "\$UC.n" "\$UC"; exit 1; }
    # (\$FX/logoutleaves: a line it leaves in the userconfig, as npm logout leaves any but the root line)
    t_=\$(sed -n "s|^\$TOK||p" "\$UC" 2>/dev/null | tail -1); [ -z "\$t_" ] || echo "DELETE token=\$t_" >> "$FX/tokops"   # (the token it ends)
    grep -v "^\$TOK" "\$UC" > "\$UC.n" 2>/dev/null; mv "\$UC.n" "\$UC"; [ ! -e "$FX/logoutleaves" ] || cat "$FX/logoutleaves" >> "\$UC"; exit 0 ;;
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
for f_ in 8 9; do ( exec 3>&\$f_ ) 2>/dev/null && echo "FD\$f_ docker" >> "$FX/fds"; done   # (a child that holds ship's fd 8 or 9: the census row)
echo "docker \$*" >> "$FX/calls"
case \$1 in info) [ -e "$FX/oninfo" ] && sh "$FX/oninfo"; [ -e "$FX/nodocker" ] && exit 1; exit 0 ;;   # (\$FX/oninfo: a hook at A7's docker info)
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
for f_ in 8 9; do ( exec 3>&\$f_ ) 2>/dev/null && echo "FD\$f_ sgit" >> "$FX/fds"; done   # (a child that holds ship's fd 8 or 9: the census row)
echo "sgit \$*" >> "$FX/calls"
c=""; if [ "\$1" = -C ]; then c=\$2; shift 2; fi
if [ "\$1 \$2" = "remote get-url" ]; then
  case " \$* " in *" --push "*) cat "$FX/pushurl" 2>/dev/null || echo https://github.com/lukaso/sheepr.git ;; *) cat "$FX/fetchurl" 2>/dev/null || echo https://github.com/lukaso/sheepr.git ;; esac
  exit 0
fi
up=\$(cat "$FX/updir" 2>/dev/null || echo "file://$FX/origin.git")
n=\$#; for a; do [ "\$a" = https://github.com/lukaso/sheepr ] && a=\$up; set -- "\$@" "\$a"; done; shift \$n
# only local bare repos: the remote argument (the first one after the subcommand that is not an
# option) is resolved as git would resolve it, in the repo the call names: a remote's every URL and
# push URL (insteadOf applied), else the argument itself as git reads it (an scp form, a path, a
# URL); anything that is not file:// is refused before git runs (the network is never reached)
case \$1 in push|fetch|ls-remote)
  rem=""; for a in "\$@"; do [ "\$a" = "\$1" ] && continue; case \$a in -*) ;; *) rem=\$a; break ;; esac; done
  [ -n "\$rem" ] || { echo "SGIT REFUSED (no remote argument)" >> "$FX/calls"; echo "sgit: no remote argument" >&2; exit 1; }
  sg() { GIT_CONFIG_NOSYSTEM=1 /usr/bin/git \${c:+-C "\$c"} "\$@"; }
  if sg remote get-url "\$rem" >/dev/null 2>&1; then
    urls=\$(sg remote get-url --all "\$rem"; sg remote get-url --push --all "\$rem"; sg ls-remote --get-url "\$rem")
  else
    urls=\$(sg ls-remote --get-url "\$rem")
  fi
  [ -n "\$urls" ] || { echo "SGIT REFUSED \$rem (no URL)" >> "$FX/calls"; echo "sgit: refused \$rem" >&2; exit 1; }
  for u in \$urls; do case \$u in file://*) ;; *) m=\$u; [ "\$u" = "\$rem" ] || m="\$rem \$u"
    echo "SGIT REFUSED \$m" >> "$FX/calls"; echo "sgit: refused \$m (only file:// remotes)" >&2; exit 1 ;; esac; done ;;
esac
extra="" real=no lie=""
[ "\$1" = ls-remote ] && [ -e "$FX/lsfail" ] && { if [ -e "$FX/lserr" ]; then cat "$FX/lserr" >&2; else echo "fatal: unable to access (stand-in)" >&2; fi; exit 128; }
[ "\$1" = fetch ] && [ -e "$FX/fetchfail" ] && { if [ -s "$FX/fetchfail" ]; then cat "$FX/fetchfail" >&2; else echo "fatal: unable to access (stand-in)" >&2; fi; exit 128; }
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
# (after a fetch that succeeded: FETCH_HEAD, and origin's refs/heads/main as ls-remote names it)
if [ "\${3:-}" = fetch ] && [ \$r = 0 ]; then
  echo "FH \$(GIT_CONFIG_NOSYSTEM=1 /usr/bin/git -C "\$2" rev-parse FETCH_HEAD) \$(GIT_CONFIG_NOSYSTEM=1 /usr/bin/git -C "\$2" ls-remote origin refs/heads/main | cut -f1)" >> "$FX/fetchheads"
fi
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

tnow() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.2f\n", time'; }   # the clock, in seconds, to 1/100
ship() { # args... -> rc; output in $FX/o. The default stand-ins; NO: names whose variable is left out;
         # SETX: one more assignment
  rm -f "$FX/calls" "$FX/pathcalls" "$FX/asks" "$FX/npmenvs" "$FX/pipe.rc" "$FX/made"
  set -- SR_ASK_RECORD="$FX/asks" SR_SHIP_DRY_BUILD="$S/build" SR_SHIP_DRY_NPMCHECK="$S/npmcheck" SR_SHIP_DRY_NOTIFY="$S/notify" SR_SHIP_DRY_CAFFEINATE="$S/caffeinate" \
    SR_SHIP_DRY_IDENTITY="$S/identity" SR_SHIP_DRY_DOCKER="$S/docker" SR_PUBLISH_DRY_GH="$S/gh" SR_PUBLISH_DRY_GIT="$S/sgit" \
    SR_PUBLISH_DRY_NPM="$S/npm" SR_PUBLISH_DRY_CURL="$S/curl" NPM_CONFIG_USERCONFIG="$FX/npmrc" $( [ "${VERIFIED:-}" = - ] || printf '%s' "SR_PUBLISH_DRY_VERIFIED=${VERIFIED:-$AH}" ) "$@"
  envs=""; for a; do case $a in *=*) k=${a%%=*}; case " ${NO:-} " in *" $k "*) continue ;; esac; envs="$envs
$a" ;; esac; done
  # the assignments as arguments to env, one per line (a value may hold spaces)
  printf '%s\n' "$envs" | sed '/^$/d' > "$FX/envs"
  set --; [ -z "${SETSID:-}" ] || set -- /usr/bin/perl -e 'use POSIX; setsid() or die "setsid: $!"; $SIG{$_} = "DEFAULT" for qw(INT QUIT); exec @ARGV or die' --
  if [ -n "${PIPEEOF:-}" ]; then   # stdout into a pipe: its reader notes when it reads EOF; ship's own end too
    { (cd "$REPO" && IFS='
'; no_osascript "$@" env -i PATH="$B:/usr/bin:/bin" HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      $(cat "$FX/envs") ${SETX:+"$SETX"} sh scripts/release.sh __ship-dry --out "${OUT:-$OUTR}" "${TAG:-v0.1.0}") 2> "$FX/o.err"; echo $? > "$FX/pipe.rc"; tnow > "$FX/t.end"; } \
      | { cat > "$FX/o"; tnow > "$FX/t.eof"; }
    cat "$FX/o.err" >> "$FX/o"; r_=$(cat "$FX/pipe.rc")
  elif [ -n "${CLOSEFD:-}" ]; then   # fd CLOSEFD closed at the start (the other to $FX/o); SHX: the shell
    if [ "$CLOSEFD" = 1 ]; then
      (cd "$REPO" && IFS='
'; no_osascript "$@" env -i PATH="$B:/usr/bin:/bin" HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        $(cat "$FX/envs") ${SHX:-sh} scripts/release.sh __ship-dry --out "${OUT:-$OUTR}" "${TAG:-v0.1.0}") >&- 2> "$FX/o"; r_=$?
    else
      (cd "$REPO" && IFS='
'; no_osascript "$@" env -i PATH="$B:/usr/bin:/bin" HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        $(cat "$FX/envs") ${SHX:-sh} scripts/release.sh __ship-dry --out "${OUT:-$OUTR}" "${TAG:-v0.1.0}") 2>&- > "$FX/o"; r_=$?
    fi
  elif [ -z "${PIPEQ:-}" ]; then
    (cd "$REPO" && IFS='
'; no_osascript "$@" env -i PATH="$B:/usr/bin:/bin" HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      $(cat "$FX/envs") ${SETX:+"$SETX"} sh scripts/release.sh __ship-dry --out "${OUT:-$OUTR}" "${TAG:-v0.1.0}") > "$FX/o" 2>&1; r_=$?
  else
    { (cd "$REPO" && IFS='
'; no_osascript "$@" env -i PATH="$B:/usr/bin:/bin" HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      $(cat "$FX/envs") ${SETX:+"$SETX"} sh scripts/release.sh __ship-dry --out "${OUT:-$OUTR}" "${TAG:-v0.1.0}") 2> "$FX/o"; echo $? > "$FX/pipe.rc"; } | sed -n "/$PIPEQ/q"
    r_=$(cat "$FX/pipe.rc")
  fi
  dryhomes "$FX/o"; cat "$FX/made" >> "$FX/allmade" 2>/dev/null
  postpush_scan
  [ ! -s "$FX/pathcalls" ] || fail "a PATH tool was called in a ship run: $(head -2 "$FX/pathcalls" | tr '\n' ' ')"
  [ -n "${KEEP:-}" ] || world_reset; return $r_
}
# after a run whose progress holds `start push` (and no `push refused`): its next file and its output
# (stdout and stderr, the first cause line among them) never say that nothing is public; the hits
# are kept for the last row, with the count of such runs
postpush_scan() {
  pf=${OUT:-$OUTR}/.${TAG:-v0.1.0}.ship-progress nf_=${OUT:-$OUTR}/${TAG:-v0.1.0}.ship-next.txt
  grep -qx 'start push' "$pf" 2>/dev/null || return 0
  ! grep -q '^push refused' "$pf" || return 0
  echo x >> "$FX/postpush.runs"
  for f_ in "$nf_" "$FX/o"; do
    [ -f "$f_" ] && grep -n -i -E 'nothing (is|was) publi|made nothing public|nothing after it is publi' "$f_" | sed "s|^|$f_:|" >> "$FX/postpush.bad"
  done
  return 0
}
# the temp dirs a run named on its output (`a temp dir, PATH` on stderr, and the dry entries' `a temp
# HOME, PATH`): a PIPEQ run's $FX/o holds its stderr only
named() { sed -n -e 's/.*a temp HOME, \(\/private\/tmp\/sr-[a-z]*\.[A-Za-z0-9]*\).*/\1/p' -e 's/.*a temp dir, \(\/private\/tmp\/sr-[a-z]*\.[A-Za-z0-9]*\).*/\1/p' "$1" | sort -u; }
# the dirs the last run made (mktemp's record) that it did not name, or that are left
unnamed() { named "$FX/o" > "$FX/named"; sort -u "$FX/made" 2>/dev/null | grep -v -x -F -f "$FX/named"; }
leftover() { sort -u "$FX/made" "$FX/named" 2>/dev/null | while read -r d; do [ ! -e "$d" ] || echo "$d"; done; }
# every dir the last run made is named on its output and gone
leakfree() { [ -z "$(unnamed)" ] && [ -z "$(leftover)" ]; }
# the dirs a run named (a phase's go to stderr, so a PIPEQ run's are read too), for the last row
dryhomes() { named "$1" >> "$FX/dryhomes"; }
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
  ship_fds
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
grep -q "^sgit -C $WTP fetch -q origin refs/heads/main\$" "$FX/calls" && pass "origin's main fetched by its full ref, in the frozen tree" || fail "the fetch: $(grep fetch "$FX/calls" | head -1)"
grep -q "^sgit -C $WTP ls-remote origin refs/heads/main refs/tags/v0\.1\.0\*\$" "$FX/calls" && grep -q "^sgit -C $WTP ls-remote https://github.com/lukaso/sheepr refs/heads/main refs/tags/v0\.1\.0\*\$" "$FX/calls" \
  && pass "ls-remote of origin and of github.com/lukaso/sheepr" || fail "ls-remote: $(grep ls-remote "$FX/calls" | tr '\n' ' ')"
[ "$(g rev-parse -q --verify refs/tags/v0.1.0)" = "$T" ] && pass "the unpushed tag survives the fetch (fetch.prune and pruneTags on)" || fail "the local tag is gone"
[ "$(sort "$FX/origin.after" | tr '\n' ' ')" = "$(printf '%s refs/heads/main\n%s refs/tags/v0.1.0\n' "$C" "$T" | sort | tr '\n' ' ')" ] \
  && pass "the push reached origin: main at the tag's commit and the tag object, nothing else (not x-follow, push.followTags on)" || fail "origin after: $(tr '\n' ' ' < "$FX/origin.after")"
[ "$(g worktree list | grep -c .)" = 1 ] && pass "the frozen tree is removed at the end" || fail "worktrees left: $(g worktree list | tr '\n' ' ')"
nopath && pass "no git call outside \$GITCMD reached the network (the PATH shim saw local subcommands only)" || fail "PATH calls: $(cat "$FX/pathcalls")"
# an annotated tag named main on origin: every fetch names refs/heads/main, so FETCH_HEAD is origin's
# branch main (as ls-remote reads it) and the run completes; a short `main` took the tag first
GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t git --git-dir="$FX/origin.git" tag -a main -m main "$BASE" || exit 3
rm -f "${FX:?}/fetchheads"; rm -rf "${OUTR:?}"; ship; r=$?
git --git-dir="$FX/origin.git" tag -d main > /dev/null || exit 3
nfh=$(cat "$FX/fetchheads" 2>/dev/null | grep -c .); bad=$(awk '$2 != $3' "$FX/fetchheads" 2>/dev/null)
completed && [ "$nfh" -ge 2 ] && [ -z "$bad" ] && pass "a tag named main on origin: the run completes; each of its $nfh fetches put origin's refs/heads/main in FETCH_HEAD" \
  || fail "a tag named main: rc=$r fetches: $nfh, FETCH_HEAD not main: $(printf '%s' "$bad" | tr '\n' '|') $(lastline)"
# the $0 compare: an edit hidden from git status (assume-unchanged) is still refused
g update-index --assume-unchanged scripts/release.sh && cp "$REPO/scripts/release.sh" "$FX/rs.keep" && echo '# an edit' >> "$REPO/scripts/release.sh"
rm -rf "${OUTR:?}"; ship; r=$?
cp "$FX/rs.keep" "$REPO/scripts/release.sh"; g update-index --no-assume-unchanged scripts/release.sh
[ $r = 1 ] && grep -q "is not v0.1.0's" "$FX/o" && ! grep -q '^sgit' "$FX/calls" 2>/dev/null && pass "a scripts/release.sh that is not the tag's (assume-unchanged): refused before any remote call" || fail "\$0 compare: rc=$r $(lastline)"
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
# every file the tag tracks under scripts/ is compared with this checkout's bytes, read from the files
# (not the index): an edit of scripts/lib/sign.sh hidden by assume-unchanged, then by skip-worktree,
# is refused before any remote call, by name; the control: the clean checkout passes the compare
for fl in assume-unchanged skip-worktree; do
  g update-index --$fl scripts/lib/sign.sh && cp "$REPO/scripts/lib/sign.sh" "$FX/sign.keep" && echo '# an edit' >> "$REPO/scripts/lib/sign.sh" \
    && ! cmp -s "$FX/sign.keep" "$REPO/scripts/lib/sign.sh" && [ -z "$(g status --porcelain)" ] || fail "the hidden sign.sh edit ($fl) was not made"
  rm -rf "${OUTR:?}"; ship; r=$?
  cp "$FX/sign.keep" "$REPO/scripts/lib/sign.sh"; g update-index --no-$fl scripts/lib/sign.sh
  [ $r = 1 ] && grep -q "scripts/lib/sign.sh is not v0.1.0's" "$FX/o" && ! grep -q '^sgit' "$FX/calls" 2>/dev/null \
    && pass "a scripts/lib/sign.sh that is not the tag's ($fl): refused before any remote call, by name" || fail "sign.sh compare ($fl): rc=$r $(lastline)"
done
rm -rf "${OUTR:?}"; ship; r=$?
! grep -q "is not v0.1.0's" "$FX/o" && grep -q "^sgit -C $WTP push --dry-run" "$FX/calls" && pass "control: a clean checkout of the tag passes the compare of scripts/ (the run goes on to the push)" || fail "control, a clean checkout: rc=$r $(lastline)"
# a filter cannot hide an edit either: .git/info/attributes gives sign.sh `text eol=crlf`, and it is
# checked out again (CR bytes in the file; git status clean; no index flag): the compare reads the
# file's own bytes (--no-filters), so it is refused by name before any remote call
printf 'scripts/lib/sign.sh text eol=crlf\n' >> "$REPO/.git/info/attributes" && rm -f "${REPO:?}/scripts/lib/sign.sh" && g checkout -- scripts/lib/sign.sh \
  && [ "$(tr -cd '\r' < "$REPO/scripts/lib/sign.sh" | wc -c | tr -d ' ')" -gt 0 ] && [ -z "$(g status --porcelain)" ] || fail "the CRLF checkout of sign.sh was not made"
rm -rf "${OUTR:?}"; ship; r=$?
sed '/^scripts\/lib\/sign.sh text eol=crlf$/d' "$REPO/.git/info/attributes" > "$FX/attr.n" && mv "$FX/attr.n" "$REPO/.git/info/attributes" \
  && rm -f "${REPO:?}/scripts/lib/sign.sh" && g checkout -- scripts/lib/sign.sh && [ "$(tr -cd '\r' < "$REPO/scripts/lib/sign.sh" | wc -c | tr -d ' ')" = 0 ] || fail "sign.sh not put back"
[ $r = 1 ] && grep -q "scripts/lib/sign.sh is not v0.1.0's" "$FX/o" && ! grep -q '^sgit' "$FX/calls" 2>/dev/null \
  && pass "a scripts/lib/sign.sh checked out with CRLF by an attribute (git status clean): refused before any remote call, by name" || fail "sign.sh CRLF: rc=$r $(lastline)"
# the files ship's parent sources from the checkout, enumerated from release.sh: the source commands
# outside any function are one, and it reads the list ship compares ($sourced)
topsrc() { # file -> "LINE top WORDS" for each source command (`.` or `source`, any quoting) outside
           # every function body, read as the shell reads it (tests/lib/sigsweep.py's reader)
  python3 -I "$SR_ROOT/tests/lib/sigsweep.py" --sources "$1" | grep '^[0-9]* top '
}
topsrc "$SR_ROOT/scripts/release.sh" > "$FX/top.src"
[ "$(grep -c . "$FX/top.src")" = 1 ] && grep -q '\. "\$root/\$sourced"' "$FX/top.src" && grep -q '^sourced=scripts/lib/sigs\.sh$' "$SR_ROOT/scripts/release.sh" \
  && pass "ship's parent sources one file from the checkout before its frozen tree, the one it compares" || fail "top-level source commands: $(tr '\n' '|' < "$FX/top.src")"
# the controls, each a copy of release.sh with one more top-level source command: before die (a
# top-level line after the first functions, found by its text), before the dispatch, unquoted, and
# spelled `source`: each must count 2
RSL=$SR_ROOT/scripts/release.sh; dl=$(grep -n '^case \$sub in$' "$RSL" | tail -1 | cut -d: -f1); fl=$(grep -n '^die() {' "$RSL" | head -1 | cut -d: -f1)
for pc in "$fl:. \"\$root/scripts/lib/realtools.sh\" || exit 1" "$dl:. \"\$root/scripts/lib/realtools.sh\" || exit 1" \
          "$fl:. \$root/scripts/lib/realtools.sh" "$fl:source \"\$root/scripts/lib/realtools.sh\""; do
  pl=${pc%%:*} pt=${pc#*:}
  awk -v L="$pl" -v T="$pt" 'NR == L {print T} {print}' "$RSL" > "$FX/rs.plant"
  [ "$(sed -n "${pl}p" "$FX/rs.plant")" = "$pt" ] || fail "control: the plant '$pt' is not at line $pl"
  n=$(topsrc "$FX/rs.plant" | grep -c .)
  [ "$n" = 2 ] && pass "control: a top-level '$pt' at line $pl is counted (2)" || fail "control: a top-level '$pt' at line $pl: counted $n, want 2"
done
# the push target
pt_row() { # label want-text: set up by the caller; one run
  rm -rf "${OUTR:?}"; ship; r=$?
  [ $r = 1 ] && grep -q "$2" "$FX/o" && ! grep -q 'push --dry-run' "$FX/calls" && pass "$1: refused before any push" || fail "$1: rc=$r $(lastline)"
}
echo https://github.com/someone/sheepr.git > "$FX/pushurl"; pt_row "a push URL that is not lukaso/sheepr" "is not lukaso/sheepr"; rm -f "$FX/pushurl"
echo git@gh-alias:lukaso/sheepr.git > "$FX/pushurl"; pt_row "an ssh host alias" "ssh host alias"; rm -f "$FX/pushurl"
# a credential in a URL is never printed: origin's URL as `remote get-url` gives it once an insteadOf
# rule put a user and a password in it; and git's own message naming such a URL (the ls-remote of
# github.com/lukaso/sheepr, rewritten the same way). Each refusal names the host and the path; no
# SECRET in stdout, stderr or the next file
echo 'https://user:SECRET1@host.invalid/lukaso/sheepr.git' > "$FX/pushurl"; pt_row "origin's URL with a credential in it" "is not lukaso/sheepr"; rm -f "${FX:?}/pushurl"
! grep -q SECRET1 "$FX/o" "$OUTR/v0.1.0.ship-next.txt" && grep -qF 'https://<redacted>@host.invalid/lukaso/sheepr.git is not lukaso/sheepr' "$OUTR/v0.1.0.ship-next.txt" \
  && pass "  no credential in stdout or the next file; the host and the path named, <redacted> in the userinfo's place" || fail "  credential printed: $(grep -c SECRET1 "$FX/o" "$OUTR/v0.1.0.ship-next.txt" | tr '\n' ' ')"
printf "fatal: unable to access 'https://user:SECRET2@host.invalid/lukaso/sheepr/': Could not resolve host: host.invalid\n" > "$FX/lserr"; : > "$FX/lsfail"
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/lsfail" "${FX:?}/lserr"
[ $r = 1 ] && ! grep -q SECRET2 "$FX/o" "$OUTR/v0.1.0.ship-next.txt" && grep -qF "https://<redacted>@host.invalid/lukaso/sheepr/" "$OUTR/v0.1.0.ship-next.txt" \
  && pass "git's message naming a URL with a credential: kept in the cause without the credential" || fail "git's message: rc=$r $(grep -c SECRET2 "$FX/o" "$OUTR/v0.1.0.ship-next.txt" | tr '\n' ' ') $(head -1 "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | cut -c1-160)"
# a user name or password in origin's URL at github.com/lukaso/sheepr (an insteadOf rule adds one;
# a token as the user is one too), in the push URL or the fetch URL, https, ssh:// or scp form: refused
# before any push as what it is, the URL shown with <redacted> in the userinfo's place; never the
# bare accepted spelling as "not lukaso/sheepr"; no part of the token in stdout, stderr or the next file
for cu in 'pushurl https://lukaso:ghp_FAKE0r9a@github.com/lukaso/sheepr.git https://<redacted>@github.com/lukaso/sheepr.git' \
  'fetchurl https://ghp_FAKE1r9b@github.com/lukaso/sheepr.git https://<redacted>@github.com/lukaso/sheepr.git' \
  'pushurl ssh://git:FAKE2r9c@github.com/lukaso/sheepr.git ssh://<redacted>@github.com/lukaso/sheepr.git' \
  'pushurl user:FAKE3r9d@github.com:lukaso/sheepr.git <redacted>@github.com:lukaso/sheepr.git'; do
  sw=${cu%% *}; cr=${cu#* }; url=${cr%% *}; shown=${cr#* }
  echo "$url" > "$FX/$sw"; pt_row "origin's $sw $shown" "holds a user name or password"; rm -f "${FX:?}/$sw"
  ! grep -q FAKE "$FX/o" "$OUTR/v0.1.0.ship-next.txt" && grep -qF "origin's URL $shown holds a user name or password" "$OUTR/v0.1.0.ship-next.txt" \
    && ! grep -q 'is not lukaso/sheepr' "$FX/o" "$OUTR/v0.1.0.ship-next.txt" && pass "  named as a user name or password, shown as $shown; no FAKE anywhere" \
    || fail "  $sw $url: $(grep -c FAKE "$FX/o" "$OUTR/v0.1.0.ship-next.txt" | tr '\n' ' ') $(head -1 "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | cut -c1-200)"
done
# userinfo runs to the last @ of the authority (a password may hold an @): no part of it printed, in
# origin's URL at another host (still "is not lukaso/sheepr") or at an ssh alias in the scp form
for cu in 'https://u:SEC9x@RET9y@host.invalid/lukaso/sheepr.git https://<redacted>@host.invalid/lukaso/sheepr.git is not lukaso/sheepr' \
  'user:SEC9z@RET9w@gh-alias:lukaso/sheepr.git <redacted>@gh-alias:lukaso/sheepr.git names an ssh host alias'; do
  url=${cu%% *}; want=${cu#* }
  echo "$url" > "$FX/pushurl"; pt_row "origin's URL $url" "$want"; rm -f "${FX:?}/pushurl"
  ! grep -q -e SEC9 -e RET9 "$FX/o" "$OUTR/v0.1.0.ship-next.txt" && grep -qF "origin's URL $want" "$OUTR/v0.1.0.ship-next.txt" \
    && pass "  no part of the userinfo printed; '$want'" || fail "  $url: $(grep -c -e SEC9 -e RET9 "$FX/o" "$OUTR/v0.1.0.ship-next.txt" | tr '\n' ' ') $(head -1 "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | cut -c1-200)"
done
# a password with an @ in it at github.com (https and ssh://): the userinfo runs to the last @, so the
# rest is lukaso/sheepr on github.com and the URL is named as holding a user name or password; and a
# token as the scp form's user at an ssh alias, or at another host: each text shows <redacted>, never
# the token (the scp rule of redact alone would not catch a user with no colon)
for cu in 'https://u:SEC10a@RET10a@github.com/lukaso/sheepr.git|https://<redacted>@github.com/lukaso/sheepr.git holds a user name or password' \
  'ssh://u:SEC10b@RET10b@github.com/lukaso/sheepr.git|ssh://<redacted>@github.com/lukaso/sheepr.git holds a user name or password' \
  'ghp_FAKE10c@gh-alias:lukaso/sheepr.git|<redacted>@gh-alias:lukaso/sheepr.git names an ssh host alias' \
  'ghp_FAKE10d@host.invalid:other/sheepr.git|<redacted>@host.invalid:other/sheepr.git is not lukaso/sheepr'; do
  url=${cu%%|*}; want=${cu#*|}
  echo "$url" > "$FX/pushurl"; pt_row "origin's URL $url" "${want#* }"; rm -f "${FX:?}/pushurl"
  ! grep -q -e SEC10 -e RET10 -e FAKE10 "$FX/o" "$OUTR/v0.1.0.ship-next.txt" && grep -qF "origin's URL $want" "$OUTR/v0.1.0.ship-next.txt" \
    && pass "  '$want'; no part of the userinfo printed" \
    || fail "  $url: $(grep -c -e SEC10 -e RET10 -e FAKE10 "$FX/o" "$OUTR/v0.1.0.ship-next.txt" | tr '\n' ' ') $(head -1 "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | cut -c1-200)"
done
# a tool's message naming such a URL (git's, at the ls-remote): the same, in the URL form and the scp form
for le in "fatal: unable to access 'https://u:SEC5x@RET5y@host.invalid/lukaso/sheepr/': Could not resolve host: host.invalid|https://<redacted>@host.invalid/lukaso/sheepr/" \
  "user:SEC6x@RET6y@github.com: Permission denied (publickey).
fatal: Could not read from remote repository.|<redacted>@github.com: Permission denied"; do
  printf '%s\n' "${le%|*}" > "$FX/lserr"; : > "$FX/lsfail"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/lsfail" "${FX:?}/lserr"
  [ $r = 1 ] && ! grep -q -e SEC5 -e RET5 -e SEC6 -e RET6 "$FX/o" "$OUTR/v0.1.0.ship-next.txt" && grep -qF "${le#*|}" "$OUTR/v0.1.0.ship-next.txt" \
    && pass "git's message naming '${le#*|}': no part of the userinfo printed, <redacted> in its place" \
    || fail "git's message ${le#*|}: rc=$r $(grep -c -e SEC5 -e RET5 -e SEC6 -e RET6 "$FX/o" "$OUTR/v0.1.0.ship-next.txt" | tr '\n' ' ') $(head -1 "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | cut -c1-200)"
done
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
# every remote argument is resolved (a URL in scp form with no user, a named remote other than
# origin with an ssh URL) and only file:// goes on; git's ssh is a recorder here, so a remote that
# got through is seen without any network; the control: a named remote with a file:// URL is taken
printf '#!/bin/sh\necho "SSH REACHED $*" >> "%s/calls"\nexit 1\n' "$FX" > "$FX/sshrec"; chmod +x "$FX/sshrec"
g remote add other ssh://host.invalid/x.git && g remote add otherfile "file://$FX/origin.git" || exit 3
sgrow() { # label args...: refused, and git's ssh never reached
  l=$1; shift; rm -f "$FX/calls"
  env -i PATH="$B:/usr/bin:/bin" HOME="$FX/ghome" GIT_SSH_COMMAND="$FX/sshrec" "$S/sgit" "$@" > /dev/null 2>&1; r=$?
  [ $r != 0 ] && grep -q '^SGIT REFUSED' "$FX/calls" && ! grep -q '^SSH REACHED' "$FX/calls" && pass "the stand-in git refuses $l, before git runs" \
    || fail "sgit and $l: rc=$r $(grep -e REFUSED -e REACHED "$FX/calls" | tr '\n' '|')"
}
sgrow "an scp-form URL with no user (ls-remote)" ls-remote host.invalid:x/y
sgrow "an scp-form URL with no user (push)" -C "$REPO" push host.invalid:x/y "$C:refs/heads/main"
sgrow "a named remote with an ssh URL (ls-remote)" -C "$REPO" ls-remote other
sgrow "a named remote with an ssh URL (fetch)" -C "$REPO" fetch -q other main
rm -f "$FX/calls"; env -i PATH="$B:/usr/bin:/bin" HOME="$FX/ghome" GIT_SSH_COMMAND="$FX/sshrec" "$S/sgit" -C "$REPO" ls-remote otherfile > /dev/null 2>&1; r=$?
[ $r = 0 ] && ! grep -q -e '^SGIT REFUSED' -e '^SSH REACHED' "$FX/calls" && pass "control: the stand-in git takes a named remote whose URL is file://" || fail "control: sgit and a file:// named remote: rc=$r $(tr '\n' '|' < "$FX/calls")"
g remote remove other; g remote remove otherfile

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
# a token line (the count 1): only npm's E401 (an expired token) makes the fix `npm config delete`;
# any other whoami failure cannot tell whether that session is live (deleting the line would leave a
# live token on npm's server); and a count that cannot be read names no delete either
# REV 11 rule 3: the npm credential commands ship prints, for its F ($FX/npmrc here), and rule 4's words
LGF="cd / && npm logout --registry=https://registry.npmjs.org/ --scope= --userconfig='$FX/npmrc'"
DLF="cd / && npm config delete //registry.npmjs.org/:_authToken --location=user --userconfig='$FX/npmrc'"
A6R4="For a token, npm logout asks npm's server to end it, and npm's docs say that invalidates it everywhere it is used; an _auth line (a user name and password) is not ended by npm logout."
lgline() { grep -oE "cd / && npm logout --registry=https://registry.npmjs.org/( --scope=)?( --userconfig='[^']*')?" "$1" | head -1; }   # FILE: its printed logout step
dlline() { grep -oE "cd / && npm config delete //registry.npmjs.org/:_authToken( --location=user)?( --userconfig='[^']*')?" "$1" | head -1; }   # FILE: its printed delete
# a6ok FILE: A6's printed logout step is a line of its own (REV 11a rule 6), after a line that ends
# "Run this logout:", and the line after it starts with rule 4's words
a6ok() {
  b_=$(awk -v l="  $LGF" '$0 == l { n_ = ""; getline n_; print p_; print l; print n_; exit } { p_ = $0 }' "$1")
  case $b_ in *"Run this logout:
  $LGF
$A6R4 "*) return 0 ;; esac; return 1
}
A6NF=$OUTR/v0.1.0.ship-next.txt
# rvfirst FILE: FILE names how each live token ends (PLAN-ship.md REV 9, rule 1: "deleting or editing a
# login line ends no token"; a session's 2-hour end; Access Tokens for an access token) before anything
# in it names npm config delete or removing a line: whatever ship counted, a line removed from disk ends
# no token
rvfirst() {
  t_=$(tr '\n' ' ' < "$1" 2>/dev/null); case $t_ in *'ends no token'*) ;; *) return 1 ;; esac
  b_=${t_%%ends no token*}; a_=${t_#*ends no token}
  case $a_ in *'2 hours after that login'*) ;; *) return 1 ;; esac
  case $a_ in *'Access Tokens'*) ;; *) return 1 ;; esac
  case $b_ in *'config delete'*|*'remove it'*|*'remove its'*|*'remove that'*|*'remove those'*|*'remove the '*|*'remove them'*) return 1 ;; esac
}
# the class (PLAN-ship.md REV 11 rule 3; REV 10 rule 2): every npm command release.sh and notify.sh
# print comes from the one helper, npmcmd: no step word (run, Run, Next:, try, with, then) and no step
# line ("  ...") is followed by a literal npm command, with or without an argument, and `cd / && npm`
# appears nowhere else; the helper's three lines are exactly rule 3's, the file through dq (a path
# holding a space and a '). No config fix/set/rename/edit; removals conditional; no logout claim
src_() { grep -v '^ *#' "$SR_ROOT/scripts/release.sh"; grep -v '^ *#' "$SR_ROOT/scripts/lib/notify.sh"; }
tok_() { src_ | grep -E 'userconfig|_authToken|login line|token|npmrc'; }   # the npm credential texts
sw_=$(src_ | grep -oE '(^|[^A-Za-z])(run|Run|Next:|try|with|then):? +(cd / && )?npm +[a-z]+|"  +(cd / && )?npm +[a-z]+' | sort | uniq -c | tr -s ' ' | tr '\n' '|')
cdn_=$(grep -v '^ *#' "$SR_ROOT/scripts/release.sh" | sed '/^npmcmd() {/,/^}/d' | cat - "$SR_ROOT/scripts/lib/notify.sh" | grep -v '^ *#' | grep -c 'cd / && npm')
fnx() { awk -v n="$1" 'index($0, n "() {") == 1 { f = 1; print; if ($0 ~ /\}[[:space:]]*(#.*)?$/) exit; next } f { print } f && /^\}/ { exit }' "$SR_ROOT/scripts/release.sh"; }
{ fnx dq; fnx npm_file; fnx npmcmd; } > "$FX/npmcmd.sh"
hf_=$(sh -c '. "$1"; NPM_CONFIG_USERCONFIG="/a b/c'"'"'d"; export NPM_CONFIG_USERCONFIG; npmcmd login; echo; npmcmd logout; echo; npmcmd delete' sh "$FX/npmcmd.sh" 2>&1)
hw_="cd / && npm login --registry=https://registry.npmjs.org/ --scope= --userconfig='/a b/c'\''d'
cd / && npm logout --registry=https://registry.npmjs.org/ --scope= --userconfig='/a b/c'\''d'
cd / && npm config delete //registry.npmjs.org/:_authToken --location=user --userconfig='/a b/c'\''d'"
fx_=$(tok_ | grep -iE 'config fix|config set|rename|edit (it|that|the line|those)' | grep -cv 'do not rename a line to that key')
rm_=$(tok_ | grep -E '(remove|delete) (it|its|that|those|them|the line|a line|a login line)' | grep -cv "only once that line's token has ended")
cl_=$(src_ | grep -ciE "npm logout (ends|ended|has ended|did not end|can end|will end)|logout[^.]* (has ended|ended it)|did not end")
ce_=$(src_ | grep -c 'an expired token')
[ -z "$sw_" ] && [ "$cdn_" = 0 ] && [ "$hf_" = "$hw_" ] && [ "$fx_" = 0 ] && [ "$rm_" = 0 ] && [ "$cl_" = 0 ] && [ "$ce_" = 0 ] \
  && pass "REV 11's class: every npm command printed comes from npmcmd (no step word or step line before a literal npm command; 'cd / && npm' only in it); its three lines are rule 3's; no config fix/set/rename/edit; removals conditional; no logout claim" \
  || fail "REV 11's class: step words before npm [$sw_]; 'cd / && npm' outside npmcmd $cdn_; npmcmd '$(printf '%s' "$hf_" | tr '\n' '|')'; fix/set/rename/edit $fx_; unconditional removals $rm_; logout claims $cl_; 'an expired token' $ce_"
# unconditional FILE: a removal in FILE that is not conditional on the line's token having ended, and
# not the delete of ship's own line after the end time (0: none)
unconditional() {
  tr '\n' ' ' < "$1" | sed -e "s/Remove a login line only once that line's token has ended[^)]*)//g" -e "s/Only after [^(]*(ship's own session's end), and only when no npm login ran since ship's, run this: *cd \/ \&\& npm config delete [^ ]*//g" \
    | grep -ciE '(remove|delete) (it|its|that|those|them|the line|a line|a login line)|config delete'
}
: > "$FX/expired"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/expired"
pre_row "an expired npm token (the count 1, whoami E401)" "Deleting or editing a login line ends no token"
rvfirst "$A6NF" && ! grep -q -e 'config delete' -e 'expired token' "$A6NF" && [ "$(unconditional "$A6NF")" = 0 ] && pass "  npm_tokens after npm's words; no delete, no 'expired' (ship cannot know the token's kind)" || fail "  the expired root line: $(head -1 "$A6NF" | cut -c1-200)"
grep -q 'E401' "$FX/o" && pass "  the reason named: npm's E401" || fail "  E401 row: $(lastline)"
[ "$(tail -1 "$A6NF")" = 'When the cause above is fixed, run ship again.' ] && pass "  class fix: its next file ends 'When the cause above is fixed, run ship again.'" || fail "  E401 class: '$(tail -1 "$A6NF")'"
: > "$FX/whoamibad2"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/whoamibad2"
pre_row "a token line, and whoami failing with ETIMEDOUT" "cannot tell whether an npm session exists"
! grep -q 'config delete' "$FX/o" && ! grep -q 'config delete' "$A6NF" && [ "$(tail -1 "$A6NF")" = 'When the cause above is fixed, run ship again.' ] && ! grep -qx 'Run ship again.' "$A6NF" \
  && pass "  no npm config delete (the session may be live), in stdout or the next file; when the cause is fixed, run ship again" || fail "  ETIMEDOUT with a token: $(grep 'config delete' "$FX/o" "$A6NF" | head -2 | tr '\n' '|') last: $(tail -1 "$A6NF")"
chmod 000 "$FX/npmrc"; rm -rf "${OUTR:?}"; ship; r=$?; chmod 644 "$FX/npmrc"; rm -f "$FX/npmrc"
pre_row "npm's userconfig unreadable (the count unreadable), whoami failing" "cannot count npm's login tokens"
! grep -q 'config delete' "$FX/o" && ! grep -q 'config delete' "$A6NF" && pass "  no npm config delete" || fail "  unreadable count: $(grep 'config delete' "$FX/o" "$A6NF" | head -2 | tr '\n' '|')"
: > "$FX/whoamibad"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/whoamibad"; pre_row "a whoami failure that is not ENEEDAUTH" "cannot tell whether an npm session"
# npm's project config (the .npmrc beside the nearest package.json above npm's cwd) wins over the
# userconfig; every npm call ship makes runs from /, where npm finds none. A project .npmrc above the
# checkout with an expired token, and a live counted line in the userconfig: npm never reads the
# project file (the live session is found), so no stop names npm config delete of the live line
printf '{}\n' > "$FX/package.json"; echo "//registry.npmjs.org/:_authToken=npm_expired" > "$FX/.npmrc"
echo "//registry.npmjs.org/:_authToken=npm_live" > "$FX/npmrc"; rm -f "${FX:?}/npmcwds"
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/package.json" "${FX:?}/.npmrc" "${FX:?}/npmrc"
pre_row "a project .npmrc with an expired token above the checkout, a live user token" "an npm session exists"
! grep -q 'config delete' "$FX/o" "$A6NF" && [ "$(sort -u "$FX/npmcwds" 2>/dev/null)" = / ] \
  && pass "  npm read no project file (every npm call ran from /); no npm config delete" || fail "  project config: cwds $(sort -u "$FX/npmcwds" 2>/dev/null | tr '\n' ' '), $(grep -c 'config delete' "$FX/o" "$A6NF" | tr '\n' ' ')"
# a stop's class comes only from ship's own checks (PLAN-ship.md, REV 8): a failed npm, gh or git
# call before the push ends "When the cause above is fixed, run ship again.", whatever it answered
# (never a bare "Run ship again.", which loops on a definite answer); the cause keeps the tool's own
# words, and a named remedy comes only for its own exact code (E401 on a counted token line: npm
# config delete; ERR_INVALID_AUTH: the npmrc auth line)
FIXL='When the cause above is fixed, run ship again.'
endsfix() { [ "$(tail -1 "$1")" = "$FIXL" ] && ! grep -qx 'Run ship again.' "$1"; }
a6row() { # label token-line(yes|no) whoami|owner code want-text
  [ "$2" = yes ] && echo "//registry.npmjs.org/:_authToken=npm_old" > "$FX/npmrc"; echo "$4" > "$FX/$3code"
  rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/$3code" "${FX:?}/npmrc"
  pre_row "$1" "$5"
  endsfix "$A6NF" && ! grep -q 'config delete' "$A6NF" && ! grep -q 'names no registry' "$A6NF" && grep -q "npm error code $4" "$A6NF" \
    && pass "  its next file keeps npm's words and ends '$FIXL'; no npm config delete, no auth-line text" || fail "  $1: last line '$(tail -1 "$A6NF")', $(grep -c -e 'config delete' -e 'names no registry' "$A6NF") remedy lines"
}
for c in E403 FETCH_ERROR E429 ETIMEDOUT; do
  a6row "a token line, whoami $c" yes whoami $c "cannot tell whether an npm session exists"
  a6row "a token line, npm owner ls $c" yes owner $c "cannot read the owners of"
done
echo "//registry.npmjs.org/:_authToken=npm_old" > "$FX/npmrc"; echo ENEEDAUTH > "$FX/whoamicode"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/whoamicode" "${FX:?}/npmrc"
pre_row "a token line, whoami ENEEDAUTH" "Deleting or editing a login line ends no token"
endsfix "$A6NF" && ! grep -q 'config delete' "$A6NF" && pass "  when the cause is fixed, run ship again; no npm config delete" || fail "  ENEEDAUTH with a token line: last '$(tail -1 "$A6NF")'"
echo E401 > "$FX/whoamicode"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/whoamicode"
pre_row "no token line ship counts, whoami E401" "Deleting or editing a login line ends no token"
endsfix "$A6NF" && ! grep -q 'config delete' "$A6NF" && pass "  when the cause is fixed, run ship again; no npm config delete" || fail "  E401 with no counted line: last '$(tail -1 "$A6NF")'"
rvfirst "$A6NF" && pass "  how each token ends named before removing the line" || fail "  E401 with no counted line: $(head -1 "$A6NF" | cut -c1-200)"
echo ERR_INVALID_AUTH > "$FX/ownercode"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/ownercode"
pre_row "npm owner ls answering ERR_INVALID_AUTH" "names ship's --registry (registry.npmjs.org), not the registry your config names"
endsfix "$A6NF" && pass "  when the cause is fixed, run ship again" || fail "  owner ls ERR_INVALID_AUTH: last line '$(tail -1 "$A6NF")'"
# ERR_INVALID_AUTH: REV 10 rule 5's fixed sentence (npm's message names ship's --registry, not the
# registry the config names: do not rename a line to that key unless its token is for it); no
# command (npm config fix overwrote lines; a rename sent a private token to registry.npmjs.org)
grep -q "do not rename a line to that key unless its token is for registry.npmjs.org" "$A6NF" && ! grep -q -e 'Write it as' -e 'run npm config fix' -e 'config fix' "$A6NF" \
  && pass "  REV 10's fixed sentence; no npm config fix, no rename" || fail "  ERR_INVALID_AUTH remedy: $(head -1 "$A6NF" | cut -c1-200)"
printf 'registry=https://npm.example.invalid/\n_authToken=npm_private\n' > "$FX/npmrc"; echo ERR_INVALID_AUTH > "$FX/ownercode"
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/ownercode" "${FX:?}/npmrc"
[ $r = 1 ] && nobuild && grep -q "names ship's --registry (registry.npmjs.org), not the registry your config names" "$A6NF" && ! grep -q -e 'Write it as' -e 'config fix' -e '//registry.npmjs.org/:_authToken' "$A6NF" && endsfix "$A6NF" \
  && pass "a private registry's top-level _authToken, ERR_INVALID_AUTH: REV 10's fixed sentence; no command, no registry.npmjs.org key named for it" \
  || fail "private registry, ERR_INVALID_AUTH: rc=$r $(head -1 "$A6NF" | cut -c1-240)"
# npm 11's own ERR_INVALID_AUTH words at owner ls (r12a np/invalid-auth-v11.err: a warning, the code, the
# key it names and "Please run npm config fix"): the next file keeps npm's words (the key, grepped
# with no =) and gives REV 10's fixed sentence, never a command of ship's own
printf '%s\n' 'npm warn Unknown user config "_authToken". This will stop working in the next major version of npm.' 'npm error code ERR_INVALID_AUTH' \
  'npm error Invalid auth configuration found: `_authToken` must be renamed to `//registry.npmjs.org/:_authToken` in user config' \
  'npm error Please run `npm config fix` to repair your configuration.`' > "$FX/ownererr"
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/ownererr"
[ $r = 1 ] && nobuild && grep -q 'npm error code ERR_INVALID_AUTH' "$A6NF" && grep -q '//registry.npmjs.org/:_authToken' "$A6NF" \
  && grep -q "do not rename a line to that key unless its token is for registry.npmjs.org" "$A6NF" && endsfix "$A6NF" \
  && pass "npm 11's ERR_INVALID_AUTH words: kept in the cause; REV 10's fixed sentence follows" || fail "npm 11 ERR_INVALID_AUTH: rc=$r $(head -1 "$A6NF" | cut -c1-240)"
# every npm command that reaches the registry answers E401, a counted token line in the userconfig:
# A4's views fail first, and the stop still names the remedy
echo "//registry.npmjs.org/:_authToken=npm_old" > "$FX/npmrc"
printf 'npm error code E401\nnpm error 401 Unauthorized - GET https://registry.npmjs.org/sheepr - stand-in\n' > "$FX/npmall"
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/npmall" "${FX:?}/npmrc"
pre_row "every npm command answering E401 (a counted token line; A4 first)" "cannot tell whether anything is public"
grep -q "Deleting or editing a login line ends no token" "$A6NF" && ! grep -q 'config delete' "$A6NF" && endsfix "$A6NF" && pass "  the next file: npm's words, then npm_tokens; no delete; when the cause is fixed, run ship again" \
  || fail "  every npm E401: $(grep -c 'config delete' "$A6NF") delete lines, last '$(tail -1 "$A6NF")'"
# every npm command answers ERR_INVALID_AUTH, npm's warning first (a top-level _authToken)
echo "_authToken=npm_old" > "$FX/npmrc"
printf 'npm warn Unknown user config "_authToken". This will stop working in the next major version of npm.\nnpm error code ERR_INVALID_AUTH\nnpm error Invalid auth configuration found: `_authToken` must be renamed to `//registry.npmjs.org/:_authToken` in user config\n' > "$FX/npmall"
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/npmall" "${FX:?}/npmrc"
pre_row "every npm command answering ERR_INVALID_AUTH" "cannot tell whether anything is public"
grep -q "do not rename a line to that key" "$A6NF" && ! grep -q 'config delete' "$A6NF" && endsfix "$A6NF" && pass "  the next file: REV 10's fixed sentence; when the cause is fixed, run ship again" \
  || fail "  every npm ERR_INVALID_AUTH: last '$(tail -1 "$A6NF")'"
# a cause keeps the tool's error lines: two long `npm warn` lines ahead of npm's error (more bytes
# than the cause's cut) leave `npm error code ETIMEDOUT` in the next file's cause (A4's first view);
# git's `warning:` lines ahead of its `fatal:` the same (A3's ls-remote). Controls: the error alone
WL='npm warn config a long stand-in warning npm could print ahead of its error, about a setting in an npmrc, line'
printf '%s 1\n%s 2\nnpm error code ETIMEDOUT\nnpm error network request to https://registry.npmjs.org/sheepr failed (stand-in)\n' "$WL" "$WL" > "$FX/npmall"
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/npmall"
[ $r = 1 ] && head -1 "$OUTR/v0.1.0.ship-next.txt" | grep -q 'npm error code ETIMEDOUT' && endsfix "$OUTR/v0.1.0.ship-next.txt" \
  && pass "two npm warnings ahead of npm's error: the next file's cause holds npm error code ETIMEDOUT" || fail "npm warnings first: rc=$r $(head -1 "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | cut -c1-260)"
printf 'npm error code ETIMEDOUT\nnpm error network request to https://registry.npmjs.org/sheepr failed (stand-in)\n' > "$FX/npmall"
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/npmall"
[ $r = 1 ] && head -1 "$OUTR/v0.1.0.ship-next.txt" | grep -q 'npm error code ETIMEDOUT' && endsfix "$OUTR/v0.1.0.ship-next.txt" \
  && pass "control: npm's error alone: the next file's cause holds npm error code ETIMEDOUT" || fail "control, npm's error alone: rc=$r $(head -1 "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | cut -c1-260)"
# the class: no cause in release.sh cuts a tool's stderr file with head; each goes through errcut
# (21 sites when this row was written: A3, A4, A5, A6, C4, the push, the fetch, the casks', npm's)
nh=$(grep -cE 'head -(c [0-9]+|1|n [0-9]+) "\$[A-Za-z_0-9]+/[A-Za-z_.]*err"' "$SR_ROOT/scripts/release.sh")
ne=$(grep -oE 'errcut "\$[A-Za-z_0-9]+/[A-Za-z_.]*err" [0-9]+' "$SR_ROOT/scripts/release.sh" | grep -c .)
[ "$nh" = 0 ] && [ "$ne" -ge 21 ] && pass "no stderr file cut with head in release.sh; $ne causes through errcut" || fail "stderr cuts: $nh with head, $ne through errcut"
GW='warning: a long stand-in warning git could print ahead of its error, about a redirect or a setting of the remote, line'
for nw in 3 0; do
  : > "$FX/lserr"; i=0; while [ $i -lt $nw ]; do i=$((i + 1)); printf '%s %s\n' "$GW" $i >> "$FX/lserr"; done
  printf "fatal: unable to access 'https://github.com/lukaso/sheepr/': Could not resolve host: github.com\n" >> "$FX/lserr"; : > "$FX/lsfail"
  rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/lsfail" "${FX:?}/lserr"
  [ $r = 1 ] && head -1 "$OUTR/v0.1.0.ship-next.txt" | grep -q "fatal: unable to access 'https://github.com/lukaso/sheepr/'" && endsfix "$OUTR/v0.1.0.ship-next.txt" \
    && pass "$( [ $nw = 0 ] && echo 'control: ')$nw git warnings ahead of its fatal: (ls-remote): the next file's cause holds it" || fail "$nw git warnings first: rc=$r $(head -1 "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | cut -c1-260)"
done
# gh at A4's release list: a definite answer (401) and a transient one (502), the same ending; the
# cause keeps gh's words
for ge in 'HTTP 401: Bad credentials (https://api.github.com/graphql)
Try authenticating with:  gh auth login' 'HTTP 502: Bad Gateway (https://api.github.com/repos/lukaso/sheepr/releases)'; do
  printf '%s\n' "$ge" > "$FX/relserr"; : > "$FX/relsfail"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/relsfail" "${FX:?}/relserr"
  g1=$(printf '%s' "$ge" | head -1 | cut -d'(' -f1)
  pre_row "gh at A4's release list: ${g1% }" "cannot tell whether anything is public"
  head -1 "$A6NF" | grep -q -F "$g1" && endsfix "$A6NF" && pass "  the cause keeps gh's words; when the cause is fixed, run ship again" || fail "  gh ${g1% }: $(head -1 "$A6NF" | cut -c1-120) last '$(tail -1 "$A6NF")'"
done
# git ls-remote failing: an auth failure and a timeout, the same ending
for le in "remote: Invalid username or password.
fatal: Authentication failed for 'https://github.com/lukaso/sheepr/'" "fatal: unable to access 'https://github.com/lukaso/sheepr/': Failed to connect to github.com port 443 after 75001 ms: Timed out"; do
  printf '%s\n' "$le" > "$FX/lserr"; : > "$FX/lsfail"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/lsfail" "${FX:?}/lserr"
  [ $r = 1 ] && head -1 "$A6NF" | grep -q 'fatal:' && endsfix "$A6NF" && pass "git ls-remote failing ($(printf '%s' "$le" | tail -1 | cut -c1-40)…): when the cause is fixed, run ship again" \
    || fail "git ls-remote failing: rc=$r $(head -1 "$A6NF" 2>/dev/null | cut -c1-100) last '$(tail -1 "$A6NF" 2>/dev/null)'"
done
# A6's pass (no token line, whoami ENEEDAUTH) holds for npm's coloured answer and for npm 9's
printf '\033[1mnpm\033[22m \033[31merror\033[39m \033[94mcode\033[39m ENEEDAUTH\n\033[1mnpm\033[22m \033[31merror\033[39m \033[94mneed auth\033[39m This command requires you to be logged in.\n' > "$FX/whoamierr"
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/whoamierr"
completed && pass "A6, whoami's ENEEDAUTH in npm's colours (no token line): passes, the run completes" || fail "coloured ENEEDAUTH: $(lastline)"
printf 'npm ERR! code ENEEDAUTH\nnpm ERR! need auth This command requires you to be logged in.\n' > "$FX/whoamierr"
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/whoamierr"
completed && pass "A6, npm 9's 'npm ERR! code ENEEDAUTH' (no token line): passes, the run completes" || fail "npm 9 ENEEDAUTH: $(lastline)"
# the operator's npmrc sets npm's heading (heading=xyz: `xyz error code ENEEDAUTH`): ship's npm pins
# it (the environment over the userconfig), so A6 reads ENEEDAUTH and passes a clean state. Control:
# the stand-in honours the npmrc line when the environment sets no heading, and the pin when it does
echo "heading=xyz" > "$FX/npmrc"
hx=$(env -i PATH=/usr/bin:/bin HOME="$FX/ghome" NPM_CONFIG_USERCONFIG="$FX/npmrc" "$S/npm" whoami 2>&1 >/dev/null); hn=$(env -i PATH=/usr/bin:/bin HOME="$FX/ghome" NPM_CONFIG_USERCONFIG="$FX/npmrc" npm_config_heading=npm "$S/npm" whoami 2>&1 >/dev/null)
[ "$hx" = "xyz error code ENEEDAUTH" ] && [ "$hn" = "npm error code ENEEDAUTH" ] && pass "control: the npm stand-in writes the npmrc's heading, and the environment's over it" || fail "control: the stand-in's heading: '$hx' '$hn'"
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/npmrc"
completed && pass "A6, an npmrc with heading=xyz (no token line): npm's heading pinned, the clean state passes, the run completes" || fail "npmrc heading=xyz: $(head -1 "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | cut -c1-200)"
# npm's E401 with a counted login line (an expired token) names its remedy, npm config delete, at A4's
# `time` and `dist-tags.latest` views and at C4's whoami after the login (each site's own npmhint)
for vf in time dist-tags.latest; do
  echo "//registry.npmjs.org/:_authToken=npm_old" > "$FX/npmrc"; echo E401 > "$FX/viewcode.$vf"
  rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/viewcode.$vf" "${FX:?}/npmrc"
  [ $r = 1 ] && nobuild && grep -q " $vf: npm error code E401" "$OUTR/v0.1.0.ship-next.txt" && grep -q "Deleting or editing a login line ends no token" "$OUTR/v0.1.0.ship-next.txt" && grep -q "Deleting or editing a login line ends no token" "$FX/o" \
    && ! grep -q 'config delete' "$OUTR/v0.1.0.ship-next.txt" && endsfix "$OUTR/v0.1.0.ship-next.txt" && pass "A4's $vf view answering E401 (a counted token line): stopped before the build; npm's words, then npm_tokens; no delete" \
    || fail "A4 $vf E401: rc=$r $(head -1 "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | cut -c1-240)"
done
echo E401 > "$FX/whoamipostlogin"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/whoamipostlogin" "${FX:?}/npmrc"
[ $r = 1 ] && grep -q 'npm whoami failed after the login (npm error code E401' "$OUTR/v0.1.0.ship-next.txt" && grep -q "Deleting or editing a login line ends no token" "$OUTR/v0.1.0.ship-next.txt" && [ "$(unconditional "$OUTR/v0.1.0.ship-next.txt")" = 0 ] \
  && ! grep -q '^npm publish' "$FX/calls" && pass "C4's whoami after the login answering E401: nothing published; npm's words, then npm_tokens; no unconditional removal" \
  || fail "C4 whoami E401: rc=$r $(head -1 "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | cut -c1-240)"
# npm's userconfig variable must be an absolute path (npm expands ~ and ${VAR} in it itself, and ship
# runs npm from /): any other value stops ship before any npm call, class fix. Control: an absolute one
for uv in 'NPM_CONFIG_USERCONFIG=~/npmrc' 'npm_config_userconfig=rel/npmrc'; do
  SETX=$uv; rm -rf "${OUTR:?}"; ship; r=$?; SETX=
  [ $r = 1 ] && nobuild && ! grep -q '^npm ' "$FX/calls" && grep -qF "${uv%%=*} is '${uv#*=}', not an absolute path" "$OUTR/v0.1.0.ship-next.txt" \
    && endsfix "$OUTR/v0.1.0.ship-next.txt" && pass "$uv: ship stops before any npm call (nothing built); the next file names it and ends '$FIXL'" \
    || fail "$uv: rc=$r $(head -1 "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | cut -c1-200)"
done
SETX="NPM_CONFIG_USERCONFIG=$FX/abs-npmrc"; rm -rf "${OUTR:?}"; ship; r=$?; SETX=
completed && pass "control: an absolute NPM_CONFIG_USERCONFIG: the run completes" || fail "control, absolute userconfig: rc=$r $(lastline)"
# REV 11a rule 8 (r14a F1, R2): an absolute userconfig variable holding a $ (npm, not the shell, expands
# ${VAR} in it, from the environment it runs in: ship's npm has none, the operator's shell may): refused
# before any npm call, the variable named; nothing made (no build, no lock left). Both spellings
mkdir -p "$FX/v" || exit 3
for uv in "NPM_CONFIG_USERCONFIG=$FX/v/\${SRFOO}rc" "npm_config_userconfig=$FX/v/\$SRFOO/rc"; do
  echo ETIMEDOUT > "$FX/logoutcode"; SETX=$uv; rm -rf "${OUTR:?}"; ship; r=$?; SETX=; rm -f "${FX:?}/logoutcode"
  [ $r = 1 ] && nobuild && ! grep -q '^npm ' "$FX/calls" && grep -qF "${uv%%=*} is '${uv#*=}': it holds a \$" "$FX/o" && [ ! -e "$OUTR/.ship.lock" ] \
    && [ "$(g worktree list | grep -c .)" = 1 ] && leakfree \
    && pass "REV 11a rule 8: ${uv%%=*} holding a \$: ship refuses before any npm call, the variable named; nothing made" \
    || fail "${uv%%=*} with a \$: rc=$r, $(grep -c '^npm ' "$FX/calls") npm calls; $(grep -m1 "${uv%%=*}" "$FX/o" | cut -c1-200)"
done
rm -rf "${FX:?}/v"
# npm's login lines for registry.npmjs.org count in any spelling (any spacing, any path under the
# host, _authToken, _auth, _password or username: npm reads each). The remedy names npm config delete
# //registry.npmjs.org/:_authToken only for exactly one such line that is the root _authToken line:
# beside a live root line, a later line with spaces (which npm uses) or a path-specific one (which
# wins for whoami) is the refused one, and the delete would remove both and leave the live token
# unrevoked: revoke on npmjs.com first, no delete command. (The one root line: the rows above.)
for nl in '//registry.npmjs.org/:_authToken = npm_old' '//registry.npmjs.org/-/:_authToken=npm_old'; do
  printf '//registry.npmjs.org/:_authToken=npm_live\n%s\n' "$nl" > "$FX/npmrc"; echo E401 > "$FX/whoamicode"
  rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/whoamicode" "${FX:?}/npmrc"
  [ $r = 1 ] && nobuild && ! grep -q 'config delete' "$FX/o" "$OUTR/v0.1.0.ship-next.txt" && grep -q 'Access Tokens' "$OUTR/v0.1.0.ship-next.txt" \
    && endsfix "$OUTR/v0.1.0.ship-next.txt" && pass "a live root line and '$nl', whoami E401: no npm config delete (stdout, the next file); revoke on npmjs.com first" \
    || fail "two lines, '$nl': rc=$r $(grep -c 'config delete' "$FX/o" "$OUTR/v0.1.0.ship-next.txt" | tr '\n' ' ') $(head -1 "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | cut -c1-200)"
done
# one line that is not the root one (path-specific), whoami E401: no delete either (it would not remove it)
echo '//registry.npmjs.org/-/:_authToken=npm_old' > "$FX/npmrc"; echo E401 > "$FX/whoamicode"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/whoamicode" "${FX:?}/npmrc"
[ $r = 1 ] && nobuild && ! grep -q 'config delete' "$FX/o" "$OUTR/v0.1.0.ship-next.txt" && grep -q 'Access Tokens' "$OUTR/v0.1.0.ship-next.txt" \
  && pass "one path-specific line, whoami E401: no npm config delete; revoke on npmjs.com first" || fail "one path-specific line: rc=$r $(head -1 "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | cut -c1-200)"
# A6's clean state needs no such line in any spelling: an empty token line with spaces (npm: ENEEDAUTH)
# is a line whoami does not use, not "no session"
echo '//registry.npmjs.org/:_authToken = ' > "$FX/npmrc"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/npmrc"
pre_row "an empty token line with spaces, whoami ENEEDAUTH" "Deleting or editing a login line ends no token"
# a spelling ship's count misses while npm reads it (a quoted key, key[]=) leaves "one root line" when
# two are there; whoami E401 (npm sent the later, expired one): the text names revoking on npmjs.com
# before the delete, which removes the live line too
for nl in "'//registry.npmjs.org/:_authToken'=npm_old" '//registry.npmjs.org/:_authToken[]=npm_old'; do
  printf '//registry.npmjs.org/:_authToken=npm_live\n%s\n' "$nl" > "$FX/npmrc"; echo E401 > "$FX/whoamicode"
  rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/whoamicode" "${FX:?}/npmrc"
  [ $r = 1 ] && nobuild && rvfirst "$OUTR/v0.1.0.ship-next.txt" && rvfirst "$FX/o" && endsfix "$OUTR/v0.1.0.ship-next.txt" \
    && pass "a live root line and $nl, whoami E401: how each token ends named before any delete (stdout, the next file)" \
    || fail "live root + $nl: rc=$r $(head -1 "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | cut -c1-240)"
done
# a line whoami does not send but views and uploads do (//registry.npmjs.org:_authToken, no slash):
# whoami ENEEDAUTH; the text says neither that npm does not use it nor a bare remove: revoke first
echo '//registry.npmjs.org:_authToken=npm_noslash' > "$FX/npmrc"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/npmrc"
[ $r = 1 ] && nobuild && ! grep -q 'npm does not use' "$FX/o" "$OUTR/v0.1.0.ship-next.txt" && rvfirst "$OUTR/v0.1.0.ship-next.txt" && endsfix "$OUTR/v0.1.0.ship-next.txt" \
  && pass "a no-slash token line, whoami ENEEDAUTH: no 'npm does not use'; how each token ends named before removing it" \
  || fail "no-slash line: rc=$r $(head -1 "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | cut -c1-240)"
# an _auth line: whoami answers (a session), and npm logout cannot remove it (ENEEDAUTH): the text names
# npm logout and, for a line still there after it, revoking on npmjs.com and removing the line. Its
# steps end the loop: the logout fails and leaves the line; removed (after the revoke), ship runs
echo '//registry.npmjs.org/:_auth=bHVrYXNjbzpwdw==' > "$FX/npmrc"; rm -rf "${OUTR:?}"; ship; r=$?
[ $r = 1 ] && nobuild && grep -q 'an npm session exists' "$OUTR/v0.1.0.ship-next.txt" && grep -qxF "  $LGF" "$OUTR/v0.1.0.ship-next.txt" \
  && grep -qF "$A6R4" "$OUTR/v0.1.0.ship-next.txt" && ! grep -q 'whatever its kind' "$OUTR/v0.1.0.ship-next.txt" && [ "$(unconditional "$OUTR/v0.1.0.ship-next.txt")" = 0 ] \
  && grep -q "an _auth line holds a user name and password, not a token" "$OUTR/v0.1.0.ship-next.txt" && ! grep -q 'username or _password' "$OUTR/v0.1.0.ship-next.txt" \
  && pass "an _auth line (whoami answers): the step 'cd / && npm logout --registry=https://registry.npmjs.org/'; no removal but once a line's token has ended" \
  || fail "_auth line: rc=$r $(head -1 "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | cut -c1-240)"
# its steps, as the text gives them (stepsdo: npm logout when the text names it; a line still there
# afterwards removed only when the text says to remove it), then ship again: the loop ends
stepsdo() { # next-file -> rc of the run after the steps
  # the printed logout step, as printed (npm: the stand-in; the shell has no NPM_CONFIG_USERCONFIG)
  st_=$(lgline "$1")
  [ -z "$st_" ] || (cd "$FX" && env -i PATH="$S:/usr/bin:/bin" HOME="$FX/ghome" sh -c "$st_" > /dev/null 2>&1)
  # an _auth line still there: removed only when the text says it holds no token
  if grep -q '^//registry.npmjs.org/:_auth=' "$FX/npmrc" 2>/dev/null && grep -q "an _auth line holds a user name and password, not a token" "$1"; then
    grep -v '^//registry.npmjs.org/:_auth=' "$FX/npmrc" > "$FX/npmrc.n"; mv "$FX/npmrc.n" "$FX/npmrc"
  fi
  rm -rf "${OUTR:?}"; ship
}
cp "$OUTR/v0.1.0.ship-next.txt" "$FX/steps.nf"; stepsdo "$FX/steps.nf"; r=$?
completed && pass "  its steps (the printed logout fails and leaves the line; the _auth line, which holds no token, removed): ship runs; the loop ends" \
  || fail "  the _auth line's steps: rc=$r, the line $(grep -c '^//registry.npmjs.org/:_auth=' "$FX/npmrc" 2>/dev/null) left; $(lastline)"
rm -f "${FX:?}/npmrc" "${FX:?}/steps.nf"
# r12a F2: an _authToken session at A6 (whoami answers) whose logout then fails with ETIMEDOUT: the text
# names the logout step and no removal that is not conditional; the step fails, the line stays, and
# the next run stops at A6 again (REV 10 rule 3: npm's words say why)
echo "//registry.npmjs.org/:_authToken=npm_old" > "$FX/npmrc"; rm -rf "${OUTR:?}"; ship; r=$?
[ $r = 1 ] && grep -q 'an npm session exists' "$OUTR/v0.1.0.ship-next.txt" && grep -qxF "  $LGF" "$OUTR/v0.1.0.ship-next.txt" && [ "$(unconditional "$OUTR/v0.1.0.ship-next.txt")" = 0 ] \
  && pass "an _authToken session at A6: the step 'cd / && npm logout --registry=https://registry.npmjs.org/'; no unconditional removal" || fail "session at A6: rc=$r $(head -1 "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | cut -c1-240)"
cp "$OUTR/v0.1.0.ship-next.txt" "$FX/steps.nf"; echo ETIMEDOUT > "$FX/logoutcode"; stepsdo "$FX/steps.nf"; r=$?; rm -f "${FX:?}/logoutcode"
[ $r = 1 ] && grep -q '^//registry.npmjs.org/:_authToken=npm_old' "$FX/npmrc" && grep -q 'an npm session exists' "$OUTR/v0.1.0.ship-next.txt" \
  && pass "  the printed logout failing (ETIMEDOUT): the line stays, and ship stops at A6 again" || fail "  ETIMEDOUT logout step: rc=$r $(lastline)"
rm -f "${FX:?}/npmrc" "${FX:?}/steps.nf"
# r12b F2: the printed logout line runs from / whatever the cwd: from a project dir whose .npmrc holds
# its own token, it ends ship's (the userconfig's) and leaves the project's. Control: run from /
mkdir -p "$FX/proj" || exit 3
for cw in "$FX/proj" /; do
  printf '{}\n' > "$FX/proj/package.json"; echo '//registry.npmjs.org/:_authToken=npm_project' > "$FX/proj/.npmrc"
  echo "//registry.npmjs.org/:_authToken=npm_old" > "$FX/npmrc"; rm -rf "${OUTR:?}"; ship; r=$?
  lg_=$(lgline "$OUTR/v0.1.0.ship-next.txt")
  [ -n "$lg_" ] && (cd "$cw" && env -i PATH="$S:/usr/bin:/bin" HOME="$FX/ghome" sh -c "$lg_" > /dev/null 2>&1)
  [ -n "$lg_" ] && ! grep -q '^//registry.npmjs.org/:_authToken=' "$FX/npmrc" && grep -q 'npm_project' "$FX/proj/.npmrc" && ! grep -q 'LOGOUT ended the project token' "$FX/calls" \
    && pass "$( [ "$cw" = / ] && echo 'control: ')the printed logout line, run from $cw: it ended ship's line, the project's line kept" \
    || fail "logout line from $cw: '$lg_' ship's line $(grep -c '_authToken=' "$FX/npmrc" 2>/dev/null) project's $(grep -c 'npm_project' "$FX/proj/.npmrc")"
done
rm -rf "${FX:?}/proj"; rm -f "${FX:?}/npmrc"
# a username and _password pair (whoami answers): npm logout removes it (F7: the text never says it
# cannot); its steps end the loop with the logout alone
printf '//registry.npmjs.org/:username=lukasco\n//registry.npmjs.org/:_password=cHc=\n' > "$FX/npmrc"; rm -rf "${OUTR:?}"; ship; r=$?
[ $r = 1 ] && nobuild && grep -q 'an npm session exists' "$OUTR/v0.1.0.ship-next.txt" && ! grep -q -e 'username or _password' -e 'cannot remove a username' "$OUTR/v0.1.0.ship-next.txt" \
  && pass "a username and _password session: npm logout named; no text says npm logout cannot remove that pair" \
  || fail "username/_password: rc=$r $(head -1 "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | cut -c1-240)"
cp "$OUTR/v0.1.0.ship-next.txt" "$FX/steps.nf"; stepsdo "$FX/steps.nf"; r=$?
completed && pass "  its steps (npm logout removes the pair): ship runs" || fail "  username/_password steps: rc=$r $(lastline)"
rm -f "${FX:?}/npmrc" "${FX:?}/steps.nf"
# a ${VAR} line (whoami E401: ship's npm gets no variable, so npm sends the text itself): the line cannot
# work under ship: remove it; no revoke, no "expired". (A literal expired token keeps its text: above)
echo '//registry.npmjs.org/:_authToken=${NPM_TOKEN}' > "$FX/npmrc"; : > "$FX/expired"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/expired" "${FX:?}/npmrc"
[ $r = 1 ] && nobuild && grep -q 'holds no token in the file, and ship runs npm with no environment variables' "$OUTR/v0.1.0.ship-next.txt" && [ "$(unconditional "$OUTR/v0.1.0.ship-next.txt")" = 0 ] \
  && ! grep -q -i 'expired' "$OUTR/v0.1.0.ship-next.txt" && pass "a \${NPM_TOKEN} line, whoami E401: npm_tokens names the \${VAR} fact; no unconditional removal, no 'expired'" \
  || fail "\${NPM_TOKEN} line: rc=$r $(head -1 "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | cut -c1-240)"
# a coloured E401 with a counted line: the remedy named
echo "//registry.npmjs.org/:_authToken=npm_old" > "$FX/npmrc"; echo E401 > "$FX/whoamiansi"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/whoamiansi" "${FX:?}/npmrc"
pre_row "a counted token line, whoami's E401 in npm's colours" "Deleting or editing a login line ends no token"
# A7: the build's preconditions
: > "$FX/nodocker"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/nodocker"; pre_row "Docker does not answer" "Docker"
: > "$FX/nobase"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/nobase"; pre_row "the pinned base image missing" "no local image rust:"
# r12b F8: the step names the checkout's test-all by its full path (single-quoted: dq), so it runs as
# printed from any directory (test-all cds to its own directory)
grep -qF "(run '$REPO/test-all' pull)" "$OUTR/v0.1.0.ship-next.txt" && pass "  the step: the checkout's test-all by its full path" || fail "  test-all step: $(grep -o '(run [^)]*)' "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null)"
: > "$FX/noamd64"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/noamd64"; pre_row "the amd64 image missing" "no local amd64 image"
grep -qF "(run '$REPO/test-all' pull, or '$REPO/test-all' amd64)" "$OUTR/v0.1.0.ship-next.txt" && pass "  the step: the checkout's test-all by its full path" || fail "  test-all step: $(grep -o '(run [^)]*)' "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null)"
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
! grep -q '^npm logout' "$FX/calls" && [ "$(grep -c "^notify failed-build v0.1.0 $OUTR\$" "$FX/calls")" = 1 ] && pass "  no logout (no login was tried); one notification, failed-build" || fail "  build failure: logouts $(grep -c '^npm logout' "$FX/calls"), notifications $(grep '^notify' "$FX/calls" | tr '\n' ' ')"
! grep -q '^npmcheck' "$FX/calls" && pass "  and no npm-check" || fail "  npm-check ran"
rm -rf "${OUTR:?}"; echo 0000000000000000000000000000000000000000 > "$FX/build.other"; ship; r=$?; rm -f "$FX/build.other"; c_row "the build makes another commit's build" "holds no signed build of v0.1.0"
! grep -q '^npmcheck' "$FX/calls" && pass "  and no npm-check (post_build_check first)" || fail "  npm-check ran"
rm -rf "${OUTR:?}"; : > "$FX/npmcheckfail"; ship; r=$?; rm -f "$FX/npmcheckfail"; c_row "npm-check refuses" "npm-check refused"
rm -rf "${OUTR:?}"; VERIFIED=-; ship; r=$?; VERIFIED=; c_row "verify judges no archive" "the checks before publishing refused"
[ "$(taps)" = 1 ] && ! grep -q 'verify has not judged' "$FX/o" && pass "  and publish_check does not run (verify && publish_check)" || fail "  publish_check ran: taps=$(taps) $(grep -c 'verify has not judged' "$FX/o")"
rm -rf "${OUTR:?}"; VERIFIED=0000000000000000000000000000000000000000000000000000000000000000; ship; r=$?; VERIFIED=; c_row "verify judged another archive" "verify judged"
rm -rf "${OUTR:?}"; : > "$FX/npmcheck.swap"; ship; r=$?; rm -f "$FX/npmcheck.swap"; c_row "the manifest changed after the build's checks (npm-check stamped the changed one)" "not the one ship checked"
# C1's hash unreadable (shasum fails, for release.sh's own call on the build's manifest only): an
# empty hash would bind nothing, so it is refused, and nothing is pushed
cat > "$B/shasum" <<EOF
#!/bin/sh
for a; do [ "\$a" = "$OUTR/v0.1.0/MANIFEST.json" ] && [ "\$HOME" = "$FX/ghome" ] && exit 1; done
exec /usr/bin/shasum "\$@"
EOF
chmod +x "$B/shasum"
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$B/shasum"; c_row "C1's hash of the build's manifest unreadable" "cannot read the hash of $OUTR/v0.1.0/MANIFEST.json"
! grep -q -e '^npmcheck' -e '^npm publish' "$FX/calls" && pass "  and no npm-check, no upload" || fail "  after an unreadable hash: $(grep -e '^npmcheck' -e '^npm publish' "$FX/calls" | head -2 | tr '\n' ' ')"
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
grep -q '^npm login --registry=https://registry.npmjs.org/ --scope=$' "$FX/calls" && pass "the login names the registry, and no scope (REV 11 rule 2)" || fail "the login: $(grep '^npm login' "$FX/calls")"
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
[ $r = 1 ] && grep -q 'npm login failed' "$FX/o" && nopub && endsfix "$OUTR/v0.1.0.ship-next.txt" && [ "$(grep -c '^npm logout' "$FX/calls")" = 1 ] && pass "a failing login: stopped, nothing public, one logout (logged in from the attempt on); when the cause is fixed, run ship again" || fail "login fails: rc=$r logouts $(grep -c '^npm logout' "$FX/calls") $(lastline)"
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
# git's reason for each refused ref (its porcelain `!` line, on stdout under --porcelain) is in the
# cause the next file names
grep -q 'pre-receive hook declined' "$OUTR/v0.1.0.ship-next.txt" && pass "  and the next file names git's reason (pre-receive hook declined)" \
  || fail "  the next file has no git reason: $(head -1 "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null)"
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
gone() { # the worktree and the lock of the last run are gone, and every dir it made is named and gone
  [ "$(g worktree list | grep -c .)" = 1 ] && [ ! -e "$OUTR/.ship.lock" ] && leakfree
}
# a success: one logout, then done (the count 0); no next file (an earlier one removed)
rm -rf "${OUTR:?}"; mkdir -p "$OUTR"; echo EARLIER > "$NF"; ship; r=$?
completed && [ "$(grep -c '^npm logout' "$FX/calls")" = 1 ] && [ "$(nots)" = "npm-login npm-approve npm-approve-again done " ] && [ "$(ln_ '^npm logout')" -lt "$(ln_ '^notify done')" ] && [ ! -e "$NF" ] && gone \
  && pass "a success: one logout, then 'done' (the last notification); an earlier next file removed; everything removed" || fail "success: rc=$r nots '$(nots)' next $(ls "$NF" 2>/dev/null) $(lastline)"
grep -q "^caffeinate -i -w $(sed -n 's/^run \([0-9]*\) .*/\1/p' "$OUTR/.v0.1.0.ship-progress")\$" "$FX/calls" && [ "$(grep -c '^caffeinate' "$FX/calls")" = 1 ] \
  && pass "caffeinate once: -i -w ship's pid" || fail "caffeinate: $(grep caffeinate "$FX/calls" | tr '\n' ' ') pid $(head -1 "$OUTR/.v0.1.0.ship-progress")"
# a success whose logout leaves the token: no done, one logout-failed, exit 1; the text: npm logout
# again until it ends with no error or answers E401, the line left as it is, and the clock time ship's
# session ends by itself (REV 9 rule 2)
hm() { sed -E 's/[0-9]{2}:[0-9]{2} [A-Za-z0-9+-]+ on [0-9]{4}-[0-9]{2}-[0-9]{2}/HH:MM ZONE on DATE/g'; }   # the session's clock time and its zone, normalized
hasblk() { # FILE TEXT: FILE (its clock times normalized) holds TEXT's lines, whole and in a row
  f_=$(printf '\001'; hm < "$1" | tr '\n' '\001'); b_=$(printf '\001%s\001' "$2" | tr '\n' '\001')
  case $f_ in *"$b_"*) return 0 ;; esac; return 1
}
# (REV 11a rule 6: each command a line of its own, nothing after it)
PL_TEXT="ship ran npm login in this run, and runs this logout as it ends:
  $LGF
Unless a line below says that ship's line is no longer in npm's userconfig, run that logout until it ends with no error. ship's session ends by itself at HH:MM ZONE on DATE (2 hours after its login). Only after HH:MM ZONE on DATE (ship's own session's end), and only when no npm login ran since ship's, run this:
  $DLF"
LOGOUT_TEXT="ship's npm login line is still in npm's userconfig after npm logout. Deleting or editing a login line ends no token. A session from npm login ends by itself 2 hours after that login and is not on npmjs.com's Access Tokens list; an access token ends when you revoke it under Access Tokens on npmjs.com; a \${VAR} line holds no token in the file, and ship runs npm with no environment variables. npm logout asks npm's server to end the token npm sends for registry.npmjs.org, wherever that token is used, and removes its line only when the server accepted. Remove a login line only once that line's token has ended (an _auth line holds a user name and password, not a token). ship's session ends by itself at HH:MM ZONE on DATE (2 hours after its login). Run this logout again until it ends with no error:
  $LGF
Only after HH:MM ZONE on DATE (ship's own session's end), and only when no npm login ran since ship's, run this:
  $DLF"
: > "$FX/logoutstays"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/logoutstays"
[ $r = 1 ] && grep -q 'is public on GitHub, Homebrew and npm' "$FX/o" && [ "$(nots)" = "npm-login npm-approve npm-approve-again logout-failed " ] && hasblk "$FX/o" "release: $LOGOUT_TEXT" \
  && [ "$(head -1 "$NF" 2>/dev/null)" = "release: ship v0.1.0 is public on GitHub, Homebrew and npm; ship's npm session is left:" ] && [ "$(sed 1d "$NF" | hm)" = "$LOGOUT_TEXT" ] && [ "$(grep -c . "$NF")" = 5 ] && gone \
  && pass "a success whose logout leaves the token: exit 1, one logout-failed (no done); npm logout again, the line left, the session's own end; the next file keeps that step" || fail "success, logout fails: rc=$r '$(nots)' next: $(head -2 "$NF" 2>/dev/null | cut -c1-120 | tr '\n' '|') $(lastline)"
# a failure after the login: one logout, one failed-PHASE; with the token left, one notification naming both
: > "$FX/pubfail.sheepr"; rm -rf "${OUTR:?}"; ship; r=$?
[ $r = 1 ] && [ "$(grep -c '^npm logout' "$FX/calls")" = 1 ] && [ "$(nots)" = "npm-login npm-approve npm-approve-again failed-npm-main " ] && gone \
  && pass "a failure after the login: one logout, one notification (failed-npm-main)" || fail "failure after login: rc=$r '$(nots)' $(lastline)"
! grep -q "after npm logout" "$NF" "$FX/o" && pass "  control: a logout that removes ship's line: no logout text" || fail "  pubfail alone: a logout text"
[ -z "$(sed -n '/^STOP$/,$p' "$FX/calls" | sed 1d | grep -v -e '^npm logout --registry=https://registry.npmjs.org/ --scope=$' -e '^notify ')" ] \
  && pass "  after the stop: no npm call but the logout (ship's key is read from F; the stop text reads nothing)" || fail "  calls after the stop: $(sed -n '/^STOP$/,$p' "$FX/calls" | sed 1d | tr '\n' ' ')"
: > "$FX/logoutfail"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/logoutfail" "$FX/pubfail.sheepr"
[ $r = 1 ] && [ "$(nots)" = "npm-login npm-approve npm-approve-again logout-failed-npm-main " ] && hasblk "$NF" "$LOGOUT_TEXT" && gone \
  && pass "a failure, and the logout leaves the token: one notification naming both; the next file holds the npm logout text" || fail "failure + logout fails: rc=$r '$(nots)' '$(grep "still in npm's userconfig after npm logout" "$NF" 2>/dev/null | hm)'"
# (X1) its order: the logout remedy comes before any `  npm login` line, in the next file and on
# stdout (following the steps in order must not replace ship's session before it ends)
ll=$(grep -n '^  cd / && npm login' "$NF" | head -1 | cut -d: -f1); lo=$(grep -n "ship's npm login line is still in npm's userconfig after npm logout" "$NF" | head -1 | cut -d: -f1)
llo=$(grep -n '^  cd / && npm login' "$FX/o" | head -1 | cut -d: -f1); loo=$(grep -nF 'cd / && npm logout --registry=https://registry.npmjs.org/' "$FX/o" | head -1 | cut -d: -f1)
[ -n "$ll" ] && [ -n "$lo" ] && [ "$lo" -lt "$ll" ] && [ -n "$llo" ] && [ -n "$loo" ] && [ "$loo" -lt "$llo" ] \
  && pass "  the logout remedy before the npm login line: in the next file (line $lo < $ll); on stdout, the logout step ($loo < $llo)" \
  || fail "  order: next file npm login at ${ll:-none}, logout text at ${lo:-none}; stdout ${llo:-none}, ${loo:-none}"
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

# the logout of ship's own session fails, with ETIMEDOUT or E401 (REV 10 rule 4; r12a F1: an E401 can come
# from another line's token, an older /-/user/ line in the global config or in a quoted userconfig
# spelling, while ship's session is live): the logout again; the clock time ship's session ends by
# itself; the delete of ship's own line only after that time, never before it
dlate() { # FILE: the delete is named only after the end time, with "after that time"
  t_=$(tr '\n' ' ' < "$1"); case $t_ in *'config delete'*) ;; *) return 0 ;; esac
  b_=${t_%%config delete*}; case $b_ in *'ends by itself'*'Only after '*"(ship's own session's end), and only when no npm login ran since ship's, run this:   cd / && npm "*) return 0 ;; *) return 1 ;; esac
}
for lc in ETIMEDOUT E401 E401q; do
  echo "${lc%q}" > "$FX/logoutcode"
  [ "$lc" = E401q ] && echo "'//registry.npmjs.org/-/user/:_authToken'=npm_older" > "$FX/npmrc"
  rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/logoutcode" "${FX:?}/npmrc"
  [ $r = 1 ] && [ "$(nots)" = "npm-login npm-approve npm-approve-again logout-failed " ] && grep -q "ship's npm login line is still in npm's userconfig after npm logout (npm logout: npm error code ${lc%q}" "$FX/o" \
    && [ "$(awk '/Run this logout again until it ends with no error:$/ { n_ = ""; getline n_; print n_; exit }' "$FX/o")" = "  $LGF" ] && grep -qE "ends by itself at [0-9]{2}:[0-9]{2}" "$FX/o" && dlate "$FX/o" && [ "$(unconditional "$FX/o")" = 0 ] \
    && ! grep -qiE "npm logout (ends|ended|can end)|did not end" "$FX/o" && grep -q "is not on npmjs.com's Access Tokens list" "$FX/o" \
    && pass "ship's logout failing with ${lc%q}$( [ $lc = E401q ] && echo ', an older quoted /-/user/ line'): the logout again, the session's own end, the delete only after it" \
    || fail "logout ${lc}: rc=$r '$(nots)' $(grep 'after npm logout' "$FX/o" | cut -c1-240)"
done
# a login line left after the logout that is not ship's own root _authToken key (here a path-specific
# one): not ship's line (REV 10 rule 4: ship's own key decides, never a count): done, no logout text
echo '//registry.npmjs.org/-/:_authToken=npm_pathline' > "$FX/logoutleaves"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/logoutleaves" "${FX:?}/npmrc"
completed && [ "$(nots)" = "npm-login npm-approve npm-approve-again done " ] && ! grep -q "after npm logout" "$FX/o" \
  && pass "a path-specific line left after the logout: not ship's own key; done, exit 0, no logout text" \
  || fail "line left after the logout: rc=$r '$(nots)' $(grep 'after npm logout' "$FX/o" | cut -c1-200)"
# ship_exit speaks only of the line ship's own login wrote (counted right after the login): an older
# line npm's login rewrites into a counted spelling (here a quoted path line, unquoted by the login) is
# not ship's: the run is done, and no text calls it ship's npm login
echo "'//registry.npmjs.org/-/:_authToken'=npm_older" > "$FX/npmrc"; : > "$FX/loginnormalizes"
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/loginnormalizes"
grep -q '^//registry.npmjs.org/-/:_authToken=npm_older' "$FX/npmrc" || fail "  the stand-in login did not rewrite the older line (the row would prove nothing)"
rm -f "${FX:?}/npmrc"
completed && [ "$(nots)" = "npm-login npm-approve npm-approve-again done " ] && ! grep -q "ship's npm login" "$FX/o" \
  && pass "an older line the login rewrote into a counted spelling: not ship's; done, exit 0, no text about ship's npm login" \
  || fail "older line after the login: rc=$r '$(nots)' $(grep "ship's npm login" "$FX/o" | cut -c1-200)"
# REV 10 rule 7 (r12a F7): the clock time ship's session ends names its zone. A date stand-in first in
# PATH: +%s answers $FX/epoch; with $FX/gnudate it answers as GNU's date does (--version answers; -r
# reads a FILE's time; -d @N); with $FX/datefail, -r and -d fail
cat > "$B/date" <<EOD
#!/bin/sh
if [ "\$1" = +%s ] && [ -s "$FX/epoch" ]; then cat "$FX/epoch"; exit 0; fi
if [ -e "$FX/datefail" ]; then case "\$1" in -r|-d) exit 1 ;; esac; fi
if [ -e "$FX/gnudate" ]; then
  case "\$1" in
    --version) echo 'date (GNU coreutils) 9.5'; exit 0 ;;
    -r) [ -e "\$2" ] || { echo "date: \$2: No such file or directory" >&2; exit 1; }; m_=\$(/usr/bin/stat -f %m "\$2"); shift 2; exec /bin/date -r "\$m_" "\$@" ;;
    -d) case "\$2" in @*) n_=\${2#@}; shift 2; exec /bin/date -r "\$n_" "\$@" ;; esac; exit 1 ;;
  esac
fi
exec /bin/date "\$@"
EOD
chmod +x "$B/date"
vienna() { TZ=Europe/Vienna /bin/date -j -f '%Y-%m-%d %H:%M' "$1" +%s; }   # 'YYYY-MM-DD HH:MM' in Vienna -> epoch
clk() { # epoch [TZ]: the clock time (its text up to "(2 hours") the logout text names for a login at epoch (logout ETIMEDOUT)
  echo "$1" > "$FX/epoch"; echo ETIMEDOUT > "$FX/logoutcode"
  rm -rf "${OUTR:?}"; SETX=${2+TZ=$2}; ship; r=$?; SETX=; rm -f "${FX:?}/logoutcode" "${FX:?}/epoch" "${FX:?}/npmrc"
  grep "after npm logout" "$FX/o" | grep -o 'ends by itself [^(]*(2 hours' | sort -u | tr '\n' '|'
}
d1_=$(clk "$(vienna '2026-10-25 00:30')" Europe/Vienna); d2_=$(clk "$(vienna '2026-10-25 01:30')" Europe/Vienna)
[ "$d1_" = "ends by itself at 02:30 CEST on 2026-10-25 (2 hours|" ] && [ "$d2_" = "ends by itself at 02:30 CET on 2026-10-25 (2 hours|" ] \
  && pass "the session's end names its zone: logins at 00:30 and 01:30 CEST on 2026-10-25 end at 02:30 CEST and at 02:30 CET" || fail "DST: '$d1_' '$d2_'"
d3_=$(clk "$(vienna '2026-10-17 14:00')" '')
[ "$d3_" = "ends by itself at 14:00 UTC on 2026-10-17 (2 hours|" ] && pass "  TZ= (empty): the zone named, UTC" || fail "  TZ=: '$d3_'"
# a file in ship's cwd named like the end's epoch number (mtime 2000-01-01), made at the login: under a
# GNU date, -r would read that file; the time stays the session's. Control: BSD's date, the same file
e4_=$(vienna '2026-10-17 12:00'); printf 'touch -t 200001010000 "%s/%s"\n' "$REPO" "$((e4_ + 7200))" > "$FX/onlogin"
for dk_ in gnudate bsd; do
  [ $dk_ = gnudate ] && : > "$FX/gnudate"
  d4_=$(clk "$e4_" Europe/Vienna); rm -f "${FX:?}/gnudate" "${REPO:?}/$((e4_ + 7200))"
  [ "$d4_" = "ends by itself at 14:00 CEST on 2026-10-17 (2 hours|" ] \
    && pass "  $( [ $dk_ = bsd ] && echo 'control: ')a file in ship's cwd named like the end's epoch number, $dk_: the session's own time" || fail "  epoch file ($dk_): '$d4_'"
done
rm -f "$FX/onlogin"
# a time ship cannot compute is left out, and the run goes on: -r and -d fail; +%s answers no number
: > "$FX/datefail"; d5_=$(clk "$(/bin/date +%s)"); rm -f "$FX/datefail"
[ "$d5_" = "ends by itself (2 hours|" ] && grep -q 'is public on GitHub, Homebrew and npm' "$FX/o" && pass "  date -r and -d fail: no time; the release goes on" || fail "  datefail: '$d5_' $(grep -m1 'stopped at' "$FX/o" | cut -c1-120)"
d6_=$(clk x)
[ "$d6_" = "ends by itself (2 hours|" ] && grep -q 'is public on GitHub, Homebrew and npm' "$FX/o" && pass "  date +%s answers no number: no time; the release goes on" || fail "  epoch x: '$d6_' $(grep -m1 -e 'stopped at' -e 'unbound' "$FX/o" | cut -c1-120)"
rm -f "$B/date"
# REV 10 rule 6 (r12a F8, F11): when ship logged in, its next file is written before its logout runs,
# with the logout step on lines 2-5, its command on line 3 (before any `npm login` line), and printed at once. A KILL to ship's
# group while the logout runs (the hook copies stdout first) leaves that step in the file and on stdout,
# after a stop (C8's upload refused: the text names npm login) and after a release done
cat > "$FX/killer" <<EOS
#!/bin/sh
lp=\$(cat "$OUTR/.ship.lock/pid" 2>/dev/null); pg=\$(/usr/bin/perl -e 'print getpgrp()')
[ -n "\$lp" ] && [ "\$pg" = "\$lp" ] || { echo "UNSAFE killer" >> "$FX/calls"; exit 0; }
cp "$FX/o" "$FX/o.atkill"; echo "SIG KILL at \$1" >> "$FX/calls"; kill -KILL 0
EOS
killclean() { # after a KILLed run: its lock and next file ($OUTR), the temp dirs its mktemp recorded, its frozen tree
  rm -rf "${OUTR:?}"
  sort -u "$FX/made" 2>/dev/null | while read -r d_; do case $d_ in /private/tmp/sr-*) [ ! -e "$d_" ] || rm -rf "${d_:?}" ;; esac; done
  g worktree prune; unnamed > /dev/null; [ -z "$(leftover)" ] && [ "$(g worktree list | grep -c .)" = 1 ] || fail "  the KILLed run's dirs: left $(leftover | tr '\n' ' ')"
}
LG='cd / && npm logout --registry=https://registry.npmjs.org/'
lnof() { grep -nF -e "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1; }   # FILE TEXT: the first line holding TEXT
for k_ in stop done; do
  [ $k_ = stop ] && : > "$FX/pubfail.sheepr"
  printf 'sh "%s/killer" logout\n' "$FX" > "$FX/onlogout"; rm -f "$FX/o.atkill"
  rm -rf "${OUTR:?}"; SETSID=1; ship; r=$?; SETSID=; rm -f "${FX:?}/onlogout" "${FX:?}/pubfail.sheepr"
  ll=$(grep -n '^  cd / && npm login' "$NF" 2>/dev/null | head -1 | cut -d: -f1); lg=$(lnof "$NF" "$LG")
  llo=$(grep -n '^  cd / && npm login' "$FX/o.atkill" 2>/dev/null | head -1 | cut -d: -f1); lgo=$(lnof "$FX/o.atkill" "$LG")
  if [ $k_ = stop ]; then
    h_='release: ship v0.1.0 stopped at npm-main'; ok_=no
    [ -n "$ll" ] && [ "${lg:-0}" = 3 ] && [ -n "$llo" ] && [ -n "$lgo" ] && [ "$lgo" -lt "$llo" ] && ok_=yes
  else
    h_="release: ship v0.1.0 is public on GitHub, Homebrew and npm; ship's npm session is left:"; ok_=no
    [ -z "$ll" ] && [ "${lg:-0}" = 3 ] && [ -n "$lgo" ] && ok_=yes
  fi
  grep -q '^SIG KILL at logout$' "$FX/calls" && ! grep -q UNSAFE "$FX/calls" && [ $ok_ = yes ] && grep -q "^$h_" "$NF" && grep -q "^$h_" "$FX/o.atkill" \
    && grep -q '_authToken=npm_dry$' "$FX/npmrc.after" && dlate "$NF" && [ "$(unconditional "$NF")" = 0 ] \
    && pass "r12a F8, F11: a KILL while ship's logout runs ($k_): the next file holds the logout step (line ${lg:-none}) before any npm login (${ll:-none}); stdout held it before the logout returned (${lgo:-none} < ${llo:-none})" \
    || fail "KILL in the logout ($k_): rc=$r $(grep -e '^SIG' -e UNSAFE "$FX/calls" | tr '\n' ' ') next file: logout ${lg:-none}, npm login ${ll:-none}; stdout: ${lgo:-none}, ${llo:-none}; $(head -2 "$NF" 2>/dev/null | cut -c1-150 | tr '\n' '|')"
  killclean
done
# a stop, and a logout that removes ship's line: the next file is the stop text alone (the step taken
# out); stdout named the step before the logout ran, then says that step is done. Its control, the
# same run's text with no login (a stop before C4), has no step. Then the class: no redirection opens
# the next file; every write is a temp file beside it, then a rename
: > "$FX/pubfail.sheepr"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/pubfail.sheepr"
DONE_L="release: ship's line is no longer in npm's userconfig after ship's own npm logout: the npm logout step above is done."
[ $r = 1 ] && ! grep -qF "$LG" "$NF" && grep -q '^release: ship v0.1.0 stopped at npm-main' "$NF" && [ "$(grep -c '^release:' "$NF")" = 1 ] \
  && [ "$(lnof "$FX/o" "$LG")" -lt "$(grep -n '^  cd / && npm login' "$FX/o" | head -1 | cut -d: -f1)" ] && [ "$(grep -n . "$FX/o" | grep -F "$DONE_L" | cut -d: -f1)" -gt "$(lnof "$FX/o" "$LG")" ] && gone \
  && pass "a stop and a logout that removes ship's line: the next file without the logout step; stdout named it before the logout, then that it is done" \
  || fail "stop + logout removes the line: rc=$r next file logout at $(lnof "$NF" "$LG"); stdout logout at $(lnof "$FX/o" "$LG"), done line at $(lnof "$FX/o" "$DONE_L")"
PFL=$(tail -1 "$NF"); PFN=$(grep -c . "$NF")
rm -rf "${OUTR:?}"; : > "$FX/build.nomanifest"; ship; r=$?; rm -f "$FX/build.nomanifest"
[ $r = 1 ] && ! grep -q 'npm logout' "$NF" "$FX/o" && pass "  control: a stop before the login: no logout step, in the file or on stdout" || fail "  no login: a logout step"
nfr_=$(grep -v '^ *#' "$SR_ROOT/scripts/release.sh" | grep -cE '>>? *"?\$nf"?([^.A-Za-z_]|$)'); nfm_=$(grep -v '^ *#' "$SR_ROOT/scripts/release.sh" | grep -cE 'mv -f "\$out/\.\$tag\.ship-next\.tmp" "\$nf"')
[ "$nfr_" = 0 ] && [ "$nfm_" = 1 ] && pass "the next file: no redirection opens it ($nfr_); one rename onto it, from the temp file beside it ($nfm_)" || fail "the next file: $nfr_ redirections open it; $nfm_ renames"
# the rewrite is a rename: a KILL at the mv onto the next file, after the logout ran, leaves the
# earlier text whole (the stop text with the logout step); the temp file beside it holds the new one
cat > "$B/mv" <<EOS
#!/bin/sh
for a_; do l_=\$a_; done
[ "\$l_" = "$NF" ] && [ -e "$FX/logout.ran" ] && sh "$FX/killer" mv
exec /bin/mv "\$@"
EOS
chmod +x "$B/mv"; printf ': > "%s/logout.ran"\n' "$FX" > "$FX/onlogout"; : > "$FX/pubfail.sheepr"; rm -f "$FX/logout.ran"
rm -rf "${OUTR:?}"; SETSID=1; ship; r=$?; SETSID=; rm -f "${FX:?}/onlogout" "${FX:?}/pubfail.sheepr" "${FX:?}/logout.ran" "${B:?}/mv"
grep -q '^SIG KILL at mv$' "$FX/calls" && ! grep -q UNSAFE "$FX/calls" && grep -q '^release: ship v0.1.0 stopped at npm-main' "$NF" && [ "$(lnof "$NF" "$LG")" = 3 ] \
  && [ "$(tail -1 "$NF")" = "$PFL" ] && [ "$(grep -c . "$NF")" = "$((PFN + 4))" ] && ! grep -qF "$LG" "$OUTR/.v0.1.0.ship-next.tmp" && [ "$(head -1 "$OUTR/.v0.1.0.ship-next.tmp")" = "$(head -1 "$NF")" ] \
  && pass "a KILL at the rename after the logout: the next file whole, as written before the logout ($PFN lines and the step); the new text in the temp file beside it" \
  || fail "KILL at the rewrite: rc=$r $(grep -e '^SIG' -e UNSAFE "$FX/calls" | tr '\n' ' ') next file: $(grep -c . "$NF" 2>/dev/null) lines, step at $(lnof "$NF" "$LG"), last '$(tail -1 "$NF" 2>/dev/null | cut -c1-80)'"
killclean
# r12b F6: the runnable lines name the checkout and the out dir in single quotes (' as '\''): a path
# holding ", $x, a backtick command, \, !x or !! (or ', or a space) runs as printed, from sh and from an
# interactive zsh (a paste: zsh -f -i reading it from stdin; in double quotes !x expands there). dq and
# the two line shapes are release.sh's own text; a stub release.sh at each path and a stub git first on
# PATH record the argv they get
W=$FX/dqw; rm -rf "${W:?}"; mkdir -p "$W/bin" || exit 3
awk '/^dq\(\) \{/ { f = 1; print; if ($0 ~ /\}[[:space:]]*(#.*)?$/) exit; next } f { print } f && /^\}/ { exit }' "$SR_ROOT/scripts/release.sh" > "$W/dq.sh"
grep -E '^ *run="  sh \$\(dq "\$oroot/scripts/release.sh"\)" o="--out \$\(dq "\$out"\) \$tag"$' "$SR_ROOT/scripts/release.sh" | head -1 > "$W/run.sh"
grep -oE 'echo "  git -C \$\(dq "\$oroot"\) ls-remote origin refs/tags/\$tag"' "$SR_ROOT/scripts/release.sh" | head -1 > "$W/git.sh"
[ -s "$W/dq.sh" ] && [ -s "$W/run.sh" ] && [ -s "$W/git.sh" ] || fail "dq: release.sh's dq or its line shapes not found (the row would prove nothing)"
printf '#!/bin/sh\n{ printf "git"; for a; do printf " [%%s]" "$a"; done; printf "\\n"; } >> "$REC"\n' > "$W/bin/git"; chmod +x "$W/bin/git"
dqrun() { # how line want -> 0 when the line, run that way from /, gave exactly want
  REC=$W/rec; : > "$REC"; export REC
  if [ "$1" = sh ]; then (cd / && PATH="$W/bin:/usr/bin:/bin" /bin/sh -c "$2") > "$W/o" 2>&1
  else (cd / && printf '%s\n' "$2" | PATH="$W/bin:/usr/bin:/bin" HOME="$W" /bin/zsh -f -i) > "$W/o" 2>&1; fi
  [ "$(cat "$REC")" = "$3" ]
}
bad_=""; n_=0
for nm_ in 'dq"q' 'dol$x' 'bt`echo X`' 'bs\x' 'bang!x' 'bang!!' "sq'q" 'sp ace'; do
  n_=$((n_ + 1)); oroot=$W/c$n_/$nm_/repo out=$W/c$n_/$nm_/out tag=v0.1.0
  mkdir -p "$oroot/scripts" "$out" || exit 3
  printf '#!/bin/sh\n{ printf "rs [%%s]" "$0"; for a; do printf " [%%s]" "$a"; done; printf "\\n"; } >> "$REC"\n' > "$oroot/scripts/release.sh"
  l1_=$(. "$W/dq.sh"; . "$W/run.sh"; printf '%s publish %s' "$run" "$o"); l2_=$(. "$W/dq.sh"; . "$W/git.sh")
  w1_="rs [$oroot/scripts/release.sh] [publish] [--out] [$out] [$tag]"; w2_="git [-C] [$oroot] [ls-remote] [origin] [refs/tags/$tag]"
  for how_ in sh zsh; do
    dqrun $how_ "$l1_" "$w1_" || bad_="$bad_ [$nm_ $how_ line 1: $(tr '\n' '|' < "$REC")]"
    dqrun $how_ "$l2_" "$w2_" || bad_="$bad_ [$nm_ $how_ line 2: $(tr '\n' '|' < "$REC")]"
  done
done
[ -z "$bad_" ] && pass "r12b F6: the runnable lines, for a checkout and an out dir holding \", \$x, a backtick command, \\, !x, !!, ' or a space, run as printed from sh and from an interactive zsh ($n_ paths)" \
  || fail "dq:$(printf '%s' "$bad_" | cut -c1-400)"
dqrun sh "  sh $oroot/scripts/release.sh publish --out $out $tag" "$w1_" && fail "  control: a line with the path unquoted ran as intended (the row would prove nothing)" \
  || pass "  control: the same line with the path unquoted is caught"
# REV 11 rule 5 (r13a F6): npm logout's error names the request's URL, /-/user/token/<the token it
# sends>; npm masks only its npm_ shape. ship's own session token, in another shape (a session from
# another registry's login, an older npm), is in no stdout, stderr or next-file line, whatever the code
# (E401, E503, a network timeout). Control: the npm_ shape
for k_ in E401 E503 ETIMEDOUT control; do
  if [ $k_ = control ]; then echo npm_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 > "$FX/logintoken"; echo E401 > "$FX/logoutmsg"; tk_=npm_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
  else echo "sessXk$k_-7f3a9c0e-1b2d-4e5f-8a9b-0c1d2e3f4a5b" > "$FX/logintoken"; echo $k_ > "$FX/logoutmsg"; tk_=$(cat "$FX/logintoken"); fi
  rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/logintoken" "${FX:?}/logoutmsg"
  [ $r = 1 ] && grep -q "still in npm's userconfig after npm logout" "$FX/o" && grep -q '/-/user/token/' "$FX/o" && ! grep -qF "$tk_" "$FX/o" && ! grep -qF "$tk_" "$NF" \
    && pass "$( [ $k_ = control ] && echo '  control (the npm_ shape, which npm masks): ' || echo "REV 11 rule 5: ")npm logout's error ($k_) naming /-/user/token/<ship's token>: the token in no stdout, stderr or next-file line" \
    || fail "logout error token ($k_): rc=$r stdout/stderr $(grep -cF "$tk_" "$FX/o") next file $(grep -cF "$tk_" "$NF" 2>/dev/null): $(grep -F "$tk_" "$FX/o" | head -1 | cut -c1-200)"
  rm -f "${FX:?}/npmrc"
done
# (r14a RR1) a token whose pieces are joined by . / + = and _ (another registry's shape; npm's URL may
# carry it so): no piece of it in stdout, stderr or the next file
echo 'sessXk.qzxv/wvyb+uktn=jpmr_rsqw' > "$FX/logintoken"; echo E401 > "$FX/logoutmsg"
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/logintoken" "${FX:?}/logoutmsg"
lk_=""; for pc_ in qzxv wvyb uktn jpmr rsqw; do ! grep -qF "$pc_" "$FX/o" && ! grep -qF "$pc_" "$NF" || lk_="$lk_ $pc_"; done
[ $r = 1 ] && grep -q '/-/user/token/<redacted>' "$FX/o" && [ -z "$lk_" ] \
  && pass "r14a RR1: a token joined by . / + = _ in npm logout's error: no piece of it in stdout, stderr or the next file" || fail "RR1: pieces left:$lk_; $(grep -F '/-/user/token/' "$FX/o" | head -1 | cut -c1-200)"
rm -f "${FX:?}/npmrc"
# (r13a F5) the logout step (pl) exactly, as ship prints it at once and puts it on the next file's
# lines 2-5 before the logout runs; a stop after the login, the logout removing ship's line
: > "$FX/pubfail.sheepr"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/pubfail.sheepr"
[ $r = 1 ] && hasblk "$FX/o" "$PL_TEXT" \
  && pass "r13a F5: the logout step's text, exactly (printed before the logout ran)" || fail "the logout step's text: '$(grep -m1 'ran npm login\|logged in to npm' "$FX/o" | hm | cut -c1-300)'"
# (r13a X2) F cannot be read after the logout (the logout's hook takes its read permission): ship
# cannot vouch that its line is gone: the remedy ("cannot tell"), logout-failed, exit 1, never done
printf 'chmod 000 "%s/npmrc"\n' "$FX" > "$FX/onlogout"; : > "$FX/logoutstays"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/onlogout" "${FX:?}/logoutstays"
chmod 600 "$FX/npmrc" 2>/dev/null
[ $r = 1 ] && [ "$(nots)" = "npm-login npm-approve npm-approve-again logout-failed " ] && grep -q "ship cannot tell whether its npm login line is still in npm's userconfig after npm logout (the userconfig cannot be read)" "$FX/o" \
  && ! grep -q "^release: ship's line is no longer in npm's userconfig after ship's own npm logout" "$FX/o" \
  && pass "r13a X2: F unreadable after the logout: 'cannot tell', the logout again, logout-failed, exit 1" \
  || fail "r13a X2: rc=$r '$(nots)' $(grep "userconfig" "$FX/o" | tail -1 | cut -c1-200)"
rm -f "${FX:?}/npmrc"
# (r13a X3) the login takes 10 minutes (a browser approval): the session's end is 2 hours after the
# login RETURNED. A date stand-in first in PATH answers +%s from $FX/epoch; the login's hook moves it on
cat > "$B/date" <<EOD
#!/bin/sh
if [ "\$1" = +%s ] && [ -s "$FX/epoch" ]; then cat "$FX/epoch"; exit 0; fi
exec /bin/date "\$@"
EOD
chmod +x "$B/date"
E_=$(/bin/date +%s); echo "$E_" > "$FX/epoch"; printf 'echo %s > "%s/epoch"\n' "$((E_ + 600))" "$FX" > "$FX/onlogin"
echo ETIMEDOUT > "$FX/logoutcode"; rm -rf "${OUTR:?}"; SETX=TZ=UTC; ship; r=$?; SETX=; rm -f "${FX:?}/logoutcode" "${FX:?}/onlogin" "${FX:?}/epoch" "${FX:?}/npmrc" "${B:?}/date"
w_=$(TZ=UTC /bin/date -r "$((E_ + 600 + 7200))" '+%H:%M %Z on %Y-%m-%d'); g_=$(grep "after npm logout" "$FX/o" | grep -o 'ends by itself at [^(]*' | head -1)
[ "$g_" = "ends by itself at $w_ " ] && pass "r13a X3: a login that takes 10 minutes: the end time is 2 hours after the login returned" \
  || fail "r13a X3: '$g_', want 'ends by itself at $w_' (2 hours after the login returned)"
# (r13a P4) the next file cannot be written (its temp file's name taken by a directory): no line says
# the steps are also in it; it says the file could not be written. A stop before the login (C2), and
# one after it (C8)
for k_ in C2 C8; do
  if [ $k_ = C2 ]; then : > "$FX/npmcheckfail"; printf 'mkdir -p "%s/.v0.1.0.ship-next.tmp"\n' "$OUTR" > "$FX/onbuild"
  else : > "$FX/pubfail.sheepr"; printf 'mkdir -p "%s/.v0.1.0.ship-next.tmp"\n' "$OUTR" > "$FX/onlogin"; fi
  rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/npmcheckfail" "${FX:?}/pubfail.sheepr" "${FX:?}/onbuild" "${FX:?}/onlogin"
  [ $r = 1 ] && [ ! -e "$NF" ] && grep -q '^release: ship v0.1.0 stopped at' "$FX/o" && ! grep -q 'these steps are also in' "$FX/o" && grep -qF "release: (the next file, $NF, could not be written: these steps are only here)" "$FX/o" \
    && pass "r13a P4: the next file not written ($k_): stdout says so, and never that the steps are also in it" || fail "next file not written ($k_): rc=$r $(grep -e 'these steps' -e 'could not be written' "$FX/o" | tr '\n' '|' | cut -c1-200)"
  # (r14b) and its notification names no file: notify.sh gets - for the out dir (the control: row "no
  # logout (no login was tried)", a written next file, gets $OUTR)
  [ "$(grep '^notify failed-' "$FX/calls" | sed 's/^notify [^ ]* v0\.1\.0 //')" = - ] \
    && pass "  r14b: its notification gets - for the out dir (it names no next file)" || fail "  r14b ($k_): the notification: $(grep '^notify failed-' "$FX/calls" | tr '\n' '|')"
  rm -rf "${OUTR:?}"
done
# --- REV 11, npm routing (r13a F1-F4): F is the userconfig npm loads; every npm call ship makes has
# --scope= (and --registry); every printed npm credential command names F
# rule 1 (r13a F2; REV 11a, r14a F5): npm's config get userconfig must name F. Real npm answers the file
# the environment or --userconfig names, even when it holds a userconfig= key (notes/r14a/np/t1 a, b):
# the key counts only in the HOME's .npmrc, with no variable; and it answers the path normalized (t1 d).
# A1 refuses before anything is made, naming both and both causes: no variable and a key in the dry
# HOME's .npmrc; F with a trailing space; F with a .. in it. Control: the variable set and F holding the
# key: the run completes
for k_ in homekey space dotdot; do
  case $k_ in
    homekey) NO=NPM_CONFIG_USERCONFIG; echo "$FX/other.npmrc" > "$FX/homekey"; w_=$FX/other.npmrc ;;
    space) SETX="NPM_CONFIG_USERCONFIG=$FX/npmrc "; w_=$FX/npmrc ;;
    dotdot) mkdir -p "$FX/x" || exit 3; SETX="NPM_CONFIG_USERCONFIG=$FX/x/../npmrc"; w_=$FX/npmrc ;;
  esac
  rm -rf "${OUTR:?}"; ship; r=$?; SETX=; NO=; rm -f "${FX:?}/homekey" "${FX:?}/npmrc"; rm -rf "${FX:?}/x"
  [ $r = 1 ] && grep -qF "npm names $w_ as its userconfig" "$FX/o" && grep -q 'a userconfig= key in' "$FX/o" && grep -q 'spelt in a way npm rewrites' "$FX/o" && grep -q 'stopped at preflight' "$NF" \
    && grep -q '^npm config get userconfig' "$FX/calls" && ! grep -q -e '^build ' -e '^npm login' -e '^npm logout' -e '^notify' "$FX/calls" && gone \
    && pass "REV 11 rule 1 (r14a F5): npm names another userconfig than F ($k_): A1 refuses, both named and both causes; nothing made" \
    || fail "A1 ($k_): rc=$r $(grep -m1 -e 'userconfig' "$FX/o" | cut -c1-240)"
done
printf 'userconfig=%s\n' "$FX/other.npmrc" > "$FX/npmrc"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/npmrc"
completed && ! grep -q 'as its userconfig' "$FX/o" && pass "  control: NPM_CONFIG_USERCONFIG names F and F holds a userconfig= key (npm answers F): the run completes" \
  || fail "  A1 control (the variable, a key in F): rc=$r $(grep -m1 'userconfig' "$FX/o" | cut -c1-200)"
# F by default (no variable: the dry HOME's .npmrc): A1 passes, and the run reaches the login (r14a R4;
# its MH, npm_file naming $HOME/npmrc, goes red here)
rm -rf "${OUTR:?}"; NO=NPM_CONFIG_USERCONFIG; ship; r=$?; NO=
grep -q '^npm config get userconfig' "$FX/calls" && grep -q '^npm login' "$FX/calls" && ! grep -q 'as its userconfig' "$FX/o" \
  && pass "  F by default (no variable: the HOME's .npmrc): A1 passes, the run reaches the login" || fail "  default F: rc=$r $(grep -m1 'userconfig' "$FX/o" | cut -c1-220)"
# (r13a X1) the key appears after A1 (here at C4's login); the logout fails (ETIMEDOUT) and leaves
# ship's line in F: ship reads F, so the remedy, logout-failed, exit 1. Control: no key
for k_ in key control; do
  [ $k_ = key ] && printf 'printf "userconfig=%%s\\n" "%s" >> "%s"\n' "$FX/other.npmrc" "$FX/npmrc" > "$FX/onlogin"
  echo ETIMEDOUT > "$FX/logoutcode"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/logoutcode" "${FX:?}/onlogin"
  [ $r = 1 ] && [ "$(nots)" = "npm-login npm-approve npm-approve-again logout-failed " ] && grep -q "ship's npm login line is still in npm's userconfig after npm logout" "$FX/o" \
    && grep -q '_authToken=npm_dry$' "$FX/npmrc.after" \
    && pass "$( [ $k_ = control ] && echo '  control: ')r13a X1$( [ $k_ = key ] && echo ', a userconfig= key written after A1'): a failed logout leaves ship's line in F: the remedy, logout-failed, exit 1" \
    || fail "r13a X1 ($k_): rc=$r '$(nots)' $(grep "userconfig after" "$FX/o" | tail -1 | cut -c1-160)"
  rm -f "${FX:?}/npmrc"
done
# rule 2 (r13a F1): npm's scope setting routes logout, view, owner and publish to the scope's registry
# B, and login rewrites <scope>:registry; every npm call ship makes has --scope=. With scope=@acme,
# @acme:registry=B and B's token in F: no request reaches B, none carries B's token, and B's line and
# routing are the same after the run: a failed C4 login; a success; A6's printed step ends the npmjs
# session on its first run and keeps B's token. Control: no scope
scoped() { printf 'scope=@acme\n@acme:registry=https://npm.acme.example/\n//npm.acme.example/:_authToken=npm_acmeB\n' > "$FX/npmrc"; }
bkeeps() { grep -qx '@acme:registry=https://npm.acme.example/' "$1" && grep -qx '//npm.acme.example/:_authToken=npm_acmeB' "$1"; }   # FILE: B's routing and token as they were
noreqb() { ! grep -q '^REQ B' "$FX/reqs" 2>/dev/null && ! grep -q 'npm_acmeB' "$FX/reqs" 2>/dev/null; }
scoped; : > "$FX/loginfail"; rm -f "$FX/reqs"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/loginfail"
[ $r = 1 ] && grep -q '^npm login' "$FX/calls" && noreqb && bkeeps "$FX/npmrc.after" \
  && pass "REV 11 rule 2: a scope routed to another registry, a failed C4 login: no request reached it, none carried its token; its line and routing kept" \
  || fail "scope, failed login: rc=$r reqs: $(tr '\n' '|' < "$FX/reqs" 2>/dev/null) after: $(tr '\n' '|' < "$FX/npmrc.after" | cut -c1-200)"
scoped; rm -f "$FX/reqs"; rm -rf "${OUTR:?}"; ship; r=$?
completed && noreqb && bkeeps "$FX/npmrc.after" && ! grep -q '_authToken=npm_dry' "$FX/npmrc.after" \
  && pass "  a success: no request reached the scope's registry; @acme:registry is still its own after the exit; ship's line gone" \
  || fail "  scope, success: rc=$r reqs: $(tr '\n' '|' < "$FX/reqs" 2>/dev/null) after: $(tr '\n' '|' < "$FX/npmrc.after" | cut -c1-200)"
for k_ in scope control; do
  if [ $k_ = scope ]; then scoped; else : > "$FX/npmrc"; fi; echo '//registry.npmjs.org/:_authToken=npm_old' >> "$FX/npmrc"; rm -f "$FX/reqs"
  rm -rf "${OUTR:?}"; ship; r=$?
  lg_=$(lgline "$NF"); [ -n "$lg_" ] && (cd / && env -i PATH="$S:/usr/bin:/bin" HOME="$FX/ghome" NPM_CONFIG_USERCONFIG="$FX/npmrc" sh -c "$lg_" > /dev/null 2>&1)
  [ $r = 1 ] && grep -q 'an npm session exists' "$NF" && [ -n "$lg_" ] && ! grep -q '_authToken=npm_old' "$FX/npmrc" \
    && { [ $k_ = control ] || { bkeeps "$FX/npmrc" && noreqb; }; } \
    && pass "$( [ $k_ = control ] && echo '  control (no scope): ' || echo '  ')A6's printed step, run once: it ended the npmjs session$( [ $k_ = scope ] && echo "; the scope's registry got no request, its token kept")" \
    || fail "  A6 step ($k_): rc=$r '$lg_' F: $(tr '\n' '|' < "$FX/npmrc" | cut -c1-200) reqs: $(tr '\n' '|' < "$FX/reqs" 2>/dev/null)"
  rm -f "${FX:?}/npmrc"
done
# rule 3 (r13a F3): ship's F is $FX/ship.npmrc (NPM_CONFIG_USERCONFIG); the shell the operator pastes
# into has none, and its HOME's .npmrc holds another token: the printed logout and delete (a failed
# logout prints both) act on ship.npmrc and keep the other line. Control: the variable set in that shell
mkdir -p "$FX/h2" || exit 3
for k_ in bare control; do
  printf '//registry.npmjs.org/:_authToken=npm_other\n' > "$FX/h2/.npmrc"; : > "$FX/ship.npmrc"
  echo ETIMEDOUT > "$FX/logoutcode"; rm -rf "${OUTR:?}"; SETX="NPM_CONFIG_USERCONFIG=$FX/ship.npmrc"; ship; r=$?; SETX=; rm -f "${FX:?}/logoutcode"
  lg_=$(lgline "$NF"); dl_=$(dlline "$NF"); ev_=""; [ $k_ = control ] && ev_="NPM_CONFIG_USERCONFIG=$FX/ship.npmrc"
  ok_=no
  if [ -n "$lg_" ] && [ -n "$dl_" ] && grep -q '_authToken=npm_dry$' "$FX/ship.npmrc"; then
    (cd / && env -i PATH="$S:/usr/bin:/bin" HOME="$FX/h2" $ev_ sh -c "$lg_" > /dev/null 2>&1)
    a_=$(grep -c '_authToken=npm_dry$' "$FX/ship.npmrc"); b_=$(grep -c 'npm_other' "$FX/h2/.npmrc")
    echo '//registry.npmjs.org/:_authToken=npm_dry' >> "$FX/ship.npmrc"
    (cd / && env -i PATH="$S:/usr/bin:/bin" HOME="$FX/h2" $ev_ sh -c "$dl_" > /dev/null 2>&1)
    c_=$(grep -c '_authToken=npm_dry$' "$FX/ship.npmrc"); d_=$(grep -c 'npm_other' "$FX/h2/.npmrc")
    [ "$a_ $b_ $c_ $d_" = "0 1 0 1" ] && ok_=yes
  fi
  [ $r = 1 ] && [ $ok_ = yes ] \
    && pass "$( [ $k_ = control ] && echo '  control (the variable set in that shell too): ' || echo 'REV 11 rule 3: ')the printed logout and delete, run in a shell $( [ $k_ = bare ] && echo 'with no NPM_CONFIG_USERCONFIG' || echo 'with it'): each acted on ship's F, the other file's line kept" \
    || fail "printed lines ($k_): rc=$r logout '$lg_' delete '$dl_' after logout/delete: ship's ${a_:-?}/${c_:-?} other's ${b_:-?}/${d_:-?}"
done
rm -rf "${FX:?}/h2"; rm -f "${FX:?}/ship.npmrc"
# rule 4 (r13a P4): A6's session text: a token is ended by npm logout everywhere it is used; an _auth
# line is not; no "whatever its kind"
echo '//registry.npmjs.org/:_authToken=npm_old' > "$FX/npmrc"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/npmrc"
[ $r = 1 ] && a6ok "$NF" && ! grep -q 'whatever its kind' "$NF" "$FX/o" \
  && pass "REV 11 rule 4: A6's session text names the logout step, then how a token and an _auth line end" || fail "A6 rule 4: $(head -1 "$NF" | cut -c1-300)"
# r13b F6: every line ship_stoptext prints that runs a command runs as printed, pasted into sh and into
# an interactive zsh -f (from stdin), for every class with no progress and every progress state; the
# checkout's, the out dir's and F's paths hold a space
SW=$FX/stw; rm -rf "${SW:?}"; mkdir -p "$SW/bin" "$SW/st ate/repo/scripts" "$SW/o ut/v0.1.0" "$SW/u rc" || exit 3
printf '%s\n' 'index($0, n "() {") == 1 { f = 1; print; if ($0 ~ /[}][[:space:]]*(#.*)?$/) exit; next }' 'f { print }' 'f && /^[}]/ { exit }' > "$SW/fn.awk"
for f_ in dq npm_file npmcmd pnstep ship_stoptext; do awk -v n="$f_" -f "$SW/fn.awk" "$SR_ROOT/scripts/release.sh"; done > "$SW/fns.sh"
printf '#!/bin/sh\n{ printf "rs [%%s]" "$0"; for a; do printf " [%%s]" "$a"; done; [ "$1" != publish-npm ] || printf " uc=[%%s]" "${NPM_CONFIG_USERCONFIG-unset}"; printf "\\n"; } >> "$REC"\n' > "$SW/st ate/repo/scripts/release.sh"
printf '#!/bin/sh\n{ printf "git"; for a; do printf " [%%s]" "$a"; done; printf "\\n"; } >> "$REC"\n' > "$SW/bin/git"
printf '#!/bin/sh\n{ printf "npm"; for a; do printf " [%%s]" "$a"; done; printf " cwd=[%%s]\\n" "$PWD"; } >> "$REC"\n' > "$SW/bin/npm"
chmod +x "$SW/bin/git" "$SW/bin/npm"
printf '{\n  "tag": "v0.1.0",\n  "commit": "c0ffee"\n}\n' > "$SW/o ut/v0.1.0/MANIFEST.json"
srun() { # how line want -> 0 when the line, run that way from /, gave exactly want
  REC=$SW/rec; : > "$REC"; export REC
  if [ "$1" = sh ]; then (cd / && env -i PATH="$SW/bin:/usr/bin:/bin" REC="$REC" /bin/sh -c "$2") > "$SW/o" 2>&1
  else (cd / && printf '%s\n' "$2" | env -i PATH="$SW/bin:/usr/bin:/bin" HOME="$SW" REC="$REC" /bin/zsh -f -i) > "$SW/o" 2>&1; fi
  [ "$(cat "$REC")" = "$3" ]
}
nl_=0 np_=0 bad_=""
for s_ in "|public|m" "|public|" "|lost|" "|unreadable|" "|fix|" "|network|" "|content|" "|diverged|" \
          "push refused: main unmoved|fix|" "push refused: main holds it|fix|" "push refused|diverged|" "start push|fix|" "done push|fix|" \
          "start npm-platform sheepr-linux-arm64|fix|" "done npm-platform sheepr-linux-arm64|fix|" "start github|fix|" "exit5|fix|" "done github|fix|" \
          "start npm-main|fix|" "done npm-main|fix|"; do
  la_=${s_%%|*} r_=${s_#*|}; cl_=${r_%%|*} mf_=${r_#*|}
  { echo "run 1 2026-10-17T00:00:00Z"; [ -z "$la_" ] || echo "$la_"; } > "$SW/prog"; echo "$cl_" > "$SW/cls"; echo "a cause" > "$SW/cause"
  [ -n "$mf_" ] && cm_=c0ffee || cm_=other
  sh -c '. "$1/fns.sh"; shipprog=$1/prog shipcls=$1/cls shipcause=$1/cause phase=push tag=v0.1.0 out="$1/o ut" oroot="$1/st ate/repo" pubok=yes
    SR_NPM_PKGS="sheepr-linux-arm64 sheepr" SR_NPM_USER=lukasco commit=$2 NPMC= NPMREG=https://registry.npmjs.org/ NPM_CONFIG_USERCONFIG="$1/u rc/npmrc"; export NPM_CONFIG_USERCONFIG
    ship_stoptext' sh "$SW" "$cm_" > "$SW/text" 2> "$SW/text.err" || bad_="$bad_ [${la_:-$cl_}: ship_stoptext failed: $(head -c 120 "$SW/text.err")]"
  while IFS= read -r l_; do
    case $l_ in
      *[!\ ]*) ;; *) continue ;;
    esac
    t_=${l_#"${l_%%[! ]*}"}   # the line without its leading spaces
    case $t_ in
      "sh '"*|"NPM_CONFIG_USERCONFIG='"*) e_=$(printf '%s\n' "$t_" | sed -n "s|^\(NPM_CONFIG_USERCONFIG='[^']*' \)\{0,1\}sh '[^']*' \([a-z-]*\) .*|\2|p"); w_="rs [$SW/st ate/repo/scripts/release.sh] [$e_] [--out] [$SW/o ut] [v0.1.0]"
        [ "$e_" != publish-npm ] || { w_="$w_ uc=[$SW/u rc/npmrc]"; np_=$((np_ + 1)); } ;;   # (REV 11a rule 7: publish-npm gets F from its line)
      "git "*) w_="git [-C] [$SW/st ate/repo] [ls-remote] [origin] [refs/tags/v0.1.0]" ;;
      "cd / && npm "*) w_="npm [login] [--registry=https://registry.npmjs.org/] [--scope=] [--userconfig=$SW/u rc/npmrc] cwd=[/]" ;;
      *) continue ;;
    esac
    nl_=$((nl_ + 1))
    for how_ in sh zsh; do srun $how_ "$l_" "$w_" || bad_="$bad_ [${la_:-$cl_} $how_: '$(printf '%s' "$t_" | cut -c1-90)': $(tr '\n' '|' < "$REC" | cut -c1-80) $(head -c 80 "$SW/o" | tr '\n' ' ')]"; done
  done < "$SW/text"
done
[ -z "$bad_" ] && [ "$nl_" -ge 29 ] && [ "$np_" = 9 ] && pass "r13b F6: every runnable line of ship_stoptext ($nl_ lines over 20 classes and progress states) runs as printed, from sh and from an interactive zsh; each of the $np_ publish-npm lines gives publish-npm F (REV 11a rule 7)" \
  || fail "stoptext lines ($nl_, $np_ publish-npm lines):$(printf '%s' "$bad_" | cut -c1-500)"
# REV 11a rule 6 (r14a): each npm credential command ship prints is a line of its own with nothing after
# it (a copied period made F.): the logout step and its delete (pl), the logout's remedy (lo), A6's
# stop, publish-npm's two whoami stops and its last line, on stdout and in the next file. Each line
# holding `cd / && npm `, taken whole, runs as printed from sh and from an interactive zsh, and the npm
# stub records exactly --userconfig=F. Control: today's sentences, copied from `cd /` to their end
ownrun() { # LABEL FILE: each line of FILE holding `cd / && npm `: that command alone, run as printed ($on_: the kinds)
  while IFS= read -r l_; do
    case $l_ in *'cd / && npm '*) ;; *) continue ;; esac
    t_=${l_#"${l_%%[! ]*}"}
    case $t_ in
      'cd / && npm login '*) k_=login w_="npm [login] [--registry=https://registry.npmjs.org/] [--scope=] [--userconfig=$FX/npmrc] cwd=[/]" ;;
      'cd / && npm logout '*) k_=logout w_="npm [logout] [--registry=https://registry.npmjs.org/] [--scope=] [--userconfig=$FX/npmrc] cwd=[/]" ;;
      'cd / && npm config delete '*) k_=delete w_="npm [config] [delete] [//registry.npmjs.org/:_authToken] [--location=user] [--userconfig=$FX/npmrc] cwd=[/]" ;;
      *) bad_="$bad_ [$1: not a line of its own: '$(printf '%s' "$t_" | cut -c1-90)']"; continue ;;
    esac
    on_="$on_ $1:$k_"
    for how_ in sh zsh; do srun $how_ "$l_" "$w_" || bad_="$bad_ [$1 $how_ $k_: $(tr '\n' '|' < "$REC" | cut -c1-160)]"; done
  done < "$2"
}
pnx() { # publish-npm through its dry entry, against the state in $OUTR; output in $FX/co
  printf 'v0.1.0\nv0.1.0\n' > "$FX/ask"
  (cd "$REPO" && no_osascript env -i PATH="$B:/usr/bin:/bin" HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    SR_PUBLISH_DRY_NPM="$S/npm" SR_PUBLISH_DRY_NOTIFY="$S/notify" NPM_CONFIG_USERCONFIG="$FX/npmrc" SR_ASK_SCRIPT="$FX/ask" SR_ASK_RECORD="$FX/asks" \
    sh scripts/release.sh __publish-npm-dry --out "$OUTR" v0.1.0) > "$FX/co" 2>&1; r_=$?; dryhomes "$FX/co"; return $r_
}
on_="" bad_=""
# pl on stdout, lo on stdout and in the next file: a stop after the login, the logout failing
: > "$FX/pubfail.sheepr"; echo ETIMEDOUT > "$FX/logoutcode"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/pubfail.sheepr" "${FX:?}/logoutcode" "${FX:?}/npmrc"
cp "$FX/o" "$SW/s1.o"; cp "$NF" "$SW/s1.nf" 2>/dev/null || : > "$SW/s1.nf"
# A6's stop: a session from before ship
echo '//registry.npmjs.org/:_authToken=npm_old' > "$FX/npmrc"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/npmrc"
cp "$FX/o" "$SW/s2.o"; cp "$NF" "$SW/s2.nf" 2>/dev/null || : > "$SW/s2.nf"
# publish-npm after a stop past the push (nothing uploaded): not logged in (ENEEDAUTH), logged in as
# another user, then a success
printf ': > "%s/viewfailv.sheepr-linux-arm64"\n' "$FX" > "$FX/afterpush"; rm -rf "${OUTR:?}"; KEEP=1; ship; r=$?; KEEP=; rm -f "${FX:?}/afterpush" "${FX:?}/viewfailv.sheepr-linux-arm64"
pnx; cp "$FX/co" "$SW/s3a.o"
echo '//registry.npmjs.org/:_authToken=npm_dry' >> "$FX/npmrc"; echo stranger > "$FX/whoami"; pnx; cp "$FX/co" "$SW/s3b.o"; rm -f "${FX:?}/whoami"
pnx; r3_=$?; cp "$FX/co" "$SW/s3c.o"
world_reset; rm -f "${FX:?}/npmrc"
for s_ in s1.o s1.nf s2.o s2.nf s3a.o s3b.o s3c.o; do ownrun "$s_" "$SW/$s_"; done
on_=$(printf '%s\n' $on_ | sort | uniq -c | tr -s ' ' | tr '\n' ' ')
ow_=$(printf '%s\n' s1.o:logout s1.o:delete s1.o:login s1.o:logout s1.o:delete s1.nf:logout s1.nf:delete s1.nf:login \
  s2.o:logout s2.o:logout s2.nf:logout s3a.o:login s3b.o:logout s3b.o:login s3c.o:logout | sort | uniq -c | tr -s ' ' | tr '\n' ' ')
[ -z "$bad_" ] && [ "$on_" = "$ow_" ] && [ "$r3_" = 0 ] && grep -q 'npm whoami failed' "$SW/s3a.o" && grep -q 'logged in to npm as stranger' "$SW/s3b.o" \
  && pass "REV 11a rule 6: each npm credential command ship prints (pl, lo, A6's stop, publish-npm's two whoami stops and its last line; stdout and the next file) is a line of its own and runs as printed, from sh and an interactive zsh" \
  || fail "rule 6: kinds [$on_], want [$ow_]; publish-npm rc ${r3_:-?};$(printf '%s' "$bad_" | cut -c1-700)"
cc_=0
for l_ in "cd / && npm config delete //registry.npmjs.org/:_authToken --location=user --userconfig='$FX/npmrc'." \
          "cd / && npm login --registry=https://registry.npmjs.org/ --scope= --userconfig='$FX/npmrc', then publish-npm again"; do
  case $l_ in
    *delete*) w_="npm [config] [delete] [//registry.npmjs.org/:_authToken] [--location=user] [--userconfig=$FX/npmrc] cwd=[/]" g_="[--userconfig=$FX/npmrc.]" ;;
    *) w_="npm [login] [--registry=https://registry.npmjs.org/] [--scope=] [--userconfig=$FX/npmrc] cwd=[/]" g_="[--userconfig=$FX/npmrc,]" ;;
  esac
  for how_ in sh zsh; do srun $how_ "$l_" "$w_" || { grep -qF "$g_" "$SW/rec" && cc_=$((cc_ + 1)); }; done
done
[ "$cc_" = 4 ] && pass "  control: today's sentences, copied from 'cd /' to their end, give the stub F. and F, (4 of 4 runs caught)" || fail "  control: $cc_ of 4 runs gave F. or F,"
# REV 11a rule 7 (r14a F3, R3): the next file's publish-npm step names F itself. ship ran with
# NPM_CONFIG_USERCONFIG=$FX/ship.npmrc and stopped after the push; in a shell without that variable
# (its HOME's .npmrc empty): the printed npm login, then the printed publish-npm line, as printed:
# publish-npm reads the file the login wrote (whoami lukasco), uploads the four packages, and its last
# line, the logout step, names that file. Control: the variable set in that shell
: > "$FX/ship.npmrc"; mkdir -p "$FX/h3" || exit 3; : > "$FX/h3/.npmrc"
printf ': > "%s/viewfailv.sheepr-linux-arm64"\n' "$FX" > "$FX/afterpush"; rm -rf "${OUTR:?}"
SETX="NPM_CONFIG_USERCONFIG=$FX/ship.npmrc"; KEEP=1; ship; r=$?; KEEP=; SETX=; rm -f "${FX:?}/afterpush" "${FX:?}/viewfailv.sheepr-linux-arm64"
cp "$NF" "$FX/r3.nf"; lgi_=$(grep -x "  cd / && npm login .*" "$FX/r3.nf" | head -1)
pnl_=$(grep "^  NPM_CONFIG_USERCONFIG='[^']*' sh '[^']*/scripts/release.sh' publish-npm --out " "$FX/r3.nf" | head -1)
[ -n "$pnl_" ] || pnl_=$(grep "^  sh '[^']*/scripts/release.sh' publish-npm --out " "$FX/r3.nf" | head -1)   # (the line without F: the red run)
for k_ in bare control; do
  ev_=""; [ $k_ = control ] && ev_="NPM_CONFIG_USERCONFIG=$FX/ship.npmrc"
  : > "$FX/ship.npmrc"; rm -f "$FX"/pub.*; printf 'v0.1.0\nv0.1.0\n' > "$FX/ask"
  (cd / && env -i PATH="$S:/usr/bin:/bin" HOME="$FX/h3" $ev_ sh -c "$lgi_") > /dev/null 2>&1
  pd_=$(printf '%s\n' "$pnl_" | sed 's/ publish-npm --out / __publish-npm-dry --out /')
  (cd / && no_osascript env -i PATH="$B:/usr/bin:/bin" HOME="$FX/h3" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
     SR_PUBLISH_DRY_NPM="$S/npm" SR_PUBLISH_DRY_NOTIFY="$S/notify" $ev_ SR_ASK_SCRIPT="$FX/ask" SR_ASK_RECORD="$FX/asks" sh -c "$pd_") > "$FX/co" 2>&1; rc_=$?
  dryhomes "$FX/co"; np_=$(ls "$FX"/pub.* 2>/dev/null | grep -c .)
  if [ -n "$lgi_" ] && [ -n "$pnl_" ] && [ $rc_ = 0 ] && [ "$np_" = 4 ] && [ "$(tail -1 "$FX/co")" = "  cd / && npm logout --registry=https://registry.npmjs.org/ --scope= --userconfig='$FX/ship.npmrc'" ]; then
    pass "$( [ $k_ = control ] && echo '  control (the variable set in that shell): ' || echo 'REV 11a rule 7 (r14a R3): ')the printed npm login, then the printed publish-npm line, in a shell $( [ $k_ = bare ] && echo 'without NPM_CONFIG_USERCONFIG' || echo 'with it'): publish-npm read the login's file, 4 uploads, its last line the logout of that file"
  else fail "rule 7 R3 ($k_): rc=$rc_, $np_ uploads, the line '$(printf '%s' "$pnl_" | cut -c1-120)'; publish-npm said: $(grep -m1 -e 'whoami failed' -e 'userconfig' "$FX/co" | cut -c1-200) | last: $(tail -1 "$FX/co" | cut -c1-160)"; fi
done
rm -rf "${FX:?}/h3"; rm -f "${FX:?}/ship.npmrc" "${FX:?}/r3.nf"; world_reset; rm -f "${FX:?}/npmrc"
# REV 11a rule 9 (r14a F2): publish-npm finds npm logged in as another account (F's live token): its stop
# names the logout step first (it ends that token everywhere it is used), then the login, then how to
# keep that token (another userconfig file). Its command lines, run in order as printed: the stand-in
# ends the other account's token before the login writes. Control: whoami ENEEDAUTH: the login alone
printf ': > "%s/viewfailv.sheepr-linux-arm64"\n' "$FX" > "$FX/afterpush"; rm -rf "${OUTR:?}"; KEEP=1; ship; r=$?; KEEP=; rm -f "${FX:?}/afterpush" "${FX:?}/viewfailv.sheepr-linux-arm64"
for k_ in stranger control; do
  : > "$FX/npmrc"; [ $k_ = control ] || { echo '//registry.npmjs.org/:_authToken=npm_stranger' > "$FX/npmrc"; echo stranger > "$FX/whoami"; }
  pnx; rc_=$?; rm -f "${FX:?}/whoami"; : > "$FX/tokops"
  grep '^  cd / && npm ' "$FX/co" > "$FX/co.steps"
  while IFS= read -r l_; do (cd / && env -i PATH="$S:/usr/bin:/bin" HOME="$FX/ghome" sh -c "$l_") > /dev/null 2>&1 < /dev/null; done < "$FX/co.steps"
  ops_=$(tr '\n' '|' < "$FX/tokops")
  if [ $k_ = stranger ]; then
    [ $rc_ = 1 ] && grep -q 'logged in to npm as stranger' "$FX/co" && [ "$ops_" = "DELETE token=npm_stranger|LOGIN|" ] \
      && grep -q 'to keep that token: run neither line' "$FX/co" && grep -qF 'an absolute path in NPM_CONFIG_USERCONFIG' "$FX/co" \
      && pass "REV 11a rule 9: npm logged in as another account: the logout step, then the login, then how to keep that token; run in order, the other token ends before the login writes" \
      || fail "rule 9: rc=$rc_ ops [$ops_]; $(grep -c . "$FX/co.steps") command lines; $(grep -A1 'logged in to npm as' "$FX/co" | tr '\n' '|' | cut -c1-300)"
  else
    [ $rc_ = 1 ] && grep -q 'npm whoami failed' "$FX/co" && [ "$ops_" = "LOGIN|" ] && ! grep -q 'npm logout' "$FX/co.steps" \
      && pass "  control: whoami ENEEDAUTH: the login step alone" || fail "  rule 9 control: rc=$rc_ ops [$ops_] $(tr '\n' '|' < "$FX/co.steps" | cut -c1-200)"
  fi
done
world_reset; rm -f "${FX:?}/npmrc" "${FX:?}/tokops" "${FX:?}/co.steps"
# r12b F3, F4: no child holds ship's fd 8 or 9 (its own stdout and stderr, kept for the handler): a
# child left behind with its fds 0-2 closed must not hold a reader of ship's stdout. `ship | reader`
# with the build stand-in leaving such a child: the reader ends within 2 s of ship's end. Control: a
# child that keeps fd 1 (ship's stdout) holds the reader
for k_ in buildlinger buildlinger1; do
  rm -f "$FX/linger.pid" "$FX/t.end" "$FX/t.eof"; : > "$FX/$k_"; rm -rf "${OUTR:?}"; PIPEEOF=1; ship; r=$?; PIPEEOF=; rm -f "${FX:?}/$k_"
  lp_=$(cat "$FX/linger.pid" 2>/dev/null); d_=$(/usr/bin/perl -e 'printf "%.1f", $ARGV[1] - $ARGV[0]' "$(cat "$FX/t.end" 2>/dev/null)" "$(cat "$FX/t.eof" 2>/dev/null)")
  if [ $k_ = buildlinger ]; then
    completed && [ -n "$lp_" ] && /usr/bin/perl -e 'exit !($ARGV[0] <= 2)' "$d_" \
      && pass "r12b F3: ship | reader, a child left behind with fds 0-2 closed: the reader ends ${d_} s after ship" || fail "linger: rc=$r child '$lp_' reader ${d_} s after ship"
  else
    completed && [ -n "$lp_" ] && /usr/bin/perl -e 'exit !($ARGV[0] >= 3)' "$d_" \
      && pass "  control: a child that keeps fd 1 holds the reader (${d_} s after ship)" || fail "  control linger: rc=$r child '$lp_' reader ${d_} s after ship"
  fi
  # the child ends by itself (15 s); wait for it, so no row after this one sees it
  n_=0; while [ -n "$lp_" ] && kill -0 "$lp_" 2>/dev/null && [ $n_ -lt 80 ]; do /bin/sleep 0.25; n_=$((n_ + 1)); done
done
# r12b F5: a closed fd 1 or fd 2 at the start (ship keeps both on fds 8 and 9: the exec that keeps them
# killed the shell before its handler, leaving its temp dir): a refusal on the open channel, a
# non-zero exit, no temp dir left, nothing public. Under sh (bash 3.2), dash and zsh as sh
for sx_ in /bin/sh /bin/dash '/bin/zsh
--emulate
sh'; do
  for cf_ in 1 2; do
    rm -rf "${OUTR:?}"; SHX=$sx_; CLOSEFD=$cf_; ship; r=$?; SHX=; CLOSEFD=
    unnamed > /dev/null; ch_=stderr; [ $cf_ = 2 ] && ch_=stdout
    [ $r != 0 ] && grep -q "ship's $( [ $cf_ = 1 ] && echo stdout || echo stderr) (fd $cf_) is closed" "$FX/o" && [ -z "$(leftover)" ] && [ ! -e "$OUTR/.ship.lock" ] \
      && ! grep -q -e 'push --porcelain --atomic' -e '^npm publish' -e '^gh api -X POST' -e '^build ' "$FX/calls" 2>/dev/null \
      && pass "r12b F5: fd $cf_ closed at the start, $(echo "$sx_" | tr '\n' ' '): refused on $ch_, exit $r, no temp dir left, nothing public" \
      || fail "fd $cf_ closed, $(echo "$sx_" | tr '\n' ' '): rc=$r left '$(leftover | tr '\n' ' ')' out: $(head -3 "$FX/o" | tr '\n' '|' | cut -c1-200)"
  done
done
# a signal while a function call with redirections runs: bash 3.2 runs the trap and the exit handler with
# that call's redirections still on, so the stop text went into the call's file. ship's own stdout
# must hold it: INT to ship's group (SETSID) from the push stand-in during C5's real push (stdout to
# $st/push), and from docker's info at A7 (stdout to /dev/null). Control: at C4's npm login (none)
cat > "$FX/sigint" <<EOS
#!/bin/sh
lp=\$(cat "$OUTR/.ship.lock/pid" 2>/dev/null); pg=\$(/usr/bin/perl -e 'print getpgrp()')
[ -n "\$lp" ] && [ "\$pg" = "\$lp" ] || { echo "UNSAFE sigint \$1" >> "$FX/calls"; exit 0; }
echo "SIG INT at \$1" >> "$FX/calls"; kill -INT 0; /bin/sleep 1
EOS
for pt in 'onpush|push' 'oninfo|preflight' 'onlogin|npm-login'; do
  hk=${pt%%|*} ph=${pt#*|}
  # (at the push, ship is logged in: its logout fails, and npm's words go only to ship's stderr)
  [ $hk = onpush ] && echo ETIMEDOUT > "$FX/logoutcode"
  printf 'sh "%s/sigint" %s\n' "$FX" "$hk" > "$FX/$hk"; rm -f "${FX:?}/onpush.done"; rm -rf "${OUTR:?}"; SETSID=1; ship; r=$?; SETSID=; rm -f "${FX:?}/$hk" "${FX:?}/onpush.done" "${FX:?}/logoutcode"
  [ $r = 1 ] && grep -q "^SIG INT at $hk" "$FX/calls" && ! grep -q UNSAFE "$FX/calls" && grep -q "^release: ship v0.1.0 stopped at $ph" "$FX/o" && grep -q '(these steps are also in' "$FX/o" \
    && { [ $hk != onpush ] || grep -q '^npm error code ETIMEDOUT' "$FX/o"; } \
    && pass "$( [ $hk = onlogin ] && echo 'control: ')INT to ship's group at $hk: the stop text (stopped at $ph) reaches ship's own stdout$( [ $hk = onpush ] && echo "; npm logout's error, ship's own stderr")" \
    || fail "INT at $hk: rc=$r $(grep -e '^SIG' -e UNSAFE "$FX/calls" | tr '\n' ' ') stdout: $(grep -c 'stopped at' "$FX/o") stop lines, $(grep -c 'these steps are also in' "$FX/o") file lines"
done
rm -f "${FX:?}/sigint"
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
# reads that fail (A2's ls-remote, A3's fetch; C3's tap read and write right): when the cause is
# fixed, run ship again (the class comes from ship's own checks, never from the tool's answer)
for sw in lsfail fetchfail; do
  : > "$FX/$sw"; ship; r=$?; rm -f "$FX/$sw"
  [ $r = 1 ] && endsfix "$NF" && pass "$sw: when the cause is fixed, run ship again" || fail "$sw: $(tr '\n' '|' < "$NF" 2>/dev/null)"
  rm -rf "${OUTR:?}"
done
# each of those reads keeps the tool's own words in the next file's first line: A3's fetch; A5's
# write-right reads of the tap and of lukaso/sheepr (before the build: nothing built, the class fix);
# C3's tap read and write-right read (after it)
printf 'fatal: stand-in fetch failure 7f3a (A3)\n' > "$FX/fetchfail"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/fetchfail"
[ $r = 1 ] && head -1 "$NF" | grep -q 'stand-in fetch failure 7f3a' && endsfix "$NF" && pass "A3's fetch failing: the next file's first line keeps git's words" || fail "A3 fetch words: rc=$r $(head -1 "$NF" 2>/dev/null | cut -c1-240)"
rm -rf "${OUTR:?}"
for pw in 'tappermfail:HTTP 502: stand-in write-right read of the tap 5c1e (A5)' 'repopermfail:HTTP 503: stand-in write-right read of lukaso/sheepr 6d2f (A5)'; do
  sw=${pw%%:*}; printf '%s\n' "${pw#*:}" > "$FX/$sw"; ship; r=$?; rm -f "${FX:?}/$sw"
  [ $r = 1 ] && nobuild && head -1 "$NF" | grep -q -F "${pw#*:}" && endsfix "$NF" \
    && pass "A5, $sw: stopped before the build; the next file keeps gh's words and ends '$FIXL'" || fail "A5 $sw: rc=$r $(head -1 "$NF" 2>/dev/null | cut -c1-240) last '$(tail -1 "$NF" 2>/dev/null)'"
  rm -rf "${OUTR:?}"
done
for pw in 'tapreadfail:HTTP 502: stand-in tap read 9d2b (C3)' 'tappermfail:HTTP 504: stand-in write-right read of the tap 8e4a (C3)'; do
  sw=${pw%%:*}; printf '%s\n' "${pw#*:}" > "$FX/$sw.txt"; printf 'cp "%s/%s.txt" "%s/%s"\n' "$FX" "$sw" "$FX" "$sw" > "$FX/onbuild"
  ship; r=$?; rm -f "${FX:?}/onbuild" "${FX:?}/$sw" "${FX:?}/$sw.txt"
  [ $r = 1 ] && grep -q '^build ' "$FX/calls" && head -1 "$NF" | grep -q -F "${pw#*:}" && endsfix "$NF" \
    && pass "C3, $sw: the next file's first line keeps gh's words" || fail "C3 $sw: rc=$r $(head -1 "$NF" 2>/dev/null | cut -c1-240)"
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
  [ $r = 1 ] && endsfix "$NF" && ! grep -q aside "$NF" && pass "C3 $sw: when the cause is fixed, run ship again, no move aside" || fail "C3 $sw: $(tr '\n' '|' < "$NF" 2>/dev/null)"
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
         # release.sh entry through its dry entry (publish-npm: its line as printed, in a shell
         # without NPM_CONFIG_USERCONFIG); RC: the first refused step, or 0
  RC=0; : > "$FX/cont"; rm -f "$FX/cont.one"
  while IFS= read -r l; do
    case $l in
      *"cd / && npm login --registry=https://registry.npmjs.org/ --scope= --userconfig='$FX/npmrc'") echo "//registry.npmjs.org/:_authToken=npm_dry" >> "$FX/npmrc"; echo login >> "$FX/cont" ;;
      *"/scripts/release.sh' "*" --out '$OUTR' v0.1.0"*)
        e=$(printf '%s\n' "$l" | sed "s/.*\/scripts\/release\.sh' \([a-z-]*\) --out.*/\1/")
        [ "$e" = "${2:-$e}" ] || continue
        [ -z "${2:-}" ] || [ ! -e "$FX/cont.one" ] || return
        [ -z "${2:-}" ] || : > "$FX/cont.one"
        echo "$e" >> "$FX/cont"; printf 'v0.1.0\nv0.1.0\n' > "$FX/ask"
        if [ "$e" = publish-npm ]; then
          # (REV 11a rule 7) the line as printed, from / in a shell without NPM_CONFIG_USERCONFIG (the
          # line names F itself), its dry entry in the entry's place; its last line, the logout step, names F
          pl_=$(printf '%s\n' "$l" | sed 's/ publish-npm --out / __publish-npm-dry --out /')
          (cd / && no_osascript env -i PATH="$B:/usr/bin:/bin" HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
            SR_PUBLISH_DRY_NPM="$S/npm" SR_PUBLISH_DRY_NOTIFY="$S/notify" SR_ASK_SCRIPT="$FX/ask" SR_ASK_RECORD="$FX/asks" sh -c "$pl_") > "$FX/co" 2>&1 \
            || { dryhomes "$FX/co"; RC=1; echo "refused: $e: $(tail -1 "$FX/co")" >> "$FX/cont"; return; }
          dryhomes "$FX/co"
          [ "$(tail -1 "$FX/co")" = "  $LGF" ] || { RC=1; echo "refused: $e: its last line is not the logout step naming F: $(tail -1 "$FX/co")" >> "$FX/cont"; return; }
          continue
        fi
        (cd "$REPO" && no_osascript env -i PATH="$B:/usr/bin:/bin" HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
          SR_PUBLISH_DRY_GH="$S/gh" SR_PUBLISH_DRY_GIT="$S/sgit" SR_PUBLISH_DRY_NPM="$S/npm" SR_PUBLISH_DRY_CURL="$S/curl" SR_PUBLISH_DRY_NOTIFY="$S/notify" NPM_CONFIG_USERCONFIG="$FX/npmrc" \
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
postpush_ok() { ! grep -i -q -E -e 'nothing (is|was) publi' -e 'made nothing public' -e 'not public\.' -e 'nothing after it is publi' "$NF"; }
stoprow() { # label: the steps of the next file ran and the release is complete
  cont; [ $RC = 0 ] && done_all && pass "$1: the steps named ($(tr '\n' ' ' < "$FX/cont")) complete the release" || fail "$1: $(tr '\n' ' ' < "$FX/cont")"
  world_reset
}
# before the push: a content check, a network read, the A4 refusals
rm -rf "${OUTR:?}"; : > "$FX/npmcheckfail"; ship; r=$?; rm -f "$FX/npmcheckfail"
grep -qx 'Nothing is public.' "$NF" && grep -qx "Move $OUTR/v0.1.0 aside (never delete it), then run ship again." "$NF" && pass "npm-check refused: 'Nothing is public', move the build aside, run ship again" || fail "npm-check text: $(tr '\n' '|' < "$NF")"
mv "$OUTR/v0.1.0" "$FX/aside"; ship; r=$?; rm -rf "${FX:?}/aside"
completed && pass "  and ship again (the build moved aside) completes" || fail "  ship again: $(lastline)"
# a signal during C2 or C3, or a failure there that is not about the build, is not a content stop: no
# "Move ... aside" (a rebuild and a second notarization). INT to ship's group during C2's npm-check,
# HUP during C3's publish_check (its npm owner ls), and the tap's cask gone at C3 (gh 404, r8b F3)
cat > "$FX/sigsend" <<EOS
#!/bin/sh
lp=\$(cat "$OUTR/.ship.lock/pid" 2>/dev/null); pg=\$(/usr/bin/perl -e 'print getpgrp()')
[ -n "\$lp" ] && [ "\$pg" = "\$lp" ] || { echo "UNSAFE sigsend \$1" >> "$FX/calls"; exit 0; }
echo "SIG \$2 at \$1" >> "$FX/calls"; kill -\$2 0; /bin/sleep 1
EOS
for pt in 'onnpmcheck|INT|npm-check' 'onowner|HUP|checks'; do
  hk=${pt%%|*} sg=${pt#*|}; ph=${sg#*|}; sg=${sg%%|*}
  printf 'sh "%s/sigsend" %s %s\n' "$FX" "$hk" "$sg" > "$FX/$hk"; rm -rf "${OUTR:?}"; SETSID=1; ship; r=$?; SETSID=; rm -f "${FX:?}/$hk"
  [ $r = 1 ] && grep -q "^SIG $sg at $hk" "$FX/calls" && ! grep -q UNSAFE "$FX/calls" && grep -q "stopped at $ph" "$NF" && grep -qx 'Nothing is public.' "$NF" && endsfix "$NF" && ! grep -q aside "$NF" \
    && pass "$sg during $ph: Nothing is public, when the cause is fixed run ship again; no move aside" \
    || fail "$sg at $hk: rc=$r $(grep -e '^SIG' -e UNSAFE "$FX/calls" | tr '\n' ' ') $(tr '\n' '|' < "$NF" 2>/dev/null | cut -c1-240)"
done
rm -f "${FX:?}/sigsend"
# r12b F1: the content class is set only where a defect in the build's bytes is found (npm_check and
# verify set it themselves; C2's parent sets none): a failure that found none ends "when the cause above
# is fixed", never "move aside" (a rebuild and a second notarization). A C2 child KILLed (no signal to
# ship), C2's temp dir not made, C3's private copy of the manifest into a temp dir it cannot write,
# shasum giving no hash at C3. Controls: npm-check's refusals of the bytes keep "move aside"
fx1() { # label phase: the last run stopped at phase; nothing is public, the fix ending, no aside; all removed
  [ $r = 1 ] && grep -q "stopped at $2" "$NF" && grep -qx 'Nothing is public.' "$NF" && endsfix "$NF" && ! grep -q aside "$NF" && gone \
    && pass "$1: Nothing is public, when the cause is fixed run ship again; no move aside" || fail "$1: rc=$r $(tr '\n' '|' < "$NF" 2>/dev/null | cut -c1-260)"
}
printf 'echo "npm-check child KILLed" >> "%s/calls"; kill -KILL $PPID\n' "$FX" > "$FX/onnpmcheck"
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/onnpmcheck"
grep -q '^npm-check child KILLed$' "$FX/calls" || fail "  the KILL hook did not run (the row would prove nothing)"
fx1 "r12b F1: the npm-check child KILLed (no signal to ship)" npm-check
printf ': > "%s/dryhomefail"\n' "$FX" > "$FX/onbuild"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/onbuild" "${FX:?}/dryhomefail"
grep -q 'mktemp: (stand-in) no dir made' "$FX/o" || fail "  the temp HOME stand-in did not refuse (the row would prove nothing)"
fx1 "  C2's temp dir not made" npm-check
: > "$FX/publishro"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/publishro"
fx1 "  C3: the manifest's private copy into a temp dir it cannot write" checks
cat > "$B/shasum" <<EOF
#!/bin/sh
[ -e "$FX/shasumnone" ] && exit 0
exec /usr/bin/shasum "\$@"
EOF
chmod +x "$B/shasum"; printf ': > "%s/shasumnone"\n' "$FX" > "$FX/onnpmcheck"
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${B:?}/shasum" "${FX:?}/onnpmcheck" "${FX:?}/shasumnone"
fx1 "  shasum gives no hash at C3 (exit 0, no output)" checks
for k_ in hash control codesign; do
  echo "$k_" > "$FX/npmcheckfail"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/npmcheckfail"
  [ $r = 1 ] && grep -qx 'Nothing is public.' "$NF" && grep -qx "Move $OUTR/v0.1.0 aside (never delete it), then run ship again." "$NF" && gone \
    && pass "  control: npm-check refuses the bytes ($k_): move the build aside" || fail "  control $k_: rc=$r $(tr '\n' '|' < "$NF" 2>/dev/null | cut -c1-200)"
done
printf 'rm -f "%s/tap/sheepr.rb"\n' "$FX" > "$FX/onbuild"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/onbuild"; tapset 0.0.9
[ $r = 1 ] && grep -q 'has no Casks/sheepr.rb' "$NF" && grep -q 'stopped at checks' "$NF" && endsfix "$NF" && ! grep -q aside "$NF" \
  && pass "C3: the tap's cask gone (gh 404): add it, then run ship again; no move aside" || fail "C3 gh 404: rc=$r $(tr '\n' '|' < "$NF" 2>/dev/null | cut -c1-240)"
rm -rf "${OUTR:?}"; printf ': > "%s/ownerfail"\n' "$FX" > "$FX/onbuild"; ship; r=$?; rm -f "$FX/onbuild" "$FX/ownerfail"
endsfix "$NF" && ! grep -q 'aside' "$NF" && grep -q 'cannot read the owners' "$NF" && pass "C3: npm's owners unreadable: when the cause is fixed, run ship again, no move aside (the first cause kept)" || fail "C3 owner text: $(tr '\n' '|' < "$NF")"
ship; r=$?; completed && pass "  and ship again (the build kept) completes" || fail "  ship again: $(lastline)"
rm -rf "${OUTR:?}"; printf 'echo stranger > "%s/owner.sheepr"\n' "$FX" > "$FX/onbuild"; ship; r=$?; rm -f "$FX/onbuild" "$FX/owner.sheepr"
grep -qx 'When the cause above is fixed, run ship again.' "$NF" && ! grep -q 'aside' "$NF" && pass "C3: a name another npm user owns: fix it first, no move aside" || fail "C3 fix text: $(tr '\n' '|' < "$NF")"
rm -rf "${OUTR:?}"; : > "$FX/relsfail"; ship; r=$?; rm -f "$FX/relsfail"
grep -q 'cannot tell whether anything is public' "$NF" && grep -qx 'This run made nothing public.' "$NF" && endsfix "$NF" && pass "A4 unreadable: 'cannot tell', this run made nothing public; when the cause is fixed, run ship again" || fail "A4 unreadable: $(tr '\n' '|' < "$NF")"
g push -q --no-follow-tags origin "$T:refs/tags/v0.1.0" || exit 3
rm -rf "${OUTR:?}"; ship; r=$?
grep -qx 'ship does not continue a release of which anything is public.' "$NF" && grep -q 'separate steps of PHASE3.md §5: build --sign, npm-check' "$NF" && ! grep -q 'Never rebuild' "$NF" \
  && pass "A4, no build: the separate steps of §5" || fail "A4 no build: $(tr '\n' '|' < "$NF")"
g push -q --no-follow-tags origin "$T:refs/tags/v0.1.0" || exit 3
rm -rf "${OUTR:?}"; mkbuild "$OUTR/v0.1.0" v0.1.0 "$C"; ship; r=$?
grep -q "^Never rebuild it: continue from $OUTR/v0.1.0" "$NF" && grep -qx "  sh '$REPO/scripts/release.sh' npm-check --out '$OUTR' v0.1.0" "$NF" && pass "A4, this build in the out dir: never rebuild, continue from it" || fail "A4 with build: $(tr '\n' '|' < "$NF")"
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
grep -q 'The push started and was not confirmed' "$NF" && grep -qx "  git -C '$REPO' ls-remote origin refs/tags/v0.1.0" "$NF" && postpush_ok && pass "the push not confirmed: check ls-remote; the steps if it is there" || fail "push unconfirmed: $(tr '\n' '|' < "$NF")"
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
# every runnable line ship writes runs from any cwd (a new terminal window opens in ~): N12's next
# file, from a checkout whose path holds a space; each `sh '.../scripts/release.sh' ENTRY ...` line,
# run from /, reaches its entry (its dry entry here, with the stand-ins); the push-unconfirmed text's
# git line, run from /, reaches the checkout (sgit: file:// remotes only)
SPR="$FX/sp ace/repo"; mkdir -p "$FX/sp ace" && cp -R "$REPO" "$SPR" || exit 3
RO_=$REPO; REPO=$SPR; : > "$FX/postfail"; rm -rf "${OUTR:?}"; KEEP=1; ship; r=$?; KEEP=; rm -f "$FX/postfail"; REPO=$RO_
nr_=0 nok_=0 bad_=""
while IFS= read -r l; do
  case $l in *"sh '"*"/scripts/release.sh' "*) ;; *) continue ;; esac
  l=${l%%v0.1.0*}v0.1.0; eval "set -- $l"; ev_=""
  case $1 in NPM_CONFIG_USERCONFIG=*) ev_=$1; shift ;; esac   # (publish-npm's line names F itself: REV 11a rule 7)
  nr_=$((nr_ + 1)); e_=$3; shift 3
  (cd / && no_osascript env -i PATH="$B:/usr/bin:/bin" HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    SR_PUBLISH_DRY_GH="$S/gh" SR_PUBLISH_DRY_GIT="$S/sgit" SR_PUBLISH_DRY_NPM="$S/npm" SR_PUBLISH_DRY_CURL="$S/curl" SR_PUBLISH_DRY_NOTIFY="$S/notify" NPM_CONFIG_USERCONFIG="$FX/npmrc" ${ev_:+"$ev_"} \
    SR_PUBLISH_DRY_VERIFIED="$AH" SR_ASK_SCRIPT="$FX/ask" SR_ASK_RECORD="$FX/asks" sh "$SPR/scripts/release.sh" "__$e_-dry" "$@") > "$FX/co" 2>&1
  dryhomes "$FX/co"
  case $l in *"'$SPR/scripts/release.sh' $e_ "*) ;; *) bad_="$bad_ [path: $l]" ;; esac
  grep -q "^release: __$e_-dry " "$FX/co" && nok_=$((nok_ + 1)) || bad_="$bad_ [$e_: $(head -1 "$FX/co" | cut -c1-80)]"
done < "$NF"
world_reset
[ "$nr_" -ge 4 ] && [ "$nok_" = "$nr_" ] && [ -z "$bad_" ] && pass "each of N12's $nr_ release.sh lines, run from / (the checkout path holds a space), reaches its entry" \
  || fail "lines from /: $nok_ of $nr_ reached their entry;$bad_"
echo tag > "$FX/pushlie"; REPO=$SPR; rm -rf "${OUTR:?}"; KEEP=1; ship; r=$?; KEEP=; REPO=$RO_; rm -f "$FX/pushlie"
gl_=$(grep '^  git -C ' "$NF" | head -1); eval "set -- ${gl_# }"; shift
(cd / && env -i PATH=/usr/bin:/bin HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$S/sgit" "$@") > "$FX/co" 2>&1; r=$?
[ -n "$gl_" ] && [ $r = 0 ] && grep -q 'refs/tags/v0.1.0' "$FX/co" && ! grep -q '^SGIT REFUSED' "$FX/calls" \
  && pass "the push-unconfirmed text's git line, run from /: it reaches the checkout (the tag listed)" || fail "git line from /: rc=$r '$gl_' $(head -1 "$FX/co" | cut -c1-120)"
world_reset; rm -rf "${FX:?}/sp ace"
: > "$FX/putfail"; rm -rf "${OUTR:?}"; KEEP=1; ship; r=$?; KEEP=; rm -f "$FX/putfail"
grep -q 'is public on GitHub, but its Homebrew cask is not updated' "$NF" && grep -qx "  sh '$REPO/scripts/release.sh' publish-cask --out '$OUTR' v0.1.0" "$NF" && postpush_ok && pass "exit 5: publish-cask, npm login, publish-npm" || fail "exit5 text: $(tr '\n' '|' < "$NF")"
stoprow "exit 5"
: > "$FX/pubfail.sheepr"; rm -rf "${OUTR:?}"; KEEP=1; ship; r=$?; KEEP=; rm -f "$FX/pubfail.sheepr"
grep -q 'public on GitHub and Homebrew, and npm may hold a part of it' "$NF" && ! grep -q 'release.sh publish ' "$NF" && grep -q 'npmjs.com/package/sheepr shows' "$NF" && postpush_ok \
  && pass "the main upload refused: npm login, publish-npm only" || fail "main refused: $(tr '\n' '|' < "$NF")"
stoprow "the main upload refused"
# a stop after the platform uploads that says why a step uploaded nothing: C8's whoami failing (GitHub
# and Homebrew done), C7's npm owner ls failing (the GitHub publish stopped): the next file keeps what
# is public, and no stop text says that nothing is
: > "$FX/whoamibadmain"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/whoamibadmain"
[ $r = 1 ] && grep -q 'public on GitHub and Homebrew' "$NF" && grep -q 'this step uploaded nothing' "$NF" && postpush_ok \
  && pass "C8's npm whoami failing: 'public on GitHub and Homebrew', this step uploaded nothing" || fail "C8 whoami: rc=$r $(head -2 "$NF" 2>/dev/null | tr '\n' '|')"
: > "$FX/ownerfailafter"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/ownerfailafter"
[ $r = 1 ] && grep -q 'v0.1.0 is pushed' "$NF" && grep -q 'this step uploaded nothing' "$NF" && postpush_ok \
  && pass "C7's npm owner ls failing: 'is pushed', this step uploaded nothing" || fail "C7 owner ls: rc=$r $(head -2 "$NF" 2>/dev/null | tr '\n' '|')"
# after the push, each of publish-npm's refusals that names what this step did not upload, reached:
# npm_visible's "another file" (C8's wait on a platform package), the loop's copy and hash checks of a
# package (its file gone, or changed, during C6), and its view's "another file" (C6, before an upload);
# each next file keeps what is public, and no stop text says that nothing after it is published
pprow() { # label first-line-text last-progress
  [ $r = 1 ] && head -1 "$NF" | grep -q -F "$2" && [ "$(lastprog)" = "$3" ] && postpush_ok \
    && pass "$1: '$2', stopped after '$3'; nothing said to be unpublished" || fail "$1: rc=$r '$(lastprog)' $(head -1 "$NF" 2>/dev/null | cut -c1-160)"
}
echo 3 > "$FX/viewother.sheepr-linux-arm64"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/viewother.sheepr-linux-arm64"
pprow "C8's wait finds another file" "sheepr-linux-arm64@0.1.0 is on npm with another file (sha512-another) than this build's" "done github"
echo 1 > "$FX/viewother.sheepr-linux-x64"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/viewother.sheepr-linux-x64"
pprow "C6's view of a package finds another file" "sheepr-linux-x64@0.1.0 is already on npm with another file (sha512-another)" "done npm-platform sheepr-linux-arm64"
printf 'rm -f "%s/v0.1.0/sheepr-linux-x64-0.1.0.tgz"\n' "$OUTR" > "$FX/onviewpush.sheepr-linux-arm64"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/onviewpush.sheepr-linux-arm64" "${FX:?}/onviewpush.sheepr-linux-arm64.done"
pprow "C6, a package's file gone during the batch" "no sheepr-linux-x64-0.1.0.tgz in" "done npm-platform sheepr-linux-arm64"
printf 'echo x >> "%s/v0.1.0/sheepr-linux-x64-0.1.0.tgz"\n' "$OUTR" > "$FX/onviewpush.sheepr-linux-arm64"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/onviewpush.sheepr-linux-arm64" "${FX:?}/onviewpush.sheepr-linux-arm64.done"
pprow "C6, a package's file changed during the batch" "sheepr-linux-x64-0.1.0.tgz does not match its manifest hash" "done npm-platform sheepr-linux-arm64"
rm -rf "${OUTR:?}"
# N6: a C8 wait that times out (npm still scans a platform package): the review and block text
printf 'echo 100000 > "%s/processing.sheepr-linux-x64"\n' "$FX" > "$FX/afterpush"; rm -rf "${OUTR:?}"; KEEP=1; ship; r=$?; KEEP=; rm -f "$FX/afterpush"
[ "$(lastprog)" = "done github" ] && grep -q "held the version for review or blocked it" "$FX/o" && grep -q "npm may hold a version for review, or block it" "$NF" \
  && grep -q 'npmjs.com/package/sheepr-linux-x64 shows' "$NF" && ! grep -q 'npmjs.com/package/sheepr shows' "$NF" && pass "N6: a C8 wait timed out: the review and block text; no wait line for the main package (never uploaded)" || fail "N6: '$(lastprog)' $(tr '\n' '|' < "$NF")"
rm -f "$FX"/processing.*   # npm's scan finished
stoprow "the C8 wait timed out (then the scan finished)"
rm -rf "${OUTR:?}"
# C8's wait times out on the first platform package (C6 of the same run uploaded the two after it):
# the stop says what this step did not do (the main package), never "nothing after it is published",
# and the next file keeps "npm may hold a part of it"; then on the last platform package
for pk in sheepr-linux-arm64 sheepr-darwin-universal; do
  printf 'echo 100000 > "%s/processing.%s"\n' "$FX" "$pk" > "$FX/afterpush"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/afterpush" "$FX"/processing.*
  [ $r = 1 ] && head -1 "$NF" | grep -q "$pk@0.1.0 is not visible on npm" && ! head -1 "$NF" | grep -q -i 'after it is published' \
    && head -1 "$NF" | grep -q 'This step did not upload the main package' && grep -q 'npm may hold a part of it' "$NF" && postpush_ok \
    && pass "C8's wait on $pk timed out: 'this step did not upload the main package', npm may hold a part of it" || fail "C8 wait on $pk: rc=$r $(head -1 "$NF" 2>/dev/null | cut -c1-80)…$(head -1 "$NF" 2>/dev/null | tail -c 120)"
done

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
grep -q "Move $OUTR/v0.1.0 aside" "$NF" && pass "  a content finding: move the build aside" || fail "  badstamp: no move aside: $(tr '\n' '|' < "$NF" 2>/dev/null | cut -c1-200)"
rm -rf "${OUTR:?}"; : > "$FX/npmcheck.touch"; ship; r=$?; rm -f "$FX/npmcheck.touch"; hint_row "C3's file check" "a file npm-check checked has changed since"
grep -q "Move $OUTR/v0.1.0 aside" "$NF" && pass "  a content finding: move the build aside" || fail "  touch: no move aside: $(tr '\n' '|' < "$NF" 2>/dev/null | cut -c1-200)"
rm -rf "${OUTR:?}"; : > "$FX/stilldraft"; ship; r=$?; rm -f "$FX/stilldraft"; hint_row "the release still a draft" "it is still a draft"
rm -rf "${OUTR:?}"; : > "$FX/putfail"; ship; r=$?; rm -f "$FX/putfail"; hint_row "the cask refused (exit 5)" "its Homebrew cask is not updated"
printf 'echo 100000 > "%s/processing.sheepr-linux-x64"\n' "$FX" > "$FX/afterpush"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/afterpush"
hint_row "a C8 wait timed out" "held the version for review or blocked it"
grep -q 'A blocked version needs a new version number' "$FX/o" && pass "  npm's review and blocking text kept (N5)" || fail "  the review text is gone"
rm -rf "${OUTR:?}"; : > "$FX/owner404.sheepr-linux-x64"; ship; r=$?; rm -f "$FX/owner404.sheepr-linux-x64"; hint_row "a name not on npm (A4)" "reserve the name first (publish a 0.0.0 placeholder as lukasco); this run made nothing public"
grep -qx 'When the cause above is fixed, run ship again.' "$NF" && ! grep -qx 'Run ship again.' "$NF" && ! grep -q '^build ' "$FX/calls" \
  && pass "  refused at A4, before the build; the fix named first, never a bare 'run ship again'" || fail "  a name not on npm: $(tr '\n' '|' < "$NF" 2>/dev/null)"
# npm's --json answers its E404 on stdout (the error object), and may say nothing on stderr: the
# time view reads both, as the version view does
rm -rf "${OUTR:?}"; : > "$FX/owner404json.sheepr-linux-x64"; ship; r=$?; rm -f "$FX/owner404json.sheepr-linux-x64"; hint_row "a name not on npm, its E404 only in --json's stdout (A4)" "reserve the name first (publish a 0.0.0 placeholder as lukasco); this run made nothing public"
printf 'cd "%s/v0.1.0" && echo x > NPM-CHECKED\n' "$OUTR" > "$FX/afterpush"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/afterpush"; hint_row "C6's stamp check" "npm-check has not passed on"
printf 'echo x >> "%s/v0.1.0/sheepr-linux-x86_64"\n' "$OUTR" > "$FX/afterpush"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/afterpush"; hint_row "C6's file check" "a file npm-check checked has changed since"
printf ': > "%s/whoamibad2"\n' "$FX" > "$FX/afterpush"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/afterpush" "$FX/whoamibad2"; hint_row "C6's whoami failing" "npm whoami failed (not logged in to npm?); this step uploaded nothing"
printf 'echo other > "%s/whoami"\n' "$FX" > "$FX/afterpush"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/afterpush" "$FX/whoami"; hint_row "C6's whoami another user" "but the packages belong to lukasco; this step uploaded nothing"
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
grep -qx -F 'shipcall() { if [ "$dryentry" = yes ]; then tool dry "$@"; else "$@" 8>&- 9>&-; fi; }   # (fds 8 and 9 closed: as in tool)' "$RS" && pass "shipcall: the real branch runs the tool as the operator has it, with fds 8 and 9 closed (text)" || fail "shipcall's text"
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
# --- no stop after the push started said that nothing is public (every run of this cell, scanned)
n_pp=$(cat "$FX/postpush.runs" 2>/dev/null | grep -c .)
[ "$n_pp" -ge 20 ] && [ ! -s "$FX/postpush.bad" ] && pass "no stop text of the $n_pp runs past 'start push' (but a refused push) says that nothing is public" \
  || fail "after the push started ($n_pp runs), a stop text says nothing is public: $(head -3 "$FX/postpush.bad" 2>/dev/null | cut -c1-200 | tr '\n' '|')"
# --- no dry HOME left: every one the cell's runs named is gone (refusals included: an rc tag and a
# tag off the grammar are refused before ship's own exit handler is set)
# r12b F4, the source half: every place ship starts a program that can outlive its call closes fds 8
# and 9: tool's four exec arms (base, net, web, dry), npm_env, shipcall's direct arm (the real entry's:
# no cell runs it), npy, git by name, and rt_judge (realtools.sh)
RSX=$SR_ROOT/scripts/release.sh RTX=$SR_ROOT/scripts/lib/realtools.sh
c1_=$(grep -c '"\$@" 8>&- 9>&- ;;' "$RSX"); c2_=$(grep -c '"\$@" 8>&- 9>&- )$' "$RSX")
c3_=$(grep -c '^shipcall() { if \[ "\$dryentry" = yes \]; then tool dry "\$@"; else "\$@" 8>&- 9>&-; fi; }' "$RSX")
c4_=$(grep -c '^npy() {.*"\$@" 8>&- 9>&-; }$' "$RSX"); c5_=$(grep -c '^git() { command git "\$@" 8>&- 9>&-; }$' "$RSX")
c6_=$(grep -c '"\$@" > "\$o_" 2>&1 8>&- 9>&- ' "$RTX")
[ "$c1_ $c2_ $c3_ $c4_ $c5_ $c6_" = "4 1 1 1 1 1" ] && pass "every place ship starts a program that can outlive its call closes fds 8 and 9 (tool 4, npm_env, shipcall, npy, git, rt_judge)" \
  || fail "fds 8 and 9 closed at: tool $c1_ of 4, npm_env $c2_, shipcall $c3_, npy $c4_, git $c5_, rt_judge $c6_"
# r12b F4: the census of the children ship starts: no stand-in (the build, npm-check, gh, npm, docker,
# git, notify, caffeinate, the identity check, curl) and no git by name started with fd 8 or 9 open,
# in any ship run of this cell. Control: a stand-in started with fd 8 open records it
[ ! -s "$FX/fds" ] && pass "no child ship started, in any run of this cell, held its fd 8 or 9" || fail "children with fd 8 or 9: $(sort "$FX/fds" | uniq -c | sort -rn | head -6 | tr '\n' '|' | cut -c1-300)"
(HOME=$FX/ghome; export HOME; "$S/caffeinate" -i 8> /dev/null) > /dev/null 2>&1
grep -q '^FD8 caffeinate' "$FX/fds" 2>/dev/null && pass "  control: a stand-in started with fd 8 open records it" || fail "  control: no FD8 record"
n_dh=$(sort -u "$FX/dryhomes" 2>/dev/null | grep -c .); n_mk=$(sort -u "$FX/allmade" 2>/dev/null | grep -c .)
left_dh=$(sort -u "$FX/dryhomes" "$FX/allmade" 2>/dev/null | while read -r d; do [ ! -e "$d" ] || echo "$d"; done)
un_dh=$(sort -u "$FX/allmade" 2>/dev/null | grep -v -x -F -f "$FX/dryhomes")
[ -z "$left_dh" ] && [ -z "$un_dh" ] && [ "$n_mk" -ge 100 ] && [ "$(sort -u "$FX/allmade" | grep -c '/sr-npmpub\.')" -ge 1 ] \
  && pass "every one of the $n_mk temp dirs this cell's runs made was named on the run's output, and none is left" \
  || fail "temp dirs left ($(printf '%s\n' "$left_dh" | grep -c .)): $(printf '%s\n' "$left_dh" | head -3 | tr '\n' ' ') not named ($(printf '%s\n' "$un_dh" | grep -c .)): $(printf '%s\n' "$un_dh" | head -3 | tr '\n' ' ')"
finish
