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
standin docker 'exit 0'
standin npmcheck 'exit 1'
standin build 'exit 1'
standin gh 'exit 1'
standin npm 'exit 1'
standin curl 'exit 1'
# $GITCMD's stand-in: `remote get-url` answered with the GitHub spelling ($FX/pushurl, $FX/fetchurl);
# push, fetch and ls-remote forwarded to /usr/bin/git, with only github.com/lukaso/sheepr rewritten
# (to $FX/updir, origin's bare repo by default); $FX/dryextra adds a line to a dry-run push;
# $FX/onpush runs once before the first real push
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
extra=""
if [ "\$1" = push ]; then
  case " \$* " in *" --dry-run "*) [ -e "$FX/dryextra" ] && extra=1 ;; *) [ -e "$FX/onpush" ] && [ ! -e "$FX/onpush.done" ] && { : > "$FX/onpush.done"; sh "$FX/onpush"; } ;; esac
fi
[ -z "\$c" ] || set -- -C "\$c" "\$@"
GIT_CONFIG_NOSYSTEM=1 /usr/bin/git "\$@"; r=\$?
[ -z "\$extra" ] || printf '*\trefs/heads/x:refs/heads/x\t[new branch]\n'
exit \$r
EOF
chmod +x "$S/sgit"

ship() { # args... -> rc; output in $FX/o. The default stand-ins; NO: names whose variable is left out;
         # SETX: one more assignment
  rm -f "$FX/calls" "$FX/pathcalls"
  set -- SR_SHIP_DRY_BUILD="$S/build" SR_SHIP_DRY_NPMCHECK="$S/npmcheck" SR_SHIP_DRY_NOTIFY="$S/notify" SR_SHIP_DRY_CAFFEINATE="$S/caffeinate" \
    SR_SHIP_DRY_IDENTITY="$S/identity" SR_SHIP_DRY_DOCKER="$S/docker" SR_PUBLISH_DRY_GH="$S/gh" SR_PUBLISH_DRY_GIT="$S/sgit" \
    SR_PUBLISH_DRY_NPM="$S/npm" SR_PUBLISH_DRY_CURL="$S/curl" "$@"
  envs=""; for a; do case $a in *=*) k=${a%%=*}; case " ${NO:-} " in *" $k "*) continue ;; esac; envs="$envs
$a" ;; esac; done
  # the assignments as arguments to env, one per line (a value may hold spaces)
  printf '%s\n' "$envs" | sed '/^$/d' > "$FX/envs"
  (cd "$REPO" && IFS='
'; no_osascript env -i PATH="$B:/usr/bin:/bin" HOME="$FX/ghome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    $(cat "$FX/envs") ${SETX:+"$SETX"} sh scripts/release.sh __ship-dry --out "${OUT:-$OUTR}" "${TAG:-v0.1.0}") > "$FX/o" 2>&1
}
nopath() { [ ! -s "$FX/pathcalls" ]; }

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
reached_a4() { ! grep -q -e 'is not lukaso/sheepr' -e 'push URL' -e 'ssh host alias' -e 'disagree' -e 'diverged' -e 'dry-run push' -e "is not $1's" -e 'cannot' "$FX/o"; }
rm -rf "${OUTR:?}"; ship; r=$?
WTP='/private/tmp/sr-ship\.[A-Za-z0-9]*/tree'
grep -q "^sgit -C $WTP push --dry-run --porcelain --atomic --no-follow-tags origin $C:refs/heads/main $T:refs/tags/v0.1.0\$" "$FX/calls" \
  && pass "the dry-run push: exactly main at the tag's commit and the tag object, atomic, --no-follow-tags, from the frozen tree" || fail "the dry-run push: $(grep 'push' "$FX/calls" | head -2 | tr '\n' ' ') $(lastline)"
grep -q "^sgit -C $WTP fetch -q origin main\$" "$FX/calls" && pass "origin's main fetched with its refspec, in the frozen tree" || fail "the fetch: $(grep fetch "$FX/calls" | head -1)"
grep -q "^sgit -C $WTP ls-remote origin refs/heads/main refs/tags/v0\.1\.0\*\$" "$FX/calls" && grep -q "^sgit -C $WTP ls-remote https://github.com/lukaso/sheepr refs/heads/main refs/tags/v0\.1\.0\*\$" "$FX/calls" \
  && pass "ls-remote of origin and of github.com/lukaso/sheepr" || fail "ls-remote: $(grep ls-remote "$FX/calls" | tr '\n' ' ')"
[ "$(g rev-parse -q --verify refs/tags/v0.1.0)" = "$T" ] && pass "the unpushed tag survives the fetch (fetch.prune and pruneTags on)" || fail "the local tag is gone"
[ -z "$(git --git-dir="$FX/origin.git" for-each-ref refs/tags)" ] && [ "$(git --git-dir="$FX/origin.git" rev-parse refs/heads/main)" = "$BASE" ] \
  && pass "nothing reached origin (a dry run only, so far)" || fail "origin: $(git --git-dir="$FX/origin.git" for-each-ref | tr '\n' ' ')"
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
# an rc tag of this version on origin only (github.com/lukaso/sheepr a second bare repo, with the
# same main and no rc tag): the glob lists it, and the checks ignore it (agreement, the remote tag)
rm -rf "${FX:?}/origin2.git"; git init -q --bare "$FX/origin2.git" && g push -q --no-follow-tags "file://$FX/origin2.git" "$BASE:refs/heads/main" \
  && g push -q --no-follow-tags origin "$BASE:refs/tags/v0.1.0-rc.1" || exit 3
echo "file://$FX/origin2.git" > "$FX/updir"; rm -rf "${OUTR:?}"; ship; r=$?; rm -f "$FX/updir"
grep -q 'push --dry-run' "$FX/calls" && reached_a4 v0.1.0 && pass "an rc tag of this version on origin only: ignored, the checks go on" || fail "rc tag on origin: $(lastline)"
git --git-dir="$FX/origin.git" tag -d v0.1.0-rc.1 >/dev/null || exit 3
# the text: no push, fetch or ls-remote git call in release.sh outside $GITCMD (the pattern: the
# word git, then a subcommand among them; a planted line is caught)
gitnet() { grep -n -E '(^|[^A-Za-z_$"])git( -C [^ ]+| -c [^ ]+)* (push|fetch|ls-remote)( |$)' "$1" | grep -v '^[0-9]*: *#'; }
[ -z "$(gitnet "$RS")" ] && pass "release.sh makes no push, fetch or ls-remote but through \$GITCMD" || fail "git network calls: $(gitnet "$RS" | head -2 | tr '\n' ' ')"
printf '  git -C "$root" fetch origin main\n' > "$FX/planted.sh"; [ -n "$(gitnet "$FX/planted.sh")" ] && pass "control: a planted 'git -C \"\$root\" fetch origin main' is caught" || fail "control: the planted line is not caught"
finish
