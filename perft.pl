#!/usr/bin/env perl
use v5.10;
use strict;
use warnings;

use FindBin qw($RealBin);
use File::Spec;

my $target = File::Spec->catfile($RealBin, 'tests', 'perft.pl');
exec $^X, $target, @ARGV
  or die "Failed to exec $target: $!\n";
