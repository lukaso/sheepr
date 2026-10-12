# The terminating signals every cleanup trap of the release catches: one list. release.sh, sign.sh,
# archive.sh and npm-pack.sh read it here; install.sh gets this line written in when it is
# rendered; exec-guard.sh (copied as one file), smoke.sh and s7-clean-user.sh (which the S7 test
# user runs alone) carry it verbatim (tests/dist/t_sigs.sh holds every one to this file).
# Measured (bash 3.2 as sh, 2026-10-12): QUIT's default runs no EXIT trap at all; the others'
# defaults run it at once, without waiting for the running tool, with the last command's status;
# trapped, the trap waits for the foreground tool. PIPE is not here: ship's parent adds it.
SIGS="HUP INT TERM QUIT ALRM USR1 USR2 XCPU XFSZ VTALRM"
