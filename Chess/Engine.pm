package Chess::Engine;
use strict;
use warnings;

use Chess::Constant;
use Chess::State;
use Chess::LocationModifer qw(%location_modifiers);
use Chess::EndgameTable;

use Chess::Book;

use List::Util qw(max min);
use Time::HiRes qw(time);

use constant DEBUG => 1;
use constant LOCATION_WEIGHT => 0.15;
use constant QUIESCE_MAX_DEPTH => 4;
use constant INF_SCORE => 1_000_000;
use constant MATE_SCORE => 900_000;
use constant ASPIRATION_WINDOW => 24;

use constant TT_FLAG_EXACT => 0;
use constant TT_FLAG_LOWER => 1;
use constant TT_FLAG_UPPER => 2;
use constant SCORE_STABILITY_DELTA => 2;
use constant EXTRA_DEPTH_ON_UNSTABLE => 4;
use constant TIME_CHECK_INTERVAL_NODES => 2048;
use constant TIME_DEFAULT_HORIZON => 34;
use constant TIME_INC_WEIGHT => 0.75;
use constant TIME_RESERVE_MS => 800;
use constant TIME_MOVE_OVERHEAD_MS => 100;
use constant TIME_MIN_BUDGET_MS => 20;
use constant TIME_HARD_SCALE => 1.5;
use constant TIME_MAX_SHARE => 0.60;
use constant TIME_EMERGENCY_MS => 1500;
use constant QUIESCE_EMERGENCY_MAX_DEPTH => 2;
use constant TT_MAX_ENTRIES => 200_000;
use constant COUNTERMOVE_BONUS => 180;
use constant EASY_MOVE_MIN_DEPTH => 4;
use constant EASY_MOVE_DEPTH_CAP => 5;

my %history_scores;
my @killer_moves;
my %transposition_table;
my %counter_moves;
my $tt_generation = 0;

my $search_has_deadline = 0;
my $search_soft_deadline = 0;
my $search_hard_deadline = 0;
my $search_nodes = 0;
my $search_quiesce_limit = QUIESCE_MAX_DEPTH;
my $search_time_abort = "__TIMEUP__";

sub new {
  my $class = shift;

  my %self;
  $self{state} = shift || die "Cannot instantiate Chess::Engine without a Chess::State";
  $self{depth} = shift || 6; # bigger number more thinky

  # hi ken
  return bless \%self, $class;
}

my %piece_values = (
  KING, 5590,
  PAWN, 10,
  BISHOP, 30,
  KNIGHT, 30,
  ROOK, 50,
  QUEEN, 90,
  OPP_KING, -5590,
  OPP_PAWN, -10,
  OPP_BISHOP, -30,
  OPP_KNIGHT, -30,
  OPP_ROOK, -50,
  OPP_QUEEN, -90,
  EMPTY, 0,
  OOB, 0,
);

my %piece_alias = map { $_ => $_ } qw(
  KING QUEEN ROOK BISHOP KNIGHT PAWN
  OPP_KING OPP_QUEEN OPP_ROOK OPP_BISHOP OPP_KNIGHT OPP_PAWN
);

$piece_alias{KING()}       = 'KING';
$piece_alias{QUEEN()}      = 'QUEEN';
$piece_alias{ROOK()}       = 'ROOK';
$piece_alias{BISHOP()}     = 'BISHOP';
$piece_alias{KNIGHT()}     = 'KNIGHT';
$piece_alias{PAWN()}       = 'PAWN';
$piece_alias{OPP_KING()}   = 'OPP_KING';
$piece_alias{OPP_QUEEN()}  = 'OPP_QUEEN';
$piece_alias{OPP_ROOK()}   = 'OPP_ROOK';
$piece_alias{OPP_BISHOP()} = 'OPP_BISHOP';
$piece_alias{OPP_KNIGHT()} = 'OPP_KNIGHT';
$piece_alias{OPP_PAWN()}   = 'OPP_PAWN';

