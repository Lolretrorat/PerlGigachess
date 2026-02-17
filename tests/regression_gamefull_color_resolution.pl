#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use Config;
use lib "$RealBin/..";

my $root = "$RealBin/..";
my $local_perl = "$root/.perl5/lib/perl5";
if (-d $local_perl) {
  unshift @INC, $local_perl;
  my $arch_perl = "$local_perl/" . $Config::Config{archname};
  unshift @INC, $arch_perl if -d $arch_perl;
}

my $loaded = do "$root/lichess.pl";
die "Failed to load lichess.pl: $@ $!\n" unless defined $loaded;

my @cases = (
  {
    name => 'prefers seed when payload ids missing',
    seed => 'white',
    bot_id => 'perl-gigachess-dev',
    event => {
      white => { name => 'Perl-GigaChess-Dev' },
      black => { name => 'maia5' },
    },
    expected => 'white',
  },
  {
    name => 'matches white id case-insensitively',
    seed => 'black',
    bot_id => 'perl-gigachess-dev',
    event => {
      white => { id => 'Perl-GigaChess-Dev' },
      black => { id => 'maia5' },
    },
    expected => 'white',
  },
  {
    name => 'matches nested black user id',
    seed => 'white',
    bot_id => 'perl-gigachess-dev',
    event => {
      white => { id => 'maia5' },
      black => { user => { id => 'perl-gigachess-dev' } },
    },
    expected => 'black',
  },
  {
    name => 'keeps seed when bot id cannot be mapped',
    seed => 'white',
    bot_id => 'perl-gigachess-dev',
    event => {
      white => { id => 'maia5' },
      black => { id => 'other-bot' },
    },
    expected => 'white',
  },
);

for my $case (@cases) {
  my $actual = _resolve_my_color_from_gamefull(
    $case->{event},
    $case->{seed},
    $case->{bot_id},
  );
  my $expected = $case->{expected};
  if (!defined $actual || $actual ne $expected) {
    my $got = defined $actual ? $actual : 'undef';
    die "Color resolution regression failed for $case->{name}: got $got expected $expected\n";
  }
}

print "gameFull color resolution regression OK: seed color is preserved and ids resolve robustly\n";
exit 0;
