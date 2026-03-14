#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use Config;
use lib "$RealBin/..";
use Chess::State;
use Chess::TableUtil qw(canonical_fen_key);

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

sub assert_black_reorder {
  my (%args) = @_;
  my $state = replay_moves(@{ $args{moves} // [] });
  my @candidates = @{ $args{candidates} // [] };
  my %visits;
  my $candidate_visits = $args{candidate_visits} // {};
  foreach my $uci (@candidates) {
    my $encoded = eval { $state->encode_move($uci) };
    die "Could not encode candidate $uci: $@\n" if !$encoded || $@;
    my $next = eval { $state->make_move($encoded) };
    die "Failed to make candidate $uci: $@\n" unless defined $next;
    $visits{canonical_fen_key($next)} = $candidate_visits->{$uci} // 0;
  }

  my $game = {
    id          => $args{name} // 'black-side',
    initial_fen => 'startpos',
    moves       => [ @{ $args{moves} // [] } ],
  };

  my @ordered;
  {
    no warnings 'redefine';
    local *_position_visit_counts_from_game = sub { return \%visits; };
    @ordered = _reorder_candidates_for_repetition($game, $state, \@candidates, {
      cp => ($args{cp} // 80),
    });
  }

  die "Black repetition regression failed for $game->{id}: got none\n" unless @ordered;
  die "Black repetition regression failed for $game->{id}: expected $args{expected}, got $ordered[0]\n"
    unless $ordered[0] eq $args{expected};
}

assert_black_reorder(
  name => 'black capture preferred when ahead',
  moves => [ qw(e2e4 d7d5 e4d5) ],
  candidates => [ qw(g8f6 d8d5) ],
  candidate_visits => {
    g8f6 => 1,
    d8d5 => 0,
  },
  expected => 'd8d5',
);

assert_black_reorder(
  name => 'black quiet pawn push penalized under guard',
  moves => [ qw(e2e4 a7a6 g1f3) ],
  candidates => [ qw(g7g5 g8f6) ],
  cp => -80,
  candidate_visits => {
    g7g5 => 1,
    g8f6 => 1,
  },
  expected => 'g8f6',
);

print "Black-side repetition guard regression OK: preserved capture and pawn-push scoring for black\n";
exit 0;
