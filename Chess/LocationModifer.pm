package Chess::LocationModifer;

use strict;
use warnings;

use Carp qw(carp croak);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use JSON::PP;
use List::Util qw(sum);

use Chess::Constant;
use Chess::State;

require Exporter;
our @ISA = qw(Exporter);

our %location_modifiers = (
    KING => {
        a1 => 0, a2 => 0, a3 => 0, a4 => 0, a5 => 0, a6 => 0, a7 => 0, a8 => 0,
        b1 => 0, b2 => 0, b3 => 0, b4 => 0, b5 => 0, b6 => 0, b7 => 0, b8 => 0,
        c1 => 0, c2 => 0, c3 => 0, c4 => 0, c5 => 0, c6 => 0, c7 => 0, c8 => 0,
        d1 => 0, d2 => 0, d3 => 0, d4 => 0, d5 => 0, d6 => 0, d7 => 0, d8 => 0,
        e1 => 0, e2 => 0, e3 => 0, e4 => 0, e5 => 0, e6 => 0, e7 => 0, e8 => 0,
        f1 => 0, f2 => 0, f3 => 0, f4 => 0, f5 => 0, f6 => 0, f7 => 0, f8 => 0,
        g1 => 0, g2 => 0, g3 => 0, g4 => 0, g5 => 0, g6 => 0, g7 => 0, g8 => 0,
        h1 => 0, h2 => 0, h3 => 0, h4 => 0, h5 => 0, h6 => 0, h7 => 0, h8 => 0,
    },
    QUEEN => {
        a1 => 0, a2 => 0, a3 => 0, a4 => 0, a5 => 0, a6 => 0, a7 => 0, a8 => 0,
        b1 => 0, b2 => 0, b3 => 0, b4 => 0, b5 => 0, b6 => 0, b7 => 0, b8 => 0,
        c1 => 0, c2 => 0, c3 => 0, c4 => 0, c5 => 0, c6 => 0, c7 => 0, c8 => 0,
        d1 => 0, d2 => 0, d3 => 0, d4 => 0, d5 => 0, d6 => 0, d7 => 0, d8 => 0,
        e1 => 0, e2 => 0, e3 => 0, e4 => 0, e5 => 0, e6 => 0, e7 => 0, e8 => 0,
        f1 => 0, f2 => 0, f3 => 0, f4 => 0, f5 => 0, f6 => 0, f7 => 0, f8 => 0,
        g1 => 0, g2 => 0, g3 => 0, g4 => 0, g5 => 0, g6 => 0, g7 => 0, g8 => 0,
        h1 => 0, h2 => 0, h3 => 0, h4 => 0, h5 => 0, h6 => 0, h7 => 0, h8 => 0,
    },
    ROOK => {
        a1 => 0, a2 => 0, a3 => 0, a4 => 0, a5 => 0, a6 => 0, a7 => 0, a8 => 0,
        b1 => 0, b2 => 0, b3 => 0, b4 => 0, b5 => 0, b6 => 0, b7 => 0, b8 => 0,
        c1 => 0, c2 => 0, c3 => 0, c4 => 0, c5 => 0, c6 => 0, c7 => 0, c8 => 0,
        d1 => 0, d2 => 0, d3 => 0, d4 => 0, d5 => 0, d6 => 0, d7 => 0, d8 => 0,
        e1 => 0, e2 => 0, e3 => 0, e4 => 0, e5 => 0, e6 => 0, e7 => 0, e8 => 0,
        f1 => 0, f2 => 0, f3 => 0, f4 => 0, f5 => 0, f6 => 0, f7 => 0, f8 => 0,
        g1 => 0, g2 => 0, g3 => 0, g4 => 0, g5 => 0, g6 => 0, g7 => 0, g8 => 0,
        h1 => 0, h2 => 0, h3 => 0, h4 => 0, h5 => 0, h6 => 0, h7 => 0, h8 => 0,
    },
    BISHOP => {
        a1 => 0, a2 => 0, a3 => 0, a4 => 0, a5 => 0, a6 => 0, a7 => 0, a8 => 0,
        b1 => 0, b2 => 0, b3 => 0, b4 => 0, b5 => 0, b6 => 0, b7 => 0, b8 => 0,
        c1 => 0, c2 => 0, c3 => 0, c4 => 0, c5 => 0, c6 => 0, c7 => 0, c8 => 0,
        d1 => 0, d2 => 0, d3 => 0, d4 => 0, d5 => 0, d6 => 0, d7 => 0, d8 => 0,
        e1 => 0, e2 => 0, e3 => 0, e4 => 0, e5 => 0, e6 => 0, e7 => 0, e8 => 0,
        f1 => 0, f2 => 0, f3 => 0, f4 => 0, f5 => 0, f6 => 0, f7 => 0, f8 => 0,
        g1 => 0, g2 => 0, g3 => 0, g4 => 0, g5 => 0, g6 => 0, g7 => 0, g8 => 0,
        h1 => 0, h2 => 0, h3 => 0, h4 => 0, h5 => 0, h6 => 0, h7 => 0, h8 => 0,
    },
    KNIGHT => {
        a1 => 0, a2 => 0, a3 => 0, a4 => 0, a5 => 0, a6 => 0, a7 => 0, a8 => 0,
        b1 => 0, b2 => 0, b3 => 0, b4 => 0, b5 => 0, b6 => 0, b7 => 0, b8 => 0,
        c1 => 0, c2 => 0, c3 => 0, c4 => 0, c5 => 0, c6 => 0, c7 => 0, c8 => 0,
        d1 => 0, d2 => 0, d3 => 0, d4 => 0, d5 => 0, d6 => 0, d7 => 0, d8 => 0,
        e1 => 0, e2 => 0, e3 => 0, e4 => 0, e5 => 0, e6 => 0, e7 => 0, e8 => 0,
        f1 => 0, f2 => 0, f3 => 0, f4 => 0, f5 => 0, f6 => 0, f7 => 0, f8 => 0,
        g1 => 0, g2 => 0, g3 => 0, g4 => 0, g5 => 0, g6 => 0, g7 => 0, g8 => 0,
        h1 => 0, h2 => 0, h3 => 0, h4 => 0, h5 => 0, h6 => 0, h7 => 0, h8 => 0,
    },
    PAWN => {
        a1 => 0, a2 => 0, a3 => 0, a4 => 0, a5 => 0, a6 => 0, a7 => 0, a8 => 0,
        b1 => 0, b2 => 0, b3 => 0, b4 => 0, b5 => 0, b6 => 0, b7 => 0, b8 => 0,
        c1 => 0, c2 => 0, c3 => 0, c4 => 0, c5 => 0, c6 => 0, c7 => 0, c8 => 0,
        d1 => 0, d2 => 0, d3 => 0, d4 => 0, d5 => 0, d6 => 0, d7 => 0, d8 => 0,
        e1 => 0, e2 => 0, e3 => 0, e4 => 0, e5 => 0, e6 => 0, e7 => 0, e8 => 0,
        f1 => 0, f2 => 0, f3 => 0, f4 => 0, f5 => 0, f6 => 0, f7 => 0, f8 => 0,
        g1 => 0, g2 => 0, g3 => 0, g4 => 0, g5 => 0, g6 => 0, g7 => 0, g8 => 0,
        h1 => 0, h2 => 0, h3 => 0, h4 => 0, h5 => 0, h6 => 0, h7 => 0, h8 => 0,
    },
    OPP_KING => {
        a1 => 0, a2 => 0, a3 => 0, a4 => 0, a5 => 0, a6 => 0, a7 => 0, a8 => 0,
        b1 => 0, b2 => 0, b3 => 0, b4 => 0, b5 => 0, b6 => 0, b7 => 0, b8 => 0,
        c1 => 0, c2 => 0, c3 => 0, c4 => 0, c5 => 0, c6 => 0, c7 => 0, c8 => 0,
        d1 => 0, d2 => 0, d3 => 0, d4 => 0, d5 => 0, d6 => 0, d7 => 0, d8 => 0,
        e1 => 0, e2 => 0, e3 => 0, e4 => 0, e5 => 0, e6 => 0, e7 => 0, e8 => 0,
        f1 => 0, f2 => 0, f3 => 0, f4 => 0, f5 => 0, f6 => 0, f7 => 0, f8 => 0,
        g1 => 0, g2 => 0, g3 => 0, g4 => 0, g5 => 0, g6 => 0, g7 => 0, g8 => 0,
        h1 => 0, h2 => 0, h3 => 0, h4 => 0, h5 => 0, h6 => 0, h7 => 0, h8 => 0,
    },
    OPP_QUEEN => {
        a1 => 0, a2 => 0, a3 => 0, a4 => 0, a5 => 0, a6 => 0, a7 => 0, a8 => 0,
        b1 => 0, b2 => 0, b3 => 0, b4 => 0, b5 => 0, b6 => 0, b7 => 0, b8 => 0,
        c1 => 0, c2 => 0, c3 => 0, c4 => 0, c5 => 0, c6 => 0, c7 => 0, c8 => 0,
        d1 => 0, d2 => 0, d3 => 0, d4 => 0, d5 => 0, d6 => 0, d7 => 0, d8 => 0,
        e1 => 0, e2 => 0, e3 => 0, e4 => 0, e5 => 0, e6 => 0, e7 => 0, e8 => 0,
        f1 => 0, f2 => 0, f3 => 0, f4 => 0, f5 => 0, f6 => 0, f7 => 0, f8 => 0,
        g1 => 0, g2 => 0, g3 => 0, g4 => 0, g5 => 0, g6 => 0, g7 => 0, g8 => 0,
        h1 => 0, h2 => 0, h3 => 0, h4 => 0, h5 => 0, h6 => 0, h7 => 0, h8 => 0,
    },
    OPP_ROOK => {
        a1 => 0, a2 => 0, a3 => 0, a4 => 0, a5 => 0, a6 => 0, a7 => 0, a8 => 0,
        b1 => 0, b2 => 0, b3 => 0, b4 => 0, b5 => 0, b6 => 0, b7 => 0, b8 => 0,
        c1 => 0, c2 => 0, c3 => 0, c4 => 0, c5 => 0, c6 => 0, c7 => 0, c8 => 0,
        d1 => 0, d2 => 0, d3 => 0, d4 => 0, d5 => 0, d6 => 0, d7 => 0, d8 => 0,
        e1 => 0, e2 => 0, e3 => 0, e4 => 0, e5 => 0, e6 => 0, e7 => 0, e8 => 0,
        f1 => 0, f2 => 0, f3 => 0, f4 => 0, f5 => 0, f6 => 0, f7 => 0, f8 => 0,
        g1 => 0, g2 => 0, g3 => 0, g4 => 0, g5 => 0, g6 => 0, g7 => 0, g8 => 0,
        h1 => 0, h2 => 0, h3 => 0, h4 => 0, h5 => 0, h6 => 0, h7 => 0, h8 => 0,
    },
    OPP_BISHOP => {
        a1 => 0, a2 => 0, a3 => 0, a4 => 0, a5 => 0, a6 => 0, a7 => 0, a8 => 0,
        b1 => 0, b2 => 0, b3 => 0, b4 => 0, b5 => 0, b6 => 0, b7 => 0, b8 => 0,
        c1 => 0, c2 => 0, c3 => 0, c4 => 0, c5 => 0, c6 => 0, c7 => 0, c8 => 0,
        d1 => 0, d2 => 0, d3 => 0, d4 => 0, d5 => 0, d6 => 0, d7 => 0, d8 => 0,
        e1 => 0, e2 => 0, e3 => 0, e4 => 0, e5 => 0, e6 => 0, e7 => 0, e8 => 0,
        f1 => 0, f2 => 0, f3 => 0, f4 => 0, f5 => 0, f6 => 0, f7 => 0, f8 => 0,
        g1 => 0, g2 => 0, g3 => 0, g4 => 0, g5 => 0, g6 => 0, g7 => 0, g8 => 0,
        h1 => 0, h2 => 0, h3 => 0, h4 => 0, h5 => 0, h6 => 0, h7 => 0, h8 => 0,
    },
    OPP_KNIGHT => {
        a1 => 0, a2 => 0, a3 => 0, a4 => 0, a5 => 0, a6 => 0, a7 => 0, a8 => 0,
        b1 => 0, b2 => 0, b3 => 0, b4 => 0, b5 => 0, b6 => 0, b7 => 0, b8 => 0,
        c1 => 0, c2 => 0, c3 => 0, c4 => 0, c5 => 0, c6 => 0, c7 => 0, c8 => 0,
        d1 => 0, d2 => 0, d3 => 0, d4 => 0, d5 => 0, d6 => 0, d7 => 0, d8 => 0,
        e1 => 0, e2 => 0, e3 => 0, e4 => 0, e5 => 0, e6 => 0, e7 => 0, e8 => 0,
        f1 => 0, f2 => 0, f3 => 0, f4 => 0, f5 => 0, f6 => 0, f7 => 0, f8 => 0,
        g1 => 0, g2 => 0, g3 => 0, g4 => 0, g5 => 0, g6 => 0, g7 => 0, g8 => 0,
        h1 => 0, h2 => 0, h3 => 0, h4 => 0, h5 => 0, h6 => 0, h7 => 0, h8 => 0,
    },
    OPP_PAWN => {
        a1 => 0, a2 => 0, a3 => 0, a4 => 0, a5 => 0, a6 => 0, a7 => 0, a8 => 0,
        b1 => 0, b2 => 0, b3 => 0, b4 => 0, b5 => 0, b6 => 0, b7 => 0, b8 => 0,
        c1 => 0, c2 => 0, c3 => 0, c4 => 0, c5 => 0, c6 => 0, c7 => 0, c8 => 0,
        d1 => 0, d2 => 0, d3 => 0, d4 => 0, d5 => 0, d6 => 0, d7 => 0, d8 => 0,
        e1 => 0, e2 => 0, e3 => 0, e4 => 0, e5 => 0, e6 => 0, e7 => 0, e8 => 0,
        f1 => 0, f2 => 0, f3 => 0, f4 => 0, f5 => 0, f6 => 0, f7 => 0, f8 => 0,
        g1 => 0, g2 => 0, g3 => 0, g4 => 0, g5 => 0, g6 => 0, g7 => 0, g8 => 0,
        h1 => 0, h2 => 0, h3 => 0, h4 => 0, h5 => 0, h6 => 0, h7 => 0, h8 => 0,
    },
);

