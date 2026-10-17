#!/bin/sh
# A release notification (PHASE3.md D2 step 3; the ship plan): a macOS notification and the terminal
# bell, so an operator who left the desk comes back for a step only a human can do.
#
#   notify.sh KEY TAG [DIR]
#
# KEY picks the text from the fixed table below; TAG (vX.Y.Z or vX.Y.Z-rc.N, one line) is the only
# thing put into it, and the phase of failed-PHASE and logout-failed-PHASE (a letter, then letters,
# digits and -, at most 32 in all). Never a tool's output. The keys: password, password-again,
# npm-login, npm-approve, npm-approve-next, npm-approve-again, done, logout-failed, failed-PHASE,
# logout-failed-PHASE (a stop and a failed npm logout: one notification names both). DIR, the out dir
# (absolute, no control character), makes failed-PHASE and logout-failed-PHASE name the next file by
# its full path, DIR/TAG.ship-next.txt (release.sh gives it): a notification read later, in another
# window, must name a file that opens from there. Any other DIR is not used: the text names the file
# by its name, and the notification is still shown (a stop must not go unseen; stderr says why).
#
# Real mode (SR_NOTIFY_OSASCRIPT not set at all): the bell on /dev/tty, then /usr/bin/osascript
# shows the text, which it gets after `--` (without it, a text that starts with -e is compiled as
# AppleScript; measured). With it, the text is item 1 of argv whatever it holds (measured
# 2026-10-11: `/usr/bin/osascript -e 'on run argv' -e 'return item 1 of argv' -e 'end run' -- -e`
# prints `-e`). Dry mode (the cells: SR_NOTIFY_OSASCRIPT set, even to nothing): it must
# name a stand-in, checked as release.sh's `standins` checks one (a script, not a symlink, whose
# real directory is a /private/tmp/sr-p3-fixtures.* directory), else nothing is run; the stand-in
# gets the same arguments as osascript; no bell.
#
# Always exits 0: a notification never stops a release. An unknown key, a bad tag or phase, a
# refused stand-in or a failing osascript shows nothing and says so on stderr. osascript runs with
# no time limit.
set -u
PATH=/usr/bin:/bin; export PATH
LC_ALL=C; export LC_ALL
say() { echo "notify: $*" >&2; }
refuse() { say "refused: $*; nothing shown"; exit 0; }
phase_ok() { # phase key
  case $1 in [a-z]*) ;; *) refuse "the key '$2' (a phase starts with a letter)" ;; esac
  case $1 in *[!a-z0-9-]*) refuse "the key '$2' (a phase is letters, digits and -)" ;; esac
  [ ${#1} -le 32 ] || refuse "the key '$2' (a phase has at most 32 characters)"
}

key=${1:-} tag=${2:-} dir=${3:-}
tagre='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.[1-9][0-9]*)?$'
printf '%s\n' "$tag" | grep -Eq "$tagre" && [ "$(printf '%s' "$tag" | wc -l | tr -d ' ')" = 0 ] \
  || refuse "the tag '$tag' is not vX.Y.Z or vX.Y.Z-rc.N"
nf=$tag.ship-next.txt
if [ -n "$dir" ]; then
  case $dir in
    *[[:cntrl:]]*) say "the out dir holds a control character: the text names the next file by its name only" ;;
    /*) nf=${dir%/}/$tag.ship-next.txt ;;
    *) say "the out dir '$dir' is not an absolute path: the text names the next file by its name only" ;;
  esac
fi
case $key in
  password) text="$tag: type the notary keychain password in the terminal" ;;
  password-again) text="$tag: Apple did not accept the submission. Type the notary keychain password again in the terminal, to fetch Apple's log" ;;
  npm-login) text="$tag: log in to npm in the browser (npm login)" ;;
  npm-approve) text="$tag: approve the npm upload in the browser (tick skip for 5 minutes)" ;;
  npm-approve-next) text="$tag: npm may ask again: approve the next npm upload in the browser" ;;
  npm-approve-again) text="$tag: npm may ask again: approve the upload of the main package in the browser" ;;
  done) text="$tag is public on GitHub, Homebrew and npm" ;;
  logout-failed) text="$tag: npm logout failed. Run cd / && npm logout --registry=https://registry.npmjs.org/ in the terminal" ;;
  failed-*)
    phase=${key#failed-}; phase_ok "$phase" "$key"
    text="$tag stopped at $phase. What to run next is in $nf" ;;
  logout-failed-*)
    phase=${key#logout-failed-}; phase_ok "$phase" "$key"
    text="$tag stopped at $phase, and npm logout failed. Run cd / && npm logout --registry=https://registry.npmjs.org/ in the terminal; what to run next is in $nf" ;;
  *) refuse "the key '$key' is not in the table" ;;
esac

if [ "${SR_NOTIFY_OSASCRIPT+set}" = set ]; then
  # dry mode: a stand-in, checked as release.sh's standins checks one; never the real osascript
  p=$SR_NOTIFY_OSASCRIPT
  case $p in *[[:cntrl:]]*) refuse "SR_NOTIFY_OSASCRIPT holds a control character" ;; esac
  [ -n "$p" ] && [ -f "$p" ] && [ ! -L "$p" ] && [ -x "$p" ] || refuse "SR_NOTIFY_OSASCRIPT is not an executable file (and not a symlink)"
  pd=$(cd -P "$(dirname "$p")" 2>/dev/null && pwd -P) || refuse "SR_NOTIFY_OSASCRIPT: cannot resolve its directory"
  case $pd/ in /private/tmp/sr-p3-fixtures.*/) ;; *) refuse "SR_NOTIFY_OSASCRIPT must be a stand-in in a /private/tmp/sr-p3-fixtures.* directory, not in $pd" ;; esac
  [ "$(head -c 2 "$p")" = '#!' ] || refuse "SR_NOTIFY_OSASCRIPT must be a script stand-in"
  osa=$pd/$(basename "$p") bell=no
else
  osa=/usr/bin/osascript bell=yes
fi
[ $bell = no ] || { printf '\a' > /dev/tty; } 2>/dev/null
"$osa" -e 'on run argv' -e 'display notification (item 1 of argv) with title "sheepr release"' -e 'end run' -- "$text" > /dev/null
r=$?
[ $r = 0 ] || say "osascript exit $r: the notification was not shown"
exit 0
