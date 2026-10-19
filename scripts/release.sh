#!/bin/sh
# The sheepr release (PHASE3.md S2). Run from a clean checkout of the tag.
#
#   release.sh check vX.Y.Z[-rc.N]                    the checks only
#   release.sh build [--out DIR] vTAG                 the unsigned artifacts (the agent may run it)
#   release.sh build --sign [--no-notarize] [--out DIR] vTAG
#                                                     the signed, notarized release (the operator)
#   release.sh npm-check [--out DIR] vTAG             check the npm tarballs; first (publish needs it)
#   release.sh publish [--out DIR] vTAG               publish a built release on GitHub, then its
#                                                     Homebrew cask (a final tag; the operator)
#   release.sh publish-cask [--out DIR] vTAG          the Homebrew cask alone, for a release that is
#                                                     public (a retry after exit 5; the operator)
#   release.sh publish-npm [--out DIR] vTAG           verify, then publish the four npm packages (the operator)
#   release.sh verify [--out DIR] vTAG                the release's facts from its archive (read-only)
#   release.sh ship [--out DIR] vTAG                  the whole release of a final tag in one run, the
#                                                     human steps grouped (the operator; the ship plan)
#
# ship (PHASE3.md §5): asks for the tag once, then, in one run: the pre-flight (the checks; this
# release.sh is the tag's; origin is lukaso/sheepr and a dry-run push of main and the tag passes;
# nothing of the version is public on GitHub, the tap or npm, and it is newer than each one's
# latest; the tap and npm's owners; the build's preconditions), the build when $out/vTAG does not
# exist (the keychain password), npm-check, every check publish makes, its own npm login (the browser,
# into ship's own file $out/.vTAG.npm/npmrc, never the operator's: REV 12), the push, the platform
# packages, publish with the cask, the main package, and its logout. It reads its helpers from a
# detached worktree of the tag; one ship or publish-npm per out dir ($out/.ship.lock, never taken
# over); the Mac stays awake (caffeinate) until it
# ends; notifications (scripts/lib/notify.sh) announce each human step and the end. It refuses an
# rc tag (an rc, and a backport, use the separate entries), and anything of the version already
# public. After a stop it prints what to run next, built from its own record ($out/.vTAG.ship-progress),
# and writes it to $out/vTAG.ship-next.txt (a refusal because something is public, or one before
# that check, keeps an earlier run's file); a release done removes it. It takes nothing from the
# environment: `__ship-dry` (the cells) takes its stand-ins from SR_SHIP_DRY_BUILD, SR_SHIP_DRY_NPMCHECK,
# SR_SHIP_DRY_NOTIFY, SR_SHIP_DRY_CAFFEINATE, SR_SHIP_DRY_IDENTITY, SR_SHIP_DRY_DOCKER and
# SR_PUBLISH_DRY_GH, _GIT, _NPM, _CURL and _VERIFIED, each checked as a stand-in.
#
# The checks (check, build): the tag is vX.Y.Z or vX.Y.Z-rc.N; the tree is clean (no change, no
# untracked file); HEAD is the tag's commit; the tag's Cargo.toml and Cargo.lock say X.Y.Z; the tag's
# scripts/release.conf SR_BUILD_COUNTER is above the previous tag's (the highest tag below this
# one, an -rc sorting before its final).
#
# `build --sign`, `publish`, `publish-cask`, `publish-npm` and `ship` refuse under the test environment (any SHEEPR_TEST_* variable) and
# without a terminal (stdin and /dev/tty); `publish`, `publish-cask`, `publish-npm` and `ship` also read the typed tag from
# /dev/tty, their human confirmation before anything goes public (`publish` asks twice, `ship` once). That is a guard against mistakes
# only: a pty passes it (PHASE3.md §1.2). `build --sign` asks for no tag, and its Developer ID
# signing runs with no prompt in both modes: the gate against an unattended Apple submission is the
# notary keychain's own password, asked for by sign.sh's unlock (D2 step 3); `--no-notarize` (a
# marked control, never submitted) has no human input at all.
#
# Exit codes: 0 done; 1 a check failed or a step failed (ship and publish-npm: also a release done whose
# npm logout failed); 2 usage; 3 refused in a test environment; 4 refused without a terminal (or
# the typed tag did not match); 5 (publish) the release is public but its Homebrew cask is not
# updated: `release.sh publish-cask --out DIR vTAG` does that step alone (ship stops there with 1
# and names it).
set -u
# one collation and one message language for every sort and comparison (the operator's locale sorts
# "SHA256SUMS" after "install.sh"; measured)
LC_ALL=C; export LC_ALL
DRYHOME=""   # set only by the dry entries (__publish-dry, __publish-cask-dry, __publish-npm-dry); never inherited (their EXIT traps remove it)
# release.sh's own, never inherited and never exported (unset first: a value from the environment
# would stay exported): shipping (yes only under ship: publish_exec asks no second confirmation and
# publish_check requires verify's binding); npm_part (publish_npm_exec's sub-mode: platform, main,
# or empty for today's order); NOTIFY (the notifier publish_npm_exec calls: the real notify.sh only
# in a real entry, a stand-in in a dry one; empty refuses)
# ship's tools come from variables of release.sh's own too, each set by an entry (the real ones in
# the real entries, stand-ins in the dry ones), never from the environment: SHIP_BUILD (the build
# child), SHIP_NPMCHECK, SHIP_VERIFY, CAFFEINATE, SHIP_IDENTITY, SHIP_DOCKER, and GH, GITCMD, NPM,
# CURL with their classes; dryentry (yes in a dry entry: real_tools refuses there); ship's own state
unset shipping npm_part NOTIFY SHIP_BUILD SHIP_NPMCHECK SHIP_VERIFY CAFFEINATE SHIP_IDENTITY SHIP_DOCKER \
  GH GITCMD NPM NPMC CURL CURLC NETC DRY dryentry shipprog shipcause shipcls ship_mh shipok pnin pnlock npm_endrc npmuc ship_gk
shipping=no npm_part="" NOTIFY="" SHIP_BUILD="" SHIP_NPMCHECK="" SHIP_VERIFY="" CAFFEINATE="" SHIP_IDENTITY="" SHIP_DOCKER=""
GH="" GITCMD="" NPM="" NPMC="" CURL="" CURLC="" NETC="" DRY="" dryentry=no shipprog="" shipcause="" shipcls="" ship_mh="" shipok=no pnin=no pnlock=no npm_endrc=0 npmuc="" ship_gk=""
root=$(cd "$(dirname "$0")/.." && pwd -P) || exit 1
# the one file this script sources from the checkout before ship's frozen tree (every later source
# command reads the frozen tree under ship); ship compares it, with every file under scripts/, with
# the tag's bytes
sourced=scripts/lib/sigs.sh
. "$root/$sourced" || exit 1   # SIGS: the signals every cleanup trap here catches (ship's parent adds PIPE)
# fput FILE FORMAT [ARG...]: FILE holds exactly what printf FORMAT ARG... makes, or 1. fout FILE COMMAND
# [ARG...]: FILE holds exactly COMMAND's output (written, then COMMAND run again and compared), or 1.
# Every file this script writes and later reads, hashes or publishes goes through one of them, or its
# text stays in a variable (PLAN-ship.md REV 12b rule 20; the census row in t_ship_dry names the files
# kept otherwise, each with its reason): /usr/bin/printf and shasum exit 0 when a full disk took none of
# the bytes (r17b F1, measured on HFS+ and APFS), and bash 3.2's builtin printf keeps a failed write's
# bytes for the next write (r16b F2), so the bytes are read back
fput() { f_=$1; shift; /usr/bin/printf "$@" > "$f_" 2>/dev/null; /usr/bin/printf "$@" | /usr/bin/cmp -s - "$f_"; }
fout() { f_=$1; shift; "$@" > "$f_" && "$@" | /usr/bin/cmp -s - "$f_"; }
usage() { echo "usage: release.sh check|build|npm-check|publish|publish-cask|publish-npm|verify|ship [--sign] [--no-notarize] [--out DIR] vTAG" >&2; exit 2; }
# redact TEXT: every URL's userinfo replaced by <redacted>, so a text still says one was there: in
# scheme://userinfo@host it runs to the authority's last @ (a password may hold one), and in the scp
# form userinfo@host:path one with a password (a colon) is replaced too; an image digest
# (name:tag@sha256:<64 hex>) is not one. The ssh user git alone is kept: ship's own accepted spellings
# name it. An insteadOf rule puts a credential in what `git remote
# get-url` answers, and a tool may name such a URL in its own message: neither is ever printed,
# written to the next file or kept as the cause (die and the exit-5 text pass it here). And npm's
# /-/user/token/<token> (npm logout's request URL names the token it sends, and npm masks only its own
# npm_ shape): the token replaced by <redacted> (REV 11 rule 5)
redact() { printf '%s' "$*" | sed -E -e 's#@(sha256:[0-9a-f]{64})#<sr-digest>\1#g' -e 's#(/-/user/token/)[^[:space:]]*#\1<redacted>#g' \
  -e 's#([A-Za-z][A-Za-z0-9+.-]*://)([^/[:space:]]{4,}|[^/[:space:]]{1,2}|[^g/[:space:]][^/[:space:]]{2}|g[^i/[:space:]][^/[:space:]]|gi[^t/[:space:]])@#\1<redacted>@#g' \
  -e "s#(^|[[:space:]'\"(<])[^/[:space:]'\"(<]*:[^/[:space:]]*@([A-Za-z0-9._-]+:)#\\1<redacted>@\\2#g" -e 's#<sr-digest>#@#g'; }
