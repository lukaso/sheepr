#!/bin/sh
# PHASE3.md §5: `release.sh publish-npm vTAG`, dry (`__publish-npm-dry`: npm is a stand-in given by
# path under /private/tmp/sr-p3-fixtures.*, never the real one; a fresh temp HOME). With decoy
# tokens in the environment:
#   - the whole run: for each package, platform packages first and the main one last, the npm
#     registry (registry.npmjs.org) is
#     asked whether that version is there (`view --json --prefer-online`, the registry pinned on the
#     command line), then `npm publish --access public` of a private copy of <out>/vTAG's file
#     whose bytes are the manifest's (a sibling -unsigned directory's packages never named); an rc
#     adds `--tag next` (npm makes a version without a tag `latest`); a manifest for another commit
#     than the tag's is refused;
#   - npm gets only the named environment: no decoy token reaches it;
#   - nothing at all without npm-check's stamp for this tag and manifest, or with a control manifest;
#   - each file is hashed against its manifest entry just before its upload: a package changed
#     during the run is refused there, with nothing after it published;
#   - a resumed run: a version already on npm with this file's integrity is skipped; with another
#     file's, refused, with nothing after it published; a view that fails other than with E404,
#     refused there;
#   - __publish-npm-dry refuses a stand-in outside /private/tmp/sr-p3-fixtures.*;
#   - the notifier (the ship plan, slice 2): NOTIFY, a stand-in in the dry entry
#     (SR_PUBLISH_DRY_NOTIFY; unset, NOTIFY stays empty and publish_npm_exec refuses it, "no
#     notifier"; empty, outside the fixtures, a symlink or the real notify.sh: refused by the stand-in
#     checks; each before any npm call; NOTIFY, NPM and NETC are never exported), is called
#     with SR_NOTIFY_OSASCRIPT set (so no dry run can show a real notification): `npm-approve-again`
#     right before the main package's upload; the real entry's body pinned;
#   - npm_part (the batch order under ship; SR_PUBLISH_DRY_NPM_PART in the dry entry, never
#     inherited): empty is today's order, also with npm_part exported; `platform` uploads the
#     platform packages back to back (`npm-approve` before the first upload), waits for nothing and
#     never touches the main package; a refused upload stops it; `main` waits until npm shows each
#     platform package (never uploading one), then uploads the main one and waits for it.
# Every dry run here is inside lib.sh's no-osascript wall.
set -u
. "$(dirname "$0")/lib.sh"
fx_dir; fx_repo
wall_ok && pass "the wall: a path naming osascript cannot run here, another can" || { fail "the no-osascript wall does not hold: nothing else runs"; finish; }
fx_release 0.1.0 1 v0.1.0
DECOY=decoy-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
PK="sheepr-linux-arm64 sheepr-linux-x64 sheepr-darwin-universal sheepr"
mkout() { # dir tag [control] [commit]: the four packages, the manifest naming each one's hash and the
           # tag's commit, npm-check's stamp
  rm -rf "$1"; mkdir -p "$1"; v=${2#v}
  for p in $PK; do echo "$p $v $1" > "$1/$p-$v.tgz"; done
  { printf '{\n  "v": 1,\n  "tag": "%s",\n  "commit": "%s",\n  "mode": "signed",\n  "control": %s,\n  "files": [\n' "$2" "${4:-$(g rev-parse "$2^{commit}")}" "${3:-false}"
    sep=""; for p in $PK; do f=$p-$v.tgz
      printf '%s    {"name": "%s", "sha256": "%s"}' "$sep" "$f" "$(shasum -a 256 "$1/$f" | cut -d' ' -f1)"; sep=",
"; done; printf '\n  ]\n}\n'; } > "$1/MANIFEST.json"
  printf '%s %s\n' "$2" "$(shasum -a 256 "$1/MANIFEST.json" | cut -d' ' -f1)" > "$1/NPM-CHECKED"
}
integrity() { python3 -c 'import base64,hashlib,sys; print("sha512-" + base64.b64encode(hashlib.sha512(open(sys.argv[1], "rb").read()).digest()).decode())' "$1"; }
# `config get userconfig` answers the userconfig npm loads (--userconfig, else the environment's, else
# $HOME/.npmrc), or $FX/other.npmrc when $FX/ucother exists. $FX/whoamicode, $FX/viewcode.<package> (the views before its
# upload) and $FX/viewcodeafter.<package> (the views after it): that call answers the file's npm error code.
# `whoami` prints $FX/whoami (exit 1 with ENEEDAUTH if $FX/whoamifail exists); `owner ls NAME`
# prints a `user <email>` line per line of $FX/owner.NAME (default: lukasco), or exits 1 with E404
# ($FX/ownerfail.NAME) or another error ($FX/ownerbad.NAME), as npm 11.6.0 was measured to.
# the stand-in answers `view --json` as npm 11.6.0 was measured to (absent: exit 1 and an E404 on
# both streams; present: the integrity, quoted): from $FX/view.<package> (present), or
# $FX/viewfail.<package> (another failure); it runs $FX/onview.<package> first if there is one.
# `publish` records the sha256 of the file it was given, and runs $FX/onpublish.<package>. After a
# publish, `view` shows that file's integrity once $FX/processing.<package> (a count of "not found"
# answers, as npm answers while it processes a new package: measured 2026-10-04) has run down, or
# another integrity if $FX/pubwrong.<package> exists; $FX/emptyafter.<package> gives that many empty
# answers first, and $FX/viewfailafter.<package> makes every view after the publish fail (ETIMEDOUT).
# $FX/pubexists.<package>: the publish is refused with one possible answer to a version an earlier run
# published (E403, "cannot publish over"; npm's answer during its scan is not measured), and the version
# then shows as that run's file; $FX/pubfail.<package>: E401.
# `sleep` is a stand-in on PATH that records its seconds (the wait's real limit, without waiting).
cat > "$FX/npm" <<EOF
#!/bin/sh
n=\$(ls "$FX" | grep -c '^env\\.npm\\.'); env > "$FX/env.npm.\$n"
echo "npm \$*" >> "$FX/calls"
case \$1 in
  view) for a; do case \$a in sheepr*@*) p=\${a%@*} ;; esac; done
    [ -f "$FX/onview.\$p" ] && sh "$FX/onview.\$p"
    if [ -f "$FX/viewempty.\$p" ]; then exit 0; fi
    if [ -f "$FX/viewfail.\$p" ]; then printf '{\\n  "error": {\\n    "code": "ETIMEDOUT"\\n  }\\n}\\n'; echo "npm error code ETIMEDOUT" >&2; exit 1; fi
    if [ -f "$FX/viewcode.\$p" ] && [ ! -f "$FX/pub.\$p" ]; then echo "npm error code \$(cat "$FX/viewcode.\$p")" >&2; exit 1; fi
    if [ -f "$FX/viewcodeafter.\$p" ] && [ -f "$FX/pub.\$p" ]; then echo "npm error code \$(cat "$FX/viewcodeafter.\$p")" >&2; exit 1; fi
    if [ -f "$FX/pub.\$p" ]; then
      if [ -f "$FX/viewfailafter.\$p" ]; then printf '{\\n  "error": {\\n    "code": "ETIMEDOUT"\\n  }\\n}\\n'; echo "npm error code ETIMEDOUT" >&2; exit 1; fi
      e=\$(cat "$FX/emptyafter.\$p" 2>/dev/null || echo 0)
      if [ "\$e" -gt 0 ]; then echo \$((e - 1)) > "$FX/emptyafter.\$p"; exit 0; fi
      k=\$(cat "$FX/processing.\$p" 2>/dev/null || echo 0)
      if [ "\$k" -gt 0 ]; then echo \$((k - 1)) > "$FX/processing.\$p"; printf '{\\n  "error": {\\n    "code": "E404"\\n  }\\n}\\n'; echo "npm error code E404" >&2; exit 1; fi
      if [ -f "$FX/pubwrong.\$p" ]; then printf '"sha512-WRONG"\\n'; exit 0; fi
      printf '"%s"\\n' "\$(cat "$FX/pub.\$p")"; exit 0
    fi
    k=\$(cat "$FX/scan.\$p" 2>/dev/null || echo 0)   # an earlier run's upload, still scanned: "not found" that many times
    if [ "\$k" -gt 0 ]; then echo \$((k - 1)) > "$FX/scan.\$p"; printf '{\\n  "error": {\\n    "code": "E404"\\n  }\\n}\\n'; echo "npm error code E404" >&2; exit 1; fi
    if [ -f "$FX/view.\$p" ]; then printf '"%s"\\n' "\$(cat "$FX/view.\$p")"; exit 0; fi
    printf '{\\n  "error": {\\n    "code": "E404"\\n  }\\n}\\n'; echo "npm error code E404" >&2; exit 1 ;;
  whoami) [ -f "$FX/onwhoami" ] && sh "$FX/onwhoami"; if [ -f "$FX/whoamifail" ]; then echo "npm error code ENEEDAUTH" >&2; exit 1; fi
    if [ -f "$FX/whoamicode" ]; then echo "npm error code \$(cat "$FX/whoamicode")" >&2; exit 1; fi; cat "$FX/whoami"; exit 0 ;;
  config) [ "\$2 \$3" = "get userconfig" ] || exit 1
    [ -e "$FX/ucother" ] && { echo "$FX/other.npmrc"; exit 0; }
    u_=""; for a_; do case \$a_ in --userconfig=*) u_=\${a_#--userconfig=} ;; esac; done
    echo "\${u_:-\${NPM_CONFIG_USERCONFIG:-\${npm_config_userconfig:-\$HOME/.npmrc}}}"; exit 0 ;;
  owner) p=\$3
    if [ -f "$FX/ownerfail.\$p" ]; then echo "npm error owner ls Couldn't get owner data \$p" >&2; echo "npm error code E404" >&2; exit 1; fi
    if [ -f "$FX/ownerbad.\$p" ]; then echo "npm error code ETIMEDOUT" >&2; exit 1; fi
    if [ -f "$FX/owner.\$p" ]; then while read -r u; do echo "\$u <\$u@example.com>"; done < "$FX/owner.\$p"; else echo "lukasco <lukasco@example.com>"; fi; exit 0 ;;
  publish) for a; do last=\$a; done; p=\$(basename "\$last" | sed 's/^\\(.*\\)-[0-9][0-9.a-z-]*\\.tgz\$/\\1/')
    echo "\$p \$(shasum -a 256 "\$last" | cut -d' ' -f1) \$last" >> "$FX/pubsha"
    python3 -c 'import base64, hashlib, sys; print("sha512-" + base64.b64encode(hashlib.sha512(open(sys.argv[1], "rb").read()).digest()).decode())' "\$last" > "$FX/pub.\$p"
    if [ -f "$FX/pubexists.\$p" ]; then echo "npm error code E403" >&2; echo "npm error 403 403 Forbidden - PUT https://registry.npmjs.org/\$p - You cannot publish over the previously published versions: 0.1.0." >&2; exit 1; fi
    if [ -f "$FX/pubfail.\$p" ]; then echo "npm error code E401" >&2; echo "npm error 401 Unauthorized" >&2; exit 1; fi
    [ -f "$FX/onpublish.\$p" ] && sh "$FX/onpublish.\$p"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$FX/npm"
