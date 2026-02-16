#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use IPC::Open2;
use JSON::PP qw(encode_json decode_json);

my $PATH_LIST_SEP = ($^O eq 'MSWin32') ? ';' : ':';
my $resolved_probetool_path;
my $resolved_probetool_checked = 0;
my %stdio_probe_cache;
my $STDIO_PROBE_CACHE_MAX = 5_000;

sub _result {
  my ($payload) = @_;
  print encode_json($payload), "\n";
}

sub _normalize_paths {
  my (@values) = @_;
  my @unique;
  my %seen;
  foreach my $raw (@values) {
    next unless defined $raw && length $raw;
    foreach my $path (split /\Q$PATH_LIST_SEP\E/, $raw) {
      $path =~ s/^\s+//;
      $path =~ s/\s+$//;
      next unless length $path;
      next if $seen{$path}++;
      push @unique, $path;
    }
  }
  return @unique;
}

sub _category_from_wdl {
  my ($wdl) = @_;
  return 'win'          if $wdl == 2;
  return 'cursed-win'   if $wdl == 1;
  return 'draw'         if $wdl == 0;
  return 'blessed-loss' if $wdl == -1;
  return 'loss'         if $wdl == -2;
  return 'unknown';
}

sub _resolve_probetool_path {
  return $resolved_probetool_path if $resolved_probetool_checked;
  $resolved_probetool_checked = 1;

  my @candidates;

  if (defined $ENV{CHESS_SYZYGY_PROBETOOL} && length $ENV{CHESS_SYZYGY_PROBETOOL}) {
    push @candidates, $ENV{CHESS_SYZYGY_PROBETOOL};
  }
  push @candidates,
    'scripts/probetool',
    '/tmp/syzygy_probetool/regular/probetool';

  for my $path (@candidates) {
    next unless defined $path && length $path;
    if (-x $path) {
      $resolved_probetool_path = $path;
      return $resolved_probetool_path;
    }
  }
  $resolved_probetool_path = undef;
  return;
}