# urluser URL: its userinfo, up to the last @ of its authority (scheme://userinfo@host/..., or the
# scp form userinfo@host:path), or nothing
urluser() {
  case $1 in *://*) a_=${1#*://} ;; *) a_=$1 ;; esac
  a_=${a_%%/*}
  case $a_ in *@*) printf '%s' "${a_%@*}" ;; esac
}
# errcut FILE BYTES: a tool's stderr as one line of a cause, at most BYTES: its error lines first
# (npm's `npm error` and `npm ERR!`, git's and gh's `error:` and `fatal:`), then its other lines in
# order, so no warning ahead of them pushes them out of the cut; npm's ANSI colour dropped; and npm's
# advice to run a credential command dropped (npmadv)
errcut() {
  e_=$(printf '\033') ep_='^(npm error|npm ERR!|error:|fatal:)'
  ec_=$(sed -e "s/$e_\[[0-9;]*[A-Za-z]//g" "$1" 2>/dev/null | npmadv); [ -n "$ec_" ] || return 0
  { printf '%s\n' "$ec_" | grep -E "$ep_"; printf '%s\n' "$ec_" | grep -vE "$ep_"; } | head -c "$2" | tr '\n' ' '
}
# npmadv: stdin without npm's advice to run a credential command: a line naming npm login, adduser,
# logout, token or config, or "logging in again" (npm's E401 and ENEEDAUTH words: notes/r17a/np/t2, t3).
# Following it, npm login writes the operator's ~/.npmrc (REV 12b rule 27); ship and publish-npm log in
# with their own file
npmadv() { grep -vE 'npm (login|adduser|logout|token|config)|logging in again'; }
die() { printf '\n' > /dev/null 2>&1; m_=$(redact "$*"); echo "release: $m_" >&2; [ -z "$shipcause" ] || [ -s "$shipcause" ] || fput "$shipcause" '%s\n' "$m_" || rm -f "$shipcause"; exit 1; }   # under ship the first cause is kept (a phase subshell's own, not the parent's summary); the drain first: see ship_exit
# next_hint TEXT [UNDER-SHIP]: a clause that names the entry to run next; under ship it is left out
# (or replaced by UNDER-SHIP: ship's stop text names what to run, from the run's own record), never
# the remedy around it
next_hint() { if [ "$shipping" = yes ]; then printf '%s' "${2:-}"; else printf '%s' "$1"; fi; }
# dq TEXT: TEXT as one single-quoted shell word, each ' written as '\'' (the one character single
# quotes cannot hold), for a runnable line that names a path: a line must run as printed from any
# directory, whatever the path holds, pasted into an interactive shell too (in double quotes, zsh and
# bash expand !x and !! there; r12b F6). No command substitution, so a trailing newline is kept
dq() {
  r_=$1 o_="" q_="'"
  while :; do
    case $r_ in
      *"$q_"*) o_=$o_${r_%%"$q_"*}"'\\''"; r_=${r_#*"$q_"} ;;
      *) break ;;
    esac
  done
  printf "'%s%s'" "$o_" "$r_"
}
stopclass() { [ -z "$shipcls" ] || fput "$shipcls" '%s\n' "$1" || { rm -f "$shipcls"; return 1; }; }   # ship's stop text: what kind of stop (no-op outside ship); a class that did not land: no class file, and 1

[ $# -ge 1 ] || usage
sub=$1; shift
sign=no nonot=no out=${HOME:-}/sheepr-release tag=""
while [ $# -gt 0 ]; do
  case $1 in
    --sign) sign=yes ;;
    --no-notarize) nonot=yes ;;
    --out) [ $# -ge 2 ] || usage; out=$2; shift ;;
    -*) usage ;;
    *) [ -z "$tag" ] || usage; tag=$1 ;;
  esac
  shift
done
[ -n "$tag" ] || usage
# --out, absolute from here on, for every entry: some steps run in other directories (the planner in
# the tree's root, npm pack in its own), and one relative spelling must name one directory
[ -n "$out" ] || usage
case $out in /*) ;; *) out=$(pwd -P)/$out || exit 1 ;; esac
# ... and physical (cd -P) once it exists (here, and in ship_run right after it makes it): npm resolves a
# path by its text, the kernel by its links, so out/lnk/.. would name two directories, ship's own npm file
# in one and npm's in the other (r17a F5; PLAN-ship.md REV 12b rule 24)
[ ! -d "$out" ] || out=$(cd -P -- "$out" && pwd -P) || exit 1
case $sub in
  check|build|publish|publish-cask|publish-npm|npm-check|verify|ship|__publish-dry|__publish-cask-dry|__publish-npm-dry|__ship-dry|__npm-env|__curl-env|__tool-class|__class-verify|__class-npm-check) ;;
  *) usage ;;
esac
[ $sign = no ] || [ "$sub" = build ] || usage
[ $nonot = no ] || [ $sign = yes ] || usage

# the gate of the operator-only entries
if { [ "$sub" = build ] && [ $sign = yes ]; } || [ "$sub" = publish ] || [ "$sub" = publish-cask ] || [ "$sub" = publish-npm ] || [ "$sub" = ship ]; then
  # the system's env and grep, the grep with no environment: neither a tool on PATH nor a variable
  # it reads (GREP_OPTIONS) can hide the test environment; only grep's "no match" (1) lets it on,
  # so a grep that fails refuses too
  /usr/bin/env | /usr/bin/env -i /usr/bin/grep -q '^SHEEPR_TEST_'; g=$?
  if [ $g != 1 ]; then
    echo "release: refused: a test environment (SHEEPR_TEST_*) is set$( [ $g = 0 ] || echo ", or it cannot be checked (grep exit $g)")" >&2; exit 3
  fi
  if ! [ -t 0 ] || ! (: < /dev/tty) 2>/dev/null; then
    echo "release: refused: $sub$( [ $sign = yes ] && echo ' --sign') needs a terminal" >&2; exit 4
  fi
  # publish, publish-cask and publish-npm make a release public: the typed tag is their human confirmation. A
  # signed build asks for nothing here: the notary keychain's own password, typed at the terminal,
  # is its gate (operator, 2026-10-06)
  if [ "$sub" = ship ]; then
    # ship's one question covers every step that makes the release public (publish asks no second one)
    printf 'release: ship %s: build, sign and notarize it, push main and the tag, publish it on GitHub, update lukaso/homebrew-tap and publish the four npm packages. Type the tag to go on: ' "$tag" > /dev/tty
    IFS= read -r answer < /dev/tty || exit 4
    [ "$answer" = "$tag" ] || { echo "release: not confirmed" >&2; exit 4; }
  elif [ "$sub" != build ]; then
    printf 'release: %s %s. Type the tag to go on: ' "$sub" "$tag" > /dev/tty
    IFS= read -r answer < /dev/tty || exit 4
    [ "$answer" = "$tag" ] || { echo "release: not confirmed" >&2; exit 4; }
  fi
fi

# --- the checks ---------------------------------------------------------------------------------
tagre='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.[1-9][0-9]*)?$'
valid() { printf '%s\n' "$1" | grep -Eq "$tagre" && [ "$(printf '%s' "$1" | wc -l | tr -d ' ')" = 0 ]; }
counter_at() { # tag -> its SR_BUILD_COUNTER (empty if none)
  git -C "$root" show "refs/tags/$1:scripts/release.conf" 2>/dev/null | sed -n 's/^SR_BUILD_COUNTER=\([0-9][0-9]*\)$/\1/p' | head -1
}
checks() {
  valid "$tag" || die "the tag '$tag' is not vX.Y.Z or vX.Y.Z-rc.N"
  commit=$(git -C "$root" rev-parse -q --verify "refs/tags/$tag^{commit}") || die "no tag $tag"
  [ -z "$(git -C "$root" status --porcelain)" ] || die "the tree is not clean (a change or an untracked file)"
  [ "$(git -C "$root" rev-parse HEAD)" = "$commit" ] || die "HEAD is not $tag"
  xyz=${tag#v}; xyz=${xyz%%-*}
  v=$(git -C "$root" show "refs/tags/$tag:Cargo.toml" | sed -n 's/^version = "\(.*\)"$/\1/p' | head -1)
  [ "$v" = "$xyz" ] || die "Cargo.toml says $v, the tag $xyz"
  lv=$(git -C "$root" show "refs/tags/$tag:Cargo.lock" | awk 'p && /^version = /{gsub(/"/,"",$3); print $3; exit} /^name = "sheepr"$/{p=1}')
  [ "$lv" = "$xyz" ] || die "Cargo.lock records sheepr $lv, not $xyz. Update it with this, then commit it:
  cd $(dq "$root") && cargo build"
  # a final release's CHANGELOG entry carries its date (an rc's may still say "not yet released")
  case $tag in *-rc.*) ;; *)
    xre=$(printf %s "$xyz" | sed 's/\./\\./g')
    cl=$(git -C "$root" show "refs/tags/$tag:CHANGELOG.md" 2>/dev/null)
    n=$(printf '%s\n' "$cl" | grep -Ec "^## $xre( |\$)")
    d=$(printf '%s\n' "$cl" | grep -Ec "^## $xre \(20[0-9]{2}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])\)\$")
    [ "$n" = 1 ] && [ "$d" = 1 ] || die "CHANGELOG.md needs exactly one '## $xyz (YYYY-MM-DD)' heading for $xyz, with a YYYY-MM-DD date (found $n heading(s) for $xyz, $d of them dated so; a trailing space or CR leaves one undated): fix it, commit, and tag again" ;;
  esac
  c=$(counter_at "$tag"); [ -n "$c" ] && [ "$c" -ge 1 ] || die "the tag has no SR_BUILD_COUNTER >= 1 in scripts/release.conf"
  prev=""
  for t in $(git -C "$root" -c versionsort.suffix=-rc tag -l 'v*' --sort=v:refname); do
    [ "$t" = "$tag" ] && break
    valid "$t" && prev=$t
  done
  if [ -n "$prev" ]; then
    pc=$(counter_at "$prev")
    [ -n "$pc" ] || die "the previous tag $prev has no readable SR_BUILD_COUNTER in scripts/release.conf (a tag from before a rename keeps it under another name): delete that tag, or tag a commit whose counter can be read"
    [ "$c" -gt "$pc" ] || die "the build counter $c is not above $prev's ($pc)"
  fi
  echo "release: $tag checks passed (commit $commit, build $c${prev:+, previous $prev})"
}

# --- tools, each with its own named environment (PHASE3.md §1.4) -------------------------------
# base: HOME PATH TMPDIR USER LOGNAME (+ DEVELOPER_DIR); cargo adds its own; docker adds its host
# and config. Nothing else of the caller's environment reaches a tool (never RUSTUP_TOOLCHAIN: it
# overrides rust-toolchain.toml).
tool() { # class command... (base: HOME PATH TMPDIR USER LOGNAME [DEVELOPER_DIR]; net: base and the
          # git/gh transport: SSH_AUTH_SOCK GIT_SSH_COMMAND GH_CONFIG_DIR, never GH_TOKEN, since gh
          # uses its own stored login)
  cls=$1; shift
  # (every arm closes fds 8 and 9, ship's own stdout and stderr kept for its handler: a child that
  # outlives its call, a daemon git starts, a stand-in's own child, must not hold ship's reader; r12b F3)
  case $cls in
    base) /usr/bin/env -i HOME="${HOME:-}" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" USER="${USER:-}" LOGNAME="${LOGNAME:-}" \
            ${DEVELOPER_DIR:+DEVELOPER_DIR="$DEVELOPER_DIR"} "$@" 8>&- 9>&- ;;
    net) /usr/bin/env -i HOME="${HOME:-}" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" USER="${USER:-}" LOGNAME="${LOGNAME:-}" \
            ${SSH_AUTH_SOCK:+SSH_AUTH_SOCK="$SSH_AUTH_SOCK"} ${GIT_SSH_COMMAND:+GIT_SSH_COMMAND="$GIT_SSH_COMMAND"} \
            ${GH_CONFIG_DIR:+GH_CONFIG_DIR="$GH_CONFIG_DIR"} ${XDG_CONFIG_HOME:+XDG_CONFIG_HOME="$XDG_CONFIG_HOME"} \
            ${HTTPS_PROXY:+HTTPS_PROXY="$HTTPS_PROXY"} ${https_proxy:+https_proxy="$https_proxy"} \
            ${HTTP_PROXY:+HTTP_PROXY="$HTTP_PROXY"} ${http_proxy:+http_proxy="$http_proxy"} \
            ${ALL_PROXY:+ALL_PROXY="$ALL_PROXY"} ${all_proxy:+all_proxy="$all_proxy"} \
            ${NO_PROXY:+NO_PROXY="$NO_PROXY"} ${no_proxy:+no_proxy="$no_proxy"} "$@" 8>&- 9>&- ;;
    # npm: ship's own npm file P (D/npmrc, D = $out/.$tag.npm; REV 12), never the operator's npmrc,
    # NPM_CONFIG_USERCONFIG's or npm_config_userconfig's file, or a token from the environment; the
    # dry run's npm gets a temp HOME too
    # web: curl's fetch of the public archive: base and the proxies, no credential and no git/gh
    # transport (CURL_HOME, which points curl at a curlrc, is dropped too; curl runs with -q)
    web) /usr/bin/env -i HOME="${HOME:-}" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" USER="${USER:-}" LOGNAME="${LOGNAME:-}" \
            ${HTTPS_PROXY:+HTTPS_PROXY="$HTTPS_PROXY"} ${https_proxy:+https_proxy="$https_proxy"} \
            ${HTTP_PROXY:+HTTP_PROXY="$HTTP_PROXY"} ${http_proxy:+http_proxy="$http_proxy"} \
            ${ALL_PROXY:+ALL_PROXY="$ALL_PROXY"} ${all_proxy:+all_proxy="$all_proxy"} \
            ${NO_PROXY:+NO_PROXY="$NO_PROXY"} ${no_proxy:+no_proxy="$no_proxy"} "$@" 8>&- 9>&- ;;
    npm) npm_env "${HOME:-}" "$@" ;;
    npmdry) npm_env "$DRYHOME" "$@" ;;   # (a dry entry's npm is a stand-in by path)
    # the dry publish: a fresh temp HOME and nothing else of the caller's, so even a real gh reached
    # through a stand-in would have no login
    dry) /usr/bin/env -i HOME="$DRYHOME" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" USER="${USER:-}" LOGNAME="${LOGNAME:-}" "$@" 8>&- 9>&- ;;
    # any other class, an empty one too (an entry that set none): nothing runs, and the step's own
    # failure path stops (a class that ran nothing and answered 0 let a step look done)
    *) echo "release: no tool class '$cls' for ${1:-a command}: nothing was run" >&2; return 2 ;;
  esac
}
npm_env() { # HOME command...: base, the proxies and a CA npm may need, never the git/gh transport
            # (one construction for the real run and the dry one), and ship's own npm file P
  h=$1 u=${npmuc:-${out%/}/.$tag.npm/npmrc} ca=${NODE_EXTRA_CA_CERTS:-}; shift
  # P (REV 12 rule 1): on npm's command line (--userconfig, which wins over every other place npm
  # looks) and in its environment; the operator's variables never reach npm (env -i). A relative CA
  # file is made absolute before the cd below, from a current directory that can be read
  case $u in /?*/.v*.npm/npmrc|/private/tmp/sr-publish.*/npmrc) ;; *) echo "release: no npm file for this run ('$u'): an entry must set out and tag" >&2; return 2 ;; esac
  case $ca in
    ''|/*) ;;
    *) p_=$(pwd -P 2>/dev/null) && [ -n "$p_" ] \
         || { echo "release: $(redact "NODE_EXTRA_CA_CERTS is '$ca', a relative path, and the current directory cannot be read: set it to an absolute path")" >&2; return 2; }
       ca=$p_/$ca ;;
  esac
  # npm runs from /: npm's project config (the .npmrc beside the nearest package.json or node_modules
  # above its cwd) wins over the userconfig, and / holds none (only root may write there). So npm
  # reads the builtin config, the userconfig, the global config and the env, and the userconfig wins
  # over all of them but the env, which holds no token, and --userconfig names P. The global config is
  # D/global (G: P's directory's), which ship never makes, so npm reads none: a token in the operator's
  # <prefix>/etc/npmrc was sent on every call before the login, and a logout of a P with no token line
  # ended it and rewrote that file (r17a F1; PLAN-ship.md REV 12b rule 25)
  # The npm_config_ pins: npm's default for every setting that changes what ship reads from npm (an
  # answer, an exit status, npm's error code, what reaches the registry), whatever the npmrc says (an
  # environment setting wins over it). The list is a census of npm 11.6.0's own config definitions,
  # run against a stand-in registry: color and loglevel (`npm error code X` in ANSI, or not written),
  # heading (`xyz error code X`), json (whoami's name in quotes), usage and dry-run (exit 0, nothing
  # published), tag (another dist-tag; a view without a version E404), offline and prefer-offline (a
  # view answered from the cache, over --prefer-online; the environment's prefer-offline also undoes
  # an npmrc's cache-min=9999, which npm reads after it, and a cache-min pin would make npm warn on
  # every call: it is deprecated), workspaces and provenance (every call, or the upload, fails),
  # update-notifier (a notice and a call of its own). What it leaves to the npmrc only makes a call
  # fail, in npm's own words: the network settings (proxy, TLS, retries, timeouts), the credentials,
  # and the keys an environment cannot reset (an empty value is ignored): workspace, provenance-file.
  # And logs-max=0 (REV 11a rule 10): npm's debug log, under its cache's _logs, is not written (npm
  # 10.9.2 writes the token of a failed logout's request into it; notes/r14a/np/t5;
  # notes/builder/np14/t14m5-*: npm 9.6.7, 10.5.2, 10.9.2 and 11.6.0 write no log file with it)
  ( cd / && exec /usr/bin/env -i HOME="$h" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" USER="${USER:-}" LOGNAME="${LOGNAME:-}" NPM_CONFIG_USERCONFIG="$u" NPM_CONFIG_GLOBALCONFIG="${u%/*}/global" \
    npm_config_color=false npm_config_loglevel=notice npm_config_heading=npm npm_config_json=false npm_config_usage=false \
    npm_config_dry_run=false npm_config_tag=latest npm_config_offline=false npm_config_prefer_offline=false \
    npm_config_workspaces=false npm_config_provenance=false npm_config_update_notifier=false npm_config_logs_max=0 \
    ${HTTPS_PROXY:+HTTPS_PROXY="$HTTPS_PROXY"} ${https_proxy:+https_proxy="$https_proxy"} \
    ${HTTP_PROXY:+HTTP_PROXY="$HTTP_PROXY"} ${http_proxy:+http_proxy="$http_proxy"} \
    ${NO_PROXY:+NO_PROXY="$NO_PROXY"} ${no_proxy:+no_proxy="$no_proxy"} \
    ${ca:+NODE_EXTRA_CA_CERTS="$ca"} "$@" --userconfig="$u" 8>&- 9>&- )
}
# git by name, for every git ship runs itself (not through tool): fds 8 and 9 closed, as in tool (git
# may leave a gc or maintenance child running, or start fsmonitor's daemon, with whatever it inherits)
git() { command git "$@" 8>&- 9>&-; }
cargo_env() { # CARGO_HOME TARGET_DIR command... (the cargo class)
  ch=$1 td=$2; shift 2
  tool base /usr/bin/env CARGO_HOME="$ch" CARGO_TARGET_DIR="$td" MACOSX_DEPLOYMENT_TARGET=12.0 \
    SHEEPR_COMMIT_OVERRIDE="$short" ${RUSTUP_HOME:+RUSTUP_HOME="$RUSTUP_HOME"} "$@"
}
docker_env() { # the docker class
  tool base /usr/bin/env ${DOCKER_HOST:+DOCKER_HOST="$DOCKER_HOST"} ${DOCKER_CONFIG:+DOCKER_CONFIG="$DOCKER_CONFIG"} docker "$@"
}

step() { echo "release: step: $*"; }
npy() { /usr/bin/env -u DEVELOPER_DIR -u SDKROOT -u TOOLCHAINS /usr/bin/python3 -I "$root/scripts/lib/npm-same.py" "$@" 8>&- 9>&-; }
npm_pack() { # the four npm tarballs into $dest; sets files_npm
  files_npm=$(tool base sh "$S/lib/npm-pack.sh" "${tag#v}" "$dest/sheepr-macos-universal.tar.gz" "$dest/sheepr-linux-aarch64" \
    "$dest/sheepr-linux-x86_64" "$src/npm/sheepr/bin/sheepr" "$dest") || return 1
  files_npm=$(printf '%s' "$files_npm" | tr '\n' ' ')
}

# --- the build (PHASE3.md S2): unsigned, signed, or the signed control ----------------------------
# The order (one sequence for every mode; PHASE3.md D2 step 3), so the operator types the notary
# keychain's password a few minutes after the start and can then leave:
#   1. the preconditions, each a refusal that leaves nothing in $out: the signing identity (signed
#      and control), the compiler pin, the Linux images;
#   2. the staging dir, $out/.<the output dir's name>-build.XXXXXX: every later step writes there;
#   3. the Linux `cargo fetch` (the only networked Linux step);
#   4. the macOS compile (its own fetch, then offline);
#   5. the bundle, or signing: sign.sh signs, asks for the password, notarizes, locks the notary
#      keychain again, staples and checks, all before it returns (the keychain is open only from
#      its unlock to its relock, before anything below runs);
#   6. the Linux builds, offline;
#   7. install.sh, the checksums, the cask, the npm packages, then MANIFEST.json;
#   8. one rename of the staging dir to the output dir ($out/vTAG, -unsigned or -control).
# A Linux failure after notarization costs a submission in Apple's history, a rebuild and the
# password again. A build that stops after step 2 keeps its staging dir (named in the message,
# never deleted here, never read by a later run); only a finished one has the output dir's name.
build_release() { # mode: unsigned | signed | control
  mode=$1
  case $mode in unsigned) final=$out/$tag-unsigned ;; signed) final=$out/$tag ;; control) final=$out/$tag-control ;; esac
  short=$(git -C "$root" rev-parse --short=12 "$commit")
  [ -e "$final" ] && die "$final exists (a release output directory is never reused)"
  scratch=$(mktemp -d /private/tmp/sr-release.XXXXXX 2>/dev/null || mktemp -d) || die "no scratch dir"
  dest=""   # the staging dir, once it is made (empty again after the rename)
  trap 'trap "" $SIGS; git -C "$root" worktree remove --force "$scratch/src" >/dev/null 2>&1; rm -rf "$scratch"
    [ -z "$dest" ] || echo "release: the build of $tag stopped; what it made is kept in $dest (never used by a later run: look at it, then remove it)" >&2' EXIT
  trap 'exit 1' $SIGS
  src=$scratch/src
  git -C "$root" worktree add -q --detach "$src" "refs/tags/$tag" || die "cannot make a worktree of $tag"
  [ -z "$(git -C "$src" status --porcelain --ignored)" ] || die "the worktree holds an untracked or ignored file"
  # from here on every helper and every setting comes from the tag's worktree, never the shared checkout
  S=$src/scripts
  . "$S/release.conf" || die "cannot read the tag's scripts/release.conf"
  pin=$(sed -n 's/^channel = "\(.*\)"$/\1/p' "$src/rust-toolchain.toml")
  [ -n "$pin" ] || die "the tag's rust-toolchain.toml names no channel"
  echo "release: building $tag ($short, $mode) in $src"

  # 1. the preconditions (a failure here leaves nothing in $out)
  if [ "$mode" != unsigned ]; then
    step "the signing identity"
    /usr/bin/security find-identity -v -p codesigning 2>/dev/null | grep -q " $SR_SIGN_IDENTITY " \
      || die "the signing identity $SR_SIGN_IDENTITY is not in the keychain"
  fi
  # the Mac compiler must be the pinned one (the Linux one is checked in each build below)
  step "the compiler"
  mkdir -p "$scratch/cargo-mac"
  rustc_mac=$(cd "$src" && cargo_env "$scratch/cargo-mac" "$scratch/target-mac" rustc -V) || die "rustc -V (mac)"
  case $rustc_mac in "rustc $pin "*) ;; *) die "the Mac compiler is '$rustc_mac', not the pinned $pin" ;; esac
  step "the Linux images"
  amd64=sr-amd64-base:$(printf %s "${SR_IMG_ALPINE##*sha256:}" | cut -c1-12)
  docker_env image inspect "$amd64" >/dev/null 2>&1 || amd64=sr-amd64-alpine:$(printf %s "${SR_IMG_ALPINE##*sha256:}" | cut -c1-12)
  # (the steps name the operator's checkout's test-all, a line each: under ship this build's root is its
  # frozen tree, a worktree of that checkout, gone when ship ends; git's common dir is the checkout's)
  ck_=$(cd "$root" && cd "$(git rev-parse --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd -P) || ck_=$root
  docker_env image inspect "$amd64" >/dev/null 2>&1 || die "no local amd64 image of the pinned base. Get it with one of these, then run the build again:
  $(dq "$ck_/test-all") pull
  $(dq "$ck_/test-all") amd64"
  for i in arm64 amd64; do
    docker_env image inspect "sr-scratch:empty-$i" >/dev/null 2>&1 && continue
    tar -cf "$scratch/empty.tar" -T /dev/null && docker_env import --platform "linux/$i" "$scratch/empty.tar" "sr-scratch:empty-$i" >/dev/null \
      || die "cannot make the empty image sr-scratch:empty-$i"
  done

  # 2. the staging dir: in $out (so the rename stays on one file system), hidden, never the output dir's name
  mkdir -p "$out" || die "cannot make $out"
  dest=$(mktemp -d "$out/.${final##*/}-build.XXXXXX") || { dest=""; die "cannot make a staging dir in $out"; }
  chmod "$(umask -S)" "$dest" || die "cannot set the mode of $dest"   # the output dir's mode, as a mkdir makes it (mktemp makes 700)
  echo "release: staging the build in $dest"

  # 3. the Linux fetch: the only networked Linux step, before the Mac work (the builds below are offline)
  step "the Linux fetch"
  mkdir -p "$scratch/cargo-linux"
  docker_env run --rm --pull=never -v "$src":/src:ro -v "$scratch/cargo-linux":/sdhome -e CARGO_HOME=/sdhome -w /src "$SR_IMG_ALPINE" \
    cargo fetch --locked -q || die "cargo fetch (linux)"

  # 4. the macOS compile: a fresh CARGO_HOME, fetched (Cargo checks each crate against Cargo.lock),
  # then offline
  step "the macOS compile"
  (cd "$src" && cargo_env "$scratch/cargo-mac" "$scratch/target-mac" cargo fetch --locked -q) || die "cargo fetch (mac)"
  for t in aarch64-apple-darwin x86_64-apple-darwin; do
    (cd "$src" && cargo_env "$scratch/cargo-mac" "$scratch/target-mac" cargo build -q --release --locked --offline --bin sheepr --target $t) \
      || die "cargo build $t"
  done

  # 5. macOS: the universal binary, then the bundle (unsigned), or signing (sign.sh)
  step "the macOS bundle"
  tool base lipo -create -output "$scratch/sheepr" "$scratch/target-mac/aarch64-apple-darwin/release/sheepr" \
    "$scratch/target-mac/x86_64-apple-darwin/release/sheepr" || die "lipo"
  for a in arm64 x86_64; do
    m=$(tool base vtool -arch $a -show-build "$scratch/sheepr" 2>/dev/null | awk '$1=="minos"{print $2; exit}')
    [ "$m" = 12.0 ] || die "the $a slice's minimum macOS is '$m', not 12.0"
  done
  xyz=${tag#v}; xyz=${xyz%%-*}
  if [ "$mode" = unsigned ]; then
    app=$(tool base sh "$S/bundle.sh" "$scratch/sheepr" "$scratch/bundle" "$xyz" "$c") || die "bundle.sh"
    mkdir -p "$scratch/rh"
    v=$(tool base sh "$S/lib/release-run.sh" "$scratch/rh" "$app/Contents/MacOS/sheepr" --version) || die "the Mac binary does not run"
    case $v in *"$short"*) ;; *) die "the Mac binary names another commit: $v" ;; esac
    tool base sh "$S/lib/archive.sh" make "$app" "$dest/sheepr-macos-universal.tar.gz" || die "archive"
    tool base sh "$S/lib/archive.sh" check "$dest/sheepr-macos-universal.tar.gz" || die "the archive fails its check"
  else
    step "signing"
    # sign.sh as a direct child (never in ( ), $( ) or a pipeline: it checks that its parent is
    # this process, by pid), with a nonce only this run knows, in a 0600 file of this user's
    nn=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    umask 077; fput "$scratch/nonce" '%s' "$nn" || die "cannot write $scratch/nonce"; umask 022
    set -- --bin "$scratch/sheepr" --version "$xyz" --build "$c" --tag "$tag" --commit "$short" --dest "$dest" --real "$nn" --nonce-file "$scratch/nonce" --parent-pid "$$"
    [ "$mode" = control ] && set -- "$@" --no-notarize
    # in the foreground: a background child of a non-interactive sh ignores INT, so ctrl-C would
    # not reach it (measured); env execs sign.sh, so its parent is still this shell
    /usr/bin/env -i HOME="${HOME:-}" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" USER="${USER:-}" LOGNAME="${LOGNAME:-}" \
      ${DEVELOPER_DIR:+DEVELOPER_DIR="$DEVELOPER_DIR"} "$S/lib/sign.sh" "$@" || die "signing failed"
  fi

  # 6. Linux, offline (the crates were fetched in step 3)
  step "the Linux builds (offline)"
  for a in aarch64 x86_64; do
    case $a in aarch64) img=$SR_IMG_ALPINE pf=linux/arm64 ;; x86_64) img=$amd64 pf=linux/amd64 ;; esac
    mkdir -p "$scratch/target-$a"
    docker_env run --rm --pull=never --network none --platform "$pf" -v "$src":/src:ro -v "$scratch/cargo-linux":/sdhome:ro \
      -v "$scratch/target-$a":/tgt -e CARGO_HOME=/sdhome -e CARGO_TARGET_DIR=/tgt -e SHEEPR_COMMIT_OVERRIDE="$short" -w /src "$img" \
      sh -c 'cargo build -q --release --locked --offline --bin sheepr && rustc -V > /tgt/rustc && uname -m > /tgt/arch && if readelf -l /tgt/release/sheepr | grep -q INTERP; then echo "a PT_INTERP" >&2; exit 1; fi' \
      || die "the Linux $a build"
    [ "$(cat "$scratch/target-$a/arch")" = "$a" ] || die "the $a build ran as $(cat "$scratch/target-$a/arch")"
    case $(cat "$scratch/target-$a/rustc") in "rustc $pin "*) ;; *) die "the Linux $a compiler is '$(cat "$scratch/target-$a/rustc")', not the pinned $pin" ;; esac
    cp "$scratch/target-$a/release/sheepr" "$dest/sheepr-linux-$a" || die "copy $a"
    v=$(docker_env run --rm --pull=never --network none --platform "$pf" -v "$dest/sheepr-linux-$a":/sheepr:ro "sr-scratch:empty-${pf#linux/}" /sheepr --version) \
      || die "the $a binary does not run in an empty image (not static?)"
    case $v in *"$short"*) ;; *) die "the $a binary names another commit: $v" ;; esac
  done

  # 7. install.sh (PHASE3.md S3), rendered with this release's version and the door
  step "install.sh, the checksums, the cask, the npm packages"
  files="sheepr-macos-universal.tar.gz sheepr-linux-aarch64 sheepr-linux-x86_64 install.sh"
  [ -f "$S/install.sh" ] || die "no scripts/install.sh at the tag"
  tool base sh "$S/lib/render-install.sh" "$S/install.sh" "${tag#v}" "$dest/install.sh" || die "render install.sh"
  ss_=$(cd "$dest" && shasum -a 256 $files) && fput "$dest/SHA256SUMS" '%s\n' "$ss_" || die "SHA256SUMS: cannot write it"
  # the Homebrew cask for lukaso/tap (PHASE3.md S4): a file for the tap, never uploaded
  tool base sh "$S/lib/render-cask.sh" "${tag#v}" "$(shasum -a 256 "$dest/sheepr-macos-universal.tar.gz" | cut -d' ' -f1)" "$dest/sheepr.rb" \
    || die "render the cask"
  npm_pack || die "npm packing"
  step "the manifest, then the rename"
  # (the manifest's text from a function: bash 3.2 misreads a case pattern's ) inside a $( ); then fput)
  mjson() {
    printf '{\n  "v": 1,\n  "tag": "%s",\n  "commit": "%s",\n  "mode": "%s",\n  "control": %s,\n  "files": [\n' "$tag" "$commit" "$mode" "$( [ "$mode" = control ] && echo true || echo false)"
    sep=""
    for f in $files $files_npm; do
      h=$(shasum -a 256 "$dest/$f" | cut -d' ' -f1)
      case $f in
        sheepr-macos-*) r=$rustc_mac ;;
        sheepr-linux-aarch64|sheepr-linux-x86_64) r=$(cat "$scratch/target-${f#sheepr-linux-}/rustc") ;;   # the binaries by name: the npm packages also start sheepr-linux-
        *) r="" ;;
      esac
      printf '%s    {"name": "%s", "sha256": "%s"%s}' "$sep" "$f" "$h" "${r:+, \"rustc\": \"$r\"}"
      sep=",
