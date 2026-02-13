#!/usr/bin/env perl
use v5.26;
use strict;
use warnings;

# Make local modules available so the bundled UCI engine can be spawned.
use FindBin qw($RealBin);
use lib $RealBin;

use JSON::PP qw(decode_json);
use IPC::Open2;
use IO::Handle;
use Text::ParseWords qw(shellwords);
use POSIX ':sys_wait_h';
use IO::Select;
use MIME::Base64 qw(encode_base64);

my $API_BASE = 'https://lichess.org/api';

load_env("$RealBin/.env");

my $token = $ENV{LICHESS_TOKEN}
  or die "Set LICHESS_TOKEN to a Bot API token generated on lichess.org\n";
my $engine_cmd = $ENV{LICHESS_ENGINE_CMD} // "$^X $RealBin/uci.pl";
my @engine_parts = shellwords($engine_cmd);
@engine_parts or die "Unable to parse LICHESS_ENGINE_CMD '$engine_cmd'\n";

STDOUT->autoflush(1);
STDERR->autoflush(1);

my $debug = $ENV{LICHESS_DEBUG} // 0;

my $auth_header = "Authorization: Bearer $token";

# Ensure the token is valid and capture the bot username.
my $account = lichess_json_get('/account');
my $bot_id  = $account->{id}
  or die "Unable to discover bot id from /api/account response\n";
log_info("Logged in as $account->{username} ($bot_id)");

$SIG{INT}  = sub { log_info('Caught SIGINT, shutting down'); exit 0 };
$SIG{TERM} = sub { log_info('Caught SIGTERM, shutting down'); exit 0 };

stream_events();
exit 0;

sub stream_events {
  while (1) {
    log_info('Connecting to event stream');
    my $ok = stream_ndjson('/stream/event', sub {
      my ($event) = @_;
      log_debug("Event $event->{type}") if $event->{type};
      handle_event($event);
    });
    if (!$ok) {
      log_warn('Event stream closed unexpectedly, reconnecting');
    }
    sleep 2;
  }
}

sub handle_event {
  my ($event) = @_;
  my $type = $event->{type} // '';
  if ($type eq 'challenge') {
    handle_challenge($event->{challenge});
  } elsif ($type eq 'challengeCanceled') {
    log_info("Challenge $event->{challenge}->{id} canceled");
  } elsif ($type eq 'challengeDeclined') {
    log_info("Challenge $event->{challenge}->{id} declined");
  } elsif ($type eq 'gameStart') {
    start_game($event->{game});
  } elsif ($type eq 'gameFinish') {
    log_info("Game $event->{game}->{id} finished");
  } else {
    log_info("Unhandled event type '$type'");
  }
}

sub handle_challenge {
  my ($challenge) = @_;
  my $id     = $challenge->{id};
  my $variant = $challenge->{variant}{key} // '';
  my $speed   = $challenge->{speed} // '';

  if ($variant ne 'standard') {
    log_info("Declining challenge $id (unsupported variant $variant)");
    decline_challenge($id, 'variant');
    return;
  }

  if ($speed eq 'correspondence') {
    log_info("Declining challenge $id (unsupported speed)");
    decline_challenge($id, 'timeControl');
    return;
  }

  log_info("Accepting challenge $id ($speed $variant)");
  my $res = http_request('POST', "/challenge/$id/accept");
  if (!$res->{success}) {
    log_warn("Failed to accept challenge $id: " . $res->{status_line});
  }
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
    play_game($game_id);
    exit 0;
  }
  log_info("Spawned handler pid $pid for game $game_id");
}

sub play_game {
  my ($game_id) = @_;
  log_info("Starting game stream for $game_id");

  my ($engine_out, $engine_in);
  my $engine_pid = open2($engine_out, $engine_in, @engine_parts);
  $engine_in->autoflush(1);

  unless (uci_handshake($engine_out, $engine_in)) {
    log_warn("Engine handshake failed, aborting game $game_id");
    kill 'TERM', $engine_pid;
    waitpid($engine_pid, 0);
    return;
  }

  my %game = (
    id           => $game_id,
    my_color     => undef,
    initial_fen  => 'startpos',
    moves        => [],
    pending_move => undef,
    status       => 'created',
    wtime        => undef,
    btime        => undef,
    winc         => 0,
    binc         => 0,
  );

  my $buffer = '';
  my $ok = stream_ndjson("/bot/game/stream/$game_id", sub {
    my ($event) = @_;
    handle_game_event(\%game, $event, $engine_out, $engine_in);
  });

  if (!$ok) {
    log_warn("Game stream $game_id ended unexpectedly");
  } else {
    log_info("Game stream $game_id finished");
  }

  kill 'TERM', $engine_pid;
  waitpid($engine_pid, 0);
}

