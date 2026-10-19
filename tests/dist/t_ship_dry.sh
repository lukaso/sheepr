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
# (\$FX/buildlinger: a child left behind, fds 0-2 closed, any other kept; \$FX/buildlinger1: fd 1 kept too.
# It lingers until \$FX/linger.go exists (the row makes it), at most 120 s)
[ -e "$FX/buildlinger" ] && { /bin/sh -c 'n=0; while [ ! -e "\$1" ] && [ \$n -lt 600 ]; do /bin/sleep 0.2; n=\$((n + 1)); done' sh "$FX/linger.go" < /dev/null > /dev/null 2>&1 & echo \$! > "$FX/linger.pid"; }
[ -e "$FX/buildlinger1" ] && { /bin/sh -c 'n=0; while [ ! -e "\$1" ] && [ \$n -lt 600 ]; do /bin/sleep 0.2; n=\$((n + 1)); done' sh "$FX/linger.go" < /dev/null 2>/dev/null & echo \$! > "$FX/linger.pid"; }
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
[ ! -e "$FX/npmcheck.empty" ] || : > "\$d/NPM-CHECKED"   # (a stamp write that landed nothing, exit 0: r17b F1)
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
# ncode CODE: npm's words for CODE on stderr, as npm 11.6.0 writes them (r17a F3: E401 and ENEEDAUTH advise
# a credential command: notes/r17a/np/t2-v24.9.0.txt, t3-v24.9.0.txt); any other code, its code line
ncode() {
  case \$1 in
    E401) printf 'npm error code E401\nnpm error Unable to authenticate, your authentication token seems to be invalid.\nnpm error To correct this please try logging in again with:\nnpm error   npm login\n' >&2 ;;
    ENEEDAUTH) printf 'npm error code ENEEDAUTH\nnpm error need auth This command requires you to be logged in.\nnpm error need auth You need to authorize this machine using \`npm adduser\`\n' >&2 ;;
    # (npm 9 to 11 advise --otp=<code>, a flag ship does not take: notes/r18a/np/t3-v*.txt; r18b F8)
    EOTP) printf 'npm error code EOTP\nnpm error This operation requires a one-time password from your authenticator.\nnpm error You can provide a one-time password by passing --otp=<code> to the command you ran.\nnpm error If you already provided a one-time password then it is likely that you either typoed\nnpm error it, or it timed out. Please try again.\n' >&2 ;;
    *) echo "npm error code \$1" >&2 ;;
  esac
}
for a_; do case \$a_ in --userconfig=*) UC=\${a_#--userconfig=} ;; --scope=*) SC=\${a_#--scope=}; scset=yes ;; esac; done
[ -n "\$UC" ] || UC=\${NPM_CONFIG_USERCONFIG:-\${npm_config_userconfig:-}}
ucdef=no; [ -n "\$UC" ] || { UC=\$HOME/.npmrc; ucdef=yes; }
UC=\$(/usr/bin/perl "$SR_ROOT/tests/dist/envrep.pl" "\$UC")   # (npm rewrites \${NAME} in the path's text first: r18a F1, tests/dist/envrep.pl)
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
echo "\$1 \$UC" >> "$FX/npmucs"   # (the userconfig each call loads: REV 11b rule 19)
# npm's global config (r17a F1): NPM_CONFIG_GLOBALCONFIG or npm_config_globalconfig, else the prefix's
# etc/npmrc (here \$FX/globaldefault); its token is sent when the userconfig has none (each such request in
# \$FX/reqs), and a logout with none in the userconfig ends it and rewrites that file without it, mode 0666
# (npm 10.9.2, 11.6.0: notes/r17a/np/t1-v*.txt part G); each call's global file in \$FX/npmgcs
GC=\${NPM_CONFIG_GLOBALCONFIG:-\${npm_config_globalconfig:-$FX/globaldefault}}
echo "\$1 \$GC" >> "$FX/npmgcs"
gt_=\$(sed -n 's|^//registry.npmjs.org/:_authToken=||p' "\$GC" 2>/dev/null | tail -1)
if [ -n "\$gt_" ] && ! grep -q '^//registry.npmjs.org/:_authToken=' "\$UC" 2>/dev/null; then
  case \$1 in
    view|owner|whoami|publish|login) echo "REQ A \$1 global=\$gt_" >> "$FX/reqs" ;;
    logout) echo "DELETE global token=\$gt_" >> "$FX/tokops"; grep -v '^//registry.npmjs.org/:_authToken=' "\$GC" > "\$GC.n"; mv "\$GC.n" "\$GC"; chmod 666 "\$GC"; exit 0 ;;
  esac
fi
last=""; for a; do case \$a in --userconfig=*) ;; *) last=\$a ;; esac; done   # (--userconfig=P comes last: REV 12)
TOK='//registry.npmjs.org/:_authToken='
# (a dead token, npm_dead*: every npm call that sends it answers E401, its logout too, and the line stays)
case \$(sed -n "s|^\$TOK||p" "\$UC" 2>/dev/null | tail -1) in npm_dead*) case \$1 in view|owner|whoami|publish|logout) ncode E401; exit 1 ;; esac ;; esac
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
    [ -e "$FX/viewcode.\$last" ] && { ncode "\$(cat "$FX/viewcode.\$last")"; echo "npm error the view of \$p \$last (stand-in)" >&2; exit 1; }
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
  whoami) [ -e "$FX/whoamibad" ] && { echo "npm error code ETIMEDOUT" >&2; exit 1; }
    # (\$FX/whoamiansi: the code it answers, in npm's colours, as color=always writes it)
    [ -e "$FX/whoamiansi" ] && { printf '\033[1mnpm\033[22m \033[31merror\033[39m \033[94mcode\033[39m %s\n' "\$(cat "$FX/whoamiansi")" >&2; exit 1; }
    [ -e "$FX/whoamicode" ] && { ncode "\$(cat "$FX/whoamicode")"; exit 1; }   # (\$FX/whoamicode: the code it answers)
    # (\$FX/whoamipostlogin: the code it answers once npm login ran: C4's whoami, not A6's)
    [ -e "$FX/whoamipostlogin" ] && grep -q '^npm login' "$FX/calls" && { ncode "\$(cat "$FX/whoamipostlogin")"; exit 1; }
    # (\$FX/whoamibadmain: fails once three uploads are recorded, i.e. at C8)
    [ -e "$FX/whoamibadmain" ] && [ "\$(grep -c '^npm publish' "$FX/calls")" -ge 3 ] && { echo "npm error code ETIMEDOUT" >&2; exit 1; }
    # (a username and _password pair: whoami answers the user name, as npm does)
    grep -q '^//registry.npmjs.org/:username=' "\$UC" 2>/dev/null && grep -q '^//registry.npmjs.org/:_password=' "\$UC" && { sed -n 's|^//registry.npmjs.org/:username=||p' "\$UC" | head -1; exit 0; }
    # (an //registry.npmjs.org/:_auth= line: whoami answers its user, as npm does for basic auth)
    grep -q '^//registry.npmjs.org/:_auth=' "\$UC" 2>/dev/null && { cat "$FX/whoami" 2>/dev/null || echo lukasco; exit 0; }
    if grep -q "^\$TOK" "\$UC" 2>/dev/null; then
      [ -e "$FX/whoamibad2" ] && { echo "npm error code ETIMEDOUT" >&2; exit 1; }
      [ -e "$FX/expired" ] && { ncode E401; exit 1; }
      case \$(sed -n "s|^\$TOK||p" "\$UC" | tail -1) in npm_stranger*) echo stranger; exit 0 ;; esac   # (the other account's token)
      cat "$FX/whoami" 2>/dev/null || echo lukasco; exit 0
    fi
    # no token line: ENEEDAUTH (\$FX/whoamierr: npm's whole answer instead, e.g. coloured, or npm 9's)
    if [ -e "$FX/whoamierr" ]; then cat "$FX/whoamierr" >&2; else ncode ENEEDAUTH; fi; exit 1 ;;
  login) [ -e "$FX/onlogin" ] && sh "$FX/onlogin"   # (\$FX/onlogin: a hook at C4's npm login)
    mkdir -p "\$(dirname "\$UC")" 2>/dev/null   # (npm's config save makes P's directory, as mkdir -p: r18a F1)
    [ -e "$FX/loginfail" ] && exit 1
    # (with a scope, npm login writes <scope>:registry=<--registry>: the scope's routing is rewritten)
    [ -n "\$SC" ] && { grep -v "^\$SC:registry=" "\$UC" > "\$UC.n" 2>/dev/null; echo "\$SC:registry=https://registry.npmjs.org/" >> "\$UC.n"; mv "\$UC.n" "\$UC"; echo "REQ A login rewrote \$SC:registry" >> "$FX/reqs"; }
    # (\$FX/logintoken: the token the login writes, instead of npm_dry)
    echo LOGIN >> "$FX/tokops"   # (\$FX/tokops: each login's write, in order with the tokens the logouts end)
    # (the root line replaced, as npm 9 to 11 do: notes/r15a/np/t6)
    [ -f "\$UC" ] && { grep -v "^\$TOK" "\$UC" > "\$UC.n"; mv "\$UC.n" "\$UC"; }
    if [ -s "$FX/logintoken" ]; then echo "\${TOK}\$(cat "$FX/logintoken")" >> "\$UC"; else echo "\${TOK}npm_dry" >> "\$UC"; fi
    [ ! -e "$FX/loginfailw" ] || exit 1
    [ ! -e "$FX/loginempty" ] || : > "\$UC"   # (\$FX/loginempty: the login leaves P with no token line, exit 0)
    [ ! -e "$FX/loginauth" ] || printf '//registry.npmjs.org/:_auth=c3RyYW5nZXI6eA==\n' > "\$UC"   # (\$FX/loginauth: only a basic-auth line, no token line: r18a F5)
    exit 0 ;;   # (\$FX/loginfailw: the login writes its line, then fails)
  logout) [ -e "$FX/onlogout" ] && sh "$FX/onlogout"   # (\$FX/onlogout: a hook as ship's logout starts)
    # (\$FX/logoutonce CODE: the next logout fails with that npm error code, once, and the line stays)
    if [ -s "$FX/logoutonce" ]; then c_=\$(cat "$FX/logoutonce"); rm -f "$FX/logoutonce"; ncode "\$c_"; exit 1; fi
    # (\$FX/logoutoncetext: the next logout fails with the file's text on stderr, once, and the line stays)
    if [ -s "$FX/logoutoncetext" ]; then cat "$FX/logoutoncetext" >&2; rm -f "$FX/logoutoncetext"; exit 1; fi
    [ -e "$FX/logoutint" ] && exec /usr/bin/perl -e 'getpgrp() == getppid() or do { open(my \$f, ">>", "$FX/calls"); print \$f "UNSAFE logoutint\\n"; exit 1 }; \$SIG{INT} = "DEFAULT"; kill "INT", 0; sleep 5; exit 0'
    # (\$FX/logoutmsg CODE: the logout fails with npm's own words for CODE, the request's URL naming the
    # token it sends (npm masks only its npm_ shape, as npm_***: notes/r13a/np/t9b-*), and the line stays)
    if [ -s "$FX/logoutmsg" ]; then
      t_=\$(sed -n "s|^\$TOK||p" "\$UC" | tail -1); case \$t_ in npm_*) t_='npm_***' ;; esac
      case \$(cat "$FX/logoutmsg") in
        E401) printf 'npm error code E401\nnpm error 401 Unauthorized - DELETE https://registry.npmjs.org/-/user/token/%s - token expired or revoked\nnpm error To correct this please try logging in again with:\nnpm error   npm login\n' "\$t_" >&2 ;;
        E503) printf 'npm error code E503\nnpm error 503 Service Unavailable - DELETE https://registry.npmjs.org/-/user/token/%s - down\n' "\$t_" >&2 ;;
        *) printf 'npm error code FETCH_ERROR\nnpm error errno FETCH_ERROR\nnpm error network timeout at: https://registry.npmjs.org/-/user/token/%s\n' "\$t_" >&2 ;;
      esac; exit 1
    fi
    # (\$FX/logoutcode: the logout fails with that npm error code, and the line stays)
    [ -e "$FX/logoutcode" ] && { ncode "\$(cat "$FX/logoutcode")"; exit 1; }
    # (a username and _password pair and no token line: npm logout removes the pair, as npm does)
    if grep -q '^//registry.npmjs.org/:username=' "\$UC" 2>/dev/null && ! grep -q "^\$TOK" "\$UC"; then
      grep -v -e '^//registry.npmjs.org/:username=' -e '^//registry.npmjs.org/:_password=' "\$UC" > "\$UC.n"; mv "\$UC.n" "\$UC"; exit 0
    fi
    # (an _auth line and no token line: npm logout answers ENEEDAUTH and leaves the line)
    grep -q '^//registry.npmjs.org/:_auth=' "\$UC" 2>/dev/null && ! grep -q "^\$TOK" "\$UC" && { ncode ENEEDAUTH; exit 1; }
    [ -e "$FX/logoutfail" ] && exit 1; [ -e "$FX/logoutstays" ] && exit 0; [ -e "$FX/logoutrm" ] && { rm -f "\$UC"; exit 0; }
    [ -e "$FX/logoutlies" ] && { grep -v "^\$TOK" "\$UC" > "\$UC.n" 2>/dev/null; mv "\$UC.n" "\$UC"; exit 1; }
    # (\$FX/logoutleaves: a line it leaves in the userconfig, as npm logout leaves any but the root line)
    # (no token line: npm logout answers ENEEDAUTH, exit 1, as real npm does: notes/r16a/np/t4)
    grep -q "^\$TOK" "\$UC" 2>/dev/null || { ncode ENEEDAUTH; exit 1; }
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
  rm -f "$FX/calls" "$FX/pathcalls" "$FX/asks" "$FX/npmenvs" "$FX/npmucs" "$FX/pipe.rc" "$FX/made"
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
    if [ "$CLOSEFD" = ro ]; then   # (ro: fd 1 open read-only, so every write to it fails, EBADF; stderr to $FX/o)
      : > "$FX/ro"
      (cd "$REPO" && IFS='
'; no_osascript "$@" env -i PATH="$B:/usr/bin:/bin" HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        $(cat "$FX/envs") ${SHX:-sh} scripts/release.sh __ship-dry --out "${OUT:-$OUTR}" "${TAG:-v0.1.0}") 1< "$FX/ro" 2> "$FX/o"; r_=$?
    elif [ "$CLOSEFD" = 1 ]; then
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
  # ship's own P as the run left it (npmrc.after: empty when D is gone; pd.after: left or gone), then D
  # removed (an earlier P makes the next run log out of it first); KEEPP=1 keeps it
  pd_=${OUT:-$OUTR}/.${TAG:-v0.1.0}.npm
  cp "$pd_/npmrc" "$FX/npmrc.after" 2>/dev/null || : > "$FX/npmrc.after"
  if [ -e "$pd_" ]; then echo left > "$FX/pd.after"; else echo gone > "$FX/pd.after"; fi
  [ -n "${KEEPP:-}" ] || rm -rf "${pd_:?}"
}
completed() { [ $r = 0 ] && grep -q 'release: ship: v0.1.0 is public on GitHub, Homebrew and npm' "$FX/o"; }
# REV 12: ship's own npm file. D = $OUTR/.v0.1.0.npm (0700), P = D/npmrc: every npm call ship makes
# loads P and names it (--userconfig=P, last); ship never reads or writes NPM_CONFIG_USERCONFIG's file
# ($FX/npmrc in every run: a decoy now), npm_config_userconfig's or the HOME's .npmrc
PD=$OUTR/.v0.1.0.npm; PP=$PD/npmrc
onlyp() { # every npm call of the last run loaded P and named it on its command line, with --registry and --scope=
  [ -s "$FX/npmucs" ] && [ "$(awk '{print $2}' "$FX/npmucs" | sort -u)" = "$PP" ] && [ -z "$(grep '^npm ' "$FX/calls" | grep -v -- " --userconfig=$PP\$")" ] \
    && [ -z "$(grep '^npm ' "$FX/calls" | grep -v -e ' --registry=https://registry.npmjs.org/ ')" ] && [ -z "$(grep '^npm ' "$FX/calls" | grep -v -e ' --scope= ')" ]
}
NPMCMD='npm (login|logout|config|token|adduser)'   # an npm credential command in a text (REV 12: none is printed)
nopath() { [ ! -s "$FX/pathcalls" ]; }
# the archive hash verify (dry) judges: the build stand-in's archive for $OUTR/v0.1.0
AH=$(printf 'sheepr-macos-universal.tar.gz %s\n' "$OUTR/v0.1.0" | shasum -a 256 | cut -d' ' -f1)