"
    done
    printf '\n  ]\n}\n'
  }
  mj_=$(mjson) && fput "$dest/MANIFEST.json" '%s\n' "$mj_" || die "cannot write the manifest"

  # 8. the rename. mv into a directory that exists puts the staging dir inside it and returns 0
  # (measured), so the output dir must not exist right before, and must be the staging dir (its
  # inode) right after; a build that went inside another directory is named there
  [ -e "$final" ] && die "$final appeared during the build; it is not this build (refused: nothing is moved into it)"
  si=$(ls -di "$dest" | awk '{print $1}'); [ -n "$si" ] || die "cannot read the staging dir's inode"
  mv "$dest" "$final" || die "cannot rename $dest to $final"
  if [ "$(ls -di "$final" | awk '{print $1}')" != "$si" ]; then
    in=$final/${dest##*/}; dest=""
    [ -e "$in" ] || in="(not found there)"
    die "$final appeared during the rename: this build went inside it, to $in; $final is not this build"
  fi
  dest=""
  echo "release: $tag built ($mode) in $final"
}

# --- publish: the thin executor behind the gate (PHASE3.md §1.2) ------------------------------
# The remote tag is read from github.com/lukaso/sheepr itself (the repository the release is
# made on), never from `origin`. GH and GITCMD are the gh and git to use: the real ones for
# publish; for __publish-dry (the cells), stand-ins under /private/tmp/sr-p3-fixtures.*, given by
# path, so the dry run can never reach the real gh.
UPSTREAM=https://github.com/lukaso/sheepr
confirm() { # prompt -> 0 on the tag typed back
  if [ "${DRY:-no}" = yes ]; then
    n=$(grep -c '^ask ' "${SR_ASK_RECORD:-/dev/null}" 2>/dev/null); n=${n:-0}
    a=$(sed -n "$((n + 1))p" "${SR_ASK_SCRIPT:-/dev/null}")
    echo "ask $1 -> $a" >> "${SR_ASK_RECORD:-/dev/null}"
  else
    printf '%s ' "$1" > /dev/tty; IFS= read -r a < /dev/tty || return 1
  fi
  [ "$a" = "$tag" ]
}
# npm-check's stamp (NPM-CHECKED in the output dir): the tag and the sha256 of the MANIFEST.json it
# passed on. npm is the last one-way step, so its check must pass before anything is public.
# MAN: the manifest these read: each entry's own private copy, taken before its first check (npm-check
# stamps that copy's hash; publish, publish-cask and publish-npm read their copy for every later
# hash, and publish's planner reads it too), so an archive and its manifest entry replaced together
# during a run do not match it. Empty: the output dir's.
MAN=""
# `verify`'s archive: verified=yes once it judged one, verified_ah that archive's sha256. publish and
# publish-cask then refuse a stamped manifest that names another hash for it. The dry entries skip
# verify; SR_PUBLISH_DRY_VERIFIED (a hash) stands in for it there, for the cells.
verified=no verified_ah=""
# sha256 FILE: its sha256 (64 hex digits), or nothing. A hash that cannot be read is no finding about
# the bytes: each caller that compares one stops with the fix class on nothing (r12b F1)
sha256() { h_=$(shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1); case $h_ in *[!0-9a-f]*) ;; *) [ ${#h_} = 64 ] && printf '%s' "$h_" ;; esac; }
hashof() { # FILE: its sha256, or a stop (fix): shasum gave no hash
  h_=$(sha256 "$1"); [ -n "$h_" ] || die "cannot read the sha256 of $1 (shasum gave no hash)"; printf '%s' "$h_"
}
# judged RC FILE PREFIX: 0 when a checking tool's failure is its verdict on the build's bytes: exit 1
# with a line of its own refusal (PREFIX) in FILE. A tool that cannot run (126, 127), a signal, a usage
# error, or no such line is no verdict (r12b F1)
judged() { [ "$1" = 1 ] && grep -q "^$3" "$2" 2>/dev/null; }
# rtfail RC TOOL TEXT [CLASS [TAIL]]: an Apple tool's refusal (rt_judge's status). Its own refusal (1):
# CLASS (content: a verdict on the bytes), TEXT, the tool's words, then TAIL. No verdict (2): no class,
# and the cause says TOOL gave none, never TEXT (a fixed verdict sentence there sent the build aside
# anyway; r13b F2). The tool's words ($RT_OUT, read here, before the check's temp dir goes) in the
# cause either way. spctl's refusal is class gatekeeper, a fix class (REV 11a rule 11, REV 12b rule 23):
# it judges only a bundle codesign's release requirement and stapler accepted, and after the push ship's
# stop text for it names no publish step; its TAIL (gkhint) says what to check (REV 11b rule 16)
rtfail() {
  w_=$(errcut "${RT_OUT:-/dev/null}" 300)
  if [ "$1" = 1 ]; then stopclass "${4:-content}"; die "$3 ($2: $w_)${5:-}"
  else die "$2 gave no verdict on the bundle (exit ${rt_rc:-?}${w_:+: $w_}): it could not judge it, which says nothing about the build"; fi
}
# gkhint ARCHIVE PATH: what follows spctl's words when Gatekeeper rejects a bundle codesign and stapler
# accepted (REV 11b rule 16): a rerun stops here again until Gatekeeper accepts it; what to check, each
# on a line of its own (the second unpacks ARCHIVE into a new temp dir, asks Gatekeeper about PATH
# there, ship's own copy being gone by then, and removes that dir: r16b F5); and the signing certificate's remedy (REV 12a): a rebuild
# only while ship knows nothing of the tag is public (under ship, before its push: its own phase, set by
# ship_run, never read from the record, which a full disk or a mode can hide: REV 12b rule 21); after the push,
# and in a standalone verify, npm-check or publish, only once a runnable ls-remote line shows the tag
# is not pushed (a pushed tag is never rebuilt: a new version). Never "expired": an expired
# certificate does not make Gatekeeper reject a notarized, timestamped build
gkhint() {
  printf '%s' ".
A rerun stops here again until Gatekeeper accepts the bundle. See what Gatekeeper says on this Mac with these (the second unpacks $(basename "$1") into a new temp dir, asks Gatekeeper about its bundle, and removes that dir):
  spctl --status
  d=\$(mktemp -d \"\${TMPDIR:-/tmp}/sheepr-gatekeeper.XXXXXX\") && tar -xzf $(dq "$1") -C \"\$d\" && spctl -a -vv -t exec \"\$d/$2\"; rm -rf \"\${d:?}\""
  if [ "$shipping" = yes ] && case ${phase:-} in preflight|build|checks|npm-check|npm-login) true ;; *) false ;; esac; then
    printf '%s' "
When the cause is a revoked signing certificate, move the build aside and rebuild it with a valid one."
  else
    gr_=$root; [ "$shipping" != yes ] || gr_=${oroot:-$root}   # (the operator's checkout: ship's root is its frozen tree)
    printf '%s' "
When the cause is a revoked signing certificate, first see whether $tag is pushed:
  git -C $(dq "$gr_") ls-remote origin refs/tags/$tag
If that prints nothing, $tag is not pushed yet: move the build aside and rebuild it with a valid certificate. If it prints a line, $tag is pushed: never rebuild $tag; release a new version."
  fi
}
stamp_line() { sh_=$(hashof "${MAN:-$1/MANIFEST.json}") || exit 1; printf '%s %s' "$tag" "$sh_"; }   # (in a $( ): its exit is the substitution's)
stamp_ok() { # dir -> 0 if npm-check passed on this tag and this manifest (a hash that cannot be read: a stop, fix)
  [ -f "$1/NPM-CHECKED" ] && [ -f "${MAN:-$1/MANIFEST.json}" ] || return 1
  sl_=$(stamp_line "$1") || exit 1
  [ "$(cat "$1/NPM-CHECKED")" = "$sl_" ]
}
man_hash() { # dir file -> the file's sha256 in MANIFEST.json (empty if it is not listed)
  sed -n "s/.*\"name\": \"$2\", \"sha256\": \"\([0-9a-f]\{64\}\)\".*/\1/p" "${MAN:-$1/MANIFEST.json}" | head -1
}
private_manifest() { # dir tmp: copy the output dir's MANIFEST.json into tmp (0700) and read it from there on
  # no manifest is a defect of the build (content); a copy that fails (a full or unwritable temp dir)
  # is not (r12b F1)
  [ -f "$1/MANIFEST.json" ] || { stopclass content; die "no MANIFEST.json in $1"; }
  cp "$1/MANIFEST.json" "$2/MANIFEST.json" 2>/dev/null || die "cannot copy $1/MANIFEST.json into $2"
  MAN=$2/MANIFEST.json
  # under ship: the manifest ship checked after the build (C1), and no other
  [ -z "$ship_mh" ] || { mh_=$(hashof "$MAN") || exit 1; [ "$mh_" = "$ship_mh" ]; } || { stopclass content; die "the manifest in $1 is not the one ship checked after the build (it changed)"; }
}
files_ok() { # dir -> 0 if every file MANIFEST.json lists is there and is its hash (npm-check's files)
  fs=$(sed -n 's/.*"name": "\([^"]*\)", "sha256": "[0-9a-f]\{64\}".*/\1/p' "${MAN:-$1/MANIFEST.json}")
  [ -n "$fs" ] || return 1
  for f in $fs; do
    fh_=""; [ ! -f "$1/$f" ] || { fh_=$(hashof "$1/$f") || exit 1; }
    [ -f "$1/$f" ] && [ "$fh_" = "$(man_hash "$1" "$f")" ] || { echo "release: $f is missing or not its manifest hash" >&2; return 1; }
  done
}
# publish_check: every check publish makes before a write, except the remote tag's (that is the
# planner's, in publish_exec): the private manifest, npm-check's stamp, the files, verify's binding,
# SHA256SUMS, npm's list and owners, the Homebrew cask's checks. It does not read the remote tag
# and writes nothing public; it does read the network (npm owner ls for the four names; the tap's
# cask and its write right, through gh). The planned ship runs it before its push (the ship plan,
# C3). It makes this run's private temp dir ($pt, removed at exit), sets what publish_exec goes on
# with (MAN, sums_h, cask, cask_put, ...) and returns 0 when every check passed. It replaces the
# caller's EXIT, HUP, INT and TERM traps with its own, so a caller with traps of its own (ship's C3)
# runs it in a subshell.
publish_check() { # dir
  d=$1
  pt=$(mktemp -d /private/tmp/sr-publish.XXXXXX) || die "no temp dir"
  drydir "$pt"
  trap 'trap "" $SIGS; rm -rf "$pt" ${DRYHOME:+"$DRYHOME"}' EXIT; trap 'rm -rf "$pt" ${DRYHOME:+"$DRYHOME"}; exit 1' $SIGS
  private_manifest "$d" "$pt"
  stamp_ok "$d" || { stopclass fix; die "npm-check has not passed on $d for this manifest$(next_hint "; run release.sh npm-check $tag first")"; }   # (the stamp is npm-check's record, not the build's bytes: REV 12b rule 22)
  files_ok "$d" || { stopclass content; die "a file npm-check checked has changed since (above)$(next_hint "; run release.sh npm-check $tag again")"; }
  [ "$shipping" = no ] || [ "$verified" = yes ] || die "verify has not judged the archive in this run; this step uploaded nothing"
  [ "$verified" = no ] || [ "$verified_ah" = "$(man_hash "$d" "$ARCHIVE")" ] \
    || { stopclass content; die "the archive verify judged is not the stamped manifest's (it changed since); this step uploaded nothing"; }
  # SHA256SUMS is not in the manifest: the build wrote it from those four files, in this order, so
  # its bytes follow from the manifest's hashes; nothing else is published, at any time. The bytes it
  # must hold are made in memory, never in a file (r17b F2: a temp dir with no room cut that file short)
  sums_=$(for x in sheepr-macos-universal.tar.gz sheepr-linux-aarch64 sheepr-linux-x86_64 install.sh; do
    printf '%s  %s\n' "$(man_hash "$d" "$x")" "$x"
  done)
  printf '%s\n' "$sums_" | cmp -s - "$d/SHA256SUMS" || { stopclass content; die "SHA256SUMS is not the one the build wrote (from MANIFEST.json's hashes)"; }
  sums_h=$(printf '%s\n' "$sums_" | shasum -a 256 | cut -d' ' -f1)
  # npm's owners of the four names, before any git or gh call: GitHub must not go public when npm
  # would then refuse (the first v0.1.0 did exactly that). On its own, publish never logs in: its npm
  # calls name an empty npm file of this run (npmuc), never P (an earlier run's P may hold a dead token)
  # and never the operator's; under ship they name P
  npm_list
  [ "$shipping" = yes ] || { : > "$pt/npmrc" || die "cannot make $pt/npmrc; this step uploaded nothing"; npmuc=$pt/npmrc; }
  npm_owners "$NPMC" "$NPM" "$pt"
  # the Homebrew cask's checks, also before anything is public: a final tag's cask is rendered,
  # the tap read and its write right checked, so a refusal there leaves nothing public
  case $tag in
    *-rc.*) cask=no; echo "release: an rc: the Homebrew cask is not touched" ;;
    *) cask=yes; cask_pre "$d" "$pt"
       # a backport (a final tag older than the tap's cask): published, the cask never moved back
       [ "$cask_put" = older ] && { cask=no; echo "release: $TAP's cask is $cask_tap, newer than $tag: the Homebrew cask is not touched"; } ;;
  esac
  return 0   # every check passed (a refusal dies above); publish_exec and ship test it
}
publish_exec() { # dir
  publish_check "$1" || die "the checks before publishing did not pass; this step uploaded nothing"
  lrt_=$(tool "$NETC" "$GITCMD" ls-remote "$UPSTREAM" "refs/tags/$tag*") || die "git ls-remote $UPSTREAM"
  fput "$pt/remote" '%s\n' "$lrt_" || die "cannot write $pt/remote"
  rl_=$(tool "$NETC" "$GH" api "repos/lukaso/sheepr/releases" --paginate --jq '.[].tag_name') || die "gh: cannot list the releases"
  fput "$pt/releases" '%s\n' "$rl_" || die "cannot write $pt/releases"
  (cd "$root" && sh scripts/release-plan.sh --out "$d" --manifest "$MAN" --tag "$tag" --remote "$pt/remote" --releases "$pt/releases") > "$pt/plan" || die "the planner refused"
  sh "$root/scripts/release-plan.sh" --validate "$pt/plan" || die "the plan does not validate"
  echo "release: the plan:"; sed 's/^/  /' "$pt/plan"
  set -- $(sed -n 's/^POST [^ ]* //p' "$pt/plan")
  id=$(tool "$NETC" "$GH" api -X POST repos/lukaso/sheepr/releases "$@" --jq .id) || die "gh: cannot make the draft"
  case $id in ''|*[!0-9]*) die "gh: no release id ($id)" ;; esac
  echo "release: draft $id made"
  for f in $(sed -n 's/^UPLOAD //p' "$pt/plan"); do
    tool "$NETC" "$GH" api -X POST -H 'Content-Type: application/octet-stream' \
      "https://uploads.github.com/repos/lukaso/sheepr/releases/$id/assets?name=$f" --input "$d/$f" --jq .id >/dev/null \
      || die "gh: upload of $f failed (the draft $id is not public; delete it on GitHub)"
  done
  tool "$NETC" "$GH" api "repos/lukaso/sheepr/releases/$id" --jq '.assets[] | "\(.id) \(.name)"' > "$pt/assets" || die "gh: cannot read the draft"
  [ "$(awk '{print $2}' "$pt/assets" | sort | tr '\n' ' ')" = "SHA256SUMS install.sh sheepr-linux-aarch64 sheepr-linux-x86_64 sheepr-macos-universal.tar.gz " ] \
    || die "the draft's assets are not exactly the five: $(awk '{print $2}' "$pt/assets" | tr '\n' ' ')"
  while read -r aid name; do
    tool "$NETC" "$GH" api -H 'Accept: application/octet-stream' "repos/lukaso/sheepr/releases/assets/$aid" > "$pt/dl" || die "gh: cannot download $name"
    # the build's bytes: the manifest's hash (SHA256SUMS: the bytes the build wrote, from it)
    if [ "$name" = SHA256SUMS ]; then
      [ "$(shasum -a 256 "$pt/dl" | cut -d' ' -f1)" = "$sums_h" ] || die "the uploaded SHA256SUMS is not the one the build wrote; the draft $id stays a draft"
      continue
    fi
    want=$(man_hash "$d" "$name")
    [ -n "$want" ] || die "$name has no manifest hash; the draft $id stays a draft"
    [ "$(shasum -a 256 "$pt/dl" | cut -d' ' -f1)" = "$want" ] || die "the uploaded $name is not the build's (its manifest hash); the draft $id stays a draft"
  done < "$pt/assets"
  lrt2_=$(tool "$NETC" "$GITCMD" ls-remote "$UPSTREAM" "refs/tags/$tag*") || die "git ls-remote $UPSTREAM"
  [ "$lrt2_" = "$lrt_" ] || die "the remote tag changed during the upload; the draft $id stays a draft"
  # the second confirmation; under ship its one confirmation, at the start, covers this step
  if [ "$shipping" = no ]; then
    confirm "release: the draft $id holds the five files, each matching. Type the tag again to make it public$( [ $cask = yes ] && [ "$cask_put" = yes ] && echo " and update $TAP"):" || die "not confirmed; the draft $id stays a draft"
  fi
  if ! tool "$NETC" "$GH" api -X PATCH "repos/lukaso/sheepr/releases/$id" -F draft=false >/dev/null; then
    # the request failed, but GitHub may have made the release public anyway: read it again
    st=$(tool "$NETC" "$GH" api "repos/lukaso/sheepr/releases/$id" --jq .draft) || st=""
    case $st in
      false) echo "release: the publish request failed, but $tag is public (the release reads draft: false)"
        [ $cask = no ] || cask_post "$d" "$pt" "releases/$id" cask_fail
        return 0 ;;
      true) die "gh: cannot publish the draft $id; it is still a draft.$(next_hint " Publish it on GitHub (Releases, the draft $tag, Publish release), or delete the draft and run publish again")" ;;
      *) die "gh: cannot publish the draft $id, and cannot read whether it is public: check it on GitHub" ;;
    esac
  fi
  echo "release: $tag published"
  [ $cask = no ] || cask_post "$d" "$pt" "releases/$id" cask_fail
}
# the real run's tools and classes, one definition for publish, publish-cask and __curl-env (which
# prints the curl class, so a cell sees the class the real entries use)
real_tools() {
  [ "$dryentry" = no ] || die "real_tools in a dry entry"
  GH=gh GITCMD=git NPM=npm NPMC=npm DRY=no NETC=net CURL=/usr/bin/curl CURLC=web
}
publish() {
  verify "$out/$tag"
  real_tools
  publish_exec "$out/$tag"
}
standins() { # VAR...: each names a stand-in for a dry run, or refuse
  # a stand-in is a script (not a symlink, not a binary), whose real directory is a fixture dir;
  # and every call runs with a fresh temp HOME and nothing else of the caller's (the `dry` class)
  for v in "$@"; do
    eval "p=\${$v:-}"
    # one string is checked and run: no control character (a trailing newline would be stripped
    # when the path is rebuilt, and another file would run)
    case $p in *[[:cntrl:]]*) die "$v holds a control character" ;; esac
    [ -n "$p" ] && [ -f "$p" ] && [ ! -L "$p" ] && [ -x "$p" ] || die "$v is not an executable file (and not a symlink)"
    pd=$(cd -P "$(dirname "$p")" 2>/dev/null && pwd -P) || die "$v: cannot resolve its directory"
    case $pd/ in /private/tmp/sr-p3-fixtures.*/) ;; *) die "$v must be a stand-in in a /private/tmp/sr-p3-fixtures.* directory, not in $pd" ;; esac
    [ "$(head -c 2 "$p")" = '#!' ] || die "$v must be a script stand-in"
    eval "$v=\$pd/\$(basename \"\$p\")"
  done
}
publish_dry() { # the cells' entry: stand-ins by path only, never the real gh; verify is not run
  dryentry=yes
  standins SR_PUBLISH_DRY_GH SR_PUBLISH_DRY_GIT SR_PUBLISH_DRY_NPM SR_PUBLISH_DRY_CURL
  DRYHOME=$(mktemp -d /private/tmp/sr-dryhome.XXXXXX) || die "no temp HOME"
  drydir "$DRYHOME"
  trap 'trap "" $SIGS; rm -rf "$DRYHOME"' EXIT; trap 'rm -rf "$DRYHOME"; exit 1' $SIGS   # right after mktemp: a death before the run's own trap leaves no temp HOME (a signal in between still can)
  echo "release: __publish-dry (stand-ins; verify not run; a temp HOME, $DRYHOME)"
  [ -z "${SR_PUBLISH_DRY_VERIFIED:-}" ] || verified=yes verified_ah=$SR_PUBLISH_DRY_VERIFIED
  # the cells' way into the shipping branches (only `yes` sets it; the planned ship sets shipping itself)
  [ "${SR_PUBLISH_DRY_SHIPPING:-}" = yes ] && shipping=yes
  GH=$SR_PUBLISH_DRY_GH GITCMD=$SR_PUBLISH_DRY_GIT NPM=$SR_PUBLISH_DRY_NPM NPMC=npmdry DRY=yes NETC=dry \
    CURL=$SR_PUBLISH_DRY_CURL CURLC=dry   # plain assignments: one before a function call is exported
  publish_exec "$out/$tag"
  rm -rf "$DRYHOME"
}

