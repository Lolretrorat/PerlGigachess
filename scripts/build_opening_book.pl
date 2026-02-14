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
my $min_position_games = 5;
my $min_move_games = 2;
my $progress_every = 0;
my $append_existing = 0;

GetOptions(
  'output=s' => \$output,
  'max-plies=i' => \$max_plies,
  'max-games=i' => \$max_games,
  'min-position-games=i' => \$min_position_games,
  'min-move-games=i' => \$min_move_games,
  'progress-every=i' => \$progress_every,
  'append-existing!' => \$append_existing,
) or die "Usage: $0 [--output PATH] [--max-plies N] [--max-games N] [--min-position-games N] [--min-move-games N] [--progress-every N] [--[no-]append-existing] [inputs...]\n";

die "--max-plies must be >= 1\n" unless $max_plies >= 1;
die "--max-games must be >= 0\n" unless $max_games >= 0;
$min_position_games = 1 if $min_position_games < 1;
$min_move_games = 1 if $min_move_games < 1;
$progress_every = 0 if !defined $progress_every || $progress_every < 0;

my @inputs = @ARGV;

my %counts;
my %position_totals;
my $parsed_games = 0;
my $processed_games = 0;
my $stop_parsing = 0;

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
  for my $uci (keys %{ $counts{$key} }) {
    my $stats = $counts{$key}{$uci};
    my $played = $stats->{played} // 0;
    next if $played < $min_move_games;
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

  push @entries, { key => $key, moves => \@moves };
}

@entries = sort {
  (_entry_total_played($b) <=> _entry_total_played($a))
    || ($a->{key} cmp $b->{key})
} @entries;

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

sub _entry_total_played {
  my ($entry) = @_;
  my $sum = 0;
  for my $move (@{ $entry->{moves} || [] }) {
    $sum += $move->{played} // 0;
  }
  return $sum;
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
  my $path = $ENV{PATH} // '';
  for my $dir (split /:/, $path) {
    next unless length $dir;
    my $full = "$dir/$cmd";
    return 1 if -x $full;
  }
  return 0;
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
  my ($headers, $movetext, $counts, $position_totals, $max_plies) = @_;
  my $result = $headers->{Result} // '*';

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

    my $candidate = _san_to_candidate($state, $token);
    if (!$candidate) {
      warn "Skipping game: could not parse SAN '$token'\n";
      return 0;
    }

    $ply++;
    if ($ply <= $max_plies) {
      my $key = canonical_fen_key($state);
      my $uci = $candidate->{uci};
      my $stats = ($counts->{$key}{$uci} ||= {
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
      $position_totals->{$key}++;
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

sub _tokenize_movetext {
  my ($text) = @_;
  my @tokens;
  my $buf = '';
  my $paren_depth = 0;
  my $brace_depth = 0;
  my $in_line_comment = 0;

  my @chars = split //, ($text // '');
  for my $ch (@chars) {
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
  my ($state, $token) = @_;
  my $san = $token // '';
  $san =~ s/^\s+|\s+$//g;
  return unless length $san;

  # Remove common suffix annotations and check/mate markers.
  $san =~ s/[!?]+$//g;
  $san =~ s/[+#]+$//g;
  $san =~ s/\s*e\.p\.?$//i;
  $san =~ tr/0/O/;

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

  my $board = $state->[Chess::State::BOARD];
  my @candidates;

  for my $move (@{ $state->generate_pseudo_moves }) {
    my $next = $state->make_move($move);
    next unless defined $next;

    my $uci = $state->decode_move($move);
    my $from = substr($uci, 0, 2);
    my $to = substr($uci, 2, 2);
    next unless $from =~ /^[a-h][1-8]$/ && $to =~ /^[a-h][1-8]$/;

    my $piece = $board->[ $move->[0] ] // 0;
    my $piece_char = _piece_to_san($piece);
    my $to_piece = $board->[ $move->[1] ] // 0;
    my $capture = ($to_piece < 0) ? 1 : 0;
    if (!$capture && $piece == PAWN && ($move->[0] % 10) != ($move->[1] % 10)) {
      $capture = 1; # en-passant capture to empty square
    }
    my $promo_char = defined $move->[2] ? _piece_to_san($move->[2]) : undef;

    if ($is_castle_king || $is_castle_queen) {
      next unless defined $move->[3];
      my $target_file = substr($to, 0, 1);
      next if $is_castle_king && $target_file ne 'g';
      next if $is_castle_queen && $target_file ne 'c';
      push @candidates, { move => $move, uci => $uci };
      next;
    }

    next if $parsed->{piece} ne $piece_char;
    next if $parsed->{to} ne $to;

    if (defined $parsed->{from_file}) {
      next if substr($from, 0, 1) ne $parsed->{from_file};
    }
    if (defined $parsed->{from_rank}) {
      next if substr($from, 1, 1) ne $parsed->{from_rank};
    }

    next if $parsed->{capture} != $capture;

    if (defined $parsed->{promo}) {
      next unless defined $promo_char && $promo_char eq $parsed->{promo};
    } else {
      next if defined $promo_char;
    }

    push @candidates, { move => $move, uci => $uci };
  }

  return unless @candidates;
  @candidates = sort { $a->{uci} cmp $b->{uci} } @candidates;
  return $candidates[0];
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
