#!/usr/bin/env perl
use v5.26;
use strict;
use warnings;

# Make local modules available so the bundled UCI engine can be spawned.
use FindBin qw($RealBin);
use lib $RealBin;
BEGIN {
  my $base = "$RealBin/.perl5/lib/perl5";
  if (-d $base) {
    unshift @INC, $base;
    my $arch = "$base/" . $Config::Config{archname};
    if (-d $arch) {
      unshift @INC, $arch;
    }
  }
}

use JSON::PP qw(decode_json encode_json);
use IPC::Open2;
use IO::Handle;
use IO::Socket::INET;
use Text::ParseWords qw(shellwords);
use POSIX ':sys_wait_h';
use Config;
use IO::Socket::SSL qw(SSL_VERIFY_PEER);
use Socket qw(AF_INET);
use Time::HiRes qw(time);
use Fcntl qw(:flock);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use Chess::State;
use Chess::Engine ();

eval {
  require IO::Socket::SSL;
  IO::Socket::SSL->import();
  require Mozilla::CA;
  1;
} or die "Install IO::Socket::SSL and Mozilla::CA to use lichess.pl: $@";

load_env("$RealBin/.env");

my $dry_run = $ENV{LICHESS_DRY_RUN} ? 1 : 0;
my $token = $ENV{LICHESS_TOKEN} // '';
my $engine_cmd = $ENV{LICHESS_ENGINE_CMD} // "$^X $RealBin/play.pl --uci";
my @engine_parts = shellwords($engine_cmd);
@engine_parts or die "Unable to parse LICHESS_ENGINE_CMD '$engine_cmd'\n";
my $think_slow_ms = $ENV{LICHESS_THINK_SLOW_MS} // 3000;
$think_slow_ms = 3000 unless defined $think_slow_ms && $think_slow_ms =~ /^\d+$/;
my $git_branch = _git_branch_name();
my $branch_override_allowed = _branch_override_allowed($git_branch);
my $depth_override = $ENV{LICHESS_DEPTH_OVERRIDE};
if (defined $depth_override) {
  if ($depth_override =~ /^-?\d+$/) {
    $depth_override = int($depth_override);
  } else {
    $depth_override = undef;
  }
}
my $default_override_depth = 4;
$depth_override = $default_override_depth
  if $branch_override_allowed && !defined $depth_override;
$depth_override = undef unless defined $depth_override && $branch_override_allowed;

STDOUT->autoflush(1);
STDERR->autoflush(1);

my $debug = $ENV{LICHESS_DEBUG} // 0;
my %handled_challenges;

my $auth_header = '';
my $ssl_ca_file = Mozilla::CA::SSL_ca_file();
my $user_agent  = 'PerlGigachess/0.1';
my $bot_id = $ENV{LICHESS_BOT_ID} // '';
my $last_tls_error = '';
my $game_url_log_path = $ENV{LICHESS_GAME_URL_LOG} // "$RealBin/data/lichess_game_urls.log";
my %logged_finished_games;
my %logged_game_urls;
my $game_url_log_cache_ready = 0;
my $game_url_log_cache_bytes = 0;
my %socket_read_buffers;
my $http_request_sock;
my $http_request_sock_pid = $$;
my %speed_depth_targets = (
  blitz     => 16,
  rapid     => 17,
  classical => 18,
  unlimited => 18,
);

unless (caller) {
  exit main();
}

sub main {
  $SIG{INT}  = sub { log_info('Caught SIGINT, shutting down'); exit 0 };
  $SIG{TERM} = sub { log_info('Caught SIGTERM, shutting down'); exit 0 };
  $SIG{CHLD} = sub { reap_children() };

  if ($dry_run) {
    return run_dry_run();
  }

  die "Set LICHESS_TOKEN to a Bot API token generated on lichess.org\n"
    unless length $token;
  $auth_header = "Bearer $token";

  # Ensure the token is valid and capture the bot username.
  my $account = lichess_json_get('/account');
  $bot_id  = $account->{id}
    or die "Unable to discover bot id from /api/account response\n";
  my $branch_desc = defined $git_branch && length $git_branch ? $git_branch : '(unknown branch)';
  my $depth_desc = defined $depth_override ? $depth_override : 'none';
  log_info("Logged in as $account->{username} ($bot_id) on branch $branch_desc, depth override is $depth_desc");

  stream_events();
  return 0;
}

