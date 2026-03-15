#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/..";

use Test::More;

use Chess::TimeManager;

my $now = 100.0;
{
  no warnings 'redefine';
  local *Chess::TimeManager::_now = sub { return $now; };

  my $tm = Chess::TimeManager->new(check_interval_nodes => 3);
  ok(!$tm->has_budget, 'new manager starts without a budget');

  $tm->start_budget_ms(10, 20);
  ok($tm->has_budget, 'start_budget_ms enables the budget');
  ok(!$tm->soft_deadline_reached, 'soft deadline not reached immediately');
  ok(!$tm->hard_deadline_reached, 'hard deadline not reached immediately');
  is($tm->soft_time_left_ms, 10, 'soft_time_left_ms reports the remaining soft budget');
  is($tm->hard_time_left_ms, 20, 'hard_time_left_ms reports the remaining hard budget');

  ok(!$tm->tick_node_and_hard_deadline_reached, 'first tick does not check deadline');
  ok(!$tm->tick_node_and_hard_deadline_reached, 'second tick does not check deadline');
  $now = 100.021;
  ok($tm->tick_node_and_hard_deadline_reached, 'third tick checks and notices hard deadline');

  $now = 200.0;
  $tm->start_budget_ms(10, 12);
  $tm->extend_soft_budget_ms(50);
  is(sprintf('%.3f', $tm->{soft_deadline}), '200.011', 'soft budget extension is capped below hard deadline');

  $now = 200.010;
  ok(!$tm->soft_deadline_reached, 'capped soft deadline still lies in the future');
  $now = 200.011;
  ok($tm->soft_deadline_reached, 'soft deadline trips at the capped value');
  is($tm->soft_time_left_ms, 0, 'soft_time_left_ms floors at zero after expiry');

  $tm->start_budget_ms(0, 0);
  ok(!$tm->has_budget, 'invalid budgets reset the manager');

  my $default_tm = Chess::TimeManager->new(check_interval_nodes => 'bad');
  $now = 300.0;
  $default_tm->start_budget_ms(1, 1);
  $now = 300.002;
  ok($default_tm->tick_node_and_hard_deadline_reached, 'invalid check interval falls back to one node');
}

done_testing();
