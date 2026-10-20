#!/usr/bin/perl
# envrep.pl TEXT: TEXT as npm's config loader rewrites a path value before it resolves it (@npmcli/config's
# env-replace.js): ${NAME} becomes the environment's NAME, and stays as written when NAME is not set;
# ${NAME?} becomes the value or nothing; an odd run of backslashes before ${ escapes it and loses half of
# them. Measured with real npm 9.6.7, 10.9.2 and 11.6.0 on --userconfig (round 18 review: notes/r18a/np/
# t1-v*.txt part E; the ? form in 11.6.0 only). The npm stand-ins of t_ship_dry and t_publish_npm_dry
# read their userconfig through it (PLAN-ship.md REV 12c rule 32). Two differences from npm, named (round 19
# review: notes/r19a/np/e1.out): npm 9, 10 and 11 also count the names of JavaScript's Object.prototype
# members as set (${toString}, ${constructor}, ${hasOwnProperty}, ${__proto__} become JS text), which this
# keeps as written; and ${NAME?} is read as npm 11.6.0 reads it (9.6.7 and 10.9.2 keep it as written). No
# row depends on either: ship and publish-npm refuse every $ in the out dir's path
use strict; use warnings;
my $s = $ARGV[0];
$s =~ s/(?<!\\)(\\*)\$\{([^\${}?]+)(\?)?\}/
  my ($esc, $name, $mod) = ($1, $2, $3);
  my $orig = $esc . '${' . $name . (defined $mod ? '?' : '') . '}';
  if (length($esc) % 2) { substr($orig, (length($esc) + 1) \/ 2) }
  else { my $fb = defined $mod ? '' : '${' . $name . '}'; substr($esc, length($esc) \/ 2) . (exists $ENV{$name} ? $ENV{$name} : $fb) }
/ge;
print $s;