# the npm stand-in, as real npm 9 to 11 answer (notes/r16a/np/t3, t4; notes/builder/np16/t16m1-*): its
# login replaces the root _authToken line and keeps another registry's (r16a R1); its logout of a
# userconfig with no token line answers ENEEDAUTH, exit 1 (r16a F8). Controls: an empty userconfig gets
# one root line; the logout of a live line ends it, exit 0
printf '//registry.npmjs.org/:_authToken=npm_other\n//other.example/:_authToken=x\n' > "$FX/st1.rc"; : > "$FX/st2.rc"; : > "$FX/st3.rc"
printf '//registry.npmjs.org/:_authToken=npm_x\n' > "$FX/st4.rc"
for f_ in st1 st2; do (cd / && env -i PATH=/usr/bin:/bin HOME="$FX/ghome" "$S/npm" login --registry=https://registry.npmjs.org/ --scope= --userconfig="$FX/$f_.rc") > /dev/null 2>&1; done
(cd / && env -i PATH=/usr/bin:/bin HOME="$FX/ghome" "$S/npm" logout --registry=https://registry.npmjs.org/ --scope= --userconfig="$FX/st3.rc") > /dev/null 2> "$FX/st3.err"; r3_=$?
(cd / && env -i PATH=/usr/bin:/bin HOME="$FX/ghome" "$S/npm" logout --registry=https://registry.npmjs.org/ --scope= --userconfig="$FX/st4.rc") > /dev/null 2>&1; r4_=$?
r1a_=$(grep -c '^//registry.npmjs.org/:_authToken=' "$FX/st1.rc"); r1b_=$(grep -c '^//registry.npmjs.org/:_authToken=' "$FX/st2.rc")
[ "$r1a_" = 1 ] && grep -qx '//registry.npmjs.org/:_authToken=npm_dry' "$FX/st1.rc" && ! grep -q npm_other "$FX/st1.rc" && grep -qx '//other.example/:_authToken=x' "$FX/st1.rc" && [ "$r1b_" = 1 ] \
  && pass "r16a R1: the npm stand-in's login replaces the root token line (another registry's kept), as real npm does; control: an empty userconfig gets one" \
  || fail "r16a R1: the stand-in's login: [$(tr '\n' ' ' < "$FX/st1.rc")] ($r1a_ root lines); empty: $r1b_"
[ $r3_ = 1 ] && grep -qx 'npm error code ENEEDAUTH' "$FX/st3.err" && [ $r4_ = 0 ] && ! grep -q '_authToken' "$FX/st4.rc" \
  && pass "r16a F8: the npm stand-in's logout with no token line answers ENEEDAUTH, exit 1, as real npm does; control: a live line, exit 0, the line gone" \
  || fail "r16a F8: the stand-in's logout, no line: exit $r3_ '$(tr '\n' ' ' < "$FX/st3.err")'; a live line: exit $r4_ [$(tr '\n' ' ' < "$FX/st4.rc")]"
rm -f "$FX/st1.rc" "$FX/st2.rc" "$FX/st3.rc" "$FX/st4.rc" "$FX/st3.err" "$FX/calls" "$FX/tokops" "$FX/npmucs" "$FX/npmenvs"
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
grep -qF "another ship or publish-npm holds $FX/rel/out/.ship.lock" "$FX/o" && pass "a relative --out: made absolute from where ship ran (the lock named by its absolute path)" || fail "relative out: $(tail -1 "$FX/o")"
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
# A6: npm's owners (REV 12: no session check; ship logs in to its own file P at C4, so no session of the
# operator's matters, and none is read)
echo stranger > "$FX/owner.sheepr"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/owner.sheepr"; pre_row "an npm name owned by someone else" "belongs to stranger"
A6NF=$OUTR/v0.1.0.ship-next.txt
# npm's project config (the .npmrc beside the nearest package.json above npm's cwd) wins over the
# userconfig; every npm call ship makes runs from /, where npm finds none. A project .npmrc above the
# checkout with an expired token (the stand-in answers E401 to a call that finds it): npm reads it never,
# and the run completes
printf '{}\n' > "$FX/package.json"; echo "//registry.npmjs.org/:_authToken=npm_expired" > "$FX/.npmrc"; rm -f "${FX:?}/npmcwds"
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/package.json" "${FX:?}/.npmrc"
completed && [ "$(sort -u "$FX/npmcwds" 2>/dev/null)" = / ] \
  && pass "a project .npmrc with an expired token above the checkout: npm read no project file (every npm call ran from /); the run completes" || fail "project config: rc=$r cwds $(sort -u "$FX/npmcwds" 2>/dev/null | tr '\n' ' '); $(lastline)"
# a stop's class comes only from ship's own checks (PLAN-ship.md, REV 8): a failed npm, gh or git
# call before the push ends "When the cause above is fixed, run ship again.", whatever it answered
# (never a bare "Run ship again.", which loops on a definite answer); the cause keeps the tool's own
# words, and no stop names an npm command (REV 12)
FIXL='When the cause above is fixed, run ship again.'
endsfix() { [ "$(tail -1 "$1")" = "$FIXL" ] && ! grep -qx 'Run ship again.' "$1"; }
a6row() { # label code want-text: npm owner ls answering CODE: refused before the build, npm's words kept
  echo "$2" > "$FX/ownercode"
  rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/ownercode"
  pre_row "$1" "$3"
  endsfix "$A6NF" && grep -q "npm error code $2" "$A6NF" && ! grep -Eq "$NPMCMD" "$A6NF" \
    && pass "  its next file keeps npm's words and ends '$FIXL'; no npm command" || fail "  $1: last line '$(tail -1 "$A6NF")', $(grep -Ec "$NPMCMD" "$A6NF") npm command lines"
}
for c in E401 E403 FETCH_ERROR E429 ETIMEDOUT ERR_INVALID_AUTH; do a6row "npm owner ls $c" $c "cannot read the owners of"; done
# every npm command that reaches the registry answering E401 (A4's views fail first), and answering
# ERR_INVALID_AUTH with npm's warning first: npm's words in the next file, no npm command, the fix ending
printf 'npm error code E401\nnpm error 401 Unauthorized - GET https://registry.npmjs.org/sheepr - stand-in\nnpm error To correct this please try logging in again with:\nnpm error   npm login\n' > "$FX/npmall"   # (npm's own words, its advice among them: r17a F3)
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/npmall"
pre_row "every npm command answering E401 (A4 first)" "cannot tell whether anything is public"
grep -q 'npm error code E401' "$A6NF" && ! grep -Eq "$NPMCMD" "$A6NF" && endsfix "$A6NF" && pass "  the next file: npm's words; no npm command; when the cause is fixed, run ship again" \
  || fail "  every npm E401: $(grep -Ec "$NPMCMD" "$A6NF") npm command lines, last '$(tail -1 "$A6NF")'"
printf 'npm warn Unknown user config "_authToken". This will stop working in the next major version of npm.\nnpm error code ERR_INVALID_AUTH\nnpm error Invalid auth configuration found: `_authToken` must be renamed to `//registry.npmjs.org/:_authToken` in user config\n' > "$FX/npmall"
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/npmall"
pre_row "every npm command answering ERR_INVALID_AUTH" "cannot tell whether anything is public"
grep -q 'npm error code ERR_INVALID_AUTH' "$A6NF" && ! grep -Eq "$NPMCMD" "$A6NF" && endsfix "$A6NF" && pass "  the next file: npm's words; no npm command; when the cause is fixed, run ship again" \
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
# REV 12 rule 2: an earlier P whose logout answers ENEEDAUTH in npm's colours, or in npm 9's words (npm's
# code read either way): P removed, the run completes
for lt_ in color npm9; do
  case $lt_ in
    color) printf '\033[1mnpm\033[22m \033[31merror\033[39m \033[94mcode\033[39m ENEEDAUTH\n\033[1mnpm\033[22m \033[31merror\033[39m \033[94mneed auth\033[39m This command requires you to be logged in.\n' > "$FX/logoutoncetext" ;;
    npm9) printf 'npm ERR! code ENEEDAUTH\nnpm ERR! need auth This command requires you to be logged in.\n' > "$FX/logoutoncetext" ;;
  esac
  rm -rf "${OUTR:?}"; mkdir -p "$PD" && chmod 700 "$PD" && echo '//registry.npmjs.org/:_authToken=npm_earlier' > "$PP" && echo $(( $(/bin/date +%s) + 3600 )) > "$PD/end" || exit 3
  ship; r=$?; rm -f "${FX:?}/logoutoncetext"
  completed && [ "$(grep -c '^npm logout' "$FX/calls")" = 2 ] && pass "REV 12 rule 2: an earlier P's logout answering ENEEDAUTH $( [ $lt_ = color ] && echo "in npm's colours" || echo "in npm 9's words"): P removed, the run completes" \
    || fail "earlier P, ENEEDAUTH ($lt_): rc=$r $(grep -c '^npm logout' "$FX/calls") logouts; $(lastline)"
done
# the operator's npmrc sets npm's heading (heading=xyz: `xyz error code ENEEDAUTH`): ship's npm pins
# it (the environment over the userconfig), so A6 reads ENEEDAUTH and passes a clean state. Control:
# the stand-in honours the npmrc line when the environment sets no heading, and the pin when it does
echo "heading=xyz" > "$FX/npmrc"
hx=$(env -i PATH=/usr/bin:/bin HOME="$FX/ghome" NPM_CONFIG_USERCONFIG="$FX/npmrc" "$S/npm" whoami 2>&1 >/dev/null); hn=$(env -i PATH=/usr/bin:/bin HOME="$FX/ghome" NPM_CONFIG_USERCONFIG="$FX/npmrc" npm_config_heading=npm "$S/npm" whoami 2>&1 >/dev/null)
[ "$(printf '%s\n' "$hx" | head -1)" = "xyz error code ENEEDAUTH" ] && ! printf '%s\n' "$hx" | grep -q '^npm ' && [ "$(printf '%s\n' "$hn" | head -1)" = "npm error code ENEEDAUTH" ] && pass "control: the npm stand-in writes the npmrc's heading, and the environment's over it" || fail "control: the stand-in's heading: '$hx' '$hn'"
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/npmrc"
completed && pass "A6, an npmrc with heading=xyz (no token line): npm's heading pinned, the clean state passes, the run completes" || fail "npmrc heading=xyz: $(head -1 "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | cut -c1-200)"
# A4's time and dist-tags.latest views answering E401: stopped before the build; npm's words, no npm command
for vf in time dist-tags.latest; do
  echo E401 > "$FX/viewcode.$vf"
  rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/viewcode.$vf"
  [ $r = 1 ] && nobuild && grep -q " $vf: npm error code E401" "$A6NF" && ! grep -Eq "$NPMCMD" "$A6NF" && ! grep -Eq "$NPMCMD" "$FX/o" && endsfix "$A6NF" \
    && pass "A4's $vf view answering E401: stopped before the build; npm's words, no npm command" || fail "A4 $vf E401: rc=$r $(head -1 "$A6NF" 2>/dev/null | cut -c1-240)"
done
: > "$FX/tokops"; echo E401 > "$FX/whoamipostlogin"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/whoamipostlogin"
[ $r = 1 ] && grep -q 'npm whoami failed after the login (npm error code E401' "$A6NF" && ! grep -Eq "$NPMCMD" "$A6NF" && ! grep -q 'logging in again' "$A6NF" && ! grep -q '^npm publish' "$FX/calls" \
  && [ "$(grep -c '^DELETE token=npm_dry' "$FX/tokops")" = 1 ] && [ "$(cat "$FX/pd.after")" = gone ] \
  && pass "C4's whoami after the login answering E401: nothing published; npm's words, no npm command; P logged out, D removed" \
  || fail "C4 whoami E401: rc=$r $(head -1 "$A6NF" 2>/dev/null | cut -c1-240)"
# r17a F4 (REV 12b rule 28): D's volume ignores file ownership (an external drive mounted noowners; the
# dry seam answers so): a stop at the login (fix): no npm login call, no P, nothing pushed. Control: every
# other run (the real check answers that the fixture's volume keeps ownership)
: > "$FX/tokops"; rm -rf "${OUTR:?}"; SETX=SR_SHIP_DRY_NOOWNERS=yes; ship; r=$?; SETX=
[ $r = 1 ] && grep -q "is on a volume that ignores file ownership (an external drive mounted noowners?)" "$A6NF" && grep -q 'stopped at npm-login' "$A6NF" \
  && ! grep -q '^npm login' "$FX/calls" && [ ! -s "$FX/tokops" ] && [ "$(cat "$FX/pd.after")" = gone ] && ! grep -q -e 'push --porcelain --atomic' -e '^npm publish' -e '^gh api -X POST' "$FX/calls" && endsfix "$A6NF" \
  && pass "r17a F4: D's volume ignores file ownership: a stop at the login (fix), no login, no P, nothing pushed" \
  || fail "r17a F4, noowners: rc=$r logins $(grep -c '^npm login' "$FX/calls") D $(cat "$FX/pd.after"); $(head -1 "$A6NF" 2>/dev/null | cut -c1-200)"
# r17a F3 (REV 12b rule 27): C4's whoami answering ENEEDAUTH in npm's words, whose last line advises
# `npm adduser`: the stop quotes npm's code and words without that line, in stdout and the next file
: > "$FX/tokops"; echo ENEEDAUTH > "$FX/whoamipostlogin"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/whoamipostlogin"
[ $r = 1 ] && grep -q 'npm whoami failed after the login (npm error code ENEEDAUTH npm error need auth This command requires you to be logged in.' "$A6NF" \
  && ! grep -Eq "$NPMCMD" "$A6NF" && ! grep '^release:' "$FX/o" | grep -Eq "$NPMCMD" && ! grep -q 'logging in again' "$A6NF" \
  && pass "r17a F3: C4's whoami answering ENEEDAUTH: npm's code and words quoted, its adduser advice not" \
  || fail "r17a F3, ENEEDAUTH: rc=$r $(grep -m1 'whoami failed' "$A6NF" 2>/dev/null | cut -c1-260)"
# r18b F8, r18a (PLAN-ship.md REV 12c rule 35): C4's whoami answering EOTP in npm's words, which advise
# `--otp=<code>` (a flag ship does not take): the stop quotes npm's code and words without that line, in
# stdout and the next file. Control: the ENEEDAUTH row above
: > "$FX/tokops"; echo EOTP > "$FX/whoamipostlogin"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/whoamipostlogin"
[ $r = 1 ] && grep -q 'npm whoami failed after the login (npm error code EOTP npm error This operation requires a one-time password' "$A6NF" \
  && ! grep -q -e '--otp' "$A6NF" && ! grep '^release:' "$FX/o" | grep -q -e '--otp' \
  && pass "r18b F8: C4's whoami answering EOTP: npm's code and words quoted, its --otp advice not" \
  || fail "r18b F8, EOTP: rc=$r $(grep -m1 'whoami failed' "$A6NF" 2>/dev/null | cut -c1-300)"
# REV 12 rule 1: the operator's userconfig variable in any spelling (~, a relative path, an absolute one,
# one holding a $; before REV 12 A1 refused the odd ones): npm never sees it; the run completes, every npm
# call loads and names P
bu_=""; mkdir -p "$FX/v" || exit 3
for uv in 'NPM_CONFIG_USERCONFIG=~/npmrc' 'npm_config_userconfig=rel/npmrc' "NPM_CONFIG_USERCONFIG=$FX/abs-npmrc" "NPM_CONFIG_USERCONFIG=$FX/v/\${SRFOO}rc" "npm_config_userconfig=$FX/v/\$SRFOO/rc"; do
  SETX=$uv; rm -rf "${OUTR:?}"; ship; r=$?; SETX=
  completed && onlyp || bu_="$bu_ [$uv: rc=$r $(lastline | cut -c1-80)]"
done
rm -rf "${FX:?}/v"
[ -z "$bu_" ] && pass "REV 12 rule 1: NPM_CONFIG_USERCONFIG or npm_config_userconfig as ~, relative, absolute or holding a \$: the run completes, every npm call P's" || fail "the userconfig spellings:$bu_"
# A7: the build's preconditions
: > "$FX/nodocker"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/nodocker"; pre_row "Docker does not answer" "Docker"
: > "$FX/nobase"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/nobase"; pre_row "the pinned base image missing" "no local image rust:"
# r12b F8, REV 11b rule 17 (r15b P4-8): the step names the checkout's test-all by its full path
# (single-quoted: dq) on a line of its own, so it runs as printed from any directory (test-all cds to
# its own directory). Each line, pasted into sh and into an interactive zsh -f from /, gives a stub
# test-all (put at the checkout's path after the run, then taken back) exactly its argument
ta7() { # FILE WANT...: the test-all lines of FILE are exactly the WANTs (pull, amd64), each a line of its own that runs as printed
  ta_=$(grep -c "test-all" "$1"); tl_=$(grep -c "^  '$REPO/test-all' [a-z0-9]*$" "$1"); f_=$1; shift
  [ "$tl_" = $# ] && [ "$ta_" = $# ] || return 1
  cp "$REPO/test-all" "$FX/ta.keep" || return 1
  printf '#!/bin/sh\n{ printf "ta"; for a; do printf " [%%s]" "$a"; done; printf "\\n"; } >> "$REC"\n' > "$REPO/test-all"
  ok_=0
  for w_; do
    l_=$(grep -x "  '$REPO/test-all' $w_" "$f_")
    for how_ in sh zsh; do
      REC=$FX/ta.rec; : > "$REC"
      if [ $how_ = sh ]; then (cd / && env -i PATH=/usr/bin:/bin REC="$REC" /bin/sh -c "$l_") > /dev/null 2>&1
      else (cd / && printf '%s\n' "$l_" | env -i PATH=/usr/bin:/bin HOME="$FX" REC="$REC" /bin/zsh -f -i) > /dev/null 2>&1; fi
      [ "$(cat "$REC")" = "ta [$w_]" ] || ok_=1
    done
  done
  cp "$FX/ta.keep" "$REPO/test-all"; rm -f "$FX/ta.keep" "$FX/ta.rec"
  return $ok_
}
ta7 "$OUTR/v0.1.0.ship-next.txt" pull && pass "  the step: the checkout's test-all by its full path, a line of its own; it runs as printed (sh, zsh)" || fail "  test-all step: $(grep 'test-all' "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | tr '\n' '|')"
: > "$FX/noamd64"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/noamd64"; pre_row "the amd64 image missing" "no local amd64 image"
ta7 "$OUTR/v0.1.0.ship-next.txt" pull amd64 && pass "  the steps: test-all pull and test-all amd64, each a line of its own; each runs as printed (sh, zsh)" || fail "  test-all steps: $(grep 'test-all' "$OUTR/v0.1.0.ship-next.txt" 2>/dev/null | tr '\n' '|')"
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
li=$(ln_ '^npm login'); wi=$(grep -n '^npm whoami' "$FX/calls" | sed -n 1p | cut -d: -f1)   # (A6 asks no whoami: REV 12)
pi=$(ln_ "^sgit -C $WTP push --porcelain --atomic --no-follow-tags origin $C:refs/heads/main $T:refs/tags/v0.1.0\$")
[ -n "$li" ] && [ -n "$pi" ] && [ "$li" -lt "$pi" ] && [ -n "$wi" ] && [ "$wi" -gt "$li" ] && [ "$wi" -lt "$pi" ] \
  && pass "npm login (then whoami) before the push; the push: the recorded object, --atomic --no-follow-tags" || fail "login $li whoami $wi push $pi"
grep -q "^npm login --registry=https://registry.npmjs.org/ --scope= --userconfig=$PP\$" "$FX/calls" && pass "the login names the registry, no scope (REV 11 rule 2), and P (REV 12)" || fail "the login: $(grep '^npm login' "$FX/calls")"
seq_=$(grep -e '^npm publish' -e '^npm view .*dist.integrity' -e '^gh api -X POST repos' -e '^gh api -X PATCH' "$FX/calls" | sed -e "s| --userconfig=$PP\$||" -e 's/^npm publish .*\/\(sheepr[a-z0-9-]*\)-0\.1\.0\.tgz$/P:\1/' -e 's/^npm view .* \(sheepr[a-z0-9-]*\)@0\.1\.0 dist\.integrity$/V:\1/' -e 's/^gh api -X POST.*/POST/' -e 's/^gh api -X PATCH.*/PATCH/' | tr '\n' ' ')
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
! grep -q '_authToken=' "$FX/npmrc.after" && [ "$(cat "$FX/pd.after")" = gone ] && pass "the run left no npm session (D removed)" || fail "P after the run: $(grep -c _authToken= "$FX/npmrc.after") token line(s), D $(cat "$FX/pd.after")"
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
[ $r = 1 ] && grep -q 'the login to npm was as other, but the packages belong to lukasco' "$FX/o" && nopub && grep -qx 'When the cause above is fixed, run ship again.' "$OUTR/v0.1.0.ship-next.txt" && pass "another npm user after the login: stopped, nothing public" || fail "wrong user: rc=$r $(lastline)"
: > "$FX/loginfail"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/loginfail"
[ $r = 1 ] && grep -q 'the login to npm failed' "$FX/o" && nopub && endsfix "$OUTR/v0.1.0.ship-next.txt" && [ "$(grep -c '^npm logout' "$FX/calls")" = 0 ] && [ "$(cat "$FX/pd.after")" = gone ] \
  && pass "a failing login that wrote nothing: stopped, nothing public, no logout (no P), D removed; when the cause is fixed, run ship again" || fail "login fails: rc=$r logouts $(grep -c '^npm logout' "$FX/calls") D $(cat "$FX/pd.after") $(lastline)"
# a login that wrote P, then failed: the logout of P (logged in from the attempt on)
: > "$FX/loginfailw"; : > "$FX/tokops"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/loginfailw"
[ $r = 1 ] && grep -q 'the login to npm failed' "$FX/o" && nopub && [ "$(grep -c '^npm logout' "$FX/calls")" = 1 ] && grep -q '^DELETE token=npm_dry' "$FX/tokops" && [ "$(cat "$FX/pd.after")" = gone ] \
  && pass "  a login that wrote P, then failed: one logout of P (logged in from the attempt on), D removed" || fail "  login wrote, then failed: rc=$r logouts $(grep -c '^npm logout' "$FX/calls") [$(tr '\n' ' ' < "$FX/tokops")] D $(cat "$FX/pd.after")"
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
# r17b F4 (REV 12b rule 21): the control's text, read from the class: "ship does not continue"
NF=$OUTR/v0.1.0.ship-next.txt   # (the next file, as the exit handler's rows below name it)
grep -qx 'ship does not continue a release of which anything is public.' "$NF" && ! grep -qx 'Nothing is public.' "$NF" \
  && pass "  control (REV 12b rule 21): with its class readable, C5's A4 refusal says ship does not continue" || fail "  control, C5's class: $(tr '\n' '|' < "$NF" 2>/dev/null | cut -c1-240)"