# the notifier's stand-in: "notify KEY TAG" into the calls, and whether SR_NOTIFY_OSASCRIPT was set
printf '#!/bin/sh\necho "notify $*" >> "%s/calls"\necho "${SR_NOTIFY_OSASCRIPT+set}" >> "%s/notifyenv"\n' "$FX" "$FX" > "$FX/notify"
chmod +x "$FX/notify"
# (it also records which of the entry's own variables reached it through the environment: names only)
mkdir -p "$FX/bin"; printf '#!/bin/sh\necho "$1" >> "%s/sleeps"\nfor k in shipping npm_part NOTIFY SHIP_BUILD SHIP_NPMCHECK SHIP_VERIFY CAFFEINATE SHIP_IDENTITY SHIP_DOCKER GH GITCMD NPM NPMC CURL CURLC NETC DRY dryentry shipprog shipcause shipcls ship_mh; do eval "[ -z \\"\\${$k+x}\\" ]" || echo "$k" >> "%s/exported"; done\n' "$FX" "$FX" > "$FX/bin/sleep"; chmod +x "$FX/bin/sleep"
echo lukasco > "$FX/whoami"
pub() { # tag -> rc; output in $FX/o. PART: SR_PUBLISH_DRY_NPM_PART; NOTI: the notifier (default the
       # stand-in; "-": none); PUBX: one more assignment. Set them as plain assignments, clear after
  rm -f "$FX/calls" "$FX"/env.npm.* "$FX/pubsha" "$FX"/pub.* "$FX/sleeps" "$FX/notifyenv"
  case ${NOTI:-} in -) nv_=SR_PUBLISH_DRY_NOTHING= ;; --empty) nv_=SR_PUBLISH_DRY_NOTIFY= ;; *) nv_=SR_PUBLISH_DRY_NOTIFY=${NOTI:-$FX/notify} ;; esac
  (cd "$REPO" && no_osascript env HOME="$FX/ghome" NPM_TOKEN="$DECOY" NODE_AUTH_TOKEN="$DECOY" npm_config__authToken="$DECOY" GH_TOKEN="$DECOY" \
    HTTPS_PROXY=http://127.0.0.1:9 NPM_CONFIG_USERCONFIG="$FX/decoy-npmrc" \
    PATH="$FX/bin:$PATH" SR_PUBLISH_DRY_NPM="$FX/npm" ${PART:+SR_PUBLISH_DRY_NPM_PART="$PART"} ${PUBX:+"$PUBX"} "$nv_" \
    sh scripts/release.sh __publish-npm-dry --out "$FX/out" "$1") > "$FX/o" 2>&1; r_=$?; sed -n 's/^release: __publish[a-z-]*-dry (.*a temp HOME, \(\/private\/tmp\/sr-dryhome\.[A-Za-z0-9]*\))$/\1/p' "$FX/o" >> "$FX/homes"
  return $r_
}
# "view NAME" or "publish NAME" per call (a name's parts start with a letter, a version with a digit)
order() { sed -En 's/^npm (view|publish) (.* |.*\/)(sheepr(-[a-z][a-z0-9]*)*)[-@][0-9].*$/\1 \3/p' "$FX/calls" 2>/dev/null | tr '\n' ','; }
D=$FX/out/v0.1.0
TODAY="view sheepr-linux-arm64,publish sheepr-linux-arm64,view sheepr-linux-arm64,view sheepr-linux-x64,publish sheepr-linux-x64,view sheepr-linux-x64,view sheepr-darwin-universal,publish sheepr-darwin-universal,view sheepr-darwin-universal,view sheepr,publish sheepr,view sheepr,"
mkout "$D" v0.1.0
mkout "$FX/out/v0.1.0-unsigned" v0.1.0
pub v0.1.0; r=$?
[ $r = 0 ] && pass "a dry publish-npm: done" || fail "dry publish-npm: rc=$r $(tail -2 "$FX/o" | tr '\n' ' ')"
[ "$(order)" = "view sheepr-linux-arm64,publish sheepr-linux-arm64,view sheepr-linux-arm64,view sheepr-linux-x64,publish sheepr-linux-x64,view sheepr-linux-x64,view sheepr-darwin-universal,publish sheepr-darwin-universal,view sheepr-darwin-universal,view sheepr,publish sheepr,view sheepr," ] \
  && pass "the order: each package asked for, then published; platform packages first, the main one last" || fail "the order: $(order)"
# each publish: the registry pinned, no --tag (a final), and a private copy of <out>/v0.1.0's file
# whose bytes, when npm got it, were the manifest's
REG="--registry=https://registry.npmjs.org/ --scope="   # the registry pinned, and no scope (REV 11 rule 2: npm's scope routes view, owner and publish)
bad=""; for p in $PK; do
  l=$(grep "^npm publish .*/$p-0.1.0.tgz\$" "$FX/calls"); f=${l##* }
  case $l in "npm publish --access public $REG /private/tmp/sr-npmpub."*"/$p-0.1.0.tgz") ;; *) bad="$bad [$l]" ;; esac
  [ "$(awk -v p="$p" '$1 == p {print $2}' "$FX/pubsha")" = "$(shasum -a 256 "$D/$p-0.1.0.tgz" | cut -d' ' -f1)" ] || bad="$bad [$p: not the manifest's bytes]"
done
[ -z "$bad" ] && pass "each publish: the registry pinned, no --tag (a final), a private copy holding the manifest's bytes" || fail "publish lines:$bad"
[ "$(grep -c "^npm view --json --prefer-online $REG sheepr[a-z0-9-]*@0.1.0 dist.integrity\$" "$FX/calls")" = 8 ] \
  && pass "each view (4 before the uploads, 4 after them): --json, --prefer-online (not npm's cache), the registry pinned" || fail "view lines: $(grep '^npm view' "$FX/calls" | head -1)"
[ "$(sed -n 1,6p "$FX/calls" | tr '\n' ',')" = "npm config get userconfig --scope=,npm whoami $REG,npm owner ls sheepr-linux-arm64 $REG,npm owner ls sheepr-linux-x64 $REG,npm owner ls sheepr-darwin-universal $REG,npm owner ls sheepr $REG," ] \
  && pass "before any view or upload: npm's userconfig (REV 11a rule 7), npm whoami, then the owners of all four names, the registry pinned" || fail "the first calls: $(sed -n 1,6p "$FX/calls" | tr '\n' ',')"
grep -q 'unsigned' "$FX/calls" && fail "a call names the -unsigned sibling" || pass "the -unsigned sibling's packages are never named"
# the notifications in today's order: one right before each upload that follows a wait (the operator
# may have left during it), none before the first: npm-approve-next before a platform package's,
# npm-approve-again before the main one's. befores: for each upload, the call line just before it
befores() { awk '/^npm publish/ { split($NF, a, "/"); n = a[length(a)]; sub(/-[0-9][0-9.a-z-]*\.tgz$/, "", n); printf "%s<%s>,", n, prev } { prev = $0 }' "$FX/calls" 2>/dev/null; }
case "$(befores)" in "sheepr-linux-arm64<npm view"*">,sheepr-linux-x64<notify npm-approve-next v0.1.0>,sheepr-darwin-universal<notify npm-approve-next v0.1.0>,sheepr<notify npm-approve-again v0.1.0>,") ok_=yes ;; *) ok_=no ;; esac
[ $ok_ = yes ] && [ "$(grep -c '^notify ' "$FX/calls")" = 3 ] \
  && pass "today's order: npm-approve-next before uploads 2 and 3, npm-approve-again before the main one, none before the first" || fail "the notifications: $(befores)"
