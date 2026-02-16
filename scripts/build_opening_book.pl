#!/usr/bin/env perl
use v5.14;
use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/..";

use Chess::Constant;
use Chess::State;
use Chess::TableUtil qw(canonical_fen_key);
use File::Spec;
use File::Path qw(make_path);
use Getopt::Long qw(GetOptions);
use JSON::PP ();

my $output = 'data/opening_book.json';
my $max_plies = 18;
my $max_games = 0;
my $min_position_games = 12;
my $min_move_games = 4;
my $progress_every = 0;
my $append_existing = 0;
my $min_white_elo = 0;
my $min_black_elo = 0;
my $min_avg_elo = 0;

GetOptions(
  'output=s' => \$output,
  'max-plies=i' => \$max_plies,
  'max-games=i' => \$max_games,
  'min-position-games=i' => \$min_position_games,
  'min-move-games=i' => \$min_move_games,
  'min-white-elo=i' => \$min_white_elo,
  'min-black-elo=i' => \$min_black_elo,
  'min-avg-elo=i' => \$min_avg_elo,
  'progress-every=i' => \$progress_every,
  'append-existing!' => \$append_existing,
) or die "Usage: $0 [--output PATH] [--max-plies N] [--max-games N] [--min-position-games N] [--min-move-games N] [--min-white-elo N] [--min-black-elo N] [--min-avg-elo N] [--progress-every N] [--[no-]append-existing] [inputs...]\n";

die "--max-plies must be >= 1\n" unless $max_plies >= 1;
die "--max-games must be >= 0\n" unless $max_games >= 0;
$min_position_games = 1 if $min_position_games < 1;
$min_move_games = 1 if $min_move_games < 1;
$min_white_elo = 0 if !defined $min_white_elo || $min_white_elo < 0;
$min_black_elo = 0 if !defined $min_black_elo || $min_black_elo < 0;
$min_avg_elo = 0 if !defined $min_avg_elo || $min_avg_elo < 0;
$progress_every = 0 if !defined $progress_every || $progress_every < 0;

my @inputs = @ARGV;
my %game_filters = (
  min_white_elo => $min_white_elo,
  min_black_elo => $min_black_elo,
  min_avg_elo   => $min_avg_elo,
);

my %counts;
my %position_totals;
my $parsed_games = 0;
my $processed_games = 0;
my $stop_parsing = 0;
my %san_candidate_cache;
my $san_candidate_cache_size = 0;
my $SAN_CANDIDATE_CACHE_MAX = 200_000;
my %state_move_pool_cache;
my $state_move_pool_cache_size = 0;
my $STATE_MOVE_POOL_CACHE_MAX = 100_000;
my %cmd_exists_cache;
my $path_dirs_cache_key;
my @path_dirs_cache;
my $path_list_sep = ($^O eq 'MSWin32') ? ';' : ':';

if (@inputs) {
  for my $path (@inputs) {
    last if $stop_parsing;
    my ($fh, $close_cb) = _open_pgn_handle($path);
    _consume_games(
      $fh,
      sub {
        my ($headers, $movetext) = @_;
        return 0 if $stop_parsing;
        $parsed_games++;
        if ($max_games && $parsed_games > $max_games) {
          $stop_parsing = 1;
          return 0;
        }
        my $ok = _process_game(
          $headers,
          $movetext,
          \%counts,
          \%position_totals,
          $max_plies,
          \%game_filters,
        );
        $processed_games++ if $ok;
        _report_progress($parsed_games, $processed_games, $progress_every);
        return 1;
      },
    );
    $close_cb->();
  }
} else {
  _consume_games(
    *STDIN,
    sub {
      my ($headers, $movetext) = @_;
      return 0 if $stop_parsing;
      $parsed_games++;
      if ($max_games && $parsed_games > $max_games) {
        $stop_parsing = 1;
        return 0;
      }
      my $ok = _process_game(
        $headers,
        $movetext,
        \%counts,
        \%position_totals,
        $max_plies,
        \%game_filters,
      );
      $processed_games++ if $ok;
      _report_progress($parsed_games, $processed_games, $progress_every);
      return 1;
    },
  );
}

if ($append_existing) {
  _merge_existing_output($output, \%counts, \%position_totals);
}