# r17b F4 (REV 12b rule 21): the class and the cause cannot be written (each a directory now, made during
# the build), then C5's A4 finds a draft of the version: the stop text says nothing about what is public
# (no "Nothing is public", no remedy a class decides)
cat > "$FX/onbuild" <<EOF
printf 'v0.0.9 false false\nv0.1.0 true false\n' > "$FX/rels"
st_=\$(grep '/sr-ship\.' "$FX/made" | tail -1); rm -f "\$st_/class" "\$st_/cause"; mkdir "\$st_/class" "\$st_/cause"
EOF
rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/onbuild"; echo "v0.0.9 false false" > "$FX/rels"
[ $r = 1 ] && grep -q 'GitHub has a release or a draft v0.1.0' "$FX/o" && nopub && grep -q "ship cannot read this stop's class" "$NF" && ! grep -qi 'nothing is public' "$NF" \
  && ! grep -qi 'move .* aside' "$NF" \
  && pass "r17b F4: no readable class (and no cause) at C5's A4 refusal: nothing said about what is public" \
  || fail "r17b F4, no class: rc=$r $(tr '\n' '|' < "$NF" 2>/dev/null | cut -c1-300)"
# r17b F4 (REV 12b rule 21): ship's record made unreadable right after the push (a mode, as a full disk or
# a removal can hide it): the next record write stops ship (C6), and its stop text, which cannot tell how
# far the run got, gives the route that holds after any step: the ls-remote check, GitHub's three cases,
# then publish-npm; never "nothing is public". Control: a C6 upload refused, the record readable: the
# platform text
printf 'chmod 000 "%s/.v0.1.0.ship-progress"\n' "$OUTR" > "$FX/afterpush"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/afterpush"; chmod 644 "$OUTR/.v0.1.0.ship-progress" 2>/dev/null
[ $r = 1 ] && grep -q 'ship cannot read its own record' "$NF" && grep -qF 'ls-remote origin refs/tags/v0.1.0' "$NF" && grep -q 'publish-cask --out' "$NF" && grep -q 'publish-npm --out' "$NF" \
  && ! grep -qi 'nothing is public' "$NF" && ! grep -qi 'nothing was public' "$NF" \
  && pass "r17b F4: the record unreadable after the push: the route that holds after any step, never 'nothing is public'" \
  || fail "r17b F4, the record: rc=$r $(tr '\n' '|' < "$NF" 2>/dev/null | cut -c1-300)"
: > "$FX/pubfail.sheepr-linux-x64"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/pubfail.sheepr-linux-x64"
[ $r = 1 ] && grep -q 'is pushed, and npm may hold a part of it; GitHub has no release of it' "$NF" && ! grep -q 'ship cannot read its own record' "$NF" \
  && pass "  control: the record readable, a C6 refusal: the platform text" || fail "  control, the record: rc=$r $(tr '\n' '|' < "$NF" 2>/dev/null | cut -c1-200)"
rm -rf "${OUTR:?}"
# r17b F4 (REV 12b rule 21): gkhint (release.sh's own) reads ship's phase, never the record: with the
# record missing, after the push (phase github) the ls-remote route and no rebuild; control: before
# the push (phase checks), the rebuild
gk1_=$(shipping=yes tag=v0.1.0 root=$FX/frozen oroot=$REPO shipprog=$FX/no-such-record phase=github; eval "$(sed -n '/^dq() {/,/^}/p' "$RS")"; eval "$(sed -n '/^gkhint() {/,/^}/p' "$RS")"; gkhint /x/a.tar.gz Sheepr.app)
gk2_=$(shipping=yes tag=v0.1.0 root=$FX/frozen oroot=$REPO shipprog=$FX/no-such-record phase=checks; eval "$(sed -n '/^dq() {/,/^}/p' "$RS")"; eval "$(sed -n '/^gkhint() {/,/^}/p' "$RS")"; gkhint /x/a.tar.gz Sheepr.app)
printf '%s\n' "$gk1_" | grep -qF "ls-remote origin refs/tags/v0.1.0" && ! printf '%s\n' "$gk1_" | grep -qF 'move the build aside and rebuild it with a valid one.' \
  && printf '%s\n' "$gk2_" | grep -qF 'move the build aside and rebuild it with a valid one.' && ! printf '%s\n' "$gk2_" | grep -qF 'ls-remote origin' \
  && pass "r17b F4: gkhint with the record missing: after the push the ls-remote route, no rebuild; control: before the push the rebuild" \
  || fail "r17b F4, gkhint: github: $(printf '%s' "$gk1_" | tail -2 | tr '\n' '|' | cut -c1-160); checks: $(printf '%s' "$gk2_" | tail -1 | cut -c1-120)"
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
[ "$(grep -B1 'push --porcelain --atomic --no-follow-tags origin "\$@" 2> "\$st/push.err"); pr_=\$?' "$RS" | head -1)" = '  progress "start push"' ] && pass "'start push' is written directly before the real push" || fail "start push: $(grep -B1 'push --porcelain --atomic --no-follow-tags origin' "$RS" | head -1)"
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
# the progress file cannot take 'start push': no push (the record is replaced through a temp file beside
# it: a directory at the temp name makes the write fail; a read-only record no longer does, REV 12b rule 21)
cat > "$FX/onbuild" <<EOF
mkdir "$OUTR/.v0.1.0.ship-progress.tmp"
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

# --- the exit handler: the stop text (to its file, then stdout), the logout of P, one
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
# a success whose logout fails (exit 1): no done, one logout-failed, exit 1; P kept; the text: ship's
# session could not be ended, the clock time it ends by itself, and that the next run logs out of it
# first (REV 12 rule 4: no npm command)
hm() { sed -E 's/[0-9]{2}:[0-9]{2} [A-Za-z0-9+-]+ on [0-9]{4}-[0-9]{2}-[0-9]{2}/HH:MM ZONE on DATE/g'; }   # the session's clock time and its zone, normalized
hasblk() { # FILE TEXT: FILE (its clock times normalized) holds TEXT's lines, whole and in a row
  f_=$(printf '\001'; hm < "$1" | tr '\n' '\001'); b_=$(printf '\001%s\001' "$2" | tr '\n' '\001')
  case $f_ in *"$b_"*) return 0 ;; esac; return 1
}
PL_TEXT="ship logged in to npm in this run, with its own file ($PP), and logs out as it ends. If that logout fails, the session ends by itself at HH:MM ZONE on DATE (2 hours after its login), and the next ship or publish-npm run of v0.1.0 with this out dir logs out of it first."
LEFT_TEXT="ship's npm session (its own file, $PP) could not be ended. It ends by itself at HH:MM ZONE on DATE (2 hours after its login). The next ship or publish-npm run of v0.1.0 with this out dir logs out of it first; a run of another version does not. There is nothing to run by hand"
: > "$FX/logoutfail"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/logoutfail"
[ $r = 1 ] && grep -q 'is public on GitHub, Homebrew and npm' "$FX/o" && [ "$(nots)" = "npm-login npm-approve npm-approve-again logout-failed " ] && hasblk "$FX/o" "release: $LEFT_TEXT" \
  && [ "$(head -1 "$NF" 2>/dev/null)" = "release: ship v0.1.0 is public on GitHub, Homebrew and npm; ship's npm session is left:" ] && [ "$(sed 1d "$NF" | hm)" = "$LEFT_TEXT" ] && [ "$(grep -c . "$NF")" = 2 ] \
  && grep -q '_authToken=npm_dry$' "$FX/npmrc.after" && gone \
  && pass "a success whose logout fails: exit 1, one logout-failed (no done); P kept; the session's own end and the next run's logout named; the next file keeps that text" || fail "success, logout fails: rc=$r '$(nots)' next: $(head -2 "$NF" 2>/dev/null | cut -c1-160 | tr '\n' '|') $(lastline)"
# a failure after the login: one logout, one failed-PHASE; the logout failing too: one notification naming both
: > "$FX/pubfail.sheepr"; rm -rf "${OUTR:?}"; ship; r=$?
[ $r = 1 ] && [ "$(grep -c '^npm logout' "$FX/calls")" = 1 ] && [ "$(nots)" = "npm-login npm-approve npm-approve-again failed-npm-main " ] && gone \
  && pass "a failure after the login: one logout, one notification (failed-npm-main)" || fail "failure after login: rc=$r '$(nots)' $(lastline)"
