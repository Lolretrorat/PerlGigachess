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
use Text::ParseWords qw(shellwords);
use POSIX ':sys_wait_h';
use Config;
use IO::Socket::SSL qw(SSL_VERIFY_PEER);

eval {
  require IO::Socket::SSL;
  IO::Socket::SSL->import();
  require Mozilla::CA;
  1;
} or die "Install IO::Socket::SSL and Mozilla::CA to use lichess.pl: $@";

load_env("$RealBin/.env");

my $token = $ENV{LICHESS_TOKEN}
  or die "Set LICHESS_TOKEN to a Bot API token generated on lichess.org\n";
my $engine_cmd = $ENV{LICHESS_ENGINE_CMD} // "$^X $RealBin/play.pl --uci";
my @engine_parts = shellwords($engine_cmd);
@engine_parts or die "Unable to parse LICHESS_ENGINE_CMD '$engine_cmd'\n";

STDOUT->autoflush(1);
STDERR->autoflush(1);

my $debug = $ENV{LICHESS_DEBUG} // 0;

my $auth_header = "Bearer $token";
my $ssl_ca_file = Mozilla::CA::SSL_ca_file();
my $user_agent  = 'PerlGigachess/0.1';

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

  unless (uci_handshake($engine_out, $engine_in)) {
    log_warn("Engine handshake failed, aborting game $game_id");
    kill 'TERM', $engine_pid;
    waitpid($engine_pid, 0);
    return;
  }

  my %game = (
    id           => $game_id,
    my_color     => normalize_color($seed_info->{color}),
    initial_fen  => normalize_fen($seed_info->{fen}),
    moves        => [],
    pending_move => undef,
    status       => 'created',
    wtime        => undef,
    btime        => undef,
    winc         => 0,
    binc         => 0,
    is_my_turn   => extract_turn_flag($seed_info),
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
    update_turn_from_event($game, $event);
    print {$engine_in} "ucinewgame\n";
    maybe_move($game, $engine_out, $engine_in);
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

  my $best = compute_bestmove($game, $engine_out, $engine_in);
  if (!$best || $best eq '(none)') {
    log_warn("Engine returned no move for $game->{id}");
    return;
  }

  if (send_move($game->{id}, $best)) {
    $game->{pending_move} = $best;
    $game->{is_my_turn}   = 0;
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

  while (my $line = <$engine_out>) {
    $line =~ s/[\r\n]+$//;
    if ($line =~ /^bestmove\s+(\S+)/) {
      return $1;
    }
  }
  return;
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
    log_warn("Move $move for $game_id was rejected: " . $res->{status_line});
    return 0;
  }
  return 1;
}

sub api_abort_game {
  my ($game_id) = @_;
  return http_request('POST', "/bot/game/$game_id/abort");
}

sub api_resign_game {
  my ($game_id) = @_;
  return http_request('POST', "/bot/game/$game_id/resign");
}

sub api_claim_draw {
  my ($game_id) = @_;
  return http_request('POST', "/bot/game/$game_id/claim-draw");
}

sub api_claim_victory {
  my ($game_id) = @_;
  return http_request('POST', "/bot/game/$game_id/claim-victory");
}

sub api_handle_takeback {
  my ($game_id, $accept) = @_;
  my $decision = $accept ? 'yes' : 'no';
  return http_request('POST', "/bot/game/$game_id/takeback/$decision");
}