my @board_indices = _build_board_indices();
my %normalized_location_tables = _normalize_location_modifiers();

sub _build_board_indices {
  my @indices;
  for my $rank (1 .. 8) {
    my $base = ($rank + 1) * 10;
    push @indices, map { $base + $_ } (1 .. 8);
  }
  return @indices;
}

sub _normalize_location_modifiers {
  my %normalized;
  for my $raw_key (keys %location_modifiers) {
    my $table = $location_modifiers{$raw_key};
    next unless ref $table eq 'HASH' && keys %{$table};
    my $canonical = $piece_alias{$raw_key} or next;
    my $max_abs = max(map { abs($_ // 0) } values %{$table}) || 0;
    my %relative = map {
      my $value = $table->{$_} // 0;
      my $ratio = $max_abs ? _clamp($value / $max_abs, -1, 1) : 0;
      $_ => $ratio;
    } keys %{$table};
    $normalized{$canonical} = \%relative;
  }
  return %normalized;
}

sub _clamp {
  my ($value, $min, $max) = @_;
  $value = $min if $value < $min;
  $value = $max if $value > $max;
  return $value;
}

sub _idx_to_square {
  my ($idx, $turn) = @_;
  my $file_idx = ($idx % 10) - 1;
  return unless $file_idx >= 0 && $file_idx < 8;
  my $file = chr(ord('a') + $file_idx);
  my $rank = $turn ? 10 - int($idx / 10) : int($idx / 10) - 1;
  return unless $rank >= 1 && $rank <= 8;
  return $file . $rank;
}

sub _location_modifier_percent {
  my ($piece, $square) = @_;
  my $canonical = $piece_alias{$piece} or return 0;
  my $table = $normalized_location_tables{$canonical} or return 0;
  return $table->{$square} // 0;
}

sub _location_bonus {
  my ($piece, $square, $base_value) = @_;
  my $percent = _location_modifier_percent($piece, $square);
  return 0 unless $percent;
  return $base_value * LOCATION_WEIGHT * $percent;
}

sub _ordered_moves {
  my ($state, $ply, $tt_move_key, $prev_move_key) = @_;
  my @scored = map {
    [ _move_order_score($state, $_, $ply, $tt_move_key, $prev_move_key), $_ ]
  } @{$state->generate_pseudo_moves};
  @scored = sort { $b->[0] <=> $a->[0] } @scored;
  return map { $_->[1] } @scored;
}

sub _move_order_score {
  my ($state, $move, $ply, $tt_move_key, $prev_move_key) = @_;
  my $board = $state->[Chess::State::BOARD];
  my $from_piece = $board->[$move->[0]] || 0;
  my $to_piece = $board->[$move->[1]] || 0;
  my $score = 0;
  my $move_key = _move_key($move);

  if (defined $tt_move_key && $move_key eq $tt_move_key) {
    $score += 5000;
  }

  if ($to_piece < 0) {
    my $victim_value = abs($piece_values{$to_piece} || 0);
    my $attacker_value = abs($piece_values{$from_piece} || 0);
    $score += 1000 + 10 * $victim_value - $attacker_value;
  }

  if (defined $move->[2]) {
    my $promo = abs($piece_values{$move->[2]} || 0);
    my $pawn = abs($piece_values{PAWN} || 1);
    $score += 500 + ($promo - $pawn);
  }

  if (defined $move->[3]) {
    $score += 50;
  }

  my $from_square = _idx_to_square($move->[0], 0);
  my $to_square = _idx_to_square($move->[1], 0);
  if (defined $to_square) {
    my $from_bonus = defined $from_square ? _location_modifier_percent($from_piece, $from_square) : 0;
    my $to_bonus = _location_modifier_percent($from_piece, $to_square);
    $score += 30 * ($to_bonus - $from_bonus);
  }

  if (! _is_capture_state($state, $move)) {
    $score += _history_bonus($move);
    $score += _killer_bonus($move, $ply);
    $score += _countermove_bonus($move, $prev_move_key);
  }

  return $score;
}

sub _is_capture_state {
  my ($state, $move) = @_;
  my $board = $state->[Chess::State::BOARD];
  my $to_piece = $board->[$move->[1]] // 0;
  return 1 if $to_piece < 0;

  my $from_piece = $board->[$move->[0]] // 0;
  return 0 unless $from_piece == PAWN;

  my $ep = $state->[Chess::State::EP];
  return 0 unless defined $ep && $move->[1] == $ep;
  return 0 unless ($move->[1] - $move->[0] == 9 || $move->[1] - $move->[0] == 11);

  return $to_piece == EMPTY ? 1 : 0;
}

sub _move_key {
  my ($move) = @_;
  return join(':', $move->[0], $move->[1], (defined $move->[2] ? $move->[2] : 0));
}

sub _history_bonus {
  my ($move) = @_;
  return ($history_scores{_move_key($move)} // 0);
}

sub _killer_bonus {
  my ($move, $ply) = @_;
  my $slot = $killer_moves[$ply] || [];
  my $key = _move_key($move);
  return 200 if defined $slot->[0] && $slot->[0] eq $key;
  return 150 if defined $slot->[1] && $slot->[1] eq $key;
  return 0;
}

sub _countermove_bonus {
  my ($move, $prev_move_key) = @_;
  return 0 unless defined $prev_move_key;
  my $counter = $counter_moves{$prev_move_key};
  return 0 unless defined $counter;
  return _move_key($move) eq $counter ? COUNTERMOVE_BONUS : 0;
}

sub _store_killer {
  my ($ply, $move) = @_;
  $killer_moves[$ply] ||= [];
  my $key = _move_key($move);
  return if defined $killer_moves[$ply][0] && $killer_moves[$ply][0] eq $key;
  $killer_moves[$ply][1] = $killer_moves[$ply][0] if defined $killer_moves[$ply][0];
  $killer_moves[$ply][0] = $key;
}

sub _store_countermove {
  my ($prev_move_key, $move) = @_;
  return unless defined $prev_move_key;
  $counter_moves{$prev_move_key} = _move_key($move);
}

sub _update_history {
  my ($move, $depth) = @_;
  my $key = _move_key($move);
  $history_scores{$key} += $depth * $depth;
}

sub _decay_history {
  for my $key (keys %history_scores) {
    $history_scores{$key} = int($history_scores{$key} * 0.85);
    delete $history_scores{$key} if $history_scores{$key} <= 0;
  }
}

sub _trim_transposition_table {
  my $size = scalar keys %transposition_table;
  return if $size <= TT_MAX_ENTRIES;

  my $target = int(TT_MAX_ENTRIES * 0.8);
  for my $key (keys %transposition_table) {
    last if $size <= $target;
    my $entry = $transposition_table{$key};
    next unless ($entry->{gen} // 0) < $tt_generation - 2 || ($entry->{depth} // 0) <= 2;
    delete $transposition_table{$key};
    $size--;
  }

  if ($size > $target) {
    for my $key (keys %transposition_table) {
      last if $size <= $target;
      delete $transposition_table{$key};
      $size--;
    }
  }
}

sub _configure_time_limits {
  my ($state, $opts) = @_;
  $opts ||= {};

  $search_has_deadline = 0;
  $search_soft_deadline = 0;
  $search_hard_deadline = 0;
  $search_nodes = 0;
  $search_quiesce_limit = QUIESCE_MAX_DEPTH;

  my $start = time();
  my $move_overhead_ms = max(0, int($opts->{move_overhead_ms} // TIME_MOVE_OVERHEAD_MS));
  my $movetime_ms = $opts->{movetime_ms};
  my $budget_ms;
  my $hard_ms;
  my $has_clock = 0;

  if (defined $movetime_ms && $movetime_ms > 0) {
    my $mt = max(1, int($movetime_ms));
    $budget_ms = max(TIME_MIN_BUDGET_MS, $mt - $move_overhead_ms);
    $hard_ms = max($budget_ms, $mt);
    $has_clock = 1;
  } elsif (defined $opts->{remaining_ms} && $opts->{remaining_ms} > 0) {
    my $remaining_ms = max(1, int($opts->{remaining_ms}));
    my $inc_ms = max(0, int($opts->{increment_ms} // 0));
    my $movestogo = int($opts->{movestogo} // 0);
    $movestogo = 0 if $movestogo < 0;
    my $horizon = $movestogo ? min(40, max(8, $movestogo)) : TIME_DEFAULT_HORIZON;

    my $reserve_ms = $opts->{reserve_ms};
    if (!defined $reserve_ms) {
      $reserve_ms = max(TIME_RESERVE_MS, int($remaining_ms * 0.05));
    }
    $reserve_ms = max(0, int($reserve_ms));

    my $usable_ms = max(0, $remaining_ms - $reserve_ms - $move_overhead_ms);
    my $base_ms = $horizon ? int($usable_ms / $horizon) : $usable_ms;
    $budget_ms = int($base_ms + $inc_ms * TIME_INC_WEIGHT);

    my $max_budget_ms = int($usable_ms * TIME_MAX_SHARE) + $inc_ms;
    $max_budget_ms = max(TIME_MIN_BUDGET_MS, $max_budget_ms);
    $budget_ms = min($budget_ms, $max_budget_ms);
    $budget_ms = max(TIME_MIN_BUDGET_MS, $budget_ms);

    if ($remaining_ms <= TIME_EMERGENCY_MS) {
      my $emergency_cap = max(TIME_MIN_BUDGET_MS, int(($remaining_ms - $move_overhead_ms) * 0.35));
      $budget_ms = min($budget_ms, $emergency_cap);
      $search_quiesce_limit = QUIESCE_EMERGENCY_MAX_DEPTH;
    }

    if (defined $opts->{max_budget_ms}) {
      $budget_ms = min($budget_ms, max(TIME_MIN_BUDGET_MS, int($opts->{max_budget_ms})));
    }

    $hard_ms = min(
      int($budget_ms * TIME_HARD_SCALE),
      max($budget_ms, $remaining_ms - int($reserve_ms * 0.5) - $move_overhead_ms)
    );
    $hard_ms = max($budget_ms, $hard_ms);
    $has_clock = 1;
  }

  if ($has_clock) {
    $search_has_deadline = 1;
    $search_soft_deadline = $start + ($budget_ms / 1000.0);
    $search_hard_deadline = $start + ($hard_ms / 1000.0);
    return {
      has_clock => 1,
      budget_ms => $budget_ms,
      hard_ms => $hard_ms,
      move_overhead_ms => $move_overhead_ms,
    };
  }

  return {
    has_clock => 0,
    budget_ms => 0,
    hard_ms => 0,
    move_overhead_ms => $move_overhead_ms,
  };
}

sub _time_up_soft {
  return $search_has_deadline && time() >= $search_soft_deadline;
}

sub _extend_soft_deadline {
  my ($extra_ms) = @_;
  return unless $search_has_deadline;
  return unless defined $extra_ms && $extra_ms > 0;
  my $extended = $search_soft_deadline + ($extra_ms / 1000.0);
  my $hard_ceiling = $search_hard_deadline - 0.001;
  $extended = $hard_ceiling if $extended > $hard_ceiling;
  $search_soft_deadline = $extended if $extended > $search_soft_deadline;
}

sub _check_time_or_abort {
  return unless $search_has_deadline;
  $search_nodes++;
  return if $search_nodes % TIME_CHECK_INTERVAL_NODES;
  die $search_time_abort if time() >= $search_hard_deadline;
}

sub _state_key {
  my ($state) = @_;
  my $fen = $state->get_fen;
  $fen =~ s/\s+\d+\s+\d+\s*$//;
  return $fen;
}

sub _find_move_by_key {
  my ($state, $target_key) = @_;
  return unless defined $target_key;

  for my $move (@{$state->generate_pseudo_moves}) {
    next unless _move_key($move) eq $target_key;
    my $new_state = $state->make_move($move);
    return $move if defined $new_state;
  }

  return;
}

sub _quiesce {
  my ($state, $alpha, $beta, $depth) = @_;
  $depth //= 0;
  _check_time_or_abort();

  my $stand_pat = _evaluate_board($state);
  $alpha = max($alpha, $stand_pat);
  return $alpha if $alpha >= $beta || $depth >= $search_quiesce_limit;

  my @captures = grep { _is_capture_state($state, $_) } @{$state->generate_pseudo_moves};
  return $alpha unless @captures;

  my @ordered = map { $_->[1] }
    sort { $b->[0] <=> $a->[0] }
    map { [ _move_order_score($state, $_, 0), $_ ] } @captures;

  foreach my $move (@ordered) {
    my $new_state = $state->make_move($move);
    next unless defined $new_state;
    my $score = -_quiesce($new_state, -$beta, -$alpha, $depth + 1);
    if ($score > $alpha) {
      $alpha = $score;
      last if $alpha >= $beta;
    }
  }

  return $alpha;
}

sub _evaluate_board {
  my ($state) = @_;
  my $board = $state->[Chess::State::BOARD];
  my $score = 0;

  for my $idx (@board_indices) {
    my $piece = $board->[$idx];
    next unless $piece;

    my $base_value = $piece_values{$piece} // 0;
    next unless $base_value;

    my $square = _idx_to_square($idx, 0) or next;
    my $bonus = _location_bonus($piece, $square, $base_value);
    $score += $base_value + $bonus;
  }

  return $score;
}

sub _search {
  my ($state, $depth, $alpha, $beta, $ply, $prev_move_key) = @_;
  $ply //= 0;
  _check_time_or_abort();

  if ($depth <= 0) {
    return (_quiesce($state, $alpha, $beta, 0), undef);
  }

  my $key = _state_key($state);
  my $tt_entry = $transposition_table{$key};

  if ($tt_entry && $tt_entry->{depth} >= $depth) {
    my $tt_score = $tt_entry->{score};
    if ($tt_entry->{flag} == TT_FLAG_EXACT) {
      return ($tt_score, _find_move_by_key($state, $tt_entry->{best_move_key}));
    }
    if ($tt_entry->{flag} == TT_FLAG_LOWER) {
      $alpha = max($alpha, $tt_score);
    } elsif ($tt_entry->{flag} == TT_FLAG_UPPER) {
      $beta = min($beta, $tt_score);
    }
    if ($alpha >= $beta) {
      return ($tt_score, _find_move_by_key($state, $tt_entry->{best_move_key}));
    }
  }

  my $alpha_orig = $alpha;
  my $beta_orig = $beta;
  my $tt_move_key = $tt_entry ? $tt_entry->{best_move_key} : undef;
  my $best_value = -INF_SCORE;
  my $best_move;
  my $legal_moves = 0;
  my $move_index = 0;
  my $in_check = $state->is_checked ? 1 : 0;

  foreach my $move (_ordered_moves($state, $ply, $tt_move_key, $prev_move_key)) {
    my $is_capture = _is_capture_state($state, $move);
    my $new_state = $state->make_move($move);
    next unless defined $new_state;

    $legal_moves++;
    my $child_prev_move_key = _move_key($move);

    my $value;
    if ($move_index == 0) {
      ($value) = _search($new_state, $depth - 1, -$beta, -$alpha, $ply + 1, $child_prev_move_key);
      $value = -$value;
    } else {
      my $reduction = 0;
      if (! $in_check
        && $depth >= 3
        && $move_index >= 3
        && !defined $move->[2]
        && !defined $move->[3]
        && ! $is_capture)
      {
        $reduction = 1;
        $reduction = 2 if $depth >= 6 && $move_index >= 8;
      }

      if ($reduction) {
        my $reduced_depth = $depth - 1 - $reduction;
        $reduced_depth = 0 if $reduced_depth < 0;
        ($value) = _search($new_state, $reduced_depth, -$alpha - 1, -$alpha, $ply + 1, $child_prev_move_key);
        $value = -$value;

        if ($value > $alpha) {
          ($value) = _search($new_state, $depth - 1, -$alpha - 1, -$alpha, $ply + 1, $child_prev_move_key);
          $value = -$value;
          if ($value > $alpha && $value < $beta) {
            ($value) = _search($new_state, $depth - 1, -$beta, -$alpha, $ply + 1, $child_prev_move_key);
            $value = -$value;
          }
        }
      } else {
        ($value) = _search($new_state, $depth - 1, -$alpha - 1, -$alpha, $ply + 1, $child_prev_move_key);
        $value = -$value;
        if ($value > $alpha && $value < $beta) {
          ($value) = _search($new_state, $depth - 1, -$beta, -$alpha, $ply + 1, $child_prev_move_key);
          $value = -$value;
        }
      }
    }
    $move_index++;

    if ($value > $best_value) {
      $best_value = $value;
      $best_move = $move;
    }

    if ($value > $alpha) {
      $alpha = $value;
      if ($alpha >= $beta) {
        unless ($is_capture) {
          _store_killer($ply, $move);
          _update_history($move, $depth);
          _store_countermove($prev_move_key, $move);
        }
        last;
      }
    }
  }

  if (! $legal_moves) {
    my $mate_or_draw = $state->is_checked ? (-MATE_SCORE + $ply) : 0;
    return ($mate_or_draw, undef);
  }

  my $flag = TT_FLAG_EXACT;
  if ($best_value <= $alpha_orig) {
    $flag = TT_FLAG_UPPER;
  } elsif ($best_value >= $beta_orig) {
    $flag = TT_FLAG_LOWER;
  }

  my $existing = $transposition_table{$key};
  if (!defined $existing || $depth >= ($existing->{depth} // -1) || ($existing->{gen} // 0) != $tt_generation) {
    $transposition_table{$key} = {
      depth => $depth,
      score => $best_value,
      flag => $flag,
      gen => $tt_generation,
      best_move_key => (defined $best_move ? _move_key($best_move) : undef),
    };
  }

  return ($best_value, $best_move);
}

#  mainly a converience wrapper around rec_think.
sub think {
  my $self = shift;
  my $on_update;
  $on_update = shift if @_ && ref($_[0]) eq 'CODE';
  $on_update = undef unless defined $on_update && ref($on_update) eq 'CODE';
  my %think_opts;
  if (scalar(@_) == 1 && ref($_[0]) eq 'HASH') {
    %think_opts = %{$_[0]};
  } elsif (@_ % 2 == 0) {
    %think_opts = @_;
  }
  my $use_book = exists $think_opts{use_book} ? ($think_opts{use_book} ? 1 : 0) : 1;
  my $state = ${$self->{state}};

  if ($use_book && (my $book_move = Chess::Book::choose_move($state))) {
    return $book_move;
  }

  if (my $table_move = Chess::EndgameTable::choose_move($state)) {
    return $table_move;
  }

  _decay_history();
  @killer_moves = ();
  $tt_generation++;
  _trim_transposition_table();

  my $target_depth = max(1, $self->{depth});
  my $max_depth = min(20, $target_depth + EXTRA_DEPTH_ON_UNSTABLE);
  my $easy_move_depth = max(EASY_MOVE_MIN_DEPTH, min($target_depth, EASY_MOVE_DEPTH_CAP));
  my $time_policy = _configure_time_limits($state, \%think_opts);
  my $best_move;
  my $prev_score = 0;
  my $last_completed_depth = 0;
  my $last_completed_score;
  my $stability_hits = 0;
  my $stable_best_hits = 0;
  my $prev_best_move_key;
  my $had_prev_score = 0;

  DEPTH_LOOP:
  for my $depth (1 .. $max_depth) {
    last DEPTH_LOOP if $last_completed_depth && _time_up_soft();
    my $alpha = -INF_SCORE;
    my $beta = INF_SCORE;
    my $window = ASPIRATION_WINDOW;
    my $iteration_score;
    my $iteration_move;
    my $aspiration_expansions = 0;

    if ($depth >= 3) {
      $alpha = max(-INF_SCORE, $prev_score - $window);
      $beta = min(INF_SCORE, $prev_score + $window);
    }

    while (1) {
      my ($score, $move);
      my $ok = eval {
        ($score, $move) = _search($state, $depth, $alpha, $beta, 0, undef);
        1;
      };
      if (! $ok) {
        my $err = $@;
        if (defined $err && $err =~ /\Q$search_time_abort\E/) {
          last DEPTH_LOOP;
        }
        die $err;
      }
      $best_move = $move if defined $move;
      $iteration_score = $score;
      $iteration_move = $move if defined $move;

      if ($score <= $alpha) {
        $aspiration_expansions++;
        $alpha = max(-INF_SCORE, $alpha - $window);
        $window *= 2;
        last if $last_completed_depth && _time_up_soft();
        next;
      }
      if ($score >= $beta) {
        $aspiration_expansions++;
        $beta = min(INF_SCORE, $beta + $window);
        $window *= 2;
        last if $last_completed_depth && _time_up_soft();
        next;
      }

      last;
    }

    next unless defined $iteration_score;
    $last_completed_depth = $depth;
    $last_completed_score = $iteration_score;
    my $iteration_move_key = defined $iteration_move ? _move_key($iteration_move) : undef;
    my $pv_changed = defined $iteration_move_key && defined $prev_best_move_key && $iteration_move_key ne $prev_best_move_key;
    if (defined $iteration_move_key && defined $prev_best_move_key && $iteration_move_key eq $prev_best_move_key) {
      $stable_best_hits++;
    } else {
      $stable_best_hits = 0;
    }

    my $score_delta = $had_prev_score ? abs($iteration_score - $prev_score) : 0;
    my $volatile = $pv_changed || $score_delta > (SCORE_STABILITY_DELTA * 4) || $aspiration_expansions >= 2;

    if ($had_prev_score && abs($iteration_score - $prev_score) <= SCORE_STABILITY_DELTA) {
      $stability_hits++;
    } else {
      $stability_hits = 0;
    }
    $prev_score = $iteration_score;
    $had_prev_score = 1;
    $prev_best_move_key = $iteration_move_key if defined $iteration_move_key;
    if ($on_update && defined $best_move) {
      eval { $on_update->($depth, $iteration_score, $best_move); };
    }

    if ($time_policy->{has_clock} && $volatile) {
      my $extra_ms = int(($time_policy->{budget_ms} || 0) * 0.25);
      _extend_soft_deadline($extra_ms);
    }

    if ($time_policy->{has_clock} && $depth >= $easy_move_depth) {
      my $easy_move = !$volatile
        && $stable_best_hits >= 2
        && $score_delta <= SCORE_STABILITY_DELTA
        && $aspiration_expansions == 0;
      last DEPTH_LOOP if $easy_move;
    }

    if ($depth >= $target_depth) {
      last if $stability_hits >= 1;
      last if _time_up_soft();
    }
  }

  if (!defined $best_move) {
    my @legal = $state->generate_moves;
    $best_move = $legal[0] if @legal;
  }

  $last_completed_score = _evaluate_board($state) unless defined $last_completed_score;
  $last_completed_depth = 1 unless $last_completed_depth;
  return wantarray
    ? ($best_move, $last_completed_score, $last_completed_depth)
    : $best_move;
}

1;
