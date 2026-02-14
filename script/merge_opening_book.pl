#!/usr/bin/env perl
use v5.14;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use JSON::PP qw(decode_json encode_json);
use File::Basename qw(dirname);
use File::Path qw(make_path);

my $base;
my $delta;
my $output;

GetOptions(
  'base=s'   => \$base,
  'delta=s'  => \$delta,
  'output=s' => \$output,
) or die "Usage: $0 --base PATH --delta PATH --output PATH\n";

die "Usage: $0 --base PATH --delta PATH --output PATH\n"
  unless defined $base && defined $delta && defined $output;

die "Missing delta file: $delta\n" unless -e $delta;

my $base_entries = _read_entries($base, 1);
my $delta_entries = _read_entries($delta, 0);

my %by_key;
for my $entry (@$base_entries, @$delta_entries) {
  next unless ref $entry eq 'HASH';
  my $key = $entry->{key} // next;
  my $moves = $entry->{moves};
  next unless ref $moves eq 'ARRAY';

  for my $move (@$moves) {
    next unless ref $move eq 'HASH';
    my $uci = $move->{uci} // next;
    next unless $uci =~ /^[a-h][1-8][a-h][1-8][nbrq]?$/;

    my $played = _num($move->{played}, _num($move->{weight}, 0));
    next if $played <= 0;

    my $slot = ($by_key{$key}{$uci} ||= {
      played => 0,
      white  => 0,
      draw   => 0,
      black  => 0,
    });

    $slot->{played} += $played;
    $slot->{white}  += _num($move->{white}, 0);
    $slot->{draw}   += _num($move->{draw}, 0);
    $slot->{black}  += _num($move->{black}, 0);
  }
}

my @out;
for my $key (keys %by_key) {
  my @moves = map {
    my $stats = $by_key{$key}{$_};
    {
      uci    => $_,
      weight => $stats->{played},
      played => $stats->{played},
      white  => $stats->{white},
      draw   => $stats->{draw},
      black  => $stats->{black},
    }
  } keys %{ $by_key{$key} };

  @moves = sort {
    ($b->{played} <=> $a->{played}) || ($a->{uci} cmp $b->{uci})
  } @moves;

  push @out, { key => $key, moves => \@moves };
}

@out = sort {
  (_total_played($b) <=> _total_played($a)) || ($a->{key} cmp $b->{key})
} @out;

my $out_dir = dirname($output);
make_path($out_dir) unless -d $out_dir;

open my $fh, '>', $output or die "Cannot write $output: $!\n";
print {$fh} JSON::PP->new->canonical->pretty->encode(\@out);
close $fh;

print "entries=" . scalar(@out) . "\n";
print "output=$output\n";

sub _read_entries {
  my ($path, $allow_missing) = @_;
  if (!-e $path) {
    return [] if $allow_missing;
    die "Missing file: $path\n";
  }

  open my $fh, '<', $path or die "Cannot read $path: $!\n";
  local $/;
  my $raw = <$fh>;
  close $fh;

  my $decoded = eval { decode_json($raw) };
  if ($@ || ref $decoded ne 'ARRAY') {
    die "Invalid opening-book JSON: $path\n";
  }
  return $decoded;
}

sub _num {
  my ($v, $default) = @_;
  return $default unless defined $v && $v =~ /^-?\d+(?:\.\d+)?$/;
  return 0 + $v;
}

sub _total_played {
  my ($entry) = @_;
  my $sum = 0;
  for my $move (@{ $entry->{moves} || [] }) {
    $sum += _num($move->{played}, _num($move->{weight}, 0));
  }
  return $sum;
}