my @entries;
for my $key (keys %counts) {
  my $total_games = $position_totals{$key} // 0;
  next if $total_games < $min_position_games;

  my @moves;
  my $entry_total_played = 0;
  for my $uci (keys %{ $counts{$key} }) {
    my $stats = $counts{$key}{$uci};
    my $played = $stats->{played} // 0;
    next if $played < $min_move_games;
    $entry_total_played += $played;
    push @moves, {
      uci => $uci,
      weight => $played,
      played => $played,
      white => $stats->{white} // 0,
      draw  => $stats->{draw} // 0,
      black => $stats->{black} // 0,
    };
  }
  next unless @moves;

  @moves = sort {
    ($b->{played} <=> $a->{played})
      || ($a->{uci} cmp $b->{uci})
  } @moves;

  push @entries, {
    key => $key,
    moves => \@moves,
    _total_played => $entry_total_played,
  };
}

@entries = sort {
  (($b->{_total_played} // 0) <=> ($a->{_total_played} // 0))
    || ($a->{key} cmp $b->{key})
} @entries;
delete $_->{_total_played} for @entries;

my ($vol, $dir, undef) = File::Spec->splitpath($output);
my $out_dir = File::Spec->catpath($vol, $dir, '');
if (defined $out_dir && length $out_dir && !-d $out_dir) {
  make_path($out_dir);
}

open my $out_fh, '>', $output or die "Cannot write $output: $!\n";
print {$out_fh} JSON::PP->new->canonical->pretty->encode(\@entries);
close $out_fh;

print "games_parsed=$parsed_games\n";
print "games_processed=$processed_games\n";
print "positions_kept=" . scalar(@entries) . "\n";
print "output=$output\n";

exit 0;

sub _merge_existing_output {
  my ($path, $counts, $position_totals) = @_;
  return unless defined $path && -e $path;

  my $json_text = do {
    open my $fh, '<', $path or die "Cannot read existing $path: $!\n";
    local $/;
    my $raw = <$fh>;
    close $fh;
    $raw;
  };

  my $existing = eval { JSON::PP->new->relaxed->decode($json_text) };
  die "Cannot parse existing $path: $@\n" if $@;
  return unless ref $existing eq 'ARRAY';

  for my $entry (@$existing) {
    next unless ref $entry eq 'HASH';
    my $key = $entry->{key};
    next unless defined $key && length $key;
    my $moves = $entry->{moves};
    next unless ref $moves eq 'ARRAY';

    my $position_played = 0;
    for my $move (@$moves) {
      next unless ref $move eq 'HASH';
      my $uci = $move->{uci};
      next unless defined $uci && length $uci;

      my $played = _nonneg_num(
        $move->{played},
        _nonneg_num($move->{games}, _nonneg_num($move->{weight}, 0)),
      );
      my $white = _nonneg_num($move->{white}, 0);
      my $draw  = _nonneg_num($move->{draw}, 0);
      my $black = _nonneg_num($move->{black}, 0);
      my $total = $white + $draw + $black;
      $played = $total if $total > $played;
      next if $played <= 0;

      my $stats = ($counts->{$key}{$uci} ||= {
        played => 0,
        white  => 0,
        draw   => 0,
        black  => 0,
      });

      $stats->{played} += $played;
      $stats->{white}  += $white;
      $stats->{draw}   += $draw;
      $stats->{black}  += $black;
      $position_played += $played;
    }

    $position_totals->{$key} += $position_played if $position_played > 0;
  }
}

sub _nonneg_num {
  my ($value, $default) = @_;
  return $default unless defined $value;
  return $default unless $value =~ /\A-?(?:\d+(?:\.\d*)?|\.\d+)\z/;
  my $num = 0 + $value;
  return $default if $num < 0;
  return $num;
}

sub _report_progress {
  my ($parsed_games, $processed_games, $progress_every) = @_;
  return unless $progress_every && $parsed_games > 0;
  return unless ($parsed_games % $progress_every) == 0;
  print STDERR "progress parsed=$parsed_games processed=$processed_games\n";
}

sub _open_pgn_handle {
  my ($path) = @_;
  if ($path =~ /\.zst$/i) {
    if (_cmd_exists('zstdcat')) {
      open my $fh, '-|', 'zstdcat', '--', $path
        or die "Cannot open zstd stream for $path: $!\n";
      return ($fh, sub { close $fh; });
    }
    if (_cmd_exists('zstd')) {
      open my $fh, '-|', 'zstd', '-dc', '--', $path
        or die "Cannot open zstd stream for $path: $!\n";
      return ($fh, sub { close $fh; });
    }
    die "Input '$path' is .zst but neither zstdcat nor zstd is available\n";
  }

  open my $fh, '<', $path or die "Cannot read $path: $!\n";
  return ($fh, sub { close $fh; });
}

sub _cmd_exists {
  my ($cmd) = @_;
  return 0 unless defined $cmd && length $cmd;
  return $cmd_exists_cache{$cmd} if exists $cmd_exists_cache{$cmd};
  for my $dir (_path_dirs()) {
    my $full = "$dir/$cmd";
    if (-x $full) {
      $cmd_exists_cache{$cmd} = 1;
      return 1;
    }
  }
  $cmd_exists_cache{$cmd} = 0;
  return 0;
}

sub _path_dirs {
  my $path = $ENV{PATH} // '';
  if (!defined $path_dirs_cache_key || $path_dirs_cache_key ne $path) {
    $path_dirs_cache_key = $path;
    @path_dirs_cache = grep { length $_ } split /\Q$path_list_sep\E/, $path;
    %cmd_exists_cache = ();
  }
  return @path_dirs_cache;
}

sub _consume_games {
  my ($fh, $on_game) = @_;
  my %headers;
  my $movetext = '';

  while (defined(my $line = <$fh>)) {
    if ($line =~ /^\s*\[(\w+)\s+"((?:[^"\\]|\\.)*)"\]\s*$/) {
      if ($movetext =~ /\S/) {
        my $keep_going = $on_game->({ %headers }, $movetext);
        return if defined $keep_going && !$keep_going;
        %headers = ();
        $movetext = '';
      }
      my ($key, $value) = ($1, $2);
      $value =~ s/\\"/"/g;
      $headers{$key} = $value;
      next;
    }

    $movetext .= $line;
    if ($line =~ /^\s*$/ && $movetext =~ /\b(?:1-0|0-1|1\/2-1\/2|\*)\b/) {
      my $keep_going = $on_game->({ %headers }, $movetext);
      return if defined $keep_going && !$keep_going;
      %headers = ();
      $movetext = '';
    }
  }

  if ($movetext =~ /\S/) {
    my $keep_going = $on_game->({ %headers }, $movetext);
    return if defined $keep_going && !$keep_going;
  }
}

