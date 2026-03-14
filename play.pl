#!/usr/bin/env perl
use v5.10;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use IO::Handle;
use IO::Select;
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
$| = 1;
STDOUT->autoflush(1);
STDERR->autoflush(1);

use FindBin qw( $RealBin );
use lib $RealBin;

use Chess::Constant;
use Chess::State;
use Chess::Engine;
use Chess::Book;
use Chess::TableUtil qw(canonical_fen_key);

my $uci_mode = 0;
my $depth = 18;
my $fen;
my $workers = 1;
my $engine_delay_ms = _normalize_delay_ms($ENV{PLAY_ENGINE_DELAY_MS} // 300);
my $book_delay_min_ms = _normalize_delay_ms($ENV{PLAY_BOOK_DELAY_MIN_MS} // 200);
my $book_delay_max_ms = _normalize_delay_ms($ENV{PLAY_BOOK_DELAY_MAX_MS} // 1200);
my %GO_NUMERIC_TOKEN = map { $_ => 1 } qw(
  wtime btime winc binc movestogo movetime depth nodes mate
);
my %GO_FLAG_TOKEN = map { $_ => 1 } qw(ponder infinite);

GetOptions(
  'uci'    => \$uci_mode,
  'depth=i' => \$depth,
  'workers=i' => \$workers,
  'engine-delay-ms=i' => \$engine_delay_ms,
  'fen=s'   => \$fen,
) or die "Usage: $0 [--depth N] [--workers N] [--fen FEN] [--engine-delay-ms MS] [--uci]\n";

$depth = _normalize_depth($depth);
$workers = _normalize_workers($workers);
$engine_delay_ms = _normalize_delay_ms($engine_delay_ms);
($book_delay_min_ms, $book_delay_max_ms) = _normalize_delay_range_ms($book_delay_min_ms, $book_delay_max_ms);

my $state = Chess::State->new($fen);

if ($uci_mode) {
  run_uci($state, $depth, $workers);
  exit 0;
}

run_interactive($state, $depth, $workers, $engine_delay_ms);
exit 0;

sub run_interactive {
  my ($state, $depth, $workers, $engine_delay_ms) = @_;

  my $engine = Chess::Engine->new(
    \$state,
    $depth,
    { workers => $workers },
  );
  my %history;
  my $cached_moves_key;
  my @cached_moves;
  _record_position($state, \%history);

  while ($state->is_playable) {
    print_board($state);

    my $state_key = canonical_fen_key($state);
    if (!defined $cached_moves_key || $cached_moves_key ne $state_key) {
      @cached_moves = $state->get_moves;
      $cached_moves_key = $state_key;
    }

    print "\nAvailable moves:\n";
    foreach my $possible_move (@cached_moves) {
      print " $possible_move\n";
    }

    my $move;
    if (! $state->[Chess::State::TURN]) {
      print "> ";
      my $input = <STDIN>;
      last unless defined $input;
      chomp $input;
      last if lc($input) eq 'quit';
      $move = eval { $state->encode_move($input) };
      unless ($move) {
        warn "Could not parse move '$input'.\n";
        next;
      }
    } else {
      my $think_started_at = time();
      my $book_move = Chess::Book::choose_move($state);
      if ($book_move) {
        my $delay_ms = _random_delay_ms($book_delay_min_ms, $book_delay_max_ms);
        sleep($delay_ms / 1000) if $delay_ms > 0;
        $move = $book_move;
      } else {
        $move = $engine->think(undef, { randomize_ties => 1 });
      }
      my $elapsed_ms = int((time() - $think_started_at) * 1000);
      my $remaining_delay_ms = $engine_delay_ms - $elapsed_ms;
      sleep($remaining_delay_ms / 1000) if $remaining_delay_ms > 0;
      print "> " . $state->decode_move($move) . "\n";
    }

    my $new_state = eval { $state->make_move($move) };
    if (! defined $new_state) {
      warn "Illegal move, try again.\n";
      next;
    }

    $state = $new_state;
    my $status = _record_position($state, \%history);
    if ($status->{force}) {
      print "Forced draw detected ($status->{force}).\n";
      last;
    } elsif ($status->{claim}) {
      print "Draw available ($status->{claim}). Continuing...\n";
    }
  }

  print "Game over. Final FEN: " . $state->get_fen . "\n";
}

sub run_uci {
  my ($state, $depth, $workers) = @_;
  my $debug = 0;
  my $move_overhead_ms = 100;
  my $own_book = 1;
  my $multi_pv = 1;
  my %history;
  _record_position($state, \%history);
  my $selector = IO::Select->new();
  $selector->add(\*STDIN);
  my $active_search;
  my $stdin_buffer = '';

  my $cleanup_active_search = sub {
    return unless $active_search;
    $selector->remove($active_search->{pipe}) if $active_search->{pipe};
    close $active_search->{pipe} if $active_search->{pipe};
    waitpid($active_search->{pid}, 0) if $active_search->{pid};
    $active_search = undef;
  };

  my $finalize_active_search = sub {
    return unless $active_search;
    my $bestmove = $active_search->{final_bestmove};
    $bestmove = $active_search->{last_candidate} unless defined $bestmove;
    $bestmove = $active_search->{stop_fallback} unless defined $bestmove;
    $bestmove = '0000' unless defined $bestmove && $bestmove =~ /^[a-h][1-8][a-h][1-8][nbrq]?$/i;
    print "bestmove $bestmove\n";
    $cleanup_active_search->();
  };

  my $cancel_active_search = sub {
    my ($emit_bestmove, $reason) = @_;
    return unless $active_search;
    my $fallback = $active_search->{last_candidate};
    $fallback = $active_search->{stop_fallback} unless defined $fallback;
    $fallback = '0000' unless defined $fallback && $fallback =~ /^[a-h][1-8][a-h][1-8][nbrq]?$/i;
    kill 'TERM', $active_search->{pid};
    print "info string $reason\n" if $debug && defined $reason && length $reason;
    if ($emit_bestmove) {
      print "bestmove $fallback\n";
    }
    $cleanup_active_search->();
  };

  while (1) {
    my @ready = $selector->can_read(0.05);
    foreach my $fh (@ready) {
      if ($active_search && fileno($fh) == fileno($active_search->{pipe})) {
        my $line = <$fh>;
        if (!defined $line) {
          $finalize_active_search->();
          next;
        }
        $line =~ s/[\r\n]+$//;
        if ($line =~ /^cand\s+(\S+)$/) {
          my $candidate = lc $1;
          if ($candidate =~ /^[a-h][1-8][a-h][1-8][nbrq]?$/) {
            $active_search->{last_candidate} = $candidate;
          }
        } elsif ($line =~ /^done\s+(\S+)$/) {
          my $best = lc $1;
          $active_search->{final_bestmove} = $best;
          $finalize_active_search->();
        }
        next;
      }

      next unless fileno($fh) == fileno(STDIN);
      my $bytes = sysread(STDIN, my $chunk, 4096);
      if (!defined $bytes) {
        next;
      }
      if ($bytes == 0) {
        $cancel_active_search->(0, 'stdin closed while search was active');
        return;
      }
      $stdin_buffer .= $chunk;

      while ($stdin_buffer =~ s/^(.*?)(?:\r?\n)//) {
        my $input = $1;

        if ($input eq 'uci') {
          print "id name PerlGigachess\n";
          print "id author Lolretrorat\n";
          print "option name Depth type spin default $depth min 1 max 20\n";
          print "option name Workers type spin default $workers min 1 max 64\n";
          print "option name MoveOverhead type spin default $move_overhead_ms min 0 max 1000\n";
          print "option name MultiPV type spin default $multi_pv min 1 max 16\n";
          print "option name OwnBook type check default true\n";
          print "uciok\n";
        } elsif ($input =~ m/^debug (on|off)$/) {
          $debug = ($1 eq 'on') ? 1 : 0;
        } elsif ($input =~ m/^setoption name\s+(.+?)(?:\s+value\s+(.+))?$/i) {
          my $name = lc $1;
          $name =~ s/\s+$//;
          my $value = defined $2 ? $2 : '';
          if ($name eq 'depth') {
            my $new_depth = $value =~ /(\d+)/ ? $1 : $depth;
            $depth = _normalize_depth($new_depth);
          } elsif ($name eq 'workers') {
            my $new_workers = $value =~ /(-?\d+)/ ? $1 : $workers;
            $workers = _normalize_workers($new_workers);
          } elsif ($name eq 'moveoverhead') {
            my $new_overhead = $value =~ /(-?\d+)/ ? $1 : $move_overhead_ms;
            $new_overhead = int($new_overhead);
            $new_overhead = 0 if $new_overhead < 0;
            $new_overhead = 1000 if $new_overhead > 1000;
            $move_overhead_ms = $new_overhead;
          } elsif ($name eq 'multipv') {
            my $new_multipv = $value =~ /(-?\d+)/ ? $1 : $multi_pv;
            $multi_pv = _normalize_multipv($new_multipv);
          } elsif ($name eq 'ownbook') {
            my $normalized = lc $value;
            $normalized =~ s/^\s+//;
            $normalized =~ s/\s+$//;
            $own_book = ($normalized eq 'true' || $normalized eq '1') ? 1 : 0;
          }
        } elsif ($input eq 'isready') {
          print "readyok\n";
        } elsif ($input eq 'ucinewgame') {
          $cancel_active_search->(1, 'search cancelled due to ucinewgame') if $active_search;
          $state = Chess::State->new();
          %history = ();
          _record_position($state, \%history);
        } elsif ($input =~ m/^position (.+?)(?: moves (.+))?$/) {
          $cancel_active_search->(1, 'search cancelled due to position update') if $active_search;
          my $position = $1;
          my $moves = $2 || '';

          if ($position eq 'startpos') {
            $position = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
          }
          elsif ($position =~ /^fen\s+(.+)/) {
            $position = $1;
          }

          $state->set_fen($position);
          %history = ();
          _record_position($state, \%history);

          foreach my $temp (split / /, $moves) {
            my $encoded = eval { $state->encode_move($temp) };
            if (! $encoded || $@) {
              print "info string Ignored invalid move token '$temp' while applying position moves; remaining tokens were skipped\n";
              last;
            }
            my $next_state = eval { $state->make_move($encoded) };
            if (! defined $next_state || $@) {
              print "info string Ignored illegal move token '$temp' while applying position moves; remaining tokens were skipped\n";
              last;
            }
            $state = $next_state;
            _record_position($state, \%history);
          }
        } elsif ($input =~ m/^go/) {
          $cancel_active_search->(1, 'search superseded by new go') if $active_search;
          my %go = _parse_go_command($input);
          my ($depth_from_cmd) = $input =~ /\bdepth\s+(-?\d+)/;
          $go{depth} = int($depth_from_cmd) if defined $depth_from_cmd;
          my $stop_fallback = _bestmove_fallback_for_go($state, \%go);

          my ($reader, $writer);
          if (!pipe($reader, $writer)) {
            print "info string Failed to start asynchronous search worker\n";
            print "bestmove 0000\n";
            next;
          }
          my $pid = fork();
          if (!defined $pid) {
            close $reader;
            close $writer;
            print "info string Failed to fork asynchronous search worker\n";
            print "bestmove 0000\n";
            next;
          }
          if ($pid == 0) {
            close $reader;
            $writer->autoflush(1);
            local $SIG{TERM} = sub { exit 0; };
            my $bestmove = '0000';
            my $ok = eval {
              $bestmove = _run_uci_go_search(
                state => $state,
                history => \%history,
                depth => $depth,
                workers => $workers,
                move_overhead_ms => $move_overhead_ms,
                own_book => $own_book,
                multi_pv => $multi_pv,
                go => \%go,
                report_fh => $writer,
              );
              1;
            };
            if (!$ok) {
              print "info string Search worker failed: $@\n";
              $bestmove = '0000';
            }
            $bestmove = '0000' unless defined $bestmove && $bestmove =~ /^[a-h][1-8][a-h][1-8][nbrq]?$/i;
            print {$writer} "done $bestmove\n";
            close $writer;
            exit 0;
          }
          close $writer;
          $reader->autoflush(1);
          $selector->add($reader);
          $active_search = {
            pid => $pid,
            pipe => $reader,
            last_candidate => undef,
            final_bestmove => undef,
            stop_fallback => $stop_fallback,
          };
        } elsif ($input eq 'stop') {
          if ($active_search) {
            $cancel_active_search->(1, 'stop acknowledged');
          } else {
            print "info string stop acknowledged (no active search)\n" if $debug;
          }
        } elsif ($input eq 'ponderhit') {
          print "info string ponderhit acknowledged (ponder mode unsupported in this build)\n" if $debug;
        } elsif ($input eq 'quit') {
          $cancel_active_search->(0, 'search cancelled due to quit') if $active_search;
          exit 0;
        } else {
          print "unknown command '$input'\n" if $debug;
        }
      }
    }

    if ($active_search) {
      my $pid = waitpid($active_search->{pid}, WNOHANG);
      if ($pid > 0 && !defined $active_search->{final_bestmove}) {
        $finalize_active_search->();
      }
    }
  }
}

sub _run_uci_go_search {
  my %args = @_;
  my $state = $args{state};
  my $history = $args{history};
  my $depth = $args{depth};
  my $workers = $args{workers};
  my $move_overhead_ms = $args{move_overhead_ms};
  my $own_book = $args{own_book};
  my $multi_pv = $args{multi_pv};
  my $go = $args{go} || {};
  my $report_fh = $args{report_fh};

  my $status = _current_draw_status($state, $history);
  if ($status->{force}) {
    print "info string Forced draw reached ($status->{force}); returning bestmove 0000\n";
    return '0000';
  } elsif ($status->{claim}) {
    print "info string Draw can be claimed now ($status->{claim})\n";
  }

  my ($allowed_moves, $allowed_uci_set, $has_searchmoves) = _resolve_searchmoves_filter($state, $go->{searchmoves});
  if ($has_searchmoves && !@{$allowed_moves}) {
    print "info string No legal moves from searchmoves filter; returning bestmove 0000\n";
    return '0000';
  }
  if ($has_searchmoves && @{$allowed_moves} == 1) {
    my $forced_uci = _decode_pv_move($state, $allowed_moves->[0]) // '0000';
    print "info string searchmoves narrowed root to a single legal move: $forced_uci\n";
    _report_search_candidate($report_fh, $forced_uci);
    return $forced_uci;
  }
  if (!$has_searchmoves && $own_book) {
    my $book_move = Chess::Book::choose_move($state);
    if ($book_move) {
      my $delay_ms = _random_delay_ms($book_delay_min_ms, $book_delay_max_ms);
      sleep($delay_ms / 1000) if $delay_ms > 0;
      my $book_uci = _decode_pv_move($state, $book_move) // '0000';
      _report_search_candidate($report_fh, $book_uci);
      return $book_uci;
    }
  }

  my $go_depth = defined $go->{depth} ? _normalize_depth($go->{depth}) : $depth;
  my $engine = Chess::Engine->new(
    \$state,
    $go_depth,
    { workers => $workers },
  );
  my %time_args = (
    move_overhead_ms => $move_overhead_ms,
  );
  $time_args{strict_depth} = 1 if defined $go->{depth};
  if (defined $go->{movetime}) {
    $time_args{movetime_ms} = $go->{movetime};
  } else {
    my $remaining_ms = $state->[Chess::State::TURN] ? $go->{btime} : $go->{wtime};
    my $increment_ms = $state->[Chess::State::TURN] ? $go->{binc} : $go->{winc};
    $time_args{remaining_ms} = $remaining_ms if defined $remaining_ms;
    $time_args{increment_ms} = $increment_ms if defined $increment_ms;
    $time_args{movestogo} = $go->{movestogo} if defined $go->{movestogo};
  }
  $time_args{multipv} = $multi_pv;
  $time_args{use_book} = ($has_searchmoves || defined $go->{depth}) ? 0 : $own_book;

  my $critical_mate_logged = 0;
  my $critical_swing_logged = 0;
  my $last_cp_for_swing;
  my @latest_pv_lines;
  my $on_think_update = sub {
    my ($cur_depth, $cur_score, $candidate_move, $update) = @_;
    my @pv_lines = _build_uci_pv_lines($state, $cur_score, $candidate_move, $update, $multi_pv);
    return unless @pv_lines;
    @latest_pv_lines = @pv_lines;
    _emit_uci_pv_info_lines($cur_depth, \@pv_lines, $multi_pv);
    my $best_line = $pv_lines[0];
    my $candidate_uci = $best_line->{pv}[0] // '0000';
    my ($score_kind, $score_value) = _uci_score_tokens($best_line->{score});
    my $eval_label = $score_kind eq 'mate'
      ? "mate $score_value"
      : _signed_cp($score_value);
    print "info string depth $cur_depth, candidate $candidate_uci, eval $eval_label\n";

    my $candidate_for_stop = $candidate_uci;
    if ($has_searchmoves && !$allowed_uci_set->{lc $candidate_uci}) {
      my $fallback_move = _pick_searchmove_fallback($state, \@pv_lines, $allowed_uci_set, $allowed_moves);
      my $fallback_uci = _decode_pv_move($state, $fallback_move);
      $candidate_for_stop = $fallback_uci if defined $fallback_uci;
    }
    _report_search_candidate($report_fh, $candidate_for_stop);

    if ($score_kind eq 'mate' && !$critical_mate_logged) {
      my $mate_desc = $score_value > 0
        ? "mate in $score_value"
        : "opponent mate in " . abs($score_value);
      print "info string Critical position: forcing line detected ($mate_desc); prioritizing tactical accuracy\n";
      $critical_mate_logged = 1;
    } elsif ($score_kind eq 'cp') {
      if (defined $last_cp_for_swing && !$critical_swing_logged) {
        my $swing = abs($score_value - $last_cp_for_swing);
        if ($cur_depth >= 6 && $swing >= 120) {
          print "info string Critical position: eval swing " . _signed_cp($last_cp_for_swing)
            . " to " . _signed_cp($score_value)
            . " cp at depth $cur_depth; reassessing tactical stability\n";
          $critical_swing_logged = 1;
        }
      }
      $last_cp_for_swing = $score_value;
    }
  };

  my ($move, $score, $searched_depth) = $engine->think($on_think_update, \%time_args);
  if (!defined $move) {
    $move = $allowed_moves->[0] if $has_searchmoves && @{$allowed_moves};
    return '0000' unless defined $move;
  }

  if ($has_searchmoves) {
    my $chosen_uci = _decode_pv_move($state, $move);
    if (!defined $chosen_uci || !$allowed_uci_set->{lc $chosen_uci}) {
      my $replacement = _pick_searchmove_fallback($state, \@latest_pv_lines, $allowed_uci_set, $allowed_moves);
      my $replacement_uci = _decode_pv_move($state, $replacement);
      if (defined $replacement_uci) {
        print "info string searchmoves filter replaced out-of-set candidate with $replacement_uci\n";
      }
      $move = $replacement if defined $replacement;
    }
  }

  if (defined $score && defined $searched_depth) {
    my @final_pv_lines = @latest_pv_lines;
    if (!@final_pv_lines) {
      @final_pv_lines = _build_uci_pv_lines($state, $score, $move, undef, $multi_pv);
    }
    if (@final_pv_lines) {
      _emit_uci_pv_info_lines($searched_depth, \@final_pv_lines, $multi_pv);
    } else {
      my ($score_kind, $score_value) = _uci_score_tokens($score);
      print "info depth $searched_depth score $score_kind $score_value\n";
    }
    my ($score_kind, $score_value) = _uci_score_tokens($score);
    my $best_uci = _decode_pv_move($state, $move) // '0000';
    if ($score_kind eq 'mate') {
      my $mate_desc = $score_value > 0
        ? "mate in $score_value"
        : "opponent mate in " . abs($score_value);
      print "info string Critical position decision: selecting $best_uci with $mate_desc at depth $searched_depth\n";
    } elsif (abs($score_value) >= 250) {
      print "info string Critical position decision: selecting $best_uci with eval " . _signed_cp($score_value)
        . " cp at depth $searched_depth\n";
    }
  }

  my $bestmove = _decode_pv_move($state, $move);
  $bestmove = '0000' unless defined $bestmove && length $bestmove;
  _report_search_candidate($report_fh, $bestmove);
  return $bestmove;
}

sub _uci_score_tokens {
  my ($score) = @_;
  my $cp = int($score // 0);
  my $mate_score = _mate_score_from_cp($cp);
  if (defined $mate_score) {
    return ('mate', $mate_score);
  }
  return ('cp', $cp);
}

sub _mate_score_from_cp {
  my ($cp) = @_;
  return unless defined $cp;
  my $mate_base = Chess::Engine::MATE_SCORE();
  my $abs_cp = abs(int($cp));
  my $distance = $mate_base - $abs_cp;
  return if $distance < 0 || $distance > 256;
  my $mate_moves = int(($distance + 1) / 2);
  $mate_moves = 1 if $mate_moves < 1;
  return $cp >= 0 ? $mate_moves : -$mate_moves;
}

sub _signed_cp {
  my ($cp) = @_;
  return '+0' unless defined $cp;
  my $v = int($cp);
  return sprintf('%+d', $v);
}

sub _normalize_multipv {
  my ($value) = @_;
  $value = 1 unless defined $value && $value =~ /^-?\d+$/;
  $value = int($value);
  $value = 1 if $value < 1;
  $value = 16 if $value > 16;
  return $value;
}

sub _decode_pv_move {
  my ($state, $mv) = @_;
  return unless defined $mv;
  return $mv if !ref($mv) && $mv =~ /^[a-h][1-8][a-h][1-8][nbrq]?$/i;
  return unless ref($mv) eq 'ARRAY';
  my $uci = eval { $state->decode_move($mv) };
  return unless defined $uci && $uci =~ /^[a-h][1-8][a-h][1-8][nbrq]?$/i;
  return $uci;
}

sub _build_uci_pv_lines {
  my ($state, $cur_score, $candidate_move, $update, $multi_pv) = @_;
  my $limit = _normalize_multipv($multi_pv);
  my @lines;

  if (ref($update) eq 'HASH' && ref($update->{pv_lines}) eq 'ARRAY') {
    for my $raw (@{$update->{pv_lines}}) {
      next unless ref($raw) eq 'HASH';
      my $pv_ref = $raw->{pv};
      next unless ref($pv_ref) eq 'ARRAY';
      my @pv_uci;
      my $cursor_state = $state;
      for my $move (@{$pv_ref}) {
        last unless defined $cursor_state;
        my $uci = _decode_pv_move($cursor_state, $move);
        last unless defined $uci;
        push @pv_uci, $uci;
        last unless ref($move) eq 'ARRAY';
        my $next_state = $cursor_state->make_move($move);
        last unless defined $next_state;
        $cursor_state = $next_state;
      }
      next unless @pv_uci;
      push @lines, {
        multipv => int($raw->{multipv} // (scalar(@lines) + 1)),
        score => int($raw->{score} // $cur_score // 0),
        pv => \@pv_uci,
      };
      last if @lines >= $limit;
    }
  }

  if (!@lines && defined $candidate_move) {
    my $candidate_uci = _decode_pv_move($state, $candidate_move);
    if (defined $candidate_uci) {
      push @lines, {
        multipv => 1,
        score => int($cur_score // 0),
        pv => [ $candidate_uci ],
      };
    }
  }

  return @lines;
}

sub _emit_uci_pv_info_lines {
  my ($depth, $pv_lines, $multi_pv) = @_;
  return unless ref($pv_lines) eq 'ARRAY' && @{$pv_lines};
  my $limit = _normalize_multipv($multi_pv);
  my $count = 0;

  for my $line (@{$pv_lines}) {
    next unless ref($line) eq 'HASH';
    my $pv = $line->{pv};
    next unless ref($pv) eq 'ARRAY' && @{$pv};
    my $score = int($line->{score} // 0);
    my ($score_kind, $score_value) = _uci_score_tokens($score);
    my $mpv = int($line->{multipv} // ($count + 1));
    $mpv = 1 if $mpv < 1;
    print "info depth $depth multipv $mpv score $score_kind $score_value pv " . join(' ', @{$pv}) . "\n";
    $count++;
    last if $count >= $limit;
  }
}

sub print_board {
  my ($state) = @_;

  print "FEN: " . $state->get_fen . "\n";

  my @board = $state->get_board;
  print "+-+-+-+-+-+-+-+-+\n";
  for my $rank (0 .. 7) {
    for my $file (0 .. 7) {
      my $piece = $board[7 - $rank][$file];
      printf("|%1s", $piece ? $p2l{$piece} : ' ');
    }
    printf("|%d\n", 8 - $rank);
    print "+-+-+-+-+-+-+-+-+\n";
  }
  print " a b c d e f g h\n";
}

sub _record_position {
  my ($state, $history) = @_;
  my $key = canonical_fen_key($state);
  my $count = ++$history->{$key};
  return _current_draw_status($state, $history, $count, $key);
}

sub _current_draw_status {
  my ($state, $history, $count_override, $key_override) = @_;
  my $key = defined $key_override ? $key_override : canonical_fen_key($state);
  my $count = defined $count_override ? $count_override : ($history->{$key} // 0);
  my $halfmove = $state->[Chess::State::HALFMOVE] // 0;

  my @claim;
  push @claim, 'threefold repetition' if $count >= 3;
  push @claim, '50-move rule' if $halfmove >= 100;

  my @force;
  push @force, 'fourfold repetition' if $count >= 4;
  push @force, '60-move rule' if $halfmove >= 120;

  return {
    claim => @claim ? join(' and ', @claim) : undef,
    force => @force ? join(' and ', @force) : undef,
  };
}

sub _normalize_depth {
  my ($value) = @_;
  $value = 1 unless defined $value && $value =~ /\d/;
  $value = int($value);
  $value = 1 if $value < 1;
  $value = 20 if $value > 20;
  return $value;
}

sub _normalize_delay_ms {
  my ($value) = @_;
  $value = 0 unless defined $value && $value =~ /^-?\d+$/;
  $value = int($value);
  $value = 0 if $value < 0;
  $value = 5000 if $value > 5000;
  return $value;
}

sub _normalize_delay_range_ms {
  my ($min_ms, $max_ms) = @_;
  $min_ms = _normalize_delay_ms($min_ms);
  $max_ms = _normalize_delay_ms($max_ms);
  if ($max_ms < $min_ms) {
    my $tmp = $max_ms;
    $max_ms = $min_ms;
    $min_ms = $tmp;
  }
  return ($min_ms, $max_ms);
}

sub _random_delay_ms {
  my ($min_ms, $max_ms) = @_;
  ($min_ms, $max_ms) = _normalize_delay_range_ms($min_ms, $max_ms);
  return $min_ms if $max_ms <= $min_ms;
  return $min_ms + int(rand($max_ms - $min_ms + 1));
}

sub _normalize_workers {
  my ($value) = @_;
  $value = 1 unless defined $value && $value =~ /^-?\d+$/;
  $value = int($value);
  $value = 1 if $value < 1;
  $value = 64 if $value > 64;
  return $value;
}

sub _report_search_candidate {
  my ($fh, $candidate_uci) = @_;
  return unless $fh;
  return unless defined $candidate_uci && $candidate_uci =~ /^[a-h][1-8][a-h][1-8][nbrq]?$/i;
  print {$fh} "cand " . lc($candidate_uci) . "\n";
}

sub _resolve_searchmoves_filter {
  my ($state, $tokens_ref) = @_;
  return ([], {}, 0) unless ref($tokens_ref) eq 'ARRAY' && @{$tokens_ref};
  my %legal_by_uci;
  foreach my $uci ($state->get_moves) {
    next unless defined $uci;
    my $norm = lc $uci;
    next unless $norm =~ /^[a-h][1-8][a-h][1-8][nbrq]?$/;
    my $encoded = eval { $state->encode_move($norm) };
    next unless $encoded && ref($encoded) eq 'ARRAY';
    $legal_by_uci{$norm} = $encoded;
  }

  my @allowed_moves;
  my %allowed_uci_set;
  foreach my $token (@{$tokens_ref}) {
    next unless defined $token;
    my $norm = lc $token;
    next unless $norm =~ /^[a-h][1-8][a-h][1-8][nbrq]?$/;
    next unless exists $legal_by_uci{$norm};
    next if $allowed_uci_set{$norm};
    $allowed_uci_set{$norm} = 1;
    push @allowed_moves, $legal_by_uci{$norm};
  }

  return (\@allowed_moves, \%allowed_uci_set, 1);
}

sub _bestmove_fallback_for_go {
  my ($state, $go) = @_;
  $go ||= {};

  my ($allowed_moves, undef, $has_searchmoves) = _resolve_searchmoves_filter($state, $go->{searchmoves});
  if ($has_searchmoves) {
    return '0000' unless @{$allowed_moves};
    my $forced_uci = _decode_pv_move($state, $allowed_moves->[0]);
    return defined $forced_uci ? $forced_uci : '0000';
  }

  my @legal = $state->generate_moves;
  return '0000' unless @legal;
  my $uci = _decode_pv_move($state, $legal[0]);
  return defined $uci ? $uci : '0000';
}

sub _pick_searchmove_fallback {
  my ($state, $pv_lines, $allowed_uci_set, $allowed_moves) = @_;
  if (ref($pv_lines) eq 'ARRAY') {
    foreach my $line (@{$pv_lines}) {
      next unless ref($line) eq 'HASH';
      my $pv = $line->{pv};
      next unless ref($pv) eq 'ARRAY' && @{$pv};
      my $candidate_uci = lc($pv->[0] // '');
      next unless $candidate_uci =~ /^[a-h][1-8][a-h][1-8][nbrq]?$/;
      next unless $allowed_uci_set->{$candidate_uci};
      my $encoded = eval { $state->encode_move($candidate_uci) };
      return $encoded if $encoded && ref($encoded) eq 'ARRAY';
    }
  }
  return $allowed_moves->[0] if ref($allowed_moves) eq 'ARRAY' && @{$allowed_moves};
  return;
}

sub _parse_go_command {
  my ($input) = @_;
  my %go;
  my @tokens = split /\s+/, $input;
  shift @tokens; # consume 'go'

  while (@tokens) {
    my $token = shift @tokens;
    if ($GO_NUMERIC_TOKEN{$token}) {
      last unless @tokens;
      my $value = shift @tokens;
      next unless defined $value && $value =~ /^-?\d+$/;
      $go{$token} = int($value);
    } elsif ($GO_FLAG_TOKEN{$token}) {
      $go{$token} = 1;
    } elsif ($token eq 'searchmoves') {
      my @searchmoves;
      while (@tokens) {
        my $move_token = shift @tokens;
        next unless defined $move_token && length $move_token;
        push @searchmoves, $move_token;
      }
      $go{searchmoves} = \@searchmoves if @searchmoves;
      last;
    }
  }

  return %go;
}
