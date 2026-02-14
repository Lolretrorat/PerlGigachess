#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($Bin);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use Getopt::Long qw(GetOptions);
use JSON::PP qw(decode_json);

use lib File::Spec->catdir($Bin, '..');
use Chess::LocationModifer qw(default_store_path);

my $output;
GetOptions('output=s' => \$output)
  or die "Usage: perl script/update_location_modifiers.pl [--output path] source.json\n";

my $input = shift @ARGV
  or die "Usage: perl script/update_location_modifiers.pl [--output path] source.json\n";

my $json_text = do {
  open my $fh, '<', $input or die "Cannot read $input: $!";
  local $/;
  my $raw = <$fh>;
  close $fh or die "Error reading $input: $!";
  $raw;
};

my $tables = decode_json($json_text);

my @pieces = qw(
  KING QUEEN ROOK BISHOP KNIGHT PAWN
  OPP_KING OPP_QUEEN OPP_ROOK OPP_BISHOP OPP_KNIGHT OPP_PAWN
);
my @files = qw(a b c d e f g h);
my @ranks = (1 .. 8);

for my $piece (@pieces) {
  die "Missing entry for $piece in $input\n" unless exists $tables->{$piece};
  for my $file (@files) {
    for my $rank (@ranks) {
      my $square = $file . $rank;
      die "Missing square $square for $piece\n"
        unless exists $tables->{$piece}{$square};
    }
  }
}

my $target = $output // default_store_path();
die "Unable to determine target path\n" unless $target;
my $dir = dirname($target);
make_path($dir) unless -d $dir;

my $json_out = JSON::PP->new->canonical->pretty->encode($tables);
open my $out, '>', $target or die "Cannot write $target: $!";
print {$out} $json_out;
close $out or die "Error writing $target: $!";

say "Wrote location modifiers to $target";