[ "$(sort -u "$FX/notifyenv" 2>/dev/null)" = set ] && pass "the dry notifier runs with SR_NOTIFY_OSASCRIPT set (no dry run can show a real notification)" || fail "the dry notifier's SR_NOTIFY_OSASCRIPT: '$(cat "$FX/notifyenv" 2>/dev/null)'"
pd=$(awk 'NR == 1 {print $3}' "$FX/pubsha"); pd=${pd%/*}
case $pd in /private/tmp/sr-npmpub.*) [ ! -e "$pd" ] && pass "this run's private copy dir is gone" || fail "$pd is left" ;; *) fail "no private copy dir recorded: '$pd'" ;; esac
# npm's environment class (npm_env, the real run's too): only the named variables; a proxy reaches
# it (the control), a token never does in the dry run; the userconfig the entry got reaches npm as
# NPM_CONFIG_USERCONFIG, in the dry class as in the real one (REV 11: npm loads that file, and ship
# reads and prints it; a dry run's npm is a stand-in by path)
bad=""; for f in "$FX"/env.npm.*; do for k in $(sed 's/=.*//' "$f"); do
  # npm_env's named set (a caller's proxy and CA settings pass by design; npm's colour and log level
  # are npm_env's own) and what sh adds
  case $k in HOME|PATH|TMPDIR|USER|LOGNAME|PWD|SHLVL|_|OLDPWD|HTTPS_PROXY|https_proxy|HTTP_PROXY|http_proxy|NO_PROXY|no_proxy|NODE_EXTRA_CA_CERTS|NPM_CONFIG_USERCONFIG) ;;
    npm_config_color|npm_config_dry_run|npm_config_heading|npm_config_json|npm_config_loglevel|npm_config_logs_max|npm_config_offline|npm_config_prefer_offline|npm_config_provenance|npm_config_tag|npm_config_update_notifier|npm_config_usage|npm_config_workspaces) ;;   # npm_env's pins (the e3 row)
    *) bad="$bad $k" ;; esac
done; done
[ -z "$bad" ] && pass "npm got only the named environment" || fail "extra environment:$(printf '%s\n' $bad | sort -u | tr '\n' ' ')"
grep -q '^HTTPS_PROXY=http://127.0.0.1:9$' "$FX/env.npm.0" && pass "control: the proxy reaches npm" || fail "control: no HTTPS_PROXY for npm"
grep -rl "$DECOY" "$FX"/env.npm.* "$FX/calls" "$FX/o" >/dev/null 2>&1 && fail "a decoy token reached npm or the output" || pass "no decoy token reached npm or the output"
h=$(sed -n 's/^HOME=//p' "$FX/env.npm.0"); case $h in /private/tmp/sr-dryhome.*) pass "the dry npm's HOME is a fresh temp dir" ;; *) fail "the dry npm's HOME is '$h'" ;; esac

# who may publish: npm's own answer, for all four names before any view or upload; the main
# package is asked last, so a refusal there proves no platform package went out first
nopub() { ! grep -q -e '^npm publish' -e '^npm view' "$FX/calls"; }
# REV 11b rule 12 (r15a F1): a whoami failure names the npm login only for a missing (ENEEDAUTH) or a dead
# (E401) credential; any other code: npm's words and "run publish-npm again", and no login line
bw_=""
for c_ in ENEEDAUTH E401 ETIMEDOUT E403; do
  mkout "$D" v0.1.0; echo $c_ > "$FX/whoamicode"; pub v0.1.0; r=$?; rm -f "$FX/whoamicode"
  case $c_ in ENEEDAUTH|E401) w_=1 ;; *) w_=0 ;; esac
  g_=$(grep -c '^  cd / && npm login ' "$FX/o")
  [ $r = 1 ] && nopub && [ "$g_" = "$w_" ] && grep -q "npm error code $c_" "$FX/o" && { [ $w_ = 1 ] || grep -q 'When npm answers, run publish-npm again' "$FX/o"; } || bw_="$bw_ [$c_: rc=$r, $g_ login lines]"
done
[ -z "$bw_" ] && pass "REV 11b rule 12: whoami ENEEDAUTH and E401 name the login; ETIMEDOUT and E403 name none (npm's words, run publish-npm again)" || fail "rule 12, whoami:$bw_"
mkout "$D" v0.1.0; : > "$FX/whoamifail"; pub v0.1.0; r=$?; rm -f "$FX/whoamifail"
[ $r = 1 ] && nopub && grep -q 'npm whoami failed' "$FX/o" && pass "not logged in to npm: refused before any view or upload" || fail "whoami fails: rc=$r $(order) $(tail -1 "$FX/o")"
# REV 11a rule 7 (r14a F3): publish-npm makes A1's check too: npm naming another userconfig than the
# file it loads (F) is refused before whoami, both files named. (Control: every run above, npm naming F)
mkout "$D" v0.1.0; : > "$FX/ucother"; pub v0.1.0; r=$?; rm -f "$FX/ucother"
[ $r = 1 ] && grep -q '^npm config get userconfig' "$FX/calls" && ! grep -q -e '^npm whoami' -e '^npm view' -e '^npm publish' "$FX/calls" \
  && grep -qF "npm names $FX/other.npmrc as its userconfig" "$FX/o" && grep -qF "but publish-npm reads and prints $FX/decoy-npmrc" "$FX/o" \
  && pass "REV 11a rule 7: npm names another userconfig than F: publish-npm refuses before whoami, both files named" \
  || fail "publish-npm, another userconfig: rc=$r, $(grep -c '^npm whoami' "$FX/calls") whoami; $(grep -m1 'userconfig' "$FX/o" | cut -c1-200)"
# npm's E401, a counted login line in npm's userconfig, at each npm call of publish-npm that can answer
# it (whoami, a view before an upload, the wait's last view after one): npm's words, then npm_tokens
# (REV 10: the count picks no words, and no delete is named). Control: no counted line, the same
echo "//registry.npmjs.org/:_authToken=npm_old" > "$FX/dryrc"
mkout "$D" v0.1.0; echo E401 > "$FX/whoamicode"; pub v0.1.0; r=$?; rm -f "$FX/whoamicode"
[ $r = 1 ] && nopub && grep -q 'npm whoami failed' "$FX/o" && grep -q "Deleting or editing a login line ends no token" "$FX/o" && ! grep -q 'config delete' "$FX/o" && pass "whoami answering E401, a counted token line: refused before any upload; npm's words, then npm_tokens, no delete" || fail "whoami E401: rc=$r $(tail -1 "$FX/o" | cut -c1-240)"
mkout "$D" v0.1.0; echo E401 > "$FX/viewcode.sheepr-linux-arm64"; pub v0.1.0; r=$?; rm -f "$FX/viewcode.sheepr-linux-arm64"
[ $r = 1 ] && ! grep -q '^npm publish' "$FX/calls" && grep -q 'cannot tell whether sheepr-linux-arm64@0.1.0 is on npm' "$FX/o" && grep -q "Deleting or editing a login line ends no token" "$FX/o" && ! grep -q 'config delete' "$FX/o" && pass "a view before an upload answering E401, a counted token line: refused there; npm_tokens, no delete" || fail "view E401: rc=$r $(tail -1 "$FX/o" | cut -c1-240)"
mkout "$D" v0.1.0; echo E401 > "$FX/viewcodeafter.sheepr-linux-arm64"; pub v0.1.0; r=$?; rm -f "$FX/viewcodeafter.sheepr-linux-arm64"
[ $r = 1 ] && grep -q 'sheepr-linux-arm64@0.1.0 is not visible on npm after' "$FX/o" && grep -q 'the last view: E401' "$FX/o" && grep -q "Deleting or editing a login line ends no token" "$FX/o" && ! grep -q 'config delete' "$FX/o" \
  && pass "the views after an upload answering E401 to the wait's limit, a counted token line: npm_tokens, no delete" || fail "wait E401: rc=$r $(tail -1 "$FX/o" | cut -c1-240)"
rm -f "$FX/dryrc"
mkout "$D" v0.1.0; echo E401 > "$FX/whoamicode"; pub v0.1.0; r=$?; rm -f "$FX/whoamicode"
[ $r = 1 ] && nopub && grep -q 'npm whoami failed' "$FX/o" && ! grep -q 'config delete' "$FX/o" && grep -q "Deleting or editing a login line ends no token" "$FX/o" && pass "control: whoami E401 with no counted line: the same npm_tokens, no delete" || fail "control whoami E401: rc=$r $(tail -1 "$FX/o" | cut -c1-240)"
mkout "$D" v0.1.0; echo other > "$FX/whoami"; pub v0.1.0; r=$?; echo lukasco > "$FX/whoami"
[ $r = 1 ] && nopub && ! grep -q '^npm owner' "$FX/calls" && grep -q 'logged in to npm as other' "$FX/o" && pass "logged in to npm as another user than release.conf's: refused before any owner, view or upload call" || fail "other user: rc=$r $(order) $(tail -1 "$FX/o")"
mkout "$D" v0.1.0; printf 'lukasco\nnpm notice x\n' > "$FX/whoami"; pub v0.1.0; r=$?; echo lukasco > "$FX/whoami"
[ $r = 1 ] && nopub && grep -q 'logged in to npm as' "$FX/o" && ! grep -q 'belongs to' "$FX/o" && pass "a whoami of more than one line: refused, for that reason" || fail "two-line whoami: rc=$r $(order) $(tail -1 "$FX/o")"
mkout "$D" v0.1.0; : > "$FX/ownerfail.sheepr"; pub v0.1.0; r=$?; rm -f "$FX/ownerfail.sheepr"
[ $r = 1 ] && nopub && grep -q 'sheepr is not on npm yet' "$FX/o" && pass "a name not on npm yet (the main one, asked last): refused before any upload" || fail "not on npm: rc=$r $(order) $(tail -1 "$FX/o")"
mkout "$D" v0.1.0; echo stranger > "$FX/owner.sheepr-linux-x64"; pub v0.1.0; r=$?; rm -f "$FX/owner.sheepr-linux-x64"
[ $r = 1 ] && nopub && grep -q 'sheepr-linux-x64 on npm belongs to stranger, not to lukasco' "$FX/o" && pass "a name owned by someone else: refused before any upload, the owner named" || fail "other owner: rc=$r $(order) $(tail -1 "$FX/o")"
mkout "$D" v0.1.0; echo lukascox > "$FX/owner.sheepr-darwin-universal"; pub v0.1.0; r=$?; rm -f "$FX/owner.sheepr-darwin-universal"
[ $r = 1 ] && nopub && pass "an owner whose name only starts with the user's: refused" || fail "prefix owner: rc=$r $(order)"
mkout "$D" v0.1.0; : > "$FX/ownerbad.sheepr-linux-arm64"; pub v0.1.0; r=$?; rm -f "$FX/ownerbad.sheepr-linux-arm64"
[ $r = 1 ] && nopub && grep -q 'cannot read the owners of sheepr-linux-arm64' "$FX/o" && pass "owners that cannot be read (not E404): refused before any upload" || fail "owner error: rc=$r $(order) $(tail -1 "$FX/o")"
mkout "$D" v0.1.0; printf 'stranger\nlukasco\n' > "$FX/owner.sheepr-linux-arm64"; pub v0.1.0; r=$?; rm -f "$FX/owner.sheepr-linux-arm64"
[ $r = 0 ] && [ "$(grep -c '^npm publish' "$FX/calls")" = 4 ] && pass "control: the user is one of several owners: published" || fail "co-owner: rc=$r $(order) $(tail -1 "$FX/o")"
# the list publishing reads again (the stamp does not bind it): the main package last, and all
# four names; a changed list is refused before any call at all
for bad in "sheepr sheepr-linux-arm64 sheepr-linux-x64 sheepr-darwin-universal" "sheepr-linux-arm64 sheepr-linux-x64 sheepr"; do
  sed -i.bak "s/^SR_NPM_PKGS=.*/SR_NPM_PKGS='$bad'/" "$REPO/scripts/release.conf" && rm -f "$REPO/scripts/release.conf.bak"
  mkout "$D" v0.1.0; pub v0.1.0; r=$?; g checkout -q scripts/release.conf
  [ $r = 1 ] && [ ! -s "$FX/calls" ] && grep -q 'SR_NPM_PKGS' "$FX/o" && pass "a list of '$bad': refused before any call" || fail "list '$bad': rc=$r calls=$(head -1 "$FX/calls" 2>/dev/null) $(tail -1 "$FX/o")"