# --- the Homebrew cask (PHASE3.md §5 step 4): lukaso/homebrew-tap's Casks/sheepr.rb -------------
# Final tags only. `publish` does it once the release is public, `publish-cask` alone (a retry after
# publish's exit 5). The tap is read and written through GitHub's contents API with gh (the login
# that publishes): no clone, so no git identity, hook or credential helper is involved. The write
# carries the blob id of the file read (GitHub refuses it when the file changed since), and the
# file is read back at the commit the write made.
TAP=lukaso/homebrew-tap CASK=Casks/sheepr.rb ARCHIVE=sheepr-macos-universal.tar.gz
cask_fail() { # publish's failure after the PATCH: the release is public, its cask is not done (5)
  echo "release: $tag is public, but its Homebrew cask is not updated: $(redact "$*").$(next_hint " Run this:
  sh $(dq "$root/scripts/release.sh") publish-cask --out $(dq "$out") $tag")" >&2; exit 5
}
blob_id() { { printf 'blob %d\0' "$(wc -c < "$1" | tr -d ' ')"; cat "$1"; } | shasum -a 1 | cut -d' ' -f1; }   # git's id of a file's bytes
cask_pre() { # dir tmp: before anything is public; sets cask_put (yes|no) and cask_blob, or refuses (1)
  cd_=$1 ct=$2 xyz=${tag#v}
  # the cask the tag renders (the tag's own template and renderer, the archive's manifest hash)
  mkdir -p "$ct/src/scripts/lib" "$ct/src/packaging/homebrew" || die "no temp dir for the cask"
  fout "$ct/src/scripts/lib/render-cask.sh" git -C "$root" show "refs/tags/$tag:scripts/lib/render-cask.sh" \
    && fout "$ct/src/packaging/homebrew/sheepr.rb.in" git -C "$root" show "refs/tags/$tag:packaging/homebrew/sheepr.rb.in" || die "cannot read $tag's cask template (or write it into $ct)"
  ah=$(man_hash "$cd_" "$ARCHIVE"); [ -n "$ah" ] || { stopclass content; die "$ARCHIVE has no manifest hash"; }
  tool base sh "$ct/src/scripts/lib/render-cask.sh" "$xyz" "$ah" "$ct/cask.rb" || die "cannot render $tag's cask"
  cmp -s "$ct/cask.rb" "$cd_/sheepr.rb" || { stopclass content; die "$cd_/sheepr.rb is not the cask the tag renders (its template, the archive's manifest hash)"; }
  # from here on only this private copy is used (the PUT, the read back): the out dir may change
  # while the operator confirms
  # the render is this release's cask: one version line (brew builds the url from it), one sha256
  # line (the archive's), one url line (the release's archive); a template that hard-codes one of
  # them renders the same in the build, so the out dir alone would not show it
  for kv in "version|  version \"$xyz\"" "sha256|  sha256 \"$ah\"" "url|  url \"https://github.com/lukaso/sheepr/releases/download/v#{version}/$ARCHIVE\""; do
    k=${kv%%|*} want=${kv#*|}
    [ "$(grep -c "^  $k " "$ct/cask.rb")" = 1 ] && grep -qxF "$want" "$ct/cask.rb" || die "$tag's cask is not this release's: its $k line is not '$want' (exactly once)"
  done
  cask_ah=$ah   # the archive's hash as checked: nothing of the out dir is read after this
  # the tap's cask: exactly one version line, never newer than this tag; this version only as these bytes
  tool "$NETC" "$GH" api -H 'Accept: application/vnd.github.raw' "repos/$TAP/contents/$CASK" > "$ct/tap.rb" 2> "$ct/tap.err" || {
    grep -q 'HTTP 404' "$ct/tap.err" && die "$TAP has no $CASK (add it by hand once)"
    stopclass fix; die "gh: cannot read $TAP's $CASK ($(errcut "$ct/tap.err" 300))"; }
  [ "$(grep -c '^  version "' "$ct/tap.rb")" = 1 ] || { stopclass fix; die "$TAP's $CASK has not exactly one version line"; }
  tv=$(sed -n 's/^  version "\(.*\)"$/\1/p' "$ct/tap.rb")
  rel=$(sh "$root/scripts/lib/cask-version.sh" "$tv" "$xyz") || { stopclass fix; die "$TAP's $CASK has a version off the grammar ('$tv')"; }
  cask_blob=$(blob_id "$ct/tap.rb") cask_put=yes cask_tap=$tv
  case $rel in
    newer) ;;
    older) cask_put=older; return 0 ;;   # the caller decides: publish skips the cask, publish-cask refuses
    *) cmp -s "$ct/tap.rb" "$ct/cask.rb" && cask_put=no \
         || { stopclass fix; die "$TAP's cask is $xyz with sha256 $(sed -n 's/^  sha256 "\(.*\)"$/\1/p' "$ct/tap.rb"), but this build's archive is $ah: refused (a swapped asset, or a tap edited by hand)"; } ;;
  esac
  pp=$(tool "$NETC" "$GH" api "repos/$TAP" --jq .permissions.push 2> "$ct/perm.err") || { stopclass fix; die "gh: cannot read $TAP ($(errcut "$ct/perm.err" 300))"; }
  [ "$pp" = true ] || { stopclass fix; die "this gh login cannot write $TAP"; }
}
cask_post() { # dir tmp release-path fail: the release is public; the cask put and read back
  ct=$2 rp=$3 f=$4 xyz=${tag#v} ah=$cask_ah   # the hash checked before; the out dir ($1) is not read again
  tool "$NETC" "$GH" api "repos/lukaso/sheepr/$rp" --jq '.draft, (.assets[] | select(.name == "'"$ARCHIVE"'" and .state == "uploaded") | .id)' \
    > "$ct/rel" 2> "$ct/rel.err" || {
    grep -q 'HTTP 404' "$ct/rel.err" && $f "no published release $tag on GitHub"
    $f "gh: cannot read the release ($(errcut "$ct/rel.err" 300))"; }
  [ "$(sed -n 1p "$ct/rel")" = false ] || $f "the release reads as a draft"
  [ "$(sed 1d "$ct/rel" | wc -l | tr -d ' ')" = 1 ] || $f "the release has not exactly one uploaded $ARCHIVE"
  aid=$(sed -n 2p "$ct/rel"); case $aid in ''|*[!0-9]*) $f "no asset id ($aid)" ;; esac
  tool "$NETC" "$GH" api -H 'Accept: application/octet-stream' "repos/lukaso/sheepr/releases/assets/$aid" > "$ct/dl" || $f "gh: cannot download $ARCHIVE"
  [ "$(shasum -a 256 "$ct/dl" | cut -d' ' -f1)" = "$ah" ] || $f "the published $ARCHIVE is not the build's (its manifest hash)"
  # what brew downloads: the cask's url (checked before), with no credentials (-q first: no curlrc) and https only
  url=https://github.com/lukaso/sheepr/releases/download/$tag/$ARCHIVE
  tool "$CURLC" "$CURL" -q -fsSL --proto =https "$url" > "$ct/brew" || $f "curl cannot fetch $url"
  [ "$(shasum -a 256 "$ct/brew" | cut -d' ' -f1)" = "$ah" ] || $f "$url is not the build's archive"
  if [ "$cask_put" = yes ]; then
    c=$(tool "$NETC" "$GH" api -X PUT "repos/$TAP/contents/$CASK" -f "message=sheepr $xyz" -f "content=$(base64 < "$ct/cask.rb" | tr -d '\n')" \
      -f "sha=$cask_blob" --jq .commit.sha 2> "$ct/put.err") || $f "gh: the cask write was refused ($(errcut "$ct/put.err" 300); a 409 means the tap changed since it was read)"
    case $c in ''|*[!0-9a-f]*) $f "no commit id from the cask write ($c)" ;; esac
    tool "$NETC" "$GH" api -H 'Accept: application/vnd.github.raw' "repos/$TAP/contents/$CASK?ref=$c" > "$ct/back" || $f "gh: cannot read the cask back"
  else
    echo "release: $TAP already holds this cask"
    tool "$NETC" "$GH" api -H 'Accept: application/vnd.github.raw' "repos/$TAP/contents/$CASK" > "$ct/back" || $f "gh: cannot read the cask back"
  fi
  cmp -s "$ct/back" "$ct/cask.rb" || $f "the cask read back from $TAP is not the one put"
  echo "release: $TAP's $CASK is $xyz"
}
publish_cask_exec() { # dir: the cask step alone, for a release that is already public
  d=$1
  case $tag in *-rc.*) die "an rc: the Homebrew cask follows final releases only" ;; esac
  pt=$(mktemp -d /private/tmp/sr-publish.XXXXXX) || die "no temp dir"
  drydir "$pt"
  trap 'trap "" $SIGS; rm -rf "$pt" ${DRYHOME:+"$DRYHOME"}' EXIT; trap 'rm -rf "$pt" ${DRYHOME:+"$DRYHOME"}; exit 1' $SIGS
  private_manifest "$d" "$pt"; m=$MAN
  mf() { sed -n "s/^ *\"$1\": *\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}$/\1/p" "$m" | head -1; }
  [ "$(mf tag)" = "$tag" ] && [ "$(mf mode)" = signed ] && [ "$(mf control)" = false ] \
    || die "the manifest is not $tag's signed build, or it is a control build"
  lc=$(git -C "$root" rev-parse -q --verify "refs/tags/$tag^{commit}") || die "no local tag $tag"
  [ "$(mf commit)" = "$lc" ] || die "the manifest's commit $(mf commit) is not $tag's ($lc)"
  files_ok "$d" || die "a file the manifest lists is missing or changed"
  [ "$verified" = no ] || [ "$verified_ah" = "$(man_hash "$d" "$ARCHIVE")" ] \
    || die "the archive verify judged is not the manifest's (it changed since); nothing is written"
  cask_pre "$d" "$pt"
  [ "$cask_put" = older ] && die "$TAP's cask is $cask_tap, newer than $tag: the cask is never moved back; nothing to do"
  cask_post "$d" "$pt" "releases/tags/$tag" die
}
publish_cask() {
  verify "$out/$tag"   # the archive the cask points at, by the real tools, as publish checks it
  real_tools
  publish_cask_exec "$out/$tag"
}
publish_cask_dry() { # the cells' entry: stand-ins by path only, never the real gh or curl
  dryentry=yes
  standins SR_PUBLISH_DRY_GH SR_PUBLISH_DRY_CURL
  DRYHOME=$(mktemp -d /private/tmp/sr-dryhome.XXXXXX) || die "no temp HOME"
  drydir "$DRYHOME"
  trap 'trap "" $SIGS; rm -rf "$DRYHOME"' EXIT; trap 'rm -rf "$DRYHOME"; exit 1' $SIGS
  echo "release: __publish-cask-dry (stand-ins; a temp HOME, $DRYHOME)"
  [ -z "${SR_PUBLISH_DRY_VERIFIED:-}" ] || verified=yes verified_ah=$SR_PUBLISH_DRY_VERIFIED
  GH=$SR_PUBLISH_DRY_GH NETC=dry CURL=$SR_PUBLISH_DRY_CURL CURLC=dry   # plain assignments, as above
  publish_cask_exec "$out/$tag"
  rm -rf "$DRYHOME"
}

