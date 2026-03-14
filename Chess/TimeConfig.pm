package Chess::TimeConfig;
use strict;
use warnings;

# Centralized time/think multiplier configuration for the gigachess.
# These settings control how the engine allocates thinking time during various time controls.

sub _env_int {
  my ($name, $default, $min, $max) = @_;
  my $value = $ENV{$name};
  $value = $default unless defined $value && $value =~ /^-?\d+$/;
  $value = int($value);
  $value = $min if defined $min && $value < $min;
  $value = $max if defined $max && $value > $max;
  return $value;
}

sub _env_num {
  my ($name, $default, $min, $max) = @_;
  my $value = $ENV{$name};
  $value = $default unless defined $value && $value =~ /^-?\d+(?:\.\d+)?$/;
  $value += 0;
  $value = $min if defined $min && $value < $min;
  $value = $max if defined $max && $value > $max;
  return $value;
}

# --- Opening boost settings (production profile) ---
our $OPENING_BOOST_MULT  = _env_num('CHESS_PROD_OPENING_MULT', 1.20, 1.0, 2.0);
our $OPENING_BOOST_PLIES = _env_int('CHESS_PROD_OPENING_PLIES', 18, 0, 80);
our $OPENING_CAP_MULT    = _env_num('CHESS_PROD_OPENING_CAP_MULT', 1.25, 1.0, 2.0);
our $OPENING_FLOOR_MS    = _env_int('CHESS_PROD_OPENING_FLOOR_MS', 8000, 0, 30_000);
our $OPENING_FLOOR_PLIES = _env_int('CHESS_PROD_OPENING_FLOOR_PLIES', 16, 0, 80);

# --- General production think settings ---
our $PROD_THINK_MULT = _env_num('CHESS_PROD_THINK_MULT', 1.18, 1.0, 2.0);
our $PROD_CAP_MULT   = _env_num('CHESS_PROD_CAP_MULT', 1.35, 1.0, 2.0);
our $PROD_FLOOR_MS   = _env_int('CHESS_PROD_FLOOR_MS', 2600, 0, 30_000);

# --- Post-book phase settings ---
our $POST_BOOK_THINK_MULT = _env_num('CHESS_POST_BOOK_THINK_MULT', 1.12, 1.0, 2.0);
our $POST_BOOK_CAP_MULT   = _env_num('CHESS_POST_BOOK_CAP_MULT', 1.18, 1.0, 2.0);

# --- Develop branch settings ---
our $DEVELOP_DEPTH_BUMP = _env_int('CHESS_DEVELOP_DEPTH_BUMP', 0, 0, 4);
our $DEVELOP_THINK_MULT = _env_num('CHESS_DEVELOP_THINK_MULT', 1.0, 1.0, 2.0);
our $DEVELOP_CAP_MULT   = _env_num('CHESS_DEVELOP_CAP_MULT', 1.0, 1.0, 2.0);

# --- Panic mode settings ---
our $PANIC_30S_MS     = _env_int('CHESS_PANIC_30S_MS', 30_000, 1_000, 180_000);
our $PANIC_10S_MS     = _env_int('CHESS_PANIC_10S_MS', 10_000, 500, $PANIC_30S_MS);
our $PANIC_30S_CAP_MS = _env_int('CHESS_PANIC_30S_CAP_MS', 2_200, 200, 8_000);
our $PANIC_10S_CAP_MS = _env_int('CHESS_PANIC_10S_CAP_MS', 900, 80, $PANIC_30S_CAP_MS);

# --- Eval drop re-think settings ---
our $EVAL_DROP_EXTRA_THINK_CP   = _env_int('CHESS_EVAL_DROP_EXTRA_THINK_CP', 40, 0, 1000);
our $EVAL_DROP_EXTRA_THINK_MULT = _env_num('CHESS_EVAL_DROP_EXTRA_THINK_MULT', 1.55, 1.0, 3.0);
our $RETHINK_DEPTH_BUMP         = _env_int('CHESS_RETHINK_DEPTH_BUMP', 1, 0, 4);

1;