sub _process_game {
  my ($headers, $movetext, $counts, $position_totals, $max_plies, $filters) = @_;
  my $result = $headers->{Result} // '*';
  $filters ||= {};

  my $white_elo = _parse_elo($headers->{WhiteElo});
  my $black_elo = _parse_elo($headers->{BlackElo});
  if (($filters->{min_white_elo} // 0) > 0) {
    return 0 unless defined $white_elo && $white_elo >= $filters->{min_white_elo};
  }
  if (($filters->{min_black_elo} // 0) > 0) {
    return 0 unless defined $black_elo && $black_elo >= $filters->{min_black_elo};
  }
  if (($filters->{min_avg_elo} // 0) > 0) {
    return 0 unless defined $white_elo && defined $black_elo;
    my $avg_elo = ($white_elo + $black_elo) / 2;
    return 0 unless $avg_elo >= $filters->{min_avg_elo};
  }

  my $state;
  eval {
    if (defined $headers->{FEN} && length $headers->{FEN}) {
      $state = Chess::State->new($headers->{FEN});
    } else {
      $state = Chess::State->new();
    }
  };
  if (!$state || $@) {
    warn "Skipping game with invalid start position: $@\n";
    return 0;
  }

  my @tokens = _tokenize_movetext($movetext);
  my $ply = 0;
  TOKEN:
  for my $token (@tokens) {
    next unless defined $token;
    $token =~ s/^\s+|\s+$//g;
    next unless length $token;

    while ($token =~ s/^\d+\.(?:\.\.)?//) {}
    next unless length $token;
    next if $token =~ /^\$\d+$/;

    if ($token =~ /^(?:1-0|0-1|1\/2-1\/2|\*)$/) {
      $result = $token if $result eq '*' || !defined $result;
      last TOKEN;
    }

    my $state_key = canonical_fen_key($state);
    my $candidate = _san_to_candidate($state, $token, $state_key);
    if (!$candidate) {
      warn "Skipping game: could not parse SAN '$token'\n";
      return 0;
    }

    $ply++;
    if ($ply <= $max_plies) {
      my $uci = $candidate->{uci};
      my $stats = ($counts->{$state_key}{$uci} ||= {
        played => 0,
        white  => 0,
        draw   => 0,
        black  => 0,
      });

      $stats->{played}++;
      if ($result eq '1-0') {
        $stats->{white}++;
      } elsif ($result eq '0-1') {
        $stats->{black}++;
      } else {
        $stats->{draw}++;
      }
      $position_totals->{$state_key}++;
    }

    my $next = $state->make_move($candidate->{move});
    if (!defined $next) {
      warn "Skipping game: SAN '$token' produced illegal transition\n";
      return 0;
    }
    $state = $next;

    last TOKEN if $ply >= $max_plies;
  }

  return 1;
}

sub _parse_elo {
  my ($value) = @_;
  return unless defined $value;
  return unless $value =~ /\A\d+(?:\.\d+)?\z/;
  return 0 + $value;
}

sub _tokenize_movetext {
  my ($text) = @_;
  my @tokens;
  my $buf = '';
  my $paren_depth = 0;
  my $brace_depth = 0;
  my $in_line_comment = 0;

  my $source = $text // '';
  my $length = length $source;
  for (my $i = 0; $i < $length; $i++) {
    my $ch = substr($source, $i, 1);
    if ($in_line_comment) {
      if ($ch eq "\n" || $ch eq "\r") {
        $in_line_comment = 0;
      }
      next;
    }
    if ($brace_depth > 0) {
      if ($ch eq '{') {
        $brace_depth++;
      } elsif ($ch eq '}') {
        $brace_depth--;
      }
      next;
    }
    if ($paren_depth > 0) {
      if ($ch eq '(') {
        $paren_depth++;
      } elsif ($ch eq ')') {
        $paren_depth--;
      }
      next;
    }

    if ($ch eq ';') {
      $in_line_comment = 1;
      next;
    }
    if ($ch eq '{') {
      $brace_depth = 1;
      next;
    }
    if ($ch eq '(') {
      $paren_depth = 1;
      next;
    }

    if ($ch =~ /\s/) {
      if (length $buf) {
        push @tokens, $buf;
        $buf = '';
      }
      next;
    }

    $buf .= $ch;
  }

  push @tokens, $buf if length $buf;
  return @tokens;
}

sub _san_to_candidate {
  my ($state, $token, $state_key) = @_;
  my $san = $token // '';
  $san =~ s/^\s+|\s+$//g;
  return unless length $san;

  # Remove common suffix annotations and check/mate markers.
  $san =~ s/[!?]+$//g;
  $san =~ s/[+#]+$//g;
  $san =~ s/\s*e\.p\.?$//i;
  $san =~ tr/0/O/;
  $state_key //= canonical_fen_key($state);
  my $cache_key = defined $state_key ? ($state_key . '|' . uc($san)) : undef;
  if (defined $cache_key && exists $san_candidate_cache{$cache_key}) {
    my $cached_uci = $san_candidate_cache{$cache_key};
    return unless defined $cached_uci && length $cached_uci;
    my $move = $state->encode_move($cached_uci);
    return unless defined $move;
    return { move => $move, uci => $cached_uci };
  }

  my $is_castle_king = ($san eq 'O-O') ? 1 : 0;
  my $is_castle_queen = ($san eq 'O-O-O') ? 1 : 0;

  my $parsed;
  if (!$is_castle_king && !$is_castle_queen) {
    return unless $san =~ /^([KQRBN])?([a-h])?([1-8])?(x)?([a-h][1-8])(?:=?([QRBN]))?$/;
    $parsed = {
      piece => $1 // '',
      from_file => $2,
      from_rank => $3,
      capture => defined($4) ? 1 : 0,
      to => $5,
      promo => $6,
    };
  }

  my @candidates;
  my $move_pool = _state_move_pool_for_key($state, $state_key);

  for my $candidate (@{$move_pool}) {
    if ($is_castle_king || $is_castle_queen) {
      my $target_file = $candidate->{castle_target};
      next unless defined $target_file;
      next if $is_castle_king && $target_file ne 'g';
      next if $is_castle_queen && $target_file ne 'c';
      push @candidates, { move => $candidate->{move}, uci => $candidate->{uci} };
      next;
    }

    next if $parsed->{piece} ne $candidate->{piece_char};
    next if $parsed->{to} ne $candidate->{to};

    if (defined $parsed->{from_file}) {
      next if $candidate->{from_file} ne $parsed->{from_file};
    }
    if (defined $parsed->{from_rank}) {
      next if $candidate->{from_rank} ne $parsed->{from_rank};
    }

    next if $parsed->{capture} != $candidate->{capture};

    if (defined $parsed->{promo}) {
      next unless defined $candidate->{promo_char} && $candidate->{promo_char} eq $parsed->{promo};
    } else {
      next if defined $candidate->{promo_char};
    }

    push @candidates, { move => $candidate->{move}, uci => $candidate->{uci} };
  }

  unless (@candidates) {
    _store_san_candidate_cache($cache_key, '') if defined $cache_key;
    return;
  }
  @candidates = sort { $a->{uci} cmp $b->{uci} } @candidates;
  my $best = $candidates[0];
  _store_san_candidate_cache($cache_key, $best->{uci}) if defined $cache_key;
  return $best;
}

sub _store_san_candidate_cache {
  my ($cache_key, $value) = @_;
  return unless defined $cache_key;
  if (!exists $san_candidate_cache{$cache_key}) {
    $san_candidate_cache_size++;
  }
  $san_candidate_cache{$cache_key} = $value;
  if ($san_candidate_cache_size > $SAN_CANDIDATE_CACHE_MAX) {
    %san_candidate_cache = ();
    $san_candidate_cache_size = 0;
  }
}

sub _state_move_pool_for_key {
  my ($state, $state_key) = @_;
  if (defined $state_key && exists $state_move_pool_cache{$state_key}) {
    return $state_move_pool_cache{$state_key};
  }

  my $board = $state->[Chess::State::BOARD];
  my @pool;

  for my $move (@{ $state->generate_pseudo_moves }) {
    my $next = $state->make_move($move);
    next unless defined $next;

    my $uci = $state->decode_move($move);
    next unless defined $uci && length($uci) >= 4;
    my $from = substr($uci, 0, 2);
    my $to = substr($uci, 2, 2);
    next unless $from =~ /^[a-h][1-8]$/ && $to =~ /^[a-h][1-8]$/;

    my $piece = $board->[ $move->[0] ] // 0;
    my $to_piece = $board->[ $move->[1] ] // 0;
    my $capture = ($to_piece < 0) ? 1 : 0;
    if (!$capture && $piece == PAWN && ($move->[0] % 10) != ($move->[1] % 10)) {
      $capture = 1;
    }

    my $promo_char = defined $move->[2] ? _piece_to_san($move->[2]) : undef;
    my $castle_target = defined $move->[3] ? substr($to, 0, 1) : undef;

    push @pool, {
      move         => $move,
      uci          => $uci,
      to           => $to,
      from_file    => substr($from, 0, 1),
      from_rank    => substr($from, 1, 1),
      piece_char   => _piece_to_san($piece),
      capture      => $capture,
      promo_char   => $promo_char,
      castle_target => $castle_target,
    };
  }

  my $pool_ref = \@pool;
  if (defined $state_key) {
    if (!exists $state_move_pool_cache{$state_key}) {
      $state_move_pool_cache_size++;
    }
    $state_move_pool_cache{$state_key} = $pool_ref;
    if ($state_move_pool_cache_size > $STATE_MOVE_POOL_CACHE_MAX) {
      %state_move_pool_cache = ();
      $state_move_pool_cache_size = 0;
    }
  }

  return $pool_ref;
}

sub _piece_to_san {
  my ($piece) = @_;
  $piece = abs($piece // 0);
  return ''  if $piece == PAWN;
  return 'N' if $piece == KNIGHT;
  return 'B' if $piece == BISHOP;
  return 'R' if $piece == ROOK;
  return 'Q' if $piece == QUEEN;
  return 'K' if $piece == KING;
  return '';
}