our @EXPORT_OK = qw(%location_modifiers load_from_file save_to_file train_from_stream default_store_path);

my @FILES = qw(a b c d e f g h);
my @RANKS = (1 .. 8);
my @ALL_SQUARES = map {
    my $file = $_;
    map { "$file$_" } @RANKS;
} @FILES;

my @TRAINABLE_PIECES = qw(KING QUEEN ROOK BISHOP KNIGHT PAWN);

my %PIECE_FROM_CHAR = (
    ''  => PAWN,
    P   => PAWN,
    N   => KNIGHT,
    B   => BISHOP,
    R   => ROOK,
    Q   => QUEEN,
    K   => KING,
);

my %PIECE_KEY = (
    PAWN()       => 'PAWN',
    KNIGHT()     => 'KNIGHT',
    BISHOP()     => 'BISHOP',
    ROOK()       => 'ROOK',
    QUEEN()      => 'QUEEN',
    KING()       => 'KING',
    OPP_PAWN()   => 'OPP_PAWN',
    OPP_KNIGHT() => 'OPP_KNIGHT',
    OPP_BISHOP() => 'OPP_BISHOP',
    OPP_ROOK()   => 'OPP_ROOK',
    OPP_QUEEN()  => 'OPP_QUEEN',
    OPP_KING()   => 'OPP_KING',
);

