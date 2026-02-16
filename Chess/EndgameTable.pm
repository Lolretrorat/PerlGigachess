package Chess::EndgameTable;
use strict;
use warnings;

use Chess::Constant;
use Chess::State ();
use File::Basename qw(dirname);
use File::Spec;
use IPC::Open2;
use JSON::PP;
use Chess::TableUtil qw(
  canonical_fen_key
  relaxed_fen_key
  normalize_uci_move
  merge_weighted_moves
  board_indices
);

my %table;
my %relaxed_table;
my %syzygy_cache;
my %syzygy_failure_backoff_until;
my %legal_move_details_cache;
my $table_path_cache;
my $default_probe_script_path_cache;
my $probe_script_path_cache;
my $probe_script_override_key;
my $syzygy_paths_raw_cache;
my @syzygy_path_tokens_cache;
my %env_bool_cache;
my %env_int_cache;
my $syzygy_probe_worker;
my $syzygy_probe_worker_backoff_until = 0;
my $SYZYGY_CACHE_MAX = 20_000;
my $SYZYGY_BACKOFF_CACHE_MAX = 20_000;

my %syzygy_wdl_rank = (
  2  => 5_000_000,  # win
  1  => 4_000_000,  # cursed win
  0  => 3_000_000,  # draw
  -1 => 2_000_000,  # blessed loss
  -2 => 1_000_000,  # loss
);

sub _table_path {
  return $table_path_cache if defined $table_path_cache;
  my $module_dir = dirname(__FILE__);
  my $root = File::Spec->catdir($module_dir, '..');
  $table_path_cache = File::Spec->catfile($root, 'data', 'endgame_table.json');
  return $table_path_cache;
}

sub _load_tables {
  %table = ();
  %relaxed_table = ();

  my $path = _table_path();
  return unless defined $path && -e $path;

  my $json_text = do {
    open my $fh, '<', $path or return;
    local $/;
    my $raw = <$fh>;
    close $fh;
    $raw;
  };

  my $data = eval { JSON::PP->new->relaxed->decode($json_text) };
  return if $@ || ref $data ne 'ARRAY';

  foreach my $entry (@$data) {
    next unless ref $entry eq 'HASH';
    my $key = $entry->{key} || next;
    my $relaxed = relaxed_fen_key($key);
    my $moves = $entry->{moves} || [];
    my %by_uci;
    foreach my $move (@$moves) {
      if (ref $move eq 'HASH') {
        my $uci = normalize_uci_move($move->{uci});
        next unless defined $uci;
        my $weight = $move->{weight};
        $weight = 1 unless defined $weight && $weight =~ /-?\d+(?:\.\d+)?/;
        $weight += 0;
        $weight = 1 if $weight <= 0;

        my $rank = $move->{rank};
        $rank = $weight unless defined $rank && $rank =~ /-?\d+(?:\.\d+)?/;
        $rank += 0;

        if (exists $by_uci{$uci}) {
          $by_uci{$uci}{weight} += $weight;
          $by_uci{$uci}{rank} = $rank if $rank > $by_uci{$uci}{rank};
        } else {
          $by_uci{$uci} = { uci => $uci, weight => $weight, rank => $rank };
        }
      } elsif (! ref $move) {
        my $uci = normalize_uci_move($move);
        next unless defined $uci;
        if (exists $by_uci{$uci}) {
          $by_uci{$uci}{weight} += 1;
        } else {
          $by_uci{$uci} = { uci => $uci, weight => 1, rank => 1 };
        }
      }
    }
    next unless %by_uci;

    my @parsed = sort {
      $b->{rank} <=> $a->{rank} || $b->{weight} <=> $a->{weight}
    } values %by_uci;

    merge_weighted_moves(\%table, $key, \@parsed, { with_rank => 1 });
    merge_weighted_moves(\%relaxed_table, $relaxed, \@parsed, { with_rank => 1 }) if defined $relaxed;
  }
}

sub choose_move {
  my ($state) = @_;
  my $legal;
  my $syzygy_entries = tablebase_entries($state);
  if ($syzygy_entries && @$syzygy_entries) {
    $legal ||= _legal_move_details($state);
    my $syzygy_move = _choose_ranked_table_move($state, $syzygy_entries, $legal);
    return $syzygy_move if $syzygy_move;
  }

  my $key = canonical_fen_key($state);
  my $entries = $table{$key};
  if (! $entries) {
    my $relaxed = relaxed_fen_key($key);
    $entries = $relaxed_table{$relaxed} if defined $relaxed;
  }

  if ($entries && @$entries) {
    $legal ||= _legal_move_details($state);
    my $move = _choose_ranked_table_move($state, $entries, $legal);
    return $move if $move;
  }

  my $fallback = _choose_simple_mating_move($state, $legal);
  return $fallback if $fallback;
  return;
}

