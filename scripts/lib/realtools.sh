# The read-only Apple tools, by absolute path (env too), each with its one subcommand (PHASE3.md §1.3).
# Sourced by release.sh (verify, publish, npm-check). A shim on PATH cannot answer for them, and
# DEVELOPER_DIR is unset for xcrun (it follows DEVELOPER_DIR to any tool). The requirement comes
# from release.conf, never from a caller. Each takes only a path.
#   rt_meets PATH        the Developer ID release requirement holds for PATH
#   rt_staple_ok PATH    the staple ticket validates
#   rt_spctl_ok PATH     Gatekeeper accepts PATH for execution (-vv: its source= line in its words)
# Each answers as rt_judge does: 0 accepts; 1 the tool refused PATH (its own refusal); 2 no verdict.
# rt_judge CODES CMD...: one tool's verdict. 1 only for the tool's own refusal: an exit in CODES (the
# refusal exits measured on this Mac: codesign 1 and 3, spctl 3, stapler 65; notes/r13b/probe/apple)
# with words. 2, no verdict, for any other exit, an exit above 125 (it cannot run, or a signal stopped
# it), an "xcrun: error:" line (xcrun's own: the tool was not reached), an Xcode license text, or no
# words: a refusal with no verdict is no finding about the bytes (r12b F1, r13b F1). Its words go to
# $RT_OUT (a file the caller names; none: /dev/null, so no verdict), its exit to rt_rc
rt_judge() {
  c_=$1; shift; o_=${RT_OUT:-/dev/null}
  "$@" > "$o_" 2>&1 8>&- 9>&- && { rt_rc=0; return 0; }   # (fds 8 and 9: ship's own, never a child's)
  rt_rc=$?
  [ "$rt_rc" -le 125 ] || return 2
  case " $c_ " in *" $rt_rc "*) ;; *) return 2 ;; esac
  [ -s "$o_" ] || return 2
  /usr/bin/grep -q '^xcrun: error:' "$o_" && return 2
  /usr/bin/grep -qi 'license' "$o_" && return 2
  return 1
}
rt_meets() { rt_judge "1 3" /usr/bin/codesign -v -R="$SR_RELEASE_REQUIREMENT" "$1"; }
rt_staple_ok() { rt_judge 65 /usr/bin/env -u DEVELOPER_DIR -u SDKROOT -u TOOLCHAINS /usr/bin/xcrun stapler validate "$1"; }
rt_spctl_ok() { rt_judge 3 /usr/sbin/spctl -a -vv -t exec "$1"; }
