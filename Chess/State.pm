package Chess::State;
use strict;
use warnings;

use Chess::Constant;
use Chess::MoveGen ();
use Chess::Zobrist qw(
  zobrist_empty_key
  zobrist_is_key
  zobrist_turn_token
  zobrist_piece_token
  zobrist_castle_token
  zobrist_ep_token
);

# Named array keys, saves a bit of time over hash-based object
use constant 1.03 {
  BOARD => 0,
  TURN => 1,
  CASTLE => 2,
  EP => 3,
  HALFMOVE => 4,
  MOVE => 5,
  KING_IDX => 6,
  OPP_KING_IDX => 7,
  PIECE_COUNT => 8,
  STATE_KEY => 9,
  FEN_KEY => 10,
};
#use constant KINGS => 6;

sub new {
  my ($class, $initialFEN) = @_;

  # default position if unspecified
  $initialFEN = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1'
    unless $initialFEN;

  # empty object with defaults
  my @self;

  # Apply initial FEN to set board position / state
  set_fen(\@self, $initialFEN);

  # Bless this class and return
  return bless \@self, $class;
}

#putting a fen in here so that i can plug this into lichess one day
sub set_fen {
  my ($self, $input) = @_;


  die "Invalid FEN string '$input'" unless $input =~ m{^\s*([BKNPQR1-8/]+)\s+([BW])\s+([KQ]+|-)\s+((?:[A-H][1-8])|-)\s+(\d+)\s+(\d+)\s*$}i;

  # a new FEN position always deletes all history
  #$self->{history} = [];


  #  Whose turn?
  $self->[TURN] = lc($2) eq 'b';

  #  Castling ability
  $self->[CASTLE] = [ [], [] ];
  $self->[CASTLE][$self->[TURN]][CASTLE_KING] = index($3, 'K') >= 0;
  $self->[CASTLE][$self->[TURN]][CASTLE_QUEEN] = index($3, 'Q') >= 0;
  $self->[CASTLE][! $self->[TURN]][CASTLE_KING] = index($3, 'k') >= 0;
  $self->[CASTLE][! $self->[TURN]][CASTLE_QUEEN] = index($3, 'q') >= 0;

  #  EP
  if ($4 eq '-') {
    $self->[EP] = undef;
  } else {
    my $ep_idx = _square_to_idx($4, $self->[TURN]);
    die "Invalid en-passant square '$4' in FEN" unless defined $ep_idx;
    $self->[EP] = $ep_idx;
  }
  #  Halfmove clock
  $self->[HALFMOVE] = $5;
  #  Move number
  $self->[MOVE] = $6;

  #  Board
  $self->[BOARD] = [
    OOB, OOB, OOB, OOB, OOB, OOB, OOB, OOB, OOB, OOB,
    OOB, OOB, OOB, OOB, OOB, OOB, OOB, OOB, OOB, OOB,
    OOB, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, OOB,
    OOB, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, OOB,
    OOB, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, OOB,
    OOB, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, OOB,
    OOB, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, OOB,
    OOB, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, OOB,
    OOB, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, OOB,
    OOB, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, EMPTY, OOB,
    OOB, OOB, OOB, OOB, OOB, OOB, OOB, OOB, OOB, OOB,
    OOB, OOB, OOB, OOB, OOB, OOB, OOB, OOB, OOB, OOB
  ];

  my $king_idx;
  my $opp_king_idx;
  my $piece_count = 0;


  my $rank = 90;
  my $flip_board = $self->[TURN] ? 1 : 0;
  foreach my $row (split m{/}, $1, 8) {
    my $file = 1;
    for (my $char_idx = 0; $char_idx < length($row); $char_idx++) {
      my $code = substr($row, $char_idx, 1);
      my $mapped_piece = $l2p{$code};
      if (defined $mapped_piece) {
        my $piece = $flip_board ? -$mapped_piece : $mapped_piece;
        my $idx = $flip_board ? (110 - $rank + $file) : ($rank + $file);
        $self->[BOARD][$idx] = $piece;
        $piece_count++;
        $king_idx = $idx if $piece == KING;
        $opp_king_idx = $idx if $piece == OPP_KING;
        $file++;
      } elsif ($code ge '1' && $code le '8') {
        $file += ord($code) - ord('0');
      } else {
        die "Illegal character $code in FEN string";
      }
    }
    $rank -= 10;
  }

  $self->[KING_IDX] = $king_idx;
  $self->[OPP_KING_IDX] = $opp_king_idx;
  $self->[PIECE_COUNT] = $piece_count;
  $self->[STATE_KEY] = _compute_zobrist_key($self);
  $self->[FEN_KEY] = undef;
}

