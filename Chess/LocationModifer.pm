package Chess::LocationModifer;

use strict;
use warnings;

use Carp qw(carp croak);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use JSON::PP;
use List::Util qw(sum);
use parent qw(Exporter);

use Chess::Constant;
use Chess::State;
use Chess::TableUtil qw(canonical_fen_key);

sub _empty_square_table {
    my %table;
    for my $file (qw(a b c d e f g h)) {
        for my $rank (1 .. 8) {
            $table{"$file$rank"} = 0;
        }
    }
    return \%table;
}

our %location_modifiers = map {
    $_ => _empty_square_table()
} qw(
    KING QUEEN BISHOP KNIGHT ROOK PAWN
    OPP_KING OPP_QUEEN OPP_BISHOP OPP_KNIGHT OPP_ROOK OPP_PAWN
);

our @EXPORT_OK = qw(%location_modifiers load_from_file save_to_file train_from_stream default_store_path);

sub load_from_file;
sub save_to_file;

my @FILES = qw(a b c d e f g h);
my @RANKS = (1 .. 8);
my @ALL_SQUARES = map {
    my $file = $_;
    map { "$file$_" } @RANKS;
} @FILES;

my @TRAINABLE_PIECES = qw(KING QUEEN BISHOP KNIGHT ROOK PAWN);

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
my %san_move_cache;
my $san_move_cache_size = 0;
my $SAN_MOVE_CACHE_MAX = 200_000;
my %state_move_candidates_cache;
my $state_move_candidates_cache_size = 0;
my $STATE_MOVE_CANDIDATES_CACHE_MAX = 100_000;