! grep -q "could not be ended" "$NF" "$FX/o" && [ "$(cat "$FX/pd.after")" = gone ] && pass "  control: a logout that ends ship's session (exit 0): D removed, no 'could not be ended'" || fail "  pubfail alone: a 'could not be ended' text, or D $(cat "$FX/pd.after")"
[ -z "$(sed -n '/^STOP$/,$p' "$FX/calls" | sed 1d | grep -v -e "^npm logout --registry=https://registry.npmjs.org/ --scope= --userconfig=$PP\$" -e '^notify ')" ] \
  && pass "  after the stop: no npm call but the logout of P (the stop text reads nothing)" || fail "  calls after the stop: $(sed -n '/^STOP$/,$p' "$FX/calls" | sed 1d | tr '\n' ' ')"
: > "$FX/logoutfail"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/logoutfail" "$FX/pubfail.sheepr"
[ $r = 1 ] && [ "$(nots)" = "npm-login npm-approve npm-approve-again logout-failed-npm-main " ] && [ "$(sed -n 2p "$NF" | hm)" = "$LEFT_TEXT" ] && gone \
  && pass "a failure, and the logout fails: one notification naming both; the next file's line 2 says the session ends by itself and the next run logs out of it" || fail "failure + logout fails: rc=$r '$(nots)' '$(sed -n 2p "$NF" 2>/dev/null | hm | cut -c1-200)'"
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

# the logout of ship's own session fails with ETIMEDOUT or E401 (REV 12 rule 4: any failure keeps P; the
# next run's logout of it decides): logout-failed, exit 1; npm's words, the session's own end and the
# next run's logout named; no npm command
for lc in ETIMEDOUT E401; do
  echo "$lc" > "$FX/logoutcode"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/logoutcode"
  [ $r = 1 ] && [ "$(nots)" = "npm-login npm-approve npm-approve-again logout-failed " ] && grep -q "ship's npm session (its own file, $PP) could not be ended (the logout's answer: npm error code $lc" "$FX/o" \
    && grep -qE "It ends by itself at [0-9]{2}:[0-9]{2}" "$FX/o" && grep -qi 'the next ship or publish-npm run of v0.1.0 with this out dir logs out of it first' "$FX/o" && ! grep -Eq "$NPMCMD" "$FX/o" "$NF" \
    && grep -q '_authToken=npm_dry$' "$FX/npmrc.after" \
    && pass "ship's logout failing with $lc: P kept; npm's words, the session's own end, the next run's logout; no npm command" \
    || fail "logout ${lc}: rc=$r '$(nots)' $(grep 'could not be ended' "$FX/o" | head -1 | cut -c1-240)"
done
# a logout that exits 0 and leaves a line in P (here a path-specific one): its exit decides; D removed, done
echo '//registry.npmjs.org/-/:_authToken=npm_pathline' > "$FX/logoutleaves"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/logoutleaves"
completed && [ "$(nots)" = "npm-login npm-approve npm-approve-again done " ] && ! grep -q "could not be ended" "$FX/o" && [ "$(cat "$FX/pd.after")" = gone ] \
  && pass "a logout that exits 0 but leaves a line in P: done, exit 0, D removed (the exit decides)" \
  || fail "line left after the logout: rc=$r '$(nots)' D $(cat "$FX/pd.after") $(grep 'could not be ended' "$FX/o" | cut -c1-200)"
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
  grep "could not be ended" "$FX/o" | grep -o 'ends by itself [^(]*(2 hours' | sort -u | tr '\n' '|'
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
# REV 10 rule 6 (r12a F8, F11), REV 12 rule 4: when ship logged in, its next file is written before its
# logout runs, with pl (ship logs out of its own file as it ends; no npm command) on line 2, and printed
# at once. A KILL to ship's group while the logout runs (the hook copies stdout first) leaves pl in the
# file and on stdout, after a stop (C8's upload refused) and after a release done
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
lnof() { grep -nF -e "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1; }   # FILE TEXT: the first line holding TEXT
PLS="ship logged in to npm in this run, with its own file ($PP)"   # (pl's start: REV 12 rule 4)
for k_ in stop done; do
  [ $k_ = stop ] && : > "$FX/pubfail.sheepr"
  printf 'sh "%s/killer" logout\n' "$FX" > "$FX/onlogout"; rm -f "$FX/o.atkill"
  rm -rf "${OUTR:?}"; SETSID=1; ship; r=$?; SETSID=; rm -f "${FX:?}/onlogout" "${FX:?}/pubfail.sheepr"
  lg=$(lnof "$NF" "$PLS"); lgo=$(lnof "$FX/o.atkill" "$PLS")
  if [ $k_ = stop ]; then h_='release: ship v0.1.0 stopped at npm-main'; else h_="release: ship v0.1.0 is public on GitHub, Homebrew and npm; ship's npm session is left:"; fi
  grep -q '^SIG KILL at logout$' "$FX/calls" && ! grep -q UNSAFE "$FX/calls" && [ "${lg:-0}" = 2 ] && [ -n "$lgo" ] && grep -q "^$h_" "$NF" && grep -q "^$h_" "$FX/o.atkill" \
    && ! grep -Eq "$NPMCMD" "$NF" "$FX/o.atkill" && grep -q '_authToken=npm_dry$' "$FX/npmrc.after" \
    && pass "r12a F8, F11, REV 12: a KILL while ship's logout runs ($k_): the next file's line 2 says ship logs out of its own file as it ends; stdout said it before the logout returned; P kept for the next run" \
    || fail "KILL in the logout ($k_): rc=$r $(grep -e '^SIG' -e UNSAFE "$FX/calls" | tr '\n' ' ') next file: line ${lg:-none}; stdout: ${lgo:-none}; $(head -2 "$NF" 2>/dev/null | cut -c1-150 | tr '\n' '|')"
  killclean
done
# a stop, and a logout that ends ship's session: the next file is the stop text alone (pl taken out);
# stdout named pl before the logout ran, then says the session is ended. Its control, the same run's text
# with no login (a stop before C4), has no pl. Then the class: no redirection opens the next file; every
# write is a temp file beside it, then a rename
: > "$FX/pubfail.sheepr"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/pubfail.sheepr"
DONE_L="release: ship's npm session is ended (its own file removed)."
[ $r = 1 ] && ! grep -qF "$PLS" "$NF" && grep -q '^release: ship v0.1.0 stopped at npm-main' "$NF" && [ "$(grep -c '^release:' "$NF")" = 1 ] \
  && [ -n "$(lnof "$FX/o" "$PLS")" ] && [ "$(grep -n . "$FX/o" | grep -F "$DONE_L" | cut -d: -f1)" -gt "$(lnof "$FX/o" "$PLS")" ] && gone \
  && pass "a stop and a logout that ends ship's session: the next file without pl; stdout named it before the logout, then that the session is ended" \
  || fail "stop + logout ends the session: rc=$r next file pl at $(lnof "$NF" "$PLS"); stdout pl at $(lnof "$FX/o" "$PLS"), ended line at $(lnof "$FX/o" "$DONE_L")"
PFL=$(tail -1 "$NF"); PFN=$(grep -c . "$NF")   # (the text after the logout: no pl)
rm -rf "${OUTR:?}"; : > "$FX/build.nomanifest"; ship; r=$?; rm -f "$FX/build.nomanifest"
[ $r = 1 ] && ! grep -qF "$PLS" "$NF" "$FX/o" && pass "  control: a stop before the login: no pl, in the file or on stdout" || fail "  no login: pl"
nfr_=$(grep -v '^ *#' "$SR_ROOT/scripts/release.sh" | grep -cE '>>? *"?\$nf"?([^.A-Za-z_]|$)'); nfm_=$(grep -v '^ *#' "$SR_ROOT/scripts/release.sh" | grep -cE 'mv -f "\$out/\.\$tag\.ship-next\.tmp" "\$nf"')
[ "$nfr_" = 0 ] && [ "$nfm_" = 1 ] && pass "the next file: no redirection opens it ($nfr_); one rename onto it, from the temp file beside it ($nfm_)" || fail "the next file: $nfr_ redirections open it; $nfm_ renames"
# r16b F2: bash 3.2's builtin printf keeps the bytes of a write to a file that failed (a full disk) and
# hands them to the next write (the stop line twice on stdout: r16b walk-nffull): no builtin printf or
# echo in release.sh or scripts/lib/*.sh writes to a file; each goes through /usr/bin/printf (a cell's
# record, SR_ASK_RECORD or SR_EXEC_RECORD, /dev/null in a real run, aside). Control: a planted one is
# caught. (The scanner: notes/builder/i3/census.py)
cat > "$FX/wcensus.py" <<'SR_CENSUS_EOF'
import sys, re
# census.py FILE...: each simple command whose program is the shell's builtin printf or echo (not
# /usr/bin/printf) with a redirection (> or >>) to a file: not /dev/null, not an fd (>&N), not /dev/tty.
# A small scanner: quotes ('', "") and $( ) / $(( )) / ${ } are skipped as one word; commands split at
# top-level ; & | && || { } ( ) and the words then, else, do, elif. Comment lines skipped; one line at a
# time (release.sh's writes are one-line commands). Prints FILE:LINE: text, then N
def commands(l):
    out, cur, i, n = [], '', 0, len(l)
    while i < n:
        ch = l[i]
        if ch == '#' and (i == 0 or l[i-1] in ' \t;'): break
        keep = cur.rstrip().endswith('>')   # a quoted word right after > is a target: kept; any other is blanked
        if ch == "'":
            j = l.find("'", i + 1); j = n - 1 if j < 0 else j; cur += l[i:j+1] if keep else 'Q'; i = j + 1; continue
        if ch == '"':
            j = i + 1; d = 0
            while j < n:
                if l[j] == '\\': j += 2; continue
                if l[j:j+2] == '$(': d += 1; j += 2; continue
                if l[j] == ')' and d: d -= 1; j += 1; continue
                if l[j] == '"' and not d: break
                j += 1
            cur += l[i:j+1] if keep else 'Q'; i = j + 1; continue
        if l[i:i+2] in ('$(', '${'):
            close = ')' if l[i+1] == '(' else '}'; opn = l[i+1]; d = 0; j = i + 1
            while j < n:
                if l[j] == opn: d += 1
                elif l[j] == close:
                    d -= 1
                    if d == 0: break
                j += 1
            cur += l[i:j+1]; i = j + 1; continue
        if ch == '\\': cur += l[i:i+2]; i += 2; continue
        if ch in ';&|{}()' and not (ch == '&' and cur.rstrip().endswith('>')):
            out.append(cur); cur = ''; i += 1; continue
        cur += ch; i += 1
    out.append(cur)
    res = []
    for c in out:
        w = c.strip()
        w = re.sub(r'^(then|else|do|elif)\s+', '', w)
        res.append(w)
    return res
n = 0
for f in sys.argv[1:]:
    for i, l in enumerate(open(f), 1):
        if l.strip().startswith('#'): continue
        for c in commands(l.rstrip('\n')):
            m = re.match(r'(?:[A-Za-z_][A-Za-z_0-9]*=\S*\s+)*(printf|echo)(\s|$)', c)
            if not m: continue
            hit = False
            for r in re.finditer(r'(?<![0-9<])(>>?)\s*(&?)("?)([^ "]*)', c):
                if r.group(2) == '&': continue
                tgt = r.group(4)
                if tgt in ('/dev/null', '/dev/tty') or tgt.startswith('&'): continue
                if 'SR_ASK_RECORD' in tgt or 'SR_EXEC_RECORD' in tgt: continue   # (a cell's record: /dev/null in a real run)
                hit = True
            if hit: print('%s:%d: %s' % (f, i, l.strip()[:170])); n += 1
print('N=%d' % n)
SR_CENSUS_EOF
wc_=$(python3 -I "$FX/wcensus.py" "$SR_ROOT/scripts/release.sh" "$SR_ROOT"/scripts/lib/*.sh)
awk '{ print } /^stopclass\(\) \{/ && !d { print "  printf %s x > \"$shipcls.planted\""; d = 1 }' "$SR_ROOT/scripts/release.sh" > "$FX/rs-planted.sh"
wp_=$(python3 -I "$FX/wcensus.py" "$FX/rs-planted.sh")
[ "$(printf '%s\n' "$wc_" | tail -1)" = N=0 ] && [ "$(printf '%s\n' "$wp_" | tail -1)" = N=1 ] \
  && pass "r16b F2: no builtin printf or echo in release.sh or scripts/lib/*.sh writes to a file (all through /usr/bin/printf); control: a planted one is caught" \
  || fail "r16b F2, the builtin writes: $(printf '%s' "$wc_" | tr '\n' '|' | cut -c1-400); planted: $(printf '%s' "$wp_" | tail -1)"
rm -f "${FX:?}/wcensus.py" "${FX:?}/rs-planted.sh"
# r18b F1 (REV 12c rule 30): a failed builtin write (a full disk, a read-only or hung-up stdout) leaves its
# bytes in bash 3.2's buffer, and the shell's next $( ) gets them first: release.sh's echo and printf are
# the two wrappers (the builtin through `command`, and when its write fails, the same write to /dev/null,
# which empties the buffer and gives the call's status), the first lines that name either; no other line
# names the builtin. Controls: a copy with a planted
# `command echo`, and one without the wrappers: each is caught
wwrap() { # FILE: ok, or what is wrong
  grep -v '^ *#' "$1" | grep -E '(^|[^A-Za-z0-9_./-])(echo|printf)([^A-Za-z0-9_.-]|$)' | head -2 > "$FX/ww.first"
  printf '%s\n' 'echo() { command echo "$@" || command echo "$@" > /dev/null 2>&1; }' \
    'printf() { command printf "$@" || command printf "$@" > /dev/null 2>&1; }' > "$FX/ww.want"
  cmp -s "$FX/ww.first" "$FX/ww.want" || { echo "the first lines that name echo or printf are not the wrappers: $(tr '\n' '|' < "$FX/ww.first" | cut -c1-200)"; return 0; }
  o_=$(grep -v '^ *#' "$1" | grep -E 'command +(echo|printf)|builtin ' | grep -vxF -f "$FX/ww.want" | head -1)
  [ -z "$o_" ] || { echo "the builtin named outside the wrappers: $o_"; return 0; }
  echo ok
}
awk '{ print } /^stopclass\(\) \{/ && !d { print "  command echo x"; d = 1 }' "$SR_ROOT/scripts/release.sh" > "$FX/ww-planted.sh"
grep -v -e '^echo() {' -e '^printf() {' "$SR_ROOT/scripts/release.sh" > "$FX/ww-nowrap.sh"
ww_=$(wwrap "$SR_ROOT/scripts/release.sh"); wp_=$(wwrap "$FX/ww-planted.sh"); wn_=$(wwrap "$FX/ww-nowrap.sh")
[ "$ww_" = ok ] && [ "$wp_" != ok ] && [ "$wn_" != ok ] \
  && pass "r18b F1: release.sh's echo and printf are the draining wrappers, the first lines that name either; no other line names the builtin; controls: a planted one, and none, each caught" \
  || fail "r18b F1, the wrappers: '$ww_'; planted: '$wp_'; none: '$wn_'"
rm -f "${FX:?}/ww.first" "${FX:?}/ww.want" "${FX:?}/ww-planted.sh" "${FX:?}/ww-nowrap.sh"
# r18b F1: ship's stdout open read-only (every builtin write to it fails, EBADF, as on a full disk): a fresh
# run, and a run on a finished build, complete as with a writable stdout: exit 0, the release's
# notifications, no next file, its lock, tree and temp dirs gone, no "Move". (Before: a failed write's
# bytes came first in the next $( ) that a check reads: a good build stopped as content, "Move aside",
# and false causes at A1 and A2; r18b walk-leak2h L2b, probe/ro1.out)
for k_ in fresh built; do
  rm -rf "${OUTR:?}"; [ $k_ = fresh ] || mkbuild "$OUTR/v0.1.0" v0.1.0 "$C"
  CLOSEFD=ro; ship; r=$?; CLOSEFD=
  [ $r = 0 ] && [ "$(nots)" = "npm-login npm-approve npm-approve-again done " ] && [ ! -e "$NF" ] && gone && ! grep -q 'Move' "$FX/o" \
    && pass "r18b F1: fd 1 read-only, a $k_ run: done (0), as with a writable stdout" \
    || fail "r18b F1: fd 1 read-only, a $k_ run: rc=$r notifications [$(nots)] next file $( [ -e "$NF" ] && head -3 "$NF" | tr '\n' '|' | cut -c1-300); stderr: $(grep -v -e '(dry)' -e 'a temp HOME' "$FX/o" | head -3 | tr '\n' '|' | cut -c1-300)"
done
rm -f "${FX:?}/ro"
# r17b F1, F2 (REV 12b rule 20): every redirection to a file in the release scripts (release.sh,
# scripts/lib/*.sh, bundle.sh, release-plan.sh; a compound command's too: `done >`, `} >`) is a write that
# proves its bytes (fput, fout, read back on its line) or one kept with its reason; each reason is used.
# Controls: a planted `done > "$st/x"`, a planted gh answer into a file, and a rule no write uses: each
# refused. (The scanner: notes/builder/r17/redir17.py)
cat > "$FX/redir.py" <<'SR_CENSUS_EOF'
import sys, re, os
# redir17.py [--rules] FILE...: every redirection of an fd to a file in the given sh files, read as the
# shell reads them: quotes (one context per '' and ""; a $( ) inside "" is code again), $(( )) skipped,
# comments, heredoc bodies skipped; a compound command's redirection (`done >`, `} >`, `) >`) counts as
# any other. A target /dev/null or /dev/tty, or an fd dup (>&N, >&-), is not a file. Prints
# "FILE:LINE: fdN OP TARGET || the line", then N=. With --rules: each one must match a rule of RULES
# below (a write that proves its bytes, or one kept with its reason), every rule must match one, and
# the unmatched and unused are printed; exit 1 when there is either (REV 12b rule 20).
def scan(path):
    src = open(path).read()
    hits = []; i = 0; n = len(src); line = 1
    stack = ['N']; depth = [0]; hd = []   # contexts; paren depth per N context; pending heredoc words
    word_start = True
    while i < n:
        ch = src[i]; top = stack[-1]
        if ch == '\n':
            line += 1; i += 1; word_start = True
            if hd and top == 'N' and len(stack) == 1:
                # heredoc bodies follow this line: skip each until its word alone (<<- strips tabs)
                for w, strip in hd:
                    while i < n:
                        j = src.find('\n', i); j = n if j < 0 else j
                        l = src[i:j]; i = j + 1; line += 1
                        if (l.lstrip('\t') if strip else l) == w: break
                hd = []
            continue
        if top == 'S':
            if ch == "'": stack.pop(); depth.pop()
            i += 1; continue
        if top == 'A':
            if src.startswith('))', i): stack.pop(); depth.pop(); i += 2; continue
            i += 1; continue
        if top == 'D':
            if ch == '\\': i += 2; continue
            if ch == '"': stack.pop(); depth.pop(); i += 1; continue
            if src.startswith('$((', i): stack.append('A'); depth.append(0); i += 3; continue
            if src.startswith('$(', i): stack.append('N'); depth.append(0); i += 2; word_start = True; continue
            i += 1; continue
        # N
        if ch == '\\': i += 2; word_start = False; continue
        if ch == '#' and word_start:
            j = src.find('\n', i); i = n if j < 0 else j; continue
        if ch == "'": stack.append('S'); depth.append(0); i += 1; word_start = False; continue
        if ch == '"': stack.append('D'); depth.append(0); i += 1; word_start = False; continue
        if src.startswith('$((', i): stack.append('A'); depth.append(0); i += 3; word_start = False; continue
        if src.startswith('$(', i): stack.append('N'); depth.append(0); i += 2; word_start = True; continue
        if ch == '(':
            depth[-1] += 1; i += 1; word_start = True; continue
        if ch == ')':
            if depth[-1] == 0 and len(stack) > 1: stack.pop(); depth.pop()
            elif depth[-1] > 0: depth[-1] -= 1
            i += 1; word_start = True; continue
        if src.startswith('<<', i) and not src.startswith('<<<', i):
            m = re.match(r'<<(-?)\s*([\'"]?)([A-Za-z_][A-Za-z_0-9]*)\2', src[i:])
            if m: hd.append((m.group(3), m.group(1) == '-')); i += m.end(); continue
        m = re.match(r'(\d*)(>>|>\||>)(?!&)', src[i:])
        if m and (i == 0 or src[i-1] not in '<>&'):
            fd = m.group(1) or '1'; op = m.group(2); j = i + m.end()
            while j < n and src[j] in ' \t': j += 1
            k = j; q = None; tgt = ''
            while k < n:
                c = src[k]
                if q:
                    if c == q: q = None; k += 1; continue
                    if c == '\\' and q == '"': tgt += src[k:k+2]; k += 2; continue
                    tgt += c; k += 1; continue
                if c in '\'"': q = c; k += 1; continue
                if c in ' \t\n;&|)<>': break
                if src.startswith('$(', k):
                    d = 0; s0 = k
                    while k < n:
                        if src[k] == '(': d += 1
                        elif src[k] == ')':
                            d -= 1
                            if d == 0: break
                        k += 1
                    tgt += src[s0:k+1]; k += 1; continue
                tgt += c; k += 1
            if tgt not in ('/dev/null', '/dev/tty') and not tgt.startswith('&'):
                ls = src.rfind('\n', 0, i) + 1; le = src.find('\n', i); le = n if le < 0 else le
                hits.append((os.path.basename(path), line, fd, op, tgt, src[ls:le].strip()))
            i = k; word_start = False; continue
        word_start = ch in ' \t;&|{}'
        i += 1
    return hits

# RULES: (file, target, reason[, a regex the line must match]). '*' as file: any file; 'fd2' as
# target: any target on fd 2. Each a write that proves its bytes, or one kept as it is, with why
RB = 'read back on its line (cmp), before it is used'
RULES = [
    ('*', 'fd2', "a tool's words on fd 2 (a cause, npm's code, a judged refusal line): a lost one makes a stop name no code, never a verdict"),
    ('release.sh', '$f_', 'fput and fout themselves: the bytes read back'),
    ('*', '${SR_ASK_RECORD:-/dev/null}', "a cell's record (/dev/null in a real run)"),
    ('exec-guard.sh', '$SR_EXEC_RECORD', "a cell's record (unset in a real run)"),
    ('release.sh', '$pt/npmrc', 'an empty file (no byte to lose)', r':\s*>\s*"\$pt/npmrc"'),
    ('npm-pack.sh', '$pk/npmrc', 'an empty file (no byte to lose)', r':\s*>\s*"\$pk/npmrc"'),
    ('npm-pack.sh', '$pk/globalrc', 'an empty file (no byte to lose)', r':\s*>\s*"\$pk/globalrc"'),
    ('archive.sh', '$t/list', "the listing's end line read back (tail): a short listing is \"cannot check\""),
    ('realtools.sh', '$o_', "an Apple tool's words: none is no verdict (rt_judge)"),
    ('release.sh', '$pt/plan', "--validate compares the whole plan with its one shape: a short one refuses"),
    ('release.sh', '$pt/assets', 'the exact-five check reads it whole: a short list refuses'),
    ('release.sh', '$pt/dl', 'a download, hashed: a short one refuses'),
    ('release.sh', '$ct/tap.rb', "the tap's raw bytes (their blob id is the write's base): a short file has no version line, is not the cask, or GitHub refuses the write"),
    ('release.sh', '$ct/rel', 'the draft flag and exactly one asset id: a short file refuses'),
    ('release.sh', '$ct/dl', 'a download, hashed: a short one refuses'),
    ('release.sh', '$ct/brew', 'a download, hashed: a short one refuses'),
    ('release.sh', '$ct/back', "the cask read back, compared whole with the one put: a short one refuses"),
    ('release.sh', '$st/dry', 'compared whole with the refspecs ship pushes: a short one refuses'),
    ('release.sh', '$out/.$tag.ship-next.tmp', RB, r'cmp -s - "\$out/\.\$tag\.ship-next\.tmp"'),
    ('sign.sh', '$dest/notary-profile.txt', "the operator's record of notarytool's answer: nothing reads it"),
    ('sign.sh', '$dest/notary-submit.json', "the operator's record of notarytool's answer: nothing reads it (the run reads the variable)"),
    ('sign.sh', '$dest/notary-log.json', "the operator's record of notarytool's log: nothing reads it"),
    ('bundle.sh', '$app/Contents/Info.plist', '/bin/cat exits 1 when a full disk took its bytes (measured, r17b)', r'cat > "\$app/Contents/Info\.plist" <<EOF \|\| exit 1'),
    ('release-plan.sh', '$tmp', "validate reads the whole plan before it is printed: a short one refuses"),
    ('npm-pack.sh', '$pk/main/package.json', RB, r'cmp -s - "\$pk/main/package\.json"'),
    ('npm-pack.sh', '$pk/darwin/package.json', RB, r'cmp -s - "\$pk/darwin/package\.json"'),
    ('npm-pack.sh', '$pk/linux-$a/package.json', RB, r'cmp -s - "\$pk/linux-\$a/package\.json"'),
    ('render-cask.sh', '$o.tmp', RB, r'cmp -s - "\$o\.tmp"'),
    ('render-install.sh', '$outf.tmp', RB, r'cmp -s - "\$outf\.tmp"'),
]
def match(h, r):
    f, tgt = r[0], r[1]
    if f != '*' and f != h[0]: return False
    if tgt == 'fd2': return h[2] == '2'
    if h[2] != '1' or h[4] != tgt: return False
    return len(r) < 4 or re.search(r[3], h[5]) is not None
args = sys.argv[1:]; rules = args[:1] == ['--rules']
if rules: args = args[1:]
hits = [h for p in args for h in scan(p)]
bad = 0; used = set()
for h in hits:
    m = [k for k, r in enumerate(RULES) if match(h, r)]
    used.update(m)
    if rules and not m:
        print('UNLISTED %s:%d: fd%s%s %s || %s' % (h[0], h[1], h[2], h[3], h[4], h[5][:160])); bad += 1
    elif not rules:
        print('%s:%d: fd%s%s %s || %s' % (h[0], h[1], h[2], h[3], h[4], h[5][:160]))
if rules:
    for k, r in enumerate(RULES):
        if k not in used: print('UNUSED %s %s' % (r[0], r[1])); bad += 1
print('N=%d UNLISTED+UNUSED=%d' % (len(hits), bad))
sys.exit(1 if rules and bad else 0)
SR_CENSUS_EOF
RF_="$SR_ROOT/scripts/release.sh $SR_ROOT/scripts/lib/*.sh $SR_ROOT/scripts/bundle.sh $SR_ROOT/scripts/release-plan.sh"
rc_=$(python3 -I "$FX/redir.py" --rules $RF_); rr_=$?
mkdir -p "$FX/pl" || exit 3
awk '{ print } /^ship_tap\(\) \{/ && !d { print "  for x in a b; do echo $x; done > \"$st/planted\""; print "  tool \"$NETC\" \"$GH\" api repos/lukaso/sheepr/releases > \"$st/rels2\""; d = 1 }' "$SR_ROOT/scripts/release.sh" > "$FX/pl/release.sh"
rp_=$(python3 -I "$FX/redir.py" --rules "$FX/pl/release.sh" $(printf '%s\n' $RF_ | grep -v '/release\.sh$'))
sed 's/^    (.release-plan.sh., .\$tmp., /    ("release-plan.sh", "$nosuch", /' "$FX/redir.py" > "$FX/redir-stale.py"
rs_=$(python3 -I "$FX/redir-stale.py" --rules $RF_)
[ $rr_ = 0 ] && [ "$(printf '%s\n' "$rp_" | grep -c '^UNLISTED')" = 2 ] \
  && [ "$(printf '%s\n' "$rp_" | grep -c '^UNLISTED release.sh:[0-9]*: fd1> $st/planted ')" = 1 ] && [ "$(printf '%s\n' "$rp_" | grep -c '^UNLISTED release.sh:[0-9]*: fd1> $st/rels2 ')" = 1 ] \
  && printf '%s\n' "$rs_" | grep -q '^UNUSED release-plan.sh \$nosuch$' && printf '%s\n' "$rs_" | grep -q '^UNLISTED release-plan.sh:[0-9]*: fd1> \$tmp ' \
  && pass "r17b F1, F2: every redirection to a file in the release scripts proves its bytes or is kept with its reason ($(printf '%s\n' "$rc_" | tail -1)); controls: a planted done > file, a gh answer into a file, a stale rule: each refused" \
  || fail "r17b F1, F2, the write census: $(printf '%s' "$rc_" | grep -e UNLISTED -e UNUSED | tr '\n' '|' | cut -c1-600); controls: $(printf '%s\n' "$rp_" | grep -c '^UNLISTED') planted, stale: $(printf '%s\n' "$rs_" | grep -c '^UNUSED')"
rm -rf "${FX:?}/redir.py" "${FX:?}/redir-stale.py" "${FX:?}/pl"
# r17b F1: fput and fout themselves (release.sh's own, read from it): a write that lands nothing (a link
# to /dev/null takes the bytes and exits 0, as /usr/bin/printf does on a full disk: measured,
# notes/builder/i17/wprobe.out) answers 1; control: a file answers 0 and holds exactly the bytes
eval "$(grep '^fput() {' "$RS")"; eval "$(grep '^fout() {' "$RS")"
ln -s /dev/null "$FX/nul.lnk" && : > "$FX/real.f" || exit 3
fput "$FX/nul.lnk" 'stamp %s\n' v0.1.0; a_=$?
fput "$FX/real.f" 'stamp %s\n' v0.1.0; b_=$?
fout "$FX/nul.lnk" /bin/echo x; c_=$?
fout "$FX/real.o" /bin/echo x; d_=$?
[ $a_ = 1 ] && [ $b_ = 0 ] && [ "$(cat "$FX/real.f")" = 'stamp v0.1.0' ] && [ $c_ = 1 ] && [ $d_ = 0 ] && [ "$(cat "$FX/real.o")" = x ] \
  && pass "r17b F1: fput and fout answer 1 for a write that landed nothing (a link to /dev/null); control: a file, 0 and its bytes" \
  || fail "r17b F1, fput/fout: link fput=$a_ fout=$c_ (want 1); file fput=$b_ fout=$d_ (want 0) '$(cat "$FX/real.f" 2>/dev/null)' '$(cat "$FX/real.o" 2>/dev/null)'"
rm -f "${FX:?}/nul.lnk" "${FX:?}/real.f" "${FX:?}/real.o"; unset -f fput fout 2>/dev/null
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
grep -q '^SIG KILL at mv$' "$FX/calls" && ! grep -q UNSAFE "$FX/calls" && grep -q '^release: ship v0.1.0 stopped at npm-main' "$NF" && [ "$(lnof "$NF" "$PLS")" = 2 ] \
  && [ "$(tail -1 "$NF")" = "$PFL" ] && [ "$(grep -c . "$NF")" = "$((PFN + 1))" ] && ! grep -qF "$PLS" "$OUTR/.v0.1.0.ship-next.tmp" && [ "$(head -1 "$OUTR/.v0.1.0.ship-next.tmp")" = "$(head -1 "$NF")" ] \
  && pass "a KILL at the rename after the logout: the next file whole, as written before the logout ($PFN lines and pl); the new text in the temp file beside it" \
  || fail "KILL at the rewrite: rc=$r $(grep -e '^SIG' -e UNSAFE "$FX/calls" | tr '\n' ' ') next file: $(grep -c . "$NF" 2>/dev/null) lines, pl at $(lnof "$NF" "$PLS"), last '$(tail -1 "$NF" 2>/dev/null | cut -c1-80)'"
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
  [ $r = 1 ] && grep -q "could not be ended" "$FX/o" && grep -q '/-/user/token/' "$FX/o" && ! grep -qF "$tk_" "$FX/o" && ! grep -qF "$tk_" "$NF" \
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
# (r13a F5, REV 12 rule 4) pl exactly, as ship prints it at once and puts it on the next file's line 2
# before the logout runs; a stop after the login, the logout ending ship's session
: > "$FX/pubfail.sheepr"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/pubfail.sheepr"
[ $r = 1 ] && hasblk "$FX/o" "$PL_TEXT" \
  && pass "r13a F5: the logout step's text, exactly (printed before the logout ran)" || fail "the logout step's text: '$(grep -m1 'ran npm login\|logged in to npm' "$FX/o" | hm | cut -c1-300)'"
# (r13a X3) the login takes 10 minutes (a browser approval): the session's end is 2 hours after the
# login RETURNED. A date stand-in first in PATH answers +%s from $FX/epoch; the login's hook moves it on
cat > "$B/date" <<EOD
#!/bin/sh
if [ "\$1" = +%s ] && [ -s "$FX/epoch" ]; then cat "$FX/epoch"; exit 0; fi
exec /bin/date "\$@"
EOD
chmod +x "$B/date"
E_=$(/bin/date +%s); echo "$E_" > "$FX/epoch"; printf 'echo %s > "%s/epoch"\n' "$((E_ + 600))" "$FX" > "$FX/onlogin"
echo ETIMEDOUT > "$FX/logoutcode"; rm -rf "${OUTR:?}"; SETX=TZ=UTC; KEEPP=1; ship; r=$?; KEEPP=; SETX=; rm -f "${FX:?}/logoutcode" "${FX:?}/onlogin" "${FX:?}/epoch" "${FX:?}/npmrc" "${B:?}/date"
de_=$(cat "$PD/end" 2>/dev/null); rm -rf "${PD:?}"
[ "$de_" = "$((E_ + 600 + 7200))" ] && pass "r17a P4-g: D/end holds the login's return + 2 hours (the login took 10 minutes)" || fail "r17a P4-g, D/end: '$de_', want $((E_ + 600 + 7200))"
w_=$(TZ=UTC /bin/date -r "$((E_ + 600 + 7200))" '+%H:%M %Z on %Y-%m-%d'); g_=$(grep "could not be ended" "$FX/o" | grep -o 'ends by itself at [^(]*' | head -1)
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
# REV 11b rule 15 (r15b P3-1, P4-5, P4-6): when the next file cannot be written, no earlier text stays
# at its name: ship removes it and stdout says so; what it cannot remove (a directory there) stdout
# calls not these steps. r15b N1: run 1 stops before the push (its file names ship again); run 2 stops
# after the push and cannot write its file. N5: a directory at the file's name (mv would put the text
# inside it): not written. Control N0: every write works. r16b F3, REV 12: a REWRITE after the logout
# that fails keeps this run's own file, written before the logout (its line 2, pl, holds whatever the
# logout did), and stdout never calls this run's file earlier: N2, the logout ended the session; N3, a
# stop and the logout failed (ETIMEDOUT); N4, a release done and the logout failed
TMPN=$OUTR/.v0.1.0.ship-next.tmp
for k_ in N1 N2 N3 N4 N5 N0; do
  rm -rf "${OUTR:?}"
  case $k_ in
    N1) : > "$FX/loginfail"; ship; r1_=$?; rm -f "${FX:?}/loginfail"; grep -q 'stopped at npm-login' "$NF" || fail "  N1: run 1 left no next file (the row would prove nothing)"
        : > "$FX/pubfail.sheepr"; printf 'mkdir -p "%s"\n' "$TMPN" > "$FX/onlogin" ;;
    N2) : > "$FX/pubfail.sheepr"; printf 'mkdir -p "%s"\n' "$TMPN" > "$FX/onlogout" ;;
    N3) : > "$FX/pubfail.sheepr"; echo ETIMEDOUT > "$FX/logoutcode"; printf 'mkdir -p "%s"\n' "$TMPN" > "$FX/onlogout" ;;
    N4) echo ETIMEDOUT > "$FX/logoutcode"; printf 'mkdir -p "%s"\n' "$TMPN" > "$FX/onlogout" ;;
    N5) mkdir -p "$NF" || exit 3; : > "$FX/pubfail.sheepr" ;;
    N0) : > "$FX/pubfail.sheepr" ;;
  esac
  ship; r=$?; rm -f "${FX:?}/pubfail.sheepr" "${FX:?}/onlogin" "${FX:?}/onlogout" "${FX:?}/logoutcode"; rmdir "$TMPN" 2>/dev/null
  nt_=$(grep -e '^notify failed-' -e '^notify logout-failed' "$FX/calls" | sed 's/^notify [^ ]* v0\.1\.0 //')
  case $k_ in
    N1) [ $r = 1 ] && [ ! -e "$NF" ] && [ "$nt_" = - ] && grep -qF "release: (the next file, $NF, could not be written: these steps are only here. ship removed the earlier next file that was there)" "$FX/o" \
        && pass "REV 11b rule 15 (r15b N1): the next file not written: the earlier one (run 1's) removed, and stdout says so; the notification names none" \
        || fail "rule 15 (N1): rc=$r; at the name: $(ls -ld "$NF" 2>/dev/null | cut -c1-60) $(head -1 "$NF" 2>/dev/null | cut -c1-100); stdout: $(grep -e 'these steps' -e 'could not be written' "$FX/o" | tr '\n' '|' | cut -c1-200)" ;;
    N2|N3|N4)
        if [ $k_ = N4 ]; then h_="release: ship v0.1.0 is public on GitHub, Homebrew and npm; ship's npm session is left:"; else h_='release: ship v0.1.0 stopped at npm-main'; fi
        [ $r = 1 ] && [ -f "$NF" ] && [ ! -L "$NF" ] && head -1 "$NF" | grep -qF "$h_" && sed -n 2p "$NF" | grep -qF "$PLS" && [ "$nt_" = "$OUTR" ] \
          && grep -qF "release: (the next file, $NF, could not be rewritten after the logout: it holds these steps as this run wrote them before the logout)" "$FX/o" \
          && ! grep -q -e 'earlier next file' -e 'these steps are only here' "$FX/o" \
          && pass "r16b F3 ($k_): a rewrite after the logout that fails keeps this run's own file (pl on its line 2); stdout says so and calls nothing earlier; the notification names the file" \
          || fail "r16b F3 ($k_): rc=$r notify '$nt_'; at the name: $(ls -ld "$NF" 2>/dev/null | cut -c1-60) $(head -2 "$NF" 2>/dev/null | cut -c1-90 | tr '\n' '|'); stdout: $(grep -e 'these steps' -e 'could not be' "$FX/o" | tr '\n' '|' | cut -c1-260)" ;;
    N5) [ $r = 1 ] && [ -d "$NF" ] && [ "$nt_" = - ] && ! grep -q 'these steps are also in' "$FX/o" \
        && grep -qF "release: (the next file, $NF, could not be written: these steps are only here. What is at $NF is not these steps: do not use it)" "$FX/o" \
        && pass "REV 11b rule 15 (r15b N5): a directory at the next file's name: not written, the notification names none, stdout says what is there is not these steps" \
        || fail "rule 15 (N5): rc=$r notify '$nt_'; stdout: $(grep -e 'these steps' -e 'could not be written' "$FX/o" | tr '\n' '|' | cut -c1-200)"
        rm -rf "${NF:?}" ;;
    N0) [ $r = 1 ] && [ -f "$NF" ] && grep -qF "release: (these steps are also in $NF)" "$FX/o" && [ "$nt_" = "$OUTR" ] \
        && pass "  control (r15b N0): every write works: the next file written, stdout says so, the notification names the out dir" || fail "  rule 15 control: rc=$r notify '$nt_' $(grep 'these steps' "$FX/o" | tr '\n' '|')" ;;
  esac
  world_reset; rm -f "${FX:?}/npmrc"
done
rm -rf "${OUTR:?}"
# r16b F4: nfput's temp name: what is there goes first, so no write goes through it. A symlink there to
# a file outside the out dir (made at C4's login, before the first write): that file unchanged, the next
# file a regular file with the stop text, stdout claims no earlier file. Control: no link
TMPN=$OUTR/.v0.1.0.ship-next.tmp
for k_ in link nolink; do
  # (each pass makes the outside file again: the control measures on its own, not after the link pass)
  rm -rf "${OUTR:?}"; printf 'outside, unchanged\n' > "$FX/outside"; s5_=$(cksum < "$FX/outside"); : > "$FX/pubfail.sheepr"
  [ $k_ = link ] && printf 'ln -s "%s" "%s"\n' "$FX/outside" "$TMPN" > "$FX/onlogin"
  ship; r=$?; rm -f "${FX:?}/pubfail.sheepr" "${FX:?}/onlogin"
  [ $r = 1 ] && [ -f "$NF" ] && [ ! -L "$NF" ] && grep -q '^release: ship v0.1.0 stopped at npm-main' "$NF" && [ "$(cksum < "$FX/outside")" = "$s5_" ] \
    && grep -qF "release: (these steps are also in $NF)" "$FX/o" && ! grep -q 'earlier next file' "$FX/o" && [ ! -e "$TMPN" ] && [ ! -L "$TMPN" ] \
    && pass "$( [ $k_ = nolink ] && echo '  control (no link): ' || echo 'r16b F4: a symlink at the temp name to a file outside: ')the outside file unchanged; the next file a regular file with the stop text; no earlier file claimed" \
    || fail "r16b F4 ($k_): rc=$r outside $( [ "$(cksum < "$FX/outside")" = "$s5_" ] && echo same || echo CHANGED); at the name: $(ls -ld "$NF" 2>/dev/null | cut -c1-80); stdout: $(grep -e 'these steps' -e 'could not be' "$FX/o" | tr '\n' '|' | cut -c1-200)"
  world_reset
done
rm -f "${FX:?}/outside"
# r16b MNFL: nfput's own check that the rename left a regular file, not a link: a mv stand-in that, after
# it renames onto the next file, puts a link there (to the moved file) stands in for any other way the
# name ends up a link: not written, stdout says so (no 'also in', no earlier file claimed), the link gone
cat > "$B/mv" <<EOS
#!/bin/sh
for a_; do l_=\$a_; done
/bin/mv "\$@" || exit \$?
[ "\$l_" = "$NF" ] && [ -e "$FX/mvlink" ] && { /bin/mv "$NF" "$FX/mvlink.real"; ln -s "$FX/mvlink.real" "$NF"; }
exit 0
EOS
chmod +x "$B/mv"; : > "$FX/mvlink"; : > "$FX/pubfail.sheepr"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/pubfail.sheepr" "${FX:?}/mvlink" "${B:?}/mv"
[ $r = 1 ] && [ ! -e "$NF" ] && [ ! -L "$NF" ] && grep -qF "release: (the next file, $NF, could not be written: these steps are only here)" "$FX/o" && ! grep -q -e 'these steps are also in' -e 'earlier next file' "$FX/o" \
  && pass "r16b MNFL: the rename leaves a link at the next file's name: nfput refuses it (not written, the link removed); stdout says so and claims no earlier file" \
  || fail "r16b MNFL: rc=$r at the name: $(ls -ld "$NF" 2>/dev/null | cut -c1-80); stdout: $(grep -e 'these steps' -e 'could not be' "$FX/o" | tr '\n' '|' | cut -c1-200)"
rm -f "${FX:?}/mvlink.real"; world_reset; rm -rf "${OUTR:?}"
# --- REV 12 (r16a F1-F3): ship's own npm file. D = $OUTR/.v0.1.0.npm (0700), P = D/npmrc: every npm
# call ship makes loads P and names it (--userconfig=P); ship never reads or writes
# NPM_CONFIG_USERCONFIG's file, npm_config_userconfig's or the HOME's .npmrc; it logs out of an earlier
# P before its login, logs in to P, and logs out of P as it ends; it prints no npm command
: > "$FX/r12out"
decoys() { # the operator's npm files, each with a live line (NPM_CONFIG_USERCONFIG's in every spelling of a
  # login npm reads, a scope routed to another registry, and npm's heading)
  printf '//registry.npmjs.org/:_authToken=npm_decoyENV\n//registry.npmjs.org/-/:_authToken=npm_decoyPATH\n//registry.npmjs.org/:_auth=bHVrYXNjbzpwdw==\n//registry.npmjs.org/:username=lukasco\n//registry.npmjs.org/:_password=cHc=\nscope=@acme\n@acme:registry=https://npm.acme.example/\n//npm.acme.example/:_authToken=npm_acmeB\nheading=xyz\n' > "$FX/npmrc"
  printf '//registry.npmjs.org/:_authToken=npm_decoyLOW\n' > "$FX/low.npmrc"
  printf '//registry.npmjs.org/:_authToken=npm_decoyHOME\n' > "$FX/ghome/.npmrc"
}
dsum() { cat "$FX/npmrc" "$FX/low.npmrc" "$FX/ghome/.npmrc" 2>/dev/null | cksum; }
r12keep() { cat "$FX/o" "$NF" >> "$FX/r12out" 2>/dev/null; }   # the texts, for the census row
# rule 1: a success, and a stop at each npm phase (the login, a platform upload, the main upload) and
# at GitHub's upload: the decoys byte-identical, every npm call P's, no decoy token sent
bd_=""
for k_ in done login platform main github; do
  decoys; s0_=$(dsum); : > "$FX/tokops"; rm -f "$FX/reqs"
  case $k_ in login) : > "$FX/loginfail" ;; platform) : > "$FX/pubfail.sheepr-linux-arm64" ;; main) : > "$FX/pubfail.sheepr" ;; github) : > "$FX/uploadfail" ;; esac
  rm -rf "${OUTR:?}"; SETX="npm_config_userconfig=$FX/low.npmrc"; KEEP=1; ship; r=$?; KEEP=; SETX=; r12keep
  rm -f "${FX:?}/loginfail" "${FX:?}/pubfail.sheepr-linux-arm64" "${FX:?}/pubfail.sheepr" "${FX:?}/uploadfail"
  if [ $k_ = done ]; then completed; else [ $r = 1 ]; fi && [ "$(dsum)" = "$s0_" ] && onlyp && ! grep -q npm_decoy "$FX/tokops" && ! grep -q '^REQ B' "$FX/reqs" 2>/dev/null \
    || bd_="$bd_ [$k_: rc=$r, the decoys $( [ "$(dsum)" = "$s0_" ] && echo same || echo CHANGED); files loaded: $(awk '{print $2}' "$FX/npmucs" 2>/dev/null | sort -u | tr '\n' ' '); $(grep '^npm ' "$FX/calls" | grep -v -- " --userconfig=$PP\$" | head -1 | cut -c1-80)]"
  world_reset; rm -f "${FX:?}/npmrc" "${FX:?}/low.npmrc" "${FX:?}/ghome/.npmrc"
done
[ -z "$bd_" ] && pass "REV 12 rule 1: a dry ship (done; stopped at the login, a platform upload, the main upload, GitHub): NPM_CONFIG_USERCONFIG's, npm_config_userconfig's and the HOME's npmrc, each with a live line, byte-identical; every npm call loads and names ship's own P" \
  || fail "REV 12 rule 1:$bd_"
# rule 2: an earlier P (a KILL, a logout that failed): ship logs out of it before its login. Exit 0,
# E401 or ENEEDAUTH: P removed, the run goes on (a P with no token line: no logout, removed; r17a F1's row). Another failure (ETIMEDOUT): P removed
# when its end time has passed; before it, a stop (fix) with npm's words, the end time, run ship again
pplant() { # LINE OFFSET: an earlier run's P (LINE, or empty), its end time now + OFFSET s
  mkdir -p "$PD" && chmod 700 "$PD" && { [ -z "$1" ] || printf '%s\n' "$1"; } > "$PP" && echo $(( $(/bin/date +%s) + $2 )) > "$PD/end"
}
EL='//registry.npmjs.org/:_authToken=npm_earlier'; b2_=""
for k_ in ok E401 ENEEDAUTH passed live; do
  rm -rf "${OUTR:?}"; : > "$FX/tokops"
  case $k_ in
    ok) pplant "$EL" 3600 ;;
    E401) pplant "$EL" 3600; echo E401 > "$FX/logoutonce" ;;
    ENEEDAUTH) pplant "$EL" 3600; echo ENEEDAUTH > "$FX/logoutonce" ;;   # (a P with no token line gets no logout: REV 12b rule 25)
    passed) pplant "$EL" -60; echo ETIMEDOUT > "$FX/logoutonce" ;;
    live) pplant "$EL" 3600; echo ETIMEDOUT > "$FX/logoutonce" ;;
  esac
  KEEP=1; ship; r=$?; KEEP=; rm -f "${FX:?}/logoutonce"; r12keep
  lo1_=$(grep -n '^npm logout' "$FX/calls" | head -1 | cut -d: -f1); li_=$(grep -n '^npm login' "$FX/calls" | head -1 | cut -d: -f1)
  if [ $k_ = live ]; then
    [ $r = 1 ] && [ -z "$li_" ] && [ -n "$lo1_" ] && grep -q 'npm error code ETIMEDOUT' "$NF" && grep -qE 'ends by itself at [0-9]{2}:[0-9]{2}' "$NF" && grep -q 'run ship again' "$NF" \
      && grep -qx "$EL" "$PP" && endsfix "$NF" || b2_="$b2_ [live: rc=$r login at '$li_'; $(head -1 "$NF" 2>/dev/null | cut -c1-160)]"
  else
    completed && [ -n "$lo1_" ] && [ -n "$li_" ] && [ "$lo1_" -lt "$li_" ] && [ ! -e "$PD" ] && { [ $k_ != ok ] || [ "$(head -1 "$FX/tokops")" = "DELETE token=npm_earlier" ]; } \
      || b2_="$b2_ [$k_: rc=$r logout at '$lo1_', login at '$li_', D $( [ -e "$PD" ] && echo left || echo gone); $(head -1 "$FX/tokops" 2>/dev/null) $(lastline | cut -c1-100)]"
  fi
  world_reset
done
[ -z "$b2_" ] && pass "REV 12 rule 2: an earlier P is logged out of before the login: exit 0, E401, ENEEDAUTH, or a failure past its end time: P removed, the run completes; a failure before its end time: a stop (fix), npm's words, the end time, run ship again, P kept" \
  || fail "REV 12 rule 2:$b2_"
# r18a F2 (PLAN-ship.md REV 12c rule 33): --out under a directory with an inheritable ACL that lets every
# account read (chmod +a ... file_inherit,directory_inherit; Finder's "apply to enclosed items" makes one):
# D (ship's mkdir -m 700) and P (npm's login) inherited it, and macOS checks an ACL's allow before the
# mode, so every account could read the session's token. Wanted: at the logout, neither D nor P holds an
# ACL entry (ls -le's numbered lines), and the release completes. Control: the same parent with no ACL
for k_ in plain acl; do
  rm -rf "${FX:?}/ap"; mkdir -p "$FX/ap" || exit 3
  [ $k_ = plain ] || /bin/chmod +a "group:everyone allow list,search,readattr,readextattr,readsecurity,read,file_inherit,directory_inherit" "$FX/ap" || exit 3
  OD=$FX/ap/out; AHX=$(printf 'sheepr-macos-universal.tar.gz %s\n' "$OD/v0.1.0" | shasum -a 256 | cut -d' ' -f1)
  printf '/bin/ls -led "%s/.v0.1.0.npm" > "%s/acl.d"; /bin/ls -le "%s/.v0.1.0.npm/npmrc" > "%s/acl.p"\n' "$OD" "$FX" "$OD" "$FX" > "$FX/onlogout"
  rm -f "$FX/acl.d" "$FX/acl.p"; : > "$FX/tokops"; OUT=$OD; VERIFIED=$AHX; ship; r=$?; OUT=; VERIFIED=; rm -f "${FX:?}/onlogout"
  [ $r = 0 ] && [ -s "$FX/acl.d" ] && [ -s "$FX/acl.p" ] && ! grep -q '^ *[0-9][0-9]*: ' "$FX/acl.d" "$FX/acl.p" && [ "$(tr '\n' ' ' < "$FX/tokops")" = "LOGIN DELETE token=npm_dry " ] \
    && pass "r18a F2: --out under a parent $( [ $k_ = acl ] && echo 'with an inheritable read-for-everyone ACL' || echo 'with no ACL (control)'): D and P hold no ACL entry at the logout; done" \
    || fail "r18a F2 ($k_): rc=$r D: [$(tr '\n' '|' < "$FX/acl.d" 2>/dev/null | sed "s|$FX|FX|g" | cut -c1-200)] P: [$(tr '\n' '|' < "$FX/acl.p" 2>/dev/null | sed "s|$FX|FX|g" | cut -c1-200)] tokops [$(tr '\n' ' ' < "$FX/tokops")]"
done
rm -rf "${FX:?}/ap"; rm -f "${FX:?}/acl.d" "${FX:?}/acl.p"
# r18a F4 (PLAN-ship.md REV 12c rule 35): P is a hard link (a second name of another file, which holds a
# live token and a line of its own): a stop (fix) before any npm call, that file byte-identical (a logout
# through it ended its token and rewrote it, mode 0600: real npm 9 to 11, notes/r18a/np/t1-v*.txt part H).
# Control: rule 2's rows (P with one name)
rm -rf "${OUTR:?}" "${FX:?}/elsewhere"; mkdir -p "$PD" "$FX/elsewhere" && chmod 700 "$PD" || exit 3
printf '//registry.npmjs.org/:_authToken=npm_elsewhere\nkeep=me\n' > "$FX/elsewhere/npmrc" && ln "$FX/elsewhere/npmrc" "$PP" || exit 3; es0_=$(cksum < "$FX/elsewhere/npmrc")
: > "$FX/tokops"; KEEP=1; ship; r=$?; KEEP=
[ $r = 1 ] && ! grep -q '^npm ' "$FX/calls" && [ "$(cksum < "$FX/elsewhere/npmrc")" = "$es0_" ] && grep -q "is not the file ship's login writes" "$FX/o" \
  && pass "r18a F4: a hard link at P: a stop (fix) before any npm call; the other file byte-identical" \
  || fail "r18a F4: rc=$r npm calls $(grep -c '^npm ' "$FX/calls" 2>/dev/null) tokops [$(tr '\n' ' ' < "$FX/tokops")] other file [$(tr '\n' '|' < "$FX/elsewhere/npmrc")]"
rm -rf "${PD:?}" "${FX:?}/elsewhere"; world_reset
# r18a F5 (REV 12c rule 35): the login leaves P with no token line (here a basic-auth line only) and whoami
# names another account: no logout of P (with no token line, npm logout ends a token of another layer: here
# one planted in D/global), P removed, and the stop that says to log in as lukasco. Control: rule 3's row
# (P with the login's token: its logout, P removed)
rm -rf "${OUTR:?}"; mkdir -p "$PD" && chmod 700 "$PD" && printf '//registry.npmjs.org/:_authToken=npm_global18\n' > "$PD/global" || exit 3
: > "$FX/tokops"; : > "$FX/loginauth"; echo stranger > "$FX/whoami"; KEEP=1; ship; r=$?; KEEP=; rm -f "${FX:?}/loginauth" "${FX:?}/whoami"
[ $r = 1 ] && ! grep -q '^npm logout' "$FX/calls" && ! grep -q DELETE "$FX/tokops" && [ ! -e "$PP" ] && grep -q 'the login to npm was as stranger' "$FX/o" \
  && pass "r18a F5: the login leaves no token line, whoami names another account: no logout (another layer's token kept), P removed, the stop" \
  || fail "r18a F5: rc=$r logouts $(grep -c '^npm logout' "$FX/calls") tokops [$(tr '\n' ' ' < "$FX/tokops")] P $( [ -e "$PP" ] && echo left || echo gone); $(grep -m1 'stopped at' "$FX/o" | cut -c1-200)"
rm -rf "${PD:?}"; world_reset
# r18a F6 (REV 12c rule 35): a stop inside npm_login before npm's login (D's volume ignores ownership: the
# seam): no login ran, so no text says ship logged in or that its session is ended. Control: the stop and
# logout row above (a login ran: pl, then "the session is ended")
: > "$FX/tokops"; rm -rf "${OUTR:?}"; SETX=SR_SHIP_DRY_NOOWNERS=yes; ship; r=$?; SETX=
[ $r = 1 ] && ! grep -q '^npm login' "$FX/calls" && ! grep -q 'logged in to npm in this run' "$FX/o" "$NF" && ! grep -q 'session is ended' "$FX/o" \
  && pass "r18a F6: a stop before npm's login: no text claims a login or an ended session" \
  || fail "r18a F6: rc=$r logins $(grep -c '^npm login' "$FX/calls"); $(grep -h -e 'logged in to npm' -e 'session is ended' "$FX/o" "$NF" 2>/dev/null | head -2 | tr '\n' '|' | cut -c1-240)"
# r18a OWN3 (REV 12c rule 35): the volume check cannot tell (npm-same.py's 3; the seam: SR_SHIP_DRY_NOOWNERS=3):
# a stop (fix) before the login, no P. Control: the noowners row (1) and every completed row (0)
: > "$FX/tokops"; rm -rf "${OUTR:?}"; SETX=SR_SHIP_DRY_NOOWNERS=3; ship; r=$?; SETX=
[ $r = 1 ] && grep -q 'cannot tell whether the volume of' "$NF" && ! grep -q '^npm login' "$FX/calls" && [ ! -s "$FX/tokops" ] && endsfix "$NF" \
  && pass "r18a OWN3: the volume check cannot tell: a stop (fix) before the login" \
  || fail "r18a OWN3: rc=$r logins $(grep -c '^npm login' "$FX/calls"); $(head -1 "$NF" 2>/dev/null | cut -c1-200)"
# r18a G1-G4 (REV 12c rule 35; notes/r18a/rows/gaps.rows): the shapes no row made.
# G1: P a FIFO: a stop (fix) before any npm call. (A writer opens it, non-blocking, for up to 20 s: a reader
# that blocks on it, ptok's grep, is let go, so a mutant shows as a run that went on, not a hang)
rm -rf "${OUTR:?}"; mkdir -p "$PD" && chmod 700 "$PD" && mkfifo "$PP" || exit 3
/usr/bin/perl -e 'use Fcntl; for (1..40) { if (sysopen(my $f, $ARGV[0], O_WRONLY|O_NONBLOCK)) { close $f; exit 0 } select(undef,undef,undef,0.5) } exit 1' "$PP" &
wp_=$!
: > "$FX/tokops"; KEEP=1; ship; r=$?; KEEP=; wait $wp_; wr_=$?
[ $r = 1 ] && grep -q "is not the file ship's login writes" "$FX/o" && ! grep -q '^npm ' "$FX/calls" \
  && pass "r18a G1: a FIFO at P: a stop (fix) before any npm call" \
  || fail "r18a G1: rc=$r npm calls $(grep -c '^npm ' "$FX/calls" 2>/dev/null) (writer $wr_: 0 = a reader opened the FIFO); $(grep -m1 'stopped at' "$FX/o" | cut -c1-160)"
rm -rf "${PD:?}"; world_reset
# G2: D a regular file: a stop (fix) before any npm call
rm -rf "${OUTR:?}"; mkdir -p "$OUTR" && echo x > "$PD" || exit 3
: > "$FX/tokops"; KEEP=1; ship; r=$?; KEEP=
[ $r = 1 ] && grep -q "is not the directory ship makes" "$FX/o" && ! grep -q '^npm ' "$FX/calls" \
  && pass "r18a G2: a regular file at D: a stop (fix) before any npm call" \
  || fail "r18a G2: rc=$r npm calls $(grep -c '^npm ' "$FX/calls" 2>/dev/null); $(grep -m1 'stopped at' "$FX/o" | cut -c1-160)"
rm -rf "${PD:?}"; world_reset
# G3: after the push (C8's view of the main package) P is replaced by a link to another file holding a live
# token: the end's logout does not go through it, and that file is untouched
rm -rf "${OUTR:?}" "${FX:?}/elsewhere"; mkdir -p "$FX/elsewhere" || exit 3
printf '//registry.npmjs.org/:_authToken=npm_elsewhere\n' > "$FX/elsewhere/npmrc"; es0_=$(cksum < "$FX/elsewhere/npmrc")
printf 'rm -f "%s"; ln -s "%s" "%s"\n' "$PP" "$FX/elsewhere/npmrc" "$PP" > "$FX/onviewpush.sheepr"
: > "$FX/tokops"; KEEP=1; ship; r=$?; KEEP=; rm -f "${FX:?}/onviewpush.sheepr" "${FX:?}/onviewpush.sheepr.done"
[ "$(cksum < "$FX/elsewhere/npmrc")" = "$es0_" ] && ! grep -q 'DELETE token=npm_elsewhere' "$FX/tokops" \
  && pass "r18a G3: a link at P made after the push: no logout through it; its target untouched" \
  || fail "r18a G3: rc=$r tokops [$(tr '\n' ' ' < "$FX/tokops")] target [$(tr '\n' ' ' < "$FX/elsewhere/npmrc")]"
rm -rf "${PD:?}" "${FX:?}/elsewhere"; world_reset
# G4: P planted as a link during the build (after the start's check): the login does not go through it (C4's
# check: a stop before the login), its target untouched
rm -rf "${OUTR:?}" "${FX:?}/elsewhere"; mkdir -p "$FX/elsewhere" || exit 3
printf '//registry.npmjs.org/:_authToken=npm_elsewhere\n' > "$FX/elsewhere/npmrc"; es0_=$(cksum < "$FX/elsewhere/npmrc")
printf 'mkdir -p "%s" && chmod 700 "%s" && ln -s "%s" "%s"\n' "$PD" "$PD" "$FX/elsewhere/npmrc" "$PP" > "$FX/onbuild"
: > "$FX/tokops"; KEEP=1; ship; r=$?; KEEP=; rm -f "${FX:?}/onbuild"
[ $r = 1 ] && [ "$(cksum < "$FX/elsewhere/npmrc")" = "$es0_" ] && ! grep -q '^npm login' "$FX/calls" && ! grep -q 'DELETE token=npm_elsewhere' "$FX/tokops" \
  && pass "r18a G4: a link at P made during the build: a stop before the login; its target untouched" \
  || fail "r18a G4: rc=$r logins $(grep -c '^npm login' "$FX/calls") tokops [$(tr '\n' ' ' < "$FX/tokops")] target [$(tr '\n' ' ' < "$FX/elsewhere/npmrc")]"
rm -rf "${PD:?}" "${FX:?}/elsewhere"; world_reset
# r17a P4-c (REV 12b rule 29): an earlier run's end time left in D (no P): gone when npm's login starts,
# and D is mode 0700 then (r17a P4-g: MMODE); the release completes. (A KILL after the login, before the
# new end was written, let the next run take that live session as ended by itself)
rm -rf "${OUTR:?}"; mkdir -p "$PD" && echo 1000 > "$PD/end" || exit 3
printf '{ [ -e "%s/end" ] && echo end-there || echo end-gone; stat -f %%Lp "%s"; } > "%s/atlogin"\n' "$PD" "$PD" "$FX" > "$FX/onlogin"
KEEP=1; ship; r=$?; KEEP=; rm -f "${FX:?}/onlogin"
completed && [ "$(tr '\n' ' ' < "$FX/atlogin" 2>/dev/null)" = "end-gone 700 " ] \
  && pass "r17a P4-c: an earlier end time in D is gone when the login starts; D is 0700 then; the release completes" || fail "r17a P4-c: rc=$r at the login: [$(tr '\n' ' ' < "$FX/atlogin" 2>/dev/null)]"
rm -f "$FX/atlogin"; world_reset
# r17a P4-g (MGARBLE): an earlier P whose end time cannot be read (garbled), its logout failing: P kept,
# a stop (fix) naming no time; never taken as ended. Control: rule 2's "passed" case (a past end: removed)
rm -rf "${OUTR:?}"; pplant "$EL" 3600; echo garbled > "$PD/end"; echo ETIMEDOUT > "$FX/logoutonce"; KEEP=1; ship; r=$?; KEEP=; rm -f "${FX:?}/logoutonce"
[ $r = 1 ] && grep -qx "$EL" "$PP" && grep -q 'could not be ended' "$NF" && grep -q 'That session ends by itself; run ship again' "$NF" && ! grep -q '^npm login' "$FX/calls" && endsfix "$NF" \
  && pass "r17a P4-g: an earlier P with a garbled end time, its logout failing: P kept, a stop naming no time" || fail "r17a P4-g, garbled end: rc=$r P $( [ -e "$PP" ] && echo kept || echo gone); $(grep -m1 'could not be ended' "$NF" 2>/dev/null | cut -c1-240)"
world_reset
# rule 2, before ship's first npm call: an earlier P whose token is dead (every npm call that sends it
# answers E401, A4's views among them): ship logs out of it before A4 (E401: P removed), and completes
rm -rf "${OUTR:?}"; pplant '//registry.npmjs.org/:_authToken=npm_dead1' 3600; KEEP=1; ship; r=$?; KEEP=; r12keep
lo1_=$(grep -n '^npm logout' "$FX/calls" | head -1 | cut -d: -f1); v1_=$(grep -n '^npm view' "$FX/calls" | head -1 | cut -d: -f1)
completed && [ -n "$lo1_" ] && [ -n "$v1_" ] && [ "$lo1_" -lt "$v1_" ] && [ ! -e "$PD" ] \
  && pass "REV 12 rule 2: an earlier P with a dead token: logged out of before ship's first npm call (A4's views), P removed; the run completes" \
  || fail "REV 12 rule 2, before A4: rc=$r logout at '$lo1_', first view at '$v1_'; $(lastline | cut -c1-160)"
world_reset
# r17a F1 (REV 12b rule 25): a token in npm's default global file (the prefix's etc/npmrc) and an earlier
# P with no token line: a done ship names its own D/global on every npm call, sends no global token, never
# logs out of that P (it is removed: nothing of ship's is in it), and leaves the global file as it was,
# its mode too. (Before: A4's views sent the global token, and npm_pre's logout ended it and rewrote the
# file, mode 0666.) Control: rule 2's rows above (a P with a token line is logged out of)
printf '//registry.npmjs.org/:_authToken=npm_global\n' > "$FX/globaldefault" && chmod 644 "$FX/globaldefault" || exit 3
gs0_=$(cksum < "$FX/globaldefault"); gm0_=$(stat -f %Lp "$FX/globaldefault")
rm -rf "${OUTR:?}"; pplant 'heading=npm' 3600; : > "$FX/tokops"; rm -f "$FX/reqs" "$FX/npmgcs"; KEEP=1; ship; r=$?; KEEP=; r12keep
li_=$(grep -n '^npm login' "$FX/calls" | head -1 | cut -d: -f1); lo1_=$(grep -n '^npm logout' "$FX/calls" | head -1 | cut -d: -f1)
completed && [ "$(awk '{print $2}' "$FX/npmgcs" | sort -u)" = "$PD/global" ] && ! grep -q npm_global "$FX/reqs" 2>/dev/null && ! grep -q 'DELETE global' "$FX/tokops" \
  && [ -n "$li_" ] && [ -n "$lo1_" ] && [ "$lo1_" -gt "$li_" ] && [ "$(cksum < "$FX/globaldefault")" = "$gs0_" ] && [ "$(stat -f %Lp "$FX/globaldefault")" = "$gm0_" ] \
  && pass "r17a F1: npm's global file holding a token, an earlier P with none: every npm call names D/global, no global token sent, no logout of that P, the global file and its mode as they were" \
  || fail "r17a F1, the global layer: rc=$r global files [$(awk '{print $2}' "$FX/npmgcs" 2>/dev/null | sort -u | tr '\n' ' ')] reqs [$(grep -c npm_global "$FX/reqs" 2>/dev/null)] tokops [$(tr '\n' ' ' < "$FX/tokops")] logout at '$lo1_', login at '$li_'"
rm -f "${FX:?}/globaldefault"; world_reset
# r17a P4-a (REV 12b rule 25): before any npm call names P, D must be a directory (not a link) and P a
# regular file (not a link): D a link, P a link, P a directory: each a stop (fix) before any npm call,
# the link's target untouched. Control: rule 2's rows above (a plain P)
for k_ in dlink plink pdir; do
  rm -rf "${OUTR:?}" "${FX:?}/elsewhere"; mkdir -p "$OUTR" "$FX/elsewhere" || exit 3
  printf '//registry.npmjs.org/:_authToken=npm_elsewhere\n' > "$FX/elsewhere/npmrc"; es0_=$(cksum < "$FX/elsewhere/npmrc")
  case $k_ in
    dlink) ln -s "$FX/elsewhere" "$PD" ;;
    plink) mkdir -m 700 "$PD" && ln -s "$FX/elsewhere/npmrc" "$PP" ;;
    pdir) mkdir -m 700 "$PD" "$PP" ;;
  esac
  : > "$FX/tokops"; KEEP=1; ship; r=$?; KEEP=
  case $k_ in dlink) w_="is not the directory ship makes" ;; *) w_="is not the file ship's login writes" ;; esac
  [ $r = 1 ] && grep -q "$w_" "$FX/o" && ! grep -q '^npm ' "$FX/calls" && [ "$(cksum < "$FX/elsewhere/npmrc")" = "$es0_" ] && [ ! -s "$FX/tokops" ] && endsfix "$NF" \
    && pass "r17a P4-a: $k_: a stop (fix) before any npm call; the link's target untouched" \
    || fail "r17a P4-a, $k_: rc=$r npm calls $(grep -c '^npm ' "$FX/calls") tokops [$(tr '\n' ' ' < "$FX/tokops")] $(grep -m1 'stopped at' "$FX/o" | cut -c1-200)"
  rm -rf "${PD:?}"; world_reset
done
rm -rf "${OUTR:?}" "${FX:?}/elsewhere"
# r17a F1 (REV 12b rule 25), the logout at the end: a P with no token line (the login left none; whoami
# then answers ENEEDAUTH): no logout of it, D removed, no "could not be ended". (A logout of it ended
# another layer's token.) Control: rule 4's rows (a P with a token line is logged out of at the end)
: > "$FX/loginempty"; : > "$FX/tokops"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/loginempty"
[ $r = 1 ] && grep -q 'npm whoami failed after the login' "$NF" && [ "$(grep -c '^npm logout' "$FX/calls")" = 0 ] && [ "$(cat "$FX/pd.after")" = gone ] && ! grep -q 'could not be ended' "$FX/o" \
  && pass "r17a F1: at the end, a P with no token line: no logout of it, D removed" || fail "r17a F1, the end's P with no line: rc=$r logouts $(grep -c '^npm logout' "$FX/calls") D $(cat "$FX/pd.after"); $(grep -m1 'could not be ended' "$FX/o" | cut -c1-160)"
# rule 3: the login names another account: the logout of P, P removed, a stop that says to log in as
# SR_NPM_USER in the browser when ship asks; nothing public
rm -rf "${OUTR:?}"; : > "$FX/tokops"; echo stranger > "$FX/whoami"; KEEP=1; ship; r=$?; KEEP=; rm -f "${FX:?}/whoami"; r12keep
[ $r = 1 ] && grep -q 'the login to npm was as stranger, but the packages belong to lukasco' "$NF" && grep -q 'log in as lukasco in the browser, then run ship again' "$NF" \
  && [ ! -e "$PP" ] && grep -q '^DELETE token=npm_dry' "$FX/tokops" && ! grep -q '^npm publish' "$FX/calls" && grep -qx 'Nothing is public.' "$NF" \
  && pass "REV 12 rule 3: the login names another account: its logout, P removed, a stop: log in as lukasco in the browser when ship asks; nothing public" \
  || fail "REV 12 rule 3: rc=$r P $( [ -e "$PP" ] && echo left || echo gone); $(head -1 "$NF" 2>/dev/null | cut -c1-200)"
world_reset
# rule 4: the logout of P at the end: exit 0, D removed (every completed row above); a failure: P kept,
# the text names the end time and that the next run logs out of it first; that next run does, then
# completes
rm -rf "${OUTR:?}"; echo ETIMEDOUT > "$FX/logoutcode"; KEEP=1; ship; r=$?; KEEP=; rm -f "${FX:?}/logoutcode"; r12keep
w_=$(grep -c "ship's npm session (its own file, $PP) could not be ended" "$FX/o"); g_=$(grep -cE 'It ends by itself at [0-9]{2}:[0-9]{2}' "$FX/o")
r4p_=$( [ -f "$PP" ] && grep -q '_authToken=npm_dry' "$PP" && echo kept || echo gone)
KEEPP=1; world_reset; KEEPP=; : > "$FX/tokops"; ship; r2_=$?; r=$r2_; r12keep
[ "$w_" -ge 1 ] && [ "$g_" -ge 1 ] && [ $r4p_ = kept ] && grep -qi 'the next ship or publish-npm run of v0.1.0 with this out dir logs out of it first' "$FX/r12out" \
  && completed && [ "$(head -1 "$FX/tokops")" = "DELETE token=npm_dry" ] && [ ! -e "$PD" ] \
  && pass "REV 12 rule 4: ship's logout failing: P kept, the text names the end time and that the next run logs out of it first; the next run does, and completes (D removed)" \
  || fail "REV 12 rule 4: text $w_ $g_, P $r4p_; the next run: rc=$r2_ first [$(head -1 "$FX/tokops")], D $( [ -e "$PD" ] && echo left || echo gone)"
# r18a F3 (PLAN-ship.md REV 12c rule 34): a done ship whose end logout fails (P kept; its text says the
# next ship or publish-npm run of v0.1.0 with this out dir logs out of it first), then ship again with the
# world as the first run left it (v0.1.0 on origin, so A2 or A3 refuses it): that run's first npm call is
# the logout of P, P is removed, and it stops because v0.1.0 is public. Control: rule 4's row above (origin
# reset between the runs: the second run logs out first and completes)
rm -rf "${OUTR:?}"; echo ETIMEDOUT > "$FX/logoutcode"; KEEP=1; ship; r1_=$?; KEEP=; rm -f "${FX:?}/logoutcode"; r12keep
pk1_=$( [ -f "$PP" ] && grep -q '_authToken=npm_dry' "$PP" && echo kept || echo gone)
t1_=$(grep -c 'the next ship or publish-npm run of v0.1.0 with this out dir logs out of it first' "$FX/o")
: > "$FX/tokops"; KEEP=1; ship; r2_=$?; KEEP=; r12keep
f2_=$(grep '^npm ' "$FX/calls" 2>/dev/null | head -1)
[ $r1_ = 1 ] && [ $pk1_ = kept ] && [ "$t1_" -ge 1 ] && [ $r2_ = 1 ] && case $f2_ in "npm logout "*) true ;; *) false ;; esac \
  && [ "$(head -1 "$FX/tokops")" = "DELETE token=npm_dry" ] && [ ! -e "$PP" ] && grep -q 'v0.1.0 is public' "$FX/o" \
  && pass "r18a F3: after a done ship whose logout failed, the next ship of v0.1.0 (the tag public) logs out of the kept session first, then refuses" \
  || fail "r18a F3: first rc=$r1_ P $pk1_ text $t1_; next rc=$r2_ first npm call [$(printf '%s' "$f2_" | cut -c1-60)] tokops [$(tr '\n' ' ' < "$FX/tokops")] P $( [ -e "$PP" ] && echo left || echo gone); $(grep -m1 'stopped at\|refused' "$FX/o" | cut -c1-200)"
world_reset; rm -rf "${OUTR:?}"
# r18b F3 (PLAN-ship.md REV 12c rule 35): the lock's pid cannot be written (here the out dir's inheritable
# ACL denies adding a file in a new subdirectory, so .ship.lock is made and its pid refused; a full disk does
# the same): a stop that names the pid file and removes its own lock, so the next run is not refused for a
# lock that no run holds. Control: every completed row (the pid written; the lock gone at the end)
rm -rf "${OUTR:?}"; mkdir -p "$OUTR" && /bin/chmod +a "user:$(id -un) deny add_file,only_inherit,directory_inherit" "$OUTR" || exit 3
ship; r=$?; /bin/chmod -N "$OUTR"
[ $r = 1 ] && grep -q 'cannot write .*/\.ship\.lock/pid' "$FX/o" && [ ! -e "$OUTR/.ship.lock" ] \
  && pass "r18b F3: the lock's pid cannot be written: a stop that removes its own lock" \
  || fail "r18b F3: rc=$r lock $( [ -e "$OUTR/.ship.lock" ] && echo left || echo gone); $(grep -m1 'cannot write' "$FX/o" | cut -c1-200)"
rm -rf "${OUTR:?}"
# r18b F4 (REV 12c rule 35): an earlier run's record that this run cannot replace (mode 0444: the first
# write's open fails) is that run's, not this one's: the stop names the record it cannot write and prints
# no route of it (here a record of the platform uploads, whose route would send the operator to publish;
# it holds no `start push`, which the post-push scan reads as this run's); it says this run made nothing
# public. Control: rule 21's rows (this run's own record, unreadable)
rm -rf "${OUTR:?}"; mkdir -p "$OUTR" && printf 'run 1 2026-01-01T00:00:00Z\nstart npm-platform sheepr-linux-arm64\n' > "$OUTR/.v0.1.0.ship-progress" \
  && chmod 444 "$OUTR/.v0.1.0.ship-progress" || exit 3
ship; r=$?; chmod 644 "$OUTR/.v0.1.0.ship-progress" 2>/dev/null
[ $r = 1 ] && grep -q 'cannot write .*/\.v0\.1\.0\.ship-progress' "$FX/o" && ! grep -q -e 'is pushed' -e ' publish --out' -e 'publish-npm --out' "$FX/o" && grep -qx 'This run made nothing public.' "$FX/o" \
  && pass "r18b F4: an earlier run's record this run cannot replace: no route of it; this run made nothing public" \
  || fail "r18b F4: rc=$r $(grep -v -e '(dry)' -e 'a temp HOME' "$FX/o" | head -6 | tr '\n' '|' | cut -c1-400)"
rm -rf "${OUTR:?}"
# rule 4: no npm command is printed: no stop text, next file or stdout above, and no notification text,
# holds "npm login", "npm logout" or "npm config" (release.sh's and notify.sh's own texts: no such words
# outside comments)
nc_=$(grep -c -e 'npm login' -e 'npm logout' -e 'npm config' "$FX/r12out")
ns_=$(cat "$SR_ROOT/scripts/release.sh" "$SR_ROOT/scripts/lib/notify.sh" | grep -v '^ *#' | grep -c -e 'npm login' -e 'npm logout' -e 'npm config')
# (and, from REV 11's class row: no step word or step line before a literal npm command, and no `cd / && npm`)
sw_=$(cat "$SR_ROOT/scripts/release.sh" "$SR_ROOT/scripts/lib/notify.sh" | grep -v '^ *#' | grep -oE '(^|[^A-Za-z])(run|Run|Next:|try|with|then):? +(cd / && )?npm +[a-z]+|"  +(cd / && )?npm +[a-z]+' | sort | uniq -c | tr -s ' ' | tr '\n' '|')
cdn_=$(cat "$SR_ROOT/scripts/release.sh" "$SR_ROOT/scripts/lib/notify.sh" | grep -v '^ *#' | grep -c 'cd / && npm')
[ "$nc_" = 0 ] && [ "$ns_" = 0 ] && [ -z "$sw_" ] && [ "$cdn_" = 0 ] && [ "$(grep -c . "$FX/r12out")" -gt 100 ] \
  && pass "REV 12 rule 4: no npm command printed: the texts of the $(grep -c 'stopped at\|is public' "$FX/r12out") runs above, and release.sh's and notify.sh's own words, hold no 'npm login', 'npm logout' or 'npm config'" \
  || fail "REV 12 rule 4, the census: $nc_ lines in the runs' texts ($(grep -m1 -e 'npm login' -e 'npm logout' -e 'npm config' "$FX/r12out" | cut -c1-140)); $ns_ in the sources; step words [$sw_]; 'cd / && npm' $cdn_"
rm -f "${FX:?}/r12out"
# r17a F5 (REV 12b rule 24): --out spelt with `..` after a symbolic link. ship resolves it physically, so
# its D and npm's P (npm reads --userconfig by its text, as the stand-in does) are one file: the release
# completes, with one login and one logout that ends npm_dry, and nothing lands in the text-spelt dir
# (made here, as npm's config save would make it). With a finished build there (the start resolves out),
# and with none (ship_run resolves it after making it). Control: the plain --out, every other row
mkdir -p "$FX/sub/x" "$FX/out2/.v0.1.0.npm" "$FX/out3/.v0.1.0.npm" && ln -s "$FX/sub/x" "$FX/lnk" || exit 3
mkbuild "$FX/sub/out2/v0.1.0" v0.1.0 "$C"
for k_ in 2 3; do
  AHX=$(printf 'sheepr-macos-universal.tar.gz %s\n' "$FX/sub/out$k_/v0.1.0" | shasum -a 256 | cut -d' ' -f1)
  : > "$FX/tokops"; OUT=$FX/lnk/../out$k_; VERIFIED=$AHX; ship; r=$?; OUT=; VERIFIED=
  [ $r = 0 ] && grep -q 'release: ship: v0.1.0 is public on GitHub, Homebrew and npm' "$FX/o" && [ "$(tr '\n' ' ' < "$FX/tokops")" = "LOGIN DELETE token=npm_dry " ] \
    && [ -z "$(ls -A "$FX/out$k_/.v0.1.0.npm")" ] && [ ! -e "$FX/sub/out$k_/.v0.1.0.npm" ] && grep -q "ship's npm session is ended" "$FX/o" \
    && pass "r17a F5: --out lnk/../out$k_ ($( [ $k_ = 2 ] && echo 'a finished build there' || echo 'no build yet')): resolved physically; one login, one logout ending npm_dry; nothing in the text-spelt dir" \
    || fail "r17a F5, lnk/../out$k_: rc=$r tokops [$(tr '\n' ' ' < "$FX/tokops")] text-spelt: [$(ls -A "$FX/out$k_/.v0.1.0.npm" | tr '\n' ' ')] $(grep -m1 'stopped at' "$FX/o" | cut -c1-160)"
done
rm -rf "${FX:?}/sub" "${FX:?}/out2" "${FX:?}/out3" "${FX:?}/lnk"
# r18a F1 (PLAN-ship.md REV 12c rule 32): --out whose path holds a $. npm reads ${NAME} in a path as a
# variable before it resolves it (\${ too; ${NAME?} in 11.6.0: notes/r18a/np/t1-v*.txt part E; the npm
# stand-in rewrites it so: tests/dist/envrep.pl), so npm's P would be another file than ship's D/npmrc, and
# ship would remove its D and say its session is ended. Each spelling (a dir named literally ${TMPDIR},
# \${TMPDIR}, ${X?}; a link to a dir named ${HOME}; a new dir under that link, which only ship_run's own
# resolution sees) is refused before any npm call, its text names the $, and no file under the fixture
# holds the session's token. Control: the plain out: one login, one logout ending it, none left
for k_ in plain lit esc q link under; do
  rm -rf "${FX:?}/d"; mkdir -p "$FX/d/"'${HOME}' && ln -s "$FX/d/"'${HOME}' "$FX/d/lnk" || exit 3   # (each case its own: no token of another)
  case $k_ in
    plain) OD=$FX/d/plain ;; lit) OD=$FX/d/'${TMPDIR}' ;; esc) OD=$FX/d/'\${TMPDIR}' ;; q) OD=$FX/d/'${X?}' ;;
    link) OD=$FX/d/lnk ;; under) OD=$FX/d/lnk/sub ;;
  esac
  AHX=$(printf 'sheepr-macos-universal.tar.gz %s\n' "$OD/v0.1.0" | shasum -a 256 | cut -d' ' -f1)
  : > "$FX/tokops"; OUT=$OD; VERIFIED=$AHX; ship; r=$?; OUT=; VERIFIED=
  left_=$(grep -rl '_authToken=npm_dry' "$FX/d" 2>/dev/null | tr '\n' ' ')
  if [ $k_ = plain ]; then
    [ $r = 0 ] && [ "$(tr '\n' ' ' < "$FX/tokops")" = "LOGIN DELETE token=npm_dry " ] && [ -z "$left_" ] \
      && pass "  control: a plain --out: one login, one logout ending the session's token, none left" \
      || fail "  control, a plain --out: rc=$r tokops [$(tr '\n' ' ' < "$FX/tokops")] left [$left_]"
  else
    [ $r = 1 ] && ! grep -q '^npm ' "$FX/calls" 2>/dev/null && grep -qF 'holds a $' "$FX/o" && [ -z "$left_" ] \
      && pass "r18a F1: --out with a \$ ($k_): refused before any npm call, the text names the \$, no token anywhere" \
      || fail "r18a F1: --out with a \$ ($k_): rc=$r npm calls $(grep -c '^npm ' "$FX/calls" 2>/dev/null) tokops [$(tr '\n' ' ' < "$FX/tokops")] left [$left_] $(grep -m1 '^release:' "$FX/o" | cut -c1-200)"
  fi