done
# the list is read once: one changed after its check (here by the whoami call) is not the one used;
# the uploads keep the checked order, the platform packages first
mkout "$D" v0.1.0; printf 'sed -i.bak "s/^SR_NPM_PKGS=.*/SR_NPM_PKGS=\x27sheepr sheepr-linux-arm64 sheepr-linux-x64 sheepr-darwin-universal\x27/" "%s" && rm -f "%s.bak"\n' "$REPO/scripts/release.conf" "$REPO/scripts/release.conf" > "$FX/onwhoami"
pub v0.1.0; r=$?; rm -f "$FX/onwhoami"; changed=$(grep -c '^SR_NPM_PKGS=.sheepr sheepr-linux' "$REPO/scripts/release.conf"); g checkout -q scripts/release.conf
[ "$changed" = 1 ] || fail "the whoami hook did not change the list (the row would prove nothing)"
[ $r = 0 ] && [ "$(order)" = "view sheepr-linux-arm64,publish sheepr-linux-arm64,view sheepr-linux-arm64,view sheepr-linux-x64,publish sheepr-linux-x64,view sheepr-linux-x64,view sheepr-darwin-universal,publish sheepr-darwin-universal,view sheepr-darwin-universal,view sheepr,publish sheepr,view sheepr," ] \
  && [ "$(sed -n 1,6p "$FX/calls" | tr '\n' ',')" = "npm config get userconfig --scope=,npm whoami $REG,npm owner ls sheepr-linux-arm64 $REG,npm owner ls sheepr-linux-x64 $REG,npm owner ls sheepr-darwin-universal $REG,npm owner ls sheepr $REG," ] \
  && pass "a list changed after its check: the checked list is the one the owner check and the uploads use" || fail "list changed mid-run: rc=$r $(order) | $(sed -n 1,6p "$FX/calls" | tr '\n' ',')"
# after each upload, publishing waits until npm shows that file (npm may process a new package for
# minutes before it shows: measured 2026-10-04), so the main package goes up only when the platform
# packages its optional dependencies name are there
mkout "$D" v0.1.0; echo 2 > "$FX/processing.sheepr-linux-x64"; pub v0.1.0; r=$?; rm -f "$FX/processing.sheepr-linux-x64"
[ $r = 0 ] && [ "$(order)" = "view sheepr-linux-arm64,publish sheepr-linux-arm64,view sheepr-linux-arm64,view sheepr-linux-x64,publish sheepr-linux-x64,view sheepr-linux-x64,view sheepr-linux-x64,view sheepr-linux-x64,view sheepr-darwin-universal,publish sheepr-darwin-universal,view sheepr-darwin-universal,view sheepr,publish sheepr,view sheepr," ] \
  && pass "a package npm is still processing: waited for (three views), then the next" || fail "processing: rc=$r $(order)"
mkout "$D" v0.1.0; echo 100000 > "$FX/processing.sheepr-darwin-universal"; pub v0.1.0; r=$?; rm -f "$FX/processing.sheepr-darwin-universal"
[ $r = 1 ] && ! grep -q '^npm publish .*/sheepr-0.1.0.tgz$' "$FX/calls" && grep -q 'not visible on npm' "$FX/o" \
  && pass "a package that never shows: refused, the main package not published" || fail "never visible: rc=$r $(order) $(tail -1 "$FX/o")"
mkout "$D" v0.1.0; : > "$FX/pubwrong.sheepr-linux-arm64"; pub v0.1.0; r=$?; rm -f "$FX/pubwrong.sheepr-linux-arm64"
[ $r = 1 ] && [ "$(order)" = "view sheepr-linux-arm64,publish sheepr-linux-arm64,view sheepr-linux-arm64," ] && grep -q 'than the one just published' "$FX/o" \
  && pass "npm showing another file than the one just published: refused there" || fail "wrong file shown: rc=$r $(order) $(tail -1 "$FX/o")"
# the wait's limit, one definition for both entries: NPM_WAIT_MAX seconds, a view every NPM_WAIT_STEP
# (npm documents its scan of each upload as about five minutes, up to 15 or more); at the limit the
# run has made MAX/STEP + 1 views of that package and slept MAX seconds, and says what npm may have done
wm=$(sed -n 's/^NPM_WAIT_MAX=\([0-9]*\).*/\1/p' "$REPO/scripts/release.sh"); ws=$(sed -n 's/^NPM_WAIT_MAX=[0-9]* NPM_WAIT_STEP=\([0-9]*\).*/\1/p' "$REPO/scripts/release.sh")
if [ -n "$wm" ] && [ -n "$ws" ] && [ "$ws" -gt 0 ] && [ "$wm" -ge 1800 ]; then pass "the wait's limit is $wm s, a view every $ws s (at least 30 minutes)"
else fail "the wait's limit: max '$wm' step '$ws'"; wm=1800 ws=10; fi   # the rows below still run, against the planned limit
mkout "$D" v0.1.0; echo 100000 > "$FX/processing.sheepr-darwin-universal"; pub v0.1.0; r=$?; rm -f "$FX/processing.sheepr-darwin-universal"
nv=$(grep -c '^npm view .* sheepr-darwin-universal@0.1.0 ' "$FX/calls"); sl=$(awk '{s += $1} END {print s + 0}' "$FX/sleeps" 2>/dev/null)
[ $r = 1 ] && [ "$nv" = $((wm / ws + 2)) ] && [ "$sl" = "$wm" ] && grep -q 'held the version for review or blocked it' "$FX/o" && grep -q 'E404' "$FX/o" && ! grep -q '^npm publish .*/sheepr-0.1.0.tgz$' "$FX/calls" \
  && pass "a package that never shows: $((wm / ws + 1)) views after its upload, $sl s of waits, refused naming review, blocking and the last error" || fail "the limit: rc=$r views=$nv (want $((wm / ws + 2)), with the one before the upload) sleeps=$sl (want $wm) $(tail -1 "$FX/o")"
mkout "$D" v0.1.0; echo $((wm / ws)) > "$FX/processing.sheepr-darwin-universal"; pub v0.1.0; r=$?; rm -f "$FX/processing.sheepr-darwin-universal"
[ $r = 0 ] && pass "a package that shows at the last view: published" || fail "the last view: rc=$r $(tail -1 "$FX/o")"
# a refused upload stops at once, whatever npm's text: what npm answers to a second upload while it
# still scans the first is not measured, so the run does not guess. Its message covers the cases: an
# earlier run's upload still scanned, held for review or blocked; a rerun skips a version already there
mkout "$D" v0.1.0; : > "$FX/pubexists.sheepr-linux-x64"; pub v0.1.0; r=$?; rm -f "$FX/pubexists.sheepr-linux-x64"
[ $r = 1 ] && [ "$(order)" = "view sheepr-linux-arm64,publish sheepr-linux-arm64,view sheepr-linux-arm64,view sheepr-linux-x64,publish sheepr-linux-x64," ] \
  && grep -q 'may still be scanning it' "$FX/o" && grep -q 'skips a version already there with this file' "$FX/o" && grep -q 'blocked version needs a new version number' "$FX/o" && grep -q 'or its login step failed' "$FX/o" \
  && pass "a refused upload (an earlier run's version): stopped at once, no view after it, the cases named" || fail "rerun exists: rc=$r $(order) $(tail -1 "$FX/o")"
mkout "$D" v0.1.0; : > "$FX/pubfail.sheepr-linux-x64"; pub v0.1.0; r=$?; rm -f "$FX/pubfail.sheepr-linux-x64"
[ $r = 1 ] && [ "$(order)" = "view sheepr-linux-arm64,publish sheepr-linux-arm64,view sheepr-linux-arm64,view sheepr-linux-x64,publish sheepr-linux-x64," ] && grep -q 'E401' "$FX/o" && grep -q 'or its login step failed' "$FX/o" && grep -q 'A browser login or 2FA approval that failed or timed out' "$FX/o" \
  && pass "a publish refused for another reason (E401): stopped at once, the reason shown" || fail "publish E401: rc=$r $(order) $(tail -1 "$FX/o")"