my %PROMOTION_FROM_CHAR = (
    Q => QUEEN,
    R => ROOK,
    B => BISHOP,
    N => KNIGHT,
);

sub default_store_path {
    return $ENV{PERLGIGACHESS_LOCATION_MODIFIER_FILE}
      if defined $ENV{PERLGIGACHESS_LOCATION_MODIFIER_FILE}
      && length $ENV{PERLGIGACHESS_LOCATION_MODIFIER_FILE};

    my $module_dir = dirname(__FILE__);
    my $root = File::Spec->catdir($module_dir, '..');
    return File::Spec->catfile($root, 'data', 'location_modifiers.json');
}

BEGIN {
    my $default = default_store_path();
    load_from_file($default) if defined $default && -e $default;
}

sub load_from_file {
    my ($path) = @_;
    return unless $path && -e $path;

    open my $fh, '<', $path or croak "Unable to open $path: $!";
    local $/;
    my $raw = <$fh>;
    close $fh;

    my $decoded = eval { JSON::PP->new->relaxed->decode($raw) };
    if ($@) {
        carp "Failed to parse $path: $@";
        return;
    }

    my $applied = _apply_external_preferences($decoded);
    _sync_opponent_modifiers() if $applied;
    return $applied;
}

sub save_to_file {
    my ($path) = @_;
    $path ||= default_store_path();
    my $dir = dirname($path);
    make_path($dir) unless -d $dir;

    open my $fh, '>', $path or croak "Unable to write $path: $!";
    print {$fh} JSON::PP->new->canonical->pretty->encode(\%location_modifiers);
    close $fh;
    return $path;
}

