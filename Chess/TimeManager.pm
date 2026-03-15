package Chess::TimeManager;
use strict;
use warnings;

use Time::HiRes qw(time);

my $MONOTONIC_CLOCK_ID = eval { Time::HiRes::CLOCK_MONOTONIC() };

sub new {
  my ($class, %opts) = @_;
  my $check_interval_nodes = $opts{check_interval_nodes};
  $check_interval_nodes = 1 unless defined $check_interval_nodes && $check_interval_nodes =~ /^\d+$/;
  $check_interval_nodes = 1 if $check_interval_nodes < 1;

  my $self = {
    check_interval_nodes => $check_interval_nodes,
    has_budget => 0,
    soft_deadline => 0.0,
    hard_deadline => 0.0,
    node_count => 0,
  };
  return bless $self, $class;
}

sub reset {
  my ($self) = @_;
  $self->{has_budget} = 0;
  $self->{soft_deadline} = 0.0;
  $self->{hard_deadline} = 0.0;
  $self->{node_count} = 0;
}

sub start_budget_ms {
  my ($self, $soft_ms, $hard_ms) = @_;

  return $self->reset() unless defined $soft_ms && defined $hard_ms;

  $soft_ms = int($soft_ms);
  $hard_ms = int($hard_ms);
  return $self->reset() if $soft_ms <= 0 || $hard_ms <= 0;

  $hard_ms = $soft_ms if $hard_ms < $soft_ms;
  my $start = _now();
  $self->{has_budget} = 1;
  $self->{soft_deadline} = $start + ($soft_ms / 1000.0);
  $self->{hard_deadline} = $start + ($hard_ms / 1000.0);
  $self->{node_count} = 0;
}

sub has_budget {
  my ($self) = @_;
  return $self->{has_budget} ? 1 : 0;
}

sub soft_deadline_reached {
  my ($self) = @_;
  return 0 unless $self->{has_budget};
  return _now() >= $self->{soft_deadline} ? 1 : 0;
}

sub hard_deadline_reached {
  my ($self) = @_;
  return 0 unless $self->{has_budget};
  return _now() >= $self->{hard_deadline} ? 1 : 0;
}

sub soft_time_left_ms {
  my ($self) = @_;
  return 0 unless $self->{has_budget};
  my $left_ms = int((($self->{soft_deadline} - _now()) * 1000.0) + 0.5);
  return $left_ms > 0 ? $left_ms : 0;
}

sub hard_time_left_ms {
  my ($self) = @_;
  return 0 unless $self->{has_budget};
  my $left_ms = int((($self->{hard_deadline} - _now()) * 1000.0) + 0.5);
  return $left_ms > 0 ? $left_ms : 0;
}

sub extend_soft_budget_ms {
  my ($self, $extra_ms) = @_;
  return unless $self->{has_budget};
  return unless defined $extra_ms && $extra_ms > 0;

  my $extended = $self->{soft_deadline} + ($extra_ms / 1000.0);
  my $hard_ceiling = $self->{hard_deadline} - 0.001;
  $extended = $hard_ceiling if $extended > $hard_ceiling;
  $self->{soft_deadline} = $extended if $extended > $self->{soft_deadline};
}

sub tick_node_and_hard_deadline_reached {
  my ($self) = @_;
  return 0 unless $self->{has_budget};

  $self->{node_count}++;
  return 0 if $self->{node_count} % $self->{check_interval_nodes};
  return $self->hard_deadline_reached();
}

sub _now {
  if (defined $MONOTONIC_CLOCK_ID && Time::HiRes->can('clock_gettime')) {
    return Time::HiRes::clock_gettime($MONOTONIC_CLOCK_ID);
  }
  return time();
}

1;