grep -q 'of the batch' "$FX/o" && fail "today's order's refusal speaks of a batch: $(tail -1 "$FX/o")" || pass "  (today's order: its refusal names no batch)"
# views after an upload that fail, or answer nothing, are waited through; the last error is named
mkout "$D" v0.1.0; : > "$FX/viewfailafter.sheepr-linux-arm64"; pub v0.1.0; r=$?; rm -f "$FX/viewfailafter.sheepr-linux-arm64"
nva=$(grep -c '^npm view .* sheepr-linux-arm64@0.1.0 ' "$FX/calls"); sl=$(awk '{s += $1} END {print s + 0}' "$FX/sleeps" 2>/dev/null)
[ $r = 1 ] && [ "$nva" = $((wm / ws + 2)) ] && [ "$sl" = "$wm" ] && grep -q 'not visible on npm after' "$FX/o" && grep -q 'ETIMEDOUT' "$FX/o" \
  && pass "views that keep failing after an upload: waited through to the limit, then refused naming ETIMEDOUT" || fail "view errors: rc=$r views=$nva sleeps=$sl $(tail -1 "$FX/o")"
mkout "$D" v0.1.0; echo 2 > "$FX/emptyafter.sheepr-linux-arm64"; pub v0.1.0; r=$?; rm -f "$FX/emptyafter.sheepr-linux-arm64"
[ $r = 0 ] && [ "$(grep -c '^npm view .* sheepr-linux-arm64@0.1.0 ' "$FX/calls")" = 4 ] && pass "two empty answers after an upload: two more views, then on" || fail "empty answers: rc=$r views=$(grep -c '^npm view .* sheepr-linux-arm64@0.1.0 ' "$FX/calls")"
# every package is checked before the first npm call: one changed before the run means none is published
mkout "$D" v0.1.0; echo x >> "$D/sheepr-0.1.0.tgz"; pub v0.1.0; r=$?
[ $r = 1 ] && [ ! -e "$FX/calls" ] && pass "a package changed after npm-check, before the run: refused, npm never called" || fail "changed before the run: rc=$r $(order)"
# a view that answers nothing (exit 0, no integrity) cannot say the version is absent
mkout "$D" v0.1.0; : > "$FX/viewempty.sheepr-linux-arm64"; pub v0.1.0; r=$?; rm -f "$FX/viewempty.sheepr-linux-arm64"
[ $r = 1 ] && ! grep -q '^npm publish' "$FX/calls" && grep -q 'cannot tell' "$FX/o" && pass "a view with no answer: refused, nothing published" || fail "empty view: rc=$r $(order)"
# a refused run leaves its private copy dir behind neither
mkout "$D" v0.1.0; : > "$FX/viewfail.sheepr-darwin-universal"; pub v0.1.0; rm -f "$FX/viewfail.sheepr-darwin-universal"
pd=$(awk 'NR == 1 {print $3}' "$FX/pubsha"); pd=${pd%/*}
case $pd in /private/tmp/sr-npmpub.*) [ ! -e "$pd" ] && pass "a refused run's private copy dir is gone" || fail "$pd is left after a refusal" ;; *) fail "no private copy dir recorded after the refusal: '$pd'" ;; esac

# the real run's npm environment (the npm class; __npm-env prints it): the operator's npmrc
# location passes, upper or lower case, and so does a proxy; no token ever does
ne() { (cd "$REPO" && env -i PATH="$PATH" HOME="$FX/ghome" NPM_TOKEN="$DECOY" NODE_AUTH_TOKEN="$DECOY" npm_config__authToken="$DECOY" GH_TOKEN="$DECOY" \
  SSH_AUTH_SOCK="$FX/sock" HTTPS_PROXY=http://127.0.0.1:9 "$@" sh scripts/release.sh __npm-env v0.1.0) 2>&1; }
e1=$(ne NPM_CONFIG_USERCONFIG="$FX/u1/npmrc"); e2=$(ne npm_config_userconfig="$FX/u2/npmrc")
printf '%s\n' "$e1" | grep -qx "NPM_CONFIG_USERCONFIG=$FX/u1/npmrc" && printf '%s\n' "$e2" | grep -qx "NPM_CONFIG_USERCONFIG=$FX/u2/npmrc" \
  && printf '%s\n' "$e1" | grep -qx 'HTTPS_PROXY=http://127.0.0.1:9' && printf '%s\n' "$e1" | grep -qx "HOME=$FX/ghome" \
  && pass "the real npm class: the operator's npmrc (either spelling), HOME and a proxy pass" || fail "the npm class: $(printf '%s' "$e1" | tr '\n' ' ')"
printf '%s\n%s\n' "$e1" "$e2" | grep -q -e "$DECOY" -e '^SSH_AUTH_SOCK=' -e '^GH_' && fail "the npm class let a token or a transport through" || pass "the real npm class: no token, no git/gh transport"
# npm's userconfig variable, either spelling, must be an absolute path: npm expands ~ and ${VAR} in
# it itself, and ship runs npm from /, so any other spelling names another file than the one the
# operator means. The npm class refuses it (npm never runs), naming the variable and its value; it
# never makes it <cwd>/~/npmrc. (An absolute one goes through unchanged: the rows above.)
for uv in 'NPM_CONFIG_USERCONFIG=~/npmrc' 'NPM_CONFIG_USERCONFIG=${HOME}/npmrc' 'npm_config_userconfig=rel/npmrc'; do
  eu=$(ne "$uv"); r=$?
  [ $r != 0 ] && printf '%s\n' "$eu" | grep -qF "${uv%%=*} is '${uv#*=}', not an absolute path" && ! printf '%s\n' "$eu" | grep -q -e '^HOME=' -e '^NPM_CONFIG_USERCONFIG=' \
    && pass "the npm class refuses $uv: not an absolute path; npm never ran" || fail "$uv: rc=$r $(printf '%s\n' "$eu" | grep -e USERCONFIG -e '^release:' | head -2 | tr '\n' ' ')"
done
# REV 11a rule 8 (r14a F1): an absolute one holding a $ (npm expands ${VAR} in it from the environment
# it runs in) is refused too, the variable named: the npm class, and publish-npm before any npm call
for uv in "NPM_CONFIG_USERCONFIG=$FX/v/\${SRFOO}rc" "npm_config_userconfig=$FX/\$SRFOO/npmrc"; do
  eu=$(ne "$uv"); r=$?
  [ $r != 0 ] && printf '%s\n' "$eu" | grep -qF "${uv%%=*} is '${uv#*=}': it holds a \$" && ! printf '%s\n' "$eu" | grep -q -e '^HOME=' -e '^NPM_CONFIG_USERCONFIG=' \
    && pass "REV 11a rule 8: the npm class refuses ${uv%%=*} holding a \$; npm never ran" || fail "\$ in ${uv%%=*}: rc=$r $(printf '%s\n' "$eu" | grep -e USERCONFIG -e '^release:' | head -2 | tr '\n' ' ')"
done
mkout "$D" v0.1.0; PUBX="NPM_CONFIG_USERCONFIG=$FX/v/\${SRFOO}rc"; pub v0.1.0; r=$?; PUBX=
[ $r = 1 ] && [ ! -e "$FX/calls" ] && grep -qF "NPM_CONFIG_USERCONFIG is '$FX/v/\${SRFOO}rc': it holds a \$" "$FX/o" \
  && pass "  publish-npm with NPM_CONFIG_USERCONFIG holding a \$: refused before any npm call" || fail "  publish-npm, \$: rc=$r $(tail -1 "$FX/o" | cut -c1-200)"
# publish-npm refuses it too, before any npm call
mkout "$D" v0.1.0; PUBX='NPM_CONFIG_USERCONFIG=~/npmrc'; pub v0.1.0; r=$?; PUBX=
[ $r = 1 ] && [ ! -e "$FX/calls" ] && grep -qF "NPM_CONFIG_USERCONFIG is '~/npmrc', not an absolute path" "$FX/o" \
  && pass "publish-npm with NPM_CONFIG_USERCONFIG='~/npmrc': refused before any npm call" || fail "publish-npm, ~/npmrc: rc=$r $(tail -1 "$FX/o" | cut -c1-200)"
# a relative NODE_EXTRA_CA_CERTS is made absolute from the current directory; when that cannot be read
# (here: it was removed), the npm class refuses (npm never runs), and never makes it /rel/ca.pem.
# Control: the same from a directory that is there
mkdir "$FX/gone" "$FX/here" || exit 3
eg=$(cd "$FX/gone" && rmdir "$FX/gone" && env -i PATH="$PATH" HOME="$FX/ghome" NPM_CONFIG_USERCONFIG="$FX/u1/npmrc" NODE_EXTRA_CA_CERTS=rel/ca.pem sh "$REPO/scripts/release.sh" __npm-env v0.1.0 2>&1); r=$?
[ $r != 0 ] && printf '%s\n' "$eg" | grep -qF "NODE_EXTRA_CA_CERTS is 'rel/ca.pem'" && ! printf '%s\n' "$eg" | grep -q -e '^HOME=' -e '^NODE_EXTRA_CA_CERTS=' \
  && pass "a relative NODE_EXTRA_CA_CERTS in a removed directory: refused, npm never ran" || fail "removed cwd: rc=$r $(printf '%s\n' "$eg" | grep -e NODE_EXTRA -e '^release:' | head -2 | tr '\n' ' ')"
eh=$(cd "$FX/here" && env -i PATH="$PATH" HOME="$FX/ghome" NPM_CONFIG_USERCONFIG="$FX/u1/npmrc" NODE_EXTRA_CA_CERTS=rel/ca.pem sh "$REPO/scripts/release.sh" __npm-env v0.1.0 2>&1); r=$?
[ $r = 0 ] && printf '%s\n' "$eh" | grep -qx "NODE_EXTRA_CA_CERTS=$(cd "$FX/here" && pwd -P)/rel/ca.pem" \
  && pass "control: a relative NODE_EXTRA_CA_CERTS in a directory that is there: made absolute from it" || fail "control, relative CA: rc=$r $(printf '%s\n' "$eh" | grep -e NODE_EXTRA -e '^release:' | head -2 | tr '\n' ' ')"
# tool, the one door to every tool class, refuses a class it does not know, an empty one too (an
# entry that set none): it names the class, runs nothing and answers non-zero, so the step's own
# failure path stops (__tool-class runs tool with SR_TOOL_CLASS's class). Control: a known class runs
tc() { (cd "$REPO" && env -i PATH="$PATH" HOME="$FX/ghome" "$@" sh scripts/release.sh __tool-class v0.1.0) 2>&1; }
for cl in '' bogus; do
  to=$(tc SR_TOOL_CLASS="$cl"); r=$?
  [ $r != 0 ] && printf '%s\n' "$to" | grep -qF "no tool class '$cl'" && ! printf '%s\n' "$to" | grep -qx ran \
    && pass "tool with the class '$cl': refused, named, nothing run (exit $r)" || fail "tool class '$cl': rc=$r $(printf '%s' "$to" | head -2 | tr '\n' ' ')"
done
to=$(tc SR_TOOL_CLASS=base); r=$?
[ $r = 0 ] && printf '%s\n' "$to" | grep -qx ran && pass "control: tool with a known class (base) runs it" || fail "control, tool base: rc=$r $(printf '%s' "$to" | head -2 | tr '\n' ' ')"
# every npm setting that changes what ship reads from npm (an answer, an exit status, npm's error
# code, what reaches the registry) is pinned to npm's default, whatever the operator's npmrc says (an
# environment setting wins over the userconfig): the list is the census of npm's own config
# definitions (heading=xyz hides `npm error code X`; json=true quotes whoami's name; usage=true and
# dry-run=true exit 0 with nothing published; tag=xyz publishes under another dist-tag and makes a
# view without a version E404; prefer-offline, or an npmrc's cache-min=9999, answers a view from the
# cache, over --prefer-online: the pinned prefer-offline undoes both). The caller's own values, either
# case, never reach npm
e3=$(ne NPM_CONFIG_USERCONFIG="$FX/u1/npmrc" npm_config_color=always npm_config_loglevel=silent npm_config_heading=xyz npm_config_json=true \
  npm_config_usage=true npm_config_dry_run=true npm_config_tag=xyz npm_config_offline=true npm_config_prefer_offline=true npm_config_cache_min=99999 \
  npm_config_workspaces=true npm_config_provenance=true npm_config_update_notifier=true NPM_CONFIG_HEADING=xyz NPM_CONFIG_JSON=true \
  npm_config_logs_max=10 NPM_CONFIG_LOGS_MAX=10)
PINS='npm_config_color=false
npm_config_dry_run=false
npm_config_heading=npm
npm_config_json=false
npm_config_loglevel=notice
npm_config_logs_max=0
npm_config_offline=false
npm_config_prefer_offline=false
npm_config_provenance=false
npm_config_tag=latest
npm_config_update_notifier=false
npm_config_usage=false
npm_config_workspaces=false'
[ "$(printf '%s\n' "$e3" | grep -i '^npm_config_' | grep -v '^NPM_CONFIG_USERCONFIG=' | LC_ALL=C sort)" = "$PINS" ] \
  && pass "the real npm class: every npm output setting pinned ($(printf '%s\n' "$PINS" | grep -c .): heading=npm, json=false, ...), the caller's own dropped" \
  || fail "the npm class's npm settings: $(printf '%s\n' "$e3" | grep -i '^npm_config_' | grep -v '^NPM_CONFIG_USERCONFIG=' | LC_ALL=C sort | tr '\n' ' ')"
# REV 11a rule 10 (r14a np/t5: npm 10.9.2 writes ship's session token into its debug log after a failed
# logout): npm_config_logs_max=0, whatever the caller's, either case (notes/builder/np14/t14m5-*: npm 9.6.7,
# 10.5.2, 10.9.2 and 11.6.0 write no file under _logs with it)
[ "$(printf '%s\n' "$e3" | grep -ic '^npm_config_logs_max=')" = 1 ] && printf '%s\n' "$e3" | grep -qx 'npm_config_logs_max=0' \
  && pass "REV 11a rule 10: npm's debug log off (npm_config_logs_max=0), the caller's own (10, either case) dropped" || fail "rule 10: $(printf '%s\n' "$e3" | grep -i 'logs_max' | tr '\n' ' ')"

# nothing at all without the stamp, with a stamp for another manifest, or with a control manifest
rm "$D/NPM-CHECKED"; pub v0.1.0; r=$?
[ $r = 1 ] && [ ! -e "$FX/calls" ] && grep -q npm-check "$FX/o" && pass "no npm-check stamp: refused, npm never called" || fail "no stamp: rc=$r $(order)"
mkout "$D" v0.1.0; echo ' ' >> "$D/MANIFEST.json"; pub v0.1.0; r=$?
[ $r = 1 ] && [ ! -e "$FX/calls" ] && pass "a stamp for another manifest: refused, npm never called" || fail "stale stamp: rc=$r $(order)"
mkout "$D" v0.1.0 true; pub v0.1.0; r=$?
[ $r = 1 ] && [ ! -e "$FX/calls" ] && grep -q control "$FX/o" && pass "a control manifest (stamped): refused, npm never called" || fail "control: rc=$r $(order)"
mkout "$D" v0.1.0 false 0000000000000000000000000000000000000000; pub v0.1.0; r=$?
[ $r = 1 ] && [ ! -e "$FX/calls" ] && grep -q commit "$FX/o" && pass "a manifest for another commit than the tag's (stamped): refused, npm never called" || fail "other commit: rc=$r $(order)"
# the bytes published are the bytes hashed: a source changed after its check (by the view) is not
# what npm gets
mkout "$D" v0.1.0; echo "echo x >> '$D/sheepr-darwin-universal-0.1.0.tgz'" > "$FX/onview.sheepr-darwin-universal"
h0=$(sed -n 's/.*"sheepr-darwin-universal-0.1.0.tgz", "sha256": "\([0-9a-f]*\)".*/\1/p' "$D/MANIFEST.json")
pub v0.1.0; r=$?; rm -f "$FX/onview.sheepr-darwin-universal"
[ $r = 0 ] && [ "$(awk '$1 == "sheepr-darwin-universal" {print $2}' "$FX/pubsha")" = "$h0" ] \
  && pass "a source changed between its check and its upload: npm got the checked bytes" || fail "changed after the check: rc=$r $(cat "$FX/pubsha" 2>/dev/null | tr '\n' ' ')"
# the hashes publish-npm checks against are the stamped manifest's, copied before the first call:
# a later package and its manifest entry replaced together (at the first view) do not match it
mkout "$D" v0.1.0
cat > "$FX/onview.sheepr-linux-arm64" <<EOF
f='$D/sheepr-linux-x64-0.1.0.tgz'; echo swapped >> "\$f"; h=\$(shasum -a 256 "\$f" | cut -d' ' -f1)
sed -i.bak "s/\\"sheepr-linux-x64-0.1.0.tgz\\", \\"sha256\\": \\"[0-9a-f]*\\"/\\"sheepr-linux-x64-0.1.0.tgz\\", \\"sha256\\": \\"\$h\\"/" '$D/MANIFEST.json' && rm -f '$D/MANIFEST.json.bak'
EOF
pub v0.1.0; r=$?; rm -f "$FX/onview.sheepr-linux-arm64"
case "$(order)" in *"publish sheepr-linux-x64"*) swapped=published ;; *) swapped=kept ;; esac
[ $r = 1 ] && [ $swapped = kept ] && grep -q 'manifest hash' "$FX/o" && grep -q "x64-0.1.0.tgz" "$D/MANIFEST.json" \
  && pass "a package and its manifest entry replaced together during the run: refused at it, not published (1)" || fail "swapped package: rc=$r $(order) $(tail -1 "$FX/o")"