sub train_from_stream {
    my ($fh, %opts) = @_;
    $fh ||= \*STDIN;

    my %counts = map {
        my %template = map { $_ => 1 } @ALL_SQUARES;
        $_ => \%template;
    } @TRAINABLE_PIECES;

    my $max_games = $opts{max_games};
    my $scale = $opts{scale} // 60;
    my ($processed, $skipped_games, $skipped_moves) = (0, 0, 0);
    my @buffer;

    while (defined(my $line = <$fh>)) {
        if ($line =~ /\S/) {
            push @buffer, $line;
            next;
        }
        next unless @buffer;
        my $ok = _process_game_lines(\%counts, \@buffer, \$skipped_moves);
        $ok ? $processed++ : $skipped_games++;
        @buffer = ();
        last if $max_games && $processed >= $max_games;
    }

    if (@buffer && (!$max_games || $processed < $max_games)) {
        my $ok = _process_game_lines(\%counts, \@buffer, \$skipped_moves);
        $ok ? $processed++ : $skipped_games++;
    }

    _apply_counts(\%counts, $scale);
    _sync_opponent_modifiers();

    return {
        games_processed => $processed,
        games_skipped   => $skipped_games,
        moves_skipped   => $skipped_moves,
        scale           => $scale,
    };
}

sub _apply_external_preferences {
    my ($data) = @_;
    return unless ref $data eq 'HASH';

    for my $piece (keys %location_modifiers) {
        my $target = $location_modifiers{$piece};
        next unless exists $data->{$piece};
        my $incoming = $data->{$piece};
        for my $square (keys %{$target}) {
            next unless exists $incoming->{$square};
            $target->{$square} = $incoming->{$square};
        }
    }

    return 1;
}

