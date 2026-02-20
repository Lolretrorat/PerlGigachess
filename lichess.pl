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
use Chess::Book ();
use Chess::TableUtil qw(canonical_fen_key);

eval {
  require IO::Socket::SSL;
  IO::Socket::SSL->import();
  require Mozilla::CA;
  1;
} or die "Install IO::Socket::SSL and Mozilla::CA to use lichess.pl: $@";

my $loaded_as_library = caller ? 1 : 0;
load_env("$RealBin/.env");

my $dry_run = $ENV{LICHESS_DRY_RUN} ? 1 : 0;
my $token = $ENV{LICHESS_TOKEN} // '';
my $engine_cmd = $ENV{LICHESS_ENGINE_CMD} // "$^X $RealBin/play.pl --uci";
my @engine_parts = shellwords($engine_cmd);
@engine_parts or die "Unable to parse LICHESS_ENGINE_CMD '$engine_cmd'\n";
my $think_tank_ms = $ENV{LICHESS_THINK_TANK_MS};
$think_tank_ms = 3000 unless defined $think_tank_ms && $think_tank_ms =~ /^\d+$/;
my $git_branch = _git_branch_name();
my $is_develop_branch = defined($git_branch) && lc($git_branch) eq 'develop' ? 1 : 0;
my $branch_override_allowed = _branch_override_allowed($git_branch);
my $depth_override = $ENV{LICHESS_DEPTH_OVERRIDE};
if (defined $depth_override) {
  if ($depth_override =~ /^-?\d+$/) {
    $depth_override = int($depth_override);
  } else {
    $depth_override = undef;
  }
}
my $is_production_profile = $branch_override_allowed ? 0 : 1;

my $prod_opening_boost_mult = $ENV{LICHESS_PROD_OPENING_MULT};
if (!defined $prod_opening_boost_mult || $prod_opening_boost_mult !~ /^\d+(?:\.\d+)?$/) {
  $prod_opening_boost_mult = 1.20;
}
$prod_opening_boost_mult += 0;
$prod_opening_boost_mult = 1.0 if $prod_opening_boost_mult < 1.0;
$prod_opening_boost_mult = 2.0 if $prod_opening_boost_mult > 2.0;

my $prod_opening_boost_plies = $ENV{LICHESS_PROD_OPENING_PLIES};
if (!defined $prod_opening_boost_plies || $prod_opening_boost_plies !~ /^\d+$/) {
  $prod_opening_boost_plies = 18;
}
$prod_opening_boost_plies = int($prod_opening_boost_plies);
$prod_opening_boost_plies = 0 if $prod_opening_boost_plies < 0;
$prod_opening_boost_plies = 80 if $prod_opening_boost_plies > 80;

my $prod_opening_cap_mult = $ENV{LICHESS_PROD_OPENING_CAP_MULT};
if (!defined $prod_opening_cap_mult || $prod_opening_cap_mult !~ /^\d+(?:\.\d+)?$/) {
  $prod_opening_cap_mult = 1.25;
}
$prod_opening_cap_mult += 0;
$prod_opening_cap_mult = 1.0 if $prod_opening_cap_mult < 1.0;
$prod_opening_cap_mult = 2.0 if $prod_opening_cap_mult > 2.0;

my $prod_opening_floor_ms = $ENV{LICHESS_PROD_OPENING_FLOOR_MS};
if (!defined $prod_opening_floor_ms || $prod_opening_floor_ms !~ /^\d+$/) {
  $prod_opening_floor_ms = 8000;
}
$prod_opening_floor_ms = int($prod_opening_floor_ms);
$prod_opening_floor_ms = 0 if $prod_opening_floor_ms < 0;
$prod_opening_floor_ms = 30_000 if $prod_opening_floor_ms > 30_000;

my $prod_opening_floor_plies = $ENV{LICHESS_PROD_OPENING_FLOOR_PLIES};
if (!defined $prod_opening_floor_plies || $prod_opening_floor_plies !~ /^\d+$/) {
  $prod_opening_floor_plies = 16;
}
$prod_opening_floor_plies = int($prod_opening_floor_plies);
$prod_opening_floor_plies = 0 if $prod_opening_floor_plies < 0;
$prod_opening_floor_plies = 80 if $prod_opening_floor_plies > 80;

my $prod_think_mult = $ENV{LICHESS_PROD_THINK_MULT};
if (!defined $prod_think_mult || $prod_think_mult !~ /^\d+(?:\.\d+)?$/) {
  $prod_think_mult = 1.18;
}
$prod_think_mult += 0;
$prod_think_mult = 1.0 if $prod_think_mult < 1.0;
$prod_think_mult = 2.0 if $prod_think_mult > 2.0;

my $prod_cap_mult = $ENV{LICHESS_PROD_CAP_MULT};
if (!defined $prod_cap_mult || $prod_cap_mult !~ /^\d+(?:\.\d+)?$/) {
  $prod_cap_mult = 1.35;
}
$prod_cap_mult += 0;
$prod_cap_mult = 1.0 if $prod_cap_mult < 1.0;
$prod_cap_mult = 2.0 if $prod_cap_mult > 2.0;

my $prod_floor_ms = $ENV{LICHESS_PROD_FLOOR_MS};
if (!defined $prod_floor_ms || $prod_floor_ms !~ /^\d+$/) {
  $prod_floor_ms = 2600;
}
$prod_floor_ms = int($prod_floor_ms);
$prod_floor_ms = 0 if $prod_floor_ms < 0;
$prod_floor_ms = 30_000 if $prod_floor_ms > 30_000;

my $post_book_think_mult = $ENV{LICHESS_POST_BOOK_THINK_MULT};
if (!defined $post_book_think_mult || $post_book_think_mult !~ /^\d+(?:\.\d+)?$/) {
  $post_book_think_mult = 1.12;
}
$post_book_think_mult += 0;
$post_book_think_mult = 1.0 if $post_book_think_mult < 1.0;
$post_book_think_mult = 2.0 if $post_book_think_mult > 2.0;

my $post_book_cap_mult = $ENV{LICHESS_POST_BOOK_CAP_MULT};
if (!defined $post_book_cap_mult || $post_book_cap_mult !~ /^\d+(?:\.\d+)?$/) {
  $post_book_cap_mult = 1.18;
}
$post_book_cap_mult += 0;
$post_book_cap_mult = 1.0 if $post_book_cap_mult < 1.0;
$post_book_cap_mult = 2.0 if $post_book_cap_mult > 2.0;

my $repetition_avoid_cp = $ENV{LICHESS_REPETITION_AVOID_CP};
if (!defined $repetition_avoid_cp || $repetition_avoid_cp !~ /^-?\d+$/) {
  $repetition_avoid_cp = 30;
}
$repetition_avoid_cp = int($repetition_avoid_cp);
$repetition_avoid_cp = 0 if $repetition_avoid_cp < 0;
$repetition_avoid_cp = 1000 if $repetition_avoid_cp > 1000;

my $repetition_seek_cp = $ENV{LICHESS_REPETITION_SEEK_CP};
if (!defined $repetition_seek_cp || $repetition_seek_cp !~ /^-?\d+$/) {
  $repetition_seek_cp = -30;
}
$repetition_seek_cp = int($repetition_seek_cp);
$repetition_seek_cp = -$repetition_seek_cp if $repetition_seek_cp > 0;
$repetition_seek_cp = -1000 if $repetition_seek_cp < -1000;

my $repetition_keep_best_cp = $ENV{LICHESS_REPETITION_KEEP_BEST_CP};
if (!defined $repetition_keep_best_cp || $repetition_keep_best_cp !~ /^\d+$/) {
  $repetition_keep_best_cp = 45;
}
$repetition_keep_best_cp = int($repetition_keep_best_cp);
$repetition_keep_best_cp = 0 if $repetition_keep_best_cp < 0;
$repetition_keep_best_cp = 1000 if $repetition_keep_best_cp > 1000;

my $repetition_max_reorder_drop = $ENV{LICHESS_REPETITION_MAX_REORDER_SCORE_DROP};
if (!defined $repetition_max_reorder_drop || $repetition_max_reorder_drop !~ /^\d+$/) {
  $repetition_max_reorder_drop = 1400;
}
$repetition_max_reorder_drop = int($repetition_max_reorder_drop);
$repetition_max_reorder_drop = 0 if $repetition_max_reorder_drop < 0;
$repetition_max_reorder_drop = 20000 if $repetition_max_reorder_drop > 20000;

my $repetition_rethink_mult = $ENV{LICHESS_REPETITION_RETHINK_MULT};
if (!defined $repetition_rethink_mult || $repetition_rethink_mult !~ /^\d+(?:\.\d+)?$/) {
  $repetition_rethink_mult = 1.60;
}
$repetition_rethink_mult += 0;
$repetition_rethink_mult = 1.0 if $repetition_rethink_mult < 1.0;
$repetition_rethink_mult = 3.0 if $repetition_rethink_mult > 3.0;