# a view that fails for another reason than E404 cannot say the version is absent: refused there
mkout "$D" v0.1.0; : > "$FX/viewfail.sheepr-darwin-universal"; pub v0.1.0; r=$?; rm -f "$FX/viewfail.sheepr-darwin-universal"
[ $r = 1 ] && [ "$(order)" = "view sheepr-linux-arm64,publish sheepr-linux-arm64,view sheepr-linux-arm64,view sheepr-linux-x64,publish sheepr-linux-x64,view sheepr-linux-x64,view sheepr-darwin-universal," ] && grep -q 'cannot tell' "$FX/o" \
  && pass "a view that fails (not E404): refused there, nothing after it published" || fail "view failure: rc=$r $(order) $(tail -1 "$FX/o")"

# a package changed during the run (by the first upload, as anything else could): refused at it
mkout "$D" v0.1.0; echo "echo x >> '$D/sheepr-darwin-universal-0.1.0.tgz'" > "$FX/onpublish.sheepr-linux-arm64"
pub v0.1.0; r=$?; rm -f "$FX/onpublish.sheepr-linux-arm64"
[ $r = 1 ] && [ "$(order)" = "view sheepr-linux-arm64,publish sheepr-linux-arm64,view sheepr-linux-arm64,view sheepr-linux-x64,publish sheepr-linux-x64,view sheepr-linux-x64," ] \
  && grep -q 'sheepr-darwin-universal-0.1.0.tgz does not match its manifest hash' "$FX/o" \
  && pass "a package changed during the run: refused just before its upload, nothing after it published" || fail "changed mid-run: rc=$r $(order) $(tail -1 "$FX/o")"

