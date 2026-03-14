package Chess::Eval;
use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(evaluate_position);

my @phase_weight = (0, 0, 1, 1, 2, 4, 0);
my $phase_max = 24;

sub evaluate_position {
  my ($state, $opts) = @_;
  $opts ||= {};

  my $board = $state->[0];
  my $indices = $opts->{board_indices} || [];
  my $piece_values = $opts->{piece_values} || {};
  my $square_of_idx_cb = $opts->{square_of_idx_cb};
  my $location_bonus_cb = $opts->{location_bonus_cb};
  my $strategic_cb = $opts->{strategic_cb};
  my $has_pst = defined $square_of_idx_cb && defined $location_bonus_cb;
  my $incremental = $opts->{incremental};
  if ((!defined $incremental || ref($incremental) ne 'HASH')
      && ref($state)
      && $state->can('incremental_eval_components')) {
    $incremental = $state->incremental_eval_components();
  }
  $incremental = {} unless ref($incremental) eq 'HASH';

  my $material = $incremental->{material};
  my $pst_mg = $incremental->{pst_mg};
  my $pst_eg = $incremental->{pst_eg};
  my $phase = $incremental->{phase};
  my $need_material = !defined $material;
  my $need_pst = !defined $pst_mg || !defined $pst_eg;
  my $need_phase = !defined $phase;
  $material = 0 if $need_material;
  $pst_mg = 0 if !defined $pst_mg;
  $pst_eg = 0 if !defined $pst_eg;
  $phase = 0 if $need_phase;

  my %ctx = (
    piece_count => 0,
    friendly_non_king => 0,
    enemy_non_king => 0,
    rook_count => 0,
    rook_home_count => 0,
    our_king_idx => undef,
    opp_king_idx => undef,
    queen_idx => undef,
    opponent_has_queen => 0,
  );

  for my $idx (@{$indices}) {
    my $piece = $board->[$idx] // 0;
    next unless $piece;

    my $abs_piece = abs($piece);
    if ($abs_piece >= 1 && $abs_piece <= 6) {
      $ctx{piece_count}++;
      $phase += ($phase_weight[$abs_piece] // 0) if $need_phase;
    }
    if ($abs_piece >= 1 && $abs_piece <= 5) {
      if ($piece > 0) {
        $ctx{friendly_non_king}++;
      } else {
        $ctx{enemy_non_king}++;
      }
    }

    if ($piece == 6) {
      $ctx{our_king_idx} = $idx;
    } elsif ($piece == -6) {
      $ctx{opp_king_idx} = $idx;
    } elsif ($piece == 5) {
      $ctx{queen_idx} = $idx;
    } elsif ($piece == -5) {
      $ctx{opponent_has_queen} = 1;
    } elsif ($piece == 4) {
      $ctx{rook_count}++;
      $ctx{rook_home_count}++ if $idx == 21 || $idx == 28;
    }

    my $base = $piece_values->{$piece} // 0;
    if ($need_material) {
      $material += $base if $base;
    }

    next unless $need_pst && $has_pst && $base;
    my $sq = $square_of_idx_cb->($idx);
    next unless defined $sq;
    my $pst = $location_bonus_cb->($piece, $sq, $base) // 0;
    $pst_mg += $pst;
    # Endgame still values square placement, but less than middlegame.
    $pst_eg += int(($pst * 0.50) + ($pst < 0 ? -0.5 : 0.5));
  }

  $phase = $phase_max if $phase > $phase_max;
  my $tapered_pst = int((($pst_mg * $phase) + ($pst_eg * ($phase_max - $phase))) / $phase_max);
  my $score = $material + $tapered_pst;

  if (defined $strategic_cb) {
    my %attack_cache;
    $score += ($strategic_cb->($board, \%ctx, \%attack_cache) // 0);
  }

  return $score;
}

1;