done
rm -rf "${FX:?}/d"
# --- REV 11 rule 2, npm routing (r13a F1): npm's scope setting routes logout, view, owner and publish
# to the scope's registry B, and login rewrites <scope>:registry; every npm call ship makes has --scope=
# (and --registry), and loads P only (REV 12). With scope=@acme, @acme:registry=B and B's token in the
# operator's file: no request reaches B, none carries B's token, and that file is as it was: a failed C4
# login; a success
scoped() { printf 'scope=@acme\n@acme:registry=https://npm.acme.example/\n//npm.acme.example/:_authToken=npm_acmeB\n' > "$FX/npmrc"; }
bkeeps() { grep -qx '@acme:registry=https://npm.acme.example/' "$1" && grep -qx '//npm.acme.example/:_authToken=npm_acmeB' "$1"; }   # FILE: B's routing and token as they were
noreqb() { ! grep -q '^REQ B' "$FX/reqs" 2>/dev/null && ! grep -q 'npm_acmeB' "$FX/reqs" 2>/dev/null; }
scoped; : > "$FX/loginfail"; rm -f "$FX/reqs"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "${FX:?}/loginfail"
[ $r = 1 ] && grep -q '^npm login' "$FX/calls" && noreqb && bkeeps "$FX/npmrc" && onlyp \
  && pass "REV 11 rule 2: a scope routed to another registry, a failed C4 login: no request reached it, none carried its token; its line and routing kept" \
  || fail "scope, failed login: rc=$r reqs: $(tr '\n' '|' < "$FX/reqs" 2>/dev/null) after: $(tr '\n' '|' < "$FX/npmrc" | cut -c1-200)"
