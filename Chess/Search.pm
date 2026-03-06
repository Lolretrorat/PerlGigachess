package Chess::Search;
use strict;
use warnings;

use Exporter qw(import);
use Chess::Heuristics qw(:engine);

use List::Util qw(min);

our @EXPORT_OK = qw(
  reset_root_search_stats
  finalize_root_search_stats
  root_search_stats
  maybe_randomize_tied_root_move
  has_sac_candidate_with_score_drop
  collect_root_pv_lines
);

my %root_search_stats;

sub reset_root_search_stats {
  %root_search_stats = (
    legal_moves => 0,
    best_value => undef,
    second_value => undef,
    best_move_key => undef,
    root_candidates => [],
  );
}

sub root_search_stats {
  return \%root_search_stats;
}

sub finalize_root_search_stats {
  my ($legal_moves) = @_;
  my @ranked = sort { $b->{score} <=> $a->{score} } @{$root_search_stats{root_candidates} || []};
  $root_search_stats{root_candidates} = \@ranked;
  $root_search_stats{legal_moves} = defined $legal_moves ? $legal_moves : scalar(@ranked);
  $root_search_stats{best_value} = @ranked ? $ranked[0]{score} : undef;
  $root_search_stats{second_value} = @ranked > 1 ? $ranked[1]{score} : undef;
  $root_search_stats{best_move_key} = @ranked ? $ranked[0]{move_key} : undef;
}

sub _resolve_root_candidate_move {
  my ($state, $candidate, $find_move_by_key_cb) = @_;
  return undef unless ref($candidate) eq 'HASH';
  my $move = $candidate->{move};
  if (!defined $move && defined $candidate->{move_key} && ref($find_move_by_key_cb) eq 'CODE') {
    $move = $find_move_by_key_cb->($state, $candidate->{move_key});
  }
  return $move;
}

sub maybe_randomize_tied_root_move {
  my ($state, $best_move, $opts, $find_move_by_key_cb) = @_;
  return $best_move unless $opts && $opts->{randomize_ties};

  my $delta_cp = defined $opts->{tie_random_cp}
    ? int($opts->{tie_random_cp})
    : ROOT_NEAR_TIE_DELTA;
  $delta_cp = 0 if $delta_cp < 0;

  my $ranked = $root_search_stats{root_candidates};
  return $best_move unless ref($ranked) eq 'ARRAY' && @{$ranked} >= 2;
  my $best_score = $ranked->[0]{score};
  return $best_move unless defined $best_score;

  my @near_tied;
  for my $candidate (@{$ranked}) {
    next unless defined $candidate->{score};
    last if ($best_score - $candidate->{score}) > $delta_cp;
    my $move = _resolve_root_candidate_move($state, $candidate, $find_move_by_key_cb);
    next unless defined $move;
    push @near_tied, $move;
  }
  return $best_move unless @near_tied >= 2;
  return $near_tied[int(rand(@near_tied))];
}

sub has_sac_candidate_with_score_drop {
  my ($state, $drop_cp, $is_sac_candidate_cb) = @_;
  return 0 unless ref($state);
  return 0 unless ref($is_sac_candidate_cb) eq 'CODE';

  my $candidates = $root_search_stats{root_candidates};
  return 0 unless ref($candidates) eq 'ARRAY' && @{$candidates};
  my $best_value = $root_search_stats{best_value};
  $drop_cp = SAC_SCORE_DROP_CP unless defined $drop_cp;
  $drop_cp = int($drop_cp);
  $drop_cp = 0 if $drop_cp < 0;

  foreach my $candidate (@{$candidates}) {
    next unless ref($candidate) eq 'HASH';
    my $move = $candidate->{move};
    next unless $is_sac_candidate_cb->($state, $move);
    return 1 unless defined $best_value && defined $candidate->{score};
    my $drop = int($best_value) - int($candidate->{score});
    return 1 if $drop >= $drop_cp;
  }

  return 0;
}

sub _extract_pv_from_move {
  my ($state, $first_move, $max_depth, $opts) = @_;
  return () unless defined $first_move;

  $max_depth = int($max_depth // 1);
  $max_depth = 1 if $max_depth < 1;

  my $tt = $opts->{transposition_table};
  my $state_key_cb = $opts->{state_key_cb};
  my $find_move_by_key_cb = $opts->{find_move_by_key_cb};

  my @pv = ($first_move);
  my $cursor_state = $state->make_move($first_move);
  return @pv unless defined $cursor_state;

  my %seen_keys;
  for my $ply (1 .. ($max_depth - 1)) {
    my $cursor_key = $state_key_cb->($cursor_state);
    last if $seen_keys{$cursor_key}++;
    my $entry = $tt->probe($cursor_key);
    last unless $entry && defined $entry->{best_move_key};
    my $next_move = $find_move_by_key_cb->($cursor_state, $entry->{best_move_key});
    last unless defined $next_move;
    push @pv, $next_move;
    my $next_state = $cursor_state->make_move($next_move);
    last unless defined $next_state;
    $cursor_state = $next_state;
  }

  return @pv;
}

sub collect_root_pv_lines {
  my ($state, $depth, $requested_multipv, $fallback_move, $fallback_score, $opts) = @_;
  my $limit = $opts->{normalize_multipv_cb}->($requested_multipv);
  my @candidates = @{$root_search_stats{root_candidates} || []};

  if (!@candidates && defined $fallback_move) {
    push @candidates, {
      move => $fallback_move,
      move_key => $opts->{move_key_cb}->($fallback_move),
      score => int($fallback_score // 0),
    };
  }

  my @pv_lines;
  my $count = min($limit, scalar @candidates);
  for my $idx (0 .. $count - 1) {
    my $candidate = $candidates[$idx];
    my $move = $candidate->{move};
    if (!defined $move && defined $candidate->{move_key}) {
      $move = $opts->{find_move_by_key_cb}->($state, $candidate->{move_key});
    }
    next unless defined $move;
    my @pv = _extract_pv_from_move($state, $move, $depth, $opts);
    next unless @pv;
    my $score = defined $candidate->{score}
      ? int($candidate->{score})
      : int($fallback_score // 0);
    push @pv_lines, {
      multipv => $idx + 1,
      score => $score,
      move => $move,
      pv => \@pv,
    };
  }

  if (!@pv_lines && defined $fallback_move) {
    my @pv = _extract_pv_from_move($state, $fallback_move, $depth, $opts);
    @pv = ($fallback_move) unless @pv;
    push @pv_lines, {
      multipv => 1,
      score => int($fallback_score // 0),
      move => $fallback_move,
      pv => \@pv,
    };
  }

  return \@pv_lines;
}

reset_root_search_stats();

1;
