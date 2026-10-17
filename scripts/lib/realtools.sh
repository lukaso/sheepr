# The read-only Apple tools, by absolute path (env too), each with its one subcommand (PHASE3.md §1.3).
# Sourced by release.sh (verify, publish, npm-check). A shim on PATH cannot answer for them, and
# DEVELOPER_DIR is unset for xcrun (it follows DEVELOPER_DIR to any tool). The requirement comes
# from release.conf, never from a caller. Each takes only a path.
#   rt_meets PATH        the Developer ID release requirement holds for PATH
#   rt_staple_ok PATH    the staple ticket validates
#   rt_spctl_ok PATH     Gatekeeper accepts PATH for execution
# Each answers as rt_judge does: 0 accepts; 1 the tool judged PATH and refuses; 2 no verdict.
# rt_judge CMD...: one tool's verdict. Its words go to $RT_OUT (a file the caller names; none:
# /dev/null). 2, no verdict, when it cannot run (exit 126 or 127), an Xcode license stops it, or it
# gave no words: a refusal with no verdict is no finding about the bytes (r12b F1)
rt_judge() {
  o_=${RT_OUT:-/dev/null}
  "$@" > "$o_" 2>&1 && return 0
  r_=$?
  case $r_ in 126|127) return 2 ;; esac
  [ -s "$o_" ] || return 2
  /usr/bin/grep -qi 'license' "$o_" && return 2
  return 1
}
rt_meets() { rt_judge /usr/bin/codesign -v -R="$SR_RELEASE_REQUIREMENT" "$1"; }
rt_staple_ok() { rt_judge /usr/bin/env -u DEVELOPER_DIR -u SDKROOT -u TOOLCHAINS /usr/bin/xcrun stapler validate "$1"; }
rt_spctl_ok() { rt_judge /usr/sbin/spctl -a -t exec "$1"; }