scoped; rm -f "$FX/reqs"; rm -rf "${OUTR:?}"; ship; r=$?
completed && noreqb && bkeeps "$FX/npmrc" && onlyp && [ "$(cat "$FX/pd.after")" = gone ] \
  && pass "  a success: no request reached the scope's registry; the operator's file as it was; every npm call P's; D removed" \
  || fail "  scope, success: rc=$r reqs: $(tr '\n' '|' < "$FX/reqs" 2>/dev/null) after: $(tr '\n' '|' < "$FX/npmrc" | cut -c1-200)"
rm -f "${FX:?}/npmrc"
# r13b F6: every line ship_stoptext prints that runs a command runs as printed, pasted into sh and into
# an interactive zsh -f (from stdin), for every class with no progress and every progress state; the
# checkout's and the out dir's paths hold a space, and so does an NPM_CONFIG_USERCONFIG ship_stoptext
# must never print (REV 12: no line names an npm file, a variable prefix or an npm command)
SW=$FX/stw; rm -rf "${SW:?}"; mkdir -p "$SW/bin" "$SW/st ate/repo/scripts" "$SW/o ut/v0.1.0" "$SW/u rc" || exit 3
printf '%s\n' 'index($0, n "() {") == 1 { f = 1; print; if ($0 ~ /[}][[:space:]]*(#.*)?$/) exit; next }' 'f { print }' 'f && /^[}]/ { exit }' > "$SW/fn.awk"
for f_ in dq ship_stoptext; do awk -v n="$f_" -f "$SW/fn.awk" "$SR_ROOT/scripts/release.sh"; done > "$SW/fns.sh"
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
  # (the record's run line names the shell that calls ship_stoptext: it reads only its own run's record,
  # REV 12c rule 35)
  sh -c '{ printf "run %s 2026-10-17T00:00:00Z\n" $$; sed 1d "$1/prog"; } > "$1/prog.n" && mv "$1/prog.n" "$1/prog"
    . "$1/fns.sh"; shipprog=$1/prog shipcls=$1/cls shipcause=$1/cause phase=push tag=v0.1.0 out="$1/o ut" oroot="$1/st ate/repo" pubok=yes
    SR_NPM_PKGS="sheepr-linux-arm64 sheepr" SR_NPM_USER=lukasco commit=$2 NPMC= NPMREG=https://registry.npmjs.org/ NPM_CONFIG_USERCONFIG="$1/u rc/npmrc"; export NPM_CONFIG_USERCONFIG
    ship_stoptext' sh "$SW" "$cm_" > "$SW/text" 2> "$SW/text.err" || bad_="$bad_ [${la_:-$cl_}: ship_stoptext failed: $(head -c 120 "$SW/text.err")]"
  while IFS= read -r l_; do
    case $l_ in
      *[!\ ]*) ;; *) continue ;;
    esac
    t_=${l_#"${l_%%[! ]*}"}   # the line without its leading spaces
    case $t_ in
      "sh '"*) e_=$(printf '%s\n' "$t_" | sed -n "s|^sh '[^']*' \([a-z-]*\) .*|\1|p"); w_="rs [$SW/st ate/repo/scripts/release.sh] [$e_] [--out] [$SW/o ut] [v0.1.0]"
        [ "$e_" != publish-npm ] || { w_="$w_ uc=[unset]"; np_=$((np_ + 1)); } ;;   # (REV 12: publish-npm's line has no variable prefix; it logs in to its own file)
      "git "*) w_="git [-C] [$SW/st ate/repo] [ls-remote] [origin] [refs/tags/v0.1.0]" ;;
      *=*" sh '"*|"cd / && npm "*|"npm login"*|"npm logout"*|"npm config"*|"npm token"*) bad_="$bad_ [${la_:-$cl_}: a variable prefix or an npm command: '$(printf '%s' "$t_" | cut -c1-90)']"; continue ;;
      *) continue ;;
    esac
    nl_=$((nl_ + 1))
    for how_ in sh zsh; do srun $how_ "$l_" "$w_" || bad_="$bad_ [${la_:-$cl_} $how_: '$(printf '%s' "$t_" | cut -c1-90)': $(tr '\n' '|' < "$REC" | cut -c1-80) $(head -c 80 "$SW/o" | tr '\n' ' ')]"; done
  done < "$SW/text"