my $repetition_guard_disable_below_ms = $ENV{LICHESS_REPETITION_GUARD_DISABLE_BELOW_MS};
if (!defined $repetition_guard_disable_below_ms || $repetition_guard_disable_below_ms !~ /^\d+$/) {
  $repetition_guard_disable_below_ms = 8_000;
}
$repetition_guard_disable_below_ms = int($repetition_guard_disable_below_ms);
$repetition_guard_disable_below_ms = 0 if $repetition_guard_disable_below_ms < 0;
$repetition_guard_disable_below_ms = 60_000 if $repetition_guard_disable_below_ms > 60_000;

my $repetition_rethink_min_clock_ms = $ENV{LICHESS_REPETITION_RETHINK_MIN_CLOCK_MS};
if (!defined $repetition_rethink_min_clock_ms || $repetition_rethink_min_clock_ms !~ /^\d+$/) {
  $repetition_rethink_min_clock_ms = 25_000;
}
$repetition_rethink_min_clock_ms = int($repetition_rethink_min_clock_ms);
$repetition_rethink_min_clock_ms = 0 if $repetition_rethink_min_clock_ms < 0;
$repetition_rethink_min_clock_ms = 120_000 if $repetition_rethink_min_clock_ms > 120_000;

my $repetition_rethink_min_budget_multiple = $ENV{LICHESS_REPETITION_RETHINK_MIN_BUDGET_MULT};
if (!defined $repetition_rethink_min_budget_multiple || $repetition_rethink_min_budget_multiple !~ /^\d+(?:\.\d+)?$/) {
  $repetition_rethink_min_budget_multiple = 8.0;
}
$repetition_rethink_min_budget_multiple += 0;
$repetition_rethink_min_budget_multiple = 1.0 if $repetition_rethink_min_budget_multiple < 1.0;
$repetition_rethink_min_budget_multiple = 20.0 if $repetition_rethink_min_budget_multiple > 20.0;

my $eval_drop_extra_think_cp = $ENV{LICHESS_EVAL_DROP_EXTRA_THINK_CP};
if (!defined $eval_drop_extra_think_cp || $eval_drop_extra_think_cp !~ /^\d+$/) {
  $eval_drop_extra_think_cp = 40;
}
$eval_drop_extra_think_cp = int($eval_drop_extra_think_cp);
$eval_drop_extra_think_cp = 0 if $eval_drop_extra_think_cp < 0;
$eval_drop_extra_think_cp = 1000 if $eval_drop_extra_think_cp > 1000;

my $eval_drop_extra_think_mult = $ENV{LICHESS_EVAL_DROP_EXTRA_THINK_MULT};
if (!defined $eval_drop_extra_think_mult || $eval_drop_extra_think_mult !~ /^\d+(?:\.\d+)?$/) {
  $eval_drop_extra_think_mult = 1.55;
}
$eval_drop_extra_think_mult += 0;
$eval_drop_extra_think_mult = 1.0 if $eval_drop_extra_think_mult < 1.0;
$eval_drop_extra_think_mult = 3.0 if $eval_drop_extra_think_mult > 3.0;

my $develop_depth_bump = $ENV{LICHESS_DEVELOP_DEPTH_BUMP};
if (!defined $develop_depth_bump || $develop_depth_bump !~ /^-?\d+$/) {
  $develop_depth_bump = $is_develop_branch ? 1 : 0;
}
$develop_depth_bump = int($develop_depth_bump);
$develop_depth_bump = 0 if $develop_depth_bump < 0;
$develop_depth_bump = 4 if $develop_depth_bump > 4;

my $develop_think_mult = $ENV{LICHESS_DEVELOP_THINK_MULT};
if (!defined $develop_think_mult || $develop_think_mult !~ /^\d+(?:\.\d+)?$/) {
  $develop_think_mult = $is_develop_branch ? 1.12 : 1.0;
}
$develop_think_mult += 0;
$develop_think_mult = 1.0 if $develop_think_mult < 1.0;
$develop_think_mult = 2.0 if $develop_think_mult > 2.0;

my $develop_cap_mult = $ENV{LICHESS_DEVELOP_CAP_MULT};
if (!defined $develop_cap_mult || $develop_cap_mult !~ /^\d+(?:\.\d+)?$/) {
  $develop_cap_mult = $is_develop_branch ? 1.10 : 1.0;
}
$develop_cap_mult += 0;
$develop_cap_mult = 1.0 if $develop_cap_mult < 1.0;
$develop_cap_mult = 2.0 if $develop_cap_mult > 2.0;

STDOUT->autoflush(1);
STDERR->autoflush(1);

my $debug = $ENV{LICHESS_DEBUG} // 0;
my %handled_challenges;
my %game_pid_by_id;
my %game_id_by_pid;

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
  bullet    => 11,
  blitz     => 13,
  rapid     => 15,
  classical => 17,
  unlimited => 18,
);
my %speed_horizon_targets = (
  bullet    => 72,
  blitz     => 56,
  rapid     => 40,
  classical => 30,
  unlimited => 26,
);

unless (caller) {
  exit main();
}

sub main {
  $SIG{INT}  = sub { log_info('Received SIGINT; shutting down'); exit 0 };
  $SIG{TERM} = sub { log_info('Received SIGTERM; shutting down'); exit 0 };
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
  log_info("Logged in as $account->{username} ($bot_id). branch=$branch_desc depth_override=$depth_desc");
  if ($is_production_profile) {
    my $mult = sprintf('%.2f', $prod_opening_boost_mult);
    my $cap_mult = sprintf('%.2f', $prod_opening_cap_mult);
    log_info("Production opening time boost enabled: mult=$mult plies=$prod_opening_boost_plies cap_mult=$cap_mult floor_ms=$prod_opening_floor_ms floor_plies=$prod_opening_floor_plies");
    my $think_mult = sprintf('%.2f', $prod_think_mult);
    my $think_cap = sprintf('%.2f', $prod_cap_mult);
    log_info("Production think boost enabled: think_mult=$think_mult cap_mult=$think_cap floor_ms=$prod_floor_ms");
  }
  if ($is_develop_branch) {
    my $think_mult = sprintf('%.2f', $develop_think_mult);
    my $cap_mult = sprintf('%.2f', $develop_cap_mult);
    log_info("Develop depth/think profile: depth_bump=$develop_depth_bump think_mult=$think_mult cap_mult=$cap_mult");
  }
  my $post_book_mult = sprintf('%.2f', $post_book_think_mult);
  my $post_book_cap = sprintf('%.2f', $post_book_cap_mult);
  log_info("Post-book think profile: think_mult=$post_book_mult cap_mult=$post_book_cap");
  _log_syzygy_runtime_status();

  stream_events();
  return 0;
}

sub _log_syzygy_runtime_status {
  my $enabled = $ENV{CHESS_SYZYGY_ENABLED};
  if (defined $enabled && length $enabled) {
    my $norm = lc $enabled;
    if ($norm =~ /^(?:0|false|off|no)$/) {
      log_info('Syzygy probing disabled by CHESS_SYZYGY_ENABLED');
      return;
    }
  }
  my @paths = _syzygy_paths();
  if (!@paths) {
    log_warn('Syzygy probing unavailable: set CHESS_SYZYGY_PATH to one or more local tablebase directories');
    return;
  }
  log_info('Syzygy probing enabled for up to ' . _syzygy_max_pieces() . ' pieces');
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
      log_warn('Event stream closed unexpectedly; reconnecting');
    }
    sleep 2;
  }
}

sub reap_children {
  while (1) {
    my $kid = waitpid(-1, WNOHANG);
    last if !defined $kid || $kid <= 0;
    if (my $game_id = delete $game_id_by_pid{$kid}) {
      delete $game_pid_by_id{$game_id};
    }
    log_debug("Reaped child pid $kid");
  }
}

sub run_dry_run {
  log_info('Running Lichess dry run (no network)');
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
    stop_game_handler($game_id) if $game_id ne 'unknown';
    log_finished_game_url($game);
  } else {
    log_info("Ignoring unhandled event type '$type'");
  }
}

