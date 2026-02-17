#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use Config;
use lib "$RealBin/..";
use Chess::State;

my $root = "$RealBin/..";
my $local_perl = "$root/.perl5/lib/perl5";
if (-d $local_perl) {
  unshift @INC, $local_perl;
  my $arch_perl = "$local_perl/" . $Config::Config{archname};
  unshift @INC, $arch_perl if -d $arch_perl;
}
my $loaded = do "$root/lichess.pl";
die "Failed to load lichess.pl: $@ $!\n" unless defined $loaded;

sub replay_moves {
  my (@moves) = @_;
  my $state = Chess::State->new();
  foreach my $move (@moves) {
    my $encoded = eval { $state->encode_move($move) };
    die "Could not encode $move: $@\n" if !$encoded || $@;
    my $next = eval { $state->make_move($encoded) };
    die "Failed to make move $move: $@\n" unless defined $next;
    $state = $next;
  }
  return $state;
}

sub assert_guard_keeps_best {
  my (%args) = @_;
  my $name = $args{name} // 'case';
  my @moves = @{ $args{moves} // [] };
  my @candidates = @{ $args{candidates} // [] };
  my $analysis = $args{analysis} // {};
  my $expected = $args{expected} // '';

  my $state = replay_moves(@moves);
  my $game = {
    id          => $name,
    initial_fen => 'startpos',
    moves       => [@moves],
  };
  my @ordered = _reorder_candidates_for_repetition($game, $state, \@candidates, $analysis);
  die "Repetition guard regression failed for $name: got none, expected $expected\n"
    unless @ordered;
  die "Repetition guard regression failed for $name: guard reordered to $ordered[0] instead of $expected\n"
    unless $ordered[0] eq $expected;
}

# Position from DoDMEUME after 10...gxf6 where guard previously replaced d1h5 with quiet pawn moves.
assert_guard_keeps_best(
  name => 'DoDMEUME move-11 guard misfire',
  moves => [
    qw(
      e2e4 e7e5
      g1f3 b8c6
      d2d4 f8b4
      c2c3 g8f6
      f3e5 b4d6
      e5c6 d7c6
      e4e5 d8e7
      c1f4 c8f5
      f1e3 e8g8
      e5f6 g7f6
    )
  ],
  candidates => [qw(d1h5 a2a3 b2b3 f2f3)],
  analysis => { cp => 53 },
  expected => 'd1h5',
);

print "Repetition guard regression OK: guard preserved strongest candidate in DoDMEUME case\n";
exit 0;
