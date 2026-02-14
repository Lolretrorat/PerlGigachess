#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use File::Spec;

$ENV{LICHESS_DRY_RUN} = 1;

my $entry = File::Spec->catfile($RealBin, '..', 'lichess.pl');
exec $^X, $entry;

die "Failed to exec $entry: $!";