sub stop_game_handler {
  my ($game_id) = @_;
  return unless defined $game_id && length $game_id;
  my $pid = delete $game_pid_by_id{$game_id};
  return unless defined $pid;
  delete $game_id_by_pid{$pid};
  if (kill 'TERM', $pid) {
    log_info("Stopped handler pid $pid for finished game $game_id");
  } else {
    log_debug("Handler pid $pid for $game_id already exited");
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
    my $id = $game->{id} // 'unknown';
    log_warn("Could not determine URL for finished game $id");
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
    log_warn('Challenge event is missing challenge payload; ignoring');
    return;
  }

  my $id = $challenge->{id};
  unless (defined $id && length $id) {
    log_warn('Challenge event is missing id; ignoring');
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
  if (my $existing = $game_pid_by_id{$game_id}) {
    log_debug("Game $game_id already has handler pid $existing");
    return;
  }
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
  $game_pid_by_id{$game_id} = $pid;
  $game_id_by_pid{$pid} = $game_id;
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
    my $resolved_color = _resolve_my_color_from_gamefull($event, $game->{my_color});
    if (defined $resolved_color) {
      my $prior = normalize_color($game->{my_color});
      if (defined $prior && $prior ne $resolved_color) {
        log_warn("Resolved game color changed for $game->{id}: $prior -> $resolved_color");
      }
      $game->{my_color} = $resolved_color;
    }
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
    _set_game_time_control($game, $event);
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
  return [] unless defined $moves;
  if (ref $moves eq 'ARRAY') {
    my @list = grep { defined $_ && length $_ } @$moves;
    return \@list;
  }
  return [] if ref $moves;

  $moves =~ s/^\s+//;
  $moves =~ s/\s+$//;
  return [] unless length $moves;
  my @list = grep { length $_ } split /\s+/, $moves;
  return \@list;
}

sub normalize_color {
  my ($color) = @_;
  return unless defined $color;
  $color = lc $color;
  return 'white' if $color eq 'white';
  return 'black' if $color eq 'black';
  return;
}

sub _normalize_player_id {
  my ($id) = @_;
  return unless defined $id;
  $id =~ s/^\s+//;
  $id =~ s/\s+$//;
  return unless length $id;
  return lc $id;
}

sub _extract_player_id {
  my ($slot) = @_;
  return unless ref $slot eq 'HASH';

  if (defined $slot->{id} && length $slot->{id}) {
    return _normalize_player_id($slot->{id});
  }
  if (ref($slot->{user}) eq 'HASH'
    && defined $slot->{user}{id}
    && length $slot->{user}{id})
  {
    return _normalize_player_id($slot->{user}{id});
  }
  if (defined $slot->{name} && length $slot->{name}) {
    return _normalize_player_id($slot->{name});
  }
  return;
}

sub _resolve_my_color_from_gamefull {
  my ($event, $seed_color, $bot_id_override) = @_;
  my $seed = normalize_color($seed_color);
  return $seed unless ref $event eq 'HASH';

  my $bot = defined $bot_id_override ? $bot_id_override : $bot_id;
  $bot = _normalize_player_id($bot);
  my $white_id = _extract_player_id($event->{white});
  my $black_id = _extract_player_id($event->{black});

  if (defined $bot) {
    return 'white' if defined $white_id && $white_id eq $bot;
    return 'black' if defined $black_id && $black_id eq $bot;
  }

  my $event_color = normalize_color($event->{color});
  return $event_color if defined $event_color;
  return $seed;
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
  if (!$state && _resync_game_from_lichess($game, 'state rebuild failed')) {
    $state = _sync_state_from_game($game);
    log_info("Recovered local state for $game->{id} after Lichess resync")
      if $state;
  }
  unless ($state) {
    log_warn("Unable to rebuild local state for $game->{id}; skipping move");
    return;
  }

  my $forced_mate_move = _forced_mate_move_for_state($state);
  my $tablebase_move = _tablebase_move_for_state($game, $state);
  my $analysis;
  if (defined $forced_mate_move) {
    $analysis = {
      move => $forced_mate_move,
      candidate => $forced_mate_move,
      elapsed_ms => 1,
      go_cmd => 'forced-mate',
      source => 'forced-mate',
      mate => 1,
    };
    log_info("Critical position in $game->{id}: found immediate forced mate, selecting $forced_mate_move");
  } elsif (defined $tablebase_move) {
    $analysis = {
      move => $tablebase_move,
      candidate => $tablebase_move,
      elapsed_ms => 1,
      go_cmd => 'tablebase',
      source => 'tablebase',
    };
    log_info("Critical position in $game->{id}: tablebase verdict selects $tablebase_move");
  } else {
    $analysis = compute_bestmove($game, $engine_out, $engine_in, $state);
  }
  my $threshold_ms = _time_control_threshold_ms($game);
  if (ref $analysis eq 'HASH'
    && defined $analysis->{elapsed_ms}
    && defined $threshold_ms
    && $threshold_ms > 0
    && $analysis->{elapsed_ms} > $threshold_ms)
  {
    log_info("You're not saying anything, Tony.");
  }
  if (ref $analysis eq 'HASH' && defined $analysis->{elapsed_ms}
    && $analysis->{elapsed_ms} >= $think_tank_ms)
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
  $analysis = _maybe_rethink_on_eval_drop($game, $engine_out, $engine_in, $state, $analysis);
  my $best = (ref $analysis eq 'HASH') ? $analysis->{move} : undef;
  my $plies = _opening_ply_count($game);
  if ($plies < 20) {
    my $go_cmd = (ref $analysis eq 'HASH' && defined $analysis->{go_cmd})
      ? $analysis->{go_cmd}
      : '';
    my $depth = (ref $analysis eq 'HASH' && defined $analysis->{depth})
      ? $analysis->{depth}
      : 'na';
    my $elapsed_ms = (ref $analysis eq 'HASH' && defined $analysis->{elapsed_ms})
      ? $analysis->{elapsed_ms}
      : 'na';
    my $move = defined $best ? $best : 'none';
    my $cand_eval = _telemetry_candidate_eval_summary($analysis);
    log_info(sprintf(
      'Opening decision in %s at ply %d: command=%s, depth=%s, elapsed=%sms, move=%s, eval=%s',
      ($game->{id} // 'unknown'),
      $plies,
      $go_cmd,
      $depth,
      $elapsed_ms,
      $move,
      $cand_eval,
    ));
  }
  my @candidates = _candidate_moves($state, $best);
  @candidates = _reorder_candidates_for_mate($state, \@candidates, $analysis);
  @candidates = _reorder_candidates_for_repetition($game, $state, \@candidates, $analysis);
  if (ref($game->{repetition_guard_meta}) eq 'HASH'
    && $game->{repetition_guard_meta}{blocked}
    && !(ref($analysis) eq 'HASH' && (($analysis->{source} // '') eq 'tablebase')))
  {
    if (_allow_repetition_rethink($game, $state)) {
      my $rethink = _rethink_with_multiplier(
        $game,
        $engine_out,
        $engine_in,
        $state,
        $analysis,
        $repetition_rethink_mult,
        'repetition-guard',
      );
      if (_analysis_prefers($rethink, $analysis)) {
        $analysis = $rethink;
        $best = (ref $analysis eq 'HASH') ? $analysis->{move} : undef;
        @candidates = _candidate_moves($state, $best);
        @candidates = _reorder_candidates_for_mate($state, \@candidates, $analysis);
        @candidates = _reorder_candidates_for_repetition($game, $state, \@candidates, $analysis);
      }
    } else {
      log_info("Skipping repetition-guard re-think in $game->{id}: low clock");
    }
  }
  _log_critical_position_decision($game, $analysis, $candidates[0]) if @candidates;
  unless (@candidates) {
    log_warn("No legal move available for $game->{id}; skipping move submission");
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
      if (ref $analysis eq 'HASH' && defined $analysis->{cp}) {
        $game->{last_engine_cp} = int($analysis->{cp});
      }
      log_info("Played $candidate in $game->{id}" . _format_eval_suffix($analysis));
      return;
    }

    last unless _is_retryable_illegal_reject($res);
    log_warn("Move was rejected with HTTP 400 in $game->{id}; retrying with an alternate legal move");
  }
}

sub _analysis_eval_label {
  my ($analysis) = @_;
  return 'none' unless ref $analysis eq 'HASH';
  return 'mate ' . ($analysis->{mate} // 0) if defined $analysis->{mate};
  return 'cp ' . ($analysis->{cp} // 0) if defined $analysis->{cp};
  return 'none';
}

sub _analysis_prefers {
  my ($candidate, $baseline) = @_;
  return 0 unless ref $candidate eq 'HASH';
  return 1 unless ref $baseline eq 'HASH';
  return 0 unless defined $candidate->{move};

  my $cand_mate = $candidate->{mate};
  my $base_mate = $baseline->{mate};
  if (defined $cand_mate || defined $base_mate) {
    return 1 if defined $cand_mate && !defined $base_mate && $cand_mate > 0;
    return 0 if !defined $cand_mate && defined $base_mate && $base_mate > 0;
    if (defined $cand_mate && defined $base_mate) {
      if ($cand_mate > 0 && $base_mate > 0) {
        return 1 if $cand_mate < $base_mate;
        return 0 if $cand_mate > $base_mate;
      } elsif ($cand_mate < 0 && $base_mate < 0) {
        return 1 if $cand_mate > $base_mate;
        return 0 if $cand_mate < $base_mate;
      } else {
        return 1 if $cand_mate > $base_mate;
        return 0 if $cand_mate < $base_mate;
      }
    }
  }

  return 0 unless defined $candidate->{cp};
  return 1 unless defined $baseline->{cp};
  return $candidate->{cp} > $baseline->{cp} ? 1 : 0;
}

sub _rethink_with_multiplier {
  my ($game, $engine_out, $engine_in, $state, $analysis, $multiplier, $reason) = @_;
  return $analysis unless ref $analysis eq 'HASH';
  return $analysis if (($analysis->{source} // '') eq 'tablebase');
  return $analysis if (($analysis->{source} // '') eq 'forced-mate');
  return $analysis unless defined $analysis->{move};

  my $extra = compute_bestmove(
    $game,
    $engine_out,
    $engine_in,
    $state,
    {
      movetime_multiplier => $multiplier,
      depth_bump => 1,
      reason => $reason,
    },
  );
  return $analysis unless ref $extra eq 'HASH' && defined $extra->{move};
  log_info(
    sprintf(
      'Re-evaluated %s position in %s: %s -> %s',
      ($reason // 'unknown'),
      ($game->{id} // 'unknown'),
      _analysis_eval_label($analysis),
      _analysis_eval_label($extra),
    )
  );
  return $extra;
}

sub _maybe_rethink_on_eval_drop {
  my ($game, $engine_out, $engine_in, $state, $analysis) = @_;
  return $analysis unless ref $analysis eq 'HASH';
  return $analysis unless defined $analysis->{cp};
  return $analysis unless ref $game eq 'HASH';
  return $analysis if (($analysis->{source} // '') eq 'tablebase');
  return $analysis if (($analysis->{source} // '') eq 'forced-mate');

  my $prev_cp = $game->{last_engine_cp};
  return $analysis unless defined $prev_cp && $prev_cp =~ /^-?\d+$/;
  my $current_cp = int($analysis->{cp});
  my $drop = int($prev_cp) - $current_cp;
  return $analysis unless $drop >= $eval_drop_extra_think_cp;

  my $mult = $eval_drop_extra_think_mult;
  log_info(
    sprintf(
      'Critical position in %s: eval dropped from %+dcp to %+dcp (drop=%dcp), triggering extra think x%.2f',
      ($game->{id} // 'unknown'),
      int($prev_cp),
      $current_cp,
      $drop,
      $mult,
    )
  );
  my $rethink = _rethink_with_multiplier(
    $game,
    $engine_out,
    $engine_in,
    $state,
    $analysis,
    $mult,
    'eval-drop',
  );
  return _analysis_prefers($rethink, $analysis) ? $rethink : $analysis;
}

sub _resync_game_from_lichess {
  my ($game, $reason) = @_;
  return 0 unless ref $game eq 'HASH';
  my $game_id = $game->{id};
  return 0 unless defined $game_id && length $game_id;

  my $moves = $game->{moves};
  $moves = [] unless ref $moves eq 'ARRAY';
  my $move_count = scalar(@$moves);
  my $last_move = $move_count ? ($moves->[-1] // '') : '';
  my $marker = "$move_count:$last_move";
  if (defined $game->{last_resync_marker}
    && $game->{last_resync_marker} eq $marker)
  {
    log_debug("Skipping duplicate Lichess resync attempt for $game_id marker=$marker");
    return 0;
  }
  $game->{last_resync_marker} = $marker;

  my $suffix = defined $reason && length $reason ? " ($reason)" : '';
  log_warn("State desync in $game_id$suffix; polling Lichess for snapshot");
  my $snapshot = _fetch_game_snapshot_once($game_id);
  unless (ref $snapshot eq 'HASH') {
    log_warn("Failed to poll Lichess snapshot for $game_id");
    return 0;
  }

  my $snapshot_type = $snapshot->{type} // '';
  my $state_payload = ref $snapshot->{state} eq 'HASH' ? $snapshot->{state} : {};
  my $moves_payload = exists $state_payload->{moves}
    ? $state_payload->{moves}
    : $snapshot->{moves};
  unless (defined $moves_payload) {
    log_warn("Lichess snapshot for $game_id is missing moves payload");
    return 0;
  }
  my $remote_moves = parse_moves($moves_payload);
  my $remote_initial_fen = normalize_fen(
    $snapshot->{initialFen} // $snapshot->{fen} // $game->{initial_fen}
  );

  $game->{initial_fen} = $remote_initial_fen;
  $game->{moves} = $remote_moves;
  $game->{status} = $state_payload->{status}
    if defined $state_payload->{status};
  $game->{status} = $snapshot->{status}
    if !defined($state_payload->{status}) && defined($snapshot->{status});
  $game->{wtime} = $state_payload->{wtime} if defined $state_payload->{wtime};
  $game->{btime} = $state_payload->{btime} if defined $state_payload->{btime};
  $game->{winc}  = $state_payload->{winc}  if defined $state_payload->{winc};
  $game->{binc}  = $state_payload->{binc}  if defined $state_payload->{binc};
  update_turn_from_event($game, $snapshot);
  update_turn_from_event($game, $state_payload);
  $game->{pending_move} = undef;

  $game->{state_obj} = undef;
  $game->{state_move_count} = 0;
  $game->{state_initial_fen} = undef;

  my $count = scalar(@{$game->{moves}});
  log_info("Applied Lichess snapshot for $game_id (type=$snapshot_type moves=$count)");
  return 1;
}

sub _fetch_game_snapshot_once {
  my ($game_id) = @_;
  return unless defined $game_id && length $game_id;

  my $path = "/bot/game/stream/$game_id";
  my $sock = _open_lichess_socket();
  unless ($sock) {
    my $err = $last_tls_error || IO::Socket::SSL::errstr() || 'unknown';
    log_warn("Unable to open TLS socket for $path: $err");
    return;
  }

  my %headers = (
    'Host'          => 'lichess.org',
    'Authorization' => "Bearer $token",
    'Accept'        => 'application/x-ndjson',
    'User-Agent'    => $user_agent,
    'Connection'    => 'close',
  );
  unless (_write_http_request($sock, 'GET', "/api$path", \%headers, '')) {
    my $err = $! ? "$!" : 'unable to write request';
    log_warn("Snapshot request write failed for $path: $err");
    _clear_socket_buffer($sock);
    close $sock;
    return;
  }

  my $resp_headers = _read_http_headers($sock);
  if (!$resp_headers->{status} || $resp_headers->{status} !~ /^2/) {
    my $status_line = $resp_headers->{status_line} // 'unknown';
    my $body = _read_all($sock);
    $body =~ s/\s+/ /g if defined $body;
    $body = substr($body // '', 0, 180);
    log_warn("Snapshot request for $path failed: $status_line body='$body'");
    _clear_socket_buffer($sock);
    close $sock;
    return;
  }

  my $snapshot;
  my $buffer = '';
  my $capture = sub {
    my ($payload) = @_;
    return unless ref $payload eq 'HASH';
    $snapshot = $payload unless $snapshot;
  };

  my $te = $resp_headers->{'transfer-encoding'} // '';
  if ($te =~ /chunked/i) {
    while (!$snapshot) {
      my $len_line = _read_line($sock);
      last unless defined $len_line;
      $len_line =~ s/\r?\n$//;
      $len_line =~ s/;.*$//;
      next if $len_line eq '';
      my $len = eval { hex($len_line) };
      last unless defined $len;
      last if $len == 0;
      my $chunk = _read_exact($sock, $len);
      last unless defined $chunk;
      _read_exact($sock, 2);
      $buffer .= $chunk;
      _drain_ndjson($path, \$buffer, $capture);
    }
  } else {
    while (!$snapshot) {
      my $chunk = '';
      my $rv = sysread($sock, $chunk, 4096);
      last unless defined $rv && $rv > 0;
      $buffer .= $chunk;
      _drain_ndjson($path, \$buffer, $capture);
    }
  }

  _clear_socket_buffer($sock);
  close $sock;

  if (!$snapshot) {
    log_warn("Snapshot stream for $path closed before payload arrived");
    return;
  }
  return $snapshot;
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
      log_warn("Failed to create board state from initial FEN for $game->{id}: $@");
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
      log_warn("Failed to encode historical move '$uci' while rebuilding $game->{id}: $@");
      $game->{state_obj} = undef;
      $game->{state_move_count} = 0;
      return;
    }
    my $next = eval { $state->make_move($encoded) };
    if (!defined $next || $@) {
      log_warn("Historical move '$uci' is illegal while rebuilding $game->{id}");
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

sub _tablebase_move_for_state {
  my ($game, $state) = @_;
  return unless ref $state;
  return unless _syzygy_ready();

  my $piece_count = _state_piece_count($state);
  return unless defined $piece_count;
  return unless $piece_count <= _syzygy_max_pieces();

  my $table_move = eval { Chess::EndgameTable::choose_move($state) };
  if (!defined $table_move || $@) {
    return;
  }

  my $uci;
  if (ref $table_move eq 'ARRAY') {
    $uci = eval { $state->decode_move($table_move) };
    return if $@;
  } elsif (!ref $table_move) {
    $uci = $table_move;
  }
  return unless defined $uci && $uci =~ /^[a-h][1-8][a-h][1-8][nbrq]?$/;

  my %legal = map { $_ => 1 } $state->get_moves;
  return unless $legal{$uci};
  return $uci;
}

sub _forced_mate_move_for_state {
  my ($state) = @_;
  return unless ref $state;

  my @legal = $state->get_moves;
  foreach my $uci (@legal) {
    my $encoded = eval { $state->encode_move($uci) };
    next if !$encoded || $@;

    my $next = eval { $state->make_move($encoded) };
    next if !defined $next || $@;

    my @reply = $next->get_moves;
    if (!@reply && $next->is_checked) {
      return $uci;
    }
  }
  return;
}

sub _reorder_candidates_for_mate {
  my ($state, $candidates_ref, $analysis) = @_;
  return @$candidates_ref unless ref $candidates_ref eq 'ARRAY' && @$candidates_ref;
  return @$candidates_ref unless ref $analysis eq 'HASH';
  return @$candidates_ref unless defined $analysis->{mate} && ($analysis->{mate} // 0) > 0;
  return @$candidates_ref if (($analysis->{source} // '') eq 'forced-mate');

  my @scored;
  for my $idx (0 .. $#$candidates_ref) {
    my $uci = $candidates_ref->[$idx];
    my $encoded = eval { $state->encode_move($uci) };
    if (!$encoded || $@) {
      push @scored, [ $idx, 0, $uci ];
      next;
    }
    my $next = eval { $state->make_move($encoded) };
    if (!defined $next || $@) {
      push @scored, [ $idx, 0, $uci ];
      next;
    }

    my @reply = $next->get_moves;
    my $score = 0;
    $score += 100_000 if !@reply && $next->is_checked;
    $score += 2_000 if $next->is_checked;
    $score -= 50 * scalar(@reply);
    push @scored, [ $idx, $score, $uci ];
  }

  my @ordered = map { $_->[2] } sort {
    $b->[1] <=> $a->[1] || $a->[0] <=> $b->[0]
  } @scored;
  return @ordered;
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

sub _reorder_candidates_for_repetition {
  my ($game, $state, $candidates_ref, $analysis) = @_;
  if (ref $game eq 'HASH') {
    delete $game->{repetition_guard_meta};
  }
  return @$candidates_ref unless ref $candidates_ref eq 'ARRAY' && @$candidates_ref;
  my $policy = _repetition_policy($analysis);
  return @$candidates_ref unless _should_apply_repetition_guard($game, $state, $analysis, $policy);

  my $visits = _position_visit_counts_from_game($game);
  return @$candidates_ref unless ref $visits eq 'HASH' && %$visits;

  my $board = $state->[Chess::State::BOARD];
  my $last_move = _last_uci_move($game);
  my @scored;
  for my $idx (0 .. $#$candidates_ref) {
    my $uci = $candidates_ref->[$idx];
    my $encoded = eval { $state->encode_move($uci) };
    if (!$encoded || $@) {
      push @scored, [ $idx, 0, $uci ];
      next;
    }

    my $next = eval { $state->make_move($encoded) };
    if (!defined $next || $@) {
      push @scored, [ $idx, 0, $uci ];
      next;
    }

    my $next_key = canonical_fen_key($next);
    my $visits_after = ($visits->{$next_key} // 0) + 1;
    my $gives_check = $next->is_checked ? 1 : 0;
    my $score = 0;
    if ($policy eq 'seek') {
      $score += 10_000 if $visits_after >= 3;
      $score += 3_500 if $visits_after == 2;
    } else {
      $score -= 10_000 if $visits_after >= 3;
      if ($visits_after == 2) {
        my $avoid_penalty = 2_200;
        if (ref $analysis eq 'HASH' && defined $analysis->{cp}) {
          my $cp = int($analysis->{cp});
          if ($cp >= ($repetition_keep_best_cp + 40)) {
            $avoid_penalty = 700;
          } elsif ($cp >= ($repetition_keep_best_cp + 15)) {
            $avoid_penalty = 1_150;
          } elsif ($cp >= $repetition_keep_best_cp) {
            $avoid_penalty = 1_600;
          }
        }
        $score -= $avoid_penalty;
      }
    }

    my $target = $board->[$encoded->[1]] // 0;
    my $is_capture = $target < 0 ? 1 : 0;
    my $is_pawn_advance = _is_pawn_advance_move($state, $encoded) ? 1 : 0;
    my $is_promo = length($uci) > 4 ? 1 : 0;
    if ($policy eq 'seek') {
      $score -= 900 if $is_capture;
      $score -= 450 if $is_pawn_advance;
    } else {
      $score += 900 if $is_capture; # prefer converting material when ahead
      if ($is_pawn_advance && !$is_capture && !$gives_check && !$is_promo) {
        $score -= 250; # avoid random quiet pawn pushes just to dodge repetition
      }
    }

    if ($last_move && _is_simple_backtrack($uci, $last_move)) {
      $score += ($policy eq 'seek') ? 2_000 : -2_000;
    }

    if ($gives_check) {
      $score += 350;
    }

    push @scored, [ $idx, $score, $uci, $visits_after, $is_capture, $gives_check, $is_promo ];
  }

  my @ordered = map { $_->[2] } sort {
    $b->[1] <=> $a->[1] || $a->[0] <=> $b->[0]
  } @scored;

  my %score_for = map { $_->[2] => $_->[1] } @scored;
  my %visits_after_for = map { $_->[2] => $_->[3] } @scored;
  my %capture_for = map { $_->[2] => $_->[4] } @scored;
  my %check_for = map { $_->[2] => $_->[5] } @scored;
  my %promo_for = map { $_->[2] => $_->[6] } @scored;
  my $from = $candidates_ref->[0];
  my $to = $ordered[0];
  if (defined $from && defined $to && $to ne $from) {
    my $cp = (ref($analysis) eq 'HASH' && defined $analysis->{cp}) ? int($analysis->{cp}) : undef;
    my $from_score = $score_for{$from} // 0;
    my $to_score = $score_for{$to} // 0;
    my $score_drop = $from_score - $to_score;
    my $from_visits_after = $visits_after_for{$from} // 0;
    my $visits_after = $visits_after_for{$to} // 0;
    my $to_is_capture = $capture_for{$to} ? 1 : 0;
    my $to_is_check = $check_for{$to} ? 1 : 0;
    my $to_is_promo = $promo_for{$to} ? 1 : 0;
    my $blocked = 0;
    my $blocked_reason = '';
    if ($policy eq 'avoid') {
      if ($from_visits_after <= 1 && $visits_after <= 1) {
        $blocked = 1;
        $blocked_reason = 'no-repetition-pressure';
      } elsif ($visits_after >= $from_visits_after) {
        $blocked = 1;
        $blocked_reason = 'no-repetition-improvement';
      }
    }
    if ($policy eq 'avoid'
      && defined $cp
      && $cp >= $repetition_keep_best_cp)
    {
      my $quiet_non_forcing = !$to_is_capture && !$to_is_check && !$to_is_promo;
      if (!$blocked && $quiet_non_forcing && $visits_after <= 1) {
        $blocked = 1;
        $blocked_reason = 'quiet-nonforcing';
      } elsif (!$blocked && $score_drop > $repetition_max_reorder_drop) {
        $blocked = 1;
        $blocked_reason = 'score-drop';
      }
    }
    if (ref $game eq 'HASH') {
      $game->{repetition_guard_meta} = {
        policy => $policy,
        cp => defined($cp) ? $cp : undef,
        from => $from,
        to => $to,
        from_score => $from_score,
        to_score => $to_score,
        from_visits_after => $from_visits_after,
        score_drop => $score_drop,
        visits_after => $visits_after,
        blocked => $blocked ? 1 : 0,
        blocked_reason => $blocked_reason,
      };
    }
    if ($blocked) {
      log_info(
        "Repetition guard kept the engine's top move in $game->{id}: "
        . "blocked alternative $to (policy=$policy, cp=$cp, reason=$blocked_reason, score_drop=$score_drop)"
      );
      return @$candidates_ref;
    }
    my $cp_log = defined($cp) ? $cp : 'n/a';
    log_info(
      "Repetition guard reordered candidates in $game->{id}: "
      . "$from -> $to (policy=$policy, cp=$cp_log, score_drop=$score_drop, visits_after=$visits_after)"
    );
  }
  return @ordered;
}

sub _repetition_policy {
  my ($analysis) = @_;
  return unless ref($analysis) eq 'HASH';

  if (defined($analysis->{mate}) && ($analysis->{mate} // 0) > 0) {
    return 'avoid';
  }
  if (defined($analysis->{mate}) && ($analysis->{mate} // 0) < 0) {
    return 'seek';
  }

  return unless defined($analysis->{cp});
  my $cp = $analysis->{cp} // 0;
  return 'avoid' if $cp >= $repetition_avoid_cp;
  return 'seek' if $cp <= $repetition_seek_cp;
  return;
}

sub _allow_repetition_rethink {
  my ($game, $state) = @_;
  my ($remaining_ms) = _clock_for_side_ms($game);
  return 1 unless defined $remaining_ms;
  my $required_ms = $repetition_rethink_min_clock_ms;
  my $planned_ms = _movetime_for_game_ms($game, $state);
  if (defined $planned_ms && $planned_ms > 0) {
    my $budget_floor = int($planned_ms * $repetition_rethink_min_budget_multiple);
    $required_ms = $budget_floor if $budget_floor > $required_ms;
  }
  return $remaining_ms >= $required_ms ? 1 : 0;
}

sub _should_apply_repetition_guard {
  my ($game, $state, $analysis, $policy) = @_;
  return 0 unless ref $game eq 'HASH' && ref $state;
  return 0 if ref($analysis) eq 'HASH' && (($analysis->{source} // '') eq 'tablebase');
  if ($repetition_guard_disable_below_ms > 0) {
    my ($remaining_ms) = _clock_for_side_ms($game);
    return 0 if defined $remaining_ms && $remaining_ms <= $repetition_guard_disable_below_ms;
  }
  if (ref($analysis) eq 'HASH' && defined $analysis->{mate}) {
    my $mate = int($analysis->{mate});
    return 0 if abs($mate) <= 2;
  }
  $policy = _repetition_policy($analysis) unless defined $policy;
  return defined $policy ? 1 : 0;
}

sub _position_visit_counts_from_game {
  my ($game) = @_;
  my %visits;
  return \%visits unless ref $game eq 'HASH';

  my $moves = $game->{moves};
  return \%visits unless ref $moves eq 'ARRAY';

  my $initial = ($game->{initial_fen} && $game->{initial_fen} ne 'startpos')
    ? $game->{initial_fen}
    : 'startpos';
  my $state = eval {
    $initial eq 'startpos' ? Chess::State->new() : Chess::State->new($initial);
  };
  return \%visits if !$state || $@;

  my $key = canonical_fen_key($state);
  $visits{$key}++;
  foreach my $uci (@$moves) {
    my $encoded = eval { $state->encode_move($uci) };
    last if !$encoded || $@;
    my $next = eval { $state->make_move($encoded) };
    last if !defined $next || $@;
    $state = $next;
    my $next_key = canonical_fen_key($state);
    $visits{$next_key}++;
  }
  return \%visits;
}

sub _last_uci_move {
  my ($game) = @_;
  return unless ref $game eq 'HASH';
  my $moves = $game->{moves};
  return unless ref $moves eq 'ARRAY' && @$moves;
  my $last = $moves->[-1];
  return unless defined $last && $last =~ /^[a-h][1-8][a-h][1-8][nbrq]?$/;
  return $last;
}

sub _is_simple_backtrack {
  my ($candidate, $last) = @_;
  return 0 unless defined $candidate && defined $last;
  return 0 unless $candidate =~ /^[a-h][1-8][a-h][1-8]$/;
  return 0 unless $last =~ /^[a-h][1-8][a-h][1-8]$/;
  return substr($candidate, 0, 2) eq substr($last, 2, 2)
    && substr($candidate, 2, 2) eq substr($last, 0, 2);
}

sub _is_pawn_advance_move {
  my ($state, $move) = @_;
  return 0 unless ref($state) && ref($move) eq 'ARRAY';
  my $board = $state->[Chess::State::BOARD];
  return 0 unless ref $board eq 'ARRAY';
  my $from_piece = $board->[$move->[0]] // 0;
  return 0 unless abs($from_piece) == 1;
  my $from_rank = int($move->[0] / 10);
  my $to_rank = int($move->[1] / 10);
  return $to_rank > $from_rank ? 1 : 0;
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

sub _set_game_time_control {
  my ($game, $event) = @_;
  return unless ref $game eq 'HASH';
  return unless ref $event eq 'HASH';
  my $raw = $event->{timeControl}
    // $event->{state}{timeControl}
    // $event->{timecontrol}
    // $event->{clock}
    // $event->{state}{clock};
  my $ms = _parse_time_control_ms($raw);
  return unless defined $ms && $ms > 0;
  $game->{time_control_base_ms} = $ms;
}

sub _parse_time_control_ms {
  my ($raw) = @_;
  return unless defined $raw;
  if (!ref $raw) {
    if ($raw =~ /^(\d+)(?:\+(\d+))?$/) {
      return $1 * 1000;
    }
    if ($raw =~ /^(\d+)$/) {
      return $1 * 1000;
    }
  }
  if (ref $raw eq 'HASH') {
    for my $key (qw(initialTimeMs initial_millis)) {
      next unless defined $raw->{$key} && $raw->{$key} =~ /^\d+$/;
      return $raw->{$key} + 0;
    }
    for my $key (qw(initialTime base initial seconds limit)) {
      next unless defined $raw->{$key} && $raw->{$key} =~ /^\d+$/;
      my $val = $raw->{$key} + 0;
      return ($val >= 10_000) ? $val : ($val * 1000);
    }
    if (defined $raw->{totalTime} && $raw->{totalTime} =~ /^\d+$/) {
      return $raw->{totalTime} + 0;
    }
  }
  return;
}

sub _time_control_threshold_ms {
  my ($game) = @_;
  return unless ref $game eq 'HASH';
  my $base = $game->{time_control_base_ms};
  if (!defined $base || $base <= 0) {
    my $w = $game->{wtime};
    my $b = $game->{btime};
    $w = undef unless defined $w && $w =~ /^\d+$/;
    $b = undef unless defined $b && $b =~ /^\d+$/;
    my $fallback = 0;
    $fallback = $w if defined $w && $w > $fallback;
    $fallback = $b if defined $b && $b > $fallback;
    $base = $fallback if $fallback > 0;
  }
  return unless defined $base && $base > 0;
  my $threshold = int($base * 0.10);
  return $threshold > 0 ? $threshold : 1;
}

sub _clock_for_side_ms {
  my ($game) = @_;
  return unless ref $game eq 'HASH';
  my $color = normalize_color($game->{my_color});
  return unless defined $color;
  my $remaining = $color eq 'white' ? $game->{wtime} : $game->{btime};
  my $increment = $color eq 'white' ? $game->{winc} : $game->{binc};
  return unless defined $remaining && $remaining =~ /^\d+$/;
  $increment = 0 unless defined $increment && $increment =~ /^\d+$/;
  return ($remaining + 0, $increment + 0);
}

sub _opening_ply_count {
  my ($game) = @_;
  return 0 unless ref $game eq 'HASH';
  my $moves = $game->{moves};
  return 0 unless ref $moves eq 'ARRAY';
  return scalar(@$moves);
}

sub _book_fast_movetime_ms_for_speed {
  my ($speed) = @_;
  return 50  if $speed eq 'bullet';
  return 90  if $speed eq 'blitz';
  return 140 if $speed eq 'rapid';
  return 220 if $speed eq 'classical';
  return 260;
}

sub _state_has_book_move {
  my ($state) = @_;
  return 0 unless ref $state;
  my $book_move = eval { Chess::Book::choose_move($state) };
  return 0 if $@;
  return defined $book_move ? 1 : 0;
}

sub _state_piece_count {
  my ($state) = @_;
  return unless ref $state;
  my $cached = $state->[Chess::State::PIECE_COUNT];
  return $cached if defined $cached;
  my $board = $state->[Chess::State::BOARD];
  return unless ref $board eq 'ARRAY';

  my $count = 0;
  for my $idx (21 .. 98) {
    next if $idx % 10 == 0 || $idx % 10 == 9;
    my $piece = $board->[$idx] // 0;
    my $abs_piece = abs($piece);
    $count++ if $abs_piece >= 1 && $abs_piece <= 6;
  }
  return $count;
}

sub _syzygy_max_pieces {
  my $max = $ENV{CHESS_SYZYGY_MAX_PIECES};
  $max = 7 unless defined $max && $max =~ /^\d+$/;
  $max = int($max);
  $max = 2 if $max < 2;
  $max = 16 if $max > 16;
  return $max;
}

sub _syzygy_paths {
  my $raw = $ENV{CHESS_SYZYGY_PATH} // '';
  return () unless length $raw;
  my $sep = ($^O eq 'MSWin32') ? ';' : ':';
  my %seen;
  my @paths = grep {
    -d $_ && !$seen{$_}++
  } grep {
    defined $_ && length $_
  } map {
    my $p = $_;
    $p =~ s/^\s+//;
    $p =~ s/\s+$//;
    $p;
  } split /\Q$sep\E/, $raw;
  return @paths;
}

sub _syzygy_ready {
  my $enabled = $ENV{CHESS_SYZYGY_ENABLED};
  if (defined $enabled && length $enabled) {
    my $norm = lc $enabled;
    return 0 if $norm =~ /^(?:0|false|off|no)$/;
  }
  my @paths = _syzygy_paths();
  return @paths ? 1 : 0;
}

sub _movetime_for_game_ms {
  my ($game, $state) = @_;
  my $allow_forced_movetime = !$loaded_as_library || $ENV{LICHESS_ALLOW_FORCED_MOVETIME_IN_LIBRARY};
  if ($allow_forced_movetime
    && defined $ENV{LICHESS_MOVETIME_MS}
    && $ENV{LICHESS_MOVETIME_MS} =~ /^\d+$/)
  {
    my $forced = int($ENV{LICHESS_MOVETIME_MS});
    return $forced if $forced > 0;
  }

  my ($remaining_ms, $increment_ms) = _clock_for_side_ms($game);
  return 800 unless defined $remaining_ms;

  my $speed = normalize_speed($game->{speed}) // '';
  if ($state && _state_has_book_move($state)) {
    my $book_ms = _book_fast_movetime_ms_for_speed($speed);
    if ($allow_forced_movetime
      && defined $ENV{LICHESS_BOOK_MOVETIME_MS}
      && $ENV{LICHESS_BOOK_MOVETIME_MS} =~ /^\d+$/)
    {
      my $forced_book_ms = int($ENV{LICHESS_BOOK_MOVETIME_MS});
      $book_ms = $forced_book_ms if $forced_book_ms > 0;
    }
    my $usable_book = $remaining_ms - 150;
    $usable_book = 40 if $usable_book < 40;
    return $book_ms if $book_ms < $usable_book;
    return $usable_book;
  }

  my $plies = _opening_ply_count($game);
  my $in_post_book_phase = $plies >= 8 ? 1 : 0;
  my $horizon = $speed_horizon_targets{$speed} // 60;
  my $inc_weight =
      $speed eq 'bullet' ? 0.20
    : $speed eq 'blitz' ? 0.28
    : $speed eq 'rapid' ? 0.35
    : $speed eq 'classical' ? 0.45
    : 0.50;
  my $max_share =
      $speed eq 'bullet' ? 0.060
    : $speed eq 'blitz' ? 0.110
    : $speed eq 'rapid' ? 0.150
    : $speed eq 'classical' ? 0.200
    : 0.220;
  my $max_cap_ms =
      $speed eq 'bullet' ? 1500
    : $speed eq 'blitz' ? 3600
    : $speed eq 'rapid' ? 6500
    : $speed eq 'classical' ? 10_000
    : 13_000;
  if ($in_post_book_phase && $speed ne 'bullet') {
    $horizon = int($horizon * 0.86);
    $horizon = 12 if $horizon < 12;
    $max_share += 0.020;
    $max_cap_ms = int($max_cap_ms * $post_book_cap_mult);
  }
  my $piece_count = _state_piece_count($state);
  if (defined $piece_count && $speed ne 'bullet') {
    if ($piece_count <= 14) {
      $horizon = int($horizon * 0.82);
      $horizon = 12 if $horizon < 12;
      $max_share += 0.025;
      $max_cap_ms = int($max_cap_ms * 1.52);
    }
    if ($piece_count <= 10) {
      $horizon = int($horizon * 0.74);
      $horizon = 10 if $horizon < 10;
      $max_share += 0.035;
      $max_cap_ms = int($max_cap_ms * 1.75);
    }
    if ($piece_count <= _syzygy_max_pieces() && _syzygy_ready()) {
      $horizon = int($horizon * 0.68);
      $horizon = 8 if $horizon < 8;
      $max_share += 0.035;
      $max_cap_ms = int($max_cap_ms * 1.48);
    }
    $max_share = 0.24 if $max_share > 0.24;
  }
  my $effective_cap_ms = $max_cap_ms;

  my $reserve_pct =
      $remaining_ms <= 10_000 ? 0.35
    : $remaining_ms <= 30_000 ? 0.25
    : $remaining_ms <= 60_000 ? 0.18
    : 0.12;
  my $reserve_ms = int($remaining_ms * $reserve_pct);
  $reserve_ms = 300 if $reserve_ms < 300;
  my $usable_ms = $remaining_ms - $reserve_ms;
  $usable_ms = 0 if $usable_ms < 0;

  my $budget_ms = int(($usable_ms / $horizon) + ($increment_ms * $inc_weight));
  my $share_cap_ms = int(($remaining_ms * $max_share) + $increment_ms);
  $share_cap_ms = 60 if $share_cap_ms < 60;
  $budget_ms = $share_cap_ms if $budget_ms > $share_cap_ms;
  if ($in_post_book_phase && $speed ne 'bullet' && $post_book_think_mult > 1.0) {
    my $boosted = int($budget_ms * $post_book_think_mult);
    $budget_ms = $boosted if $boosted > $budget_ms;
  }

  if ($is_production_profile
    && $prod_opening_boost_plies > 0
    && $prod_opening_boost_mult > 1.0)
  {
    if ($plies < $prod_opening_boost_plies) {
      my $remaining_phase = ($prod_opening_boost_plies - $plies) / $prod_opening_boost_plies;
      my $opening_mult = 1.0 + (($prod_opening_boost_mult - 1.0) * $remaining_phase);
      if ($opening_mult > 1.0) {
        my $boosted_ms = int($budget_ms * $opening_mult);
        my $opening_cap_ms = int($max_cap_ms * $prod_opening_cap_mult);
        $opening_cap_ms = $max_cap_ms if $opening_cap_ms < $max_cap_ms;
        $effective_cap_ms = $opening_cap_ms if $opening_cap_ms > $effective_cap_ms;
        $budget_ms = $boosted_ms if $boosted_ms > $budget_ms;
        $budget_ms = $opening_cap_ms if $budget_ms > $opening_cap_ms;
      }
    }
  }

  if ($is_production_profile
    && $prod_opening_floor_plies > 0
    && $prod_opening_floor_ms > 0
    && $plies < $prod_opening_floor_plies
    && $speed eq 'rapid'
    && $increment_ms == 0)
  {
    my $base_ms = $game->{time_control_base_ms};
    my $is_ten_zero_rapid = defined $base_ms
      && $base_ms =~ /^\d+$/
      && $base_ms >= 8 * 60 * 1000
      && $base_ms <= 12 * 60 * 1000;
    if ($is_ten_zero_rapid && $usable_ms >= $prod_opening_floor_ms) {
      my $opening_cap_ms = int($max_cap_ms * $prod_opening_cap_mult);
      $opening_cap_ms = $max_cap_ms if $opening_cap_ms < $max_cap_ms;
      $opening_cap_ms = $prod_opening_floor_ms if $opening_cap_ms < $prod_opening_floor_ms;
      $effective_cap_ms = $opening_cap_ms if $opening_cap_ms > $effective_cap_ms;
      $budget_ms = $prod_opening_floor_ms if $budget_ms < $prod_opening_floor_ms;
    }
  }

  if ($is_production_profile && $speed ne 'bullet') {
    if ($prod_cap_mult > 1.0) {
      my $prod_cap_ms = int($effective_cap_ms * $prod_cap_mult);
      $prod_cap_ms = $effective_cap_ms if $prod_cap_ms < $effective_cap_ms;
      $effective_cap_ms = $prod_cap_ms if $prod_cap_ms > $effective_cap_ms;
    }
    if ($prod_think_mult > 1.0 && $remaining_ms >= 45_000) {
      my $boosted_ms = int($budget_ms * $prod_think_mult);
      $budget_ms = $boosted_ms if $boosted_ms > $budget_ms;
    }
    if ($prod_floor_ms > 0 && $remaining_ms >= 90_000) {
      my $speed_floor =
          $speed eq 'classical' ? int($prod_floor_ms * 1.60)
        : $speed eq 'blitz'     ? int($prod_floor_ms * 0.55)
        : $speed eq 'rapid'     ? $prod_floor_ms
        : int($prod_floor_ms * 0.80);
      $speed_floor = 0 if $speed_floor < 0;
      $budget_ms = $speed_floor if $speed_floor > 0 && $budget_ms < $speed_floor && $usable_ms >= $speed_floor;
    }
  }
  if ($is_develop_branch && $speed ne 'bullet') {
    if ($develop_cap_mult > 1.0) {
      my $dev_cap_ms = int($effective_cap_ms * $develop_cap_mult);
      $dev_cap_ms = $effective_cap_ms if $dev_cap_ms < $effective_cap_ms;
      $effective_cap_ms = $dev_cap_ms if $dev_cap_ms > $effective_cap_ms;
    }
    if ($develop_think_mult > 1.0 && $remaining_ms >= 20_000) {
      my $boosted_ms = int($budget_ms * $develop_think_mult);
      $budget_ms = $boosted_ms if $boosted_ms > $budget_ms;
    }
  }

  my $min_ms =
      $speed eq 'bullet' ? ($remaining_ms <= 10_000 ? 70 : 110)
    : $speed eq 'blitz' ? ($remaining_ms <= 10_000 ? 90 : 220)
    : $speed eq 'rapid' ? ($remaining_ms <= 10_000 ? 120 : 420)
    : $speed eq 'classical' ? ($remaining_ms <= 10_000 ? 140 : 700)
    : ($remaining_ms <= 10_000 ? 100 : 300);
  if (defined $piece_count && $piece_count <= 10 && $remaining_ms >= 90_000 && $speed ne 'bullet' && $speed ne 'blitz') {
    my $endgame_floor = $speed eq 'classical' ? 5000 : 3800;
    $budget_ms = $endgame_floor if $budget_ms < $endgame_floor && $usable_ms >= $endgame_floor;
  }
  $budget_ms = $min_ms if $budget_ms < $min_ms;
  $budget_ms = $effective_cap_ms if $budget_ms > $effective_cap_ms;
  return $budget_ms;
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

sub _effective_engine_depth_for_game {
  my ($game) = @_;
  return unless ref $game eq 'HASH';

  my $depth = $game->{engine_depth};
  $depth = $game->{engine_depth_default} if !defined $depth;
  return unless defined $depth && $depth =~ /^-?\d+$/;

  my $min_depth = defined $game->{engine_depth_min} ? int($game->{engine_depth_min}) : 1;
  my $max_depth = defined $game->{engine_depth_max} ? int($game->{engine_depth_max}) : 20;
  $depth = int($depth);
  $depth = $min_depth if $depth < $min_depth;
  $depth = $max_depth if $depth > $max_depth;
  return $depth;
}

sub _bumped_engine_depth_for_game {
  my ($game, $bump) = @_;
  return unless defined $bump && $bump =~ /^-?\d+$/;

  my $depth = _effective_engine_depth_for_game($game);
  return unless defined $depth;
  $depth += int($bump);

  my $min_depth = defined $game->{engine_depth_min} ? int($game->{engine_depth_min}) : 1;
  my $max_depth = defined $game->{engine_depth_max} ? int($game->{engine_depth_max}) : 20;
  $depth = $min_depth if $depth < $min_depth;
  $depth = $max_depth if $depth > $max_depth;
  return $depth;
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
  if ($is_develop_branch && $develop_depth_bump > 0) {
    $target += $develop_depth_bump;
  }
  my $current_depth = $game->{engine_depth};
  $current_depth = $game->{engine_depth_default} if !defined $current_depth;
  return if defined $current_depth && $current_depth == $target;

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

sub _telemetry_candidate_eval_summary {
  my ($analysis) = @_;
  return 'none' unless ref $analysis eq 'HASH';

  my @parts;
  my $candidate = $analysis->{candidate};
  $candidate = $analysis->{move} if !defined $candidate && defined $analysis->{move};
  push @parts, "pv:$candidate" if defined $candidate && length $candidate;
  if (defined $analysis->{mate}) {
    push @parts, sprintf('mate:%+d', $analysis->{mate});
  } elsif (defined $analysis->{cp}) {
    push @parts, sprintf('cp:%+d', $analysis->{cp});
  }
  return @parts ? join(',', @parts) : 'none';
}

sub _log_critical_position_decision {
  my ($game, $analysis, $selected_move) = @_;
  return unless ref $game eq 'HASH' && ref $analysis eq 'HASH';
  return if (($analysis->{source} // '') eq 'tablebase');
  return if (($analysis->{source} // '') eq 'forced-mate');

  my $move = defined $selected_move && length $selected_move
    ? $selected_move
    : ($analysis->{move} // $analysis->{candidate});
  return unless defined $move && length $move;

  my $game_id = $game->{id} // 'unknown';
  if (defined $analysis->{mate}) {
    my $mate = int($analysis->{mate});
    my $desc = $mate > 0 ? "mate in $mate" : "opponent mate in " . abs($mate);
    log_info("Critical position in $game_id: engine sees $desc, choosing $move");
    return;
  }

  return unless defined $analysis->{cp};
  my $cp = int($analysis->{cp});
  return unless abs($cp) >= 220;
  my $context = $cp >= 0
    ? 'pressing for conversion'
    : 'prioritizing defense';
  log_info("Critical position in $game_id: eval=" . sprintf('%+dcp', $cp) . ", choosing $move while $context");
}

sub compute_bestmove {
  my ($game, $engine_out, $engine_in, $state, $opts) = @_;
  $opts = {} unless ref $opts eq 'HASH';
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
  my $bumped_depth;
  if (defined $opts->{depth_bump} && $opts->{depth_bump} =~ /^-?\d+$/) {
    $bumped_depth = int($opts->{depth_bump});
  }
  if (defined $depth_override) {
    my $depth = int($depth_override);
    if (defined $bumped_depth) {
      $depth += $bumped_depth;
    }
    $depth = 1 if $depth < 1;
    $depth = 20 if $depth > 20;
    $go = "go depth $depth";
  } else {
    my $movetime = _movetime_for_game_ms($game, $state);
    if (defined $opts->{movetime_multiplier} && $opts->{movetime_multiplier} =~ /^\d+(?:\.\d+)?$/) {
      my $mult = $opts->{movetime_multiplier} + 0;
      $mult = 1.0 if $mult < 1.0;
      $mult = 3.0 if $mult > 3.0;
      my $boosted = int($movetime * $mult);
      my ($remaining_ms, $inc_ms) = _clock_for_side_ms($game);
      if (defined $remaining_ms && defined $inc_ms) {
        my $cap = int(($remaining_ms * 0.45) + ($inc_ms * 2));
        $cap = $remaining_ms - 200 if $cap > ($remaining_ms - 200);
        $cap = 80 if $cap < 80;
        $boosted = $cap if $boosted > $cap;
      }
      $movetime = $boosted if $boosted > $movetime;
    }
    if (defined $opts->{movetime_floor_ms} && $opts->{movetime_floor_ms} =~ /^\d+$/) {
      my $floor = int($opts->{movetime_floor_ms});
      $movetime = $floor if $floor > $movetime;
    }
    my $go_depth = _bumped_engine_depth_for_game($game, $bumped_depth);
    if (defined $go_depth) {
      $go = "go depth $go_depth movetime $movetime";
    } else {
      $go = "go movetime $movetime";
    }
  }
  print {$engine_in} "$go\n";
  if (defined $opts->{reason} && length $opts->{reason}) {
    log_info("Search adjustment for $game->{id}: $go (reason=$opts->{reason})");
  }

  my %analysis = (
    move   => undef,
    go_cmd => $go,
  );
  while (my $line = <$engine_out>) {
    $line =~ s/[\r\n]+$//;
    if ($line =~ /^info\b/) {
      if ($line =~ /^info string\s*(.*)$/) {
        my $msg = $1 // '';
        $msg =~ s/\s+$//;
        log_info("Thinking... $msg in $game->{id}") if length $msg;
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
    log_warn("Lichess rejected move $move in game $game_id: " . $res->{status_line} . $extra);
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
      my $snippet = $line;
      $snippet =~ s/\s+/ /g;
      $snippet = substr($snippet, 0, 180);
      log_warn("Failed to decode NDJSON payload on $path; skipping line. payload='$snippet' error=$@");
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
        log_warn("Failed to open TLS socket for $path after $attempt attempts: $err");
        return 0;
      }
      log_warn("Failed to open TLS socket for $path: $err");
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
      $body =~ s/\s+/ /g if defined $body;
      $body = substr($body // '', 0, 180);
      log_warn("Stream request for $path failed: $status_line body='$body'");
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

    log_info("Stream $path connected: " . ($headers->{status_line} // 'unknown'));
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
      log_info("Stream $path completed cleanly");
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