sub tablebase_entries {
  my ($state) = @_;
  return unless _env_bool('CHESS_SYZYGY_ENABLED', 1);
  return unless _piece_count($state) <= _env_int('CHESS_SYZYGY_MAX_PIECES', 7, 2, 16);

  my @tb_paths = _syzygy_paths();
  return unless @tb_paths;
  my $probe_sig = _syzygy_probe_signature(\@tb_paths);

  my $key = canonical_fen_key($state);
  my $cache_key = _syzygy_cache_key($key, $probe_sig);
  return if _in_syzygy_failure_backoff($cache_key);

  my $ttl = _env_int('CHESS_SYZYGY_CACHE_TTL', 30 * 24 * 3600, 0);
  if ($ttl > 0) {
    my $entry = $syzygy_cache{$cache_key};
    if (ref $entry eq 'HASH') {
      my $age = time() - ($entry->{ts} // 0);
      if ($age <= $ttl && ref $entry->{data} eq 'ARRAY') {
        return $entry->{data};
      }
    }
  }

  my $fen = $state->get_fen;
  my $payload = _probe_syzygy($fen, \@tb_paths);
  if (! $payload || ref $payload ne 'HASH' || ref $payload->{moves} ne 'ARRAY') {
    _mark_syzygy_failure($cache_key);
    return;
  }

  my @entries;
  foreach my $move (@{$payload->{moves}}) {
    next unless ref $move eq 'HASH';
    my $uci = normalize_uci_move($move->{uci});
    next unless defined $uci;

    my $wdl = _numeric_or($move->{wdl}, -3);
    my $rank = $syzygy_wdl_rank{$wdl} // 0;
    my $dtz = _maybe_numeric($move->{dtz});
    my $dtm = _maybe_numeric($move->{dtm});

    if (defined $dtz) {
      my $clamped = $dtz > 400 ? 400 : $dtz;
      if ($wdl > 0) {
        $rank += (400 - $clamped) * 10;
      } elsif ($wdl < 0) {
        $rank += $clamped * 10;
      } else {
        $rank += (400 - $clamped);
      }
    }
    if (defined $dtm) {
      my $clamped = $dtm > 600 ? 600 : $dtm;
      $rank += ($wdl > 0) ? (600 - $clamped) : $clamped;
    }

    my $weight = _numeric_or($move->{weight}, 1);
    $weight = 1 if $weight < 1;

    push @entries, {
      uci    => $uci,
      rank   => $rank,
      weight => $weight,
    };
  }

  @entries = sort {
    $b->{rank} <=> $a->{rank} || $b->{weight} <=> $a->{weight}
  } @entries;

  if (scalar(keys %syzygy_cache) >= $SYZYGY_CACHE_MAX) {
    %syzygy_cache = ();
  }
  $syzygy_cache{$cache_key} = {
    ts   => time(),
    data => \@entries,
  };
  return \@entries;
}

sub _choose_ranked_table_move {
  my ($state, $entries, $legal) = @_;
  $legal ||= _legal_move_details($state);
  return unless keys %{$legal};

  my $best_move;
  my $best_score;
  foreach my $entry (@$entries) {
    next unless ref $entry eq 'HASH';
    my $uci = $entry->{uci} // next;
    my $detail = $legal->{$uci} or next;
    my $rank = $entry->{rank} // $entry->{weight} // 0;

    # Tablebase preference:
    # first use table rank, then tie-break by restricting the opponent.
    my $score = 1_000_000 * $rank;
    $score += 500_000 if $detail->{mate};
    $score += 5_000 if $detail->{gives_check};
    $score -= 25 * $detail->{opp_moves};
    $score -= 100 * $detail->{opp_captures};
    $score += $entry->{weight} // 0;

    if (!defined $best_score || $score > $best_score) {
      $best_score = $score;
      $best_move = $detail->{move};
    }
  }

  return $best_move;
}

sub _choose_simple_mating_move {
  my ($state, $legal) = @_;
  return unless _is_basic_mating_material($state);

  $legal ||= _legal_move_details($state);
  return unless keys %{$legal};

  my $best_move;
  my $best_score;
  foreach my $detail (values %{$legal}) {
    my $score = 0;
    $score += 500_000 if $detail->{mate};
    $score += 5_000 if $detail->{gives_check};
    $score -= 30 * $detail->{opp_moves};
    $score -= 120 * $detail->{opp_captures};
    if (!defined $best_score || $score > $best_score) {
      $best_score = $score;
      $best_move = $detail->{move};
    }
  }

  return $best_move;
}

sub _is_basic_mating_material {
  my ($state) = @_;
  my $board = $state->[Chess::State::BOARD];

  my ($friendly_king, $enemy_king, $friendly_queen, $friendly_rook, $other_friendly, $enemy_other) = (0, 0, 0, 0, 0, 0);
  foreach my $idx (board_indices()) {
    my $piece = $board->[$idx] // 0;
    next unless $piece;
    if ($piece > 0) {
      if ($piece == KING) {
        $friendly_king++;
      } elsif ($piece == QUEEN) {
        $friendly_queen++;
      } elsif ($piece == ROOK) {
        $friendly_rook++;
      } else {
        $other_friendly++;
      }
    } else {
      if ($piece == OPP_KING) {
        $enemy_king++;
      } else {
        $enemy_other++;
      }
    }
  }

  return 0 unless $friendly_king == 1 && $enemy_king == 1;
  return 0 unless $enemy_other == 0;
  return 1 if $friendly_queen == 1 && $friendly_rook == 0 && $other_friendly == 0;
  return 1 if $friendly_rook == 1 && $friendly_queen == 0 && $other_friendly == 0;
  return 0;
}

sub _legal_move_details {
  my ($state) = @_;
  my $state_key = canonical_fen_key($state);
  if (defined $state_key && exists $legal_move_details_cache{$state_key}) {
    return $legal_move_details_cache{$state_key};
  }

  my %details;
  foreach my $move (@{$state->generate_pseudo_moves}) {
    my $new_state = $state->make_move($move);
    next unless defined $new_state;

    my $uci = normalize_uci_move($state->decode_move($move));
    next unless defined $uci;

    my $opp_moves = 0;
    my $opp_captures = 0;
    foreach my $opp_move (@{$new_state->generate_pseudo_moves}) {
      my $reply = $new_state->make_move($opp_move);
      next unless defined $reply;
      $opp_moves++;
      my $target = $new_state->[Chess::State::BOARD][$opp_move->[1]] // 0;
      $opp_captures++ if $target < 0;
    }
    my $gives_check = $new_state->is_checked ? 1 : 0;

    $details{$uci} = {
      move => $move,
      opp_moves => $opp_moves,
      opp_captures => $opp_captures,
      gives_check => $gives_check,
      mate => (($opp_moves == 0 && $gives_check) ? 1 : 0),
    };
  }
  my $result = \%details;
  if (defined $state_key) {
    if (scalar(keys %legal_move_details_cache) >= 20_000) {
      %legal_move_details_cache = ();
    }
    $legal_move_details_cache{$state_key} = $result;
  }
  return $result;
}

sub _probe_syzygy {
  my ($fen, $tb_paths) = @_;
  my $script = _probe_script_path();
  return unless -e $script;

  if (_env_bool('CHESS_SYZYGY_PERSISTENT', 1)) {
    my $persistent = _probe_syzygy_persistent($fen, $tb_paths, $script);
    return $persistent if $persistent;
  }

  return _probe_syzygy_once($fen, $tb_paths, $script);
}

sub _probe_syzygy_once {
  my ($fen, $tb_paths, $script) = @_;
  my @cmd = ($script, '--fen', $fen);
  foreach my $path (@$tb_paths) {
    push @cmd, ('--tb-path', $path);
  }

  my $output = '';
  my $ok = eval {
    open my $fh, '-|', @cmd or die "spawn failed";
    local $/;
    $output = <$fh>;
    close $fh or die "probe failed";
    1;
  };
  return unless $ok;
  return unless defined $output && length $output;

  my $data = eval { JSON::PP->new->decode($output) };
  return if $@;
  return $data;
}

sub _probe_syzygy_persistent {
  my ($fen, $tb_paths, $script) = @_;
  return if time() < $syzygy_probe_worker_backoff_until;

  my $sig = _syzygy_worker_signature($script, $tb_paths);
  my $worker = _ensure_syzygy_probe_worker($sig, $script, $tb_paths);
  return unless ref $worker eq 'HASH';

  my $request = JSON::PP->new->encode({ fen => $fen });
  my $write_ok = eval {
    my $in = $worker->{in};
    print {$in} $request, "\n" or die "write failed";
    1;
  };
  if (! $write_ok) {
    _stop_syzygy_probe_worker();
    _mark_syzygy_probe_worker_failure();
    return;
  }

  my $line;
  my $timeout = _env_int('CHESS_SYZYGY_PERSISTENT_TIMEOUT_SECS', 3, 1, 30);
  my $read_ok = eval {
    local $SIG{ALRM} = sub { die "timeout\n" };
    alarm($timeout);
    $line = readline($worker->{out});
    alarm(0);
    1;
  };
  alarm(0);

  if (! $read_ok || ! defined $line || $line !~ /\S/) {
    _stop_syzygy_probe_worker();
    _mark_syzygy_probe_worker_failure();
    return;
  }

  my $data = eval { JSON::PP->new->decode($line) };
  if ($@ || ref $data ne 'HASH') {
    _stop_syzygy_probe_worker();
    _mark_syzygy_probe_worker_failure();
    return;
  }

  return $data;
}

sub _ensure_syzygy_probe_worker {
  my ($sig, $script, $tb_paths) = @_;
  if (ref $syzygy_probe_worker eq 'HASH') {
    return $syzygy_probe_worker if ($syzygy_probe_worker->{sig} // '') eq $sig;
    _stop_syzygy_probe_worker();
  }

  my @cmd = ($script, '--stdio');
  foreach my $path (@$tb_paths) {
    push @cmd, ('--tb-path', $path);
  }

  my ($out, $in);
  my $pid = eval { open2($out, $in, @cmd) };
  if (! $pid || $@) {
    _mark_syzygy_probe_worker_failure();
    return;
  }

  my $old_handle = select($in);
  $| = 1;
  select($old_handle);

  $syzygy_probe_worker = {
    sig => $sig,
    pid => $pid,
    in  => $in,
    out => $out,
  };
  return $syzygy_probe_worker;
}

sub _stop_syzygy_probe_worker {
  return unless ref $syzygy_probe_worker eq 'HASH';
  my $pid = $syzygy_probe_worker->{pid};
  my $in = $syzygy_probe_worker->{in};
  my $out = $syzygy_probe_worker->{out};

  eval { close $in if $in; };
  eval { close $out if $out; };
  waitpid($pid, 0) if defined $pid && $pid > 0;
  $syzygy_probe_worker = undef;
}

sub _mark_syzygy_probe_worker_failure {
  my $seconds = _env_int('CHESS_SYZYGY_PERSISTENT_RETRY_SECS', 10, 1, 300);
  $syzygy_probe_worker_backoff_until = time() + $seconds;
}

sub _syzygy_worker_signature {
  my ($script, $tb_paths) = @_;
  my @paths = ref $tb_paths eq 'ARRAY' ? @$tb_paths : ();
  my $probetool = $ENV{CHESS_SYZYGY_PROBETOOL} // '';
  my $python = $ENV{CHESS_SYZYGY_PYTHON} // '';
  return join("\x1D", $script, $probetool, $python, @paths);
}

sub _probe_script_path {
  my $override = $ENV{CHESS_SYZYGY_PROBE_SCRIPT};
  my $override_key = defined $override ? "1:$override" : '0:';
  if (defined $probe_script_override_key
      && $probe_script_override_key eq $override_key
      && defined $probe_script_path_cache) {
    return $probe_script_path_cache;
  }

  if (defined $override && length $override) {
    $probe_script_path_cache = $override;
    $probe_script_override_key = $override_key;
    return $probe_script_path_cache;
  }

  $probe_script_path_cache = _default_probe_script_path();
  $probe_script_override_key = $override_key;
  return $probe_script_path_cache;
}

sub _default_probe_script_path {
  return $default_probe_script_path_cache if defined $default_probe_script_path_cache;
  my $module_dir = dirname(__FILE__);
  my $root = File::Spec->catdir($module_dir, '..');
  $default_probe_script_path_cache = File::Spec->catfile($root, 'scripts', 'probe_syzygy.pl');
  return $default_probe_script_path_cache;
}

sub _syzygy_paths {
  my $raw = $ENV{CHESS_SYZYGY_PATH} // '';
  if (!defined $syzygy_paths_raw_cache || $raw ne $syzygy_paths_raw_cache) {
    $syzygy_paths_raw_cache = $raw;
    @syzygy_path_tokens_cache = ();
    return unless length $raw;

    my $sep = ($^O eq 'MSWin32') ? ';' : ':';
    my %seen;
    @syzygy_path_tokens_cache = grep {
      !$seen{$_}++
    } grep {
      defined $_ && length $_
    } map {
      my $path = $_;
      $path =~ s/^\s+//;
      $path =~ s/\s+$//;
      $path;
    } split /\Q$sep\E/, $raw;
  }

  my @paths = grep { -d $_ } @syzygy_path_tokens_cache;

  return @paths;
}

sub _piece_count {
  my ($state) = @_;
  my $board = $state->[Chess::State::BOARD];
  my $count = 0;

  for my $rank (2 .. 9) {
    my $base = $rank * 10;
    for my $file (1 .. 8) {
      my $piece = $board->[$base + $file] // 0;
      my $abs_piece = abs($piece);
      $count++ if $abs_piece >= PAWN && $abs_piece <= KING;
    }
  }

  return $count;
}

sub _env_bool {
  my ($name, $default) = @_;
  my $default_bool = $default ? 1 : 0;
  my $raw_exists = exists $ENV{$name} ? 1 : 0;
  my $raw = $raw_exists ? ($ENV{$name} // '') : '';
  my $raw_key = ($raw_exists ? '1:' : '0:') . $raw;
  my $cache_key = $name . '|default=' . $default_bool;
  my $cached = $env_bool_cache{$cache_key};
  if (ref $cached eq 'HASH' && ($cached->{raw_key} // '') eq $raw_key) {
    return $cached->{value};
  }

  my $value;
  if (!$raw_exists) {
    $value = $default_bool;
  } else {
    my $normalized = lc($raw);
    if ($normalized =~ /^(?:1|true|on|yes)$/) {
      $value = 1;
    } elsif ($normalized =~ /^(?:0|false|off|no)$/) {
      $value = 0;
    } else {
      $value = $default_bool;
    }
  }

  $env_bool_cache{$cache_key} = {
    raw_key => $raw_key,
    value   => $value,
  };
  return $value;
}

sub _env_int {
  my ($name, $default, $min, $max) = @_;
  my $raw_exists = exists $ENV{$name} ? 1 : 0;
  my $raw = $raw_exists ? ($ENV{$name} // '') : '';
  my $raw_key = ($raw_exists ? '1:' : '0:') . $raw;
  my $cache_key = join('|', map { defined $_ ? $_ : '' } $name, $default, $min, $max);
  my $cached = $env_int_cache{$cache_key};
  if (ref $cached eq 'HASH' && ($cached->{raw_key} // '') eq $raw_key) {
    return $cached->{value};
  }

  my $value = $raw_exists ? $ENV{$name} : $default;
  $value = $default unless defined $value && $value =~ /^-?\d+$/;
  $value = int($value);
  $value = $min if defined $min && $value < $min;
  $value = $max if defined $max && $value > $max;
  $env_int_cache{$cache_key} = {
    raw_key => $raw_key,
    value   => $value,
  };
  return $value;
}

sub _numeric_or {
  my ($value, $default) = @_;
  return $default unless defined $value && $value =~ /^-?\d+(?:\.\d+)?$/;
  return $value + 0;
}

sub _maybe_numeric {
  my ($value) = @_;
  return unless defined $value && $value =~ /^-?\d+(?:\.\d+)?$/;
  my $num = abs($value + 0);
  return $num;
}

sub _syzygy_cache_key {
  my ($state_key, $probe_sig) = @_;
  $state_key //= '';
  $probe_sig //= '';
  return $state_key . "\x1F" . $probe_sig;
}

sub _syzygy_probe_signature {
  my ($tb_paths) = @_;
  my $script = _probe_script_path();
  my @paths = ref $tb_paths eq 'ARRAY' ? @$tb_paths : ();
  return join("\x1E", $script, @paths);
}

sub _in_syzygy_failure_backoff {
  my ($cache_key) = @_;
  my $until = $syzygy_failure_backoff_until{$cache_key} // 0;
  if ($until <= time()) {
    delete $syzygy_failure_backoff_until{$cache_key}
      if exists $syzygy_failure_backoff_until{$cache_key};
    return 0;
  }
  return $until > time();
}

sub _mark_syzygy_failure {
  my ($cache_key) = @_;
  my $seconds = _env_int('CHESS_SYZYGY_FAILURE_BACKOFF_SECS', 120, 1, 3600);
  if (scalar(keys %syzygy_failure_backoff_until) >= $SYZYGY_BACKOFF_CACHE_MAX) {
    %syzygy_failure_backoff_until = ();
  }
  $syzygy_failure_backoff_until{$cache_key} = time() + $seconds;
}

END {
  _stop_syzygy_probe_worker();
}

_load_tables();

1;