sub stream_events {
  while (1) {
    reap_children();
    log_info('Connecting to event stream');
    my $ok = stream_ndjson('/stream/event', sub {
      my ($event) = @_;
      unless (ref $event eq 'HASH') {
        log_debug("Ignoring non-object event on /stream/event");
        return;
      }
      log_debug("Event " . ($event->{type} // ''));
      handle_event($event);
    });
    if (!$ok) {
      log_warn('Event stream closed unexpectedly, reconnecting');
    }
    sleep 2;
  }
}

sub reap_children {
  while (1) {
    my $kid = waitpid(-1, WNOHANG);
    last if !defined $kid || $kid <= 0;
    log_debug("Reaped child pid $kid");
  }
}

sub run_dry_run {
  log_info('Running lichess dry run (no network)');
  $bot_id = 'dry-run-bot';
  $auth_header = 'Bearer dry-run-token';
  %handled_challenges = ();

  my @accepted_ids;
  my @declined_ids;
  my @attempted_moves;
  my $send_attempt = 0;

  {
    no warnings 'redefine';

    local *http_request = sub {
      my ($method, $path, $opts) = @_;
      if ($method eq 'POST' && $path =~ m{^/challenge/([^/]+)/accept$}) {
        push @accepted_ids, $1;
        return {
          success => 1, status => 200, reason => 'OK',
          status_line => 'HTTP/1.1 200 OK', content => '{}',
        };
      }
      if ($method eq 'POST' && $path =~ m{^/challenge/([^/]+)/decline$}) {
        push @declined_ids, $1;
        return {
          success => 1, status => 200, reason => 'OK',
          status_line => 'HTTP/1.1 200 OK', content => '{}',
        };
      }
      return {
        success => 1, status => 200, reason => 'OK',
        status_line => 'HTTP/1.1 200 OK', content => '{}',
      };
    };

    local *compute_bestmove = sub {
      return {
        move => 'g1f3',
        elapsed_ms => 42,
        depth => 4,
        cp => 18,
      };
    };

    local *send_move = sub {
      my ($game_id, $move, $opts) = @_;
      push @attempted_moves, $move;
      $send_attempt++;
      if ($send_attempt == 1) {
        return {
          success => 0, status => 400, reason => 'Bad Request',
          status_line => 'HTTP/1.1 400 Bad Request', content => 'illegal move',
        };
      }
      return {
        success => 1, status => 200, reason => 'OK',
        status_line => 'HTTP/1.1 200 OK', content => '{}',
      };
    };

    handle_event({
      type => 'challenge',
      challenge => {
        id => 'dry-accept-1',
        direction => 'in',
        status => 'created',
        speed => 'rapid',
        variant => { key => 'standard' },
        challenger => { name => 'tester' },
      },
    });

    # Duplicate challenge should be ignored once handled.
    handle_event({
      type => 'challenge',
      challenge => {
        id => 'dry-accept-1',
        direction => 'in',
        status => 'created',
        speed => 'rapid',
        variant => { key => 'standard' },
        challenger => { name => 'tester' },
      },
    });

    handle_event({
      type => 'challengeCreated',
      challenge => {
        id => 'dry-decline-1',
        direction => 'in',
        status => 'created',
        speed => 'bullet',
        variant => { key => 'chess960' },
        challenger => { name => 'variant-user' },
      },
    });

    my %game = (
      id                => 'dry-game-1',
      my_color          => 'white',
      initial_fen       => 'startpos',
      moves             => [ 'e2e4', 'e7e5' ],
      pending_move      => undef,
      status            => 'started',
      wtime             => 120_000,
      btime             => 120_000,
      winc              => 0,
      binc              => 0,
      is_my_turn        => 1,
      state_obj         => undef,
      state_move_count  => 0,
      state_initial_fen => undef,
    );

    maybe_move(\%game, undef, undef);

    my $played = $game{pending_move};
    push @{$game{moves}}, $played if defined $played && length $played;
    push @{$game{moves}}, 'b8c6';
    $game{pending_move} = undef;
    $game{is_my_turn} = 0;
    my $synced = _sync_state_from_game(\%game) ? 1 : 0;

    log_info("Dry run accepted challenges: " . (@accepted_ids ? join(',', @accepted_ids) : 'none'));
    log_info("Dry run declined challenges: " . (@declined_ids ? join(',', @declined_ids) : 'none'));
    log_info("Dry run move attempts: " . (@attempted_moves ? join(' -> ', @attempted_moves) : 'none'));
    log_info("Dry run state sync: " . ($synced ? 'ok' : 'failed') . " count=$game{state_move_count}");
  }

  return 0;
}

sub handle_event {
  my ($event) = @_;
  my $type = $event->{type} // '';
  if ($type eq 'challenge' || $type eq 'challengeCreated') {
    handle_challenge(extract_challenge_payload($event));
  } elsif ($type eq 'challengeCanceled') {
    log_info("Challenge " . challenge_id($event) . " canceled");
  } elsif ($type eq 'challengeDeclined') {
    log_info("Challenge " . challenge_id($event) . " declined");
  } elsif ($type eq 'challengeAccepted') {
    my $id = challenge_id($event);
    $handled_challenges{$id} = 1 if $id ne 'unknown';
    log_info("Challenge $id accepted");
  } elsif ($type eq 'gameStart') {
    start_game($event->{game});
  } elsif ($type eq 'gameFinish') {
    my $game = (ref $event->{game} eq 'HASH') ? $event->{game} : $event;
    my $game_id = (ref $game eq 'HASH' && defined $game->{id}) ? $game->{id} : 'unknown';
    log_info("Game $game_id finished");
    log_finished_game_url($game);
  } else {
    log_info("Unhandled event type '$type'");
  }
}

sub log_finished_game_url {
  my ($game) = @_;
  return unless ref $game eq 'HASH';

  my $game_id = $game->{id} // '';
  if (length $game_id && $logged_finished_games{$game_id}) {
    log_debug("Skipping duplicate game URL log for $game_id");
    return;
  }

  my $url = game_url_from_payload($game);
  unless (defined $url && length $url) {
    log_warn('Unable to determine URL for finished game');
    return;
  }

  if ($logged_game_urls{$url}) {
    $logged_finished_games{$game_id} = 1 if length $game_id;
    log_debug("Game URL already logged: $url");
    return;
  }

  return unless ensure_parent_dir($game_url_log_path);

  my $max_attempts = 3;
  for (my $attempt = 1; $attempt <= $max_attempts; $attempt++) {
    my $fh;
    unless (open $fh, '+>>', $game_url_log_path) {
      log_warn("Unable to append game URL to $game_url_log_path (attempt $attempt): $!");
      if ($attempt < $max_attempts) {
        select undef, undef, undef, 0.2 * $attempt;
        next;
      }
      return;
    }
    $fh->autoflush(1);

    unless (flock($fh, LOCK_EX)) {
      log_warn("Unable to lock game URL log $game_url_log_path (attempt $attempt): $!");
      close $fh;
      if ($attempt < $max_attempts) {
        select undef, undef, undef, 0.2 * $attempt;
        next;
      }
      return;
    }

    _refresh_logged_game_urls_locked($fh);
    my $already_logged = $logged_game_urls{$url} ? 1 : 0;

    my $write_ok = 1;
    if (!$already_logged) {
      unless (seek($fh, 0, 2)) {
        log_warn("Unable to seek to end of game URL log: $!");
        $write_ok = 0;
      } elsif (!print {$fh} "$url\n") {
        log_warn("Unable to append game URL to $game_url_log_path: $!");
        $write_ok = 0;
      } else {
        $logged_game_urls{$url} = 1;
        my $pos = tell($fh);
        if (defined $pos && $pos >= 0) {
          $game_url_log_cache_bytes = $pos;
          $game_url_log_cache_ready = 1;
        }
      }
    }

    my $closed = close $fh;
    unless ($closed) {
      log_warn("Unable to close game URL log $game_url_log_path: $!");
      $write_ok = 0;
    }

    if ($already_logged || $write_ok) {
      $logged_finished_games{$game_id} = 1 if length $game_id;
      if ($already_logged) {
        log_debug("Game URL already logged: $url");
      } else {
        log_info("Logged finished game URL: $url");
      }
      return;
    }

    if ($attempt < $max_attempts) {
      select undef, undef, undef, 0.2 * $attempt;
    }
  }

  log_warn("Failed to persist finished game URL after $max_attempts attempts: $url");
}

sub _refresh_logged_game_urls_locked {
  my ($fh) = @_;
  return 0 unless $fh;

  my $start = 0;
  if ($game_url_log_cache_ready) {
    my $size = -s $fh;
    if (defined $size && $size >= $game_url_log_cache_bytes) {
      $start = $game_url_log_cache_bytes;
    } else {
      %logged_game_urls = ();
      $game_url_log_cache_bytes = 0;
    }
  } else {
    %logged_game_urls = ();
  }

  unless (seek($fh, $start, 0)) {
    log_warn("Unable to refresh game URL log cache: $!");
    return 0;
  }

  while (my $line = <$fh>) {
    $line =~ s/[\r\n]+$//;
    next unless length $line;
    $logged_game_urls{$line} = 1;
  }

  my $pos = tell($fh);
  if (defined $pos && $pos >= 0) {
    $game_url_log_cache_bytes = $pos;
    $game_url_log_cache_ready = 1;
  }
  return 1;
}

sub maybe_log_finished_from_status {
  my ($game) = @_;
  return unless ref $game eq 'HASH';
  return unless is_terminal_game_status($game->{status});
  log_finished_game_url($game);
}

sub is_terminal_game_status {
  my ($status) = @_;
  return 0 unless defined $status && length $status;
  my $normalized = lc $status;
  return 0 if $normalized eq 'created';
  return 0 if $normalized eq 'started';
  return 1;
}

sub ensure_parent_dir {
  my ($path) = @_;
  return 0 unless defined $path && length $path;
  my $dir = dirname($path);
  return 1 unless defined $dir && length $dir;
  return 1 if -d $dir;

  my $ok = eval { make_path($dir); 1 };
  unless ($ok && -d $dir) {
    my $err = $@ || 'unknown error';
    chomp $err;
    log_warn("Unable to create directory $dir for game URL log: $err");
    return 0;
  }
  return 1;
}

sub game_url_from_payload {
  my ($game) = @_;
  return unless ref $game eq 'HASH';

  if (defined $game->{url} && length $game->{url}) {
    return normalize_lichess_url($game->{url});
  }

  return unless defined $game->{id} && length $game->{id};
  return "https://lichess.org/$game->{id}";
}

sub normalize_lichess_url {
  my ($url) = @_;
  return unless defined $url && length $url;
  return $url if $url =~ m{^https?://};
  $url = "/$url" unless $url =~ m{^/};
  return "https://lichess.org$url";
}

sub handle_challenge {
  my ($challenge) = @_;
  $challenge = extract_challenge_payload($challenge);
  unless (ref $challenge eq 'HASH') {
    log_warn('Challenge event missing challenge payload');
    return;
  }

  my $id = $challenge->{id};
  unless (defined $id && length $id) {
    log_warn('Challenge event missing id');
    return;
  }

  if ($handled_challenges{$id}) {
    log_debug("Skipping previously handled challenge $id");
    return;
  }

  my $challenger = $challenge->{challenger}{name}
    // $challenge->{challenger}{id}
    // 'unknown';
  my $challenger_id = lc($challenge->{challenger}{id} // '');
  my $dest_user_id = lc($challenge->{destUser}{id} // '');
  my $bot_id_lc = lc($bot_id // '');

  if (length $challenger_id && length $bot_id_lc && $challenger_id eq $bot_id_lc) {
    log_info("Ignoring outgoing challenge $id from $challenger");
    return;
  }
  if (length $dest_user_id && length $bot_id_lc && $dest_user_id ne $bot_id_lc) {
    log_info("Ignoring challenge $id not addressed to this bot (destUser=$dest_user_id)");
    return;
  }

  my $direction = lc($challenge->{direction} // '');
  if (length $direction && $direction ne 'in') {
    log_debug("Ignoring non-incoming challenge $id (direction=$direction)");
    return;
  }

  my $status = lc($challenge->{status} // '');
  if (length $status && $status ne 'created') {
    log_debug("Ignoring challenge $id with status $status");
    return;
  }

  my $variant = lc($challenge->{variant}{key} // '');
  my $speed   = lc($challenge->{speed} // '');

  if ($variant ne 'standard') {
    log_info("Declining challenge $id (unsupported variant $variant)");
    decline_challenge($id, 'variant');
    $handled_challenges{$id} = 1;
    return;
  }

  if ($speed eq 'correspondence') {
    log_info("Declining challenge $id (unsupported speed)");
    decline_challenge($id, 'timeControl');
    $handled_challenges{$id} = 1;
    return;
  }

  log_info("Accepting incoming challenge $id from $challenger ($speed $variant)");
  if (accept_challenge($id)) {
    $handled_challenges{$id} = 1;
  }
}

sub challenge_id {
  my ($event) = @_;
  return 'unknown' unless ref $event eq 'HASH';
  my $challenge = extract_challenge_payload($event);
  if (ref $challenge eq 'HASH' && defined $challenge->{id}) {
    return $challenge->{id};
  }
  return $event->{id} // 'unknown';
}

sub extract_challenge_payload {
  my ($source) = @_;
  return unless ref $source eq 'HASH';
  if (ref $source->{challenge} eq 'HASH' && exists $source->{challenge}{id}) {
    return $source->{challenge};
  }
  if (exists $source->{id}) {
    return $source;
  }
  if (ref $source->{challenge} eq 'HASH') {
    return extract_challenge_payload($source->{challenge});
  }
  return;
}

sub accept_challenge {
  my ($id) = @_;
  my $attempt = 0;
  while ($attempt < 3) {
    $attempt++;
    my $res = http_request('POST', "/challenge/$id/accept");
    return 1 if $res->{success};
    my $status = $res->{status} // 0;
    if ($status == 404) {
      log_info("Challenge $id could not be accepted (HTTP 404: already resolved or not incoming)");
      return 0;
    }
    log_warn(
      "Failed to accept challenge $id (attempt $attempt): $res->{status_line}"
    );
    if ($status == 409) {
      log_info("Challenge $id is already accepted");
      return 1;
    }
    if ($status >= 400 && $status < 500 && $status != 429) {
      return 0;
    }
    select undef, undef, undef, 0.5;
  }
  return 0;
}

sub decline_challenge {
  my ($id, $reason) = @_;
  $reason //= 'generic';
  my $res = http_request('POST', "/challenge/$id/decline", {
    form => { reason => $reason },
  });
  if (!$res->{success}) {
    log_warn("Failed to decline challenge $id: " . $res->{status_line});
  }
}

sub start_game {
  my ($game) = @_;
  my $game_id = $game->{id};
  my $pid = fork();
  if (!defined $pid) {
    log_warn("Unable to fork for game $game_id: $!");
    return;
  }
  if ($pid == 0) {
    select undef, undef, undef, 0.1;
    play_game($game);
    exit 0;
  }
  log_info("Spawned handler pid $pid for game $game_id");
}

sub play_game {
  my ($seed) = @_;
  my $seed_info = (ref $seed eq 'HASH') ? $seed : {};
  my $game_id = $seed_info->{id} // $seed;
  log_info("Starting game stream for $game_id");

  my ($engine_out, $engine_in);
  my $engine_pid = open2($engine_out, $engine_in, @engine_parts);
  $engine_in->autoflush(1);

  my $engine_meta = uci_handshake($engine_out, $engine_in);
  unless ($engine_meta) {
    log_warn("Engine handshake failed, aborting game $game_id");
    kill 'TERM', $engine_pid;
    waitpid($engine_pid, 0);
    return;
  }

  my %game = (
    id           => $game_id,
    my_color     => normalize_color($seed_info->{color}),
    speed        => extract_speed($seed_info),
    initial_fen  => normalize_fen($seed_info->{fen}),
    moves        => [],
    pending_move => undef,
    status       => 'created',
    wtime        => undef,
    btime        => undef,
    winc         => 0,
    binc         => 0,
    is_my_turn   => extract_turn_flag($seed_info),
    state_obj        => undef,
    state_move_count => 0,
    state_initial_fen => undef,
    engine_supports_depth => $engine_meta->{has_depth_option} ? 1 : 0,
    engine_depth_min      => $engine_meta->{depth_min},
    engine_depth_max      => $engine_meta->{depth_max},
    engine_depth_default  => $engine_meta->{depth_default},
    engine_depth          => $engine_meta->{depth_default},
  );
  log_debug("Opening game stream for $game_id");
  my $buffer = '';
  my $ok = stream_ndjson("/bot/game/stream/$game_id", sub {
    my ($event) = @_;
    unless (ref $event eq 'HASH') {
      log_debug("Ignoring non-object payload on game stream $game_id");
      return;
    }
    handle_game_event(\%game, $event, $engine_out, $engine_in);
  });

  if (!$ok) {
    log_warn("Game stream $game_id ended unexpectedly");
  } else {
    log_info("Game stream $game_id finished");
  }
  maybe_log_finished_from_status(\%game);

  kill 'TERM', $engine_pid;
  waitpid($engine_pid, 0);
}

sub handle_game_event {
  my ($game, $event, $engine_out, $engine_in) = @_;
  my $type = $event->{type} // '';

  if ($type eq 'gameFull') {
    log_debug("gameFull payload: " . encode_json($event)) if $debug;
    log_debug("gameFull for $game->{id}");
    $game->{initial_fen} = $event->{initialFen} && $event->{initialFen} ne 'startpos'
      ? $event->{initialFen} : 'startpos';
    $game->{my_color} =
      ($event->{white}{id} && $event->{white}{id} eq $bot_id) ? 'white' : 'black';
    $game->{status} = $event->{state}{status} // 'started';
    $game->{moves}  = parse_moves($event->{state}{moves});
    $game->{wtime}  = $event->{state}{wtime};
    $game->{btime}  = $event->{state}{btime};
    $game->{winc}   = $event->{state}{winc};
    $game->{binc}   = $event->{state}{binc};
    my $event_speed = extract_speed($event);
    $game->{speed}  = $event_speed if defined $event_speed;
    $game->{state_obj} = undef;
    $game->{state_move_count} = 0;
    $game->{state_initial_fen} = undef;
    update_turn_from_event($game, $event);
    print {$engine_in} "ucinewgame\n";
    maybe_apply_speed_depth($game, $engine_out, $engine_in);
    maybe_move($game, $engine_out, $engine_in);
    maybe_log_finished_from_status($game);
  } elsif ($type eq 'gameState') {
    log_debug("gameState payload: " . encode_json($event)) if $debug;
    log_debug("gameState for $game->{id}: moves=$event->{moves}");
    $game->{status} = $event->{status} if defined $event->{status};
    $game->{moves}  = parse_moves($event->{moves});
    $game->{wtime}  = $event->{wtime};
    $game->{btime}  = $event->{btime};
    $game->{winc}   = $event->{winc};
    $game->{binc}   = $event->{binc};
    $game->{pending_move} = undef if $game->{pending_move};
    update_turn_from_event($game, $event);
    maybe_move($game, $engine_out, $engine_in);
    maybe_log_finished_from_status($game);
  } elsif ($type eq 'chatLine') {
    log_info("Chat <$event->{username}> $event->{text}") if $event->{text};
  }
}

sub parse_moves {
  my ($moves) = @_;
  return [] unless defined $moves && length $moves;
  my @moves = split / /, $moves;
  return \@moves;
}

sub normalize_color {
  my ($color) = @_;
  return unless defined $color;
  $color = lc $color;
  return 'white' if $color eq 'white';
  return 'black' if $color eq 'black';
  return;
}

sub normalize_fen {
  my ($fen) = @_;
  return 'startpos' unless defined $fen && length $fen;
  return $fen;
}

sub normalize_speed {
  my ($speed) = @_;
  return unless defined $speed;
  $speed = lc $speed;
  return $speed;
}

sub extract_speed {
  my ($source) = @_;
  return unless ref $source eq 'HASH';

  my $speed = $source->{speed};
  if (!defined $speed && ref $source->{perf} eq 'HASH') {
    $speed = $source->{perf}{name} // $source->{perf}{key};
  }
  return normalize_speed($speed);
}

sub extract_turn_flag {
  my ($source) = @_;
  return unless ref $source eq 'HASH';
  if (exists $source->{state}
    && ref $source->{state} eq 'HASH'
    && exists $source->{state}{isMyTurn})
  {
    return $source->{state}{isMyTurn} ? 1 : 0;
  }
  if (exists $source->{isMyTurn}) {
    return $source->{isMyTurn} ? 1 : 0;
  }
  return;
}

sub update_turn_from_event {
  my ($game, $event) = @_;
  my $flag = extract_turn_flag($event);
  if (defined $flag) {
    $game->{is_my_turn} = $flag ? 1 : 0;
  } else {
    $game->{is_my_turn} = undef;
  }
}

sub infer_turn_from_moves {
  my ($game) = @_;
  return unless defined $game->{my_color};
  my $initial = initial_side_from_fen($game->{initial_fen});
  my $moves = $game->{moves} // [];
  my $side;
  if ($initial eq 'white') {
    $side = (@$moves % 2 == 0) ? 'white' : 'black';
  } else {
    $side = (@$moves % 2 == 0) ? 'black' : 'white';
  }
  return $side eq $game->{my_color} ? 1 : 0;
}

sub initial_side_from_fen {
  my ($fen) = @_;
  return 'white' unless defined $fen && $fen ne 'startpos';
  if ($fen =~ /\s([wb])\s/) {
    return $1 eq 'b' ? 'black' : 'white';
  }
  return 'white';
}

sub maybe_move {
  my ($game, $engine_out, $engine_in) = @_;
  return unless ($game->{status} // '') eq 'started';
  log_debug("maybe_move status=$game->{status}");
  return unless defined $game->{my_color};
  return if $game->{pending_move};

  my $my_turn = defined $game->{is_my_turn}
    ? $game->{is_my_turn}
    : infer_turn_from_moves($game);
  log_debug("my_color=$game->{my_color} is_my_turn=" . ($my_turn // 'undef'));
  return unless $my_turn;

  my $state = _sync_state_from_game($game);
  unless ($state) {
    log_warn("Unable to rebuild local state for $game->{id}; skipping move");
    return;
  }

  my $my_clock_before_ms = _my_clock_ms($game);
  my $analysis = compute_bestmove($game, $engine_out, $engine_in);
  if (ref $analysis eq 'HASH'
    && defined $analysis->{elapsed_ms}
    && defined $my_clock_before_ms
    && $my_clock_before_ms > 0)
  {
    my $warn_threshold_ms = int($my_clock_before_ms * 0.10);
    $warn_threshold_ms = 1 if $warn_threshold_ms < 1;
    if ($analysis->{elapsed_ms} > $warn_threshold_ms) {
      log_warn("You're not saying anything, Tony.");
    }
  }
  if (ref $analysis eq 'HASH' && defined $analysis->{elapsed_ms}
    && $analysis->{elapsed_ms} >= $think_slow_ms)
  {
    log_info(
      sprintf(
        'Long think in %s: %dms (candidate %s%s)',
        $game->{id},
        $analysis->{elapsed_ms},
        ($analysis->{move} // 'none'),
        _format_eval_suffix($analysis),
      )
    );
  }
  my $best = (ref $analysis eq 'HASH') ? $analysis->{move} : undef;
  my @candidates = _candidate_moves($state, $best);
  unless (@candidates) {
    log_warn("No legal move available for $game->{id}");
    return;
  }

  my $attempts = 0;
  while (@candidates && $attempts < 4) {
    my $candidate = shift @candidates;
    $attempts++;

    my $res = send_move($game->{id}, $candidate);
    if ($res->{success}) {
      $game->{pending_move} = $candidate;
      $game->{is_my_turn}   = 0;
      log_info("Played $candidate in $game->{id}" . _format_eval_suffix($analysis));
      return;
    }

    last unless _is_retryable_illegal_reject($res);
    log_warn("Retrying with alternate legal move for $game->{id} after HTTP 400");
  }
}

sub _my_clock_ms {
  my ($game) = @_;
  return unless ref $game eq 'HASH';
  return unless defined $game->{my_color};

  my $clock = $game->{my_color} eq 'white'
    ? $game->{wtime}
    : $game->{btime};
  return unless defined $clock && $clock =~ /^\d+$/;
  return $clock + 0;
}

sub _sync_state_from_game {
  my ($game) = @_;
  my $moves = $game->{moves} || [];
  my $initial = ($game->{initial_fen} && $game->{initial_fen} ne 'startpos')
    ? $game->{initial_fen}
    : 'startpos';

  my $needs_rebuild = !defined $game->{state_obj}
    || !defined $game->{state_move_count}
    || $game->{state_move_count} > @$moves
    || ($game->{state_initial_fen} // '') ne $initial;

  if ($needs_rebuild) {
    my $state = eval {
      $initial eq 'startpos' ? Chess::State->new() : Chess::State->new($initial);
    };
    if (!$state || $@) {
      log_warn("Could not create state from initial FEN for $game->{id}: $@");
      $game->{state_obj} = undef;
      $game->{state_move_count} = 0;
      $game->{state_initial_fen} = undef;
      return;
    }
    $game->{state_obj} = $state;
    $game->{state_move_count} = 0;
    $game->{state_initial_fen} = $initial;
  }

  my $state = $game->{state_obj};
  for (my $i = $game->{state_move_count}; $i < @$moves; $i++) {
    my $uci = $moves->[$i];
    my $encoded = eval { $state->encode_move($uci) };
    if (!$encoded || $@) {
      log_warn("Failed to encode move '$uci' in $game->{id}: $@");
      $game->{state_obj} = undef;
      $game->{state_move_count} = 0;
      return;
    }
    my $next = eval { $state->make_move($encoded) };
    if (!defined $next || $@) {
      log_warn("Illegal historical move '$uci' while rebuilding $game->{id}");
      $game->{state_obj} = undef;
      $game->{state_move_count} = 0;
      return;
    }
    $state = $next;
    $game->{state_move_count} = $i + 1;
  }

  $game->{state_obj} = $state;
  return $state;
}

sub _candidate_moves {
  my ($state, $proposed) = @_;
  my @legal = $state->get_moves;
  return () unless @legal;

  my %legal = map { $_ => 1 } @legal;
  my @ordered;
  my %seen;
  if (defined $proposed && $proposed ne '(none)' && $legal{$proposed}) {
    push @ordered, $proposed;
    $seen{$proposed} = 1;
  } elsif (defined $proposed && length $proposed) {
    log_warn("Engine proposed illegal move '$proposed'; trying fallback move(s)");
  } else {
    log_warn("Engine returned no move; trying fallback move(s)");
  }

  foreach my $move (_engine_contender_moves($state, 6)) {
    next unless $legal{$move};
    next if $seen{$move};
    push @ordered, $move;
    $seen{$move} = 1;
  }

  foreach my $move (@legal) {
    next if $seen{$move};
    push @ordered, $move;
  }

  return @ordered;
}

sub _engine_contender_moves {
  my ($state, $limit) = @_;
  $limit = 1 unless defined $limit && $limit =~ /^\d+$/;
  $limit = 1 if $limit < 1;

  my $board = $state->[Chess::State::BOARD];
  my @ordered = map { $_->[1] }
    sort { $b->[0] <=> $a->[0] }
    map {
      my $move = $_;
      my $score = 0;
      my $target = $board->[$move->[1]] // 0;
      $score += 1000 + (10 * abs($target)) if $target < 0;
      $score += 250 if defined $move->[2];
      $score += 50 if defined $move->[3];
      [ $score, $move ];
    } @{$state->generate_pseudo_moves};

  my @contenders;
  foreach my $move (@ordered) {
    my $next = $state->make_move($move);
    next unless defined $next;
    push @contenders, $state->decode_move($move);
    last if @contenders >= $limit;
  }

  return @contenders;
}

sub _is_retryable_illegal_reject {
  my ($res) = @_;
  return 0 unless ref $res eq 'HASH' && (($res->{status} // 0) == 400);

  my $body = lc($res->{content} // '');
  return 1 unless length $body;
  return 0 if $body =~ /(not your turn|game (?:is )?(?:over|finished)|already ended|terminated|too late|not started)/;
  return 1;
}

sub _branch_override_allowed {
  my ($branch) = @_;
  return 1 unless defined $branch && length $branch;
  my $norm = lc $branch;
  return 0 if $norm eq 'main';
  return 1;
}

sub _git_branch_name {
  my $repo_root = $RealBin;
  return unless defined $repo_root && length $repo_root;
  return unless -d "$repo_root/.git";

  my $branch;
  if (open my $git, '-|', 'git', '-C', $repo_root, 'rev-parse', '--abbrev-ref', 'HEAD') {
    $branch = <$git>;
    close $git;
  }
  chomp $branch if defined $branch;
  return $branch if defined $branch && length $branch;
  return;
}

sub _set_engine_depth {
  my ($game, $engine_out, $engine_in, $target, $reason) = @_;
  return unless ref $game eq 'HASH';

  my $min_depth = defined $game->{engine_depth_min} ? int($game->{engine_depth_min}) : 1;
  my $max_depth = defined $game->{engine_depth_max} ? int($game->{engine_depth_max}) : 20;
  $target = $min_depth if $target < $min_depth;
  $target = $max_depth if $target > $max_depth;

  my $current_depth = $game->{engine_depth};
  $current_depth = $game->{engine_depth_default} if !defined $current_depth;
  return if defined $current_depth && $current_depth == $target;

  print {$engine_in} "setoption name Depth value $target\n";
  print {$engine_in} "isready\n";
  while (my $line = <$engine_out>) {
    $line =~ s/[\r\n]+$//;
    if ($line =~ /^readyok/) {
      $game->{engine_depth} = $target;
      my $suffix = defined $reason && length $reason ? " ($reason)" : '';
      log_info("Set engine depth to $target for $game->{id}$suffix");
      return 1;
    }
  }

  my $suffix = defined $reason && length $reason ? " ($reason)" : '';
  log_warn("Depth update failed for $game->{id}$suffix");
  return;
}

sub maybe_apply_speed_depth {
  my ($game, $engine_out, $engine_in) = @_;
  return unless ref $game eq 'HASH';
  return unless $game->{engine_supports_depth};

  if (defined $depth_override) {
    return _set_engine_depth($game, $engine_out, $engine_in, $depth_override, 'local override');
  }

  my $speed = normalize_speed($game->{speed});
  return unless defined $speed && exists $speed_depth_targets{$speed};

  my $target = $speed_depth_targets{$speed};
  return unless defined $target;
  my $current_depth = $game->{engine_depth};
  $current_depth = $game->{engine_depth_default} if !defined $current_depth;
  return if defined $current_depth && $current_depth >= $target;

  return _set_engine_depth($game, $engine_out, $engine_in, $target, $speed);
}

sub _format_eval_suffix {
  my ($analysis) = @_;
  return '' unless ref $analysis eq 'HASH';

  my @parts;
  push @parts, "depth $analysis->{depth}" if defined $analysis->{depth};
  if (defined $analysis->{mate}) {
    push @parts, "mate $analysis->{mate}";
  } elsif (defined $analysis->{cp}) {
    push @parts, sprintf('cp %+d', $analysis->{cp});
  }

  return @parts ? " (engine " . join(', ', @parts) . ")" : '';
}

sub compute_bestmove {
  my ($game, $engine_out, $engine_in) = @_;
  my $started_at = time;

  my $moves = $game->{moves} // [];
  if ($game->{initial_fen} && $game->{initial_fen} ne 'startpos') {
    print {$engine_in} "position fen $game->{initial_fen}";
  } else {
    print {$engine_in} "position startpos";
  }
  if (@$moves) {
    print {$engine_in} " moves " . join(' ', @$moves);
  }
  print {$engine_in} "\n";

  my $go;
  if (defined $game->{wtime} && defined $game->{btime}) {
    $go = sprintf 'go wtime %d btime %d', $game->{wtime}, $game->{btime};
    if (defined $game->{winc} && defined $game->{binc}) {
      $go .= sprintf ' winc %d binc %d', $game->{winc}, $game->{binc};
    }
  } else {
    my $movetime = $ENV{LICHESS_MOVETIME_MS} // 800;
    $go = "go movetime $movetime";
  }
  print {$engine_in} "$go\n";

  my %analysis = (move => undef);
  while (my $line = <$engine_out>) {
    $line =~ s/[\r\n]+$//;
    if ($line =~ /^info\b/) {
      if ($line =~ /^info string Thinking\.\.\.\s*(.*)$/) {
        my $msg = $1 // '';
        $msg =~ s/\s+$//;
        log_info("Thinking... $msg in $game->{id}");
        next;
      }
      if ($line =~ /\bdepth\s+(\d+)/) {
        $analysis{depth} = $1 + 0;
      }
      if ($line =~ /\bscore\s+cp\s+(-?\d+)/) {
        $analysis{cp} = $1 + 0;
        delete $analysis{mate};
      } elsif ($line =~ /\bscore\s+mate\s+(-?\d+)/) {
        $analysis{mate} = $1 + 0;
        delete $analysis{cp};
      }
      if ($line =~ /\bpv\s+(\S+)/) {
        $analysis{candidate} = $1;
      }
      next;
    }
    if ($line =~ /^bestmove\s+(\S+)/) {
      $analysis{move} = $1;
      $analysis{elapsed_ms} = int((time - $started_at) * 1000);
      return \%analysis;
    }
  }
  $analysis{elapsed_ms} = int((time - $started_at) * 1000);
  return \%analysis;
}

sub send_move {
  my ($game_id, $move, $opts) = @_;
  $opts ||= {};
  my %query;
  if ($opts->{offer_draw}) {
    $query{offeringDraw} = 'true';
  }
  my $res = http_request('POST', "/bot/game/$game_id/move/$move", {
    query => \%query,
  });
  if (!$res->{success}) {
    my $extra = '';
    if (defined $res->{content} && length $res->{content}) {
      my $body = $res->{content};
      $body =~ s/\s+/ /g;
      $body = substr($body, 0, 180);
      $extra = " body='$body'";
    }
    log_warn("Move $move for $game_id was rejected: " . $res->{status_line} . $extra);
    return $res;
  }
  return $res;
}

sub uci_handshake {
  my ($engine_out, $engine_in) = @_;
  print {$engine_in} "uci\n";
  my %meta = (
    has_ownbook => 0,
    has_depth_option => 0,
    depth_min => undef,
    depth_max => undef,
    depth_default => undef,
  );
  while (my $line = <$engine_out>) {
    $line =~ s/[\r\n]+$//;
    if ($line =~ /^option\s+name\s+(.+?)\s+type\s+(\S+)\s*(.*)$/i) {
      my $name = lc($1 // '');
      my $type = lc($2 // '');
      my $tail = $3 // '';
      $name =~ s/\s+$//;
      $meta{has_ownbook} = 1 if $name eq 'ownbook';
      if ($name eq 'depth' && $type eq 'spin') {
        $meta{has_depth_option} = 1;
        $meta{depth_default} = $1 + 0 if $tail =~ /\bdefault\s+(-?\d+)/i;
        $meta{depth_min} = $1 + 0 if $tail =~ /\bmin\s+(-?\d+)/i;
        $meta{depth_max} = $1 + 0 if $tail =~ /\bmax\s+(-?\d+)/i;
      }
    }
    last if $line =~ /^uciok/;
  }
  if ($meta{has_ownbook}) {
    print {$engine_in} "setoption name OwnBook value true\n";
  }
  if ($meta{has_depth_option}) {
    $meta{depth_min} = 1 unless defined $meta{depth_min};
    $meta{depth_max} = 20 unless defined $meta{depth_max};
    if (!defined $meta{depth_default}) {
      $meta{depth_default} = $meta{depth_min};
    }
  }
  print {$engine_in} "isready\n";
  while (my $line = <$engine_out>) {
    $line =~ s/[\r\n]+$//;
    return \%meta if $line =~ /^readyok/;
  }
  return;
}

sub lichess_json_get {
  my ($path) = @_;
  my $res = http_request('GET', $path);
  $res->{success}
    or die "Request to $path failed: " . $res->{status_line} . "\n";
  return decode_json($res->{content});
}
sub log_info {
  my ($msg) = @_;
  _emit_log('INFO', $msg);
}

sub log_warn {
  my ($msg) = @_;
  _emit_log('WARN', $msg);
}

sub log_debug {
  my ($msg) = @_;
  return unless $debug;
  _emit_log('DEBUG', $msg);
}

sub _emit_log {
  my ($level, $msg) = @_;
  my $ts = scalar gmtime;
  warn "[$ts] $level $msg\n";
}

sub _drain_ndjson {
  my ($path, $buffer_ref, $callback) = @_;
  while (1) {
    my $newline_idx = index($$buffer_ref, "\n");
    last if $newline_idx < 0;
    my $line = substr($$buffer_ref, 0, $newline_idx + 1, '');
    $line =~ s/\r?\n$//;
    next unless length $line;
    if ($line =~ /^[0-9a-f]+$/i) {
      log_debug("Skipping chunk marker on $path: $line") if $debug;
      next;
    }
    log_debug("NDJSON $path: $line") if $debug;
    my $payload = eval { decode_json($line) };
    if ($@) {
      log_warn("Failed to decode payload '$line': $@");
      next;
    }
    $callback->($payload);
  }
}

sub _read_http_headers {
  my ($fh) = @_;
  my %headers;
  my $status_line = _read_line($fh);
  return {} unless defined $status_line;
  $status_line =~ s/\r?\n$//;
  $headers{status_line} = $status_line;
  if ($status_line =~ m{^HTTP/\S+\s+(\d+)}) {
    $headers{status} = $1;
  }
  while (defined(my $line = _read_line($fh))) {
    last if $line =~ /^\r?\n$/;
    $line =~ s/\r?\n$//;
    my $colon = index($line, ':');
    next unless $colon > 0;
    my $key = lc substr($line, 0, $colon);
    my $value = substr($line, $colon + 1);
    $value =~ s/^\s+//;
    $headers{$key} = $value;
  }
  return \%headers;
}

sub _consume_chunked {
  my ($fh, $cb) = @_;
  while (1) {
    my $len_line = _read_line($fh);
    return 0 unless defined $len_line;
    $len_line =~ s/\r?\n$//;
    $len_line =~ s/;.*$//;
    my $len = eval { hex($len_line) };
    return 0 if !defined $len;
    last if $len == 0;
    my $chunk = _read_exact($fh, $len);
    return 0 unless defined $chunk;
    $cb->($chunk);
    _read_exact($fh, 2); # consume CRLF
  }
  return 1;
}

sub _socket_buffer_ref {
  my ($fh) = @_;
  my $id = fileno($fh);
  return unless defined $id;
  $socket_read_buffers{$id} //= '';
  return \$socket_read_buffers{$id};
}

sub _clear_socket_buffer {
  my ($fh) = @_;
  my $id = fileno($fh);
  return unless defined $id;
  delete $socket_read_buffers{$id};
}

sub _read_line {
  my ($fh) = @_;
  my $buf_ref = _socket_buffer_ref($fh);
  return unless defined $buf_ref;

  while (1) {
    my $newline_idx = index($$buf_ref, "\n");
    if ($newline_idx >= 0) {
      return substr($$buf_ref, 0, $newline_idx + 1, '');
    }

    my $chunk = '';
    my $rv = sysread($fh, $chunk, 4096);
    return if !defined $rv;
    if ($rv == 0) {
      return unless length $$buf_ref;
      return substr($$buf_ref, 0, length($$buf_ref), '');
    }
    $$buf_ref .= $chunk;
  }
}

sub _read_exact {
  my ($fh, $len) = @_;
  return '' if !defined $len || $len <= 0;

  my $buf_ref = _socket_buffer_ref($fh);
  return unless defined $buf_ref;

  my $data = '';
  if (length($$buf_ref)) {
    my $take = length($$buf_ref) >= $len ? $len : length($$buf_ref);
    $data = substr($$buf_ref, 0, $take, '');
    return $data if length($data) >= $len;
  }

  while (length($data) < $len) {
    my $remaining = $len - length($data);
    my $chunk = '';
    my $rv = sysread($fh, $chunk, ($remaining > 8192 ? 8192 : $remaining));
    return unless defined $rv && $rv > 0;
    $data .= $chunk;
  }
  return $data;
}

sub _read_all {
  my ($fh) = @_;
  my $buf_ref = _socket_buffer_ref($fh);
  my $data = defined $buf_ref ? substr($$buf_ref, 0, length($$buf_ref), '') : '';
  while (1) {
    my $chunk = '';
    my $rv = sysread($fh, $chunk, 4096);
    last unless $rv;
    $data .= $chunk;
  }
  return $data;
}

sub load_env {
  my ($path) = @_;
  return unless -e $path;
  open my $fh, '<', $path or die "Unable to open $path: $!";
  while (my $line = <$fh>) {
    $line =~ s/[\r\n]+$//;
    next if $line =~ /^\s*#/;
    next unless length $line;
    if ($line =~ /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/) {
      my ($key, $val) = ($1, $2);
      $val =~ s/^['"]// && $val =~ s/['"]$//;
      $ENV{$key} = $val unless exists $ENV{$key};
    }
  }
  close $fh;
}

sub _open_lichess_socket {
  my @errors;
  my @ssl_attempts = (
    {
      label => 'default',
      args  => {},
    },
    {
      label => 'force-ipv4',
      args  => {
        Family           => AF_INET,
        GetAddrInfoFlags => 0,
      },
    },
  );

  foreach my $attempt (@ssl_attempts) {
    my $sock = IO::Socket::SSL->new(
      PeerHost        => 'lichess.org',
      PeerPort        => 443,
      Proto           => 'tcp',
      Timeout         => 15,
      SSL_verify_mode => SSL_VERIFY_PEER(),
      SSL_ca_file     => $ssl_ca_file,
      SNI_hostname    => 'lichess.org',
      %{$attempt->{args}},
    );
    if ($sock) {
      $sock->autoflush(1);
      $last_tls_error = '';
      return $sock;
    }
    my $err = IO::Socket::SSL::errstr() // 'unknown';
    push @errors, "$attempt->{label}: $err";
  }

  my $plain = IO::Socket::INET->new(
    PeerAddr => 'lichess.org',
    PeerPort => 443,
    Proto    => 'tcp',
    Timeout  => 15,
  );

  if ($plain) {
    my $sock = IO::Socket::SSL->start_SSL(
      $plain,
      SSL_verify_mode => SSL_VERIFY_PEER(),
      SSL_ca_file     => $ssl_ca_file,
      SSL_hostname    => 'lichess.org',
      SNI_hostname    => 'lichess.org',
    );
    if ($sock) {
      $sock->autoflush(1);
      $last_tls_error = '';
      return $sock;
    }
    my $err = IO::Socket::SSL::errstr() // 'unknown';
    push @errors, "inet+start_ssl: $err";
  } else {
    my $err = $! ? "$!" : 'unable to open TCP socket';
    push @errors, "inet-connect: $err";
  }

  my $hint = '';
  if (grep { /name resolution|getaddrinfo|IO::Socket::IP configuration failed/i } @errors) {
    $hint = ' (check DNS/network connectivity for lichess.org)';
  }
  $last_tls_error = join('; ', @errors) . $hint;
  return;
}

sub _write_http_request {
  my ($sock, $method, $path, $headers, $body) = @_;
  $method = uc($method // 'GET');
  $path ||= '/';
  my $request = sprintf "%s %s HTTP/1.1\r\n", $method, $path;
  foreach my $key (keys %{$headers || {}}) {
    my $value = $headers->{$key};
    $request .= "$key: $value\r\n";
  }
  $request .= "\r\n";
  $request .= $body if defined $body && length $body;
  my $ok = print {$sock} $request;
  return $ok ? 1 : 0;
}

sub _http_error_response {
  my ($err) = @_;
  $err //= 'unknown';
  return {
    success     => 0,
    status      => 0,
    reason      => $err,
    status_line => "IO::Socket::SSL error: $err",
    content     => '',
  };
}

sub _drop_http_request_socket {
  my ($sock) = @_;
  $sock //= $http_request_sock;
  if ($sock) {
    _clear_socket_buffer($sock);
    close $sock;
  }
  $http_request_sock = undef;
  $http_request_sock_pid = $$;
}

sub _acquire_http_request_socket {
  if ($http_request_sock && $http_request_sock_pid != $$) {
    _drop_http_request_socket($http_request_sock);
  }
  if ($http_request_sock && !defined fileno($http_request_sock)) {
    _drop_http_request_socket($http_request_sock);
  }
  if ($http_request_sock) {
    return ($http_request_sock, 1);
  }
  my $sock = _open_lichess_socket();
  return unless $sock;
  $http_request_sock = $sock;
  $http_request_sock_pid = $$;
  return ($http_request_sock, 0);
}

sub _http_response_has_body {
  my ($method, $status) = @_;
  $method = uc($method // 'GET');
  $status = defined $status ? $status + 0 : 0;
  return 0 if $method eq 'HEAD';
  return 0 if $status >= 100 && $status < 200;
  return 0 if $status == 204 || $status == 304;
  return 1;
}

sub http_request {
  my ($method, $path, $opts) = @_;
  $opts ||= {};
  $method = uc($method // 'GET');
  my $relative = $path // '/';
  $relative = "/$relative" unless $relative =~ m{^/};
  $relative = "/api$relative" unless $relative =~ m{^/api/};

  if (my $query = $opts->{query}) {
    my $qs = _encode_query($query);
    $relative .= ($relative =~ /\?/ ? '&' : '?') . $qs if length $qs;
  }

  my $content = '';
  if (my $form = $opts->{form}) {
    $content = _encode_form($form);
    $opts->{headers}{'Content-Type'} //= 'application/x-www-form-urlencoded';
  } elsif (exists $opts->{content}) {
    $content = $opts->{content};
  }

  my $allow_cached_retry = 1;
  while (1) {
    my ($sock, $from_cache) = _acquire_http_request_socket();
    unless ($sock) {
      my $err = $last_tls_error || IO::Socket::SSL::errstr() || 'unknown';
      return _http_error_response($err);
    }

    my %headers = (
      'Host'          => 'lichess.org',
      'Authorization' => $auth_header,
      'User-Agent'    => $user_agent,
      'Accept'        => $opts->{accept} // 'application/json',
      'Connection'    => 'keep-alive',
    );
    if (my $extra = $opts->{headers}) {
      foreach my $key (keys %$extra) {
        $headers{$key} = $extra->{$key};
      }
    }
    if (length $content) {
      $headers{'Content-Length'} = length($content);
    } elsif ($method =~ /^(?:POST|PUT|PATCH)$/) {
      $headers{'Content-Length'} = 0;
    }

    my $write_ok = _write_http_request($sock, $method, $relative, \%headers, $content);
    unless ($write_ok) {
      my $err = $! ? "$!" : 'unable to write request';
      _drop_http_request_socket($sock);
      if ($from_cache && $allow_cached_retry) {
        $allow_cached_retry = 0;
        log_debug("Retrying $method $relative after keep-alive write failure: $err");
        next;
      }
      return _http_error_response($err);
    }

    my $resp_headers = _read_http_headers($sock);
    unless ($resp_headers->{status_line}) {
      my $err = $! ? "$!" : 'empty HTTP response';
      _drop_http_request_socket($sock);
      if ($from_cache && $allow_cached_retry) {
        $allow_cached_retry = 0;
        log_debug("Retrying $method $relative after keep-alive read failure: $err");
        next;
      }
      return _http_error_response($err);
    }

    my $status_line = $resp_headers->{status_line} // 'HTTP/1.1 000';
    my ($status, $reason) = $status_line =~ m{^HTTP/\S+\s+(\d+)\s*(.*)$};
    $reason //= '';

    my $body = '';
    my $body_complete = 1;
    my $read_mode = 'none';
    my $te = $resp_headers->{'transfer-encoding'} // '';
    if (_http_response_has_body($method, $status)) {
      if ($te =~ /chunked/i) {
        $read_mode = 'chunked';
        my $ok = _consume_chunked($sock, sub { $body .= shift });
        if (!$ok) {
          $body = '';
          $body_complete = 0;
        }
      } elsif (defined(my $len = $resp_headers->{'content-length'})) {
        $read_mode = 'length';
        my $data = _read_exact($sock, $len);
        if (defined $data) {
          $body = $data;
        } else {
          $body = '';
          $body_complete = 0;
        }
      } else {
        $read_mode = 'until-close';
        $body = _read_all($sock);
      }
    }

    my $request_conn = lc($headers{'Connection'} // '');
    my $response_conn = lc($resp_headers->{'connection'} // '');
    my $can_reuse =
      $body_complete
      && $request_conn ne 'close'
      && $response_conn !~ /\bclose\b/
      && ($read_mode eq 'none' || $read_mode eq 'chunked' || $read_mode eq 'length');

    if (!$can_reuse) {
      _drop_http_request_socket($sock);
    }

    return {
      success     => ($status && $status >= 200 && $status < 300) ? 1 : 0,
      status      => $status // 0,
      reason      => $reason,
      status_line => $status_line,
      content     => $body // '',
    };
  }
}

sub _encode_form {
  my ($form) = @_;
  my @pairs;
  foreach my $key (sort keys %$form) {
    my $value = defined $form->{$key} ? $form->{$key} : '';
    push @pairs, join('=', _form_escape($key), _form_escape($value));
  }
  return join '&', @pairs;
}

sub _encode_query {
  my ($params) = @_;
  my @pairs;
  foreach my $key (sort keys %$params) {
    my $value = defined $params->{$key} ? $params->{$key} : '';
    push @pairs, join('=', _query_escape($key), _query_escape($value));
  }
  return join '&', @pairs;
}

sub _form_escape {
  my ($text) = @_;
  $text //= '';
  $text =~ s/([^A-Za-z0-9_\-\.~ ])/sprintf '%%%02X', ord($1)/ge;
  $text =~ s/ /+/g;
  return $text;
}

sub _query_escape {
  my ($text) = @_;
  $text //= '';
  $text =~ s/([^A-Za-z0-9_\-\.~])/sprintf '%%%02X', ord($1)/ge;
  return $text;
}

sub _next_backoff_delay {
  my ($delay, $max) = @_;
  $delay = 1 unless defined $delay && $delay > 0;
  $max = 30 unless defined $max && $max > 0;
  my $next = $delay * 2;
  return ($next > $max) ? $max : $next;
}

sub stream_ndjson {
  my ($path, $callback) = @_;
  my $attempt = 0;
  my $is_game_stream = ($path =~ m{/bot/game/stream/}) ? 1 : 0;
  my $retry_limit = $is_game_stream ? 5 : 0;
  my $retry_delay = 1;
  my $max_retry_delay = $is_game_stream ? 4 : 30;

  while (1) {
    $attempt ++;
    log_info("Opening stream $path (attempt $attempt)");
    my $sock = _open_lichess_socket();
    if (!$sock) {
      my $err = $last_tls_error || IO::Socket::SSL::errstr() || 'unknown';
      if ($retry_limit && $attempt >= $retry_limit) {
        log_warn("Unable to open TLS socket for $path after $attempt attempts: $err");
        return 0;
      }
      log_warn("Unable to open TLS socket: $err");
      log_info("Retrying stream $path in ${retry_delay}s");
      sleep $retry_delay;
      $retry_delay = _next_backoff_delay($retry_delay, $max_retry_delay);
      next;
    }

    my %headers = (
      'Host'          => 'lichess.org',
      'Authorization' => "Bearer $token",
      'Accept'        => 'application/x-ndjson',
      'User-Agent'    => $user_agent,
      'Connection'    => 'keep-alive',
    );
    _write_http_request($sock, 'GET', "/api$path", \%headers, '');

    my $headers = _read_http_headers($sock);
    if (!$headers->{status} || $headers->{status} !~ /^2/) {
      my $status_line = $headers->{status_line} // 'unknown';
      my $body = _read_all($sock);
      log_warn("Stream $path failed: $status_line body=$body");
      _clear_socket_buffer($sock);
      close $sock;
      if ($retry_limit && $attempt >= $retry_limit) {
        log_warn("Giving up stream $path after $attempt attempts");
        return 0;
      }
      log_info("Retrying stream $path in ${retry_delay}s");
      sleep $retry_delay;
      $retry_delay = _next_backoff_delay($retry_delay, $max_retry_delay);
      next;
    }

    log_info("Stream $path status " . ($headers->{status_line} // 'unknown'));
    my $buffer = '';
    my $ok = 0;
    my $te = $headers->{'transfer-encoding'} // '';
    if ($te =~ /chunked/i) {
      while (1) {
        my $len_line = _read_line($sock);
        last unless defined $len_line;
        $len_line =~ s/\r?\n$//;
        $len_line =~ s/;.*$//;
        next if $len_line eq '';
        my $len = eval { hex($len_line) };
        last if !defined $len;
        last if $len == 0;
        my $chunk = _read_exact($sock, $len);
        last unless defined $chunk;
        _read_exact($sock, 2);
        $buffer .= $chunk;
        _drain_ndjson($path, \$buffer, $callback);
        $ok = 1;
      }
    } else {
      while (1) {
        my $chunk = '';
        my $rv = sysread($sock, $chunk, 4096);
        last unless defined $rv && $rv > 0;
        $buffer .= $chunk;
        _drain_ndjson($path, \$buffer, $callback);
        $ok = 1;
      }
    }

    _clear_socket_buffer($sock);
    close $sock;

    if ($ok) {
      log_info("Stream $path completed");
      return 1;
    }

    log_warn("Stream $path closed unexpectedly");

    if ($is_game_stream) {
      if ($attempt >= $retry_limit) {
        return 0;
      }
      log_info("Retrying game stream $path in ${retry_delay}s");
      sleep $retry_delay;
      $retry_delay = _next_backoff_delay($retry_delay, $max_retry_delay);
      next;
    }

    return 0;
  }
}