# a resumed run: the same file already there is skipped; another file there stops the run
mkout "$D" v0.1.0; integrity "$D/sheepr-linux-arm64-0.1.0.tgz" > "$FX/view.sheepr-linux-arm64"
pub v0.1.0; r=$?
[ $r = 0 ] && ! grep -q '^npm publish .*linux-arm64' "$FX/calls" && [ "$(grep -c '^npm publish' "$FX/calls")" = 3 ] && grep -q 'already on npm (the same file)' "$FX/o" \
  && pass "a version already on npm with this file: skipped, the rest published" || fail "resume same: rc=$r $(order)"
case "$(befores)" in "sheepr-linux-x64<npm view"*">,sheepr-darwin-universal<notify npm-approve-next v0.1.0>,sheepr<notify npm-approve-again v0.1.0>,") \
  pass "  its first upload (x64) has no notification, the next two do" ;; *) fail "  the notifications: $(befores)" ;; esac
mkout "$D" v0.1.0; for p_ in sheepr-linux-arm64 sheepr-linux-x64 sheepr-darwin-universal; do integrity "$D/$p_-0.1.0.tgz" > "$FX/view.$p_"; done
pub v0.1.0; r=$?; rm -f "$FX/view.sheepr-linux-x64" "$FX/view.sheepr-darwin-universal"   # (arm64's view stays, as the next row expects)
[ $r = 0 ] && [ "$(grep -c '^npm publish' "$FX/calls")" = 1 ] && ! grep -q '^notify ' "$FX/calls" \
  && pass "the three platform packages already on npm: the main upload is the first, no notification (0)" || fail "main first: rc=$r $(befores)"
echo "sha512-AAAA" > "$FX/view.sheepr-linux-x64"
pub v0.1.0; r=$?; rm -f "$FX"/view.*
[ $r = 1 ] && [ "$(order)" = "view sheepr-linux-arm64,view sheepr-linux-x64," ] && grep -q 'another file' "$FX/o" \
  && pass "a version already on npm with another file: refused there, nothing after it published" || fail "resume other: rc=$r $(order) $(tail -1 "$FX/o")"

# an rc: every publish carries --tag next
fx_release 0.1.1 2 v0.1.1-rc.1
mkout "$FX/out/v0.1.1-rc.1" v0.1.1-rc.1
pub v0.1.1-rc.1; r=$?
[ $r = 0 ] && [ "$(grep -c "^npm publish --access public $REG --tag next " "$FX/calls")" = 4 ] && pass "an rc: each publish has --tag next" || fail "rc: rc=$r $(grep '^npm publish' "$FX/calls" | head -1)"

# npm_part is never inherited: an exported npm_part=platform is today's order
mkout "$D" v0.1.0; PUBX=npm_part=platform; pub v0.1.0; r=$?; PUBX=
[ $r = 0 ] && [ "$(order)" = "$TODAY" ] && pass "an exported npm_part=platform: today's order, unchanged (0)" || fail "exported npm_part: rc=$r $(order)"
# the notifier: none, or the real notify.sh (the fixture's), refused before any npm call
mkout "$D" v0.1.0; NOTI=-; pub v0.1.0; r=$?; NOTI=
[ $r = 1 ] && [ ! -e "$FX/calls" ] && grep -q 'release: no notifier' "$FX/o" && pass "no notifier (SR_PUBLISH_DRY_NOTIFY unset, NOTIFY empty): refused by publish_npm_exec, npm never called" || fail "no notifier: rc=$r $(order) $(tail -1 "$FX/o")"
mkout "$D" v0.1.0; NOTI=--empty; pub v0.1.0; r=$?; NOTI=
[ $r = 1 ] && [ ! -e "$FX/calls" ] && grep -q 'SR_PUBLISH_DRY_NOTIFY is not an executable file' "$FX/o" && pass "an empty SR_PUBLISH_DRY_NOTIFY: refused by the stand-in check, npm never called" || fail "empty notifier: rc=$r $(order) $(tail -1 "$FX/o")"
mkout "$D" v0.1.0; NOTI=$REPO/scripts/lib/notify.sh; pub v0.1.0; r=$?; NOTI=
[ $r = 1 ] && [ ! -e "$FX/calls" ] && grep -q 'the real notify.sh' "$FX/o" && pass "the real notify.sh as the dry notifier: refused, npm never called" || fail "real notify.sh: rc=$r $(order) $(tail -1 "$FX/o")"
mkout "$D" v0.1.0; PART=bogus; pub v0.1.0; r=$?; PART=
[ $r = 1 ] && [ ! -e "$FX/calls" ] && grep -q "npm_part 'bogus'" "$FX/o" && pass "a part that is not platform, main or empty: refused, npm never called" || fail "bogus part: rc=$r $(order) $(tail -1 "$FX/o")"
# platform: the three platform packages back to back, each once (asked for, then uploaded), no wait
# (each would need two more views if waited for), the main package untouched; npm-approve right
# before the first upload
for p in sheepr-linux-arm64 sheepr-linux-x64 sheepr-darwin-universal; do echo 2 > "$FX/processing.$p"; done
mkout "$D" v0.1.0; PART=platform; pub v0.1.0; r=$?; PART=; rm -f "$FX"/processing.*
[ $r = 0 ] && [ "$(order)" = "view sheepr-linux-arm64,publish sheepr-linux-arm64,view sheepr-linux-x64,publish sheepr-linux-x64,view sheepr-darwin-universal,publish sheepr-darwin-universal," ] \
  && pass "platform: the three platform packages back to back, the main one untouched (0)" || fail "platform: rc=$r $(order) $(tail -1 "$FX/o")"
[ ! -e "$FX/sleeps" ] && pass "platform: no wait (no sleep, no view after an upload)" || fail "platform waited: $(cat "$FX/sleeps" | tr '\n' ' ')"
nl=$(grep -n '^notify ' "$FX/calls" | cut -d: -f1); np=$(grep -n '^npm publish' "$FX/calls" | head -1 | cut -d: -f1)
[ "$(grep -c '^notify ' "$FX/calls")" = 1 ] && grep -qx 'notify npm-approve v0.1.0' "$FX/calls" && [ -n "$np" ] && [ "$nl" = $((np - 1)) ] \
  && pass "platform: notify npm-approve once, right before the first upload" || fail "platform's notification: $(grep -n -e '^notify' -e '^npm publish' "$FX/calls" | tr '\n' ' ')"
grep -q 'four npm packages' "$FX/o" && fail "platform says the four packages are on npm" || pass "platform: no 'four packages' line"
mkout "$D" v0.1.0; : > "$FX/pubfail.sheepr-linux-x64"; PART=platform; pub v0.1.0; r=$?; PART=; rm -f "$FX/pubfail.sheepr-linux-x64"
[ $r = 1 ] && [ "$(order)" = "view sheepr-linux-arm64,publish sheepr-linux-arm64,view sheepr-linux-x64,publish sheepr-linux-x64," ] \
  && pass "platform: a refused second upload stops it, nothing after it (1)" || fail "platform, refused upload: rc=$r $(order)"
grep -q 'may also refuse an upload while it still scans an earlier package of the batch' "$FX/o" && pass "  and its message names npm's possible refusal while it scans an earlier package of the batch" || fail "  the refusal: $(tail -1 "$FX/o")"
mkout "$D" v0.1.0; integrity "$D/sheepr-linux-arm64-0.1.0.tgz" > "$FX/view.sheepr-linux-arm64"; PART=platform; pub v0.1.0; r=$?; PART=
nl=$(grep -n '^notify ' "$FX/calls" | cut -d: -f1); np=$(grep -n '^npm publish' "$FX/calls" | head -1 | cut -d: -f1)
[ $r = 0 ] && [ "$(order)" = "view sheepr-linux-arm64,view sheepr-linux-x64,publish sheepr-linux-x64,view sheepr-darwin-universal,publish sheepr-darwin-universal," ] && [ -n "$np" ] && [ "$nl" = $((np - 1)) ] \
  && pass "platform, one already on npm (this file): skipped; the notification before the first real upload (0)" || fail "platform, one there: rc=$r $(order) notify at $nl, first publish at $np"
for p in sheepr-linux-x64 sheepr-darwin-universal; do integrity "$D/$p-0.1.0.tgz" > "$FX/view.$p"; done
PART=platform; pub v0.1.0; r=$?; PART=; rm -f "$FX"/view.*
[ $r = 0 ] && ! grep -q -e '^npm publish' -e '^notify ' "$FX/calls" && pass "platform, all three already on npm: no upload, no notification (0)" || fail "platform, all there: rc=$r $(grep -e '^npm publish' -e '^notify' "$FX/calls" | tr '\n' ' ')"
# main: waits until npm shows each platform package (uploaded earlier; never uploaded here), then
# uploads the main package, npm-approve-again right before, and waits for it
mkout "$D" v0.1.0; for p in sheepr-linux-arm64 sheepr-linux-x64 sheepr-darwin-universal; do integrity "$D/$p-0.1.0.tgz" > "$FX/view.$p"; done
PART=main; pub v0.1.0; r=$?; PART=
nl=$(grep -n '^notify ' "$FX/calls" | cut -d: -f1); np=$(grep -n '^npm publish' "$FX/calls" | head -1 | cut -d: -f1)
[ $r = 0 ] && [ "$(order)" = "view sheepr-linux-arm64,view sheepr-linux-x64,view sheepr-darwin-universal,view sheepr,publish sheepr,view sheepr," ] \
  && pass "main: the platform packages seen, no upload of one, then the main one uploaded and waited for (0)" || fail "main: rc=$r $(order) $(tail -1 "$FX/o")"