# --- publish-npm: the four packages (PHASE3.md §5), after publish --------------------------------
# Platform packages first, the main one last (its optional dependencies name them). Only the files
# in <out>/vTAG, each hashed against its manifest entry just before its upload. A version already on
# npm is skipped when its integrity is this file's (a resumed run) and refused otherwise. An rc goes
# under the `next` dist-tag: npm makes a version without a tag `latest`. npm's login is publish-npm's
# own (ship's, under ship), in its own file (REV 12), never the operator's and never a token from the
# environment. On its own it runs verify first, as publish and publish-cask do, and refuses a manifest
# whose archive is not the one verify judged (REV 12b rule 23: after ship stopped at Gatekeeper's refusal,
# publish-npm must not publish the main package of a build Gatekeeper rejects).
NPMREG=https://registry.npmjs.org/   # pinned on the command line: an npmrc's registry or scope registry never applies
# npm_visible NAME VERSION INTEGRITY [WHOSE]: wait until npm serves this version with this file
# (WHOSE names that file in a refusal; default: the one just published). npm scans
# every upload before it shows it, and then publishes it, holds it for review or blocks it (npm,
# 2026-07-28: typically about five minutes, up to 15 or more); measured 2026-10-04, two of the four
# placeholders showed about two minutes after "Your package is being processed". The main package's
# optional dependencies name the platform packages, so each upload waits until its file is there
# before the next one. Another file there is refused at once. Installs read npm's abbreviated record,
# which a cache may hold up to 300 s longer: an install in the first minutes may still miss a package.
# One definition of the limit for the real and the dry run (the dry run's cell gives `sleep` a
# stand-in); set here, so an exported NPM_WAIT_MAX cannot shorten it. It counts the waits between
# views (NPM_WAIT_MAX seconds of them); each view's own time comes on top.
NPM_WAIT_MAX=1800 NPM_WAIT_STEP=10
readonly NPM_WAIT_MAX NPM_WAIT_STEP   # a second assignment (an entry, a caller) fails loudly
# notafter PACKAGE: what this step did not upload after PACKAGE, true in every mode: under main the
# batch (C6, or an earlier publish-npm) uploaded the platform packages, and this step uploads only
# the main package; otherwise this step uploads in SR_NPM_PKGS's order (mainp: publish_npm_exec's)
notafter() {
  if [ "$npm_part" = main ] && [ "$1" != "$mainp" ]; then printf '%s' "this step did not upload the main package"
  else printf '%s' "this step uploaded nothing after it"; fi
}
npm_visible() {
  w=0
  while :; do
    vout=$(tool "$NETC" "$NPM" view --json --prefer-online --registry="$NPMREG" --scope= "$1@$2" dist.integrity 2> "$pc/err"); r=$?
    got=$(printf '%s' "$vout" | tr -d ' "\n\r')
    if [ $r = 0 ] && [ -n "$got" ]; then
      [ "$got" = "$3" ] && return 0
      die "$1@$2 is on npm with another file ($got) than ${4:-the one just published}; $(notafter "$1")"
    fi
    [ "$w" -lt "$NPM_WAIT_MAX" ] || die "$1@$2 is not visible on npm after $((NPM_WAIT_MAX / NPM_WAIT_STEP)) waits of $NPM_WAIT_STEP s, $NPM_WAIT_MAX s in all, each view's own time on top (the last view: $(npmcode "$pc/err" | grep . || echo "exit $r, an empty answer")). npm scans every upload before it shows it: it may still be scanning, or it held the version for review or blocked it. Look at https://www.npmjs.com/package/$1 and npm's email to ${SR_NPM_USER:-the owner}$(next_hint "; once it shows, run publish-npm again (it skips a version already there with this file)"). A blocked version needs a new version number. $(notafter "$1" | sed 's/^t/T/')"
    sleep "$NPM_WAIT_STEP"; w=$((w + NPM_WAIT_STEP))
  done
}
# npm_list: release.conf's SR_NPM_PKGS must be the four packages, the main one last (npm-same.py
# list: the check npm-check makes). publish and publish-npm read the list again, and npm-check's
# stamp does not bind it, so each checks it before any npm call.
npm_list() {
  . "$root/scripts/release.conf" || die "cannot read scripts/release.conf"
  npy list "${SR_NPM_PKGS:-}" || die "scripts/release.conf's SR_NPM_PKGS is refused (above); this step uploaded nothing"
}
# npm_owners CLASS NPM TMPDIR: npm's owners of each name in SR_NPM_PKGS must include SR_NPM_USER
# (release.conf). Measured (npm 11.6.0): `owner ls NAME` needs no login and prints `user <email>`
# lines, or exits 1 with E404 for a name not on npm. A name not on npm yet is refused: npm may
# reject it as too similar to another, or someone may take it first; each name is reserved first
# (a 0.0.0 placeholder). publish runs this before any GitHub call, publish-npm before any upload.
npm_owners() { # after npm_list, which read release.conf: the list checked is the list used (one read)
  [ -n "${SR_NPM_USER:-}" ] && [ -n "${SR_NPM_PKGS:-}" ] || die "scripts/release.conf names no SR_NPM_USER or SR_NPM_PKGS (npm_list runs first)"
  for p in $SR_NPM_PKGS; do
    own=$(tool "$1" "$2" owner ls "$p" --registry="$NPMREG" --scope= 2> "$3/err"); r=$?
    if [ $r != 0 ]; then
      grep -q 'E404' "$3/err" && { stopclass fix; die "$p is not on npm yet: reserve the name first (publish a 0.0.0 placeholder as $SR_NPM_USER)$(next_hint ", then run this again"); this step uploaded nothing"; }
      stopclass fix; die "cannot read the owners of $p on npm (npm owner ls: exit $r, $(errcut "$3/err" 200)); this step uploaded nothing"
    fi
    printf '%s\n' "$own" | awk -v me="$SR_NPM_USER" '$1 == me {f = 1} END {exit !f}' \
      || { stopclass fix; die "$p on npm belongs to $(printf '%s\n' "$own" | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//'), not to $SR_NPM_USER; this step uploaded nothing"; }
  done
}
# notify KEY: the operator's attention, through $NOTIFY with the tag; it never stops the run. A dry
# entry's notifier always runs with SR_NOTIFY_OSASCRIPT set (empty), so even notify.sh given there
# by mistake shows nothing real; a real entry's runs in the base class (no SR_NOTIFY_OSASCRIPT)
notify() {
  # a stop's notification also gets the out dir: its text names the next file's full path; when that
  # file could not be written (ship_exit's wrote), -: the text names no file
  case $1 in failed-*|logout-failed*) if [ "${wrote:-no}" = yes ]; then set -- "$1" "$tag" "$out"; else set -- "$1" "$tag" -; fi ;; *) set -- "$1" "$tag" ;; esac
  if [ -n "$DRYHOME" ]; then tool dry /usr/bin/env SR_NOTIFY_OSASCRIPT= "$NOTIFY" "$@"
  else tool base "$NOTIFY" "$@"; fi || echo "release: the notification '$1' failed; the run goes on" >&2
}
# publish_npm_exec DIR. npm_part (release.sh's own, never inherited): empty, today's order (each
# package asked for, uploaded, then waited for until npm shows it; the main one last); platform (the
# batch under ship): the platform packages not on npm yet, uploaded back to back, nothing waited
# for, the main one untouched; main: wait until npm shows each platform package (never uploading
# one: a version npm still scans answers E404), then the main one, uploaded and waited for. In
# both orders the main package goes up only once npm shows the packages it names.
publish_npm_exec() { # dir
  d=$1 m=$1/MANIFEST.json nv=${tag#v}
  [ -n "$NOTIFY" ] || die "no notifier (an entry must set NOTIFY); this step uploaded nothing"
  case $npm_part in ''|platform|main) ;; *) die "npm_part '$npm_part' is not platform, main or empty; this step uploaded nothing" ;; esac
  pc=$(mktemp -d /private/tmp/sr-npmpub.XXXXXX) || die "no temp dir"   # the private copies npm gets
  drydir "$pc"
  # (on its own: the logout of its own session first, then the lock: npm_end, REV 12 rule 5)
  trap 'trap "" $SIGS; npm_end "$pc"; rm -rf "$pc" ${DRYHOME:+"$DRYHOME"}; [ "$npm_endrc" = 0 ] || exit 1' EXIT; trap 'npm_end "$pc"; rm -rf "$pc" ${DRYHOME:+"$DRYHOME"}; exit 1' $SIGS
  chmod 700 "$pc" || die "cannot make $pc private"
  private_manifest "$d" "$pc"; m=$MAN
  stamp_ok "$d" || die "npm-check has not passed on $d for this manifest$(next_hint "; run release.sh npm-check $tag first")"
  mf() { sed -n "s/^ *\"$1\": *\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}$/\1/p" "$m" | head -1; }
  [ "$(mf tag)" = "$tag" ] && [ "$(mf mode)" = signed ] && [ "$(mf control)" = false ] \
    || die "the manifest is not $tag's signed build, or it is a control build"
  lc=$(git -C "$root" rev-parse -q --verify "refs/tags/$tag^{commit}") || die "no local tag $tag"
  [ "$(mf commit)" = "$lc" ] || die "the manifest's commit $(mf commit) is not $tag's ($lc)"
  # every file npm-check checked, before the first npm call (each is checked again just before its upload)
  files_ok "$d" || die "a file npm-check checked has changed since (above); this step uploaded nothing.$(next_hint " Run release.sh npm-check $tag again")"
  # (on its own: the archive verify judged, bound to this manifest, as publish binds it; REV 12b rule 23)
  [ "$verified" = no ] || [ "$verified_ah" = "$(man_hash "$d" "$ARCHIVE")" ] \
    || die "the archive verify judged is not the manifest's (it changed since); this step uploaded nothing"
  # who may publish, before any view or upload: npm must say the user is release.conf's (measured,
  # npm 11.6.0: `whoami` prints the user, or exits 1 with ENEEDAUTH), and that user must own every name
  npm_list
  # on its own, publish-npm holds ship's lock (P is in the out dir: one ship or publish-npm at a time),
  # logs out of an earlier P, and logs in itself (REV 12 rules 2, 3, 5); under ship, the parent did
  if [ "$shipping" != yes ]; then
    npm_lock publish-npm
    npm_pre "$pc" publish-npm "this step uploaded nothing"
    notify npm-login
    pnin=yes; npm_login "$pc" publish-npm "this step uploaded nothing"
  fi
  # under ship: the parent's session (C4) must name SR_NPM_USER still
  if [ "$shipping" = yes ]; then
    me=$(tool "$NETC" "$NPM" whoami --registry="$NPMREG" --scope= 2> "$pc/err") || die "npm whoami failed; this step uploaded nothing ($(errcut "$pc/err" 200))"
    [ "$me" = "${SR_NPM_USER:-}" ] || die "logged in to npm as $(printf '%s' "$me" | head -c 100 | tr '\n' ' '), but the packages belong to ${SR_NPM_USER:-nobody named in release.conf}; this step uploaded nothing"
  fi
  npm_owners "$NETC" "$NPM" "$pc"
  case $tag in *-rc.*) set -- --tag next ;; *) set -- ;; esac
  mainp=""; for p in $SR_NPM_PKGS; do mainp=$p; done   # the main package: the last (npm_list checked the list)
  asked=no waited=no
  for p in $SR_NPM_PKGS; do
    [ "$p" = "$mainp" ] && [ "$npm_part" = platform ] && continue
    f=$p-$nv.tgz
    # npm gets a private copy, hashed against the manifest: the bytes checked are the bytes sent
    cp "$d/$f" "$pc/$f" 2>/dev/null || die "no $f in $d; $(notafter "$p")"
    h=$(shasum -a 256 "$pc/$f" | cut -d' ' -f1)
    [ -n "$h" ] && [ "$h" = "$(man_hash "$d" "$f")" ] \
      || die "$f does not match its manifest hash (changed after npm-check?); $(notafter "$p")"
    want=$(npy integrity "$pc/$f") || die "cannot hash $f"
    if [ "$p" != "$mainp" ] && [ "$npm_part" = main ]; then
      npm_visible "$p" "$nv" "$want" "this build's (uploaded earlier, by the batch)"; waited=yes
      echo "release: $p@$nv: npm shows this file"
      continue
    fi
    # on npm already? measured (npm 11.6.0): a version there is exit 0 and its integrity (quoted
    # under --json); one that is not, exit 1 with E404; anything else cannot say
    vout=$(tool "$NETC" "$NPM" view --json --prefer-online --registry="$NPMREG" --scope= "$p@$nv" dist.integrity 2> "$pc/err"); r=$?
    got=$(printf '%s' "$vout" | tr -d ' "\n\r')
    if [ $r = 0 ] && [ -n "$got" ]; then
      [ "$got" = "$want" ] || die "$p@$nv is already on npm with another file ($got); $(notafter "$p")"
      echo "release: $p@$nv is already on npm (the same file): skipped"
      continue
    elif ! { [ $r != 0 ] && printf '%s\n' "$vout" | cat - "$pc/err" | grep -q 'E404'; }; then
      die "cannot tell whether $p@$nv is on npm (npm view: exit $r, $(errcut "$pc/err" 300)); $(notafter "$p")"
    fi
    # the operator may have left during a wait: a notification before each upload that follows one
    # (npm-approve-again for the main package, npm-approve-next for another), none before the first;
    # the batch (platform, no waits) gets one before its first upload
    if [ "$npm_part" = platform ]; then [ $asked = yes ] || { notify npm-approve; asked=yes; }
    elif [ $waited = yes ] && [ "$p" = "$mainp" ]; then notify npm-approve-again
    elif [ $waited = yes ]; then notify npm-approve-next; fi
    case $npm_part in platform) progress "start npm-platform $p" ;; main) progress "start npm-main" ;; esac   # right before the upload
    # a refused upload stops at once, whatever npm says: its answer to a second upload while it still
    # scans the first one is not measured, so the run does not guess which refusal is which
    tool "$NETC" "$NPM" publish --access public --registry="$NPMREG" --scope= "$@" "$pc/$f" \
      || die "npm refused the upload of $f, or its login step failed (above); npm's own advice there to log in again does not apply: $( [ "$shipping" = yes ] && echo ship || echo publish-npm) logs in with its own file.$( [ "$npm_part" = platform ] && echo " These uploads go back to back: npm may also refuse an upload while it still scans an earlier package of the batch (not measured).") A browser login or 2FA approval that failed or timed out$(next_hint ": run publish-npm again (it skips a version already there with this file)" " may be the cause"). If this run or an earlier one uploaded $p@$nv, npm may still be scanning it (about five minutes, up to 15 or more), or it held it for review or blocked it: look at https://www.npmjs.com/package/$p and npm's email to ${SR_NPM_USER:-the owner}$(next_hint ", wait, then run publish-npm again"). A blocked version needs a new version number. $(notafter "$p" | sed 's/^t/T/')"
    if [ "$npm_part" = platform ]; then
      progress "done npm-platform $p"
      echo "release: $p@$nv uploaded (npm scans it before it shows it; not waited for here)"
      continue
    fi
    npm_visible "$p" "$nv" "$want"; waited=yes
    echo "release: $p@$nv published, and npm shows this file"
  done
  if [ "$npm_part" = platform ]; then echo "release: the platform packages of $tag are uploaded; npm shows each one after its scan"
  else echo "release: the four npm packages of $tag are on npm"; fi
}
# the entries set their tools with plain assignments: an assignment before a function call is
# exported, and stays, under the system's sh (measured). NPMC with NETC: the logins and logouts of P
# (npm_pre, npm_login, npm_end) run through NPMC
publish_npm() { verify "$out/$tag"; NPM=npm NETC=npm NPMC=npm NOTIFY=$root/scripts/lib/notify.sh; publish_npm_exec "$out/$tag"; }
publish_npm_dry() { # the cells' entry: a stand-in npm by path only, never the real one
  dryentry=yes
  standins SR_PUBLISH_DRY_NPM
  # the notifier, when one is given: a stand-in, never the tree's own notify.sh (the real notifier).
  # None given leaves NOTIFY empty, which publish_npm_exec refuses before any npm call
  if [ -n "${SR_PUBLISH_DRY_NOTIFY+set}" ]; then
    standins SR_PUBLISH_DRY_NOTIFY
    cmp -s "$SR_PUBLISH_DRY_NOTIFY" "$root/scripts/lib/notify.sh" && die "SR_PUBLISH_DRY_NOTIFY is the real notify.sh, not a stand-in"
    NOTIFY=$SR_PUBLISH_DRY_NOTIFY
  fi
  DRYHOME=$(mktemp -d /private/tmp/sr-dryhome.XXXXXX) || die "no temp HOME"
  drydir "$DRYHOME"
  trap 'trap "" $SIGS; rm -rf "$DRYHOME"' EXIT; trap 'rm -rf "$DRYHOME"; exit 1' $SIGS   # right after mktemp: a death before the run's own trap leaves no temp HOME (a signal in between still can)
  echo "release: __publish-npm-dry (a stand-in npm and notifier; a temp HOME, $DRYHOME)"
  # the cells' choice of the sub-mode, only when they make one (ship sets npm_part itself); otherwise
  # release.sh's own empty one, as in the real entry. publish_npm_exec checks the value
  [ -z "${SR_PUBLISH_DRY_NPM_PART+set}" ] || npm_part=$SR_PUBLISH_DRY_NPM_PART
  [ -z "${SR_PUBLISH_DRY_VERIFIED:-}" ] || verified=yes verified_ah=$SR_PUBLISH_DRY_VERIFIED   # (verify's stand-in, as in __publish-dry)
  NPM=$SR_PUBLISH_DRY_NPM NETC=npmdry NPMC=npmdry
  publish_npm_exec "$out/$tag"
  rm -rf "$DRYHOME"
}