# Return a FEN string representing the current game state
sub get_fen {
  my ($self) = @_;

  my $placement = '';

  for my $rank (0 .. 7)
  {
    my $skip = 0;
    for my $file (0 .. 7) {
      my $piece = $self->[TURN] ?
        -$self->[BOARD][10 * (2 + $rank) + $file + 1] :
	$self->[BOARD][10 * (9 - $rank) + $file + 1];

      if ($piece) {
        if ($skip > 0) {
          $placement .= $skip;
          $skip = 0;
        }
        $placement .= $p2l{$piece};
      } else {
        $skip ++;
      }
    }
    if ($skip > 0) {
      # Pad remaining squares
      $placement .= $skip;
    }
    if ($rank < 7) {
      # Rank delimiter
      $placement .= '/';
    }
  }

  # Castle
  my $castle = '';
  $castle .= 'K' if $self->[CASTLE][$self->[TURN]][CASTLE_KING];
  $castle .= 'Q' if $self->[CASTLE][$self->[TURN]][CASTLE_QUEEN];
  $castle .= 'k' if $self->[CASTLE][! $self->[TURN]][CASTLE_KING];
  $castle .= 'q' if $self->[CASTLE][! $self->[TURN]][CASTLE_QUEEN];
  $castle = '-' if $castle eq '';

  # EP
  my $ep = '-';
  if (defined $self->[EP]) {
    $ep = _idx_to_square($self->[EP], $self->[TURN]) // '-';
  }

  return join(' ',
    $placement,
    ($self->[TURN] ? 'b' : 'w'),
    $castle,
    $ep,
    $self->[HALFMOVE],
    $self->[MOVE]
  );
}

sub get_board
{
  my ($self) = @_;

  my @ret;
  for my $rank (20, 30, 40, 50, 60, 70, 80, 90) {
    if ($self->[TURN]) {
      push @ret, [ map { - $_ } @{$self->[BOARD]}[110-$rank+1 .. 110-$rank+8] ];
    } else {
      push @ret, [ @{$self->[BOARD]}[$rank+1 .. $rank+8] ];
    }
  }
  return @ret;
}

sub get_moves
{
  my ($self) = @_;

  return map { decode_move($self, $_) } generate_moves($self);
}

# converts a string to a move array
sub encode_move
{
  my ($self, $move) = @_;
  return unless defined $move;
  $move =~ s/\s+//g;
  return unless $move =~ /^([a-h])([1-8])([a-h])([1-8])([nbrqNBRQ])?$/;
  my @fields = ($1, $2, $3, $4, $5);
  my ($from, $to, $promo);
  my $promo_piece = defined $fields[4] ? $l2p{uc($fields[4])} : undef;
  return if defined($fields[4]) && !defined($promo_piece);

  if ($self->[TURN])
  {
    $from = 10 * (10 - $fields[1]) + ord($fields[0]) - ord('a') + 1;
    $to = 10 * (10 - $fields[3]) + ord($fields[2]) - ord('a') + 1;
    $promo = defined($promo_piece) ? -$promo_piece : undef;
  } else {
    $from = 10 * ($fields[1] + 1) + ord($fields[0]) - ord('a') + 1;
    $to = 10 * ($fields[3] + 1) + ord($fields[2]) - ord('a') + 1;
    $promo = $promo_piece;
  }

  my $special;
  if ($self->[BOARD][$from] == KING && $from == 25 && !defined $promo) {
    $special = CASTLE_KING if $to == 27;
    $special = CASTLE_QUEEN if $to == 23;
  }

  return [ $from, $to, $promo, $special ];
}