[ "$(grep -c '^notify ' "$FX/calls")" = 1 ] && grep -qx 'notify npm-approve-again v0.1.0' "$FX/calls" && [ -n "$np" ] && [ "$nl" = $((np - 1)) ] \
  && pass "main: notify npm-approve-again once, right before the main upload" || fail "main's notification: $(grep -n -e '^notify' -e '^npm publish' "$FX/calls" | tr '\n' ' ')"
echo 2 > "$FX/scan.sheepr-linux-x64"; PART=main; pub v0.1.0; r=$?; PART=; rm -f "$FX/scan.sheepr-linux-x64"
[ $r = 0 ] && [ "$(grep -c '^npm view .* sheepr-linux-x64@0.1.0 ' "$FX/calls")" = 3 ] && [ "$(grep -c . "$FX/sleeps" 2>/dev/null)" = 2 ] && ! grep -q '^npm publish .*/sheepr-linux' "$FX/calls" \
  && pass "main: a platform package npm still scans is waited for (three views, two waits), never uploaded (0)" || fail "main, scanning: rc=$r $(order) sleeps=$(cat "$FX/sleeps" 2>/dev/null | tr '\n' ' ')"
echo "sha512-WRONG" > "$FX/view.sheepr-linux-x64"; PART=main; pub v0.1.0; r=$?; PART=; integrity "$D/sheepr-linux-x64-0.1.0.tgz" > "$FX/view.sheepr-linux-x64"
[ $r = 1 ] && ! grep -q '^npm publish' "$FX/calls" && grep -q "sheepr-linux-x64@0.1.0 is on npm with another file (sha512-WRONG) than this build's (uploaded earlier, by the batch)" "$FX/o" && ! grep -q 'just published' "$FX/o" \
  && pass "main: a platform package shown with another file: refused, naming it as this build's earlier upload, nothing uploaded (1)" || fail "main, another file: rc=$r $(tail -1 "$FX/o")"
echo 100000 > "$FX/scan.sheepr-darwin-universal"; PART=main; pub v0.1.0; r=$?; PART=; rm -f "$FX/scan.sheepr-darwin-universal"
[ $r = 1 ] && ! grep -q '^npm publish' "$FX/calls" && grep -q 'held the version for review or blocked it' "$FX/o" \
  && pass "main: a platform package that never shows: refused naming review and blocking, nothing uploaded (1)" || fail "main, never shows: rc=$r $(order) $(tail -1 "$FX/o")"
integrity "$D/sheepr-0.1.0.tgz" > "$FX/view.sheepr"; PART=main; pub v0.1.0; r=$?; PART=; rm -f "$FX"/view.*
[ $r = 0 ] && ! grep -q -e '^npm publish' -e '^notify ' "$FX/calls" && grep -q 'already on npm (the same file)' "$FX/o" \
  && pass "main: the main package already on npm (this file): skipped, no notification (0)" || fail "main, main there: rc=$r $(order)"
# the real entry, which no dry run reaches: its body exactly, defined once, and its dispatch arm
# (NPMC too: the class npmhint's token count reads npm's userconfig with; unset, it read none)
want='publish_npm() { NPM=npm NETC=npm NPMC=npm NOTIFY=$root/scripts/lib/notify.sh; publish_npm_exec "$out/$tag"; }'
[ "$(grep -c '^publish_npm() ' "$SR_ROOT/scripts/release.sh")" = 1 ] && grep -qxF "$want" "$SR_ROOT/scripts/release.sh" \
  && pass "publish_npm: exactly its pinned body (the real notify.sh), defined once" || fail "publish_npm's body: $(grep '^publish_npm() ' "$SR_ROOT/scripts/release.sh")"
grep -qxF '  publish-npm) publish_npm ;;' "$SR_ROOT/scripts/release.sh" && pass "the dispatch: '  publish-npm) publish_npm ;;'" || fail "the publish-npm dispatch arm"
nb=$(sed -n '/^notify() {/,/^}/p' "$SR_ROOT/scripts/release.sh")
# (its arguments: the key and the tag; a stop's key also the out dir, so its text names the next file,
# or - when ship_exit could not write that file: the text then names none; e87ee70)
printf '%s\n' "$nb" | grep -qF 'then tool dry /usr/bin/env SR_NOTIFY_OSASCRIPT= "$NOTIFY" "$@"' && printf '%s\n' "$nb" | grep -qF 'else tool base "$NOTIFY" "$@"; fi' \
  && printf '%s\n' "$nb" | grep -qF 'case $1 in failed-*|logout-failed*) if [ "${wrote:-no}" = yes ]; then set -- "$1" "$tag" "$out"; else set -- "$1" "$tag" -; fi ;; *) set -- "$1" "$tag" ;; esac' \
  && pass "notify(): a dry entry's notifier with SR_NOTIFY_OSASCRIPT set, a real entry's in the base class; a stop's key gets the out dir, or - when the next file was not written" || fail "notify()'s body: $(printf '%s' "$nb" | tr '\n' ' ')"

# __publish-npm-dry refuses a stand-in outside the fixtures, for the npm and for the notifier, each
# with the other one valid and a full release to publish: the refusal names it, the outside one is
# never called (inside the wall, as every run here)
OUT=$(mktemp -d /private/tmp/sr-outside.XXXXXX); trap 'rm -rf "$OUT" "$FX"' EXIT
printf '#!/bin/sh\necho "OUTSIDE $*" >> "%s/called"\nexit 0\n' "$OUT" > "$OUT/npm"; chmod +x "$OUT/npm"
printf '#!/bin/sh\necho "OUTSIDE notify $*" >> "%s/called"\nexit 0\n' "$OUT" > "$OUT/notify"; chmod +x "$OUT/notify"
ln -s "$OUT/npm" "$FX/npm-link"; ln -s "$OUT/notify" "$FX/notify-link"
mkout "$D" v0.1.0
for spec in "outside:$OUT/npm" "symlink:$FX/npm-link"; do
  l=${spec%%:*} p=${spec#*:}; rm -f "$OUT/called"
  PUBX=SR_PUBLISH_DRY_NPM=$p; pub v0.1.0; r=$?; PUBX=
  [ $r = 1 ] && [ ! -e "$OUT/called" ] && grep -q -e 'SR_PUBLISH_DRY_NPM must' -e 'SR_PUBLISH_DRY_NPM is not' "$FX/o" \
    && pass "__publish-npm-dry, a $l npm: refused for the npm stand-in, the outside npm never called" || fail "__publish-npm-dry, $l npm: rc=$r called=$(head -1 "$OUT/called" 2>/dev/null) $(tail -1 "$FX/o")"
done
for spec in "outside:$OUT/notify" "symlink:$FX/notify-link"; do
  l=${spec%%:*} p=${spec#*:}; rm -f "$OUT/called"
  NOTI=$p; pub v0.1.0; r=$?; NOTI=
  [ $r = 1 ] && [ ! -e "$OUT/called" ] && [ ! -e "$FX/calls" ] && grep -q -e 'SR_PUBLISH_DRY_NOTIFY must' -e 'SR_PUBLISH_DRY_NOTIFY is not' "$FX/o" \
    && pass "__publish-npm-dry, a $l notifier: refused for the notifier stand-in before any npm call, the outside notifier never called" || fail "__publish-npm-dry, $l notifier: rc=$r called=$(head -1 "$OUT/called" 2>/dev/null) $(tail -1 "$FX/o")"
done
# the entry's variables are plain assignments: none reached a child through the environment (the
# sleep stand-in runs during a wait, outside the npm class)
mkout "$D" v0.1.0; rm -f "$FX/exported"; echo 2 > "$FX/processing.sheepr-linux-x64"; pub v0.1.0; r=$?; rm -f "$FX/processing.sheepr-linux-x64"
[ $r = 0 ] && [ -s "$FX/sleeps" ] && [ ! -e "$FX/exported" ] && pass "none of release.sh's own variables is exported (a waited run's sleep sees none)" || fail "exported to a child: rc=$r sleeps=$(grep -c . "$FX/sleeps" 2>/dev/null) exported: $(sort -u "$FX/exported" 2>/dev/null | tr '\n' ' ')"
# and when the caller exports every one of them, release.sh unsets each before it sets it, so none
# stays exported (an assignment alone keeps a variable from the environment exported)
mkout "$D" v0.1.0; rm -f "$FX/exported"; echo 2 > "$FX/processing.sheepr-linux-x64"
( export shipping=yes npm_part=platform NOTIFY=/nonexistent SHIP_BUILD=/x SHIP_NPMCHECK=/x SHIP_VERIFY=x CAFFEINATE=/x SHIP_IDENTITY=/x SHIP_DOCKER=/x \
    GH=/x GITCMD=/x NPM=/x NPMC=x CURL=/x CURLC=x NETC=x DRY=x dryentry=no shipprog=/x shipcause=/x shipcls=/x ship_mh=x; pub v0.1.0 ); r=$?
rm -f "$FX/processing.sheepr-linux-x64"
[ $r = 0 ] && [ -s "$FX/sleeps" ] && [ ! -e "$FX/exported" ] && [ "$(grep -c '^npm publish' "$FX/calls")" = 4 ] \
  && pass "the caller exports all of release.sh's own variables: none reaches a child, and today's order runs (four uploads, 0)" || fail "caller's exports: rc=$r exported: $(sort -u "$FX/exported" 2>/dev/null | tr '\n' ' ') $(order)"
# this cell's own dry HOMEs (each run prints the one it made; other sessions may run these cells at
# the same time, so the whole /private/tmp is not counted): at least ten seen, none left
nh=$(grep -c . "$FX/homes" 2>/dev/null); nh=${nh:-0}; left=""
while IFS= read -r h; do [ -e "$h" ] && left="$left $h"; done < "$FX/homes" 2>/dev/null
[ "$nh" -ge 10 ] && [ -z "$left" ] && pass "none of this cell's $nh dry HOMEs is left, after the refused runs too" || fail "this cell's dry HOMEs: $nh seen; left:$left"
finish