# --- npm-check: before any `npm publish` (PHASE3.md §5 step 5) ----------------------------------
npm_check() { # dir
  . "$root/scripts/release.conf" || die "cannot read scripts/release.conf"
  . "$root/scripts/lib/realtools.sh" || die "cannot read realtools.sh"
  d=$1 nv=${tag#v}
  # the content class only at a check that found a defect in the build's bytes (r12b F1)
  [ -f "$d/MANIFEST.json" ] || { stopclass content; die "no $d/MANIFEST.json"; }
  # a stamp from an earlier pass never outlives a check that does not pass
  rm -f "$d/NPM-CHECKED" || die "cannot remove $d/NPM-CHECKED"
  nt=/private/tmp/sr-npmcheck.$$.$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')
  trap 'trap "" $SIGS; rm -rf "$nt"' EXIT; trap 'rm -rf "$nt"; exit 1' $SIGS
  mkdir -m 700 "$nt" "$nt/p" "$nt/ref" || die "no temp dir"
  RT_OUT=$nt/rt.out   # the Apple tools' words (rt_judge)
  # the manifest every check reads, and the stamp names: a private copy, taken first (a manifest
  # replaced during the check gets no stamp that publish accepts)
  private_manifest "$d" "$nt"; m=$MAN
  mode=$(sed -n 's/^ *"mode": *"\([^"]*\)",*$/\1/p' "$m"); ctl=$(sed -n 's/^ *"control": *\([a-z]*\),*$/\1/p' "$m")
  mtag=$(sed -n 's/^ *"tag": *"\([^"]*\)",*$/\1/p' "$m")
  [ "$mtag" = "$tag" ] || { stopclass content; die "the manifest is for $mtag, not $tag"; }
  [ "$mode" = signed ] || { stopclass content; die "the manifest's mode is '$mode', not signed"; }
  [ "$ctl" = false ] || { stopclass content; die "the manifest is a control build"; }
  [ -n "${SR_NPM_PKGS:-}" ] || die "scripts/release.conf names no SR_NPM_PKGS"
  for f in sheepr-macos-universal.tar.gz sheepr-linux-aarch64 sheepr-linux-x86_64 $(for p in $SR_NPM_PKGS; do printf '%s-%s.tgz\n' "$p" "$nv"; done); do
    [ -f "$d/$f" ] || { stopclass content; die "missing $f (a file of the build, or a package of release.conf's SR_NPM_PKGS)"; }
    h=$(hashof "$d/$f") || exit 1
    grep -q "\"name\": \"$f\", \"sha256\": \"$h\"" "$m" || { stopclass content; die "$f does not match its manifest hash"; }
  done
  # the four packages, read raw, before anything unpacks them (npm-same.py says why), against the
  # tag's license texts, README and launcher
  for x in LICENSE-MIT LICENSE-APACHE README.md npm/sheepr/bin/sheepr; do
    fout "$nt/ref/$(basename "$x")" git -C "$root" show "refs/tags/$tag:$x" 2>/dev/null || die "cannot read $x at $tag (or write it into $nt/ref)"
  done
  mv "$nt/ref/sheepr" "$nt/ref/launcher"
  dt=$d/sheepr-darwin-universal-$nv.tgz
  npy packages "$d" "$nv" "$nt/ref" "$SR_NPM_PKGS" 2> "$nt/npy.err"; r_=$?; cat "$nt/npy.err" >&2
  [ $r_ = 0 ] || { judged $r_ "$nt/npy.err" 'npm-same: ' && stopclass content; die "an npm package is refused (above)"; }
  # the bundle the real tools judge: an archive tar cannot list is a defect of its bytes; one that
  # lists and does not unpack is the temp dir's (full, unwritable)
  /usr/bin/tar -tzf "$dt" > /dev/null 2>&1; r_=$?   # (a tar a signal stopped, above 125: no finding)
  [ $r_ = 0 ] || { [ $r_ -gt 125 ] || stopclass content; die "the darwin package is not a gzip tar archive tar can read (tar -t: exit $r_)"; }
  /usr/bin/tar -xzf "$dt" -C "$nt/p" || die "cannot unpack the darwin package into $nt/p"
  b=$nt/p/package/Sheepr.app
  /usr/bin/plutil -extract SheeprControlBuild raw -o - "$b/Contents/Info.plist" >/dev/null 2>&1 && { stopclass content; die "the darwin package holds a control build (SheeprControlBuild in its Info.plist)"; }
  rt_meets "$b" && rt_meets "$b/Contents/MacOS/sheepr" || rtfail $? codesign "codesign: the darwin package's bundle does not meet the release requirement"
  rt_staple_ok "$b" || rtfail $? stapler "stapler: the darwin package's bundle has no valid staple ticket"
  rt_spctl_ok "$b" || rtfail $? spctl "spctl: Gatekeeper rejects the darwin package's bundle, which codesign's release requirement and stapler accepted" gatekeeper "$(gkhint "$dt" package/Sheepr.app)"
  # the release archive: its own check (only files and directories, the bundle signed and
  # stapled), then the same files as the package, read raw: path, mode and content (a CDHash is
  # read from the embedded signature, not recomputed, so equal CDHashes prove nothing)
  "$root/scripts/lib/archive.sh" check "$d/sheepr-macos-universal.tar.gz" --signed 2> "$nt/arc.err"; r_=$?; cat "$nt/arc.err" >&2
  [ $r_ = 0 ] || { judged $r_ "$nt/arc.err" 'archive: ' && stopclass content; die "the release archive fails its check (above)"; }
  npy same "$dt" "$d/sheepr-macos-universal.tar.gz" 2> "$nt/npy.err"; r_=$?; cat "$nt/npy.err" >&2
  [ $r_ = 0 ] || { judged $r_ "$nt/npy.err" 'npm-same: ' && stopclass content; die "the darwin package's bundle is not the release archive's bundle (above)"; }
  sl_=$(stamp_line "$d") || exit 1
  fput "$d/NPM-CHECKED" '%s' "$sl_" || { rm -f "$d/NPM-CHECKED"; die "cannot write $d/NPM-CHECKED (no stamp is left)"; }
  rm -rf "$nt"; trap - EXIT
  echo "release: the npm tarballs of $tag check out (NPM-CHECKED written)$(next_hint "; publish comes next, then publish-npm")"
}

# --- verify: the three facts, from the archive, by the real tools (PHASE3.md §1.2) --------------
verify() { # dir -> exit 1 naming the tool that refused
  . "$root/scripts/release.conf" || die "cannot read scripts/release.conf"
  . "$root/scripts/lib/realtools.sh" || die "cannot read realtools.sh"
  d=$1 arc=$1/sheepr-macos-universal.tar.gz
  [ -f "$arc" ] || { stopclass content; die "no $arc"; }
  vt=/private/tmp/sr-verify.$$.$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')
  trap 'trap "" $SIGS; rm -rf "$vt"' EXIT; trap 'rm -rf "$vt"; exit 1' $SIGS
  # the bundle the real tools judge, from a private copy whose hash publish then binds to the
  # stamped manifest (an archive replaced after this check is not the one judged). The copy, its hash
  # and the unpack are the temp dir's (full, unwritable: fix); an archive tar cannot list is a
  # defect of its bytes (content; r12b F1)
  mkdir -m 700 "$vt" && cp "$arc" "$vt/a.tgz" || die "cannot copy $arc into $vt"
  RT_OUT=$vt/rt.out   # the Apple tools' words (rt_judge)
  verified_ah=$(hashof "$vt/a.tgz") || exit 1
  /usr/bin/tar -tzf "$vt/a.tgz" > /dev/null 2>&1; r_=$?   # (a tar a signal stopped, above 125: no finding)
  [ $r_ = 0 ] || { [ $r_ -gt 125 ] || stopclass content; die "$arc is not a gzip tar archive tar can read (tar -t: exit $r_)"; }
  /usr/bin/tar -xzf "$vt/a.tgz" -C "$vt" && rm -f "$vt/a.tgz" || die "cannot unpack $arc into $vt"
  a=$vt/Sheepr.app
  # a control build's bundle carries the control marker (bundle.sh --control): never a release
  /usr/bin/plutil -extract SheeprControlBuild raw -o - "$a/Contents/Info.plist" >/dev/null 2>&1 && { stopclass content; die "the archive holds a control build (SheeprControlBuild in its Info.plist)"; }
  rt_meets "$a" && rt_meets "$a/Contents/MacOS/sheepr" || rtfail $? codesign "codesign: the bundle does not meet the release requirement"
  rt_staple_ok "$a" || rtfail $? stapler "stapler: no valid staple ticket"
  rt_spctl_ok "$a" || rtfail $? spctl "spctl: Gatekeeper rejects the bundle, which codesign's release requirement and stapler accepted" gatekeeper "$(gkhint "$arc" Sheepr.app)"
  rm -rf "$vt"; trap - EXIT
  verified=yes
  echo "release: $d: signed, notarized and stapled (checked from the archive)"
}

# --- ship: the whole release of a final tag in one run (the ship plan; PHASE3.md §5) ------------
# One orchestration, ship_run, serves `ship` (the real tools; behind the gate and its one question)
# and `__ship-dry` (stand-ins; the cells). The real entry's values are pinned by text in t_ship_dry.
# ship_fds: fds 1 and 2 open, checked before anything is made (first in ship, right after the dry marker
# in __ship-dry). ship keeps both on fds 8 and 9 for its
# handler, and that exec, with one of them closed, killed the shell before the handler was set, leaving
# the run's temp dir (r12b F5). The refusal goes to the one that is open
ship_fds() {
  if ! ( exec 3>&1 ) 2>/dev/null; then echo "release: ship's stdout (fd 1) is closed: run ship with its stdout open (nothing was done)" >&2; exit 2; fi
  if ! ( exec 3>&2 ); then echo "release: ship's stderr (fd 2) is closed: run ship with its stderr open (nothing was done)"; exit 2; fi
}
ship() {
  ship_fds
  SHIP_BUILD=/bin/sh SHIP_NPMCHECK=npm_check SHIP_VERIFY=verify NOTIFY=frozen-tree CAFFEINATE=/usr/bin/caffeinate SHIP_IDENTITY=/usr/bin/security SHIP_DOCKER=docker
  real_tools
  shipping=yes
  ship_run
}
ship_dry() { # the cells' entry: stand-ins by path only, never a real tool; no gate, no question
  dryentry=yes
  ship_fds
  standins SR_SHIP_DRY_BUILD SR_SHIP_DRY_NPMCHECK SR_SHIP_DRY_NOTIFY SR_SHIP_DRY_CAFFEINATE SR_SHIP_DRY_IDENTITY SR_SHIP_DRY_DOCKER \
    SR_PUBLISH_DRY_GH SR_PUBLISH_DRY_GIT SR_PUBLISH_DRY_NPM SR_PUBLISH_DRY_CURL
  cmp -s "$SR_SHIP_DRY_NOTIFY" "$root/scripts/lib/notify.sh" && die "SR_SHIP_DRY_NOTIFY is the real notify.sh, not a stand-in"
  DRYHOME=$(mktemp -d /private/tmp/sr-dryhome.XXXXXX) || die "no temp HOME"
  drydir "$DRYHOME"
  # right after mktemp, as in the other dry entries: ship_run refuses an rc or a tag off the grammar
  # before it sets its own exit handler (which then replaces this one and removes the temp HOME)
  trap 'trap "" $SIGS; rm -rf "$DRYHOME"' EXIT; trap 'rm -rf "$DRYHOME"; exit 1' $SIGS
  echo "release: __ship-dry (stand-ins; a temp HOME, $DRYHOME)"
  SHIP_BUILD=$SR_SHIP_DRY_BUILD SHIP_NPMCHECK=$SR_SHIP_DRY_NPMCHECK SHIP_VERIFY=ship_dry_verify NOTIFY=$SR_SHIP_DRY_NOTIFY
  ship_gk=${SR_SHIP_DRY_SPCTL:-}   # (the cells: C3 or C7, where ship_dry_verify gives Gatekeeper's refusal)
  CAFFEINATE=$SR_SHIP_DRY_CAFFEINATE SHIP_IDENTITY=$SR_SHIP_DRY_IDENTITY SHIP_DOCKER=$SR_SHIP_DRY_DOCKER
  GH=$SR_PUBLISH_DRY_GH GITCMD=$SR_PUBLISH_DRY_GIT NPM=$SR_PUBLISH_DRY_NPM NPMC=npmdry DRY=yes NETC=dry CURL=$SR_PUBLISH_DRY_CURL CURLC=dry
  shipping=yes
  ship_run
}
ship_dry_verify() { # dir: verify's stand-in in __ship-dry (verify runs the real Apple tools): the
                    # archive judged is the hash SR_PUBLISH_DRY_VERIFIED names, or none (1)
  [ -n "${SR_PUBLISH_DRY_VERIFIED:-}" ] || { echo "release: verify (dry): no SR_PUBLISH_DRY_VERIFIED, no archive judged" >&2; return 1; }
  # the cells' Gatekeeper refusal at C3 (no progress yet) or C7 ('start github'; SR_SHIP_DRY_SPCTL, read by
  # ship_dry): verify's own spctl stop there, with spctl's words for a rejection (verify itself, with the
  # real tools' stand-ins: t_release_verify)
  case $ship_gk:$(grep -v '^run ' "$shipprog" 2>/dev/null | tail -1) in
    C3:|'C7:start github')
      RT_OUT=$st/gk.out rt_rc=3; fput "$RT_OUT" '%s\n' "$1/Sheepr.app: rejected" "source=Notarized Developer ID" || die "cannot write $RT_OUT"
      rtfail 1 spctl "spctl: Gatekeeper rejects the bundle, which codesign's release requirement and stapler accepted" gatekeeper "$(gkhint "$1/sheepr-macos-universal.tar.gz" Sheepr.app)" ;;
  esac
  verified=yes verified_ah=$SR_PUBLISH_DRY_VERIFIED
}
ship_run() { # ship and __ship-dry: the whole release (the ship plan's phases A, B, C)
  # A1. the tag first (every path below is built from it): a final vX.Y.Z only
  valid "$tag" || die "the tag '$tag' is not vX.Y.Z or vX.Y.Z-rc.N"
  case $tag in *-rc.*) die "$tag is an rc: ship releases a final tag; an rc, or a backport, uses the separate entries (PHASE3.md §5)" ;; esac
  mkdir -p "$out" || die "cannot make $out"
  out=$(cd -P -- "$out" && pwd -P) && [ -n "$out" ] || die "cannot resolve $out"   # (physical: REV 12b rule 24)
  st=$(mktemp -d /private/tmp/sr-ship.XXXXXX) || die "no temp dir"
  drydir "$st"
  shipcause=$st/cause shipcls=$st/class; stopclass fix || die "cannot write $shipcls"
  locked=no logged_in=no armed=no pubok=no shipok=no phase=preflight oroot=$root wt="" progok=no
  # ship's own stdout and stderr, kept on fds 8 and 9 before the handler is set and before the first
  # call with redirections: bash 3.2 runs a trap, and so this handler, with the redirections of the
  # function call it interrupted still on (a signal during `tool ... > "$st/push"` sent the whole stop
  # text into that file; r11b, measured); the handler's first line puts them back. One mechanism for
  # every such call, now and later
  exec 8>&1 9>&2
  trap 'ship_exit $?' EXIT
  # PIPE too: a stdout closed during the run otherwise kills the shell after the handler ran, with 141
  # (bash 3.2 re-raises it; measured 2026-10-12); trapped, the handler's own status stands. A trapped
  # signal waits for the foreground child (the build, an upload) to end
  trap 'exit 1' $SIGS PIPE
  # one ship per out dir: a held lock is never taken over, and never removed by a ship that did not make it
  mkdir "$out/.ship.lock" 2>/dev/null || die "another ship or publish-npm holds $out/.ship.lock (its pid: $(cat "$out/.ship.lock/pid" 2>/dev/null || echo unknown)); when none runs, remove that directory, then run ship again"
  fput "$out/.ship.lock/pid" '%s\n' "$$" || die "cannot write $out/.ship.lock/pid"
  locked=yes
  # this run's own record, started once it holds the lock: the stop text is built from it
  shipprog=$out/.$tag.ship-progress
  rm -f "$shipprog.tmp" 2>/dev/null
  fput "$shipprog" 'run %s %s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || die "cannot write $shipprog"
  progok=yes   # (ship_stoptext: from here a record it cannot read is never "nothing started")
  # the Mac stays awake until ship ends (-w: caffeinate ends with this process)
  shipcall "$CAFFEINATE" -i -w $$ > /dev/null 2>&1 &
  # A1 (on). The checks in the operator's checkout (HEAD the tag's commit, the tree clean), and this
  # release.sh must be the tag's own (an edit marked assume-unchanged hides from git, not from cmp)
  checks
  fout "$st/release.sh" git -C "$root" show "refs/tags/$tag:scripts/release.sh" 2>/dev/null || die "cannot read $tag's scripts/release.sh (or write it into $st)"
  cmp -s "$0" "$st/release.sh" || die "this scripts/release.sh is not $tag's (an edit, maybe marked assume-unchanged): run ship from a clean checkout of the tag"
  # every file the tag tracks under scripts/ (the sourced sigs.sh among them, and whatever any
  # spelling sources from there) holds the tag's bytes in this checkout, read from the file and never
  # from the index, so assume-unchanged and skip-worktree hide nothing: a regular file by its blob
  # hash (no filters), a symlink by its target; any other entry (a submodule) is refused
  fout "$st/scripts.tree" git -C "$root" ls-tree -r --full-tree "refs/tags/$tag" -- scripts 2>/dev/null && [ -s "$st/scripts.tree" ] \
    || die "cannot list $tag's files under scripts/ (or write the list into $st)"
  while IFS= read -r l_; do
    m_=${l_%% *} h_=${l_#* * } f_=${l_#*	}; h_=${h_%%	*}
    case $m_ in
      100644|100755) [ -f "$root/$f_" ] && [ ! -L "$root/$f_" ] && [ "$(git -C "$root" hash-object --no-filters -- "$f_" 2>/dev/null)" = "$h_" ] ;;
      120000) [ -L "$root/$f_" ] && [ "$(readlink "$root/$f_")" = "$(git -C "$root" cat-file blob "$h_" 2>/dev/null)" ] ;;
      *) false ;;
    esac || die "this $f_ is not $tag's (an edit, maybe hidden by assume-unchanged or skip-worktree): run ship from a clean checkout of the tag"
  done < "$st/scripts.tree"
  tagobj=$(git -C "$root" rev-parse -q --verify "refs/tags/$tag") || die "no tag $tag"
  # the commit the checks passed on must be the recorded object's (a tag moved in between is refused)
  tc=$(git -C "$root" rev-parse -q --verify "$tagobj^{commit}") && [ "$tc" = "$commit" ] \
    || die "the tag $tag moved while ship checked it (it names ${tc:-no commit} now; the checks passed on $commit): look at the tag, then run ship again"
  # the frozen tree: a detached worktree of the tag's commit, in this run's temp dir; every later
  # step reads its helpers, release.conf, the planner and the walls there, and the build child is
  # its release.sh
  git -C "$root" worktree add -q --detach "$st/tree" "$commit" || die "cannot make a worktree of $commit"
  wt=$st/tree root=$st/tree
  [ "$NOTIFY" != frozen-tree ] || NOTIFY=$root/scripts/lib/notify.sh
  # A2. the push target; A3. the push, as far as a dry run can tell
  ship_target
  ship_pushcheck
  # REV 12 rule 2, before ship's first npm call (A4's views name P): an earlier P logged out of first (a
  # dead token there would fail every npm call with E401); C4 makes sure again before the login
  npm_pre "$st" ship "this run has made nothing public"
  ship_nothing_public   # A4
  pubok=yes             # from here a stop before the push may say "nothing is public"
  ship_tap              # A5
  ship_npm_ready        # A6
  ship_build_ready      # A7
  armed=yes             # A8: from here a stop notifies
  # B. the build, when there is none: the frozen tree's release.sh, a direct child (sign.sh checks
  # that its own parent is `release.sh build --sign`); it asks for the notary keychain's password
  if [ ! -e "$out/$tag" ]; then
    phase=build; stopclass fix
    shipcall "$SHIP_BUILD" "$root/scripts/release.sh" build --sign --out "$out" "$tag" || die "the build failed (above); nothing is public"
  fi
  # C0. the build's checks, on every path; C1. its manifest's hash, which every later phase's
  # private copy must have (the npm bytes and the GitHub bytes are one build)
  phase=checks
  post_build_check "$out/$tag"
  ship_mh=$(shasum -a 256 "$out/$tag/MANIFEST.json" | cut -d' ' -f1)
  printf '%s\n' "$ship_mh" | grep -qx '[0-9a-f]\{64\}' || { ship_mh=""; stopclass fix; die "cannot read the hash of $out/$tag/MANIFEST.json (every later phase is bound to it); nothing is public"; }
  # C2. npm-check (its own traps: a subshell). No class is set ahead of C2 and C3 but fix, and the
  # parent sets none after them: a signal, a child killed, a tool that cannot run, or a failure that
  # is not about the build (the tap's cask gone, npm's owners), is no content stop. content is set
  # only by a check that found a defect in the build's bytes (npm_check's, publish_check's,
  # cask_pre's and verify's own; r12b F1). A dry entry's stand-in gets the class file to do the same
  phase=npm-check; stopclass fix
  if [ "$dryentry" = yes ]; then
    ( drysub; tool dry /usr/bin/env SR_SHIP_DRY_CLASS="$shipcls" "$SHIP_NPMCHECK" "$out/$tag" ) || die "npm-check refused $out/$tag (above)"
  else
    ( "$SHIP_NPMCHECK" "$out/$tag" ) || die "npm-check refused $out/$tag (above)"
  fi
  # C3. every check publish makes before a write, but the remote tag's (no remote tag yet): verify
  # binds the archive it judged, so it runs in the same subshell as publish_check
  phase=checks
  ( drysub; $SHIP_VERIFY "$out/$tag" && publish_check "$out/$tag" ) || die "the checks before publishing refused (above)"
  # C4. the npm session, in the parent, in ship's own file P (REV 12): an earlier P logged out of
  # first; a notification, then npm's own login (the operator's browser) into P; logged_in from the
  # attempt on (the handler logs out); then npm must name SR_NPM_USER
  phase=npm-login; stopclass fix
  npm_pre "$st" ship "nothing is public"
  notify npm-login
  logged_in=yes
  npm_login "$st" ship "nothing is public"
  # C5. A2's read fresh, A3 and A4 again; the live tag still the recorded object; then the push of
  # exactly A3's refspecs (the recorded object), atomic, no tag followed
  phase=push
  ship_lsr; ship_pushcheck; ship_nothing_public
  [ "$(git -C "$root" rev-parse -q --verify "refs/tags/$tag")" = "$tagobj" ] || { stopclass content; die "the tag $tag moved since ship recorded it ($tagobj); nothing is public"; }
  set -- "$tagobj:refs/tags/$tag"; [ $pushmain = no ] || set -- "$commit:refs/heads/main" "$@"
  # (git's answers in variables, never in a file: a lost write must not read as "nothing landed")
  progress "start push"
  pu_=$(tool "$NETC" "$GITCMD" -C "$root" push --porcelain --atomic --no-follow-tags origin "$@" 2> "$st/push.err"); pr_=$?
  if [ $pr_ != 0 ]; then
    # an atomic push moves both refs or neither: refused, when github.com/lukaso/sheepr shows no tag
    # and main not at the tag's commit (pushed, or held by it before)
    lp_=$(tool "$NETC" "$GITCMD" -C "$root" ls-remote "$UPSTREAM" refs/heads/main "refs/tags/$tag" 2>/dev/null) \
      || die "the push failed, and the refs of $UPSTREAM cannot be read to tell whether it landed ($(errcut "$st/push.err" 300))"
    if ! printf '%s\n' "$lp_" | awk -v t="refs/tags/$tag" '$2 == t {f = 1} END {exit !f}' \
       && { [ $pushmain = no ] || ! printf '%s\n' "$lp_" | awk -v c="$commit" '$2 == "refs/heads/main" && $1 == c {f = 1} END {exit !f}'; }; then
      # why, from main as the remote shows it now (C5 read it as $amain): unmoved (the remote's own
      # rules refused it), moved on past the commit, or moved elsewhere
      um=$(printf '%s\n' "$lp_" | awk '$2 == "refs/heads/main" {print $1}')
      if [ -n "$um" ] && [ "$um" = "$amain" ]; then why="main unmoved"
      else
        tool "$NETC" "$GITCMD" -C "$root" fetch -q origin refs/heads/main 2>/dev/null \
          || die "the push was refused and origin's main moved, but it cannot be fetched to tell where ($(errcut "$st/push.err" 300))"
        if [ -n "$um" ] && git -C "$root" merge-base --is-ancestor "$commit" "$um" 2>/dev/null; then why="main holds it"; else why="main moved"; fi
      fi
      progress "push refused: $why"
      # git's reason for each refused ref is its porcelain `!` line (stdout under --porcelain)
      rej=$(printf '%s\n' "$pu_" | grep '^!' | cut -f2- | tr '\t\n' ' ;' | head -c 300)
      die "the push was refused, and nothing of it landed (${rej:+git: $rej }$(errcut "$st/push.err" 300)); nothing is public"
    fi
    die "the push failed, but $UPSTREAM shows a part of it ($(printf '%s\n' "$lp_" | tr '\t\n' ' ;'))"
  fi
  # what the push did: origin's main fetched, and github.com/lukaso/sheepr shows the tag at the
  # recorded object and main at or past the tag's commit
  tool "$NETC" "$GITCMD" -C "$root" fetch -q origin refs/heads/main || die "the push ran, but origin's main cannot be fetched to confirm it"
  lp_=$(tool "$NETC" "$GITCMD" -C "$root" ls-remote "$UPSTREAM" refs/heads/main "refs/tags/$tag") || die "the push ran, but the refs of $UPSTREAM cannot be read to confirm it"
  [ "$(printf '%s\n' "$lp_" | awk -v t="refs/tags/$tag" '$2 == t {print $1}')" = "$tagobj" ] || die "after the push, $UPSTREAM's $tag is not the recorded object $tagobj"
  um=$(printf '%s\n' "$lp_" | awk '$2 == "refs/heads/main" {print $1}')
  [ -n "$um" ] && git -C "$root" merge-base --is-ancestor "$commit" "$um" 2>/dev/null || die "after the push, $UPSTREAM's main (${um:-none}) does not hold $tag's commit"
  progress "done push"
  # C6. npm, the platform packages, back to back (one approval); nothing waited for here
  phase=npm-platform
  ( drysub; NETC=$NPMC npm_part=platform; publish_npm_exec "$out/$tag" ) || die "the npm upload of a platform package stopped (above)"
  # C7. GitHub while npm scans: verify binds the archive it judged, in publish_exec's subshell
  phase=github
  progress "start github"
  ( drysub; $SHIP_VERIFY "$out/$tag" && publish_exec "$out/$tag" ); r=$?
  case $r in
    0) progress "done github" ;;
    5) progress exit5; die "$tag is public on GitHub, but its Homebrew cask is not updated (above)" ;;
    *) die "the GitHub publish stopped (above)" ;;
  esac
  # C8. npm, the main package: once npm shows the three, uploaded and waited for
  phase=npm-main
  ( drysub; NETC=$NPMC npm_part=main; publish_npm_exec "$out/$tag" ) || die "the npm upload of the main package stopped (above)"
  progress "done npm-main"
  # C9. done: the handler logs out
  echo "release: ship: $tag is public on GitHub, Homebrew and npm"
  shipok=yes   # the one place a run is done: the handler reads this, never the exit status (a signal
  exit 0       # ship does not trap can reach the handler with status 0)
}
progress() { # line: ship's record of the phases (no-op outside ship); written before the step it names.
  # The record is replaced whole: the old one and LINE into a new file beside it (fput), renamed onto
  # it, so a write a full disk cut short leaves it as it was, and the step is not run (REV 12b rule 21)
  [ -n "$shipprog" ] || return 0
  pr_=$(cat "$shipprog" 2>/dev/null) && [ -n "$pr_" ] || die "cannot read $shipprog (ship's own record)"
  rm -f "$shipprog.tmp" 2>/dev/null
  fput "$shipprog.tmp" '%s\n%s\n' "$pr_" "$1" && mv -f "$shipprog.tmp" "$shipprog" 2>/dev/null || { rm -f "$shipprog.tmp" 2>/dev/null; die "cannot write $shipprog"; }
}
drydir() { # dir: a dry run names each temp dir it makes on stderr (a closed stdout cannot hide it),
           # so its cells can hold every one to being gone; a real run (no temp HOME) says nothing
  [ -z "${DRYHOME:-}" ] || echo "release: (dry) a temp dir, $1" >&2
}
drysub() { # in a dry entry's phase subshell: a temp HOME of its own (the phase's own trap removes it)
  [ "$dryentry" = yes ] || return 0
  DRYHOME=$(mktemp -d /private/tmp/sr-dryhome.XXXXXX) || die "no temp HOME"
  trap 'trap "" $SIGS; rm -rf "$DRYHOME"' EXIT; trap 'rm -rf "$DRYHOME"; exit 1' $SIGS
  echo "release: (a phase) a temp HOME, $DRYHOME" >&2   # stderr: a closed stdout cannot hide it
}
# shipcall TOOL ARGS...: a ship tool, in the dry class in a dry entry; with the caller's environment in
# the real one (the build needs the terminal, cargo and Docker as the operator has them)
shipcall() { if [ "$dryentry" = yes ]; then tool dry "$@"; else "$@" 8>&- 9>&-; fi; }   # (fds 8 and 9 closed: as in tool)
shipdocker() { # the docker class, with SHIP_DOCKER
  if [ "$dryentry" = yes ]; then tool dry "$SHIP_DOCKER" "$@"
  else tool base /usr/bin/env ${DOCKER_HOST:+DOCKER_HOST="$DOCKER_HOST"} ${DOCKER_CONFIG:+DOCKER_CONFIG="$DOCKER_CONFIG"} "$SHIP_DOCKER" "$@"; fi
}
ship_public() { stopclass public; die "something of $tag is public: $*"; }
ship_unreadable() { stopclass unreadable; die "cannot tell whether anything is public: $*"; }
ship_nothing_public() { # A4: nothing of the version public (GitHub, the tap, npm and npm's time
  # record), and the version newer than GitHub's latest final release and npm's latest of each name
  xyz=${tag#v}
  # (gh's answers in variables, never in a file: a lost write must not read as "nothing there")
  rels_=$(tool "$NETC" "$GH" api repos/lukaso/sheepr/releases --paginate --jq '.[] | [.tag_name, .draft, .prerelease] | @tsv' 2> "$st/rels.err") \
    || ship_unreadable "gh cannot list the releases ($(errcut "$st/rels.err" 200))"
  [ -z "$(printf '%s\n' "$rels_" | awk -F '\t' -v t="$tag" '$1 == t')" ] || ship_public "GitHub has a release or a draft $tag"
  hi=""
  for v in $(printf '%s\n' "$rels_" | awk -F '\t' '$2 == "false" && $3 == "false" {print $1}'); do
    v=${v#v}; sh "$root/scripts/lib/cask-version.sh" "$v" "$v" >/dev/null 2>&1 || continue
    if [ -z "$hi" ] || [ "$(sh "$root/scripts/lib/cask-version.sh" "$hi" "$v")" = newer ]; then hi=$v; fi
  done
  [ -z "$hi" ] || [ "$(sh "$root/scripts/lib/cask-version.sh" "$hi" "$xyz")" = newer ] || die "$tag is not newer than GitHub's latest release v$hi: tag a newer version"
  # the tap's cask (A5 checks it further)
  if ! tapc_=$(tool "$NETC" "$GH" api -H 'Accept: application/vnd.github.raw' "repos/$TAP/contents/$CASK" 2> "$st/tap.err"); then
    grep -q 'HTTP 404' "$st/tap.err" && die "$TAP has no $CASK (add it by hand once)"
    ship_unreadable "gh cannot read $TAP's $CASK ($(errcut "$st/tap.err" 300))"
  fi
  printf '%s\n' "$tapc_" | grep -qxF "  version \"$xyz\"" && ship_public "$TAP's cask is $xyz"
  # npm, each name: the version not there (E404), never there once ("time"), and newer than its latest
  . "$root/scripts/release.conf" || die "cannot read scripts/release.conf"
  for p in $SR_NPM_PKGS; do
    vout=$(tool "$NPMC" "$NPM" view --json --prefer-online --registry="$NPMREG" --scope= "$p@$xyz" dist.integrity 2> "$st/err"); r=$?
    if [ $r = 0 ] && [ -n "$(printf '%s' "$vout" | tr -d ' "\n\r')" ]; then ship_public "npm has $p@$xyz"
    elif ! { [ $r != 0 ] && printf '%s\n' "$vout" | cat - "$st/err" | grep -q 'E404'; }; then ship_unreadable "npm view $p@$xyz: exit $r, $(errcut "$st/err" 200)"; fi
    # a name npm does not know answers E404 to every view (owner ls too, A6): not a read failure
    # (npm's --json says its E404 in the error object on stdout, and may say nothing on stderr)
    tm=$(tool "$NPMC" "$NPM" view --json --prefer-online --registry="$NPMREG" --scope= "$p" time 2> "$st/err") || {
      printf '%s\n' "$tm" | cat - "$st/err" | grep -q E404 && { stopclass fix; die "$p is not on npm yet: reserve the name first (publish a 0.0.0 placeholder as ${SR_NPM_USER:-the owner}); this run made nothing public"; }
      ship_unreadable "npm view $p time: $(errcut "$st/err" 200)"; }
    if printf '%s\n' "$tm" | grep -q "\"$xyz\":"; then stopclass lost; die "$p@$xyz was published once and is gone: $xyz can never be published on npm again; release a new version"; fi
    lt=$(tool "$NPMC" "$NPM" view --json --prefer-online --registry="$NPMREG" --scope= "$p" dist-tags.latest 2> "$st/err") || ship_unreadable "npm view $p dist-tags.latest: $(errcut "$st/err" 200)"
    lt=$(printf '%s' "$lt" | tr -d ' "\n\r')
    [ -z "$lt" ] || [ "$(sh "$root/scripts/lib/cask-version.sh" "$lt" "$xyz" 2>/dev/null)" = newer ] || die "$tag is not newer than npm's latest $p ($lt): tag a newer version"
  done
}
ship_tap() { # A5: the tap's cask has one version line, below this version; this gh login may write
             # the tap and lukaso/sheepr
  [ "$(printf '%s\n' "$tapc_" | grep -c '^  version "')" = 1 ] || die "$TAP's $CASK has not exactly one version line"
  tv=$(printf '%s\n' "$tapc_" | sed -n 's/^  version "\(.*\)"$/\1/p')
  [ "$(sh "$root/scripts/lib/cask-version.sh" "$tv" "$xyz" 2>/dev/null)" = newer ] || die "$TAP's cask is $tv, not below $xyz"
  for r_ in "$TAP" lukaso/sheepr; do
    pp=$(tool "$NETC" "$GH" api "repos/$r_" --jq .permissions.push 2> "$st/perm.err") || { stopclass fix; die "gh: cannot read $r_ ($(errcut "$st/perm.err" 300))"; }
    [ "$pp" = true ] || die "this gh login cannot write $r_"
  done
}
# D, ship's own npm directory for this release (REV 12 rule 1): ${out%/}/.$tag.npm (mode 0700, made by
# npm_login), spelt out at each use, never through a $( ) (a closed stdout's bytes would land in it). P
# = D/npmrc is the one npm file ship, publish-npm and their dry entries name; D/end holds the epoch
# second its session ends by itself (2 hours after the login, REV 9). D is a sibling of $out/$tag:
# nothing ship uploads, archives or hashes lies in it
# ptok FILE: FILE holds a registry.npmjs.org token line (the line npm's login writes). A logout of P runs
# only then: with none, npm logout ends a token of another layer it reads (r17a F1; REV 12b rule 25)
ptok() { grep -q '^//registry\.npmjs\.org/:_authToken=.' "$1" 2>/dev/null; }
# npm_dok WHO TAIL: before any npm call names P (REV 12b rule 25; r17a P4-a): D absent or a directory
# (not a link), P absent or a regular file (not a link), as ship's mkdir and npm's login make them; else a
# stop (fix): npm would log out, or log in, through a link into another file, and a directory at P takes
# a login's token nowhere
npm_dok() {
  d_=${out%/}/.$tag.npm
  if [ -L "$d_" ] || { [ -e "$d_" ] && [ ! -d "$d_" ]; }; then stopclass fix; die "$d_ is not the directory ship makes (a link, or a file): remove it, then run $1 again; $2"; fi
  if [ -L "$d_/npmrc" ] || { [ -e "$d_/npmrc" ] && [ ! -f "$d_/npmrc" ]; }; then stopclass fix; die "$d_/npmrc is not the file ship's login writes (a link, or a directory): remove it, then run $1 again; $2"; fi
}
# npm_pre DIR WHO TAIL: before a login (REV 12 rule 2): D's and P's shapes (npm_dok); when P exists (an
# earlier run's: a KILL, a logout that failed) and holds a token line (ptok; else it is removed), the
# logout of P first. Exit 0, E401 or ENEEDAUTH: P removed. Any other
# failure: P removed when its end time has passed (that session ended by itself); else a stop (fix)
# with npm's words, the end time, and "run WHO again". DIR holds npm's stderr
npm_pre() {
  npm_dok "$2" "$3"
  pp_=${out%/}/.$tag.npm/npmrc
  [ -e "$pp_" ] || return 0
  ptok "$pp_" || { rm -f "$pp_"; return 0; }   # (no token line: nothing of ship's to end, and a logout would end another layer's)
  tool "$NPMC" "$NPM" logout --registry="$NPMREG" --scope= 2> "$1/pre.err"; r_=$?
  c_=$(npmcode "$1/pre.err")
  if [ $r_ = 0 ] || [ "$c_" = E401 ] || [ "$c_" = ENEEDAUTH ]; then rm -f "$pp_"; return 0; fi
  e_=$(cat "${out%/}/.$tag.npm/end" 2>/dev/null) n_=$(date +%s 2>/dev/null)
  case "$e_:$n_" in *[!0-9:]*|:*|*:) ;; *) [ "$n_" -lt "$e_" ] || { rm -f "$pp_"; return 0; } ;; esac
  stopclass fix; die "an earlier session of ship's own npm file ($pp_) could not be ended (the logout's answer: $(errcut "$1/pre.err" 200)); $3. That session ends by itself$(t_=$(ship_clock "$e_"); [ -z "$t_" ] || printf ' at %s' "$t_"); run $2 again then, or once npm answers"
}
# npm_login DIR WHO TAIL: ship's own login into P (REV 12 rule 3): D made (0700; never a link), npm's
# login (the operator's browser), the end time recorded in D; whoami must name SR_NPM_USER, else the
# logout of P, P removed, and a stop that says how to log in when WHO asks
npm_login() {
  d_=${out%/}/.$tag.npm   # (npm_pre ran first: D is absent or a directory, not a link)
  { [ -d "$d_" ] || mkdir -m 700 "$d_"; } 2>/dev/null && chmod 700 "$d_" 2>/dev/null || die "cannot make $d_ (ship's own npm directory); $3"
  tool "$NPMC" "$NPM" login --registry="$NPMREG" --scope= || die "the login to npm failed, or was not answered; $3"
  # the clock time this session ends by itself: 2 hours after the login (PLAN-ship.md REV 9), taken
  # once the login returned (so never before the session's real end), with its zone (REV 10 rule 7);
  # a time ship cannot compute is left out
  e_=$(date +%s 2>/dev/null); ship_end=""
  case $e_ in ''|*[!0-9]*) ;; *) ship_end=$(ship_clock $(( e_ + 7200 ))); fput "$d_/end" '%s\n' $(( e_ + 7200 )) || die "cannot write $d_/end; $3" ;; esac
  who=$(tool "$NPMC" "$NPM" whoami --registry="$NPMREG" --scope= 2> "$1/who.err") || die "npm whoami failed after the login ($(errcut "$1/who.err" 200)); $3"
  [ "$who" = "${SR_NPM_USER:-}" ] && return 0
  tool "$NPMC" "$NPM" logout --registry="$NPMREG" --scope= 2> "$1/who.err" && rm -f "$d_/npmrc"
  die "the login to npm was as $(printf '%s' "$who" | head -c 100 | tr '\n' ' '), but the packages belong to ${SR_NPM_USER:-nobody named in release.conf}; $3. When $2 asks you to log in to npm, log in as ${SR_NPM_USER:-the owner} in the browser, then run $2 again"
}
# npm_out DIR: the logout of P at the end (REV 12 rule 4). Exit 0 (or no P, or none with a token line): D removed (0). A
# failure: P kept (1); npm's words in DIR/out.err (the next ship or publish-npm run of this tag, with this
# out dir, logs out of it first)
npm_out() {
  d_=${out%/}/.$tag.npm
  # (only a regular P with a token line: a link, a directory or a P without one holds nothing of ship's
  # to end, and its logout would end another file's token or another layer's: REV 12b rule 25)
  if [ -f "$d_/npmrc" ] && [ ! -L "$d_/npmrc" ] && ptok "$d_/npmrc"; then
    tool "$NPMC" "$NPM" logout --registry="$NPMREG" --scope= 2> "$1/out.err" || return 1
  fi
  rm -rf "${d_:?}"; return 0
}
# npm_left WORDS: what stdout says when ship's own session could not be ended (no npm command: REV 12
# rule 4): its end time, and that the next run of this tag with this out dir logs out of it first (a run
# of another version reads only its own D: REV 12b rule 26)
npm_left() {
  a_=""; [ -z "${1:-}" ] || a_=" (the logout's answer: $1)"
  printf '%s' "ship's npm session (its own file, ${out%/}/.$tag.npm/npmrc) could not be ended$a_. It ends by itself $( [ -n "${ship_end:-}" ] && printf 'at %s ' "$ship_end")(2 hours after its login). The next ship or publish-npm run of $tag with this out dir logs out of it first; a run of another version does not. There is nothing to run by hand"
}
# npm_lock WHO: publish-npm on its own takes ship's lock while it uses D (P is in the out dir: one ship
# or publish-npm per out dir at a time); npm_end releases it. Never taken over
npm_lock() {
  mkdir "$out/.ship.lock" 2>/dev/null || die "another ship or publish-npm holds $out/.ship.lock (its pid: $(cat "$out/.ship.lock/pid" 2>/dev/null || echo unknown)); when none runs, remove that directory, then run $1 again; this step uploaded nothing"
  pnlock=yes; fput "$out/.ship.lock/pid" '%s\n' "$$" || die "cannot write $out/.ship.lock/pid; this step uploaded nothing"
}
# npm_end DIR: publish-npm on its own, as it exits (its EXIT trap): the logout of its own session, then
# its lock (REV 12 rule 5); nothing under ship
npm_end() {
  if [ "${pnin:-no}" = yes ]; then
    pnin=no
    if npm_out "$1"; then echo "release: publish-npm's npm session is ended (its own file removed)"
    else npm_endrc=1; echo "release: $(redact "$(npm_left "$(errcut "$1/out.err" 200)")")" >&2; fi
  fi
  [ "${pnlock:-no}" != yes ] || { pnlock=no; rm -rf "${out:?}/.ship.lock"; }
}
# npmcode FILE: the first error code npm wrote there: npm 11's `npm error code X`, npm 9's
# `npm ERR! code X`; ANSI colour (an npmrc's color=always) dropped first; or nothing
npmcode() {
  e_=$(printf '\033')
  sed -e "s/$e_\[[0-9;]*[A-Za-z]//g" "$1" 2>/dev/null | sed -n -e 's/^npm error code \([A-Za-z0-9_]*\).*/\1/p' -e 's/^npm ERR! code \([A-Za-z0-9_]*\).*/\1/p' | head -1
}
ship_npm_ready() { # A6: npm's list and owners (no login needed; REV 12: ship logs in to its own file
  # at C4, so no session of the operator's matters)
  npm_list; npm_owners "$NPMC" "$NPM" "$st"
}
post_build_check() { # dir: a finished build of this tag and commit, signed, not a control, its files
  # its manifest's, and no control manifest inside it (-mindepth 2: a control build beside it is not)
  [ -f "$1/MANIFEST.json" ] || { stopclass content; die "no $1/MANIFEST.json"; }
  pm() { sed -n "s/^ *\"$2\": *\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}$/\1/p" "$1/MANIFEST.json" | head -1; }
  [ "$(pm "$1" tag)" = "$tag" ] && [ "$(pm "$1" commit)" = "$commit" ] && [ "$(pm "$1" mode)" = signed ] && [ "$(pm "$1" control)" = false ] \
    || { stopclass content; die "$1 holds no signed build of $tag at $commit (or a control build)"; }
  files_ok "$1" || { stopclass content; die "a file of $1 is missing or not its manifest hash"; }
  nested=$(find "$1" -mindepth 2 -name MANIFEST.json -exec grep -l '"control": *true' {} + 2>/dev/null | head -1)
  [ -z "$nested" ] || { stopclass content; die "a control build's manifest lies inside $1 ($nested)"; }
}
ship_build_ready() { # A7: no build yet: the build's preconditions; a finished one: its checks
  . "$root/scripts/release.conf" || die "cannot read scripts/release.conf"
  if [ -e "$out/$tag" ]; then
    post_build_check "$out/$tag"
    echo "release: a finished build of $tag is in $out/$tag: checked; it is not built again"
    return 0
  fi
  shipdocker info >/dev/null 2>&1 || die "Docker does not answer (docker info): start it, then run ship again"
  # (each step names the checkout's test-all by its full path, on a line of its own: it runs as printed
  # from any directory; test-all cds to its own; REV 11b rule 17)
  shipdocker image inspect "$SR_IMG_ALPINE" >/dev/null 2>&1 || die "no local image $SR_IMG_ALPINE. Pull it with this, then run ship again:
  $(dq "$oroot/test-all") pull"
  a1=sr-amd64-base:$(printf %s "${SR_IMG_ALPINE##*sha256:}" | cut -c1-12) a2=sr-amd64-alpine:$(printf %s "${SR_IMG_ALPINE##*sha256:}" | cut -c1-12)
  shipdocker image inspect "$a1" >/dev/null 2>&1 || shipdocker image inspect "$a2" >/dev/null 2>&1 || die "no local amd64 image of the pinned base. Get it with one of these, then run ship again:
  $(dq "$oroot/test-all") pull
  $(dq "$oroot/test-all") amd64"
  shipcall "$SHIP_IDENTITY" find-identity -v -p codesigning 2>/dev/null | grep -q " $SR_SIGN_IDENTITY " || die "the signing identity $SR_SIGN_IDENTITY is not in the keychain"
  [ -f "$HOME/$SR_NOTARY_KEYCHAIN" ] || die "no notary keychain at $HOME/$SR_NOTARY_KEYCHAIN: do PHASE3.md D2 step 3 first"
}
ship_target() { # A2: origin is lukaso/sheepr on github.com (exactly one push URL, and the fetch URL)
  pu=$(tool "$NETC" "$GITCMD" -C "$root" remote get-url --push --all origin) || die "git: cannot read origin's push URL"
  [ "$(printf '%s\n' "$pu" | grep -c .)" = 1 ] || die "origin has $(printf '%s\n' "$pu" | grep -c .) push URLs; ship pushes to one, lukaso/sheepr on github.com"
  fu=$(tool "$NETC" "$GITCMD" -C "$root" remote get-url origin) || die "git: cannot read origin's URL"
  for u in "$pu" "$fu"; do
    case $u in
      https://github.com/lukaso/sheepr|https://github.com/lukaso/sheepr.git|git@github.com:lukaso/sheepr|git@github.com:lukaso/sheepr.git|ssh://git@github.com/lukaso/sheepr|ssh://git@github.com/lukaso/sheepr.git) continue ;;
    esac
    # a user name or password in it (an insteadOf rule may add one; a token may be the user name): the
    # URL is shown with <redacted> in its place, and when the rest is lukaso/sheepr on github.com the
    # refusal says that is the reason (a bare accepted spelling is never called "not lukaso/sheepr")
    d_=$u ui_=$(urluser "$u")
    if [ -n "$ui_" ] && [ "$ui_" != git ]; then
      r_=${u#*"$ui_"@}
      case $u in *://*) d_="${u%%://*}://<redacted>@$r_" b_="${u%%://*}://$r_" ;; *) d_="<redacted>@$r_" b_=$r_ ;; esac
      case $b_ in
        https://github.com/lukaso/sheepr|https://github.com/lukaso/sheepr.git|ssh://github.com/lukaso/sheepr|ssh://github.com/lukaso/sheepr.git|github.com:lukaso/sheepr|github.com:lukaso/sheepr.git)
          die "origin's URL $d_ holds a user name or password: ship pushes with git's own login, never with one in the URL. Remove it from origin's URL, or from the url.<base>.insteadOf rule that adds it" ;;
      esac
    fi
    case $u in
      *:lukaso/sheepr|*:lukaso/sheepr.git) die "origin's URL $d_ names an ssh host alias: ship accepts github.com itself (git@github.com:lukaso/sheepr.git or https://github.com/lukaso/sheepr.git)" ;;
      *) die "origin's URL $d_ is not lukaso/sheepr on github.com" ;;
    esac
  done
  ship_lsr
}
ship_lsr() { # A2's read of the remote refs, again before the push: origin's and github.com/lukaso/
             # sheepr's main and this tag (exactly refs/tags/vTAG and its peeled line; an rc tag of
             # the version is not one) must agree; sets amain (origin's main) and rtag
  for r_ in origin "$UPSTREAM"; do
    # (git's answers in variables, never in a file: a lost write must not read as "no tag there")
    lr_=$(tool "$NETC" "$GITCMD" -C "$root" ls-remote "$r_" refs/heads/main "refs/tags/$tag*" 2> "$st/ls.err") || { stopclass fix; die "git: cannot list the refs of $r_ (ls-remote: $(errcut "$st/ls.err" 300))"; }
    lv_=$(printf '%s\n' "$lr_" | awk -v t="refs/tags/$tag" '$2 == "refs/heads/main" || $2 == t || $2 == t "^{}"' | sort)
    if [ "$r_" = origin ]; then lso_=$lv_; else lsu_=$lv_; fi
  done
  [ "$lso_" = "$lsu_" ] || { stopclass network; die "origin and $UPSTREAM disagree on main or $tag ($(printf '%s\n' "$lso_" | tr '\t\n' ' ;') against $(printf '%s\n' "$lsu_" | tr '\t\n' ' ;')); a push in between? run ship again"; }
  amain=$(printf '%s\n' "$lso_" | awk '$2 == "refs/heads/main" {print $1}')
  [ -n "$amain" ] || die "origin has no main"
  rtag=$(printf '%s\n' "$lso_" | awk -v t="refs/tags/$tag" '$2 == t || $2 == t "^{}"')
}
ship_pushcheck() { # A3, again before the push: no remote tag; origin's main fetched (FETCH_HEAD is per
  # worktree: fetched and read with one -C; the refspec keeps the unpushed tag under fetch.prune and
  # pruneTags) and either an ancestor of the tag's commit (main pushed) or holding it (not pushed);
  # the dry-run push of exactly those refspecs, --no-follow-tags, lists exactly them
  [ -z "$rtag" ] || ship_public "the tag is on origin ($(printf '%s' "$rtag" | head -1))"
  tool "$NETC" "$GITCMD" -C "$root" fetch -q origin refs/heads/main 2> "$st/fetch.err" || { stopclass fix; die "git: cannot fetch origin's main ($(errcut "$st/fetch.err" 300))"; }
  fh=$(git -C "$root" rev-parse -q --verify FETCH_HEAD) || die "no FETCH_HEAD after the fetch"
  [ "$fh" = "$amain" ] || { stopclass network; die "origin's main moved between its read ($amain) and the fetch ($fh)"; }
  if git -C "$root" merge-base --is-ancestor "$commit" "$fh"; then pushmain=no
  elif git -C "$root" merge-base --is-ancestor "$fh" "$commit"; then pushmain=yes
  else stopclass diverged; die "origin's main ($fh) has diverged from $tag's commit ($commit)"; fi
  set -- "$tagobj:refs/tags/$tag"; [ $pushmain = no ] || set -- "$commit:refs/heads/main" "$@"
  tool "$NETC" "$GITCMD" -C "$root" push --dry-run --porcelain --atomic --no-follow-tags origin "$@" > "$st/dry" 2> "$st/dry.err" \
    || die "the dry-run push failed ($(errcut "$st/dry.err" 300))"
  # git's porcelain lines, by tab-separated fields: the flag (a space for a fast-forward, measured;
  # * for a new ref), from:to, the summary
  want=$(printf '*\trefs/tags/%s\n' "$tag"; [ $pushmain = no ] || printf ' \trefs/heads/main\n')
  got=$(awk -F '\t' 'NF >= 3 { split($2, a, ":"); print $1 "\t" a[2] }' "$st/dry" | sort)
  [ "$got" = "$(printf '%s\n' "$want" | sort)" ] || die "the dry-run push lists other refs than $( [ $pushmain = no ] || echo 'main and ')$tag: $(tr '\t\n' ' ;' < "$st/dry")"
}
ship_exit() { # rc: ship's one exit handler, set once by ship_run and never replaced
  trap '' $SIGS PIPE
  exec 1>&8 2>&9   # ship's own stdout and stderr, whatever call a signal interrupted (ship_run); before any output
  rc=$1 n=0 nf=$out/$tag.ship-next.txt wrote=no nfleft=no
  [ "$shipok" = yes ] || [ "$rc" != 0 ] || rc=1   # a stop is never status 0
  # a write to a closed stdout leaves its bytes in the shell's buffer, and bash 3.2 hands them to the
  # next builtin write with a redirection, or to a $( ) (measured 2026-10-12): one byte to /dev/null
  # drains them, before each of those here (notify's own stderr line may carry them: the terminal)
  drain
  # 1. a stop of a run that holds the lock: what to run next, built from this run's own record, to
  # its file first (a closed terminal or pipe cannot lose it), then to stdout, at once. A stop before
  # A8 that cannot vouch for an earlier run's file (an A4 refusal, or a stop before A4 passed: both
  # before the push) keeps it; from A8 on, this run's own text is the file (C5's A4 refusal included).
  # When ship logged in (REV 10 rule 6), the text's line 2 says ship logs out of its own session as it
  # ends (REV 12 rule 4: no npm command), in the file before the logout runs: a KILL during the logout
  # leaves it in place. A release done has a file then too, that line alone
  txt="" keep=no lo="" pl=""
  if [ "$logged_in" = yes ]; then
    pl="ship logged in to npm in this run, with its own file (${out%/}/.$tag.npm/npmrc), and logs out as it ends. If that logout fails, the session ends by itself $( [ -n "${ship_end:-}" ] && printf 'at %s ' "$ship_end")(2 hours after its login), and the next ship or publish-npm run of $tag with this out dir logs out of it first."
  fi
  if [ "$locked" = yes ] && [ "$shipok" != yes ]; then
    txt=$(ship_stoptext)
    if [ -f "$nf" ] && [ $armed = no ] && { [ $pubok = no ] || grep -qx -e public -e lost -e unreadable "$shipcls" 2>/dev/null; }; then
      keep=yes
    fi
  elif [ "$locked" = yes ] && [ -n "$pl" ]; then
    txt="release: ship $tag is public on GitHub, Homebrew and npm; ship's npm session is left:"
  fi
  if [ -n "$txt" ]; then
    drain
    if [ $keep = yes ]; then
      printf '%s\n' "$txt" "release: an earlier run's next steps ($nf), kept as they are:"
      cat "$nf" 2>/dev/null
    else
      body=$txt; [ -z "$pl" ] || body=$(line2 "$txt" "$pl")
      if nfput "$body"; then wrote=yes; else nfgone; fi
      printf '%s\n' "$body"
      [ -n "$pl" ] || nfsaid
    fi
  fi
  # 2. the npm session ship made: the logout of P (REV 12 rule 4): exit 0, D removed; a failure, P kept
  # for the next run, which logs out of it first (in a dry entry the temp HOME still exists here)
  if [ "$logged_in" = yes ]; then
    drain; npm_out "$st" || n=1
    # (npm's words only through redact: its URL names the token it sends; REV 11 rule 5)
    drain; lw=$(errcut "$st/out.err" 200); [ "$n" = 0 ] || [ -z "$lw" ] || { redact "$(npmadv < "$st/out.err")"; echo; } >&2
  fi
  if [ "$n" != 0 ]; then
    rc=1
    drain; lo=$(redact "$(npm_left "$lw")")
  fi
  # the logout's outcome (REV 10 rule 6): the file rewritten whole (nfput), the logout's remedy in the
  # step's place, or the step taken out (a release done: no file); then stdout
  if [ -n "$pl" ] && [ -n "$txt" ] && [ $keep = no ]; then
    drain
    if [ -n "$lo" ]; then
      [ $wrote = no ] || nfput "$(line2 "$txt" "$lo")" || nfkept
      printf '%s\n' "release: $lo"; nfsaid
    else
      if [ "$shipok" = yes ]; then rm -f "$nf"; else [ $wrote = no ] || nfput "$txt" || nfkept; fi
      printf '%s\n' "release: ship's npm session is ended (its own file removed)."
      [ "$shipok" = yes ] || nfsaid
    fi
  elif [ -n "$lo" ]; then
    drain; echo "release: $lo"
  fi
  # 3. one notification, once armed: done only after the logout ended
  if [ "$armed" = yes ]; then
    if [ "$shipok" = yes ] && [ "$n" = 0 ]; then notify done
    elif [ "$shipok" = yes ]; then notify logout-failed
    elif [ "$n" = 0 ]; then notify "failed-$phase"
    else notify "logout-failed-$phase"; fi
  fi
  [ "$shipok" != yes ] || [ "$n" != 0 ] || rm -f "$nf"   # a release done, ship's session ended: no steps left
  # 4. the frozen tree, the temp dirs, the lock (only this run's)
  [ -z "$wt" ] || git -C "$oroot" worktree remove --force "$wt" >/dev/null 2>&1
  rm -rf "${st:?}"
  [ -z "$DRYHOME" ] || rm -rf "$DRYHOME"
  [ "$locked" = yes ] && rm -rf "${out:?}/.ship.lock"
  exit "$rc"
}
drain() { printf '\n' > /dev/null 2>&1; }
# ship_clock EPOCH: that moment on this machine's clock, with its zone: "HH:MM ZONE on YYYY-MM-DD"
# (REV 10 rule 7), or nothing. GNU date (it answers --version) reads -d @N; BSD date reads -r N. GNU's
# -r reads a FILE's time, so -r first let a file in the cwd named like the number answer (r12a F7)
ship_clock() {
  case ${1:-} in ''|*[!0-9]*) return 0 ;; esac
  if date --version > /dev/null 2>&1; then c_=$(date -d "@$1" '+%H:%M %Z on %Y-%m-%d' 2>/dev/null)
  else c_=$(date -r "$1" '+%H:%M %Z on %Y-%m-%d' 2>/dev/null); fi || return 0
  case $c_ in [0-2][0-9]:[0-5][0-9]' '?*' on '[0-9][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]) printf '%s' "$c_" ;; esac
}
# line2 TEXT LINE: TEXT with LINE as its second line
line2() { printf '%s\n' "$1" | sed -n 1p; printf '%s\n' "$2"; printf '%s\n' "$1" | sed 1d; }
# nfput TEXT: the next file holds TEXT, whole or not at all (REV 10 rule 6): written to a temp file
# beside it (the lock is held: one writer) by /usr/bin/printf (r16b F2: bash 3.2's builtin keeps a failed
# write's bytes, a full disk's, and the next write hands them on: the stop line twice), then renamed onto it; a failed write leaves it as it was
# (ship_exit then calls nfgone). It succeeds only when the name then holds a regular file (REV 11b rule
# 15): mv -f onto a directory puts the text inside it and says it worked (r15b N5); and only when the
# temp file, and then that file, hold exactly the text (read back: /usr/bin/printf exits 0 when a full
# disk took none of it; r17b F3)
nfput() {
  [ ! -d "$nf" ] || return 1
  # (r16b F4: what is at the temp name goes first, a link among them, and the write makes a new file,
  # noclobber: no write goes through a link; a file the write left short is not the text: rm, 1)
  rm -f "$out/.$tag.ship-next.tmp" 2>/dev/null
  ( set -C; /usr/bin/printf '%s\n' "$1" > "$out/.$tag.ship-next.tmp" ) 2>/dev/null && /usr/bin/printf '%s\n' "$1" | /usr/bin/cmp -s - "$out/.$tag.ship-next.tmp" \
    && mv -f "$out/.$tag.ship-next.tmp" "$nf" 2>/dev/null || { rm -f "$out/.$tag.ship-next.tmp" 2>/dev/null; return 1; }
  [ -f "$nf" ] && [ ! -L "$nf" ] && /usr/bin/printf '%s\n' "$1" | /usr/bin/cmp -s - "$nf" && return 0
  rm -f "$nf" 2>/dev/null; return 1   # (the rename left no regular file at the name: what is there is this run's own)
}
# nfgone: after a write of the next file failed, no other text stays at its name (REV 11b rule 15: an
# earlier run's, or this run's from before its logout, names steps that are not these): ship removes
# it; nfleft says what is there now (removed, or yes: something ship cannot remove, a directory), for nfsaid
nfgone() {
  [ -e "$nf" ] || [ -L "$nf" ] || return 0
  if [ ! -d "$nf" ] && rm -f "$nf" 2>/dev/null && [ ! -e "$nf" ] && [ ! -L "$nf" ]; then nfleft=removed; else nfleft=yes; fi
}
# nfkept: after a failed rewrite (after the logout; r16b F3): this run's own file, written before the
# logout, holds these steps (its line 2, pl, holds whatever the logout did): it stays (nfleft=kept); when
# no regular file is left at the name, as after a failed first write (nfgone)
nfkept() { if [ -f "$nf" ] && [ ! -L "$nf" ]; then nfleft=kept; else wrote=no; nfgone; fi; }
# nfsaid: where else the steps are: the next file, or that it could not be written (wrote, ship_exit's),
# and what nfgone or nfkept did with what was at its name
nfsaid() {
  if [ "$wrote" = yes ] && [ "$nfleft" = kept ]; then printf '%s\n' "release: (the next file, $nf, could not be rewritten after the logout: it holds these steps as this run wrote them before the logout)"
  elif [ "$wrote" = yes ]; then printf '%s\n' "release: (these steps are also in $nf)"
  elif [ "$nfleft" = removed ]; then printf '%s\n' "release: (the next file, $nf, could not be written: these steps are only here. ship removed the earlier next file that was there)"
  elif [ "$nfleft" = yes ]; then printf '%s\n' "release: (the next file, $nf, could not be written: these steps are only here. What is at $nf is not these steps: do not use it)"
  else printf '%s\n' "release: (the next file, $nf, could not be written: these steps are only here)"; fi
}
# ship_stoptext: what to run after a stop, from this run's progress file (the last phase it started
# or finished), the stop's class and its cause; no network read. Every command names --out
ship_stoptext() {
  rec_=$(cat "$shipprog" 2>/dev/null)
  last=$(printf '%s\n' "$rec_" | grep -v '^run ' | tail -1)
  cls=$(cat "$shipcls" 2>/dev/null) cause=$(cat "$shipcause" 2>/dev/null)
  [ -n "$cause" ] || cause="a signal, or a step that named no cause"
  # each runnable line names the operator's checkout by its absolute path (oroot: root is the frozen
  # tree by now), so it runs as printed from any directory (a new terminal window opens in ~)
  run="  sh $(dq "$oroot/scripts/release.sh")" o="--out $(dq "$out") $tag"
  mainp=""; for p_ in ${SR_NPM_PKGS:-}; do mainp=$p_; done
  up=$(printf '%s\n' "$rec_" | sed -n 's/^start npm-platform //p'); printf '%s\n' "$rec_" | grep -qx 'start npm-main' && up="$up $mainp"
  echo "release: ship $tag stopped at $phase: $cause"
  # a record ship wrote and cannot read back (no run line: removed, cut short, a mode): it cannot tell how
  # far this run got, so the route that holds after any step, never "nothing is public" (REV 12b rule 21)
  case $rec_ in
    "run "*) ;;
    *) if [ "${progok:-no}" = yes ]; then
         echo "ship cannot read its own record ($shipprog): it cannot tell how far this run got. Check whether $tag is on GitHub:"
         echo "  git -C $(dq "$oroot") ls-remote origin refs/tags/$tag"
         echo "If that prints nothing: run ship again. If it prints a line, check GitHub's releases for $tag:"
         echo "  a draft is not public: delete it on GitHub, then run:"; echo "  $run publish $o"
         echo "  a public release: run:"; echo "  $run publish-cask $o"
         echo "  neither: run:"; echo "  $run publish $o"
         echo "Then:"; echo "$run publish-npm $o"
         echo "publish-npm skips a version npm already shows with this file."
         return 0
       fi ;;
  esac
  case $last in
    '')
      # no readable class (its write did not land): nothing is said about what is public, and no
      # remedy that a class decides (REV 12b rule 21)
      if [ -z "$cls" ]; then
        echo "ship cannot read this stop's class ($shipcls): it says nothing here about what is public."
        echo "When the cause above is fixed, run ship again: it refuses when anything of $tag is public."
        return 0
      fi
      case $cls in
        public)
          echo "ship does not continue a release of which anything is public."
          if [ -f "$out/$tag/MANIFEST.json" ] && grep -q "^ *\"tag\": \"$tag\"" "$out/$tag/MANIFEST.json" && grep -q "^ *\"commit\": \"${commit:-none}\"" "$out/$tag/MANIFEST.json"; then
            echo "Never rebuild it: continue from $out/$tag with the separate steps (PHASE3.md §5), in order:"
            echo "$run npm-check $o"
            echo "$run publish $o"
            echo "When the GitHub release is already public, run this instead of the line above:"
            echo "$run publish-cask $o"
            echo "$run publish-npm $o"
          else
            echo "Continue with the separate steps of PHASE3.md §5: build --sign, npm-check, the push, publish, publish-npm."
          fi ;;
        lost) echo "ship does not continue: release a new version." ;;
        unreadable) echo "This run made nothing public."; echo "When the cause above is fixed, run ship again." ;;
        *)
          if [ $pubok = yes ]; then echo "Nothing is public."; else echo "This run made nothing public."; fi
          case $cls in
            network) echo "Run ship again." ;;
            content) echo "Move $out/$tag aside (never delete it), then run ship again." ;;
            diverged) [ ! -e "$out/$tag" ] || echo "Move $out/$tag aside (it holds a build of the old commit)."
              echo "Tag again on top of origin's main, then run ship." ;;
            *) echo "When the cause above is fixed, run ship again." ;;
          esac ;;
      esac
      return 0 ;;
    'push refused: main unmoved')
      echo "Nothing is public: the push was refused, and nothing of it landed; origin's main did not move."
      echo "When the cause above is fixed, run ship again."
      return 0 ;;
    'push refused: main holds it')
      echo "Nothing is public: the push was refused, and nothing of it landed; origin's main moved on, and holds $tag's commit."
      echo "Run ship again."
      return 0 ;;
    'push refused'*)
      echo "Nothing is public: the push was refused, and nothing of it landed."
      echo "Move $out/$tag aside (it holds a build of the old commit). Tag again on top of origin's main, then run ship."
      return 0 ;;
    'start push')
      echo "The push started and was not confirmed. Check whether $tag is on GitHub:"
      echo "  git -C $(dq "$oroot") ls-remote origin refs/tags/$tag"
      echo "If it is not: run ship again. If it is, run in order:"
      echo "$run publish $o"; echo "$run publish-npm $o" ;;
    'done push')
      echo "$tag is pushed; nothing else is public. Run in order:"
      echo "$run publish $o"; echo "$run publish-npm $o" ;;
    'start npm-platform '*|'done npm-platform '*)
      echo "$tag is pushed, and npm may hold a part of it; GitHub has no release of it. Run in order:"
      echo "$run publish $o"; echo "$run publish-npm $o" ;;
    'start github')
      # Gatekeeper rejected the build at C7 (verify, before any GitHub call): no publish step is named;
      # publish and publish-npm both run verify, and refuse it (REV 12b rule 23)
      if [ "$cls" = gatekeeper ]; then
        echo "$tag is pushed, and npm holds its platform packages (uploaded before this check); GitHub has no release of it."
        echo "Gatekeeper rejects this build (above): it is not published on GitHub, and publish-npm refuses it too (it runs verify first). Release a new version."
        return 0
      fi
      echo "$tag is pushed, and npm may hold a part of it; the GitHub publish stopped. Check GitHub's releases for $tag:"
      echo "  a draft is not public: delete it on GitHub, then run:"; echo "  $run publish $o"
      echo "  a public release: run:"; echo "  $run publish-cask $o"
      echo "  neither: run:"; echo "  $run publish $o"
      echo "Then:"; echo "$run publish-npm $o" ;;
    exit5)
      echo "$tag is public on GitHub, but its Homebrew cask is not updated, and npm may hold a part of it. Run in order:"
      echo "$run publish-cask $o"; echo "$run publish-npm $o" ;;
    'done github'|'start npm-main')
      echo "$tag is public on GitHub and Homebrew, and npm may hold a part of it. Run in order:"
      echo "$run publish-npm $o" ;;
    *) echo "$tag is public on GitHub, Homebrew and npm." ;;
  esac
  # after an upload: the wait, and npm's review
  if [ -n "$(printf '%s' "$up" | tr -d ' ')" ]; then
    for p_ in $up; do echo "If npm still scans $p_@${tag#v}, wait until https://www.npmjs.com/package/$p_ shows ${tag#v} before publish-npm."; done
    echo "publish-npm skips a version npm already shows with this file."
    echo "npm may hold a version for review, or block it: look at npm's email to ${SR_NPM_USER:-the owner}. A blocked version needs a new version number."
  fi
}