# converts a move array back to a string
sub decode_move
{
  my ($self, $move) = @_;

  if ($self->[TURN])
  {
    return sprintf('%c%1d%c%1d%s',
      ($move->[0] % 10) - 1 + ord 'a',
      10 - int($move->[0] / 10),
      ($move->[1] % 10) - 1 + ord 'a',
      10 - int($move->[1] / 10),
      ($move->[2] ? lc($p2l{$move->[2]}) : ''));
  }

  return sprintf('%c%1d%c%1d%s',
    ($move->[0] % 10) - 1 + ord 'a',
    int($move->[0] / 10) - 1,
    ($move->[1] % 10) - 1 + ord 'a',
    int($move->[1] / 10) - 1,
    ($move->[2] ? lc($p2l{$move->[2]}) : ''));
}

sub _square_to_idx {
  my ($square, $turn) = @_;
  return unless defined $square && $square =~ /^([a-h])([1-8])$/i;
  my ($file, $rank) = (lc($1), $2);
  my $file_idx = ord($file) - ord('a') + 1;
  return $turn
    ? 10 * (10 - $rank) + $file_idx
    : 10 * ($rank + 1) + $file_idx;
}

sub _idx_to_square {
  my ($idx, $turn) = @_;
  my $file = ($idx % 10) - 1;
  return unless $file >= 0 && $file < 8;
  my $rank = $turn ? 10 - int($idx / 10) : int($idx / 10) - 1;
  return unless $rank >= 1 && $rank <= 8;
  return chr(ord('a') + $file) . $rank;
}

sub _flip_idx {
  my ($idx) = @_;
  my $rank_base = int($idx / 10) * 10;
  my $file = $idx % 10;
  return 110 - $rank_base + $file;
}

sub _internal_idx_to_abs_square {
  my ($idx, $turn) = @_;
  my $mapped = $turn ? _flip_idx($idx) : $idx;
  my $file = ($mapped % 10) - 1;
  return unless $file >= 0 && $file < 8;
  my $rank = int($mapped / 10) - 2;
  return unless $rank >= 0 && $rank < 8;
  return (8 * $rank) + $file;
}

sub _internal_piece_to_zobrist_piece {
  my ($piece, $turn) = @_;
  return unless defined $piece;
  return if $piece == EMPTY || abs($piece) > KING;
  my $absolute_piece = $turn ? -$piece : $piece;
  my $offset = $absolute_piece < 0 ? 6 : 0;
  return $offset + abs($absolute_piece) - 1;
}

sub _absolute_castle_flags {
  my ($turn, $castle) = @_;
  my ($white_ref, $black_ref) = $turn
    ? ($castle->[1], $castle->[0])
    : ($castle->[0], $castle->[1]);
  return (
    $white_ref->[CASTLE_KING] ? 1 : 0,
    $white_ref->[CASTLE_QUEEN] ? 1 : 0,
    $black_ref->[CASTLE_KING] ? 1 : 0,
    $black_ref->[CASTLE_QUEEN] ? 1 : 0,
  );
}

sub _compute_zobrist_key {
  my ($self) = @_;
  my $turn = $self->[TURN] ? 1 : 0;
  my $key = zobrist_empty_key();

  for my $idx (21 .. 28, 31 .. 38, 41 .. 48, 51 .. 58, 61 .. 68, 71 .. 78, 81 .. 88, 91 .. 98) {
    my $piece = $self->[BOARD][$idx] // EMPTY;
    next if $piece == EMPTY || abs($piece) > KING;
    my $piece_idx = _internal_piece_to_zobrist_piece($piece, $turn);
    my $square = _internal_idx_to_abs_square($idx, $turn);
    next unless defined $piece_idx && defined $square;
    $key ^= zobrist_piece_token($piece_idx, $square);
  }

  $key ^= zobrist_turn_token() if $turn;

  my ($white_king, $white_queen, $black_king, $black_queen) = _absolute_castle_flags($turn, $self->[CASTLE]);
  $key ^= zobrist_castle_token(0, CASTLE_KING) if $white_king;
  $key ^= zobrist_castle_token(0, CASTLE_QUEEN) if $white_queen;
  $key ^= zobrist_castle_token(1, CASTLE_KING) if $black_king;
  $key ^= zobrist_castle_token(1, CASTLE_QUEEN) if $black_queen;

  if (defined $self->[EP]) {
    my $ep_square = _internal_idx_to_abs_square($self->[EP], $turn);
    $key ^= zobrist_ep_token($ep_square) if defined $ep_square;
  }

  return $key;
}