done
[ -z "$bad_" ] && [ "$nl_" -ge 21 ] && [ "$np_" = 9 ] && pass "r13b F6: every runnable line of ship_stoptext ($nl_ lines over 20 classes and progress states) runs as printed, from sh and from an interactive zsh; each of the $np_ publish-npm lines has no variable prefix and gives publish-npm no userconfig variable (REV 12)" \
  || fail "stoptext lines ($nl_, $np_ publish-npm lines):$(printf '%s' "$bad_" | cut -c1-500)"
# r12b F3, F4: no child holds ship's fd 8 or 9 (its own stdout and stderr, kept for the handler): a
# child left behind with its fds 0-2 closed must not hold a reader of ship's stdout. `ship | reader`
# with the build stand-in leaving such a child: the reader ends within 2 s of ship's end. Control: a
# child that keeps fd 1 (ship's stdout) holds the reader. The child lingers until the row releases it,
# 4 s after ship's own end (its t.end), so the control holds the reader however long ship ran
# (r15b P4-10: a child that ended by itself after 15 s let a slow run's control fail)
for k_ in buildlinger buildlinger1; do
  rm -f "$FX/linger.pid" "$FX/t.end" "$FX/t.eof" "$FX/linger.go"; : > "$FX/$k_"; rm -rf "${OUTR:?}"
  ( n_=0; until [ -e "$FX/t.end" ] || [ $n_ -ge 1500 ]; do /bin/sleep 0.2; n_=$((n_ + 1)); done; /bin/sleep 4; : > "$FX/linger.go" ) < /dev/null > /dev/null 2>&1 &
  rl_=$!
  PIPEEOF=1; ship; r=$?; PIPEEOF=; rm -f "${FX:?}/$k_"; wait $rl_
  lp_=$(cat "$FX/linger.pid" 2>/dev/null); d_=$(/usr/bin/perl -e 'printf "%.1f", $ARGV[1] - $ARGV[0]' "$(cat "$FX/t.end" 2>/dev/null)" "$(cat "$FX/t.eof" 2>/dev/null)")
  if [ $k_ = buildlinger ]; then
    completed && [ -n "$lp_" ] && /usr/bin/perl -e 'exit !($ARGV[0] <= 2)' "$d_" \
      && pass "r12b F3: ship | reader, a child left behind with fds 0-2 closed: the reader ends ${d_} s after ship" || fail "linger: rc=$r child '$lp_' reader ${d_} s after ship"
  else
    completed && [ -n "$lp_" ] && /usr/bin/perl -e 'exit !($ARGV[0] >= 3)' "$d_" \
      && pass "  control: a child that keeps fd 1 holds the reader (${d_} s after ship)" || fail "  control linger: rc=$r child '$lp_' reader ${d_} s after ship"
  fi
  # the child ends once released; wait for it, so no row after this one sees it
  n_=0; while [ -n "$lp_" ] && kill -0 "$lp_" 2>/dev/null && [ $n_ -lt 80 ]; do /bin/sleep 0.25; n_=$((n_ + 1)); done
