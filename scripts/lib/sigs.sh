# The terminating signals every cleanup trap of the release catches: one list. release.sh, sign.sh,
# archive.sh and npm-pack.sh read it here; install.sh gets the list written into its trap lines
# when it is rendered (it may be piped to zsh, which does not split $SIGS into words);
# exec-guard.sh (copied as one file), smoke.sh and s7-clean-user.sh (which the S7 test user runs
# alone) carry this line verbatim (tests/dist/t_sigs.sh holds every one to this file). Every file
# that names $SIGS but install.sh runs under /bin/sh only: `sh FILE`, or its #!/bin/sh line
# (smoke.sh as ~/s7-smoke.sh; s7-clean-user.sh as `sh /Users/Shared/sr-s7/s7-clean-user.sh`).
# Measured (bash 3.2 as sh, 2026-10-17; tests/dist/t_sigs.sh measures it on each run): the
# defaults of QUIT and PROF end the shell without running its EXIT trap at all; the defaults of
# HUP, TERM, ALRM, USR1, USR2, XCPU, XFSZ and VTALRM run it at once, without waiting for the running
# tool; INT's default, sent to the shell alone, lets it go on. Trapped, each waits for the
# foreground tool. PIPE is not here: ship's parent adds it.
SIGS="HUP INT TERM QUIT ALRM USR1 USR2 XCPU XFSZ VTALRM PROF"