sub _process_game_lines {
    my ($counts, $lines, $skipped_moves_ref) = @_;
    my %tags;
    for my $line (@{$lines}) {
        if ($line =~ /^\[(\w+)\s+"([^"]*)"\]/) {
            $tags{$1} = $2;
        }
    }

    my $fen;
    if (($tags{SetUp} // '') eq '1' && $tags{FEN}) {
        $fen = $tags{FEN};
    }

    my $state = eval { Chess::State->new($fen) };
    if ($@) {
        carp "Skipping game due to invalid FEN: $@";
        return 0;
    }

    my $body = join ' ', grep { $_ !~ /^\[/ } @{$lines};
    $body = _clean_pgn_body($body);
    my @tokens = split /\s+/, $body;

    TOKEN: for my $raw (@tokens) {
        next unless length $raw;
        next if $raw eq '...';

        if ($raw =~ /^\d+\.(.*)$/) {
            $raw = $1;
            redo TOKEN unless length $raw;
        }

        next if $raw =~ /^\d+\.{1,3}$/;
        last if $raw =~ /^(1-0|0-1|1\/2-1\/2|\*)$/;

        my $move = _san_to_move($state, $raw);
        unless ($move) {
            ${$skipped_moves_ref}++;
            next;
        }

        my $uci = $state->decode_move($move);
        my $to_square = substr($uci, 2, 2);
        my $board = $state->[Chess::State::BOARD];
        my $piece = $board->[$move->[0]];
        my $piece_key = _piece_key($piece);

        if ($piece_key && exists $counts->{$piece_key}) {
            $counts->{$piece_key}{$to_square}++;
        } else {
            ${$skipped_moves_ref}++;
        }

        my $next_state = $state->make_move($move);
        if ($next_state) {
            $state = $next_state;
        } else {
            ${$skipped_moves_ref}++;
        }
    }

    return 1;
}

sub _clean_pgn_body {
    my ($body) = @_;
    $body =~ s/\{[^}]*\}//g while $body =~ /\{/ && $body =~ /\}/;
    $body =~ s/\([^()]*\)//g while $body =~ /\(/ && $body =~ /\)/;
    $body =~ s/;[^\n]*//g;
    $body =~ s/\$[0-9]+//g;
    $body =~ s/\r//g;
    $body =~ tr/\x{00A0}/ /;
    return $body;
}

