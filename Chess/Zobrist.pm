package Chess::Zobrist;
use strict;
use warnings;

use Digest::SHA qw(sha256);

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(
  zobrist_empty_key
  zobrist_is_key
  zobrist_key_hex
  zobrist_turn_token
  zobrist_piece_token
  zobrist_castle_token
  zobrist_ep_token
);

my @piece_tokens;
my @castle_tokens;
my @ep_tokens;
my $turn_token;

sub zobrist_empty_key {
  return "\0" x 8;
}

sub zobrist_is_key {
  my ($key) = @_;
  return defined $key
    && !ref($key)
    && length($key) == 8;
}

sub zobrist_key_hex {
  my ($key) = @_;
  return unless zobrist_is_key($key);
  return unpack('H16', $key);
}

sub zobrist_turn_token {
  return $turn_token;
}

sub zobrist_piece_token {
  my ($piece_idx, $square) = @_;
  return if !defined $piece_idx || !defined $square;
  return if $piece_idx < 0 || $piece_idx > 11;
  return if $square < 0 || $square > 63;
  return $piece_tokens[$piece_idx][$square];
}

sub zobrist_castle_token {
  my ($color, $side) = @_;
  return if !defined $color || !defined $side;
  return if $color < 0 || $color > 1;
  return if $side < 0 || $side > 1;
  return $castle_tokens[$color][$side];
}

sub zobrist_ep_token {
  my ($square) = @_;
  return if !defined $square;
  return if $square < 0 || $square > 63;
  return $ep_tokens[$square];
}

sub _token {
  my ($label) = @_;
  return substr(sha256($label), 0, 8);
}

sub _init_tokens {
  for my $piece_idx (0 .. 11) {
    for my $square (0 .. 63) {
      $piece_tokens[$piece_idx][$square] = _token("piece:$piece_idx:$square");
    }
  }

  for my $color (0 .. 1) {
    for my $side (0 .. 1) {
      $castle_tokens[$color][$side] = _token("castle:$color:$side");
    }
  }

  for my $square (0 .. 63) {
    $ep_tokens[$square] = _token("ep:$square");
  }

  $turn_token = _token('turn:black');
}

_init_tokens();

1;