sub _wdl_from_meaning {
  my ($meaning, $score_kind, $score_value) = @_;
  my $m = lc($meaning // '');
  return 2  if $m =~ /tb\s+win/;
  return -2 if $m =~ /tb\s+loss/;
  return 1  if $m =~ /cursed\s+win/;
  return -1 if $m =~ /blessed\s+loss/;
  return 0  if $m =~ /\bdraw\b/;

  if ($m =~ /mate\s+score/) {
    return ($score_value // 0) >= 0 ? 2 : -2;
  }
  if (($score_kind // '') eq 'cp') {
    return 2  if $score_value > 100;
    return -2 if $score_value < -100;
    return 1  if $score_value > 0;
    return -1 if $score_value < 0;
    return 0;
  }

  return 0;
}

sub _probe_with_probetool {
  my ($fen, $tb_paths, $probetool) = @_;
  my $path_arg = join($PATH_LIST_SEP, @$tb_paths);

  my @cmd = ($probetool, '-u', '-r', '-p', $path_arg, $fen);
  my $raw = '';
  my $ok = eval {
    open my $fh, '-|', @cmd or die "spawn failed";
    local $/;
    $raw = <$fh>;
    close $fh or die "probetool failed";
    1;
  };

  if (!$ok || !defined $raw || $raw !~ /\S/) {
    my $err = $@ || 'empty_output';
    $err =~ s/\s+$//;
    return { source => 'syzygy', moves => [], error => "probe_failed:$err" };
  }

  my @moves;
  my $mode;
  my $capture_rows = 0;

  for my $line (split /\n/, $raw) {
    if ($line =~ /^root_probe_(dtz|wdl)\(\):\s*$/) {
      my $candidate = $1;
      if (!@moves || $candidate eq 'dtz') {
        $mode = $candidate;
        $capture_rows = 0;
      } else {
        $mode = undef;
        $capture_rows = 0;
      }
      next;
    }

    next unless defined $mode;

    if ($line =~ /^move\s+rank\s+score\s+meaning\s*$/) {
      $capture_rows = 1;
      next;
    }

    if ($capture_rows && $line =~ /^\s*$/) {
      $capture_rows = 0;
      $mode = undef;
      next;
    }

    next unless $capture_rows;
    if ($line =~ /^\s*([a-h][1-8][a-h][1-8][nbrq]?)\s+(-?\d+)\s+(cp|mate)\s+(-?\d+)\s+(.+?)\s*$/i) {
      my ($uci, $rank, $score_kind, $score_value, $meaning) = ($1, $2, lc($3), $4 + 0, $5);
      my $wdl = _wdl_from_meaning($meaning, $score_kind, $score_value);
      push @moves, {
        uci      => lc($uci),
        wdl      => $wdl,
        dtz      => undef,
        category => _category_from_wdl($wdl),
        rank     => int($rank),
      };
    }
  }

  if (!@moves) {
    return { source => 'syzygy', moves => [], error => 'probe_failed:no_root_moves' };
  }

  my $n = scalar(@moves);
  for my $idx (0 .. $#moves) {
    $moves[$idx]{weight} = $n - $idx;
  }

  @moves = sort {
    ($b->{rank} <=> $a->{rank})
      || ($b->{weight} <=> $a->{weight})
      || ($a->{uci} cmp $b->{uci})
  } @moves;

  return { source => 'syzygy', engine => 'probetool', moves => \@moves };
}

sub _probe_with_python {
  my ($fen, $tb_paths) = @_;

  my $python = $ENV{CHESS_SYZYGY_PYTHON} // 'python3';
  my $dtz_max_candidates = $ENV{CHESS_SYZYGY_DTZ_MAX_CANDIDATES};
  $dtz_max_candidates = 8
    unless defined $dtz_max_candidates && $dtz_max_candidates =~ /^\d+$/;
  $dtz_max_candidates = 1 if $dtz_max_candidates < 1;
  $dtz_max_candidates = 128 if $dtz_max_candidates > 128;
  my $py_code = <<'PYCODE';
import json
import sys

def _category_from_wdl(wdl):
    if wdl == 2:
        return "win"
    if wdl == 1:
        return "cursed-win"
    if wdl == 0:
        return "draw"
    if wdl == -1:
        return "blessed-loss"
    if wdl == -2:
        return "loss"
    return "unknown"

def _emit(payload):
    sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")

def main():
    try:
        payload = json.load(sys.stdin)
    except Exception as exc:
        _emit({"source": "syzygy", "moves": [], "error": f"probe_failed:{exc}"})
        return 0

    fen = payload.get("fen", "")
    tb_paths = payload.get("tb_paths", [])
    dtz_max_candidates = payload.get("dtz_max_candidates", 8)
    try:
        dtz_max_candidates = int(dtz_max_candidates)
    except Exception:
        dtz_max_candidates = 8
    if dtz_max_candidates < 1:
        dtz_max_candidates = 1

    try:
        import chess
        import chess.syzygy
    except Exception as exc:
        _emit({"source": "syzygy", "moves": [], "error": f"missing_dependency:{exc}"})
        return 2

    try:
        board = chess.Board(fen)
    except Exception as exc:
        _emit({"source": "syzygy", "moves": [], "error": f"invalid_fen:{exc}"})
        return 0

    moves = []
    try:
        with chess.syzygy.open_tablebase(tb_paths[0]) as tb:
            for path in tb_paths[1:]:
                tb.add_directory(path)

            legal = list(board.legal_moves)
            scanned = []
            for index, move in enumerate(legal):
                board.push(move)
                try:
                    child_wdl = int(tb.probe_wdl(board))
                except Exception:
                    board.pop()
                    continue
                board.pop()
                scanned.append(
                    {
                        "index": index,
                        "move": move,
                        "wdl": -child_wdl,
                    }
                )

            if not scanned:
                _emit({"source": "syzygy", "moves": [], "error": "probe_failed:no_root_moves"})
                return 0

            best_wdl = max(item["wdl"] for item in scanned)
            dtz_candidates = [item for item in scanned if item["wdl"] == best_wdl]
            dtz_candidates.sort(key=lambda item: item["index"])
            dtz_indexes = {item["index"] for item in dtz_candidates[:dtz_max_candidates]}

            for item in scanned:
                index = item["index"]
                move = item["move"]
                wdl = item["wdl"]
                child_dtz = None
                if index in dtz_indexes:
                    board.push(move)
                    try:
                        child_dtz = int(tb.probe_dtz(board))
                    except Exception:
                        child_dtz = None
                    board.pop()

                rank = {2: 500000, 1: 400000, 0: 300000, -1: 200000, -2: 100000}.get(wdl, 0)

                if child_dtz is not None:
                    abs_dtz = abs(child_dtz)
                    if wdl > 0:
                        rank += max(0, 400 - min(abs_dtz, 400)) * 10
                    elif wdl < 0:
                        rank += min(abs_dtz, 400) * 10
                    else:
                        rank += max(0, 400 - min(abs_dtz, 400))

                rank -= index

                moves.append(
                    {
                        "uci": move.uci(),
                        "wdl": wdl,
                        "dtz": child_dtz,
                        "category": _category_from_wdl(wdl),
                        "rank": rank,
                        "weight": max(1, len(legal) - index),
                    }
                )
    except Exception as exc:
        _emit({"source": "syzygy", "moves": [], "error": f"probe_failed:{exc}"})
        return 0

    moves.sort(key=lambda item: (item.get("rank", 0), item.get("weight", 0)), reverse=True)
    _emit({"source": "syzygy", "engine": "python-chess", "moves": moves})
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
PYCODE

  my ($probe_out, $probe_in);
  my $pid = eval { open2($probe_out, $probe_in, $python, '-c', $py_code) };
  if (!$pid || $@) {
    my $err = $@ || 'spawn failed';
    $err =~ s/\s+$//;
    return { source => 'syzygy', moves => [], error => "missing_dependency:$err" };
  }

  print {$probe_in} encode_json({
    fen                => $fen,
    tb_paths           => $tb_paths,
    dtz_max_candidates => $dtz_max_candidates,
  });
  close $probe_in;

  local $/;
  my $raw = <$probe_out>;
  close $probe_out;
  waitpid($pid, 0);

  if (!defined $raw || $raw !~ /\S/) {
    return { source => 'syzygy', moves => [], error => 'probe_failed:empty_output' };
  }

  my $decoded = eval { decode_json($raw) };
  if ($@ || ref $decoded ne 'HASH') {
    return { source => 'syzygy', moves => [], error => 'probe_failed:invalid_output' };
  }

  return $decoded;
}

sub _probe_payload {
  my ($fen, $tb_paths) = @_;
  my $payload;
  if (my $probetool = _resolve_probetool_path()) {
    $payload = _probe_with_probetool($fen, $tb_paths, $probetool);
  }

  if (!defined $payload || ref $payload ne 'HASH' || ref $payload->{moves} ne 'ARRAY') {
    $payload = _probe_with_python($fen, $tb_paths);
  }

  return $payload;
}

sub _run_stdio {
  my ($tb_paths) = @_;
  local $| = 1;

  while (my $line = <STDIN>) {
    $line =~ s/\s+$//;
    next unless length $line;

    my $request = eval { decode_json($line) };
    if ($@ || ref $request ne 'HASH') {
      _result({ source => 'syzygy', moves => [], error => 'invalid_request' });
      next;
    }

    my $fen = $request->{fen};
    if (!defined $fen || !length $fen) {
      _result({ source => 'syzygy', moves => [], error => 'missing_fen' });
      next;
    }

    if (exists $stdio_probe_cache{$fen}) {
      _result($stdio_probe_cache{$fen});
      next;
    }

    my $payload = _probe_payload($fen, $tb_paths);
    if (!defined $payload || ref $payload ne 'HASH' || ref $payload->{moves} ne 'ARRAY') {
      $payload = { source => 'syzygy', moves => [], error => 'probe_failed:invalid_output' };
    }
    if (scalar(keys %stdio_probe_cache) >= $STDIO_PROBE_CACHE_MAX) {
      %stdio_probe_cache = ();
    }
    $stdio_probe_cache{$fen} = $payload;
    _result($payload);
  }
}

my $fen;
my @tb_path;
my $stdio = 0;
GetOptions(
  'fen=s'     => \$fen,
  'stdio!'    => \$stdio,
  'tb-path=s' => \@tb_path,
) or die "Usage: $0 [--stdio] --fen FEN --tb-path DIR [--tb-path DIR...]\n";

my @tb_paths = _normalize_paths(@tb_path);
if (!@tb_paths) {
  _result({ source => 'syzygy', moves => [], error => 'missing_tb_path' });
  exit 0;
}

foreach my $path (@tb_paths) {
  if (!-d $path) {
    _result({ source => 'syzygy', moves => [], error => "invalid_tb_path:$path" });
    exit 0;
  }
}

if ($stdio) {
  _run_stdio(\@tb_paths);
  exit 0;
}

die "Usage: $0 [--stdio] --fen FEN --tb-path DIR [--tb-path DIR...]\n"
  unless defined $fen && length $fen;

my $payload = _probe_payload($fen, \@tb_paths);
_result($payload);
my $exit_code = $? >> 8;
exit($exit_code);