sub _san_to_move {
    my ($state, $token) = @_;
    my $san = $token;
    $san =~ s/[!?]+$//;
    $san =~ s/[+#]+$//;
    $san =~ s/e\.p\.//i;

    return _find_castle_move($state, CASTLE_KING)  if $san =~ /^O-O$/i;
    return _find_castle_move($state, CASTLE_QUEEN) if $san =~ /^O-O-O$/i;

    my $promotion;
    $promotion = $1 if $san =~ s/=([QRBN])$//;
    my $is_capture = $san =~ s/x//;

    my $piece_letter = '';
    $piece_letter = $1 if $san =~ s/^([KQRBN])//;

    return unless $san =~ /([a-h][1-8])$/;
    my $target = $1;
    $san =~ s/[a-h][1-8]$//;

    my ($dis_file, $dis_rank);
    if (length $san) {
        if ($san =~ /^([a-h])([1-8])$/) {
            ($dis_file, $dis_rank) = ($1, $2);
        } elsif ($san =~ /^([1-8])([a-h])$/) {
            ($dis_rank, $dis_file) = ($1, $2);
        } elsif ($san =~ /^[a-h]$/) {
            $dis_file = $san;
        } elsif ($san =~ /^[1-8]$/) {
            $dis_rank = $san;
        } else {
            return;
        }
    }

    my $piece_type = $PIECE_FROM_CHAR{$piece_letter} // PAWN;
    my $board = $state->[Chess::State::BOARD];

    MOVE: for my $move (@{$state->generate_pseudo_moves}) {
        my $uci = $state->decode_move($move);
        my $from = substr($uci, 0, 2);
        my $to = substr($uci, 2, 2);
        next if $to ne $target;

        my $board_piece = $board->[$move->[0]];
        next if $board_piece != $piece_type;

        if (defined $dis_file && substr($from, 0, 1) ne $dis_file) {
            next MOVE;
        }
        if (defined $dis_rank && substr($from, 1, 1) ne $dis_rank) {
            next MOVE;
        }

        my $dest_piece = $board->[$move->[1]];
        if ($is_capture) {
            next MOVE unless $dest_piece < 0;
        } else {
            next MOVE if $dest_piece < 0;
        }

        if ($promotion) {
            my $promo_piece = $PROMOTION_FROM_CHAR{$promotion} or next MOVE;
            next MOVE unless defined $move->[2] && $move->[2] == $promo_piece;
        } else {
            next MOVE if defined $move->[2];
        }

        return $move;
    }

    return;
}

sub _find_castle_move {
    my ($state, $castle_flag) = @_;
    for my $move (@{$state->generate_pseudo_moves}) {
        next unless defined $move->[3];
        return $move if $move->[3] == $castle_flag;
    }
    return;
}

sub _apply_counts {
    my ($counts, $scale) = @_;
    my $square_total = scalar @ALL_SQUARES || 64;

    for my $piece (@TRAINABLE_PIECES) {
        my $square_counts = $counts->{$piece} || next;
        my $total = sum(values %{$square_counts}) || next;
        my $mean = $total / $square_total;
        for my $square (@ALL_SQUARES) {
            my $hits = $square_counts->{$square} || 1;
            my $ratio = $hits / ($mean || 1);
            my $score = int(log($ratio) * $scale);
            $location_modifiers{$piece}{$square} = $score;
        }
    }
}

sub _sync_opponent_modifiers {
    for my $piece (@TRAINABLE_PIECES) {
        my $opp_key = 'OPP_' . $piece;
        next unless exists $location_modifiers{$opp_key};
        for my $square (@ALL_SQUARES) {
            my $value = $location_modifiers{$piece}{$square} // 0;
            $location_modifiers{$opp_key}{$square} = -$value;
        }
    }
}

sub _piece_key {
    my ($piece) = @_;
    return $PIECE_KEY{$piece};
}

1;