sub api_send_chat {
  my ($game_id, $room, $text) = @_;
  $text //= '';
  if (length $text > 140) {
    log_warn("Chat message too long ($game_id): " . length($text));
    return { success => 0, status => 0, status_line => 'chat too long', content => '' };
  }
  return http_request('POST', "/bot/game/$game_id/chat", {
    form => { room => $room, text => $text },
    accept => 'application/json',
  });
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

sub mask_secret {
  my ($text) = @_;
  return $text unless defined $token && length $token;
  my $needle = "Bearer $token";
  $text =~ s/\Q$needle\E/Bearer <redacted>/g;
  return $text;
}

sub _drain_ndjson {
  my ($path, $buffer_ref, $callback) = @_;
  while ($$buffer_ref =~ s/^(.*?\n)//) {
    my $line = $1;
    $line =~ s/[\r\n]+$//;
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
    my ($key, $value) = split /:\s*/, $line, 2;
    next unless defined $key && defined $value;
    $headers{lc $key} = $value;
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

sub _consume_raw {
  my ($fh, $cb) = @_;
  while (1) {
    my $chunk = '';
    my $rv = sysread($fh, $chunk, 4096);
    last unless $rv;
    $cb->($chunk);
  }
  return 1;
}

sub _read_line {
  my ($fh) = @_;
  my $line = '';
  while (1) {
    my $char = '';
    my $rv = sysread($fh, $char, 1);
    return if !defined $rv || $rv == 0;
    $line .= $char;
    last if $char eq "\n";
  }
  return $line;
}

sub _read_exact {
  my ($fh, $len) = @_;
  my $data = '';
  while (length($data) < $len) {
    my $chunk = '';
    my $rv = sysread($fh, $chunk, $len - length($data));
    return unless defined $rv && $rv > 0;
    $data .= $chunk;
  }
  return $data;
}

sub _read_all {
  my ($fh) = @_;
  my $data = '';
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

  my $sock = IO::Socket::SSL->new(
    PeerHost        => 'lichess.org',
    PeerPort        => 443,
    SSL_verify_mode => SSL_VERIFY_PEER(),
    SSL_ca_file     => $ssl_ca_file,
    SNI_hostname    => 'lichess.org',
  );
  unless ($sock) {
    my $err = IO::Socket::SSL::errstr() // 'unknown';
    return {
      success     => 0,
      status      => 0,
      reason      => $err,
      status_line => "IO::Socket::SSL error: $err",
      content     => '',
    };
  }
  $sock->autoflush(1);

  my %headers = (
    'Host'          => 'lichess.org',
    'Authorization' => $auth_header,
    'User-Agent'    => $user_agent,
    'Accept'        => $opts->{accept} // 'application/json',
    'Connection'    => 'close',
  );
  if (my $extra = $opts->{headers}) {
    foreach my $key (keys %$extra) {
      $headers{$key} = $extra->{$key};
    }
  }
  if (length $content) {
    $headers{'Content-Length'} = length($content);
  }

  my $request = sprintf "%s %s HTTP/1.1\r\n", $method, $relative;
  foreach my $key (keys %headers) {
    my $value = $headers{$key};
    $request .= "$key: $value\r\n";
  }
  $request .= "\r\n";
  $request .= $content if length $content;

  print {$sock} $request;

  my $resp_headers = _read_http_headers($sock);
  my $status_line = $resp_headers->{status_line} // 'HTTP/1.1 000';
  my ($status, $reason) = $status_line =~ m{^HTTP/\S+\s+(\d+)\s*(.*)$};
  $reason //= '';

  my $body = '';
  my $te = $resp_headers->{'transfer-encoding'} // '';
  if ($te =~ /chunked/i) {
    my $ok = _consume_chunked($sock, sub { $body .= shift });
    $body = '' unless $ok;
  } elsif (defined(my $len = $resp_headers->{'content-length'})) {
    my $data = _read_exact($sock, $len);
    $body = defined $data ? $data : '';
  } else {
    $body = _read_all($sock);
  }
  close $sock;

  return {
    success     => ($status && $status >= 200 && $status < 300) ? 1 : 0,
    status      => $status // 0,
    reason      => $reason,
    status_line => $status_line,
    content     => $body // '',
  };
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

sub stream_ndjson {
  my ($path, $callback) = @_;
  my $attempt = 0;

  while (1) {
    $attempt ++;
    log_info("Opening stream $path (attempt $attempt)");
    my $sock = IO::Socket::SSL->new(
      PeerHost        => 'lichess.org',
      PeerPort        => 443,
      SSL_verify_mode => SSL_VERIFY_PEER(),
      SSL_ca_file     => $ssl_ca_file,
      SNI_hostname    => 'lichess.org',
    );
    if (!$sock) {
      log_warn("Unable to open TLS socket: " . IO::Socket::SSL::errstr());
      sleep 2;
      next;
    }
    $sock->autoflush(1);

    my $request = join('', 
      "GET /api$path HTTP/1.1\r\n",
      "Host: lichess.org\r\n",
      "Authorization: Bearer $token\r\n",
      "Accept: application/x-ndjson\r\n",
      "User-Agent: $user_agent\r\n",
      "Connection: keep-alive\r\n",
      "\r\n"
    );
    print {$sock} $request;

    my $headers = _read_http_headers($sock);
    if (!$headers->{status} || $headers->{status} !~ /^2/) {
      my $status_line = $headers->{status_line} // 'unknown';
      my $body = _read_all($sock);
      log_warn("Stream $path failed: $status_line body=$body");
      close $sock;
      sleep 1;
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

    close $sock;

    if ($ok) {
      log_info("Stream $path completed");
      return 1;
    }

    log_warn("Stream $path closed unexpectedly");

    if ($path =~ m{/bot/game/stream/} && $attempt < 5) {
      log_info("Retrying game stream $path in 1s");
      sleep 1;
      next;
    }

    return 0;
  }
}