sub handle_game_event {
  my ($game, $event, $engine_out, $engine_in) = @_;
  my $type = $event->{type} // '';

  if ($type eq 'gameFull') {
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
    print {$engine_in} "ucinewgame\n";
    maybe_move($game, $engine_out, $engine_in);
  } elsif ($type eq 'gameState') {
    log_debug("gameState for $game->{id}: moves=$event->{moves}");
    $game->{status} = $event->{status} if defined $event->{status};
    $game->{moves}  = parse_moves($event->{moves});
    $game->{wtime}  = $event->{wtime};
    $game->{btime}  = $event->{btime};
    $game->{winc}   = $event->{winc};
    $game->{binc}   = $event->{binc};
    if ($game->{pending_move} && @{$game->{moves}}
      && $game->{moves}[-1] eq $game->{pending_move})
    {
      $game->{pending_move} = undef;
    }
    maybe_move($game, $engine_out, $engine_in);
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

sub maybe_move {
  my ($game, $engine_out, $engine_in) = @_;
  return unless ($game->{status} // '') eq 'started';
  log_debug("maybe_move status=$game->{status}");
  return unless defined $game->{my_color};
  return if $game->{pending_move};

  my $move_count = scalar @{$game->{moves}};
  my $side_to_move = $move_count % 2 == 0 ? 'white' : 'black';
  log_debug("move_count=$move_count my=$game->{my_color} side=$side_to_move");
  return unless $side_to_move eq $game->{my_color};

  my $best = compute_bestmove($game, $engine_out, $engine_in);
  if (!$best || $best eq '(none)') {
    log_warn("Engine returned no move for $game->{id}");
    return;
  }

  if (send_move($game->{id}, $best)) {
    $game->{pending_move} = $best;
    log_info("Played $best in $game->{id}");
  }
}

sub compute_bestmove {
  my ($game, $engine_out, $engine_in) = @_;
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

  my $go = 'go';
  if (defined $game->{wtime} && defined $game->{btime}) {
    $go .= sprintf ' wtime %d btime %d', $game->{wtime}, $game->{btime};
  }
  if (defined $game->{winc} && defined $game->{binc}) {
    $go .= sprintf ' winc %d binc %d', $game->{winc}, $game->{binc};
  }
  print {$engine_in} "$go\n";

  while (my $line = <$engine_out>) {
    $line =~ s/[\r\n]+$//;
    if ($line =~ /^bestmove\s+(\S+)/) {
      return $1;
    }
  }
  return;
}

sub send_move {
  my ($game_id, $move) = @_;
  my $res = http_request('POST', "/bot/game/$game_id/move/$move");
  if (!$res->{success}) {
    log_warn("Move $move for $game_id was rejected: " . $res->{status_line});
    return 0;
  }
  return 1;
}

sub uci_handshake {
  my ($engine_out, $engine_in) = @_;
  print {$engine_in} "uci\n";
  while (my $line = <$engine_out>) {
    $line =~ s/[\r\n]+$//;
    last if $line =~ /^uciok/;
  }
  print {$engine_in} "isready\n";
  while (my $line = <$engine_out>) {
    $line =~ s/[\r\n]+$//;
    return 1 if $line =~ /^readyok/;
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
  my $ts = scalar gmtime;
  warn "[$ts] INFO $msg\n";
}

sub log_warn {
  my ($msg) = @_;
  my $ts = scalar gmtime;
  warn "[$ts] WARN $msg\n";
}

sub log_debug {
  my ($msg) = @_;
  return unless $debug;
  my $ts = scalar gmtime;
  warn "[$ts] DEBUG $msg\n";
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

sub http_request {
  my ($method, $path, $opts) = @_;
  $opts ||= {};
  my $url = "$API_BASE$path";
  my @cmd = (
    'curl', '-sS', '-i',
    '-H', $auth_header,
    '-H', 'Accept: application/json',
  );
  push @cmd, '-X', $method if $method ne 'GET';
  if (my $form = $opts->{form}) {
    while (my ($key, $value) = each %$form) {
      push @cmd, '-d', "$key=$value";
    }
  } elsif (exists $opts->{content}) {
    push @cmd, '--data-binary', $opts->{content};
  }
  push @cmd, $url;

  open my $fh, '-|', @cmd
    or die "Failed to run curl for $method $path: $!";

  my $status_line = '';
  while (my $line = <$fh>) {
    $line =~ s/\r?\n$//;
    if ($line =~ m{^HTTP/}) {
      $status_line = $line;
      last;
    }
  }
  unless ($status_line) {
    close $fh;
    return {
      success     => 0,
      status      => 0,
      status_line => 'No HTTP status received',
      content     => '',
    };
  }

  my ($status, $reason) = $status_line =~ m{^HTTP/\S+\s+(\d+)\s*(.*)$};
  $reason //= '';

  while (my $line = <$fh>) {
    $line =~ s/\r?\n$//;
    last if $line eq '';
  }

  my $content = do { local $/; <$fh> };
  close $fh;

  return {
    success     => ($status && $status >= 200 && $status < 300),
    status      => $status,
    reason      => $reason,
    status_line => $status_line,
    content     => $content // '',
  };
}

sub stream_ndjson {
  my ($path, $callback) = @_;
  my $url = "$API_BASE$path";
  my $req = join '',
    "GET $url HTTP/1.1\r\n",
    "Host: lichess.org\r\n",
    "$auth_header\r\n",
    "Accept: application/x-ndjson\r\n",
    "Connection: close\r\n",
    "\r\n";

  my ($reader, $writer);
  my $pid = open2($reader, $writer, 'openssl', 's_client', '-quiet', 'lichess.org:443');
  print {$writer} $req;
  close $writer;

  my $sel = IO::Select->new($reader);
  my $header = '';
  while (1) {
    my $chunk = '';
    my $rv = sysread($reader, $chunk, 1);
    last unless $rv;
    $header .= $chunk;
    last if $header =~ /\r\n\r\n/;
  }

  unless ($header =~ m{HTTP/\S+\s+200}) {
    log_warn("Stream $path unexpected headers: " . encode_base64($header));
    close $reader;
    waitpid($pid, 0);
    return 0;
  }

  my $buffer = '';
  while ($sel->can_read) {
    my $chunk = '';
    my $rv = sysread($reader, $chunk, 4096);
    last unless $rv;
    $buffer .= $chunk;
    while ($buffer =~ s/^(.*?\n)//) {
      my $line = $1;
      $line =~ s/[\r\n]+$//;
      next unless length $line;
      my $payload = eval { decode_json($line) };
      if ($@) {
        log_warn("Failed to decode payload '$line': $@");
        next;
      }
      $callback->($payload);
    }
  }

  close $reader;
  waitpid($pid, 0);
  return 1;
}