sub make_move {
  my ($self, $move) = @_;

  #  Board
  my @board = @{$self->[BOARD]};

  # lookup the existing piece
  my $from_piece = $board[$move->[0]];
  my $to_piece   = $board[$move->[1]];
  my $is_capture = ($to_piece // 0) < 0 ? 1 : 0;
  my $is_en_passant = 0;
  my $piece_count = $self->[PIECE_COUNT];
  if (!defined $piece_count) {
    $piece_count = 0;
    for my $idx (21 .. 28, 31 .. 38, 41 .. 48, 51 .. 58, 61 .. 68, 71 .. 78, 81 .. 88, 91 .. 98) {
      my $piece = $board[$idx] // 0;
      $piece_count++ if abs($piece) >= PAWN && abs($piece) <= KING;
    }
  }
  my $own_king_idx = $self->[KING_IDX];
  my $opp_king_idx = $self->[OPP_KING_IDX];
  my $turn = $self->[TURN] ? 1 : 0;
  my $old_state_key = $self->[STATE_KEY];
  $old_state_key = _compute_zobrist_key($self) unless zobrist_is_key($old_state_key);
  my ($white_king_old, $white_queen_old, $black_king_old, $black_queen_old)
    = _absolute_castle_flags($turn, $self->[CASTLE]);
  my $from_square = _internal_idx_to_abs_square($move->[0], $turn);
  my $to_square = _internal_idx_to_abs_square($move->[1], $turn);
  my $moving_piece_idx = _internal_piece_to_zobrist_piece($from_piece, $turn);
  my $captured_piece = $to_piece;
  my $captured_idx = $move->[1];

  # En-passant capture moves to an empty target square.
  if ($from_piece == PAWN
      && defined $self->[EP]
      && !defined $move->[2]
      && ($move->[1] - $move->[0] == 9 || $move->[1] - $move->[0] == 11)
      && $move->[1] == $self->[EP]
      && ($to_piece // 0) == EMPTY)
  {
    $is_en_passant = 1;
    $is_capture = 1;
    $captured_piece = $board[$move->[1] - 10];
    $captured_idx = $move->[1] - 10;
    $board[$move->[1] - 10] = EMPTY;
    $piece_count--;
  }

  # make move
  if (defined $move->[3]) {
    # special-case handler
    if ($move->[3] == CASTLE_KING) {
      # kingside castle
      # cannot castle out of check
      return undef if checked(\@board);
      #  test move-through-check
      @board[25, 26] = (0, KING);
      return undef if checked(\@board);
      # move rook
      @board[28, 26] = (0, ROOK);
      # fall through to next condition (king move)
    } elsif ($move->[3] == CASTLE_QUEEN) {
      # queenside castle
      # cannot castle out of check
      return undef if checked(\@board);
      #  test move-through-check
      @board[25, 24] = (0, KING);
      return undef if checked(\@board);
      # move rook
      @board[21, 24] = (0, ROOK);
      # fall through to next condition (king move)
    }
  }

  @board[$move->[0], $move->[1]] = (0, $move->[2] || $from_piece);
  $piece_count-- if $is_capture && !$is_en_passant;
  $own_king_idx = $move->[1] if $from_piece == KING;

  # Test for legality.
  return undef if checked(\@board);

  # flip board
  for my $rank (20, 30, 40, 50) {
    ($board[$rank + $_], $board[110 - $rank + $_]) = (-$board[110 - $rank + $_], -$board[$rank + $_]) for (1 .. 8);
  }

  my @next_to_move_castle = (
    $self->[CASTLE][1][CASTLE_KING] ? 1 : 0,
    $self->[CASTLE][1][CASTLE_QUEEN] ? 1 : 0,
  );
  # Capturing an opponent rook on its home square removes that side's right.
  $next_to_move_castle[CASTLE_KING] = 0 if $move->[1] == 98;
  $next_to_move_castle[CASTLE_QUEEN] = 0 if $move->[1] == 91;

  my @next_opponent_castle = (
    ($move->[0] == 25 || $move->[0] == 28) ? 0 : ($self->[CASTLE][0][CASTLE_KING] ? 1 : 0),
    ($move->[0] == 25 || $move->[0] == 21) ? 0 : ($self->[CASTLE][0][CASTLE_QUEEN] ? 1 : 0),
  );

  my $new_ep;
  if ($from_piece == PAWN && !defined $move->[2] && $move->[1] - $move->[0] == 20) {
    $new_ep = _flip_idx($move->[0] + 10);
  }

  my $new_king_idx = defined $opp_king_idx ? _flip_idx($opp_king_idx) : undef;
  my $new_opp_king_idx = defined $own_king_idx ? _flip_idx($own_king_idx) : undef;
  my @new_castle = ( \@next_to_move_castle, \@next_opponent_castle );
  my ($white_king_new, $white_queen_new, $black_king_new, $black_queen_new)
    = _absolute_castle_flags(! $turn, \@new_castle);

  my $new_state_key = $old_state_key;
  $new_state_key ^= zobrist_turn_token();

  if (defined $self->[EP]) {
    my $old_ep_square = _internal_idx_to_abs_square($self->[EP], $turn);
    $new_state_key ^= zobrist_ep_token($old_ep_square) if defined $old_ep_square;
  }

  $new_state_key ^= zobrist_castle_token(0, CASTLE_KING) if $white_king_old;
  $new_state_key ^= zobrist_castle_token(0, CASTLE_QUEEN) if $white_queen_old;
  $new_state_key ^= zobrist_castle_token(1, CASTLE_KING) if $black_king_old;
  $new_state_key ^= zobrist_castle_token(1, CASTLE_QUEEN) if $black_queen_old;

  if (defined $moving_piece_idx && defined $from_square) {
    $new_state_key ^= zobrist_piece_token($moving_piece_idx, $from_square);
  }
  if ($is_capture && defined $captured_piece && $captured_piece != EMPTY) {
    my $captured_piece_idx = _internal_piece_to_zobrist_piece($captured_piece, $turn);
    my $captured_square = _internal_idx_to_abs_square($captured_idx, $turn);
    if (defined $captured_piece_idx && defined $captured_square) {
      $new_state_key ^= zobrist_piece_token($captured_piece_idx, $captured_square);
    }
  }
  my $placed_piece = defined $move->[2] ? $move->[2] : $from_piece;
  my $placed_piece_idx = _internal_piece_to_zobrist_piece($placed_piece, $turn);
  if (defined $placed_piece_idx && defined $to_square) {
    $new_state_key ^= zobrist_piece_token($placed_piece_idx, $to_square);
  }

  if (defined $move->[3]) {
    my $rook_piece_idx = _internal_piece_to_zobrist_piece(ROOK, $turn);
    if (defined $rook_piece_idx) {
      if ($move->[3] == CASTLE_KING) {
        my $rook_from_square = _internal_idx_to_abs_square(28, $turn);
        my $rook_to_square = _internal_idx_to_abs_square(26, $turn);
        $new_state_key ^= zobrist_piece_token($rook_piece_idx, $rook_from_square) if defined $rook_from_square;
        $new_state_key ^= zobrist_piece_token($rook_piece_idx, $rook_to_square) if defined $rook_to_square;
      } elsif ($move->[3] == CASTLE_QUEEN) {
        my $rook_from_square = _internal_idx_to_abs_square(21, $turn);
        my $rook_to_square = _internal_idx_to_abs_square(24, $turn);
        $new_state_key ^= zobrist_piece_token($rook_piece_idx, $rook_from_square) if defined $rook_from_square;
        $new_state_key ^= zobrist_piece_token($rook_piece_idx, $rook_to_square) if defined $rook_to_square;
      }
    }
  }

  $new_state_key ^= zobrist_castle_token(0, CASTLE_KING) if $white_king_new;
  $new_state_key ^= zobrist_castle_token(0, CASTLE_QUEEN) if $white_queen_new;
  $new_state_key ^= zobrist_castle_token(1, CASTLE_KING) if $black_king_new;
  $new_state_key ^= zobrist_castle_token(1, CASTLE_QUEEN) if $black_queen_new;

  if (defined $new_ep) {
    my $new_ep_square = _internal_idx_to_abs_square($new_ep, ! $turn);
    $new_state_key ^= zobrist_ep_token($new_ep_square) if defined $new_ep_square;
  }

  return bless [
    \@board,
    ! $self->[TURN],
    \@new_castle,
    $new_ep,
    (($from_piece == PAWN || defined $move->[2] || $is_capture || $is_en_passant) ? 0 : $self->[HALFMOVE] + 1),
    ($self->[TURN] ? $self->[MOVE] + 1 : $self->[MOVE]),
    $new_king_idx,
    $new_opp_king_idx,
    $piece_count,
    $new_state_key,
    undef,
    #[ $self->[KINGS][1], $self->[KINGS][0] ]
  ];

  # Bless this class and return
  #return bless \@new_state; #, ref $self;
}

sub generate_moves
{
  my ($self) = @_;

  # locate king
  return grep {
    defined make_move($self, $_);
  } @{generate_pseudo_moves($self)};
}

sub generate_moves_by_type {
  my ($self, $type) = @_;
  return Chess::MoveGen::generate_moves($self, $type);
}

# Immutable-state compatibility helpers for do/undo style callers.
sub do_move {
  my ($self, $move, $stack) = @_;
  my $next = make_move($self, $move);
  return unless defined $next;
  push @{$stack}, $self if ref($stack) eq 'ARRAY';
  return $next;
}

sub undo_move {
  my ($self, $stack) = @_;
  return unless ref($stack) eq 'ARRAY' && @{$stack};
  return pop @{$stack};
}

sub is_checked {
  return checked($_[0]->[BOARD]);
}

sub is_playable {
  return (generate_moves($_[0]) > 0);
}

sub checked
{
  my ($board) = @_;

  for (21 .. 28, 31 .. 38, 41 .. 48, 51 .. 58, 61 .. 68, 71 .. 78, 81 .. 88, 91 .. 98) {
    return attacked($board, $_) if $board->[$_] == KING
  }
}

sub attacked {
  my ($board, $idx) = @_;

  # check surrounding squares (pawn, queen, bishop, rook, king attack)
  for (-11, -10, -9, -1, 1, 9, 10, 11) {
    return 1 if $board->[$idx + $_] == OPP_KING;
  }

  # Board is always oriented to side-to-move, so opponent pawns attack
  # from +9/+11 relative to our king square.
  return 1 if $board->[$idx + 11] == OPP_PAWN ||
              $board->[$idx + 9] == OPP_PAWN;

  # check knight attacks from here
  for (-21, -19, -12, -8, 8, 12, 19, 21) {
    return 1 if $board->[$idx + $_] == OPP_KNIGHT;
  }

  my $dest;
  for my $inc (-10, -1, 1, 10) {
    $dest = $idx;
    do {
      $dest += $inc;
      return 1 if $board->[$dest] == OPP_ROOK ||
                  $board->[$dest] == OPP_QUEEN;
    } while (! $board->[$dest] );
  }

  # now bishop or queen
  for my $inc (-11, -9, 9, 11) {
    $dest = $idx;
    do {
      $dest += $inc;
      return 1 if $board->[$dest] == OPP_BISHOP ||
                  $board->[$dest] == OPP_QUEEN;
    } while (! $board->[$dest] );
  }

  # square is safe...
  return 0;
}


sub generate_pseudo_moves
{
  my ($self) = @_;

  #my @board = \@{$self->[BOARD]};

  # Begin with an empty list of potential moves.
  my @m;


  for my $idx (21 .. 28, 31 .. 38, 41 .. 48, 51 .. 58, 61 .. 68, 71 .. 78, 81 .. 88, 91 .. 98) {

    # Compute all possible moves.
    if ($self->[BOARD][$idx] == KING) {
      # King 
      for (-11, -10, -9, -1, 1, 9, 10, 11) {
        push @m, [ $idx, $idx + $_ ] if $self->[BOARD][$idx + $_] <= 0;
      }
    } elsif ($self->[BOARD][$idx] == KNIGHT) {
      # Knight
      for (-21, -19, -12, -8, 8, 12, 19, 21) {
        push @m, [ $idx, $idx + $_ ] if $self->[BOARD][$idx + $_] <= 0;
      }
    } elsif ($self->[BOARD][$idx] == PAWN) {
      # Pawn
      #  Attempt a one-space-forward move
      if (! $self->[BOARD][$idx + 10]) {
        if ($idx > 80) {
          #  Promote.
          push @m,
              [ $idx, $idx + 10, BISHOP ],
              [ $idx, $idx + 10, KNIGHT ],
              [ $idx, $idx + 10, QUEEN ],
              [ $idx, $idx + 10, ROOK ];
        } else {
          push @m, [ $idx, $idx + 10 ];

          # we may double-push if on 2nd rank and 4th unoccupied
          if ($idx < 40 && ! $self->[BOARD][$idx + 20])
          {
            push @m, [ $idx, $idx + 20 ];
          }
        }
      }

      # Try a capture instead.
      for (9, 11)
      {
        # check ownership by opponent.
        if ($self->[BOARD][$idx + $_] < 0) {
          if ($idx > 80) {
            # end of board for white!  Promote.
            push @m,
                [ $idx, $idx + $_, BISHOP ],
                [ $idx, $idx + $_, KNIGHT ],
                [ $idx, $idx + $_, QUEEN ],
                [ $idx, $idx + $_, ROOK ];
          } else {
            push @m, [ $idx, $idx + $_ ];
          }
        } elsif (defined $self->[EP] && $idx + $_ == $self->[EP]) {
          # En-passant capture to the target square.
          push @m, [ $idx, $idx + $_ ];
        }
      }
    } else {
      # Rook, Bishop, or Queen moves

      # Rook or Queen moves
      if ($self->[BOARD][$idx] == ROOK || $self->[BOARD][$idx] == QUEEN) {
        for my $inc (-10, -1, 1, 10) {
          my $dest = $idx;
          do {
            $dest += $inc;
            push @m, [ $idx, $dest ] if $self->[BOARD][$dest] <= 0;
          } while ( ! $self->[BOARD][$dest] );
        }
      }

      # Bishop or Queen moves
      if ($self->[BOARD][$idx] == BISHOP || $self->[BOARD][$idx] == QUEEN) {
        for my $inc (-11, -9, 9, 11) {
          my $dest = $idx;
          do {
            $dest += $inc;
            push @m, [ $idx, $dest ] if $self->[BOARD][$dest] <= 0;
          } while ( ! $self->[BOARD][$dest] );
        }
      }
    }
  }

  # Castling
  push @m, [ 25, 27, undef, CASTLE_KING ] if $self->[CASTLE][0][CASTLE_KING] && $self->[BOARD][26] == EMPTY && $self->[BOARD][27] == EMPTY;
  push @m, [ 25, 23, undef, CASTLE_QUEEN ] if $self->[CASTLE][0][CASTLE_QUEEN] && $self->[BOARD][24] == EMPTY && $self->[BOARD][23] == EMPTY && $self->[BOARD][22] == EMPTY;

  return \@m;
}

###############################################################################
# DEBUG - Pretty-print a Board and other internal state.
#  This is formatted *as the engine sees it*
sub pp {
  my ($self) = @_;

  # header
  print "FEN: " . $self->get_fen . "\n";

  # check for check (find my king)
  print (checked($self->[BOARD]) ? "IN CHECK\n" : "(not in check)\n");
  # board image, rank 8 down to 1
  print "TURN: " . ($self->[TURN] ? '1 - BLACK' : '0 - WHITE') . "\n";
  print "   0 1 2 3 4 5 6 7 8 9\n";
  print "  +-+-+-+-+-+-+-+-+-+-+\n";
  for my $rank (0 .. 11) {
    printf("%2d|", $rank);
    for my $file (0 .. 9) {
      my $piece = $self->[BOARD][10 * $rank + $file];
      printf("%1s|", $piece ? $p2l{$piece} : ' ');
    }
    print "\n  +-+-+-+-+-+-+-+-+-+-+\n";
  }
  print "\n";

  # other state info
  print "Castle: self, K=" . $self->[CASTLE][$self->[TURN]][CASTLE_KING] . ', Q=' . $self->[CASTLE][$self->[TURN]][CASTLE_QUEEN] . "\n";
  print "    opponent, k=" . $self->[CASTLE][! $self->[TURN]][CASTLE_KING] . ', q=' . $self->[CASTLE][! $self->[TURN]][CASTLE_QUEEN] . "\n";
  my $ep = defined $self->[EP] ? (_idx_to_square($self->[EP], $self->[TURN]) // '(invalid)') : '(none)';
  print "En Passant: $ep\n";
  print "Halfmove: " . $self->[HALFMOVE] . "\n";
  print "Move: " . $self->[MOVE] . "\n";

  # list all possible moves
  print "\nAvailable moves:\n";
  foreach my $move (@{$self->generate_pseudo_moves}) {
    print " [" . join(',', @{$move}) . "]";
    print " (moves into check)" unless defined $self->make_move($move);
    print "\n";
  }
}

1;
