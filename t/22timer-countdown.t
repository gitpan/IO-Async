#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 42;
use Test::Fatal;
use Test::Refcount;

use Time::HiRes qw( time );

use IO::Async::Timer::Countdown;

use IO::Async::Loop::Poll;

use constant AUT => $ENV{TEST_QUICK_TIMERS} ? 0.1 : 1;

# Kindof like Test::Timer only we use Time::HiRes
# We'll be quite lenient on the time taken, in case of heavy test machine load
sub time_about
{
   my ( $code, $target, $name ) = @_;

   my $lower = $target*0.75;
   my $upper = $target*1.5 + 1;

   my $now = time;
   $code->();
   my $took = (time - $now) / AUT;

   cmp_ok( $took, '>', $lower, "$name took at least $lower" );
   cmp_ok( $took, '<', $upper * 3, "$name took no more than $upper" );
   if( $took > $upper and $took <= $upper * 3 ) {
      diag( "$name took longer than $upper - this may just be an indication of a busy testing machine rather than a bug" );
   }
}

my $loop = IO::Async::Loop::Poll->new();

testing_loop( $loop );

my $expired;

my @eargs;

my $timer = IO::Async::Timer::Countdown->new(
   delay => 2 * AUT,

   on_expire => sub { @eargs = @_; $expired = 1 },
);

ok( defined $timer, '$timer defined' );
isa_ok( $timer, "IO::Async::Timer", '$timer isa IO::Async::Timer' );

is_oneref( $timer, '$timer has refcount 1 initially' );

$loop->add( $timer );

is_refcount( $timer, 2, '$timer has refcount 2 after adding to Loop' );

is( $timer->start, $timer, '$timer->start returns $timer' );

is_refcount( $timer, 2, '$timer has refcount 2 after starting' );

ok( $timer->is_running, 'Started Timer is running' );

time_about( sub { wait_for { $expired } }, 2, 'Timer works' );
is_deeply( \@eargs, [ $timer ], 'on_expire args' );

ok( !$timer->is_running, 'Expired Timer is no longer running' );

undef @eargs;

is_refcount( $timer, 2, '$timer has refcount 2 before removing from Loop' );

$loop->remove( $timer );

is_oneref( $timer, '$timer has refcount 1 after removing from Loop' );

undef $expired;

is( $timer->start, $timer, '$timer->start out of a Loop returns $timer' );

$loop->add( $timer );

time_about( sub { wait_for { $expired } }, 2, 'Timer works a second time' );

undef $expired;
$timer->start;

$loop->loop_once( 1 * AUT );

$timer->stop;

$loop->loop_once( 2 * AUT );

ok( !$expired, "Stopped timer doesn't expire" );

undef $expired;
$timer->start;

$loop->loop_once( 1 * AUT );

my $now = time;
$timer->reset;

$loop->loop_once( 1.5 * AUT );

ok( !$expired, "Reset Timer hasn't expired yet" );

wait_for { $expired };
my $took = (time - $now) / AUT;

cmp_ok( $took, '>', 1.5, "Timer has now expired took at least 1.5" );
cmp_ok( $took, '<', 2.5, "Timer has now expired took no more than 2.5" );

undef $expired;
$timer->start;

$loop->remove( $timer );

$loop->loop_once( 3 * AUT );

ok( !$expired, "Removed Timer does not expire" );

$timer->start;

$loop->add( $timer );

ok( $timer->is_running, 'Pre-started Timer is running after adding' );

time_about( sub { wait_for { $expired } }, 2, 'Pre-started Timer works' );

$loop->remove( $timer );

undef $expired;

$timer->start;
$timer->stop;

$loop->add( $timer );

$loop->loop_once( 3 * AUT );

is( $expired, undef, "start/stopped Timer doesn't expire" );

$timer->configure( delay => 1 * AUT );

undef $expired;
$timer->start;

time_about( sub { wait_for { $expired } }, 1, 'Reconfigured timer delay works' );

my $new_expired;
$timer->configure( on_expire => sub { $new_expired = 1 } );

$timer->start;

time_about( sub { wait_for { $new_expired } }, 1, 'Reconfigured timer on_expire works' );

$timer->start;
ok( exception { $timer->configure( delay => 5 ); },
    'Configure a running timer fails' );

$loop->remove( $timer );

undef @eargs;

is_oneref( $timer, 'Timer has refcount 1 finally' );

undef $timer;

## Subclass

my $sub_expired;

$timer = TestTimer->new(
   delay => 2 * AUT,
);

ok( defined $timer, 'subclass $timer defined' );
isa_ok( $timer, "IO::Async::Timer", 'subclass $timer isa IO::Async::Timer' );

is_oneref( $timer, 'subclass $timer has refcount 1 initially' );

$loop->add( $timer );

is_refcount( $timer, 2, 'subclass $timer has refcount 2 after adding to Loop' );

$timer->start;

is_refcount( $timer, 2, 'subclass $timer has refcount 2 after starting' );

ok( $timer->is_running, 'Started subclass Timer is running' );

time_about( sub { wait_for { $sub_expired } }, 2, 'subclass Timer works' );

ok( !$timer->is_running, 'Expired subclass Timer is no longer running' );

is_refcount( $timer, 2, 'subclass $timer has refcount 2 before removing from Loop' );

$loop->remove( $timer );

is_oneref( $timer, 'subclass $timer has refcount 1 after removing from Loop' );

undef $timer;

package TestTimer;
use base qw( IO::Async::Timer::Countdown );

sub on_expire { $sub_expired = 1 }