sub default_store_path {
    return $ENV{PERLGIGACHESS_LOCATION_MODIFIER_FILE}
      if defined $ENV{PERLGIGACHESS_LOCATION_MODIFIER_FILE}
      && length $ENV{PERLGIGACHESS_LOCATION_MODIFIER_FILE};

    my $module_dir = dirname(__FILE__);
    my $root = File::Spec->catdir($module_dir, '..');
    return File::Spec->catfile($root, 'data', 'location_modifiers.json');
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
    my $accumulate = exists $opts{accumulate} ? ($opts{accumulate} ? 1 : 0) : 0;
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

    _apply_counts(\%counts, $scale, $accumulate);
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
    my @tokens = _tokenize_movetext($body);

    TOKEN: for my $raw (@tokens) {
        next unless length $raw;
        next if $raw eq '...';

        if ($raw =~ /^\d+\.(.*)$/) {
            $raw = $1;
            redo TOKEN unless length $raw;
        }

        next if $raw =~ /^\d+\.{1,3}$/;
        next if $raw =~ /^\$\d+$/;
        last if $raw =~ /^(1-0|0-1|1\/2-1\/2|\*)$/;

        my $move = _san_to_move($state, $raw);
        unless ($move) {
            ${$skipped_moves_ref}++;
            next;
        }

        my $next_state = $state->make_move($move);
        if (!$next_state) {
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

        $state = $next_state;
    }

    return 1;
}

sub _clean_pgn_body {
    my ($body) = @_;
    my @tokens = grep { $_ !~ /^\$\d+$/ } _tokenize_movetext($body);
    return join ' ', @tokens;
}

sub _tokenize_movetext {
    my ($body) = @_;
    my @tokens;
    my $buf = '';
    my $paren_depth = 0;
    my $brace_depth = 0;
    my $in_line_comment = 0;

    my $text = $body // '';
    my $length = length $text;
    for (my $i = 0; $i < $length; $i++) {
        my $ch = substr($text, $i, 1);
        $ch = ' ' if ord($ch) == 0xA0;

        if ($in_line_comment) {
            if ($ch eq "\n" || $ch eq "\r") {
                $in_line_comment = 0;
            }
            next;
        }
        if ($brace_depth > 0) {
            if ($ch eq '{') {
                $brace_depth++;
            } elsif ($ch eq '}') {
                $brace_depth--;
            }
            next;
        }
        if ($paren_depth > 0) {
            if ($ch eq '(') {
                $paren_depth++;
            } elsif ($ch eq ')') {
                $paren_depth--;
            }
            next;
        }

        if ($ch eq ';') {
            $in_line_comment = 1;
            next;
        }
        if ($ch eq '{') {
            $brace_depth = 1;
            next;
        }
        if ($ch eq '(') {
            $paren_depth = 1;
            next;
        }

        if ($ch =~ /\s/) {
            if (length $buf) {
                push @tokens, $buf;
                $buf = '';
            }
            next;
        }

        $buf .= $ch;
    }

    push @tokens, $buf if length $buf;
    return @tokens;
}

sub _san_to_move {
    my ($state, $token) = @_;
    my $san = $token;
    $san =~ s/^\s+|\s+$//g;
    return unless length $san;
    $san =~ tr/0/O/;
    $san =~ s/[!?]+$//;
    $san =~ s/[+#]+$//;
    $san =~ s/e\.p\.//i;
    my $cache_token = uc($san);

    my $state_key = canonical_fen_key($state);
    my $cache_key = defined $state_key ? "$state_key|$cache_token" : undef;
    if (defined $cache_key && exists $san_move_cache{$cache_key}) {
        my $cached_uci = $san_move_cache{$cache_key};
        return unless defined $cached_uci && length $cached_uci;
        return $state->encode_move($cached_uci);
    }

    if ($san =~ /^O-O$/i) {
        my $move = _find_castle_move($state, CASTLE_KING, $state_key);
        _store_san_move_cache($cache_key, defined $move ? $state->decode_move($move) : '')
          if defined $cache_key;
        return $move;
    }
    if ($san =~ /^O-O-O$/i) {
        my $move = _find_castle_move($state, CASTLE_QUEEN, $state_key);
        _store_san_move_cache($cache_key, defined $move ? $state->decode_move($move) : '')
          if defined $cache_key;
        return $move;
    }

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
    my $promo_piece = defined $promotion ? $PROMOTION_FROM_CHAR{$promotion} : undef;
    return if defined $promotion && !defined $promo_piece;
    my $candidates = _move_candidates_for_state($state, $state_key);

    MOVE: for my $candidate (@{$candidates}) {
        next if $candidate->{to} ne $target;

        next if $candidate->{piece} != $piece_type;

        if (defined $dis_file && $candidate->{from_file} ne $dis_file) {
            next MOVE;
        }
        if (defined $dis_rank && $candidate->{from_rank} ne $dis_rank) {
            next MOVE;
        }

        if ($is_capture) {
            next MOVE unless $candidate->{capture};
        } else {
            next MOVE if $candidate->{capture};
        }

        if ($promotion) {
            next MOVE unless defined $candidate->{promo_piece}
              && $candidate->{promo_piece} == $promo_piece;
        } else {
            next MOVE if defined $candidate->{promo_piece};
        }

        _store_san_move_cache($cache_key, $candidate->{uci}) if defined $cache_key;
        return $candidate->{move};
    }

    _store_san_move_cache($cache_key, '') if defined $cache_key;
    return;
}

sub _find_castle_move {
    my ($state, $castle_flag, $state_key) = @_;
    my $candidates = _move_candidates_for_state($state, $state_key);
    for my $candidate (@{$candidates}) {
        next unless defined $candidate->{castle_flag};
        return $candidate->{move} if $candidate->{castle_flag} == $castle_flag;
    }
    return;
}

sub _move_candidates_for_state {
    my ($state, $state_key) = @_;
    if (defined $state_key && exists $state_move_candidates_cache{$state_key}) {
        return $state_move_candidates_cache{$state_key};
    }

    my $board = $state->[Chess::State::BOARD];
    my @candidates;
    for my $move (@{$state->generate_pseudo_moves}) {
        my $uci = $state->decode_move($move);
        next unless defined $uci && length($uci) >= 4;

        my $from = substr($uci, 0, 2);
        my $to = substr($uci, 2, 2);
        next unless $from =~ /^[a-h][1-8]$/ && $to =~ /^[a-h][1-8]$/;

        my $dest_piece = $board->[$move->[1]];
        push @candidates, {
            move        => $move,
            uci         => $uci,
            to          => $to,
            from_file   => substr($from, 0, 1),
            from_rank   => substr($from, 1, 1),
            piece       => $board->[$move->[0]],
            capture     => ($dest_piece < 0 ? 1 : 0),
            promo_piece => (defined $move->[2] ? $move->[2] : undef),
            castle_flag => $move->[3],
        };
    }

    my $candidate_ref = \@candidates;
    if (defined $state_key) {
        if (!exists $state_move_candidates_cache{$state_key}) {
            $state_move_candidates_cache_size++;
        }
        $state_move_candidates_cache{$state_key} = $candidate_ref;
        if ($state_move_candidates_cache_size > $STATE_MOVE_CANDIDATES_CACHE_MAX) {
            %state_move_candidates_cache = ();
            $state_move_candidates_cache_size = 0;
        }
    }
    return $candidate_ref;
}

sub _store_san_move_cache {
    my ($cache_key, $value) = @_;
    return unless defined $cache_key;
    if (!exists $san_move_cache{$cache_key}) {
        $san_move_cache_size++;
    }
    $san_move_cache{$cache_key} = $value;
    if ($san_move_cache_size > $SAN_MOVE_CACHE_MAX) {
        %san_move_cache = ();
        $san_move_cache_size = 0;
    }
}

sub _apply_counts {
    my ($counts, $scale, $accumulate) = @_;
    my $square_total = scalar @ALL_SQUARES || 64;
    $accumulate = $accumulate ? 1 : 0;

    for my $piece (@TRAINABLE_PIECES) {
        my $square_counts = $counts->{$piece} || next;
        my $total = sum(values %{$square_counts}) || next;
        my $mean = $total / $square_total;
        for my $square (@ALL_SQUARES) {
            my $hits = $square_counts->{$square} || 1;
            my $ratio = $hits / ($mean || 1);
            my $score = int(log($ratio) * $scale);
            if ($accumulate) {
                my $existing = $location_modifiers{$piece}{$square} // 0;
                $location_modifiers{$piece}{$square} = int($existing + $score);
            } else {
                $location_modifiers{$piece}{$square} = $score;
            }
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

BEGIN {
    my $default = default_store_path();
    load_from_file($default) if defined $default && -e $default;
}

1;