done
rm -f "${FX:?}/linger.go"
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
# REV 12 rule 4: the logout's exit decides, not P's lines: a logout that exits 1 having removed its line is
# a failure (P kept; the next run's logout of it answers ENEEDAUTH, and P goes)
: > "$FX/logoutlies"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/logoutlies"
[ $r = 1 ] && [ "$(nots)" = "npm-login npm-approve npm-approve-again logout-failed " ] && [ "$(cat "$FX/pd.after")" = left ] \
  && pass "a logout that exits 1 with its line gone: logout-failed, exit 1, P kept (the exit decides)" || fail "logout lies: rc=$r '$(nots)' D $(cat "$FX/pd.after")"
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
# stdout closed during the uploads, and a logout that removes P itself (exit 0): D removed (the handler
# drains the bytes the closed stdout left before the logout and its words)
: > "$FX/logoutrm"; rm -rf "${OUTR:?}"; PIPEQ='uploaded (npm scans it'; ship; r=$?; PIPEQ=; rm -f "$FX/logoutrm"
[ "$r" = 1 ] && [ "$(nots)" = "npm-login npm-approve failed-npm-platform " ] && [ "$(grep -c '^release:' "$NF")" = 1 ] && [ "$(cat "$FX/pd.after")" = gone ] && leakfree \
  && pass "stdout closed, P removed by its logout (exit 0): failed-npm-platform, D removed, no temp dir left" || fail "closed stdout, P removed: rc=$r '$(nots)' D $(cat "$FX/pd.after")"
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
cont() { # run each release.sh step the next file names, in order, through its dry entry (publish-npm:
         # its line as printed, in a shell with no userconfig variable; it logs in itself); an npm
         # command in the file is refused (REV 12: none is printed); RC: the first refused step, or 0
  RC=0; : > "$FX/cont"; rm -f "$FX/cont.one"
  while IFS= read -r l; do
    case $l in
      *"npm login"*|*"npm logout"*|*"npm config"*) RC=1; echo "refused: an npm command in the next file: $l" >> "$FX/cont"; return ;;
      *"/scripts/release.sh' "*" --out '$OUTR' v0.1.0"*)
        e=$(printf '%s\n' "$l" | sed "s/.*\/scripts\/release\.sh' \([a-z-]*\) --out.*/\1/")
        [ "$e" = "${2:-$e}" ] || continue
        [ -z "${2:-}" ] || [ ! -e "$FX/cont.one" ] || return
        [ -z "${2:-}" ] || : > "$FX/cont.one"
        echo "$e" >> "$FX/cont"; printf 'v0.1.0\nv0.1.0\n' > "$FX/ask"
        if [ "$e" = publish-npm ]; then
          # (REV 12) the line as printed, from / in a shell with no userconfig variable, its dry entry in
          # the entry's place: it logs in to its own file and out of it; its last line says so
          pl_=$(printf '%s\n' "$l" | sed 's/ publish-npm --out / __publish-npm-dry --out /')
          (cd / && no_osascript env -i PATH="$B:/usr/bin:/bin" HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
            SR_PUBLISH_DRY_NPM="$S/npm" SR_PUBLISH_DRY_NOTIFY="$S/notify" SR_ASK_SCRIPT="$FX/ask" SR_ASK_RECORD="$FX/asks" sh -c "$pl_") > "$FX/co" 2>&1 \
            || { dryhomes "$FX/co"; RC=1; echo "refused: $e: $(tail -1 "$FX/co")" >> "$FX/cont"; return; }
          dryhomes "$FX/co"
          [ "$(tail -1 "$FX/co")" = "release: publish-npm's npm session is ended (its own file removed)" ] || { RC=1; echo "refused: $e: its last line is not its own logout's: $(tail -1 "$FX/co")" >> "$FX/cont"; return; }
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
  cont; [ $RC = 0 ] && done_all && ! grep -Eq "$NPMCMD" "$NF" && pass "$1: the steps named ($(tr '\n' ' ' < "$FX/cont")) complete the release" || fail "$1: $(tr '\n' ' ' < "$FX/cont")"
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
[ "$(lastprog)" = "done push" ] && grep -q '^v0.1.0 is pushed; nothing else is public. Run in order:' "$NF" && ! grep -q 'npmjs.com/package' "$NF" && pass "the push done, no upload: publish, publish-npm (no wait note)" || fail "push done: '$(lastprog)' $(tr '\n' '|' < "$NF")"
stoprow "the push done, no upload"
for pk in sheepr-linux-arm64 sheepr-linux-x64 sheepr-darwin-universal; do
  : > "$FX/pubfail.$pk"; rm -rf "${OUTR:?}"; KEEP=1; ship; r=$?; KEEP=; rm -f "$FX/pubfail.$pk"
  grep -q "https://www.npmjs.com/package/$pk shows 0.1.0" "$NF" && grep -q "npm's email to lukasco. A blocked version needs a new version number." "$NF" && grep -q 'GitHub has no release of it' "$NF" && postpush_ok \
    && pass "a platform upload stopped ($pk): publish, publish-npm, the wait note and npm's review" || fail "platform stop $pk: $(tr '\n' '|' < "$NF")"
  stoprow "the platform uploads stopped at $pk"
done
: > "$FX/uploadfail"; rm -rf "${OUTR:?}"; KEEP=1; ship; r=$?; KEEP=; rm -f "$FX/uploadfail"
grep -q "a draft is not public: delete it on GitHub, then run:" "$NF" && postpush_ok && pass "GitHub stopped with a draft: the three cases named" || fail "draft left: $(tr '\n' '|' < "$NF")"
rm -rf "${FX:?}/up"   # the operator deletes the draft
cont "$NF" publish; [ $RC = 0 ] && pass "  the draft deleted: publish completes" || fail "  publish after the draft: $(tr '\n' ' ' < "$FX/cont")"
cont "$NF" publish-npm; [ $RC = 0 ] && done_all && pass "  then publish-npm: the release complete" || fail "  publish-npm: $(tr '\n' ' ' < "$FX/cont")"
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
  case $1 in *=*) bad_="$bad_ [a variable prefix: $1]"; shift ;; esac   # (REV 12: no line has one)
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
grep -q 'is public on GitHub, but its Homebrew cask is not updated' "$NF" && grep -qx "  sh '$REPO/scripts/release.sh' publish-cask --out '$OUTR' v0.1.0" "$NF" && postpush_ok && pass "exit 5: publish-cask, publish-npm" || fail "exit5 text: $(tr '\n' '|' < "$NF")"
stoprow "exit 5"
: > "$FX/pubfail.sheepr"; rm -rf "${OUTR:?}"; KEEP=1; ship; r=$?; KEEP=; rm -f "$FX/pubfail.sheepr"
grep -q 'public on GitHub and Homebrew, and npm may hold a part of it' "$NF" && ! grep -q 'release.sh publish ' "$NF" && grep -q 'npmjs.com/package/sheepr shows' "$NF" && postpush_ok \
  && pass "the main upload refused: publish-npm only" || fail "main refused: $(tr '\n' '|' < "$NF")"
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

# REV 12a (r16b F1, F6): Gatekeeper's refusal (spctl, class fix) names the certificate's rebuild only while
# ship knows nothing is public, before C5: at C3 (the control), move the build aside and rebuild it; at
# C7 (after the push; r16b walk-c7) the rebuild only on the condition that v0.1.0 is not pushed, checked
# by a runnable ls-remote line (here the tag is pushed: the line, run as printed, lists it). Never
# "expired", in the cause, the stop text or the next file. (SR_SHIP_DRY_SPCTL: verify's own spctl stop
# at that phase, in the dry entry)
GKR="When the cause is a revoked signing certificate, move the build aside and rebuild it with a valid one."
GKC="If that prints nothing, v0.1.0 is not pushed yet: move the build aside and rebuild it with a valid certificate. If it prints a line, v0.1.0 is pushed: never rebuild v0.1.0; release a new version."
SETX=SR_SHIP_DRY_SPCTL=C3; rm -rf "${OUTR:?}"; ship; r=$?; SETX=
[ $r = 1 ] && grep -q 'stopped at checks: spctl: Gatekeeper rejects the bundle' "$NF" && grep -qxF "$GKR" "$NF" && ! grep -q -e 'release a new version' -e 'ls-remote origin refs/tags' "$NF" \
  && pass "REV 12a, control: Gatekeeper's refusal at C3 (nothing public): the certificate's remedy, move the build aside and rebuild it" \
  || fail "REV 12a at C3: rc=$r $(head -1 "$NF" 2>/dev/null | cut -c1-120) $(grep -e 'rebuild' "$NF" 2>/dev/null | tr '\n' '|' | cut -c1-240)"
! grep -qi 'expired' "$NF" "$FX/o" && pass "REV 12a: at C3, no 'expired'" || fail "REV 12a at C3: $(grep -i 'expired' "$NF" | head -1 | cut -c1-200)"
SETX=SR_SHIP_DRY_SPCTL=C7; rm -rf "${OUTR:?}"; KEEP=1; ship; r=$?; KEEP=; SETX=
gl_=$(grep -x "  git -C '$REPO' ls-remote origin refs/tags/v0.1.0" "$NF" | head -1); gk7_=no
if [ -n "$gl_" ]; then
  eval "set -- ${gl_# }"; shift
  (cd / && env -i PATH=/usr/bin:/bin HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$S/sgit" "$@") > "$FX/gk7" 2>&1 && grep -q 'refs/tags/v0.1.0$' "$FX/gk7" && ! grep -q '^SGIT REFUSED' "$FX/calls" && gk7_=yes
fi
world_reset
[ $r = 1 ] && [ "$(lastprog)" = "start github" ] && grep -q 'stopped at github: spctl: Gatekeeper rejects the bundle' "$NF" && ! grep -qxF "$GKR" "$NF" "$FX/o" \
  && grep -qxF "$GKC" "$NF" && [ $gk7_ = yes ] \
  && pass "REV 12a: Gatekeeper's refusal at C7 (after the push): no rebuild but on the condition that v0.1.0 is not pushed, in stdout or the next file; the ls-remote line runs as printed (it lists the pushed tag)" \
  || fail "REV 12a at C7: rc=$r '$(lastprog)' ls-remote line '$gl_' ($gk7_); $(grep -e 'rebuild' "$NF" 2>/dev/null | tr '\n' '|' | cut -c1-300)"
! grep -qi 'expired' "$NF" "$FX/o" && pass "REV 12a: at C7, no 'expired'" || fail "REV 12a at C7: $(grep -i 'expired' "$NF" | head -1 | cut -c1-200)"
# r17b F5 (REV 12b rule 23): at C7 that refusal (class gatekeeper) names no publish step: no publish,
# publish-cask or publish-npm line in stdout or the next file; publish-npm refuses it too; release a new
# version. Control: a C7 stop of another kind (the release still a draft) still lists publish-npm
grep -q "Gatekeeper rejects this build (above): it is not published on GitHub, and publish-npm refuses it too (it runs verify first). Release a new version." "$NF" \
  && ! grep -q -e "release.sh' publish --out" -e "release.sh' publish-cask --out" -e "release.sh' publish-npm --out" "$NF" "$FX/o" \
  && pass "r17b F5: Gatekeeper's refusal after the push names no publish step (publish-npm refuses it too); release a new version" \
  || fail "r17b F5: $(grep -e 'publish' -e 'Gatekeeper rejects this' "$NF" 2>/dev/null | tr '\n' '|' | cut -c1-300)"
rm -rf "${OUTR:?}"; : > "$FX/stilldraft"; ship; r=$?; rm -f "$FX/stilldraft"
[ $r = 1 ] && [ "$(lastprog)" = "start github" ] && grep -q "release.sh' publish-npm --out" "$NF" && ! grep -q 'Gatekeeper rejects this build' "$NF" \
  && pass "  control: a C7 stop of another kind (the release still a draft) still lists publish-npm" || fail "  control, C7 draft: rc=$r '$(lastprog)' $(grep publish "$NF" 2>/dev/null | tr '\n' '|' | cut -c1-200)"
rm -rf "${OUTR:?}"
rm -f "${FX:?}/gk7"

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
# (REV 12b rule 22: the stamp is npm-check's record, not the build's bytes: class fix, never "move aside")
! grep -q "Move $OUTR/v0.1.0 aside" "$NF" && grep -qx 'When the cause above is fixed, run ship again.' "$NF" && pass "  REV 12b rule 22: a stamp that is not this manifest's: class fix, no move aside" || fail "  badstamp: $(tr '\n' '|' < "$NF" 2>/dev/null | cut -c1-200)"
# r17b F1: npm-check's stamp write that landed nothing (the stand-in leaves it empty, exit 0): ship stops
# at C3 with class fix, never "move aside" (a rebuild and a second notarization for no defect)
rm -rf "${OUTR:?}"; : > "$FX/npmcheck.empty"; ship; r=$?; rm -f "$FX/npmcheck.empty"
[ $r = 1 ] && grep -q 'npm-check has not passed on' "$FX/o" && ! grep -qi 'move .* aside' "$NF" && grep -qx 'When the cause above is fixed, run ship again.' "$NF" && ! grep -q 'push --porcelain --atomic' "$FX/calls" \
  && pass "r17b F1: an empty stamp (npm-check's write landed nothing): C3 stops, class fix, no move aside, nothing pushed" \
  || fail "r17b F1, empty stamp: rc=$r $(tr '\n' '|' < "$NF" 2>/dev/null | cut -c1-240)"
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
printf ': > "%s/whoamibad2"\n' "$FX" > "$FX/afterpush"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/afterpush" "$FX/whoamibad2"; hint_row "C6's whoami failing" "npm whoami failed; this step uploaded nothing"
printf 'echo other > "%s/whoami"\n' "$FX" > "$FX/afterpush"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/afterpush" "$FX/whoami"; hint_row "C6's whoami another user" "but the packages belong to lukasco; this step uploaded nothing"
: > "$FX/pubfail.sheepr-linux-x64"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/pubfail.sheepr-linux-x64"; hint_row "an upload refused" "A browser login or 2FA approval that failed or timed out may be the cause"
# r17a F3 (REV 12b rule 27): npm's own words on the terminal advise a new login; the refusal says it does not apply
grep -q "npm's own advice there to log in again does not apply: ship logs in with its own file" "$FX/o" \
  && pass "r17a F3: an upload refused: npm's own advice to log in again does not apply (ship logs in with its own file)" || fail "r17a F3, the upload's refusal: $(grep -m1 'npm refused the upload' "$FX/o" | cut -c1-240)"
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
# POST; the build moved aside (each check of publish_check also has its own row in t_publish_dry), but
# for a missing stamp: npm-check's record, class fix (REV 12b rule 22)
cr() { # label want-text
  [ $r = 1 ] && grep -q "$2" "$FX/o" && ! grep -q -e 'push --porcelain --atomic' -e '^npm publish' -e '^gh api -X POST' "$FX/calls" \
    && grep -qx "Move $OUTR/v0.1.0 aside (never delete it), then run ship again." "$NF" && pass "under ship, $1: refused at C3, nothing public; move the build aside" || fail "$1: rc=$r $(lastline)"
}
printf 'cd "%s/v0.1.0" && sort -r -k2 SHA256SUMS > S && mv S SHA256SUMS\n' "$OUTR" > "$FX/afterbuild"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/afterbuild"
cr "a SHA256SUMS that is not the build's (reordered)" "SHA256SUMS is not the one the build wrote"
printf 'echo "# edited" >> "%s/v0.1.0/sheepr.rb"\n' "$OUTR" > "$FX/afterbuild"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/afterbuild"
cr "the out dir's cask edited" "is not the cask the tag renders"
: > "$FX/npmcheck.nostamp"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/npmcheck.nostamp"
[ $r = 1 ] && grep -q "npm-check has not passed on" "$FX/o" && ! grep -q -e 'push --porcelain --atomic' -e '^npm publish' -e '^gh api -X POST' "$FX/calls" \
  && ! grep -q "Move $OUTR/v0.1.0 aside" "$NF" && grep -qx 'When the cause above is fixed, run ship again.' "$NF" \
  && pass "under ship, no npm-check stamp: refused at C3, nothing public; class fix, no move aside (REV 12b rule 22)" || fail "no npm-check stamp: rc=$r $(lastline)"
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
c1_=$(grep -c '"\$@" 8>&- 9>&- ;;' "$RSX"); c2_=$(grep -c '"\$@" --userconfig="\$u" 8>&- 9>&- )$' "$RSX")
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
