#!/bin/sh
# Render the Homebrew cask for a release (PHASE3.md S4) from packaging/homebrew/sheepr.rb.in:
#   render-cask.sh VERSION SHA256 OUT
# VERSION is X.Y.Z or X.Y.Z-rc.N; SHA256 the macOS archive's (64 lowercase hex digits).
set -u
[ $# -eq 3 ] || { echo "usage: render-cask.sh VERSION SHA256 OUT" >&2; exit 2; }
v=$1 h=$2 o=$3
lib=$(cd "$(dirname "$0")" && pwd -P) || exit 1
# one line only: grep matches line by line, so a second line would pass unchecked
one() { printf '%s\n' "$1" | grep -Eq "$2" && [ "$(printf '%s' "$1" | wc -l | tr -d ' ')" = 0 ]; }
one "$v" '^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[1-9][0-9]*)?$' || { echo "render-cask: bad version $v" >&2; exit 2; }
one "$h" '^[0-9a-f]{64}$' || { echo "render-cask: bad sha256 $h" >&2; exit 2; }
# the render read back before the rename: sed may exit 0 when a full disk took none of its bytes (as
# /usr/bin/printf does: r17b F1), and a short cask would read as another one
t_=$lib/../../packaging/homebrew/sheepr.rb.in
sed -e "s/@VERSION@/$v/" -e "s/@SHA256@/$h/" "$t_" > "$o.tmp" && sed -e "s/@VERSION@/$v/" -e "s/@SHA256@/$h/" "$t_" | /usr/bin/cmp -s - "$o.tmp" && mv "$o.tmp" "$o" \
  || { rm -f "$o.tmp"; echo "render-cask: cannot write $o" >&2; exit 1; }