case $sub in
  check) checks ;;
  verify) verify "$out/$tag" ;;
  build)
    checks
    if [ $sign = no ]; then build_release unsigned
    elif [ $nonot = yes ]; then build_release control
    else build_release signed; fi ;;
  publish) publish ;;
  __publish-dry) publish_dry ;;
  publish-cask) publish_cask ;;
  __publish-cask-dry) publish_cask_dry ;;
  publish-npm) publish_npm ;;
  __publish-npm-dry) publish_npm_dry ;;
  # the cells' view of the npm class: the environment the real run's npm gets, then the arguments
  # npm_env adds after the command, one arg= line each (it runs only env and printf)
  ship) ship ;;
  __ship-dry) ship_dry ;;
  __npm-env) tool npm /bin/sh -c '/usr/bin/env; for a; do printf "arg=%s\n" "$a"; done' sh ;;
  __tool-class) tool "${SR_TOOL_CLASS-}" /bin/echo ran ;;   # the cells: tool with SR_TOOL_CLASS's class
  __curl-env) real_tools; tool "$CURLC" /usr/bin/env ;;
  npm-check) npm_check "$out/$tag" ;;
  # the cells' view of a check's stop class: the check in a subshell, as ship's C2 and C3 run it, with
  # a class file of its own (fix first, as ship sets it); then the class it left
  __class-verify|__class-npm-check)
    shipcls=$(mktemp /private/tmp/sr-class.XXXXXX) || die "no temp file"; fput "$shipcls" 'fix\n' || die "cannot write $shipcls"
    if [ "$sub" = __class-verify ]; then ( verify "$out/$tag" ); else ( npm_check "$out/$tag" ); fi; r_=$?
    echo "release: (class) $(cat "$shipcls")"; rm -f "$shipcls"; exit "$r_" ;;
esac
